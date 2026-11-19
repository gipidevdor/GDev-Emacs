;;; gdev-decision-test.el --- Prove di deroghe e decisioni di non applicabilità -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una persona decide su un controllo; la decisione entra nell'archivio e nella
;; catena, le regole la limitano e la valutazione produce gli esiti
;; WAIVED_WITH_AUTHORIZATION e NOT_APPLICABLE solo da lì.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-assessment)

(defun gdev-test-decision--add (db id control &optional kind actor actor-kind reason)
  "Registra in DB la decisione KIND su CONTROL di ID.
Predefiniti: una deroga di una persona che non ha aperto la transazione."
  (gdev-decision-add db id :kind (or kind 'waiver) :control control
                     :reason (or reason "Accettato per questa modifica")
                     :actor (or actor "responsabile") :actor-kind (or actor-kind 'human)))

(defun gdev-test-decision--status (assessment control)
  "Restituisci l'esito di CONTROL in ASSESSMENT."
  (cdr (assoc control (gdev-test-assessment--results assessment))))

(ert-deftest gdev-test-decision-migration-3-keeps-the-chain-and-adds-decisions ()
  "Salire dalla versione 2 conserva dati e catena e apre le decisioni."
  (gdev-test-assurance--with-root root
    (let ((all gdev-assurance-db--migrations) id)
      (let ((gdev-assurance-db--migrations (seq-take all 2)))
        (gdev-assurance-db-with-open (db root 'write)
          (setq id (gdev-test-assurance--open db 'secure))
          (gdev-test-assurance--walk db id 'CLASSIFIED)
          (gdev-test-assurance--prove db id)
          (should (= (gdev-assurance-db-version db) 2))
          (should-error (sqlite-execute db "select * from decision"))
          (should-error (sqlite-execute db "insert into tx_event (tx_id, kind, from_state, to_state, actor, actor_kind, at, prev_hash, hash)
 values (?, 'decision', 'CLASSIFIED', 'CLASSIFIED', 'x', 'human', 'x', ?, ?)"
                                        (list id (make-string 64 ?0) (make-string 64 ?1))))))
      (let ((gdev-assurance-db--migrations (seq-take all 3)))
        (gdev-assurance-db-with-open (db root 'write)
          (should (= (gdev-assurance-db-version db) 3))
          (should (= 3 (gdev-test-assurance--event-count db)))
          (should-not (append (gdev-process-verify db) (gdev-evidence-verify db)
                              (gdev-decision-verify db)))
          (should (equal (gdev-test-decision--add db id "GES-S02") "DC-0001"))
          (should (= 4 (gdev-test-assurance--event-count db)))
          (should-not (append (gdev-process-verify db) (gdev-evidence-verify db)
                              (gdev-decision-verify db)))
          (should-error (sqlite-execute db "update tx_event set actor = 'altro'"))
          (should-error (sqlite-execute db "delete from tx_event")))))))

(ert-deftest gdev-test-decision-records-the-decision-in-the-archive-and-the-chain ()
  "Una decisione ha una riga, un evento con il suo riferimento e l'impronta del motivo."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (should (equal (gdev-test-decision--add db id "GES-S02") "DC-0001"))
      (should (equal (gdev-test-decision--add db id "GES-S03" 'not-applicable "altra persona"
                                              'human "Nessuna revisione: modifica solo di testo")
                     "DC-0002"))
      (let ((rows (gdev-decision-list db id)))
        (should (equal (mapcar (lambda (row) (alist-get 'ref row)) rows) '("DC-0001" "DC-0002")))
        (should (eq (alist-get 'kind (car rows)) 'waiver))
        (should (eq (alist-get 'kind (cadr rows)) 'not-applicable))
        (should (equal (alist-get 'control_id (cadr rows)) "GES-S03"))
        (should (equal (alist-get 'actor (cadr rows)) "altra persona"))
        (should (eq (alist-get 'actor_kind (cadr rows)) 'human)))
      (should (equal (mapcar (lambda (row) (alist-get 'ref row)) (gdev-decision-list db))
                     '("DC-0001" "DC-0002")))
      (should-not (gdev-decision-list db "GT-0099"))
      (let ((event (nth 2 (gdev-process-events db id))))
        (should (eq (alist-get 'kind event) 'decision))
        (should (eq (alist-get 'from_state event) 'CLASSIFIED))
        (should (eq (alist-get 'to_state event) 'CLASSIFIED))
        (should (equal (alist-get 'ref event) "DC-0001"))
        (should (equal (alist-get 'note event)
                       (concat "waiver GES-S02 sha256:"
                               (gdev-evidence-sha256 "Accettato per questa modifica")))))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'CLASSIFIED))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-decision-validates-its-input-without-leaving-a-trace ()
  "Genere, controllo, motivo e attore invalidi sono rifiutati prima di arrivare all'archivio."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure))
          (before nil))
      (setq before (gdev-test-assurance--event-count db))
      (dolist (arguments `((:kind nil :control "GES-S02" :reason "r" :actor "x" :actor-kind human)
                           (:kind perdono :control "GES-S02" :reason "r" :actor "x" :actor-kind human)
                           (:kind waiver :control "" :reason "r" :actor "x" :actor-kind human)
                           (:kind waiver :control nil :reason "r" :actor "x" :actor-kind human)
                           (:kind waiver :control "GES-S02" :reason "" :actor "x" :actor-kind human)
                           (:kind waiver :control "GES-S02" :reason ,(make-string 1001 ?x)
                                  :actor "x" :actor-kind human)
                           (:kind waiver :control "GES-S02" :reason "a\nb" :actor "x" :actor-kind human)
                           (:kind waiver :control "GES-S02" :reason "r" :actor "" :actor-kind human)
                           (:kind waiver :control "GES-S02" :reason "r" :actor "x" :actor-kind robot)))
        (should (gdev-test-assurance--refusal
                 (lambda () (apply #'gdev-decision-add db id arguments)))))
      (should (gdev-test-assurance--refusal
               (lambda () (gdev-test-decision--add db "GT-0099" "GES-S02"))))
      (should (= before (gdev-test-assurance--event-count db)))
      (should-not (gdev-decision-list db)))))

(ert-deftest gdev-test-decision-rules-refuse-and-record-why ()
  "Le regole del dominio `decision' rifiutano e lasciano il rifiuto nella catena."
  (gdev-test-assurance--with-archive (root db)
    (let ((core (gdev-test-assurance--open db 'core))
          (secure (gdev-test-assurance--open db 'secure)))
      (cl-flet ((refusal (id control kind-of-actor actor)
                  (gdev-test-assurance--refusal
                   (lambda () (gdev-decision-add db id :kind 'waiver :control control :reason "perché"
                                                 :actor actor :actor-kind kind-of-actor)))))
        ;; Solo una persona.
        (dolist (kind '(agent ci system))
          (should (string-match-p "richiede una persona" (refusal secure "GES-S02" kind "altra"))))
        ;; Il controllo deve essere del profilo.
        (should (string-match-p "GES-S01 non è del profilo core" (refusal core "GES-S01" 'human "altra")))
        (should (string-match-p "GES-INESISTENTE non è del profilo"
                                (refusal secure "GES-INESISTENTE" 'human "altra")))
        ;; La catena di audit non si deroga.
        (should (string-match-p "GES-C02 non ammette decisioni" (refusal secure "GES-C02" 'human "altra")))
        ;; Dal profilo secure in su non decide chi ha aperto.
        (should (string-match-p "chi ha aperto GT-0002 non decide"
                                (refusal secure "GES-S02" 'human "proponente")))
        ;; Con il profilo core chi ha aperto può decidere.
        (should (gdev-decision-add db core :kind 'waiver :control "GES-C01" :reason "perché"
                                   :actor "proponente" :actor-kind 'human)))
      ;; Ogni rifiuto sta nella catena con la regola.
      (should (equal (mapcar (lambda (event) (alist-get 'ref event))
                             (seq-filter (lambda (event) (eq (alist-get 'kind event) 'refusal))
                                         (gdev-process-events db secure)))
                     '("decision-human-only" "decision-human-only" "decision-human-only"
                       "decision-known-control" "decision-known-control" "decision-separation")))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-decision-refuses-concluded-transactions ()
  "Una transazione conclusa non accetta decisioni: sarebbero retroattive."
  (gdev-test-assurance--with-archive (root db)
    (dolist (state '(CANCELLED REJECTED))
      (let ((id (gdev-test-assurance--open db 'secure)))
        (gdev-test-assurance--step db id state 'human)
        (should (string-match-p (format "è in %s: non accetta decisioni" state)
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-decision--add db id "GES-S02")))))))
    (let ((baselined (gdev-test-assessment--baseline db 'secure '(VERIFYING fact collected))))
      (should (string-match-p "è in BASELINED"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-test-decision--add db baselined "GES-S02"))))))))

(ert-deftest gdev-test-decision-origin-binds-the-actor-kind ()
  "Un canale che impone un tipo d'attore non registra decisioni dichiarate come umane."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (let ((gdev-process-origin 'agent))
        (should (string-match-p "Il canale impone attori di tipo agent"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-decision--add db id "GES-S02"))))))
      (should (equal (alist-get 'ref (car (last (gdev-process-events db id))))
                     "origin-binds-actor-kind"))
      (should-not (gdev-decision-list db)))))

(ert-deftest gdev-test-decision-the-database-itself-requires-a-person ()
  "Il vincolo dell'archivio rifiuta una decisione di un attore che non è una persona."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (dolist (kind '("agent" "ci" "system"))
        (should-error (sqlite-execute db "insert into decision
 (tx_id, kind, control_id, reason, actor, actor_kind, decided_at)
 values (?, 'waiver', 'GES-S02', 'r', 'x', ?, 'x')" (list id kind))))
      (should-error (sqlite-execute db "insert into decision
 (tx_id, kind, control_id, reason, actor, actor_kind, decided_at)
 values (?, 'perdono', 'GES-S02', 'r', 'x', 'human', 'x')" (list id)))
      (gdev-test-decision--add db id "GES-S02")
      (should-error (sqlite-execute db "update decision set reason = 'altro'"))
      (should-error (sqlite-execute db "delete from decision"))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-decision-verify-detects-tampering ()
  "Riscrivere una decisione o i suoi eventi lascia traccia nella verifica."
  (cl-flet ((problems-after (edit)
              (gdev-test-assurance--with-archive (root db)
                (let ((id (gdev-test-assurance--open db 'secure)))
                  (gdev-test-assurance--step db id 'CLASSIFIED)
                  (gdev-test-decision--add db id "GES-S02")
                  (gdev-test-assurance--drop-guards db)
                  (sqlite-execute db "drop trigger decision_no_update")
                  (sqlite-execute db "drop trigger decision_no_delete")
                  (funcall edit db id)
                  (gdev-decision-verify db)))))
    (dolist (case `(("la decisione non è quella dell'evento"
                     ,(lambda (db _) (sqlite-execute db "update decision set reason = 'riscritto'")))
                    ("la decisione non è quella dell'evento"
                     ,(lambda (db _) (sqlite-execute db "update decision set control_id = 'GES-S03'")))
                    ("ha un evento ma nessuna decisione"
                     ,(lambda (db _) (sqlite-execute db "delete from decision")))
                    ("non ha l'evento nella catena"
                     ,(lambda (db _) (sqlite-execute db "delete from tx_event where kind = 'decision'")))
                    ("ha più di un evento"
                     ,(lambda (db id)
                        (gdev-assurance-db-transaction
                         db (lambda ()
                              (gdev-process-append-event
                               db id 'decision 'CLASSIFIED 'CLASSIFIED "x" 'human :ref "DC-0001"
                               :note (gdev-decision--note 'waiver "GES-S02"
                                                          "Accettato per questa modifica"))))))
                    ("la transazione non è quella dell'evento"
                     ,(lambda (db _)
                        (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'PROPOSED', 'core', 'x')")
                        (sqlite-execute db "update decision set tx_id = 'GT-0050'")))))
      (should (seq-some (lambda (problem) (string-match-p (regexp-quote (car case)) problem))
                        (problems-after (cadr case)))))))

(ert-deftest gdev-test-decision-a-waiver-turns-a-missing-control-into-waived ()
  "Una deroga a un controllo non soddisfatto lo rende WAIVED_WITH_AUTHORIZATION."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assessment--baseline db 'secure '(VERIFYING fact collected))))
      (should (equal (gdev-test-decision--status (gdev-assessment-run db id) "GES-S02") "NOT_SATISFIED"))
      (should (eq (alist-get 'ok (list (cons 'ok (null (gdev-assurance-verify db))))) t)))
    (gdev-test-assurance--with-archive (root other)
      (let ((id (gdev-test-assurance--open other 'secure)))
        (gdev-test-assurance--walk other id 'CLASSIFIED 'ANALYZED 'AUTHORIZED 'IMPLEMENTING)
        (let ((before (gdev-assessment-run other id)))
          (should (equal (gdev-test-decision--status before "GES-S03") "NOT_VERIFIED")))
        (gdev-test-decision--add other id "GES-S03" 'waiver "responsabile" 'human "Revisione rinviata")
        (let* ((a (gdev-assessment-run other id))
               (result (seq-find (lambda (r) (equal (alist-get 'control r) "GES-S03"))
                                 (alist-get 'results a))))
          (should (equal (alist-get 'status result) "WAIVED_WITH_AUTHORIZATION"))
          (should (string-match-p "Derogato da responsabile: Revisione rinviata (DC-0001)"
                                  (alist-get 'reason result)))
          (should (string-match-p "Senza la deroga: NOT_VERIFIED" (alist-get 'reason result)))
          (should (equal (alist-get 'decisions result) ["DC-0001"]))
          (should (= (alist-get 'WAIVED_WITH_AUTHORIZATION (alist-get 'summary a)) 1)))))))

(ert-deftest gdev-test-decision-a-waiver-keeps-the-finding-it-waives ()
  "La deroga riporta il motivo originale; su un controllo già soddisfatto non cambia l'esito."
  (gdev-test-assurance--with-archive (root db)
    (let ((missing (gdev-test-assessment--baseline db 'secure '(VERIFYING fact collected)))
          (done (gdev-test-assessment--baseline
                 db 'secure '(ANALYZED deduction collected) '(VERIFYING fact collected)
                 '(REVIEWING fact collected))))
      (gdev-assurance-db-close db)
      (gdev-assurance-db-with-open (db root 'write)
        (should-error (gdev-test-decision--add db missing "GES-S02" 'waiver) :type 'gdev-process-refused)
        (should-not (gdev-decision-list db))))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db 'secure)))
        (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
        (gdev-test-assurance--prove db id 'deduction)
        (gdev-test-decision--add db id "GES-S02")
        (gdev-test-assurance--step db id 'AUTHORIZED 'human "altra persona")
        (let ((a (gdev-assessment-run db id)))
          ;; S02 è soddisfatto: la deroga non serve e l'esito resta SATISFIED.
          (should (equal (gdev-test-decision--status a "GES-S02") "SATISFIED"))
          (should (= (alist-get 'WAIVED_WITH_AUTHORIZATION (alist-get 'summary a)) 0)))))))

(ert-deftest gdev-test-decision-not-applicable-overrides-the-evaluation ()
  "Un controllo dichiarato non applicabile è NOT_APPLICABLE, con chi, perché e riferimento."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED 'AUTHORIZED 'IMPLEMENTING)
      (gdev-test-decision--add db id "GES-S03" 'not-applicable "responsabile" 'human
                               "Nessun codice da rivedere")
      (let* ((a (gdev-assessment-run db id))
             (result (seq-find (lambda (r) (equal (alist-get 'control r) "GES-S03"))
                               (alist-get 'results a))))
        (should (equal (alist-get 'status result) "NOT_APPLICABLE"))
        (should (string-match-p "Dichiarato non applicabile da responsabile: Nessun codice da rivedere (DC-0001)"
                                (alist-get 'reason result)))
        (should (equal (alist-get 'decisions result) ["DC-0001"]))
        (should (= (alist-get 'NOT_APPLICABLE (alist-get 'summary a)) 1)))
      ;; La decisione più recente di ciascun genere vale: una deroga successiva non la cancella.
      (gdev-test-decision--add db id "GES-S03" 'waiver "responsabile" 'human "Poi derogato")
      (should (equal (gdev-test-decision--status (gdev-assessment-run db id) "GES-S03")
                     "NOT_APPLICABLE")))))

(ert-deftest gdev-test-decision-the-latest-waiver-counts ()
  "Fra due deroghe allo stesso controllo vale l'ultima."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-decision--add db id "GES-S02" 'waiver "uno" 'human "Primo motivo")
      (gdev-test-decision--add db id "GES-S02" 'waiver "due" 'human "Secondo motivo")
      (let* ((a (gdev-assessment-run db id))
             (reason (gdev-test-assessment--reason a "GES-S02")))
        (should (equal (gdev-test-decision--status a "GES-S02") "WAIVED_WITH_AUTHORIZATION"))
        (should (string-match-p "due: Secondo motivo (DC-0002)" reason))
        (should-not (string-match-p "Primo motivo" reason))))))

(ert-deftest gdev-test-decision-changes-the-assessment-inputs ()
  "Una decisione cambia la catena, quindi l'impronta degli ingressi della valutazione."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assurance--open db 'secure))
           (before (gdev-assessment-run db id)))
      (gdev-test-decision--add db id "GES-S02")
      (let ((after (gdev-assessment-run db id)))
        (should-not (equal (alist-get 'chain_head before) (alist-get 'chain_head after)))
        (should-not (equal (alist-get 'input_digest before) (alist-get 'input_digest after)))
        (should (equal (alist-get 'controls_digest before) (alist-get 'controls_digest after)))
        (should (equal after (gdev-assessment-run db id)))))))

(ert-deftest gdev-test-decision-controls-declare-which-ones-admit-decisions ()
  "Il flag :decidibile è obbligatorio e booleano; la catena di audit non è decidibile."
  (let ((data (gdev-controls-load)))
    (dolist (control (plist-get data :controls))
      (should (plist-member control :decidibile))
      (should (eq (and (plist-get control :decidibile) t)
                  (not (member (plist-get control :id) '("GES-C02" "GES-K02")))))))
  (should (equal gdev-controls--decision-kinds gdev-decision-kinds))
  (let ((control (copy-sequence (car (plist-get (gdev-controls-load) :controls)))))
    (setf (plist-get control :decidibile) 'forse)
    (should (member "GES-C01: :decidibile deve essere t o nil"
                    (gdev-controls--control-problems control)))
    (setq control (cl-loop for (key value) on control by #'cddr
                           unless (eq key :decidibile) append (list key value)))
    (should (member "GES-C01: manca :decidibile" (gdev-controls--control-problems control)))))

(ert-deftest gdev-test-decision-readings-show-and-count-decisions ()
  "`status', `show' e i dati strutturati riportano le decisioni."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-decision--add db id "GES-S02" 'waiver "responsabile" 'human "Accettato per ora")
      (gdev-assurance-db-close db)
      (let ((data (gdev-assurance-data "status" root)))
        (should (= (alist-get 'decisions data) 1)))
      (let ((show (gdev-assurance-data "show" root id)))
        (should (= (alist-get 'decisions_total show) 1))
        (should (equal (alist-get 'ref (aref (alist-get 'decisions show) 0)) "DC-0001"))
        (should (equal (alist-get 'kind (aref (alist-get 'decisions show) 0)) "waiver"))
        (should (stringp (json-serialize show))))
      (let ((status (gdev-test-assurance--cli root "status")))
        (should (string-match-p "Eventi, prove, rifiuti, decisioni, valutazioni: 2, 0, 0, 1, 0" (cdr status))))
      (let ((shown (gdev-test-assurance--cli root "show" id)))
        (should (string-match-p "Decisioni:" (cdr shown)))
        (should (string-match-p "DC-0001 +waiver +GES-S02 +responsabile: Accettato per ora" (cdr shown)))
        (should (string-match-p "decision +PROPOSED +human:responsabile" (cdr shown)))
        (should (string-match-p "\\[DC-0001: waiver GES-S02 sha256:" (cdr shown))))
      (let ((assessed (gdev-test-assurance--cli root "assess" id)))
        (should (= (car assessed) 0))
        (should (string-match-p "GES-S02 +WAIVED_WITH_AUTHORIZATION" (cdr assessed)))
        (should (string-match-p "Derogato da responsabile: Accettato per ora" (cdr assessed)))))))

(ert-deftest gdev-test-decision-policy-registers-its-rules-in-order ()
  "Le regole del dominio `decision' sono registrate nell'ordine previsto."
  (should (equal (gdev-policy-rules 'decision)
                 '(origin-binds-actor-kind decision-human-only decision-open-transaction
                   decision-known-control decision-separation))))

(provide 'gdev-decision-test)
(ert-deftest gdev-test-decision-metadata-matches-the-audit-event ()
  "Autore e data di una decisione non si cambiano senza lasciare traccia."
  (dolist (case '(("actor" "altra persona" "l'attore")
                  ("decided_at" "2099-01-01T00:00:00Z" "la data")))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db 'secure)))
        (gdev-test-decision--add db id "GES-S02")
        (should-not (gdev-assurance-verify db))
        (gdev-test-assurance--edit-restoring-guard
         db "decision_no_update" (format "update decision set %s = ?" (car case)) (cadr case))
        (should-not (gdev-assurance-db-integrity db))
        (should-not (gdev-process-verify db))
        (let ((data (gdev-assurance-data "verify" root)))
          (should (eq (alist-get 'ok data) :false))
          (should (seq-some (lambda (problem) (string-search (nth 2 case) problem))
                            (alist-get 'problems data))))))))

;;; gdev-decision-test.el ends here
