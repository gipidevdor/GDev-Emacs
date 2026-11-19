;;; config.el --- :emacs undo: cronologia visiva delle modifiche, salvata tra i riavvii -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; C-/ annulla, C-? ripete (funzioni incluse in Emacs).  C-x u apre l'albero
;; degli annullamenti: percorri ogni stato passato dell'area di
;; testo, rami compresi.  La cronologia si salva con ogni file e
;; torna quando lo riapri.

;;; Code:

(require 'gdev-lib)

(use-package vundo
  :ensure t
  :bind ("C-x u" . vundo)
  :custom (vundo-glyph-alist vundo-unicode-symbols))

(use-package undo-fu-session
  :ensure t
  :hook (emacs-startup . undo-fu-session-global-mode)
  :custom
  (undo-fu-session-directory (gdev-state-file "undo/"))
  (undo-fu-session-incompatible-files
   (append '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'") gdev-sensitive-file-regexps))
  (undo-fu-session-file-limit 2000))

;;; config.el ends here
