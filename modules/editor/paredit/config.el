;;; config.el --- :editor paredit: modifica strutturale del codice Lisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; In ogni area di testo con codice Common Lisp o Emacs Lisp, interpreti
;; interattivi compresi, il codice resta sempre bilanciato: C-) ingloba la
;; forma successiva, C-} espelle l'ultima, M-( racchiude in parentesi, M-r
;; sostituisce la forma esterna con quella sotto il cursore. Lo scioglimento
;; è su C-c ( s, la convoluzione su C-c ( c, così M-s (ricerca) e M-?
;; (riferimenti) mantengono il loro significato globale. I livelli di
;; annidamento hanno colori diversi (rainbow-delimiters).

;;; Code:

(require 'gdev-lib)

(defconst gdev-paredit-mode-hooks
  '(lisp-mode-hook emacs-lisp-mode-hook lisp-interaction-mode-hook lisp-data-mode-hook
    sly-mrepl-mode-hook ielm-mode-hook scheme-mode-hook eval-expression-minibuffer-setup-hook)
  "Ganci di ogni area di testo che contiene codice Lisp.")

(defun gdev-paredit--no-electric-pair ()
  "Disattiva `electric-pair-local-mode': paredit accoppia già i delimitatori."
  (electric-pair-local-mode -1))

(use-package paredit
  :ensure t
  :init
  (dolist (hook gdev-paredit-mode-hooks)
    (add-hook hook #'paredit-mode)
    (add-hook hook #'gdev-paredit--no-electric-pair))
  :config
  (keymap-unset paredit-mode-map "M-s" t)
  (keymap-unset paredit-mode-map "M-?" t)
  ;; RET e C-j mantengono il significato abituale (e funzionano nei REPL).
  (keymap-unset paredit-mode-map "RET" t)
  (keymap-unset paredit-mode-map "C-j" t)
  (keymap-set paredit-mode-map "C-c ( s" 'paredit-splice-sexp)
  (keymap-set paredit-mode-map "C-c ( c" 'paredit-convolute-sexp))

(use-package rainbow-delimiters
  :ensure t
  :hook ((lisp-mode emacs-lisp-mode lisp-data-mode sly-mrepl-mode) . rainbow-delimiters-mode))

;;; config.el ends here
