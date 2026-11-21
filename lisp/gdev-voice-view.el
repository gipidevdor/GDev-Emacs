;;; gdev-voice-view.el --- Controllo della voce accanto al documento -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; La vista consulta lo stato applicativo e richiama i comandi comuni.
;; Aprirla non prepara strumenti, non scarica modelli e non apre il microfono.
;;; Code:
(require 'gdev-voice-audio)
(require 'gdev-ui)
(require 'button)

(declare-function gdev-editor-document "gdev-commands" ())

(define-derived-mode gdev-voice-view-mode special-mode "Voce"
  "Controlla comandi italiani, ascolto e lettura."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (setq-local truncate-lines nil))

(defun gdev-voice-view--button (label command)
  "Inserisci LABEL che richiama COMMAND da tastiera e puntatore."
  (insert-text-button label 'type 'gdev-ui-action 'gdev-voice-action command
                      'action (lambda (_) (call-interactively command)))
  (insert "\n"))

(defun gdev-voice-view-render ()
  "Ridisegna la vista aperta senza cambiare fuoco o pulsante selezionato."
  (when-let* ((buffer (get-buffer "*Voce GDev*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (selected (get-text-property (point) 'gdev-voice-action))
            (position (point)))
        (erase-buffer)
        (insert (propertize "Voce" 'face 'gdev-ui-view-title) "\n\n")
        (insert (if-let* ((status (gdev-voice-status-string))) (string-trim status) "Pronta") "\n")
        (when-let* ((document (gdev-editor-document)))
          (insert (propertize (concat "Documento: " (buffer-name document)) 'face 'gdev-ui-secondary) "\n"))
        (insert "\n")
        (gdev-voice-view--button "Comando in italiano…" #'gdev-voice-execute)
        (gdev-voice-view--button "Leggi testo" #'gdev-voice-read)
        (gdev-voice-view--button "Pausa o riprendi lettura" #'gdev-voice-pause)
        (gdev-voice-view--button "Scegli voce italiana…" #'gdev-voice-select-voice)
        (gdev-voice-view--button "Memorizza correzione vocale…" #'gdev-voice-learn-correction)
        (insert "\n" (propertize "Dettatura facoltativa" 'face 'gdev-ui-view-heading) "\n")
        (if (eq gdev-voice-recognizer 'whisper)
            (progn
              (insert "Whisper locale · italiano\n")
              (gdev-voice-view--button "Dettatura" #'gdev-voice-start-dictation)
              (gdev-voice-view--button "Comando vocale" #'gdev-voice-start-command)
              (gdev-voice-view--button "Disattiva riconoscimento" #'gdev-voice-disable))
          (insert "Disattivata. Nessun modello richiesto dai comandi scritti o dalla lettura.\n")
          (when-let* ((size (gdev-voice-backend-model-size)))
            (insert (format "Pesi del modello: %.0f MB. Gli strumenti si preparano separatamente.\n"
                            (/ size 1000000.0))))
          (gdev-voice-view--button "Attiva riconoscimento locale…" #'gdev-voice-prepare))
        (gdev-voice-view--button "Interrompi voce" #'gdev-voice-stop)
        (gdev-voice-view--button "Diagnosi del motore vocale" #'gdev-voice-diagnostics)
        (insert "\n" (propertize "Come si usa" 'face 'gdev-ui-view-heading) "\n"
                "Ripeti Dettatura per terminare e trascrivere. C-g interrompe.\n"
                "La lettura usa la selezione o il testo dal cursore alla fine; C-u legge tutto.\n"
                "Comandi: «seleziona le ultime due parole», «vai alla riga venti», «salva il file».\n"
                "Durante la dettatura: «comando, seleziona tutto».\n"
                "Punteggiatura: «virgola», «a capo», «apri parentesi». «letterale» conserva la parola.\n")
        (goto-char (or (and selected (text-property-any (point-min) (point-max) 'gdev-voice-action selected))
                       (min position (point-max))))))))

(defun gdev-voice-open ()
  "Apri i controlli accanto al documento senza attivare il riconoscimento."
  (interactive)
  (let ((buffer (get-buffer-create "*Voce GDev*")))
    (with-current-buffer buffer (unless (derived-mode-p 'gdev-voice-view-mode) (gdev-voice-view-mode)))
    (if (bound-and-true-p gdev-layout-mode)
        (pop-to-buffer buffer)
      (select-window (display-buffer-in-side-window buffer '((side . bottom) (window-height . 0.4)))))
    (gdev-voice-view-render)))

(add-hook 'gdev-voice-state-change-hook #'gdev-voice-view-render)
(provide 'gdev-voice-view)
;;; gdev-voice-view.el ends here
