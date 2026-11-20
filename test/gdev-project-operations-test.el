;;; gdev-project-operations-test.el --- Contratti del progetto operativo -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'gdev-project-operations)
(require 'gdev-launch)

(defun gdev-project-operation-test--execute (action root)
  "Esegui il comando effettivo di ACTION in ROOT, conservandone la diagnosi."
  (let ((default-directory root) (command (gdev-build--command action root)))
    (with-temp-buffer
      (let ((code (call-process shell-file-name nil t nil shell-command-switch command)))
        (ert-info ((format "%s\n%s" command (buffer-string))) (should (equal code 0)))))))

(ert-deftest gdev-test-project-operation-model-detects-false-readiness-and-success ()
  (should (eq t (alist-get 'ok (gdev-project-operation-model-check))))
  (should (= 158 (alist-get 'cases (gdev-project-operation-model-check))))
  (dolist (function '(gdev-project-operation-decision gdev-project-operation-result))
    (cl-letf (((symbol-function function) (lambda (&rest _) (if (eq function 'gdev-project-operation-decision) 'ready 'completed))))
      (let ((result (gdev-project-operation-model-check)))
        (should (eq :false (alist-get 'ok result)))
        (should (> (length (alist-get 'counterexamples result)) 0))
        (should (stringp (json-serialize result)))))))

(ert-deftest gdev-test-project-operation-model-detects-an-unclassified-provider ()
  (let ((gdev-project-build-file-markers (cons '(new-system "new.file") gdev-project-build-file-markers)))
    (should (eq :false (alist-get 'ok (gdev-project-operation-model-check))))))

(ert-deftest gdev-test-project-operation-declarations-are-data-and-atomic ()
  (gdev-make-test--project
   (let ((file (expand-file-name gdev-project-operations-file root)))
     (dolist (data '("(:version 1 :profiles ((\"Uno\" :build (\"echo\" \"ok\"))))"
                     "; commento\n(:version 1 :default \"Uno\" :profiles ((\"Uno\" :build (\"echo\")))) ; fine\n"))
       (with-temp-file file (insert data))
       (should (equal "Uno" (plist-get (gdev-project-operations-read root #'gdev-launch--options) :default))))
     (dolist (data '("(:version 1 :version 1 :profiles ((\"Uno\" :build (\"echo\"))))"
                     "(:version 1 :default \"Assente\" :profiles ((\"Uno\" :build (\"echo\"))))"
                     "(:version 1 :profiles ((\"Uno\" :build (\"echo\")) (\"Uno\" :test (\"echo\"))))"
                     "(:version 1 :profiles ((\"Uno\" :build (\"echo\")))) (error \"non eseguire\")"
                     "(:version 1 :profiles ((\"Uno\" :unknown (\"echo\"))))"
                     "(:version 1 :profiles ("))
       (with-temp-file file (insert data))
       (should-error (gdev-project-operations-read root #'gdev-launch--options) :type 'user-error)))))

(ert-deftest gdev-test-project-operation-declarations-refresh-and-respect-personal-choices ()
  (gdev-make-test--load)
  (gdev-make-test--project
   (let ((gdev-launch--project-profiles (make-hash-table :test #'equal))
         (gdev-launch--native-profiles (make-hash-table :test #'equal))
         (gdev-launch-profiles nil) (gdev-launch--standalone-selections nil)
         (gdev-layout-mode nil) captured)
     (with-temp-file gdev-project-operations-file
       (prin1 '(:version 1 :profiles (("Condiviso" :build ("echo" "prima")))) (current-buffer)))
     (cl-letf (((symbol-function 'gdev-launch--start) (lambda (argv &rest _) (setq captured argv))))
       (should (gdev-launch-dispatch 'build))
       (should (equal captured '("echo" "prima")))
       (with-temp-file gdev-project-operations-file
         (prin1 '(:version 1 :profiles (("Condiviso" :build ("echo" "dopo")))) (current-buffer)))
       (should (gdev-launch-dispatch 'build))
       (should (equal captured '("echo" "dopo")))
       (let ((gdev-launch-profiles `((,root ("Personale" :build ("echo" "privato")))))
             (gdev-launch--standalone-selections `((,root . "Personale"))))
         (should (gdev-launch-dispatch 'build))
         (should (equal captured '("echo" "privato")))))
     (with-temp-file gdev-project-operations-file (insert "(:version 99)"))
     (should-error (gdev-launch-dispatch 'build) :type 'user-error)
     (should-not (gethash root gdev-launch--project-profiles)))))

(ert-deftest gdev-test-project-operation-activates-languages-without-a-document ()
  (gdev-make-test--load)
  (gdev-auto-test--state
   (setq gdev-modules '((:tools build)))
   (dolist (entry (append gdev-project-language-markers '((python gdev-python-project-p))))
     (gdev-make-test--project
      (let ((gdev-project-language-markers (list entry)) active)
        (cl-letf (((symbol-function (cadr entry)) (lambda (_) t)))
          (when (eq (car entry) 'python)
            (with-temp-file "pyproject.toml" (insert "[project]\nname='fixture'\n")))
          (gdev-auto-modules-call-for-project
           root (lambda () (setq active (gdev-module-status :lang (car entry)))))
          (should (eq active 'active))
          (should-not (gdev-module-status :lang (car entry)))))))))

(ert-deftest gdev-test-project-operation-deleted-manifest-cannot-run-a-stale-profile ()
  (gdev-make-test--project
   (let* ((nested (expand-file-name "nested/" root))
          (default-directory nested)
          (gdev-launch-profiles nil) (gdev-launch--standalone-selections nil) (gdev-layout-mode nil)
          (gdev-launch--project-profiles (make-hash-table :test #'equal))
          (gdev-launch--native-profiles (make-hash-table :test #'equal)) ran)
     (make-directory nested t)
     (with-temp-file (expand-file-name gdev-project-operations-file nested)
       (prin1 '(:version 1 :profiles (("Fixture" :build ("echo" "ok")))) (current-buffer)))
     (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) root))
               ((symbol-function 'gdev-launch--start) (lambda (&rest _) (setq ran t))))
       (should (gdev-launch-dispatch 'build))
       (should ran)
       (delete-file (expand-file-name gdev-project-operations-file nested))
       (setq ran nil)
       (should-not (gdev-launch-dispatch 'build))
       (should-not ran)
       (should-not (gethash nested gdev-launch--project-profiles))))))

(ert-deftest gdev-test-project-operation-perl-generates-makefile-builds-and-tests ()
  (skip-unless (and (executable-find "perl") (executable-find "make") (executable-find "prove")))
  (gdev-make-test--load)
  (gdev-make-test--project
   (make-directory "lib" t) (make-directory "t" t)
   (with-temp-file "lib/Fixture.pm" (insert "package Fixture; our $VERSION='0.01'; sub value { 42 } 1;\n"))
   (with-temp-file "Makefile.PL"
     (insert "use ExtUtils::MakeMaker; WriteMakefile(NAME=>'Fixture', VERSION_FROM=>'lib/Fixture.pm');\n"))
   (with-temp-file "t/basic.t"
     (insert "use Test::More tests=>1; use Fixture; is(Fixture::value(),42);\n"))
   (should (eq 'perl-make (gdev-build-system root)))
   (gdev-project-operation-test--execute 'build root)
   (should (file-regular-p "Makefile"))
   (should (file-regular-p "blib/lib/Fixture.pm"))
   (gdev-project-operation-test--execute 'test root)))

(ert-deftest gdev-test-project-operation-python-compiles-sources-and-reports-errors ()
  (skip-unless (executable-find "python3"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "requirements.txt" (insert "# Solo libreria standard\n"))
   (with-temp-file "programma.py" (insert "print(42)\n"))
   (make-directory ".venv" t)
   (with-temp-file ".venv/non_compilare.py" (insert "sintassi non valida !"))
   (let ((gdev-modules '((:tools build))) (python-shell-interpreter "python3")
         (process-environment (copy-sequence process-environment)))
     (setenv "PYTHONPYCACHEPREFIX" (expand-file-name "bytecode" root))
     (gdev-project-operation-test--execute 'build root)
     (should (directory-files-recursively "bytecode" "programma.*\\.pyc\\'"))
     (should-not (directory-files-recursively "bytecode" "non_compilare.*\\.pyc\\'"))
     (with-temp-file "programma.py" (insert "def errore(:\n"))
     (let ((command (gdev-build--command 'build root)))
       (with-temp-buffer
         (let* ((default-directory root)
                (code (call-process shell-file-name nil t nil shell-command-switch command)))
           (ert-info ((format "%s · %s\n%s" default-directory command (buffer-string))) (should-not (zerop code)))))))))

(ert-deftest gdev-test-project-operation-python-builds-distributable-packages ()
  (skip-unless (getenv "GDEV_TEST_PYTHON_BUILD"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "pyproject.toml"
     (insert "[build-system]\nrequires=['setuptools','wheel']\nbuild-backend='setuptools.build_meta'\n"
             "[project]\nname='gdev-operation-fixture'\nversion='0.0.1'\n"))
   (with-temp-file "fixture.py" (insert "VALUE = 42\n"))
   (let ((python-shell-interpreter (getenv "GDEV_TEST_PYTHON_BUILD")))
     (gdev-project-operation-test--execute 'build root))
   (should (directory-files "dist" nil "\\.whl\\'"))
   (should (directory-files "dist" nil "\\.tar\\.gz\\'"))))

(ert-deftest gdev-test-project-operation-make-tasks-merge-with-personal-overrides ()
  (skip-unless (executable-find "make"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "Makefile" (insert "all test:\n\t@echo ok\n"))
   (let* ((gdev-project-tasks `((,root ("test" . "echo personale") ("privato" . "echo privato"))))
          (tasks (gdev-build-project-tasks root)))
     (should (equal "echo personale" (cdr (assoc "test" tasks))))
     (should (assoc "all" tasks)) (should (assoc "privato" tasks)))))

(ert-deftest gdev-test-project-operation-control-is-passive-and-actions-retain-root ()
  (gdev-make-test--load)
  (require 'gdev-project-control (gdev-config-file "modules/tools/build/gdev-project-control"))
  (gdev-make-test--project
   (with-temp-file "Makefile" (insert "all:\n\t@echo ok\n"))
   (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Processo nel controllo")))
             ((symbol-function 'call-process) (lambda (&rest _) (error "Processo nel controllo")))
             ((symbol-function 'process-file) (lambda (&rest _) (error "Processo nel controllo"))))
     (let ((observation (gdev-project-control-observe root)))
       (should (eq 'make (plist-get observation :system)))
       (with-temp-buffer
         (gdev-project-control-mode)
         (gdev-project-control-render observation root nil)
         (should-not truncate-lines)
         (should (text-property-not-all (point-min) (point-max) 'button nil))
         (goto-char (button-start (next-button (point-min))))
         (gdev-project-control-render observation root nil)
         (should (equal "Compila" (button-label (button-at (point))))))))
   (let (seen)
     (gdev-project-control--call (lambda () (setq seen (gdev-build--root))) root nil)
     (should (equal seen root)))))

(ert-deftest gdev-test-project-operation-environment-refresh-updates-open-documents ()
  (gdev-make-test--project
   (with-temp-file "Makefile" (insert "all:\n"))
   (let ((gdev-trusted-projects (list (file-name-as-directory (file-truename root))))
         (gdev-project-environment-refresh-functions nil)
         (buffer (generate-new-buffer " *gdev-ambiente-progetto*")) (calls 0))
     (unwind-protect
         (with-current-buffer buffer
           (setq default-directory root buffer-file-name (expand-file-name "README.md" root))
           (let ((gdev-project-environment-functions
                  (list (lambda (_root)
                          (cl-incf calls)
                          (setq-local process-environment (copy-sequence process-environment))
                          (setenv "GDEV_PROJECT_TEST" "aggiornato")
                          (setq-local gdev-project-environment-status 'ready)))))
             (gdev-use-project-tools root)
             (setq-local gdev-project-environment-status 'failed)
             (gdev-refresh-project-environment root)
             (should (eq gdev-project-environment-status 'ready))
             (should (equal "aggiornato" (getenv "GDEV_PROJECT_TEST")))
             (should (>= calls 2))))
       (kill-buffer buffer)))))

(ert-deftest gdev-test-project-operation-mise-removes-stale-values-without-duplicates ()
  (require 'gdev-mise (gdev-config-file "modules/tools/build/gdev-mise"))
  (with-temp-buffer
    (setq-local process-environment (copy-sequence process-environment))
    (setenv "GDEV_PROJECT_TEST" "originale")
    (gdev-mise--install-env '((GDEV_PROJECT_TEST . "prima")))
    (gdev-mise--install-env '((GDEV_PROJECT_TEST . "dopo")))
    (should (equal "dopo" (getenv "GDEV_PROJECT_TEST")))
    (should (= 1 (length (seq-filter (lambda (entry) (string-prefix-p "GDEV_PROJECT_TEST=" entry)) process-environment))))
    (gdev-mise--install-env nil)
    (should (equal "originale" (getenv "GDEV_PROJECT_TEST")))))

(ert-deftest gdev-test-project-operation-env-clears-explicitly-removed-values ()
  (require 'gdev-env)
  (let ((process-environment (copy-sequence process-environment)) (exec-path (copy-sequence exec-path))
        (gdev-env-variables '("GDEV_PROJECT_TEST")))
    (setenv "GDEV_PROJECT_TEST" "precedente")
    (gdev-env--apply '(("GDEV_PROJECT_TEST" . nil)))
    (should-not (getenv "GDEV_PROJECT_TEST"))))

(provide 'gdev-project-operations-test)
;;; gdev-project-operations-test.el ends here
