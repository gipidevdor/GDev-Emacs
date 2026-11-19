;;; gdev-assurance-db.el --- Archivio SQLite dell'assicurazione ingegneristica -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il nucleo dell'assicurazione ingegneristica (Process Kernel) conserva
;; transazioni, eventi e prove in un database SQLite per progetto:
;; `.gdev/assurance/assurance.sqlite' sotto la radice del progetto.  Questo
;; file apre l'archivio, applica le migrazioni e ne controlla l'integrità.
;; Carica da solo: non richiede la configurazione di GDev, i moduli né alcun
;; modello linguistico.
;;
;; Due modi di apertura:
;;
;;   `read'   non crea nulla e non migra; la connessione rifiuta ogni scrittura;
;;   `write'  crea la cartella (0700) e il file (0600) e applica le migrazioni.
;;
;; Le migrazioni sono blocchi di istruzioni numerati e immutabili: un blocco
;; pubblicato non si modifica mai, se ne aggiunge uno nuovo.  L'archivio ne
;; registra l'impronta (SHA-256 senza gli spazi), così una modifica
;; successiva si riconosce.  I trigger rifiutano `update' e `delete' su
;; eventi e prove.  Questo rende l'alterazione rilevabile e rifiutata dal
;; database, non impossibile per chi ha accesso al file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function sqlite-available-p "sqlite.c" ())
(declare-function sqlite-open "sqlite.c" (&optional file))
(declare-function sqlite-close "sqlite.c" (db))
(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))
(declare-function sqlite-pragma "sqlite.c" (db pragma))

;;;; Errori

(define-error 'gdev-assurance-error "Errore dell'archivio di assicurazione")
(define-error 'gdev-assurance-db-unavailable
  "SQLite non è disponibile in questo Emacs" 'gdev-assurance-error)
(define-error 'gdev-assurance-db-missing "Archivio assente" 'gdev-assurance-error)
(define-error 'gdev-assurance-db-outdated
  "Archivio di una versione precedente: serve la migrazione" 'gdev-assurance-error)
(define-error 'gdev-assurance-db-unusable "Archivio non utilizzabile" 'gdev-assurance-error)
(define-error 'gdev-assurance-db-too-new
  "Archivio creato da una versione più recente di GDev" 'gdev-assurance-error)

;;;; Percorsi

(defconst gdev-assurance-db-directory ".gdev/assurance/"
  "Cartella dell'archivio, relativa alla radice del progetto.")

(defconst gdev-assurance-db-file-name "assurance.sqlite"
  "Nome del file dell'archivio.")

(defun gdev-assurance-db-file (root)
  "Restituisci il file dell'archivio del progetto con radice ROOT."
  (expand-file-name (concat gdev-assurance-db-directory gdev-assurance-db-file-name) root))

(defun gdev-assurance-db-find-root (directory)
  "Restituisci la radice che contiene un archivio sopra DIRECTORY, o nil."
  (when-let* ((root (locate-dominating-file
                    directory (concat gdev-assurance-db-directory gdev-assurance-db-file-name))))
    (file-name-as-directory (expand-file-name root))))

;;;; Tempo

(defvar gdev-assurance-db-clock-function #'current-time
  "Funzione che restituisce l'istante di una registrazione.
Le prove la sostituiscono per ottenere date ripetibili; il codice no.")

(defun gdev-assurance-db-now ()
  "Restituisci l'istante corrente in UTC, con i millisecondi."
  (format-time-string "%FT%T.%3NZ" (funcall gdev-assurance-db-clock-function) t))

;;;; Migrazioni

(defconst gdev-assurance-db--states
  "'PROPOSED','CLASSIFIED','ANALYZED','AUTHORIZED','IMPLEMENTING','VERIFYING','REVIEWING','APPROVED','BASELINED','BLOCKED','REJECTED','SUSPENDED','CANCELLED','SUPERSEDED'"
  "Elenco SQL degli stati nella migrazione 1.  Non modificarlo: aggiungi una
migrazione.")

(defvar gdev-assurance-db--migrations
  `((1
     ;; Transazioni.
     ,(format "create table tx (
  id text primary key check (id glob 'GT-[0-9][0-9][0-9][0-9]*'),
  n integer not null unique check (n >= 1),
  title text not null check (length(title) between 1 and 200),
  state text not null check (state in (%s)),
  profile text not null check (profile in ('core','quality','secure','high-assurance','critical')),
  opened_at text not null)"
              gdev-assurance-db--states)
     ;; Eventi: una catena in sola aggiunta; ogni impronta include la precedente.
     ,(format "create table tx_event (
  seq integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('open','transition','evidence')),
  from_state text check (from_state is null or from_state in (%s)),
  to_state text not null check (to_state in (%s)),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  ref text,
  note text,
  at text not null,
  prev_hash text not null check (length(prev_hash) = 64),
  hash text not null unique check (length(hash) = 64))"
              gdev-assurance-db--states gdev-assurance-db--states)
     ;; Prove.
     "create table evidence (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('fact','deduction','hypothesis')),
  origin text not null check (origin in ('collected','reconstructed')),
  description text not null check (length(description) between 1 and 500),
  sha256 text not null check (length(sha256) = 64),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  collected_at text not null)"
     "create index tx_event_tx on tx_event(tx_id, seq)"
     "create index evidence_tx on evidence(tx_id)"
     "create trigger tx_event_no_update before update on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger tx_event_no_delete before delete on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger evidence_no_update before update on evidence
begin select raise(abort, 'evidence è in sola aggiunta'); end"
     "create trigger evidence_no_delete before delete on evidence
begin select raise(abort, 'evidence è in sola aggiunta'); end"
     "create trigger tx_no_delete before delete on tx
begin select raise(abort, 'tx non si cancella'); end"
     "create trigger tx_fixed_fields before update of id, n, title, profile, opened_at on tx
begin select raise(abort, 'tx: il campo non si modifica'); end")
    (2
     ;; Un rifiuto resta nella catena: SQLite non modifica un vincolo `check',
     ;; quindi la tabella si ricostruisce con le righe e le impronte intatte.
     ,(format "create table tx_event_v2 (
  seq integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('open','transition','evidence','refusal')),
  from_state text check (from_state is null or from_state in (%s)),
  to_state text not null check (to_state in (%s)),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  ref text,
  note text,
  at text not null,
  prev_hash text not null check (length(prev_hash) = 64),
  hash text not null unique check (length(hash) = 64))"
              gdev-assurance-db--states gdev-assurance-db--states)
     "insert into tx_event_v2
 (seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash)
 select seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash
 from tx_event"
     "drop table tx_event"
     "alter table tx_event_v2 rename to tx_event"
     "create index tx_event_tx on tx_event(tx_id, seq)"
     "create trigger tx_event_no_update before update on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger tx_event_no_delete before delete on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end")
    (3
     ;; Le decisioni sui controlli (deroga, non applicabilità) entrano nella catena
     ;; come evento `decision': la tabella degli eventi si ricostruisce di nuovo.
     ,(format "create table tx_event_v3 (
  seq integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('open','transition','evidence','refusal','decision')),
  from_state text check (from_state is null or from_state in (%s)),
  to_state text not null check (to_state in (%s)),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  ref text,
  note text,
  at text not null,
  prev_hash text not null check (length(prev_hash) = 64),
  hash text not null unique check (length(hash) = 64))"
              gdev-assurance-db--states gdev-assurance-db--states)
     "insert into tx_event_v3
 (seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash)
 select seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash
 from tx_event"
     "drop table tx_event"
     "alter table tx_event_v3 rename to tx_event"
     "create index tx_event_tx on tx_event(tx_id, seq)"
     "create trigger tx_event_no_update before update on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger tx_event_no_delete before delete on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     ;; Una decisione la prende una persona: lo impone anche il database.
     "create table decision (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('waiver','not-applicable')),
  control_id text not null check (length(control_id) between 1 and 64),
  reason text not null check (length(reason) between 1 and 1000),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind = 'human'),
  decided_at text not null)"
     "create index decision_tx on decision(tx_id)"
     "create trigger decision_no_update before update on decision
begin select raise(abort, 'decision è in sola aggiunta'); end"
     "create trigger decision_no_delete before delete on decision
begin select raise(abort, 'decision è in sola aggiunta'); end")
    (4
     ;; Le valutazioni registrate entrano nella catena come evento `assessment': la
     ;; tabella degli eventi si ricostruisce ancora, con righe e impronte intatte.
     ,(format "create table tx_event_v4 (
  seq integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('open','transition','evidence','refusal','decision','assessment')),
  from_state text check (from_state is null or from_state in (%s)),
  to_state text not null check (to_state in (%s)),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  ref text,
  note text,
  at text not null,
  prev_hash text not null check (length(prev_hash) = 64),
  hash text not null unique check (length(hash) = 64))"
              gdev-assurance-db--states gdev-assurance-db--states)
     "insert into tx_event_v4
 (seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash)
 select seq, tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash
 from tx_event"
     "drop table tx_event"
     "alter table tx_event_v4 rename to tx_event"
     "create index tx_event_tx on tx_event(tx_id, seq)"
     "create trigger tx_event_no_update before update on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger tx_event_no_delete before delete on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create table assessment (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  profile text not null check (profile in ('core','quality','secure','high-assurance','critical')),
  controls_digest text not null check (length(controls_digest) = 64),
  input_digest text not null check (length(input_digest) = 64),
  chain_head text not null check (length(chain_head) = 64),
  result_digest text not null check (length(result_digest) = 64),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  assessed_at text not null)"
     "create table assessment_result (
  assessment_id integer not null references assessment(id),
  position integer not null check (position >= 1),
  control_id text not null check (length(control_id) between 1 and 64),
  status text not null check (status in ('SATISFIED','NOT_SATISFIED','NOT_VERIFIED','NOT_APPLICABLE','WAIVED_WITH_AUTHORIZATION')),
  reason text not null,
  primary key (assessment_id, position))"
     "create index assessment_tx on assessment(tx_id)"
     "create trigger assessment_no_update before update on assessment
begin select raise(abort, 'assessment è in sola aggiunta'); end"
     "create trigger assessment_no_delete before delete on assessment
begin select raise(abort, 'assessment è in sola aggiunta'); end"
     "create trigger assessment_result_no_update before update on assessment_result
begin select raise(abort, 'assessment_result è in sola aggiunta'); end"
     "create trigger assessment_result_no_delete before delete on assessment_result
begin select raise(abort, 'assessment_result è in sola aggiunta'); end")
    (5
     ,(format "create table tx_event_v5 (
  seq integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('open','transition','evidence','refusal','decision','assessment','record')),
  from_state text check (from_state is null or from_state in (%s)),
  to_state text not null check (to_state in (%s)),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  ref text, note text, at text not null,
  prev_hash text not null check (length(prev_hash) = 64),
  hash text not null unique check (length(hash) = 64))"
              gdev-assurance-db--states gdev-assurance-db--states)
     "insert into tx_event_v5 select * from tx_event"
     "drop table tx_event"
     "alter table tx_event_v5 rename to tx_event"
     "create index tx_event_tx on tx_event(tx_id, seq)"
     "create trigger tx_event_no_update before update on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create trigger tx_event_no_delete before delete on tx_event
begin select raise(abort, 'tx_event è in sola aggiunta'); end"
     "create table assurance_record (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('artifact','trace','baseline','commit','request','recovery')),
  payload text not null check (length(payload) between 2 and 131072),
  digest text not null check (length(digest) = 64),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  recorded_at text not null)"
     "create index assurance_record_tx on assurance_record(tx_id, kind, id)"
     "create trigger assurance_record_no_update before update on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end"
     "create trigger assurance_record_no_delete before delete on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end")
    (6
     "alter table assessment add column context_digest text
 check (context_digest is null or length(context_digest) = 64)"
     "create table assurance_record_v6 (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('artifact','trace','baseline','commit','request','recovery','standard')),
  payload text not null check (length(payload) between 2 and 131072),
  digest text not null check (length(digest) = 64),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  recorded_at text not null)"
     "insert into assurance_record_v6 select * from assurance_record"
     "drop table assurance_record"
     "alter table assurance_record_v6 rename to assurance_record"
     "create index assurance_record_tx on assurance_record(tx_id, kind, id)"
     "create trigger assurance_record_no_update before update on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end"
     "create trigger assurance_record_no_delete before delete on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end")
    (7
     "create table assurance_record_v7 (
  id integer primary key autoincrement,
  tx_id text not null references tx(id),
  kind text not null check (kind in ('artifact','trace','baseline','commit','request','recovery','standard','project','run')),
  payload text not null check (length(payload) between 2 and 131072),
  digest text not null check (length(digest) = 64),
  actor text not null check (length(actor) between 1 and 200),
  actor_kind text not null check (actor_kind in ('human','agent','ci','system')),
  recorded_at text not null)"
     "insert into assurance_record_v7 select * from assurance_record"
     "drop table assurance_record"
     "alter table assurance_record_v7 rename to assurance_record"
     "create index assurance_record_tx on assurance_record(tx_id, kind, id)"
     "create trigger assurance_record_no_update before update on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end"
     "create trigger assurance_record_no_delete before delete on assurance_record
begin select raise(abort, 'assurance_record è in sola aggiunta'); end"))
  "Migrazioni: elenco di (VERSIONE ISTRUZIONE...), in ordine e senza salti.
Ogni istruzione è una sola istruzione SQL.  Un blocco pubblicato non si
modifica.")

(defun gdev-assurance-db--normalize (statement)
  "Restituisci STATEMENT con gli spazi ridotti a uno solo."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " statement)))

(defun gdev-assurance-db--checksum (statements)
  "Restituisci l'impronta SHA-256 di STATEMENTS senza le differenze di spazi."
  (secure-hash 'sha256 (encode-coding-string
                        (mapconcat #'gdev-assurance-db--normalize statements ";") 'utf-8)))

(defun gdev-assurance-db-latest-version ()
  "Restituisci l'ultima versione dello schema, dopo aver controllato l'ordine."
  (let ((expected 0))
    (dolist (migration gdev-assurance-db--migrations)
      (unless (= (car migration) (setq expected (1+ expected)))
        (error "Le migrazioni dell'archivio non sono consecutive: manca la %d" expected)))
    expected))

;;;; Connessione

(defun gdev-assurance-db-available-p ()
  "Restituisci non nil se questo Emacs ha SQLite."
  (and (fboundp 'sqlite-available-p) (sqlite-available-p)))

(defun gdev-assurance-db-sqlite-version (db)
  "Restituisci la versione di SQLite usata da DB."
  (caar (sqlite-select db "select sqlite_version()")))

(defun gdev-assurance-db-version (db)
  "Restituisci la versione dello schema di DB: 0 se non è inizializzato."
  (if (zerop (caar (sqlite-select db "select count(*) from sqlite_master
 where type = 'table' and name = 'schema_migrations'")))
      0
    (or (caar (sqlite-select db "select max(version) from schema_migrations")) 0)))

(defun gdev-assurance-db--ensure-directory (file)
  "Crea la cartella di FILE accessibile solo all'utente e il file vuoto, a 0600."
  (let ((directory (file-name-directory file)))
    (with-file-modes #o700 (make-directory directory t))
    (set-file-modes directory #o700)
    (unless (file-exists-p file)
      ;; Un file vuoto è un database valido: SQLite lo inizializza alla prima scrittura.
      (with-file-modes #o600 (write-region "" nil file nil 'silent)))
    (set-file-modes file #o600)))

(defun gdev-assurance-db--configure (db mode)
  "Imposta la connessione DB per MODE."
  (sqlite-pragma db "foreign_keys = on")
  (sqlite-pragma db "busy_timeout = 5000")
  ;; Il file sta nel progetto e può venire da altri: lo schema non è attendibile.
  (sqlite-pragma db "trusted_schema = off")
  (when (eq mode 'read)
    (sqlite-pragma db "query_only = on")))

(defun gdev-assurance-db-close (db)
  "Chiudi la connessione DB."
  (ignore-errors (sqlite-close db)))

(defun gdev-assurance-db-open (root &optional mode)
  "Apri l'archivio del progetto ROOT e restituisci la connessione.
MODE è `read' (predefinito) o `write'.  In lettura l'archivio deve esistere
ed essere alla versione corrente; in scrittura viene creato e migrato."
  (let ((mode (or mode 'read))
        (file (gdev-assurance-db-file root)))
    (unless (gdev-assurance-db-available-p)
      (signal 'gdev-assurance-db-unavailable nil))
    (pcase mode
      ('read (unless (file-regular-p file)
               (signal 'gdev-assurance-db-missing (list file))))
      ('write (gdev-assurance-db--ensure-directory file))
      (_ (error "Modo di apertura sconosciuto: %S" mode)))
    (let ((db (sqlite-open file)) done)
      (unwind-protect
          (condition-case err
              (prog1
                  (progn
		    (gdev-assurance-db--configure db mode)
		    (if (eq mode 'write)
			(gdev-assurance-db--migrate db)
		      (let ((version (gdev-assurance-db-version db))
			    (latest (gdev-assurance-db-latest-version)))
			(cond ((> version latest)
			       (signal 'gdev-assurance-db-too-new (list version latest)))
			      ((< version latest)
			       (signal 'gdev-assurance-db-outdated (list version latest))))))
                    db)
                (setq done t))
            (gdev-assurance-error (signal (car err) (cdr err)))
            (sqlite-error
             (signal 'gdev-assurance-db-unusable (list (error-message-string err)))))
        (unless done (gdev-assurance-db-close db))))))

(defmacro gdev-assurance-db-with-open (spec &rest body)
  "Esegui BODY con una connessione aperta e chiudila all'uscita.
SPEC è (VARIABILE ROOT [MODE])."
  (declare (indent 1) (debug ((symbolp form &optional form) body)))
  (let ((db (car spec)))
    `(let ((,db (gdev-assurance-db-open ,(nth 1 spec) ,(nth 2 spec))))
       (unwind-protect (progn ,@body)
         (gdev-assurance-db-close ,db)))))

;;;; Transazioni SQL

(defvar gdev-assurance-db--reads nil
  "Connessioni con una lettura coerente aperta dal nucleo.")

(defun gdev-assurance-db-read-transaction (db function)
  "Esegui FUNCTION su un'unica istantanea di DB.
Una chiamata annidata condivide la transazione già aperta."
  (if (or (memq db gdev-assurance-db--reads)
          (gdev-assurance-db-in-transaction-p db))
      (funcall function)
    (let ((gdev-assurance-db--reads (cons db gdev-assurance-db--reads))
          done)
      (sqlite-execute db "begin")
      (unwind-protect
          (prog1 (funcall function)
            (sqlite-execute db "commit")
            (setq done t))
        (unless done (ignore-errors (sqlite-execute db "rollback")))))))

(defvar gdev-assurance-db--transactions nil
  "Connessioni con una transazione aperta da `gdev-assurance-db-transaction'.")

(defun gdev-assurance-db-in-transaction-p (db)
  "Restituisci non nil se DB ha una transazione aperta dal nucleo."
  (and (memq db gdev-assurance-db--transactions) t))

(defun gdev-assurance-db-transaction (db function)
  "Esegui FUNCTION in una transazione di DB e restituisci il suo valore.
Qualunque uscita non regolare annulla tutte le scritture.  Una chiamata
annidata partecipa alla transazione già aperta."
  (if (gdev-assurance-db-in-transaction-p db)
      (funcall function)
    (let ((gdev-assurance-db--transactions (cons db gdev-assurance-db--transactions))
          (done nil))
      (sqlite-execute db "begin immediate")
      (unwind-protect
          (prog1 (funcall function)
            (sqlite-execute db "commit")
            (setq done t))
        (unless done
          (ignore-errors (sqlite-execute db "rollback")))))))

(defun gdev-assurance-db--migrate (db)
  "Applica a DB le migrazioni mancanti, tutte o nessuna."
  (let ((latest (gdev-assurance-db-latest-version)))
    (gdev-assurance-db-transaction
     db
     (lambda ()
       (sqlite-execute db "create table if not exists schema_migrations (
  version integer primary key,
  applied_at text not null,
  checksum text not null)")
       (let ((current (gdev-assurance-db-version db)))
         (when (> current latest)
           (signal 'gdev-assurance-db-too-new (list current latest)))
         (dolist (migration gdev-assurance-db--migrations)
           (when (> (car migration) current)
             (dolist (statement (cdr migration))
               (sqlite-execute db statement))
             (sqlite-execute
              db "insert into schema_migrations (version, applied_at, checksum) values (?, ?, ?)"
              (list (car migration) (gdev-assurance-db-now)
                    (gdev-assurance-db--checksum (cdr migration)))))))))))

;;;; Letture

(defun gdev-assurance-db-select (db query &optional values)
  "Esegui QUERY su DB e restituisci le righe come alist.  Le chiavi sono i nomi
delle colonne come simboli; VALUES lega i punti interrogativi."
  (let* ((result (sqlite-select db query values 'full))
         (columns (mapcar #'intern (car result))))
    (mapcar (lambda (row) (cl-mapcar #'cons columns row)) (cdr result))))

;;;; Integrità

(defun gdev-assurance-db--expected-objects (versions)
  "Restituisci i nomi degli oggetti che le migrazioni VERSIONS lasciano nello
schema.  Segue le istruzioni nell'ordine: crea, elimina e rinomina."
  (let (names)
    (dolist (migration gdev-assurance-db--migrations)
      (when (memq (car migration) versions)
        (dolist (statement (cdr migration))
          (cond
           ((string-match "\\`create \\(?:table\\|index\\|trigger\\) \\([a-z_0-9]+\\)" statement)
            (cl-pushnew (match-string 1 statement) names :test #'equal))
           ((string-match "\\`drop \\(?:table\\|index\\|trigger\\) \\([a-z_0-9]+\\)" statement)
            (setq names (delete (match-string 1 statement) names)))
           ((string-match "\\`alter table \\([a-z_0-9]+\\) rename to \\([a-z_0-9]+\\)" statement)
            (setq names (cons (match-string 2 statement)
                              (delete (match-string 1 statement) names))))))))
    (nreverse names)))

(defun gdev-assurance-db--check-rows (db pragma)
  "Restituisci le righe del controllo PRAGMA di SQLite su DB."
  (sqlite-select db (concat "pragma " pragma)))

(defun gdev-assurance-db-integrity (db)
  "Restituisci l'elenco dei problemi strutturali di DB: nil se è integro.
Controlla l'integrità di SQLite, le chiavi esterne, le migrazioni applicate
e la presenza di tabelle, indici e trigger previsti."
  (let (problems)
    (when (and (>= (gdev-assurance-db-version db) 6)
               (not (member "context_digest" (mapcar #'cadr (sqlite-select db "pragma table_info(assessment)")))))
      (push "Colonna dello schema mancante: assessment.context_digest" problems))
    (let ((rows (gdev-assurance-db--check-rows db "integrity_check")))
      (unless (equal rows '(("ok")))
        (dolist (row rows)
          (push (format "Integrità di SQLite: %s" (car row)) problems))))
    (dolist (row (gdev-assurance-db--check-rows db "foreign_key_check"))
      (push (format "Chiave esterna violata: %s, riga %s, verso %s" (nth 0 row) (nth 1 row) (nth 2 row))
            problems))
    (let ((applied (and (> (gdev-assurance-db-version db) 0)
                        (sqlite-select db "select version, checksum from schema_migrations order by version")))
          (versions nil))
      (dolist (row applied)
        (let ((migration (assq (car row) gdev-assurance-db--migrations)))
          (push (car row) versions)
          (cond ((null migration)
                 (push (format "Migrazione %d sconosciuta a questa versione di GDev" (car row)) problems))
                ((not (equal (cadr row) (gdev-assurance-db--checksum (cdr migration))))
                 (push (format "Migrazione %d alterata: l'impronta non corrisponde" (car row)) problems)))))
      (let ((actual (mapcar #'car (sqlite-select db "select name from sqlite_master
 where name not like 'sqlite_%' and name != 'schema_migrations'")))
            (expected (gdev-assurance-db--expected-objects versions)))
        (dolist (name expected)
          (unless (member name actual)
            (push (format "Oggetto dello schema mancante: %s" name) problems)))
        (dolist (name actual)
          (unless (member name expected)
            (push (format "Oggetto dello schema non previsto: %s" name) problems)))))
    (nreverse problems)))

(provide 'gdev-assurance-db)
;;; gdev-assurance-db.el ends here
