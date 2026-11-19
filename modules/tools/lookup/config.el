;;; config.el --- :tools lookup: documentazione locale e in rete -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;;   C-c c k    documentazione dell'elemento sotto il cursore, dalla fonte
;;              del linguaggio (perldoc, HyperSpec, describe-symbol) o dal
;;              server di linguaggio
;;   C-c s k    cerca nella documentazione locale di questo
;;              linguaggio (cppreference, CMake, Perl, MDN...), scaricata
;;              da devdocs.io in raccolte
;;   C-c s o    cerca sul web il simbolo sotto il cursore
;;
;; I moduli dei linguaggi dichiarano la loro documentazione locale con
;; `gdev-set-docsets'; `gdev sync' la scarica una volta sola.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(use-package devdocs
  :ensure t
  :commands (devdocs-lookup devdocs-install devdocs-peruse devdocs-search)
  :custom
  (devdocs-data-dir (gdev-state-file "devdocs/"))
  (devdocs-window-select t))

(defvar devdocs-current-docs)

(defun gdev-lookup--set-docsets ()
  "Indica a devdocs la documentazione locale della modalità principale."
  (when-let* ((docsets (gdev-handler :docsets)))
    (setq-local devdocs-current-docs docsets)))

(add-hook 'after-change-major-mode-hook #'gdev-lookup--set-docsets)

(defun gdev-lookup-documentation ()
  "Mostra la documentazione dell'elemento sotto il cursore."
  (interactive)
  (cond ((gdev-handler :documentation) (funcall (gdev-handler :documentation)))
        ((bound-and-true-p eglot--managed-mode) (eldoc-doc-buffer t))
        ((derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode)
         (describe-symbol (or (symbol-at-point) (user-error "Nessun simbolo sotto il cursore"))))
        (t (call-interactively #'devdocs-lookup))))

(defgroup gdev-lookup nil
  "Documentazione e definizioni."
  :group 'gdev)

(defcustom gdev-lookup-search-url "https://duckduckgo.com/?q=%s"
  "URL usato da `gdev-lookup-online'; %s viene sostituito dalla ricerca."
  :type 'string)

(defun gdev-lookup-online (query)
  "Cerca QUERY sul web (predefinito: il simbolo sotto il cursore)."
  (interactive
   (list (read-string (format-prompt "Cerca sul web" (thing-at-point 'symbol t))
                      nil nil (thing-at-point 'symbol t))))
  (browse-url (format gdev-lookup-search-url (url-hexify-string query))))

;;; config.el ends here
