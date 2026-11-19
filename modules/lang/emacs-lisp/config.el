;;; config.el --- :lang emacs-lisp: estendere Emacs dall'interno -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Emacs Lisp, il linguaggio con cui Emacs si estende mentre è in
;; esecuzione:
;;
;;   C-c o r    IELM, l'interprete interattivo di Emacs Lisp
;;   C-c c e    valuta la regione o l'area di testo; C-M-x la
;;              funzione (defun)
;;   C-c c k    descrive il simbolo sotto il cursore
;;   F5         prepara la funzione sotto il cursore per l'esecuzione passo
;;              passo con edebug (SPC avanza)
;;   F6         esegue i test ERT dell'area di testo
;;   C-c l m    espande la macro sotto il cursore, un passo alla volta
;;   C-c l c    compila il file in codice intermedio
;;   C-c l d    controlla la documentazione delle funzioni (checkdoc)

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)

(defvar ielm-history-file-name)

(setq ielm-history-file-name (gdev-state-file "ielm-history"))

(use-package macrostep
  :ensure t
  :commands macrostep-expand)

(defun gdev-elisp-repl ()
  "Restituisce l'area di testo di IELM, avviandolo se serve."
  (save-window-excursion (ielm))
  (get-buffer "*ielm*"))

(defun gdev-elisp-run (&optional _ask-arguments)
  "Valuta il file Emacs Lisp aperto."
  (eval-buffer)
  (message "Valutato %s" (buffer-name)))

(defun gdev-elisp-test ()
  "Valuta l'area di testo ed esegue tutti i test ERT definiti finora."
  (eval-buffer)
  (ert t))
(declare-function ert "ert")

(defun gdev-elisp-documentation ()
  "Descrive il simbolo sotto il cursore."
  (describe-symbol (or (symbol-at-point) (user-error "Nessun simbolo sotto il cursore"))))

(defun gdev-elisp-edebug-defun ()
  "Prepara per edebug la funzione (defun) sotto il cursore.
L'esecuzione si ferma alla sua prossima chiamata."
  (interactive)
  (eval-defun t))

(defconst gdev-elisp-modes '(emacs-lisp-mode lisp-interaction-mode)
  "Modalità principali del codice Emacs Lisp.")

(gdev-set-repl gdev-elisp-modes #'gdev-elisp-repl)
(gdev-set-eval gdev-elisp-modes #'eval-region)
(gdev-set-runner gdev-elisp-modes :run #'gdev-elisp-run :test #'gdev-elisp-test)
(gdev-set-documentation gdev-elisp-modes #'gdev-elisp-documentation)
(gdev-set-debugger gdev-elisp-modes #'gdev-elisp-edebug-defun)
(gdev-set-docsets gdev-elisp-modes "elisp")

(gdev-set-popup-rule "\\`\\*\\(ielm\\|ert\\)\\*\\'" :select t)

(gdev-localleader elisp-mode emacs-lisp-mode-map
  "m" "espandi macro" #'macrostep-expand
  "c" "compila in codice intermedio" #'byte-compile-file
  "d" "controlla documentazione (checkdoc)" #'checkdoc
  "b" "valuta l'intera area di testo" #'eval-buffer
  "t" "esegui test" #'ert
  "x" "esegui funzione passo passo (edebug)" #'gdev-elisp-edebug-defun)

;;; config.el ends here
