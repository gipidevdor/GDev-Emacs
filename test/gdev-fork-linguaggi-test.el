;;; gdev-fork-linguaggi-test.el --- Regressioni dei fork per i linguaggi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'ordine delle sequenze YAML, il rientro HCL e la
;; colorazione dei nomi delle librerie di Swift.

;;; Code:

(require 'ert)

(defvar swift-mode:highlight-symbols-in-standard-library)
(defvar swift-mode:highlight-symbols-in-foundation-framework)
(defvar terraform-indent-level)

(ert-deftest gdev-test-fork-yaml-preserves-sequence-order-across-aliases ()
  "Le sequenze miste conservano l'ordine anche dopo la risoluzione degli alias."
  (package-activate-all)
  (require 'yaml)
  (let* ((source "base: &base [x, y, z]
refs:
  - *base
  - - one
    - two
  - fin
")
         (as-lists (yaml-parse-string source :sequence-type 'list))
         (as-arrays (yaml-parse-string source :sequence-type 'array)))
    (should (equal (gethash 'base as-lists) '("x" "y" "z")))
    (should (equal (gethash 'refs as-lists) '(("x" "y" "z") ("one" "two") "fin")))
    (should (equal (gethash 'base as-arrays) ["x" "y" "z"]))
    (should (equal (gethash 'refs as-arrays) [["x" "y" "z"] ["one" "two"] "fin"]))))

(ert-deftest gdev-test-fork-terraform-indents-relative-to-enclosing-line ()
  "Il comando di rientro usa la riga del delimitatore e conserva il testo dei blocchi letterali."
  (package-activate-all)
  (require 'terraform-mode)
  (with-temp-buffer
    (insert "resource \"type\" \"name\" {
values = [
1,
]
object = { inline = true }
text = <<EOT
{ inside literal }
EOT
}
")
    (let ((terraform-indent-level 2))
      (terraform-mode))
    (let ((inhibit-message t))
      (indent-region (point-min) (point-max)))
    (should (equal (buffer-string)
                   "resource \"type\" \"name\" {
  values = [
    1,
  ]
  object = { inline = true }
  text = <<EOT
{ inside literal }
EOT
}
"))
    (goto-char (point-min))
    (search-forward "inline")
    (let ((original-point (point)))
      (save-restriction
        (narrow-to-region (1+ (line-beginning-position)) (point-max))
        (put-text-property (- (point) (length "inline")) (line-end-position)
                           'field 'gdev-fixture)
        (should-not (hcl--block-indentation))
        (should (= (point) original-point)))))
  (with-temp-buffer
    (hcl-mode)
    (insert "  outer {\rvalue\r}")
    (goto-char (point-min))
    (search-forward "value")
    (should-not (hcl--block-indentation))
    (let ((selective-display t))
      (should (= (hcl--block-indentation) 2)))))

(ert-deftest gdev-test-fork-swift-fontifies-configured-libraries ()
  "Le due opzioni di Swift governano anche le ricerche con una sola libreria."
  (package-activate-all)
  (require 'swift-mode)
  (dolist (standard '(nil t))
    (dolist (foundation '(nil t))
      (with-temp-buffer
        (insert "let a: Never\nlet b: UUID\nlet c: String\n// String UUID\n")
        (let ((swift-mode:highlight-symbols-in-standard-library standard)
              (swift-mode:highlight-symbols-in-foundation-framework foundation))
          (swift-mode)
          (font-lock-ensure (point-min) (point-max)))
        (goto-char (point-min))
        (search-forward "Never")
        (should (eq (eq (get-text-property (1- (point)) 'face)
                        'swift-mode:builtin-type-face)
                    standard))
        (search-forward "UUID")
        (should (eq (eq (get-text-property (1- (point)) 'face)
                        'swift-mode:builtin-type-face)
                    foundation))
        (search-forward "String")
        (should (eq (eq (get-text-property (1- (point)) 'face)
                        'swift-mode:builtin-type-face)
                    (or standard foundation)))
        (search-forward "String")
        (should-not (eq (get-text-property (1- (point)) 'face)
                        'swift-mode:builtin-type-face))))))

(provide 'gdev-fork-linguaggi-test)
;;; gdev-fork-linguaggi-test.el ends here
