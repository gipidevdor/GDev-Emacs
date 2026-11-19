;;; config.el --- :term eshell: l'interprete dei comandi scritta in Emacs Lisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Eshell è un interprete dei comandi scritto in Emacs Lisp: uguale
;; su ogni sistema, remoto in modo trasparente (cd /ssh:nome-macchina:/var/log
;; funziona), con il Lisp alla richiesta e i risultati in
;; un'area di testo normale.
;;
;;   C-c o e    mostra/nascondi nel pannello l'Eshell del progetto
;;   C-c o E    apri una nuova Eshell nella cartella corrente

;;; Code:

(require 'gdev-lib)
(require 'gdev-workspace-roots)

(defvar eshell-buffer-name)
(defvar eshell-directory-name)
(defvar eshell-history-size)
(defvar eshell-hist-ignoredups)
(defvar eshell-scroll-to-bottom-on-input)
(defvar eshell-destroy-buffer-when-process-dies)
(defvar eshell-visual-commands)

(setq eshell-directory-name (gdev-state-file "eshell/")
      eshell-buffer-name "*Interprete Lisp*"
      eshell-history-size 10000
      eshell-hist-ignoredups t
      eshell-scroll-to-bottom-on-input 'this
      eshell-destroy-buffer-when-process-dies t
      ;; I comandi che richiedono un vero terminale girano in Eat (term/eat).
      eshell-visual-commands '("htop" "top" "less" "more" "vim" "nvim" "ssh" "tail" "watch"))

(defun gdev-eshell-project ()
  "Mostra l'interprete Lisp del progetto corrente.
Richiamato dall'interprete, lo nasconde. Un prefisso apre una sessione nuova
o seleziona la sessione con il numero indicato."
  (interactive)
  (if (and (derived-mode-p 'eshell-mode) (not current-prefix-arg)
           (not (bound-and-true-p project-current-directory-override)))
      (quit-window)
    (let* ((default-directory (or (bound-and-true-p project-current-directory-override)
                                  (gdev-workspace-directory) (gdev-project-root)))
           (eshell-buffer-name (format "*Interprete Lisp · %s*"
                                       (abbreviate-file-name (directory-file-name default-directory)))))
      (eshell current-prefix-arg))))

(defun gdev-eshell-here ()
  "Apre una nuova Eshell nella cartella corrente."
  (interactive)
  (eshell t))

;;; config.el ends here
