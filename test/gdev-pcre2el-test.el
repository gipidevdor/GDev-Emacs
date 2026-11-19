;;; gdev-pcre2el-test.el --- Contratto del convertitore regex -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Verifica la modifica dei flag senza sostituire il prompt protetto.
;;; Code:
(require 'ert)
(require 'cl-lib)

(ert-deftest gdev-test-pcre2el-local-fork-preserves-prompt-text-and-cursor-on-flag-changes ()
  (require 'package)
  (package-activate-all)
  (require 'pcre2el)
  (should (string-prefix-p (file-truename (gdev-config-file "vendor/elpa/pcre2el-1.12/"))
                           (file-truename (symbol-file 'rxt--toggle-flag-minibuffer 'defun))))
  (dolist (case '(("Prova à[0-9]+" ?i "(?i)Prova à[0-9]+")
                  ("(?i)Prova à[0-9]+" ?i "Prova à[0-9]+")
                  ("(?s)Prova à[0-9]+" ?i "(?is)Prova à[0-9]+")
                  ("(?is)Prova à[0-9]+" ?s "(?i)Prova à[0-9]+")))
    (dolist (cursor '(start middle end))
      (with-temp-buffer
        (insert (propertize "Espressione: " 'read-only t 'front-sticky t 'rear-nonsticky t))
        (let ((start (point)))
          (insert (car case))
          (goto-char (pcase cursor ('start start) ('middle (+ start 3)) ('end (point-max))))
          (cl-letf (((symbol-function 'minibuffer-prompt-end) (lambda () start))
                    ((symbol-function 'minibuffer-contents) (lambda () (buffer-substring-no-properties start (point-max)))))
            (rxt--toggle-flag-minibuffer (cadr case)))
          (should (equal (concat "Espressione: " (nth 2 case)) (buffer-string)))
          (should (get-text-property (point-min) 'read-only))
          (should (<= start (point) (point-max)))
          (when (eq cursor 'end) (should (= (point) (point-max)))))))))

;;; gdev-pcre2el-test.el ends here
