;;; gdev-performance-test.el --- Regressioni dei percorsi ottimizzati -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'equivalenza con i percorsi Emacs e il limite dei processi CLI.

;;; Code:

(require 'ert)
(require 'gdev-commands)

(ert-deftest gdev-test-quick-open-bulk-paths-keep-emacs-relative-names ()
  "I nomi espansi in blocco coincidono con quelli calcolati singolarmente."
  (let* ((base (file-name-as-directory (make-temp-file "gdev-path-test-" t)))
         (active (expand-file-name "uno/" base))
         (other (expand-file-name "due/" base))
         (nested (expand-file-name "interno/" active))
         (names (list "è con spazi.el" "due\nrighe.el" "uno/file.el" "./src/file.el"
                      "interno/../file.el" "src//file.el" "../file.el" "" "~/file.el"
                      (expand-file-name "assoluto.el" base))))
    (unwind-protect
        (progn
          (make-directory nested t)
          (make-directory other)
          (dolist (root (list active other nested base))
            (should (equal (gdev-quick-open--candidate-names names root active)
                           (mapcar (lambda (name)
                                     (file-relative-name (expand-file-name name root) active))
                                   names))))
          (should-not (gdev-quick-open--candidate-names nil other active)))
      (delete-directory base t))))

(ert-deftest gdev-test-cli-job-count-is-bounded-and-configurable ()
  "La CLI usa le CPU disponibili e accetta un limite positivo esplicito."
  (load (gdev-config-file "lisp/gdev-cli.el") nil t t)
  (let ((process-environment (copy-sequence process-environment))
        (processors 1))
    (cl-letf (((symbol-function 'num-processors) (lambda (&rest _) processors)))
      (setenv "GDEV_JOBS" nil)
      (should (= (gdev-cli--jobs) 1))
      (setq processors 2)
      (should (= (gdev-cli--jobs) 2))
      (setq processors 10)
      (should (= (gdev-cli--jobs) 4))
      (setenv "GDEV_JOBS" "1")
      (should (= (gdev-cli--jobs) 1))
      (setenv "GDEV_JOBS" "20")
      (should (= (gdev-cli--jobs) 10))
      (setenv "GDEV_JOBS" "0")
      (should-error (gdev-cli--jobs) :type 'user-error))))

(provide 'gdev-performance-test)
;;; gdev-performance-test.el ends here
