;;; gdev-decisions.el --- Deroghe e decisioni di non applicabilità -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una persona può decidere, per una transazione, che un controllo del suo
;; profilo:
;;
;;   waiver          non è soddisfatto e lo si accetta (deroga);
;;   not-applicable  non si applica a questa modifica.
;;
;; Ogni decisione dice quale controllo, perché e chi la prende, e resta
;; nell'archivio e nella catena di audit come evento `decision'.  La valutazione
;; (`gdev-assessment') la usa per produrre WAIVED_WITH_AUTHORIZATION e
;; NOT_APPLICABLE: non esiste un altro modo di ottenere quegli esiti.
;;
;; Le regole del dominio `decision' sono del motore `gdev-policy' e si negano per
;; impostazione predefinita:
;;
;;   - la decide una persona: lo impongono anche la regola e un vincolo
;;     dell'archivio;
;;   - il controllo deve essere del profilo della transazione e deve ammettere
;;     decisioni: la catena di audit integra non si deroga;
;;   - una transazione conclusa non ne accetta di nuove: sarebbe retroattiva;
;;   - dal profilo `secure' in su non decide chi ha aperto la transazione.
;;
;; I controlli di passaggio di `gdev-gates' non si derogano: sono regole del
;; processo, non controlli della valutazione.  Una decisione non si revoca; se
;; serve, se ne prende un'altra e la valutazione conta la più recente.
;;
;; Limite dichiarato, lo stesso di tutto il nucleo: in questo processo nulla
;; impedisce a un agente che valuta Lisp di prendere una decisione
;; dichiarandosi una persona.  L'argine è fuori dal processo.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-assurance-db)
(require 'gdev-policy)
(require 'gdev-process)
(require 'gdev-evidence)
(require 'gdev-controls)

(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defconst gdev-decision-kinds '(waiver not-applicable)
  "Generi di decisione.")

(defconst gdev-decision--closed-states '(BASELINED REJECTED CANCELLED SUPERSEDED)
  "Stati in cui una transazione non accetta decisioni nuove.")

(defun gdev-decision-ref (id)
  "Restituisci l'identificativo leggibile della decisione numero ID."
  (format "DC-%04d" id))

(defun gdev-decision--note (kind control reason)
  "Restituisci la nota dell'evento di una decisione di KIND su CONTROL con REASON."
  (format "%s %s sha256:%s" kind control (gdev-evidence-sha256 reason)))

;;;; Regole

(defun gdev-decision--rule-human (context)
  "Regola `decision-human-only': una decisione è di una persona."
  (unless (eq (plist-get context :actor-kind) 'human)
    (format "Una decisione sui controlli richiede una persona, non un attore di tipo %s"
            (plist-get context :actor-kind))))

(defun gdev-decision--rule-open (context)
  "Regola `decision-open-transaction': una transazione conclusa non accetta
decisioni."
  (let ((tx (plist-get context :tx)))
    (when (memq (alist-get 'state tx) gdev-decision--closed-states)
      (format "%s è in %s: non accetta decisioni nuove" (alist-get 'id tx) (alist-get 'state tx)))))

(defun gdev-decision--rule-control (context)
  "Regola `decision-known-control': il controllo è del profilo e ammette decisioni."
  (let* ((tx (plist-get context :tx))
         (data (gdev-controls-load))
         (control-id (plist-get context :control))
         (control (cl-find control-id (gdev-controls-for-profile data (alist-get 'profile tx))
                           :key (lambda (item) (plist-get item :id)) :test #'equal)))
    (cond ((null control)
           (format "Il controllo %s non è del profilo %s" control-id (alist-get 'profile tx)))
          ((not (plist-get control :decidibile))
           (format "Il controllo %s non ammette decisioni" control-id)))))

(defun gdev-decision--rule-separation (context)
  "Regola `decision-separation': dal profilo secure in su non decide chi ha aperto."
  (let ((tx (plist-get context :tx)))
    (when (and (memq (alist-get 'profile tx) gdev-process--separated-profiles)
               (equal (plist-get context :actor)
                      (gdev-process--opener (plist-get context :db) (alist-get 'id tx))))
      (format "Con il profilo %s chi ha aperto %s non decide sui suoi controlli"
              (alist-get 'profile tx) (alist-get 'id tx)))))

(dolist (rule `((decision-human-only ,#'gdev-decision--rule-human
                                     "Una decisione sui controlli è di una persona.")
                (decision-open-transaction ,#'gdev-decision--rule-open
                                           "Una transazione conclusa non accetta decisioni.")
                (decision-known-control ,#'gdev-decision--rule-control
                                        "Il controllo è del profilo e ammette decisioni.")
                (decision-separation ,#'gdev-decision--rule-separation
                                     "Chi propone non decide sui controlli.")))
  (apply #'gdev-policy-register 'decision rule))

;;;; Scritture e letture

(cl-defun gdev-decision-add (db tx-id &key kind control reason actor actor-kind)
  "Registra in DB una decisione KIND sul controllo CONTROL di TX-ID e
restituisci il suo riferimento.  REASON dice perché.  Le regole del dominio
`decision' possono rifiutarla: il rifiuto entra nella catena come per un
passaggio."
  (unless (memq kind gdev-decision-kinds)
    (gdev-process-refuse "Il genere della decisione deve essere uno fra %s"
                         (mapconcat #'symbol-name gdev-decision-kinds ", ")))
  (gdev-process-check-line "Il controllo" control 64)
  (gdev-process-check-line "Il motivo" reason 1000)
  (gdev-process-check-actor actor actor-kind)
  (gdev-process-attempt
   db 'decision tx-id nil actor actor-kind (list :kind kind :control control)
   (lambda (tx)
     (let ((state (alist-get 'state tx))
           (at (gdev-assurance-db-now)))
       (sqlite-execute
        db "insert into decision (tx_id, kind, control_id, reason, actor, actor_kind, decided_at)
 values (?, ?, ?, ?, ?, ?, ?)"
        (list tx-id (symbol-name kind) control reason actor (symbol-name actor-kind) at))
       (let ((ref (gdev-decision-ref (caar (sqlite-select db "select max(id) from decision")))))
         (gdev-process-append-event db tx-id 'decision state state actor actor-kind
                                    :ref ref :note (gdev-decision--note kind control reason) :at at)
         ref)))))

(defun gdev-decision-list (db &optional tx-id)
  "Restituisci le decisioni di DB come alist, dalla prima all'ultima.
Con TX-ID, solo quelle della transazione."
  (mapcar (lambda (row)
            (let ((row (gdev-process-symbolize row '(kind actor_kind))))
              (cons (cons 'ref (gdev-decision-ref (alist-get 'id row))) row)))
          (if tx-id
              (gdev-assurance-db-select db "select * from decision where tx_id = ? order by id"
                                        (list tx-id))
            (gdev-assurance-db-select db "select * from decision order by id"))))

(defun gdev-decision-verify (db)
  "Restituisci i problemi nel legame fra le decisioni e la catena di audit di DB.
Ogni decisione ha un solo evento con il suo riferimento, la transazione, il
controllo e l'impronta del motivo; ogni evento di decisione ha la sua riga.
Attore, tipo d'attore e data devono coincidere con l'evento.
Ritorna nil se tutto torna."
  (let ((events (make-hash-table :test #'equal))
        problems)
    (dolist (event (gdev-assurance-db-select
                    db "select seq, tx_id, ref, note, actor, actor_kind, at
 from tx_event where kind = 'decision'"))
      (push event (gethash (alist-get 'ref event) events)))
    (dolist (row (gdev-decision-list db))
      (let* ((ref (alist-get 'ref row))
             (found (gethash ref events)))
        (cond ((null found)
               (push (format "%s non ha l'evento nella catena" ref) problems))
              ((cdr found)
               (push (format "%s ha più di un evento nella catena" ref) problems))
              ((not (equal (alist-get 'note (car found))
                           (gdev-decision--note (alist-get 'kind row) (alist-get 'control_id row)
                                                (alist-get 'reason row))))
               (push (format "%s: la decisione non è quella dell'evento" ref) problems))
              (t (setq problems
                       (append (gdev-process-event-row-problems row (car found) 'decided_at)
                               problems))))
        (remhash ref events)))
    (maphash (lambda (ref found)
               (push (format "%s ha un evento ma nessuna decisione (evento %d)"
                             ref (alist-get 'seq (car found)))
                     problems))
             events)
    (sort problems #'string<)))

(provide 'gdev-decisions)
;;; gdev-decisions.el ends here
