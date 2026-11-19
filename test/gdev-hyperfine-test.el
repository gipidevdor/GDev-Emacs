;;; gdev-hyperfine-test.el --- Ciclo di vita delle misure Hyperfine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; L'uscita del processo conserva il rapporto utile e rimuove l'esportazione
;; temporanea anche quando una misurazione fallisce o viene annullata.

;;; Code:

(require 'ert)
(require 'gdev-modules)

(ert-deftest gdev-hyperfine-test-reports-success-and-removes-exports ()
  (skip-unless (and (not gdev-windows-p) (executable-find "hyperfine")))
  (unless (fboundp 'gdev-profile-hyperfine)
    (load (gdev-module-file :tools 'profiler ".el") nil t))
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "gdev-benchmark-test-" t))))
         (default-directory root)
         (temporary-file-directory root)
         (compilation-ask-about-save nil)
         reports output)
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-project-root) (lambda (&optional _directory) root))
                  ((symbol-function 'gdev-profile-report-benchmarks)
                   (lambda (data directory origin)
                     (push (list data directory origin) reports))))
          (dolist (run '((success . "sleep 0.01 && true") (failure . "false") (cancel . "sleep 20")))
            (setq output (gdev-profile-hyperfine (cdr run)))
            (let ((job (get-buffer-process output))
                  (export-directory (car (directory-files root t "^gdev-hyperfine-")))
                  (deadline (+ (float-time) 15)))
              (should (and export-directory (file-directory-p export-directory)))
              (when (eq (car run) 'cancel)
                (let ((kill-buffer-query-functions nil)) (kill-buffer output)))
              (while (and (or (process-live-p job) (file-exists-p export-directory))
                          (< (float-time) deadline))
                (accept-process-output nil 0.05))
              (should-not (process-live-p job))
              (should-not (file-exists-p export-directory))
              (should (= (length reports) 1))
              (should (equal (alist-get 'command (car (alist-get 'results (caar reports))))
                             "sleep 0.01 && true"))
              (should (equal (nth 1 (car reports)) root)))))
      (when (buffer-live-p output)
        (let ((kill-buffer-query-functions nil)) (kill-buffer output)))
      (delete-directory root t))))

(provide 'gdev-hyperfine-test)
;;; gdev-hyperfine-test.el ends here
