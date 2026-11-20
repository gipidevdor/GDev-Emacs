;;; gdev-format-test.el --- Ciclo di vita della formattazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Usa processi reali con un gate esplicito. L'uscita del programma può
;; precedere la sentinella: il risultato è pronto quando la sentinella ha
;; applicato o scartato il testo e rilasciato il buffer di output.

;;; Code:

(require 'ert)
(require 'cl-lib)
(defvar eglot--managed-mode)
(defvar native-comp-enable-subr-trampolines)

(defun gdev-format-test--wait (process)
  "Attendi la consegna del risultato di PROCESS, non solo la sua uscita."
  (let ((output (process-get process 'gdev-format-test-output))
        (deadline (+ (float-time) 5)))
    (while (and (buffer-live-p output) (< (float-time) deadline))
      (accept-process-output process 0.05))
    (should-not (buffer-live-p output))))

(defmacro gdev-format-test--with-formatter (&rest body)
  "Esegui BODY con un formattatore locale che attende il file `gate'."
  (declare (indent 0))
  `(progn
     (skip-unless (and (executable-find "sh") (executable-find "tr") (executable-find "cat")))
     (load (gdev-module-file :editor 'format ".el") nil t t)
     (let* ((root (make-temp-file "gdev-format-test-" t))
            (default-directory (file-name-as-directory root))
            (temporary-file-directory default-directory)
            (script (expand-file-name "formattatore è.sh" root))
            (gate (expand-file-name "gate" root))
            (source (generate-new-buffer "gdev-format-source"))
            (gdev--handlers (make-hash-table :test #'eq))
            children)
       (unwind-protect
           (with-current-buffer source
             (with-temp-file script
               (insert "#!/bin/sh\nwhile test ! -f \"$1\"; do sleep 0.01; done\nexec tr a-z A-Z\n"))
             (set-file-modes script #o700)
             (gdev-set-formatter 'fundamental-mode
                                 (lambda () (gdev-format-with-program script gate)))
             (insert "prova\n")
             (cl-labels ((start (&optional command)
                           (let ((process (call-interactively (or command #'gdev-format-buffer))))
                             (should (processp process))
                             (push process children)
                             (process-put process 'gdev-format-test-output (process-buffer process))
                             (process-put process 'gdev-format-test-sentinel (process-sentinel process))
                             process))
                         (release () (write-region "" nil gate nil 'silent)))
               ,@body))
         (when (buffer-live-p source)
           (with-current-buffer source (set-buffer-modified-p nil))
           (kill-buffer source))
         (dolist (process children)
           (when (process-live-p process) (delete-process process))
           ;; Anche una regressione che perde la notifica deve lasciare
           ;; pulita la fixture, dopo che le sue asserzioni sono fallite.
           (when (buffer-live-p (process-get process 'gdev-format-test-output))
             (ignore-errors (funcall (process-get process 'gdev-format-test-sentinel) process "fixture cleanup\n"))))
         (delete-directory root t)))))

(ert-deftest gdev-test-manual-format-does-not-overwrite-newer-edits ()
  "La formattazione asincrona aggiorna il testo solo se è ancora attuale."
  (gdev-format-test--with-formatter
    (let ((process (start #'gdev-format-dwim)))
      (should (process-live-p process))
      (should (equal (buffer-string) "prova\n"))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "PROVA\n")))
    (delete-file gate)
    (erase-buffer)
    (insert "bozza\n")
    (let ((process (start)))
      (insert "aggiunta\n")
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "bozza\naggiunta\n")))
    (should (gdev-format-buffer))
    (should (equal (buffer-string) "BOZZA\nAGGIUNTA\n"))))

(ert-deftest gdev-test-behavior-format-synchronous-request-supersedes-pending ()
  "Un risultato sincrono identico al testo revoca la richiesta precedente."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (gdev-set-formatter 'fundamental-mode (lambda () (gdev-format-with-program "cat")))
      (should (gdev-format-buffer))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\n"))
      (should-not (process-live-p process)))))

(ert-deftest gdev-test-behavior-format-lsp-buffer-supersedes-pending ()
  "Passare al server di linguaggio revoca il vecchio formattatore esterno."
  (gdev-format-test--with-formatter
    (let ((process (start))
          (eglot--managed-mode t)
          (gdev--handlers (make-hash-table :test #'eq)) called)
      (cl-letf (((symbol-function 'eglot-server-capable) (lambda (&rest _) t))
                ((symbol-function 'eglot-format-buffer) (lambda () (setq called t))))
        (gdev-format-buffer))
      (should called)
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\n")))))

(ert-deftest gdev-test-behavior-format-lsp-region-supersedes-pending ()
  "La richiesta al server per una selezione revoca il vecchio risultato."
  (gdev-format-test--with-formatter
    (let ((process (start)) (eglot--managed-mode t) called)
      (cl-letf (((symbol-function 'eglot-server-capable) (lambda (&rest _) t))
                ((symbol-function 'eglot-format) (lambda (beg end) (setq called (list beg end)))))
        (gdev-format-dwim 1 3 t))
      (should (equal called '(1 3)))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\n")))))

(ert-deftest gdev-test-behavior-format-mode-change-cancels-pending ()
  "Cambiare modalità termina il lavoro e rilascia il suo output."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (text-mode)
      (should-not (process-live-p process))
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\n")))))

(ert-deftest gdev-test-behavior-format-editing-cancels-pending ()
  "La prima modifica termina il processo che lavorava sul vecchio testo."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (insert "aggiunta\n")
      (should-not (process-live-p process))
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\naggiunta\n")))))

(ert-deftest gdev-test-behavior-format-inhibited-hooks-still-reject-stale-output ()
  "Il controllo di versione resta valido anche con gli hook disabilitati."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (let ((inhibit-modification-hooks t)) (insert "aggiunta\n"))
      (should (process-live-p process))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "prova\naggiunta\n")))))

(ert-deftest gdev-test-behavior-format-property-changes-keep-pending ()
  "Cambiare le facce senza modificare i caratteri conserva il lavoro."
  (gdev-format-test--with-formatter
    (let ((process (start)) (tick (buffer-chars-modified-tick)))
      (put-text-property 1 3 'face 'bold)
      (should (= tick (buffer-chars-modified-tick)))
      (should (process-live-p process))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "PROVA\n")))))

(ert-deftest gdev-test-behavior-format-closing-source-releases-output ()
  "Chiudere il documento termina il processo senza lasciare il suo buffer."
  (gdev-format-test--with-formatter
    (let ((process (start)) (source (current-buffer)))
      (set-buffer-modified-p nil)
      (should (kill-buffer source))
      (should-not (process-live-p process))
      (gdev-format-test--wait process))))

(ert-deftest gdev-test-behavior-format-declining-region-keeps-pending ()
  "Annullare la conferma conserva la richiesta già in corso."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-error (gdev-format-dwim 1 3 t) :type 'user-error))
      (should (process-live-p process))
      (release)
      (gdev-format-test--wait process)
      (should (equal (buffer-string) "PROVA\n")))))

(ert-deftest gdev-test-behavior-format-completion-is-delivered-once ()
  "Una notifica finale duplicata non riapplica il testo né fallisce la pulizia."
  (gdev-format-test--with-formatter
    (let ((process (start)))
      (release)
      (gdev-format-test--wait process)
      (insert "aggiunta\n")
      (funcall (process-get process 'gdev-format-test-sentinel) process "finished\n")
      (should (equal (buffer-string) "PROVA\naggiunta\n")))))

(ert-deftest gdev-test-behavior-format-start-failure-releases-resources ()
  "Un processo che non parte lascia il documento e le risorse iniziali."
  (gdev-format-test--with-formatter
    (let ((before (directory-files root nil nil t))
          (native-comp-enable-subr-trampolines nil)
          (original (symbol-function 'make-process)) output)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest arguments)
                   (if (equal (plist-get arguments :name) "gdev-format")
                       (progn (setq output (plist-get arguments :buffer)) (error "Avvio simulato non riuscito"))
                     (apply original arguments)))))
        (should-error (call-interactively #'gdev-format-buffer)))
      (should output)
      (should-not (buffer-live-p output))
      (should-not gdev-format--process)
      (should (equal (directory-files root nil nil t) before))
      (should (equal (buffer-string) "prova\n")))))

(ert-deftest gdev-test-behavior-format-failed-command-preserves-source ()
  "Un'uscita non riuscita conserva il testo e consegna l'errore una volta."
  (gdev-format-test--with-formatter
    (with-temp-file script
      (insert "#!/bin/sh\nwhile test ! -f \"$1\"; do sleep 0.01; done\n"
              "printf ERRORE-FORMAT >&2\nexit 7\n"))
    (let ((original (symbol-function 'message))
          (native-comp-enable-subr-trampolines nil) messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (let ((text (and (stringp format-string)
                                    (apply #'format format-string arguments))))
                     (if (and text (string-match-p "ERRORE-FORMAT" text))
                         (push text messages)
                       (apply original format-string arguments))))))
        (let ((process (start)))
          (release)
          (gdev-format-test--wait process)
          (should (= 7 (process-exit-status process)))
          (funcall (process-get process 'gdev-format-test-sentinel) process "finished\n")
          (should (= 1 (length messages)))
          (should (equal (buffer-string) "prova\n")))))))

(ert-deftest gdev-test-behavior-format-early-completion-is-not-lost ()
  "Un'uscita durante l'installazione della sentinella viene consegnata."
  (gdev-format-test--with-formatter
    (let ((original (symbol-function 'set-process-sentinel))
          (native-comp-enable-subr-trampolines nil))
      (release)
      (cl-letf (((symbol-function 'set-process-sentinel)
                 (lambda (process sentinel)
                   (when (equal (process-name process) "gdev-format")
                     (let ((deadline (+ (float-time) 5)))
                       (while (and (process-live-p process) (< (float-time) deadline))
                         (accept-process-output process 0.05))
                       (accept-process-output process 0.05)))
                   (funcall original process sentinel))))
        (let ((process (start)))
          (should-not (process-live-p process))
          (should (equal (buffer-string) "PROVA\n")))))))

(provide 'gdev-format-test)
;;; gdev-format-test.el ends here
