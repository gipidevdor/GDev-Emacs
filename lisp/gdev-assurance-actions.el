;;; gdev-assurance-actions.el --- Comandi espliciti dell'assicurazione -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le scritture sono comandi distinti dalle letture. MCP propone; la CLI
;; conferma i dati esaminati. L'identità dichiarata non autentica una persona.
;;; Code:
(require 'gdev-assurance)
(require 'gdev-adoption)
(require 'gdev-documents)
(require 'gdev-assurance-git)
(require 'gdev-assurance-requests)
(require 'gdev-standard-assessment)
(require 'gdev-procedures)
(require 'gdev-work)
(declare-function gdev-project-report "gdev-project-report" (root &optional check))

(defconst gdev-assurance-action-contracts
  '(("open" 2 2) ("advance" 2 2) ("evidence" 3 3) ("assess-record" 1 1)
    ("adopt" 1 1) ("recover" 2 2) ("documents" 0 1) ("hooks" 2 2)
    ("sign" 4 4) ("sign-amend" 4 4) ("confirm" 2 2) ("reject" 2 2) ("artifact" 3 3) ("link" 5 5)
    ("standard-select" 3 3) ("standard-proof" 4 4) ("standard-decision" 4 4) ("decision" 4 4)
    ("project-init" 2 2) ("project-bind" 1 1) ("procedure-run" 2 2) ("procedure-resume" 2 2)
    ("project-requirement" 3 3) ("work-bind" 2 2) ("snippet-write" 4 4) ("snippet-preview" 2 2) ("project-report" 0 1) ("project-field" 3 3))
  "Scritture esplicite e arità dei loro operandi.")

(defun gdev-assurance-action-operands-p (command operands)
  "Controlla l'arità e i tipi di OPERANDS per la scrittura COMMAND."
  (when-let* ((entry (assoc command gdev-assurance-action-contracts)))
    (and (proper-list-p operands) (<= (nth 1 entry) (length operands) (nth 2 entry))
         (cl-every #'stringp operands))))

(defun gdev-assurance-action-run (root command operands &optional actor)
  "Esegui la scrittura umana COMMAND su ROOT, con OPERANDS e ACTOR.
CLI e Workbench usano questa entrata. Il canale dell'attore resta quello
del chiamante: una richiesta di agente non diventa umana."
  (unless (gdev-assurance-action-operands-p command operands)
    (user-error "Operandi non validi per %s" command))
  (let* ((actor (or actor (getenv "GDEV_ASSURANCE_ACTOR") (user-login-name)))
         (a (nth 0 operands)) (b (nth 1 operands)) (c (nth 2 operands))
         (d (nth 3 operands)) (e (nth 4 operands))
         (result
          (pcase command
            ("project-init" (gdev-project-initialize root a b))
            ("project-field"
             (let* ((key (intern (concat ":" a))) (data (gdev-project-read root)))
               (unless (assq key gdev-project-required-fields) (user-error "Campo di progetto sconosciuto: %s" a))
               (gdev-project-write-file root gdev-project-manifest (pp-to-string (plist-put data key b)) c)
               (gdev-project-data root)))
            ("project-requirement" (gdev-project-add-requirement root a (gdev-project-snippet-arguments b) c))
            ("snippet-preview"
             (gdev-project-snippet-preview root a (gdev-project-snippet-arguments b)))
            ("project-report"
             (require 'gdev-project-report)
             (unless (member a '(nil "check")) (user-error "Usa project-report oppure project-report check"))
             (when (and (gdev-project-report root (equal a "check")) a) (user-error "Rapporto del progetto da rigenerare"))
             "Rapporto del progetto aggiornato")
            ("adopt" (gdev-adoption-adopt root (intern a) :actor actor :actor-kind 'human))
            ("recover" (gdev-adoption-recover root (intern a) b :actor actor :actor-kind 'human))
            ("documents"
             (unless (member a '(nil "check")) (user-error "Usa documents oppure documents check"))
             (let ((different (gdev-documents-generate root (equal a "check"))))
               (when (and a different) (user-error "Documenti da rigenerare: %s" different))
               (vconcat different)))
            ("hooks"
             (with-temp-buffer
               (unless (zerop (process-file gdev-assurance-git-checker nil t nil "--root" root
                                            "--signers" (expand-file-name a) "--repository" b "install"))
                 (user-error "%s" (buffer-string))))
             "Ganci installati")
            (_
             (gdev-assurance-db-with-open (db root 'write)
               (pcase command
                 ("work-bind" (gdev-work-bind db a root b :actor actor :actor-kind 'human))
                 ("snippet-write"
                  (gdev-project-snippet-apply db a root b (gdev-project-snippet-arguments d) c :actor actor :actor-kind 'human))
                 ("project-bind" (gdev-project-bind db a root :actor actor :actor-kind 'human))
                 ("procedure-run" (gdev-procedures-run db a root b :actor actor :actor-kind 'human))
                 ("procedure-resume"
                  (let* ((start (car (gdev-procedures--rows db a b)))
                         (definition (and start (alist-get 'procedure (gdev-record-data start)))))
                    (unless definition (user-error "Esecuzione non trovata: %s" b))
                    (gdev-procedures-run db a root (alist-get 'id definition) :actor actor :actor-kind 'human :resume b)))
                 ("open" (gdev-process-open db :title a :profile (intern b) :actor actor :actor-kind 'human))
                 ("advance" (gdev-process-advance db a (intern (upcase b)) :actor actor :actor-kind 'human))
                 ("evidence" (gdev-evidence-add db a :kind 'fact :origin 'collected :description b
                                                :file (expand-file-name c root) :actor actor :actor-kind 'human))
                 ("assess-record" (gdev-assessment-record db a :actor actor :actor-kind 'human))
                 ("standard-select" (gdev-standard-select db a (split-string b "," t) c :actor actor :actor-kind 'human))
                 ("standard-proof" (gdev-standard-proof-file db a b c (expand-file-name d root) :actor actor :actor-kind 'human))
                 ("standard-decision" (gdev-standard-decision db a b c d :actor actor :actor-kind 'human))
                 ("decision" (gdev-decision-add db a :control b :kind (intern c) :reason d :actor actor :actor-kind 'human))
                 ("artifact" (gdev-trace-artifact db a root b (intern c) :actor actor :actor-kind 'human))
                 ("link" (gdev-trace-link db a b c (intern d) e :actor actor :actor-kind 'human))
                 ((or "sign" "sign-amend") (gdev-assurance-git-sign db a root b c d :actor actor :actor-kind 'human
                                                                    :amend (equal command "sign-amend")))
                 ((or "confirm" "reject")
                  (gdev-assurance-request-confirm db root a b :actor actor :actor-kind 'human
                                                  :accept (equal command "confirm")))))))))
    result))

(defun gdev-assurance-actions-cli (root command operands)
  "Stampa l'esito di COMMAND con OPERANDS su ROOT e il codice di uscita."
  (if (not (gdev-assurance-action-operands-p command operands))
      (progn (princ "Operandi non validi. Vedi docs/assicurazione/README.md.\n") 2)
    (condition-case err
        (let ((result (gdev-assurance-action-run root command operands)))
          (princ (format "%s\n" (if (or (stringp result) (symbolp result)) result
                                  (decode-coding-string (json-serialize result :null-object :null :false-object :false) 'utf-8-unix))))
          (cond ((equal "CANCELLED" (alist-get 'status (and (listp result) result))) 130)
                ((equal "FAILED" (alist-get 'status (and (listp result) result))) 1) (t 0)))
      (error (princ (format "%s\n" (error-message-string err))) 1))))

(provide 'gdev-assurance-actions)
;;; gdev-assurance-actions.el ends here
