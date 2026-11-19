;;; config.el --- :editor fold: nascondi e mostra i blocchi di codice -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; hideshow, incluso in Emacs, è attivo in ogni area di testo di
;; codice: C-c c z piega o riapre il blocco sotto il cursore, C-c c Z
;; tutti i blocchi dell'area di testo.

;;; Code:

(require 'gdev-lib)

(declare-function hs-hide-all "hideshow" ())
(declare-function hs-show-all "hideshow" ())
(declare-function gdev-lavorazione-documento "gdev-lavorazione" (contesto))
(declare-function gdev-lavorazione-registra "gdev-lavorazione"
                  (nome descrizione schema funzione &rest proprieta))
(autoload 'hs-toggle-hiding "hideshow" nil t)

(add-hook 'prog-mode-hook #'hs-minor-mode)

(defvar-local gdev-fold--all-hidden nil "Non nil dopo `hs-hide-all' qui.")

(defun gdev-fold--imposta (nascosti)
  "Piega tutti i blocchi se NASCOSTI, altrimenti espandili."
  (unless (bound-and-true-p hs-minor-mode)
    (user-error "La piegatura non è attiva per %s" major-mode))
  (if nascosti (hs-hide-all) (hs-show-all))
  (setq gdev-fold--all-hidden nascosti))

(defun gdev-fold-toggle-all ()
  "Piega tutti i blocchi dell'area di testo, o li riapre tutti."
  (interactive)
  (gdev-fold--imposta (not gdev-fold--all-hidden)))

(with-eval-after-load 'gdev-lavorazione
  (gdev-lavorazione-registra
   "piega-blocchi" "Piega tutti i blocchi del documento."
   nil (lambda (contesto)
         (with-current-buffer (gdev-lavorazione-documento contesto)
           (gdev-fold--imposta t)))
   :modulo "Piegatura" :richiede-documento t)
  (gdev-lavorazione-registra
   "espandi-blocchi" "Espandi tutti i blocchi del documento."
   nil (lambda (contesto)
         (with-current-buffer (gdev-lavorazione-documento contesto)
           (gdev-fold--imposta nil)))
   :modulo "Piegatura" :richiede-documento t))

;;; config.el ends here
