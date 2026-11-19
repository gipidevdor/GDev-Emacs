;;; gdev-assurance-lavorazione.el --- Azioni dichiarative del processo -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le macro verificano o propongono. Non approvano e non chiedono input.
;;; Code:
(require 'gdev-assurance)
(declare-function gdev-lavorazione-registra "gdev-lavorazione" (nome descrizione schema funzione &rest properties))
(declare-function gdev-lavorazione-radice "gdev-lavorazione" (contesto))
(declare-function gdev-documents-generate "gdev-documents" (root &optional check))
(declare-function gdev-assurance-request-submit "gdev-assurance-requests" (db tx-id operation arguments &rest properties))

(defun gdev-assurance-lavorazione-verify (context)
  "Verifica l'archivio della radice di CONTEXT."
  (let ((data (gdev-assurance-data "verify" (gdev-lavorazione-radice context))))
    (unless (eq t (alist-get 'ok data)) (user-error "%s" (alist-get 'problems data)))))

(defun gdev-assurance-lavorazione-documents (context)
  "Controlla senza scritture i documenti nella radice di CONTEXT."
  (require 'gdev-documents)
  (when-let* ((different (gdev-documents-generate (gdev-lavorazione-radice context) t)))
    (user-error "Documenti da rigenerare: %s" different)))

(defun gdev-assurance-lavorazione-propose (context transaction operation arguments)
  "Proponi OPERATION con ARGUMENTS JSON per TRANSACTION nella radice di CONTEXT."
  (require 'gdev-assurance-requests)
  (let ((gdev-process-origin 'agent)
        (args (json-parse-string arguments :array-type 'array)))
    (gdev-assurance-db-with-open (db (gdev-lavorazione-radice context) 'write)
      (gdev-assurance-request-submit db transaction operation args))))

(defun gdev-assurance-lavorazione-assess (context transaction &optional standards)
  "Verifica i controlli dovuti di TRANSACTION nella radice di CONTEXT.
Con STANDARDS richiedi anche una scelta di standard esplicita."
  (let* ((data (gdev-assurance-data (if standards "standard-assess" "assess")
                                    (gdev-lavorazione-radice context) transaction))
         (failed (gdev-assurance-blocking-result data)))
    (when (and standards (eq :null (alist-get 'selection (alist-get 'standards data))))
      (user-error "Nessuno standard scelto per %s" transaction))
    (when failed (user-error "%s: %s" (alist-get 'control failed) (alist-get 'reason failed)))))

(defun gdev-assurance-lavorazione-standards (context transaction)
  "Verifica gli standard scelti di TRANSACTION nella radice di CONTEXT."
  (gdev-assurance-lavorazione-assess context transaction t))

(with-eval-after-load 'gdev-lavorazione
  (gdev-lavorazione-registra "assicurazione-verifica" "Verifica archivio e catena del processo."
                            nil #'gdev-assurance-lavorazione-verify :modulo "Assicurazione")
  (gdev-lavorazione-registra "assicurazione-documenti" "Controlla i documenti generati senza modificarli."
                            nil #'gdev-assurance-lavorazione-documents :modulo "Assicurazione")
  (gdev-lavorazione-registra "assicurazione-valuta" "Verifica i controlli dovuti della transazione."
                            '(("transazione" . testo-non-vuoto)) #'gdev-assurance-lavorazione-assess :modulo "Assicurazione")
  (gdev-lavorazione-registra "assicurazione-valuta-standard" "Verifica gli obiettivi degli standard scelti."
                            '(("transazione" . testo-non-vuoto)) #'gdev-assurance-lavorazione-standards :modulo "Assicurazione")
  (gdev-lavorazione-registra "assicurazione-proponi" "Accoda una proposta da confermare, senza eseguirla."
                            '(("transazione" . testo-non-vuoto) ("operazione" . testo-non-vuoto)
                              ("argomenti" . testo-non-vuoto))
                            #'gdev-assurance-lavorazione-propose :modulo "Assicurazione"))

(provide 'gdev-assurance-lavorazione)
;;; gdev-assurance-lavorazione.el ends here
