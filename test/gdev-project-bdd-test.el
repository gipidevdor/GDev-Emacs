;;; gdev-project-bdd-test.el --- BDD delle operazioni effettive -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'gdev-bdd (gdev-config-file "test/gdev-bdd"))

(defun gdev-project-bdd--setup ()
  (gdev-make-test--load)
  (let ((root (file-name-as-directory (make-temp-file "gdev progetto bdd-" t))))
    (make-directory (expand-file-name "src/nested" root) t)
    (make-directory (expand-file-name "stato" root) t)
    (list root (make-hash-table) (current-window-configuration))))

(defun gdev-project-bdd--cleanup (context)
  (when context
    (let ((root (car context)) (buffer (gethash 'output (cadr context))))
      (when (buffer-live-p buffer)
        (when-let* ((process (get-buffer-process buffer)) ((process-live-p process))) (delete-process process))
        (kill-buffer buffer))
      (set-window-configuration (nth 2 context))
      (delete-directory root t))))

(defun gdev-project-bdd--prepare (context kind)
  (let ((default-directory (car context)))
    (pcase kind
      ("Make Cpp"
       (should (and (executable-find "make") (executable-find "c++")))
       (with-temp-file "main.cpp" (insert "int main() { return 0; }\n"))
       (with-temp-file "Makefile" (insert ".DEFAULT_GOAL := prodotto\nprodotto:\n\t$(CXX) main.cpp -o programma\n")))
      ("Programma Perl"
       (with-temp-file "prova.pl" (insert "my $valore = 42;\nprint $valore;\n"))
       (with-temp-file "Makefile" (insert "all:\n\tperl -c prova.pl\n")))
      ("Make errato"
       (should (executable-find "make"))
       (with-temp-file "Makefile" (insert "all:\n\t@echo Errore previsto; exit 23\n")))
      ("Perl"
       (should (and (executable-find "make") (executable-find "perl")))
       (make-directory "lib" t) (make-directory "t" t)
       (with-temp-file "lib/Fixture.pm" (insert "package Fixture; our $VERSION='0.01'; sub value {42} 1;\n"))
       (with-temp-file "Makefile.PL" (insert "use ExtUtils::MakeMaker; WriteMakefile(NAME=>'Fixture',VERSION_FROM=>'lib/Fixture.pm');\n"))
       (with-temp-file "t/basic.t" (insert "use Test::More tests=>1; use Fixture; is(Fixture::value(),42);\n")))
      ("Dichiarato"
       (with-temp-file gdev-project-operations-file
         (prin1 '(:version 1 :profiles (("Locale" :configure ("sh" "-c" "touch configurato")))) (current-buffer))))
      ("Strumenti Python"
       (should (executable-find "python3"))
       (with-temp-file "requirements.txt" (insert "# libreria standard\n"))
       (with-temp-file "pip.py"
         (insert "import pathlib, sys\npathlib.Path('strumenti-pronti').write_text(sys.prefix)\n")))
      ("Python"
       (should (executable-find "python3"))
       (with-temp-file "requirements.txt" (insert "# libreria standard\n"))
       (with-temp-file "programma.py" (insert "VALUE = 42\n"))
       (make-directory "tests" t)
       (with-temp-file "tests/test_programma.py"
         (insert "import unittest\nfrom programma import VALUE\nclass Prova(unittest.TestCase):\n    def test_value(self):\n        self.assertEqual(VALUE, 42)\n"))))))

(defun gdev-project-bdd--operate (context action)
  (let* ((root (car context)) (gdev-layout-mode nil)
         (gdev-state-directory (expand-file-name "stato/" root))
         (gdev-launch-profiles nil) (gdev-launch--standalone-selections nil)
         (gdev-launch--project-profiles (make-hash-table :test #'equal))
         (gdev-launch--native-profiles (make-hash-table :test #'equal))
         (gdev-trusted-projects (list (file-name-as-directory (file-truename root))))
         (process-environment (copy-sequence process-environment))
         buffer process)
    (setenv "PYTHONPYCACHEPREFIX" (expand-file-name "bytecode" root))
    (with-temp-buffer
      (setq default-directory (expand-file-name "src/nested/" root))
      (let ((compilation-start-hook
             (cons (lambda (process) (setq buffer (process-buffer process))) compilation-start-hook)))
        (funcall action)))
    (puthash 'output buffer (cadr context))
    (should (buffer-live-p buffer))
    (setq process (get-buffer-process buffer))
    (should process)
    (let ((deadline (+ (float-time) 30)))
      (while (and (process-live-p process) (< (float-time) deadline)) (accept-process-output process 0.03))
      (should-not (process-live-p process))
      (accept-process-output process 0.01))
    (puthash 'code (process-exit-status process) (cadr context))))

(defun gdev-project-bdd--session (context)
  "Apri, compila e ispeziona un programma locale con il debugger GUD reale."
  (require 'gud)
  (unless (fboundp 'gdev-perl-perldb) (load (gdev-module-file :lang 'perl ".el") nil t))
  (let* ((root (file-name-as-directory (file-truename (car context))))
         (state (cadr context))
         (gdev-trusted-projects (list root))
         (project-list-file (expand-file-name "progetti" root))
         (project--list nil)
         (compilation-ask-about-save nil)
         build debug source)
    (gdev-test--with-layout
      (let ((original (gdev-workspace-state-ensure-id)))
        (unwind-protect
            (progn
              (tab-bar-new-tab)
              (gdev-open-folder root)
              (should (equal (gdev-workspace-directory) root))
              (with-selected-window (gdev-layout-editor)
                (should (file-equal-p root (gdev-default-directory)))
                (should (file-equal-p root (gdev-build--root))))
              (let ((compilation-start-hook
                     (cons (lambda (process) (setq build process)) compilation-start-hook)))
                (call-interactively #'gdev-build))
              (should (processp build))
              (gdev-test-launch--wait (lambda () (not (process-live-p build))))
              (should (zerop (process-exit-status build)))
              (select-window (gdev-layout-editor))
              (gdev-open-file (expand-file-name "prova.pl" root))
              (setq source (current-buffer))
              (cl-letf (((symbol-function 'read-shell-command)
                         (lambda (_prompt initial &rest _) initial)))
                (call-interactively #'gdev-perl-perldb))
              (setq debug (get-buffer-process gud-comint-buffer))
              (should (process-live-p debug))
              (with-current-buffer (process-buffer debug)
                (gdev-test-launch--wait (lambda () (string-match-p "DB<[0-9]+>" (buffer-string))))
                (comint-send-string debug "n\n")
                (comint-send-string debug "p qq{valore-osservato=$valore}\n")
                (gdev-test-launch--wait-output (process-buffer debug) "valore-osservato=42")
                (puthash 'valore 42 state)
                (comint-send-string debug "q\n")
                (gdev-test-launch--wait (lambda () (not (process-live-p debug)))))
              (tab-bar-close-tab)
              (puthash 'ritorno (equal original (gdev-workspace-state-id)) state))
          (dolist (proc (list debug build))
            (when (processp proc)
              (when (process-live-p proc) (delete-process proc))
              (when (buffer-live-p (process-buffer proc)) (kill-buffer (process-buffer proc)))))
          (when (buffer-live-p source) (kill-buffer source)))))))

(gdev-bdd-register-feature
 (gdev-config-file "test/behavior/project.feature") "gdev-test-behavior-project-"
 `(("un progetto operativo \"\\([^\"]+\\)\"" . ,#'gdev-project-bdd--prepare)
   ("apro la cartella, compilo, ispeziono il programma nel debugger e chiudo lo spazio" . ,#'gdev-project-bdd--session)
   ("il debugger ha letto il valore dal programma" . ,(lambda (context) (should (equal 42 (gethash 'valore (cadr context))))))
   ("sono tornato allo spazio iniziale" . ,(lambda (context) (should (gethash 'ritorno (cadr context)))))
   ("compilo dalla sottocartella senza aprire un sorgente" . ,(lambda (context) (gdev-project-bdd--operate context #'gdev-build)))
   ("eseguo tutti i test dalla cartella" . ,(lambda (context) (gdev-project-bdd--operate context #'gdev-build-test)))
   ("configuro dalla sottocartella senza aprire un sorgente" . ,(lambda (context) (gdev-project-bdd--operate context #'gdev-build-configure)))
   ("preparo gli strumenti Python dalla cartella" . ,(lambda (context)
                                                       (gdev-project-bdd--operate
							context (lambda () (gdev-auto-modules-call-for-project
                                                                            (car context) #'gdev-python-install-tools)))))
   ("la compilazione termina con successo" . ,(lambda (context) (should (zerop (gethash 'code (cadr context))))))
   ("la compilazione segnala un errore" . ,(lambda (context) (should-not (zerop (gethash 'code (cadr context))))))
   ("esiste il prodotto \"\\([^\"]+\\)\"" . ,(lambda (context name) (should (file-regular-p (expand-file-name name (car context))))))
   ("il bytecode del progetto è stato creato" . ,(lambda (context) (should (directory-files-recursively (expand-file-name "bytecode" (car context)) "programma.*\\.pyc\\'"))))
   ("offre il controllo del progetto" . ,(lambda (context)
                                           (with-current-buffer (gethash 'output (cadr context))
                                             (goto-char (point-min)) (should (search-forward "Controlla progetto" nil t))))))
 #'gdev-project-bdd--setup #'gdev-project-bdd--cleanup)

(provide 'gdev-project-bdd-test)
;;; gdev-project-bdd-test.el ends here
