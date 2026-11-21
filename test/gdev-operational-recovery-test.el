;;; gdev-operational-recovery-test.el --- Ambiente e recupero dello spazio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Processi reali con shell controllate e stato privato verificano tempi,
;; annullamento e pubblicazione dell'ambiente. I checkpoint esercitano le
;; schede native e leggono l'istantanea persistita senza modificare i documenti.

;;; Code:

(require 'ert)
(require 'gdev-env)
(require 'gdev-workspaces)
(defvar gdev-core--xref-search-program-auto)
(defvar xref-search-program)

(defmacro gdev-test-operational--with-shell (script &rest body)
  "Esegui BODY con una shell SCRIPT e un archivio temporanei."
  (declare (indent 1))
  `(let* ((gdev-test-operational-directory (make-temp-file "gdev-shell-test-" t))
          (gdev-test-operational-shell (expand-file-name "shell" gdev-test-operational-directory))
          (gdev-state-directory (file-name-as-directory gdev-test-operational-directory))
          (gdev-env-variables '("GDEV_ENV_TEST_VALUE"))
          (gdev-env--shell-timeout 2)
          (gdev-env--refresh-process nil)
          (gdev-env--refresh-request nil)
          (process-environment (copy-sequence process-environment))
          (exec-path exec-path))
     (unwind-protect
         (progn
           (with-temp-file gdev-test-operational-shell
             (insert "#!/bin/sh\n" ,script "\n"))
           (set-file-modes gdev-test-operational-shell #o700)
           (setenv "SHELL" gdev-test-operational-shell)
           (setenv "GDEV_ENV_TEST_VALUE" "precedente")
           ,@body)
       (gdev-env-refresh-cancel)
       (delete-directory gdev-test-operational-directory t))))

(defun gdev-test-operational--wait (process)
  "Attendi PROCESS con un limite indipendente dal timeout del lettore."
  (let ((deadline (+ (float-time) 4)))
    (while (and (not (process-get process 'gdev-env-finished)) (< (float-time) deadline))
      (accept-process-output process 0.02))
    (should (process-get process 'gdev-env-finished))
    (should-not (process-live-p process))
    (should-not (buffer-live-p (process-buffer process)))
    (should-not (buffer-live-p (process-get process 'gdev-env-errors)))
    (should-not (process-get process 'gdev-env-timer))))

(ert-deftest gdev-test-operational-environment-refresh-keeps-the-editor-responsive ()
  "La lettura non blocca timer e pubblica insieme valori completi dopo il salvataggio."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell
      "export GDEV_ENV_TEST_VALUE='nuovo\nvalore'\n/bin/sleep 0.2\nexec /bin/sh -c \"$4\""
    (let* ((started (float-time)) (tick nil)
          (timer (run-at-time 0.03 nil (lambda () (setq tick t)))))
      (unwind-protect
          (let ((process (gdev-env-refresh t)))
            (should (< (- (float-time) started) 1))
            (should (equal (getenv "GDEV_ENV_TEST_VALUE") "precedente"))
            (gdev-test-operational--wait process)
            (should tick)
            (should (equal (getenv "GDEV_ENV_TEST_VALUE") "nuovo\nvalore"))
            (should (equal (gdev-state-db-entries "ambiente" "")
                           '(("GDEV_ENV_TEST_VALUE" . "nuovo\nvalore")))))
        (cancel-timer timer)))))

(ert-deftest gdev-test-operational-environment-timeout-preserves-the-cache ()
  "Una shell bloccata scade, libera le risorse e lascia valido l'ambiente precedente."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell "exec /bin/sleep 5"
    (gdev-env-save-current)
    (let ((gdev-env--shell-timeout 0.05) warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (let ((started (float-time)) (process (gdev-env-refresh t)))
          (gdev-test-operational--wait process)
          (should (< (- (float-time) started) 1))
          (should (string-match-p "Tempo scaduto" (car warnings)))
          (should (equal (getenv "GDEV_ENV_TEST_VALUE") "precedente"))
          (should (equal (gdev-state-db-entries "ambiente" "")
                         '(("GDEV_ENV_TEST_VALUE" . "precedente")))))))))

(ert-deftest gdev-test-operational-environment-cancel-and-supersede ()
  "Un nuovo aggiornamento e l'annullamento impediscono consegne superate."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell "exec /bin/sleep 5"
    (let ((first (gdev-env-refresh t)))
      (with-temp-file gdev-test-operational-shell
        (insert "#!/bin/sh\nexport GDEV_ENV_TEST_VALUE=recente\nexec /bin/sh -c \"$4\"\n"))
      (let ((second (gdev-env-refresh t)))
        (gdev-test-operational--wait first)
        (gdev-test-operational--wait second)
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "recente")))
      (with-temp-file gdev-test-operational-shell (insert "#!/bin/sh\nexec /bin/sleep 5\n"))
      (let ((third (gdev-env-refresh t)))
        (gdev-env-refresh-cancel)
        (gdev-test-operational--wait third)
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "recente"))
        (should (equal (gdev-state-db-entries "ambiente" "")
                       '(("GDEV_ENV_TEST_VALUE" . "recente")))))
      (let ((fourth (gdev-env-refresh t)))
        (with-temp-file gdev-test-operational-shell
          (insert "#!/bin/sh\nexport GDEV_ENV_TEST_VALUE=sincrono\nexec /bin/sh -c \"$4\"\n"))
        (gdev-env-refresh)
        (gdev-test-operational--wait fourth)
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "sincrono"))))))

(ert-deftest gdev-test-operational-environment-invalid-output-and-profile-change ()
  "Né un risultato parziale né un cambio di profilo applicano l'ambiente letto."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell "printf '\\0__GDEV_ENV__\\0incompleto'"
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (gdev-test-operational--wait (gdev-env-refresh t))
        (should (string-match-p "incompleto" (car warnings)))
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "precedente"))
        (with-temp-file gdev-test-operational-shell
          (insert "#!/bin/sh\nexport GDEV_ENV_TEST_VALUE=altro\n/bin/sleep 0.1\nexec /bin/sh -c \"$4\"\n"))
        (let ((process (gdev-env-refresh t)))
          (let ((gdev-state-directory (expand-file-name "profilo-diverso" gdev-test-operational-directory)))
            (gdev-test-operational--wait process))
          (should (string-match-p "profilo è cambiato" (car warnings)))
          (should (equal (getenv "GDEV_ENV_TEST_VALUE") "precedente"))
          (should-not (gdev-env-saved-p)))))))

(ert-deftest gdev-test-operational-environment-immediate-completion-keeps-request-identity ()
  "Un esito immediato non lascia una richiesta conclusa né sovrascrive quella di un hook."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell
      "export GDEV_ENV_TEST_VALUE=primo\nexec /bin/sh -c \"$4\""
    (let ((reader (symbol-function 'gdev-env--read-login-shell))
          (gdev-env-after-refresh-hook nil))
      (cl-letf (((symbol-function 'gdev-env--read-login-shell)
                 (lambda (callback)
                   (let ((process (funcall reader callback)))
                     (gdev-test-operational--wait process)
                     process))))
        (gdev-env-refresh t)
        (should-not gdev-env--refresh-process)
        (should-not gdev-env--refresh-request)
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "primo"))))
    (let ((reader (symbol-function 'gdev-env--read-login-shell))
          (reads 0) reentered second
          (gdev-env-after-refresh-hook nil))
      (setq gdev-env-after-refresh-hook
            (list (lambda ()
                    (unless reentered
                      (setq reentered t)
                      (with-temp-file gdev-test-operational-shell
                        (insert "#!/bin/sh\nexport GDEV_ENV_TEST_VALUE=secondo\n/bin/sleep 0.1\nexec /bin/sh -c \"$4\"\n"))
                      (setq second (gdev-env-refresh t))))))
      (cl-letf (((symbol-function 'gdev-env--read-login-shell)
                 (lambda (callback)
                   (let ((process (funcall reader callback)))
                     (cl-incf reads)
                     (when (= reads 1) (gdev-test-operational--wait process))
                     process))))
        (let ((first (gdev-env-refresh t)))
          (should (process-get first 'gdev-env-finished))
          (should (eq gdev-env--refresh-process second))
          (should (equal (getenv "GDEV_ENV_TEST_VALUE") "primo"))
          (gdev-test-operational--wait second)
          (should (equal (getenv "GDEV_ENV_TEST_VALUE") "secondo"))
          (should-not gdev-env--refresh-process)
          (should-not gdev-env--refresh-request))))))

(ert-deftest gdev-test-operational-environment-exit-before-sentinel-is-delivered ()
  "Una shell già terminata viene consegnata senza aspettare il timeout."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell
      "export GDEV_ENV_TEST_VALUE=completo\nexec /bin/sh -c \"$4\""
    (let ((make (symbol-function 'make-process)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest arguments)
                   (let ((process (apply make arguments)))
                     ;; Simula l'uscita prima che il lettore abbia installato
                     ;; proprietà, timeout e sentinel definitivo.
                     (while (process-live-p process)
                       (accept-process-output process 0.02))
                     process))))
        (let ((process (gdev-env-refresh t)))
          (should (process-get process 'gdev-env-finished))
          (should (equal (getenv "GDEV_ENV_TEST_VALUE") "completo"))
          (should-not gdev-env--refresh-process)
          (should-not gdev-env--refresh-request))))))

(ert-deftest gdev-test-operational-environment-synchronous-reader-is-bounded ()
  "La compatibilità Lisp mantiene errori sincroni e un limite per la shell."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell "exec /bin/sleep 5"
    (let ((gdev-env--shell-timeout 0.04) (started (float-time)))
      (should-error (gdev-env--from-login-shell))
      (should (< (- (float-time) started) 1)))
    (let ((read-shell (symbol-function 'gdev-env--read-login-shell))
          cancelled process)
      (cl-letf (((symbol-function 'gdev-env--read-login-shell)
                 (lambda (callback) (setq process (funcall read-shell callback))))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) (signal 'quit nil))))
        (condition-case nil (gdev-env--from-login-shell)
          (quit (setq cancelled t))))
      (should cancelled)
      (gdev-test-operational--wait process))))

(ert-deftest gdev-test-operational-environment-failed-shell-and-write-are-atomic ()
  "Shell fallita e disco non scrivibile conservano i valori precedenti."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell
      "export GDEV_ENV_TEST_VALUE=nonvalido\n/bin/sh -c \"$4\"\nexit 9"
    (gdev-env-save-current)
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (gdev-test-operational--wait (gdev-env-refresh t))
        (should (string-match-p "non ha completato" (car warnings)))
        (with-temp-file gdev-test-operational-shell
          (insert "#!/bin/sh\nexport GDEV_ENV_TEST_VALUE=nonpubblicato\nexec /bin/sh -c \"$4\"\n"))
        (cl-letf (((symbol-function 'gdev-state-db--put)
                   (lambda (&rest _) (signal 'file-error '("Disco non scrivibile")))))
          (gdev-test-operational--wait (gdev-env-refresh t)))
        (should (string-match-p "Disco non scrivibile" (car warnings)))
        (should (equal (getenv "GDEV_ENV_TEST_VALUE") "precedente"))
        (should (equal (gdev-state-db-entries "ambiente" "")
                       '(("GDEV_ENV_TEST_VALUE" . "precedente"))))))))

(ert-deftest gdev-test-operational-environment-keeps-project-overrides ()
  "La consegna aggiorna l'applicazione e conserva l'ambiente locale del progetto."
  (skip-unless (file-executable-p "/bin/sh"))
  (gdev-test-operational--with-shell
      "export GDEV_ENV_TEST_VALUE=globale\n/bin/sleep 0.05\nexec /bin/sh -c \"$4\""
    (with-temp-buffer
      (setq-local process-environment (copy-sequence process-environment)
                  exec-path '("/strumenti-progetto"))
      (setenv "GDEV_ENV_TEST_VALUE" "locale")
      (gdev-test-operational--wait (gdev-env-refresh t))
      (should (equal (getenv "GDEV_ENV_TEST_VALUE") "locale"))
      (should (equal exec-path '("/strumenti-progetto"))))
    (should (equal (getenv "GDEV_ENV_TEST_VALUE") "globale"))
    (should (equal (gdev-state-db-entries "ambiente" "")
                   '(("GDEV_ENV_TEST_VALUE" . "globale"))))))

(ert-deftest gdev-test-operational-environment-refreshes-automatic-xref-only ()
  "La ricerca vede ripgrep arrivato dalla shell e conserva le scelte esplicite."
  (require 'package)
  (package-activate-all)
  (require 'gdev-core)
  (let ((properties (symbol-plist 'xref-search-program))
        (gdev-core--xref-search-program-auto 'grep)
        (xref-search-program 'grep))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_program) "/strumenti/rg")))
          (put 'xref-search-program 'saved-value nil)
          (put 'xref-search-program 'customized-value nil)
          (should (memq #'gdev-core--refresh-xref-search-program gdev-env-after-refresh-hook))
          (gdev-core--refresh-xref-search-program)
          (should (eq xref-search-program 'ripgrep))
          (setq xref-search-program 'ugrep)
          (gdev-core--refresh-xref-search-program)
          (should (eq xref-search-program 'ugrep))
          (setq xref-search-program 'grep gdev-core--xref-search-program-auto 'grep)
          (put 'xref-search-program 'saved-value '(grep))
          (gdev-core--refresh-xref-search-program)
          (should (eq xref-search-program 'grep)))
      (setplist 'xref-search-program properties))))

(ert-deftest gdev-test-operational-checkpoint-keeps-workspace-changes-without-edits ()
  "Schede, cartelle, documento attivo e geometria si recuperano senza nuove bozze."
  (gdev-test--with-layout
    (let* ((gdev-state-directory (make-temp-file "gdev-space-checkpoint-" t))
           (gdev-workspaces--session-active nil)
           (gdev-workspaces--generation nil)
           (gdev-workspaces--checkpoint-signature nil)
           (gdev-workspaces--checkpoint-file nil)
           (gdev-workspaces--checkpoint-cache nil)
           (gdev-drafts-hot-exit nil)
           (first-file (expand-file-name "primo.txt" gdev-state-directory))
           (second-file (expand-file-name "secondo.txt" gdev-state-directory))
           (first (find-file-noselect first-file))
           (second (find-file-noselect second-file)))
      (unwind-protect
          (progn
            (switch-to-buffer first)
            (gdev-workspace-state-set 'gdev-layout-folder gdev-state-directory)
            (gdev-workspaces-checkpoint)
            (let ((initial (gdev-workspaces--read)))
              (tab-bar-new-tab)
              (tab-bar-rename-tab "Secondo spazio")
              (gdev-workspace-state-set 'gdev-layout-folder temporary-file-directory)
              (switch-to-buffer second)
              (let ((split-width-threshold 0)) (split-window-right))
              (gdev-workspaces-checkpoint)
              (let* ((saved (gdev-workspaces--read))
                     (active (nth (plist-get saved :active) (plist-get saved :tabs)))
                     (generation (plist-get saved :generazione)))
                (should-not (equal saved initial))
                (should (= (length (plist-get saved :tabs)) 2))
                (should (equal (plist-get active :folder) temporary-file-directory))
                (should (equal (plist-get active :name) "Secondo spazio"))
                (should (string-search second-file (prin1-to-string (plist-get active :windows))))
                (should (eq (cadr (plist-get active :windows)) 'hc))
                (gdev-workspaces-checkpoint)
                (should (= generation (plist-get (gdev-workspaces--read) :generazione)))
                (switch-to-buffer first)
                (gdev-workspaces-checkpoint)
                (should-not (= generation (plist-get (gdev-workspaces--read) :generazione))))))
        (dolist (buffer (list first second)) (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory gdev-state-directory t)))))

(ert-deftest gdev-test-operational-checkpoint-ignores-cursor-motion ()
  "Spostare il cursore non riscrive il checkpoint dello stesso documento."
  (let* ((first '(:active 0 :tabs ((:name "Uno" :windows ((80 . 24) leaf
                                                       (buffer "/test.el" (selected . t) (point . 1) (start . 1)))))))
         (second (copy-tree first))
         (windows (plist-get (car (plist-get second :tabs)) :windows)))
    (setf (alist-get 'point (cddr (assq 'buffer (cddr windows)))) 50)
    (should (equal (gdev-workspaces--checkpoint-metadata first)
                   (gdev-workspaces--checkpoint-metadata second)))))

(provide 'gdev-operational-recovery-test)
;;; gdev-operational-recovery-test.el ends here
