;;; gdev-assurance-labels.el --- Lessico italiano del processo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; CLI e viste condividono le etichette. I codici degli archivi e delle
;; integrazioni restano stabili; questo modulo non carica l'interfaccia.

;;; Code:

(defconst gdev-assurance-labels
  '((state
     ("PROPOSED" . "Proposta") ("CLASSIFIED" . "Classificata")
     ("ANALYZED" . "In analisi") ("AUTHORIZED" . "Autorizzata")
     ("IMPLEMENTING" . "In lavorazione") ("VERIFYING" . "In verifica")
     ("REVIEWING" . "In revisione") ("APPROVED" . "Approvata")
     ("BASELINED" . "Consolidata") ("BLOCKED" . "Bloccata")
     ("SUSPENDED" . "Sospesa") ("REJECTED" . "Rifiutata")
     ("CANCELLED" . "Annullata") ("SUPERSEDED" . "Sostituita"))
    (actor ("human" . "Persona") ("agent" . "Agente")
           ("ci" . "CI") ("system" . "Sistema"))
    (profile ("core" . "Essenziale") ("quality" . "Qualità")
             ("secure" . "Sicuro") ("high-assurance" . "Alta garanzia")
             ("critical" . "Critico"))
    (result ("SATISFIED" . "Soddisfatto") ("NOT_SATISFIED" . "Non soddisfatto")
            ("NOT_VERIFIED" . "Da verificare") ("NOT_APPLICABLE" . "Non applicabile")
            ("WAIVED_WITH_AUTHORIZATION" . "Deroga autorizzata"))
    (event ("open" . "Apertura") ("transition" . "Passaggio") ("refusal" . "Rifiuto")
           ("decision" . "Decisione") ("assessment" . "Valutazione")
           ("evidence" . "Prova") ("record" . "Registrazione")))
  "Etichette per stati, attori, profili, esiti ed eventi.")

(defun gdev-assurance-label (group value)
  "Restituisci l'etichetta di VALUE per GROUP, conservando codici sconosciuti."
  (let ((code (if (symbolp value) (symbol-name value) value)))
    (or (cdr (assoc code (cdr (assq group gdev-assurance-labels)))) code)))

(defun gdev-assurance-label-code (group name)
  "Leggi NAME come codice o etichetta italiana per GROUP."
  (unless (stringp name) (user-error "Indica un nome del processo"))
  (let* ((entries (cdr (assq group gdev-assurance-labels)))
         (code (assoc-string name entries t))
         (label (downcase (replace-regexp-in-string "-" " " name))))
    (if code (intern (car code))
      (or (catch 'found
            (dolist (entry entries)
              (when (equal label (downcase (cdr entry)))
                (throw 'found (intern (car entry))))))
          (user-error "%s sconosciuto: %s"
                      (cond ((eq group 'state) "Stato") ((eq group 'profile) "Profilo") (t "Nome")) name)))))

(defun gdev-assurance-state-code (name)
  "Leggi NAME come codice o nome italiano di uno stato del processo."
  (gdev-assurance-label-code 'state name))

(provide 'gdev-assurance-labels)
;;; gdev-assurance-labels.el ends here
