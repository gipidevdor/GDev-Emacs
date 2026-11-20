;;; gdev-mise.el --- Ambiente asincrono dei progetti mise -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Condivide la richiesta di ambiente fra i documenti della stessa cartella
;; di configurazione. Una risposta vale per la revisione dei file letti.
;; La configurazione del modulo di compilazione installa gli autoload.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'gdev-lib)
(require 'gdev-project-types)

(defconst gdev-mise-config-files
  '("mise.toml" ".mise.toml" "mise.local.toml" ".mise.local.toml"
    ".config/mise.toml" ".config/mise/config.toml" "mise/config.toml" ".tool-versions")
  "File che rendono una cartella un progetto mise.")

(cl-defstruct gdev-mise--request
  stamp (status 'pending) process environment buffers
  ;; Ultima riga di errore di mise, per spiegare perché l'ambiente non è pronto.
  detail)

(defvar gdev-mise--requests (make-hash-table :test #'equal)
  "Cartella di configurazione -> richiesta corrente di mise.")

(defvar-local gdev-mise--buffer-request nil
  "Richiesta di mise da cui dipende l'ambiente di questo documento.")

(defvar-local gdev-mise--original-values nil
  "Valori precedenti delle variabili assegnate da mise in questo documento.")
(defvar-local gdev-mise--original-path nil)

(defun gdev-mise--config-directory (directory)
  "Restituisce la cartella più vicina sopra DIRECTORY con una configurazione mise.
La cartella personale (home) è esclusa: la configurazione globale vale
già per la shell, e quindi per l'ambiente salvato da `gdev env'."
  (let ((home (file-name-as-directory (expand-file-name "~"))))
    (when-let* ((root (locate-dominating-file
     directory
     (lambda (candidate)
       (and (not (equal (file-name-as-directory (expand-file-name candidate)) home))
            (cl-some (lambda (name) (file-exists-p (expand-file-name name candidate)))
                     gdev-mise-config-files))))))
      (file-name-as-directory (expand-file-name root)))))

(defun gdev-mise--stamp (directory)
  "Restituisce le date di modifica dei file di configurazione in DIRECTORY."
  (mapcar (lambda (name)
            (file-attribute-modification-time
             (file-attributes (expand-file-name name directory))))
          gdev-mise-config-files))

(defun gdev-mise--install-env (environment)
  "Applica ENVIRONMENT nel documento corrente."
  (setq-local process-environment (copy-sequence process-environment))
  (unless gdev-mise--original-path (setq gdev-mise--original-path (copy-sequence exec-path)))
  (dolist (entry environment)
    (let ((name (symbol-name (car entry))))
      (unless (assoc name gdev-mise--original-values)
        (push (cons name (getenv name)) gdev-mise--original-values))))
  (dolist (entry gdev-mise--original-values) (setenv (car entry) (cdr entry)))
  (dolist (entry environment) (setenv (symbol-name (car entry)) (cdr entry)))
  (setq-local exec-path (if-let* ((path (alist-get 'PATH environment)))
                           (append (parse-colon-path path) (list exec-directory))
                         (copy-sequence gdev-mise--original-path))))

(defun gdev-mise--resume-document (directory request)
  "Aggiorna il documento corrente se attende ancora REQUEST di DIRECTORY."
  (when (eq request gdev-mise--buffer-request)
    (setq gdev-mise--buffer-request nil)
    (setq-local gdev-project-environment-status nil)
    (when-let* ((buffer-file-name)
                ((not (file-remote-p buffer-file-name)))
                ((not (bound-and-true-p envrc-mode)))
                (root (gdev-project-operation-context-root))
                ((gdev-project-trusted-p root)))
      (if (equal directory (gdev-mise--config-directory default-directory))
          (progn
            (setq-local gdev-project-environment-status (gdev-mise--request-status request)
                        gdev-project-environment-detail (gdev-mise--request-detail request))
            (when (eq gdev-project-environment-status 'ready)
              (gdev-mise--install-env (gdev-mise--request-environment request))))
        ;; Una configurazione più vicina può essere comparsa nel frattempo.
        (gdev-mise-apply root))
      (when (gdev-project-environment-ready-p)
        (gdev-prepend-project-tools root)
        (with-demoted-errors "Ambiente del progetto: %S"
          (run-hooks 'gdev-project-environment-ready-hook))))))

(defun gdev-mise--publish (directory request status &optional environment)
  "Concludi REQUEST per DIRECTORY con STATUS e aggiorna i documenti in attesa."
  (let ((buffers (gdev-mise--request-buffers request)))
    (setf (gdev-mise--request-status request) status
          (gdev-mise--request-environment request) environment
          (gdev-mise--request-process request) nil
          (gdev-mise--request-buffers request) nil)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (gdev-mise--resume-document directory request))))))

(defun gdev-mise--result (buffer)
  "Leggi da BUFFER la risposta eseguita da mise."
  (with-current-buffer buffer
    (goto-char (point-min))
    ;; Un ambiente vuoto è un risultato valido.
    (condition-case nil
        (let ((environment (json-parse-buffer :object-type 'alist)))
          (skip-chars-forward " \t\r\n")
          (when (and (eobp)
                     (listp environment)
                     (cl-every (lambda (entry) (and (consp entry) (stringp (cdr entry)))) environment))
            (cons t environment)))
      ((json-parse-error json-end-of-file) nil))))

(defun gdev-mise--last-line (buffer)
  "Ultima riga non vuota di BUFFER, accorciata, o nil: la causa riportata da mise."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((line (car (last (split-string (buffer-string) "\n" t "[ \t\r]+")))))
        (truncate-string-to-width (string-trim line) 160 nil nil "…")))))

(defun gdev-mise--complete (directory request child output)
  "Consegna OUTPUT di CHILD se REQUEST è ancora corrente per DIRECTORY."
  (when (eq request (gethash directory gdev-mise--requests))
    (let* ((current (gdev-mise--stamp directory))
           (same-version (equal (gdev-mise--request-stamp request) current)))
      (if (and (not same-version) (seq-some #'identity current))
          (gdev-mise--start directory current)
        (if-let* ((same-version)
                  ((eq (process-status child) 'exit))
                  ((zerop (process-exit-status child)))
                  (result (gdev-mise--result output)))
            (gdev-mise--publish directory request 'ready (cdr result))
          (gdev-mise--publish directory request 'failed))))))

(defun gdev-mise--start (directory stamp)
  "Avvia o riusa la richiesta mise per DIRECTORY alla versione STAMP."
  (let ((previous (gethash directory gdev-mise--requests)))
    (if (and previous (equal stamp (gdev-mise--request-stamp previous))
             (not (eq (gdev-mise--request-status previous) 'failed)))
        previous
      (let* ((waiting (and previous (gdev-mise--request-buffers previous)))
             (request (make-gdev-mise--request :stamp stamp :buffers waiting))
             (child (and previous (gdev-mise--request-process previous)))
             (default-directory directory)
             (output (generate-new-buffer " *gdev-mise*"))
             (errors (generate-new-buffer " *gdev-mise-errors*"))
             process)
        (puthash directory request gdev-mise--requests)
        (dolist (buffer waiting)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (when (eq gdev-mise--buffer-request previous)
                (setq gdev-mise--buffer-request request)))))
        (when (process-live-p child) (delete-process child))
        (condition-case nil
            (progn
              (setq process
                    (make-process
                     :name "gdev-mise" :buffer output :stderr errors
                     :command '("mise" "env" "--json")
                     :connection-type 'pipe :coding 'utf-8-unix :noquery t
                     :sentinel
                     (lambda (child _event)
                       (when (memq (process-status child) '(exit signal failed))
                         (unwind-protect
                             (progn
                               (setf (gdev-mise--request-detail request)
                                     (gdev-mise--last-line errors))
                               (gdev-mise--complete directory request child output))
                           (kill-buffer output)
                           (kill-buffer errors))))))
              (setf (gdev-mise--request-process request) process)
              (when (process-live-p process) (ignore-errors (process-send-eof process))))
          (file-error
           (setf (gdev-mise--request-detail request) "mise non disponibile: aggiorna l'ambiente della shell o installa mise")
           (kill-buffer output)
           (kill-buffer errors)
           (gdev-mise--publish directory request 'failed)))
        request))))

(defun gdev-mise--prepare-folder (folder)
  "Prepara in background l'ambiente della cartella locale FOLDER."
  (when-let* (((not (file-remote-p folder)))
              (directory (gdev-mise--config-directory folder))
              ((gdev-project-trusted-p (gdev-project-operation-context-root directory))))
    (let ((process-environment (default-value 'process-environment))
          (exec-path (default-value 'exec-path)))
      (gdev-mise--start directory (gdev-mise--stamp directory)))))

(defun gdev-mise-environment (directory)
  "Richiedi l'ambiente di mise per DIRECTORY.
Restituisci i valori già disponibili e lascia avanzare mise in background."
  (let ((request (gdev-mise--start directory (gdev-mise--stamp directory))))
    (when (eq (gdev-mise--request-status request) 'ready)
      (gdev-mise--request-environment request))))

(defun gdev-mise-apply (_root)
  "Prepara l'ambiente mise del documento corrente."
  (when-let* (((not (bound-and-true-p envrc-mode)))
              (directory (gdev-mise--config-directory default-directory))
              ((gdev-project-trusted-p (gdev-project-operation-context-root directory))))
    (let* ((request (gdev-mise--start directory (gdev-mise--stamp directory)))
           (status (gdev-mise--request-status request)))
      (setq-local gdev-project-environment-status status
                  gdev-project-environment-detail (gdev-mise--request-detail request))
      (pcase status
        ('ready (gdev-mise--install-env (gdev-mise--request-environment request)))
        ('pending
         (setq-local gdev-mise--buffer-request request)
         (cl-pushnew (current-buffer) (gdev-mise--request-buffers request)))))))

(defun gdev-mise-refresh (root)
  "Invalida il risultato concluso di mise per ROOT.
Conserva le richieste ancora attive."
  (when-let* ((directory (gdev-mise--config-directory root))
              (request (gethash directory gdev-mise--requests))
              ((not (eq (gdev-mise--request-status request) 'pending))))
    (remhash directory gdev-mise--requests)))

(defun gdev-mise-reset-document ()
  "Scarta la risposta attesa e i valori del contesto precedente."
  (setq gdev-mise--buffer-request nil gdev-mise--original-values nil gdev-mise--original-path nil))

(add-hook 'gdev-project-environment-reset-hook #'gdev-mise-reset-document)

(provide 'gdev-mise)
;;; gdev-mise.el ends here
