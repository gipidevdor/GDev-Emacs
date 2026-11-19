;;; vista.el --- Modello per una vista di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Copia il modello e rinomina modalità, funzione e caratteristica.
;; Scegli il profilo in base al tipo di contenuto. Vedi docs/interfaccia.md.

;;; Code:

(require 'gdev-command-context)
(require 'gdev-ui)

(define-derived-mode gdev-esempio-mode special-mode "Esempio"
  "Mostra il contenuto del modulo."
  (gdev-ui-view-setup 'document)
  ;; Se le righe mostrano file, i comandi del menu File e del menu
  ;; contestuale agiscono sulla voce della riga corrente.
  (setq-local gdev-command-file-function
              (lambda () (get-text-property (point) 'gdev-esempio-file))))

(defun gdev-esempio-render (command)
  "Disegna la vista vuota con un'azione che richiama COMMAND."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Esempio" 'face 'gdev-ui-view-title) "\n\n")
    (insert (propertize "Nessun elemento" 'face 'gdev-ui-secondary) "\n")
    (insert-text-button "Apri…" 'type 'gdev-ui-action
                        'action (lambda (_) (call-interactively command)))
    (insert "\n")
    (goto-char (point-min))))

(provide 'gdev-esempio)
;;; vista.el ends here
