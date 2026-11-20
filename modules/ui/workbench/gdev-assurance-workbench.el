;;; gdev-assurance-workbench.el --- Assicurazione nel progetto -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Una vista per spazio, una sola fonte dei dati nel nucleo. I ridisegni
;; usano l'istantanea già letta; le scritture restano nelle entrate comuni.
;;; Code:
(require 'button)
(require 'text-property-search)
(require 'gdev-ui)
(require 'gdev-layout)
(require 'gdev-activity)
(require 'gdev-command-context)
(require 'gdev-assurance-workspace)
(require 'gdev-documents)

(declare-function gdev-close-document "gdev-commands" ())
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))

(defconst gdev-assurance--sections
  '((project . "Progetto") (transactions . "Transazioni") (controls . "Controlli") (standards . "Standard")
    (taxonomy . "Tassonomie") (procedures . "Procedure") (runs . "Esecuzioni")
    (trace . "Tracce") (requests . "Proposte") (documents . "Documenti")
    (capability . "Capacità") (verify . "Audit") (impact . "Impatto")))
(defconst gdev-assurance--states
  (cdr (assq 'state gdev-assurance-labels)))
(defconst gdev-assurance--results
  (mapcar (lambda (entry)
            (list (car entry) (gdev-assurance-label 'result (car entry)) (cadr entry)))
          '(("SATISFIED" gdev-ui-status-success) ("NOT_SATISFIED" gdev-ui-status-error)
            ("NOT_VERIFIED" gdev-ui-status-warning) ("NOT_APPLICABLE" gdev-ui-secondary)
            ("WAIVED_WITH_AUTHORIZATION" gdev-ui-status-warning))))
(defconst gdev-assurance--page-size 30)
(defvar-local gdev-assurance--root nil)
(defvar-local gdev-assurance--space nil)
(defvar-local gdev-assurance--transaction nil)
(defvar-local gdev-assurance--section 'transactions)
(defvar-local gdev-assurance--standard nil)
(defvar-local gdev-assurance--model nil)
(defvar-local gdev-assurance--error nil)
(defvar-local gdev-assurance--notice nil)
(defvar-local gdev-assurance--notice-face 'gdev-ui-status-success)
(defvar-local gdev-assurance--filter "")
(defvar-local gdev-assurance--page 0)
(defvar-local gdev-assurance--width nil)
(defvar-local gdev-assurance--source-file nil)
(defvar-local gdev-assurance--receipt nil)
(defvar-local gdev-assurance--reader-process nil)
(defvar-local gdev-assurance--model-request nil)
(defvar gdev-assurance--selected-row nil)
(defvar gdev-assurance-filter-history nil)

(defun gdev-assurance--state-label (state)
  "Restituisci l'etichetta italiana di STATE, simbolo o testo."
  (let ((name (if (symbolp state) (symbol-name state) state)))
    (gdev-assurance-label 'state name)))

(defun gdev-assurance--project-root (&optional root)
  "Ricava la radice locale ROOT dal contesto effettivo del comando."
  (let ((directory (or root (and (derived-mode-p 'gdev-assurance-mode) gdev-assurance--root)
                       (gdev-command-directory))))
    (unless (and (stringp directory) (not (file-remote-p directory)) (file-directory-p directory))
      (user-error "Scegli una cartella locale per l'assicurazione"))
    (let* ((project (if root directory (gdev-command-project)))
           (archive (and (not root) (gdev-assurance-db-find-root directory)))
           (base (or root (and archive (string-prefix-p project archive) archive) project directory)))
      (file-name-as-directory (file-truename base)))))

(defun gdev-assurance--button (label command identity &optional help)
  "Inserisci LABEL con COMMAND e identità stabile IDENTITY."
  (insert-text-button label 'type 'gdev-ui-action 'gdev-assurance-focus identity
                      'help-echo (or help label)
                      'action (lambda (_) (if (commandp command) (call-interactively command) (funcall command)))))

(defun gdev-assurance--actions (actions)
  "Disponi ACTIONS alla larghezza effettiva della vista."
  (let ((start (point)))
    (gdev-ui-insert-actions actions (gdev-ui-buffer-pixel-width))
    (let ((end (point)) (remaining actions) button)
      (save-excursion
        (goto-char start)
        (while (and (setq button (next-button (point) t)) (< (button-start button) end))
          (button-put button 'gdev-assurance-focus (list 'action (nth 2 (pop remaining))))
          (goto-char (button-end button)))))))

(defun gdev-assurance--row (identity title text &optional command)
  "Inserisci una voce con IDENTITY, TITLE, TEXT e COMMAND facoltativo."
  (let ((start (point)))
    (if command (gdev-assurance--button title command identity title)
      (insert (propertize title 'face 'gdev-ui-view-heading 'gdev-assurance-focus identity)))
    (insert "\n" text "\n")
    (add-text-properties start (point) (list 'gdev-assurance-row identity))))

(defun gdev-assurance--entries (rows identity render)
  "Filtra e pagina ROWS; IDENTITY e RENDER descrivono ogni voce."
  (let* ((selected gdev-assurance--selected-row)
         (query (regexp-quote gdev-assurance--filter)) (case-fold-search t)
         (rows (if (string-empty-p query) rows
                 (seq-filter (lambda (row) (string-match-p query (format "%S" row))) rows)))
         (position (and selected (seq-position rows selected (lambda (row key) (equal (funcall identity row) key)))))
         (page (if position (/ position gdev-assurance--page-size)
                 (max 0 (min gdev-assurance--page (/ (max 0 (1- (length rows))) gdev-assurance--page-size)))))
         (start (* page gdev-assurance--page-size)))
    (setq gdev-assurance--page page)
    (when (> (length rows) gdev-assurance--page-size)
      (when (> page 0) (gdev-assurance--button "‹ Precedenti" #'gdev-assurance-previous '(page previous)) (insert "   "))
      (when (< (+ start gdev-assurance--page-size) (length rows))
        (gdev-assurance--button "Successive ›" #'gdev-assurance-next '(page next)) (insert "   "))
      (insert (propertize (format "%d–%d di %d\n" (1+ start) (min (length rows) (+ start gdev-assurance--page-size)) (length rows))
                          'face 'gdev-ui-secondary)))
    (if rows
        (dolist (row (seq-take (nthcdr start rows) gdev-assurance--page-size))
          (let ((begin (point)))
            (funcall render row)
            (add-text-properties begin (point) (list 'gdev-assurance-row (funcall identity row))))
          (insert "\n"))
      (insert (propertize (if (string-empty-p query) "Nessuna voce disponibile.\n" "Nessuna voce corrisponde al filtro.\n")
                          'face 'gdev-ui-secondary)))))

(defun gdev-assurance--read-model ()
  "Leggi i dati richiesti dalla vista su una sola istantanea dell'archivio."
  (gdev-assurance-project-data
   gdev-assurance--root gdev-assurance--transaction
   (when (memq gdev-assurance--section '(standards trace requests capability verify impact project taxonomy procedures runs))
     (symbol-name gdev-assurance--section))
   (cond ((memq gdev-assurance--section '(standards taxonomy)) gdev-assurance--standard)
         ((eq gdev-assurance--section 'runs) gdev-assurance--transaction))
   (unless (memq gdev-assurance--section '(taxonomy runs)) gdev-assurance-data-limit)
   gdev-assurance--section))

(defun gdev-assurance--stop-reader ()
  "Annulla soltanto la lettura avviata da questa vista."
  (let ((process gdev-assurance--reader-process))
    (setq gdev-assurance--reader-process nil)
    (when (and process (process-live-p process)) (delete-process process))))

(defun gdev-assurance--reader-finished (process view frame space request output diagnostics)
  "Consegna PROCESS soltanto a VIEW e REQUEST ancora correnti."
  (when (and (memq (process-status process) '(exit signal failed))
             (not (process-get process 'gdev-assurance-delivered)))
    ;; Lo stato finale può precedere l'ultimo blocco ancora nel pipe.
    ;; Prenota la consegna prima di accettare output e sentinelle rientranti.
    (process-put process 'gdev-assurance-delivered t)
    (let ((process-adaptive-read-buffering nil))
      (while (accept-process-output process 0))
      (when-let* ((stderr (and (buffer-live-p diagnostics) (get-buffer-process diagnostics))))
        (while (accept-process-output stderr 0))))
    (unwind-protect
        (when (and (buffer-live-p view) (frame-live-p frame) (gdev-workspace-state-find space frame))
          (with-current-buffer view
            (when (and (eq process gdev-assurance--reader-process) (eq space gdev-assurance--space)
                       (equal request (list gdev-assurance--root gdev-assurance--transaction
                                            gdev-assurance--section gdev-assurance--standard)))
              (setq gdev-assurance--reader-process nil)
              (condition-case failure
                  (if (and (eq 'exit (process-status process)) (zerop (process-exit-status process)))
                      (setq gdev-assurance--model-request request
                            gdev-assurance--model
                            (with-current-buffer output
                              (json-parse-string (buffer-string) :object-type 'alist :array-type 'array
                                                 :null-object :null :false-object :false)))
                    (error "%s" (concat (with-current-buffer output (buffer-string))
                                        (with-current-buffer diagnostics (buffer-string)))))
                (error (setq gdev-assurance--error (error-message-string failure))))
              (gdev-assurance--render))))
      (when (buffer-live-p output) (kill-buffer output))
      (when (buffer-live-p diagnostics) (kill-buffer diagnostics)))))

(defun gdev-assurance--read-async ()
  "Leggi archivio e sorgenti fuori dal processo grafico."
  (gdev-assurance--stop-reader)
  (let* ((view (current-buffer)) (frame (selected-frame))
         (space gdev-assurance--space) (root gdev-assurance--root)
         (tx gdev-assurance--transaction) (section gdev-assurance--section)
         (standard gdev-assurance--standard)
         (request (list root tx section standard))
         (output (generate-new-buffer " *gdev-assurance-reader*"))
         (diagnostics (generate-new-buffer " *gdev-assurance-reader-errors*"))
         (default-directory root))
    (unless (equal request gdev-assurance--model-request) (setq gdev-assurance--model nil))
    (condition-case failure
      (progn
       (setq gdev-assurance--reader-process
          (make-process
           :name "gdev-assurance-reader" :buffer output :stderr diagnostics :noquery t :connection-type 'pipe :coding 'utf-8-unix
           :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                          "-l" (gdev-config-file "early-init.el") "-L" (gdev-config-file "lisp")
                          "-l" (gdev-config-file "lisp/gdev-assurance.el") "--eval"
                          "(let* ((args command-line-args-left) (root (pop args)) (id (pop args)) (section (pop args)) (standard (pop args)) (view (intern (pop args)))) (setq command-line-args-left nil) (princ (decode-coding-string (json-serialize (gdev-assurance-project-data root (unless (equal id \"\") id) (unless (equal section \"\") section) (unless (equal standard \"\") standard) (unless (member section '(\"taxonomy\" \"runs\")) 200) view)) 'utf-8-unix)))"
                          root (or tx "")
                          (if (memq section '(standards trace requests capability verify impact project taxonomy procedures runs))
                              (symbol-name section) "")
                          (or (cond ((memq section '(standards taxonomy)) standard) ((eq section 'runs) tx)) "")
                          (symbol-name section))
           :sentinel #'ignore))
       ;; Pubblica il processo prima di consegnare una risposta già pronta.
       (let* ((process gdev-assurance--reader-process)
              (sentinel (lambda (child _event)
                          (gdev-assurance--reader-finished child view frame space request output diagnostics))))
         (set-process-sentinel process sentinel)
         (when (memq (process-status process) '(exit signal failed)) (funcall sentinel process ""))))
      (error
       (gdev-assurance--stop-reader)
       (when (buffer-live-p output) (kill-buffer output))
       (when (buffer-live-p diagnostics) (kill-buffer diagnostics))
       (setq gdev-assurance--error (format "Impossibile leggere il progetto: %s" (error-message-string failure)))))
    (gdev-assurance--render)))

(defun gdev-assurance-refresh ()
  "Rileggi l'archivio senza cambiare selezione, filtro o spazio."
  (interactive)
  (unless (eq gdev-assurance--space (gdev-workspace-state-id)) (user-error "Questa vista appartiene a un altro spazio"))
  (setq gdev-assurance--error nil)
  (gdev-assurance-workspace-active)
  (if (and (not noninteractive)
           (file-exists-p (expand-file-name ".gdev-assurance/project.eld" gdev-assurance--root))
           (file-regular-p (gdev-assurance-db-file gdev-assurance--root)))
      (gdev-assurance--read-async)
    (gdev-assurance--stop-reader)
    (condition-case error
        (setq gdev-assurance--model (gdev-assurance--read-model)
              gdev-assurance--model-request
              (list gdev-assurance--root gdev-assurance--transaction gdev-assurance--section gdev-assurance--standard))
      (error (setq gdev-assurance--model nil gdev-assurance--error (error-message-string error))))
    (gdev-assurance--render)))

(defun gdev-assurance--transactions ()
  "Disegna le transazioni del progetto."
  (gdev-assurance--actions '(("file" "≡" "Collega scheda…" gdev-assurance-work-bind)))
  (gdev-assurance--entries
   (append (alist-get 'transactions (alist-get 'transactions gdev-assurance--model)) nil)
   (lambda (row) (list 'transaction (alist-get 'id row)))
   (lambda (row)
     (let ((id (alist-get 'id row)))
       (gdev-assurance--row (list 'transaction id) (concat id " · " (alist-get 'title row))
                            (format "%s · %s" (gdev-assurance--state-label (alist-get 'state row)) (gdev-assurance-label 'profile (alist-get 'profile row)))
                            (lambda () (gdev-assurance-select id))))))
  (let ((work (alist-get 'work (alist-get 'work gdev-assurance--model))))
    (when (and work (not (eq work :null)))
      (let ((definition (alist-get 'definition work)))
        (insert "\n" (propertize "Scheda della lavorazione" 'face 'gdev-ui-view-heading) "\n"
                (alist-get 'objective definition) "\nResponsabile: " (alist-get 'owner definition) "\n")
        (let ((procedure (alist-get 'procedure definition)))
          (insert (format "Procedura: %s · versione %s\n" (alist-get 'id procedure) (alist-get 'version procedure))))
        (insert "Requisiti: " (mapconcat #'identity (append (alist-get 'requirements definition) nil) ", ") "\n")
        (seq-doseq (condition (alist-get 'prerequisites definition)) (insert "Prerequisito: " condition "\n"))
        (insert "Accettazione:\n")
        (seq-doseq (criterion (alist-get 'acceptance definition)) (insert "• " criterion "\n")))))
  (seq-doseq (application (alist-get 'snippets (alist-get 'work gdev-assurance--model)))
    (let* ((effect (alist-get 'effect (alist-get 'data application))) (path (alist-get 'path effect)))
      (gdev-assurance--row
       (list 'snippet-application (alist-get 'ref application))
       (format "%s · versione %s · %s" (alist-get 'snippet effect) (alist-get 'version effect) path)
       (mapconcat (lambda (parameter) (format "%s: %s" (alist-get 'name parameter) (alist-get 'value parameter)))
                  (append (alist-get 'parameters effect) nil) "\n")
       (lambda () (gdev-assurance-visit path))))))

(defun gdev-assurance--target (control)
  "Ricava l'obiettivo completo del CONTROL GDev scelto."
  (when (string-prefix-p "STD-" control)
    (let ((value (substring control 4))) (replace-regexp-in-string "\\`\\([^:]+\\):" "\\1#" value))))

(defun gdev-assurance--controls ()
  "Disegna esiti e azioni della transazione selezionata."
  (if (null gdev-assurance--transaction)
      (insert "Scegli una transazione per valutarne i controlli.\n")
    (gdev-assurance--actions '(("insert" "+" "Raccogli prova…" gdev-assurance-evidence)
                               ("test" "✓" "Registra valutazione" gdev-assurance-record)
                               ("workflow" "≡" "Scegli standard…" gdev-assurance-select-standards)))
    (insert "\n")
    (gdev-assurance--entries
     (append (alist-get 'results (alist-get 'assessment gdev-assurance--model)) nil)
     (lambda (row) (list 'control (alist-get 'control row)))
     (lambda (row)
       (let* ((id (alist-get 'control row)) (target (gdev-assurance--target id))
              (state (assoc (alist-get 'status row) gdev-assurance--results)))
         (gdev-assurance--row (list 'control id) (alist-get 'title row)
                              (concat (propertize (or (nth 1 state) (alist-get 'status row)) 'face (nth 2 state))
                                      (if (eq :false (alist-get 'due row)) " · non ancora dovuto" "")
                                      "\n" (alist-get 'reason row)))
         (when target
           (gdev-assurance--button "Registra prova…" (lambda () (gdev-assurance-proof target)) (list 'proof target))
           (insert "   ")
           (gdev-assurance--button "Decisione…" (lambda () (gdev-assurance-standard-decision target)) (list 'decision target))
           (insert "\n"))
         (when (and (null target) (eq t (alist-get 'decidable row)))
           (gdev-assurance--button "Decisione…" (lambda () (gdev-assurance-control-decision id)) (list 'decision id))
           (insert "\n")))))))

(defun gdev-assurance--standards ()
  "Disegna il catalogo e i criteri degli obiettivi."
  (let ((data (alist-get 'detail gdev-assurance--model)))
    (when gdev-assurance--standard
      (gdev-assurance--button "‹ Tutti gli standard" (lambda () (gdev-assurance-catalog nil)) '(catalog back)) (insert "\n\n"))
    (when gdev-assurance--standard
      (let ((entry (aref (alist-get 'standards data) 0)))
        (insert (propertize (alist-get 'title entry) 'face 'gdev-ui-view-heading) "\n")
        (insert (format "Edizione %s · %s\n" (alist-get 'edition entry) (alist-get 'scope entry)))
        (gdev-assurance--button "Fonte ufficiale" (lambda () (browse-url (alist-get 'source entry))) '(catalog source))
        (insert "\n\n")
        (when (eq :false (alist-get 'selectable entry))
          (insert (propertize "Edizione o perimetro non verificati: non selezionabile.\n\n" 'face 'gdev-ui-status-warning)))))
    (insert (propertize "Controlli originali GDev; gli esiti non sono certificazioni normative.\n\n" 'face 'gdev-ui-secondary))
    (gdev-assurance--entries
     (if gdev-assurance--standard
         (append (alist-get 'targets (aref (alist-get 'standards data) 0)) nil)
       (append (alist-get 'standards data) nil))
     (lambda (row) (list 'standard (or (alist-get 'target row) (alist-get 'id row))))
     (lambda (row)
       (if gdev-assurance--standard
           (let ((definition (alist-get 'definition row)))
             (gdev-assurance--row (list 'standard (alist-get 'target row)) (alist-get 'target row)
                                  (format "Dovuto: %s · prova: %s\nRuoli: %s%s%s"
                                          (gdev-assurance--state-label (alist-get 'due row))
                                          (gdev-assurance--state-label (alist-get 'proof_state row))
                                          (mapconcat #'identity (alist-get 'roles definition) ", ")
                                          (if (eq t (alist-get 'human definition)) " · verifica umana" "")
                                          (if (eq t (alist-get 'independent definition)) " · indipendente" ""))))
         (let ((id (alist-get 'id row)))
           (gdev-assurance--row (list 'standard id) (concat id " · " (alist-get 'edition row))
                                (format "%s\n%s · %d obiettivi%s" (alist-get 'title row)
                                        (alist-get 'scope row) (alist-get 'target_count row)
                                        (if (eq t (alist-get 'selectable row)) "" " · non selezionabile"))
                                (lambda () (gdev-assurance-catalog id)))))))))

(defun gdev-assurance--requests ()
  "Mostra proposte, argomenti e digest prima delle conferme."
  (let* ((all (append (alist-get 'requests (alist-get 'detail gdev-assurance--model)) nil))
         (resolved (mapcar (lambda (row) (alist-get 'request (alist-get 'data row))) all)))
    (insert (propertize "La conferma conserva l'identità di agente e non sostituisce una verifica umana.\n\n" 'face 'gdev-ui-secondary))
    (gdev-assurance--entries
     all (lambda (row) (list 'request (alist-get 'ref row)))
     (lambda (row)
       (let* ((data (alist-get 'data row)) (ref (alist-get 'ref row))
              (pending (and (equal "pending" (alist-get 'status data)) (not (member ref resolved)))))
         (gdev-assurance--row (list 'request ref) (format "%s · %s · %s" ref (alist-get 'transaction row) (alist-get 'operation data))
                              (format "%s\n%s\nImpronta: %s"
                                      (cond (pending "Da confermare") ((equal "pending" (alist-get 'status data)) "Già esaminata")
                                            ((equal "accepted" (alist-get 'status data)) "Confermata") (t "Rifiutata"))
                                      (decode-coding-string (json-serialize (alist-get 'arguments data)) 'utf-8-unix)
                                      (alist-get 'digest row)))
         (when pending
           (gdev-assurance--button "Conferma…" (lambda () (gdev-assurance-confirm ref (alist-get 'digest row))) (list 'confirm ref))
           (insert "   ")
           (gdev-assurance--button "Rifiuta" (lambda () (gdev-assurance-reject ref (alist-get 'digest row))) (list 'reject ref))
           (insert "\n")))))))

(defun gdev-assurance--trace ()
  "Mostra file e relazioni senza leggere o aprire percorsi esterni."
  (gdev-assurance--actions '(("insert" "+" "Registra artefatto…" gdev-assurance-artifact)
                             ("workflow" "↔" "Collega artefatti…" gdev-assurance-link)))
  (let ((detail (alist-get 'detail gdev-assurance--model)))
    (gdev-assurance--entries
     (append (alist-get 'artifacts detail) nil) (lambda (row) (list 'artifact (alist-get 'ref row)))
     (lambda (row)
       (let ((file (expand-file-name (alist-get 'path row) gdev-assurance--root)))
         (gdev-assurance--row (list 'artifact (alist-get 'ref row)) (alist-get 'path row)
                              (format "%s · %s" (alist-get 'ref row) (alist-get 'role row))
                              (lambda () (gdev-assurance-visit file))))))
    (insert (propertize "Relazioni\n" 'face 'gdev-ui-view-heading))
    (seq-doseq (row (alist-get 'links detail))
      (insert (format "%s → %s · %s\n" (alist-get 'from row) (alist-get 'to row) (alist-get 'relation row))))))

(defun gdev-assurance--documents ()
  "Mostra i documenti del manifesto con azioni esplicite di generazione."
  (gdev-assurance--actions '(("test" "✓" "Controlla documenti" gdev-assurance-check-documents)
                             ("file" "+" "Genera documenti" gdev-assurance-generate-documents)))
  (if (not (file-regular-p (expand-file-name gdev-documents-manifest gdev-assurance--root)))
      (insert "Nessun manifesto dei documenti in questo progetto. Consulta la guida per predisporlo.\n")
    (dolist (entry gdev-documents-types)
      (let ((file (expand-file-name (concat gdev-documents-output (symbol-name (car entry)) ".md") gdev-assurance--root)))
        (if (file-regular-p file)
            (gdev-assurance--button (cdr entry) (lambda () (gdev-assurance-visit file)) (list 'document (car entry)))
          (insert (propertize (concat (cdr entry) " · da generare") 'face 'gdev-ui-secondary)))
        (insert "\n")))))

(defun gdev-assurance--other ()
  "Disegna audit, impatto o capacità da dati già ricevuti."
  (let ((data (alist-get 'detail gdev-assurance--model)))
    (pcase gdev-assurance--section
      ('verify
       (insert (if (eq t (alist-get 'ok data)) "Archivio e catena integri.\n" "Archivio da verificare.\n"))
       (seq-doseq (problem (alist-get 'problems data)) (insert (propertize problem 'face 'gdev-ui-status-error) "\n"))
       (gdev-assurance--actions '(("git" "+" "Installa ganci Git…" gdev-assurance-install-hooks)))
       (when gdev-assurance--transaction
         (gdev-assurance--actions '(("git" "✓" "Firma indice…" gdev-assurance-sign)
                                    ("git" "✓" "Firma amend…" gdev-assurance-sign-amend))))
       (when (equal gdev-assurance--transaction (alist-get 'transaction gdev-assurance--receipt))
         (when gdev-assurance--receipt
           (insert "\n" (propertize (alist-get 'trailers gdev-assurance--receipt) 'face 'fixed-pitch) "\n")
           (gdev-assurance--actions '(("buffer" "=" "Copia riferimenti commit" gdev-assurance-copy-receipt))))))
      ('capability
       (insert (propertize "Osservazioni del progetto; non attribuiscono livelli ufficiali di capacità.\n\n" 'face 'gdev-ui-secondary))
       (gdev-assurance--entries
        (append (alist-get 'controls data) nil) (lambda (row) (list 'capability (alist-get 'control row)))
        (lambda (row) (gdev-assurance--row (list 'capability (alist-get 'control row)) (alist-get 'title row)
                                           (format "%d osservazioni · %s%% soddisfatte" (alist-get 'observations row)
                                                   (if (eq :null (alist-get 'satisfied_percent row)) "—" (alist-get 'satisfied_percent row)))))))
      ('impact
       (insert (propertize "File cambiati\n" 'face 'gdev-ui-view-heading))
       (seq-doseq (file (alist-get 'changed data)) (insert (format "%s\n" file)))
       (insert "\n" (propertize "Artefatti interessati\n" 'face 'gdev-ui-view-heading))
       (seq-doseq (row (alist-get 'affected data)) (insert (format "%s\n" row)))))))

(defun gdev-assurance--navigation ()
  "Mostra le sezioni senza sottrarre spazio al contenuto nei riquadri stretti."
  (if (< (or (gdev-ui-buffer-pixel-width) (window-body-width nil t))
         (gdev-ui-string-pixel-width
          (propertize "Progetto Transazioni Controlli Standard Tassonomie" 'face 'gdev-ui-action)))
      (gdev-assurance--actions
       (list (list "workflow" "≡" (concat "Sezione: " (cdr (assq gdev-assurance--section gdev-assurance--sections)) "…")
                   #'gdev-assurance-section :primary t :help "Scegli sezione · S")))
    (gdev-assurance--actions
     (mapcar (lambda (entry)
               (let ((section (car entry)))
                 (list "workflow" "·" (cdr entry) (lambda () (gdev-assurance-section section))
                       :primary (eq section gdev-assurance--section)))) gdev-assurance--sections))))

(defun gdev-assurance--filter-bar ()
  "Mostra il filtro completo nell'aiuto e la sua rimozione esplicita."
  (let* ((text (if (string-empty-p gdev-assurance--filter) "Filtra…"
                 (concat "Filtro: " gdev-assurance--filter)))
         (label (gdev-ui-fit-text text (or (gdev-ui-buffer-pixel-width) (window-body-width nil t))
                                  (lambda (value) (gdev-ui-string-pixel-width
                                                   (propertize value 'face 'gdev-ui-action))))))
    (gdev-assurance--button label #'gdev-assurance-filter '(filter) text))
  (unless (string-empty-p gdev-assurance--filter)
    (insert "\n")
    (gdev-assurance--button "Azzera filtro" #'gdev-assurance-clear-filter '(filter clear) "Mostra tutte le voci · F"))
  (insert "\n\n"))

(defun gdev-assurance--render ()
  "Ridisegna dai dati memorizzati, conservando l'identità sotto il cursore."
  (let* ((focus (get-text-property (point) 'gdev-assurance-focus))
         (row (get-text-property (point) 'gdev-assurance-row))
         (gdev-assurance--selected-row row)
         (positions (mapcar (lambda (window)
                              (let ((at (window-point window)))
                                (list window (get-text-property at 'gdev-assurance-focus)
                                      (get-text-property at 'gdev-assurance-row))))
                            (get-buffer-window-list nil nil t)))
         (inhibit-read-only t) (width (gdev-ui-buffer-pixel-width)))
    ;; La paginazione legge l'identità prima di cancellare il testo.
    (setq gdev-assurance--width width)
    (let ((marker (copy-marker (point))))
      (erase-buffer)
      (insert (propertize "Assicurazione del progetto" 'face 'gdev-ui-view-title) "\n")
      (insert (propertize (abbreviate-file-name gdev-assurance--root) 'face 'gdev-ui-secondary 'help-echo gdev-assurance--root) "\n\n")
      (gdev-assurance--actions '(("insert" "+" "Nuova transazione…" gdev-assurance-new)
                                 ("workflow" "≡" "Scegli transazione…" gdev-assurance-select)
                                 ("refresh" "↻" "Aggiorna" gdev-assurance-refresh)
                                 ("help" "?" "Guida" gdev-assurance-help)))
      (when (eq :false (alist-get 'archive (alist-get 'status gdev-assurance--model)))
        (gdev-assurance--actions '(("git" "+" "Adotta progetto esistente…" gdev-assurance-adopt))))
      (gdev-assurance--navigation)
      (insert "\n")
      (when-let* ((tx (alist-get 'transaction (alist-get 'show gdev-assurance--model))))
        (insert (propertize (concat (alist-get 'id tx) " · " (alist-get 'title tx)) 'face 'gdev-ui-view-heading) "\n")
        (let ((assessment (alist-get 'assessment gdev-assurance--model)))
          (insert (format "%s · %s%s\n" (gdev-assurance--state-label (alist-get 'state tx))
                          (or (alist-get 'profile_title assessment) (alist-get 'profile_title tx) (alist-get 'profile tx))
                          (if (or (eq t (alist-get 'provisional assessment)) (eq t (alist-get 'provisional tx)))
                              " · provvisorio" ""))))
        (unless (memq (intern (alist-get 'state tx)) gdev-assurance-workspace--closed-states)
          (gdev-assurance--actions '(("run" ">" "Passaggio di stato…" gdev-assurance-advance))))
        (insert "\n"))
      (when gdev-assurance--notice (insert (propertize gdev-assurance--notice 'face gdev-assurance--notice-face) "\n\n"))
      (gdev-assurance--filter-bar)
      (when (and gdev-assurance--reader-process gdev-assurance--model)
        (insert (propertize "Aggiornamento in corso…\n\n" 'face 'gdev-ui-secondary)))
      (cond
       (gdev-assurance--error (insert (propertize gdev-assurance--error 'face 'gdev-ui-status-error) "\n"))
       ((and gdev-assurance--reader-process (null gdev-assurance--model))
        (insert (propertize "Lettura del progetto in corso…\n" 'face 'gdev-ui-secondary)))
       (t
        (when (eq :false (alist-get 'archive (alist-get 'status gdev-assurance--model)))
          (insert (propertize "Nessun archivio nel progetto. Consulta gli standard o apri una transazione per iniziare.\n\n" 'face 'gdev-ui-secondary)))
        (pcase gdev-assurance--section
          ('project (gdev-assurance--project)) ('taxonomy (gdev-assurance--taxonomy))
          ('procedures (gdev-assurance--procedures)) ('runs (gdev-assurance--runs))
          ('transactions (gdev-assurance--transactions)) ('controls (gdev-assurance--controls))
          ('standards (gdev-assurance--standards)) ('trace (gdev-assurance--trace))
          ('requests (gdev-assurance--requests)) ('documents (gdev-assurance--documents))
          (_ (gdev-assurance--other)))))
      (goto-char (point-min))
      (let ((found (or (and focus (text-property-search-forward 'gdev-assurance-focus focus #'equal))
                       (progn (goto-char (point-min)) (and row (text-property-search-forward 'gdev-assurance-row row #'equal))))))
        (goto-char (if found (prop-match-beginning found) (min (marker-position marker) (point-max)))))
      (set-marker marker nil))
    (dolist (entry positions)
      (pcase-let ((`(,window ,identity ,item) entry))
        (when (window-live-p window)
          (save-excursion
            (goto-char (point-min))
            (let ((found (or (and identity (text-property-search-forward 'gdev-assurance-focus identity #'equal))
                             (progn (goto-char (point-min)) (and item (text-property-search-forward 'gdev-assurance-row item #'equal))))))
              (when found (set-window-point window (prop-match-beginning found))))))))
    (set-buffer-modified-p nil)))

(defun gdev-assurance-section (&optional section)
  "Apri SECTION della vista, oppure sceglila per nome."
  (interactive)
  (unless (derived-mode-p 'gdev-assurance-mode) (gdev-assurance-show))
  (setq section (or section (car (rassoc (completing-read "Sezione: " (mapcar #'cdr gdev-assurance--sections)
                                                       nil t nil nil (cdr (assq gdev-assurance--section gdev-assurance--sections)))
                                        gdev-assurance--sections))))
  (unless (assq section gdev-assurance--sections) (user-error "Sezione sconosciuta: %s" section))
  (setq gdev-assurance--section section
        gdev-assurance--page 0 gdev-assurance--filter "" gdev-assurance--notice nil)
  (goto-char (point-min)) (gdev-assurance-refresh))

(defun gdev-assurance-catalog (&optional standard)
  "Mostra gli obiettivi di STANDARD, oppure il catalogo completo."
  (interactive)
  (unless (derived-mode-p 'gdev-assurance-mode) (gdev-assurance-show))
  (setq gdev-assurance--standard standard)
  (gdev-assurance-section 'standards))

(defun gdev-assurance-filter ()
  "Filtra le voci senza rileggere l'archivio."
  (interactive)
  (setq gdev-assurance--filter (read-string "Filtra: " gdev-assurance--filter 'gdev-assurance-filter-history)
        gdev-assurance--page 0)
  (goto-char (point-min)) (gdev-assurance--render))
(defun gdev-assurance-clear-filter ()
  "Rimuovi il filtro senza accessi all'archivio."
  (interactive)
  (setq gdev-assurance--filter "" gdev-assurance--page 0)
  (goto-char (point-min)) (gdev-assurance--render))
(defun gdev-assurance--turn-page (direction)
  "Cambia pagina in DIRECTION e porta il fuoco alla prima voce ricevuta."
  (let ((before gdev-assurance--page) (position (point)))
    (cl-incf gdev-assurance--page direction)
    (goto-char (point-min)) (gdev-assurance--render)
    (goto-char (if (= before gdev-assurance--page) (min position (point-max))
                 (or (text-property-not-all (point-min) (point-max) 'gdev-assurance-row nil) (point-min))))))
(defun gdev-assurance-next ()
  "Mostra le voci successive."
  (interactive) (gdev-assurance--turn-page 1))
(defun gdev-assurance-previous ()
  "Mostra le voci precedenti."
  (interactive) (gdev-assurance--turn-page -1))

(defun gdev-assurance-visit (file)
  "Apri FILE del progetto rispettando il confine della cartella."
  (unless (and (file-regular-p file)
               (file-in-directory-p (file-truename file) gdev-assurance--root))
    (user-error "Il file deve essere leggibile dentro il progetto"))
  (gdev-open-file file))

(defun gdev-assurance-help ()
  "Apri la guida locale dell'assicurazione."
  (interactive) (gdev-open-file (gdev-config-file "docs/assicurazione/README.md")))

(defun gdev-assurance-show-active ()
  "Apri il progetto della transazione attiva, anche in uno spazio con più radici."
  (interactive)
  (let ((active (gdev-assurance-workspace-active)))
    (unless active (user-error "Nessuna transazione attiva in questo spazio"))
    (gdev-assurance-show (plist-get active :root))
    (setq gdev-assurance--transaction (plist-get active :id))
    (gdev-assurance-section 'controls)))

(defvar-keymap gdev-assurance-mode-map
  "RET" #'push-button "TAB" #'forward-button "<backtab>" #'backward-button
  "n" #'forward-button "p" #'backward-button "g" #'gdev-assurance-refresh
  "f" #'gdev-assurance-filter "F" #'gdev-assurance-clear-filter "S" #'gdev-assurance-section
  "]" #'gdev-assurance-next "[" #'gdev-assurance-previous
  "t" #'gdev-assurance-select "c" #'gdev-assurance-new "a" #'gdev-assurance-advance
  "s" #'gdev-assurance-select-standards "v" #'gdev-assurance-proof "e" #'gdev-assurance-evidence
  "d" #'gdev-assurance-decision "r" #'gdev-assurance-record "q" #'gdev-close-document)

(define-derived-mode gdev-assurance-mode special-mode "Assicurazione"
  "Consulta il processo del progetto e usa le azioni del nucleo."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-document)
  (add-hook 'text-scale-mode-hook #'gdev-assurance--render-if-ready nil t)
  (add-hook 'kill-buffer-hook #'gdev-assurance--stop-reader nil t)
  (visual-line-mode 1))

(defun gdev-assurance--render-if-ready ()
  "Ridisponi soltanto una vista già associata a un progetto."
  (when gdev-assurance--root (gdev-assurance--render)))

(defun gdev-assurance-show (&optional root)
  "Apri l'assicurazione del progetto ROOT nello spazio corrente."
  (interactive (list (when current-prefix-arg (read-directory-name "Progetto: "))))
  (let* ((root (gdev-assurance--project-root root))
         (source (gdev-command-file))
         (active (gdev-assurance-workspace-active))
         (space (gdev-workspace-state-ensure-id))
         (buffer (gdev-activity-buffer 'assurance "*Assicurazione*" #'gdev-assurance-mode)))
    (with-current-buffer buffer
      (unless (equal root gdev-assurance--root)
        (setq gdev-assurance--transaction nil gdev-assurance--section 'transactions
              gdev-assurance--filter "" gdev-assurance--page 0 gdev-assurance--standard nil
              gdev-assurance--source-file nil gdev-assurance--receipt nil))
      (setq-local gdev-activity-kind nil)
      (setq gdev-assurance--root root default-directory root gdev-assurance--space space)
      (when source (setq gdev-assurance--source-file source))
      (when (and (null gdev-assurance--transaction) active (file-equal-p root (plist-get active :root)))
        (setq gdev-assurance--transaction (plist-get active :id))))
    (pop-to-buffer buffer)
    (gdev-assurance-refresh)
    buffer))

(defun gdev-assurance--redraw-visible (&optional frame force)
  "Ridisponi le viste di FRAME senza accessi all'archivio."
  (dolist (buffer (delete-dups (mapcar #'window-buffer (window-list frame 'no-minibuffer))))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'gdev-assurance-mode)
                 gdev-assurance--root
                 (or force (not (equal gdev-assurance--width (gdev-ui-buffer-pixel-width)))))
        (gdev-assurance--render)))))
(defun gdev-assurance--theme-changed ()
  "Ricalcola le barre delle viste anche nelle finestre non selezionate."
  (dolist (frame (frame-list)) (gdev-assurance--redraw-visible frame t)))
(add-hook 'window-size-change-functions #'gdev-assurance--redraw-visible)
(add-hook 'gdev-ui-after-theme-hook #'gdev-assurance--theme-changed)

(require 'gdev-assurance-interactive)
(require 'gdev-project-workbench)
(provide 'gdev-assurance-workbench)
;;; gdev-assurance-workbench.el ends here
