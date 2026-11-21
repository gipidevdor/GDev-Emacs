;;; gdev-project-native-tools-test.el --- Strumenti fissati e preset -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'gdev-modules)
(defun gdev-test-project-native-tools--load ()
  "Carica il modulo senza installare dipendenze della prova."
  (unless (fboundp 'gdev-cc-check-format-version)
    (let ((use-package-ensure-function #'ignore))
      (load (gdev-module-file :lang 'cc ".el") nil t t))))

(ert-deftest gdev-test-project-native-tools-formatter-pin-fails-before-edits ()
  (gdev-test-project-native-tools--load)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-format-pin-" t)))
         (default-directory root) called)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".clang-format-version" root) (insert "21.1.8\n"))
          (cl-letf (((symbol-function 'executable-find) (lambda (_) "/fake/clang-format"))
                    ((symbol-function 'process-file) (lambda (&rest _) (insert "clang-format version 20.1.0") 0))
                    ((symbol-function 'gdev-format-with-program) (lambda (&rest _) (setq called t))))
            (should-error (gdev-cc-clang-format) :type 'user-error)
            (should-not called))
          (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (insert "clang-format version 21.1.8") 0)))
            (should-not (gdev-cc-check-format-version "/fake/formatter"))))
      (delete-directory root t))))

(ert-deftest gdev-test-project-native-tools-clangd-follows-selected-database ()
  (gdev-test-project-native-tools--load)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-database-" t)))
         (default-directory root) (directory (expand-file-name "build/selected preset/" root)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "CMakePresets.json" root) (insert "{}"))
          (make-directory directory t)
          (cl-letf (((symbol-function 'gdev-cmake--context) (lambda (&rest _) (list :directory directory))))
            (should-not (gdev-cc-compilation-database))
            (with-temp-file (expand-file-name "compile_commands.json" directory) (insert "[]"))
            (should (file-equal-p directory (gdev-cc-compilation-database)))
            (should (member (concat "--compile-commands-dir=" directory) (gdev-cc-clangd-command)))))
      (delete-directory root t))))

(provide 'gdev-project-native-tools-test)
