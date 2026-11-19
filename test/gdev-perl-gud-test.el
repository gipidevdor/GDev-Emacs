;;; gdev-perl-gud-test.el --- Avvio Perl con il debugger GUD -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-modules)
(require 'gud)

(ert-deftest gdev-perl-gud-keeps-project-directory-and-quotes-script ()
  "GUD apre gli script in sottocartelle mantenendo `-Ilib' relativo alla radice."
  (unless (fboundp 'gdev-perl-perldb)
    (load (gdev-module-file :lang 'perl ".el") nil t))
  (let* ((root (expand-file-name "Progetto Perl/" temporary-file-directory))
         (script (expand-file-name "bin/script di prova" root))
         (gud-chdir-before-run t)
         started)
    (with-temp-buffer
      (setq buffer-file-name script
            default-directory (file-name-directory script))
      (cl-letf (((symbol-function 'gdev-project-root) (lambda (&optional _) root))
                ((symbol-function 'read-shell-command) (lambda (_prompt initial &rest _args) initial))
                ((symbol-function 'perldb)
                 (lambda (line)
                   (should (equal default-directory root))
                   (should-not gud-chdir-before-run)
                   (should (equal (split-string-and-unquote line)
                                  (list "perl" "-Ilib" "-d" script)))
                   (setq started t))))
        (gdev-perl-perldb)))
    (should started)
    (should gud-chdir-before-run)))

(provide 'gdev-perl-gud-test)
;;; gdev-perl-gud-test.el ends here
