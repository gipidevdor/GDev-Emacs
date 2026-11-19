;;; gdev-auto-modules-test.el --- Ciclo di vita dei moduli automatici -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'gdev-modules)
(require 'eglot)
(defvar gdev-lsp-auto-start)
(defvar gdev-auto-test-hook nil)
(defun gdev-auto-test--advice-target () nil)
(define-derived-mode gdev-auto-test-mode fundamental-mode "Prova")

(defmacro gdev-auto-test--state (&rest body)
  (declare (indent 0) (debug t))
  `(let ((gdev-modules nil) (gdev-module-load-times nil) (gdev-failed-modules nil)
         (gdev-auto-modules--entries nil) (gdev-auto-modules--owners (make-hash-table :test #'equal))
         (gdev-auto-modules--registration-owners (make-hash-table :test #'eq))
         (gdev--handlers (make-hash-table :test #'eq)) (gdev-project-languages nil)
         (gdev-doctor-checks nil) (gdev-tool-action-groups nil) (gdev-popup-rules nil)
         (eglot-server-programs (copy-tree eglot-server-programs))
         (gdev-lsp-auto-start nil) (auto-mode-alist (copy-sequence auto-mode-alist)))
     (unwind-protect (progn ,@body)
       (let (leases)
         (maphash (lambda (_ record) (maphash (lambda (_ lease) (push lease leases)) (cadr record)))
                  gdev-auto-modules--owners)
         (dolist (lease leases)
           (let ((owner (aref lease 1)))
             (when (buffer-live-p owner)
               (with-current-buffer owner (setq kill-buffer-query-functions nil))
               (kill-buffer owner))
             (gdev-auto-modules-release lease)))))))

(defun gdev-auto-test--module (root name body)
  (let ((file (expand-file-name (format "modules/lang/%s/config.el" name) root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert ";;; -*- lexical-binding: t; -*-\n" body))
    file))

(defmacro gdev-auto-test--fixture (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "gdev-auto-module-" t))
          (gdev-config-directory (file-name-as-directory root))
          (gdev-user-directory (expand-file-name "user/" root)))
     (unwind-protect
         (gdev-auto-test--state
           (gdev-auto-test--module root 'fixture
                                  "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n(gdev-doctor-check \"fixture\" #'ignore \"Prova\")\n")
           ,@body)
       (delete-directory root t))))

(ert-deftest gdev-test-auto-modules-swift-files-activate-share-release-and-reopen ()
  "L'apertura normale colora Swift senza dichiararlo nella configurazione."
  (gdev-auto-modules-initialize)
  (gdev-auto-test--state
    (setq gdev-modules '((:tools build)))
    (unless (fboundp 'gdev-run-dwim) (load (gdev-module-file :tools 'build) nil t))
    (let ((directory (make-temp-file "gdev-auto-swift-" t)) first second)
      (unwind-protect
          (progn
            (dolist (name '("uno.swift" "due.swift"))
              (with-temp-file (expand-file-name name directory)
                (insert "import Foundation\nstruct Prova { let nome: String = \"Ciao\" }\n")))
            (should-not (gdev-module-status :lang 'swift))
            (setq first (find-file-noselect (expand-file-name "uno.swift" directory)))
            (with-current-buffer first
              (should (eq 'swift-mode major-mode))
              (should (keymapp (gdev-menu--language-map)))
              (let* ((group (assq 'language (gdev-command-sidebar--group-sources)))
                     (actions (gdev-command-sidebar--resolve group)))
                (should group)
                (should (memq 'gdev-run-dwim (mapcar #'gdev-command-sidebar--action-command actions)))
                (should (eq (key-binding (kbd "C-c l r")) #'gdev-run-dwim)))
              (font-lock-ensure)
              (goto-char (point-min)) (search-forward "import")
              (should (memq 'swift-mode:keyword-face (ensure-list (get-text-property (1- (point)) 'face)))))
            (setq second (find-file-noselect (expand-file-name "due.swift" directory)))
            (should (= 2 (hash-table-count (cadr (gethash '(:lang swift) gdev-auto-modules--owners)))))
            (kill-buffer first)
            (should (eq 'active (gdev-module-status :lang 'swift)))
            (kill-buffer second)
            (should-not (gdev-module-status :lang 'swift))
            (should-not (alist-get 'swift-mode (gethash :format gdev--handlers)))
            (should-not (assq 'swift gdev-project-languages))
            (should-not (assoc "swift" gdev-doctor-checks))
            (setq first (find-file-noselect (expand-file-name "uno.swift" directory)))
            (should (eq 'active (gdev-module-status :lang 'swift)))
            (kill-buffer first)
            (should (zerop (hash-table-count gdev-auto-modules--owners))))
        (dolist (buffer (list first second)) (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory directory t)))))

(ert-deftest gdev-test-auto-modules-close-cancellation-and-mode-change-preserve-state ()
  (gdev-auto-modules-initialize)
  (gdev-auto-test--fixture
    (let ((buffer (generate-new-buffer " *gdev-auto-close*")))
      (with-current-buffer buffer
        (gdev-auto-modules--call-mode 'fixture #'gdev-auto-test-mode)
        (gdev-auto-modules--call-mode 'fixture #'gdev-auto-test-mode)
        (should (= 1 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners)))))
        (setq-local kill-buffer-query-functions (list (lambda () nil)))
        (should-not (kill-buffer buffer))
        (should (eq 'active (gdev-module-status :lang 'fixture)))
        (setq kill-buffer-query-functions nil)
        (text-mode)
        (should-not gdev-auto-modules--lease)
        (should-not (gdev-module-status :lang 'fixture)))
      (kill-buffer buffer))))

(ert-deftest gdev-test-auto-modules-work-scopes-release-on-error-and-quit ()
  (gdev-auto-test--fixture
    (let ((lease (gdev-auto-modules-acquire :lang 'fixture 'document)))
      (should-error (gdev-with-auto-module (:lang 'fixture) (error "Interruzione")))
      (should (eq 'active (gdev-module-status :lang 'fixture)))
      (should (eq 'quit (condition-case nil
                           (gdev-with-auto-module (:lang 'fixture) (signal 'quit nil))
                         (quit 'quit))))
      (should (= 1 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners)))))
      (gdev-auto-modules-release lease)
      (gdev-auto-modules-release lease)
      (should-not (gdev-module-status :lang 'fixture))
      (should-not (gdev-handler :run 'gdev-auto-test-mode)))))

(ert-deftest gdev-test-auto-modules-configured-choice-and-personal-file-mode-prevail ()
  (gdev-auto-modules-initialize)
  (gdev-auto-test--fixture
    (let ((gdev-modules '((:lang fixture))))
      (should-not (gdev-auto-modules-acquire :lang 'fixture))
      (should-not gdev-auto-modules--entries)
      (should (zerop (hash-table-count gdev-auto-modules--owners))))
    (let ((auto-mode-alist (cons '("\\.swift\\'" . text-mode) auto-mode-alist)))
      (with-temp-buffer
        (setq buffer-file-name "/fixture/personal.swift")
        (set-auto-mode)
        (should (eq 'text-mode major-mode))
        (should-not (gdev-module-status :lang 'swift))))))

(ert-deftest gdev-test-auto-modules-failed-load-rolls-back-and-can-retry ()
  (gdev-auto-test--fixture
    (gdev-auto-test--module root 'fixture
                           "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n(add-to-list 'auto-mode-alist '(\"rotto\" . text-mode))\n(error \"Guasto previsto\")\n")
    (let ((init-file-debug nil)) (should-error (gdev-auto-modules-acquire :lang 'fixture)))
    (should-not (gdev-handler :run 'gdev-auto-test-mode))
    (should-not (assoc "rotto" auto-mode-alist))
    (should-not gdev-auto-modules--entries)
    (should (zerop (hash-table-count gdev-auto-modules--owners)))
    (gdev-auto-test--module root 'fixture "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n")
    (gdev-with-auto-module (:lang 'fixture)
      (should (eq 'active (gdev-module-status :lang 'fixture))))
    (should-not (gdev-module-status :lang 'fixture))))

(ert-deftest gdev-test-auto-modules-release-preserves-other-modules-and-newer-overrides ()
  (gdev-auto-test--fixture
    (gdev-auto-test--module root 'second "(gdev-set-runner 'text-mode :run #'ignore)\n")
    (let ((first (gdev-auto-modules-acquire :lang 'fixture 'one))
          (second (gdev-auto-modules-acquire :lang 'second 'two)))
      (gdev-set-runner 'gdev-auto-test-mode :run #'forward-char)
      (gdev-auto-modules-release first)
      (should (eq #'forward-char (gdev-handler :run 'gdev-auto-test-mode)))
      (should (eq #'ignore (gdev-handler :run 'text-mode)))
      (gdev-auto-modules-release second)
      (should-not (gdev-handler :run 'text-mode)))))

(ert-deftest gdev-test-auto-modules-nested-initialization-keeps-independent-owner ()
  (gdev-auto-test--fixture
    (gdev-auto-test--module root 'second "(gdev-set-runner 'text-mode :run #'ignore)\n")
    (gdev-auto-test--module root 'fixture
                           "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n(gdev-auto-modules-acquire :lang 'second 'nested)\n")
    (let ((first (gdev-auto-modules-acquire :lang 'fixture 'outer)))
      (gdev-auto-modules-release first)
      (should (eq 'active (gdev-module-status :lang 'second)))
      (should (eq #'ignore (gdev-handler :run 'text-mode)))
      (gdev-auto-modules-release (gethash 'nested (cadr (gethash '(:lang second) gdev-auto-modules--owners))))
      (should-not (gdev-handler :run 'text-mode)))))

(ert-deftest gdev-test-auto-modules-cleanup-completes-after-a-failing-callback ()
  (let ((scope (list t)) (done 0))
    (let ((gdev--registration-scope scope))
      (gdev-register-module-cleanup (lambda () (cl-incf done)))
      (gdev-register-module-cleanup (lambda () (error "Rilascio guasto"))))
    (should-error (gdev-module-scope-close scope))
    (should (= 1 done))
    (gdev-module-scope-close scope)
    (should (= 1 done))))

(ert-deftest gdev-test-auto-modules-same-provider-reentrancy-and-mode-failure-are-safe ()
  (gdev-auto-modules-initialize)
  (gdev-auto-test--fixture
    (gdev-auto-test--module root 'fixture
                           "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n(gdev-auto-modules-acquire :lang 'fixture 'nested)\n")
    (let ((outer (gdev-auto-modules-acquire :lang 'fixture 'outer)))
      (should (= 2 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners)))))
      (gdev-auto-modules-release (gethash 'nested (cadr (gethash '(:lang fixture) gdev-auto-modules--owners))))
      (gdev-auto-modules-release outer))
    (gdev-auto-test--module root 'fixture "(gdev-set-runner 'gdev-auto-test-mode :run #'ignore)\n")
    (with-temp-buffer
      (should-error (gdev-auto-modules--call-mode 'fixture (lambda () (gdev-auto-test-mode) (error "Modo guasto"))))
      (should-not gdev-auto-modules--lease)
      (should-not (gdev-module-status :lang 'fixture)))))

(ert-deftest gdev-test-auto-modules-commands-observe-release-after-publication ()
  (gdev-auto-test--fixture
    (gdev-auto-test--module root 'fixture "(gdev-set-tool-actions 'automatic \"Prova\" 'tools [\"Prova\" ignore t])\n")
    (let* (states
           (gdev-tool-actions-change-hook (list (lambda () (push (list (gdev-module-status :lang 'fixture)
                                                                      (and (assq 'automatic gdev-tool-action-groups) t)) states)))))
      (gdev-with-auto-module (:lang 'fixture)
        (should (equal '((active t)) states)))
      (should (equal '((nil nil) (active t)) states)))))

(ert-deftest gdev-test-auto-modules-eglot-deferred-effects-expire-with-their-owner ()
  "Una callback differita non riesuma un modulo già rilasciato."
  (let* ((directory (make-temp-file "gdev-auto-eglot-" t))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GDEV_STATE_DIR" (expand-file-name "state" directory))
          (setenv "GDEV_USER_DIR" (expand-file-name "user" directory))
          (with-temp-buffer
            (let ((code '(progn
                           (require 'gdev-modules)
                           (cl-assert (not (featurep 'eglot)))
                           (let ((scope (gdev-auto-modules--scoped-load
                                         (lambda () (gdev-set-eglot-server 'gdev-auto-fake '("never-start-this"))))))
                             (gdev-module-scope-close scope))
                           (require 'eglot)
                           (cl-assert (not (assoc '(gdev-auto-fake) eglot-server-programs)))
                           (let ((before (copy-tree eglot-server-programs))
                                 (scope (gdev-auto-modules--scoped-load
                                         (lambda () (gdev-set-eglot-server 'gdev-auto-fake '("never-start-this"))))))
                             (cl-assert (assoc '(gdev-auto-fake) eglot-server-programs))
                             (gdev-module-scope-close scope)
                             (cl-assert (equal before eglot-server-programs))))))
              (ert-info ((buffer-string))
                (should (eql 0 (call-process (expand-file-name invocation-name invocation-directory)
                                             nil t nil "--batch" "-Q" "-l" (gdev-config-file "early-init.el")
                                             "-L" (gdev-config-file "lisp") "--eval" (prin1-to-string code))))))))
      (delete-directory directory t))))

(ert-deftest gdev-test-auto-modules-catalogue-providers-release-all-capability-registries ()
  "Ogni fornitore disponibile esegue davvero attivazione e rilascio."
  (gdev-auto-modules-initialize)
  (gdev-auto-test--state
    (dolist (provider gdev-auto-modules-catalogue)
      (ert-info ((format "Fornitore %s" (car provider)))
        (let ((before (list (copy-hash-table gdev--handlers) gdev-project-languages gdev-doctor-checks
                            gdev-tool-action-groups gdev-writing--project-markers)))
          (gdev-with-auto-module (:lang (car provider))
            (should (eq 'active (gdev-module-status :lang (car provider)))))
          (should-not (gdev-module-status :lang (car provider)))
          (should (equal (nth 1 before) gdev-project-languages))
          (should (equal (nth 2 before) gdev-doctor-checks))
          (should (equal (nth 3 before) gdev-tool-action-groups))
          (should (equal (nth 4 before) gdev-writing--project-markers))
          (should (equal (hash-table-keys (car before)) (hash-table-keys gdev--handlers))))))))

(ert-deftest gdev-test-auto-modules-compilation-outlives-document-and-output-buffer ()
  "Il processo conserva il modulo anche quando la vista viene chiusa."
  (gdev-auto-test--fixture
    (let ((source (generate-new-buffer " *gdev-auto-process-source*")) output process)
      (unwind-protect
          (progn
            (with-current-buffer source
              (gdev-auto-modules--call-mode 'fixture #'gdev-auto-test-mode)
              (setq output
                    (gdev-auto-modules--compile
                     (lambda (&rest _)
                       (let ((buffer (generate-new-buffer " *gdev-auto-process*")))
                         (setq process (make-process :name "gdev-auto-lease-test" :buffer buffer
                                                     :command '("/bin/sh" "-c" "sleep 0.1") :noquery t))
                         buffer))))
              (should (= 2 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners))))))
            (kill-buffer source)
            (should (eq 'active (gdev-module-status :lang 'fixture)))
            ;; Scollega la vista senza arrestare il lavoro in corso.
            (set-process-buffer process nil)
            (kill-buffer output)
            (should (eq 'active (gdev-module-status :lang 'fixture)))
            (gdev-test-launch--wait (lambda () (not (gdev-module-status :lang 'fixture))))
            (should (zerop (process-exit-status process))))
        (when (process-live-p process) (delete-process process))
        (dolist (buffer (list source output)) (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-auto-modules-owned-hooks-and-deferred-advice-expire ()
  (let* ((gdev-auto-test-hook '(ignore))
         (scope (list t))
         (gdev--registration-scope scope))
    (gdev-module-add-hook 'gdev-auto-test-hook #'ignore)
    (gdev-module-add-hook 'gdev-auto-test-hook #'forward-char)
    (gdev-module-advice-add 'gdev-auto-test--advice-target :before #'ignore)
    (should (memq #'forward-char gdev-auto-test-hook))
    (gdev-module-scope-close scope)
    (should (equal '(ignore) gdev-auto-test-hook))
    (should-not (advice-member-p #'ignore 'gdev-auto-test--advice-target))
    (let ((features (cons 'gdev-auto-test-deferred features)) late)
      (gdev-module-after-load 'gdev-auto-test-deferred (setq late t))
      (should-not late))))

(ert-deftest gdev-test-auto-modules-compilation-includes-unconfigured-providers-once ()
  (require 'gdev-cli)
  (let ((gdev-modules '((:lang python))))
    (let ((files (gdev-cli--compile-files)))
      (dolist (provider gdev-auto-modules-catalogue)
        (should (= 1 (cl-count (gdev-module-file :lang (car provider) ".el") files :test #'equal))))
      (should-not gdev-auto-modules--entries))))

(ert-deftest gdev-test-auto-modules-shared-hooks-last-owner-and-permanent-adoption ()
  (let ((gdev-auto-test-hook nil)
        (gdev-module--owned-effects (make-hash-table :test #'equal)))
    (dolist (permanent '(nil t))
      (let ((first (list t)) (second (list t)))
        (dolist (scope (list first second))
          (let ((gdev--registration-scope scope))
            (gdev-module-add-hook 'gdev-auto-test-hook #'ignore)
            (gdev-module-advice-add 'gdev-auto-test--advice-target :before #'ignore)))
        (gdev-module-scope-close first)
        (should (memq #'ignore gdev-auto-test-hook))
        (should (advice-member-p #'ignore 'gdev-auto-test--advice-target))
        (when permanent
          (let ((gdev--registration-scope nil))
            (gdev-module-add-hook 'gdev-auto-test-hook #'ignore)
            (gdev-module-advice-add 'gdev-auto-test--advice-target :before #'ignore)))
        (gdev-module-scope-close second)
        (should (eq permanent (and (memq #'ignore gdev-auto-test-hook) t)))
        (should (eq permanent (and (advice-member-p #'ignore 'gdev-auto-test--advice-target) t)))
        (should (zerop (hash-table-count gdev-module--owned-effects)))
        (remove-hook 'gdev-auto-test-hook #'ignore)
        (advice-remove 'gdev-auto-test--advice-target #'ignore)))))

(ert-deftest gdev-test-auto-modules-first-command-line-file-activates-in-ordinary-startup ()
  "L'avvio ordinario non dipende dall'ordine di altri file già visitati."
  (let* ((directory (make-temp-file "gdev-auto-cold-" t))
         (user (expand-file-name "user/" directory))
         (file (expand-file-name "Primo.swift" directory))
         (process-environment (copy-sequence process-environment)) status)
    (unwind-protect
        (progn
          (make-directory user t)
          (with-temp-file (expand-file-name "init.el" user)
            (insert ";;; -*- lexical-binding: t; -*-\n(gdev! :tools build)\n"))
          (with-temp-file file (insert "struct Prova { let numero = 42 }\n"))
          (setenv "GDEV_USER_DIR" user)
          (setenv "GDEV_STATE_DIR" (expand-file-name "state/" directory))
          (with-temp-buffer
            (setq status
                  (call-process
                     (expand-file-name invocation-name invocation-directory) nil t nil
                     "--batch" "-Q" "-l" (gdev-config-file "early-init.el")
                     "--eval" "(package-activate-all)"
                     "-l" (gdev-config-file "init.el") file "--eval"
                     (prin1-to-string
                      '(progn
                         (cl-assert (eq major-mode 'swift-mode))
                         (cl-assert (not (gdev-module--configured-declaration :lang 'swift)))
                         (cl-assert (eq 'active (gdev-module-status :lang 'swift)))
                         (font-lock-ensure)
                         (goto-char (point-min)) (search-forward "struct")
                         (cl-assert (memq 'swift-mode:keyword-face (ensure-list (get-text-property (1- (point)) 'face))))
                         (cl-assert (eq (key-binding (kbd "C-c l r")) 'gdev-run-dwim))
                         (text-mode)
                         (cl-assert (not (gdev-module-status :lang 'swift)))))))
            (ert-info ((buffer-string)) (should (eql status 0)))))
      (delete-directory directory t))))

(ert-deftest gdev-test-auto-modules-compilation-start-error-and-immediate-exit-release ()
  (gdev-auto-test--fixture
    (with-temp-buffer
      (gdev-auto-modules--call-mode 'fixture #'gdev-auto-test-mode)
      (should-error (gdev-auto-modules--compile (lambda () (error "Avvio fallito"))))
      (should (= 1 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners)))))
      (let ((output (generate-new-buffer " *gdev-auto-finished*")))
        (unwind-protect
            (should (eq output (gdev-auto-modules--compile (lambda () output))))
          (kill-buffer output)))
      (should (= 1 (hash-table-count (cadr (gethash '(:lang fixture) gdev-auto-modules--owners))))))))

(ert-deftest gdev-test-auto-modules-swift-repl-keeps-its-own-lease ()
  (gdev-auto-modules-initialize)
  (gdev-auto-test--state
    (let ((source (generate-new-buffer " *gdev-auto-swift-document*"))
          (repl (generate-new-buffer " *gdev-auto-swift-repl*")))
      (unwind-protect
          (progn
            (with-current-buffer source (swift-mode))
            (with-current-buffer repl (swift-repl-mode))
            (kill-buffer source)
            (should (eq 'active (gdev-module-status :lang 'swift)))
            (kill-buffer repl)
            (should-not (gdev-module-status :lang 'swift)))
        (dolist (buffer (list source repl)) (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'gdev-auto-modules-test)
;;; gdev-auto-modules-test.el ends here
