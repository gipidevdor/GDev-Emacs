;;; gdev-core-latency-test.el --- Protezione del primo file aperto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Code:

(require 'ert)
(require 'gdev-lib)

(ert-deftest gdev-test-so-long-protects-first-command-line-file ()
  "La protezione è attiva già durante il primo argomento file di Emacs."
  (let* ((directory (make-temp-file "gdev-test-so-long-" t))
         (long (expand-file-name "lungo.el" directory))
         (short (expand-file-name "normale.el" directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GDEV_STATE_DIR" (expand-file-name "stato" directory))
          (setenv "GDEV_USER_DIR" (expand-file-name "utente" directory))
          (with-temp-file long
            (insert ";;; -*- lexical-binding: t; -*-\n; " (make-string 20000 ?x) "\n"))
          (with-temp-file short
            (insert ";;; -*- lexical-binding: t; -*-\n(message \"Esempio\")\n"))
          (with-temp-buffer
            (let ((status
                   (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil t nil "--batch" "-Q"
                    "-l" (gdev-config-file "early-init.el")
                    "-L" (gdev-config-file "lisp")
                    "--eval" "(progn (require 'package) (package-activate-all))"
                    "-l" "gdev-core"
                    "--eval" (concat "(progn (cl-assert (not (bound-and-true-p global-so-long-mode)))"
                                     " (setq so-long-invisible-buffer-function nil))")
                    long "--eval" "(cl-assert (eq major-mode 'so-long-mode))"
                    short "--eval" "(progn (cl-assert (eq major-mode 'emacs-lisp-mode)) (kill-emacs 0))")))
              (ert-info ((buffer-string))
                (should (eql status 0))))))
      (delete-directory directory t))))

(ert-deftest gdev-test-core-hides-cursor-in-unfocused-windows ()
  "Il cursore resta solo nella finestra attiva, anche nei buffer creati dopo l'avvio."
  (let* ((directory (make-temp-file "gdev-test-cursore-" t))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GDEV_STATE_DIR" (expand-file-name "stato" directory))
          (setenv "GDEV_USER_DIR" (expand-file-name "utente" directory))
          (with-temp-buffer
            (let ((status
                   (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil t nil "--batch" "-Q"
                    "-l" (gdev-config-file "early-init.el")
                    "-L" (gdev-config-file "lisp")
                    "--eval" "(progn (require 'package) (package-activate-all))"
                    "-l" "gdev-core"
                    "--eval" (concat "(progn (cl-assert (not (default-value 'cursor-in-non-selected-windows)))"
                                     " (with-temp-buffer (cl-assert (not cursor-in-non-selected-windows)))"
                                     " (kill-emacs 0))"))))
              (ert-info ((buffer-string))
                (should (eql status 0))))))
      (delete-directory directory t))))

(ert-deftest gdev-test-core-keeps-saved-preferences ()
  "Le scelte salvate con le Preferenze prevalgono sui valori predefiniti del nucleo."
  (let* ((directory (make-temp-file "gdev-test-preferenze-" t))
         (state (expand-file-name "stato" directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (make-directory state t)
          (with-temp-file (expand-file-name "custom.el" state)
            (insert "(custom-set-variables '(fill-column 80) '(indent-tabs-mode t)"
                    " '(history-length 50))\n"))
          (setenv "GDEV_STATE_DIR" state)
          (setenv "GDEV_USER_DIR" (expand-file-name "utente" directory))
          (with-temp-buffer
            (let ((status
                   (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil t nil "--batch" "-Q"
                    "-l" (gdev-config-file "early-init.el")
                    "-L" (gdev-config-file "lisp")
                    "--eval" "(progn (require 'package) (package-activate-all))"
                    "-l" "gdev-core"
                    "--eval" (concat "(progn (cl-assert (= (default-value 'fill-column) 80))"
                                     " (cl-assert (default-value 'indent-tabs-mode))"
                                     " (cl-assert (= history-length 50))"
                                     ;; Senza scelte salvate restano i valori di GDev.
                                     " (cl-assert (default-value 'truncate-lines))"
                                     " (kill-emacs 0))"))))
              (ert-info ((buffer-string))
                (should (eql status 0))))))
      (delete-directory directory t))))

(provide 'gdev-core-latency-test)
;;; gdev-core-latency-test.el ends here
