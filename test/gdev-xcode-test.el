;;; gdev-xcode-test.el --- Progetti Xcode nel flusso comune -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'gdev-launch)

(defun gdev-test-xcode--project (root &optional product)
  "Crea in ROOT uno schema il cui prodotto ha un nome diverso."
  (let* ((container (expand-file-name "Progetto Musica.xcodeproj/" root))
         (scheme (expand-file-name "xcshareddata/xcschemes/Prova Mac.xcscheme" container)))
    (make-directory (file-name-directory scheme) t)
    (with-temp-file (expand-file-name "project.pbxproj" container) (insert "// fixture\n"))
    (with-temp-file scheme
      (insert (format "<Scheme><LaunchAction buildConfiguration=\"Debug\"><BuildableProductRunnable><BuildableReference BuildableName=\"%s\"/></BuildableProductRunnable></LaunchAction></Scheme>"
                      (or product "Accordatore Finale.app"))))
    container))

(defmacro gdev-test-xcode--fixture (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev-xcode-con-spazi-" t)))
          (default-directory root)
          (buffers-before (buffer-list))
          (gdev-launch-profiles nil)
          (gdev-launch--native-profiles (make-hash-table :test #'equal))
          (gdev-launch--standalone-selections nil)
          (gdev-launch-selection-change-hook nil)
          (gdev-xcode-build-directory "build/gdev")
          (gdev-xcode-destination "platform=macOS"))
     (unwind-protect
         (progn (gdev-test-xcode--project root) ,@body)
       (dolist (buffer (buffer-list))
         (when (and (not (memq buffer buffers-before)) (buffer-live-p buffer)
                    (with-current-buffer buffer (equal default-directory root)))
           (when-let* ((process (get-buffer-process buffer)))
             (set-process-query-on-exit-flag process nil)
             (delete-process process))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(ert-deftest gdev-test-xcode-profile-reads-product-and-keeps-products-in-project ()
  (gdev-test-xcode--fixture
    (let* ((profile (gdev-xcode-profile root))
           (options (gdev-launch--options profile root))
           (build (plist-get options :build))
           (app (expand-file-name "build/gdev/Build/Products/Debug/Accordatore Finale.app" root)))
      (should (equal "Prova Mac" (car profile)))
      (should (equal (member "-project" build) (nthcdr 1 build)))
      (should (equal "Progetto Musica.xcodeproj" (cadr (member "-project" build))))
      (should (equal (expand-file-name "build/gdev" root) (cadr (member "-derivedDataPath" build))))
      (should (equal '("build") (last build)))
      (should (equal (list "open" "-n" app) (plist-get options :run)))
      (should (equal (expand-file-name "Contents/MacOS/Accordatore Finale" app)
                     (plist-get (plist-get options :debug) :program)))
      (should-not (file-exists-p (expand-file-name "build" root))))))

(ert-deftest gdev-test-xcode-private-profile-prevails-and-view-reads-have-no-io ()
  (gdev-test-xcode--fixture
    (let ((gdev-layout-mode nil)
          (native-comp-enable-subr-trampolines nil))
      (should (equal root (gdev-launch-refresh-native-profile)))
      (cl-letf (((symbol-function 'directory-files) (lambda (&rest _) (ert-fail "Scansione durante il ridisegno")))
                ((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Processo durante il ridisegno"))))
        (dotimes (_ 100)
          (should (equal root (gdev-launch-profile-root)))
          (should (equal "Prova Mac" (car (gdev-launch-selected root))))))
      (let ((gdev-launch-profiles (list (list root '("Personale" :build ("true"))))))
        (should (equal '("Personale" :build ("true")) (car (gdev-launch-profiles-for root))))
        (should-not (gdev-launch-selected root))
        (gdev-launch-refresh-native-profile)
        (should-not (gethash root gdev-launch--native-profiles))))))

(ert-deftest gdev-test-xcode-rejects-products-and-directories-outside-project ()
  (gdev-test-xcode--fixture
    (let ((gdev-xcode-build-directory "../fuori-progetto"))
      (should-error (gdev-xcode-profile root) :type 'user-error))
    (gdev-test-xcode--project root "../../intruso.app")
    (should-error (gdev-xcode-profile root) :type 'user-error)))

(ert-deftest gdev-test-xcode-workspace-precedes-project-and-missing-run-is-explicit ()
  (gdev-test-xcode--fixture
    (let* ((workspace (expand-file-name "Musica.xcworkspace/" root))
           (gdev-layout-mode nil))
      (make-directory workspace)
      (should (equal (directory-file-name workspace) (gdev-xcode-container root)))
      (should (equal "-workspace" (cadr (plist-get (cdr (gdev-xcode-profile root)) :build))))
      (with-temp-file (expand-file-name "xcshareddata/xcschemes/Prova Mac.xcscheme" (expand-file-name "Progetto Musica.xcodeproj/" root))
        (insert "<Scheme><BuildAction/></Scheme>"))
      (gdev-launch-refresh-native-profile)
      (cl-letf (((symbol-function 'gdev-read-program) (lambda (&rest _) (ert-fail "Richiesta manuale inattesa"))))
        (should-error (gdev-launch-dispatch 'run) :type 'user-error)))))

(defun gdev-test-xcode--tools (root)
  "Installa programmi finti: nessun compilatore o applicazione grafica."
  (let ((tools (expand-file-name "tools/" root)))
    (make-directory tools t)
    (dolist (tool '("xcodebuild" "open"))
      (let ((file (expand-file-name tool tools)))
        (with-temp-file file
          (insert "#!/bin/sh\n"
                  (if (equal tool "xcodebuild")
                      "printf 'BUILD\\n' >> events\nprintf '%s\\n' \"$PWD\" \"$@\" >> events\nif test -f fail-build; then exit 7; fi\nprintf 'BUILD-FINITA\\n'\n"
                    "printf 'OPEN\\n' >> events\nprintf '%s\\n' \"$@\" >> events\n")))
        (set-file-modes file #o700)))
    tools))

(ert-deftest gdev-test-xcode-build-from-pane-uses-document-project-without-save-dialogue ()
  "Un buffer modificato senza nome non diventa il programma da compilare."
  (gdev-test-launch--load-tools)
  (gdev-test-xcode--fixture
    (let* ((tools (gdev-test-xcode--tools root))
           (process-environment (cons (concat "PATH=" tools path-separator (getenv "PATH")) process-environment))
           (exec-path (cons tools exec-path))
           (output (format "*%s*" (gdev-build--output-name root))))
      (gdev-test--with-layout
        (gdev-workspace-state-set 'gdev-workspace-roots (list root))
        (let ((source (generate-new-buffer "Documento senza nome · Xcode"))
              (pane (generate-new-buffer "*Comandi di progetto · prova*")))
          (with-current-buffer source (setq default-directory root) (insert "appunti non salvati"))
          (with-current-buffer pane (setq default-directory temporary-file-directory))
          (set-window-buffer (gdev-layout-editor) source)
          (select-window (gdev-layout-show-left pane 'gdev-sidebar))
          (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) (ert-fail "Dialogo di salvataggio inatteso")))
                    ((symbol-function 'read-shell-command) (lambda (&rest _) (ert-fail "Comando manuale inatteso"))))
            (call-interactively #'gdev-build))
          (gdev-test-launch--wait-output output "BUILD-FINITA")
          (gdev-test-launch--wait (lambda () (not (get-buffer-process output))))
          (should (equal "Prova Mac" (car (gdev-launch-selected root))))
          (with-current-buffer source
            (should (buffer-modified-p))
            (should-not buffer-file-name))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "events" root))
            (should (string-search (concat "-derivedDataPath\n" (directory-file-name root) "/build/gdev\nbuild\n") (buffer-string)))
            (should-not (string-search "OPEN" (buffer-string))))
          (with-current-buffer source (set-buffer-modified-p nil))
          (kill-buffer source)
          (kill-buffer pane))))))

(ert-deftest gdev-test-xcode-run-builds-first-and-does-not-launch-after-failure ()
  "Il profilo generato attraversa davvero processi e sentinelle comuni."
  (gdev-test-launch--load-tools)
  (gdev-test-xcode--fixture
    (let* ((tools (gdev-test-xcode--tools root))
           (process-environment (cons (concat "PATH=" tools path-separator (getenv "PATH")) process-environment))
           (exec-path (cons tools exec-path))
           (gdev-layout-mode nil)
           (output (format "*%s*" (gdev-build--output-name root)))
           (events (expand-file-name "events" root)))
      (with-temp-buffer
        (setq default-directory root)
        (should (gdev-launch-dispatch 'run))
        (gdev-test-launch--wait
         (lambda () (and (file-exists-p events)
                         (with-temp-buffer (insert-file-contents events) (string-search "OPEN" (buffer-string))))))
        (gdev-test-launch--wait
         (lambda () (not (seq-some (lambda (process) (and (process-live-p process)
                                                         (equal root (buffer-local-value 'default-directory (process-buffer process)))))
                                   (seq-filter (lambda (process) (buffer-live-p (process-buffer process))) (process-list))))))
        (with-temp-file events)
        (with-temp-file (expand-file-name "fail-build" root))
        (should (gdev-launch-dispatch 'run))
        (gdev-test-launch--wait-output output "codice 7")
        (gdev-test-launch--wait (lambda () (not (get-buffer-process output))))
        (with-temp-buffer
          (insert-file-contents events)
          (should (string-prefix-p "BUILD\n" (buffer-string)))
          (should-not (string-search "OPEN" (buffer-string))))))))

(provide 'gdev-xcode-test)
;;; gdev-xcode-test.el ends here
