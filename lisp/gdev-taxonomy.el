;;; gdev-taxonomy.el --- Tassonomie con provenienza e copertura esplicita -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le gerarchie derivano dai dati acquisiti, mai da numeri di clausola
;; inventati. Completezza dell'indice e attuazione sono dimensioni distinte.
;;; Code:
(require 'gdev-standards)
(require 'gdev-evidence)
(require 'gdev-graph)
(require 'json)

(defun gdev-taxonomy--imported (id)
  "Leggi l'indice riproducibile delle fonti PDF/Markdown per ID."
  (let ((file (expand-file-name "standard/indici-fonti.json" gdev-standards-directory)))
    (when (file-regular-p file)
      (let ((data (with-temp-buffer (insert-file-contents file)
                                    (json-parse-buffer :object-type 'alist :array-type 'array :false-object :false))))
        (unless (eq 1 (alist-get 'schema_version data)) (user-error "Versione degli indici non supportata"))
        (when-let* ((entry (seq-find (lambda (row) (equal id (alist-get 'id row))) (alist-get 'taxonomies data))))
          (let ((ids (make-hash-table :test #'equal)))
            (seq-doseq (node (alist-get 'nodes entry))
              (unless (and (stringp (alist-get 'id node)) (not (gethash (alist-get 'id node) ids))
                           (stringp (alist-get 'title node)) (stringp (alist-get 'kind node))
                           (stringp (alist-get 'locator node)))
                (user-error "Nodo di tassonomia non valido: %s" id))
              (puthash (alist-get 'id node) node ids))
            (let ((adjacency (make-hash-table :test #'equal)) nodes)
              (seq-doseq (node (alist-get 'nodes entry))
                (let ((parent (alist-get 'parent node)) (name (alist-get 'id node)))
                  (push name nodes)
                  (when (and parent (not (eq parent :null)))
                    (unless (gethash parent ids) (user-error "Gerarchia della tassonomia non valida: %s" id))
                    (puthash name (list parent) adjacency))))
              (when (gdev-graph-cycle (nreverse nodes) adjacency)
                (user-error "Gerarchia della tassonomia non valida: %s" id)))
            (seq-doseq (source (alist-get 'sources entry))
              (let* ((path (alist-get 'path source))
                     (base (expand-file-name "standard/" gdev-standards-directory))
                     (file (and (stringp path) (expand-file-name path base))))
                (unless (and file (file-in-directory-p (file-truename file) base)
                             (file-regular-p file) (equal (alist-get 'sha256 source) (gdev-evidence-file-sha256 file)))
                  (user-error "L'indice %s non corrisponde più alla fonte locale" id))))
            entry))))))

(defun gdev-taxonomy--node (id parent title kind locator &optional text)
  "Costruisci un nodo ID con PARENT, TITLE, KIND, LOCATOR e TEXT."
  `((id . ,id) (parent . ,(or parent :null)) (title . ,title)
    (kind . ,kind) (locator . ,locator) (text . ,(or text :null))))

(defun gdev-taxonomy--asvs (data)
  "Ricostruisci capitoli, sezioni e requisiti ASVS da DATA."
  (let ((seen (make-hash-table :test #'equal)) nodes)
    (dolist (row data)
      (dolist (part `((,(plist-get row :capitolo) nil ,(plist-get row :nome-capitolo) "chapter")
                      (,(plist-get row :sezione) ,(plist-get row :capitolo) ,(plist-get row :nome-sezione) "section")
                      (,(plist-get row :id) ,(plist-get row :sezione) ,(plist-get row :id) "requirement")))
        (unless (gethash (car part) seen)
          (puthash (car part) t seen)
          (push (gdev-taxonomy--node (nth 0 part) (nth 1 part) (nth 2 part) (nth 3 part)
                                    (nth 0 part) (when (equal (nth 3 part) "requirement") (plist-get row :testo))) nodes))))
    (nreverse nodes)))

(defun gdev-taxonomy--ssdf (data)
  "Ricostruisci gruppi, pratiche e compiti SSDF dalla tabella DATA."
  (let ((seen (make-hash-table :test #'equal)) nodes practice)
    (dolist (row (cdr (plist-get (car data) :righe)))
      (let ((heading (or (nth 0 row) "")) (task (or (nth 1 row) "")))
        (when (string-match "(\\([A-Z]+\\.[0-9]+\\)):" heading)
          (setq practice (match-string 1 heading))
          (let ((group (car (split-string practice "\\."))))
            (unless (gethash group seen)
              (puthash group t seen)
              (push (gdev-taxonomy--node group nil group "group" group) nodes))
            (unless (gethash practice seen)
              (puthash practice t seen)
              (push (gdev-taxonomy--node practice group heading "practice" practice) nodes))))
        (when (string-match "\\`\\([A-Z]+\\.[0-9]+\\.[0-9]+\\):" task)
          (let ((id (match-string 1 task)))
            (unless (gethash id seen)
              (puthash id t seen)
              (push (gdev-taxonomy--node id practice id "requirement" id task) nodes))))))
    (nreverse nodes)))

(defun gdev-taxonomy--reference (data)
  "Rendi DATA un indice di riferimento, senza attribuirgli completezza."
  (mapcar (lambda (row)
            (gdev-taxonomy--node (plist-get row :id) nil
                                 (or (plist-get row :titolo) (plist-get row :id))
                                 "reference" (plist-get row :id))) data))

(defun gdev-taxonomy--sources (entry)
  "Controlla byte e impronte delle acquisizioni di ENTRY."
  (mapcar
   (lambda (source)
     (let* ((path (plist-get source :file))
            (file (and path (expand-file-name path (expand-file-name "standard/" gdev-standards-directory))))
            (expected (plist-get source :sha256))
            (actual (and file (file-regular-p file) (gdev-evidence-file-sha256 file))))
       `((path . ,(or path :null)) (expected . ,(or expected :null))
         (sha256 . ,(or actual :null))
         (verified . ,(if (and expected (equal expected actual)) t :false)))))
   (plist-get entry :acquisizioni)))

(defun gdev-taxonomy-data (&optional id)
  "Leggi le tassonomie o quella di ID senza aprire un archivio di progetto."
  (gdev-standards-with-cache
   (lambda ()
     (let ((entries (if id (list (or (gdev-standards-get id) (user-error "Standard sconosciuto: %s" id)))
                      (gdev-standards-all))) result)
       (dolist (entry entries)
         (let* ((name (plist-get entry :id)) (data (gdev-standards-data name))
                (imported (gdev-taxonomy--imported name))
                (complete (or (member name '("owasp-asvs" "nist-sp-800-218"))
                              (eq t (alist-get 'index_complete imported))))
                (requirements-complete (member name '("owasp-asvs" "nist-sp-800-218")))
                (nodes (if imported (append (alist-get 'nodes imported) nil) (pcase name
                         ("owasp-asvs" (gdev-taxonomy--asvs data))
                         ("nist-sp-800-218" (gdev-taxonomy--ssdf data))
                         (_ (gdev-taxonomy--reference data)))))
                (sources (gdev-taxonomy--sources entry))
                (sound (and sources (cl-every (lambda (source) (eq t (alist-get 'verified source))) sources))))
           (push `((id . ,name) (edition . ,(plist-get entry :edizione))
                   (title . ,(plist-get entry :titolo)) (source . ,(plist-get entry :fonte))
                   (reuse . ,(symbol-name (plist-get entry :classe-riuso)))
                   (scope . ,(or (alist-get 'index_scope imported) (pcase name ("owasp-asvs" "Requisiti della fonte ASVS CSV 5.0.0")
                               ("nist-sp-800-218" "Pratiche e compiti della tabella SSDF 1.1")
                               (_ "Riferimenti verificati disponibili localmente"))))
                   (index_status . ,(cond ((and complete sound) "COMPLETE_WITHIN_SCOPE")
                                         (nodes "PARTIAL") (t "BIBLIOGRAPHIC")))
                   (requirements_status . ,(if (and requirements-complete sound) "EXTRACTED_WITHIN_SCOPE" "TO_INTEGRATE"))
                   (implementation_status . "NOT_ASSESSED")
                   (missing . ,(or (alist-get 'missing imported) (if complete []
                                 ["Integrare e revisionare struttura e obblighi non rappresentati dalle fonti locali."])))
                   (sources . ,(vconcat sources)) (nodes . ,(vconcat nodes))
                   (node_count . ,(length nodes))
                   (requirement_count . ,(seq-count (lambda (node) (equal "requirement" (alist-get 'kind node))) nodes))) result)))
       `((schema_version . 1) (taxonomies . ,(vconcat (nreverse result))) (certification . :false))))))

(defun gdev-taxonomy-digest ()
  "Fissa registro, conversioni e byte delle fonti della richiesta corrente."
  (gdev-evidence-sha256 (decode-coding-string (json-serialize (gdev-taxonomy-data)) 'utf-8-unix)))

(provide 'gdev-taxonomy)
;;; gdev-taxonomy.el ends here
