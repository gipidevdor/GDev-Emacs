;;; gdev-assessment.el --- Valutazione dei controlli di una transazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Valuta una transazione rispetto ai controlli del suo profilo, leggendo solo
;; l'archivio di assicurazione.  La valutazione non scrive nulla e non dichiara
;; nulla che l'archivio non mostri: senza prove, un controllo dovuto non è
;; soddisfatto.
;;
;; Esiti di un controllo:
;;
;;   SATISFIED      l'archivio mostra tutto ciò che il controllo richiede;
;;   NOT_SATISFIED  il controllo è dovuto e manca ciò che richiede;
;;   NOT_VERIFIED   non si può ancora dire: lo stato in cui diventa dovuto non
;;                  è stato raggiunto, oppure le prove sono solo ricostruite;
;;   NOT_APPLICABLE la transazione è stata rifiutata o annullata, oppure una persona
;;                  ha dichiarato il controllo non applicabile (`gdev-decisions');
;;   WAIVED_WITH_AUTHORIZATION  una persona ha derogato a un controllo che non
;;                  sarebbe soddisfatto (`gdev-decisions').  È l'unico modo di
;;                  ottenere questo esito: nessun parametro lo permette.  Una
;;                  deroga a un controllo già soddisfatto non cambia l'esito.
;;
;; La valutazione riguarda i controlli di GDev, non la conformità a uno
;; standard: i riferimenti alle clausole sono informativi.
;;
;; È riproducibile: gli stessi dati, cioè la stessa catena di eventi e gli stessi
;; controlli, danno lo stesso risultato.  Il risultato riporta l'impronta della
;; catena, quella dei controlli e l'impronta dei due insieme.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-assurance)
(require 'gdev-controls)
(require 'gdev-decisions)
(require 'gdev-assessment-store)
(require 'gdev-standard-assessment)
(require 'gdev-project-store)

(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defconst gdev-assessment-statuses
  '(SATISFIED NOT_SATISFIED NOT_VERIFIED NOT_APPLICABLE WAIVED_WITH_AUTHORIZATION)
  "Esiti possibili di un controllo.")

(defconst gdev-assessment--note
  "Valutazione dei controlli di GDev: non attesta la conformità a nessuno standard."
  "Avvertenza che accompagna ogni valutazione.")

(defvar gdev-assessment--context nil
  "Dati condivisi solo durante una lettura dell'archivio.")

(defun gdev-assessment-context (db)
  "Raccogli controlli, integrità e testa della catena dell'istantanea DB."
  (list :db db :controls (gdev-controls-load) :problems (gdev-assurance-verify db)
        :project (gdev-project-assessment-context db)
        :head (or (caar (sqlite-select db "select hash from tx_event order by seq desc limit 1"))
                  gdev-process-genesis-hash)))

(defun gdev-assessment--result (status reason &optional events evidence)
  "Costruisci l'esito STATUS con il motivo REASON, gli EVENTS e le prove
EVIDENCE citati."
  (list :status status :reason reason :events events :evidence evidence))

(defun gdev-assessment--reached-p (events state)
  "Restituisci non nil se EVENTS entrano in STATE con un'apertura o un passaggio."
  (cl-some (lambda (event)
             (and (memq (alist-get 'kind event) '(open transition))
                  (eq (alist-get 'to_state event) state)))
           events))

(defun gdev-assessment--transition (events requirement)
  "Valuta il requisito di passaggio REQUIREMENT su EVENTS."
  (let* ((state (plist-get requirement :a))
         (kind (plist-get requirement :attore))
         (passes (cl-remove-if-not (lambda (event)
                                     (and (eq (alist-get 'kind event) 'transition)
                                          (eq (alist-get 'to_state event) state)))
                                   events))
         (matching (cl-find kind passes :key (lambda (event) (alist-get 'actor_kind event)))))
    (cond (matching
           (gdev-assessment--result
            'SATISFIED (format "Passaggio a %s compiuto da un attore di tipo %s (evento %d)"
                               state kind (alist-get 'seq matching))
            (list (alist-get 'seq matching))))
          (passes
           (gdev-assessment--result
            'NOT_SATISFIED
            (format "Il passaggio a %s è di un attore di tipo %s, non %s"
                    state (alist-get 'actor_kind (car passes)) kind)
            (list (alist-get 'seq (car passes)))))
          (t (gdev-assessment--result 'NOT_SATISFIED
                                      (format "Nessun passaggio a %s registrato" state))))))

(defun gdev-assessment--actor-into (events state)
  "Restituisci l'attore dell'ultimo passaggio di EVENTS a STATE, o nil."
  (when-let* ((pass (car (last (cl-remove-if-not
                                (lambda (event) (and (eq (alist-get 'kind event) 'transition)
                                                     (eq (alist-get 'to_state event) state)))
                                events)))))
    (alist-get 'actor pass)))

(defun gdev-assessment--evidence (events evidence requirement)
  "Valuta il requisito di prova REQUIREMENT su EVENTS e sulle prove EVIDENCE.
Oltre a genere, origine e minimo, la prova può chiedere un tipo d'attore
(:attore) e che chi la registra non sia chi ha portato la transazione in uno
stato (:indipendente-da-chi-porta-a)."
  (let* ((state (plist-get requirement :in))
         (kind (plist-get requirement :genere))
         (origin (plist-get requirement :origine))
         (minimum (plist-get requirement :minimo))
         (actor-kind (plist-get requirement :attore))
         (independent-of (plist-get requirement :indipendente-da-chi-porta-a))
         (mover (and independent-of (gdev-assessment--actor-into events independent-of)))
         (entry (car (last (seq-filter (lambda (event)
                                        (and (eq (alist-get 'kind event) 'transition)
                                             (eq (alist-get 'to_state event) state))) events))))
         (after (or (alist-get 'seq entry) 0))
         (refs (mapcar (lambda (event) (alist-get 'ref event))
                       (cl-remove-if-not (lambda (event)
                                           (and (eq (alist-get 'kind event) 'evidence)
                                                (> (alist-get 'seq event) after)
                                                (eq (alist-get 'from_state event) state)))
                                         events)))
         (rows (cl-remove-if-not (lambda (row) (member (alist-get 'ref row) refs)) evidence))
         (same-kind (cl-remove-if-not (lambda (row) (eq (alist-get 'kind row) kind)) rows))
         (eligible (cl-remove-if-not (lambda (row) (eq (alist-get 'origin row) origin)) same-kind))
         (good (cl-remove-if-not
                (lambda (row)
                  (and (or (null actor-kind) (eq (alist-get 'actor_kind row) actor-kind))
                       (or (null independent-of) (and mover (not (equal (alist-get 'actor row) mover))))))
                eligible))
         (refs-of (lambda (list) (mapcar (lambda (row) (alist-get 'ref row)) list))))
    (cond ((>= (length good) minimum)
           (gdev-assessment--result
            'SATISFIED (format "%s %s (%s) registrate in %s"
                               (if (= (length good) 1) "1 prova" (format "%d prove" (length good)))
                               kind origin state)
            nil (funcall refs-of good)))
          ((and eligible (null good))
           (gdev-assessment--result
            'NOT_SATISFIED
            (format "In %s ci sono prove %s (%s), ma nessuna %s"
                    state kind origin
                    (string-join (delq nil (list (and actor-kind
                                                      (format "di un attore di tipo %s" actor-kind))
                                                 (and independent-of
                                                      (format "indipendente da chi ha portato la transazione a %s"
                                                              independent-of))))
                                 " e "))
            nil (funcall refs-of eligible)))
          (good
           (gdev-assessment--result
            'NOT_VERIFIED
            (format "In %s ci sono %d prove %s (%s) valide: ne servono %d"
                    state (length good) kind origin minimum)
            nil (funcall refs-of good)))
          (same-kind
           (gdev-assessment--result
            'NOT_VERIFIED
            (format "In %s ci sono prove %s, ma non %s: ne servono %d e ne risultano %d"
                    state kind origin minimum (length good))
            nil (funcall refs-of same-kind)))
          (t (gdev-assessment--result
              'NOT_SATISFIED
              (format "Nessuna prova %s (%s) registrata in %s" kind origin state))))))

(defun gdev-assessment--recorded-before (events requirement)
  "Valuta che una valutazione registrata preceda il passaggio di REQUIREMENT,
su EVENTS."
  (let* ((state (plist-get requirement :prima-di))
         (pass (cl-find-if (lambda (event) (and (eq (alist-get 'kind event) 'transition)
                                                (eq (alist-get 'to_state event) state)))
                           events))
         (before (and pass (cl-remove-if-not
                            (lambda (event) (and (eq (alist-get 'kind event) 'assessment)
                                                 (< (alist-get 'seq event) (alist-get 'seq pass))))
                            events))))
    (cond ((null pass)
           (gdev-assessment--result 'NOT_SATISFIED (format "Nessun passaggio a %s registrato" state)))
          ((null before)
           (gdev-assessment--result
            'NOT_SATISFIED (format "Nessuna valutazione registrata prima del passaggio a %s" state)
            (list (alist-get 'seq pass))))
          (t (gdev-assessment--result
              'SATISFIED (format "Valutazione %s registrata prima del passaggio a %s"
                                 (alist-get 'ref (car (last before))) state)
              (list (alist-get 'seq (car (last before))) (alist-get 'seq pass)))))))

(defun gdev-assessment--distinct-actors (events requirement)
  "Valuta che le persone che portano ai due stati di REQUIREMENT, su EVENTS,
siano diverse."
  (let* ((states (plist-get requirement :stati))
         (actors (mapcar (lambda (state) (gdev-assessment--actor-into events state)) states)))
    (cond ((memq nil actors)
           (gdev-assessment--result
            'NOT_SATISFIED (format "Nessun passaggio a %s registrato"
                                   (nth (cl-position nil actors) states))))
          ((equal (car actors) (cadr actors))
           (gdev-assessment--result
            'NOT_SATISFIED (format "%s ha portato la transazione a %s e a %s"
                                   (car actors) (car states) (cadr states))))
          (t (gdev-assessment--result
              'SATISFIED (format "%s e %s sono stati portati da attori diversi (%s e %s)"
                                 (car states) (cadr states) (car actors) (cadr actors)))))))

(defun gdev-assessment--no-decision (decisions requirement)
  "Valuta che DECISIONS non contenga decisioni del genere di REQUIREMENT."
  (let* ((kind (plist-get requirement :genere))
         (found (cl-remove-if-not (lambda (decision) (eq (alist-get 'kind decision) kind))
                                  decisions)))
    (if found
        (gdev-assessment--result
         'NOT_SATISFIED (format "Esistono %d decisioni %s (%s)" (length found) kind
                                (mapconcat (lambda (decision) (alist-get 'ref decision)) found ", "))
         nil nil)
      (gdev-assessment--result 'SATISFIED (format "Nessuna decisione %s" kind)))))

(defun gdev-assessment--separation (events requirement)
  "Valuta il requisito di separazione REQUIREMENT su EVENTS."
  (let* ((state (plist-get requirement :stato))
         (opener (cl-find 'open events :key (lambda (event) (alist-get 'kind event))))
         (pass (cl-find-if (lambda (event) (and (eq (alist-get 'kind event) 'transition)
                                                (eq (alist-get 'to_state event) state)))
                           events)))
    (cond ((null pass)
           (gdev-assessment--result 'NOT_SATISFIED (format "Nessun passaggio a %s registrato" state)))
          ((equal (alist-get 'actor pass) (alist-get 'actor opener))
           (gdev-assessment--result
            'NOT_SATISFIED (format "%s ha aperto la transazione e l'ha portata a %s"
                                   (alist-get 'actor pass) state)
            (list (alist-get 'seq pass))))
          (t (gdev-assessment--result
              'SATISFIED (format "La transazione è stata aperta da un attore e portata a %s da un altro"
                                 state)
              (list (alist-get 'seq pass)))))))

(defun gdev-assessment--integrity (problems)
  "Valuta il requisito d'integrità sui PROBLEMS dell'archivio."
  (if problems
      (gdev-assessment--result
       'NOT_SATISFIED (format "La verifica dell'archivio trova %d problemi; il primo: %s"
                              (length problems) (car problems)))
    (gdev-assessment--result 'SATISFIED "La verifica dell'archivio non trova problemi")))

(defun gdev-assessment--requirement (requirement events evidence problems decisions)
  "Valuta REQUIREMENT con EVENTS, EVIDENCE, i PROBLEMS dell'archivio e le
DECISIONS."
  (pcase (car requirement)
    (:passaggio (gdev-assessment--transition events (cdr requirement)))
    (:prova (gdev-assessment--evidence events evidence (cdr requirement)))
    (:separazione (gdev-assessment--separation events (cdr requirement)))
    (:archivio-integro (gdev-assessment--integrity problems))
    (:valutazione-registrata (gdev-assessment--recorded-before events (cdr requirement)))
    (:attori-distinti (gdev-assessment--distinct-actors events (cdr requirement)))
    (:nessuna-decisione (gdev-assessment--no-decision decisions (cdr requirement)))))

(defun gdev-assessment--evaluate (control events evidence problems decisions)
  "Valuta CONTROL su EVENTS, EVIDENCE, PROBLEMS e DECISIONS, senza applicare le
decisioni."
  (cond
   ((not (gdev-assessment--reached-p events (plist-get control :dovuto-da)))
    (gdev-assessment--result
     'NOT_VERIFIED (format "Lo stato %s, da cui il controllo è dovuto, non è stato raggiunto"
                           (plist-get control :dovuto-da))))
   (t
    (let ((results (mapcar (lambda (requirement)
                             (gdev-assessment--requirement requirement events evidence problems
                                                           decisions))
                           (plist-get control :richiede))))
      (cl-flet ((first-with (status) (cl-find status results
                                              :key (lambda (result) (plist-get result :status)))))
        (let ((chosen (or (first-with 'NOT_SATISFIED) (first-with 'NOT_VERIFIED)
                          (car results))))
          (list :status (plist-get chosen :status)
                :reason (plist-get chosen :reason)
                :events (delete-dups (apply #'append (mapcar (lambda (r) (plist-get r :events)) results)))
                :evidence (delete-dups (apply #'append
                                              (mapcar (lambda (r) (plist-get r :evidence)) results))))))))))

(defun gdev-assessment--decision-text (decision)
  "Descrivi DECISION: chi, perché e il riferimento."
  (format "%s: %s (%s)" (alist-get 'actor decision) (alist-get 'reason decision)
          (alist-get 'ref decision)))

(defun gdev-assessment--control (control state events evidence problems decisions)
  "Valuta CONTROL per una transazione in STATE, con EVENTS, EVIDENCE, PROBLEMS
e DECISIONS.  Una persona può aver dichiarato il controllo non applicabile o
aver derogato: vale la decisione più recente di ciascun genere."
  (let* ((own (cl-remove-if-not (lambda (decision)
                                  (equal (alist-get 'control_id decision) (plist-get control :id)))
                                decisions))
         (latest (lambda (kind)
                   (car (last (cl-remove-if-not (lambda (decision) (eq (alist-get 'kind decision) kind))
                                                own)))))
         (not-applicable (funcall latest 'not-applicable))
         (waiver (funcall latest 'waiver)))
    (cond
     ((memq state '(REJECTED CANCELLED))
      (gdev-assessment--result 'NOT_APPLICABLE
                               (format "La transazione è in %s: nulla da valutare" state)))
     (not-applicable
      (list :status 'NOT_APPLICABLE
            :reason (format "Dichiarato non applicabile da %s"
                            (gdev-assessment--decision-text not-applicable))
            :decisions (list (alist-get 'ref not-applicable))))
     (t
      (let ((base (gdev-assessment--evaluate control events evidence problems decisions)))
        (if (and waiver (memq (plist-get base :status) '(NOT_SATISFIED NOT_VERIFIED)))
            (list :status 'WAIVED_WITH_AUTHORIZATION
                  :reason (format "Derogato da %s. Senza la deroga: %s, %s"
                                  (gdev-assessment--decision-text waiver)
                                  (plist-get base :status) (plist-get base :reason))
                  :events (plist-get base :events) :evidence (plist-get base :evidence)
                  :decisions (list (alist-get 'ref waiver)))
          base))))))

(defun gdev-assessment--changes (previous current)
  "Confronta le righe PREVIOUS con i risultati CURRENT per identificativo.
Conserva l'ordine registrato, poi elenca le aggiunte nell'ordine corrente."
  (let ((statuses (make-hash-table :test #'equal))
        changes)
    (seq-doseq (result current)
      (puthash (alist-get 'control result) (alist-get 'status result) statuses))
    (pcase-dolist (`(,control ,before ,_) previous)
      (let ((after (gethash control statuses :null)))
        (unless (equal before after)
          (push `((control . ,control) (before . ,before) (after . ,after)) changes))
        (remhash control statuses)))
    (seq-doseq (result current)
      (let* ((control (alist-get 'control result))
             (after (gethash control statuses)))
        (when after
          (push `((control . ,control) (before . :null) (after . ,after)) changes))))
    (vconcat (nreverse changes))))

(defun gdev-assessment--recorded (db tx-id data)
  "Confronta la valutazione DATA con l'ultima registrata per TX-ID in DB.
Restituisci un alist con la valutazione registrata, gli eventi arrivati dopo e
gli esiti cambiati, oppure :null se non ce n'è nessuna."
  (if-let* ((last (car (last (gdev-assessment-store-list db tx-id)))))
      (let* ((ref (alist-get 'ref last))
             (event-seq (caar (sqlite-select db "select seq from tx_event
 where kind = 'assessment' and ref = ?" (list ref))))
             (previous (gdev-assessment-store-results db (alist-get 'id last))))
        `((ref . ,ref)
          (assessed_at . ,(alist-get 'assessed_at last))
          (result_digest . ,(alist-get 'result_digest last))
          (events_since . ,(caar (sqlite-select db "select count(*) from tx_event where seq > ?"
                                                (list event-seq))))
          (controls_changed . ,(if (equal (alist-get 'controls_digest last)
                                          (alist-get 'controls_digest data))
                                   :false t))
          (context_changed . ,(if (equal (or (alist-get 'context_digest last) :null)
                                          (or (alist-get 'context_digest data) :null)) :false t))
          (changes . ,(gdev-assessment--changes previous (alist-get 'results data)))))
    :null))

(cl-defun gdev-assessment-record (db tx-id &key actor actor-kind)
  "Valuta la transazione TX-ID di DB e registra la valutazione; restituisci il
suo riferimento.  La valutazione resta nell'archivio e nella catena di
audit.  Le regole del dominio `assessment' possono rifiutarla: il rifiuto
entra nella catena."
  (gdev-process-check-actor actor actor-kind)
  (gdev-process-attempt
   db 'assessment tx-id nil actor actor-kind nil
   (lambda (tx)
     (gdev-assessment-store-insert db tx (gdev-assessment-run db tx-id) actor actor-kind))))

(defun gdev-assessment--run (db tx-id context)
  "Valuta la transazione TX-ID di DB rispetto ai controlli del suo profilo.
Restituisci un alist pronto per `json-serialize'.  Segnala
`gdev-standards-error' se i dati dei controlli non sono validi e
`gdev-assurance-no-transaction' se la transazione non esiste.  Il campo
`recorded' confronta con l'ultima valutazione registrata."
  (let* ((data (plist-get context :controls))
         (tx (or (gdev-process-get db tx-id)
                 (signal 'gdev-assurance-no-transaction (list tx-id))))
         (profile (alist-get 'profile tx))
         (state (alist-get 'state tx))
         (entry (gdev-controls-profile data profile))
         (events (gdev-process-events db tx-id))
         (evidence (gdev-evidence-list db tx-id))
         (decisions (gdev-decision-list db tx-id))
         (problems (plist-get context :problems))
         (head (plist-get context :head))
         (results (mapcar (lambda (control)
                            (cons control (gdev-assessment--control control state events evidence problems
                                                                    decisions)))
                          (gdev-controls-for-profile data profile)))
         (standards (gdev-standard-assessment db tx-id problems))
         (project (gdev-project-assessment db tx-id (plist-get context :project)))
         (extra-results (vconcat (alist-get 'results standards) (alist-get 'results project)))
         (standard-digest (unless (eq :null (alist-get 'context_digest standards)) (alist-get 'context_digest standards)))
         (project-digest (unless (eq :null (alist-get 'context_digest project)) (alist-get 'context_digest project)))
         (context-digest (if project (gdev-evidence-sha256 (format "%s\n%s" standard-digest project-digest)) standard-digest))
         (controls-digest (if (eq :null (alist-get 'definition_digest standards)) (plist-get data :digest)
                            (gdev-evidence-sha256 (concat (plist-get data :digest) "\n" (alist-get 'definition_digest standards)))))
         (summary (mapcar (lambda (status)
                            (cons status (cl-count status results
                                                   :key (lambda (item) (plist-get (cdr item) :status)))))
                          gdev-assessment-statuses))
         (assessment
          `((transaction . ,tx-id)
            (state . ,(symbol-name state))
            (profile . ,(symbol-name profile))
            (profile_title . ,(plist-get entry :titolo))
            (provisional . ,(if (plist-get entry :provvisorio) t :false))
            (chain_head . ,head)
            (controls_digest . ,controls-digest)
            (context_digest . ,(or context-digest :null))
            (input_digest . ,(gdev-assessment-store-input-digest tx-id head controls-digest context-digest))
            (standards . ,standards)
            (project . ,(or project :null))
            (results . ,(vconcat
                         (mapcar (lambda (item)
                                   (let ((control (car item)) (result (cdr item)))
                                     `((control . ,(plist-get control :id))
                                       (title . ,(plist-get control :titolo))
                                       (decidable . ,(if (plist-get control :decidibile) t :false))
                                       (status . ,(symbol-name (plist-get result :status)))
                                       (due . ,(if (gdev-assessment--reached-p events (plist-get control :dovuto-da)) t :false))
                                       (reason . ,(plist-get result :reason))
                                       (events . ,(vconcat (plist-get result :events)))
                                       (evidence . ,(vconcat (plist-get result :evidence)))
                                       (decisions . ,(vconcat (plist-get result :decisions)))
                                       (references . ,(vconcat
                                                       (mapcar (lambda (reference)
                                                                 (format "%s %s %s" (plist-get reference :standard)
                                                                         (plist-get reference :edizione)
                                                                         (plist-get reference :clausola)))
                                                               (plist-get control :riferimenti)))))))
                                 results) extra-results))
            (summary . ,(mapcar (lambda (cell)
                                 (cons (car cell) (+ (cdr cell) (seq-count (lambda (row)
                                                                           (equal (symbol-name (car cell)) (alist-get 'status row)))
                                                                         extra-results)))) summary))
            (note . ,gdev-assessment--note))))
    (append assessment (list (cons 'recorded (gdev-assessment--recorded db tx-id assessment))))))

(defun gdev-assessment-run (db tx-id)
  "Valuta TX-ID su una sola istantanea di DB, senza scrivere."
  (gdev-standards-with-cache (lambda () (gdev-assurance-db-read-transaction
   db (lambda ()
        (gdev-assessment--run
         db tx-id (if (eq db (plist-get gdev-assessment--context :db))
                      gdev-assessment--context
                    (gdev-assessment-context db))))))))

(provide 'gdev-assessment)
;;; gdev-assessment.el ends here
