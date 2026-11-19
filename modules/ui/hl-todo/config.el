;;; config.el --- :ui hl-todo: evidenzia TODO, FIXME e simili -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; TODO, FIXME, HACK, NOTE, XXX risaltano nei commenti.  C-c s t li elenca
;; nell'area di testo, C-c p l in tutto il progetto (:tools git).

;;; Code:

(require 'gdev-lib)

(use-package hl-todo
  :ensure t
  :hook ((prog-mode conf-mode yaml-ts-mode) . hl-todo-mode)
  :commands hl-todo-occur)

;;; config.el ends here
