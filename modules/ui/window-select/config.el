;;; config.el --- :ui window-select: salta a una finestra con una lettera -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; M-o etichetta ogni finestra con una lettera della riga centrale della
;; tastiera: digitala per saltarci.  Con due finestre passa semplicemente
;; all'altra.  C-c w x scambia due finestre.

;;; Code:

(require 'gdev-lib)

(use-package ace-window
  :ensure t
  :bind ("M-o" . ace-window)
  :commands ace-swap-window
  :custom
  (aw-keys '(?a ?s ?d ?f ?g ?h ?j ?k ?l))
  (aw-scope 'frame)
  (aw-background nil))

;;; config.el ends here
