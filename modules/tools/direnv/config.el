;;; config.el --- :tools direnv: ambiente locale del progetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; I documenti locali di una cartella con .envrc usano il suo ambiente
;; dopo autorizzazione con M-x envrc-allow. M-x envrc-reload aggiorna
;; l'ambiente dei buffer già aperti. La lettura avviene in background.
;; Se usi anche mise, caricalo dalla .envrc del progetto.

;;; Code:

(require 'gdev-handlers)

(use-package envrc
  :ensure t
  :commands (envrc-mode envrc-allow envrc-reload envrc-deny envrc-show-log)
  :custom (envrc-async t)
  :config (advice-add 'envrc--apply :after #'gdev-direnv--after-apply))

(declare-function gdev-lsp-maybe-start "../../tools/lsp/config")
(defvar envrc--running)

(defun gdev-direnv--after-apply (buffer _result)
  "Ripristina gli strumenti di BUFFER e avvia il suo server quando pronto."
  (with-current-buffer buffer
    (when (and buffer-file-name gdev--project-tools-applied (not envrc--running))
      (gdev-prepend-project-tools (gdev-project-root))
      (when (fboundp 'gdev-lsp-maybe-start)
        (gdev-lsp-maybe-start)))))

(defun gdev-direnv-apply (_root)
  "Attiva direnv per i file locali sotto una configurazione .envrc."
  (when (and (executable-find "direnv")
             (locate-dominating-file default-directory ".envrc"))
    (envrc-mode 1)))

(add-hook 'gdev-project-environment-functions #'gdev-direnv-apply -90)
(gdev-set-tool-actions 'direnv "Ambiente del progetto" "settings"
  ["Autorizza .envrc" envrc-allow]
  ["Ricarica .envrc" envrc-reload]
  ["Mostra il registro di direnv" envrc-show-log]
  ["Revoca autorizzazione .envrc" envrc-deny])

(gdev-doctor-executable "direnv" "brew install direnv" 'note)

;;; config.el ends here
