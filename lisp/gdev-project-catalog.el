;;; gdev-project-catalog.el --- Cataloghi autorevoli esterni -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il catalogo è una vista derivata. Stati e identificativi restano quelli
;; della fonte; la freschezza non costituisce approvazione o prova del gate.
;;; Code:
(require 'json)
(require 'seq)
(require 'cl-lib)
(declare-function gdev-project--plist "gdev-project" (data keys))
(declare-function gdev-project--id-p "gdev-project" (value))
(declare-function gdev-project--strings "gdev-project" (values &optional paths))
(declare-function gdev-project-file "gdev-project" (root path))
(declare-function gdev-process-refuse "gdev-process" (format-string &rest args))
(declare-function gdev-evidence-file-sha256 "gdev-evidence" (file))

(defun gdev-project-catalog-validate (catalogs)
  "Verifica le dichiarazioni CATALOGS senza leggere o eseguire le fonti."
  (unless (proper-list-p catalogs) (gdev-process-refuse "Cataloghi non validi"))
  (let (ids)
    (dolist (row catalogs)
      (gdev-project--plist row '(:id :path :directories :files))
      (unless (and (gdev-project--id-p (plist-get row :id))
                   (not (member (plist-get row :id) ids))
                   (stringp (plist-get row :path)))
        (gdev-process-refuse "Identificativo o percorso del catalogo non valido"))
      (gdev-project--strings (list (plist-get row :path)) t)
      (dolist (key '(:directories :files)) (gdev-project--strings (plist-get row key) t))
      (unless (or (plist-get row :directories) (plist-get row :files))
        (gdev-process-refuse "Catalogo senza fonti dichiarate"))
      (push (plist-get row :id) ids))))

(defun gdev-project-catalog-paths (root descriptor)
  "Elenca le fonti di DESCRIPTOR in ROOT, comprese aggiunte e rimozioni."
  (let ((root (file-name-as-directory (file-truename root)))
        (paths (copy-sequence (plist-get descriptor :files))))
    (dolist (path (plist-get descriptor :directories))
      (let ((directory (gdev-project-file root path)))
        (unless (file-directory-p directory) (gdev-process-refuse "Cartella del catalogo assente: %s" path))
        (dolist (file (directory-files-recursively directory "."))
          (push (file-relative-name file root) paths))))
    (sort (delete-dups paths) #'string<)))

(defun gdev-project-catalog-inputs (root descriptor)
  "Fissa contenuto e inventario corrente delle fonti di DESCRIPTOR in ROOT."
  (vconcat
   (mapcar (lambda (path)
             (let ((file (gdev-project-file root path)))
               `((path . ,path) (sha256 . ,(if (file-regular-p file) (gdev-evidence-file-sha256 file) :null)))))
           (gdev-project-catalog-paths root descriptor))))

(defun gdev-project-catalog-read (root descriptor)
  "Leggi una vista JSON di DESCRIPTOR in ROOT, verificandone provenienza e limiti."
  (let ((file (gdev-project-file root (plist-get descriptor :path))))
    (unless (and (file-regular-p file) (<= (file-attribute-size (file-attributes file)) (* 16 1024 1024)))
      (gdev-process-refuse "Catalogo assente o oltre 16 MiB"))
    (let* ((data (with-temp-buffer (insert-file-contents file)
                                  (json-parse-buffer :object-type 'alist :array-type 'array)))
           (inputs (alist-get 'inputs data)) (records (alist-get 'records data))
           (paths (make-hash-table :test #'equal)) (ids (make-hash-table :test #'equal)))
      (unless (and (eq 1 (alist-get 'schema_version data))
                   (equal (plist-get descriptor :id) (alist-get 'id data))
                   (vectorp inputs) (vectorp records) (<= (length records) 20000))
        (gdev-process-refuse "Versione, identità o struttura del catalogo non valida"))
      (seq-doseq (input inputs)
        (let ((path (alist-get 'path input)) (hash (alist-get 'sha256 input)))
          (gdev-project-file root path)
          (unless (and (stringp hash) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" hash) (not (gethash path paths)))
            (gdev-process-refuse "Impronta o fonte duplicata nel catalogo"))
          (puthash path t paths)))
      (seq-doseq (record records)
        (let ((id (alist-get 'id record)) (path (alist-get 'path record)))
          (unless (and (gdev-project--id-p id) (not (gethash id ids)) (gethash path paths)
                       (stringp (alist-get 'kind record)) (stringp (alist-get 'state record))
                       (listp (alist-get 'data record)))
            (gdev-process-refuse "Record esterno non valido, duplicato o senza fonte"))
          (puthash id t ids)))
      (let ((current (gdev-project-catalog-inputs root descriptor)))
        ;; L'ordine del produttore non influisce sulla freschezza.
        (unless (equal (sort (append inputs nil) (lambda (a b) (string< (alist-get 'path a) (alist-get 'path b))))
                       (append current nil))
          (gdev-process-refuse "Catalogo superato: rigenera la vista dalle fonti correnti")))
      data)))

(defun gdev-project-catalog-data (root descriptor)
  "Esponi DESCRIPTOR in ROOT senza trasformare un errore in un catalogo vuoto valido."
  (condition-case err
      `((id . ,(plist-get descriptor :id)) (status . "CURRENT")
        (catalog . ,(gdev-project-catalog-read root descriptor))
        (human_approval . "NOT_VERIFIED") (certification . :false))
    (error `((id . ,(plist-get descriptor :id)) (status . "INVALID")
             (problem . ,(error-message-string err)) (human_approval . "NOT_VERIFIED") (certification . :false)))))

(provide 'gdev-project-catalog)
;;; gdev-project-catalog.el ends here
