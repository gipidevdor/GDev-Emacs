;;; gdev-snippets-test.el --- Prove del catalogo YASnippet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica i frammenti del progetto con il parser incluso e prova le
;; entrate utente nella configurazione ordinaria.

;;; Code:

(require 'cl-lib)
(require 'ert)

(ert-deftest gdev-test-snippets-catalog-expands ()
  "Ogni abbreviazione del catalogo ha un nome, un gruppo e un'espansione."
  (require 'yasnippet (expand-file-name "yasnippet" (gdev-bundled-package-directory 'yasnippet)))
  (let* ((root (gdev-config-file "snippets/"))
         (files (directory-files-recursively root "\\`\\(?:dp\\|g\\)-[^/]+\\'"))
         (seen (make-hash-table :test #'equal))
         (yas-good-grace nil))
    (should files)
    (dolist (file files)
      (let* ((relative (file-relative-name file root))
             (mode (car (split-string relative "/")))
             (definition
              (with-temp-buffer
                (insert-file-contents file)
                (yas--parse-template file))))
        (ert-info ((format "Frammento %s" relative))
          (pcase-let ((`(,key ,body ,name ,_condition ,group ,env . ,_) definition))
            (should (equal key (file-name-nondirectory file)))
            (should (not (string-empty-p name)))
            (should group)
            (should-not (gethash (cons mode key) seen))
            (puthash (cons mode key) t seen)
            (with-temp-buffer
              (yas-minor-mode 1)
              (yas-expand-snippet body (point) (point) env)
              (yas-exit-all-snippets)
              (should-not (string-empty-p (string-trim (buffer-string))))
              (should-not (string-match-p "YASESCAPE[0-9]+PROTECTGUARD" (buffer-string))))))))
    (dolist (mode '("c++-mode" "python-mode" "js-mode" "typescript-mode" "java-mode" "csharp-mode"))
      (dolist (pattern '("abstract-factory" "builder" "factory-method" "prototype" "singleton"
                         "adapter" "bridge" "composite" "decorator" "facade" "flyweight" "proxy"
                         "chain-of-responsibility" "command" "interpreter" "iterator" "mediator"
                         "memento" "observer" "state" "strategy" "template-method" "visitor"))
        (ert-info ((format "%s deve avere il pattern %s" mode pattern))
          (should (gethash (cons mode (concat "dp-" pattern)) seen)))))))

(ert-deftest gdev-test-snippets-collection-loads-quietly ()
  "Le direttive descrittive della raccolta non compaiono nell'area dei messaggi."
  (require 'yasnippet (expand-file-name "yasnippet" (gdev-bundled-package-directory 'yasnippet)))
  (let* ((root (expand-file-name "snippets/" (gdev-bundled-package-directory 'yasnippet-snippets)))
         (described (expand-file-name "cc-mode/member_description" root))
         (annotated (expand-file-name "c++-mode/class11" root))
         messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (push (and format (apply #'format-message format args)) messages))))
      (dolist (file (list described annotated))
        (with-temp-buffer
          (insert-file-contents file)
          (let ((yas-verbosity 1))
            (should (nth 2 (yas--parse-template file))))))
      (should-not messages)
      (with-temp-buffer
        (insert-file-contents annotated)
        (let ((yas-verbosity 4))
          (yas--parse-template annotated))))
    (should (seq-some (lambda (text) (string-search "unknown directive" text)) messages))))

(ert-deftest gdev-test-snippets-editor-entry-points ()
  "TAB e il comando Inserisci usano il catalogo nel documento attivo."
  (skip-unless (getenv "GDEV_TEST_SMOKE"))
  (unless (fboundp 'gdev-snippets--completing-prompt)
    (require 'package)
    (package-activate-all)
    (load (gdev-config-file "init.el") nil t))
  (skip-unless (gdev-module-p :editor 'snippets))
  (with-temp-buffer
    (cperl-mode)
    (should yas-minor-mode)
    (insert "script")
    ;; Il frammento Perl esistente proviene dal progetto e si carica alla prima visita.
    (should (eq (key-binding (kbd "TAB")) 'yas-expand))
    (call-interactively (key-binding (kbd "TAB")))
    (should (string-prefix-p "#!/usr/bin/env perl\n" (buffer-string))))
  (with-temp-buffer
    (python-mode)
    (let (choice)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt candidates &rest _)
                   (should (equal prompt "Frammento: "))
                   (setq choice (seq-find (lambda (label) (string-prefix-p "dp-builder  " label))
                                          candidates))
                   (should (string-search "Pattern / Creazionali" choice))
                   choice)))
        (call-interactively (key-binding (kbd "C-c i s"))))
      (should (string-search "class ReportBuilder" (buffer-string)))
      ;; Il primo campo modifica tutte le occorrenze del nome.
      (insert "Summary")
      (should (string-search "class SummaryBuilder" (buffer-string)))
      (yas-exit-all-snippets))
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (keyboard-quit))))
        (should (eq (condition-case nil
                        (call-interactively (key-binding (kbd "C-c i s")))
                      (quit 'annullato))
                    'annullato)))
      (should (equal before (buffer-string))))))

(ert-deftest gdev-test-snippets-typescript-variants ()
  "Uno stesso trigger seleziona la sintassi del file che l'utente apre."
  (skip-unless (getenv "GDEV_TEST_SMOKE"))
  (unless (fboundp 'gdev-snippets--completing-prompt)
    (require 'package)
    (package-activate-all)
    (load (gdev-config-file "init.el") nil t))
  (skip-unless (and (gdev-module-p :lang 'javascript)
                    (gdev-module-p :editor 'snippets)
                    (treesit-language-available-p 'tsx)
                    (treesit-language-available-p 'typescript)))
  (pcase-dolist (`(,file ,mode ,signature)
                '(("Example.jsx" tsx-ts-mode "function total(amount, discount)")
                  ("Example.tsx" tsx-ts-mode "function total(amount: number, discount: Discount)")
                  ("Example.ts" typescript-ts-mode "function total(amount: number, discount: Discount)")))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name file temporary-file-directory))
      (set-auto-mode)
      (should (eq major-mode mode))
      (insert "dp-strategy")
      (let ((yas-fallback-behavior nil)
            ;; Un menu indicherebbe che più varianti rispondono allo stesso trigger.
            (yas-prompt-functions (list (lambda (&rest _) (ert-fail "Trigger ambiguo")))))
        (should (yas-expand)))
      (should (string-search signature (buffer-string))))))

(ert-deftest gdev-test-snippets-terraform-test-files ()
  "Un file .tftest.hcl usa Terraform anche quando HCL è già caricato."
  (skip-unless (getenv "GDEV_TEST_SMOKE"))
  (unless (fboundp 'gdev-snippets--completing-prompt)
    (require 'package)
    (package-activate-all)
    (load (gdev-config-file "init.el") nil t))
  (skip-unless (and (gdev-module-p :tools 'terraform)
                    (gdev-module-p :editor 'snippets)))
  (require 'hcl-mode)
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "checks.tftest.hcl" temporary-file-directory))
    (set-auto-mode)
    (should (eq major-mode 'terraform-mode))
    (let ((yas-fallback-behavior nil))
      (insert "g-tf-for-each")
      (should-not (yas-expand))
      (erase-buffer)
      (insert "g-tf-test")
      (should (yas-expand))
      (should (string-search "command = plan" (buffer-string))))))

;;; gdev-snippets-test.el ends here
