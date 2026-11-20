;;; config.el --- :editor format: un solo comando di formattazione per ogni linguaggio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; C-c c f formatta l'area di testo, o la selezione, con lo
;; strumento del progetto: clang-format, perltidy, deno fmt...  I moduli dei
;; linguaggi registrano il proprio formattatore con `gdev-set-formatter';
;; altrimenti formatta il server di linguaggio.  La
;; formattazione sostituisce solo ciò che è cambiato: cursore, segni
;; e cronologia di annullamento restano intatti.
;; Il lavoro in secondo piano termina alla prima modifica del testo,
;; al cambio di modalità o quando una nuova richiesta lo supera.
;;
;; Opzione +onsave: formatta anche prima di salvare, ma solo nei
;; progetti che dichiarano il proprio stile (.clang-format, .perltidyrc,
;; deno.json...), così il codice di altri non viene mai riformattato.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-modules)

(declare-function eglot-server-capable "eglot")
(declare-function eglot-format "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function gdev-lavorazione-documento "gdev-lavorazione" (contesto))
(declare-function gdev-lavorazione-radice "gdev-lavorazione" (contesto))
(declare-function gdev-lavorazione-registra "gdev-lavorazione"
                  (nome descrizione schema funzione &rest proprieta))

(defvar gdev-format--background nil
  "Non nil per la formattazione richiesta da tastiera o menu.")

(defvar gdev-format--errore-processo nil
  "Non nil se un'uscita non riuscita deve fermare la lavorazione.")

(defvar-local gdev-format--process nil)

(defun gdev-format--cancel ()
  "Libera la richiesta corrente e termina il processo se è ancora attivo."
  (let ((process gdev-format--process))
    (setq gdev-format--process nil)
    (remove-hook 'after-change-functions #'gdev-format--changed t)
    (when (process-live-p process) (delete-process process))))

(defun gdev-format--changed (&rest _changes)
  "Interrompi il lavoro il cui testo di partenza è appena cambiato."
  (when (and gdev-format--process
             (/= (process-get gdev-format--process 'gdev-format--source-tick)
                 (buffer-chars-modified-tick)))
    (gdev-format--cancel)))

(defun gdev-format--release (output directory)
  "Rilascia il buffer OUTPUT e la cartella temporanea DIRECTORY."
  (unwind-protect
      (when (buffer-live-p output) (kill-buffer output))
    (when (file-directory-p directory) (delete-directory directory t))))

(defun gdev-format--start (program arguments)
  "Formatta il testo corrente con PROGRAM e ARGUMENTS in un processo separato."
  (let* ((source (current-buffer))
         (executable (or (executable-find program)
                         (signal 'file-missing (list "Formattatore non trovato" program))))
         (tick (buffer-chars-modified-tick))
         (file buffer-file-name)
         (mode major-mode)
         (beg (point-min))
         (end (point-max))
         (directory (make-temp-file "gdev-format-" t))
         (input (expand-file-name "input" directory))
         (errors (expand-file-name "errors" directory))
         (output (generate-new-buffer " *gdev-format*"))
         process)
    (unwind-protect
        (progn
          (let ((coding-system-for-write (or coding-system-for-write
                                             (cdr default-process-coding-system))))
            (write-region beg end input nil 'silent))
          (setq process
                (make-process
                 :name "gdev-format" :buffer output :connection-type 'pipe :noquery t
                 :command (append (list "/bin/sh" "-c"
                                        "input=$1; errors=$2; shift 2; exec \"$@\" < \"$input\" 2> \"$errors\""
                                        "gdev-format" input errors executable)
                                  arguments)
                 ;; Conserva anche un'uscita consegnata prima che la
                 ;; sentinella applicativa sia stata installata.
                 :sentinel (lambda (child event)
                             (when (memq (process-status child) '(exit signal failed))
                               (process-put child 'gdev-format--pending-event event)))))
          (process-put process 'gdev-format--source-tick tick)
          (setq gdev-format--process process)
          (add-hook 'kill-buffer-hook #'gdev-format--cancel nil t)
          (add-hook 'change-major-mode-hook #'gdev-format--cancel nil t)
          (add-hook 'after-change-functions #'gdev-format--changed nil t)
          (set-process-sentinel
           process
           (lambda (child _event)
             (when (and (memq (process-status child) '(exit signal failed))
                        (not (process-get child 'gdev-format--handled)))
               (process-put child 'gdev-format--handled t)
               (unwind-protect
                   (when (buffer-live-p source)
                     (with-current-buffer source
                       (when (eq child gdev-format--process)
                         (gdev-format--cancel)
                         (cond
                          ((not (and (eq (process-status child) 'exit)
                                     (zerop (process-exit-status child))))
                           (message "%s: %s" program
                                    (string-trim (or (gdev-read-file-contents errors) "Formattazione non riuscita"))))
                          ((and (= tick (buffer-chars-modified-tick))
                                (equal file buffer-file-name) (eq mode major-mode)
                                (= beg (point-min)) (= end (point-max))
                                (not buffer-read-only))
                           (with-suppressed-warnings ((obsolete replace-buffer-contents))
                             (replace-buffer-contents output 3)))
                          (t (message "Formattazione scartata perché il documento è cambiato"))))))
                 (gdev-format--release output directory)))))
          (when-let* ((event (process-get process 'gdev-format--pending-event)))
            (process-put process 'gdev-format--pending-event nil)
            (funcall (process-sentinel process) process event))
          process)
      (unless process
        (gdev-format--release output directory)))))

(defun gdev-format-with-program (program &rest arguments)
  "Passa l'area di testo a PROGRAM ARGUMENTS e lo sostituisce con il risultato.
La sostituzione è minima (`replace-buffer-contents').  Restituisce non nil
se riesce; altrimenti mostra gli errori del programma.  Per una richiesta
manuale locale restituisce il processo, che applica il risultato a fine lavoro."
  (gdev-require-project-environment)
  (gdev-format--cancel)
  (if (and gdev-format--background (not (file-remote-p default-directory))
           (file-executable-p "/bin/sh"))
      (gdev-format--start program arguments)
    (apply #'gdev-format--with-program-now program arguments)))

(defun gdev-format--with-program-now (program &rest arguments)
  "Formatta subito il testo corrente con PROGRAM e ARGUMENTS."
  (let ((output (generate-new-buffer " *gdev-format*"))
        (errors (make-temp-file "gdev-format")))
    (unwind-protect
        (if (zerop (apply #'call-process-region (point-min) (point-max)
                          program nil (list output errors) nil arguments))
            (progn (with-suppressed-warnings ((obsolete replace-buffer-contents))
                     (replace-buffer-contents output 3))
                   t)
          (let ((dettaglio (string-trim (gdev-read-file-contents errors))))
            (if gdev-format--errore-processo
                (user-error "%s non riuscito: %s" program dettaglio)
              (message "%s: %s" program dettaglio)))
          nil)
      (kill-buffer output)
      (delete-file errors))))

(defun gdev-format-buffer (&optional background)
  "Formatta il buffer con il gestore registrato o il server di linguaggio.
Con BACKGROUND avvia in secondo piano un formattatore esterno locale."
  (interactive (list t))
  (let ((formatter (gdev-handler :format)))
    (cond (formatter
           (gdev-format--cancel)
           (let ((gdev-format--background background))
             (funcall formatter)))
          ((and (bound-and-true-p eglot--managed-mode)
                (eglot-server-capable :documentFormattingProvider))
           (gdev-format--cancel)
           (eglot-format-buffer))
          (t (user-error "Nessun formattatore per %s" major-mode)))))

(defun gdev-format-dwim (&optional beg end background)
  "Formatta la selezione attiva tra BEG e END, altrimenti l'intera area di testo.
La selezione va al server di linguaggio, che sa formattare parte di un file:
un formattatore esterno riformatta tutto il documento, e prima lo chiede.
Con BACKGROUND il formattatore esterno locale lavora in secondo piano."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end) t)
                 (list nil nil t)))
  (cond ((and beg (bound-and-true-p eglot--managed-mode)
              (eglot-server-capable :documentRangeFormattingProvider))
         (gdev-format--cancel)
         (eglot-format beg end))
        ;; Senza un server a intervalli la selezione verrebbe ignorata e il
        ;; diff riguarderebbe tutto il file: meglio dirlo e chiedere.
        ((and beg (not (y-or-n-p "Il formattatore non sa formattare una selezione: formattare tutto il documento? ")))
         (user-error "Formattazione annullata"))
        (t (gdev-format-buffer background))))

;;;; Al salvataggio (+onsave)

(defgroup gdev-format nil
  "Formattazione del codice."
  :group 'gdev)

(defcustom gdev-format-style-files
  '((c-ts-base-mode ".clang-format" "_clang-format")
    (cmake-ts-mode ".cmake-format" ".cmake-format.yaml" ".gersemirc")
    (cperl-mode ".perltidyrc")
    (js-base-mode "deno.json" "deno.jsonc")
    (typescript-ts-base-mode "deno.json" "deno.jsonc")
    (css-base-mode "deno.json" "deno.jsonc")
    (json-ts-mode "deno.json" "deno.jsonc")
    (web-mode "deno.json" "deno.jsonc"))
  "Modalità principale -> file la cui presenza dichiara lo stile del progetto."
  :type '(alist :key-type symbol :value-type (repeat string)))

(defvar-local gdev-format-on-save nil
  "Decide se formattare prima di salvare: t, nil o `auto'.
Con `auto' formatta solo se il progetto dichiara il proprio stile.
L'opzione +onsave rende `auto' il valore predefinito.  Impostala per
progetto in .dir-locals.el o cambiala nel buffer con C-c t f.")
(put 'gdev-format-on-save 'safe-local-variable #'symbolp)

(defun gdev-format--style-declared-p ()
  "Restituisce non nil se il progetto dichiara lo stile di questo linguaggio."
  (or (when-let* ((names (cl-loop for (mode . files) in gdev-format-style-files
                                 when (derived-mode-p mode) return files)))
        (cl-some (lambda (name) (locate-dominating-file default-directory name)) names))
      (when-let* ((predicate (gdev-handler :format-style)))
        (funcall predicate))))

(defun gdev-format-before-save ()
  "Formatta l'area di testo prima di salvare, secondo `gdev-format-on-save'."
  (when (and (gdev-project-environment-ready-p)
             (pcase gdev-format-on-save
               ('auto (gdev-format--style-declared-p))
               (value value)))
    (condition-case err
        (gdev-format-buffer)
      (error
       (display-warning 'gdev
                        (format "Salvataggio senza formattazione: %s"
                                (error-message-string err))
                        :warning)))))

(defun gdev-format-toggle-on-save ()
  "Attiva o disattiva in quest'area di testo la formattazione al salvataggio."
  (interactive)
  (setq gdev-format-on-save (not (if (eq gdev-format-on-save 'auto)
                                     (gdev-format--style-declared-p)
                                   gdev-format-on-save)))
  (message "Formattazione al salvataggio %s"
           (if gdev-format-on-save "attivata" "disattivata")))

(when (gdev-module-p :editor 'format '+onsave)
  (setq-default gdev-format-on-save 'auto))

(defun gdev-format--install-before-save ()
  "Attiva qui la formattazione al salvataggio, secondo `gdev-format-on-save'."
  (add-hook 'before-save-hook #'gdev-format-before-save nil t))

(add-hook 'prog-mode-hook #'gdev-format--install-before-save)

(defun gdev-format--in-lavorazione (contesto)
  "Formatta il documento di CONTESTO con il gestore locale registrato."
  (unless (gdev-project-trusted-p (gdev-lavorazione-radice contesto))
    (user-error "Autorizza gli strumenti della cartella prima di formattare"))
  (with-current-buffer (gdev-lavorazione-documento contesto)
    (unless (gdev-handler :format)
      (user-error "Nessun formattatore locale per %s" major-mode))
    (let ((gdev-format--errore-processo t))
      (save-restriction
        (widen)
        (atomic-change-group (gdev-format-buffer))))))

(with-eval-after-load 'gdev-lavorazione
  (gdev-lavorazione-registra
   "formatta-documento" "Usa il formattatore del linguaggio nella cartella autorizzata."
   nil #'gdev-format--in-lavorazione :modulo "Formattazione" :richiede-documento t))

;;; config.el ends here
