;;; gdev-performance-tools-test.el --- Regressioni degli strumenti concorrenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Prove senza rete con processi di servizio isolati.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-modules)
(require 'so-long)
(require 'treesit)

(defvar gdev-treesit-languages)
(defvar treesit--install-language-grammar-out-dir-history)
(defvar gdev-tree-sitter-auto-max-bytes)
(defvar gdev-tree-sitter-auto-classic-modes)

(ert-deftest gdev-test-tools-gist-publishes-selected-text-in-background ()
  "Il comando ritorna mentre gh attende, poi consegna l'URL negli appunti."
  (skip-unless (executable-find "sh"))
  (load (gdev-module-file :tools 'github ".el") nil t t)
  (let* ((root (make-temp-file "gdev-gist-test-" t))
         (gh (expand-file-name "gh" root))
         (received (expand-file-name "received" root))
         (gate (expand-file-name "gate" root))
         (default-directory (file-name-as-directory root))
         (exec-path (cons root exec-path))
         (process-environment (copy-sequence process-environment))
         (kill-ring nil)
         (interprogram-cut-function nil)
         process)
    (unwind-protect
        (progn
          (setenv "GDEV_TEST_GIST_BODY" received)
          (setenv "GDEV_TEST_GIST_GATE" gate)
          (with-temp-file gh
            (insert "#!/bin/sh\nset -eu\n"
                    "test \"$*\" = 'gist create --filename esempio.el --public -'\n"
                    "cat > \"$GDEV_TEST_GIST_BODY\"\n"
                    "i=0\nwhile test ! -f \"$GDEV_TEST_GIST_GATE\"; do\n"
                    "  test \"$i\" -lt 50 || exit 8\n"
                    "  i=$((i+1))\n  sleep 0.1\ndone\n"
                    "printf '%s\\n' https://gist.example.org/fixture\n"))
          (set-file-modes gh #o755)
          (with-temp-buffer
            (let ((transient-mark-mode t))
              (setq buffer-file-name (expand-file-name "esempio.el" root))
              (insert "aaTèsto selezionatozz")
              (goto-char 3)
              (set-mark (- (point-max) 2))
              (activate-mark)
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                (setq process (gdev-github-gist t)))))
          (should (process-live-p process))
          (should-not kill-ring)
          (write-region "" nil gate nil 'silent)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not kill-ring) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (equal (car kill-ring) "https://gist.example.org/fixture"))
          (with-temp-buffer
            (insert-file-contents received)
            (should (equal (buffer-string) "Tèsto selezionato"))))
      (when (process-live-p process) (delete-process process))
      (delete-directory root t))))

(ert-deftest gdev-test-tools-gist-keeps-the-local-client-for-remote-documents ()
  "I documenti remoti passano il testo a gh locale, senza connessione TRAMP."
  (load (gdev-module-file :tools 'github ".el") nil t t)
  (with-temp-buffer
    (setq default-directory "/ssh:fixture.invalid:/progetto/")
    (insert "testo del documento")
    (cl-letf (((symbol-function 'gdev-github--start)
               (lambda (directory _callback _arguments input)
                 (should-not (file-remote-p directory))
                 (should (equal input "testo del documento"))
                 'started)))
      (should (eq (gdev-github-gist nil) 'started)))))

(ert-deftest gdev-test-tools-javascript-skips-tree-sitter-for-large-and-minified-files ()
  "La selezione per estensione decide prima di interrogare la grammatica."
  (let ((auto-mode-alist (copy-sequence auto-mode-alist))
        (major-mode-remap-defaults nil)
        (major-mode-remap-alist nil)
        (gdev-tree-sitter-auto-max-bytes (* 16 1024))
        (so-long-threshold 10000)
        (prog-mode-hook nil)
        (available t)
        checks)
    (load (gdev-module-file :lang 'javascript ".el") nil t t)
    (cl-letf (((symbol-function 'treesit-ready-p)
               (lambda (language quiet)
                 (should (eq language 'javascript))
                 (should quiet)
                 (cl-incf checks)
                 available))
              ((symbol-function 'js-ts-mode) (lambda () (setq major-mode 'js-ts-mode))))
      (dolist (filename '("prova.js" "prova.mjs" "prova.cjs"))
        (with-temp-buffer
          (setq buffer-file-name filename checks 0)
          (insert "const risposta = 42;\n")
          (set-auto-mode)
          (should (eq major-mode 'js-ts-mode))
          (should (= checks 1))))
      (dolist (source (list (concat "const v = 1;" (make-string 12000 ?\s))
                            (mapconcat #'identity (make-list 200 (make-string 100 ?è)) "\n")))
        (with-temp-buffer
          (setq buffer-file-name "prova.js" checks 0)
          (insert "const risposta = 42;\n" source)
          (set-auto-mode)
          (should (eq major-mode 'js-mode))
          (should (= checks 0))
          (font-lock-ensure (point-min) (min (point-max) (+ (point-min) 22)))
          (should (eq (get-text-property (point-min) 'face) 'font-lock-keyword-face))))
      (with-temp-buffer
        (setq buffer-file-name "prova.js" available nil checks 0)
        (insert "const risposta = 42;\n")
        (set-auto-mode)
        (should (eq major-mode 'js-mode))
        (should (= checks 1)))
      (with-temp-buffer
        (setq buffer-file-name "prova.js" checks 0)
        (insert "// -*- mode: js-ts -*-\n" (make-string 12000 ?\s))
        (set-auto-mode)
        (should (eq major-mode 'js-ts-mode))
        (should (= checks 0))))))

(ert-deftest gdev-test-tools-language-modes-preserve-fallbacks-and-preferences ()
  "Le estensioni usano la politica comune e conservano i gestori disponibili."
  (let ((auto-mode-alist (copy-sequence auto-mode-alist))
        (major-mode-remap-defaults nil)
        (major-mode-remap-alist nil)
        (gdev-tree-sitter-auto-max-bytes 1024)
        (gdev-tree-sitter-auto-classic-modes '(python-mode sh-mode java-mode csharp-mode))
        (prog-mode-hook nil)
        checked)
    (dolist (language '(cc data web sh python java csharp))
      (load (gdev-module-file :lang language ".el") nil t t))
    (cl-letf (((symbol-function 'treesit-ready-p)
               (lambda (grammar quiet)
                 (should quiet)
                 (push grammar checked)
                 nil)))
      (dolist (entry '(("codice.c" "int test(void);\n" c-mode c)
                       ("codice.h" "template <typename T> class Test {};\n" c++-mode cpp)
                       ("codice.ixx" "export module test;\n" c++-mode cpp)
                       ("codice.py" "def test():\n    return 1\n" python-mode nil)
                       ("Codice.java" "class Codice {}\n" java-mode nil)
                       ("Codice.cs" "class Codice {}\n" csharp-mode nil)
                       ("stile.css" "a { color: red; }\n" css-mode css)
                       ("dati.jsonc" "// Nota\n{\"risposta\": 42}\n" js-json-mode json)
                       ("dati.toml" "risposta = 42\n" conf-toml-mode toml)
                       ("codice.sh" "#!/bin/bash\necho test\n" sh-mode nil)))
        (pcase-let ((`(,file ,source ,classic ,grammar) entry))
          (ert-info (file)
            (with-temp-buffer
              (setq buffer-file-name file checked nil)
              (insert source)
              (set-auto-mode)
              (should (eq major-mode classic))
              (should (equal checked (and grammar (list grammar))))
              (pcase classic
                ('conf-toml-mode
                 (should (eq (gdev-handler :format) 'gdev-data-format-toml))
                 (should (equal (plist-get (gdev-handler :eglot) :contact)
                                '("taplo" "lsp" "stdio"))))
                ('js-json-mode
                 (font-lock-ensure (point-min) (point-max))
                 (should (memq (get-text-property (point-min) 'face)
                               '(font-lock-comment-face font-lock-comment-delimiter-face)))))))))
      (let ((gdev-tree-sitter-auto-classic-modes nil))
        (dolist (entry '(("codice.sh" "#!/usr/bin/env -S bash -e\n" bash)
                         ("codice.sh" "#!/bin/sh\n" nil)
                         (".zshrc" "echo test\n" nil)))
          (pcase-let ((`(,file ,source ,grammar) entry))
            (with-temp-buffer
              (setq buffer-file-name file checked nil)
              (insert source)
              (set-auto-mode)
              (should (eq major-mode 'sh-mode))
              (should (equal checked (and grammar (list grammar))))))))
      (with-temp-buffer
        (let ((major-mode-remap-alist '((css-mode . text-mode))))
          (setq buffer-file-name "stile.css" checked nil)
          (set-auto-mode)
          (should (eq major-mode 'text-mode))
          (should-not checked))))))

(ert-deftest gdev-test-tools-grammars-use-a-bounded-pool-and-stage-results ()
  "Due worker avanzano insieme. Le ricette locali seguono l'installatore ordinario."
  (skip-unless (and (executable-find "sh") dynamic-library-suffixes
                    (not (memq system-type '(windows-nt cygwin)))))
  (load (gdev-module-file :tools 'tree-sitter ".el") nil t t)
  (let* ((root (make-temp-file "gdev-grammars-test-" t))
         (user-emacs-directory (file-name-as-directory root))
         (destination (expand-file-name "tree-sitter/" root))
         (gate (expand-file-name "gate" root))
         (gdev-treesit-languages '((first . cl-lib) (second . cl-lib)
                                  (local . cl-lib) (failed . cl-lib) (present . cl-lib)))
         (treesit-language-source-alist '((first "https://example.org/first")
                                          (second "https://example.org/second")
                                          (local "/fake/local-recipe")
                                          (failed "https://example.org/failed")))
         (treesit--install-language-grammar-out-dir-history nil)
         (starter (symbol-function 'gdev-treesit--start-worker))
         (library-name (lambda (language) (format "libtree-sitter-%s%s" language (car dynamic-library-suffixes))))
         (peak 0)
         processes synchronous)
    (unwind-protect
        (cl-letf (((symbol-function 'treesit-language-available-p)
                   (lambda (language &optional _)
                     (or (eq language 'present) (memq language synchronous)
                         (file-exists-p (expand-file-name (funcall library-name language) destination)))))
                  ((symbol-function 'treesit-install-language-grammar)
                   (lambda (language &optional _) (push language synchronous)))
                  ((symbol-function 'gdev-treesit--worker-command)
                   (lambda (recipe staging)
                     (should (memq (car recipe) '(first second failed)))
                     (list "sh" "-c"
                           (concat "i=0; while test ! -f \"$1\"; do "
                                   "test \"$i\" -lt 50 || exit 8; i=$((i+1)); sleep 0.1; done; "
                                   "printf compiled > \"$2\"; test \"$3\" != failed")
                           "gdev-grammar-test" gate
                           (expand-file-name (funcall library-name (car recipe)) staging)
                           (symbol-name (car recipe)))))
                  ((symbol-function 'gdev-treesit--start-worker)
                   (lambda (recipe staging)
                     (let ((process (funcall starter recipe staging)))
                       (push process processes)
                       (setq peak (max peak (cl-count-if #'process-live-p processes)))
                       (when (= (length processes) 2) (write-region "" nil gate nil 'silent))
                       process))))
          (should (equal (gdev-treesit-install-grammars 2) '(failed)))
          (should (equal synchronous '(local)))
          (should (= peak 2))
          (should (= (length processes) 3))
          (should-not (seq-some #'process-live-p processes))
          (should-not (seq-some (lambda (process) (buffer-live-p (process-buffer process))) processes))
          (should-not (directory-files destination nil "\\`\\.gdev-grammars-")))
      (delete-directory root t))))

;;; gdev-performance-tools-test.el ends here
