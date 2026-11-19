;;; gdev-procedures.el --- Procedure versionate con giornale e ripresa -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Ogni passo è un piano .lavorazione eseguito dal motore ordinario.
;; Il giornale SQL precede gli effetti: un passo interrotto con effetti non
;; ripetibili richiede riconciliazione. Le esecuzioni passate restano immutabili.
;;; Code:
(require 'gdev-project-store)
(require 'gdev-project-templates)
(require 'gdev-work)

(declare-function gdev-lavorazione-run-file "gdev-lavorazione" (file root &optional check))
(declare-function gdev-lavorazione-run-text "gdev-lavorazione" (text root &optional check))
(declare-function gdev-lavorazione-registra "gdev-lavorazione" (name description schema function &rest keys))
(declare-function gdev-lavorazione-radice "gdev-lavorazione" (context))
(declare-function gdev-formal-check "gdev-formal" ())
(declare-function gdev-documents-generate "gdev-documents" (root &optional check))
(declare-function gdev-project-report "gdev-project-report" (root &optional check))

(defvar gdev-procedures--checks nil)
(defvar gdev-procedures--effects nil)
(defvar gdev-procedures--log-file nil)
(defvar gdev-procedures--stage nil)
(defvar gdev-project-report-path)
(defvar gdev-procedures--cancel-function nil
  "Predicato opzionale di annullamento, consultato fra passi e attese.")

(defun gdev-procedures--definition (data id)
  "Trova la procedura ID in DATA."
  (or (seq-find (lambda (row) (equal id (plist-get row :id))) (plist-get data :procedures))
      (gdev-process-refuse "Procedura sconosciuta: %s" id)))

(defun gdev-procedures--engine ()
  "Carica a richiesta il motore e registra le azioni di dominio."
  (unless (fboundp 'gdev-lavorazione-run-file)
    (let ((load-path (cons (expand-file-name "../modules/ui/workbench/" (file-name-directory (locate-library "gdev-procedures"))) load-path)))
      (require 'gdev-lavorazione)))
  (gdev-procedures-register-actions))

(defun gdev-procedures-plan (root id)
  "Valida tutti i piani della procedura ID di ROOT senza eseguirli."
  (let* ((data (gdev-project-read root)) (procedure (gdev-procedures--definition data id)))
    (gdev-procedures--engine)
    (let (produced)
      (dolist (step (plist-get procedure :steps))
        (dolist (input (plist-get step :inputs))
          (when (and (not (eq 'implementation (plist-get procedure :mode)))
                     (member input (gdev-project-output-paths data)))
            (gdev-process-refuse "Separa produzione e verifica di %s con una nuova istantanea" input))
          (unless (or (member input produced) (file-regular-p (gdev-project-file root input)))
            (gdev-process-refuse "Input del passo %s assente: %s" (plist-get step :id) input)))
        (gdev-lavorazione-run-file (gdev-project-file root (plist-get step :plan)) root t)
        (setq produced (append produced (plist-get step :outputs)))))
    `((procedure . ,(gdev-project-json procedure)) (status . "PLANNED")
      (effects_applied . :false) (inputs . ,(gdev-project-inputs root data)))))

(defun gdev-procedures--rows (db tx-id &optional run)
  "Leggi il giornale di TX-ID in DB, filtrando RUN se indicato."
  (seq-filter (lambda (row) (or (null run) (equal run (alist-get 'run_id (gdev-record-data row)))))
              (gdev-record-list db tx-id 'run)))

(defun gdev-procedures--validate (db tx data)
  "Valida DATA del giornale nella transazione TX di DB."
  (gdev-record-fields data '(version event run_id status) '(start procedure context context_digest step detail outputs checks effects plans tools log work_ref work_inputs inputs context_after))
  (unless (and (eq 1 (alist-get 'version data)) (gdev-project--id-p (alist-get 'run_id data))
               (pcase (alist-get 'event data)
                 ((or "start" "resume") (equal "RUNNING" (alist-get 'status data)))
                 ("step" (member (alist-get 'status data) '("RUNNING" "SUCCEEDED" "FAILED")))
                 ("finish" (member (alist-get 'status data) '("SUCCEEDED" "FAILED" "CANCELLED")))))
    (gdev-process-refuse "Versione, evento o stato del giornale non validi"))
  (unless (and (eq 1 (alist-get 'version data)) (gdev-project--id-p (alist-get 'run_id data))
               (member (alist-get 'event data) '("start" "step" "finish" "resume"))
               (member (alist-get 'status data) '("RUNNING" "SUCCEEDED" "FAILED" "CANCELLED")))
    (gdev-process-refuse "Evento di esecuzione non valido"))
  (if (equal "start" (alist-get 'event data))
      (unless (and (equal "RUNNING" (alist-get 'status data))
                   (alist-get 'procedure data) (alist-get 'context data)
                   (vectorp (alist-get 'plans data))
                   (= (length (alist-get 'plans data)) (length (alist-get 'steps (alist-get 'procedure data))))
                   (equal (alist-get 'context_digest data) (gdev-project-context-digest (alist-get 'context data))))
        (gdev-process-refuse "Avvio della procedura incompleto"))
    (let* ((start (gdev-record-get db (alist-get 'start data)))
           (original (and start (gdev-record-data start))))
      (unless (and start (eq 'run (alist-get 'kind start))
                   (equal (alist-get 'id tx) (alist-get 'tx_id start))
                   (equal "start" (alist-get 'event original))
                   (equal (alist-get 'run_id data) (alist-get 'run_id original)))
        (gdev-process-refuse "Esecuzione di origine non risolta"))
      (when (equal "step" (alist-get 'event data))
        (unless (and (integerp (alist-get 'step data))
                     (<= 0 (alist-get 'step data))
                     (< (alist-get 'step data) (length (alist-get 'steps (alist-get 'procedure original)))))
          (gdev-process-refuse "Numero di passo fuori dal piano")))))
  (dolist (key '(outputs checks effects inputs))
    (when (assq key data)
      (unless (vectorp (alist-get key data)) (gdev-process-refuse "Elenco %s non valido" key)))))

(defun gdev-procedures--sequence-problem (db tx data &optional before)
  "Controlla la sequenza di DATA usando le righe di TX anteriori a BEFORE."
  (let* ((rows (seq-filter (lambda (row) (or (null before) (< (alist-get 'id row) before)))
                           (gdev-procedures--rows db (alist-get 'id tx) (alist-get 'run_id data))))
         (last (and rows (gdev-record-data (car (last rows)))))
         (event (alist-get 'event data)))
    (cond
     ((equal event "start") (when rows "Identificativo di esecuzione già usato"))
     ((null rows) "Esecuzione senza avvio")
     ((equal event "resume")
      (when (and (equal "finish" (alist-get 'event last)) (equal "SUCCEEDED" (alist-get 'status last)))
        "Un'esecuzione conclusa non si riprende"))
     ((equal "finish" (alist-get 'event last)) "Riprendi esplicitamente l'esecuzione prima di aggiungere eventi")
     ((and (equal event "step") (not (equal "RUNNING" (alist-get 'status data)))
           (not (and (equal "step" (alist-get 'event last))
                     (equal "RUNNING" (alist-get 'status last))
                     (equal (alist-get 'step data) (alist-get 'step last)))))
      "L'esito del passo richiede il suo avvio nel giornale")
     ((and (equal event "finish") (equal "SUCCEEDED" (alist-get 'status data)))
      (let* ((start (gdev-record-data (car rows))) (steps (alist-get 'steps (alist-get 'procedure start))))
        (cl-loop for step across steps for index from 0
                 when (eq t (alist-get 'required step))
                 thereis (let ((found (seq-find (lambda (row)
                                                  (let ((payload (gdev-record-data row)))
                                                    (and (equal "step" (alist-get 'event payload))
                                                         (equal index (alist-get 'step payload))))) (reverse rows))))
                           (unless (and found (equal "SUCCEEDED" (alist-get 'status (gdev-record-data found))))
                             "Manca l'esito positivo di un passo obbligatorio"))))))))

(defun gdev-procedures--rule (context)
  "Applica la sequenza al nuovo evento di CONTEXT."
  (gdev-procedures--sequence-problem (plist-get context :db) (plist-get context :tx) (plist-get context :data)))

(defun gdev-procedures--verify-row (db row)
  "Verifica la sequenza storica di ROW in DB."
  (when-let* ((problem (gdev-procedures--sequence-problem db (gdev-process-get db (alist-get 'tx_id row))
                                                         (gdev-record-data row) (alist-get 'id row))))
    (gdev-process-refuse "%s" problem)))

(gdev-record-register 'run #'gdev-procedures--validate #'gdev-procedures--rule #'gdev-procedures--verify-row)

(defun gdev-procedures--log (root file)
  "Identifica il log FILE effettivamente prodotto sotto ROOT."
  (if (file-regular-p file)
      `((path . ,(file-relative-name file root)) (sha256 . ,(gdev-evidence-file-sha256 file)))
    :null))

(defun gdev-procedures-log-current-p (root log)
  "Controlla LOG soltanto nella cartella dei log di esecuzione posseduta."
  (if (or (null log) (eq log :null)) t
    (let* ((path (alist-get 'path log)) (base (file-name-as-directory (file-truename root)))
           (file (and (stringp path) (expand-file-name path base))))
      (and (stringp path)
           (string-match-p "\\`\\.gdev/assurance/run-logs/RUN-[A-Za-z0-9-]+-[0-9]+\\.log\\'" path)
           (file-in-directory-p (file-truename file) base) (file-regular-p file)
           (equal (alist-get 'sha256 log) (gdev-evidence-file-sha256 file))))))

(defun gdev-procedures--files (root paths)
  "Fissa le uscite PATHS di ROOT, comprese quelle mancanti."
  (vconcat (mapcar (lambda (path) (gdev-project-file-fingerprint root path)) paths)))

(defun gdev-procedures--outputs-current-p (root outputs)
  "Restituisci non nil se OUTPUTS esistono e corrispondono ai byte in ROOT."
  (seq-every-p (lambda (row)
                (let ((current (gdev-project-file-fingerprint root (alist-get 'path row))))
                  (and (not (eq :null (alist-get 'sha256 current)))
                       (cl-every (lambda (key) (or (not (assq key row)) (equal (alist-get key row) (alist-get key current))))
                                 '(sha256 mode git_sha1 git_sha256))
                       (or (not (assq 'target row))
                           (equal (gdev-record-encode `((target . ,(alist-get 'target row))))
                                  (gdev-record-encode `((target . ,(alist-get 'target current))))))))) outputs))

(defun gdev-procedures--lock (root)
  "Acquisisci un'esclusione di processo locale nel progetto ROOT."
  (let* ((file (expand-file-name ".gdev/assurance/procedure.lock" root))
         (token (json-serialize `((pid . ,(emacs-pid)) (host . ,(system-name))))))
    (make-directory (file-name-directory file) t)
    (when (file-locked-p file) (gdev-process-refuse "Un'altra procedura possiede il blocco del progetto"))
    (let ((create-lockfiles t) acquired)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'ask-user-about-lock)
                       (lambda (&rest _) (gdev-process-refuse "Un'altra procedura ha acquisito il blocco"))))
              (lock-file file))
            (when (file-exists-p file)
              (let ((old (with-temp-buffer (insert-file-contents file)
                                           (json-parse-buffer :object-type 'alist))))
                (when (or (not (equal (alist-get 'host old) (system-name)))
                          (not (integerp (alist-get 'pid old)))
                          (process-attributes (alist-get 'pid old)))
                  (gdev-process-refuse "Una procedura è già in corso; attendi o annullala"))
                (delete-file file)))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region token nil file nil 'silent nil 'excl))
            (setq acquired t)
            (cons file token))
        (unless acquired (unlock-file file))))))

(defun gdev-procedures--unlock (lock)
  "Rilascia LOCK soltanto se appartiene ancora a questa esecuzione."
  (when (and lock (file-exists-p (car lock))
             (equal (cdr lock) (with-temp-buffer (insert-file-contents (car lock)) (buffer-string))))
    (delete-file (car lock))
    (unlock-file (car lock))))

(cl-defun gdev-procedures-run (db tx-id root procedure-id &key actor actor-kind resume)
  "Esegui PROCEDURE-ID di ROOT in TX-ID di DB, o riprendi RESUME.
Il piano è risolto integralmente prima della prima registrazione."
  (setq root (file-name-as-directory (file-truename root)))
  (gdev-trace-root db root)
  (gdev-process-check-actor actor actor-kind)
  (gdev-procedures-plan root procedure-id)
  (let* ((project (gdev-project-read root))
         (procedure (gdev-procedures--definition project procedure-id))
         (implementation (eq 'implementation (plist-get procedure :mode)))
         (gdev-procedures--stage (and implementation 'IMPLEMENTING))
         (work (gdev-work-latest db tx-id))
         (work-ref (if work (alist-get 'ref work) :null))
         (work-inputs (gdev-procedures--files root (append (and work (alist-get 'inputs (alist-get 'definition (gdev-record-data work)))) nil)))
         (context (gdev-project-context root project))
         (digest (gdev-project-context-digest context))
         (plans (mapcar (lambda (step)
                          (with-temp-buffer (insert-file-contents (gdev-project-file root (plist-get step :plan))) (buffer-string)))
                        (plist-get procedure :steps)))
         (run (or resume (concat "RUN-" (substring (secure-hash 'sha256 (format "%s-%s-%s" (emacs-pid) (current-time) (random))) 0 24))))
         (prior (and resume (gdev-procedures--rows db tx-id resume)))
         (start (and prior (car prior)))
         (start-ref (and start (alist-get 'ref start)))
         (original (and start (gdev-record-data start)))
         (lock (gdev-procedures--lock root)) complete cancelled failure)
    (unwind-protect
        (progn
          (when (and implementation (not (eq 'IMPLEMENTING (alist-get 'state (gdev-process-get db tx-id)))))
            (gdev-process-refuse "Una procedura di implementazione richiede la lavorazione in sviluppo"))
          (when-let* ((problem (gdev-work-problem db tx-id root (alist-get 'state (gdev-process-get db tx-id)))))
            (gdev-process-refuse "%s" problem))
          (unless (gdev-procedures--outputs-current-p root work-inputs) (gdev-process-refuse "Un input della lavorazione è assente"))
          (when resume
            (unless (and start (equal "start" (alist-get 'event original))
                         (equal digest (alist-get 'context_digest original))
                         (equal work-ref (or (alist-get 'work_ref original) :null))
                         (equal (gdev-record-encode `((inputs . ,work-inputs)))
                                (gdev-record-encode `((inputs . ,(or (alist-get 'work_inputs original) [])))))
                         (equal (gdev-record-encode (gdev-project-json procedure))
                                (gdev-record-encode (alist-get 'procedure original))))
              (gdev-process-refuse "La procedura o le sorgenti sono cambiate: avvia una nuova esecuzione")))
          (when resume (setq plans (append (alist-get 'plans original) nil)))
          ;; L'esecuzione usa esattamente i testi fissati nel giornale.
          (cl-loop for step in (plist-get procedure :steps) for text in plans do
                   (let* ((path (plist-get step :plan))
                          (input (seq-find (lambda (entry) (equal path (alist-get 'path entry)))
                                           (alist-get 'inputs context))))
                     (unless (equal (gdev-evidence-sha256 text) (alist-get 'sha256 input))
                       (gdev-process-refuse "Il piano è cambiato durante la preparazione: %s" path))
                     (gdev-lavorazione-run-text text root t)))
          (if resume
              (gdev-record-add db tx-id 'run
                               `((version . 1) (event . "resume") (run_id . ,run) (status . "RUNNING") (start . ,start-ref))
                               :actor actor :actor-kind actor-kind)
            (setq start-ref
                  (gdev-record-add db tx-id 'run
                                   `((version . 1) (event . "start") (run_id . ,run) (status . "RUNNING")
                                     (procedure . ,(gdev-project-json procedure)) (context . ,context) (context_digest . ,digest)
                                     (plans . ,(vconcat plans)) (work_ref . ,work-ref) (work_inputs . ,work-inputs)
                                     (tools . ((emacs . ,emacs-version) (system . ,(symbol-name system-type)))))
                                   :actor actor :actor-kind actor-kind)))
          (cl-labels
              ((record (event status &rest fields)
                 (gdev-record-add db tx-id 'run
                                  (append `((version . 1) (event . ,event) (run_id . ,run) (start . ,start-ref) (status . ,status)) fields)
                                  :actor actor :actor-kind actor-kind)))
            (condition-case err
                (progn
                  (cl-loop for step in (plist-get procedure :steps) for index from 0 do
                           (when (and gdev-procedures--cancel-function (funcall gdev-procedures--cancel-function)) (signal 'quit nil))
                           (let* ((finished (seq-find (lambda (row)
                                                       (let ((payload (gdev-record-data row)))
                                                         (and (equal "step" (alist-get 'event payload))
                                                              (equal index (alist-get 'step payload))))) (reverse prior)))
                                  (previous (and finished (gdev-record-data finished)))
                                  (skip (and previous (equal "SUCCEEDED" (alist-get 'status previous))
                                             (gdev-procedures-log-current-p root (alist-get 'log previous))
                                             (gdev-procedures--outputs-current-p root (alist-get 'effects previous))
                                             (gdev-procedures--outputs-current-p root (alist-get 'outputs previous)))))
                             (unless skip
                               (when (and previous (eq 'manual (plist-get step :replay)))
                                 (gdev-process-refuse "Il passo %s può avere effetti: riconciliali e avvia una nuova esecuzione" (plist-get step :id)))
                               (let ((inputs (gdev-procedures--files root (plist-get step :inputs))))
                                 (unless (gdev-procedures--outputs-current-p root inputs)
                                   (gdev-process-refuse "Input del passo %s non disponibili" (plist-get step :id)))
                                 (record "step" "RUNNING" (cons 'step index) (cons 'inputs inputs)))
                               (let ((gdev-procedures--checks nil) (gdev-procedures--effects nil)
                                     (gdev-procedures--log-file
                                      (expand-file-name (format ".gdev/assurance/run-logs/%s-%d.log" run index) root)))
                                 (condition-case step-error
                                     (progn
                                       (with-timeout ((plist-get step :timeout) (error "Tempo massimo del passo superato"))
                                         (gdev-lavorazione-run-text (nth index plans) root))
                                       (unless (and (gdev-procedures--outputs-current-p root (gdev-procedures--files root (plist-get step :outputs)))
                                                    (gdev-procedures--outputs-current-p root (vconcat gdev-procedures--effects)))
                                         (gdev-process-refuse "Il passo non ha prodotto tutte le uscite dichiarate"))
                                       (record "step" "SUCCEEDED" (cons 'step index)
                                               (cons 'outputs (gdev-procedures--files root (plist-get step :outputs)))
                                               (cons 'checks (vconcat gdev-procedures--checks))
                                               (cons 'effects (vconcat gdev-procedures--effects))
                                               (cons 'log (gdev-procedures--log root gdev-procedures--log-file))))
                                   (error
                                    (record "step" "FAILED" (cons 'step index) (cons 'detail (error-message-string step-error))
                                            (cons 'log (gdev-procedures--log root gdev-procedures--log-file)))
                                    (when (plist-get step :required) (signal (car step-error) (cdr step-error)))))))))
                  (unless (or implementation
                              (and (equal digest (gdev-project-context-digest (gdev-project-context root)))
                                   (gdev-procedures--outputs-current-p root work-inputs)))
                    (gdev-process-refuse "Le sorgenti sono cambiate durante la verifica"))
                  (unless (gdev-procedures--outputs-current-p root (gdev-procedures--files root (plist-get procedure :outputs)))
                    (gdev-process-refuse "La procedura non ha prodotto tutte le uscite dichiarate"))
                  (record "finish" "SUCCEEDED" (cons 'outputs (gdev-procedures--files root (plist-get procedure :outputs)))
                          (cons 'context_after (gdev-project-context-digest (gdev-project-context root))))
                  (setq complete t))
              (quit (setq cancelled t failure "Esecuzione annullata"))
              (error (setq failure (error-message-string err))))
            (unless complete (record "finish" (if cancelled "CANCELLED" "FAILED") (cons 'detail failure))))
          `((run_id . ,run) (status . ,(cond (complete "SUCCEEDED") (cancelled "CANCELLED") (t "FAILED")))
            (detail . ,(or failure :null)) (human_approval . "NOT_VERIFIED")))
      (gdev-procedures--unlock lock))))

(defun gdev-procedures-data (db &optional tx-id)
  "Restituisci il giornale di DB, eventualmente filtrato per TX-ID."
  `((runs . ,(vconcat (mapcar (lambda (row) `((ref . ,(alist-get 'ref row)) (record_id . ,(alist-get 'id row))
                                             (transaction . ,(alist-get 'tx_id row))
                                             (data . ,(gdev-record-data row)))) (gdev-procedures--rows db tx-id))))))

(defun gdev-procedures-verification (db tx-id root project &optional digest)
  "Valuta ciascun requisito di PROJECT sulle esecuzioni correnti di TX-ID.
DIGEST riusa l'impronta già calcolata nella stessa lettura, mai fra letture."
  (let* ((digest (or digest (gdev-project-context-digest (gdev-project-context root project))))
         (rows (gdev-procedures--rows db tx-id))
         (latest (make-hash-table :test #'equal))
         (entered (caar (sqlite-select db "select max(seq) from tx_event where tx_id = ? and kind = 'transition' and to_state = 'VERIFYING'" (list tx-id)))))
    (dolist (row rows)
      (let* ((data (gdev-record-data row))
             (start (and (equal "finish" (alist-get 'event data)) (gdev-record-get db (alist-get 'start data)))))
        (when start (puthash (alist-get 'id (alist-get 'procedure (gdev-record-data start))) row latest))))
    (vconcat
     (mapcar
      (lambda (requirement)
        (let* ((row (gethash (plist-get requirement :procedure) latest))
               (finish (and row (gdev-record-data row)))
               (start (and row (gdev-record-get db (alist-get 'start finish))))
               (original (and start (gdev-record-data start)))
               (start-seq (and start (caar (sqlite-select db "select seq from tx_event where kind = 'record' and ref = ?" (list (alist-get 'ref start))))))
               (steps (make-hash-table :test #'eql)) cases)
          ;; Solo l'ultimo evento di ciascun passo può sostenere l'esito.
          (when start
            (dolist (step-row (gdev-procedures--rows db tx-id (alist-get 'run_id original)))
              (let ((step (gdev-record-data step-row)))
                (when (equal "step" (alist-get 'event step)) (puthash (alist-get 'step step) step steps))))
            (maphash
             (lambda (_ step)
               (when (and (equal "SUCCEEDED" (alist-get 'status step))
                          (gdev-procedures-log-current-p root (alist-get 'log step))
                          (gdev-procedures--outputs-current-p root (alist-get 'outputs step))
                          (gdev-procedures--outputs-current-p root (alist-get 'effects step)))
                 (seq-doseq (check (alist-get 'checks step))
                   (when (equal "PASSED" (alist-get 'status check))
                     (push (alist-get 'name check) cases)
                     (setq cases (append (append (alist-get 'passed check) nil) cases)))))) steps))
          (let ((reason
                 (cond
                  ((eq 'not-applicable (plist-get requirement :applicability)) nil)
                  ((equal "implementation" (alist-get 'mode (alist-get 'procedure original))) "Un'implementazione non costituisce una verifica")
                  ((not entered) "Avvia il ciclo di verifica della lavorazione")
                  ((not (equal "SUCCEEDED" (alist-get 'status finish))) "Esegui la procedura obbligatoria con successo")
                  ((or (not start-seq) (<= start-seq entered)) "Ripeti la procedura nel ciclo di verifica corrente")
                  ((not (equal digest (alist-get 'context_digest original))) "Sorgenti o definizioni cambiate: ripeti la procedura")
                  ((not (equal (or (alist-get 'work_ref original) :null)
                               (if-let* ((work (gdev-work-latest db tx-id))) (alist-get 'ref work) :null)))
                   "Scheda della lavorazione cambiata: ripeti la procedura")
                  ((not (gdev-procedures--outputs-current-p root (alist-get 'outputs finish))) "Uscite della procedura assenti o cambiate")
                  ((not (gdev-procedures--outputs-current-p root (alist-get 'work_inputs original))) "Input della lavorazione cambiati: ripeti la procedura")
                  ((not (plist-get requirement :tests)) "Collega controlli eseguibili al requisito")
                  ((not (cl-every (lambda (name) (member name cases)) (plist-get requirement :tests)))
                   "Mancano esiti positivi dei controlli richiesti"))))
            `((id . ,(plist-get requirement :id))
              (status . ,(cond ((eq 'not-applicable (plist-get requirement :applicability)) "NOT_APPLICABLE")
                               (reason "NOT_VERIFIED") (t "SATISFIED")))
              (reason . ,(or reason "Controlli registrati sulla definizione corrente"))
              (run . ,(or (alist-get 'run_id finish) :null))
              (checks . ,(vconcat (sort (delete-dups cases) #'string<)))))))
      (plist-get project :requirements)))))

(defun gdev-procedures-verified-p (db tx-id root project &optional digest)
  "Verifica requisiti e artefatti obbligatori di PROJECT nel ciclo corrente."
  (let* ((digest (or digest (gdev-project-context-digest (gdev-project-context root project))))
         (entered (caar (sqlite-select db "select max(seq) from tx_event where tx_id = ? and kind = 'transition' and to_state = 'VERIFYING'" (list tx-id))))
         (latest (make-hash-table :test #'equal))
         (work (gdev-work-latest db tx-id))
         (required (append (seq-filter (lambda (row) (plist-get row :required)) (plist-get project :artifacts))
                           (mapcar (lambda (path) (list :path path :required t))
                                   (append (alist-get 'artifacts (and work (alist-get 'definition (gdev-record-data work)))) nil)))))
    (dolist (row (gdev-procedures--rows db tx-id))
      (let* ((finish (gdev-record-data row))
             (start (and (equal "finish" (alist-get 'event finish)) (gdev-record-get db (alist-get 'start finish)))))
        (when start (puthash (alist-get 'id (alist-get 'procedure (gdev-record-data start))) (cons start finish) latest))))
    (and entered (plist-get project :requirements)
         (seq-every-p (lambda (row) (member (alist-get 'status row) '("SATISFIED" "NOT_APPLICABLE")))
                      (gdev-procedures-verification db tx-id root project digest))
         (cl-every
          (lambda (artifact)
            (let (found)
              (maphash
               (lambda (procedure pair)
                 (let* ((start (car pair)) (finish (cdr pair)) (original (gdev-record-data start))
                        (seq (caar (sqlite-select db "select seq from tx_event where kind = 'record' and ref = ?" (list (alist-get 'ref start))))))
                   (when (and (or (null (plist-get artifact :procedure)) (equal procedure (plist-get artifact :procedure)))
                              (equal "SUCCEEDED" (alist-get 'status finish)) seq (> seq entered)
                              (equal digest (alist-get 'context_digest original))
                              (equal (or (alist-get 'work_ref original) :null) (if work (alist-get 'ref work) :null))
                              (seq-find (lambda (output) (equal (plist-get artifact :path) (alist-get 'path output))) (alist-get 'outputs finish))
                              (gdev-procedures--outputs-current-p root (alist-get 'outputs finish)))
                     (setq found t)))) latest)
              found)) required))))

(defun gdev-procedures--check (name)
  "Registra NAME tra i controlli effettivamente eseguiti."
  (push `((name . ,name) (status . "PASSED")) gdev-procedures--checks))

(defun gdev-procedures--project (context)
  "Controlla il progetto della lavorazione CONTEXT."
  (let* ((root (gdev-lavorazione-radice context)) (problems (gdev-project-problems root (gdev-project-read root) gdev-procedures--stage)))
    (when problems (gdev-process-refuse "%s" (car problems))) (gdev-procedures--check "project")))

(defun gdev-procedures--model (_context)
  "Esegui la verifica finita dei predicati del nucleo."
  (require 'gdev-formal)
  (let ((result (gdev-formal-check)))
    (unless (eq t (alist-get 'ok result)) (gdev-process-refuse "Controesempio nel modello formale: %S" result))
    (setf (alist-get 'name result) "model" (alist-get 'status result) "PASSED")
    (push result gdev-procedures--checks)))

(defun gdev-procedures--ert (context file selector)
  "Esegui FILE ERT con SELECTOR in un figlio isolato di CONTEXT."
  (let* ((root (gdev-lavorazione-radice context)) (test (gdev-project-file root file))
         (distribution (file-name-directory (directory-file-name
                                             (file-name-directory (locate-library "gdev-procedures")))))
         (temporary (make-temp-file "gdev-procedure-" t))
         (output (generate-new-buffer " *gdev-procedure-tests*"))
         (result (expand-file-name "result.json" temporary))
         (process-environment (copy-sequence process-environment)) process)
    (unwind-protect
        (progn
          (unless (file-regular-p test) (gdev-process-refuse "Suite ERT assente: %s" file))
          (setenv "GDEV_STATE_DIR" (expand-file-name "state" temporary))
          (setenv "GDEV_USER_DIR" (expand-file-name "user" temporary))
          (setenv "GDEV_PROCEDURE_TEST" test) (setenv "GDEV_PROCEDURE_SELECTOR" selector)
          (setenv "GDEV_PROCEDURE_RESULT" result)
          (setq process (make-process
                         :name "gdev-procedure-tests" :buffer output :noquery t :sentinel #'ignore
                         :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                        "-l" (expand-file-name "early-init.el" distribution)
                                        "-l" (expand-file-name "test/gdev-procedure-worker.el" distribution))))
          (while (process-live-p process)
            (when (and gdev-procedures--cancel-function (funcall gdev-procedures--cancel-function)) (signal 'quit nil))
            (accept-process-output process 0.05))
          (unless (and (zerop (process-exit-status process)) (file-regular-p result))
            (gdev-process-refuse "Suite ERT fallita: consulta il rapporto del passo"))
          (let ((data (with-temp-buffer (insert-file-contents result)
                                       (json-parse-buffer :object-type 'alist :array-type 'array))))
            (unless (and (eq t (alist-get 'ok data)) (> (alist-get 'selected data) 0))
              (gdev-process-refuse "Suite ERT senza casi superati o con errori"))
            (push data gdev-procedures--checks)))
      (gdev-procedures--stop-child process)
      (when gdev-procedures--log-file
        (make-directory (file-name-directory gdev-procedures--log-file) t)
        (with-current-buffer output
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (point-min) (point-max) gdev-procedures--log-file t 'silent))))
      (kill-buffer output) (delete-directory temporary t))))

(defun gdev-procedures--python (context file arguments)
  "Esegui FILE Python con ARGUMENTS JSON espliciti nella radice di CONTEXT."
  (let* ((root (gdev-lavorazione-radice context)) (test (gdev-project-file root file))
         (args (json-parse-string arguments :array-type 'array))
         (program (or (executable-find "python3") (gdev-process-refuse "Python 3 non disponibile"))))
    (unless (and (file-regular-p test) (vectorp args) (seq-every-p #'stringp args))
      (gdev-process-refuse "Suite o argomenti Python non validi"))
    (let* ((temporary (make-temp-file "gdev-procedure-python-" t))
           (output (generate-new-buffer " *gdev-procedure-python*"))
           (process-environment (copy-sequence process-environment))
           (default-directory root) process)
      (unwind-protect
          (progn
            (setenv "GDEV_STATE_DIR" (expand-file-name "state" temporary))
            (setenv "GDEV_USER_DIR" (expand-file-name "user" temporary))
            (setq process (make-process :name "gdev-procedure-python" :buffer output :noquery t :sentinel #'ignore
                                        :command (append (list program test) (append args nil))))
            (while (process-live-p process)
              (when (and gdev-procedures--cancel-function (funcall gdev-procedures--cancel-function)) (signal 'quit nil))
              (accept-process-output process 0.05))
            (unless (and (eq 'exit (process-status process)) (zerop (process-exit-status process)))
              (gdev-process-refuse "Suite Python fallita: %s; consulta il rapporto del passo" file))
            (gdev-procedures--check file))
        (gdev-procedures--stop-child process)
        (when gdev-procedures--log-file
          (make-directory (file-name-directory gdev-procedures--log-file) t)
          (with-current-buffer output
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (point-min) (point-max) gdev-procedures--log-file t 'silent))))
        (kill-buffer output) (delete-directory temporary t)))))

(defun gdev-procedures--stop-child (process)
  "Interrompi soltanto il gruppo del figlio PROCESS creato dalla procedura."
  (when (and process (process-live-p process))
    (ignore-errors (interrupt-process process))
    (let ((deadline (+ (float-time) 1.0)))
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.05)))
    (when (process-live-p process) (ignore-errors (kill-process process)))))

(defun gdev-procedures--documents (context)
  "Controlla i documenti della lavorazione CONTEXT."
  (require 'gdev-documents)
  (when-let* ((different (gdev-documents-generate (gdev-lavorazione-radice context) t)))
    (gdev-process-refuse "Documenti da rigenerare: %s" different))
  (gdev-procedures--check "documents"))

(defun gdev-procedures--report (context)
  "Produci il rapporto controllato del progetto di CONTEXT."
  (require 'gdev-project-report)
  (let ((root (gdev-lavorazione-radice context)))
    (gdev-project-report root)
    (push `((path . ,gdev-project-report-path)
            (sha256 . ,(gdev-evidence-file-sha256 (expand-file-name gdev-project-report-path root)))) gdev-procedures--effects))
  (gdev-procedures--check "project-report"))

(defun gdev-procedures--snippet (context id path arguments)
  "Materializza ID in PATH con ARGUMENTS JSON nella lavorazione CONTEXT."
  (let ((args (gdev-project-snippet-arguments arguments)))
    (push (gdev-project-snippet-write (gdev-lavorazione-radice context) id
                                     args path)
          gdev-procedures--effects)))

(defun gdev-procedures-register-actions ()
  "Registra le azioni di progetto nel catalogo comune delle lavorazioni."
  (gdev-lavorazione-registra "progetto-controlla" "Verifica campi e collegamenti del progetto." nil #'gdev-procedures--project :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-modello" "Esplora il modello finito dei controlli." nil #'gdev-procedures--model :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-documenti" "Confronta i documenti con le sorgenti." nil #'gdev-procedures--documents :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-rapporto" "Genera il rapporto tracciato del progetto." nil #'gdev-procedures--report :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-test-ert" "Esegui una suite ERT isolata e registra i casi superati."
                            '(("file" . percorso) ("selettore" . testo-non-vuoto)) #'gdev-procedures--ert :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-test-python" "Esegui una suite Python con argomenti espliciti."
                            '(("file" . percorso) ("argomenti" . testo-non-vuoto)) #'gdev-procedures--python :modulo "Progetto formale")
  (gdev-lavorazione-registra "progetto-modello-inserisci" "Materializza un modello versionato con parametri JSON."
                            '(("modello" . testo-non-vuoto) ("destinazione" . percorso) ("parametri" . testo-non-vuoto))
                            #'gdev-procedures--snippet :modulo "Progetto formale"))

(with-eval-after-load 'gdev-lavorazione (gdev-procedures-register-actions))

(provide 'gdev-procedures)
;;; gdev-procedures.el ends here
