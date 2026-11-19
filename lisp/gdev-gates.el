;;; gdev-gates.el --- Controlli di passaggio fra gli stati -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un controllo di passaggio (gate) subordina un passaggio di stato alle
;; prove registrate.  È una regola del dominio `transition' del motore
;; (`gdev-policy'): il passaggio che lo richiede si nega finché mancano le
;; prove, e il rifiuto resta nella catena di audit.
;;
;; Una prova conta solo se:
;;
;;   - è stata registrata mentre la transazione era nello stato di partenza;
;;   - è successiva all'ultimo ingresso in quello stato: chi torna in
;;     VERIFYING dopo una verifica fallita non riusa le prove di prima;
;;   - ha il genere e l'origine richiesti.  Una prova `reconstructed' non
;;     soddisfa un controllo che chiede `collected'.
;;
;; L'elenco `gdev-gates-table' è provvisorio: contiene l'unico controllo che il
;; nucleo applica da solo.  I controlli che discendono da standard e profili
;; li definirà la Fase C a partire dai controlli operativi del registro.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-policy)

(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))
(declare-function gdev-assurance-db-version "gdev-assurance-db" (db))
(declare-function gdev-standard-transition-rule "gdev-standard-assessment" (context))
(declare-function gdev-project-transition-rule "gdev-project-store" (context))

(defvar gdev-gates-table
  '((:id verification-evidence
     :profiles (quality secure high-assurance critical)
     :from VERIFYING :to REVIEWING
     :needs ((:kind fact :origin collected :minimum 1))))
  "Controlli di passaggio: un plist per controllo.
:id lo nomina; :profiles elenca i profili che lo applicano; :from e :to il
passaggio; :needs le prove richieste, con :kind, :origin e :minimum.")

(defun gdev-gates--evidence-since-entry (db id state)
  "Restituisci (GENERE ORIGINE) delle prove di ID dopo l'ultimo ingresso in STATE."
  (let ((entered (or (caar (sqlite-select
                            db "select max(seq) from tx_event
 where tx_id = ? and kind in ('open', 'transition') and to_state = ?"
                            (list id (symbol-name state))))
                     0)))
    (sqlite-select
     db "select ev.kind, ev.origin from tx_event te
 join evidence ev on te.ref = printf('EV-%04d', ev.id)
 where te.tx_id = ? and te.kind = 'evidence' and te.seq > ?"
     (list id entered))))

(defun gdev-gates--shortfall (gate rows)
  "Restituisci il motivo per cui ROWS non bastano a GATE, o nil se bastano."
  (cl-some (lambda (need)
             (let* ((kind (symbol-name (plist-get need :kind)))
                    (origin (symbol-name (plist-get need :origin)))
                    (minimum (plist-get need :minimum))
                    (count (cl-count-if (lambda (row) (and (equal (car row) kind)
                                                           (equal (cadr row) origin)))
                                        rows)))
               (when (< count minimum)
                 (format "Il controllo %s richiede almeno %d prove %s (%s) registrate in %s dopo l'ultimo ingresso: ne risultano %d"
                         (plist-get gate :id) minimum kind origin (plist-get gate :from) count))))
           (plist-get gate :needs)))

(defun gdev-gates-rule (context)
  "Regola `gate': nega il passaggio di CONTEXT se un controllo non è soddisfatto."
  (let* ((tx (plist-get context :tx))
         (from (alist-get 'state tx))
         (to (plist-get context :target))
         (profile (alist-get 'profile tx)))
    (or (cl-some (lambda (gate)
               (when (and (eq (plist-get gate :from) from)
                          (eq (plist-get gate :to) to)
                          (memq profile (plist-get gate :profiles)))
                 (gdev-gates--shortfall
                  gate (gdev-gates--evidence-since-entry
                        (plist-get context :db) (alist-get 'id tx) from))))
             gdev-gates-table)
        (when (and (>= (gdev-assurance-db-version (plist-get context :db)) 6)
                   (sqlite-select (plist-get context :db) "select id from assurance_record where tx_id = ? and kind = 'standard' limit 1"
                                  (list (alist-get 'id tx))))
          (require 'gdev-standard-assessment)
          (gdev-standard-transition-rule context))
        (when (>= (gdev-assurance-db-version (plist-get context :db)) 7)
          (require 'gdev-project-store)
          (gdev-project-transition-rule context)))))

(provide 'gdev-gates)
;;; gdev-gates.el ends here
