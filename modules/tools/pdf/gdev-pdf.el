;;; gdev-pdf.el --- Lettura PDF con il fork di DocView e PDFKit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Il fork di DocView conserva pagina e zoom per finestra. PDFKit
;; rasterizza le singole pagine e legge il testo in processi asincroni.
;; La cache delle pagine appartiene al buffer e si elimina alla chiusura.

;;; Code:

(declare-function clear-image-cache "image.c" (&optional filter frame))

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-doc-view)

(declare-function gdev-org-pdf-note "../../lang/org/config" ())
(defvar gdev-context-items)
(defvar revert-buffer-preserve-modes)

(defconst gdev-pdf--raster-edge 1600
  "Lato massimo, in pixel, che il lettore chiede a PDFKit.")
(defconst gdev-pdf--cache-limit 4
  "Pagine da conservare, oltre alle eventuali pagine visibili.")

(defvar gdev-pdf--build-waiters nil
  "Richieste in attesa della compilazione del lettore nativo.")
(defvar gdev-pdf--session-directory nil
  "Radice temporanea dei lettori aperti in questo processo Emacs.")
(defvar-local gdev-pdf--directory nil)
(defvar-local gdev-pdf--source nil)
(defvar-local gdev-pdf--pages nil)
(defvar-local gdev-pdf--render-job nil)
(defvar-local gdev-pdf--text-job nil)
(defvar-local gdev-pdf--password nil)
(defvar-local gdev-pdf--failure nil)
(defvar-local gdev-pdf--locked nil)
(defvar-local gdev-pdf--matches nil)

(defun gdev-pdf--finish-build (program problem)
  "Consegna PROGRAM o PROBLEM alle richieste in attesa."
  (let ((waiters (nreverse gdev-pdf--build-waiters)))
    (setq gdev-pdf--build-waiters nil)
    (dolist (waiter waiters)
      (funcall waiter program problem))))

(defun gdev-pdf--build (source program)
  "Compila SOURCE in background e pubblica PROGRAM con una sostituzione atomica."
  (let* ((directory (file-name-directory program))
         (default-directory temporary-file-directory)
         (staging nil)
         (output nil)
         (process nil))
    (unwind-protect
        (progn
          (make-directory directory t)
          (setq staging (make-temp-file (expand-file-name "pdf-build-" directory) t)
                output (generate-new-buffer " *gdev-pdf-build*"))
          (let ((executable (expand-file-name "pdf" staging)))
            (setq process
                  (make-process
                   :name "gdev-pdf-build" :buffer output :noquery t
                   :connection-type 'pipe :coding 'utf-8-unix
                   :command (list "/usr/bin/clang" "-O2" "-fobjc-arc" "-framework" "PDFKit"
                                  "-framework" "AppKit" "-framework" "Foundation"
                                  source "-o" executable)
                   :sentinel
                   (lambda (child _event)
                     (when (memq (process-status child) '(exit signal failed))
                       (let (problem)
                         (unwind-protect
                             (condition-case err
                                 (if (and (eq (process-status child) 'exit)
                                          (zerop (process-exit-status child)))
                                     (rename-file executable program t)
                                   (setq problem
                                         "Compilazione di PDFKit fallita. Verifica gli strumenti di Xcode."))
                               (file-error (setq problem (error-message-string err))))
                           (kill-buffer output)
                           (delete-directory staging t))
                         (gdev-pdf--finish-build program problem))))))))
      (unless process
        (when output (kill-buffer output))
        (when staging (delete-directory staging t))))))

(defun gdev-pdf--ensure-helper (callback)
  "Chiama CALLBACK con il lettore nativo oppure un errore di compilazione."
  (let* ((source (gdev-config-file "bin/gdev-pdf-macos.m"))
         (program (gdev-state-file (concat "native-modules/pdf-" system-configuration))))
    (cond
     ((and (file-executable-p program) (not (file-newer-than-file-p source program)))
      (funcall callback program nil))
     (gdev-pdf--build-waiters (push callback gdev-pdf--build-waiters))
     (t
      (push callback gdev-pdf--build-waiters)
      (condition-case err
          (gdev-pdf--build source program)
        (error (gdev-pdf--finish-build nil (error-message-string err))))))))

(defun gdev-pdf--cancel (slot)
  "Annulla la richiesta nello SLOT del lettore."
  (let ((process (car (symbol-value slot))))
    (set slot nil)
    (when (process-live-p process)
      (delete-process process))))

(defun gdev-pdf--failure-text (errors)
  "Restituisci il messaggio diagnostico dal buffer ERRORS."
  (with-current-buffer errors
    (goto-char (point-max))
    (skip-chars-backward "\n\r")
    (if (bobp)
        "Lettura del PDF interrotta."
      (string-trim (buffer-substring (line-beginning-position) (point))))))

(defun gdev-pdf--complete (buffer slot job status output errors success failure)
  "Consegna il risultato di JOB solo alla richiesta ancora attiva in SLOT."
  (unwind-protect
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq (symbol-value slot) job)
            (set slot nil)
            (condition-case err
                (if (zerop status)
                    (funcall success output)
                  (funcall failure status (gdev-pdf--failure-text errors)))
              (error (funcall failure 1 (error-message-string err)))))))
    (kill-buffer output)
    (kill-buffer errors)))

(defun gdev-pdf--check-revision ()
  "Verifica che la sorgente locale appartenga ancora alla revisione aperta."
  (unless buffer-file-name (user-error "Apri un file PDF"))
  (unless (or (file-remote-p buffer-file-name)
              (verify-visited-file-modtime (current-buffer)))
    (user-error "Il PDF è cambiato. Premi r per ricaricarlo")))

(defun gdev-pdf--source-file ()
  "Restituisci il percorso locale della revisione visitata."
  (gdev-pdf--check-revision)
  (or gdev-pdf--source
      (setq gdev-pdf--source
            (if (file-remote-p buffer-file-name)
                (let ((copy (expand-file-name "documento.pdf" gdev-pdf--directory)))
                  (copy-file buffer-file-name copy t)
                  copy)
              buffer-file-name))))

(defun gdev-pdf--run (slot operation arguments success failure)
  "Esegui OPERATION con ARGUMENTS, sostituendo la richiesta in SLOT.
SUCCESS riceve il buffer di risposta. FAILURE riceve il codice e il messaggio."
  (gdev-pdf--cancel slot)
  (let ((buffer (current-buffer))
        (job (list nil)))
    (set slot job)
    (gdev-pdf--ensure-helper
     (lambda (program problem)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (eq (symbol-value slot) job)
             (let (output errors process)
               (condition-case err
                   (progn
                     (when problem (error "%s" problem))
                     (let* ((source (gdev-pdf--source-file))
                            (default-directory gdev-pdf--directory))
                       (setq output (generate-new-buffer " *gdev-pdf-output*")
                             errors (generate-new-buffer " *gdev-pdf-errors*")
                             process
                             (make-process
                              :name (concat "gdev-pdf-" operation) :buffer output :stderr errors
                              :command (append (list program operation source) arguments)
                              :connection-type 'pipe :coding 'utf-8-unix :noquery t
                              :sentinel
                              (lambda (child _event)
                                (when (memq (process-status child) '(exit signal failed))
                                  (gdev-pdf--complete buffer slot job (process-exit-status child)
                                                      output errors success failure)))))
                       (setcar job process)
                       (when-let* ((stderr (get-buffer-process errors)))
                         (set-process-query-on-exit-flag stderr nil)
                         (set-process-sentinel stderr #'ignore))
                       (when (process-live-p process)
                         (when gdev-pdf--password
                           (process-send-string process gdev-pdf--password))
                         (process-send-eof process))))
                 (error
                  (when (eq (symbol-value slot) job)
                    (set slot nil)
                    (if process
                        (delete-process process)
                      (when output (kill-buffer output))
                      (when errors (kill-buffer errors)))
                    (funcall failure 1 (error-message-string err)))))))))))))

(defun gdev-pdf--windows ()
  "Elenca le finestre grafiche del documento, con quella attiva per prima."
  (let ((windows (get-buffer-window-list (current-buffer) nil 'visible))
        (selected (selected-window)))
    (when (memq selected windows)
      (setq windows (cons selected (delq selected windows))))
    (seq-filter (lambda (window) (display-graphic-p (window-frame window))) windows)))

(defun gdev-pdf--show (window)
  "Mostra la pagina corrente o lo stato del lettore in WINDOW."
  (let* ((page (gdev-doc-view-current-page window))
         (file (cdr (assq page gdev-pdf--pages))))
    (gdev-doc-view-insert-image
     window file
     (unless file
       (propertize (concat "  " (or gdev-pdf--failure "Caricamento della pagina…"))
                   'face (if gdev-pdf--failure 'gdev-ui-status-warning 'gdev-ui-secondary))))))

(defun gdev-pdf--trim-cache ()
  "Mantieni le pagine visibili e al massimo quattro pagine di riserva."
  (let ((visible (mapcar #'gdev-doc-view-current-page (gdev-pdf--windows)))
        (spare 0))
    (setq gdev-pdf--pages
          (seq-filter
           (lambda (entry)
             (or (memq (car entry) visible)
                 (<= (cl-incf spare) gdev-pdf--cache-limit)
                 (progn (when (fboundp 'clear-image-cache) (clear-image-cache (cdr entry))) (delete-file (cdr entry)) nil)))
           gdev-pdf--pages))))

(defun gdev-pdf--forget-password ()
  "Elimina la password della sessione di lettura."
  (when gdev-pdf--password
    (clear-string gdev-pdf--password)
    (setq gdev-pdf--password nil)))

(defun gdev-pdf--render-error (status message)
  "Mostra MESSAGE e indica se STATUS richiede una password."
  (setq gdev-pdf--locked (= status 4)
        gdev-pdf--failure (if gdev-pdf--locked "PDF protetto · premi u per sbloccarlo." message))
  (when gdev-pdf--locked
    (gdev-pdf--forget-password))
  (mapc #'gdev-pdf--show (gdev-pdf--windows))
  (force-mode-line-update))

(defun gdev-pdf--rendered (file output)
  "Attiva FILE quando OUTPUT conferma pagina e dimensione del documento."
  (let* ((metadata (with-current-buffer output
                     (goto-char (point-min))
                     (json-parse-buffer :object-type 'alist)))
         (pages (alist-get 'pages metadata))
         (page (alist-get 'page metadata)))
    (unless (and (integerp page) (integerp pages) (<= 1 page pages) (file-readable-p file))
      (error "Risposta non valida del lettore PDF"))
    (gdev-pdf--check-revision)
    (setq gdev-doc-view-page-count pages
          gdev-pdf--locked nil)
    (push (cons page file) gdev-pdf--pages)
    (mapc #'gdev-pdf--show (gdev-pdf--windows))
    (gdev-pdf--trim-cache)
    (force-mode-line-update)
    (gdev-pdf--pump)))

(defun gdev-pdf--pump ()
  "Carica una sola pagina mancante alla volta, dando priorità alla vista attiva."
  (unless (or gdev-pdf--render-job gdev-pdf--failure)
    (let* ((windows (gdev-pdf--windows))
           (page (cl-find-if-not (lambda (number) (assq number gdev-pdf--pages))
                                 (mapcar #'gdev-doc-view-current-page (or windows '(t))))))
      (when page
        (unless gdev-pdf--directory
          (unless gdev-pdf--session-directory
            (setq gdev-pdf--session-directory (make-temp-file "gdev-pdf-" t))
            (add-hook 'kill-emacs-hook #'gdev-pdf--release-session))
          (setq gdev-pdf--directory
                (make-temp-file (expand-file-name "doc-" gdev-pdf--session-directory) t)))
        (let ((file (expand-file-name (format "pagina-%d.png" page) gdev-pdf--directory)))
          (gdev-pdf--run 'gdev-pdf--render-job "render"
                         (list (number-to-string page) (number-to-string gdev-pdf--raster-edge) file)
                         (lambda (output) (gdev-pdf--rendered file output))
                         #'gdev-pdf--render-error))))))

(defun gdev-pdf--update (window)
  "Aggiorna WINDOW dopo un cambio di pagina, zoom o dimensione."
  (when-let* ((page (assq (gdev-doc-view-current-page window) gdev-pdf--pages)))
    (unless (eq page (car gdev-pdf--pages))
      (setq gdev-pdf--pages (cons page (delq page gdev-pdf--pages)))))
  (gdev-pdf--show window)
  (gdev-pdf--pump)
  (force-mode-line-update))

(defun gdev-pdf--release ()
  "Annulla i processi e rimuovi la cache locale del documento."
  (gdev-pdf--cancel 'gdev-pdf--render-job)
  (gdev-pdf--cancel 'gdev-pdf--text-job)
  (gdev-pdf--forget-password)
  (dolist (entry gdev-pdf--pages)
    (when (fboundp 'clear-image-cache) (clear-image-cache (cdr entry))))
  (when gdev-pdf--directory
    (delete-directory gdev-pdf--directory t))
  (setq gdev-pdf--directory nil
        gdev-pdf--source nil
        gdev-pdf--pages nil
        gdev-pdf--matches nil))

(defun gdev-pdf--release-session ()
  "Rilascia le cache dei PDF prima di uscire da Emacs."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when gdev-pdf--directory (gdev-pdf--release))))
  (when gdev-pdf--session-directory
    (delete-directory gdev-pdf--session-directory t)
    (setq gdev-pdf--session-directory nil)))

(defun gdev-pdf--reload ()
  "Rileggi il documento aggiornato mantenendo il punto di lettura."
  (gdev-pdf--release)
  (setq gdev-doc-view-page-count nil
        gdev-pdf--locked nil
        gdev-pdf--failure nil)
  (mapc #'gdev-pdf--show (gdev-pdf--windows))
  (gdev-pdf--pump))

(defun gdev-pdf--revert (function &rest arguments)
  "Chiama FUNCTION con ARGUMENTS conservando la modalità e lo zoom."
  (let ((revert-buffer-preserve-modes t))
    (apply function arguments)))

(defun gdev-pdf-current-page ()
  "Restituisci la pagina corrente dopo che il lettore l'ha caricata."
  (let ((page (gdev-doc-view-current-page)))
    (and (assq page gdev-pdf--pages) page)))

(defalias 'gdev-pdf-goto-page #'gdev-doc-view-goto-page)

(defun gdev-pdf-unlock ()
  "Sblocca il PDF con una password valida per questa apertura."
  (interactive)
  (unless gdev-pdf--locked (user-error "Il PDF non è bloccato"))
  (let ((password (read-passwd "Password PDF: ")))
    (gdev-pdf--forget-password)
    (setq gdev-pdf--password password
          gdev-pdf--failure nil
          gdev-pdf--locked nil)
    (mapc #'gdev-pdf--show (gdev-pdf--windows))
    (gdev-pdf--pump)))

(defun gdev-pdf-open-externally ()
  "Apri questo PDF con l'applicazione esterna."
  (interactive)
  (browse-url-of-file (or buffer-file-name (user-error "Nessun PDF aperto"))))

(defun gdev-pdf--text-error (_status message)
  "Mostra MESSAGE senza modificare la pagina corrente."
  (message "%s" message))

(defun gdev-pdf--read-text (page callback)
  "Estrai il testo di PAGE, o di tutto il PDF se vale zero, e chiama CALLBACK."
  (unless gdev-doc-view-page-count
    (user-error (or gdev-pdf--failure "Attendi l'apertura del PDF")))
  (gdev-pdf--run 'gdev-pdf--text-job "text" (list (number-to-string page))
                 callback #'gdev-pdf--text-error))

(define-derived-mode gdev-pdf-text-mode special-mode "Testo del PDF"
  "Leggi una copia testuale del documento."
  (gdev-ui-view-setup 'document)
  (visual-line-mode 1))

(defun gdev-pdf-open-text (all)
  "Mostra il testo della pagina. Con prefisso ALL mostra tutto il documento."
  (interactive "P")
  (let ((page (gdev-doc-view-current-page))
        (origin (current-buffer))
        (name (file-name-nondirectory buffer-file-name)))
    (gdev-pdf--read-text
     (if all 0 page)
     (lambda (output)
       (let* ((text (with-current-buffer output (buffer-string)))
              (title (if all name (format "%s · pagina %d" name page)))
              (buffer (get-buffer-create (format "*Testo · %s*" (buffer-name origin)))))
         (with-current-buffer buffer
           (gdev-pdf-text-mode)
           (let ((inhibit-read-only t))
             (erase-buffer)
             (setq-local header-line-format (concat "  " (replace-regexp-in-string "%" "%%" title t t)))
             (insert (if (string-blank-p text)
                         (propertize "Nessun testo presente nella pagina." 'face 'gdev-ui-secondary)
                       text))
             (goto-char (point-min))
             (when (and all (> page 1))
               (search-forward "\f" nil 'move (1- page)))))
         (if (eq (window-buffer) origin)
             (pop-to-buffer buffer)
           (display-buffer buffer)))))))

(defun gdev-pdf--visit-match (backward &optional include-current window)
  "Vai al prossimo esito, a ritroso se BACKWARD.
Con INCLUDE-CURRENT considera anche la pagina aperta in WINDOW."
  (unless gdev-pdf--matches
    (user-error "Nessuna pagina corrispondente"))
  (let* ((current (gdev-doc-view-current-page window))
         (pages (if backward (reverse gdev-pdf--matches) gdev-pdf--matches))
         (match (cl-find-if (lambda (page)
                             (or (and include-current (= page current))
                                 (if backward (< page current) (> page current))))
                           pages)))
    (gdev-pdf-goto-page (or match (car pages)) window)))

(defun gdev-pdf-search (regexp &optional backward)
  "Cerca REGEXP nel PDF. Con BACKWARD parti verso le pagine precedenti."
  (interactive (list (read-regexp "Cerca nel PDF: ")))
  (when (string-empty-p regexp) (user-error "Inserisci il testo da cercare"))
  (string-match-p regexp "")
  (let ((window (selected-window)))
    (gdev-pdf--read-text
     0 (lambda (output)
         (setq gdev-pdf--matches (gdev-doc-view-search-pages regexp output))
         (when (and gdev-pdf--matches (window-live-p window)
                    (eq (window-buffer window) (current-buffer)))
           (gdev-pdf--visit-match backward t window))
         (message "%d pagine corrispondenti" (length gdev-pdf--matches))))))

(defun gdev-pdf-search-forward (new)
  "Vai al prossimo esito, oppure cerca con prefisso NEW."
  (interactive "P")
  (if (and gdev-pdf--matches (not new))
      (gdev-pdf--visit-match nil)
    (call-interactively #'gdev-pdf-search)))

(defun gdev-pdf-search-backward (new)
  "Vai all'esito precedente, oppure cerca con prefisso NEW."
  (interactive "P")
  (if (and gdev-pdf--matches (not new))
      (gdev-pdf--visit-match t)
    (gdev-pdf-search (read-regexp "Cerca indietro nel PDF: ") t)))

(defun gdev-pdf--header-control (label help command)
  "Crea il controllo LABEL con tooltip HELP che richiama COMMAND."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
                (lambda (event)
                  (interactive "e")
                  (with-selected-window (posn-window (event-start event))
                    (call-interactively command))))
    (propertize label 'face 'gdev-ui-action 'mouse-face 'gdev-ui-side-hover
                'help-echo help 'local-map map)))

(defconst gdev-pdf--previous-control
  (gdev-pdf--header-control "  ‹  " "Pagina precedente · p" #'gdev-doc-view-previous-page))
(defconst gdev-pdf--next-control
  (gdev-pdf--header-control "  ›  " "Pagina successiva · n" #'gdev-doc-view-next-page))

(defun gdev-pdf--header ()
  "Mostra navigazione e numero di pagina per la finestra corrente."
  (when gdev-doc-view-page-count
    (let* ((page (gdev-doc-view-current-page))
           (count gdev-doc-view-page-count))
      (list (if (> page 1) gdev-pdf--previous-control "     ")
            (propertize (format "Pagina %d di %d" page count) 'face 'gdev-ui-secondary)
            (when (< page count) gdev-pdf--next-control)))))

(defconst gdev-pdf--actions
  '(["Pagina precedente" gdev-doc-view-previous-page (> (gdev-doc-view-current-page) 1)]
    ["Pagina successiva" gdev-doc-view-next-page
     (and gdev-doc-view-page-count (< (gdev-doc-view-current-page) gdev-doc-view-page-count))]
    ["Vai a pagina…" gdev-doc-view-goto-page gdev-doc-view-page-count]
    ["Cerca nel PDF…" gdev-pdf-search gdev-doc-view-page-count]
    ["Mostra il testo" gdev-pdf-open-text gdev-doc-view-page-count]
    ["Adatta la pagina" gdev-doc-view-fit-page gdev-doc-view-page-count]
    ["Adatta la larghezza" gdev-doc-view-fit-width gdev-doc-view-page-count]
    ["Ingrandisci" gdev-doc-view-enlarge gdev-doc-view-page-count]
    ["Riduci" gdev-doc-view-shrink gdev-doc-view-page-count]
    ["Annota la pagina in Org" gdev-org-pdf-note
     (and (fboundp 'gdev-org-pdf-note) (gdev-pdf-current-page))]
    ["Sblocca PDF…" gdev-pdf-unlock gdev-pdf--locked]
    ["Ricarica il PDF" revert-buffer]
    ["Apri all’esterno" gdev-pdf-open-externally])
  "Azioni del lettore disponibili nel riquadro e nel menu contestuale.")

(defvar-keymap gdev-pdf-mode-map
  "C-s" #'gdev-pdf-search-forward
  "C-r" #'gdev-pdf-search-backward
  "C-c C-t" #'gdev-pdf-open-text
  "u" #'gdev-pdf-unlock
  "r" #'revert-buffer)

(define-derived-mode gdev-pdf-mode gdev-doc-view-mode "Lettore PDF"
  "Leggi il PDF corrente con PDFKit."
  (gdev-ui-view-setup 'preview)
  (setq-local gdev-context-items gdev-pdf--actions
              gdev-doc-view-update-function #'gdev-pdf--update
              header-line-format '(:eval (gdev-pdf--header))
              view-read-only nil)
  (add-function :around (local 'revert-buffer-function) #'gdev-pdf--revert)
  (add-hook 'after-revert-hook #'gdev-pdf--reload nil t)
  (add-hook 'kill-buffer-hook #'gdev-pdf--release nil t)
  (add-hook 'change-major-mode-hook #'gdev-pdf--release nil t)
  (when buffer-file-name (gdev-pdf--pump)))

(provide 'gdev-pdf)
;;; gdev-pdf.el ends here
