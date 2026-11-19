;;; gdev-project-store.el --- Istantanee di progetto e controlli di passaggio -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il manifesto resta versionato fra i sorgenti. Le registrazioni fissano
;; il contesto verificato e impediscono il riuso silenzioso di prove scadute.
;;; Code:
(require 'gdev-project)

(declare-function gdev-procedures-verified-p "gdev-procedures" (db tx-id root data &optional digest))
(declare-function gdev-procedures-verification "gdev-procedures" (db tx-id root project &optional digest))
(declare-function gdev-work-problem "gdev-work" (db tx-id root stage))
(declare-function gdev-work-record-validate "gdev-work" (data))
(declare-function gdev-controls-load "gdev-controls" ())
(declare-function gdev-controls-profile "gdev-controls" (data profile))
(declare-function gdev-project-snippet-preview "gdev-project-templates" (root id arguments))
(declare-function gdev-project-write-file "gdev-project-templates" (root path content &optional expected))

(defun gdev-project-store-root (db)
  "Ricava la radice di progetto dal file principale di DB."
  (let* ((file (nth 2 (cl-find "main" (sqlite-select db "pragma database_list") :key #'cadr :test #'equal)))
         (root (and file (expand-file-name "../../../" file))))
    (unless root (gdev-process-refuse "Archivio di progetto senza file principale"))
    (gdev-trace-root db root)))

(defun gdev-project-context (root &optional data)
  "Fissa manifesto, fonti, tassonomie e interprete del progetto ROOT."
  (let* ((data (or data (gdev-project-read root)))
         (inputs (gdev-project-inputs root data))
         (inventory (gdev-project-source-inventory root data))
         (engines (mapcar (lambda (name)
                            (let* ((library (or (locate-library name)
                                                (when (equal name "gdev-lavorazione")
                                                  (expand-file-name "../modules/ui/workbench/gdev-lavorazione.el"
                                                                    (file-name-directory (locate-library "gdev-project"))))))
                                   (source (and library (concat (file-name-sans-extension library) ".el")))
                                   (file (if (and source (file-regular-p source)) source library)))
                              (cons (intern name) (and file (gdev-evidence-file-sha256 file)))))
                          '("gdev-project" "gdev-graph" "gdev-modules" "gdev-auto-modules" "gdev-handlers" "gdev-language-modes" "gdev-launch" "gdev-xcode" "gdev-project-store" "gdev-procedures" "gdev-taxonomy" "gdev-project-templates" "gdev-project-report" "gdev-formal" "gdev-work"
                            "gdev-lavorazione" "gdev-assurance-db" "gdev-records" "gdev-process" "gdev-policy" "gdev-gates"
                            "gdev-assurance-git" "gdev-assessment" "gdev-evidence" "gdev-trace" "gdev-standard-assessment" "gdev-documents" "gdev-controls" "gdev-standards"))))
    `((project . ,(plist-get data :id)) (inputs . ,inputs)
      (taxonomy . ,(gdev-taxonomy-digest))
      (rules . ,(vconcat (mapcar (lambda (path)
                                   (let ((file (expand-file-name path gdev-standards-directory)))
                                     `((path . ,path) (sha256 . ,(if (file-regular-p file) (gdev-evidence-file-sha256 file) :null)))))
                                 '("profili/controlli.eld" "profili/profili.eld" "standard/attuazione.eld"))))
      (source_count . ,(length inventory))
      (source_digest . ,(gdev-evidence-sha256 (decode-coding-string (json-serialize inventory) 'utf-8-unix)))
      (engines . ,(vconcat (mapcar (lambda (entry) `((name . ,(symbol-name (car entry)))
                                                    (sha256 . ,(or (cdr entry) :null)))) engines))))))

(defun gdev-project-context-digest (context)
  "Impronta canonica del CONTEXT di verifica, anche oltre 128 KiB."
  (gdev-evidence-sha256 (gdev-record-encode context)))

(defun gdev-project-store--validate (_db _tx data)
  "Valida DATA di una registrazione di progetto."
  (cond
   ((equal "work" (alist-get 'operation data))
    (require 'gdev-work) (gdev-work-record-validate data))
   ((equal "snippet" (alist-get 'operation data))
    (gdev-project-store--snippet-validate data))
   (t
    (gdev-record-fields data '(version operation context context_digest definition))
    (unless (and (eq 1 (alist-get 'version data)) (equal "snapshot" (alist-get 'operation data))
                 (equal (alist-get 'context_digest data) (gdev-project-context-digest (alist-get 'context data))))
      (gdev-process-refuse "Istantanea di progetto non valida")))))

(defun gdev-project-store--snippet-validate (data)
  "Valida la registrazione immutabile di un modello applicato DATA."
  (gdev-record-fields data '(version operation effect))
  (let* ((effect (alist-get 'effect data)) (parameters (alist-get 'parameters effect)))
    (gdev-record-fields effect '(snippet version template template_sha256 parameters sha256 status path))
    (unless (and (eq 1 (alist-get 'version data))
                 (gdev-project--id-p (alist-get 'snippet effect))
                 (integerp (alist-get 'version effect)) (> (alist-get 'version effect) 0)
                 (gdev-trace-relative-p (alist-get 'template effect))
                 (gdev-project-output-p (alist-get 'path effect))
                 (equal "MATERIALIZED" (alist-get 'status effect))
                 (cl-every (lambda (key) (let ((value (alist-get key effect)))
                                          (and (stringp value) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" value))))
                           '(template_sha256 sha256))
                 (vectorp parameters)
                 (seq-every-p (lambda (row) (gdev-record-fields row '(name value))
                                (and (gdev-project--text-p (alist-get 'name row)) (stringp (alist-get 'value row)))) parameters)
                 (= (length parameters) (length (delete-dups (mapcar (lambda (row) (alist-get 'name row)) (append parameters nil))))))
      (gdev-process-refuse "Applicazione del modello non valida"))))

(cl-defun gdev-project-snippet-apply (db tx-id root id arguments path &key actor actor-kind)
  "Applica ID con ARGUMENTS in PATH e archivia parametri e impronte per TX-ID.
Le regole SQL precedono gli effetti. Un errore SQL successivo alla scrittura
lascia il file da riconciliare; ripetere lo stesso contenuto è idempotente."
  (gdev-trace-root db root)
  (gdev-process-check-actor actor actor-kind)
  (require 'gdev-project-templates)
  (let* ((preview (gdev-project-snippet-preview root id arguments))
         (effect (append (assq-delete-all 'content (copy-tree preview)) (list (cons 'path path))))
         (_ (setf (alist-get 'status effect) "MATERIALIZED"))
         (data `((version . 1) (operation . "snippet") (effect . ,effect))))
    (gdev-record-json data)
    (gdev-process-attempt
     db 'record tx-id nil actor actor-kind (list :record-kind 'project :data data)
     (lambda (_tx)
       (gdev-project-write-file root path (alist-get 'content preview))
       (gdev-record-add db tx-id 'project data :actor actor :actor-kind actor-kind)))))

(defun gdev-project-snapshots (db tx-id)
  "Leggi le sole istantanee di progetto di TX-ID in DB."
  (seq-filter (lambda (row) (equal "snapshot" (alist-get 'operation (gdev-record-data row))))
              (gdev-record-list db tx-id 'project)))

(gdev-record-register 'project #'gdev-project-store--validate)

(cl-defun gdev-project-bind (db tx-id root &key actor actor-kind)
  "Lega la definizione corrente di ROOT a TX-ID in DB con ACTOR."
  (gdev-trace-root db root)
  (let* ((data (gdev-project-read root)) (context (gdev-project-context root data)))
    (gdev-record-add db tx-id 'project
                     `((version . 1) (operation . "snapshot") (context . ,context)
                       (context_digest . ,(gdev-project-context-digest context)) (definition . ,(gdev-project-json data)))
                     :actor actor :actor-kind actor-kind)))

(defun gdev-project-ready-p (stage defined fresh verified)
  "Decidi il passaggio STAGE dai fatti DEFINED, FRESH e VERIFIED.
La revisione e le chiusure richiedono tutte le condizioni; l'analisi
richiede una definizione completa. I passaggi di recupero restano liberi."
  (cond ((memq stage '(REVIEWING APPROVED BASELINED)) (and defined fresh verified t))
        ((memq stage '(ANALYZED AUTHORIZED IMPLEMENTING VERIFYING)) (and defined t))
        (t t)))

(defun gdev-project-profile-p (actual required)
  "Accetta ACTUAL soltanto se è REQUIRED o ne eredita il rigore."
  (require 'gdev-controls)
  (let ((data (gdev-controls-load)))
    (cl-labels ((inherits (profile)
                  (or (eq profile required)
                      (seq-some #'inherits (plist-get (gdev-controls-profile data profile) :eredita)))))
      (inherits actual))))

(defun gdev-project-transition-rule (context)
  "Verifica il progetto formale prima del passaggio descritto da CONTEXT."
  (let* ((db (plist-get context :db)) (root (gdev-project-store-root db))
         (id (alist-get 'id (plist-get context :tx))) (stage (plist-get context :target))
         (snapshots (gdev-project-snapshots db id))
         (file (expand-file-name gdev-project-manifest root)))
    (when (and (memq stage '(ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED))
               (or snapshots (file-exists-p file)))
      (condition-case err
          (let* ((data (gdev-project-read root))
                 (problems (append (unless (gdev-project-profile-p (alist-get 'profile (plist-get context :tx)) (plist-get data :profile))
                                     (list "Il profilo della lavorazione è meno rigoroso di quello del progetto"))
                                   (gdev-project-problems root data stage)))
                 (current (gdev-project-context-digest (gdev-project-context root data)))
                 (fresh (and snapshots (equal current (alist-get 'context_digest (gdev-record-data (car (last snapshots))))))))
            (cond
             ((not (memq stage '(ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED))) nil)
             (problems (format "Progetto incompleto: %s" (car problems)))
             ((progn (require 'gdev-work) (gdev-work-problem db id root stage)))
             ((null snapshots) "Collega la definizione del progetto alla transazione")
             ((and (memq stage '(REVIEWING APPROVED BASELINED)) (not fresh))
              "Definizione o sorgenti cambiate: registra una nuova istantanea e ripeti le verifiche")
             ((memq stage '(REVIEWING APPROVED BASELINED))
              (require 'gdev-procedures)
              (unless (gdev-project-ready-p stage (null problems) fresh
                                            (gdev-procedures-verified-p db id root data current))
                "Esegui con successo le procedure dei requisiti sulla definizione corrente"))))
        (error (format "Definizione del progetto non verificabile: %s" (error-message-string err)))))))

(defun gdev-project-assessment-context (db)
  "Leggi una volta la definizione e le impronte del progetto formale di DB."
  (when (>= (gdev-assurance-db-version db) 7)
    (let ((root (gdev-project-store-root db)))
      (when (or (file-exists-p (expand-file-name gdev-project-manifest root))
                (gdev-record-list db nil 'project))
        (condition-case err
            (let* ((data (gdev-project-read root)) (context (gdev-project-context root data)))
              (list :root root :data data :digest (gdev-project-context-digest context)))
          (error (list :root root :error (error-message-string err))))))))

(defun gdev-project-assessment (db tx-id context)
  "Valuta definizione, istantanea e prove di TX-ID sul CONTEXT già letto."
  (when context
    (require 'gdev-procedures)
    (let* ((data (plist-get context :data)) (root (plist-get context :root))
           (digest (plist-get context :digest))
           (state (alist-get 'state (gdev-process-get db tx-id)))
           (closing (memq state '(REVIEWING APPROVED BASELINED)))
           (problems (or (and (plist-get context :error) (list (plist-get context :error)))
                         (append (unless (gdev-project-profile-p (alist-get 'profile (gdev-process-get db tx-id)) (plist-get data :profile))
                                   (list "Profilo della lavorazione incompatibile con il progetto"))
                                 (gdev-project-problems root data state))))
           (snapshots (gdev-project-snapshots db tx-id))
           (fresh (and digest snapshots
                       (equal digest (alist-get 'context_digest (gdev-record-data (car (last snapshots)))))))
           (verified (and data (gdev-procedures-verified-p db tx-id root data digest))))
      `((context_digest . ,(or digest :null))
        (results . ,(vconcat
                     (mapcar
                      (lambda (spec)
                        `((control . ,(nth 0 spec)) (title . ,(nth 1 spec)) (decidable . t)
                          (status . ,(if (nth 2 spec) "SATISFIED" (if (nth 3 spec) "NOT_SATISFIED" "NOT_VERIFIED")))
                          (due . ,(if (nth 3 spec) t :false)) (reason . ,(nth 4 spec))
                          (events . []) (evidence . []) (decisions . []) (references . [])))
                      (list (list "PROJECT-DEFINITION" "Definizione formale del progetto" (null problems)
                                  (memq state '(ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED))
                                  (or (car problems) "Campi e riferimenti compilati"))
                            (list "PROJECT-SNAPSHOT" "Istantanea corrente del progetto" fresh closing
                                  (if fresh "Definizione e sorgenti corrispondono all'istantanea"
                                    "Collega nuovamente la definizione e ripeti le prove"))
                            (list "PROJECT-VERIFICATION" "Requisiti e artefatti verificati" verified closing
                                  (if verified "Procedure e controlli superati nel ciclo corrente"
                                    "Esegui le procedure richieste e controlla le uscite"))))))
        (requirements . ,(if data (gdev-procedures-verification db tx-id root data digest) []))
        (human_approval . "NOT_VERIFIED")))))

(provide 'gdev-project-store)
;;; gdev-project-store.el ends here
