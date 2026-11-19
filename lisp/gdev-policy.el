;;; gdev-policy.el --- Motore delle regole del processo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il motore decide se un'azione del processo è ammessa.  Non conosce stati,
;; prove o profili: raccoglie regole registrate per dominio (`open',
;; `transition', `supersede', `evidence') e le applica nell'ordine di
;; registrazione.  Chi definisce un dominio registra le sue regole.
;;
;; Una regola è una funzione del contesto, un plist, che restituisce nil se
;; l'azione le sta bene oppure il motivo del rifiuto, una stringa.  Deve essere
;; deterministica e senza effetti: legge il contesto e al più interroga
;; l'archivio.  La prima regola che nega decide.
;;
;; Si nega per impostazione predefinita:
;;
;;   - un dominio senza regole nega, perché «nessuna regola» non è «nessun
;;     divieto»;
;;   - una regola che segnala un errore nega;
;;   - una regola che restituisce qualcosa di diverso da nil o una stringa
;;     nega.
;;
;; Nessuna di queste condizioni lascia passare l'azione.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar gdev-policy--rules nil
  "Regole registrate: alist DOMINIO -> elenco di (ID FUNZIONE DOCUMENTAZIONE).
L'ordine è quello di registrazione.")

(defun gdev-policy-register (domain id function &optional doc)
  "Registra in DOMAIN la regola ID, realizzata da FUNCTION.
Una regola con lo stesso ID nello stesso dominio viene sostituita al suo
posto, così ricaricare un file non ne altera l'ordine.  DOC dice cosa vieta."
  (let* ((entry (list id function doc))
         (cell (assq domain gdev-policy--rules)))
    (if (null cell)
        (push (list domain entry) gdev-policy--rules)
      (if-let* ((existing (assq id (cdr cell))))
          (setcar (memq existing (cdr cell)) entry)
        (setcdr cell (append (cdr cell) (list entry)))))
    id))

(defun gdev-policy-rules (domain)
  "Restituisci gli identificativi delle regole di DOMAIN, in ordine di
applicazione."
  (mapcar #'car (cdr (assq domain gdev-policy--rules))))

(defun gdev-policy--deny (rule reason)
  "Restituisci la decisione che nega per RULE con il motivo REASON."
  (list :allowed nil :rule rule :reason reason))

(defun gdev-policy-decide (domain context)
  "Decidi se un'azione di DOMAIN è ammessa nel CONTEXT dato.
Restituisci un plist (:allowed t) oppure (:allowed nil :rule ID :reason TESTO)."
  (let ((entries (cdr (assq domain gdev-policy--rules)))
        (decision nil))
    (if (null entries)
        (gdev-policy--deny 'no-rules (format "Nessuna regola per %s: si nega" domain))
      (while (and entries (null decision))
        (pcase-let ((`(,id ,function) (car entries)))
          (setq entries (cdr entries))
          (condition-case err
              (let ((outcome (funcall function context)))
                (cond ((null outcome))
                      ((stringp outcome) (setq decision (gdev-policy--deny id outcome)))
                      (t (setq decision
                               (gdev-policy--deny
                                id (format "La regola %s ha restituito un valore non valido" id))))))
            (error (setq decision
                         (gdev-policy--deny
                          id (format "La regola %s ha fallito: %s" id (error-message-string err))))))))
      (or decision (list :allowed t)))))

(provide 'gdev-policy)
;;; gdev-policy.el ends here
