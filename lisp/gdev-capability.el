;;; gdev-capability.el --- Capacità osservata del processo GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Osservazioni riproducibili per controllo su tutte le transazioni del profilo.
;; Non assegna livelli ISO né trasforma deroghe in prove soddisfatte.

;;; Code:

(require 'cl-lib)
(require 'gdev-assessment)

(defconst gdev-capability-note
  "Misura delle osservazioni di GDev, non una valutazione ufficiale di capacità o conformità."
  "Limite della misura mostrato in ogni risultato.")

(defun gdev-capability--run (db &optional profile)
  "Misura i controlli osservati in DB, eventualmente per PROFILE (stringa)."
  (when (and profile (not (member profile (mapcar #'symbol-name gdev-process-profiles))))
    (user-error "Profilo sconosciuto: %s" profile))
  (gdev-assurance-db-read-transaction
   db (lambda ()
        (let* ((gdev-assessment--context (gdev-assessment-context db))
               (data (plist-get gdev-assessment--context :controls))
               (problems (plist-get gdev-assessment--context :problems))
               (transactions (cl-remove-if-not
                              (lambda (tx) (or (null profile)
                                               (equal profile (symbol-name (alist-get 'profile tx)))))
                              (gdev-process-list db)))
               (observations (make-hash-table :test #'equal))
               (known (make-hash-table :test #'equal))
               (controls (copy-sequence (plist-get data :controls))) extra fingerprints inputs
               rows)
          (dolist (control controls) (puthash (plist-get control :id) t known))
          (dolist (tx transactions)
            (let ((assessment (gdev-assessment-run db (alist-get 'id tx))))
              (unless (eq :null (alist-get 'selection (alist-get 'standards assessment)))
                (push (alist-get 'controls_digest assessment) fingerprints)
                (push (alist-get 'input_digest assessment) inputs))
              (seq-doseq (result (alist-get 'results assessment))
                (let ((id (alist-get 'control result)))
                  (push (alist-get 'status result) (gethash id observations))
                  (unless (gethash id known)
                    (puthash id t known)
                    (push (list :id id :titolo (alist-get 'title result)) extra))))))
          (setq controls (nconc controls (nreverse extra)))
          (dolist (control controls)
            (let* ((id (plist-get control :id))
                   (statuses (gethash id observations))
                   (counts (mapcar (lambda (status)
                                     (cons status (cl-count (symbol-name status) statuses :test #'equal)))
                                   gdev-assessment-statuses))
                   (applicable (- (length statuses) (alist-get 'NOT_APPLICABLE counts))))
              (when (or statuses (null profile)
                        (member id (mapcar (lambda (c) (plist-get c :id))
                                          (gdev-controls-for-profile data (intern profile)))))
                (push `((control . ,id) (title . ,(plist-get control :titolo))
                        (observations . ,(length statuses)) (statuses . ,counts)
                        (satisfied_percent . ,(if (zerop applicable) :null
                                                (/ (* 100 (alist-get 'SATISFIED counts)) applicable))))
                      rows))))
          `((method . "GES-observations-1")
            (scope . ,(or profile "all"))
            (state . ,(cond (problems "INCONSISTENT")
                            ((null transactions) "NOT_VERIFIED") (t "OBSERVED")))
            (ok . ,(if problems :false t))
            (problems . ,(vconcat problems))
            (transactions . ,(length transactions))
            (chain_head . ,(plist-get gdev-assessment--context :head))
            (input_digest . ,(gdev-evidence-sha256 (concat (plist-get gdev-assessment--context :head) "\n"
                                                         (plist-get data :digest) "\n" (mapconcat #'identity inputs "\n"))))
            (controls_digest . ,(if fingerprints
                                    (gdev-evidence-sha256 (concat (plist-get data :digest) "\n" (mapconcat #'identity fingerprints "\n")))
                                  (plist-get data :digest)))
            (controls . ,(vconcat (nreverse rows)))
            (note . ,gdev-capability-note))))))

(defun gdev-capability-run (db &optional profile)
  "Misura DB con una cache dei riferimenti limitata a questa richiesta."
  (gdev-standards-with-cache (lambda () (gdev-capability--run db profile))))

(provide 'gdev-capability)
;;; gdev-capability.el ends here
