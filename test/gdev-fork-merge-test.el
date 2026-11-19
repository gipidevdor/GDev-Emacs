;;; gdev-fork-merge-test.el --- Integrazione isolata dei fork -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica un merge pulito e uno con un conflitto sulle stesse sorgenti.

;;; Code:

(require 'ert)
(require 'gdev-fork-merge)
(require 'gdev-lib)

(defun gdev-fork-merge-test--write (directory name content)
  "Crea NAME con CONTENT in DIRECTORY."
  (with-temp-file (expand-file-name name directory) (insert content)))

(ert-deftest gdev-fork-merge-preserves-local-edits-and-reports-conflicts ()
  "Git conserva la personalizzazione attraverso una rinomina e segnala le modifiche concorrenti."
  (skip-unless (executable-find "git"))
  (let* ((scratch (make-temp-file "gdev-fork-test-" t))
         (gdev-config-directory (file-name-as-directory (expand-file-name "checkout" scratch)))
         (gdev-bundled-packages '((prova "1.0" "GPL-3.0-or-later")))
         (fork (gdev-bundled-package-directory 'prova))
         (original (expand-file-name "base a monte" scratch))
         (incoming (expand-file-name "nuovo rilascio" scratch))
         (temporary-file-directory (file-name-as-directory scratch))
         (stable (mapconcat (lambda (i) (format "riga invariata %d\n" i)) (number-sequence 1 12)))
         (base (concat "Testo a monte\n" stable "Valore originale\n"))
         (local (concat "Testo GDev\n" stable "Valore originale\n"))
         (remote (concat "Testo a monte\n" stable "Nuovo valore\n")))
    (unwind-protect
        (progn
          (dolist (folder (list original incoming fork)) (make-directory folder t))
          (gdev-fork-merge-test--write original "motore.el" base)
          (gdev-fork-merge-test--write original "obsoleto.el" "contenuto")
          (gdev-fork-merge-test--write fork "motore.el" local)
          (gdev-fork-merge-test--write fork "obsoleto.el" "contenuto")
          (gdev-fork-merge-test--write fork "GDEV.md" "Modifica GDev, 2026-11-15\n")
          (gdev-fork-merge-test--write fork "motore.elc" "compilato")
          (gdev-fork-merge-test--write incoming "motore-nuovo.el" remote)
          (let* ((preview (gdev-fork-merge "prova" original incoming))
                 (merged (car preview)))
            (should-not (cdr preview))
            (should (equal (gdev-read-file-contents (expand-file-name "motore-nuovo.el" merged))
                           (concat "Testo GDev\n" stable "Nuovo valore\n")))
            (should (file-exists-p (expand-file-name "GDEV.md" merged)))
            (should-not (file-exists-p (expand-file-name "obsoleto.el" merged)))
            (should-not (file-exists-p (expand-file-name "motore.elc" merged))))
          (delete-file (expand-file-name "motore-nuovo.el" incoming))
          (gdev-fork-merge-test--write incoming "motore.el" (concat "Testo modificato a monte\n" stable))
          (let* ((preview (gdev-fork-merge "prova" original incoming))
                 (merged (gdev-read-file-contents (expand-file-name "motore.el" (car preview)))))
            (should (equal (cdr preview) '("motore.el")))
            (dolist (value '("Testo GDev" "Testo a monte" "Testo modificato a monte"))
              (should (string-search value merged))))
          (should (equal (gdev-read-file-contents (expand-file-name "motore.el" fork)) local))
          (should (equal (gdev-read-file-contents (expand-file-name "motore.el" original)) base)))
      (delete-directory scratch t))))

(provide 'gdev-fork-merge-test)
;;; gdev-fork-merge-test.el ends here
