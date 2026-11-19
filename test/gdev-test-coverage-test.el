;;; gdev-test-coverage-test.el --- Prove del rapporto di copertura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)

(ert-deftest gdev-test-coverage-lcov-merges-sections-and-preserves-unmeasured-lines ()
  "La copertura conta righe distinte e lascia fuori le righe senza dati."
  (require 'gdev-test-coverage)
  (let* ((root (make-temp-file "gdev-copertura-parser-" t))
         (path (expand-file-name "copertura.info" root))
         (a (expand-file-name "src/file con spazi.c" root))
         (b (expand-file-name "altro.c" root)))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "TN:prima\nSF:src/file con spazi.c\nDA:3,0\nDA:1,4,abc\nDA:0,3\n")
            (insert "BRDA:3,1,1,4\nLH:42\nend_of_record\n")
            (insert (format "TN:seconda\nSF:%s\nDA:3,2\nDA:8,0\nend_of_record\n" a))
            (insert (format "DA:9,10\nSF:%s\nDA:2,0\nend_of_record\n" b)))
          (let* ((report (gdev-test-coverage--read path root))
                 (first (gdev-test-coverage--file-data report a))
                 (second (gdev-test-coverage--file-data report b)))
            (should (= (gdev-test-coverage--report-total report) 4))
            (should (= (gdev-test-coverage--report-covered report) 2))
            (should (equal (gdev-test-coverage--file-lines first) [(1 . t) (3 . t) (8)]))
            (should (equal (gdev-test-coverage--file-lines second) [(2)]))
            (should (= (gdev-test-coverage--lower-bound (gdev-test-coverage--file-lines first) 7) 2)))
          (with-temp-file path (insert "Rapporto estraneo\n"))
          (should-error (gdev-test-coverage--read path root) :type 'user-error))
      (delete-directory root t))))

(ert-deftest gdev-test-coverage-publishes-to-origin-without-focusing-or-reopening ()
  "Una risposta di copertura aggiorna solo lo spazio che l'ha richiesta."
  (require 'gdev-test-coverage)
  (gdev-test--with-layout
    (let* ((frame (selected-frame))
           (owner (gdev-workspace-state-ensure-id frame))
           (root (make-temp-file "gdev-copertura-origine-" t))
           (report (expand-file-name "copertura.info" root)))
      (unwind-protect
          (progn
            (with-temp-file report (insert "SF:a.c\nDA:1,0\nend_of_record\n"))
            (tab-bar-new-tab)
            (let ((selected (selected-window)))
              (should (gdev-test-coverage-publish report root owner frame))
              (should (eq selected (selected-window)))
              (should-not (gdev-workspace-state-get 'gdev-test-coverage-reports frame))
              (should (= 1 (length (gdev-workspace-state-read 'gdev-test-coverage-reports
                                                              (gdev-workspace-state-find owner frame)))))
              (tab-bar-select-tab 1)
              (tab-bar-close-tab)
              (should-not (gdev-test-coverage-publish "/rapporto-assente.info" root owner frame))))
        (delete-directory root t)))))

(ert-deftest gdev-test-coverage-gutter-is-scoped-cached-and-released-on-edit ()
  "Il margine mantiene l'impaginazione, limita le righe e scade alla modifica."
  (require 'gdev-test-coverage)
  (gdev-test--with-layout
    (let* ((root (make-temp-file "gdev-copertura-margine-" t))
           (path (expand-file-name "sorgente.txt" root))
           (report (expand-file-name "copertura.info" root))
           (frame (selected-frame))
           (window (gdev-layout-editor))
           (gdev-test-coverage--painted (make-hash-table :test #'eq))
           buffer)
      (unwind-protect
          (progn
            (with-temp-file path (dotimes (i 400) (insert (format "Riga %d\n" (1+ i)))))
            (with-temp-file report
              (insert "SF:sorgente.txt\n")
              (dotimes (i 400) (insert (format "DA:%d,%d\n" (1+ i) (% i 2))))
              (insert "end_of_record\n"))
            (setq buffer (find-file-noselect path))
            (set-window-buffer window buffer)
            (set-window-margins window 1 3)
            (gdev-test-coverage-publish report root (gdev-workspace-state-ensure-id frame) frame)
            (gdev-test-coverage--paint-window window (with-current-buffer buffer (point-min)))
            (let* ((paint (gethash window gdev-test-coverage--painted))
                   (overlays (gdev-test-coverage--paint-overlays paint)))
              (should paint)
              (should (<= (length overlays) (+ 2 (window-body-height window))))
              (should (> (length overlays) 2))
              (should (equal (window-margins window) '(1 . 4)))
              (should (cl-every (lambda (ov) (eq (overlay-get ov 'window) window)) overlays))
              (gdev-test-coverage--paint-window window (with-current-buffer buffer (point-min)))
              (should (eq paint (gethash window gdev-test-coverage--painted)))
              (with-current-buffer buffer (insert "modifica"))
              (should-not (gethash window gdev-test-coverage--painted))
              (should (equal (window-margins window) '(1 . 3)))))
        (gdev-test-coverage--clear-window window)
        (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
        (delete-directory root t)))))

(defun gdev-test-coverage--test-button (id)
  "Restituisci il pulsante della vista con identità ID."
  (let ((button (next-button (point-min) t)))
    (while (and button (not (equal id (button-get button 'gdev-test-coverage-id))))
      (setq button (next-button (button-end button))))
    button))

(ert-deftest gdev-test-coverage-file-and-line-actions-use-the-active-editor ()
  "Selezionare un file o una riga raggiunge sempre l'identità indicata."
  (require 'gdev-test-coverage)
  (gdev-test--with-layout
    (let* ((root (file-truename (make-temp-file "gdev-copertura-vista-" t)))
           (first (expand-file-name "a.txt" root))
           (second (expand-file-name "b.txt" root))
           (report (expand-file-name "copertura.info" root))
           (gdev-test-coverage--painted (make-hash-table :test #'eq))
           pane)
      (unwind-protect
          (progn
            (dolist (file (list first second))
              (with-temp-file file (insert "Prima\nSeconda\nTerza\n")))
            (with-temp-file report
              (insert "SF:a.txt\nDA:1,0\nDA:2,1\nend_of_record\nSF:b.txt\nDA:1,1\nend_of_record\n"))
            (gdev-test-coverage-publish report root (gdev-workspace-state-ensure-id) (selected-frame))
            (gdev-test-coverage-show root)
            (setq pane (current-buffer))
            (should (derived-mode-p 'gdev-test-coverage-mode))
            (should (string-search "2 di 3 righe" (buffer-string)))
            (button-activate (gdev-test-coverage--test-button first))
            (should (equal gdev-test-coverage--selected-file first))
            (should (string-search "! Riga 1 · mai eseguita" (buffer-string)))
            (button-activate (gdev-test-coverage--test-button 2))
            (should (eq (selected-window) (gdev-layout-editor)))
            (should (file-equal-p buffer-file-name first))
            (should (= (line-number-at-pos) 2)))
        (maphash (lambda (window _) (gdev-test-coverage--clear-window window)) gdev-test-coverage--painted)
        (when (buffer-live-p pane) (kill-buffer pane))
        (dolist (file (list first second))
          (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer)))
        (delete-directory root t)))))

(provide 'gdev-test-coverage-test)
;;; gdev-test-coverage-test.el ends here
