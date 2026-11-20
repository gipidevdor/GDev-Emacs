;;; gdev-behavior-lsp-test.el --- Fourslash con Eglot e Deno reali -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Input e marcatori provengono da TypeScript 5.7.3. Il server è quello
;; configurato dal modulo JavaScript GDev, senza risposte simulate.
;; Nessun import remoto, npm o collegamento a servizi esterni.

;;; Code:

(require 'eglot)
(require 'xref)

(defun gdev-behavior-with-lsp (file function)
  "Esegui FUNCTION con codice e marcatori Fourslash di FILE e un server vero."
  (gdev-behavior-prerequisite (executable-find "deno") "deno lsp")
  (gdev-behavior-grammar 'typescript)
  (require 'typescript-ts-mode)
  (pcase-let* ((`(,code ,markers)
                (gdev-behavior-fourslash
                 (gdev-behavior-read (concat "upstream/fourslash/tests/cases/fourslash/" file ".ts"))))
               (root (file-name-as-directory (make-temp-file "gdev-fourslash-" t)))
               (path (expand-file-name "documento.ts" root))
               (default-directory root)
               (process-environment (copy-sequence process-environment))
               (auto-mode-alist (copy-tree auto-mode-alist))
               (interpreter-mode-alist (copy-tree interpreter-mode-alist))
               (eglot-server-programs (copy-tree eglot-server-programs))
               (eglot-sync-connect t)
               (eglot-connect-timeout 10)
               (eglot-autoshutdown t)
               (eglot-events-buffer-size 0)
               (eglot-stay-out-of '(flymake eldoc))
               (gdev-lsp-auto-start nil)
               (project-find-functions (list (lambda (_) (cons 'transient root))))
               (buffer nil) (server nil))
    (unwind-protect
        (progn
          (setenv "DENO_DIR" (expand-file-name "deno-cache" root))
          (setenv "DENO_NO_UPDATE_CHECK" "1")
          (with-temp-file (expand-file-name "deno.json" root)
            (insert "{\"lock\":false,\"compilerOptions\":{\"lib\":[\"esnext\"]}}\n"))
          (with-temp-file path (insert code))
          (load (gdev-module-file :lang 'javascript ".el") nil t t)
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (typescript-ts-mode)
            (apply #'eglot (eglot--guess-contact))
            (setq server (eglot-current-server))
            (should server)
            (should (eglot-managed-p))
            (funcall function code markers)
            ;; Completamenti, navigazione e rinomina non salvano da soli.
            (should (equal code (with-temp-buffer (insert-file-contents path) (buffer-string))))))
      (when (and server (jsonrpc-running-p server)) (eglot-shutdown server))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(dolist (entry '(("completionListOnParam" "Blah")
                 ("completionListOnFunctionCallWithOptionalArgument" "q")
                 ("completionListOnMethodParameterName" nil)))
  (let ((file (car entry)) (expected (cadr entry)))
    (gdev-behavior-register
     (intern (concat "gdev-test-behavior-lsp-" file))
     (format "Fourslash %s: completamenti Eglot/Deno al marcatore." file)
     (lambda ()
       (gdev-behavior-with-lsp
        file
        (lambda (code markers)
          (goto-char (cdr (assoc "" markers)))
          (let* ((capf (eglot-completion-at-point))
                 (prefix (when capf (buffer-substring-no-properties (nth 0 capf) (point))))
                 (candidates (when capf (all-completions prefix (nth 2 capf)))))
            (should (equal (mapcar #'substring-no-properties candidates) (when expected (list expected)))))
          (should (equal (buffer-string) code))))) 'lsp)))

(dolist (file '("goToDefinitionSameFile" "goToDefinitionShadowVariable"))
  (gdev-behavior-register
   (intern (concat "gdev-test-behavior-lsp-" file))
   (format "Fourslash %s: xref raggiunge la dichiarazione, anche con nomi oscurati." file)
   (lambda ()
     (gdev-behavior-with-lsp
      file
      (lambda (code markers)
        (let ((references (cl-remove-if-not (lambda (entry) (string-suffix-p "Reference" (car entry))) markers)))
          (should references)
          (dolist (reference references)
            (let ((target (cdr (assoc (string-replace "Reference" "Definition" (car reference)) markers))))
              (should target)
              (goto-char (cdr reference))
              (let* ((definitions (xref-backend-definitions 'eglot (thing-at-point 'symbol t)))
                     (marker (xref-location-marker (xref-item-location (car definitions)))))
                (should (= (length definitions) 1))
                (should (eq (marker-buffer marker) (current-buffer)))
                (should (= (marker-position marker) target))))))
        (should (equal (buffer-string) code))))) 'lsp))

(ert-deftest gdev-test-behavior-lsp-rename-function-parameter ()
  "La rinomina aggiorna parametro, uso e JSDoc, senza salvare il file."
  (gdev-behavior-with-lsp
   "renameFunctionParameter1"
   (lambda (code markers)
     (goto-char (cdr (assoc "" markers)))
     ;; Il comando interattivo risolve anche il backend delle nuove
     ;; versioni di Eglot. Solo il nome digitato viene fornito dalla prova.
     (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "renamed")))
       (let ((this-command 'eglot-rename))
         (call-interactively #'eglot-rename)))
     (let ((expected (replace-regexp-in-string "\\_<p\\_>" "renamed" code)))
       (should-not (equal expected code))
       (should (equal (buffer-string) expected))
       (should (buffer-modified-p))))))

(provide 'gdev-behavior-lsp-test)
;;; gdev-behavior-lsp-test.el ends here
