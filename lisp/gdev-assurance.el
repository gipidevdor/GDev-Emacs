;;; gdev-assurance.el --- Nucleo dell'assicurazione ingegneristica -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Facciata del nucleo: riunisce l'archivio (`gdev-assurance-db'), le
;; transazioni (`gdev-process') e le prove (`gdev-evidence') e offre i
;; letture di `gdev assurance' (le scritture esplicite sono in
;; `gdev-assurance-actions'):
;;
;;   gdev assurance status          archivio, versione dello schema, conteggi
;;   gdev assurance list [STATO]    transazioni, con filtro per stato
;;   gdev assurance show ID         una transazione, i suoi eventi e le sue prove
;;   gdev assurance verify          integrità, catena degli eventi e prove
;;
;; Nessuna lettura crea, migra o modifica l'archivio. Carica da solo,
;; senza la configurazione di GDev.
;;
;; `gdev-assurance-data' restituisce gli stessi dati in forma strutturata,
;; pronta per `json-serialize': la usano il sottocomando, che li stampa, e lo
;; strumento MCP `gdev_assurance'.  È l'unica fonte delle letture.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-assurance-db)
(require 'gdev-assurance-api)
(require 'gdev-standards)
(require 'gdev-process)
(require 'gdev-evidence)
(require 'gdev-controls)
(require 'gdev-decisions)
(require 'gdev-assessment-store)
(require 'gdev-records)

(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))
(declare-function gdev-assessment-run "gdev-assessment" (db tx-id))
(declare-function gdev-standard-selection "gdev-standard-assessment" (db id))
(declare-function gdev-capability-run "gdev-capability" (db &optional profile))
(declare-function gdev-trace-artifacts "gdev-trace" (db))
(declare-function gdev-trace-links "gdev-trace" (db))
(declare-function gdev-trace-impact "gdev-trace" (db root &optional paths))
(declare-function gdev-assurance-actions-cli "gdev-assurance-actions" (root command operands))
(declare-function gdev-standard-catalog-data "gdev-standard-catalog" (&optional id))
(declare-function gdev-formal-check "gdev-formal" ())
(declare-function gdev-project-data "gdev-project" (root &optional stage))
(declare-function gdev-project-read "gdev-project" (root))
(declare-function gdev-project-json "gdev-project" (data))
(declare-function gdev-project-suggest "gdev-project" (standard))
(declare-function gdev-taxonomy-data "gdev-taxonomy" (&optional id))
(declare-function gdev-procedures-plan "gdev-procedures" (root id))
(declare-function gdev-procedures-data "gdev-procedures" (db &optional tx-id))
(declare-function gdev-work-data "gdev-work" (db tx-id))
(defvar gdev-project-manifest)
(defvar gdev-assessment-statuses)
(defvar gdev-assurance-action-contracts)

(define-error 'gdev-assurance-no-transaction "Transazione inesistente" 'gdev-assurance-error)

(defconst gdev-assurance-data-limit 200
  "Righe di un elenco che `gdev-assurance-data' restituisce a un agente.")

(defun gdev-assurance-verify (db)
  "Restituisci tutti i problemi di DB: struttura, catena, transazioni e prove.
Ritorna nil se l'archivio è integro."
  (append (gdev-assurance-db-integrity db)
          (gdev-process-verify db)
          (gdev-evidence-verify db)
          (gdev-decision-verify db)
          (gdev-assessment-store-verify db)
          (gdev-record-verify db)))

;;;; Dati

(defun gdev-assurance--json-value (value)
  "Restituisci VALUE come valore JSON: nil è null, un simbolo il suo nome."
  (cond ((null value) :null) ((symbolp value) (symbol-name value)) (t value)))

(defun gdev-assurance--json-row (row)
  "Restituisci ROW, un alist, con i valori adatti a `json-serialize'."
  (mapcar (lambda (cell) (cons (car cell) (gdev-assurance--json-value (cdr cell)))) row))

(defun gdev-assurance--rows (rows limit)
  "Restituisci (VETTORE . TOTALE): le ultime LIMIT di ROWS come righe JSON."
  (let ((total (length rows)))
    (cons (vconcat (mapcar #'gdev-assurance--json-row
                           (if (and limit (> total limit)) (last rows limit) rows)))
          total)))

(defun gdev-assurance--count-of (db table &optional where)
  "Restituisci il numero di righe di TABLE in DB, con la condizione WHERE."
  (caar (sqlite-select db (concat "select count(*) from " table (and where (concat " where " where))))))

(defun gdev-assurance--status-data (root db)
  "Restituisci i dati dello stato dell'archivio DB del progetto ROOT."
  (let ((counts (sqlite-select db "select state, count(*) from tx group by state order by min(n)"))
        (last (car (gdev-assurance-db-select
                    db "select at, hash from tx_event order by seq desc limit 1"))))
    `((archive . t)
      (root . ,root)
      (file . ,(gdev-assurance-db-file root))
      (schema_version . ,(gdev-assurance-db-version db))
      (latest_schema_version . ,(gdev-assurance-db-latest-version))
      (sqlite_version . ,(gdev-assurance-db-sqlite-version db))
      (transactions . ,(mapcar (lambda (row) (cons (intern (car row)) (cadr row))) counts))
      (transaction_count . ,(apply #'+ (mapcar #'cadr counts)))
      (events . ,(gdev-assurance--count-of db "tx_event"))
      (evidence . ,(gdev-assurance--count-of db "evidence"))
      (refusals . ,(gdev-assurance--count-of db "tx_event" "kind = 'refusal'"))
      (decisions . ,(gdev-assurance--count-of db "decision"))
      (assessments . ,(gdev-assurance--count-of db "assessment"))
      (last_event . ,(if last
                         `((at . ,(alist-get 'at last)) (hash . ,(alist-get 'hash last)))
                       :null)))))

(defvar gdev-assurance--reader nil
  "Connessione in sola lettura condivisa entro una richiesta sul progetto.")

(defun gdev-assurance-call-with-reader (root function)
  "Chiama FUNCTION con l'archivio di ROOT su una sola istantanea SQL.
Le letture della facciata annidate sullo stesso archivio riusano la
connessione. La connessione si chiude prima del ritorno al chiamante."
  (let ((file (file-truename (gdev-assurance-db-file root))))
    (if (and gdev-assurance--reader (equal file (car gdev-assurance--reader)))
        (funcall function (cdr gdev-assurance--reader))
      (gdev-assurance-db-with-open (db root)
        (gdev-assurance-db-read-transaction
         db (lambda ()
              (let ((gdev-assurance--reader (cons file db))) (funcall function db))))))))

(defun gdev-assurance--view-transaction (db id)
  "Leggi ID in DB con le scelte dei comandi, senza esiti di verifica."
  (require 'gdev-standard-assessment)
  (let* ((tx (or (gdev-process-get db id) (signal 'gdev-assurance-no-transaction (list id))))
         (catalog (gdev-controls-load))
         (profile (gdev-controls-profile catalog (alist-get 'profile tx)))
         (selection (gdev-standard-selection db id)))
    (append (gdev-assurance--json-row tx)
            `((profile_title . ,(plist-get profile :titolo))
              (provisional . ,(if (plist-get profile :provvisorio) t :false))
              (standard_targets . ,(if selection (alist-get 'targets (gdev-record-data selection)) []))
              (profile_controls . ,(vconcat
                                     (mapcar (lambda (control)
                                               `((control . ,(plist-get control :id))
                                                 (decidable . ,(if (plist-get control :decidibile) t :false))))
                                             (gdev-controls-for-profile catalog (alist-get 'profile tx)))))))))

(defun gdev-assurance-project-data (root &optional id detail argument limit section)
  "Leggi stato, transazioni e dettagli di ROOT su una sola istantanea.
ID seleziona la transazione. DETAIL è una lettura aggiuntiva fra standards,
trace, requests, capability, verify e impact; ARGUMENT ne precisa il filtro.
LIMIT limita gli elenchi. SECTION seleziona i dati necessari a una vista;
se omessa conserva la lettura completa, incluse storia e valutazione.
Una vista informativa non produce esiti di verifica: `controls' rilegge
sempre la valutazione. Il chiamante riceve dati, senza connessioni SQL.
Senza archivio restano consultabili lo stato assente e il catalogo."
  (unless (member detail '(nil "standards" "trace" "requests" "capability" "verify" "impact" "project" "taxonomy" "procedures" "runs"))
    (user-error "Dettaglio del progetto non valido: %s" detail))
  (unless (memq section '(nil project transactions controls standards taxonomy procedures runs
                            trace requests documents capability verify impact))
    (user-error "Sezione del progetto non valida: %s" section))
  (gdev-standards-with-cache
   (lambda ()
     (if (not (file-regular-p (gdev-assurance-db-file root)))
         `((status . ((archive . :false) (root . ,root)))
           (detail . ,(when (member detail '("standards" "project" "taxonomy" "procedures"))
                        (gdev-assurance-data detail root argument limit))))
       (gdev-assurance-call-with-reader
        root (lambda (db)
               `((status . ,(gdev-assurance-data "status" root))
                 (transactions . ,(gdev-assurance-data "list" root))
                 (show . ,(when id
                            (if (null section) (gdev-assurance-data "show" root id limit)
                              `((transaction . ,(gdev-assurance--view-transaction db id))))))
                 (work . ,(when (and id (memq section '(nil transactions)))
                            (require 'gdev-work) (gdev-work-data db id)))
                 (assessment . ,(when (and id (memq section '(nil controls)))
                                  (gdev-assurance-data "assess" root id)))
                 (detail . ,(when detail (gdev-assurance-data detail root argument limit))))))))))

(defun gdev-assurance--source-page (rows argument limit)
  "Taglia ROWS con LIMIT e il cursore in ARGUMENT, conservando il totale."
  (let* ((parts (and argument (split-string argument "@")))
         (suffix (cadr parts)) (offset (if suffix (string-to-number suffix) 0))
         (size (or limit (length rows))))
    (when (or (> (length parts) 2) (and suffix (not (string-match-p "\\`[0-9]+\\'" suffix)))
              (> offset (length rows))) (user-error "Cursore di lettura non valido"))
    `((items . ,(vconcat (seq-subseq rows offset (min (length rows) (+ offset size)))))
      (total . ,(length rows)) (offset . ,offset)
      (next_argument . ,(if (< (+ offset size) (length rows)) (format "%s@%d" (car parts) (+ offset size)) :null)))))

(defun gdev-assurance--project-source-data (command root argument &optional limit)
  "Leggi COMMAND dai sorgenti di ROOT, senza connessioni SQLite."
  (require 'gdev-project)
  (pcase command
    ("project" (let ((stage (and argument (intern (upcase argument)))))
                 (when (and stage (not (memq stage gdev-process-states))) (user-error "Fase sconosciuta: %s" argument))
                 (gdev-project-data root stage)))
    ("taxonomy"
     (let ((data (gdev-taxonomy-data (car (and argument (split-string argument "@"))))))
       (seq-doseq (row (alist-get 'taxonomies data))
         (if (not argument) (setf (alist-get 'nodes row) [])
           (let ((page (gdev-assurance--source-page (alist-get 'nodes row) argument limit)))
             (setf (alist-get 'nodes row) (alist-get 'items page))
             (nconc row `((offset . ,(alist-get 'offset page))
                          (next_argument . ,(alist-get 'next_argument page))))))) data))
    ("suggest"
     (let ((page (gdev-assurance--source-page (gdev-project-suggest (car (split-string argument "@"))) argument limit)))
       (cons '(status . "PROPOSED") (cons (cons 'suggestions (alist-get 'items page)) (assq-delete-all 'items page)))))
    ("snippets" (let* ((data (when (file-exists-p (expand-file-name gdev-project-manifest root)) (gdev-project-read root)))
                       (rows (plist-get data :snippets)))
                  (when argument (setq rows (list (or (seq-find (lambda (row) (equal argument (plist-get row :id))) rows)
                                                      (user-error "Modello sconosciuto: %s" argument)))))
                  `((snippets . ,(vconcat (mapcar #'gdev-project-json rows))))))
    ("procedures" `((procedures . ,(vconcat (mapcar #'gdev-project-json (plist-get (when (file-exists-p (expand-file-name gdev-project-manifest root)) (gdev-project-read root)) :procedures))))))
    ("procedure-plan" (require 'gdev-procedures) (gdev-procedures-plan root argument))
    ("model-check" (require 'gdev-formal) (gdev-formal-check))))

(defun gdev-assurance-data (command root &optional argument limit)
  "Leggi dall'archivio del progetto ROOT i dati di COMMAND, in sola lettura.
COMMAND è nel catalogo `gdev-assurance-read-contracts'. ARGUMENT è lo stato,
l'identificativo, il profilo o il percorso richiesto dal comando.
LIMIT, se indicato, taglia gli elenchi alle ultime righe, con il
totale a parte.  Restituisci un alist pronto per `json-serialize'.  Senza
archivio `status' risponde (archive . :false), `standards' legge il catalogo;
gli altri segnalano
`gdev-assurance-db-missing'.  Una transazione che manca segnala
`gdev-assurance-no-transaction'."
  (when (and (member command '("show" "assess" "standard-assess")) (null argument))
    (signal 'gdev-assurance-no-transaction (list argument)))
  (unless (gdev-assurance-operands-p command (and argument (list argument)))
    (user-error "Operandi non validi per %s" command))
  (if (member command '("project" "taxonomy" "suggest" "snippets" "procedures" "procedure-plan" "model-check"))
      (gdev-assurance--project-source-data command root argument limit)
  (if (equal command "standards")
      (progn (require 'gdev-standard-catalog) (gdev-standard-catalog-data argument))
  (if (and (equal command "status") (not (file-regular-p (gdev-assurance-db-file root))))
      `((archive . :false) (root . ,root))
    (gdev-assurance-call-with-reader root (lambda (db)
      (gdev-assurance-db-read-transaction db (lambda () (pcase command
        ("status" (gdev-assurance--status-data root db))
        ("list"
         (let* ((state (and argument (intern (upcase argument))))
                (rows (progn
                        (unless (or (null state) (memq state gdev-process-states))
                          (user-error "Stato sconosciuto: %s" argument))
                        (gdev-assurance--rows (gdev-process-list db state) limit))))
           `((state . ,(if state (symbol-name state) :null))
             (transactions . ,(car rows))
             (total . ,(cdr rows)))))
        ("show"
         (let ((tx (or (gdev-process-get db argument)
                       (signal 'gdev-assurance-no-transaction (list argument))))
               (events (gdev-assurance--rows (gdev-process-events db argument) limit))
               (evidence (gdev-assurance--rows (gdev-evidence-list db argument) limit))
               (decisions (gdev-assurance--rows (gdev-decision-list db argument) limit))
               (assessments (gdev-assurance--rows (gdev-assessment-store-list db argument) limit)))
           `((transaction . ,(gdev-assurance--json-row tx))
             (events . ,(car events))
             (events_total . ,(cdr events))
             (evidence . ,(car evidence))
             (evidence_total . ,(cdr evidence))
             (decisions . ,(car decisions))
             (decisions_total . ,(cdr decisions))
             (assessments . ,(car assessments))
             (assessments_total . ,(cdr assessments)))))
        ("assess"
         (require 'gdev-assessment)
         (gdev-assessment-run db argument))
        ("standard-assess"
         (require 'gdev-assessment)
         (let* ((data (gdev-assessment-run db argument))
                (results (alist-get 'results (alist-get 'standards data))))
           (setf (alist-get 'results data) results (alist-get 'recorded data) :null
                 (alist-get 'summary data)
                 (mapcar (lambda (status) (cons status (seq-count (lambda (row)
                                                                  (equal (symbol-name status) (alist-get 'status row))) results)))
                         gdev-assessment-statuses)) data))
        ("capability"
         (require 'gdev-capability)
         (gdev-capability-run db argument))
        ("trace"
         (require 'gdev-trace)
         (when-let* ((problems (gdev-assurance-verify db)))
           (signal 'gdev-assurance-error (list (car problems))))
         (let ((artifacts (gdev-assurance--rows (gdev-trace-artifacts db) limit))
               (links (gdev-assurance--rows (gdev-trace-links db) limit)))
           `((artifacts . ,(car artifacts)) (artifacts_total . ,(cdr artifacts))
             (links . ,(car links)) (links_total . ,(cdr links)))))
        ("work" (require 'gdev-work) (gdev-work-data db argument))
        ("runs"
         (require 'gdev-procedures)
         (let* ((selector (car (and argument (split-string argument "@"))))
                (data (gdev-procedures-data db (unless (equal selector "all") selector)))
                (page (gdev-assurance--source-page (alist-get 'runs data) (or argument "all") limit)))
           (cons (cons 'runs (alist-get 'items page)) (assq-delete-all 'items page))))
        ("requests"
         (require 'gdev-assurance-requests)
         (let* ((all (if argument (list (or (gdev-record-get db argument)
                                           (user-error "Richiesta inesistente: %s" argument)))
                       (gdev-record-list db nil 'request)))
                (rows (mapcar (lambda (row)
                                (unless (eq (alist-get 'kind row) 'request) (user-error "Non è una richiesta"))
                                `((ref . ,(alist-get 'ref row)) (digest . ,(alist-get 'digest row))
                                  (transaction . ,(alist-get 'tx_id row)) (data . ,(gdev-record-data row)))) all)))
           (let ((limited (gdev-assurance--rows rows limit)))
             `((requests . ,(car limited)) (total . ,(cdr limited))))))
        ("impact"
         (require 'gdev-trace)
         (when-let* ((problems (gdev-assurance-verify db)))
           (signal 'gdev-assurance-error (list (car problems))))
         (let* ((data (gdev-trace-impact db root (and argument (list argument))))
                (affected (gdev-assurance--rows (append (alist-get 'affected data) nil) limit)))
           `((changed . ,(alist-get 'changed data)) (affected . ,(car affected))
             (affected_total . ,(cdr affected)))))
        ("verify"
         (let ((problems (gdev-assurance-verify db)))
           `((ok . ,(if problems :false t))
             (problems . ,(vconcat problems))
             (transactions . ,(gdev-assurance--count-of db "tx"))
             (events . ,(gdev-assurance--count-of db "tx_event"))
             (evidence . ,(gdev-assurance--count-of db "evidence")))))
        (_ (error "Comando sconosciuto: %S" command)))))))))))

;;;; Testo

(defun gdev-assurance--say (format-string &rest arguments)
  "Stampa FORMAT-STRING con ARGUMENTS e un a capo."
  (princ (concat (apply #'format format-string arguments) "\n")))

(defun gdev-assurance--short-hash (hash)
  "Restituisci l'inizio di HASH, abbastanza per riconoscerlo."
  (substring hash 0 12))

(defun gdev-assurance--plural (count singular plural)
  "Restituisci COUNT con il nome al numero giusto."
  (format "%d %s" count (if (= count 1) singular plural)))

(defun gdev-assurance--render-status (data)
  "Stampa i dati di stato DATA e restituisci lo stato di uscita."
  (let ((counts (alist-get 'transactions data))
        (last (alist-get 'last_event data)))
    (gdev-assurance--say "Archivio di assicurazione")
    (gdev-assurance--say "  Radice:        %s" (alist-get 'root data))
    (gdev-assurance--say "  File:          %s" (alist-get 'file data))
    (gdev-assurance--say "  Schema:        versione %d di %d"
                         (alist-get 'schema_version data) (alist-get 'latest_schema_version data))
    (gdev-assurance--say "  SQLite:        %s" (alist-get 'sqlite_version data))
    (gdev-assurance--say "  Transazioni:   %d%s" (alist-get 'transaction_count data)
                         (if counts
                             (concat " (" (mapconcat (lambda (cell) (format "%s %d" (car cell) (cdr cell)))
                                                     counts ", ")
                                     ")")
                           ""))
    (gdev-assurance--say "  Eventi, prove, rifiuti, decisioni, valutazioni: %d, %d, %d, %d, %d"
                         (alist-get 'events data) (alist-get 'evidence data)
                         (alist-get 'refusals data) (alist-get 'decisions data)
                         (alist-get 'assessments data))
    (gdev-assurance--say "  Ultimo evento: %s"
                         (if (eq last :null)
                             "nessuno"
                           (format "%s, impronta %s" (alist-get 'at last)
                                   (gdev-assurance--short-hash (alist-get 'hash last)))))
    0))

(defun gdev-assurance--render-list (data)
  "Stampa le transazioni di DATA e restituisci lo stato di uscita."
  (let ((rows (alist-get 'transactions data))
        (state (alist-get 'state data)))
    (if (zerop (length rows))
        (gdev-assurance--say "Nessuna transazione%s." (if (eq state :null) "" (format " in %s" state)))
      (gdev-assurance--say "%-8s %-13s %-15s %s" "ID" "STATO" "PROFILO" "TITOLO")
      (seq-doseq (row rows)
        (gdev-assurance--say "%-8s %-13s %-15s %s" (alist-get 'id row) (alist-get 'state row)
                             (alist-get 'profile row) (alist-get 'title row))))
    0))

(defun gdev-assurance--render-event (event)
  "Stampa una riga per EVENT, un alist JSON."
  (let ((kind (alist-get 'kind event))
        (note (alist-get 'note event)))
    (gdev-assurance--say "    %3d  %s  %-10s %s%s  %s:%s%s"
                         (alist-get 'seq event) (alist-get 'at event) kind
                         (pcase kind
                           ("transition" (format "%s → " (alist-get 'from_state event)))
                           ("refusal" (format "%s ✗ " (alist-get 'from_state event)))
                           (_ ""))
                         (alist-get 'to_state event) (alist-get 'actor_kind event)
                         (alist-get 'actor event)
                         (if (eq note :null)
                             ""
                           (format "  [%s%s]"
                                   (if (member kind '("refusal" "decision" "assessment"))
                                       (concat (alist-get 'ref event) ": ")
                                     "")
                                   (replace-regexp-in-string "\n" " " note))))))

(defun gdev-assurance--render-show (data)
  "Stampa la transazione di DATA con eventi e prove e restituisci lo stato di
uscita."
  (let ((tx (alist-get 'transaction data))
        (evidence (alist-get 'evidence data)))
    (gdev-assurance--say "%s  %s" (alist-get 'id tx) (alist-get 'title tx))
    (gdev-assurance--say "  Stato:    %s" (alist-get 'state tx))
    (gdev-assurance--say "  Profilo:  %s" (alist-get 'profile tx))
    (gdev-assurance--say "  Aperta:   %s" (alist-get 'opened_at tx))
    (gdev-assurance--say "  Eventi:")
    (seq-doseq (event (alist-get 'events data))
      (gdev-assurance--render-event event))
    (gdev-assurance--say "  Prove:%s" (if (zerop (length evidence)) " nessuna" ""))
    (seq-doseq (row evidence)
      (gdev-assurance--say "    %s  %-10s %-13s %s  sha256:%s…"
                           (alist-get 'ref row) (alist-get 'kind row) (alist-get 'origin row)
                           (alist-get 'description row)
                           (gdev-assurance--short-hash (alist-get 'sha256 row))))
    (let ((assessments (alist-get 'assessments data)))
      (gdev-assurance--say "  Valutazioni registrate:%s" (if (zerop (length assessments)) " nessuna" ""))
      (seq-doseq (row assessments)
        (gdev-assurance--say "    %s  %s  %-14s %s  (%s)"
                             (alist-get 'ref row) (alist-get 'assessed_at row) (alist-get 'profile row)
                             (mapconcat (lambda (cell) (format "%d %s" (cdr cell) (car cell)))
                                        (cl-remove-if (lambda (cell) (zerop (cdr cell)))
                                                      (alist-get 'summary row))
                                        ", ")
                             (alist-get 'actor row))))
    (let ((decisions (alist-get 'decisions data)))
      (gdev-assurance--say "  Decisioni:%s" (if (zerop (length decisions)) " nessuna" ""))
      (seq-doseq (row decisions)
        (gdev-assurance--say "    %s  %-14s %-8s %s: %s"
                             (alist-get 'ref row) (alist-get 'kind row) (alist-get 'control_id row)
                             (alist-get 'actor row)
                             (replace-regexp-in-string "\n" " " (alist-get 'reason row)))))
    0))

(defun gdev-assurance--render-verify (data)
  "Stampa l'esito di DATA e restituisci lo stato di uscita."
  (let ((problems (alist-get 'problems data)))
    (if (> (length problems) 0)
        (progn (gdev-assurance--say "Problemi trovati (%d):" (length problems))
               (seq-doseq (problem problems) (gdev-assurance--say "  - %s" problem))
               1)
      (gdev-assurance--say "Archivio integro: %s, %s, %s."
                           (gdev-assurance--plural (alist-get 'transactions data) "transazione" "transazioni")
                           (gdev-assurance--plural (alist-get 'events data) "evento" "eventi")
                           (gdev-assurance--plural (alist-get 'evidence data) "prova" "prove"))
      (gdev-assurance--say (concat "Nota: la catena rileva le alterazioni; una riscrittura completa"
                                   " con impronte ricalcolate richiede un'àncora esterna."))
      0)))

(defun gdev-assurance--render-assess (data)
  "Stampa la valutazione DATA e restituisci 1 se un controllo non è
soddisfatto, altrimenti 0."
  (let ((summary (alist-get 'summary data)))
    (gdev-assurance--say "Valutazione di %s: %s%s" (alist-get 'transaction data)
                         (alist-get 'profile_title data)
                         (if (eq (alist-get 'provisional data) t) " (provvisorio)" ""))
    (gdev-assurance--say "  Stato della transazione: %s" (alist-get 'state data))
    (gdev-assurance--say "  Impronta degli ingressi: %s (catena %s, controlli %s)"
                         (gdev-assurance--short-hash (alist-get 'input_digest data))
                         (gdev-assurance--short-hash (alist-get 'chain_head data))
                         (gdev-assurance--short-hash (alist-get 'controls_digest data)))
    (unless (or (null (alist-get 'context_digest data)) (eq :null (alist-get 'context_digest data)))
      (gdev-assurance--say "  Impronta degli artefatti: %s" (gdev-assurance--short-hash (alist-get 'context_digest data))))
    (seq-doseq (result (alist-get 'results data))
      (gdev-assurance--say "  %-8s %-14s %s" (alist-get 'control result) (alist-get 'status result)
                           (alist-get 'title result))
      (gdev-assurance--say "           %s" (alist-get 'reason result)))
    (gdev-assurance--say "Riepilogo: %s"
                         (mapconcat (lambda (cell) (format "%d %s" (cdr cell) (car cell))) summary ", "))
    (let ((recorded (alist-get 'recorded data)))
      (if (eq recorded :null)
          (gdev-assurance--say "Nessuna valutazione registrata per questa transazione.")
        (gdev-assurance--say "Ultima valutazione registrata: %s del %s, %d eventi dopo."
                             (alist-get 'ref recorded) (alist-get 'assessed_at recorded)
                             (alist-get 'events_since recorded))
        (when (eq (alist-get 'controls_changed recorded) t)
          (gdev-assurance--say "  I controlli sono cambiati dopo la registrazione."))
        (when (eq (alist-get 'context_changed recorded) t)
          (gdev-assurance--say "  Gli artefatti sono cambiati dopo la registrazione."))
        (if (zerop (length (alist-get 'changes recorded)))
            (gdev-assurance--say "  Gli esiti non sono cambiati.")
          (seq-doseq (change (alist-get 'changes recorded))
            (gdev-assurance--say "  Cambiato: %s %s → %s" (alist-get 'control change)
                                 (if (eq (alist-get 'before change) :null) "assente" (alist-get 'before change))
                                 (if (eq (alist-get 'after change) :null) "assente" (alist-get 'after change)))))))
    (gdev-assurance--say "%s" (alist-get 'note data))
    (if (gdev-assurance-blocking-result data) 1 0)))

(defun gdev-assurance--render-capability (data)
  "Stampa le osservazioni DATA e restituisci lo stato di uscita."
  (gdev-assurance--say "Capacità osservata: %s · %d transazioni · %s"
                       (alist-get 'scope data) (alist-get 'transactions data) (alist-get 'state data))
  (seq-doseq (row (alist-get 'controls data))
    (gdev-assurance--say "  %s  %s · %d osservazioni"
                         (alist-get 'control row) (alist-get 'title row)
                         (alist-get 'observations row))
    (gdev-assurance--say "    %s"
                         (mapconcat (lambda (pair) (format "%s: %d" (car pair) (cdr pair)))
                                    (alist-get 'statuses row) ", ")))
  (gdev-assurance--say "%s" (alist-get 'note data))
  (if (eq (alist-get 'ok data) t) 0 1))

(defun gdev-assurance--render-trace (data)
  "Stampa gli artefatti e gli archi di DATA."
  (seq-doseq (row (alist-get 'artifacts data))
    (gdev-assurance--say "%s  %-14s %s" (alist-get 'ref row) (alist-get 'role row)
                         (alist-get 'path row)))
  (seq-doseq (row (alist-get 'links data))
    (gdev-assurance--say "%s  %s → %s (%s)" (alist-get 'ref row) (alist-get 'from row)
                         (alist-get 'to row) (alist-get 'relation row)))
  (gdev-assurance--say "%d artefatti, %d relazioni"
                       (alist-get 'artifacts_total data) (alist-get 'links_total data))
  0)

(defun gdev-assurance--render-impact (data)
  "Stampa i file cambiati e gli artefatti raggiungibili di DATA."
  (gdev-assurance--say "File cambiati: %s" (mapconcat #'identity (alist-get 'changed data) ", "))
  (seq-doseq (row (alist-get 'affected data))
    (gdev-assurance--say "  %s  %s" (alist-get 'ref row) (alist-get 'path row)))
  (gdev-assurance--say "%d artefatti coinvolti" (alist-get 'affected_total data))
  0)

(defun gdev-assurance--render-requests (data)
  "Stampa i dati delle richieste DATA da esaminare prima della conferma."
  (gdev-assurance--say "%s" (json-serialize data :null-object :null :false-object :false))
  0)

(defun gdev-assurance--render-standards (data)
  "Stampa il catalogo DATA e gli eventuali obiettivi di uno standard."
  (seq-doseq (row (alist-get 'standards data))
    (gdev-assurance--say "%s · %s · %s · %s · %d obiettivi" (alist-get 'id row) (alist-get 'edition row)
                         (alist-get 'status row) (alist-get 'scope row) (alist-get 'target_count row))
    (gdev-assurance--say "  %s · %s" (alist-get 'title row) (alist-get 'source row))
    (seq-doseq (target (alist-get 'targets row))
      (gdev-assurance--say "  %s · dovuto in %s · prova in %s" (alist-get 'target target)
                           (alist-get 'due target) (alist-get 'proof_state target))
      (let ((definition (alist-get 'definition target)))
        (gdev-assurance--say "    Ruoli: %s · persona: %s · indipendente: %s · valutazione registrata: %s"
                             (mapconcat #'identity (alist-get 'roles definition) ", ")
                             (if (eq t (alist-get 'human definition)) "sì" "no")
                             (if (eq t (alist-get 'independent definition)) "sì" "no")
                             (if (eq t (alist-get 'assessment definition)) "sì" "no"))
        (seq-doseq (edge (alist-get 'trace definition))
          (gdev-assurance--say "    Relazione: %s" (mapconcat #'identity edge " → "))))))
  (gdev-assurance--say "%s" (alist-get 'note data)) 0)

(defun gdev-assurance--render-standard-assess (data)
  "Stampa gli standard di DATA; una scelta assente non dà esito positivo."
  (let ((result (gdev-assurance--render-assess data)))
    (if (eq :null (alist-get 'selection (alist-get 'standards data)))
        (progn (gdev-assurance--say "Nessuno standard scelto: attuazione non verificata.") 1)
      result)))

(defun gdev-assurance--render-project-data (data)
  "Stampa DATA senza trasformare mancanze o prove saltate in successi."
  (princ (decode-coding-string (json-serialize data :null-object :null :false-object :false) 'utf-8-unix))
  (princ "\n")
  (if (or (eq :false (alist-get 'ok data)) (member (alist-get 'status data) '("INCOMPLETE" "MISSING"))) 1 0))

(dolist (command '(work project taxonomy suggest snippets procedures procedure-plan runs model-check))
  (defalias (intern (concat "gdev-assurance--render-" (symbol-name command))) #'gdev-assurance--render-project-data))

(defconst gdev-assurance--usage
  (concat "Uso: gdev assurance status\n"
          "     gdev assurance list [STATO]\n"
          "     gdev assurance show ID\n"
          "     gdev assurance verify\n"
          "     gdev assurance assess ID\n"
          "     gdev assurance capability [PROFILO]\n"
          "     gdev assurance trace\n"
          "     gdev assurance impact [PERCORSO]\n"
          "     gdev assurance requests [RC-ID]\n"
          "     gdev assurance standards [STANDARD]\n"
          "     gdev assurance standard-assess ID\n"
          "Scritture esplicite: open, advance, evidence, assess-record, adopt, recover,\n"
          "documents, hooks, sign, confirm, reject, artifact, link,\n"
          "standard-select, standard-proof, standard-decision, decision.\n"
          "Progetto: project, work ID, taxonomy [ID@CURSORE], suggest ID, snippets,\n"
          "procedures, procedure-plan ID, runs [ID], model-check.\n"
          "Creazione: project-init, project-field, project-requirement, project-bind,\n"
          "work-bind, snippet-preview, snippet-write, procedure-run, procedure-resume,\n"
          "project-report [check]. Vedi docs/assicurazione/progetto-formale.md.")
  "Sintassi dei sottocomandi.")

(defun gdev-assurance-cli (arguments)
  "Esegui il sottocomando esplicito di ARGUMENTS e restituisci lo stato di uscita.
Parte dalla cartella corrente: cerca verso l'alto la radice che ha un archivio."
  (let* ((command (car arguments))
         (operands (cdr arguments))
         (found (gdev-assurance-db-find-root default-directory))
         (root (expand-file-name (or found (locate-dominating-file default-directory ".gdev-assurance/project.eld")
                                     (locate-dominating-file default-directory ".git") default-directory)))
         (state (and (equal command "list") operands (intern (upcase (car operands))))))
    (require 'gdev-assurance-actions)
    (cond
     ((assoc command gdev-assurance-action-contracts)
      (gdev-assurance-actions-cli root command operands))
     ((not (gdev-assurance-operands-p command operands))
      (gdev-assurance--say "%s" gdev-assurance--usage)
      2)
     ((and state (not (memq state gdev-process-states)))
      (gdev-assurance--say "Stato sconosciuto: %s\nStati: %s" (car operands)
                           (mapconcat #'symbol-name gdev-process-states " "))
      2)
     ((and (equal command "capability") operands
           (not (member (car operands) (mapcar #'symbol-name gdev-process-profiles))))
      (gdev-assurance--say "Profilo sconosciuto: %s" (car operands))
      2)
     (t
      (condition-case err
          (let ((data (gdev-assurance-data command root (car operands))))
            (cond
             ((eq (alist-get 'archive data) :false)
              (gdev-assurance--say "Nessun archivio di assicurazione in %s." root)
              (gdev-assurance--say "Il nucleo lo crea alla prima transazione; questo comando non crea nulla.")
              0)
             (t (funcall (intern (concat "gdev-assurance--render-" command)) data))))
        (gdev-assurance-db-missing
         (gdev-assurance--say "Nessun archivio di assicurazione in %s." root)
         1)
        (gdev-assurance-no-transaction
         (gdev-assurance--say "La transazione %s non esiste." (cadr err))
         1)
        (gdev-assurance-error
         (gdev-assurance--say "%s%s" (get (car err) 'error-message)
                              (if (cdr err)
                                  (concat ": " (mapconcat (lambda (datum) (format "%s" datum))
                                                          (cdr err) ", "))
                                ""))
         1)
        (user-error (gdev-assurance--say "%s" (error-message-string err)) 1))))))

(provide 'gdev-assurance)
;;; gdev-assurance.el ends here
