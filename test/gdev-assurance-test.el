;;; gdev-assurance-test.el --- Prove del nucleo dell'assicurazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Archivio, transazioni, catena di audit, prove e sottocomandi di sola
;; lettura.  Ogni prova lavora in una cartella temporanea con un orologio
;; ripetibile.  Le manomissioni simulano chi ha accesso al file: tolgono i
;; trigger e riscrivono le righe, e la verifica deve accorgersene.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-assurance)
(require 'gdev-agent-interface)
(require 'gdev-mcp)

(defun gdev-test-assurance--clock ()
  "Restituisci un orologio che avanza di un secondo a ogni lettura."
  (let ((n 0) (start (encode-time '(0 0 0 1 1 2026 nil nil t))))
    (lambda () (time-add start (setq n (1+ n))))))

(defmacro gdev-test-assurance--with-root (root &rest body)
  "Esegui BODY con ROOT, una radice temporanea, e un orologio ripetibile."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,root (file-name-as-directory (make-temp-file "gdev-assurance-" t)))
         (gdev-assurance-db-clock-function (gdev-test-assurance--clock)))
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defmacro gdev-test-assurance--with-archive (spec &rest body)
  "Esegui BODY con SPEC, (ROOT DB): una radice e un archivio aperto in scrittura."
  (declare (indent 1) (debug ((symbolp symbolp) body)))
  (let ((root (nth 0 spec)) (db (nth 1 spec)))
    `(gdev-test-assurance--with-root ,root
       (let ((,db (gdev-assurance-db-open ,root 'write)))
         (unwind-protect (progn ,@body)
           (gdev-assurance-db-close ,db))))))

(defun gdev-test-assurance--sql (db query &rest values)
  "Esegui QUERY su DB con VALUES e restituisci le righe."
  (if (string-match-p "\\`select" query)
      (sqlite-select db query values)
    (sqlite-execute db query values)))

(defun gdev-test-assurance--open (db &optional profile)
  "Apri in DB una transazione di prova con PROFILE e restituisci il suo id."
  (gdev-process-open db :title "Modifica di prova" :profile (or profile 'core)
                     :actor "proponente" :actor-kind 'human))

(defun gdev-test-assurance--step (db id to &optional actor-kind actor)
  "Porta ID a TO come ACTOR-KIND: una persona per gli stati riservati."
  (gdev-process-advance
   db id to :actor (or actor "revisore")
   :actor-kind (or actor-kind (if (memq to '(AUTHORIZED APPROVED BASELINED)) 'human 'agent))))

(defun gdev-test-assurance--walk (db id &rest states)
  "Porta ID attraverso STATES nell'ordine."
  (dolist (state states) (gdev-test-assurance--step db id state)))

(defconst gdev-test-assurance--to-baselined
  '(CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED)
  "Il percorso principale dopo PROPOSED.")

(defun gdev-test-assurance--refusal (function)
  "Esegui FUNCTION e restituisci il motivo del rifiuto, o nil se non rifiuta."
  (condition-case err (progn (funcall function) nil)
    (gdev-process-refused (cadr err))))

(defun gdev-test-assurance--prove (db id &optional kind origin)
  "Registra in DB una prova di ID, KIND `fact' e ORIGIN `collected' se omessi."
  (gdev-evidence-add db id :kind (or kind 'fact) :origin origin :description "Prova di prova"
                     :content "esito" :actor "ci" :actor-kind 'ci))

(defun gdev-test-assurance--drop-guards (db)
  "Toglie da DB i trigger di sola aggiunta, come farebbe chi ha accesso al file."
  (dolist (name '("tx_event_no_update" "tx_event_no_delete" "evidence_no_update"
                  "evidence_no_delete" "tx_no_delete" "tx_fixed_fields"))
    (sqlite-execute db (concat "drop trigger " name))))

(defun gdev-test-assurance--edit-restoring-guard (db trigger query &rest values)
  "Esegui QUERY con VALUES in DB e ripristina esattamente il TRIGGER tolto."
  (let ((definition (caar (sqlite-select db "select sql from sqlite_master
 where type = 'trigger' and name = ?" (list trigger)))))
    (should (stringp definition))
    (sqlite-execute db (concat "drop trigger " trigger))
    (unwind-protect
        (sqlite-execute db query values)
      (sqlite-execute db definition))))

(defun gdev-test-assurance--event-count (db)
  "Restituisci il numero di eventi di DB."
  (caar (sqlite-select db "select count(*) from tx_event")))

;;;; Archivio

(ert-deftest gdev-test-assurance-db-creates-a-private-migrated-archive ()
  "Un archivio nuovo è privato, alla versione corrente e integro."
  (gdev-test-assurance--with-root root
    (let ((file (gdev-assurance-db-file root)))
      (should-not (file-exists-p (concat root ".gdev")))
      (gdev-assurance-db-with-open (db root 'write)
        (should (= (gdev-assurance-db-version db) (gdev-assurance-db-latest-version)))
        (should-not (gdev-assurance-db-integrity db))
        (should (stringp (gdev-assurance-db-sqlite-version db))))
      (should (= (file-modes file) #o600))
      (should (= (file-modes (file-name-directory file)) #o700))
      ;; Riaprire non rifà le migrazioni.
      (gdev-assurance-db-with-open (db root 'write)
        (should (= (gdev-assurance-db-latest-version)
                   (caar (sqlite-select db "select count(*) from schema_migrations")))))
      (make-directory (concat root "a/b/") t)
      (should (equal (gdev-assurance-db-find-root (concat root "a/b/")) root)))
    (gdev-test-assurance--with-root other
      (should-not (gdev-assurance-db-find-root other)))))

(ert-deftest gdev-test-assurance-db-read-mode-creates-nothing-and-refuses-writes ()
  "La lettura non crea l'archivio e la sua connessione non scrive."
  (gdev-test-assurance--with-root root
    (should-error (gdev-assurance-db-open root) :type 'gdev-assurance-db-missing)
    (should-error (gdev-assurance-db-open root 'read) :type 'gdev-assurance-db-missing)
    (should-not (file-exists-p (concat root ".gdev")))
    (should-error (gdev-assurance-db-open root 'altro) :type 'error)
    (gdev-assurance-db-close (gdev-assurance-db-open root 'write))
    (gdev-assurance-db-with-open (db root)
      (should-error (sqlite-execute db "delete from schema_migrations"))
      (should-error (gdev-assurance-db-transaction db (lambda () nil)))
      (should-error (gdev-process-open db :title "Titolo" :profile 'core
                                       :actor "mario" :actor-kind 'human)))
    (gdev-assurance-db-with-open (db root 'write)
      (should (null (gdev-process-list db))))))

(ert-deftest gdev-test-assurance-db-refuses-outdated-and-newer-archives ()
  "Un archivio vuoto o di una versione diversa non si usa a metà."
  (gdev-test-assurance--with-root root
    (let ((file (gdev-assurance-db-file root)))
      (make-directory (file-name-directory file) t)
      (write-region "" nil file nil 'silent)
      (should-error (gdev-assurance-db-open root) :type 'gdev-assurance-db-outdated)
      (gdev-assurance-db-close (gdev-assurance-db-open root 'write))
      (gdev-assurance-db-with-open (db root 'write)
        (sqlite-execute db "insert into schema_migrations values (99, 'x', 'x')"))
      (should-error (gdev-assurance-db-open root) :type 'gdev-assurance-db-too-new)
      (should-error (gdev-assurance-db-open root 'write) :type 'gdev-assurance-db-too-new)
      (should (string-match-p "più recente"
                              (error-message-string
                               (condition-case err (gdev-assurance-db-open root)
                                 (error err))))))))

(ert-deftest gdev-test-assurance-db-reports-a-file-that-is-not-a-database ()
  "Un file qualunque al posto dell'archivio dà un errore chiaro, in lettura e in scrittura."
  (gdev-test-assurance--with-root root
    (let ((file (gdev-assurance-db-file root))
          (garbage (make-string 4096 ?x)))
      (make-directory (file-name-directory file) t)
      (write-region garbage nil file nil 'silent)
      (should-error (gdev-assurance-db-open root) :type 'gdev-assurance-db-unusable)
      (should-error (gdev-assurance-db-open root 'write) :type 'gdev-assurance-db-unusable)
      (let ((result (gdev-test-assurance--cli root "verify")))
        (should (= (car result) 1))
        (should (string-match-p "Archivio non utilizzabile" (cdr result))))
      (should (equal garbage (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest gdev-test-assurance-db-reports-a-missing-sqlite ()
  "Senza SQLite il nucleo rifiuta di aprire e lo dice."
  (gdev-test-assurance--with-root root
    (cl-letf (((symbol-function 'gdev-assurance-db-available-p) (lambda () nil)))
      (should-error (gdev-assurance-db-open root 'write) :type 'gdev-assurance-db-unavailable))
    (should-not (file-exists-p (concat root ".gdev")))
    (should (gdev-assurance-db-available-p))))

(ert-deftest gdev-test-assurance-db-migrations-are-atomic-and-ordered ()
  "Salire di versione è tutto o niente, e i salti nei numeri si rifiutano."
  (gdev-test-assurance--with-root root
    (gdev-assurance-db-close (gdev-assurance-db-open root 'write))
    (let* ((next (1+ (gdev-assurance-db-latest-version)))
           (gdev-assurance-db--migrations
           (append gdev-assurance-db--migrations
                   (list (list next "create table extra (a text)" "create index extra_a on extra(a)")))))
      (gdev-assurance-db-with-open (db root 'write)
        (should (= (gdev-assurance-db-version db) next))
        (should-not (gdev-assurance-db-integrity db)))
      (let ((gdev-assurance-db--migrations
             (append gdev-assurance-db--migrations
                     (list (list (1+ next) "create table tre (a text)" "questa non è SQL")))))
        (should-error (gdev-assurance-db-open root 'write))
        (let ((gdev-assurance-db--migrations (butlast gdev-assurance-db--migrations)))
          (gdev-assurance-db-with-open (db root)
            (should (= (gdev-assurance-db-version db) next))
            (should-not (sqlite-select db "select name from sqlite_master where name = 'tre'")))))
      (let ((gdev-assurance-db--migrations (list (car gdev-assurance-db--migrations)
                                                 '(3 "create table tre (a text)"))))
        (should-error (gdev-assurance-db-latest-version))))))

(ert-deftest gdev-test-assurance-db-reports-a-tampered-schema ()
  "Trigger tolti, oggetti aggiunti e migrazioni alterate compaiono nella verifica."
  (gdev-test-assurance--with-archive (root db)
    (sqlite-execute db "drop trigger tx_event_no_update")
    (sqlite-execute db "create table intruso (a text)")
    (sqlite-execute db "update schema_migrations set checksum = 'alterata'")
    (sqlite-execute db "insert into schema_migrations values (?, 'x', 'x')"
                    (list (1+ (gdev-assurance-db-latest-version))))
    (let ((problems (gdev-assurance-db-integrity db)))
      (should (member "Oggetto dello schema mancante: tx_event_no_update" problems))
      (should (member "Oggetto dello schema non previsto: intruso" problems))
      (should (member "Migrazione 1 alterata: l'impronta non corrisponde" problems))
      (should (member (format "Migrazione %d sconosciuta a questa versione di GDev"
                              (1+ (gdev-assurance-db-latest-version))) problems)))
    (sqlite-execute db "pragma foreign_keys = off")
    (sqlite-execute db "insert into tx_event (tx_id, kind, to_state, actor, actor_kind, at, prev_hash, hash)
 values ('GT-0099', 'open', 'PROPOSED', 'x', 'human', 'x', ?, ?)"
                    (list (make-string 64 ?0) (make-string 64 ?1)))
    (should (seq-some (lambda (problem) (string-prefix-p "Chiave esterna violata" problem))
                      (gdev-assurance-db-integrity db)))))

(ert-deftest gdev-test-assurance-db-reports-what-sqlite-finds-wrong ()
  "I problemi che SQLite stesso segnala passano nella verifica, uno per riga."
  (gdev-test-assurance--with-archive (root db)
    (let ((original (symbol-function 'gdev-assurance-db--check-rows)))
      (cl-letf (((symbol-function 'gdev-assurance-db--check-rows)
                 (lambda (db pragma)
                   (if (equal pragma "integrity_check")
                       '(("pagina 5 danneggiata") ("indice 2 incompleto"))
                     (funcall original db pragma)))))
        (should (equal (gdev-assurance-db-integrity db)
                       '("Integrità di SQLite: pagina 5 danneggiata"
                         "Integrità di SQLite: indice 2 incompleto")))))))

(ert-deftest gdev-test-assurance-db-schema-rejects-invalid-values-and-edits ()
  "I vincoli e i trigger rifiutano valori fuori elenco e modifiche della cronologia."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db id 'CLASSIFIED 'agent)
      (gdev-assurance-db-transaction
       db (lambda () (gdev-process-append-event db id 'evidence 'CLASSIFIED 'CLASSIFIED "x" 'human)))
      (dolist (query '("update tx_event set actor = 'altro'"
                       "delete from tx_event"
                       "delete from tx"
                       "update tx set title = 'altro'"
                       "update tx set profile = 'core'"
                       "update tx set state = 'INVENTATO'"
                       "update tx set id = 'GT-0099'"))
        (should-error (sqlite-execute db query)))
      (should (= (gdev-test-assurance--event-count db) 3))
      (gdev-evidence-add db id :kind 'fact :description "d" :content "c"
                         :actor "x" :actor-kind 'human)
      (should-error (sqlite-execute db "update evidence set sha256 = 'x'"))
      (should-error (sqlite-execute db "delete from evidence"))
      (should-error (sqlite-execute db "insert into evidence (tx_id, kind, origin, description, sha256, actor, actor_kind, collected_at)
 values ('GT-0001', 'opinione', 'collected', 'd', ?, 'x', 'human', 'x')"
                                    (list (make-string 64 ?0))))
      (should-error (sqlite-execute db "insert into tx_event (tx_id, kind, to_state, actor, actor_kind, at, prev_hash, hash)
 values ('GT-0099', 'open', 'PROPOSED', 'x', 'human', 'x', ?, ?)"
                                    (list (make-string 64 ?0) (make-string 64 ?2)))))))

(ert-deftest gdev-test-assurance-db-transactions-roll-back-and-nest ()
  "Un'uscita non regolare annulla le scritture; una chiamata annidata partecipa."
  (gdev-test-assurance--with-archive (root db)
    (should-error
     (gdev-assurance-db-transaction
      db (lambda ()
           (gdev-process-open db :title "Annullata" :profile 'core :actor "a" :actor-kind 'human)
           (error "Fallisce"))))
    (should (null (gdev-process-list db)))
    (should-not (gdev-assurance-db-in-transaction-p db))
    (should (= 7 (gdev-assurance-db-transaction
                  db (lambda ()
                       (should (gdev-assurance-db-in-transaction-p db))
                       (gdev-assurance-db-transaction db (lambda () 7))))))
    (should (equal '(((a . 1) (b . "x")))
                   (gdev-assurance-db-select db "select ? as a, ? as b" '(1 "x"))))
    (should (string-match-p "\\`2026-01-01T00:00:[0-9][0-9]\\.000Z\\'" (gdev-assurance-db-now)))))

;;;; Transazioni

(ert-deftest gdev-test-process-transition-table-matches-the-rules ()
  "Ogni coppia di stati ha l'esito che le regole prescrivono, né più né meno."
  (let* ((chain '(PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING
                  REVIEWING APPROVED BASELINED))
         (active (butlast chain))
         (allowed (list '(BASELINED . SUPERSEDED) '(VERIFYING . IMPLEMENTING)
                        '(REVIEWING . IMPLEMENTING))))
    (cl-loop for (from to) on chain while to do (push (cons from to) allowed))
    (dolist (from active)
      (dolist (to '(BLOCKED SUSPENDED CANCELLED)) (push (cons from to) allowed))
      (unless (eq from 'APPROVED) (push (cons from 'REJECTED) allowed)))
    (dolist (from '(BLOCKED SUSPENDED))
      (dolist (to (append active '(REJECTED CANCELLED))) (push (cons from to) allowed)))
    (should (= (length gdev-process-states) 14))
    (dolist (from gdev-process-states)
      (dolist (to gdev-process-states)
        (should (eq (and (member (cons from to) allowed) t)
                    (gdev-process-allowed-p from to)))))
    (dolist (from gdev-process-terminal-states)
      (should-not (cdr (assq from gdev-process-transitions))))))

(ert-deftest gdev-test-process-states-match-the-schema ()
  "Gli stati del nucleo e quelli accettati dal database sono gli stessi."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (dolist (state gdev-process-states)
        (sqlite-execute db "update tx set state = ? where id = ?" (list (symbol-name state) id)))
      (should-error (sqlite-execute db "update tx set state = 'INVENTATO' where id = ?" (list id)))
      (dolist (profile gdev-process-profiles)
        (should (gdev-process-open db :title "p" :profile profile :actor "a" :actor-kind 'human))))))

(ert-deftest gdev-test-process-open-records-the-proposal ()
  "Aprire assegna l'identificativo, imposta PROPOSED e valida ogni campo."
  (gdev-test-assurance--with-archive (root db)
    (let ((first (gdev-test-assurance--open db 'secure))
          (second (gdev-process-open db :title "Proposta di un agente" :profile 'core
                                     :actor "ag" :actor-kind 'agent :note "riga\ncon a capo")))
      (should (equal (list first second) '("GT-0001" "GT-0002")))
      (should (eq (alist-get 'state (gdev-process-get db first)) 'PROPOSED))
      (should (eq (alist-get 'profile (gdev-process-get db first)) 'secure))
      (let ((event (car (gdev-process-events db second))))
        (should (eq (alist-get 'kind event) 'open))
        (should (null (alist-get 'from_state event)))
        (should (eq (alist-get 'actor_kind event) 'agent))
        (should (equal (alist-get 'note event) "riga\ncon a capo")))
      (should (equal (mapcar (lambda (tx) (alist-get 'id tx)) (gdev-process-list db 'PROPOSED))
                     (list first second)))
      (should-not (gdev-process-list db 'BASELINED))
      (should-not (gdev-process-get db "GT-0099"))
      (should-not (gdev-process-get db nil))
      (dolist (arguments `((:title "" :profile core :actor "a" :actor-kind human)
                           (:title ,(make-string 201 ?x) :profile core :actor "a" :actor-kind human)
                           (:title "due\nrighe" :profile core :actor "a" :actor-kind human)
                           (:title nil :profile core :actor "a" :actor-kind human)
                           (:title "t" :profile nullo :actor "a" :actor-kind human)
                           (:title "t" :profile core :actor "" :actor-kind human)
                           (:title "t" :profile core :actor "a" :actor-kind robot)
                           (:title "t" :profile core :actor "a" :actor-kind nil)
                           (:title "t" :profile core :actor "a" :actor-kind human :note "x\0y")
                           (:title "t" :profile core :actor "a" :actor-kind human
                                   :note ,(make-string 1001 ?x))
                           (:title "t" :profile core :actor "a" :actor-kind human :note 5)))
        (should (gdev-test-assurance--refusal
                 (lambda () (apply #'gdev-process-open db arguments)))))
      (should (= (gdev-test-assurance--event-count db) 2)))))

(ert-deftest gdev-test-process-main-path-reaches-baselined-and-verifies ()
  "Il percorso principale arriva a BASELINED e la catena risulta integra."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (apply #'gdev-test-assurance--walk db id gdev-test-assurance--to-baselined)
      (should (eq (alist-get 'state (gdev-process-get db id)) 'BASELINED))
      (let ((events (gdev-process-events db id)))
        (should (= (length events) 9))
        (should (equal (mapcar (lambda (e) (alist-get 'to_state e)) events)
                       (cons 'PROPOSED gdev-test-assurance--to-baselined)))
        (should (equal (alist-get 'prev_hash (car events)) gdev-process-genesis-hash))
        (should (equal (alist-get 'prev_hash (cadr events)) (alist-get 'hash (car events)))))
      (should-not (gdev-process-verify db))
      (should-not (gdev-assurance-verify db))
      ;; Il ritorno a IMPLEMENTING dopo una verifica fallita è ammesso.
      (let ((other (gdev-test-assurance--open db)))
        (gdev-test-assurance--walk db other 'CLASSIFIED 'ANALYZED 'AUTHORIZED 'IMPLEMENTING
                                   'VERIFYING 'IMPLEMENTING 'VERIFYING 'REVIEWING 'IMPLEMENTING)
        (should (eq (alist-get 'state (gdev-process-get db other)) 'IMPLEMENTING))
        (should-not (gdev-process-verify db))))))

(ert-deftest gdev-test-process-refusals-change-nothing-but-the-trail ()
  "Un rifiuto lascia lo stato com'era e aggiunge alla catena solo il proprio evento."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (dolist (attempt
               `(("non si passa a APPROVED" ,id APPROVED human)
                 ("non si passa a PROPOSED" ,id PROPOSED human)
                 ("richiede una persona" ,id CANCELLED agent)
                 ("richiede una persona" ,id SUSPENDED ci)
                 ("richiede una persona" ,id REJECTED system)
                 ("non si passa a SUPERSEDED" ,id SUPERSEDED human)
                 ("non esiste" "GT-0099" CLASSIFIED human)
                 ("non esiste" nil CLASSIFIED human)
                 ("non è uno stato" ,id NONSTATO human)))
        (pcase-let ((`(,fragment ,target ,to ,kind) attempt))
          (let ((reason (gdev-test-assurance--refusal
                         (lambda () (gdev-process-advance db target to :actor "x" :actor-kind kind)))))
            (should (and reason (string-match-p fragment reason))))))
      (dolist (invalid '((:actor "" :actor-kind human) (:actor "x" :actor-kind robot)
                         (:actor "x" :actor-kind human :note "a\0b")))
        (should (gdev-test-assurance--refusal
                 (lambda () (apply #'gdev-process-advance db id 'ANALYZED invalid)))))
      ;; Sei tentativi su una transazione esistente restano nella catena; gli altri no.
      (should (= (gdev-test-assurance--event-count db) 8))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'CLASSIFIED))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-process-reserved-states-need-a-person ()
  "Un agente, la CI e il sistema non autorizzano, approvano né fissano una linea di base."
  (dolist (kind '(agent ci system))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'AUTHORIZED kind))))
        (gdev-test-assurance--walk db id 'AUTHORIZED 'IMPLEMENTING 'VERIFYING 'REVIEWING)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'APPROVED kind))))
        (gdev-test-assurance--step db id 'APPROVED)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'BASELINED kind))))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'CANCELLED kind))))
        (should (eq (alist-get 'state (gdev-process-get db id)) 'APPROVED))))))

(ert-deftest gdev-test-process-separation-of-duties-follows-the-profile ()
  "Dal profilo secure in su chi propone non autorizza né approva."
  (dolist (profile '(core quality))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db profile)))
        (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
        (should (eq 'AUTHORIZED (gdev-test-assurance--step db id 'AUTHORIZED 'human "proponente"))))))
  (dolist (profile '(secure high-assurance critical))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db profile)))
        (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
        (should (string-match-p "chi ha aperto"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--step db id 'AUTHORIZED 'human "proponente")))))
        (gdev-test-assurance--step db id 'AUTHORIZED 'human "altra persona")
        (gdev-test-assurance--walk db id 'IMPLEMENTING 'VERIFYING)
        (gdev-test-assurance--prove db id)
        (gdev-test-assurance--step db id 'REVIEWING)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'APPROVED 'human "proponente"))))
        (gdev-test-assurance--step db id 'APPROVED 'human "altra persona")
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'BASELINED 'human "proponente"))))
        (should (eq 'BASELINED (gdev-test-assurance--step db id 'BASELINED 'human "altra persona")))))))

(ert-deftest gdev-test-process-blocked-and-suspended-resume-where-they-left ()
  "Blocco e sospensione riprendono solo dallo stato di partenza e da chi può."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED 'AUTHORIZED 'IMPLEMENTING 'VERIFYING)
      ;; Un gate o un agente bloccano; un agente non sblocca.
      (should (eq 'BLOCKED (gdev-test-assurance--step db id 'BLOCKED 'ci "gate")))
      (should (string-match-p "riprende solo da VERIFYING"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-test-assurance--step db id 'IMPLEMENTING 'human)))))
      (should (string-match-p "agente non rimuove"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-test-assurance--step db id 'VERIFYING 'agent)))))
      (should (eq 'VERIFYING (gdev-test-assurance--step db id 'VERIFYING 'ci)))
      ;; Un secondo blocco, in un altro stato, ha il proprio punto di ripresa.
      (gdev-test-assurance--step db id 'REVIEWING)
      (gdev-test-assurance--step db id 'BLOCKED 'agent)
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-test-assurance--step db id 'VERIFYING 'human))))
      (should (eq 'REVIEWING (gdev-test-assurance--step db id 'REVIEWING 'system)))
      ;; Sospendere e riprendere sono riservati a una persona.
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-test-assurance--step db id 'SUSPENDED 'agent))))
      (gdev-test-assurance--step db id 'SUSPENDED 'human)
      (dolist (kind '(agent ci system))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'REVIEWING kind)))))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-test-assurance--step db id 'APPROVED 'human))))
      (should (eq 'REVIEWING (gdev-test-assurance--step db id 'REVIEWING 'human)))
      (should (eq 'CANCELLED (gdev-test-assurance--step db id 'CANCELLED 'human)))
      (should-not (gdev-process-verify db)))))

(ert-deftest gdev-test-process-terminal-states-refuse-everything ()
  "Da REJECTED, CANCELLED e SUPERSEDED non si esce, per nessun attore."
  (gdev-test-assurance--with-archive (root db)
    (let ((rejected (gdev-test-assurance--open db))
          (cancelled (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db rejected 'REJECTED 'human)
      (gdev-test-assurance--step db cancelled 'CANCELLED 'human)
      (dolist (id (list rejected cancelled))
        (dolist (to gdev-process-states)
          (dolist (kind gdev-process-actor-kinds)
            (should (gdev-test-assurance--refusal
                     (lambda () (gdev-test-assurance--step db id to kind)))))))
      (should-not (gdev-process-verify db)))))

(ert-deftest gdev-test-process-supersede-replaces-a-baseline ()
  "Una linea di base si sostituisce solo con una successiva, per mano di una persona."
  (gdev-test-assurance--with-archive (root db)
    (let ((old (gdev-test-assurance--open db))
          (new (gdev-test-assurance--open db))
          (pending (gdev-test-assurance--open db)))
      (dolist (id (list old new))
        (apply #'gdev-test-assurance--walk db id gdev-test-assurance--to-baselined))
      (cl-flet ((supersede (older newer &optional (kind 'human))
                  (gdev-test-assurance--refusal
                   (lambda () (gdev-process-supersede db older newer :actor "x" :actor-kind kind)))))
        (should (supersede old new 'agent))
        (should (supersede pending new))
        (should (supersede old pending))
        (should (supersede new old))
        (should (supersede old "GT-0099"))
        (should (supersede "GT-0099" new))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-process-supersede db old new :actor "" :actor-kind 'human)))))))
  (gdev-test-assurance--with-archive (root db)
    (let ((old (gdev-test-assurance--open db)) (new (gdev-test-assurance--open db)))
      (dolist (id (list old new))
        (apply #'gdev-test-assurance--walk db id gdev-test-assurance--to-baselined))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-process-supersede db old old :actor "x" :actor-kind 'human))))
      (should (string-match-p "gdev-process-supersede"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-process-advance db old 'SUPERSEDED
                                                                :actor "x" :actor-kind 'human)))))
      (should (eq 'SUPERSEDED (gdev-process-supersede db old new :actor "x" :actor-kind 'human
                                                      :note "nuova linea di base")))
      (let ((event (car (last (gdev-process-events db old)))))
        (should (equal (alist-get 'ref event) new))
        (should (eq (alist-get 'from_state event) 'BASELINED)))
      (should (eq (alist-get 'state (gdev-process-get db new)) 'BASELINED))
      (should-not (gdev-process-verify db)))))

(ert-deftest gdev-test-process-event-hash-is-unambiguous ()
  "Spostare un carattere fra due campi cambia l'impronta."
  (let ((one (gdev-process-event-hash gdev-process-genesis-hash "GT-0001" 'open nil 'PROPOSED
                                      "ab" 'human "c" nil "t"))
        (two (gdev-process-event-hash gdev-process-genesis-hash "GT-0001" 'open nil 'PROPOSED
                                      "a" 'human "bc" nil "t"))
        (nothing (gdev-process-event-hash gdev-process-genesis-hash "GT-0001" 'open nil 'PROPOSED
                                          "a" 'human nil "" "t")))
    (should (= (length one) 64))
    (should-not (equal one two))
    (should (equal nothing (gdev-process-event-hash gdev-process-genesis-hash "GT-0001" 'open nil
                                                    'PROPOSED "a" 'human "" nil "t")))))

(ert-deftest gdev-test-process-events-join-the-chain-only-inside-a-transaction ()
  "Un evento fuori da una transazione dell'archivio è un errore di programmazione."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (should-error (gdev-process-append-event db id 'evidence 'PROPOSED 'PROPOSED "x" 'human)
                    :type 'error))))

(ert-deftest gdev-test-process-verify-detects-tampering ()
  "Chi riscrive l'archivio, anche togliendo i trigger, viene scoperto."
  (cl-flet ((problems-after (edit)
              (gdev-test-assurance--with-archive (root db)
                (let ((id (gdev-test-assurance--open db)))
                  (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED 'AUTHORIZED)
                  (gdev-test-assurance--drop-guards db)
                  (funcall edit db id)
                  (gdev-assurance-verify db)))))
    (let ((cases
           `(("l'impronta non corrisponde ai campi"
              ,(lambda (db _) (sqlite-execute db "update tx_event set note = 'riscritta' where seq = 2")))
             ("la catena non torna"
              ,(lambda (db _) (sqlite-execute db "update tx_event set prev_hash = ? where seq = 3"
                                              (list (make-string 64 ?a)))))
             ("la catena non torna"
              ,(lambda (db _) (sqlite-execute db "delete from tx_event where seq = 2")))
             ("ma l'ultimo evento porta a"
              ,(lambda (db _) (sqlite-execute db "delete from tx_event where seq = 4")))
             ("ma l'ultimo evento porta a"
              ,(lambda (db id) (sqlite-execute db "update tx set state = 'BASELINED' where id = ?" (list id))))
             ("non ha eventi"
              ,(lambda (db _) (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'PROPOSED', 'core', 'x')")))
             ("non ha un'apertura"
              ,(lambda (db _)
                 (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'PROPOSED', 'core', 'x')")
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db "GT-0050" 'transition 'PROPOSED
                                                           'CLASSIFIED "x" 'human)))))
             ("è aperta due volte"
              ,(lambda (db id)
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db id 'open nil 'PROPOSED "x" 'human)))))
             ("l'apertura deve portare a PROPOSED"
              ,(lambda (db _)
                 (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'ANALYZED', 'core', 'x')")
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db "GT-0050" 'open nil 'ANALYZED "x" 'human)))))
             ("parte da PROPOSED ma lo stato era AUTHORIZED"
              ,(lambda (db id)
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db id 'transition 'PROPOSED
                                                           'CLASSIFIED "x" 'human)))))
             ("il passaggio AUTHORIZED → PROPOSED non è ammesso"
              ,(lambda (db id)
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db id 'transition 'AUTHORIZED
                                                           'PROPOSED "x" 'human)))))
             ("APPROVED richiede una persona"
              ,(lambda (db id)
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db id 'transition 'AUTHORIZED
                                                           'IMPLEMENTING "x" 'human)
                                (gdev-process-append-event db id 'transition 'IMPLEMENTING
                                                           'VERIFYING "x" 'human)
                                (gdev-process-append-event db id 'transition 'VERIFYING
                                                           'REVIEWING "x" 'human)
                                (gdev-process-append-event db id 'transition 'REVIEWING
                                                           'APPROVED "ag" 'agent)))))
             ("una prova, una decisione o una valutazione non cambia stato"
              ,(lambda (db id)
                 (gdev-assurance-db-transaction
                  db (lambda () (gdev-process-append-event db id 'evidence 'AUTHORIZED
                                                           'IMPLEMENTING "x" 'human)))))
             ("tipo prova"
              ,(lambda (db id)
                 (sqlite-execute db "pragma ignore_check_constraints = on")
                 (gdev-assurance-db-transaction
                  db (lambda ()
                       (sqlite-execute db "insert into tx_event (tx_id, kind, to_state, actor, actor_kind, at, prev_hash, hash)
 values (?, 'prova', 'AUTHORIZED', 'x', 'human', 'x', ?, ?)"
                                       (list id (make-string 64 ?0) (make-string 64 ?9)))))))))
          found)
      (dolist (case cases)
        (let ((problems (problems-after (cadr case))))
          (push (car case) found)
          (should (seq-some (lambda (problem) (string-match-p (regexp-quote (car case)) problem))
                            problems)))))))

;;;; Prove

(ert-deftest gdev-test-evidence-records-the-hash-and-joins-the-chain ()
  "Una prova conserva l'impronta, non il contenuto, ed è un evento della catena."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assurance--open db))
           (file (expand-file-name "referto.txt" root))
           (text (progn (write-region "contenuto del file" nil file nil 'silent) "caffè ☕")))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (should (equal (gdev-evidence-add db id :kind 'fact :description "Test eseguiti"
                                        :content text :actor "ci" :actor-kind 'ci)
                     "EV-0001"))
      (should (equal (gdev-evidence-add db id :kind 'deduction :origin 'reconstructed
                                        :description "Dal referto" :file file
                                        :actor "ci" :actor-kind 'ci)
                     "EV-0002"))
      (let ((rows (gdev-evidence-list db id)))
        (should (equal (mapcar (lambda (row) (alist-get 'ref row)) rows) '("EV-0001" "EV-0002")))
        (should (equal (alist-get 'sha256 (car rows))
                       (secure-hash 'sha256 (encode-coding-string text 'utf-8))))
        (should (equal (alist-get 'sha256 (cadr rows)) (gdev-evidence-file-sha256 file)))
        (should (eq (alist-get 'origin (car rows)) 'collected))
        (should (eq (alist-get 'origin (cadr rows)) 'reconstructed))
        (should (eq (alist-get 'kind (cadr rows)) 'deduction)))
      (should (equal (mapcar (lambda (row) (alist-get 'ref row)) (gdev-evidence-list db))
                     '("EV-0001" "EV-0002")))
      (should-not (gdev-evidence-list db "GT-0099"))
      (let ((event (nth 2 (gdev-process-events db id))))
        (should (eq (alist-get 'kind event) 'evidence))
        (should (eq (alist-get 'from_state event) 'CLASSIFIED))
        (should (eq (alist-get 'to_state event) 'CLASSIFIED))
        (should (equal (alist-get 'ref event) "EV-0001")))
      (should (equal (alist-get 'state (gdev-process-get db id)) 'CLASSIFIED))
      (should-not (gdev-evidence-verify db))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-evidence-validates-its-input ()
  "Genere, origine, contenuto, descrizione, attore e transazione si controllano."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db))
          (file (expand-file-name "f.txt" root)))
      (write-region "x" nil file nil 'silent)
      (dolist (arguments `((:kind opinione :description "d" :content "c")
                           (:kind nil :description "d" :content "c")
                           (:kind fact :origin presunta :description "d" :content "c")
                           (:kind fact :description "" :content "c")
                           (:kind fact :description ,(make-string 501 ?x) :content "c")
                           (:kind fact :description "d")
                           (:kind fact :description "d" :content "c" :file ,file)
                           (:kind fact :description "d" :content 42)
                           (:kind fact :description "d" :file ,(expand-file-name "manca.txt" root))
                           (:kind fact :description "d" :content "c" :actor "")
                           (:kind fact :description "d" :content "c" :actor-kind robot)))
        (should (gdev-test-assurance--refusal
                 (lambda () (apply #'gdev-evidence-add db id
                                   (append arguments (unless (plist-member arguments :actor)
                                                       '(:actor "x"))
                                           (unless (plist-member arguments :actor-kind)
                                             '(:actor-kind human))))))))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-evidence-add db "GT-0099" :kind 'fact :description "d" :content "c"
                                             :actor "x" :actor-kind 'human))))
      (should (null (gdev-evidence-list db))))))

(ert-deftest gdev-test-evidence-is-never-retroactive ()
  "Una transazione conclusa non accetta prove nuove; una in pausa sì."
  (gdev-test-assurance--with-archive (root db)
    (cl-flet ((add (id) (gdev-evidence-add db id :kind 'fact :description "d" :content "c"
                                           :actor "x" :actor-kind 'human)))
      (let ((baselined (gdev-test-assurance--open db))
            (rejected (gdev-test-assurance--open db))
            (cancelled (gdev-test-assurance--open db))
            (superseded (gdev-test-assurance--open db))
            (paused (gdev-test-assurance--open db))
            (newest (gdev-test-assurance--open db)))
        (dolist (id (list baselined superseded newest))
          (apply #'gdev-test-assurance--walk db id gdev-test-assurance--to-baselined))
        (gdev-process-supersede db superseded newest :actor "x" :actor-kind 'human)
        (gdev-test-assurance--step db rejected 'REJECTED 'human)
        (gdev-test-assurance--step db cancelled 'CANCELLED 'human)
        (dolist (id (list baselined rejected cancelled superseded))
          (should (string-match-p "non accetta prove" (gdev-test-assurance--refusal (lambda () (add id))))))
        (gdev-test-assurance--step db paused 'BLOCKED 'ci)
        (should (add paused))
        (gdev-test-assurance--step db paused 'PROPOSED 'ci)
        (gdev-test-assurance--step db paused 'SUSPENDED 'human)
        (should (add paused))
        (should-not (gdev-assurance-verify db))))))

(ert-deftest gdev-test-evidence-verify-detects-tampering ()
  "Riscrivere una prova o i suoi eventi lascia traccia nella verifica."
  (cl-flet ((problems-after (edit)
              (gdev-test-assurance--with-archive (root db)
                (let ((id (gdev-test-assurance--open db)))
                  (gdev-test-assurance--step db id 'CLASSIFIED)
                  (gdev-evidence-add db id :kind 'fact :description "d" :content "c"
                                     :actor "x" :actor-kind 'human)
                  (gdev-test-assurance--drop-guards db)
                  (funcall edit db id)
                  (gdev-evidence-verify db)))))
    (dolist (case `(("l'impronta registrata non è quella dell'evento"
                     ,(lambda (db _) (sqlite-execute db "update evidence set sha256 = ?"
                                                     (list (make-string 64 ?f)))))
                    ("ha un evento ma nessuna prova"
                     ,(lambda (db _) (sqlite-execute db "delete from evidence")))
                    ("non ha l'evento nella catena"
                     ,(lambda (db _) (sqlite-execute db "delete from tx_event where kind = 'evidence'")))
                    ("ha più di un evento"
                     ,(lambda (db id)
                        (gdev-assurance-db-transaction
                         db (lambda ()
                              (gdev-process-append-event
                               db id 'evidence 'CLASSIFIED 'CLASSIFIED "x" 'human
                               :ref "EV-0001" :note (concat "sha256:" (gdev-evidence-sha256 "c")))))))
                    ("la transazione non è quella dell'evento"
                     ,(lambda (db _)
                        (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'PROPOSED', 'core', 'x')")
                        (sqlite-execute db "update evidence set tx_id = 'GT-0050'")))))
      (should (seq-some (lambda (problem) (string-match-p (regexp-quote (car case)) problem))
                        (problems-after (cadr case)))))))

;;;; Motore delle regole

(defmacro gdev-test-policy--with-rules (rules &rest body)
  "Esegui BODY con le sole REGOLE, un alist DOMINIO -> regole come per il motore."
  (declare (indent 1) (debug (form body)))
  `(let ((gdev-policy--rules ,rules)) ,@body))

(ert-deftest gdev-test-policy-applies-rules-in-order-and-the-first-denial-decides ()
  "Le regole girano nell'ordine di registrazione; la prima che nega decide."
  (let ((calls nil))
    (gdev-test-policy--with-rules nil
      (gdev-policy-register 'prova 'prima (lambda (_) (push 'prima calls) nil) "ok")
      (gdev-policy-register 'prova 'seconda (lambda (_) (push 'seconda calls) "No dalla seconda"))
      (gdev-policy-register 'prova 'terza (lambda (_) (push 'terza calls) "No dalla terza"))
      (should (equal (gdev-policy-rules 'prova) '(prima seconda terza)))
      (should (equal (gdev-policy-decide 'prova nil)
                     '(:allowed nil :rule seconda :reason "No dalla seconda")))
      (should (equal (nreverse calls) '(prima seconda)))
      ;; Sostituire una regola ne conserva il posto.
      (gdev-policy-register 'prova 'seconda (lambda (_) nil))
      (should (equal (gdev-policy-rules 'prova) '(prima seconda terza)))
      (should (eq 'terza (plist-get (gdev-policy-decide 'prova nil) :rule)))
      (gdev-policy-register 'prova 'terza (lambda (_) nil))
      (should (equal (gdev-policy-decide 'prova nil) '(:allowed t))))))

(ert-deftest gdev-test-policy-denies-by-default ()
  "Senza regole, con una regola che fallisce o che restituisce altro, si nega."
  (gdev-test-policy--with-rules nil
    (let ((decision (gdev-policy-decide 'vuoto nil)))
      (should-not (plist-get decision :allowed))
      (should (eq (plist-get decision :rule) 'no-rules))
      (should (string-match-p "Nessuna regola per vuoto" (plist-get decision :reason))))
    (gdev-policy-register 'guasto 'esplode (lambda (_) (error "Boom")))
    (let ((decision (gdev-policy-decide 'guasto nil)))
      (should-not (plist-get decision :allowed))
      (should (eq (plist-get decision :rule) 'esplode))
      (should (string-match-p "ha fallito: Boom" (plist-get decision :reason))))
    (dolist (value '(t 42 :si (a b)))
      (gdev-policy-register 'strano 'strana (lambda (_) value))
      (let ((decision (gdev-policy-decide 'strano nil)))
        (should-not (plist-get decision :allowed))
        (should (string-match-p "valore non valido" (plist-get decision :reason)))))
    ;; I domini non si mescolano.
    (gdev-policy-register 'a 'ok (lambda (_) nil))
    (should (plist-get (gdev-policy-decide 'a nil) :allowed))
    (should-not (plist-get (gdev-policy-decide 'b nil) :allowed))))

(ert-deftest gdev-test-policy-process-registers-its-rules-in-a-fixed-order ()
  "Le regole del processo sono registrate, in ordine, e coprono ogni dominio."
  (should (equal (gdev-policy-rules 'open) '(origin-binds-actor-kind)))
  (should (equal (gdev-policy-rules 'transition)
                 '(origin-binds-actor-kind transition-table supersede-only resume-from-origin
                   human-only suspended-resume-human blocked-no-agent separation-of-duties gate)))
  (should (equal (gdev-policy-rules 'supersede)
                 '(origin-binds-actor-kind supersede-human supersede-old-baselined
                   supersede-new-baselined supersede-order)))
  (should (equal (gdev-policy-rules 'evidence)
                 '(origin-binds-actor-kind evidence-open-transaction))))

(ert-deftest gdev-test-policy-a-missing-rule-set-blocks-the-process ()
  "Se il registro è vuoto il processo rifiuta, non lascia passare."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-policy--with-rules nil
        (should (string-match-p "Nessuna regola per transition"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--step db id 'CLASSIFIED)))))
        (should (string-match-p "Nessuna regola per open"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--open db))))))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'PROPOSED))
      (let ((refusal (car (last (gdev-process-events db id)))))
        (should (eq (alist-get 'kind refusal) 'refusal))
        (should (equal (alist-get 'ref refusal) "no-rules"))))))

;;;; Controlli di passaggio

(ert-deftest gdev-test-gates-require-collected-evidence-from-the-state ()
  "Il passaggio da VERIFYING a REVIEWING chiede una prova raccolta in VERIFYING."
  (dolist (profile '(quality secure high-assurance critical))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db profile)))
        (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
        (gdev-process-advance db id 'AUTHORIZED :actor "altra persona" :actor-kind 'human)
        (gdev-test-assurance--walk db id 'IMPLEMENTING)
        ;; Una prova registrata prima di VERIFYING non conta.
        (gdev-test-assurance--prove db id)
        (gdev-test-assurance--step db id 'VERIFYING)
        (let ((reason (gdev-test-assurance--refusal
                       (lambda () (gdev-test-assurance--step db id 'REVIEWING)))))
          (should (string-match-p "verification-evidence richiede almeno 1 prove fact (collected)" reason))
          (should (string-match-p "ne risultano 0" reason)))
        ;; Né una prova di un altro genere o di un'altra origine.
        (gdev-test-assurance--prove db id 'deduction)
        (gdev-test-assurance--prove db id 'hypothesis)
        (gdev-test-assurance--prove db id 'fact 'reconstructed)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'REVIEWING))))
        (gdev-test-assurance--prove db id)
        (should (eq 'REVIEWING (gdev-test-assurance--step db id 'REVIEWING)))
        (should-not (gdev-assurance-verify db))))))

(ert-deftest gdev-test-gates-do-not-reuse-evidence-after-a-return ()
  "Tornare in VERIFYING dopo una verifica fallita non riusa le prove di prima."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'quality)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED 'AUTHORIZED 'IMPLEMENTING 'VERIFYING)
      (gdev-test-assurance--prove db id)
      (gdev-test-assurance--step db id 'REVIEWING)
      (gdev-test-assurance--walk db id 'IMPLEMENTING 'VERIFYING)
      (should (string-match-p "ne risultano 0"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-test-assurance--step db id 'REVIEWING)))))
      (gdev-test-assurance--prove db id)
      (should (eq 'REVIEWING (gdev-test-assurance--step db id 'REVIEWING))))))

(ert-deftest gdev-test-gates-leave-the-core-profile-and-other-passages-alone ()
  "Il profilo core non ha controlli; gli altri passaggi non sono toccati."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core)))
      (apply #'gdev-test-assurance--walk db id gdev-test-assurance--to-baselined)
      (should (eq (alist-get 'state (gdev-process-get db id)) 'BASELINED))
      (should-not (gdev-evidence-list db id))))
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'critical)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (should (eq 'BLOCKED (gdev-test-assurance--step db id 'BLOCKED 'ci)))
      (should (eq 'ANALYZED (gdev-test-assurance--step db id 'ANALYZED 'ci))))))

(ert-deftest gdev-test-gates-follow-the-table-they-are-given ()
  "Il controllo si definisce nei dati: un'altra tabella cambia l'esito."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core)))
      (gdev-test-assurance--walk db id 'CLASSIFIED)
      (let ((gdev-gates-table
             '((:id due-prove :profiles (core) :from CLASSIFIED :to ANALYZED
                :needs ((:kind hypothesis :origin reconstructed :minimum 2))))))
        (should (string-match-p "due-prove richiede almeno 2 prove hypothesis (reconstructed)"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--step db id 'ANALYZED)))))
        (gdev-test-assurance--prove db id 'hypothesis 'reconstructed)
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'ANALYZED))))
        (gdev-test-assurance--prove db id 'hypothesis 'reconstructed)
        (should (eq 'ANALYZED (gdev-test-assurance--step db id 'ANALYZED)))))))

;;;; Traccia dei rifiuti

(ert-deftest gdev-test-process-refusals-are-recorded-with-rule-and-reason ()
  "Il rifiuto di un passaggio entra nella catena con chi, cosa, regola e motivo."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (cl-flet ((refusals ()
                  (seq-filter (lambda (e) (eq (alist-get 'kind e) 'refusal))
                              (gdev-process-events db id))))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-process-advance db id 'BASELINED :actor "ag" :actor-kind 'agent))))
        (should (= (length (refusals)) 1))
        (let ((event (car (refusals))))
          (should (eq (alist-get 'from_state event) 'CLASSIFIED))
          (should (eq (alist-get 'to_state event) 'BASELINED))
          (should (equal (alist-get 'actor event) "ag"))
          (should (eq (alist-get 'actor_kind event) 'agent))
          (should (equal (alist-get 'ref event) "transition-table"))
          (should (string-match-p "non si passa a BASELINED" (alist-get 'note event))))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-process-advance db id 'APPROVED :actor "p" :actor-kind 'human))))
        (should (equal (mapcar (lambda (e) (alist-get 'to_state e)) (refusals))
                       '(BASELINED APPROVED))))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'CLASSIFIED))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-process-refusals-of-evidence-and-supersede-are-recorded ()
  "Anche le prove su una transazione chiusa e le sostituzioni rifiutate lasciano traccia."
  (gdev-test-assurance--with-archive (root db)
    (let ((closed (gdev-test-assurance--open db))
          (other (gdev-test-assurance--open db)))
      (apply #'gdev-test-assurance--walk db closed gdev-test-assurance--to-baselined)
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-test-assurance--prove db closed))))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-process-supersede db closed other :actor "x" :actor-kind 'human))))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-process-supersede db closed other :actor "x" :actor-kind 'agent))))
      (let ((refusals (seq-filter (lambda (e) (eq (alist-get 'kind e) 'refusal))
                                  (gdev-process-events db closed))))
        (should (equal (mapcar (lambda (e) (alist-get 'ref e)) refusals)
                       '("evidence-open-transaction" "supersede-new-baselined" "supersede-human")))
        (should (equal (mapcar (lambda (e) (alist-get 'to_state e)) refusals)
                       '(BASELINED SUPERSEDED SUPERSEDED))))
      ;; Il secondo fallisce perché other non è una linea di base, il terzo perché l'attore è un agente.
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-process-refusals-without-a-transaction-or-valid-input-leave-no-event ()
  "Senza una transazione o con dati invalidi non c'è un evento a cui riferire il rifiuto."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (let ((before (gdev-test-assurance--event-count db)))
        (dolist (attempt (list (lambda () (gdev-process-advance db "GT-0099" 'CLASSIFIED
                                                                :actor "x" :actor-kind 'human))
                               (lambda () (gdev-process-advance db id 'NONSTATO
                                                                :actor "x" :actor-kind 'human))
                               (lambda () (gdev-process-advance db id 'CLASSIFIED
                                                                :actor "" :actor-kind 'human))
                               (lambda () (gdev-process-supersede db id "GT-0099"
                                                                  :actor "x" :actor-kind 'human))
                               (lambda () (gdev-process-open db :title "t" :profile 'core
                                                             :actor "x" :actor-kind 'robot))))
          (should (gdev-test-assurance--refusal attempt)))
        (should (= before (gdev-test-assurance--event-count db)))))))

(ert-deftest gdev-test-process-refusal-inside-an-outer-transaction-is-kept-when-handled ()
  "Dentro una transazione aperta dal chiamante, il rifiuto resta se lo gestisce e conferma."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-assurance-db-transaction
       db (lambda ()
            (should (gdev-test-assurance--refusal
                     (lambda () (gdev-test-assurance--step db id 'APPROVED))))))
      (should (equal (alist-get 'ref (car (last (gdev-process-events db id)))) "transition-table"))
      ;; Se l'errore risale e la transazione esterna cade, non resta nulla.
      (should-error
       (gdev-assurance-db-transaction
        db (lambda () (gdev-test-assurance--step db id 'APPROVED))))
      (should (= 2 (length (gdev-process-events db id))))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-process-verify-checks-refusal-events ()
  "Un rifiuto che parte dallo stato sbagliato o senza regola è un problema."
  (cl-flet ((problems-after (edit)
              (gdev-test-assurance--with-archive (root db)
                (let ((id (gdev-test-assurance--open db)))
                  (gdev-test-assurance--step db id 'CLASSIFIED)
                  (funcall edit db id)
                  (gdev-assurance-verify db)))))
    (dolist (edit (list (lambda (db id)
                          (gdev-assurance-db-transaction
                           db (lambda () (gdev-process-append-event db id 'refusal 'PROPOSED 'APPROVED
                                                                    "x" 'human :ref "human-only"))))
                        (lambda (db id)
                          (gdev-assurance-db-transaction
                           db (lambda () (gdev-process-append-event db id 'refusal 'CLASSIFIED 'APPROVED
                                                                    "x" 'human))))))
      (should (seq-some (lambda (problem) (string-match-p "un rifiuto parte dallo stato corrente" problem))
                        (problems-after edit))))
    ;; Un rifiuto regolare non cambia lo stato che la verifica si aspetta.
    (should-not (problems-after
                 (lambda (db id)
                   (gdev-assurance-db-transaction
                    db (lambda () (gdev-process-append-event db id 'refusal 'CLASSIFIED 'APPROVED
                                                             "x" 'human :ref "transition-table"
                                                             :note "no"))))))))

;;;; Origine del canale

(ert-deftest gdev-test-process-origin-binds-the-actor-kind-to-the-channel ()
  "Un canale impone il tipo d'attore: chi ne dichiara un altro è rifiutato e registrato."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (let ((gdev-process-origin 'agent))
        (should (string-match-p "Il canale impone attori di tipo agent: human non è ammesso"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--step db id 'AUTHORIZED 'human)))))
        ;; Aprire non ha una transazione a cui riferire il rifiuto.
        (should (string-match-p "Il canale impone"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assurance--open db)))))
        (should (eq 'BLOCKED (gdev-process-advance db id 'BLOCKED :actor "x" :actor-kind 'agent)))
        (should (gdev-evidence-add db id :kind 'fact :description "d" :content "c"
                                   :actor "x" :actor-kind 'agent)))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'BLOCKED))
      ;; Il vincolo vale anche all'inverso: un canale umano non registra attori agente.
      (let ((gdev-process-origin 'human))
        (should (gdev-test-assurance--refusal
                 (lambda () (gdev-test-assurance--step db id 'ANALYZED 'agent))))
        (should (eq 'ANALYZED (gdev-test-assurance--step db id 'ANALYZED 'human))))
      (should (equal (mapcar (lambda (e) (alist-get 'ref e))
                             (seq-filter (lambda (e) (eq (alist-get 'kind e) 'refusal))
                                         (gdev-process-events db id)))
                     '("origin-binds-actor-kind" "origin-binds-actor-kind")))
      (should-not (gdev-assurance-verify db)))))

(defvar gdev-test-assurance--db nil
  "Archivio a cui una forma valutata da un agente di prova può arrivare.")

(ert-deftest gdev-test-process-agent-actions-run-with-the-agent-origin ()
  "Ciò che un agente valuta dall'editor conta come azione di un agente."
  (require 'gdev-agent-control)
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assurance--open db))
           (gdev-test-assurance--db db))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (should (equal (alist-get 'value (gdev-agent-control-request "eval" "gdev-process-origin" "5" "false"))
                     "agent"))
      (should-not gdev-process-origin)
      ;; Un agente che valuta un'autorizzazione dichiarandosi persona viene rifiutato.
      (should-error
       (gdev-agent-control-request
        "eval" (format "(gdev-process-advance gdev-test-assurance--db %S 'AUTHORIZED :actor \"ag\" :actor-kind 'human)" id)
        "5" "false"))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'ANALYZED))
      (should (equal (alist-get 'ref (car (last (gdev-process-events db id))))
                     "origin-binds-actor-kind"))
      ;; Dichiarandosi agente può fare ciò che spetta a un agente.
      (gdev-agent-control-request
       "eval" (format "(gdev-process-advance gdev-test-assurance--db %S 'BLOCKED :actor \"ag\" :actor-kind 'agent)" id)
       "5" "false")
      (should (eq (alist-get 'state (gdev-process-get db id)) 'BLOCKED)))))

;;;; Migrazione 2

(ert-deftest gdev-test-assurance-db-migration-2-keeps-the-chain-and-allows-refusals ()
  "Salire da un archivio della versione 1 conserva dati e catena e accetta i rifiuti."
  (gdev-test-assurance--with-root root
    (let ((all gdev-assurance-db--migrations)
          id)
      (let ((gdev-assurance-db--migrations (list (car all))))
        (gdev-assurance-db-with-open (db root 'write)
          (setq id (gdev-test-assurance--open db))
          (gdev-test-assurance--walk db id 'CLASSIFIED)
          (gdev-test-assurance--prove db id)
          (should (= (gdev-assurance-db-version db) 1))
          (should-error (sqlite-execute db "insert into tx_event (tx_id, kind, from_state, to_state, actor, actor_kind, at, prev_hash, hash)
 values (?, 'refusal', 'PROPOSED', 'APPROVED', 'x', 'human', 'x', ?, ?)"
                                        (list id (make-string 64 ?0) (make-string 64 ?1))))))
      (let ((gdev-assurance-db--migrations (seq-take all 2)))
       (gdev-assurance-db-with-open (db root 'write)
        (should (= (gdev-assurance-db-version db) 2))
        (should (= 3 (gdev-test-assurance--event-count db)))
        (should-not (append (gdev-process-verify db) (gdev-evidence-verify db)))
        (should (gdev-test-assurance--refusal (lambda () (gdev-test-assurance--step db id 'APPROVED))))
        (gdev-test-assurance--step db id 'ANALYZED)
        (should (= 5 (gdev-test-assurance--event-count db)))
        (should-not (append (gdev-process-verify db) (gdev-evidence-verify db)))
        ;; I trigger della nuova tabella proteggono ancora la cronologia.
        (should-error (sqlite-execute db "update tx_event set actor = 'altro'"))
        (should-error (sqlite-execute db "delete from tx_event"))
        (should (equal (alist-get 'seq (car (last (gdev-process-events db id)))) 5)))))))

;;;; Dati strutturati e strumento MCP

(defun gdev-test-assurance--populate (db)
  "Riempie DB con tre transazioni, una prova e un rifiuto, e restituisci gli id."
  (let ((first (gdev-test-assurance--open db 'secure))
        (second (gdev-test-assurance--open db))
        (third (gdev-test-assurance--open db)))
    (gdev-test-assurance--walk db first 'CLASSIFIED)
    (gdev-test-assurance--prove db first)
    (should (gdev-test-assurance--refusal
             (lambda () (gdev-process-advance db first 'BASELINED :actor "ag" :actor-kind 'agent))))
    (gdev-test-assurance--step db second 'CANCELLED 'human)
    (list first second third)))

(ert-deftest gdev-test-assurance-data-is-ready-for-json ()
  "I dati di ogni comando si serializzano in JSON e riportano i campi attesi."
  (gdev-test-assurance--with-archive (root db)
    (pcase-let ((`(,first ,second ,_third) (gdev-test-assurance--populate db)))
      (gdev-assurance-db-close db)
      (let* ((status (gdev-assurance-data "status" root))
             (list-all (gdev-assurance-data "list" root))
             (list-one (gdev-assurance-data "list" root "cancelled"))
             (show (gdev-assurance-data "show" root first))
             (verify (gdev-assurance-data "verify" root)))
        (dolist (data (list status list-all list-one show verify))
          (should (stringp (json-serialize data))))
        (should (eq (alist-get 'archive status) t))
        (should (equal (alist-get 'file status) (gdev-assurance-db-file root)))
        (should (= (alist-get 'schema_version status) (alist-get 'latest_schema_version status)))
        (should (equal (alist-get 'transactions status)
                       '((CLASSIFIED . 1) (CANCELLED . 1) (PROPOSED . 1))))
        (should (= (alist-get 'transaction_count status) 3))
        (should (= (alist-get 'refusals status) 1))
        (should (= (alist-get 'evidence status) 1))
        (should (= (length (alist-get 'transactions list-all)) 3))
        (should (= (alist-get 'total list-all) 3))
        (should (eq (alist-get 'state list-all) :null))
        (should (equal (alist-get 'state list-one) "CANCELLED"))
        (should (equal (mapcar (lambda (row) (alist-get 'id row)) (alist-get 'transactions list-one))
                       (list second)))
        (should (equal (alist-get 'state (alist-get 'transaction show)) "CLASSIFIED"))
        (should (= (alist-get 'events_total show) 4))
        (should (equal (alist-get 'kind (aref (alist-get 'events show) 3)) "refusal"))
        (should (eq (alist-get 'note (aref (alist-get 'events show) 0)) :null))
        (should (equal (alist-get 'ref (aref (alist-get 'evidence show) 0)) "EV-0001"))
        (should (eq (alist-get 'ok verify) t))
        (should (equal (alist-get 'problems verify) []))))))

(ert-deftest gdev-test-assurance-data-without-an-archive-and-with-bad-arguments ()
  "Senza archivio status lo dice; gli altri comandi, e gli argomenti sbagliati, segnalano."
  (gdev-test-assurance--with-root root
    (should (equal (gdev-assurance-data "status" root) `((archive . :false) (root . ,root))))
    (dolist (command '("list" "verify"))
      (should-error (gdev-assurance-data command root) :type 'gdev-assurance-db-missing))
    (should-not (file-exists-p (concat root ".gdev"))))
  (gdev-test-assurance--with-archive (root db)
    (gdev-assurance-db-close db)
    (should-error (gdev-assurance-data "show" root "GT-0099") :type 'gdev-assurance-no-transaction)
    (should-error (gdev-assurance-data "show" root nil) :type 'gdev-assurance-no-transaction)
    (should-error (gdev-assurance-data "list" root "nonstato") :type 'user-error)
    (should-error (gdev-assurance-data "scrivi" root) :type 'error)))

(ert-deftest gdev-test-assurance-data-cuts-long-lists-to-the-latest-rows ()
  "Con un limite si restituiscono le ultime righe e il totale a parte."
  (gdev-test-assurance--with-archive (root db)
    (let ((ids (cl-loop repeat 5 collect (gdev-test-assurance--open db))))
      (dotimes (_ 4) (ignore-errors (gdev-process-advance db (car ids) 'BASELINED
                                                          :actor "x" :actor-kind 'agent)))
      (gdev-assurance-db-close db)
      (let ((list (gdev-assurance-data "list" root nil 2))
            (show (gdev-assurance-data "show" root (car ids) 3)))
        (should (equal (mapcar (lambda (row) (alist-get 'id row)) (alist-get 'transactions list))
                       (last ids 2)))
        (should (= (alist-get 'total list) 5))
        (should (= (length (alist-get 'events show)) 3))
        (should (= (alist-get 'events_total show) 5))
        (should (equal (alist-get 'seq (aref (alist-get 'events show) 2)) 9))))))

(defun gdev-test-assurance--live (&rest arguments)
  "Esegui l'azione dal vivo `assurance' con ARGUMENTS e restituisci i suoi dati."
  (alist-get 'assurance (gdev-agent-interface--dispatch "assurance" arguments)))

(ert-deftest gdev-test-assurance-live-action-reads-through-the-interface ()
  "L'azione dal vivo legge l'archivio per radice o dalla cartella della finestra."
  (gdev-test-assurance--with-archive (root db)
    (pcase-let ((`(,first . ,_) (gdev-test-assurance--populate db)))
      (gdev-assurance-db-close db)
      (let ((status (gdev-test-assurance--live "status" "" root)))
        (should (eq (alist-get 'archive status) t))
        (should (= (alist-get 'transaction_count status) 3)))
      (should (= (length (alist-get 'transactions (gdev-test-assurance--live "list" "proposed" root))) 1))
      (should (equal (alist-get 'id (alist-get 'transaction
                                                (gdev-test-assurance--live "show" first root)))
                     first))
      (should (eq (alist-get 'ok (gdev-test-assurance--live "verify" "" root)) t))
      ;; Senza radice si parte dalla cartella della finestra selezionata e si risale.
      (make-directory (concat root "src/") t)
      (let ((buffer (window-buffer (selected-window))))
        (with-current-buffer buffer
          (let ((default-directory (concat root "src/")))
            (should (equal (alist-get 'root (gdev-test-assurance--live "status" "" "")) root)))))
      ;; Il risultato passa da json-serialize come per ogni azione.
      (should (stringp (json-serialize (gdev-agent-interface--dispatch "assurance"
                                                                       (list "show" first root)))))
      ;; Gli errori diventano messaggi in italiano, senza toccare l'archivio.
      (dolist (case `((("show" "GT-0099" ,root) . "La transazione GT-0099 non esiste")
                      (("show" "" ,root) . "Indica l.identificativo")
                      (("assess" "" ,root) . "Indica l.identificativo")
                      (("scrivi" "" ,root) . "Indica uno fra status")
                      (("list" "nonstato" ,root) . "Stato sconosciuto")))
        (let ((err (should-error (apply #'gdev-test-assurance--live (car case)) :type 'user-error)))
          (should (string-match-p (cdr case) (cadr err))))))
    (gdev-test-assurance--with-root other
      (let ((err (should-error (gdev-test-assurance--live "verify" "" other) :type 'user-error)))
        (should (string-match-p "Nessun archivio di assicurazione" (cadr err))))
      (let ((err (should-error (gdev-test-assurance--live "list" "" other) :type 'user-error)))
        (should (string-match-p "Nessun archivio" (cadr err)))))))

(ert-deftest gdev-test-assurance-live-action-is-listed-and-read-only ()
  "Lo strumento è nel catalogo, con la stessa arità dell'azione, e dichiara di sola lettura."
  (should (equal (cdr (assoc "assurance" gdev-agent-interface--live-actions)) 3))
  (should (member "gdev_assurance" gdev-mcp-all-tools))
  (let ((tool (cdr (assoc "gdev_assurance" gdev-mcp--tools))))
    (should (equal (alist-get 'required (alist-get 'inputSchema tool)) ["command"]))
    (should (eq (alist-get 'readOnlyHint (alist-get 'annotations tool)) t))
    (should (eq (alist-get 'destructiveHint (alist-get 'annotations tool)) :false))
    (should (equal (alist-get 'enum (alist-get 'command (alist-get 'properties (alist-get 'inputSchema tool))))
                   (vconcat (gdev-assurance-read-commands))))))

(ert-deftest gdev-test-assurance-mcp-validates-its-arguments ()
  "Comando, argomento e radice dello strumento si controllano prima di arrivare all'editor."
  (dolist (command '("status" "list" "show" "verify" "assess"))
    (should (equal (gdev-mcp--operand 'assurance-command command) command)))
  (dolist (invalid '("scrivi" "" nil 5))
    (should-error (gdev-mcp--operand 'assurance-command invalid) :type 'user-error))
  (should (equal (gdev-mcp--operand 'assurance-argument "") ""))
  (should (equal (gdev-mcp--operand 'assurance-argument "GT-0001") "GT-0001"))
  (dolist (invalid (list nil 5 (make-string 4097 ?x) "a\0b"))
    (should-error (gdev-mcp--operand 'assurance-argument invalid) :type 'user-error))
  (gdev-test-assurance--with-root root
    (should (equal (gdev-mcp--operand 'assurance-root "") ""))
    (should (equal (gdev-mcp--operand 'assurance-root root) root))
    (dolist (invalid (list nil 5 "relativo/" (concat root "manca/") (make-string 4097 ?/)))
      (should-error (gdev-mcp--operand 'assurance-root invalid) :type 'user-error))))

;;;; Sottocomandi

(defun gdev-test-assurance--cli (root &rest arguments)
  "Esegui `gdev assurance' ARGUMENTS da ROOT e restituisci (STATO . TESTO)."
  (let* ((default-directory root)
         (status nil)
         (text (with-output-to-string (setq status (gdev-assurance-cli arguments)))))
    (cons status text)))

(defun gdev-test-assurance--snapshot (root)
  "Restituisci i file sotto ROOT con dimensione e data, per confrontare prima e dopo."
  (mapcar (lambda (file)
            (let ((attributes (file-attributes file)))
              (list file (file-attribute-size attributes) (file-attribute-modification-time attributes))))
          (directory-files-recursively root "" t)))

(ert-deftest gdev-test-assurance-cli-without-an-archive-creates-nothing ()
  "Senza archivio, status lo dice con esito 0 e gli altri sottocomandi con 1; nulla si crea."
  (gdev-test-assurance--with-root root
    (let ((status (gdev-test-assurance--cli root "status")))
      (should (= (car status) 0))
      (should (string-match-p "Nessun archivio di assicurazione" (cdr status)))
      (should (string-match-p "non crea nulla" (cdr status))))
    (dolist (arguments '(("list") ("show" "GT-0001") ("verify")))
      (let ((result (apply #'gdev-test-assurance--cli root arguments)))
        (should (= (car result) 1))
        (should (string-match-p "Nessun archivio" (cdr result)))))
    (should-not (file-exists-p (concat root ".gdev")))))

(ert-deftest gdev-test-assurance-cli-reads-an-archive-without-changing-it ()
  "I sottocomandi mostrano archivio, transazioni, eventi e prove senza toccare nulla."
  (gdev-test-assurance--with-archive (root db)
    (let ((first (gdev-test-assurance--open db 'secure))
          (second (gdev-test-assurance--open db)))
      (gdev-test-assurance--walk db first 'CLASSIFIED)
      (gdev-process-advance db first 'BLOCKED :actor "gate" :actor-kind 'ci
                            :note "gate\nnegato")
      (gdev-evidence-add db first :kind 'fact :description "Esito del gate" :content "x"
                         :actor "gate" :actor-kind 'ci)
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-process-advance db first 'APPROVED :actor "p" :actor-kind 'human))))
      (gdev-assurance-db-close db)
      (make-directory (concat root "src/") t)
      (let ((before (gdev-test-assurance--snapshot root))
            (sub (concat root "src/")))
        (let ((status (gdev-test-assurance--cli sub "status")))
          (should (= (car status) 0))
          (should (string-search (format "Schema:        versione %d di %d"
                                        (gdev-assurance-db-latest-version)
                                        (gdev-assurance-db-latest-version)) (cdr status)))
          (should (string-match-p "Transazioni:   2 (Bloccata 1, Proposta 1)" (cdr status)))
          (should (string-match-p "Eventi, prove, rifiuti, decisioni, valutazioni: 6, 1, 1, 0, 0" (cdr status)))
          (should (string-match-p "Ultimo evento: 2026-01-01T" (cdr status))))
        (let ((listing (gdev-test-assurance--cli sub "list")))
          (should (string-match-p "GT-0001 +Bloccata +Sicuro +Modifica di prova" (cdr listing)))
          (should (string-match-p "GT-0002 +Proposta +Essenziale" (cdr listing))))
        (let ((filtered (gdev-test-assurance--cli sub "list" "proposed")))
          (should (string-match-p "GT-0002" (cdr filtered)))
          (should-not (string-match-p "GT-0001" (cdr filtered))))
        (should (string-match-p "Nessuna transazione nello stato Consolidata"
                                (cdr (gdev-test-assurance--cli sub "list" "BASELINED"))))
        (let ((shown (gdev-test-assurance--cli sub "show" second)))
          (should (= (car shown) 0))
          (should (string-match-p "Prove: nessuna" (cdr shown))))
        (let ((shown (gdev-test-assurance--cli sub "show" first)))
          (should (string-match-p "Classificata → Bloccata +CI:gate +\\[gate negato\\]" (cdr shown)))
          (should (string-match-p "Bloccata ✗ Approvata +Persona:p +\\[resume-from-origin: Da BLOCKED si riprende solo da CLASSIFIED\\]"
                                  (cdr shown)))
          (should (string-match-p "EV-0001 +fact +collected +Esito del gate +sha256:[0-9a-f]\\{12\\}…"
                                  (cdr shown))))
        (let ((verified (gdev-test-assurance--cli sub "verify")))
          (should (= (car verified) 0))
          (should (string-match-p "Archivio integro: 2 transazioni, 6 eventi, 1 prova\\." (cdr verified))))
        (should (equal before (gdev-test-assurance--snapshot root)))))))

(ert-deftest gdev-test-assurance-cli-reports-missing-and-unusable-archives ()
  "Transazione inesistente, archivio vecchio o nuovo e problemi danno esito 1."
  (gdev-test-assurance--with-archive (root db)
    (gdev-assurance-db-close db)
    (let ((missing (gdev-test-assurance--cli root "show" "GT-0099")))
      (should (= (car missing) 1))
      (should (string-match-p "GT-0099 non esiste" (cdr missing))))
    (gdev-assurance-db-with-open (db root 'write)
      (sqlite-execute db "insert into schema_migrations values (9, 'x', 'x')"))
    (let ((result (gdev-test-assurance--cli root "verify")))
      (should (= (car result) 1))
      (should (string-search (format "più recente di GDev: 9, %d" (gdev-assurance-db-latest-version))
                             (cdr result))))))

(ert-deftest gdev-test-assurance-cli-reports-an-uninitialized-archive ()
  "Un file vuoto non è un archivio: serve la migrazione e la CLI non la fa."
  (gdev-test-assurance--with-root root
    (let ((file (gdev-assurance-db-file root)))
      (make-directory (file-name-directory file) t)
      (write-region "" nil file nil 'silent)
      (let ((result (gdev-test-assurance--cli root "list")))
        (should (= (car result) 1))
        (should (string-search (format "serve la migrazione: 0, %d" (gdev-assurance-db-latest-version))
                               (cdr result))))
      (should (= 0 (file-attribute-size (file-attributes file)))))))

(ert-deftest gdev-test-assurance-cli-verify-reports-tampering ()
  "Una catena alterata dà esito 1 e un elenco di problemi."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (gdev-test-assurance--drop-guards db)
      (sqlite-execute db "update tx_event set actor = 'altro' where seq = 1")
      (gdev-assurance-db-close db)
      (let ((result (gdev-test-assurance--cli root "verify")))
        (should (= (car result) 1))
        (should (string-match-p "Problemi trovati ([0-9]+):" (cdr result)))
        (should (string-match-p "Evento 1: l'impronta non corrisponde" (cdr result)))
        (should (string-match-p "Oggetto dello schema mancante: tx_event_no_update" (cdr result)))))))

(ert-deftest gdev-test-assurance-cli-rejects-bad-usage ()
  "Sottocomandi e operandi sbagliati danno esito 2 senza aprire l'archivio."
  (gdev-test-assurance--with-root root
    (dolist (arguments '(nil ("sconosciuto") ("status" "x") ("verify" "x") ("list" "a" "b")
                         ("show") ("show" "a" "b")))
      (let ((result (apply #'gdev-test-assurance--cli root arguments)))
        (should (= (car result) 2))
        (should (string-match-p "Uso: gdev assurance status" (cdr result)))))
    (let ((result (gdev-test-assurance--cli root "list" "nonstato")))
      (should (= (car result) 2))
      (should (string-match-p "Stato sconosciuto: nonstato" (cdr result))))
    (should-not (file-exists-p (concat root ".gdev")))))

(ert-deftest gdev-test-assurance-kernel-loads-alone ()
  "Il nucleo carica senza la configurazione di GDev, i moduli o altri pacchetti."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (file-name-directory (locate-library "gdev-assurance")))
         (output (with-temp-buffer
                   (list (call-process
                          emacs nil t nil "--batch" "-Q" "-L" lisp "--eval"
                          "(progn (setq load-prefer-newer t) (require 'gdev-assurance)
 (princ (list (featurep 'gdev-lib) (featurep 'gdev-core) (featurep 'package)
              (featurep 'gdev-ui) (featurep 'gdev-layout)
              (fboundp 'gdev-process-open) (fboundp 'gdev-assurance-project-data))))")
                         (buffer-string)))))
    (should (= 0 (car output)))
    (should (string-match-p "(nil nil nil nil nil t t)" (cadr output)))))

(provide 'gdev-assurance-test)
(ert-deftest gdev-test-assurance-evidence-metadata-matches-the-audit-event ()
  "Autore, tipo d'attore e data di una prova devono coincidere con la catena."
  (dolist (case '(("actor" "altra persona" "l'attore")
                  ("actor_kind" "human" "il tipo d'attore")
                  ("collected_at" "2099-01-01T00:00:00Z" "la data")))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-test-assurance--prove db id)
        (should-not (gdev-assurance-verify db))
        (gdev-test-assurance--edit-restoring-guard
         db "evidence_no_update" (format "update evidence set %s = ?" (car case)) (cadr case))
        (should-not (gdev-assurance-db-integrity db))
        (should-not (gdev-process-verify db))
        (let ((data (gdev-assurance-data "verify" root)))
          (should (eq (alist-get 'ok data) :false))
          (should (seq-some (lambda (problem) (string-search (nth 2 case) problem))
                            (alist-get 'problems data))))))))

(ert-deftest gdev-test-assurance-cli-and-live-verify-detect-metadata-changes ()
  "CLI e agente mostrano lo stesso errore quando una prova cambia autore."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--prove db id)
      (gdev-test-assurance--edit-restoring-guard
       db "evidence_no_update" "update evidence set actor = 'autore diverso'")
      (let ((result (gdev-test-assurance--cli root "verify"))
            (live (gdev-test-assurance--live "verify" "" root)))
        (should (= (car result) 1))
        (should (string-search "EV-0001: l'attore" (cdr result)))
        (should (eq (alist-get 'ok live) :false))
        (should (seq-some (lambda (problem) (string-search "EV-0001: l'attore" problem))
                          (alist-get 'problems live)))))))

;;; gdev-assurance-test.el ends here
