;;; gdev-hit-latency-test.el --- Scansione dei file non tracciati di Hit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Code:

(require 'cl-lib)
(require 'ert)

(ert-deftest gdev-hit-latency-tests-untracked-list-without-scanning-tracked-files ()
  "Conserva ordine, percorsi, filtri e impostazioni dei file non tracciati."
  (skip-unless (executable-find "git"))
  (require 'package)
  (package-activate-all)
  (require 'magit)
  (let* ((root (make-temp-file "gdev-hit-untracked-" t))
         (default-directory (file-name-as-directory (file-truename root)))
         (process-environment (copy-sequence process-environment)))
    (setenv "GIT_CONFIG_GLOBAL" null-device)
    (setenv "GIT_CONFIG_NOSYSTEM" "1")
    (unwind-protect
        (cl-labels ((git (&rest args)
                      (with-temp-buffer
                        (should (eql 0 (apply #'process-file "git" nil t nil args)))
                        (buffer-string)))
                    (write (file text)
                      (with-temp-file file (insert text))))
          (git "init" "-q" "--template=")
          (git "config" "user.name" "GDev")
          (git "config" "user.email" "gdev@example.org")
          (git "config" "commit.gpgSign" "false")
          (write ".gitignore" "*.ign\n")
          (write "origine" "Originale\n")
          (write "tracciato" "Originale\n")
          (git "add" "--" ".gitignore" "origine" "tracciato")
          (git "commit" "-qm" "Base")
          (git "mv" "origine" "rinominato")
          (write "tracciato" "Modificato\n")
          (make-directory "cartella")
          (make-directory "vuota")
          (write "cartella/nome con spazi" "Uno\n")
          (write "cartella/scarta.ign" "Ignorato\n")
          (write "file\ncon a capo" "Due\n")
          (let ((before (git "status" "-z" "--porcelain" "--untracked-files=all"))
                (git-items (symbol-function 'magit-git-items))
                calls)
            (with-temp-buffer
              (magit-status-mode)
              (cl-letf (((symbol-function 'magit-git-items)
                         (lambda (&rest args)
                           (push (car args) calls)
                           (apply git-items args))))
                (setq-local magit-status-show-untracked-files t)
                (should (equal (magit-list-untracked-files) '("cartella/" "file\ncon a capo")))
                (setq-local magit-status-show-untracked-files 'all)
                (should (equal (magit-list-untracked-files) '("cartella/nome con spazi" "file\ncon a capo")))
                (should (equal (magit-list-untracked-files '("cartella")) '("cartella/nome con spazi")))
                (should (equal calls '("ls-files" "ls-files" "ls-files")))
                (setq calls nil)
                (let ((default-directory (expand-file-name "cartella/")))
                  (should (equal (magit-list-untracked-files '("nome con spazi"))
                                 '("cartella/nome con spazi"))))
                (should (equal calls '("status")))
                (git "config" "--local" "status.showUntrackedFiles" "no")
                (kill-local-variable 'magit-status-show-untracked-files)
                (should-not (magit-list-untracked-files))))
            (should (equal before (git "status" "-z" "--porcelain" "--untracked-files=all")))))
      (delete-directory root t))))

;;; gdev-hit-latency-test.el ends here
