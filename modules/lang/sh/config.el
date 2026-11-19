;;; config.el --- :lang sh: programmi per l'interprete dei comandi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Tree-sitter per i documenti Bash compatibili; ShellCheck segnala i problemi
;; mentre scrivi negli script di shell
;; (tramite Flymake, integrato in Emacs).
;;
;;   C-F5       esegue il programma col suo interprete (ricorda gli argomenti)
;;   C-c c e    esegue la regione in un interprete dei comandi
;;   C-c c f    shfmt, se installato (rispetta .editorconfig)
;;   C-c o r    un interprete dei comandi nella radice del progetto

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-language-modes)

(declare-function sh-execute-region "sh-script")
(defvar sh-basic-offset)
(defvar sh-indent-after-continuation)

(defconst gdev-sh-modes '(sh-mode bash-ts-mode)
  "Modalità principali dei programmi per l'interprete dei comandi.")

(setq sh-basic-offset 4
      sh-indent-after-continuation 'always)

(defun gdev-sh--bash-file-p ()
  "Tieni conto dell'interprete dichiarato prima di scegliere il modo Bash."
  (save-match-data
    (save-excursion
      (goto-char (point-min))
      (if (looking-at auto-mode-interpreter-regexp)
          (equal (match-string-no-properties 2) "bash")
        (and buffer-file-name
             (string-match-p "\\(?:\\.bash\\(?:rc\\|_profile\\|_login\\)?\\|/PKGBUILD\\)\\'" buffer-file-name))))))

(gdev-language-register-tree-sitter 'sh-mode 'bash-ts-mode 'bash #'gdev-sh--bash-file-p)
(add-to-list 'auto-mode-alist '("\\.\\(zsh\\|bash\\)rc\\'" . sh-mode))
(add-to-list 'auto-mode-alist '("/\\.\\(zshenv\\|zprofile\\|bash_profile\\|profile\\)\\'" . sh-mode))

(declare-function gdev-run-file-with "../../tools/build/config")
(declare-function gdev-format-with-program "../../editor/format/config")
(defvar sh-shell)

(defun gdev-sh-run-file (&optional ask-arguments)
  "Esegue il programma aperto con il suo interprete dei comandi.
Con ASK-ARGUMENTS richiede di nuovo gli argomenti."
  (let ((file (or buffer-file-name (user-error "Apri prima il programma da eseguire"))))
    (gdev-run-file-with (list (if (bound-and-true-p sh-shell) (symbol-name sh-shell) "sh"))
                        ask-arguments (file-name-directory file))))

(defun gdev-sh-repl ()
  "Restituisci un buffer shell nella cartella principale del progetto."
  (let ((default-directory (gdev-project-root)))
    (save-window-excursion
      (shell (format "*Terminale · %s*" (abbreviate-file-name (directory-file-name default-directory)))))))

(defun gdev-sh-shfmt ()
  "Formatta l'area di testo con shfmt."
  (unless (executable-find "shfmt") (user-error "shfmt non è installato (brew install shfmt)"))
  (gdev-format-with-program "shfmt" "--filename" (or buffer-file-name "script.sh")))

(gdev-set-runner gdev-sh-modes :run #'gdev-sh-run-file)
(gdev-set-repl gdev-sh-modes #'gdev-sh-repl)
(gdev-set-eval gdev-sh-modes #'sh-execute-region)
(gdev-set-formatter gdev-sh-modes #'gdev-sh-shfmt)
(gdev-set-docsets gdev-sh-modes "bash")

(gdev-doctor-executable "shellcheck" "brew install shellcheck")
(gdev-doctor-executable "shfmt" "brew install shfmt" 'note)

;;; config.el ends here
