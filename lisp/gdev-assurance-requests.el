;;; gdev-assurance-requests.el --- Proposte degli agenti da confermare -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; MCP registra una proposta, senza eseguirla. Una persona legge i dati e
;; conferma il loro digest dalla CLI. La conferma scade a ogni altro evento e
;; si consuma una sola volta. L'azione resta di tipo agent anche dopo il sì.
;; Questo protocollo non autentica chi può eseguire Lisp o scrivere su disco.

;;; Code:

(require 'gdev-assurance)
(require 'gdev-trace)
(require 'gdev-assessment)
(require 'gdev-standard-assessment)

(defun gdev-assurance-request-parse (proposal)
  "Leggi PROPOSAL come JSON completo, rifiutando chiavi duplicate e dati extra."
  (unless (and (stringp proposal) (<= (string-bytes proposal) 32768))
    (gdev-process-refuse "Proposta troppo grande o non testuale"))
  (let ((json-object-type 'alist) (json-array-type 'vector) (json-key-type 'symbol)
        (json-null :null) (json-false :false))
    (with-temp-buffer
      (insert proposal) (goto-char (point-min))
      (let ((data (json-read)))
        (skip-chars-forward " \r\t\n")
        (unless (eobp) (gdev-process-refuse "Dati dopo la proposta"))
        (gdev-record-fields data '(operation arguments))
        (gdev-record-json data)
        data))))

(defun gdev-assurance-request--arguments (operation arguments)
  "Controlla OPERATION e ARGUMENTS senza eseguirli."
  (unless (and (vectorp arguments) (cl-every #'stringp arguments))
    (gdev-process-refuse "Gli argomenti devono essere un vettore di testi"))
  (pcase operation
    ("advance"
     (unless (and (= (length arguments) 1)
                  (member (aref arguments 0) '("CLASSIFIED" "ANALYZED" "IMPLEMENTING" "VERIFYING" "REVIEWING" "BLOCKED")))
       (gdev-process-refuse "Passaggio non offerto agli agenti")))
    ("evidence"
     (unless (= (length arguments) 2) (gdev-process-refuse "Indica descrizione e contenuto"))
     (gdev-process-check-line "La descrizione" (aref arguments 0) 1000)
     (unless (<= (string-bytes (aref arguments 1)) 16384) (gdev-process-refuse "Prova troppo grande")))
    ("assess" (unless (= (length arguments) 0) (gdev-process-refuse "assess non ha argomenti")))
    ("standard-proof"
     (unless (and (= (length arguments) 3) (<= 1 (length (aref arguments 0)) 180)
                  (string-match-p "\\`EV-[0-9]\\{4,18\\}\\'" (aref arguments 1))
                  (member (aref arguments 2) '("pass" "fail")))
       (gdev-process-refuse "Indica obiettivo, prova EV e pass/fail")))
    ("artifact"
     (unless (and (= (length arguments) 3) (gdev-trace-relative-p (aref arguments 0))
                  (member (aref arguments 1) (mapcar #'symbol-name gdev-trace-roles))
                  (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (aref arguments 2)))
       (gdev-process-refuse "Indica percorso relativo, ruolo e SHA-256 dell'artefatto")))
    ("link"
     (unless (and (= (length arguments) 4)
                  (member (aref arguments 2) (mapcar #'symbol-name gdev-trace-relations)))
       (gdev-process-refuse "Indica artefatti, relazione e motivo")))
    (_ (gdev-process-refuse "Operazione non offerta agli agenti: %S" operation))))

(defun gdev-assurance-request--data (db tx data)
  "Controlla i dati storici DATA di una richiesta di TX in DB."
  (gdev-record-fields data '(status operation arguments request) '(failure))
  (when (assq 'failure data) (gdev-process-check-line "L'errore" (alist-get 'failure data) 1000))
  (gdev-assurance-request--arguments (alist-get 'operation data) (alist-get 'arguments data))
  (unless (member (alist-get 'status data) '("pending" "accepted" "rejected"))
    (gdev-process-refuse "Esito della richiesta non valido"))
  (if (equal (alist-get 'status data) "pending")
      (unless (eq :null (alist-get 'request data)) (gdev-process-refuse "Una proposta non cita un'altra richiesta"))
    (let* ((ref (alist-get 'request data)) (row (gdev-record-get db ref))
           (original (and row (gdev-record-data row))))
      (unless (and (eq (alist-get 'kind row) 'request)
                   (equal (alist-get 'tx_id row) (alist-get 'id tx))
                   (equal (alist-get 'status original) "pending")
                   (equal (alist-get 'operation data) (alist-get 'operation original))
                   (equal (alist-get 'arguments data) (alist-get 'arguments original)))
        (gdev-process-refuse "La conferma non corrisponde alla proposta"))
      (when (> (cl-count-if (lambda (item) (equal ref (alist-get 'request (gdev-record-data item))))
                           (gdev-record-list db (alist-get 'id tx) 'request)) 1)
        (gdev-process-refuse "La richiesta è stata consumata più volte")))))

(gdev-record-register 'request #'gdev-assurance-request--data)

(cl-defun gdev-assurance-request-submit (db tx-id operation arguments &key (actor "agente"))
  "Registra una proposta OPERATION con ARGUMENTS di ACTOR per TX-ID, senza
eseguirla."
  (gdev-record-add db tx-id 'request `((status . "pending") (operation . ,operation)
                                     (arguments . ,arguments) (request . :null))
                   :actor actor :actor-kind 'agent))

(defun gdev-assurance-request-enqueue (root tx-id proposal)
  "Accoda PROPOSAL per TX-ID in ROOT dal canale agente, senza creare archivi."
  (let ((data (gdev-assurance-request-parse proposal)) (gdev-process-origin 'agent))
    (unless (and (stringp root) (file-name-absolute-p root) (not (file-remote-p root))
                 (file-directory-p root))
      (gdev-process-refuse "Indica la radice assoluta locale del progetto"))
    (unless (file-regular-p (gdev-assurance-db-file root))
      (signal 'gdev-assurance-db-missing (list root)))
    (gdev-assurance-db-with-open (db root 'write)
      (gdev-trace-root db root)
      (let* ((ref (gdev-assurance-request-submit db tx-id (alist-get 'operation data) (alist-get 'arguments data)))
             (row (gdev-record-get db ref)))
        `((request . ,ref) (digest . ,(alist-get 'digest row)) (status . "pending"))))))

(defun gdev-assurance-request--confirmation-rule (context)
  "Richiedi una persona, i byte esaminati e una richiesta corrente in CONTEXT."
  (let* ((db (plist-get context :db)) (row (gdev-record-get db (plist-get context :request)))
         (data (and row (gdev-record-data row)))
         (last (car (gdev-assurance-db-select db "select ref from tx_event order by seq desc limit 1"))))
    (cond
     ((not (eq (plist-get context :actor-kind) 'human)) "La conferma richiede una persona")
     ((not (and (eq (alist-get 'kind row) 'request) (equal (alist-get 'status data) "pending")))
      "La registrazione non è una proposta")
     ((gdev-assurance-verify db) "L'archivio non è integro: la conferma non può applicare dati alterati")
     ((not (equal (plist-get context :digest) (alist-get 'digest row))) "La proposta è diversa dai dati esaminati")
     ((not (equal (alist-get 'ref row) (alist-get 'ref last))) "La proposta è scaduta o è già stata consumata")
     (t nil))))

(gdev-policy-register 'request-confirm 'origin-binds-actor-kind #'gdev-process--rule-origin)
(gdev-policy-register 'request-confirm 'current-human-confirmation #'gdev-assurance-request--confirmation-rule)

(cl-defun gdev-assurance-request-confirm (db root ref digest &key actor actor-kind (accept t))
  "Conferma REF e DIGEST esaminati, o rifiutali con ACCEPT nil; restituisci
l'esito."
  (gdev-process-check-actor actor actor-kind)
  (gdev-trace-root db root)
  (let* ((row (gdev-record-get db ref)) (data (and row (gdev-record-data row)))
         (id (alist-get 'tx_id row)))
    (unless id (gdev-process-refuse "Richiesta inesistente"))
    (let ((outcome (gdev-process-attempt
     db 'request-confirm id nil actor actor-kind (list :request ref :digest digest)
     (lambda (_tx)
       (let ((operation (alist-get 'operation data))
             (args (append (alist-get 'arguments data) nil)) result failure)
         (when accept
           (condition-case err
            (let ((gdev-process-origin 'agent) (agent (alist-get 'actor row)))
             (setq result
                   (pcase operation
                     ("advance" (gdev-process-advance db id (intern (car args)) :actor agent :actor-kind 'agent))
                     ("evidence" (gdev-evidence-add db id :kind 'fact :origin 'collected :description (car args)
                                                     :content (cadr args) :actor agent :actor-kind 'agent))
                     ("assess" (gdev-assessment-record db id :actor agent :actor-kind 'agent))
                     ("standard-proof" (gdev-standard-proof db id (car args) (cadr args) (nth 2 args)
                                                            :actor agent :actor-kind 'agent))
                     ("artifact"
                      (let ((file (expand-file-name (gdev-trace-relative root (car args)) root)))
                        (unless (and (or (file-symlink-p file) (file-in-directory-p (file-truename file) root))
                                     (equal (nth 2 args) (gdev-trace-file-sha256 file)))
                          (gdev-process-refuse "L'artefatto è cambiato dopo la proposta")))
                      (gdev-trace-artifact db id root (car args) (intern (cadr args)) :actor agent :actor-kind 'agent))
                     ("link" (gdev-trace-link db id (nth 0 args) (nth 1 args) (intern (nth 2 args)) (nth 3 args)
                                              :actor agent :actor-kind 'agent)))))
            (gdev-process-refused (setq failure (error-message-string err) accept nil))))
         (gdev-record-add db id 'request `((status . ,(if accept "accepted" "rejected"))
                                         (operation . ,operation) (arguments . ,(alist-get 'arguments data)) (request . ,ref)
                                         ,@(and failure (list (cons 'failure (truncate-string-to-width failure 1000)))))
                          :actor actor :actor-kind 'human)
         `((request . ,ref) (status . ,(if accept "accepted" "rejected"))
           (result . ,(format "%s" result)) (failure . ,(or failure :null))))))))
      (unless (eq :null (alist-get 'failure outcome)) (gdev-process-refuse "%s" (alist-get 'failure outcome)))
      outcome)))

(provide 'gdev-assurance-requests)
;;; gdev-assurance-requests.el ends here
