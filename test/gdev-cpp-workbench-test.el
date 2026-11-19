;;; gdev-cpp-workbench-test.el --- Prove C++ nel riquadro Test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica il passo iniziale, l'identità delle azioni e la selezione CTest.

;;; Code:

(require 'ert)
(require 'gdev-project-view)

(ert-deftest gdev-cpp-test-panel-offers-configure-and-keeps-action ()
  "Un progetto CMake vuoto offre la configurazione e conserva il fuoco sul pulsante."
  (let ((root (file-name-as-directory (make-temp-file "gdev-ctest-view-" t))))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file (expand-file-name "CMakeLists.txt" root))
          (gdev-project-view-mode)
          (setq-local gdev-project-view--root root
                      gdev-activity-kind 'test)
          (cl-letf (((symbol-function 'gdev-build-configure) (lambda () (interactive)))
                    ((symbol-function 'gdev-build) (lambda () (interactive))))
            (gdev-project-view--render)
            (should-not truncate-lines)
            (goto-char (point-min))
            (should (search-forward "Configura CMake per rilevare i test" nil t))
            (let ((button (next-button (point))))
              (should (eq (button-get button 'gdev-project-view-id) 'configure))
              (should (eq (button-get button 'face) 'gdev-ui-action-primary))
              (goto-char (button-start button)))
            (setq gdev-project-view--status "Nuovo stato con una lunghezza diversa")
            (gdev-project-view--render)
            (should (eq (button-get (button-at (point)) 'gdev-project-view-id) 'configure))))
      (delete-directory root t))))

(ert-deftest gdev-cpp-ctest-selects-exact-names ()
  "CTest seleziona per nome letterale, anche dopo aver filtrato il catalogo."
  (skip-unless (executable-find "ctest"))
  (let* ((root (file-name-as-directory (make-temp-file "gdev-ctest-selection-" t)))
         (default-directory root)
         (name "renderer [fast] + c++ (debug)"))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "CTestTestfile.cmake" root)
            (insert "add_test(\"altro\" \"cmake\" \"-E\" \"true\")\n"
                    "add_test(\"" name "\" \"cmake\" \"-E\" \"true\")\n"))
          (with-temp-buffer
            (should (= 0 (apply #'call-process "ctest" nil t nil "--show-only=json-v1"
                                (gdev-project-view--ctest-selection (list name)))))
            (let ((hits (gdev-project-view--ctest-parse (buffer-string) root)))
              (should (equal (mapcar (lambda (test) (alist-get 'name test)) hits) (list name))))))
      (delete-directory root t))))

(ert-deftest gdev-cpp-process-charts-track-both-metrics ()
  "I grafici conservano lo stesso intervallo per CPU e memoria residente."
  (with-temp-buffer
    (dotimes (index 16)
      (gdev-debug-workbench--accept-sample (list (* index 20) (* index 1024) "avvio")))
    (should (= (length gdev-debug-workbench--cpu-history) 12))
    (should (= (length gdev-debug-workbench--rss-history) 12))
    (should (= (car gdev-debug-workbench--cpu-history) 300))
    (should (= (car gdev-debug-workbench--rss-history) 15360))
    (should (equal (gdev-debug-workbench--sparkline '(300 150 0) 300) "·▄█"))
    (gdev-debug-workbench--sample-process nil)
    (setq gdev-debug-workbench--target '(123 . manual))
    (gdev-debug-workbench--sample-process nil)
    (should-not gdev-debug-workbench--cpu-history)
    (should-not gdev-debug-workbench--rss-history)))

(ert-deftest gdev-cpp-ctest-and-build-reserve-the-same-directory ()
  "CTest e Compila condividono il vincolo, lasciando libere le altre cartelle."
  (gdev-test-launch--load-tools)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-ctest-build-" t)))
         (first (expand-file-name "build-uno/" root))
         (second (expand-file-name "build-due/" root))
         (alias (expand-file-name "alias/" root))
         (resource first)
         (view (generate-new-buffer " *verifica CTest*"))
         (gdev-build--active nil)
         ctest first-build second-build)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-buffer
            (setq default-directory root)
            (set-window-buffer (gdev-layout-editor) (current-buffer))
            (make-directory first)
            (make-directory second)
            (make-symbolic-link (directory-file-name first) (directory-file-name alias))
            (with-temp-file (expand-file-name "CMakeLists.txt" root))
            (with-current-buffer view
              (setq-local gdev-project-view--root root
                          gdev-project-view--test-provider 'ctest
                          gdev-project-view--test-dir alias
                          gdev-project-view--test-build-command "/bin/sleep 8"
                          gdev-project-view--lines '(test)))
            (cl-letf (((symbol-function 'gdev-project-view-sync) #'ignore)
                      ((symbol-function 'gdev-project-view--render) #'ignore)
                      ((symbol-function 'gdev-cmake--context)
                       (lambda (&rest _) (list :directory resource)))
                      ((symbol-function 'gdev-cmake--command)
                       (lambda (&rest _) "/bin/sleep 8")))
              (with-current-buffer view
                (gdev-project-view--test nil)
                (setq ctest gdev-project-view--test-run))
              (should (process-live-p (get-buffer-process ctest)))
              (should-error (gdev-build) :type 'user-error)
              (setq resource second
                    second-build (gdev-build))
              (should (process-live-p (get-buffer-process second-build)))
              (should (process-live-p (get-buffer-process ctest)))
              (delete-process (get-buffer-process ctest))
              (setq resource first
                    first-build (gdev-build))
              (should (process-live-p (get-buffer-process first-build)))
              (should (process-live-p (get-buffer-process second-build)))
              (with-current-buffer ctest
                (should-error (recompile) :type 'user-error))
              (with-current-buffer view
                (should-error (gdev-project-view--test nil) :type 'user-error)))))
      (dolist (buffer (delete-dups (list ctest first-build second-build view)))
        (when (buffer-live-p buffer)
          (when-let* ((process (get-buffer-process buffer)))
            (delete-process process))
          (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest gdev-cpp-ctest-panel-records-failure-and-retries-only-failed-tests ()
  "Il pannello CTest distingue build fallita, esiti parziali e ripetizione mirata."
  (gdev-test-launch--load-tools)
  (skip-unless (and (executable-find "ctest") (executable-find "cmake")))
  (let* ((root (file-name-as-directory (make-temp-file "gdev-ctest-outcome-" t)))
         (directory (expand-file-name "build/" root))
         (view (generate-new-buffer " *verifica esiti CTest*"))
         (pass "riesce")
         (fail "fallisce [misto]")
         output)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-buffer
            (setq default-directory root)
            (setq-local process-environment (cons "LC_ALL=C" process-environment))
            (set-window-buffer (gdev-layout-editor) (current-buffer))
            (make-directory directory)
            (with-temp-file (expand-file-name "CMakeLists.txt" root))
            (with-temp-file (expand-file-name "CTestTestfile.cmake" directory)
              (insert (format "add_test(\"%s\" \"cmake\" \"-E\" \"true\")\n" pass)
                      (format "add_test(\"%s\" \"cmake\" \"-E\" \"false\")\n" fail)))
            (with-current-buffer view
              (gdev-project-view-mode)
              (setq-local gdev-activity-kind 'test
                          gdev-project-view--root root
                          gdev-project-view--results (make-hash-table :test #'equal))
              (cl-letf (((symbol-function 'gdev-project-view-sync) #'ignore))
                (gdev-project-view--test-refresh (list :directory directory :build-command "exit 7"))
                (gdev-test-launch--wait (lambda () (eq gdev-project-view--test-provider 'ctest)))
                (should (equal (mapcar (lambda (test) (alist-get 'name test))
                                       gdev-project-view--lines)
                               (list pass fail)))
                (let ((compilation-in-progress nil)
                      (compilation-start-hook
                       (cons #'gdev-test-launch--finish-in-start-hook compilation-start-hook)))
                  (call-interactively #'gdev-project-view-test-all))
                (setq output gdev-project-view--test-run)
                (should-not (get-buffer-process output))
                (should (equal gdev-project-view--status "Consulta l’output dei test"))
                (should (= (hash-table-count gdev-project-view--results) 0))
                (should-error (gdev-project-view-test-failed) :type 'user-error)
                (with-current-buffer output
                  (should (string-search "codice 7" (buffer-string)))
                  (should-not (string-search "Test project " (buffer-string))))
                (setq gdev-project-view--test-build-command "true")
                (call-interactively #'gdev-project-view-test-all)
                (gdev-test-launch--wait
                 (lambda () (equal gdev-project-view--status "Esecuzione terminata · 2 esiti")))
                (should (equal (gethash pass gdev-project-view--results) "Passato"))
                (should (equal (gethash fail gdev-project-view--results) "Fallito"))
                (call-interactively #'gdev-project-view-test-failed)
                (gdev-test-launch--wait
                 (lambda () (equal gdev-project-view--status "Esecuzione terminata · 1 esito")))
                (should (equal (gethash pass gdev-project-view--results) "Passato"))
                (should (equal (gethash fail gdev-project-view--results) "Fallito"))
                (with-current-buffer output
                  (let ((results (gdev-project-view--ctest-results)))
                    (should-not (gethash pass results))
                    (should (equal (gethash fail results) "Fallito"))))))))
      (dolist (buffer (list view output))
        (when (buffer-live-p buffer)
          (when-let* ((process (get-buffer-process buffer))) (delete-process process))
          (kill-buffer buffer)))
      (delete-directory root t))))

(provide 'gdev-cpp-workbench-test)
;;; gdev-cpp-workbench-test.el ends here
