;;; config.el --- :tools llm: Claude in qualsiasi area di testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; gptel invia a Claude un'area di testo, una regione o una
;; conversazione e riporta la risposta in Emacs man mano che arriva:
;;
;;   C-c a a    conversazione in Org: chiedi, leggi, chiedi ancora
;;   C-c a s    invia la regione, o l'area di testo fino al cursore, da ovunque
;;   C-c a r    riscrivi la regione secondo un'istruzione (le differenze
;;              restano da rivedere)
;;   C-c a x    aggiungi la regione o l'area di testo al contesto; C-c a f un file
;;   C-c a m    menu: modello, istruzioni di sistema,
;;              contesto, strumenti
;;   C-c a g    agente: pianifica e usa gli strumenti, chiedendo prima di
;;              ogni azione
;;   C-c a k    interrompi la richiesta in corso
;;
;; La chiave API si legge dal Portachiavi di macOS tramite
;; auth-source, mai da un file.  Salvala una volta sola:
;;   security add-internet-password -a apikey -s api.anthropic.com -w
;; Funziona anche la variabile ANTHROPIC_API_KEY. Le chiamate di strumento
;; chiedono sempre conferma.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(defun gdev-llm-anthropic-key ()
  "Restituisce la chiave API Anthropic da auth-source o da ANTHROPIC_API_KEY."
  (or (when-let* ((entry (car (auth-source-search :host "api.anthropic.com" :user "apikey"
                                                  :require '(:secret))))
                  (secret (plist-get entry :secret)))
        (if (functionp secret) (funcall secret) secret))
      (getenv "ANTHROPIC_API_KEY")
      (user-error "Nessuna chiave API Anthropic: vedi C-h d m tools llm")))

(defconst gdev-llm-claude-models
  '((claude-opus-5-5
     :description "Il più capace: architettura, correzioni (debug) difficili, compiti lunghi"
     :capabilities (media tool-use cache)
     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp" "application/pdf")
     :request-params (:thinking (:type "adaptive")))
    (claude-sonnet-5-5
     :description "Veloce e solido: il codice di tutti i giorni"
     :capabilities (media tool-use cache)
     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp" "application/pdf")
     :request-params (:thinking (:type "adaptive")))
    (claude-haiku-5-5
     :description "Il più veloce: domande rapide, riscritture"
     :capabilities (media tool-use cache)
     :mime-types ("image/jpeg" "image/png" "image/gif" "image/webp" "application/pdf")))
  "Modelli Claude proposti da gptel, dal più capace.")

(use-package gptel
  :ensure t
  :commands (gptel gptel-send gptel-menu gptel-rewrite gptel-add gptel-add-file gptel-abort)
  :custom
  (gptel-default-mode 'org-mode)
  (gptel-max-tokens 32000)
  (gptel-temperature nil)               ; i modelli Claude attuali la rifiutano
  (gptel-include-reasoning nil)         ; il ragionamento resta fuori dal buffer
  (gptel-confirm-tool-calls t)          ; ogni chiamata va approvata
  (gptel-org-branching-context t)       ; ogni titolo Org è un filo a sé
  :config
  (setq gptel-backend (gptel-make-anthropic "Claude"
                        :stream t
                        :key #'gdev-llm-anthropic-key
                        :models gdev-llm-claude-models)
        gptel-model 'claude-opus-5-5))
(declare-function gptel-make-anthropic "gptel-anthropic")

;; `gdev doctor' chiede solo se la chiave esiste: `security' senza -g non
;; legge mai il segreto, quindi il Portachiavi non chiede nulla e non si
;; stampa niente.
(defun gdev-llm-key-present-p ()
  "Restituisce non nil se esiste una chiave API Anthropic.
La cerca nell'ambiente e nel Portachiavi."
  (or (getenv "ANTHROPIC_API_KEY")
      (and gdev-macos-p
           (zerop (call-process "security" nil nil nil "find-internet-password"
                                "-s" "api.anthropic.com" "-a" "apikey")))))

(gdev-doctor-check "Chiave API Anthropic" #'gdev-llm-key-present-p
                   "security add-internet-password -a apikey -s api.anthropic.com -w" 'note)

;; Un ciclo di agente sopra gptel: legge file, cerca, modifica ed esegue
;; comandi, e ogni passo è mostrato e confermato.
(use-package gptel-agent
  :ensure t
  :after gptel
  :commands gptel-agent)

;;; config.el ends here
