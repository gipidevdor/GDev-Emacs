;;; config.el --- :tools agent: Claude Code dentro Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Claude Code, l'agente che scrive codice, gira in un terminale dentro
;; Emacs per il progetto corrente e dialoga con questo Emacs: vede il file
;; aperto e la selezione, mostra in ediff le differenze da rivedere
;; e usa ciò che Emacs sa già del codice: xref, imenu, i file del progetto,
;; le segnalazioni.
;;
;;   C-c a c    avvia Claude Code per questo progetto, o lo mostra
;;   C-c a C    menu: riprendi, continua, invia la regione, ferma...
;;   C-c a q    ferma una sessione di Claude Code
;;
;; Richiede il comando `claude' (dall'installatore ufficiale di Claude
;; Code, senza npm).
;;
;; Subito dopo l'avvio apre anche il socket privato del server MCP di
;; GDev (`gdev-mcp-server'): gli agenti collegati con bin/gdev-mcp
;; pilotano questa istanza senza avviare altri processi.  Vedi
;; docs/agenti.md.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-handlers)

(gdev-doctor-executable "claude" "brew install --cask claude-code")

(autoload 'gdev-mcp-server-autostart "gdev-mcp-server")
(autoload 'gdev-mcp-server-start "gdev-mcp-server" nil t)
(autoload 'gdev-mcp-server-stop "gdev-mcp-server" nil t)

(unless noninteractive
  ;; Caricare il server costa circa 15 ms: il socket si apre al primo
  ;; secondo di inattività, fuori dal percorso di avvio, e dopo la
  ;; configurazione privata, che può disattivarlo con
  ;; `gdev-agent-mcp-autostart'.
  (run-with-idle-timer 1 nil #'gdev-mcp-server-autostart))

(defvar claude-code-ide-enable-execute-code)

(use-package claude-code-ide
  :ensure t
  :commands (claude-code-ide claude-code-ide-menu claude-code-ide-stop)
  :init
  ;; Il collegamento locale non autentica il client.
  (setq claude-code-ide-enable-execute-code nil)
  :custom
  (claude-code-ide-terminal-backend 'eat)
  (claude-code-ide-use-side-window (not (gdev-module-p :ui 'workbench)))
  (claude-code-ide-use-ide-diff t)      ; rivedi in ediff le modifiche proposte
  :config
  ;; Claude può interrogare xref, imenu, i file del progetto e le segnalazioni.
  (claude-code-ide-emacs-tools-setup))
(declare-function claude-code-ide-emacs-tools-setup "claude-code-ide-emacs-tools")

;;; config.el ends here
