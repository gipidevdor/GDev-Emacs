;;; config.el --- :lang rest: richieste HTTP scritte in Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; In un titolo Org con l'etichetta :verb: scrivi una richiesta HTTP:
;;
;;   * API utenti  :verb:
;;   template https://api.example.com/v1
;;   Authorization: Bearer {{(auth-source-pick-first-password :host "api.example.com")}}
;;   ** Elenco utenti
;;   get /users
;;
;; C-c C-r C-r invia la richiesta sotto il cursore e mostra la risposta.
;; I sottotitoli ereditano URL e intestazioni dei titoli che li
;; contengono.  Le chiavi d'accesso arrivano dal Portachiavi di
;; macOS tramite auth-source: non si scrivono mai nel file.

;;; Code:

(require 'gdev-lib)

(use-package verb
  :ensure t
  :after org
  :demand t
  :config (keymap-set org-mode-map "C-c C-r" verb-command-map))
(defvar org-mode-map)
(defvar verb-command-map)

;;; config.el ends here
