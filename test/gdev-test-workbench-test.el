;;; gdev-test-workbench-test.el --- Verifiche della vista Test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verifiche condivise del catalogo, dei filtri e delle azioni di esecuzione.

;;; Code:

(require 'ert)
(require 'gdev-project-view)

(ert-deftest gdev-test-workbench-filters-exact-ids-by-result-and-secondary-label ()
  "La stessa selezione è usata per mostrare ed eseguire i risultati filtrati."
  (with-temp-buffer
    (gdev-project-view-mode)
    (setq-local gdev-activity-kind 'test
                gdev-project-view--root "/tmp/"
                gdev-project-view--lines '(((name . "rapido-integrazione") (gdev-groups "rapidi" "integrazione"))
                                          ((name . "rapido-successo") (gdev-groups "rapidi" "integrazione"))
                                          ((name . "altro") (gdev-groups "altro")))
                gdev-project-view--results (make-hash-table :test #'equal))
    (puthash "rapido-integrazione" "Fallito" gdev-project-view--results)
    (puthash "rapido-successo" "Passato" gdev-project-view--results)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "integrazione")))
      (gdev-project-view-test-filter-group))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Fallito")))
      (gdev-project-view-test-filter-result))
    (should (string-search "rapido-integrazione" (buffer-string)))
    (should-not (string-search "rapido-successo" (buffer-string)))
    (should-not (string-search "altro" (buffer-string)))
    (cl-letf (((symbol-function 'gdev-project-view--test) #'identity))
      (should (equal (gdev-project-view-test-filtered) '("rapido-integrazione"))))))

(ert-deftest gdev-test-workbench-progress-does-not-consume-a-partial-line ()
  "I frammenti di output vengono letti solo dopo il termine della riga."
  (with-temp-buffer
    (insert "1/2 Test #1: prima ............ Passed 0.1 sec\n"
            "2/2 Test #2: seconda .......... ***Fail")
    (let* ((split (line-beginning-position))
           (results (gdev-project-view--ctest-results (point-min) split)))
      (should (equal (gethash "prima" results) "Passato"))
      (should-not (gethash "seconda" results))
      (insert "ed 0.2 sec\n")
      (gdev-project-view--ctest-results split (point-max) results)
      (should (equal (gethash "seconda" results) "Fallito"))
      (should (= (hash-table-count results) 2)))))

(ert-deftest gdev-test-workbench-cursor-discovery-rejects-edited-origin ()
  "Il rilevamento in corso non avvia un test da una revisione superata."
  (gdev-test--with-layout
    (let ((source (generate-new-buffer " *fixture test*")) callback runs)
      (unwind-protect
          (progn
            (set-window-buffer (gdev-layout-editor) source)
            (with-current-buffer source (setq buffer-file-name "/tmp/test_esempio.py"))
            (cl-letf (((symbol-function 'gdev-project-view-sync) #'ignore)
                      ((symbol-function 'gdev-project-view--test-buffer) (lambda () source))
                      ((symbol-function 'gdev-project-view--test-refresh)
                       (lambda (context finish) (should-not context) (setq callback finish)))
                      ((symbol-function 'gdev-project-view--test-at-position)
                       (lambda (&rest _) (cl-incf runs))))
              (setq runs 0)
              (gdev-project-view-test-at-point)
              (should callback)
              (funcall callback)
              (should (= runs 1))
              (with-current-buffer source (insert "revisione successiva"))
              (funcall callback)
              (should (= runs 1))))
        (when (buffer-live-p source)
          (with-current-buffer source (set-buffer-modified-p nil))
          (kill-buffer source))))))

;; La cartella dello spazio può essere una sottocartella del repository.
(ert-deftest gdev-test-project-view-git-paths-start-at-the-repository ()
  (let* ((top (file-name-as-directory (make-temp-file "gdev-git-vista-" t)))
         (root (file-name-as-directory (expand-file-name "cpp" top))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" top))
          (make-directory root)
          (should (equal (gdev-project-view--git-path "cpp/main.cpp" root)
                         (expand-file-name "cpp/main.cpp" top)))
          (should (equal (gdev-project-view--git-path "README.md" root)
                         (expand-file-name "README.md" top))))
      (delete-directory top t))))

(provide 'gdev-test-workbench-test)
;;; gdev-test-workbench-test.el ends here
