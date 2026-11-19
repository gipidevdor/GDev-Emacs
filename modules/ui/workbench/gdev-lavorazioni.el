;;; gdev-lavorazioni.el --- Lavorazioni dello spazio di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; L'attività elenca i piani dello spazio e quelli già aperti. Le azioni
;; del documento restano nella vista Composizione e nel sorgente.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'hl-line)
(require 'seq)
(require 'text-property-search)
(require 'gdev-activity)
(require 'gdev-context)
(require 'gdev-layout)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)
(require 'gdev-lavorazione-indice)

(declare-function gdev-lavorazione--apri-sorgente "gdev-lavorazione" (file))
(declare-function gdev-lavorazione-nuova "gdev-lavorazione" (file))
(declare-function gdev-lavorazione-catalogo "gdev-lavorazione" ())
(declare-function gdev-quit-view "gdev-commands" (&optional kill window))
(declare-function gdev-lavorazione-composizione "gdev-lavorazione-composizione" (&optional sorgente))

(defconst gdev-lavorazioni--per-pagina 80 "Numero di piani rilevati da disegnare per pagina.")
(defvar-local gdev-lavorazioni--radici nil)
(defvar-local gdev-lavorazioni--aperti nil)
(defvar-local gdev-lavorazioni--progetto nil)
(defvar-local gdev-lavorazioni--corrente nil)
(defvar-local gdev-lavorazioni--stato nil)
(defvar-local gdev-lavorazioni--richiesta nil)
(defvar-local gdev-lavorazioni--annulla nil)
(defvar-local gdev-lavorazioni--larghezza nil)
(defvar-local gdev-lavorazioni--pagina 0)
(defvar-local gdev-lavorazioni--pagine 1)

(defun gdev-lavorazioni--file (buffer)
  "Restituisci il percorso del piano aperto in BUFFER."
  (when (and (buffer-live-p buffer)
             (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'gdev-lavorazione-mode))
    (buffer-file-name buffer)))

(defun gdev-lavorazioni--documenti (frame)
  "Elenca i percorsi delle lavorazioni aperte nei gruppi di FRAME."
  (delete-dups
   (delq nil
         (cl-loop for editor in (gdev-layout--editors frame)
                  append (mapcar #'gdev-lavorazioni--file
                                 (cons (window-buffer editor)
                                       (window-parameter editor 'tab-line-buffers)))))))

(defun gdev-lavorazioni--annulla-indice ()
  "Invalida la richiesta di rilevamento e libera il suo processo."
  (setq gdev-lavorazioni--richiesta nil)
  (when gdev-lavorazioni--annulla
    (funcall gdev-lavorazioni--annulla)
    (setq gdev-lavorazioni--annulla nil)))

(defun gdev-lavorazioni--appartiene-p (vista identita)
  "Verifica che VISTA sia ancora l'attività dello spazio IDENTITA."
  (seq-some (lambda (frame)
              (when-let* ((tab (gdev-workspace-state-find identita frame)))
                (eq vista (alist-get 'lavorazioni (gdev-workspace-state-read 'gdev-activity-buffers tab)))))
            (frame-list)))

(defun gdev-lavorazioni--avvia-indice (frame)
  "Rileva i piani delle radici correnti di FRAME."
  (gdev-lavorazioni--annulla-indice)
  (if (not gdev-lavorazioni--radici)
      (setq gdev-lavorazioni--stato 'senza-cartella)
    (let ((vista (current-buffer))
          (identita (gdev-workspace-state-ensure-id frame))
          (richiesta (make-symbol "lavorazioni")))
      (setq gdev-lavorazioni--stato 'lettura
            gdev-lavorazioni--richiesta richiesta
            gdev-lavorazioni--annulla
            (gdev-lavorazione-indice-avvia
             gdev-lavorazioni--radici
             (lambda (file stato)
               (when (and (buffer-live-p vista) (gdev-lavorazioni--appartiene-p vista identita))
                 (with-current-buffer vista
                   (when (eq richiesta gdev-lavorazioni--richiesta)
                     (setq gdev-lavorazioni--richiesta nil
                           gdev-lavorazioni--annulla nil
                           gdev-lavorazioni--progetto file
                           gdev-lavorazioni--stato stato)
                     (gdev-lavorazioni--render (get-buffer-window vista t)))))))))))

(defun gdev-lavorazioni--voce ()
  "Restituisci il file indicato nella riga corrente."
  (get-text-property (point) 'gdev-lavorazioni-file))

(defun gdev-lavorazioni--posizione (identita)
  "Trova il pulsante o la riga con IDENTITA."
  (when identita
    (save-excursion
      (goto-char (point-min))
      (when-let* ((voce (text-property-search-forward 'gdev-lavorazioni-voce identita t)))
        (prop-match-beginning voce)))))

(defun gdev-lavorazioni--pulsante (etichetta comando descrizione &optional principale)
  "Mostra ETICHETTA per COMANDO con DESCRIZIONE e faccia PRINCIPALE."
  (insert-text-button etichetta 'type 'gdev-ui-action
                      'face (if principale 'gdev-ui-action-primary 'gdev-ui-action)
                      'gdev-lavorazioni-voce comando 'help-echo descrizione
                      'action (lambda (_) (call-interactively comando))))

(defun gdev-lavorazioni--nome (file)
  "Restituisci il nome leggibile di FILE."
  (replace-regexp-in-string "[[:cntrl:]]" " " (file-name-base file)))

(defun gdev-lavorazioni--riga (file doppio larghezza misura)
  "Mostra FILE, con la cartella se DOPPIO, entro LARGHEZZA usando MISURA."
  (let* ((inizio (point))
         (nome (propertize (gdev-lavorazioni--nome file) 'face 'gdev-ui-action)))
    (insert (gdev-ui-fit-text nome larghezza misura))
    (when doppio
      (let* ((radice (gdev-workspace-root-for file gdev-lavorazioni--radici))
             (base (if (and radice (cdr gdev-lavorazioni--radici))
                       (file-name-directory (directory-file-name (car gdev-lavorazioni--radici)))
                     radice))
             (cartella (if base (file-relative-name (file-name-directory file) base)
                         (abbreviate-file-name (file-name-directory file))))
             (dettaglio (propertize (replace-regexp-in-string "[[:cntrl:]]" " " cartella)
                                   'face 'gdev-ui-secondary 'help-echo file)))
        (insert "\n" (gdev-ui-fit-text dettaglio larghezza misura))))
    (make-text-button inizio (point) 'type 'gdev-ui-action
                      'button-data file 'action #'gdev-lavorazioni-apri-file)
    (insert "\n")
    (add-text-properties inizio (point)
                         (list 'gdev-lavorazioni-file file 'gdev-lavorazioni-voce file
                               'help-echo file))
    (when (equal file gdev-lavorazioni--corrente)
      (add-face-text-property inizio (point) 'gdev-ui-side-current t))))

(defun gdev-lavorazioni--navigazione ()
  "Mostra i controlli per scorrere le pagine del progetto."
  (when (> gdev-lavorazioni--pagine 1)
    (when (> gdev-lavorazioni--pagina 0)
      (gdev-lavorazioni--pulsante "Indietro" #'gdev-lavorazioni-indietro "Pagina precedente")
      (insert "  "))
    (when (< (1+ gdev-lavorazioni--pagina) gdev-lavorazioni--pagine)
      (gdev-lavorazioni--pulsante "Avanti" #'gdev-lavorazioni-avanti "Pagina successiva"))
    (insert "\n" (propertize (format "Pagina %d di %d" (1+ gdev-lavorazioni--pagina)
                                    gdev-lavorazioni--pagine)
                              'face 'gdev-ui-secondary)
            "\n")))

(defun gdev-lavorazioni--render (window &optional pagina-richiesta)
  "Disegna i piani di WINDOW e segui la voce al cursore.
Con PAGINA-RICHIESTA vai alla pagina scelta esplicitamente."
  (let* ((grafica (and (window-live-p window) (display-graphic-p (window-frame window))))
         (misura (if grafica #'gdev-ui-string-pixel-width #'string-width))
         (larghezza (if (window-live-p window) (window-body-width window grafica) 30))
         (voce (get-text-property (if (window-live-p window) (window-point window) (point))
                                  'gdev-lavorazioni-voce))
         (prima (and (window-live-p window)
                     (get-text-property (window-start window) 'gdev-lavorazioni-voce)))
         (progetto (seq-remove (lambda (file) (member file gdev-lavorazioni--aperti))
                              gdev-lavorazioni--progetto))
         (pagine (max 1 (ceiling (length progetto) gdev-lavorazioni--per-pagina)))
         (indice (and (not pagina-richiesta) (stringp voce)
                      (cl-position voce progetto :test #'equal)))
         (pagina (min (or pagina-richiesta
                          (and indice (/ indice gdev-lavorazioni--per-pagina))
                          gdev-lavorazioni--pagina)
                      (1- pagine)))
         (voci (seq-take (nthcdr (* pagina gdev-lavorazioni--per-pagina) progetto)
                         gdev-lavorazioni--per-pagina))
         (conteggi (make-hash-table :test #'equal))
         (inhibit-read-only t))
    (setq gdev-lavorazioni--larghezza larghezza
          gdev-lavorazioni--pagina pagina
          gdev-lavorazioni--pagine pagine)
    (dolist (file (append gdev-lavorazioni--aperti progetto))
      (cl-incf (gethash (gdev-lavorazioni--nome file) conteggi 0)))
    (erase-buffer)
    (insert (propertize "Lavorazioni" 'face 'gdev-ui-side-title) "\n\n")
    (gdev-lavorazioni--pulsante "Nuova…" #'gdev-lavorazioni-nuova "Crea una lavorazione" t)
    (insert "  ")
    (gdev-lavorazioni--pulsante "Apri…" #'gdev-lavorazioni-scegli-file "Apri un file .lavorazione")
    (insert "\n")
    (gdev-lavorazioni--pulsante "Catalogo azioni" #'gdev-lavorazione-catalogo "Consulta le azioni disponibili")
    (when (or gdev-lavorazioni--aperti progetto)
      (insert (if (<= (funcall misura (propertize "Catalogo azioni  Cerca…" 'face 'gdev-ui-action))
                      larghezza)
                  "  " "\n"))
      (gdev-lavorazioni--pulsante "Cerca…" #'gdev-lavorazioni-cerca "Cerca nelle lavorazioni elencate"))
    (insert "\n\n")
    (pcase-dolist (`(,titolo ,file-sezione ,progetto-p)
                  (list (list "Aperte" gdev-lavorazioni--aperti nil)
                        (list "Nel progetto" voci t)))
      (when file-sezione
        (insert (propertize titolo 'face 'gdev-ui-view-heading
                            'gdev-lavorazioni-voce (and progetto-p 'progetto)) "\n")
        (when progetto-p (gdev-lavorazioni--navigazione))
        (dolist (file file-sezione)
          (gdev-lavorazioni--riga file (> (gethash (gdev-lavorazioni--nome file) conteggi) 1)
                                  larghezza misura))
        (insert "\n")))
    (when-let* ((stato (pcase gdev-lavorazioni--stato
                        ('lettura "Ricerca in corso…")
                        ('senza-cartella "Apri una cartella per cercare i piani.")
                        ('errore "Ricerca non riuscita. Premi g per riprovare.")
                        ('limite "Prime 500 lavorazioni.")
                        ('ok (unless (or progetto gdev-lavorazioni--aperti)
                               "Nessuna lavorazione nel progetto.")))))
      (insert (gdev-ui-fit-text (propertize stato 'face 'gdev-ui-secondary 'help-echo stato)
                                larghezza misura) "\n"))
    (let ((punto (or (gdev-lavorazioni--posizione voce)
                     (gdev-lavorazioni--posizione gdev-lavorazioni--corrente)
                     (gdev-lavorazioni--posizione 'gdev-lavorazioni-nuova)
                     (point-min))))
      (goto-char punto)
      (when (window-live-p window)
        (set-window-point window punto)
        (when-let* ((inizio (gdev-lavorazioni--posizione prima)))
          (set-window-start window inizio t))))))

(defun gdev-lavorazioni--resize (window)
  "Adatta il testo quando cambia la larghezza di WINDOW."
  (unless (equal gdev-lavorazioni--larghezza
                 (window-body-width window (display-graphic-p (window-frame window))))
    (gdev-lavorazioni--render window)))

(defun gdev-lavorazioni-sync (buffer &optional frame aggiorna)
  "Allinea BUFFER allo spazio di FRAME e rileggi le radici con AGGIORNA."
  (let* ((frame (or frame (selected-frame)))
         (editor (gdev-layout-editor frame))
         (finestra (get-buffer-window buffer frame))
         (piani (gdev-lavorazioni--documenti frame))
         (radici (seq-remove #'file-remote-p (gdev-workspace-roots frame)))
         (piano (and editor (gdev-lavorazioni--file (window-buffer editor)))))
    (with-current-buffer buffer
      (when editor
        (setq default-directory
              (or (gdev-workspace-directory nil frame)
                  (buffer-local-value 'default-directory (window-buffer editor)))))
      (let ((radici-cambiate (not (equal radici gdev-lavorazioni--radici)))
            (corrente (or piano gdev-lavorazioni--corrente)))
        (when radici-cambiate
          (setq gdev-lavorazioni--progetto nil gdev-lavorazioni--pagina 0))
        (when (or aggiorna radici-cambiate (not gdev-lavorazioni--stato))
          (setq gdev-lavorazioni--radici radici
                gdev-lavorazioni--stato nil)
          (gdev-lavorazioni--avvia-indice frame))
        (when (or aggiorna (not gdev-lavorazioni--larghezza) radici-cambiate
                  (not (equal piani gdev-lavorazioni--aperti))
                  (not (equal corrente gdev-lavorazioni--corrente)))
          (setq gdev-lavorazioni--aperti piani gdev-lavorazioni--corrente corrente)
          (gdev-lavorazioni--render finestra))))))

(defun gdev-lavorazioni-aggiorna ()
  "Aggiorna i piani aperti e ripeti la ricerca nel progetto."
  (interactive)
  (gdev-lavorazioni-sync (current-buffer) nil t))

(defun gdev-lavorazioni--cambia-pagina (passo)
  "Sposta l'elenco di PASSO pagine."
  (let ((pagina (+ passo gdev-lavorazioni--pagina)))
    (unless (<= 0 pagina (1- gdev-lavorazioni--pagine))
      (user-error "Non ci sono altre pagine in questa direzione"))
    (gdev-lavorazioni--render (get-buffer-window) pagina)
    (when-let* ((sezione (gdev-lavorazioni--posizione 'progetto)))
      (goto-char sezione))))

(defun gdev-lavorazioni-avanti ()
  "Mostra la pagina successiva."
  (interactive)
  (gdev-lavorazioni--cambia-pagina 1))

(defun gdev-lavorazioni-indietro ()
  "Mostra la pagina precedente."
  (interactive)
  (gdev-lavorazioni--cambia-pagina -1))

(defun gdev-lavorazioni--leggi-file (prompt &optional esistente)
  "Chiedi un file con PROMPT, già presente se ESISTENTE è non nil."
  (let* ((frame (selected-frame))
         (origine (gdev-workspace-state-ensure-id frame))
         (file (read-file-name prompt nil nil esistente nil
                               (when esistente
                                 (lambda (name)
                                   (or (file-directory-p name) (string-suffix-p ".lavorazione" name)))))))
    (unless (and (eq frame (selected-frame)) (eq origine (gdev-workspace-state-id frame)))
      (user-error "Lo spazio è cambiato. Scegli di nuovo il file"))
    (expand-file-name file)))

(defun gdev-lavorazioni-nuova ()
  "Crea un piano e apri la sua composizione."
  (interactive)
  (gdev-lavorazione-nuova (gdev-lavorazioni--leggi-file "Nuova lavorazione: ")))

(defun gdev-lavorazioni-scegli-file ()
  "Scegli un file di lavorazione e apri la sua composizione."
  (interactive)
  (gdev-lavorazioni-apri-file (gdev-lavorazioni--leggi-file "Apri lavorazione: " t)))

(defun gdev-lavorazioni-apri-file (&optional file)
  "Apri FILE, o la lavorazione indicata, e mostra i suoi passi."
  (interactive)
  (let ((file (or file (gdev-lavorazioni--voce)
                  (gdev-lavorazioni--leggi-file "Apri lavorazione: " t))))
    (unless (and (string-suffix-p ".lavorazione" file)
                 (or (get-file-buffer file) (file-regular-p file)))
      (user-error "Scegli un file .lavorazione"))
    (require 'gdev-lavorazione)
    (gdev-lavorazione-composizione (gdev-lavorazione--apri-sorgente file))))

(defun gdev-lavorazioni-cerca ()
  "Cerca un piano tra quelli aperti e rilevati."
  (interactive)
  (let* ((vista (current-buffer))
         (frame (selected-frame))
         (origine (gdev-workspace-state-ensure-id frame))
         (voci (delete-dups (append gdev-lavorazioni--aperti gdev-lavorazioni--progetto nil)))
         (scelte (mapcar (lambda (file) (cons (abbreviate-file-name file) file)) voci)))
    (unless scelte (user-error "Nessuna lavorazione da cercare"))
    (let ((file (cdr (assoc (completing-read "Cerca lavorazione: " scelte nil t) scelte))))
      (unless (and (eq frame (selected-frame)) (gdev-lavorazioni--appartiene-p vista origine)
                   (eq origine (gdev-workspace-state-id frame))
                   (with-current-buffer vista (or (member file gdev-lavorazioni--aperti)
                                                  (member file gdev-lavorazioni--progetto))))
        (user-error "L'elenco è cambiato. Cerca di nuovo"))
      (gdev-lavorazioni-apri-file file))))

(defvar-keymap gdev-lavorazioni-mode-map
  :parent special-mode-map
  "RET" #'gdev-lavorazioni-apri-file
  "a" #'gdev-lavorazioni-scegli-file
  "c" #'gdev-lavorazione-catalogo
  "n" #'gdev-lavorazioni-nuova
  "]" #'gdev-lavorazioni-avanti
  "[" #'gdev-lavorazioni-indietro
  "/" #'gdev-lavorazioni-cerca
  "g" #'gdev-lavorazioni-aggiorna
  ;; Un'attività riporta all'editor e lascia aperta la colonna, come `gdev-quit-view'.
  "q" #'gdev-quit-view)

(define-derived-mode gdev-lavorazioni-mode special-mode "Lavorazioni"
  "Naviga i piani dello spazio di lavoro."
  (gdev-ui-view-setup 'sidebar)
  (setq-local gdev-context-items
              '(["Apri lavorazione" gdev-lavorazioni-apri-file (gdev-lavorazioni--voce)]
                ["Apri file di lavorazione…" gdev-lavorazioni-scegli-file t (:target view)]
                ["Nuova lavorazione…" gdev-lavorazioni-nuova t (:target view)]
                ["Cerca lavorazione…" gdev-lavorazioni-cerca
                 (or gdev-lavorazioni--aperti gdev-lavorazioni--progetto) (:target view)]
                ["Catalogo delle azioni" gdev-lavorazione-catalogo t (:target view)]
                ["Aggiorna l’elenco" gdev-lavorazioni-aggiorna t (:target view)]))
  (add-hook 'window-size-change-functions #'gdev-lavorazioni--resize nil t)
  (add-hook 'kill-buffer-hook #'gdev-lavorazioni--annulla-indice nil t)
  (hl-line-mode 1))

(defun gdev-lavorazioni-buffer ()
  "Restituisci la vista Lavorazioni dello spazio corrente."
  (let ((buffer (gdev-activity-buffer 'lavorazioni "*Lavorazioni*" #'gdev-lavorazioni-mode)))
    (gdev-lavorazioni-sync buffer)
    buffer))

(defun gdev-lavorazioni--finestra (frame)
  "Restituisci la finestra di Lavorazioni in FRAME, se visibile."
  (when-let* ((window (gdev-layout-left-window frame)))
    (when (eq (buffer-local-value 'major-mode (window-buffer window)) 'gdev-lavorazioni-mode)
      window)))

(defun gdev-lavorazioni--sync-frame (frame)
  "Aggiorna l'attività solo quando è mostrata da FRAME."
  (when-let* ((window (gdev-lavorazioni--finestra frame)))
    (gdev-lavorazioni-sync (window-buffer window) frame)))

(add-hook 'window-buffer-change-functions #'gdev-lavorazioni--sync-frame)

(defun gdev-lavorazioni--tema ()
  "Rimisura le righe visibili dopo un cambio di aspetto."
  (dolist (frame (frame-list))
    (when-let* ((window (gdev-lavorazioni--finestra frame)))
      (with-current-buffer (window-buffer window)
        (gdev-lavorazioni--render window)))))

(add-hook 'gdev-ui-after-theme-hook #'gdev-lavorazioni--tema)

(defun gdev-lavorazioni-pannello ()
  "Apri la vista Lavorazioni dello spazio di lavoro."
  (interactive)
  (let* ((buffer (gdev-lavorazioni-buffer))
         (window (gdev-activity-display buffer 'lavorazioni)))
    (if (window-live-p window)
        (with-current-buffer buffer (gdev-lavorazioni--resize window))
      (user-error "Allarga la finestra per mostrare Lavorazioni"))))

(provide 'gdev-lavorazioni)
;;; gdev-lavorazioni.el ends here
