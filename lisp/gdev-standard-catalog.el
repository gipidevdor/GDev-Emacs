;;; gdev-standard-catalog.el --- Obiettivi verificabili degli standard -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; La scheda bibliografica non è un indice di clausole. Per un testo protetto
;; senza indice pubblico si offre solo un obiettivo documentale dichiarato.
;; I controlli sono originali GDev, le verifiche normative restano dell'operatore.
;;; Code:
(require 'gdev-standards)
(require 'gdev-records)
(require 'gdev-trace)

(defconst gdev-standard-catalog-note
  "Controlli originali GDev e prove dichiarate; non certificano conformità, livelli SLSA o capacità ISO.")

(defun gdev-standard-catalog-policies ()
  "Leggi i criteri originali GDev, verificando tipi e riferimenti."
  (let ((policies (gdev-standards-read (expand-file-name "standard/attuazione.eld" gdev-standards-directory))) seen)
    (unless (proper-list-p policies) (signal 'gdev-standards-error '("Criteri degli standard non validi")))
    (dolist (policy policies)
      (let ((id (and (plistp policy) (plist-get policy :standard))))
        (unless (and (stringp id) (gdev-standards-get id) (not (member id seen))
                     (memq (plist-get policy :scope) '(documento clausola))
                     (proper-list-p (plist-get policy :roles))
                     (cl-every (lambda (role) (memq role gdev-trace-roles)) (plist-get policy :roles))
                     (proper-list-p (plist-get policy :trace))
                     (cl-every (lambda (edge)
                                 (and (proper-list-p edge) (= (length edge) 3)
                                      (memq (nth 0 edge) gdev-trace-roles)
                                      (memq (nth 1 edge) gdev-trace-relations)
                                      (memq (nth 2 edge) gdev-trace-roles))) (plist-get policy :trace))
                     (memq (plist-get policy :due) '(nil REVIEWING APPROVED BASELINED))
                     (memq (plist-get policy :proof-state) '(nil VERIFYING REVIEWING))
                     (cl-every (lambda (key) (memq (plist-get policy key) '(nil t)))
                               '(:human :independent :assessment)))
          (signal 'gdev-standards-error (list (format "Criterio di attuazione non valido: %S" id))))
        (push id seen)))
    policies))

(defun gdev-standard-catalog--targets (id)
  "Materializza i controlli GDev verificati per ID."
  (gdev-standards-with-cache
   (lambda ()
     (let* ((entry (or (gdev-standards-get id) (user-error "Standard sconosciuto: %s" id)))
            (policy (seq-find (lambda (item) (equal id (plist-get item :standard)))
                              (gdev-standard-catalog-policies)))
            (scope (plist-get policy :scope))
            (clauses (if (eq scope 'documento) '("@document") (and policy (gdev-standards-clauses id))))
            (definition (let ((print-length nil) (print-level nil))
                          (gdev-evidence-sha256
                           (prin1-to-string (list "GES-standards-1" entry policy
                                                  (gdev-standards-data id) clauses))))))
       (when (and policy clauses (eq (plist-get entry :stato) 'corrente))
         (mapcar
          (lambda (clause)
            (list :standard id :edition (plist-get entry :edizione) :clause clause :scope scope
                  :control (concat "STD-" id ":" clause)
                  :title (format "Verifica GDev · %s · %s" id (if (eq scope 'documento) "documento" clause))
                  :digest definition :source (plist-get entry :fonte)
                  :due (or (plist-get policy :due) 'REVIEWING)
                  :proof-state (or (plist-get policy :proof-state) 'VERIFYING)
                  :roles (plist-get policy :roles) :trace (plist-get policy :trace)
                  :human (plist-get policy :human) :independent (plist-get policy :independent)
                  :assessment (plist-get policy :assessment))) clauses))))))

(defun gdev-standard-catalog-targets (id)
  "Leggi gli obiettivi di ID condividendoli entro una sola richiesta."
  (gdev-standards-with-cache
   (lambda ()
     (let* ((key (concat "targets:" id)) (found (gethash key gdev-standards--cache)))
       (if found (car found)
         (let ((targets (gdev-standard-catalog--targets id)))
           (puthash key (list targets) gdev-standards--cache) targets))))))

(defun gdev-standard-catalog-resolve (specification)
  "Risolvi SPECIFICATION, ID oppure ID#CLAUSOLA, se verificato."
  (gdev-process-check-line "L'obiettivo dello standard" specification 200)
  (let* ((parts (split-string specification "#")) (id (car parts))
         (all (gdev-standard-catalog-targets id))
         (selected (if (= (length parts) 1) all
                     (and (= (length parts) 2)
                          (seq-filter (lambda (target) (equal (cadr parts) (plist-get target :clause))) all)))))
    (unless selected (gdev-process-refuse "Nessun obiettivo verificato per %s" specification))
    selected))

(defun gdev-standard-catalog-definition (target)
  "Rendi TARGET una definizione JSON archiviabile, senza testo normativo."
  `((id . ,(plist-get target :standard)) (edition . ,(plist-get target :edition))
    (digest . ,(plist-get target :digest)) (scope . ,(symbol-name (plist-get target :scope)))
    (due . ,(symbol-name (plist-get target :due))) (proof_state . ,(symbol-name (plist-get target :proof-state)))
    (roles . ,(vconcat (mapcar #'symbol-name (plist-get target :roles))))
    (trace . ,(vconcat (mapcar (lambda (edge) (vconcat (mapcar #'symbol-name edge))) (plist-get target :trace))))
    (human . ,(if (plist-get target :human) t :false))
    (independent . ,(if (plist-get target :independent) t :false))
    (assessment . ,(if (plist-get target :assessment) t :false))))

(defun gdev-standard-catalog-data (&optional id)
  "Restituisci il catalogo o gli obiettivi di ID, senza archivio."
  (gdev-standards-with-cache
   (lambda ()
     (let ((entries (if id (list (or (gdev-standards-get id) (user-error "Standard sconosciuto: %s" id)))
                      (gdev-standards-all))) rows)
       (dolist (entry entries)
         (let* ((name (plist-get entry :id)) (targets (gdev-standard-catalog-targets name))
                (scope (plist-get (car targets) :scope)))
           (push `((id . ,name) (title . ,(plist-get entry :titolo))
                   (edition . ,(plist-get entry :edizione)) (status . ,(symbol-name (plist-get entry :stato)))
                   (reuse . ,(symbol-name (plist-get entry :classe-riuso))) (source . ,(plist-get entry :fonte))
                   (selectable . ,(if targets t :false)) (target_count . ,(length targets))
                   (scope . ,(if scope (symbol-name scope) "unavailable"))
                   (targets . ,(if id
                                   (vconcat (mapcar (lambda (target)
                                                     `((target . ,(concat name "#" (plist-get target :clause)))
                                                       (control . ,(plist-get target :control))
                                                       (due . ,(symbol-name (plist-get target :due)))
                                                       (proof_state . ,(symbol-name (plist-get target :proof-state)))
                                                       (definition . ,(gdev-standard-catalog-definition target))
                                                       (definition_digest . ,(plist-get target :digest)))) targets)) []))) rows)))
       `((standards . ,(vconcat (nreverse rows))) (note . ,gdev-standard-catalog-note))))))

(provide 'gdev-standard-catalog)
;;; gdev-standard-catalog.el ends here
