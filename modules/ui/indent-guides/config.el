;;; config.el --- :ui indent-guides: guide di rientro che mostrano l'annidamento -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Sottili guide verticali a ogni livello di rientro, che seguono i blocchi
;; di tree-sitter dove disponibile; il livello corrente è messo in risalto.
;; Sono disegnate con proprietà del testo, non con sovrapposizioni: costano
;; poco anche nei file grandi.

;;; Code:

(require 'gdev-lib)

(use-package indent-bars
  :ensure t
  :hook ((c-ts-base-mode python-base-mode yaml-ts-mode json-ts-mode
          js-base-mode typescript-ts-base-mode css-base-mode
          cperl-mode web-mode cmake-ts-mode) . indent-bars-mode)
  :custom
  (indent-bars-treesit-support t)
  (indent-bars-no-descend-string t)
  (indent-bars-width-frac 0.15)
  (indent-bars-pattern ".")
  (indent-bars-color-by-depth nil)
  (indent-bars-highlight-current-depth '(:blend 0.4)))

;;; config.el ends here
