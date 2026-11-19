;;; gdev-evidence.el --- Prove delle transazioni ingegneristiche -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una prova lega a una transazione l'impronta (SHA-256) di un contenuto e
;; dice di che genere è:
;;
;;   fact        ciò che si è osservato o misurato;
;;   deduction   ciò che ne segue per ragionamento;
;;   hypothesis  ciò che si assume senza averlo verificato.
;;
;; L'origine distingue la prova `collected', raccolta durante la
;; transazione, dalla `reconstructed', ricostruita a posteriori (per esempio
;; nell'adozione di un progetto preesistente).  Il nucleo non rende mai
;; retroattiva una prova: l'istante lo fissa lui, non chi chiama, e una
;; transazione conclusa non ne accetta di nuove.
;;
;; Ogni prova è anche un evento della catena di audit.  L'evento riporta
;; l'impronta, quindi alterare la riga della prova si rileva con
;; `gdev-evidence-verify'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-assurance-db)
(require 'gdev-policy)
(require 'gdev-process)

(declare-function sqlite-execute "sqlite.c" (db query &optional values))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defconst gdev-evidence-kinds '(fact deduction hypothesis)
  "Generi di prova.")

(defconst gdev-evidence-origins '(collected reconstructed)
  "Origini di una prova.")

(defconst gdev-evidence--closed-states '(BASELINED REJECTED CANCELLED SUPERSEDED)
  "Stati in cui una transazione non accetta prove nuove.")

(defun gdev-evidence-ref (id)
  "Restituisci l'identificativo leggibile della prova numero ID."
  (format "EV-%04d" id))

(defun gdev-evidence-sha256 (text)
  "Restituisci l'impronta SHA-256 di TEXT, codificato in UTF-8."
  (secure-hash 'sha256 (encode-coding-string text 'utf-8)))

(defun gdev-evidence-file-sha256 (file)
  "Restituisci l'impronta SHA-256 dei byte di FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun gdev-evidence--rule-open (context)
  "Regola `evidence-open-transaction': una transazione conclusa non accetta prove."
  (let ((tx (plist-get context :tx)))
    (when (memq (alist-get 'state tx) gdev-evidence--closed-states)
      (format "%s è in %s: non accetta prove nuove" (alist-get 'id tx) (alist-get 'state tx)))))

(gdev-policy-register 'evidence 'evidence-open-transaction #'gdev-evidence--rule-open
                      "Una transazione conclusa non accetta prove nuove.")

(cl-defun gdev-evidence-add (db tx-id &key kind origin description content file actor actor-kind)
  "Registra in DB una prova di TX-ID e restituisci il suo riferimento.
KIND è uno di `gdev-evidence-kinds'; ORIGIN, se omesso, è `collected'.
DESCRIPTION dice cosa dimostra.  Il contenuto è CONTENT, un testo, oppure
FILE, un file: ne resta solo l'impronta.  Le regole del dominio `evidence'
possono rifiutarla: il rifiuto entra nella catena come per un passaggio."
  (let ((origin (or origin 'collected)))
    (unless (memq kind gdev-evidence-kinds)
      (gdev-process-refuse "Il genere della prova deve essere uno fra %s"
                           (mapconcat #'symbol-name gdev-evidence-kinds ", ")))
    (unless (memq origin gdev-evidence-origins)
      (gdev-process-refuse "L'origine della prova deve essere una fra %s"
                           (mapconcat #'symbol-name gdev-evidence-origins ", ")))
    (gdev-process-check-line "La descrizione" description 500)
    (gdev-process-check-actor actor actor-kind)
    (unless (eq (and content t) (not file))
      (gdev-process-refuse "Indica o il contenuto o il file della prova, non entrambi né nessuno"))
    (when (and content (not (stringp content)))
      (gdev-process-refuse "Il contenuto deve essere un testo"))
    (when (and file (not (file-regular-p file)))
      (gdev-process-refuse "Il file della prova non esiste: %s" file))
    (let ((sha256 (if content (gdev-evidence-sha256 content) (gdev-evidence-file-sha256 file))))
      (gdev-process-attempt
       db 'evidence tx-id nil actor actor-kind nil
       (lambda (tx)
         (let ((state (alist-get 'state tx))
               (at (gdev-assurance-db-now)))
           (sqlite-execute
            db "insert into evidence
 (tx_id, kind, origin, description, sha256, actor, actor_kind, collected_at)
 values (?, ?, ?, ?, ?, ?, ?, ?)"
            (list tx-id (symbol-name kind) (symbol-name origin) description sha256
                  actor (symbol-name actor-kind) at))
           (let ((ref (gdev-evidence-ref (caar (sqlite-select db "select max(id) from evidence")))))
             (gdev-process-append-event db tx-id 'evidence state state actor actor-kind
                                        :ref ref :note (concat "sha256:" sha256) :at at)
             ref)))))))

(defun gdev-evidence-list (db &optional tx-id)
  "Restituisci le prove di DB come alist, dalla prima all'ultima.
Con TX-ID, solo quelle della transazione."
  (mapcar (lambda (row)
            (let ((row (gdev-process-symbolize row '(kind origin actor_kind))))
              (cons (cons 'ref (gdev-evidence-ref (alist-get 'id row))) row)))
          (if tx-id
              (gdev-assurance-db-select db "select * from evidence where tx_id = ? order by id"
                                        (list tx-id))
            (gdev-assurance-db-select db "select * from evidence order by id"))))

(defun gdev-evidence-verify (db)
  "Restituisci i problemi nel legame fra le prove e la catena di audit di DB.
Ogni prova ha un solo evento con il suo riferimento e la sua impronta; ogni
evento di prova ha la sua riga.  Transazione, attore, tipo d'attore e data
devono coincidere con l'evento.  Ritorna nil se tutto torna."
  (let ((events (make-hash-table :test #'equal))
        problems)
    (dolist (event (gdev-assurance-db-select
                    db "select seq, tx_id, ref, note, actor, actor_kind, at
 from tx_event where kind = 'evidence'"))
      (push event (gethash (alist-get 'ref event) events)))
    (dolist (row (gdev-evidence-list db))
      (let* ((ref (alist-get 'ref row))
             (found (gethash ref events)))
        (cond ((null found)
               (push (format "%s non ha l'evento nella catena" ref) problems))
              ((cdr found)
               (push (format "%s ha più di un evento nella catena" ref) problems))
              ((not (equal (alist-get 'note (car found)) (concat "sha256:" (alist-get 'sha256 row))))
               (push (format "%s: l'impronta registrata non è quella dell'evento" ref) problems))
              (t (setq problems
                       (append (gdev-process-event-row-problems row (car found) 'collected_at)
                               problems))))
        (remhash ref events)))
    (maphash (lambda (ref found)
               (push (format "%s ha un evento ma nessuna prova (evento %d)"
                             ref (alist-get 'seq (car found)))
                     problems))
             events)
    (sort problems #'string<)))

(provide 'gdev-evidence)
;;; gdev-evidence.el ends here
