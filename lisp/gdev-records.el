;;; gdev-records.el --- Registrazioni del processo in sola aggiunta -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Tracce, inventari e richieste condividono persistenza e legame con l'audit.
;; Il modulo proprietario controlla i dati; il nucleo conserva il JSON ordinato
;; e ne lega l'impronta, il genere e i metadati all'evento della catena.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'gdev-process)
(require 'gdev-evidence)

(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))
(declare-function sqlite-execute "sqlite.c" (db query &optional values))

(defconst gdev-record-owners
  '((artifact . gdev-trace) (trace . gdev-trace) (baseline . gdev-adoption)
    (commit . gdev-assurance-git) (request . gdev-assurance-requests)
    (recovery . gdev-adoption) (standard . gdev-standard-assessment)
    (project . gdev-project-store) (run . gdev-procedures))
  "Proprietario dei dati di ogni genere di registrazione.")

(defvar gdev-record--validators (make-hash-table :test #'eq))
(defvar gdev-record--rules (make-hash-table :test #'eq))
(defvar gdev-record--row-validators (make-hash-table :test #'eq))

(defun gdev-record-register (kind validator &optional rule row-validator)
  "Registra VALIDATOR (DB TX DATA) per KIND, con RULE e ROW-VALIDATOR
opzionali.  RULE riceve il contesto di scrittura; ROW-VALIDATOR verifica DB
e la riga storica."
  (unless (and (assq kind gdev-record-owners) (functionp validator)
               (or (null rule) (functionp rule)) (or (null row-validator) (functionp row-validator)))
    (error "Genere o controllo di registrazione non valido: %S" kind))
  (puthash kind validator gdev-record--validators)
  (puthash kind rule gdev-record--rules)
  (puthash kind row-validator gdev-record--row-validators))

(defun gdev-record-ref (id)
  "Restituisci il riferimento della registrazione ID."
  (format "RC-%04d" id))

(defun gdev-record--ordered (value depth)
  "Ordina gli oggetti JSON in VALUE, entro DEPTH livelli."
  (when (> depth 16) (gdev-process-refuse "Dati troppo annidati"))
  (cond
   ((or (stringp value) (memq value '(t :false :null))) value)
   ((and (integerp value) (<= (abs value) 9007199254740991)) value)
   ((vectorp value)
    (vconcat (mapcar (lambda (item) (gdev-record--ordered item (1+ depth))) value)))
   ((and (proper-list-p value)
         (cl-every (lambda (cell) (and (consp cell) (symbolp (car cell))
                                       (let ((case-fold-search nil))
                                         (string-match-p "\\`[a-z][a-z0-9_]*\\'"
                                                         (symbol-name (car cell)))))) value))
    (unless (= (length value) (length (delete-dups (mapcar #'car value))))
      (gdev-process-refuse "Chiavi JSON duplicate"))
    (mapcar (lambda (cell) (cons (car cell) (gdev-record--ordered (cdr cell) (1+ depth))))
            (sort (copy-sequence value)
                  (lambda (a b) (string-lessp (symbol-name (car a)) (symbol-name (car b)))))))
   (t (gdev-process-refuse "Valore JSON non ammesso: %S" value))))

(defun gdev-record-encode (data)
  "Serializza DATA come oggetto JSON ordinato, senza limiti di dimensione."
  (unless (and (consp data) (proper-list-p data))
    (gdev-process-refuse "La registrazione richiede un oggetto di dati"))
  (decode-coding-string
               (json-serialize (gdev-record--ordered data 0)
                               :null-object :null :false-object :false) 'utf-8-unix))

(defun gdev-record-json (data)
  "Serializza DATA come registrazione JSON ordinata, entro 128 KiB."
  (let ((json (gdev-record-encode data)))
    (when (> (string-bytes json) 131072) (gdev-process-refuse "Registrazione troppo grande"))
    json))

(defun gdev-record-fields (data required &optional optional)
  "Controlla le chiavi REQUIRED e OPTIONAL dell'oggetto DATA."
  (unless (and (proper-list-p data) (cl-every #'consp data)
               (cl-every (lambda (key) (assq key data)) required)
               (cl-every (lambda (cell) (memq (car cell) (append required optional))) data))
    (gdev-process-refuse "Campi della registrazione non validi: richiesti %S" required)))

(defun gdev-record--validate (db tx kind data)
  "Controlla DATA secondo il proprietario di KIND nella transazione TX di DB."
  (let ((owner (cdr (assq kind gdev-record-owners))))
    (unless owner (gdev-process-refuse "Genere di registrazione sconosciuto: %S" kind))
    (unless (gethash kind gdev-record--validators) (require owner))
    (let ((validator (gethash kind gdev-record--validators)))
      (unless validator (gdev-process-refuse "Manca il controllo di %s" kind))
      (funcall validator db tx data))))

(defun gdev-record--rule (context)
  "Controlla genere, dati e stato della registrazione di CONTEXT."
  (let ((kind (plist-get context :record-kind))
        (tx (plist-get context :tx)))
    (cond
     ((and (memq kind '(baseline recovery)) (not (eq (plist-get context :actor-kind) 'human)))
      "Inventario iniziale e recupero richiedono una persona")
     ((and (memq (alist-get 'state tx) '(BASELINED REJECTED CANCELLED SUPERSEDED))
           (not (eq kind 'commit)))
      "Una transazione conclusa non accetta registrazioni nuove")
     (t (gdev-record--validate (plist-get context :db) tx kind (plist-get context :data))
        (when-let* ((rule (gethash kind gdev-record--rules))) (funcall rule context))))))

(gdev-policy-register 'record 'origin-binds-actor-kind #'gdev-process--rule-origin)
(gdev-policy-register 'record 'record-data #'gdev-record--rule)

(cl-defun gdev-record-add (db tx-id kind data &key actor actor-kind)
  "Registra DATA di KIND in DB per TX-ID; restituisci il riferimento."
  (gdev-process-check-actor actor actor-kind)
  (let* ((json (gdev-record-json data)) (digest (gdev-evidence-sha256 json)))
    (gdev-process-attempt
     db 'record tx-id nil actor actor-kind (list :record-kind kind :data data)
     (lambda (tx)
       (let ((at (gdev-assurance-db-now)) (state (alist-get 'state tx)))
         (sqlite-execute db "insert into assurance_record
 (tx_id, kind, payload, digest, actor, actor_kind, recorded_at) values (?, ?, ?, ?, ?, ?, ?)"
                         (list tx-id (symbol-name kind) json digest actor (symbol-name actor-kind) at))
         (let ((ref (gdev-record-ref (caar (sqlite-select db "select max(id) from assurance_record")))))
           (gdev-process-append-event db tx-id 'record state state actor actor-kind
                                      :ref ref :note (format "%s sha256:%s" kind digest) :at at)
           ref))))))

(defun gdev-record-list (db &optional tx-id kind)
  "Leggi le registrazioni di DB; con TX-ID o KIND filtra le righe."
  (let ((query "select * from assurance_record where 1 = 1") values)
    (when tx-id (setq query (concat query " and tx_id = ?") values (list tx-id)))
    (when kind (setq query (concat query " and kind = ?")
                     values (append values (list (symbol-name kind)))))
    (mapcar (lambda (row)
              (append (list (cons 'ref (gdev-record-ref (alist-get 'id row))))
                      (gdev-process-symbolize row '(kind actor_kind))))
            (gdev-assurance-db-select db (concat query " order by id") values))))

(defun gdev-record-data (row)
  "Leggi il contenuto JSON della registrazione ROW senza valutarlo."
  (json-parse-string (alist-get 'payload row) :object-type 'alist :array-type 'array
                     :null-object :null :false-object :false))

(defun gdev-record-get (db ref)
  "Restituisci la registrazione REF di DB, o nil."
  (when (and (stringp ref) (let ((case-fold-search nil))
                           (string-match "\\`RC-\\([0-9]\\{1,18\\}\\)\\'" ref)))
    (let ((number (string-to-number (match-string 1 ref))))
      (when-let* ((canonical (equal ref (gdev-record-ref number)))
                  (row (car (gdev-assurance-db-select
                            db "select * from assurance_record where id = ?" (list number)))))
        (append (list (cons 'ref (gdev-record-ref number)))
                (gdev-process-symbolize row '(kind actor_kind)))))))

(defun gdev-record--verify (db)
  "Restituisci le incongruenze delle registrazioni e dei loro eventi in DB."
  (let ((events (make-hash-table :test #'equal)) problems)
    (dolist (event (gdev-assurance-db-select db "select * from tx_event where kind = 'record'"))
      (push event (gethash (alist-get 'ref event) events)))
    (dolist (row (gdev-record-list db))
      (let* ((ref (alist-get 'ref row)) (found (gethash ref events))
             (kind (alist-get 'kind row)) (payload (alist-get 'payload row)))
        (condition-case err
            (progn
              (gdev-record--validate db (gdev-process-get db (alist-get 'tx_id row))
                                     kind (gdev-record-data row))
              (when-let* ((validator (gethash kind gdev-record--row-validators)))
                (funcall validator db row))
              (unless (equal payload (gdev-record-json (gdev-record-data row)))
                (push (format "%s: i dati non sono canonici" ref) problems)))
          (error (push (format "%s: dati non validi (%s)" ref (error-message-string err)) problems)))
        (unless (equal (alist-get 'digest row) (gdev-evidence-sha256 payload))
          (push (format "%s: impronta dei dati non corrispondente" ref) problems))
        (cond
         ((null found) (push (format "%s non ha l'evento nella catena" ref) problems))
         ((cdr found) (push (format "%s ha più di un evento nella catena" ref) problems))
         (t
          (unless (equal (alist-get 'note (car found))
                         (format "%s sha256:%s" kind (alist-get 'digest row)))
            (push (format "%s: il genere o l'impronta non corrisponde all'evento" ref) problems))
          (setq problems (append (gdev-process-event-row-problems row (car found) 'recorded_at)
                                  problems))))
        (remhash ref events)))
    (maphash (lambda (ref _) (push (format "%s ha un evento ma nessuna registrazione" ref) problems)) events)
    (sort problems #'string<)))

(defun gdev-record-verify (db)
  "Verifica le registrazioni di DB quando lo schema le prevede."
  (when (>= (gdev-assurance-db-version db) 5)
    (gdev-record--verify db)))

(provide 'gdev-records)
;;; gdev-records.el ends here
