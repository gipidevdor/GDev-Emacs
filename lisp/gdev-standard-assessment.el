;;; gdev-standard-assessment.el --- Attuazione degli standard per transazione -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Scelta umana e criteri fissati nell'audit; ogni obiettivo ha una prova con
;; esito e impronta degli artefatti. Nessun fatto generico soddisfa una clausola.
;; La struttura verificata è originale GDev, non una certificazione normativa.
;;; Code:
(require 'gdev-assurance)
(require 'gdev-standard-catalog)

(defun gdev-standard--digest-p (value)
  "Restituisci non nil per un'impronta SHA-256 VALUE."
  (let ((case-fold-search nil))
    (and (stringp value) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" value))))

(defun gdev-standard--records (db id)
  "Leggi le registrazioni di standard di ID, se lo schema di DB le prevede."
  (when (>= (gdev-assurance-db-version db) 6) (gdev-record-list db id 'standard)))

(defun gdev-standard-selection (db id)
  "Restituisci l'ultima scelta degli standard di ID, oppure nil."
  (car (last (seq-filter (lambda (row) (equal "selection" (alist-get 'type (gdev-record-data row))))
                         (gdev-standard--records db id)))))

(defun gdev-standard--definition (selection target)
  "Restituisci la definizione fissata da SELECTION per TARGET."
  (let ((data (gdev-record-data selection)) (standard (car (split-string target "#"))))
    (unless (member target (append (alist-get 'targets data) nil))
      (gdev-process-refuse "Obiettivo fuori dalla scelta: %s" target))
    (or (seq-find (lambda (definition) (equal standard (alist-get 'id definition)))
                  (alist-get 'definitions data))
        (gdev-process-refuse "Definizione assente per %s" target))))

(defun gdev-standard--choice-data (specifications reason)
  "Risolvi SPECIFICATIONS e REASON nei dati immutabili di una scelta."
  (gdev-process-check-line "Il motivo della scelta" reason 1000)
  (unless (and (proper-list-p specifications) specifications (cl-every #'stringp specifications))
    (gdev-process-refuse "Indica almeno uno standard o obiettivo"))
  (gdev-standards-with-cache
   (lambda ()
     (let (targets definitions ids)
       (dolist (spec specifications)
         (dolist (target (gdev-standard-catalog-resolve spec))
           (let ((id (plist-get target :standard)))
             (push (concat id "#" (plist-get target :clause)) targets)
             (unless (member id ids)
               (push id ids) (push (gdev-standard-catalog-definition target) definitions)))))
       (setq targets (sort (delete-dups targets) #'string-lessp))
       (unless (<= (length targets) 512) (gdev-process-refuse "La scelta supera 512 obiettivi"))
       `((type . "selection") (targets . ,(vconcat targets))
         (definitions . ,(vconcat (sort definitions (lambda (a b) (string-lessp (alist-get 'id a) (alist-get 'id b))))))
         (reason . ,reason))))))

(defun gdev-standard--event (db ref)
  "Leggi l'evento che introduce REF."
  (car (gdev-assurance-db-select db "select * from tx_event where ref = ? and kind in ('record','evidence')" (list ref))))

(defun gdev-standard--evidence (db id ref)
  "Leggi da DB la prova REF della transazione ID."
  (seq-find (lambda (row) (equal ref (alist-get 'ref row))) (gdev-evidence-list db id)))

(defun gdev-standard--data (db tx data)
  "Controlla DATA come registrazione storica di TX in DB."
  (pcase (alist-get 'type data)
    ("selection"
     (gdev-record-fields data '(type targets definitions reason))
     (gdev-process-check-line "Il motivo" (alist-get 'reason data) 1000)
     (unless (and (vectorp (alist-get 'targets data)) (< 0 (length (alist-get 'targets data)) 513)
                  (cl-every (lambda (target) (and (stringp target) (<= (length target) 180)
                                                  (= 2 (length (split-string target "#")))))
                            (alist-get 'targets data))
                  (= (length (alist-get 'targets data)) (length (delete-dups (append (alist-get 'targets data) nil))))
                  (vectorp (alist-get 'definitions data)))
       (gdev-process-refuse "Scelta degli standard non valida"))
     (let (seen)
       (seq-doseq (definition (alist-get 'definitions data))
         (gdev-record-fields definition '(id edition digest scope due proof_state roles trace human independent assessment))
         (gdev-process-check-line "Lo standard" (alist-get 'id definition) 100)
         (gdev-process-check-line "L'edizione" (alist-get 'edition definition) 100)
         (unless (and (not (member (alist-get 'id definition) seen))
                      (gdev-standard--digest-p (alist-get 'digest definition))
                      (member (alist-get 'scope definition) '("documento" "clausola"))
                      (member (alist-get 'due definition) '("REVIEWING" "APPROVED" "BASELINED"))
                      (member (alist-get 'proof_state definition) '("VERIFYING" "REVIEWING"))
                      (vectorp (alist-get 'roles definition)) (vectorp (alist-get 'trace definition))
                      (cl-every (lambda (role) (member role (mapcar #'symbol-name gdev-trace-roles)))
                                (alist-get 'roles definition))
                      (cl-every (lambda (edge) (and (vectorp edge) (= 3 (length edge))
                                                  (member (aref edge 0) (mapcar #'symbol-name gdev-trace-roles))
                                                  (member (aref edge 1) (mapcar #'symbol-name gdev-trace-relations))
                                                  (member (aref edge 2) (mapcar #'symbol-name gdev-trace-roles))))
                                (alist-get 'trace definition))
                      (cl-every (lambda (key) (memq (alist-get key definition) '(t :false))) '(human independent assessment)))
           (gdev-process-refuse "Definizione degli standard non valida"))
         (push (alist-get 'id definition) seen))
       (seq-doseq (target (alist-get 'targets data))
         (unless (member (car (split-string target "#")) seen) (gdev-process-refuse "Obiettivo senza definizione")))))
    ((or "proof" "decision")
     (let* ((proof (equal (alist-get 'type data) "proof"))
            (selection (gdev-record-get db (alist-get 'selection data))))
       (gdev-record-fields data (if proof '(type selection target evidence evidence_digest input_digest verdict)
                                 '(type selection target verdict reason)))
       (unless (and (eq 'standard (alist-get 'kind selection))
                    (equal "selection" (alist-get 'type (gdev-record-data selection)))
                    (equal (alist-get 'id tx) (alist-get 'tx_id selection)))
         (gdev-process-refuse "La registrazione non cita una scelta della stessa transazione"))
       (gdev-standard--definition selection (alist-get 'target data))
       (if proof
           (let ((evidence (gdev-standard--evidence db (alist-get 'id tx) (alist-get 'evidence data))))
             (unless (and evidence (eq 'fact (alist-get 'kind evidence)) (eq 'collected (alist-get 'origin evidence))
                          (equal (alist-get 'evidence_digest data) (alist-get 'sha256 evidence))
                          (gdev-standard--digest-p (alist-get 'input_digest data))
                          (member (alist-get 'verdict data) '("pass" "fail")))
               (gdev-process-refuse "La verifica richiede una prova raccolta, la sua impronta e un esito")))
         (unless (member (alist-get 'verdict data) '("not-applicable" "waiver" "revoke"))
           (gdev-process-refuse "Decisione sullo standard non valida"))
         (gdev-process-check-line "Il motivo" (alist-get 'reason data) 1000)
         (when (and (eq 'critical (alist-get 'profile tx)) (equal "waiver" (alist-get 'verdict data)))
           (gdev-process-refuse "Il profilo critical non accetta deroghe")))))
    (_ (gdev-process-refuse "Genere di registrazione dello standard non valido"))))

(defun gdev-standard--authority (data actor-kind)
  "Controlla l'autorità ACTOR-KIND per DATA."
  (when (and (member (alist-get 'type data) '("selection" "decision")) (not (eq actor-kind 'human)))
    (gdev-process-refuse "Scelta degli standard e decisioni richiedono una persona")))

(defun gdev-standard--row (db row)
  "Verifica l'autorità e l'ordine storico della registrazione ROW."
  (let* ((data (gdev-record-data row)) (event (gdev-standard--event db (alist-get 'ref row)))
         (kind (alist-get 'type data)))
    (gdev-standard--authority data (alist-get 'actor_kind row))
    (when (equal kind "decision")
      (when-let* ((reason (gdev-decision--rule-separation
                          (list :db db :tx (gdev-process-get db (alist-get 'tx_id row)) :actor (alist-get 'actor row)))))
        (gdev-process-refuse "%s" reason)))
    (if (equal kind "selection")
        (unless (and (member (alist-get 'from_state event) '("PROPOSED" "CLASSIFIED" "ANALYZED"))
                     (not (sqlite-select db "select seq from tx_event where tx_id = ? and kind = 'transition'
 and to_state = 'AUTHORIZED' and seq < ?" (list (alist-get 'tx_id row) (alist-get 'seq event)))))
          (gdev-process-refuse "Scelta registrata dopo l'autorizzazione"))
      (let* ((selection (gdev-record-get db (alist-get 'selection data)))
             (before (gdev-standard--event db (alist-get 'ref selection))))
        (unless (< (alist-get 'seq before) (alist-get 'seq event))
          (gdev-process-refuse "La registrazione precede la scelta degli standard"))
        (when (equal kind "proof")
          (let* ((definition (gdev-standard--definition selection (alist-get 'target data)))
                 (evidence (gdev-standard--event db (alist-get 'evidence data))))
            (unless (and (< (alist-get 'seq before) (alist-get 'seq evidence) (alist-get 'seq event))
                         (equal (alist-get 'from_state evidence) (alist-get 'proof_state definition))
                         (equal (alist-get 'from_state event) (alist-get 'proof_state definition))
                         (or (not (eq t (alist-get 'human definition))) (eq 'human (alist-get 'actor_kind row))))
              (gdev-process-refuse "La prova non appartiene alla fase o all'attore richiesto"))
            (let* ((entry (gdev-standard--entry (gdev-process-events db (alist-get 'tx_id row))
                                               (alist-get 'proof_state definition) (alist-get 'seq event)))
                   (inputs (gdev-assurance-db-select db "select r.kind, r.digest from assurance_record r
 join tx_event e on e.ref = printf('RC-%04d', r.id) and e.kind = 'record'
 where r.tx_id = ? and r.kind in ('artifact','trace') and e.seq < ? order by r.id"
                                                     (list (alist-get 'tx_id row) (alist-get 'seq event))))
                   (digest (gdev-evidence-sha256
                            (gdev-record-encode
                             `((artifacts . ,(vconcat (mapcar (lambda (item) (alist-get 'digest item))
                                                              (seq-filter (lambda (item) (equal "artifact" (alist-get 'kind item))) inputs))))
                               (links . ,(vconcat (mapcar (lambda (item) (alist-get 'digest item))
                                                          (seq-filter (lambda (item) (equal "trace" (alist-get 'kind item))) inputs)))))))))
              (unless (and entry (< (alist-get 'seq entry) (alist-get 'seq evidence))
                           (equal digest (alist-get 'input_digest data))
                           (or (not (eq t (alist-get 'independent definition)))
                               (not (equal (alist-get 'actor row) (alist-get 'actor entry)))))
                (gdev-process-refuse "Gli ingressi o l'indipendenza della prova non corrispondono alla storia")))))))))

(defun gdev-standard--context (db id)
  "Raccogli gli ingressi di ID una sola volta, senza leggere fuori dal progetto."
  (let* ((records (gdev-standard--records db id))
         (selection (car (last (seq-filter (lambda (row) (equal "selection" (alist-get 'type (gdev-record-data row)))) records))))
         (events (gdev-process-events db id))
         (artifacts (and selection (gdev-record-list db id 'artifact)))
         (links (and selection (gdev-record-list db id 'trace)))
         (latest (make-hash-table :test #'equal))
         (proofs (make-hash-table :test #'equal)) (decisions (make-hash-table :test #'equal)) changed file-states)
    (dolist (row records)
      (let ((data (gdev-record-data row)))
        (when (equal (alist-get 'selection data) (alist-get 'ref selection))
          (pcase (alist-get 'type data)
            ("proof" (puthash (alist-get 'target data) row proofs))
            ("decision" (puthash (alist-get 'target data) row decisions))))))
    (dolist (row artifacts) (puthash (alist-get 'path (gdev-record-data row)) row latest))
    (when selection
      (let* ((main (cl-find "main" (sqlite-select db "pragma database_list") :key #'cadr :test #'equal))
             (root (gdev-trace-root db (expand-file-name "../.." (file-name-directory (nth 2 main))))))
        (maphash
         (lambda (path row)
           (let* ((data (gdev-record-data row)) (file (expand-file-name path root))
                  (mode (if (file-symlink-p file) "symlink" "file"))
                  (actual (condition-case nil
                              (when (and (equal path (gdev-trace-relative root path))
                                         (or (file-symlink-p file) (and (file-regular-p file) (file-in-directory-p (file-truename file) root))))
                                (gdev-trace-file-sha256 file)) (error nil))))
             (push `((path . ,path) (mode . ,mode) (digest . ,(or actual :null))) file-states)
             (unless (and (equal mode (or (alist-get 'mode data) "file")) (equal actual (alist-get 'sha256 data)))
               (push path changed)))) latest)))
    (list :selection selection :records records :events events :artifacts (hash-table-values latest) :links links
          :proofs proofs :decisions decisions :structure-cache (make-hash-table :test #'equal)
          :changed changed :files-digest (gdev-evidence-sha256
                                          (gdev-record-encode `((files . ,(vconcat (sort file-states
                                                                                       (lambda (a b) (string-lessp (alist-get 'path a) (alist-get 'path b)))))))))
          :input (gdev-evidence-sha256
                                   (gdev-record-encode `((artifacts . ,(vconcat (mapcar (lambda (row) (alist-get 'digest row)) artifacts)))
                                                        (links . ,(vconcat (mapcar (lambda (row) (alist-get 'digest row)) links)))))))))

(defun gdev-standard--entry (events state &optional before)
  "Trova l'ultimo ingresso in STATE tra EVENTS prima di BEFORE, se indicato."
  (car (last (seq-filter (lambda (event) (and (memq (alist-get 'kind event) '(open transition))
                                              (eq (alist-get 'to_state event) (intern state))
                                              (or (null before) (< (alist-get 'seq event) before)))) events))))

(defun gdev-standard--structure (context definition)
  "Restituisci la carenza strutturale di CONTEXT rispetto a DEFINITION."
  (let* ((artifacts (plist-get context :artifacts))
         (rows (mapcar (lambda (row) (cons (alist-get 'ref row) (gdev-record-data row))) artifacts)))
    (or
     (seq-some (lambda (role)
                 (unless (seq-some (lambda (row) (equal role (alist-get 'role (cdr row)))) rows)
                   (format "Manca un artefatto del ruolo %s" role))) (alist-get 'roles definition))
     (seq-some
      (lambda (edge)
        (when (seq-some
               (lambda (from)
                 (and (equal (aref edge 0) (alist-get 'role (cdr from)))
                      (not (seq-some
                            (lambda (row)
                              (let* ((link (gdev-record-data row)) (to (assoc (alist-get 'to link) rows)))
                                (and (equal (car from) (alist-get 'from link))
                                     (equal (aref edge 1) (alist-get 'relation link))
                                     (equal (aref edge 2) (alist-get 'role (cdr to))))))
                            (plist-get context :links))))) rows)
          (format "Tracciabilità incompleta: %s → %s → %s" (aref edge 0) (aref edge 1) (aref edge 2))))
      (alist-get 'trace definition)))))

(defun gdev-standard--rule (context)
  "Controlla la scrittura dello standard descritta da CONTEXT."
  (let* ((db (plist-get context :db)) (tx (plist-get context :tx)) (data (plist-get context :data))
         (id (alist-get 'id tx)) (type (alist-get 'type data)))
    (gdev-standard--authority data (plist-get context :actor-kind))
    (when (equal type "decision")
      (when-let* ((reason (gdev-decision--rule-separation context))) (gdev-process-refuse "%s" reason)))
    (if (equal type "selection")
        (progn
          (unless (and (memq (alist-get 'state tx) '(PROPOSED CLASSIFIED ANALYZED))
                       (not (seq-some (lambda (event) (eq 'AUTHORIZED (alist-get 'to_state event))) (gdev-process-events db id))))
            (gdev-process-refuse "Scegli gli standard prima dell'autorizzazione"))
          (unless (equal (gdev-record-json data)
                         (gdev-record-json (gdev-standard--choice-data (append (alist-get 'targets data) nil) (alist-get 'reason data))))
            (gdev-process-refuse "La scelta non corrisponde al catalogo corrente")))
      (unless (equal (alist-get 'selection data) (alist-get 'ref (gdev-standard-selection db id)))
        (gdev-process-refuse "La scelta citata è stata sostituita"))
      (when (equal type "proof")
        (let* ((ctx (gdev-standard--context db id)) (definition (gdev-standard--definition (plist-get ctx :selection) (alist-get 'target data)))
               (current (car (gdev-standard-catalog-resolve (alist-get 'target data))))
               (entry (gdev-standard--entry (plist-get ctx :events) (alist-get 'proof_state definition)))
               (ev (gdev-standard--event db (alist-get 'evidence data)))
               (selected (gdev-standard--event db (alist-get 'selection data))))
          (unless (and (equal (plist-get current :digest) (alist-get 'digest definition))
                       (equal (symbol-name (alist-get 'state tx)) (alist-get 'proof_state definition)) entry
                       (< (max (alist-get 'seq entry) (alist-get 'seq selected)) (alist-get 'seq ev))
                       (equal (alist-get 'from_state ev) (alist-get 'proof_state definition))
                       (equal (plist-get ctx :input) (alist-get 'input_digest data))
                       (null (plist-get ctx :changed))
                       (or (not (eq t (alist-get 'human definition))) (eq 'human (plist-get context :actor-kind)))
                       (or (not (eq t (alist-get 'independent definition)))
                           (not (equal (plist-get context :actor) (alist-get 'actor entry)))))
            (gdev-process-refuse "Prova superata, fase/attore non ammessi o artefatti cambiati")))))
    nil))

(gdev-record-register 'standard #'gdev-standard--data #'gdev-standard--rule #'gdev-standard--row)

(cl-defun gdev-standard-select (db id specifications reason &key actor actor-kind)
  "Fissa gli standard SPECIFICATIONS per ID con REASON, scelti da ACTOR."
  (gdev-record-add db id 'standard (gdev-standard--choice-data specifications reason) :actor actor :actor-kind actor-kind))

(cl-defun gdev-standard-proof (db id target evidence verdict &key actor actor-kind)
  "Registra VERDICT di TARGET usando EVIDENCE raccolta per ID."
  (let* ((selection (gdev-standard-selection db id)) (ctx (gdev-standard--context db id))
         (ev (gdev-standard--evidence db id evidence)))
    (gdev-record-add db id 'standard `((type . "proof") (selection . ,(alist-get 'ref selection))
                                      (target . ,target) (evidence . ,evidence) (verdict . ,verdict)
                                      (evidence_digest . ,(alist-get 'sha256 ev)) (input_digest . ,(plist-get ctx :input)))
                     :actor actor :actor-kind actor-kind)))

(cl-defun gdev-standard-proof-file (db id target verdict file &key actor actor-kind)
  "Registra FILE e VERDICT per TARGET di ID nella stessa transazione SQL."
  (gdev-assurance-db-transaction
   db (lambda ()
        (let ((ev (gdev-evidence-add db id :kind 'fact :origin 'collected :description (concat "Verifica GDev " target)
                                    :file file :actor actor :actor-kind actor-kind)))
          (gdev-standard-proof db id target ev verdict :actor actor :actor-kind actor-kind)))))

(cl-defun gdev-standard-decision (db id target verdict reason &key actor actor-kind)
  "Registra la decisione umana VERDICT e REASON su TARGET di ID."
  (gdev-record-add db id 'standard `((type . "decision") (selection . ,(alist-get 'ref (gdev-standard-selection db id)))
                                    (target . ,target) (verdict . ,verdict) (reason . ,reason)) :actor actor :actor-kind actor-kind))

(defun gdev-standard--evaluate (db tx ctx target definition problems &optional entering)
  "Valuta TARGET secondo DEFINITION su CTX, considerando l'ingresso ENTERING."
  (let* ((events (plist-get ctx :events))
         (current (car (condition-case nil (gdev-standard-catalog-resolve target) (error nil))))
         (stale (not (equal (plist-get current :digest) (alist-get 'digest definition))))
         (due (or stale (equal entering (alist-get 'due definition)) (gdev-standard--entry events (alist-get 'due definition))))
         (proof (gethash target (plist-get ctx :proofs)))
         (decision (gethash target (plist-get ctx :decisions)))
         (data (and proof (gdev-record-data proof)))
         (proof-event (and proof (gdev-standard--event db (alist-get 'ref proof))))
         (entry (gdev-standard--entry events (alist-get 'proof_state definition)))
         (ev-event (and proof (gdev-standard--event db (alist-get 'evidence data))))
         (cached (gethash (alist-get 'digest definition) (plist-get ctx :structure-cache)))
         (structural (if cached (car cached)
                       (let ((result (gdev-standard--structure ctx definition)))
                         (puthash (alist-get 'digest definition) (list result) (plist-get ctx :structure-cache)) result))) status reason)
    (cond
     (problems (setq status "NOT_SATISFIED" reason "Archivio non integro"))
     ((memq (alist-get 'state tx) '(REJECTED CANCELLED))
      (setq status "NOT_APPLICABLE" reason "La transazione è stata rifiutata o annullata"))
     (stale (setq status "NOT_VERIFIED" reason "Definizione cambiata o non più verificabile: serve una nuova scelta"))
     ((null due) (setq status "NOT_VERIFIED" reason "Il controllo non è ancora dovuto"))
     ((plist-get ctx :changed) (setq status "NOT_VERIFIED" reason (format "Artefatti cambiati o assenti: %s" (plist-get ctx :changed))))
     ((or (null proof) (null entry) (<= (alist-get 'seq ev-event) (alist-get 'seq entry))
          (not (equal (alist-get 'input_digest data) (plist-get ctx :input))))
      (setq status "NOT_VERIFIED" reason "Manca una prova specifica per la scelta, gli artefatti e il ciclo correnti"))
     ((equal "fail" (alist-get 'verdict data)) (setq status "NOT_SATISFIED" reason "La verifica specifica riporta un esito negativo"))
     (structural (setq status "NOT_SATISFIED" reason structural))
     ((and (eq t (alist-get 'assessment definition)) (null (gdev-assessment-store-list db (alist-get 'id tx))))
      (setq status "NOT_SATISFIED" reason "Manca una valutazione registrata"))
     ((and (eq t (alist-get 'independent definition)) (equal (alist-get 'actor proof) (alist-get 'actor entry)))
      (setq status "NOT_SATISFIED" reason "La verifica non è indipendente"))
     (t (setq status "SATISFIED" reason "Prova specifica con esito positivo e struttura GDev verificata")))
    ;; L'integrità e la validità della definizione non si possono derogare.
    (when (and decision (null problems) (not stale) (not (equal status "NOT_APPLICABLE")))
      (let* ((choice (gdev-record-data decision)) (verdict (alist-get 'verdict choice)))
        (cond ((equal verdict "not-applicable")
               (setq status "NOT_APPLICABLE" reason (format "Non applicabile per %s: %s" (alist-get 'actor decision) (alist-get 'reason choice))))
              ((and (equal verdict "waiver") (not (equal status "SATISFIED")))
               (setq reason (format "Deroga di %s: %s. Senza la deroga: %s, %s"
                                    (alist-get 'actor decision) (alist-get 'reason choice) status reason)
                     status "WAIVED_WITH_AUTHORIZATION")))))
    `((control . ,(concat "STD-" (replace-regexp-in-string "#" ":" target)))
      (title . ,(concat "Verifica GDev · " target)) (status . ,status) (reason . ,reason) (due . ,(if due t :false))
      (events . ,(if proof-event (vector (alist-get 'seq proof-event)) []))
      (evidence . ,(if proof (vector (alist-get 'evidence data)) []))
      (decisions . ,(if decision (vector (alist-get 'ref decision)) []))
      (references . ,(vector (concat target " · " (alist-get 'edition definition) " · " (alist-get 'scope definition)))))))

(defun gdev-standard-assessment (db id &optional problems entering)
  "Valuta gli standard scelti per ID, senza modificare DB o certificare conformità."
  (gdev-standards-with-cache
   (lambda ()
     (gdev-assurance-db-read-transaction
      db (lambda ()
           (let* ((tx (gdev-process-require db id)) (ctx (gdev-standard--context db id))
                  (selection (plist-get ctx :selection))
                  (data (and selection (gdev-record-data selection)))
                  (definitions (mapcar
                                (lambda (definition)
                                  (let ((current (condition-case nil
                                                     (car (gdev-standard-catalog-targets (alist-get 'id definition)))
                                                   (error nil))))
                                    `((id . ,(alist-get 'id definition)) (digest . ,(or (plist-get current :digest) :null)))))
                                (append (alist-get 'definitions data) nil))))
             `((selection . ,(if selection (alist-get 'ref selection) :null))
               (context_digest . ,(if selection (gdev-evidence-sha256 (concat (plist-get ctx :input) "\n" (plist-get ctx :files-digest))) :null))
               (definition_digest . ,(if data (gdev-evidence-sha256
                                               (gdev-record-json `((choice . ,(alist-get 'digest selection))
                                                                   (current . ,(vconcat definitions))))) :null))
               (results . ,(vconcat (mapcar (lambda (target)
                                             (gdev-standard--evaluate db tx ctx target (gdev-standard--definition selection target)
                                                                      problems entering)) (append (alist-get 'targets data) nil))))
               (note . ,gdev-standard-catalog-note))))))))

(defun gdev-standard-transition-rule (context)
  "Nega il passaggio di CONTEXT se mancano i controlli dovuti."
  (let* ((db (plist-get context :db)) (id (alist-get 'id (plist-get context :tx)))
         (target (symbol-name (plist-get context :target))))
    (when (and (member target '("REVIEWING" "APPROVED" "BASELINED")) (gdev-standard-selection db id))
      (let* ((assessment (gdev-standard-assessment db id (gdev-assurance-verify db) target))
             (failed (gdev-assurance-blocking-result assessment)))
        (when failed (format "%s: %s" (alist-get 'control failed) (alist-get 'reason failed)))))))

(defun gdev-standard--git-bytes (root &rest arguments)
  "Leggi oggetti Git con ARGUMENTS in ROOT senza filtri o conversioni di testo."
  (let ((default-directory root) (coding-system-for-read 'no-conversion))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (unless (zerop (apply #'process-file "git" nil t nil "--no-replace-objects" "--no-optional-locks"
                           "-c" "core.fsmonitor=false" arguments))
        (gdev-process-refuse "Git non può leggere gli oggetti da verificare"))
      (buffer-string))))

(defun gdev-standard-staged-problems (db id root tree)
  "Confronta gli artefatti di ID con l'albero immutabile TREE da firmare."
  (when (gdev-standard-selection db id)
    (gdev-trace-root db root)
    (unless (and (stringp tree) (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" tree))
      (gdev-process-refuse "Albero Git non valido"))
    (let ((entries (make-hash-table :test #'equal)) (digests (make-hash-table :test #'equal)) problems)
      (dolist (entry (split-string (gdev-standard--git-bytes root "ls-tree" "-rz" "--full-tree" tree) "\0" t))
        (when (string-match "\\`\\([0-9]+\\) blob \\([0-9a-f]+\\)\t\\(.+\\)\\'" entry)
          (puthash (decode-coding-string (match-string 3 entry) 'utf-8-unix)
                   (cons (match-string 1 entry) (match-string 2 entry)) entries)))
      (dolist (row (plist-get (gdev-standard--context db id) :artifacts))
        (let* ((data (gdev-record-data row)) (path (alist-get 'path data)) (entry (gethash path entries))
               (oid (cdr entry))
               (digest (and oid (or (gethash oid digests)
                                    (puthash oid (secure-hash 'sha256 (gdev-standard--git-bytes root "cat-file" "blob" oid)) digests)))))
          (unless (and (equal digest (alist-get 'sha256 data))
                       (if (equal "symlink" (alist-get 'mode data)) (equal "120000" (car entry))
                         (member (car entry) '("100644" "100755"))))
            (push path problems))))
      (sort problems #'string-lessp))))

(provide 'gdev-standard-assessment)
;;; gdev-standard-assessment.el ends here
