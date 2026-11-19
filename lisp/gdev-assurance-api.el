;;; gdev-assurance-api.el --- Contratti delle entrate di assicurazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Un solo catalogo per CLI, agente e schema MCP. Nessuna apertura di archivio.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defconst gdev-assurance-read-contracts
  '(("status" 0 0) ("list" 0 1) ("show" 1 1) ("verify" 0 0)
    ("assess" 1 1) ("capability" 0 1) ("trace" 0 0) ("impact" 0 1) ("requests" 0 1)
    ("standards" 0 1) ("standard-assess" 1 1)
    ("work" 1 1) ("project" 0 1) ("taxonomy" 0 1) ("suggest" 1 1) ("snippets" 0 1)
    ("procedures" 0 0) ("procedure-plan" 1 1) ("runs" 0 1) ("model-check" 0 0))
  "Comandi di lettura: (NOME MINIMO-OPERANDI MASSIMO-OPERANDI).")

(defun gdev-assurance-read-commands ()
  "Restituisci i nomi dei comandi di lettura, nell'ordine del catalogo."
  (mapcar #'car gdev-assurance-read-contracts))

(defun gdev-assurance-read-command-p (command)
  "Restituisci non nil se COMMAND è una lettura registrata."
  (and (assoc command gdev-assurance-read-contracts) t))

(defun gdev-assurance-operands-p (command operands)
  "Restituisci non nil se OPERANDS rispetta l'arità di COMMAND."
  (when-let* ((entry (assoc command gdev-assurance-read-contracts)))
    (and (proper-list-p operands)
         (<= (nth 1 entry) (length operands) (nth 2 entry))
         (cl-every #'stringp operands))))

(defun gdev-assurance-blocking-result (data)
  "Restituisci il primo controllo dovuto non soddisfatto di DATA."
  (seq-find (lambda (row) (and (eq t (alist-get 'due row))
                              (member (alist-get 'status row) '("NOT_VERIFIED" "NOT_SATISFIED"))))
            (alist-get 'results data)))

(provide 'gdev-assurance-api)
;;; gdev-assurance-api.el ends here
