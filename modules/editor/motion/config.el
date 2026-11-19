;;; config.el --- :editor motion: salta, seleziona, sposta il testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Muoviti nel testo visibile e sposta righe e selezioni con pochi tasti.
;;
;;   M-j          salta a un punto visibile digitando pochi caratteri (avy)
;;   M-g w  M-g L salta a una parola / a una riga
;;   C-+  C-M-+   allarga / restringe la selezione per nodo sintattico (expreg)
;;   M-up M-down  sposta la riga o la selezione con Sposta testo (move-text)
;;   C-c i d      duplica la riga o la selezione

;;; Code:

(require 'gdev-lib)

(use-package avy
  :ensure t
  :bind (("M-j" . avy-goto-char-timer)
         ("M-g w" . avy-goto-word-1)
         ("M-g L" . avy-goto-line)
         :map isearch-mode-map
         ("M-j" . avy-isearch))
  :custom
  (avy-timeout-seconds 0.35)
  (avy-style 'at-full)
  (avy-all-windows t))

(use-package expreg
  :ensure t
  :bind (("C-+" . expreg-expand)
         ("C-M-+" . expreg-contract)))

(use-package gdev-sposta-testo
  :ensure t
  :bind (("M-<up>" . gdev-sposta-testo-su)
         ("M-<down>" . gdev-sposta-testo-giu)))

;;; config.el ends here
