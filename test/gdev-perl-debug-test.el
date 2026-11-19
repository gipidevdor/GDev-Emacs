;;; gdev-perl-debug-test.el --- Profili Perl del banco di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Code:

(require 'ert)
(require 'gdev-modules)
(require 'gdev-project-view)

(ert-deftest gdev-perl-debug-profile-launches-a-readable-script ()
  "Un profilo Perl conserva argomenti, variabili e lib/ del progetto."
  (package-activate-all)
  (unless (fboundp 'gdev-run-dwim)
    (load (gdev-module-file :tools 'build ".el") nil t t))
  (load (gdev-module-file :tools 'debugger ".el") nil t t)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-perl-profile-" t)))
         (script (expand-file-name "prova con spazi.pl" root))
         (profile '("Prova" "prova con spazi.pl" ("CQ TEST")
                    ("PERL5LIB=moduli" "GDEV_TEST=valore=composto") perl))
         (gdev-launch-profiles (list (list root profile)))
         (gdev-launch--standalone-selections (list (cons root "Prova")))
         (gdev-layout-mode nil)
         debug run environment)
    (unwind-protect
        (progn
          (with-temp-file script (insert "print qq(CQ\\n);\n"))
          (set-file-modes script #o600)
          (with-temp-buffer
            (setq default-directory root)
            (cl-letf (((symbol-function 'dape) (lambda (config) (setq debug config)))
                      ((symbol-function 'gdev-compile)
                       (lambda (&rest args) (setq run args environment compilation-environment))))
              (gdev-debug-dwim)
              (gdev-run-dwim)))
          (should (equal (plist-get debug :program) script))
          (should (equal (plist-get debug :args) ["CQ TEST"]))
          (should (equal (plist-get debug :cwd) root))
          (let ((env (plist-get debug :env)))
            (should (equal (gethash "GDEV_TEST" env) "valore=composto"))
            (should (equal (gethash "PERL5LIB" env)
                           (concat (expand-file-name "lib" root) path-separator "moduli"))))
          (should (equal (nth 2 run) root))
          (should (equal (car run) (gdev-command-line "perl" "-Ilib" script "CQ TEST")))
          (should (equal (seq-take environment 2) (nth 3 profile)))
          (let ((named (cdr (assq 'gdev-perl (gdev-debug--configs)))))
            (should (eq (plist-get named 'command-cwd) 'dape-command-cwd))
            (should (eq (plist-get named :cwd) 'dape-cwd))
            (should (eq (plist-get named :env) #'gdev-debug--perl-environment))))
      (delete-directory root t))))

(provide 'gdev-perl-debug-test)
;;; gdev-perl-debug-test.el ends here
