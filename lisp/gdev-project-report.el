;;; gdev-project-report.el --- Rapporto di progetto riproducibile -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il rapporto descrive la definizione e le lacune correnti. Le approvazioni
;; e le prove di esecuzione restano nell'audit, senza attestazioni implicite.
;;; Code:
(require 'gdev-project-templates)

(defconst gdev-project-report-path "docs/assicurazione/generati/project.md")

(defun gdev-project-report--cell (value)
  "Rendi VALUE sicuro per una cella Markdown."
  (replace-regexp-in-string "[|\n\r]" " " (format "%s" (or value "Da compilare"))))

(defun gdev-project-report-render (root)
  "Genera il rapporto di ROOT senza scriverlo."
  (gdev-standards-with-cache
   (lambda ()
     (let* ((data (gdev-project-read root)) (inputs (gdev-project-inputs root data))
            (problems (gdev-project-problems root data))
            (digest (gdev-evidence-sha256 (gdev-record-encode `((generator . "GDev-project-1") (inputs . ,inputs)
                                                                              (taxonomy . ,(gdev-taxonomy-digest)))))))
       (with-temp-buffer
         (insert "<!-- Generato da GDev; non modificare. Fonti sha256:" digest " -->\n\n# " (plist-get data :name) "\n\n")
         (insert (or (plist-get data :purpose) "Scopo da compilare.") "\n\n")
         (insert "Stato della definizione: " (if problems "INCOMPLETE" "DEFINED")
                 ". Approvazione umana: NOT_VERIFIED. Nessuna certificazione attribuita.\n\n")
         (insert "## Requisiti e verifiche previste\n\n| Requisito | Criterio di accettazione | Metodo | Procedura |\n| --- | --- | --- | --- |\n")
         (dolist (row (plist-get data :requirements))
           (insert (format "| %s | %s | %s | %s |\n" (plist-get row :id)
                           (gdev-project-report--cell (plist-get row :acceptance)) (plist-get row :method) (plist-get row :procedure))))
         (insert "\n## Standard e copertura\n\n| Standard | Edizione | Applicabilità | Perimetro | Indice |\n| --- | --- | --- | --- | --- |\n")
         (dolist (row (plist-get data :standards))
           (let ((taxonomy (aref (alist-get 'taxonomies (gdev-taxonomy-data (plist-get row :id))) 0)))
             (insert (format "| %s | %s | %s | %s | %s |\n" (plist-get row :id) (plist-get row :edition)
                             (plist-get row :applicability) (plist-get row :scope) (alist-get 'index_status taxonomy)))))
         (insert "\n## Compilazione ancora necessaria\n\n")
         (if problems (dolist (problem problems) (insert "- " problem "\n"))
           (insert "I campi dovuti sono compilati. Questo non attesta l'esecuzione delle verifiche.\n"))
         (insert "\n## Impronte delle sorgenti\n\n| Percorso | SHA-256 |\n| --- | --- |\n")
         (seq-doseq (row inputs) (insert (format "| %s | %s |\n" (alist-get 'path row) (alist-get 'sha256 row))))
         (buffer-string))))))

(defun gdev-project-report (root &optional check)
  "Produci il rapporto di ROOT; con CHECK confrontalo senza scrivere."
  (let* ((content (gdev-project-report-render root)) (file (gdev-project-file root gdev-project-report-path))
         (old (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)))))
    (when (and old (not (string-prefix-p "<!-- Generato da GDev; non modificare. Fonti sha256:" old)))
      (gdev-process-refuse "Il rapporto contiene dati dell'utente"))
    (if check (not (equal old content))
      (gdev-project-write-file root gdev-project-report-path content (and old (gdev-evidence-file-sha256 file))))))

(provide 'gdev-project-report)
;;; gdev-project-report.el ends here
