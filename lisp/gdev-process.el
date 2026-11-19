;;; gdev-process.el --- Transazioni ingegneristiche e catena di audit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una transazione ingegneristica porta una modifica da PROPOSED a
;; BASELINED attraverso stati ammessi esplicitamente.  Ogni passaggio è un
;; evento della catena di audit: l'impronta di un evento include quella del
;; precedente, quindi ogni alterazione successiva si rileva.
;;
;; Le regole sono del motore `gdev-policy', deterministiche, e si nega per
;; impostazione predefinita:
;;
;;   - una coppia di stati che non è nella tabella `gdev-process-transitions'
;;     è rifiutata;
;;   - AUTHORIZED, APPROVED, BASELINED e gli altri passaggi riservati
;;     richiedono un attore umano; un agente non li compie mai;
;;   - dal profilo `secure' in su chi ha aperto la transazione non la
;;     autorizza né la approva;
;;   - un lavoro BLOCKED o SUSPENDED riprende solo dallo stato che aveva;
;;   - i controlli di passaggio di `gdev-gates' chiedono le prove.
;;
;; Un passaggio rifiutato non cambia lo stato e lascia nella catena un
;; evento `refusal' con la regola e il motivo.  Non lo lascia se manca la
;; transazione o se i dati sono invalidi: senza una transazione o un attore
;; leggibili non c'è nulla a cui riferirlo.
;;
;; Limite dichiarato: il nucleo non autentica l'attore.  Un canale (CLI, MCP,
;; azioni dal vivo degli agenti) lega `gdev-process-origin' al tipo d'attore
;; che gli compete: il nucleo rifiuta e registra chi dichiara un tipo
;; diverso.  Questo ferma le chiamate ingenue e gli errori, non un agente che
;; valuta Lisp e riassegna volutamente la variabile, riscrive il file
;; dell'archivio o ridefinisce il nucleo: in questo processo non esiste un
;; confine che lo impedisca.  L'argine reale sta fuori, nel controllo in CI.
;;
;; Ogni scrittura sta in una transazione SQL: se qualcosa fallisce, non
;; resta nulla.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'subr-x)
(require 'gdev-assurance-db)
(require 'gdev-policy)
(require 'gdev-gates)

(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(define-error 'gdev-process-refused "Passaggio rifiutato" 'gdev-assurance-error)

;;;; Stati e regole

(defconst gdev-process-states
  '(PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING
    APPROVED BASELINED BLOCKED REJECTED SUSPENDED CANCELLED SUPERSEDED)
  "Stati di una transazione.")

(defconst gdev-process-profiles '(core quality secure high-assurance critical)
  "Profili di rigore, dal più leggero al più rigido.")

(defconst gdev-process-actor-kinds '(human agent ci system)
  "Tipi di attore che il nucleo distingue.")

(defconst gdev-process--active-states
  '(PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED)
  "Stati in cui il lavoro è in corso e si può bloccare, sospendere o annullare.")

(defconst gdev-process-transitions
  '((PROPOSED CLASSIFIED BLOCKED SUSPENDED REJECTED CANCELLED)
    (CLASSIFIED ANALYZED BLOCKED SUSPENDED REJECTED CANCELLED)
    (ANALYZED AUTHORIZED BLOCKED SUSPENDED REJECTED CANCELLED)
    (AUTHORIZED IMPLEMENTING BLOCKED SUSPENDED REJECTED CANCELLED)
    (IMPLEMENTING VERIFYING BLOCKED SUSPENDED REJECTED CANCELLED)
    (VERIFYING REVIEWING IMPLEMENTING BLOCKED SUSPENDED REJECTED CANCELLED)
    (REVIEWING APPROVED IMPLEMENTING BLOCKED SUSPENDED REJECTED CANCELLED)
    (APPROVED BASELINED BLOCKED SUSPENDED CANCELLED)
    (BASELINED SUPERSEDED)
    (BLOCKED PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING
             REVIEWING APPROVED REJECTED CANCELLED)
    (SUSPENDED PROPOSED CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING
               REVIEWING APPROVED REJECTED CANCELLED)
    (REJECTED)
    (CANCELLED)
    (SUPERSEDED))
  "Per ogni stato, gli stati a cui può passare.  Ogni altra coppia è rifiutata.
Il passaggio da BLOCKED o SUSPENDED è poi limitato allo stato di partenza.")

(defconst gdev-process--human-states
  '(AUTHORIZED APPROVED BASELINED REJECTED CANCELLED SUSPENDED SUPERSEDED)
  "Stati che solo una persona può impostare.")

(defconst gdev-process--separated-profiles '(secure high-assurance critical)
  "Profili in cui chi apre la transazione non la autorizza né la approva.")

(defconst gdev-process--separated-states '(AUTHORIZED APPROVED BASELINED)
  "Stati che chi ha aperto la transazione non può impostare nei profili separati.")

(defconst gdev-process-terminal-states '(REJECTED CANCELLED SUPERSEDED)
  "Stati da cui non si esce.")

(defun gdev-process-allowed-p (from to)
  "Restituisci non nil se la tabella ammette il passaggio da FROM a TO."
  (and (memq to (cdr (assq from gdev-process-transitions))) t))

;;;; Controllo dei valori

(defun gdev-process-refuse (format-string &rest arguments)
  "Rifiuta con il motivo FORMAT-STRING e ARGUMENTS."
  (signal 'gdev-process-refused (list (apply #'format format-string arguments))))

(defun gdev-process-check-line (name value maximum)
  "Controlla che VALUE sia una riga di testo non vuota, lunga al più MAXIMUM."
  (unless (and (stringp value) (<= 1 (length value) maximum)
               (not (string-match-p "[[:cntrl:]]" value)))
    (gdev-process-refuse "%s deve essere una riga di testo da 1 a %d caratteri" name maximum)))

(defun gdev-process--check-note (note)
  "Controlla che NOTE sia assente oppure un testo breve senza caratteri di
controllo."
  (when note
    (unless (and (stringp note) (<= (length note) 1000)
                 (not (string-match-p "[\0-\10\13-\37\177]" note)))
      (gdev-process-refuse "La nota deve essere un testo di al più 1000 caratteri"))))

(defun gdev-process-check-actor (actor actor-kind)
  "Controlla ACTOR e ACTOR-KIND: il nucleo non ne presume nessuno."
  (gdev-process-check-line "L'attore" actor 200)
  (unless (memq actor-kind gdev-process-actor-kinds)
    (gdev-process-refuse "Il tipo d'attore deve essere uno fra %s"
                          (mapconcat #'symbol-name gdev-process-actor-kinds ", "))))

;;;; Catena degli eventi

(defconst gdev-process-genesis-hash (make-string 64 ?0)
  "Impronta che precede il primo evento dell'archivio.")

(defun gdev-process--field (value)
  "Restituisci VALUE come testo per l'impronta: nil è vuoto, un simbolo il suo
nome."
  (cond ((null value) "") ((symbolp value) (symbol-name value)) (t value)))

(defun gdev-process-event-hash (previous tx-id kind from to actor actor-kind ref note at)
  "Restituisci l'impronta di un evento a partire dai suoi campi e da PREVIOUS.
Ogni campo precede il proprio testo con la lunghezza, così due eventi
diversi non danno mai la stessa sequenza."
  (secure-hash
   'sha256
   (encode-coding-string
    (mapconcat (lambda (field)
                 (let ((text (gdev-process--field field)))
                   (format "%d:%s" (length text) text)))
               (list previous tx-id kind from to actor actor-kind ref note at) "")
    'utf-8)))

(cl-defun gdev-process-append-event (db tx-id kind from to actor actor-kind &key ref note at)
  "Aggiungi alla catena un evento di TX-ID e restituisci la sua impronta.
Va chiamata dentro `gdev-assurance-db-transaction': senza, l'impronta del
precedente potrebbe cambiare fra la lettura e la scrittura."
  (unless (gdev-assurance-db-in-transaction-p db)
    (error "Un evento si aggiunge solo dentro una transazione dell'archivio"))
  (let* ((previous (or (caar (sqlite-select db "select hash from tx_event order by seq desc limit 1"))
                       gdev-process-genesis-hash))
         (at (or at (gdev-assurance-db-now)))
         (hash (gdev-process-event-hash previous tx-id kind from to actor actor-kind ref note at)))
    (sqlite-execute
     db "insert into tx_event
 (tx_id, kind, from_state, to_state, actor, actor_kind, ref, note, at, prev_hash, hash)
 values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
     (list tx-id (symbol-name kind) (and from (symbol-name from)) (symbol-name to)
           actor (symbol-name actor-kind) ref note at previous hash))
    hash))

;;;; Letture

(defun gdev-process-symbolize (row keys)
  "Restituisci ROW con i valori di KEYS trasformati in simboli."
  (dolist (key keys row)
    (let ((cell (assq key row)))
      (when (and cell (stringp (cdr cell)))
        (setcdr cell (intern (cdr cell)))))))

(defun gdev-process-event-row-problems (row event time-field)
  "Confronta ROW con il suo EVENT della catena; restituisci le incongruenze.
ROW contiene ref, tx_id, actor e actor_kind come nelle letture del nucleo.
TIME-FIELD indica la colonna di ROW da confrontare con la data dell'evento."
  (let ((event (gdev-process-symbolize event '(actor_kind)))
        (ref (alist-get 'ref row))
        problems)
    (dolist (field `((tx_id tx_id "la transazione non è quella dell'evento")
                     (actor actor "l'attore non è quello dell'evento")
                     (actor_kind actor_kind "il tipo d'attore non è quello dell'evento")
                     (,time-field at "la data non è quella dell'evento")))
      (unless (equal (alist-get (nth 0 field) row) (alist-get (nth 1 field) event))
        (push (format "%s: %s" ref (nth 2 field)) problems)))
    (nreverse problems)))

(defun gdev-process-get (db id)
  "Restituisci la transazione ID di DB come alist, o nil se non esiste."
  (when-let* ((row (car (gdev-assurance-db-select db "select * from tx where id = ?" (list id)))))
    (gdev-process-symbolize row '(state profile))))

(defun gdev-process-list (db &optional state)
  "Restituisci le transazioni di DB, nell'ordine di apertura.
Con STATO, solo quelle in quello stato."
  (mapcar (lambda (row) (gdev-process-symbolize row '(state profile)))
          (if state
              (gdev-assurance-db-select db "select * from tx where state = ? order by n"
                                        (list (symbol-name state)))
            (gdev-assurance-db-select db "select * from tx order by n"))))

(defun gdev-process-events (db id)
  "Restituisci gli eventi della transazione ID, dal primo all'ultimo."
  (mapcar (lambda (row) (gdev-process-symbolize row '(kind from_state to_state actor_kind)))
          (gdev-assurance-db-select db "select * from tx_event where tx_id = ? order by seq"
                                    (list id))))

(defun gdev-process-require (db id)
  "Restituisci la transazione ID o rifiuta se non esiste."
  (or (and (stringp id) (gdev-process-get db id))
      (gdev-process-refuse "La transazione %s non esiste" id)))

(defun gdev-process--opener (db id)
  "Restituisci l'attore che ha aperto la transazione ID."
  (caar (sqlite-select db "select actor from tx_event where tx_id = ? and kind = 'open'"
                       (list id))))

(defun gdev-process--resume-state (db id)
  "Restituisci lo stato da cui la transazione ID è stata bloccata o sospesa."
  (when-let* ((name (caar (sqlite-select
                           db "select from_state from tx_event
 where tx_id = ? and kind = 'transition' and to_state in ('BLOCKED', 'SUSPENDED')
 order by seq desc limit 1" (list id)))))
    (intern name)))

;;;; Regole

(defvar gdev-process-origin nil
  "Tipo d'attore che il canale della chiamata corrente impone, o nil.
Nil è il codice Lisp locale e fidato: il nucleo si fida del tipo dichiarato.
Un canale lo lega a `human', `agent', `ci' o `system' mentre agisce per
conto di quell'attore; il nucleo rifiuta e registra chi ne dichiara un altro.")

(defun gdev-process--rule-origin (context)
  "Regola `origin-binds-actor-kind': il tipo d'attore è quello del canale."
  (let ((kind (plist-get context :actor-kind)))
    (when (and gdev-process-origin (not (eq kind gdev-process-origin)))
      (format "Il canale impone attori di tipo %s: %s non è ammesso" gdev-process-origin kind))))

(defun gdev-process--rule-table (context)
  "Regola `transition-table': il passaggio sta nella tabella degli stati."
  (let ((from (alist-get 'state (plist-get context :tx)))
        (to (plist-get context :target)))
    (unless (gdev-process-allowed-p from to)
      (format "Da %s non si passa a %s" from to))))

(defun gdev-process--rule-supersede-only (context)
  "Regola `supersede-only': SUPERSEDED si raggiunge solo sostituendo."
  (when (eq (plist-get context :target) 'SUPERSEDED)
    "BASELINED passa a SUPERSEDED solo con `gdev-process-supersede'"))

(defun gdev-process--rule-resume (context)
  "Regola `resume-from-origin': da BLOCKED o SUSPENDED si torna da dove si era."
  (let* ((tx (plist-get context :tx))
         (from (alist-get 'state tx))
         (to (plist-get context :target)))
    (when (and (memq from '(BLOCKED SUSPENDED)) (memq to gdev-process--active-states))
      (let ((resume (gdev-process--resume-state (plist-get context :db) (alist-get 'id tx))))
        (unless (eq to resume)
          (format "Da %s si riprende solo da %s" from resume))))))

(defun gdev-process--rule-human (context)
  "Regola `human-only': i passaggi riservati sono di una persona."
  (let ((to (plist-get context :target)) (kind (plist-get context :actor-kind)))
    (when (and (memq to gdev-process--human-states) (not (eq kind 'human)))
      (format "%s richiede una persona, non un attore di tipo %s" to kind))))

(defun gdev-process--rule-suspended (context)
  "Regola `suspended-resume-human': solo una persona riprende un lavoro sospeso."
  (when (and (eq (alist-get 'state (plist-get context :tx)) 'SUSPENDED)
             (not (eq (plist-get context :actor-kind) 'human)))
    "Solo una persona riprende un lavoro sospeso"))

(defun gdev-process--rule-blocked (context)
  "Regola `blocked-no-agent': un agente non rimuove un blocco."
  (when (and (eq (alist-get 'state (plist-get context :tx)) 'BLOCKED)
             (eq (plist-get context :actor-kind) 'agent))
    "Un agente non rimuove un blocco"))

(defun gdev-process--rule-separation (context)
  "Regola `separation-of-duties': chi propone non autorizza né approva."
  (let ((tx (plist-get context :tx)) (to (plist-get context :target)))
    (when (and (memq to gdev-process--separated-states)
               (memq (alist-get 'profile tx) gdev-process--separated-profiles)
               (equal (plist-get context :actor)
                      (gdev-process--opener (plist-get context :db) (alist-get 'id tx))))
      (format "Con il profilo %s chi ha aperto %s non può portarla a %s"
              (alist-get 'profile tx) (alist-get 'id tx) to))))

(defun gdev-process--rule-supersede-human (context)
  "Regola `supersede-human': solo una persona sostituisce una linea di base."
  (unless (eq (plist-get context :actor-kind) 'human)
    "Solo una persona sostituisce una linea di base"))

(defun gdev-process--rule-supersede-old (context)
  "Regola `supersede-old-baselined': ciò che si sostituisce è una linea di base."
  (let ((old (plist-get context :tx)))
    (unless (eq (alist-get 'state old) 'BASELINED)
      (format "%s non è in BASELINED" (alist-get 'id old)))))

(defun gdev-process--rule-supersede-new (context)
  "Regola `supersede-new-baselined': ciò che sostituisce è una linea di base."
  (let ((new (plist-get context :new)))
    (unless (eq (alist-get 'state new) 'BASELINED)
      (format "%s non è in BASELINED" (alist-get 'id new)))))

(defun gdev-process--rule-supersede-order (context)
  "Regola `supersede-order': chi sostituisce è successivo."
  (let ((old (plist-get context :tx)) (new (plist-get context :new)))
    (when (<= (alist-get 'n new) (alist-get 'n old))
      (format "%s deve essere successiva a %s" (alist-get 'id new) (alist-get 'id old)))))

(dolist (domain '(open transition supersede evidence decision assessment))
  (gdev-policy-register domain 'origin-binds-actor-kind #'gdev-process--rule-origin
                        "Il tipo d'attore è quello che il canale impone."))
(dolist (rule `((transition-table ,#'gdev-process--rule-table "Il passaggio sta nella tabella.")
                (supersede-only ,#'gdev-process--rule-supersede-only
                                "SUPERSEDED si raggiunge solo sostituendo.")
                (resume-from-origin ,#'gdev-process--rule-resume
                                    "Si riprende dallo stato di partenza.")
                (human-only ,#'gdev-process--rule-human "I passaggi riservati sono di una persona.")
                (suspended-resume-human ,#'gdev-process--rule-suspended
                                        "Solo una persona riprende un lavoro sospeso.")
                (blocked-no-agent ,#'gdev-process--rule-blocked "Un agente non rimuove un blocco.")
                (separation-of-duties ,#'gdev-process--rule-separation
                                      "Chi propone non autorizza né approva.")
                (gate ,#'gdev-gates-rule "Le prove richieste dal controllo di passaggio.")))
  (apply #'gdev-policy-register 'transition rule))
(dolist (rule `((supersede-human ,#'gdev-process--rule-supersede-human
                                 "Solo una persona sostituisce una linea di base.")
                (supersede-old-baselined ,#'gdev-process--rule-supersede-old
                                         "Si sostituisce una linea di base.")
                (supersede-new-baselined ,#'gdev-process--rule-supersede-new
                                         "Si sostituisce con una linea di base.")
                (supersede-order ,#'gdev-process--rule-supersede-order
                                 "Chi sostituisce è successivo.")))
  (apply #'gdev-policy-register 'supersede rule))

;;;; Scritture

(defun gdev-process-attempt (db domain tx-id target actor actor-kind context action)
  "Applica le regole di DOMAIN a un'azione su TX-ID e, se ammessa, esegue
ACTION.  TARGET è lo stato a cui l'azione punta; nil per le azioni che non
cambiano stato (una prova).  CONTEXT è un plist con i dati in più per le
regole, o una funzione (DB TX) che lo restituisce.  ACTION riceve la
transazione ed esegue nella stessa transazione SQL: il suo valore è il
risultato.

Se le regole negano, la transazione non cambia, il rifiuto entra nella
catena come evento `refusal' (stato di partenza, stato richiesto, regola e
motivo) e si segnala `gdev-process-refused'.  Chiamata dentro una
transazione dell'archivio già aperta, il rifiuto vi partecipa e resta solo
se chi chiama gestisce l'errore e la conferma."
  (let ((outcome
         (gdev-assurance-db-transaction
          db
          (lambda ()
            (let* ((tx (gdev-process-require db tx-id))
                   (target (or target (alist-get 'state tx)))
                   (decision (gdev-policy-decide
                              domain
                              (append (list :db db :tx tx :target target
                                            :actor actor :actor-kind actor-kind)
                                      (if (functionp context) (funcall context db tx) context)))))
              (if (plist-get decision :allowed)
                  (list :done (funcall action tx))
                (list :refused tx target decision)))))))
    (pcase outcome
      (`(:done ,value) value)
      (`(:refused ,tx ,target ,decision)
       (gdev-assurance-db-transaction
        db (lambda ()
             (gdev-process-append-event db tx-id 'refusal (alist-get 'state tx) target
                                        actor actor-kind
                                        :ref (symbol-name (plist-get decision :rule))
                                        :note (plist-get decision :reason))))
       (gdev-process-refuse "%s: %s" tx-id (plist-get decision :reason))))))

(defun gdev-process--move (db tx to actor actor-kind note ref)
  "Registra il passaggio di TX a TO e aggiorna il suo stato."
  (let ((id (alist-get 'id tx)))
    (gdev-process-append-event db id 'transition (alist-get 'state tx) to actor actor-kind
                               :ref ref :note note)
    (sqlite-execute db "update tx set state = ? where id = ?" (list (symbol-name to) id))
    to))

(cl-defun gdev-process-open (db &key title profile actor actor-kind note)
  "Apri in DB una transazione in PROPOSED e restituisci il suo identificativo.
TITLE è una riga di testo, PROFILE uno di `gdev-process-profiles'.  ACTOR e
ACTOR-KIND dicono chi la propone; anche un agente può proporre.  Un rifiuto non
lascia traccia nell'archivio: non esiste ancora una transazione a cui riferirlo."
  (gdev-process-check-line "Il titolo" title 200)
  (unless (memq profile gdev-process-profiles)
    (gdev-process-refuse "Il profilo deve essere uno fra %s"
                         (mapconcat #'symbol-name gdev-process-profiles ", ")))
  (gdev-process-check-actor actor actor-kind)
  (gdev-process--check-note note)
  (let ((decision (gdev-policy-decide 'open (list :actor actor :actor-kind actor-kind
                                                  :profile profile))))
    (unless (plist-get decision :allowed)
      (gdev-process-refuse "%s" (plist-get decision :reason))))
  (gdev-assurance-db-transaction
   db
   (lambda ()
     (let* ((n (1+ (or (caar (sqlite-select db "select max(n) from tx")) 0)))
            (id (format "GT-%04d" n))
            (at (gdev-assurance-db-now)))
       (sqlite-execute db "insert into tx (id, n, title, state, profile, opened_at)
 values (?, ?, ?, 'PROPOSED', ?, ?)"
                       (list id n title (symbol-name profile) at))
       (gdev-process-append-event db id 'open nil 'PROPOSED actor actor-kind :note note :at at)
       id))))

(cl-defun gdev-process-advance (db id to &key actor actor-kind note)
  "Porta la transazione ID di DB allo stato TO e restituisci TO.
Se una regola lo vieta registra il rifiuto e segnala `gdev-process-refused'."
  (gdev-process-check-actor actor actor-kind)
  (gdev-process--check-note note)
  (unless (memq to gdev-process-states)
    (gdev-process-refuse "%S non è uno stato" to))
  (gdev-process-attempt
   db 'transition id to actor actor-kind nil
   (lambda (tx) (gdev-process--move db tx to actor actor-kind note nil))))

(cl-defun gdev-process-supersede (db old-id new-id &key actor actor-kind note)
  "Segna OLD-ID come SUPERSEDED da NEW-ID.
Entrambe devono essere in BASELINED e NEW-ID deve essere successiva.  Solo
una persona sostituisce una linea di base."
  (gdev-process-check-actor actor actor-kind)
  (gdev-process--check-note note)
  (gdev-process-attempt
   db 'supersede old-id 'SUPERSEDED actor actor-kind
   (lambda (db _tx) (list :new (gdev-process-require db new-id)))
   (lambda (old) (gdev-process--move db old 'SUPERSEDED actor actor-kind note new-id))))

;;;; Verifica

(defun gdev-process-verify (db)
  "Restituisci i problemi della catena degli eventi e delle transazioni di DB.
Rifà ogni impronta, controlla la concatenazione, la continuità degli stati di
ogni transazione e la coerenza fra lo stato e l'ultimo evento.  Ritorna nil
se tutto torna.  Una catena riscritta per intero e con impronte ricalcolate
non si distingue da una originale senza un'àncora esterna."
  (let ((expected gdev-process-genesis-hash)
        (last-state (make-hash-table :test #'equal))
        problems)
    (dolist (event (gdev-assurance-db-select db "select * from tx_event order by seq"))
      (let-alist event
        (let ((tx .tx_id) (from (and .from_state (intern .from_state))) (to (intern .to_state)))
          (unless (equal .prev_hash expected)
            (push (format "Evento %d: la catena non torna (prev_hash)" .seq) problems))
          (unless (equal .hash (gdev-process-event-hash
                                .prev_hash tx .kind .from_state .to_state .actor .actor_kind
                                .ref .note .at))
            (push (format "Evento %d: l'impronta non corrisponde ai campi" .seq) problems))
          (setq expected .hash)
          (let ((state (gethash tx last-state)))
            (pcase .kind
              ("open"
               (when state (push (format "Evento %d: %s è aperta due volte" .seq tx) problems))
               (unless (and (null from) (eq to 'PROPOSED))
                 (push (format "Evento %d: l'apertura deve portare a PROPOSED" .seq) problems)))
              ("transition"
               (cond ((null state)
                      (push (format "Evento %d: %s non ha un'apertura" .seq tx) problems))
                     ((not (eq from state))
                      (push (format "Evento %d: parte da %s ma lo stato era %s" .seq from state) problems))
                     ((not (gdev-process-allowed-p from to))
                      (push (format "Evento %d: il passaggio %s → %s non è ammesso" .seq from to) problems))
                     ((and (memq to gdev-process--human-states) (not (equal .actor_kind "human")))
                      (push (format "Evento %d: %s richiede una persona" .seq to) problems))))
              ((or "evidence" "decision" "assessment")
               (unless (and state (eq from state) (eq to state))
                 (push (format "Evento %d: una prova, una decisione o una valutazione non cambia stato"
                               .seq)
                       problems)))
              ("record"
               (unless (and state (eq from state) (eq to state))
                 (push (format "Evento %d: una registrazione non cambia stato" .seq) problems)))
              ("refusal"
               (unless (and state (eq from state) .ref)
                 (push (format "Evento %d: un rifiuto parte dallo stato corrente e indica la regola"
                               .seq)
                       problems)))
              (_ (push (format "Evento %d: tipo %s sconosciuto" .seq .kind) problems)))
            (unless (equal .kind "refusal")
              (puthash tx to last-state))))))
    (dolist (tx (gdev-process-list db))
      (let ((id (alist-get 'id tx)) (state (alist-get 'state tx)))
        (cond ((null (gethash id last-state))
               (push (format "%s non ha eventi" id) problems))
              ((not (eq state (gethash id last-state)))
               (push (format "%s è in %s ma l'ultimo evento porta a %s"
                             id state (gethash id last-state))
                     problems)))))
    (nreverse problems)))

(provide 'gdev-process)
;;; gdev-process.el ends here
