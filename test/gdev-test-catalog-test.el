;;; gdev-test-catalog-test.el --- Identificatori ed esiti dei test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; I comandi, gli esiti e la scelta al cursore usano gli stessi identificatori.

;;; Code:

(require 'ert)
(require 'gdev-test-catalog)

(ert-deftest gdev-test-catalog-selects-parameters-and-exact-source ()
  "Una funzione pytest comprende le varianti e la registrazione CTest è precisa."
  (require 'python)
  (let* ((root (file-name-as-directory temporary-file-directory))
         (file (expand-file-name "test con spazi.py" root))
         (name "test con spazi.py::TestMisure::test_misura")
         (first (concat name "[a b]"))
         (second (concat name "[c]")))
    (with-temp-buffer
      (setq buffer-file-name file)
      (insert "class TestMisure:\n    def test_misura(self, x):\n        return x\n")
      (let ((python-mode-hook nil) (prog-mode-hook nil)) (python-mode))
      (goto-char (point-min))
      (search-forward "return x")
      (should (equal (gdev-test-catalog-at-point
                      'pytest (mapcar (lambda (id) (gdev-test-catalog--entry id (cons file 1)))
                                      (list first second (concat name "_altra"))) root)
                     (list first second))))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "CMakeLists.txt" root))
      (insert "project(Prova)\nadd_test(\n  NAME misura\n  COMMAND programma)\n")
      (goto-char (point-min))
      (search-forward "NAME misura")
      (should (equal (gdev-test-catalog-at-point
                      'ctest (list (gdev-test-catalog--entry "misura" (cons buffer-file-name 2))
                                   (gdev-test-catalog--entry "altro" (cons buffer-file-name 5))) root)
                     '("misura"))))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "prove/con spazi.test.js" root))
      (let ((entries (gdev-test-catalog-files "altro.test.js\0prove/con spazi.test.js\0" root)))
        (should (equal (gdev-test-catalog-at-point 'node entries root) '("prove/con spazi.test.js")))
        (should (equal (gdev-test-catalog-at-point 'deno entries root) '("prove/con spazi.test.js")))
        (setq buffer-file-name (expand-file-name "indice.js" root))
        (should-not (gdev-test-catalog-at-point 'node entries root))))))

(ert-deftest gdev-test-catalog-command-keeps-identifiers-as-individual-arguments ()
  "Percorsi con spazi o simili a opzioni restano argomenti dei runner."
  (let ((ids '("--un test.js" "altro test.js")))
    (should (equal (gdev-test-catalog-command 'node "/progetto/" ids 3)
                   '("node" "--test" "--test-reporter=junit" "--test-concurrency=3"
                     "./--un test.js" "./altro test.js")))
    (should (equal (gdev-test-catalog-command 'deno "/progetto/" ids 2)
                   '("deno" "test" "--reporter=junit" "--parallel"
                     "./--un test.js" "./altro test.js"))))
  (cl-letf (((symbol-function 'gdev-python--interpreter) (lambda (_) "/bin/python")))
    (should (equal (gdev-test-catalog-command 'pytest "/progetto/" '("file.py::test_x[a b]"))
                   '("/bin/python" "-m" "pytest" "--color=no" "-v" "--" "file.py::test_x[a b]")))))

(ert-deftest gdev-test-catalog-streams-pytest-status-without-rescanning ()
  "Gli esiti si accumulano per intervalli e le attese fallite si distinguono."
  (with-temp-buffer
    (insert "test.py::test_saltato XFAIL [20%]\n")
    (let ((start (point))
          (results (gdev-test-catalog-results 'pytest default-directory)))
      (insert "test.py::test_riuscito XPASS [40%]\n[gw2] [ 60%] FAILED test con spazi.py::test_fallito[a b] \n")
      (let ((end (point)))
        (insert "test.py::test_successivo PASSED [80%]\n")
        (should (eq results (gdev-test-catalog-results 'pytest default-directory start end results)))
        (should (= (hash-table-count results) 3))
        (should (equal (gethash "test.py::test_saltato" results) "Saltato"))
        (should (equal (gethash "test.py::test_riuscito" results) "Passato"))
        (should (equal (gethash "test con spazi.py::test_fallito[a b]" results) "Fallito"))
        (should-not (gethash "test.py::test_successivo" results))))))

(ert-deftest gdev-test-catalog-junit-normalizes-absolute-files-and-uri ()
  "Un errore prevale sui casi passati dello stesso file anche con percorsi diversi."
  (let* ((root (file-name-as-directory (file-truename temporary-file-directory)))
         (absolute (expand-file-name "prove con spazi.test.js" root))
         (uri (concat "file://" (replace-regexp-in-string " " "%20" absolute))))
    (with-temp-buffer
      (insert "Diagnosi precedente\n<testsuites>\n"
              (format "<testcase name=\"x\" file=\"%s\"><failure /></testcase>\n" uri)
              "<testcase name=\"y\" file=\"./prove con spazi.test.js\"/>\n"
              "<testcase name=\"z\" file=\"./altra.test.js\"><skipped /></testcase>\n")
      (should (hash-table-empty-p (gdev-test-catalog-results 'node root)))
      (insert "</testsuites>\n")
      (let ((results (gdev-test-catalog-results 'node root)))
        (should (= (hash-table-count results) 2))
        (should (equal (gethash "prove con spazi.test.js" results) "Fallito"))
        (should (equal (gethash "altra.test.js" results) "Saltato"))))
    (with-temp-buffer
      (insert (format "<testsuite name=\"%s\" tests=\"2\" failures=\"0\" errors=\"1\" disabled=\"0\">\n" uri)
              "</testsuite>\n")
      (let ((results (gdev-test-catalog-results 'deno root)))
        (should (= (hash-table-count results) 1))
        (should (equal (gethash "prove con spazi.test.js" results) "Fallito"))))))

(ert-deftest gdev-test-catalog-ctest-location-accepts-project-alias ()
  "Una registrazione deve corrispondere anche se CMake è stato configurato da un alias."
  (let* ((root (make-temp-file "gdev-test-ctest-alias-" t))
         (directory (expand-file-name "progetto" root))
         (alias (expand-file-name "alias" root))
         (real-file (expand-file-name "CMakeLists.txt" directory)))
    (unwind-protect
        (progn
          (make-directory directory)
          (make-symbolic-link directory alias)
          (with-temp-file real-file (insert "add_test(NAME esempio COMMAND prova)\n"))
          (with-temp-buffer
            (setq-local buffer-file-name real-file)
            (let ((entries (list (list '(name . "esempio")
                                       (cons 'gdev-location (cons (expand-file-name "CMakeLists.txt" alias) 1))))))
              (should (equal (gdev-test-catalog-at-point 'ctest entries directory) '("esempio"))))))
      (delete-directory root t))))

(provide 'gdev-test-catalog-test)
;;; gdev-test-catalog-test.el ends here
