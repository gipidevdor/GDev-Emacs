;;; gdev-formal.el --- Verifica esaustiva di un modello finito del processo -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Esplora fatti booleani e stati finiti. Confronta i predicati realmente
;; usati dal nucleo con invarianti indipendenti. Non dimostra il runtime Lisp.
;;; Code:
(require 'gdev-project-store)

(defun gdev-formal-check ()
  "Esplora il modello finito delle autorizzazioni e della validità delle prove."
  (let ((cases 0) counterexamples)
    (dolist (state gdev-process-states)
      (dolist (actor '(human agent ci system))
        (let ((reason (gdev-process--rule-human (list :target state :actor-kind actor))))
          (cl-incf cases)
          (when (and (not (eq actor 'human)) (memq state '(AUTHORIZED APPROVED BASELINED REJECTED CANCELLED SUSPENDED SUPERSEDED))
                     (null reason))
            (push `((property . "reserved-human-state") (state . ,(symbol-name state))
                    (actor . ,(symbol-name actor))) counterexamples))))
      (dotimes (bits 8)
        (let* ((defined (/= 0 (logand bits 1))) (fresh (/= 0 (logand bits 2)))
               (verified (/= 0 (logand bits 4)))
               (allowed (gdev-project-ready-p state defined fresh verified)))
          (cl-incf cases)
          (when (and allowed (memq state '(REVIEWING APPROVED BASELINED))
                     (or (not defined) (not fresh) (not verified)))
            (push `((property . "no-unverified-completion") (state . ,(symbol-name state)) (facts . ,bits)) counterexamples))
          (when (and (memq state '(REVIEWING APPROVED BASELINED)) defined verified
                     (gdev-project-ready-p state defined nil verified))
            (push `((property . "change-invalidates-proof") (state . ,(symbol-name state))) counterexamples))
          (when (and defined fresh verified (memq state '(REVIEWING APPROVED BASELINED)) (not allowed))
            (push `((property . "valid-completion-is-reachable") (state . ,(symbol-name state))) counterexamples)))))
    (dolist (from gdev-process-states)
      (dolist (to gdev-process-states)
        (cl-incf cases)
        (when (and (memq from '(PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING))
                   (memq to '(APPROVED BASELINED)) (gdev-process-allowed-p from to))
          (push `((property . "no-lifecycle-shortcut") (from . ,(symbol-name from)) (to . ,(symbol-name to))) counterexamples))))
    `((schema_version . 1) (method . "exhaustive-finite-model") (cases . ,cases)
      (ok . ,(if counterexamples :false t)) (counterexamples . ,(vconcat (nreverse counterexamples)))
      (scope . "14 stati, 4 tipi di attore, 8 combinazioni di completezza/freschezza/verifica e tutte le coppie di stati")
      (assumptions . ["Predicati del nucleo non ridefiniti durante la verifica."
                      "I fatti di ingresso sono calcolati correttamente dagli adattatori, verificati separatamente dai test di integrazione."])
      (limitations . ["Non prova autenticazione, correttezza di SQLite, sistema operativo o tutto il programma Lisp."])
      (human_approval . "NOT_VERIFIED"))))

(provide 'gdev-formal)
;;; gdev-formal.el ends here
