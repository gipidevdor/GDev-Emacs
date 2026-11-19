;;; gdev-capability-test.el --- Percorsi e capacità osservata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Stessa lettura da CLI e agente, istantanee SQL e osservazioni senza punteggi
;; normativi. Le prove usano solo archivi temporanei.

;;; Code:

(require 'ert)
(require 'gdev-capability)

(ert-deftest gdev-test-capability-dynamic-controls-preserve-first-seen-order ()
  "L'indice unifica le osservazioni mantenendo ordine e primo titolo dei controlli."
  (gdev-test-assurance--with-archive (_root db)
    (let* ((controls '((:id "BASE-2" :titolo "Base due") (:id "BASE-1" :titolo "Base uno")))
           (snapshot (copy-tree controls))
           (context `(:controls (:controls ,controls :digest "catalog") :problems nil :head "head")))
      (cl-letf (((symbol-function 'gdev-assessment-context) (lambda (_) context))
                ((symbol-function 'gdev-process-list)
                 (lambda (_) '(((id . "T1") (profile . core)) ((id . "T2") (profile . core)))))
                ((symbol-function 'gdev-assessment-run)
                 (lambda (_ id)
                   `((standards . ((selection . :null)))
                     (results . ,(if (equal id "T1")
                                    [((control . "D2") (title . "Primo titolo") (status . "SATISFIED"))
                                     ((control . "D1") (title . "Dinamico uno") (status . "NOT_VERIFIED"))]
                                  [((control . "D2") (title . "Altro titolo") (status . "SATISFIED"))
                                   ((control . "BASE-1") (title . "Base uno") (status . "SATISFIED"))]))))))
        (let* ((report (gdev-capability-run db)) (rows (append (alist-get 'controls report) nil)))
          (should (equal '("BASE-2" "BASE-1" "D2" "D1") (mapcar (lambda (row) (alist-get 'control row)) rows)))
          (should (equal "Primo titolo" (alist-get 'title (nth 2 rows))))
          (should (= 2 (alist-get 'observations (nth 2 rows))))
          (should (= 100 (alist-get 'satisfied_percent (nth 2 rows))))
          (should (eq :null (alist-get 'satisfied_percent (car rows))))))
      (should (equal snapshot controls)))))

(ert-deftest gdev-test-assurance-read-contract-rejects-missing-and-extra-operands ()
  (should-not (gdev-assurance-read-command-p "advance"))
  (should-not (gdev-assurance-operands-p "show" nil))
  (should-not (gdev-assurance-operands-p "status" '("extra")))
  (should-not (gdev-assurance-operands-p "list" '(5)))
  (should-not (gdev-assurance-operands-p "list" 'bad))
  (should-not (gdev-assurance-operands-p "bad" nil))
  (should (gdev-assurance-operands-p "capability" nil))
  (should (gdev-assurance-operands-p "capability" '("core"))))

(ert-deftest gdev-test-assurance-read-snapshot-survives-a-concurrent-commit ()
  (gdev-test-assurance--with-archive (root writer)
    (sqlite-pragma writer "journal_mode = WAL")
    (gdev-test-assurance--open writer)
    (gdev-assurance-db-with-open (reader root)
      (gdev-assurance-db-read-transaction
       reader (lambda ()
                (should (= 1 (caar (sqlite-select reader "select count(*) from tx"))))
                (gdev-test-assurance--open writer)
                (gdev-assurance-db-read-transaction
                 reader (lambda ()
                          (should (= 1 (caar (sqlite-select reader "select count(*) from tx"))))))))
      (should (= 2 (caar (sqlite-select reader "select count(*) from tx")))))
    (gdev-assurance-db-transaction
     writer (lambda () (should (eq 'inside (gdev-assurance-db-read-transaction writer (lambda () 'inside))))))
    (should-error (gdev-assurance-db-read-transaction writer (lambda () (error "annulla"))))
    (should (eq 'after (gdev-assurance-db-read-transaction writer (lambda () 'after))))))

(defun gdev-test-capability--control (data id)
  "Restituisci il controllo ID dalle osservazioni DATA."
  (seq-find (lambda (row) (equal (alist-get 'control row) id)) (alist-get 'controls data)))

(ert-deftest gdev-test-capability-empty-archive-is-not-a-positive-assessment ()
  (gdev-test-assurance--with-archive (root db)
    (let ((data (gdev-capability-run db "core")))
      (should (equal (alist-get 'state data) "NOT_VERIFIED"))
      (should (= (length (alist-get 'controls data)) 3))
      (should (eq :null (alist-get 'satisfied_percent (aref (alist-get 'controls data) 0))))
      (should (= 0 (alist-get 'transactions data)))
      (should (string-search "non una valutazione ufficiale" (alist-get 'note data))))
    (should-error (gdev-capability-run db "unknown") :type 'user-error)))

(ert-deftest gdev-test-capability-distinguishes-observed-unverified-waived-and-inapplicable ()
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-assessment--baseline db 'core)
    (let ((pending (gdev-test-assurance--open db)))
      (gdev-decision-add db pending :kind 'waiver :control "GES-C03" :reason "Rinvio"
                         :actor "responsabile" :actor-kind 'human))
    (let ((cancelled (gdev-test-assurance--open db)))
      (gdev-test-assurance--step db cancelled 'CANCELLED 'human))
    (gdev-test-assurance--open db 'quality)
    (let* ((data (gdev-capability-run db "core"))
           (control (gdev-test-capability--control data "GES-C03"))
           (counts (alist-get 'statuses control)))
      (should (equal data (gdev-capability-run db "core")))
      (should (= 3 (alist-get 'transactions data)))
      (should (= 1 (alist-get 'SATISFIED counts)))
      (should (= 1 (alist-get 'WAIVED_WITH_AUTHORIZATION counts)))
      (should (= 1 (alist-get 'NOT_APPLICABLE counts)))
      (should (= 50 (alist-get 'satisfied_percent control)))
      (should (= 1 (alist-get 'NOT_VERIFIED
                                  (alist-get 'statuses (gdev-test-capability--control data "GES-C01"))))))
    (should (= 4 (alist-get 'transactions (gdev-capability-run db))))))

(ert-deftest gdev-test-capability-refuses-a-false-positive-on-a-damaged-archive ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance--prove db id)
      (gdev-test-assurance--edit-restoring-guard
       db "evidence_no_update" "update evidence set actor = 'altro'")
      (let ((data (gdev-capability-run db)))
        (should (equal (alist-get 'state data) "INCONSISTENT"))
        (should (eq (alist-get 'ok data) :false))
        (should (> (length (alist-get 'problems data)) 0)))
      (should (= 1 (car (gdev-test-assurance--cli root "capability")))))))

(ert-deftest gdev-test-assurance-all-read-entrances-agree-without-writing ()
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assessment--baseline db 'core))
           (file (gdev-assurance-db-file root))
           (before (gdev-evidence-file-sha256 file)))
      (gdev-test-project--fixture root)
      (dolist (command (gdev-assurance-read-commands))
        (let ((argument (cond ((member command '("work" "show" "assess" "standard-assess")) id)
                              ((equal command "suggest") "nist-sp-800-218")
                              ((equal command "procedure-plan") "PROC-FEATURE") (t ""))))
          (should (equal (gdev-assurance-data command root (unless (equal argument "") argument))
                         (gdev-test-assurance--live command argument root)))
          (should (equal command (gdev-mcp--operand 'assurance-command command)))
          (should (= (if (member command '("assess" "standard-assess")) 1 0) (car (apply #'gdev-test-assurance--cli root command
                                    (unless (equal argument "") (list argument))))))))
      (should (equal before (gdev-evidence-file-sha256 file))))
    (should (= 2 (car (gdev-test-assurance--cli root "capability" "unknown"))))
    (should (= 2 (car (gdev-test-assurance--cli root "capability" "core" "extra"))))))

;;; gdev-capability-test.el ends here
