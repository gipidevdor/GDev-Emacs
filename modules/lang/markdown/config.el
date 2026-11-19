;;; config.el --- :lang markdown: README, documentazione, note -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Markdown nella variante di GitHub.  I blocchi di codice sono colorati
;; secondo il loro linguaggio; titoli, collegamenti e tabelle si navigano
;; con C-c C-n/p e C-c C-o.  C-c c f formatta con deno fmt; marksman, se
;; installato, aggiunge un server di linguaggio:
;; collegamenti tra file, titoli, riferimenti.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(use-package markdown-mode
  :ensure t
  :mode (("README\\.md\\'" . gfm-mode)
         ("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . markdown-mode))
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-header-scaling t)
  (markdown-enable-wiki-links t)
  (markdown-italic-underscore t)
  (markdown-asymmetric-header t)
  (markdown-gfm-uppercase-checkbox t))

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-markdown-deno-fmt ()
  "Formatta l'area di testo con deno fmt."
  (unless (executable-find "deno") (user-error "deno non è installato (brew install deno)"))
  (gdev-format-with-program "deno" "fmt" "--quiet" "--ext=md" "-"))

(gdev-set-formatter 'markdown-mode #'gdev-markdown-deno-fmt)
(gdev-set-eglot-server '(markdown-mode gfm-mode) '("marksman" "server"))
(gdev-set-docsets 'markdown-mode "markdown")

;; Markdown non è una modalità di programmazione: il server di linguaggio
;; si avvia qui.
(declare-function gdev-lsp-maybe-start "../../tools/lsp/config")
(defun gdev-markdown-maybe-start-lsp ()
  "Avvia marksman qui se tools/lsp è attivo e marksman è installato."
  (when (fboundp 'gdev-lsp-maybe-start)
    (gdev-lsp-maybe-start)))
(gdev-module-add-hook 'markdown-mode-hook #'gdev-markdown-maybe-start-lsp)

;;; config.el ends here
