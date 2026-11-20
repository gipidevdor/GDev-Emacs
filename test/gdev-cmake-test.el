;;; gdev-cmake-test.el --- Configurazione, compilazione e test CMake -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Prove del flusso di una cartella appena aperta e delle preimpostazioni
;; collegate allo stesso albero CMake.

;;; Code:

(require 'ert)
(require 'gdev-modules)

(defvar gdev-build-settings)
(defvar gdev-cmake-build-directory)
(defvar gdev-cmake--artifact-cache)

(defun gdev-cmake-test--load-build ()
  (unless (fboundp 'gdev-cmake-test-context)
    (load (gdev-module-file :tools 'build ".el") nil t)))

(ert-deftest gdev-cmake-test-build-and-test-follow-selected-configure-preset ()
  (gdev-cmake-test--load-build)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-cmake-presets-" t)))
         (default-directory root)
         (gdev-build-settings nil)
         (process-environment (copy-sequence process-environment))
         (directory (expand-file-name "out con spazi/Ninja Multi-Config/mac-debug/" root)))
    (unwind-protect
        (progn
          (setenv "GDEV_TEST_PARENT" "out con spazi")
          (setenv "GDEV_TEST_OUT" "wrong path")
          (setenv "GDEV_TEST_MASK" "mac-debug")
          (with-temp-file (expand-file-name "CMakeLists.txt" root)
            (insert "cmake_minimum_required(VERSION 3.23)\nproject(Smoke LANGUAGES CXX)\n"))
          (with-temp-file (expand-file-name "CMakePresets.json" root)
            (insert "{\"version\":5,\"include\":[\"presets.json\"],\n"
                    "\"configurePresets\":[{\"name\":\"mac-debug\",\"inherits\":\"base\","
                    "\"environment\":{\"GDEV_TEST_OUT\":\"$penv{GDEV_TEST_PARENT}\",\"GDEV_TEST_MASK\":null}},"
                    "{\"name\":\"release\",\"inherits\":\"base\"}],\n"
                    "\"buildPresets\":[{\"name\":\"compile\",\"configurePreset\":\"mac-debug\"},"
                    "{\"name\":\"other\",\"configurePreset\":\"release\"}],\n"
                    "\"testPresets\":[{\"name\":\"verify\",\"configurePreset\":\"mac-debug\","
                    "\"configuration\":\"Debug\"}]}"))
          (with-temp-file (expand-file-name "presets.json" root)
            (insert "{\"version\":5,\"configurePresets\":[{\"name\":\"base\",\"hidden\":true,"
                    "\"generator\":\"Ninja Multi-Config\","
                    "\"environment\":{\"GDEV_TEST_TREE\":\"$env{GDEV_TEST_OUT}/${generator}/$env{GDEV_TEST_MASK}\","
                    "\"GDEV_TEST_MASK\":\"wrong preset\"},"
                    "\"binaryDir\":\"$env{GDEV_TEST_TREE}\"}]}"))
          (gdev-build--put :configure-preset "mac-debug" root)
          (gdev-build--put :build-preset "other" root)
          (let (calls)
            (cl-letf (((symbol-function 'process-file)
                       (lambda (program _infile _destination _display &rest args)
                         (should (equal program "cmake"))
                         (push args calls)
                         (insert "Available configure presets:\n\n  \"mac-debug\"\n  \"release\"\n"
                                 "\nAvailable build presets:\n\n  \"compile\"\n  \"other\"\n"
                                 "\nAvailable test presets:\n\n  \"verify\"\n")
                         0)))
              (should (equal (gdev-cmake--context root nil 'test)
                             (list :configure "mac-debug" :type nil :directory directory
                                   :build "compile" :test "verify" :test-configuration "Debug")))
              (should (equal calls '(("--list-presets=all"))))))
          (cl-letf (((symbol-function 'gdev-cmake--presets)
                     (lambda (kind &optional _root _report-errors)
                       (pcase kind
                         ("configure" '("mac-debug" "release")) ("build" '("compile" "other"))
                         ("test" '("verify"))))))
            (let ((command (gdev-build--command 'test root)))
              (should (equal (gdev-cmake--context root)
                             (list :configure "mac-debug" :type nil :directory directory
                                   :build "compile" :test "verify" :test-configuration "Debug")))
              (should (string-prefix-p "cmake --preset mac-debug && cmake --build --preset compile" command))
              (should (string-match-p "--config Debug.*&& ctest .*--preset verify -C Debug\\'" command))
              (should (file-regular-p (expand-file-name ".cmake/api/v1/query/client-gdev/codemodel-v2" directory))))
            (with-temp-file (expand-file-name "CTestTestfile.cmake" directory))
            (should (equal (plist-get (gdev-cmake-test-context root) :directory) directory))
            (gdev-build--put :cmake-preset-type "Debug" root)
            (let* ((context (gdev-cmake--context root))
                   (override (plist-get context :directory)))
              (should (equal override (expand-file-name "build-gdev/mac-debug/Debug/" root)))
              (should (string-prefix-p "cmake --preset mac-debug -B " (gdev-cmake-configure-command context)))
              (should-not (plist-get context :build))
              (should (string-suffix-p "--config Debug --parallel 1"
                                       (cl-letf (((symbol-function 'num-processors) (lambda () 1)))
                                         (gdev-cmake-build-command nil context))))
              (should (string-suffix-p "-C Debug" (gdev-cmake-test-command context))))))
      (delete-directory root t))))

(ert-deftest gdev-cmake-test-environment-macros-stop-on-cycles ()
  (gdev-cmake-test--load-build)
  (should-not (gdev-cmake--expand "$env{GDEV_TEST_ONE}" default-directory "test" default-directory
                                  '((GDEV_TEST_ONE . "$env{GDEV_TEST_TWO}")
                                    (GDEV_TEST_TWO . "$env{GDEV_TEST_ONE}")))))

(ert-deftest gdev-cmake-test-reuses-artifacts-for-the-current-index ()
  "Riusa solo metadati completi e ricontrolla gli eseguibili sul disco."
  (gdev-cmake-test--load-build)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-cmake-index-" t)))
         (default-directory root)
         (gdev-build-settings nil)
         (gdev-cmake-build-directory "build")
         (gdev-cmake--artifact-cache nil)
         (build (expand-file-name "build/" root))
         (reply (expand-file-name ".cmake/api/v1/reply/" build))
         (extension (if gdev-windows-p ".exe" ""))
         (first-name (concat "primo" extension))
         (second-name (concat "secondo" extension))
         (first (expand-file-name first-name build))
         (second (expand-file-name second-name build))
         (read-json (symbol-function 'gdev-cmake--json))
         reads)
    (unwind-protect
        (progn
          (make-directory reply t)
          (with-temp-file (expand-file-name "CMakeLists.txt" root))
          (dolist (file (list first second))
            (with-temp-file file (insert "Prova\n"))
            (set-file-modes file #o755))
          (cl-labels
              ((json (name text)
                 (with-temp-file (expand-file-name (concat name ".json") reply)
                   (insert text)))
               (index (name)
                 (json (concat "index-" name)
                       (format "{\"reply\":{\"client-gdev\":{\"codemodel-v2\":{\"jsonFile\":\"modello-%s.json\"}}}}" name))
                 (json (concat "modello-" name)
                       (format "{\"configurations\":[{\"targets\":[{\"jsonFile\":\"obiettivo-%s.json\"}]}]}" name)))
               (artifact (name path)
                 (json (concat "obiettivo-" name)
                       (format "{\"type\":\"EXECUTABLE\",\"artifacts\":[{\"path\":\"%s\"}]}" path))))
            (cl-letf (((symbol-function 'gdev-cmake--json)
                       (lambda (file)
                         (when (string-prefix-p "obiettivo-" (file-name-nondirectory file))
                           (push (file-name-nondirectory file) reads))
                         (funcall read-json file))))
              (index "A")
              (artifact "A" first-name)
              (should (equal (gdev-project-programs root) (list (concat "build/" first-name))))
              (delete-file first)
              (should-not (gdev-project-programs root))
              (with-temp-file first (insert "Prova\n"))
              (set-file-modes first #o755)
              (should (equal (gdev-project-programs root) (list (concat "build/" first-name))))
              (should (equal reads '("obiettivo-A.json")))
              (index "B")
              (let ((model (expand-file-name "modello-B.json" reply))
                    (temporary (expand-file-name "modello-in-arrivo" reply)))
                (rename-file model temporary)
                (should-not (gdev-project-programs root))
                (rename-file temporary model))
              (should-not (gdev-project-programs root))
              (artifact "B" second-name)
              (should (equal (gdev-project-programs root) (list (concat "build/" second-name))))
              (should (equal reads '("obiettivo-B.json" "obiettivo-B.json" "obiettivo-A.json"))))))
      (delete-directory root t))))

(ert-deftest gdev-cmake-test-fresh-build-needs-configuration-before-testing ()
  (gdev-cmake-test--load-build)
  (dolist (tool '("cmake" "ctest" "c++"))
    (skip-unless (executable-find tool)))
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "gdev-cmake-flow-" t))))
         (default-directory root)
         (process-environment (copy-sequence process-environment))
         (gdev-cmake-build-directory "build con spazi")
         (gdev-build-settings nil))
    (unwind-protect
        (progn
          (setenv "CCACHE_DIR" (expand-file-name "ccache" root))
          (setenv "CCACHE_TEMPDIR" (expand-file-name "ccache/tmp" root))
          (with-temp-file (expand-file-name "CMakeLists.txt")
            (insert "cmake_minimum_required(VERSION 3.20)\nproject(Smoke LANGUAGES CXX)\n"
                    "add_executable(gdev_flow main.cpp)\nenable_testing()\n"
                    "add_test(NAME smoke COMMAND gdev_flow)\n"))
          (with-temp-file (expand-file-name "main.cpp") (insert "int main() { return 0; }\n"))
          (with-temp-buffer
            (let ((status (call-process-shell-command (gdev-build--command 'test root) nil t)))
              (ert-info ((buffer-string))
                (should (eql status 0))))
            (should (string-match-p "100% tests passed" (buffer-string))))
          (should (equal (gdev-project-programs root)
                         (list (concat "build con spazi/gdev_flow" (if gdev-windows-p ".exe" "")))))
          (should (string-prefix-p "cmake --build " (gdev-build--command 'build root))))
      (delete-directory root t))))

;; Il tipo si sceglie per la radice del progetto CMake, che può essere una
;; sottocartella della radice di project.el.
(ert-deftest gdev-cmake-test-build-type-and-targets-follow-the-build-root ()
  (gdev-cmake-test--load-build)
  (let* ((top (file-name-as-directory (file-truename (make-temp-file "gdev-cmake-radice-" t))))
         (root (file-name-as-directory (expand-file-name "app" top)))
         (default-directory top)
         (gdev-cmake-build-directory "build")
         (gdev-build-settings nil)
         listed)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "build" root) t)
          (with-temp-file (expand-file-name "CMakeLists.txt" root) (insert "project(App)\n"))
          (with-temp-file (expand-file-name "build/CMakeCache.txt" root)
            (insert "CMAKE_HOME_DIRECTORY:INTERNAL=" (directory-file-name root) "\n"))
          (cl-letf (((symbol-function 'gdev-build--root) (lambda () root))
                    ((symbol-function 'completing-read) (lambda (&rest _) "Release"))
                    ((symbol-function 'gdev-build-configure) #'ignore)
                    ((symbol-function 'process-lines-ignore-status)
                     (lambda (&rest command) (push command listed) '("app: phony"))))
            (should-not (equal (gdev-project-root) root))
            (gdev-build-set-type)
            (should (string-match-p "-DCMAKE_BUILD_TYPE=Release" (gdev-cmake-configure-command)))
            (should (equal (gdev-cmake-targets) '("app")))
            (should (equal (nth 2 (car listed)) (expand-file-name "build/" root)))))
      (delete-directory top t))))

;; Lo spazio è il repository e il progetto CMake sta in una sua sottocartella.
(ert-deftest gdev-cmake-test-build-root-finds-the-outermost-subfolder-project ()
  (gdev-cmake-test--load-build)
  (let* ((top (file-name-as-directory (file-truename (make-temp-file "gdev-cmake-annidato-" t))))
         (cpp (file-name-as-directory (expand-file-name "cpp" top)))
         (source (file-name-as-directory (expand-file-name "src/core" cpp))))
    (unwind-protect
        (progn
          (make-directory source t)
          (dolist (directory (list cpp (expand-file-name "src" cpp)))
            (with-temp-file (expand-file-name "CMakeLists.txt" directory) (insert "project(App)\n")))
          (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) top))
                    ((symbol-function 'gdev-workspace-directory) (lambda (&rest _) top)))
            (with-temp-buffer
              (setq default-directory source)
              (should (equal (gdev-build--root) cpp)))
            (with-temp-buffer
              (setq default-directory top)
              (should (equal (gdev-build--root) top)))))
      (delete-directory top t))))

;; F7 e ⌘B con il fuoco in una vista laterale agiscono sul documento, come F5.
(ert-deftest gdev-cmake-test-commands-from-a-side-view-use-the-editor ()
  (gdev-cmake-test--load-build)
  (gdev-test--with-layout
    (let* ((editor (gdev-layout-editor))
           (view (generate-new-buffer "*vista laterale*"))
           (side (display-buffer-in-side-window view '((side . left))))
           windows)
      (unwind-protect
          (cl-letf (((symbol-function 'gdev-launch-dispatch)
                     (lambda (&rest _) (push (selected-window) windows) t)))
            (select-window side)
            (call-interactively #'gdev-build)
            (should (equal windows (list editor)))
            ;; Da Lisp il comando resta dove viene chiamato.
            (select-window side)
            (gdev-build)
            (should (eq (car windows) side))
            (select-window side)
            (call-interactively #'gdev-test-dwim)
            (should (eq (car windows) editor)))
        (kill-buffer view)))))

(provide 'gdev-cmake-test)
;;; gdev-cmake-test.el ends here
