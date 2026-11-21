;;; gdev-work.el --- Schede operative delle transazioni formali -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; La transazione possiede identificativo, stati e blocchi. Una scheda
;; versionata ne descrive il lavoro; l'audit ne conserva ogni associazione.
;;; Code:
(require 'gdev-project-store)

(defun gdev-work-validate (data project)
  "Valida la scheda DATA e i suoi riferimenti nel PROJECT."
  (gdev-project--plist data '(:version :title :type :objective :scope :requirements :inputs
                             :prerequisites :owner :priority :depends-on :procedure :snippets
                             :acceptance :artifacts :revisions))
  (unless (and (eq 1 (plist-get data :version))
               (memq (plist-get data :type) '(feature bugfix refactor docs dependency release))
               (memq (plist-get data :priority) '(must should could))
               (cl-every (lambda (key) (gdev-project--text-p (plist-get data key)))
                         '(:title :objective :scope :owner))
               (plist-get data :requirements) (plist-get data :acceptance))
    (gdev-process-refuse "Compila titolo, tipo, obiettivo, ambito, responsabile, requisiti e accettazione"))
  (dolist (key '(:requirements :prerequisites :depends-on :snippets :acceptance :revisions))
    (gdev-project--strings (plist-get data key)))
  (gdev-project--strings (plist-get data :inputs) t)
  (gdev-project--strings (plist-get data :artifacts) #'gdev-project-output-p)
  (dolist (key '(:requirements :snippets))
    (dolist (id (plist-get data key))
      (unless (seq-find (lambda (row) (equal id (plist-get row :id))) (plist-get project key))
        (gdev-process-refuse "Riferimento %s non risolto nella lavorazione" id))))
  (let* ((selected (plist-get data :procedure))
         (procedure (seq-find (lambda (row) (equal (plist-get selected :id) (plist-get row :id)))
                              (plist-get project :procedures))))
    (gdev-project--plist selected '(:id :version))
    (unless (and procedure (equal (plist-get selected :version) (plist-get procedure :version))
                 (member (symbol-name (plist-get data :type)) (plist-get procedure :types)))
      (gdev-process-refuse "Procedura %s: richiesta versione %S per tipo %s; disponibile versione %S per tipi %S. Correggi :procedure della scheda o :types della procedura."
                           (plist-get selected :id) (plist-get selected :version) (plist-get data :type)
                           (plist-get procedure :version) (plist-get procedure :types))))
  data)

(defun gdev-work-latest (db tx-id)
  "Restituisci l'ultima scheda collegata a TX-ID in DB."
  (car (last (seq-filter (lambda (row) (equal "work" (alist-get 'operation (gdev-record-data row))))
                         (gdev-record-list db tx-id 'project)))))

(cl-defun gdev-work-bind (db tx-id root path &key actor actor-kind)
  "Collega la scheda versionata PATH a TX-ID senza alterarne lo stato."
  (gdev-trace-root db root)
  (let* ((file (gdev-project-file root path))
         (data (gdev-work-validate (gdev-standards-read file) (gdev-project-read root))))
    (dolist (input (plist-get data :inputs))
      (unless (file-regular-p (gdev-project-file root input)) (gdev-process-refuse "Input assente: %s" input)))
    (dolist (dependency (plist-get data :depends-on))
      (unless (and (not (equal dependency tx-id)) (gdev-process-get db dependency))
        (gdev-process-refuse "Lavorazione dipendente non risolta: %s" dependency)))
    (gdev-record-add db tx-id 'project
                     `((version . 1) (operation . "work") (path . ,path)
                       (sha256 . ,(gdev-evidence-file-sha256 file)) (definition . ,(gdev-project-json data)))
                     :actor actor :actor-kind actor-kind)))

(defun gdev-work-record-validate (data)
  "Valida i campi di associazione immutabile DATA."
  (gdev-record-fields data '(version operation path sha256 definition))
  (unless (and (eq 1 (alist-get 'version data)) (equal "work" (alist-get 'operation data))
               (gdev-trace-relative-p (alist-get 'path data))
               (stringp (alist-get 'sha256 data))
               (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" (alist-get 'sha256 data))
               (listp (alist-get 'definition data)))
    (gdev-process-refuse "Associazione della scheda non valida")))

(defun gdev-work-problem (db tx-id root stage)
  "Indica il primo vincolo della scheda non soddisfatto prima di STAGE."
  (when-let* ((record (gdev-work-latest db tx-id)))
    (let* ((payload (gdev-record-data record))
           (file (gdev-project-file root (alist-get 'path payload)))
           (data (and (file-regular-p file)
                      (gdev-work-validate (gdev-standards-read file) (gdev-project-read root)))))
      (cond
       ((or (not data) (not (equal (alist-get 'sha256 payload) (gdev-evidence-file-sha256 file))))
        "La scheda della lavorazione è cambiata: collegala nuovamente e ripeti le prove")
       ((memq stage '(AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED))
        (when (seq-some (lambda (id) (not (eq 'BASELINED (alist-get 'state (gdev-process-get db id)))))
                        (plist-get data :depends-on))
          "Completa le lavorazioni da cui dipende questa attività"))))))

(defun gdev-work-data (db tx-id)
  "Descrivi la scheda, lo stato e le esecuzioni di TX-ID in DB."
  (let* ((tx (or (gdev-process-get db tx-id) (gdev-process-refuse "Lavorazione non trovata: %s" tx-id)))
         (record (gdev-work-latest db tx-id)))
    `((transaction . ,tx-id) (state . ,(symbol-name (alist-get 'state tx)))
      (work . ,(if record (gdev-record-data record) :null))
      (snippets . ,(vconcat (mapcar (lambda (row) `((ref . ,(alist-get 'ref row)) (data . ,(gdev-record-data row))))
                                   (seq-filter (lambda (row) (equal "snippet" (alist-get 'operation (gdev-record-data row))))
                                               (gdev-record-list db tx-id 'project)))))
      (next . ,(if record "Consulta i controlli e la procedura collegata" "Collega una scheda di lavorazione")))))

(provide 'gdev-work)
;;; gdev-work.el ends here
