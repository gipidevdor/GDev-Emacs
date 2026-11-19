;;; gdev-assessment-profiles-test.el --- Prove dei controlli di high-assurance e critical -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I nuovi requisiti (indipendenza, attore, valutazione registrata, attori distinti,
;; nessuna decisione) e i cinque controlli proposti per i profili più rigidi.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-assessment)

(defun gdev-test-assessment-profiles--status (assessment control)
  "Restituisci l'esito di CONTROL in ASSESSMENT."
  (cdr (assoc control (gdev-test-assessment--results assessment))))

(defun gdev-test-assessment-profiles--evidence (db id kind actor actor-kind)
  "Registra in DB una prova collected di ID, di KIND, di ACTOR con ACTOR-KIND."
  (gdev-evidence-add db id :kind kind :description "Prova" :content (format "%S" (list kind actor))
                     :actor actor :actor-kind actor-kind))

(defun gdev-test-assessment-profiles--critical (db &rest options)
  "Porta in DB una transazione critical fino a BASELINED e restituisci il suo id.
OPTIONS: :verifier (autore della prova di verifica), :reviewer-kind (tipo d'attore
della revisione), :approver e :record (non nil: registra una valutazione prima
della linea di base)."
  (let ((id (gdev-test-assurance--open db 'critical)))
    (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
    (gdev-test-assessment-profiles--evidence db id 'deduction "ci" 'ci)
    (gdev-test-assurance--step db id 'AUTHORIZED 'human "anna")
    (gdev-test-assurance--step db id 'IMPLEMENTING 'agent "ag1")
    (gdev-test-assurance--step db id 'VERIFYING 'agent "ag1")
    (gdev-test-assessment-profiles--evidence
     db id 'fact (or (plist-get options :verifier) "verificatore") 'ci)
    (gdev-test-assurance--step db id 'REVIEWING 'agent "ag2")
    (gdev-test-assessment-profiles--evidence
     db id 'fact "revisore" (or (plist-get options :reviewer-kind) 'human))
    (gdev-test-assurance--step db id 'APPROVED 'human (or (plist-get options :approver) "bea"))
    (when (plist-get options :record)
      (gdev-assessment-record db id :actor "pipeline" :actor-kind 'ci))
    (gdev-test-assurance--step db id 'BASELINED 'human "carlo")
    id))

(ert-deftest gdev-test-assessment-profiles-critical-flow-satisfies-all-twelve-controls ()
  "Una transazione critical condotta come richiesto soddisfa tutti i controlli."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assessment-profiles--critical db :record t))
           (a (gdev-assessment-run db id)))
      (should (= (length (alist-get 'results a)) 12))
      (should (equal (delete-dups (mapcar #'cdr (gdev-test-assessment--results a))) '("SATISFIED")))
      (should (= (alist-get 'SATISFIED (alist-get 'summary a)) 12))
      (should (eq (alist-get 'provisional a) t))
      (should-not (gdev-assurance-verify db)))))

(ert-deftest gdev-test-assessment-profiles-h01-needs-a-verifier-who-did-not-move-it ()
  "La prova di verifica deve essere di chi non ha portato la transazione a VERIFYING."
  (gdev-test-assurance--with-archive (root db)
    (let ((same (gdev-test-assessment-profiles--critical db :verifier "ag1" :record t))
          (other (gdev-test-assessment-profiles--critical db :record t)))
      (let ((a (gdev-assessment-run db same)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-H01") "NOT_SATISFIED"))
        (should (string-match-p "ma nessuna indipendente da chi ha portato la transazione a VERIFYING"
                                (gdev-test-assessment--reason a "GES-H01")))
        ;; Il controllo di qualità, che non chiede indipendenza, è soddisfatto.
        (should (equal (gdev-test-assessment-profiles--status a "GES-Q01") "SATISFIED")))
      (should (equal (gdev-test-assessment-profiles--status (gdev-assessment-run db other) "GES-H01")
                     "SATISFIED")))))

(ert-deftest gdev-test-assessment-profiles-h02-needs-a-review-by-a-person ()
  "La revisione deve essere registrata da un attore di tipo human."
  (gdev-test-assurance--with-archive (root db)
    (let ((by-ci (gdev-test-assessment-profiles--critical db :reviewer-kind 'ci :record t))
          (by-person (gdev-test-assessment-profiles--critical db :record t)))
      (let ((a (gdev-assessment-run db by-ci)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-H02") "NOT_SATISFIED"))
        (should (string-match-p "ma nessuna di un attore di tipo human"
                                (gdev-test-assessment--reason a "GES-H02")))
        (should (equal (gdev-test-assessment-profiles--status a "GES-S03") "SATISFIED")))
      (should (equal (gdev-test-assessment-profiles--status (gdev-assessment-run db by-person) "GES-H02")
                     "SATISFIED")))))

(ert-deftest gdev-test-assessment-profiles-h03-needs-an-assessment-recorded-before-the-baseline ()
  "Una valutazione registrata dopo la linea di base non conta."
  (gdev-test-assurance--with-archive (root db)
    (let ((recorded (gdev-test-assessment-profiles--critical db :record t))
          (missing (gdev-test-assessment-profiles--critical db))
          (late (gdev-test-assessment-profiles--critical db)))
      (gdev-assessment-record db late :actor "pipeline" :actor-kind 'ci)
      (let ((a (gdev-assessment-run db recorded)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-H03") "SATISFIED"))
        (should (string-match-p "Valutazione AS-0001 registrata prima del passaggio a BASELINED"
                                (gdev-test-assessment--reason a "GES-H03"))))
      (dolist (id (list missing late))
        (let ((a (gdev-assessment-run db id)))
          (should (equal (gdev-test-assessment-profiles--status a "GES-H03") "NOT_SATISFIED"))
          (should (string-match-p "Nessuna valutazione registrata prima del passaggio a BASELINED"
                                  (gdev-test-assessment--reason a "GES-H03")))))))
  ;; Prima che BASELINED sia raggiunto il controllo non è ancora dovuto.
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'high-assurance)))
      (should (equal (gdev-test-assessment-profiles--status (gdev-assessment-run db id) "GES-H03") "NOT_VERIFIED"))))
  ;; Se è dovuto prima del passaggio, il passaggio che manca si dice.
  (let ((controls (gdev-standards-read (expand-file-name "profili/controlli.eld"
                                                         gdev-standards-directory))))
    (setf (plist-get (nth 9 controls) :dovuto-da) 'PROPOSED)
    (gdev-test-controls--with-data (controls nil)
      (gdev-test-assurance--with-archive (root db)
        (let ((a (gdev-assessment-run db (gdev-test-assurance--open db 'high-assurance))))
          (should (equal (gdev-test-assessment-profiles--status a "GES-H03") "NOT_SATISFIED"))
          (should (string-match-p "Nessun passaggio a BASELINED registrato"
                                  (gdev-test-assessment--reason a "GES-H03"))))))))

(ert-deftest gdev-test-assessment-profiles-k01-needs-two-different-people ()
  "Chi autorizza e chi approva devono essere persone diverse."
  (gdev-test-assurance--with-archive (root db)
    (let ((same (gdev-test-assessment-profiles--critical db :approver "anna" :record t))
          (different (gdev-test-assessment-profiles--critical db :record t)))
      (let ((a (gdev-assessment-run db same)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-K01") "NOT_SATISFIED"))
        (should (string-match-p "anna ha portato la transazione a AUTHORIZED e a APPROVED"
                                (gdev-test-assessment--reason a "GES-K01"))))
      (let ((a (gdev-assessment-run db different)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-K01") "SATISFIED"))
        (should (string-match-p "anna e bea" (gdev-test-assessment--reason a "GES-K01"))))))
  (let ((controls (gdev-standards-read (expand-file-name "profili/controlli.eld"
                                                         gdev-standards-directory))))
    (setf (plist-get (nth 10 controls) :dovuto-da) 'PROPOSED)
    (gdev-test-controls--with-data (controls nil)
      (gdev-test-assurance--with-archive (root db)
        (let ((a (gdev-assessment-run db (gdev-test-assurance--open db 'critical))))
          (should (equal (gdev-test-assessment-profiles--status a "GES-K01") "NOT_SATISFIED"))
          (should (string-match-p "Nessun passaggio a AUTHORIZED registrato"
                                  (gdev-test-assessment--reason a "GES-K01"))))))))

(ert-deftest gdev-test-assessment-profiles-k02-forbids-waivers-but-not-declared-inapplicability ()
  "Una transazione critical non ha deroghe; una dichiarazione di non applicabilità non conta."
  (gdev-test-assurance--with-archive (root db)
    (let ((waived (gdev-test-assurance--open db 'critical))
          (inapplicable (gdev-test-assurance--open db 'critical))
          (clean (gdev-test-assurance--open db 'critical)))
      (gdev-decision-add db waived :kind 'waiver :control "GES-S02" :reason "Accettato"
                         :actor "responsabile" :actor-kind 'human)
      (gdev-decision-add db inapplicable :kind 'not-applicable :control "GES-S02"
                         :reason "Non pertinente" :actor "responsabile" :actor-kind 'human)
      (let ((a (gdev-assessment-run db waived)))
        (should (equal (gdev-test-assessment-profiles--status a "GES-K02") "NOT_SATISFIED"))
        (should (string-match-p "Esistono 1 decisioni waiver (DC-0001)"
                                (gdev-test-assessment--reason a "GES-K02"))))
      (dolist (id (list inapplicable clean))
        (let ((a (gdev-assessment-run db id)))
          (should (equal (gdev-test-assessment-profiles--status a "GES-K02") "SATISFIED"))
          (should (string-match-p "Nessuna decisione waiver" (gdev-test-assessment--reason a "GES-K02")))))
      ;; Il controllo non ammette decisioni: non si può derogare alla regola «nessuna deroga».
      (should (string-match-p "GES-K02 non ammette decisioni"
                              (gdev-test-assurance--refusal
                               (lambda () (gdev-decision-add db clean :kind 'waiver :control "GES-K02"
                                                             :reason "Eccezione" :actor "responsabile"
                                                             :actor-kind 'human))))))))

(ert-deftest gdev-test-assessment-profiles-the-new-controls-belong-only-to-their-profiles ()
  "H01–H03 non sono di secure; K01 e K02 non sono di high-assurance."
  (gdev-test-assurance--with-archive (root db)
    (let ((ids (lambda (profile)
                 (mapcar #'car (gdev-test-assessment--results
                                (gdev-assessment-run db (gdev-test-assurance--open db profile)))))))
      (dolist (control '("GES-H01" "GES-H02" "GES-H03" "GES-K01" "GES-K02"))
        (should-not (member control (funcall ids 'secure))))
      (dolist (control '("GES-K01" "GES-K02"))
        (should-not (member control (funcall ids 'high-assurance))))
      (dolist (control '("GES-H01" "GES-H02" "GES-H03"))
        (should (member control (funcall ids 'high-assurance)))
        (should (member control (funcall ids 'critical)))))))

(ert-deftest gdev-test-assessment-profiles-new-requirement-forms-are-validated ()
  "Ogni forma nuova di requisito è controllata prima dell'uso."
  (let* ((reference '(:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.8.2"))
         (problems
          (gdev-controls--control-problems
           `(:id "X" :titolo "t" :decidibile t :dovuto-da REVIEWING :metodo "m"
             :riferimenti (,reference)
             :richiede ((:prova :genere fact :origine collected :minimo 1 :in VERIFYING
                                :attore robot :indipendente-da-chi-porta-a NOSTATO)
                        (:valutazione-registrata :prima-di NOSTATO)
                        (:attori-distinti :stati (AUTHORIZED))
                        (:attori-distinti :stati (AUTHORIZED NOSTATO))
                        (:attori-distinti :stati uno)
                        (:nessuna-decisione :genere perdono))))))
    (dolist (fragment '("la prova indica un tipo d'attore sconosciuto"
                        "la prova indica uno stato sconosciuto per l'indipendenza"
                        "la valutazione registrata indica uno stato sconosciuto"
                        "gli attori distinti richiedono due stati noti"
                        "la decisione indica un genere sconosciuto"))
      (should (seq-some (lambda (problem) (string-match-p (regexp-quote fragment) problem)) problems))))
  ;; Le forme valide non producono problemi.
  (should-not (gdev-controls--control-problems
               `(:id "Y" :titolo "t" :decidibile t :dovuto-da REVIEWING :metodo "m"
                 :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.8.2"))
                 :richiede ((:prova :genere fact :origine collected :minimo 1 :in VERIFYING
                                    :attore human :indipendente-da-chi-porta-a VERIFYING)
                            (:valutazione-registrata :prima-di BASELINED)
                            (:attori-distinti :stati (AUTHORIZED APPROVED))
                            (:nessuna-decisione :genere waiver))))))

(provide 'gdev-assessment-profiles-test)
;;; gdev-assessment-profiles-test.el ends here
