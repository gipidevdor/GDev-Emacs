;;; gdev-project-workbench.el --- Progetti, tassonomie e procedure nel Workbench -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Estende la vista di assicurazione: stessa modalità, chiusura, selezione
;; e servizi di scrittura. Il ridisegno usa soltanto i dati già letti.
;;; Code:
(require 'gdev-project-templates)
(declare-function gdev-assurance-data "gdev-assurance" (command root &optional argument limit))
(declare-function gdev-ui-view-setup "gdev-ui" (profile))
(declare-function gdev-layout-mark-document "gdev-layout" ())

(defvar gdev-assurance--root)
(defvar gdev-assurance--model)
(defvar gdev-assurance--standard)
(defvar gdev-assurance--notice)
(declare-function gdev-assurance-show "gdev-assurance-workbench" (&optional root))
(declare-function gdev-assurance-section "gdev-assurance-workbench" (&optional section))
(declare-function gdev-assurance-refresh "gdev-assurance-workbench" ())
(declare-function gdev-assurance-visit "gdev-assurance-workbench" (file))
(declare-function gdev-assurance--button "gdev-assurance-workbench" (label command identity &optional help))
(declare-function gdev-assurance--row "gdev-assurance-workbench" (identity title text &optional command))
(declare-function gdev-assurance--entries "gdev-assurance-workbench" (rows identity render))
(declare-function gdev-assurance--actions "gdev-assurance-workbench" (actions))
(declare-function gdev-assurance--context "gdev-assurance-interactive" (&optional transaction))
(declare-function gdev-assurance--write "gdev-assurance-interactive" (context command operands))
(declare-function gdev-assurance--check-context "gdev-assurance-interactive" (context))
(declare-function gdev-assurance--background "gdev-assurance-interactive" (context command operands label))

(defconst gdev-assurance--project-labels
  '(("draft" . "Bozza") ("proposed" . "Proposto") ("accepted" . "Accettato")
    ("functional" . "Funzione") ("quality" . "Qualità") ("security" . "Sicurezza")
    ("data" . "Dati") ("interface" . "Interfaccia") ("performance" . "Prestazioni")
    ("compatibility" . "Compatibilità") ("usability" . "Usabilità") ("process" . "Processo") ("release" . "Rilascio")
    ("implementation" . "Produzione") ("verification" . "Verifica") ("test" . "Test") ("analysis" . "Analisi") ("review" . "Revisione") ("model-check" . "Modello finito")
    ("RUNNING" . "In corso") ("SUCCEEDED" . "Riuscita") ("FAILED" . "Fallita") ("CANCELLED" . "Annullata")
    ("COMPLETE_WITHIN_SCOPE" . "Completo nel perimetro indicato") ("PARTIAL" . "Parziale")
    ("BIBLIOGRAPHIC" . "Scheda bibliografica") ("EXTRACTED_WITHIN_SCOPE" . "Estratti nel perimetro indicato")
    ("TO_INTEGRATE" . "Da integrare") ("chapter" . "Capitolo") ("section" . "Sezione")
    ("requirement" . "Requisito") ("reference" . "Riferimento") ("group" . "Gruppo")
    ("practice" . "Pratica") ("recommendation" . "Raccomandazione") ("obligation-candidate" . "Obbligo da revisionare")))

(defun gdev-assurance--project-label (value)
  "Rendi leggibile VALUE conservando gli identificativi nelle API."
  (if (or (null value) (eq value :null)) "Da compilare"
    (or (cdr (assoc value gdev-assurance--project-labels)) value)))

(defun gdev-assurance-project ()
  "Apri requisiti e compilazione del progetto formale."
  (interactive) (gdev-assurance-section 'project))

(defun gdev-assurance-project-new ()
  "Prepara una bozza con cataloghi versionati e default proposti."
  (interactive)
  (let* ((context (gdev-assurance--context)) (id (read-string "Identificativo del progetto: "))
         (name (read-string "Nome del progetto: ")))
    (gdev-assurance--write context "project-init" (list id name))
    (gdev-assurance-section 'project)))

(defun gdev-assurance-project-edit ()
  "Apri la definizione autorevole del progetto nell'editor."
  (interactive)
  (let ((context (gdev-assurance--context)))
    (gdev-assurance-visit (gdev-project-file (plist-get context :root) gdev-project-manifest))))

(defun gdev-assurance-project-fill ()
  "Compila un campo richiesto conservando la versione esaminata."
  (interactive)
  (let* ((context (gdev-assurance--context)) (root (plist-get context :root))
         (data (gdev-project-read root))
         (hash (gdev-evidence-file-sha256 (gdev-project-file root gdev-project-manifest)))
         (choices (mapcar (lambda (field) (cons (nth 1 field) (car field))) gdev-project-required-fields))
         (choice (completing-read "Campo da compilare: " choices nil t))
         (key (cdr (assoc choice choices))) (value (read-string (concat choice ": ") (plist-get data key))))
    (gdev-assurance--write context "project-field" (list (substring (symbol-name key) 1) value hash))))

(defun gdev-assurance-project-bind ()
  "Collega la definizione e le fonti correnti alla transazione scelta."
  (interactive)
  (let ((context (gdev-assurance--context t)))
    (gdev-assurance--write context "project-bind" (list (plist-get context :id)))))

(defun gdev-assurance-requirement-new ()
  "Raccogli un requisito completo e salvalo come proposta da esaminare."
  (interactive)
  (let* ((context (gdev-assurance--context)) (root (plist-get context :root))
         (data (gdev-project-read root))
         (hash (gdev-evidence-file-sha256 (gdev-project-file root gdev-project-manifest)))
         (id (read-string "Identificativo del requisito: " "REQ-"))
         (arguments (list
                     (cons "statement" (read-string "Comportamento richiesto: "))
                     (cons "acceptance" (read-string "Criterio di accettazione: "))
                     (cons "owner" (read-string "Responsabile: " (plist-get data :owner)))
                     (cons "origin" (read-string "Origine della richiesta: "))
                     (cons "rationale" (read-string "Motivazione: "))
                     (cons "source" (file-relative-name (read-file-name "Sorgente interessato: " root nil t) root))
                     (cons "tests" (read-string "Controlli richiesti, separati da virgole: "))
                     (cons "method" (completing-read "Metodo: " (mapcar #'symbol-name gdev-project-methods) nil t nil nil "test"))
                     (cons "procedure" (completing-read "Procedura: " (mapcar (lambda (row) (plist-get row :id)) (plist-get data :procedures)) nil t)))))
    (gdev-assurance--write context "project-requirement"
                           (list id (gdev-record-encode (mapcar (lambda (pair) (cons (intern (car pair)) (cdr pair))) arguments)) hash))))

(defun gdev-assurance-work-bind ()
  "Collega una scheda operativa salvata alla transazione scelta."
  (interactive)
  (let* ((context (gdev-assurance--context t)) (root (plist-get context :root))
         (path (file-relative-name (read-file-name "Scheda della lavorazione (.eld): " root nil t) root)))
    (gdev-assurance--write context "work-bind" (list (plist-get context :id) path))))

(defun gdev-assurance-snippet ()
  "Cerca un modello, raccogli i parametri e mostra l'anteprima."
  (interactive)
  (let* ((context (gdev-assurance--context t)) (root (plist-get context :root))
         (data (gdev-project-read root))
         (choices (mapcar (lambda (row) (cons (format "%s · %s · %s" (plist-get row :id) (plist-get row :description) (plist-get row :language)) row))
                           (plist-get data :snippets)))
         (snippet (cdr (assoc (completing-read "Modello: " choices nil t) choices)))
         (id (plist-get snippet :id))
         (arguments (mapcar (lambda (parameter)
                              (cons (plist-get parameter :name)
                                    (read-string (concat (plist-get parameter :reason) " ") (plist-get parameter :default))))
                            (plist-get snippet :parameters)))
         (preview (gdev-project-snippet-preview root id arguments))
         (json (if arguments (gdev-record-encode (mapcar (lambda (pair) (cons (intern (car pair)) (cdr pair))) arguments)) "{}"))
         (buffer (generate-new-buffer (concat "*Modello · " id "*"))))
    (gdev-assurance--check-context context)
    (with-current-buffer buffer
      (insert (format "%s · versione %s\n\n" id (alist-get 'version preview)))
      (insert-text-button "Crea file e registra…" 'follow-link t
                          'action (lambda (_)
                                    (let ((path (file-relative-name (read-file-name "Nuovo file: " root) root)))
                                      (gdev-assurance--write context "snippet-write" (list (plist-get context :id) id path json))
                                      (let ((enable-local-eval nil)) (gdev-assurance-visit (gdev-project-file root path))))))
      (insert "\n\n" (alist-get 'content preview))
      (special-mode) (set-buffer-modified-p nil)
      (gdev-ui-view-setup 'document) (gdev-layout-mark-document) (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun gdev-assurance-taxonomy (&optional id)
  "Apri la tassonomia di ID, oppure l'elenco con copertura e lacune."
  (interactive)
  (unless (derived-mode-p 'gdev-assurance-mode) (gdev-assurance-show))
  (setq gdev-assurance--standard id) (gdev-assurance-section 'taxonomy))

(defun gdev-assurance-procedures ()
  "Apri le procedure versionate del progetto."
  (interactive) (gdev-assurance-section 'procedures))

(defun gdev-assurance-procedure-plan (&optional id)
  "Valida e mostra il piano ID senza eseguirne gli effetti."
  (interactive)
  (let* ((context (gdev-assurance--context))
         (data (gdev-assurance-data "procedures" (plist-get context :root)))
         (id (or id (completing-read "Procedura: " (mapcar (lambda (row) (alist-get 'id row)) (alist-get 'procedures data)) nil t)))
         (plan (gdev-assurance-data "procedure-plan" (plist-get context :root) id)))
    (gdev-assurance--check-context context)
    (setq gdev-assurance--notice (format "%s: piano valido, %d passi. Nessun effetto applicato." id
                                         (length (alist-get 'steps (alist-get 'procedure plan)))))
    (gdev-assurance-refresh)))

(defun gdev-assurance-procedure-run (&optional id)
  "Avvia ID in secondo piano, con arresto nelle Operazioni dello spazio."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (data (gdev-assurance-data "procedures" (plist-get context :root)))
         (id (or id (completing-read "Procedura da avviare: "
                                     (mapcar (lambda (row) (alist-get 'id row)) (alist-get 'procedures data)) nil t))))
    (gdev-assurance--background context "procedure-run" (list (plist-get context :id) id) (concat "Procedura " id))))

(defun gdev-assurance-procedure-resume (run)
  "Riprendi RUN della transazione scelta, controllando sorgenti ed effetti."
  (interactive "sEsecuzione da riprendere: ")
  (let ((context (gdev-assurance--context t)))
    (gdev-assurance--background context "procedure-resume" (list (plist-get context :id) run) "Ripresa della procedura")))

(defun gdev-assurance--project ()
  "Disegna requisiti e campi mancanti dal modello già letto."
  (let* ((detail (alist-get 'detail gdev-assurance--model)) (project (alist-get 'project detail)))
    (if (eq project :null)
        (progn (insert "Definisci il progetto per ricevere requisiti, modelli e controlli guidati.\n\n")
               (gdev-assurance--button "Definisci progetto…" #'gdev-assurance-project-new '(project new)))
      (gdev-assurance--actions '(("insert" "+" "Nuovo requisito…" gdev-assurance-requirement-new)
                                 ("file" "≡" "Modelli…" gdev-assurance-snippet)
                                 ("edit" "✎" "Compila campo…" gdev-assurance-project-fill)
                                 ("file" "≡" "Apri definizione" gdev-assurance-project-edit)
                                 ("workflow" "↔" "Collega alla transazione" gdev-assurance-project-bind)))
      (insert "\n" (propertize (format "%s · %s" (alist-get 'id project) (alist-get 'name project)) 'face 'gdev-ui-view-heading) "\n")
      (insert (format "Profilo: %s\n%s\n\n" (gdev-assurance--project-label (alist-get 'profile project))
                      (let ((purpose (alist-get 'purpose project))) (if (stringp purpose) purpose "Scopo da compilare"))))
      (if (> (length (alist-get 'problems detail)) 0)
          (progn (insert (propertize "Da completare\n" 'face 'gdev-ui-status-warning))
                 (seq-doseq (problem (alist-get 'problems detail)) (insert "• " problem "\n")))
        (insert (propertize "Definizione compilata. Le verifiche e le approvazioni restano distinte.\n" 'face 'gdev-ui-secondary)))
      (insert "\n")
      (gdev-assurance--entries
       (append (alist-get 'requirements project) nil) (lambda (row) (list 'requirement (alist-get 'id row)))
       (lambda (row)
         (gdev-assurance--row (list 'requirement (alist-get 'id row)) (alist-get 'id row)
                              (format "%s\n%s · %s · %s\nAccettazione: %s\nVerifica: %s"
                                      (alist-get 'statement row) (gdev-assurance--project-label (alist-get 'status row)) (gdev-assurance--project-label (alist-get 'category row))
                                      (alist-get 'owner row) (alist-get 'acceptance row) (gdev-assurance--project-label (alist-get 'method row)))))))))

(defun gdev-assurance--taxonomy ()
  "Disegna la copertura delle fonti e la gerarchia già acquisita."
  (let* ((data (alist-get 'detail gdev-assurance--model)) (rows (append (alist-get 'taxonomies data) nil)))
    (insert (propertize "Indice, estrazione degli obblighi e attuazione sono verifiche distinte.\n\n" 'face 'gdev-ui-secondary))
    (when gdev-assurance--standard
      (gdev-assurance--button "‹ Tutte le tassonomie" (lambda () (gdev-assurance-taxonomy)) '(taxonomy back))
      (insert "\n\n")
      (dolist (row rows)
        (insert (propertize (alist-get 'title row) 'face 'gdev-ui-view-heading) "\n" (alist-get 'scope row) "\n")
        (seq-doseq (missing (alist-get 'missing row)) (insert (propertize missing 'face 'gdev-ui-status-warning) "\n")))
      (insert "\n"))
    (gdev-assurance--entries
     (if gdev-assurance--standard (append (alist-get 'nodes (car rows)) nil) rows)
     (lambda (row) (list 'taxonomy (alist-get 'id row)))
     (lambda (row)
       (let ((id (alist-get 'id row)))
         (if gdev-assurance--standard
             (gdev-assurance--row (list 'taxonomy id) (concat id " · " (alist-get 'title row))
                                  (format "%s · %s\n%s" (gdev-assurance--project-label (alist-get 'kind row)) (alist-get 'locator row)
                                          (let ((text (alist-get 'text row))) (if (stringp text) text ""))))
           (gdev-assurance--row (list 'taxonomy id) (concat id " · " (alist-get 'edition row))
                                (format "%s\nIndice: %s · %d nodi · %d requisiti\nObblighi: %s"
                                        (alist-get 'scope row) (gdev-assurance--project-label (alist-get 'index_status row)) (alist-get 'node_count row)
                                        (alist-get 'requirement_count row) (gdev-assurance--project-label (alist-get 'requirements_status row)))
                                (lambda () (gdev-assurance-taxonomy id)))))))))

(defun gdev-assurance--procedures ()
  "Disegna procedure e passi, con anteprima e avvio separati."
  (gdev-assurance--entries
   (append (alist-get 'procedures (alist-get 'detail gdev-assurance--model)) nil)
   (lambda (row) (list 'procedure (alist-get 'id row)))
   (lambda (row)
     (let ((id (alist-get 'id row)))
       (gdev-assurance--row (list 'procedure id) (format "%s · versione %d" id (alist-get 'version row))
                            (format "%s · %s\n%d passi · Uscite: %s" (alist-get 'title row)
                                    (gdev-assurance--project-label (or (alist-get 'mode row) "verification")) (length (alist-get 'steps row))
                                    (mapconcat #'identity (append (alist-get 'outputs row) nil) ", ")))
       (gdev-assurance--button "Controlla piano" (lambda () (gdev-assurance-procedure-plan id)) (list 'procedure-plan id))
       (insert "   ")
       (gdev-assurance--button "Avvia…" (lambda () (gdev-assurance-procedure-run id)) (list 'procedure-run id))
       (insert "\n")))))

(defun gdev-assurance--runs ()
  "Mostra gli ultimi esiti per esecuzione senza nascondere il giornale."
  (let ((latest (make-hash-table :test #'equal)) rows)
    (seq-doseq (row (alist-get 'runs (alist-get 'detail gdev-assurance--model)))
      (puthash (alist-get 'run_id (alist-get 'data row)) row latest))
    (maphash (lambda (_ row) (push row rows)) latest)
    (gdev-assurance--entries
     (sort rows (lambda (a b) (> (alist-get 'record_id a) (alist-get 'record_id b))))
     (lambda (row) (list 'run (alist-get 'run_id (alist-get 'data row))))
     (lambda (row)
       (let* ((data (alist-get 'data row)) (id (alist-get 'run_id data)))
         (gdev-assurance--row (list 'run id) id
                              (format "%s · %s\n%s" (gdev-assurance--project-label (alist-get 'status data)) (alist-get 'transaction row)
                                      (let ((detail (alist-get 'detail data))) (if (stringp detail) detail "Giornale e impronte conservati nell'audit."))))
         (when (member (alist-get 'status data) '("FAILED" "CANCELLED" "RUNNING"))
           (gdev-assurance--button "Riprendi…" (lambda () (gdev-assurance-procedure-resume id)) (list 'resume id))
           (insert "\n")))))))

(provide 'gdev-project-workbench)
;;; gdev-project-workbench.el ends here
