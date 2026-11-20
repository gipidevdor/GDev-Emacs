;;; gdev-make-test.el --- Contratto operativo dei progetti Make -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le prove usano Make e compilatori reali in cartelle temporanee.
;;; Code:
(require 'ert)
(require 'gdev-project-types)

(defun gdev-make-test--load ()
  (gdev-cmake-test--load-build)
  (unless (featurep 'gdev-make)
    (load (gdev-config-file "modules/tools/build/gdev-make.el") nil t t)))

(defmacro gdev-make-test--project (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev make progetto-" t)))
          (gdev-state-directory (expand-file-name "stato/" root))
          (default-directory root)
          (native-comp-enable-subr-trampolines nil)
          (gdev-build-settings nil))
     (unwind-protect (progn (make-directory gdev-state-directory t) ,@body)
       (delete-directory root t))))

(ert-deftest gdev-test-make-recognizes-folders-without-git-for-every-marker ()
  (gdev-make-test--load)
  (dolist (family gdev-project-build-file-markers)
    (dolist (name (cdr family))
      (gdev-make-test--project
       (let* ((source (expand-file-name "src/deep/" root))
              (default-directory source))
         (make-directory source t)
         (with-temp-file (expand-file-name name root) (insert "fixture"))
         (should (gdev-project-build-marked-p root))
         (should (equal root (gdev-project-operation-root source)))
         (cl-letf (((symbol-function 'gdev-handler) (lambda (&rest _) nil))
                   ((symbol-function 'gdev-project-root) (lambda (&rest _) source))
                   ((symbol-function 'gdev-workspace-directory) (lambda (&rest _) nil)))
           (should (equal root (gdev-build--root)))))))))

(ert-deftest gdev-test-make-root-respects-the-workspace-boundary ()
  (gdev-make-test--load)
  (gdev-make-test--project
   (let ((first (expand-file-name "one/" root))
         (other (expand-file-name "two/" root)))
     (make-directory first t) (make-directory other t)
     (with-temp-file (expand-file-name "Makefile" root) (insert "all:\n"))
     (should (equal first (gdev-project-operation-root first first)))
     (with-temp-file (expand-file-name "Makefile" first) (insert "all:\n"))
     (should (equal first (gdev-project-operation-root first first)))
     (should (equal other (gdev-project-operation-root other other))))))

(ert-deftest gdev-test-make-inspects-expanded-rules-without-building ()
  (skip-unless (executable-find "make"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "Makefile"
     (insert "include targets.mk\n.DEFAULT_GOAL := prodotto\nNAME = extra\n"
             ".PHONY: prodotto test clean $(NAME)\n"
             "prodotto: dependency.txt\n\t@echo eseguito > risultato\n"
             "test clean $(NAME):\n\t@echo azione\n"
             "dependency.txt:\n\t@echo input > $@\n"))
   (with-temp-file "targets.mk" (insert ".PHONY: included\nincluded:\n\t@echo incluso\n"))
   (let ((data (gdev-make-inspect root)))
     (should (equal "prodotto" (plist-get data :default)))
     (dolist (name '("prodotto" "test" "clean" "extra" "included"))
       (should (member name (plist-get data :targets))))
     (should-not (member "Makefile" (plist-get data :targets))))
   (should-not (file-exists-p "risultato"))
   (should-not (file-exists-p "dependency.txt"))))

(ert-deftest gdev-test-make-default-build-produces-a-real-executable ()
  (skip-unless (and (executable-find "make") (executable-find "cc")))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "main.c" (insert "int main(void) { return 0; }\n"))
   (with-temp-file "Makefile"
     (insert ".DEFAULT_GOAL := programma\nprogramma: main.c\n\t$(CC) $< -o $@\n"))
   (let ((command (gdev-build--command 'build root)))
     (should-not (string-match-p " -- all" command))
     (with-temp-buffer (should (zerop (call-process shell-file-name nil t nil shell-command-switch command)))))
   (should (file-executable-p "programma"))
   (should (zerop (call-process (expand-file-name "programma" root))))))

(ert-deftest gdev-test-make-variables-are-data-and-persist-per-project ()
  (skip-unless (executable-find "make"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (let ((text "un valore con spazi; $$(echo NON_ESEGUITO)"))
     (with-temp-file "Makefile" (insert "all:\n\t@printf '%s' '$(MESSAGE)' > risultato\n"))
     (gdev-build--put :make-variables (list (concat "MESSAGE=" text)) root)
     (let ((command (gdev-make-command root 'build)))
       (with-temp-buffer (should (zerop (call-process shell-file-name nil t nil shell-command-switch command)))))
     ;; Make interpreta $ secondo la propria sintassi, non la shell chiamante.
     (should (equal (gdev-read-file-contents "risultato") "un valore con spazi; $(echo NON_ESEGUITO)"))
     (should (equal (gdev-make-variables root) (list (concat "MESSAGE=" text)))))))

(ert-deftest gdev-test-make-invalid-configuration-keeps-the-saved-choice ()
  (gdev-make-test--load)
  (gdev-make-test--project
   (gdev-build--put :make-variables '("CC=cc") root)
   (dolist (input '("--eval=esegui" "senza-assegnamento" "CC=\"uno\ndue\""))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input)))
       (should-error (gdev-make-configure root) :type 'user-error))
     (should (equal (gdev-make-variables root) '("CC=cc"))))))

(ert-deftest gdev-test-make-targets-cannot-become-options-or-assignments ()
  (gdev-make-test--load)
  (gdev-make-test--project
   (dolist (goal '("--eval=azione" "VAR=valore" "uno\ndue" ""))
     (should-error (gdev-make-command root 'build goal) :type 'user-error))
   (should (equal (car (last (gdev-shell-split (gdev-make-command root 'build "obiettivo con spazi"))))
                  "obiettivo con spazi"))))

(ert-deftest gdev-test-make-configure-edits-options-without-compiling ()
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "Makefile" (insert "all:\n\t@echo compilato > risultato\n"))
   (cl-letf (((symbol-function 'gdev-build--root) (lambda () root))
             ((symbol-function 'gdev-launch-dispatch) (lambda (&rest _) nil))
             ((symbol-function 'read-string) (lambda (&rest _) "CC=cc")))
     (gdev-build-configure))
   (should (equal '("CC=cc") (gdev-make-variables root)))
   (should-not (file-exists-p "risultato"))))

(ert-deftest gdev-test-make-catalog-enforces-size-and-time-limits-and-releases-buffers ()
  (skip-unless (executable-find "make"))
  (gdev-make-test--load)
  (gdev-make-test--project
   (with-temp-file "Makefile" (insert "all:\n\t@echo ok\n"))
   (let ((gdev-make-inspection-max-bytes 32))
     (should-error (gdev-make-inspect root) :type 'user-error))
   (let ((script (expand-file-name "motore-lento" root))
         (gdev-make-inspection-timeout 0.01))
     (with-temp-file script (insert "#!/bin/sh\nsleep 0.2\n"))
     (set-file-modes script #o700)
     (let ((gdev-make-program script))
       (should-error (gdev-make-inspect root) :type 'user-error)))
   (should-not (seq-some (lambda (buffer) (string-prefix-p " *gdev-make-" (buffer-name buffer))) (buffer-list)))))

(provide 'gdev-make-test)
;;; gdev-make-test.el ends here
