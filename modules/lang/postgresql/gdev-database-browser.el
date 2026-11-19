;;; gdev-database-browser.el --- Esploratore comune di Database SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La vista gestisce navigazione, selezione e ciclo di vita delle richieste.
;; Il motore restituisce il catalogo o l'anteprima con un formato comune.

;;; Code:

(require 'cl-lib)
(require 'hl-line)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'text-property-search)
(require 'gdev-handlers)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function gdev-close-document "gdev-commands" ())
(declare-function gdev-database-browse "config" (&optional choose))
(declare-function mouse-set-point "mouse" (event &optional promote-to-region))
(defvar gdev-context-items)

(defvar-local gdev-database-browser--engine nil)
(defvar-local gdev-database-browser--connection nil)
(defvar-local gdev-database-browser--request nil)
(defvar-local gdev-database-browser--origin nil)
(defvar-local gdev-database-browser--path nil)
(defvar-local gdev-database-browser--rows nil)
(defvar-local gdev-database-browser--job nil
  "Identità della richiesta corrente, con la sua funzione di annullamento.")

(defconst gdev-database-browser--kinds
  '(("r" . "Tabella") ("p" . "Partizionata") ("v" . "Vista")
    ("m" . "Vista materializzata") ("f" . "Tabella esterna")))

(defun gdev-database-browser--label (value)
  "Mostra VALUE su una riga e conserva il testo completo nel suggerimento."
  (propertize (replace-regexp-in-string "[[:cntrl:]]" "·" value) 'help-echo value))

(defun gdev-database-browser--preview-format (rows)
  "Prepara le intestazioni della griglia di ROWS."
  (let ((headings (make-hash-table :test 'equal)))
    (puthash "Riga" t headings)
    (vconcat
     '[("Riga" 5 nil)]
     (mapcar
      (lambda (pair)
        (let* ((name (gdev-database-browser--label (car pair)))
               (heading name)
               (count 1))
          (while (gethash heading headings)
            (setq heading (propertize (format "%s (%d)" name (cl-incf count))
                                      'help-echo (car pair))))
          (puthash heading t headings)
          (list heading 18 nil)))
      (car rows)))))

(defun gdev-database-browser--format (depth rows width)
  "Prepara le colonne per DEPTH e ROWS con WIDTH colonne di finestra."
  (let ((available (- width tabulated-list-padding)))
    (pcase depth
      (0 '[("Schema" 24 t)])
      (1 (vector (list "Nome" (max 8 (min 27 (- available 21))) t)
                 '("Tipo" 20 t)))
      (2 (let ((column (max 8 (min 22 (/ (- available 14) 2)))))
           (vector (list "Colonna" column t) (list "Tipo" column t)
                   '("Obbligatoria" 12 t))))
      (3 (gdev-database-browser--preview-format rows)))))

(defun gdev-database-browser--entries (depth rows)
  "Prepara le righe di DEPTH senza alterare le identità in ROWS."
  (pcase depth
    (0 (mapcar (lambda (name) (list name (vector (gdev-database-browser--label name)))) rows))
    (1 (mapcar (lambda (row)
                 (cl-destructuring-bind (name kind) row
                   (list name (vector (gdev-database-browser--label name)
                                      (alist-get kind gdev-database-browser--kinds "Relazione" nil #'equal)))))
               rows))
    (2 (mapcar (lambda (row)
                 (cl-destructuring-bind (name type required) row
                   (list name (vector (gdev-database-browser--label name)
                                      (gdev-database-browser--label type)
                                      (if (eq required t) "Sì" "No")))))
               rows))
    (3 (cl-loop for row in rows for number from 1
                collect
                (list number
                      (vconcat (list (number-to-string number))
                               (mapcar (lambda (pair)
                                         (gdev-database-browser--label (or (cadr pair) "NULL")))
                                       row)))))))

(defun gdev-database-browser--status (&optional status detail)
  "Mostra il percorso corrente e un eventuale STATUS con il suo DETAIL."
  (let* ((path gdev-database-browser--path)
         (location (if path
                       (mapconcat #'gdev-database-browser--label (seq-take path 2) " › ")
                     "Schemi"))
         (text (string-join (delq nil (list status location
                                           (when (= (length path) 3) "Anteprima · fino a 50 righe")))
                            " · ")))
    (setq mode-line-process
          (list " · " (propertize (replace-regexp-in-string "%" "%%" text t t)
                                  'help-echo (or detail text))))
    (force-mode-line-update)))

(defun gdev-database-browser--select (id)
  "Raggiungi ID anche se la riga è stata spostata dall'ordinamento."
  (when (and id (not (equal id (tabulated-list-get-id))))
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'tabulated-list-id id t)))
      (goto-char (prop-match-beginning match)))))

(defun gdev-database-browser--render (path rows &optional selected)
  "Mostra ROWS al livello PATH e mantieni il punto su SELECTED."
  (let* ((depth (length path))
         (window (get-buffer-window (current-buffer) t))
         (same-level (equal path gdev-database-browser--path))
         (id (or selected (when same-level (tabulated-list-get-id)))))
    (unless same-level
      (setq tabulated-list-sort-key nil)
      (dolist (view (get-buffer-window-list (current-buffer) nil t))
        (set-window-hscroll view 0)))
    (setq gdev-database-browser--path path
          gdev-database-browser--rows rows
          tabulated-list-format (gdev-database-browser--format depth rows (if window (window-body-width window) 80))
          tabulated-list-entries (gdev-database-browser--entries depth rows))
    (tabulated-list-init-header)
    (tabulated-list-print same-level)
    (gdev-database-browser--select id)
    (gdev-database-browser--status (unless rows "Nessun elemento"))))

(defun gdev-database-browser--resize (window)
  "Adatta le colonne di WINDOW riutilizzando i risultati già letti."
  (let ((depth (length gdev-database-browser--path)))
    (when (memq depth '(1 2))
      (let ((format (gdev-database-browser--format depth gdev-database-browser--rows
                                                  (window-body-width window))))
        (unless (equal tabulated-list-format format)
          (setq tabulated-list-format format)
          (tabulated-list-init-header)
          (tabulated-list-print t))))))

(defun gdev-database-browser--tab ()
  "Cerca lo spazio proprietario della vista, anche dopo un trasferimento."
  (when gdev-database-browser--origin
    (let ((view (current-buffer)))
      (cl-loop for frame in (frame-list)
               for tab = (gdev-workspace-state-find gdev-database-browser--origin frame)
               when (memq view (gdev-workspace-state-read 'gdev-database-browser-buffers tab))
               return tab))))

(defun gdev-database-browser--cancel ()
  "Invalida e annulla l'eventuale richiesta della vista."
  (let ((cancel (car gdev-database-browser--job)))
    (setq gdev-database-browser--job nil)
    (when cancel (funcall cancel))))

(defun gdev-database-browser-cancel ()
  "Annulla il caricamento e mantieni il livello visibile."
  (interactive)
  (when gdev-database-browser--job
    (gdev-database-browser--cancel)
    (gdev-database-browser--status "Caricamento annullato")))

(defun gdev-database-browser--failure (diagnostic)
  "Mostra DIAGNOSTIC senza sostituire l'ultimo livello valido."
  (gdev-database-browser--status "Caricamento non riuscito" diagnostic)
  (when (eq gdev-database-browser--origin (gdev-workspace-state-id))
    (message "Database SQL: %s" diagnostic)))

(defun gdev-database-browser--load (path &optional selected)
  "Richiedi PATH in secondo piano e ripristina SELECTED se disponibile."
  (unless (gdev-database-browser--tab)
    (user-error "Questo spazio di lavoro non è più aperto"))
  (gdev-database-browser--cancel)
  (let ((job (list nil))
        (view (current-buffer)))
    (setq gdev-database-browser--job job)
    (gdev-database-browser--status "Caricamento…")
    (condition-case failure
        (setcar job
                (funcall
                 gdev-database-browser--request gdev-database-browser--connection path
                 (lambda (rows diagnostic)
                   (when (buffer-live-p view)
                     (with-current-buffer view
                       (when (and (eq job gdev-database-browser--job)
                                  (gdev-database-browser--tab))
                         (setq gdev-database-browser--job nil)
                         (if diagnostic
                             (gdev-database-browser--failure diagnostic)
                           (gdev-database-browser--render
                            path rows (if (equal path gdev-database-browser--path)
                                          (or (tabulated-list-get-id) selected)
                                        selected)))))))))
      (quit (gdev-database-browser-cancel) (signal (car failure) (cdr failure)))
      (error (gdev-database-browser--cancel)
             (gdev-database-browser--failure (error-message-string failure))))))

(defun gdev-database-browser-open ()
  "Apri lo schema o la relazione sulla riga corrente."
  (interactive)
  (when (and (< (length gdev-database-browser--path) 2) (tabulated-list-get-id))
    (gdev-database-browser--load
     (append gdev-database-browser--path (list (tabulated-list-get-id))))))

(defun gdev-database-browser-click (event)
  "Apri la voce sulla riga del clic EVENT."
  (interactive "e")
  (mouse-set-point event)
  (gdev-database-browser-open))

(defun gdev-database-browser-up ()
  "Torna al livello precedente e seleziona l'oggetto appena consultato."
  (interactive)
  (when-let* ((path gdev-database-browser--path))
    (gdev-database-browser--load
     (butlast path) (unless (= (length path) 3) (car (last path))))))

(defun gdev-database-browser-refresh ()
  "Aggiorna il livello visibile conservandone la selezione."
  (interactive)
  (gdev-database-browser--load gdev-database-browser--path (tabulated-list-get-id)))

(defun gdev-database-browser-preview ()
  "Mostra un'anteprima in sola lettura della relazione corrente."
  (interactive)
  (unless (= (length gdev-database-browser--path) 2)
    (user-error "Apri prima una tabella o una vista"))
  (gdev-database-browser--load (append gdev-database-browser--path '(anteprima))))

(defun gdev-database-browser-switch ()
  "Scegli un'altra connessione da esplorare."
  (interactive)
  (gdev-database-browse t))

(defun gdev-database-browser--release ()
  "Termina la richiesta e rimuovi la vista dal suo spazio."
  (gdev-database-browser--cancel)
  (when-let* ((tab (gdev-database-browser--tab)))
    (gdev-workspace-state-set 'gdev-database-browser-buffers
                              (remq (current-buffer)
                                    (gdev-workspace-state-read 'gdev-database-browser-buffers tab))
                              tab)))

(defun gdev-database-browser--close-tab (tab last-tab)
  "Rilascia le viste di TAB quando si chiude e non è LAST-TAB."
  (unless (or last-tab gdev-workspace-state--moving-tab)
    (dolist (view (gdev-workspace-state-read 'gdev-database-browser-buffers tab))
      (when (buffer-live-p view) (kill-buffer view)))))

(defun gdev-database-browser--close-frame (frame)
  "Rilascia le viste degli spazi che appartengono a FRAME."
  (dolist (tab (gdev-workspace-state-tabs frame))
    (gdev-database-browser--close-tab tab nil)))

(defvar-keymap gdev-database-browser-mode-map
  :parent tabulated-list-mode-map
  :doc "Tasti dell'esploratore Database SQL."
  "RET" #'gdev-database-browser-open
  "<double-mouse-1>" #'gdev-database-browser-click
  "^" #'gdev-database-browser-up
  "g" #'gdev-database-browser-refresh
  "v" #'gdev-database-browser-preview
  "c" #'gdev-database-browser-switch
  "C-c C-k" #'gdev-database-browser-cancel
  "q" #'gdev-close-document)

(define-derived-mode gdev-database-browser-mode tabulated-list-mode "Database SQL"
  "Esplora schemi, tabelle, viste, colonne e dati della connessione."
  (gdev-ui-view-setup 'table)
  (setq-local gdev-context-items
              '(["Apri" gdev-database-browser-open
                 (and (< (length gdev-database-browser--path) 2) (tabulated-list-get-id))]
                ["Livello precedente" gdev-database-browser-up gdev-database-browser--path]
                ["Anteprima delle righe" gdev-database-browser-preview
                 (= (length gdev-database-browser--path) 2)]
                ["Aggiorna" gdev-database-browser-refresh]
                ["Annulla caricamento" gdev-database-browser-cancel gdev-database-browser--job]
                ["Scegli connessione…" gdev-database-browser-switch]))
  (add-hook 'kill-buffer-hook #'gdev-database-browser--release nil t)
  (add-hook 'window-size-change-functions #'gdev-database-browser--resize nil t)
  (hl-line-mode 1))

(defun gdev-database-browser-display (engine connection label directory request &optional mode)
  "Mostra la CONNECTION di ENGINE e restituisci il buffer selezionato.
LABEL distingue la connessione. DIRECTORY contiene l'ambiente di progetto.
REQUEST riceve CONNECTION, il percorso e la funzione di consegna
(RIGHE ERRORE). Restituisce una funzione di annullamento senza argomenti.
MODE è una modalità compatibile con l'esploratore comune."
  (let* ((origin (gdev-workspace-state-ensure-id))
         (buffers (seq-filter #'buffer-live-p
                              (gdev-workspace-state-get 'gdev-database-browser-buffers)))
         (view (seq-find (lambda (buffer)
                           (with-current-buffer buffer
                             (and (eq gdev-database-browser--engine engine)
                                  (equal gdev-database-browser--connection connection))))
                         buffers)))
    (if view
        (pop-to-buffer view)
      (let ((environment process-environment)
            (executables exec-path)
            ready)
        (setq view (generate-new-buffer (format "*Database SQL · %s*" (gdev-database-browser--label label))))
        (unwind-protect
            (progn
              (with-current-buffer view
                (funcall (or mode #'gdev-database-browser-mode))
                (setq-local gdev-database-browser--origin origin
                            gdev-database-browser--engine engine
                            gdev-database-browser--connection connection
                            gdev-database-browser--request request
                            default-directory directory
                            process-environment environment
                            exec-path executables))
              (gdev-workspace-state-set 'gdev-database-browser-buffers (cons view buffers))
              (pop-to-buffer view)
              (with-current-buffer view
                (gdev-database-browser--render nil nil)
                (gdev-database-browser--load nil))
              (setq ready t))
          (unless ready (kill-buffer view)))))
    view))

(gdev-set-popup-rule '(derived-mode . gdev-database-browser-mode))
(add-hook 'tab-bar-tab-pre-close-functions #'gdev-database-browser--close-tab)
(add-hook 'delete-frame-functions #'gdev-database-browser--close-frame)

(provide 'gdev-database-browser)
;;; gdev-database-browser.el ends here
