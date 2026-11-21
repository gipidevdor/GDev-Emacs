;;; config.el --- :lang javascript: JavaScript e TypeScript con Deno -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; JavaScript e TypeScript serviti da Deno: un
;; solo eseguibile autonomo fa da server di linguaggio (tipi,
;; controlli, correzioni rapide), da formattatore e da esecutore dei test,
;; sia per i progetti Deno sia per quelli Node (package.json, specificatori
;; npm: e node:).  Non serve npm.
;;
;;   C-F5       esegue questo file (deno run; node per i .js semplici nei
;;              progetti Node)
;;   F6         esegue i suoi test (deno test, o node --test)
;;   C-c o r    interprete interattivo: deno repl, o node
;;   C-c c f    deno fmt
;;   C-c l d    esecuzione passo passo del file con node inspect;
;;              l'istruzione debugger; fa da punto di interruzione

;;; Code:

(require 'cl-lib)
(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-project-types)
(require 'gdev-keys)
(require 'gdev-language-modes)

(defvar js-indent-level)
(defvar typescript-ts-mode-indent-offset)
(defvar js-base-mode-map)

(defconst gdev-js-modes '(js-ts-mode js-mode typescript-ts-mode tsx-ts-mode)
  "Modalità principali del codice JavaScript e TypeScript.")

(gdev-language-register-tree-sitter 'js-mode 'js-ts-mode 'javascript)
(add-to-list 'auto-mode-alist '("\\.[mc]?js\\'" . js-mode))
(add-to-list 'auto-mode-alist '("\\.[mc]?ts\\'" . typescript-ts-mode))
(add-to-list 'auto-mode-alist '("\\.tsx\\'" . tsx-ts-mode))
(add-to-list 'auto-mode-alist '("\\.jsx\\'" . tsx-ts-mode))

(setq js-indent-level 2
      typescript-ts-mode-indent-offset 2)

;;;; Server di linguaggio

(gdev-set-eglot-server '((js-ts-mode :language-id "javascript")
                         (js-mode :language-id "javascript")
                         (typescript-ts-mode :language-id "typescript")
                         (tsx-ts-mode :language-id "typescriptreact"))
                       '("deno" "lsp" :initializationOptions (:enable t :lint t)))

(gdev-doctor-executable "deno" "brew install deno")

;;;; Formattazione

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-js-deno-fmt ()
  "Formatta l'area di testo con deno fmt e il deno.json del progetto."
  (unless (executable-find "deno") (user-error "deno non è installato (brew install deno)"))
  (gdev-format-with-program "deno" "fmt" "--quiet"
                            (concat "--ext=" (cond ((derived-mode-p 'tsx-ts-mode) "tsx")
                                                   ((derived-mode-p 'typescript-ts-base-mode) "ts")
                                                   (t "js")))
                            "-"))

(gdev-set-formatter gdev-js-modes #'gdev-js-deno-fmt)

;;;; Esecuzione, test, REPL, debug

(declare-function gdev-run-file-with "../../tools/build/config")

(defun gdev-js--deno-p (&optional root)
  "Restituisce non nil se il file aperto va eseguito con Deno.
JavaScript e TypeScript seguono i manifesti del progetto. Per un file
isolato, senza manifesto, usa Deno. ROOT, se presente, indica il pacchetto."
  (not (eq (gdev-project-javascript-runtime
            (or root (gdev-project-javascript-root default-directory (gdev-project-root)))) 'node)))

(defun gdev-js-run-file (&optional ask-arguments)
  "Esegue il file aperto; con ASK-ARGUMENTS richiede di nuovo gli argomenti."
  (let ((root (gdev-project-javascript-root default-directory (gdev-project-root))))
    (gdev-run-file-with (if (gdev-js--deno-p root) '("deno" "run" "--allow-read" "--allow-env") '("node"))
                        ask-arguments root)))

(defun gdev-js-test-file ()
  "Esegue i test del file aperto (deno test, o node --test)."
  (let ((file (or buffer-file-name (user-error "Apri prima il file di test")))
        (root (gdev-project-javascript-root default-directory (gdev-project-root))))
    (save-buffer)
    (gdev-compile (if (gdev-js--deno-p root)
                      (gdev-command-line "deno" "test" (file-local-name file))
                    (gdev-command-line "node" "--test" (file-local-name file)))
                  (format "Test JavaScript · %s" (abbreviate-file-name file)) root)))

(defun gdev-js-repl ()
  "Restituisci un buffer con l'interprete JavaScript di Deno o Node."
  (let* ((default-directory (gdev-project-javascript-root default-directory (gdev-project-root)))
         (name (format "Interprete JavaScript · %s"
                       (abbreviate-file-name (directory-file-name default-directory))))
         (program (if (gdev-js--deno-p default-directory) "deno" "node")))
    (unless (gdev-executable-in program default-directory)
      (user-error "%s non è disponibile per questo progetto" program))
    (make-comint name program nil (if (equal program "deno") "repl" "--interactive"))))

(defun gdev-js-debug-file ()
  "Esegue passo passo del file aperto con lo strumento di diagnosi di Node.
Comandi: c (continua), n (riga successiva), s (entra), o (esci),
sb(riga) (punto di interruzione), repl (valuta), watch('expr').  Si
ferma anche sulle istruzioni `debugger;'."
  (interactive)
  (let ((file (or buffer-file-name (user-error "Apri prima il programma da eseguire passo passo")))
        (default-directory (gdev-project-root)))
    (unless (executable-find "node") (user-error "Node.js non disponibile per l'esecuzione passo passo"))
    (save-buffer)
    (pop-to-buffer (make-comint (format "Debug JavaScript · %s" (abbreviate-file-name file))
                                "node" nil "inspect" (file-local-name file)))))

(gdev-set-runner gdev-js-modes :run #'gdev-js-run-file :test #'gdev-js-test-file)
(gdev-set-repl gdev-js-modes #'gdev-js-repl)
(gdev-set-docsets '(js-ts-mode js-mode) "javascript" "dom" "node")
(gdev-set-docsets '(typescript-ts-mode tsx-ts-mode) "typescript" "javascript" "dom" "deno~2")
(gdev-set-popup-rule "\\`\\*\\(?:Interprete\\|Debug\\) JavaScript · " :select t)

(gdev-localleader js js-base-mode-map
  "d" "esegui passo passo (node inspect)" #'gdev-js-debug-file)

;;; config.el ends here
