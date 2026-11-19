;;; gdev-assessment-record-test.el --- Prove delle valutazioni registrate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una valutazione si registra nell'archivio e nella catena; il confronto con
;; quella corrente mostra cosa è cambiato; le righe dei risultati non si
;; alterano senza che la verifica se ne accorga.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-assessment)

(defun gdev-test-assessment-record--record (db id &optional actor kind)
  "Registra in DB una valutazione di ID, come ACTOR di tipo KIND."
  (gdev-assessment-record db id :actor (or actor "ci") :actor-kind (or kind 'ci)))

(ert-deftest gdev-test-assessment-record-migration-4-keeps-the-chain-and-adds-assessments ()
  "Salire dalla versione 3 conserva dati e catena e apre le valutazioni registrate."
  (gdev-test-assurance--with-root root
    (let ((all gdev-assurance-db--migrations) id)
      (let ((gdev-assurance-db--migrations (seq-take all 3)))
        (gdev-assurance-db-with-open (db root 'write)
          (setq id (gdev-test-assurance--open db 'secure))
          (gdev-test-assurance--walk db id 'CLASSIFIED)
          (gdev-decision-add db id :kind 'waiver :control "GES-S02" :reason "Accettato"
                             :actor "responsabile" :actor-kind 'human)
          (should (= (gdev-assurance-db-version db) 3))
          (should-error (sqlite-execute db "select * from assessment"))))
      (gdev-assurance-db-with-open (db root 'write)
        (should (= (gdev-assurance-db-version db) (gdev-assurance-db-latest-version)))
        (should (= 3 (gdev-test-assurance--event-count db)))
        (should-not (gdev-assurance-verify db))
        (should (equal (gdev-test-assessment-record--record db id) "AS-0001"))
        (should (= 4 (gdev-test-assurance--event-count db)))
        (should-not (gdev-assurance-verify db))
        (should-error (sqlite-execute db "update tx_event set actor = 'altro'"))
        (should-error (sqlite-execute db "delete from tx_event"))))))

(ert-deftest gdev-test-assessment-record-stores-results-and-chain-event ()
  "Una valutazione registrata ha le righe dei risultati, le impronte e un evento nella catena."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (should (equal (gdev-test-assessment-record--record db id "pipeline" 'ci) "AS-0001"))
      (should (equal (gdev-test-assessment-record--record db id "ana" 'human) "AS-0002"))
      (let* ((rows (gdev-assessment-store-list db id))
             (first (car rows))
             (event (nth 2 (gdev-process-events db id)))
             (results (gdev-assessment-store-results db (alist-get 'id first))))
        (should (equal (mapcar (lambda (row) (alist-get 'ref row)) rows) '("AS-0001" "AS-0002")))
        (should (equal (alist-get 'profile first) "secure"))
        (should (equal (alist-get 'actor first) "pipeline"))
        (should (eq (alist-get 'actor_kind first) 'ci))
        (should (= (length results) 7))
        (should (equal (car (car results)) "GES-C01"))
        (should (equal (nth 1 (car results)) "NOT_VERIFIED"))
        (should (equal (alist-get 'result_digest first) (gdev-assessment-store-digest results)))
        (should (equal (alist-get 'SATISFIED (alist-get 'summary first)) 1))
        (should (= (apply #'+ (mapcar #'cdr (alist-get 'summary first))) 7))
        (should (eq (alist-get 'kind event) 'assessment))
        (should (eq (alist-get 'from_state event) 'CLASSIFIED))
        (should (eq (alist-get 'to_state event) 'CLASSIFIED))
        (should (equal (alist-get 'ref event) "AS-0001"))
        (should (equal (alist-get 'note event)
                       (format "input:%s result:%s" (alist-get 'input_digest first)
                               (alist-get 'result_digest first)))))
      (should (equal (mapcar (lambda (row) (alist-get 'ref row)) (gdev-assessment-store-list db))
                     '("AS-0001" "AS-0002")))
      (should-not (gdev-assessment-store-list db "GT-0099"))
      (should (eq (alist-get 'state (gdev-process-get db id)) 'CLASSIFIED))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-assessment-record-refuses-without-a-transaction-or-with-bad-actor ()
  "Una transazione che manca, o un attore invalido, non registrano nulla."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)) (before nil))
      (setq before (gdev-test-assurance--event-count db))
      (dolist (attempt (list (lambda () (gdev-assessment-record db "GT-0099" :actor "x" :actor-kind 'ci))
                             (lambda () (gdev-assessment-record db id :actor "" :actor-kind 'ci))
                             (lambda () (gdev-assessment-record db id :actor "x" :actor-kind 'robot))))
        (should (gdev-test-assurance--refusal attempt)))
      (should (= before (gdev-test-assurance--event-count db)))
      (should-not (gdev-assessment-store-list db))
      ;; Con controlli invalidi la valutazione non si registra e l'archivio non cambia.
      (gdev-test-controls--with-data ('((:id "X")) nil)
        (should-error (gdev-test-assessment-record--record db id) :type 'gdev-standards-error))
      (should (= before (gdev-test-assurance--event-count db)))
      (should-not (gdev-assessment-store-list db)))))

(ert-deftest gdev-test-assessment-record-origin-binds-the-actor-kind ()
  "Un canale che impone un tipo d'attore non registra valutazioni dichiarate di un altro."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (let ((gdev-process-origin 'agent))
        (should (string-match-p "Il canale impone attori di tipo agent"
                                (gdev-test-assurance--refusal
                                 (lambda () (gdev-test-assessment-record--record db id "x" 'human)))))
        (should (equal (gdev-test-assessment-record--record db id "ag" 'agent) "AS-0001")))
      (should (equal (alist-get 'ref (nth 1 (gdev-process-events db id))) "origin-binds-actor-kind"))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-assessment-record-the-database-guards-the-results ()
  "Le valutazioni registrate non si modificano né si cancellano, e hanno valori ammessi."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core)))
      (gdev-test-assessment-record--record db id)
      (dolist (query '("update assessment set profile = 'core'"
                       "delete from assessment"
                       "update assessment_result set status = 'SATISFIED'"
                       "delete from assessment_result"))
        (should-error (sqlite-execute db query)))
      (should-error (sqlite-execute db "insert into assessment_result
 (assessment_id, position, control_id, status, reason) values (1, 9, 'X', 'FORSE', 'r')"))
      (should-error (sqlite-execute db "insert into assessment_result
 (assessment_id, position, control_id, status, reason) values (1, 0, 'X', 'SATISFIED', 'r')"))
      (should-error (sqlite-execute db "insert into assessment
 (tx_id, profile, controls_digest, input_digest, chain_head, result_digest, actor, actor_kind, assessed_at)
 values (?, 'core', 'x', 'x', 'x', 'x', 'a', 'ci', 'x')" (list id)))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-assessment-record-verify-detects-tampering ()
  "Riscrivere i risultati, le impronte o gli eventi di una valutazione lascia traccia."
  (cl-flet ((problems-after (edit)
              (gdev-test-assurance--with-archive (root db)
                (let ((id (gdev-test-assurance--open db 'core)))
                  (gdev-test-assessment-record--record db id)
                  (gdev-test-assurance--drop-guards db)
                  (dolist (name '("assessment_no_update" "assessment_no_delete"
                                  "assessment_result_no_update" "assessment_result_no_delete"))
                    (sqlite-execute db (concat "drop trigger " name)))
                  (funcall edit db id)
                  (gdev-assessment-store-verify db)))))
    (dolist (case `(("i risultati non corrispondono all'impronta registrata"
                     ,(lambda (db _) (sqlite-execute db "update assessment_result set status = 'SATISFIED'
 where position = 1")))
                    ("i risultati non corrispondono all'impronta registrata"
                     ,(lambda (db _) (sqlite-execute db "update assessment_result set reason = 'riscritto'
 where position = 2")))
                    ("non ha risultati"
                     ,(lambda (db _) (sqlite-execute db "delete from assessment_result")))
                    ("le impronte non sono quelle dell'evento"
                     ,(lambda (db _) (sqlite-execute db "update assessment set input_digest = ?"
                                                     (list (make-string 64 ?a)))))
                    ("ha un evento ma nessuna valutazione"
                     ,(lambda (db _)
                        (sqlite-execute db "delete from assessment_result")
                        (sqlite-execute db "delete from assessment")))
                    ("non ha l'evento nella catena"
                     ,(lambda (db _) (sqlite-execute db "delete from tx_event where kind = 'assessment'")))
                    ("ha più di un evento"
                     ,(lambda (db id)
                        (gdev-assurance-db-transaction
                         db (lambda ()
                              (gdev-process-append-event
                               db id 'assessment 'PROPOSED 'PROPOSED "x" 'ci :ref "AS-0001"
                               :note (format "input:%s result:%s"
                                             (caar (sqlite-select db "select input_digest from assessment"))
                                             (caar (sqlite-select db "select result_digest from assessment"))))))))
                    ("la transazione non è quella dell'evento"
                     ,(lambda (db _)
                        (sqlite-execute db "insert into tx values ('GT-0050', 50, 't', 'PROPOSED', 'core', 'x')")
                        (sqlite-execute db "update assessment set tx_id = 'GT-0050'")))))
      (should (seq-some (lambda (problem) (string-match-p (regexp-quote (car case)) problem))
                        (problems-after (cadr case)))))))

(ert-deftest gdev-test-assessment-record-compares-with-the-latest-recorded ()
  "La valutazione corrente dice se, dopo l'ultima registrata, sono cambiati gli esiti."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (should (eq (alist-get 'recorded (gdev-assessment-run db id)) :null))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (gdev-test-assessment-record--record db id)
      (let ((recorded (alist-get 'recorded (gdev-assessment-run db id))))
        (should (equal (alist-get 'ref recorded) "AS-0001"))
        (should (= (alist-get 'events_since recorded) 0))
        (should (eq (alist-get 'controls_changed recorded) :false))
        (should (equal (alist-get 'changes recorded) []))
        (should (equal (alist-get 'result_digest recorded)
                       (caar (sqlite-select db "select result_digest from assessment")))))
      ;; Dopo nuovi eventi cambiano gli esiti che dipendevano da ciò che è stato registrato.
      (gdev-test-assurance--prove db id 'deduction)
      (gdev-test-assurance--step db id 'AUTHORIZED 'human "altra persona")
      (let* ((recorded (alist-get 'recorded (gdev-assessment-run db id)))
             (changes (alist-get 'changes recorded)))
        (should (= (alist-get 'events_since recorded) 2))
        (should (equal (mapcar (lambda (change) (alist-get 'control change)) changes)
                       '("GES-S01" "GES-S02")))
        (should (equal (alist-get 'before (aref changes 0)) "NOT_VERIFIED"))
        (should (equal (alist-get 'after (aref changes 0)) "SATISFIED"))
        (should (stringp (json-serialize (gdev-assessment-run db id)))))
      ;; Un controllo cambiato nei dati lo dice, e la valutazione registrata resta com'era.
      (gdev-test-controls--with-data ((let ((controls (gdev-standards-read
                                                       (expand-file-name "profili/controlli.eld"
                                                                         gdev-standards-directory))))
                                       (setf (plist-get (car controls) :titolo) "Un altro titolo")
                                       controls)
                                     nil)
        (should (eq (alist-get 'controls_changed (alist-get 'recorded (gdev-assessment-run db id))) t)))
      ;; Un controllo che non c'è più nei dati è un cambiamento verso «assente».
      (gdev-test-controls--with-data ((cdr (gdev-standards-read
                                            (expand-file-name "profili/controlli.eld"
                                                              gdev-standards-directory)))
                                     '((:id core :titolo "c" :eredita () :controlli ("GES-C02"))
                                       (:id quality :titolo "q" :eredita (core) :controlli ())
                                       (:id secure :titolo "s" :eredita (quality) :controlli ("GES-S01"))
                                       (:id high-assurance :titolo "h" :eredita (secure) :controlli ()
                                        :provvisorio t)
                                       (:id critical :titolo "k" :eredita (high-assurance) :controlli ()
                                        :provvisorio t)))
        (let ((changes (alist-get 'changes (alist-get 'recorded (gdev-assessment-run db id)))))
          (should (equal (alist-get 'after (seq-find (lambda (c) (equal (alist-get 'control c) "GES-C01"))
                                                     changes))
                         :null)))))))

(ert-deftest gdev-test-assessment-record-readings-show-and-count-assessments ()
  "`status', `show' e `assess' riportano le valutazioni registrate e i cambiamenti."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (gdev-test-assessment-record--record db id "pipeline" 'ci)
      (gdev-test-assurance--prove db id 'deduction)
      (gdev-test-assurance--step db id 'AUTHORIZED 'human "altra persona")
      (gdev-assurance-db-close db)
      (should (= (alist-get 'assessments (gdev-assurance-data "status" root)) 1))
      (let ((show (gdev-assurance-data "show" root id)))
        (should (= (alist-get 'assessments_total show) 1))
        (should (equal (alist-get 'ref (aref (alist-get 'assessments show) 0)) "AS-0001"))
        (should (stringp (json-serialize show))))
      (let ((status (gdev-test-assurance--cli root "status")))
        (should (string-match-p "decisioni, valutazioni: 6, 1, 0, 0, 1" (cdr status))))
      (let ((shown (gdev-test-assurance--cli root "show" id)))
        (should (string-match-p "Valutazioni registrate:" (cdr shown)))
        (should (string-match-p "AS-0001 +2026-01-01T[0-9:.]+Z +secure +.*1 SATISFIED.*\\(pipeline\\)"
                                (cdr shown)))
        (should (string-match-p "assessment +ANALYZED +ci:pipeline +\\[AS-0001: input:" (cdr shown))))
      (let ((assessed (gdev-test-assurance--cli root "assess" id)))
        (should (string-match-p "Ultima valutazione registrata: AS-0001 del .* 2 eventi dopo\\."
                                (cdr assessed)))
        (should (string-match-p "Cambiato: GES-S01 NOT_VERIFIED → SATISFIED" (cdr assessed)))))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db 'core)))
        (gdev-assurance-db-close db)
        (let ((assessed (gdev-test-assurance--cli root "assess" id)))
          (should (string-match-p "Nessuna valutazione registrata per questa transazione"
                                  (cdr assessed))))
        (gdev-assurance-db-with-open (db root 'write)
          (gdev-test-assessment-record--record db id))
        (let ((assessed (gdev-test-assurance--cli root "assess" id)))
          (should (string-match-p "Ultima valutazione registrata: AS-0001 del .* 0 eventi dopo\\."
                                  (cdr assessed)))
          (should (string-match-p "Gli esiti non sono cambiati" (cdr assessed))))))))

(ert-deftest gdev-test-assessment-record-compares-added-and-removed-controls ()
  "Il confronto mostra entrambi i lati di una sostituzione nel profilo."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core))
          (catalog (gdev-controls-load)))
      (gdev-test-assessment-record--record db id)
      (setf (plist-get (gdev-controls-profile catalog 'core) :controlli)
            '("GES-C01" "GES-C02" "GES-Q01")
            (plist-get (gdev-controls-profile catalog 'quality) :controlli)
            '("GES-C03"))
      (gdev-assurance-db-close db)
      (gdev-test-controls--with-data (nil (plist-get catalog :profiles))
        (let* ((data (gdev-test-assurance--live "assess" id root))
               (json (json-parse-string (json-serialize data) :object-type 'alist))
               (changes (alist-get 'changes (alist-get 'recorded json))))
          (should (equal changes
                         [((control . "GES-C03") (before . "NOT_VERIFIED") (after . :null))
                          ((control . "GES-Q01") (before . :null) (after . "NOT_VERIFIED"))])))
        (let ((output (cdr (gdev-test-assurance--cli root "assess" id))))
          (should (string-match-p "GES-C03 NOT_VERIFIED → assente" output))
          (should (string-match-p "GES-Q01 assente → NOT_VERIFIED" output)))))))

(ert-deftest gdev-test-assessment-record-controls-changed-is-reported-in-text ()
  "Se i controlli sono cambiati dopo la registrazione, l'avviso compare nel testo."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core)))
      (gdev-test-assessment-record--record db id)
      (gdev-assurance-db-close db)
      (gdev-test-controls--with-data ((let ((controls (gdev-standards-read
                                                       (expand-file-name "profili/controlli.eld"
                                                                         gdev-standards-directory))))
                                       (setf (plist-get (car controls) :titolo) "Un altro titolo")
                                       controls)
                                     nil)
        (should (string-match-p "I controlli sono cambiati dopo la registrazione"
                                (cdr (gdev-test-assurance--cli root "assess" id))))))))

(ert-deftest gdev-test-assessment-record-policy-rules-and-digest ()
  "Il dominio `assessment' ha la sola regola di origine; l'impronta dipende dall'ordine."
  (should (equal (gdev-policy-rules 'assessment) '(origin-binds-actor-kind)))
  (let ((one (gdev-assessment-store-digest '(("A" "SATISFIED" "x") ("B" "NOT_VERIFIED" "y"))))
        (two (gdev-assessment-store-digest '(("B" "NOT_VERIFIED" "y") ("A" "SATISFIED" "x")))))
    (should (= (length one) 64))
    (should-not (equal one two))
    (should (equal one (gdev-assessment-store-digest '(("A" "SATISFIED" "x") ("B" "NOT_VERIFIED" "y")))))))

(provide 'gdev-assessment-record-test)
(ert-deftest gdev-test-assessment-record-metadata-matches-the-audit-event ()
  "Autore, tipo d'attore, data e profilo della valutazione restano verificabili."
  (dolist (case '(("actor" "altra persona" "l'attore")
                  ("actor_kind" "human" "il tipo d'attore")
                  ("assessed_at" "2099-01-01T00:00:00Z" "la data")
                  ("profile" "quality" "il profilo")))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-test-assessment-record--record db id)
        (should-not (gdev-assurance-verify db))
        (gdev-test-assurance--edit-restoring-guard
         db "assessment_no_update" (format "update assessment set %s = ?" (car case)) (cadr case))
        (should-not (gdev-assurance-db-integrity db))
        (should-not (gdev-process-verify db))
        (let ((data (gdev-assurance-data "verify" root)))
          (should (eq (alist-get 'ok data) :false))
          (should (seq-some (lambda (problem) (string-search (nth 2 case) problem))
                            (alist-get 'problems data))))))))

(ert-deftest gdev-test-assessment-record-inputs-match-the-registered-digest ()
  "Le impronte dei controlli e della catena devono ricostruire quella degli ingressi."
  (dolist (field '("controls_digest" "chain_head"))
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-test-assessment-record--record db id)
        (gdev-test-assurance--edit-restoring-guard
         db "assessment_no_update" (format "update assessment set %s = ?" field) (make-string 64 ?a))
        (should-not (gdev-assurance-db-integrity db))
        (should-not (gdev-process-verify db))
        (let ((data (gdev-assurance-data "verify" root)))
          (should (eq (alist-get 'ok data) :false))
          (should (seq-some (lambda (problem) (string-search "gli ingressi" problem))
                            (alist-get 'problems data))))))))

(ert-deftest gdev-test-assessment-record-result-positions-are-contiguous ()
  "Cambiare le posizioni mantenendo lo stesso ordine non conserva una valutazione valida."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assessment-record--record db id)
      (gdev-test-assurance--edit-restoring-guard
       db "assessment_result_no_update" "update assessment_result set position = position + 10")
      (should-not (gdev-assurance-db-integrity db))
      (should-not (gdev-process-verify db))
      (let ((data (gdev-assurance-data "verify" root)))
        (should (eq (alist-get 'ok data) :false))
        (should (seq-some (lambda (problem) (string-search "le posizioni" problem))
                          (alist-get 'problems data)))))))

;;; gdev-assessment-record-test.el ends here
