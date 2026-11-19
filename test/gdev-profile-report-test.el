;;; gdev-profile-report-test.el --- Rapporto delle misurazioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Code:

(require 'ert)
(require 'gdev-lib)
(require 'gdev-profile-report
         (gdev-config-file "modules/tools/profiler/gdev-profile-report.el"))

(ert-deftest gdev-profile-report-test-ranking-and-values ()
  "Ordina i comandi e mantiene il valore originale di ogni durata."
  (let ((data '((results . (((command . "lento") (mean . 0.025))
                            ((command . "veloce") (mean . 6.1234567e-6) (stddev . 0)
                             (median . 6.2e-6) (times 6.1234567e-6 6.2e-6))
                            ((command . "secondo") (mean . 6.1234567e-6))))))
        report)
    (unwind-protect
        (save-window-excursion
          (setq report (gdev-profile-report-benchmarks data default-directory))
          (with-current-buffer report
            (should (eq gdev-ui-view-profile 'document))
            (should (gdev-layout-document-tab-p report))
            (should (eq (gdev-layout--role report) 'editor))
            (should buffer-read-only)
            (goto-char (point-min))
            (should (re-search-forward "^veloce$" nil t))
            (should (search-forward "6.12346 µs" nil t))
            (should (equal (get-text-property (1- (point)) 'help-echo) "6.1234567e-06 s"))
            (should (search-forward "2 esecuzioni" nil t))
            (should (re-search-forward "^secondo$" nil t))
            (should (re-search-forward "^lento$" nil t))
            (let* ((bars (reverse gdev-profile-report--bars))
                   (fast (get-text-property (caar bars) 'display))
                   (slow (get-text-property (caar (last bars)) 'display)))
              (should (> (length fast) 0))
              (should (> (length slow) (length fast))))))
      (when (buffer-live-p report) (kill-buffer report)))))

(ert-deftest gdev-profile-report-test-empty-and-output-from-keyboard ()
  "Il documento vuoto resta leggibile e la sua azione risponde da tastiera."
  (let ((output (generate-new-buffer "*Output misurazione di prova*")) report)
    (unwind-protect
        (save-window-excursion
          (setq report (gdev-profile-report-benchmarks nil default-directory output))
          (goto-char (point-min))
          (should-not gdev-profile-report--bars)
          (should (string-search "Nessuna misurazione disponibile" (buffer-string)))
          (execute-kbd-macro (kbd "TAB"))
          (should (equal (button-label (button-at (point))) "Apri output"))
          (execute-kbd-macro (kbd "RET"))
          (should (eq (current-buffer) output)))
      (when (buffer-live-p report) (kill-buffer report))
      (kill-buffer output))))

(ert-deftest gdev-profile-report-test-hyperfine-v2-wall-clock ()
  "Usa i tempi trascorsi di hyperfine 2 anche quando vengono esportati tempi CPU."
  (let ((data '((schema_version . 2)
                (results . (((command . "prima")
                             (summary (time_cpu (mean . 0.0008))
                                      (time_wall_clock (count . 10) (mean . 0.03))))
                            ((command . "seconda")
                             (summary (time_cpu (mean . 0.0015))
                                      (time_wall_clock (count . 10) (mean . 0.01)))))))))
    (let ((results (gdev-profile-report--results data)))
      (should (equal (mapcar (lambda (result) (alist-get 'command result)) results)
                     '("seconda" "prima")))
      (should (= (alist-get 'count (car results)) 10))
      (should (= (alist-get 'mean (car results)) 0.01)))))

(provide 'gdev-profile-report-test)
;;; gdev-profile-report-test.el ends here
