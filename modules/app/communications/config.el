;;; config.el --- :app communications: posta, feed e chat IRC -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; M-x gdev-mail apre Gnus. Configura la posta con gnus-select-method e
;; auth-source. M-x gdev-rss apre i feed RSS e Atom di Elfeed.
;; M-x gdev-irc apre una connessione IRC cifrata con TLS.

;;; Code:

(require 'gdev-handlers)

(use-package elfeed
  :ensure t
  :commands (elfeed elfeed-add-feed)
  :custom (elfeed-db-directory (gdev-state-file "elfeed/")))

(declare-function gnus "gnus")
(defun gdev-mail ()
  "Apri la posta e i gruppi di discussione in Gnus."
  (interactive)
  (require 'gnus)
  (gnus))

(defun gdev-rss ()
  "Apri i feed RSS e Atom."
  (interactive)
  (elfeed))

(declare-function erc-tls "erc")
(defun gdev-irc ()
  "Connetti ERC a un server IRC tramite TLS."
  (interactive)
  (require 'erc)
  (call-interactively #'erc-tls))

(gdev-set-tool-actions 'communications "Comunicazioni" "notes"
  ["Connetti a IRC…" gdev-irc]
  ["Posta e gruppi" gdev-mail]
  ["Feed RSS e Atom" gdev-rss]
  ["Aggiungi feed…" elfeed-add-feed])

;;; config.el ends here
