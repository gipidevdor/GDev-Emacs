;;; gdev-procedure-worker.el --- Processo ERT isolato delle procedure -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Caricato soltanto dal comando esplicito progetto-test-ert.
;;; Code:
(require 'ert)
(require 'json)
(require 'seq)
(setq load-prefer-newer t)
(load (getenv "GDEV_PROCEDURE_TEST") nil nil t)
(let* ((selector (getenv "GDEV_PROCEDURE_SELECTOR"))
       (selected (ert-select-tests selector t))
       (stats (ert-run-tests-batch selector))
       (passed (seq-filter (lambda (test) (ert-test-passed-p (ert-test-most-recent-result test))) selected))
       (skipped (seq-filter (lambda (test) (ert-test-skipped-p (ert-test-most-recent-result test))) selected))
       (ok (and passed (zerop (ert-stats-completed-unexpected stats))))
       (report `((name . "ert") (ok . ,(if ok t :false)) (status . ,(if ok "PASSED" "FAILED"))
                 (selected . ,(length selected))
                 (passed . ,(vconcat (mapcar (lambda (test) (symbol-name (ert-test-name test))) passed)))
                 (skipped . ,(vconcat (mapcar (lambda (test) (symbol-name (ert-test-name test))) skipped)))))
       (bytes (json-serialize report :false-object :false)))
  (with-temp-buffer
    (set-buffer-multibyte nil) (insert bytes)
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) (getenv "GDEV_PROCEDURE_RESULT") nil 'silent)))
  (kill-emacs (if ok 0 1)))
;;; gdev-procedure-worker.el ends here
