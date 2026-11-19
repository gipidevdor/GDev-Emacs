;;; gdev-assessment-store.el --- Valutazioni registrate nell'archivio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una valutazione registrata conserva, per una transazione, l'esito di ogni
;; controllo, le impronte dei dati da cui è nata e chi l'ha richiesta.  Resta
;; nell'archivio e nella catena di audit come evento `assessment': l'evento
;; riporta le impronte degli ingressi e dei risultati, quindi alterare le righe
;; dei risultati si rileva con `gdev-assessment-store-verify'.
;;
;; Questo file conosce la forma dei dati e li verifica; non calcola nessuna
;; valutazione.  La calcola `gdev-assessment', che registra qui il risultato.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-assurance-db)
(require 'gdev-process)
(require 'gdev-evidence)

(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defun gdev-assessment-store-ref (id)
  "Restituisci l'identificativo leggibile della valutazione numero ID."
  (format "AS-%04d" id))

(defun gdev-assessment-store-digest (results)
  "Restituisci l'impronta SHA-256 di RESULTS, una lista di (CONTROLLO STATO
MOTIVO).  L'ordine fa parte dell'impronta."
  (gdev-evidence-sha256
   (mapconcat (lambda (item) (format "%d|%s|%s|%s\n" (car item) (nth 1 item) (nth 2 item) (nth 3 item)))
              (cl-loop for result in results for position from 1
                       collect (cons position result))
              "")))

(defun gdev-assessment-store-input-digest (tx-id chain-head controls-digest &optional context-digest)
  "Restituisci l'impronta degli ingressi di TX-ID, CHAIN-HEAD e CONTROLS-DIGEST."
  (gdev-evidence-sha256 (concat chain-head "\n" controls-digest "\n" tx-id
                               (and context-digest (concat "\ncontext:" context-digest)))))

(defun gdev-assessment-store--note (input-digest result-digest &optional context-digest)
  "Restituisci la nota dell'evento di una valutazione con le impronte indicate."
  (concat (format "input:%s result:%s" input-digest result-digest)
          (and context-digest (concat " context:" context-digest))))

(defun gdev-assessment-store--rows (data)
  "Restituisci i risultati di DATA, un alist di valutazione, come (CONTROLLO
STATO MOTIVO)."
  (cl-loop for result across (alist-get 'results data)
           collect (list (alist-get 'control result) (alist-get 'status result)
                         (alist-get 'reason result))))

(defun gdev-assessment-store-insert (db tx data actor actor-kind)
  "Registra in DB la valutazione DATA della transazione TX e restituisci il suo
riferimento.  Va chiamata dentro `gdev-process-attempt': scrive le righe e
l'evento nella stessa transazione dell'archivio."
  (let* ((id (alist-get 'id tx))
         (state (alist-get 'state tx))
         (rows (gdev-assessment-store--rows data))
         (result-digest (gdev-assessment-store-digest rows))
         (at (gdev-assurance-db-now))
         (context (let ((value (alist-get 'context_digest data))) (unless (eq :null value) value))))
    (sqlite-execute
     db (if context "insert into assessment
 (tx_id, profile, controls_digest, input_digest, chain_head, result_digest, actor, actor_kind, assessed_at, context_digest)
 values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)" "insert into assessment
 (tx_id, profile, controls_digest, input_digest, chain_head, result_digest, actor, actor_kind, assessed_at)
 values (?, ?, ?, ?, ?, ?, ?, ?, ?)")
     (append (list id (alist-get 'profile data) (alist-get 'controls_digest data)
           (alist-get 'input_digest data) (alist-get 'chain_head data) result-digest
           actor (symbol-name actor-kind) at) (and context (list context))))
    (let* ((number (caar (sqlite-select db "select max(id) from assessment")))
           (ref (gdev-assessment-store-ref number)))
      (cl-loop for row in rows for position from 1
               do (sqlite-execute
                   db "insert into assessment_result (assessment_id, position, control_id, status, reason)
 values (?, ?, ?, ?, ?)"
                   (list number position (car row) (nth 1 row) (nth 2 row))))
      (gdev-process-append-event db id 'assessment state state actor actor-kind
                                 :ref ref
                                 :note (gdev-assessment-store--note (alist-get 'input_digest data)
                                                                    result-digest context)
                                 :at at)
      ref)))

(defun gdev-assessment-store--result-rows (db number)
  "Leggi da DB posizione, controllo, esito e motivo della valutazione NUMBER."
  (sqlite-select db "select position, control_id, status, reason from assessment_result
 where assessment_id = ? order by position" (list number)))

(defun gdev-assessment-store-results (db number)
  "Restituisci i risultati della valutazione NUMBER in DB.
Ogni risultato è (CONTROLLO STATO MOTIVO)."
  (mapcar #'cdr (gdev-assessment-store--result-rows db number)))

(defun gdev-assessment-store-summary (db number)
  "Restituisci per la valutazione NUMBER un alist (STATO . CONTEGGIO).
Gli stati seguono l'ordine di `gdev-assessment-statuses'."
  (let ((counts (sqlite-select db "select status, count(*) from assessment_result
 where assessment_id = ? group by status" (list number))))
    (mapcar (lambda (status)
              (cons status (or (cadr (assoc (symbol-name status) counts)) 0)))
            '(SATISFIED NOT_SATISFIED NOT_VERIFIED NOT_APPLICABLE WAIVED_WITH_AUTHORIZATION))))

(defun gdev-assessment-store-list (db &optional tx-id)
  "Restituisci le valutazioni registrate in DB come alist, dalla prima all'ultima.
Con TX-ID, solo quelle della transazione.  Ogni riga ha :ref e :summary."
  (mapcar (lambda (row)
            (let ((row (gdev-process-symbolize row '(actor_kind))))
              (append (list (cons 'ref (gdev-assessment-store-ref (alist-get 'id row)))
                            (cons 'summary (gdev-assessment-store-summary db (alist-get 'id row))))
                      row)))
          (if tx-id
              (gdev-assurance-db-select db "select * from assessment where tx_id = ? order by id"
                                        (list tx-id))
            (gdev-assurance-db-select db "select * from assessment order by id"))))

(defun gdev-assessment-store-verify (db)
  "Restituisci i problemi fra valutazioni registrate e catena di DB.
Ogni valutazione ha risultati numerati da 1, le impronte di ingressi e
risultati coerenti e il profilo della transazione.  Il suo unico evento
concorda con transazione, attore, tipo d'attore, data e testa della catena;
ogni evento di valutazione ha la sua riga."
  (let ((events (make-hash-table :test #'equal))
        (profiles (make-hash-table :test #'equal))
        problems)
    (dolist (tx (gdev-process-list db))
      (puthash (alist-get 'id tx) (symbol-name (alist-get 'profile tx)) profiles))
    (dolist (event (gdev-assurance-db-select
                    db "select seq, tx_id, ref, note, actor, actor_kind, at, prev_hash
 from tx_event where kind = 'assessment'"))
      (push event (gethash (alist-get 'ref event) events)))
    (dolist (row (gdev-assessment-store-list db))
      (let* ((ref (alist-get 'ref row))
             (found (gethash ref events))
             (result-rows (gdev-assessment-store--result-rows db (alist-get 'id row)))
             (results (mapcar #'cdr result-rows)))
        (unless (equal (alist-get 'profile row) (gethash (alist-get 'tx_id row) profiles))
          (push (format "%s: il profilo non è quello della transazione" ref) problems))
        (unless (equal (alist-get 'input_digest row)
                       (gdev-assessment-store-input-digest
                        (alist-get 'tx_id row) (alist-get 'chain_head row)
                        (alist-get 'controls_digest row) (alist-get 'context_digest row)))
          (push (format "%s: gli ingressi non corrispondono all'impronta registrata" ref) problems))
        (cond ((null results)
               (push (format "%s non ha risultati" ref) problems))
              ((not (equal (mapcar #'car result-rows) (number-sequence 1 (length results))))
               (push (format "%s: le posizioni dei risultati non sono consecutive da 1" ref) problems))
              ((not (equal (alist-get 'result_digest row) (gdev-assessment-store-digest results)))
               (push (format "%s: i risultati non corrispondono all'impronta registrata" ref) problems)))
        (cond ((null found)
               (push (format "%s non ha l'evento nella catena" ref) problems))
              ((cdr found)
               (push (format "%s ha più di un evento nella catena" ref) problems))
              ((not (equal (alist-get 'note (car found))
                           (gdev-assessment-store--note (alist-get 'input_digest row)
                                                        (alist-get 'result_digest row) (alist-get 'context_digest row))))
               (push (format "%s: le impronte non sono quelle dell'evento" ref) problems))
              (t
               (setq problems
                     (append (gdev-process-event-row-problems row (car found) 'assessed_at) problems))
               (unless (equal (alist-get 'chain_head row) (alist-get 'prev_hash (car found)))
                 (push (format "%s: la testa della catena non precede l'evento della valutazione" ref)
                       problems))))
        (remhash ref events)))
    (maphash (lambda (ref found)
               (push (format "%s ha un evento ma nessuna valutazione (evento %d)"
                             ref (alist-get 'seq (car found)))
                     problems))
             events)
    (sort problems #'string<)))

(provide 'gdev-assessment-store)
;;; gdev-assessment-store.el ends here
