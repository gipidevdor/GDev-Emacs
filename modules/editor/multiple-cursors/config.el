;;; config.el --- :editor multiple-cursors: modifica più punti insieme -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Più cursori scrivono insieme in punti diversi dell'area di testo.
;;
;;   C->  C-<    aggiungi un cursore all'occorrenza successiva / precedente
;;   ⌘D         seleziona la parola e aggiungi l'occorrenza successiva
;;   C-M->       salta questa occorrenza
;;   C-c c M     un cursore per occorrenza (nella funzione, poi nell'area di testo)
;;   C-c c L     un cursore su ogni riga della selezione
;;
;; Esc torna a un solo cursore.  Per rinominare un simbolo ovunque meglio
;; C-c c r, che usa il server di linguaggio; su più file,
;; una ricerca esportata con C-. E.

;;; Code:

(require 'gdev-lib)

(defvar mc/keymap)
(declare-function multiple-cursors-mode "multiple-cursors-core")

(defun gdev-cursors-exit ()
  "Torna a un solo cursore e deseleziona il testo."
  (interactive)
  (multiple-cursors-mode -1)
  (deactivate-mark))

(with-eval-after-load 'multiple-cursors-core
  (keymap-set mc/keymap "<escape>" #'gdev-cursors-exit))

(use-package multiple-cursors
  :ensure t
  :bind (("C->" . mc/mark-next-like-this)
         ("C-<" . mc/mark-previous-like-this)
         ("C-M->" . mc/skip-to-next-like-this))
  :commands (mc/mark-all-dwim mc/edit-lines mc/mark-next-like-this-word)
  :custom
  (mc/list-file (gdev-state-file "mc-lists.el")))

;;; config.el ends here
