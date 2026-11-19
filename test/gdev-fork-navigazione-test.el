;;; gdev-fork-navigazione-test.el --- Regressioni di ricerca e navigazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Conserva l'associazione delle modifiche ai risultati di ricerca e la
;; precedenza degli stati Git ricevuti in più blocchi da Dired.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defvar diff-hl-dired-extra-indicators)
(defvar diff-hl-dired-process-buffer)

(ert-deftest gdev-fork-wgrep-keeps-order-and-reports-each-rejected-edit ()
  "Le modifiche divise fra più gruppi conservano ordine e segnalazioni."
  (require 'wgrep (expand-file-name "wgrep" (gdev-bundled-package-directory 'wgrep)))
  (with-temp-buffer
    (let* ((first-error (make-overlay (point) (point)))
           (second-error (make-overlay (point) (point)))
           (first '(1 "prima" "nuova prima"))
           (second '(3 "seconda" "nuova seconda"))
           (other '(2 "altra" "nuova altra"))
           (editors (list (list "fonte.txt" first)
                          (list "mancante.txt" (list 1 "x" "y" first-error))
                          (list "altro.txt" other)
                          (list (copy-sequence "fonte.txt") second)
                          (list (copy-sequence "mancante.txt")
                                (list 4 "p" "q" second-error)))))
      (cl-letf (((symbol-function 'wgrep-gather-editor) (lambda () editors))
                ((symbol-function 'wgrep-check-file)
                 (lambda (file)
                   (when (equal file "mancante.txt")
                     (signal 'wgrep-error '("File mancante"))))))
        (let ((transaction (wgrep-compute-transaction)))
          (should (equal transaction (list (list "fonte.txt" first second)
                                           (list "altro.txt" other))))
          (should (eq (nth 1 (car transaction)) first))
          (should (eq (nth 2 (car transaction)) second))))
      (dolist (overlay (list first-error second-error))
        (should (eq (overlay-get overlay 'face) 'wgrep-reject-face))
        (should (equal (overlay-get overlay 'wgrep-reject-message) "File mancante"))))))

(ert-deftest gdev-fork-wgrep-keeps-line-positions-with-narrowing ()
  "Righe duplicate, fuori ordine o oltre l'ultima mantengono la posizione."
  (require 'wgrep (expand-file-name "wgrep" (gdev-bundled-package-directory 'wgrep)))
  (with-temp-buffer
    (insert "xxprima\n\nterza\nultimaZZ")
    (narrow-to-region (+ (point-min) 2) (- (point-max) 2))
    (let* ((lines '(1 2 2 4 5 9 3 1 0 2 4))
           (edits (mapcar #'list lines))
           (expected (mapcar (lambda (line) (wgrep-goto-line line) (point)) lines)))
      (wgrep-compute-linum-to-marker edits)
      (should (equal (mapcar (lambda (edit) (marker-position (car edit))) edits)
                     expected)))))

(ert-deftest gdev-fork-diff-hl-merges-partial-dired-statuses ()
  "Dired pubblica gli stati una volta sola e conserva la precedenza."
  (let ((load-path (cons (gdev-bundled-package-directory 'diff-hl) load-path)))
    (require 'diff-hl-dired))
  (with-temp-buffer
    (let ((directory-buffer (current-buffer))
          (diff-hl-dired-extra-indicators nil)
          callback updates)
      (setq-local diff-hl-dired-process-buffer nil)
      (cl-letf (((symbol-function 'vc-responsible-backend) (lambda (&rest _) 'Git))
                ((symbol-function 'diff-hl-dired-status-files)
                 (lambda (_backend _directory _files update) (setq callback update)))
                ((symbol-function 'diff-hl-dired-highlight-items)
                 (lambda (statuses)
                   (should (eq (current-buffer) directory-buffer))
                   (push statuses updates))))
        (unwind-protect
            (progn
              (diff-hl-dired-update)
              (with-current-buffer diff-hl-dired-process-buffer
                (funcall callback '(("fonte/sotto/ignorato" ignored) ("sola/inserito" added)) t)
                (funcall callback '(("fonte/sotto/modificato" edited) ("sola/ignorato" ignored)) t)
                (should-not updates)
                (funcall callback '(("fonte/sotto/aggiunto" added)) nil))
              (should (equal updates
                             '((("sola" . insert) ("fonte/sotto" . change) ("fonte" . change)
                                ("fonte/sotto/aggiunto" . insert) ("sola/ignorato" . ignored)
                                ("fonte/sotto/modificato" . change) ("sola/inserito" . insert)
                                ("fonte/sotto/ignorato" . ignored)))))
              (should-not (buffer-live-p diff-hl-dired-process-buffer)))
          (when (buffer-live-p diff-hl-dired-process-buffer)
            (kill-buffer diff-hl-dired-process-buffer)))))))

(provide 'gdev-fork-navigazione-test)
;;; gdev-fork-navigazione-test.el ends here
