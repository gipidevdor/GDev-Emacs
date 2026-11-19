;;; gdev-assurance-interactive.el --- Azioni del processo nell'editor -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; I lettori raccolgono i dati; la facciata comune esegue le scritture.
;; Una richiesta sospesa non può cambiare spazio, progetto o transazione.
;;; Code:
(require 'gdev-assurance-actions)
(require 'gdev-assurance-workspace)
(require 'gdev-command-context)
(require 'gdev-workbench-operations)
(defvar gdev-assurance--root)
(defvar gdev-assurance--transaction)
(defvar gdev-assurance--section)
(defvar gdev-assurance--model)
(defvar gdev-assurance--notice)
(defvar gdev-assurance--notice-face)
(defvar gdev-assurance--source-file)
(defvar gdev-assurance--space)
(defvar gdev-assurance--receipt)
(declare-function gdev-assurance-show "gdev-assurance-workbench" (&optional root))
(declare-function gdev-assurance-refresh "gdev-assurance-workbench" ())
(declare-function gdev-assurance--render "gdev-assurance-workbench" ())
(declare-function gdev-assurance-section "gdev-assurance-workbench" (&optional section))
(declare-function gdev-assurance--state-label "gdev-assurance-workbench" (state))
(declare-function gdev-assurance--target "gdev-assurance-workbench" (control))

(defun gdev-assurance--project-context (&optional tab)
  "Leggi l'identità delle cartelle di TAB, o dello spazio corrente."
  (mapcar (lambda (field) (if tab (gdev-workspace-state-read field tab) (gdev-workspace-state-get field)))
          '(gdev-workspace-roots gdev-layout-folder)))

(defun gdev-assurance--context (&optional transaction)
  "Fissa il contesto della vista; con TRANSACTION richiedi una scelta."
  (unless (and (derived-mode-p 'gdev-assurance-mode) gdev-assurance--root) (gdev-assurance-show))
  (unless (eq gdev-assurance--space (gdev-workspace-state-id))
    (user-error "Questa vista appartiene a un altro spazio"))
  (when (and transaction (null gdev-assurance--transaction))
    (user-error "Scegli prima una transazione"))
  (list :buffer (current-buffer) :frame (selected-frame)
        :space (gdev-workspace-state-ensure-id) :root gdev-assurance--root :id gdev-assurance--transaction
        :project (copy-tree (gdev-assurance--project-context))
        :active (gdev-workspace-state-get 'gdev-assurance-transaction) :file gdev-assurance--source-file))

(defun gdev-assurance--check-context (context)
  "Rifiuta CONTEXT se la richiesta ha cambiato bersaglio durante un prompt."
  (let ((buffer (plist-get context :buffer)))
    (unless (and (buffer-live-p buffer) (eq (selected-frame) (plist-get context :frame))
                 (eq (plist-get context :space) (gdev-workspace-state-id))
                 (equal (plist-get context :project) (gdev-assurance--project-context))
                 (equal (plist-get context :root) (buffer-local-value 'gdev-assurance--root buffer))
                 (equal (plist-get context :id) (buffer-local-value 'gdev-assurance--transaction buffer)))
      (user-error "Lo spazio, il progetto o la transazione è cambiato; ripeti il comando"))))

(defun gdev-assurance--write (context command operands)
  "Esegui COMMAND con OPERANDS sul CONTEXT ancora valido e aggiorna la vista."
  (gdev-assurance--check-context context)
  (with-current-buffer (plist-get context :buffer)
    (setq gdev-assurance--notice nil gdev-assurance--notice-face 'gdev-ui-status-success))
  (unwind-protect
      (gdev-assurance-action-run (plist-get context :root) command operands)
    (when (and (buffer-live-p (plist-get context :buffer))
               (eq (plist-get context :space) (gdev-workspace-state-id)))
      (with-current-buffer (plist-get context :buffer) (gdev-assurance-refresh)))))

(defun gdev-assurance--read-file (context prompt)
  "Leggi un file per CONTEXT con PROMPT, senza usare modifiche non salvate."
  (let ((file (read-file-name prompt (plist-get context :root) (plist-get context :file) t)))
    (when (file-remote-p file) (user-error "Scegli un file locale"))
    (when-let* ((buffer (find-buffer-visiting file)) ((buffer-modified-p buffer)))
      (user-error "Salva %s prima di registrarlo" (file-name-nondirectory file)))
    file))

(defun gdev-assurance--read-target (target)
  "Scegli un obiettivo della transazione, usando TARGET quando indicato."
  (or target
      (let ((row (get-text-property (point) 'gdev-assurance-row)))
        (and (eq (car row) 'control) (gdev-assurance--target (cadr row))))
      (let ((targets (or (append (alist-get 'standard_targets
                                          (alist-get 'transaction (alist-get 'show gdev-assurance--model))) nil)
                         (delq nil (mapcar (lambda (row) (gdev-assurance--target (alist-get 'control row)))
                                         (alist-get 'results (alist-get 'assessment gdev-assurance--model)))))))
        (unless targets (user-error "Nessuno standard scelto per questa transazione"))
        (completing-read "Obiettivo: " targets nil t))))

(defun gdev-assurance-select (&optional id)
  "Scegli la transazione ID del progetto; le transazioni aperte diventano attive."
  (interactive)
  (let* ((context (gdev-assurance--context))
         (rows (alist-get 'transactions (alist-get 'transactions gdev-assurance--model)))
         (choices (mapcar (lambda (row) (cons (format "%s · %s" (alist-get 'id row) (alist-get 'title row)) (alist-get 'id row))) rows))
         (_ (unless (or id choices) (user-error "Nessuna transazione nel progetto")))
         (id (or id (cdr (assoc (completing-read "Transazione: " choices nil t) choices)))))
    (unless id (user-error "Nessuna transazione nel progetto"))
    (gdev-assurance--check-context context)
    (let* ((show (gdev-assurance-data "show" (plist-get context :root) id))
           (state (intern (alist-get 'state (alist-get 'transaction show)))))
      (unless (memq state gdev-assurance-workspace--closed-states)
        (gdev-assurance-workspace-select (plist-get context :root) id)))
    (setq gdev-assurance--transaction id)
    (gdev-assurance-section 'controls)))

(defun gdev-assurance-new ()
  "Apri una transazione e rendila attiva nello spazio corrente."
  (interactive)
  (let* ((context (gdev-assurance--context))
         (title (read-string "Titolo della modifica: "))
         (default (if (file-exists-p (expand-file-name gdev-project-manifest (plist-get context :root)))
                      (symbol-name (plist-get (gdev-project-read (plist-get context :root)) :profile)) "core"))
         (profile (completing-read "Profilo: " (mapcar #'symbol-name gdev-process-profiles) nil t nil nil default))
         (id (gdev-assurance--write context "open" (list title profile))))
    (gdev-assurance-workspace-select (plist-get context :root) id)
    (setq gdev-assurance--transaction id)
    (gdev-assurance-section 'controls)))

(defun gdev-assurance-advance ()
  "Avanza la transazione selezionata attraverso le regole del nucleo."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (tx (alist-get 'transaction (gdev-assurance-data "show" (plist-get context :root) (plist-get context :id))))
         (states (cdr (assq (intern (alist-get 'state tx)) gdev-process-transitions)))
         (choices (mapcar (lambda (state) (cons (format "%s · %s" (gdev-assurance--state-label state) state) (symbol-name state))) states)))
    (unless choices (user-error "La transazione è conclusa"))
    (gdev-assurance--write context "advance"
                           (list (plist-get context :id) (cdr (assoc (completing-read "Passa a: " choices nil t) choices))))))

(defun gdev-assurance-select-standards ()
  "Scegli standard interi o singoli obiettivi prima dell'autorizzazione."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (choices (gdev-standards-with-cache
                   (lambda ()
                     (cl-loop for entry in (gdev-standards-all) for id = (plist-get entry :id)
                              for targets = (gdev-standard-catalog-targets id)
                              when targets append (cons id (mapcar (lambda (row) (concat id "#" (plist-get row :clause))) targets))))))
         (selected (completing-read-multiple "Standard o obiettivi (virgole): " choices nil t))
         (reason (read-string "Motivo della scelta: ")))
    (gdev-assurance--write context "standard-select" (list (plist-get context :id) (mapconcat #'identity selected ",") reason))))

(defun gdev-assurance-proof (&optional target)
  "Raccogli una prova specifica per TARGET, con un esito dichiarato."
  (interactive)
  (let* ((context (gdev-assurance--context t)) (target (gdev-assurance--read-target target))
         (verdict (if (equal "Positivo" (completing-read "Esito della verifica: " '("Positivo" "Negativo") nil t)) "pass" "fail"))
         (file (gdev-assurance--read-file context "Rapporto della verifica: ")))
    (gdev-assurance--write context "standard-proof" (list (plist-get context :id) target verdict file))))

(defun gdev-assurance-standard-decision (&optional target)
  "Registra non applicabilità, deroga o revoca per TARGET."
  (interactive)
  (let* ((context (gdev-assurance--context t)) (target (gdev-assurance--read-target target))
         (choices '(("Non applicabile" . "not-applicable") ("Deroga autorizzata" . "waiver") ("Revoca" . "revoke")))
         (verdict (cdr (assoc (completing-read "Decisione: " choices nil t) choices)))
         (reason (read-string "Motivo e responsabilità: ")))
    (gdev-assurance--write context "standard-decision" (list (plist-get context :id) target verdict reason))))

(defun gdev-assurance-control-decision (&optional control)
  "Prendi una decisione motivata sul CONTROL del profilo."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (controls (seq-filter (lambda (row) (eq t (alist-get 'decidable row)))
                               (or (alist-get 'results (alist-get 'assessment gdev-assurance--model))
                                   (alist-get 'profile_controls
                                              (alist-get 'transaction (alist-get 'show gdev-assurance--model))))))
         (control (or control (completing-read "Controllo: " (mapcar (lambda (row) (alist-get 'control row)) controls) nil t)))
         (choices '(("Non applicabile" . "not-applicable") ("Deroga autorizzata" . "waiver")))
         (kind (cdr (assoc (completing-read "Decisione: " choices nil t) choices)))
         (reason (read-string "Motivo e responsabilità: ")))
    (gdev-assurance--write context "decision" (list (plist-get context :id) control kind reason))))

(defun gdev-assurance-decision ()
  "Prendi una decisione sulla voce selezionata, da tastiera o dal menu."
  (interactive)
  (gdev-assurance--context t)
  (let* ((row (get-text-property (point) 'gdev-assurance-row))
         (control (and (eq 'control (car row)) (cadr row)))
         (target (and control (gdev-assurance--target control))))
    (if target (gdev-assurance-standard-decision target)
      (if control (gdev-assurance-control-decision control)
        (call-interactively (if (equal "Standard" (completing-read "Ambito: " '("Standard" "Controllo del profilo") nil t))
                                #'gdev-assurance-standard-decision #'gdev-assurance-control-decision))))))

(defun gdev-assurance--adoption-complete (context id frame tab)
  "Attiva ID nel CONTEXT ancora corrente di FRAME e TAB, o spiega il rinvio."
  (let ((view (plist-get context :buffer)))
    (cond
     ((not (equal (plist-get context :project) (gdev-assurance--project-context tab)))
      "Il progetto dello spazio è cambiato; la transazione non è stata attivata.")
     ((not (equal (plist-get context :id) (buffer-local-value 'gdev-assurance--transaction view)))
      "La transazione mostrata è cambiata; la selezione è stata conservata.")
     ((equal (plist-get context :active) (gdev-workspace-state-read 'gdev-assurance-transaction tab))
      (condition-case failure
          (progn (gdev-assurance-workspace-select (plist-get context :root) id frame (plist-get context :space))
                 (with-current-buffer view (setq gdev-assurance--transaction id))
                 nil)
        (error (error-message-string failure)))))))

(defun gdev-assurance--background-finish (context command label operation output process)
  "Pubblica l'esito di PROCESS in CONTEXT attraverso il proprietario OPERATION.
COMMAND e LABEL descrivono il lavoro; OUTPUT ne conserva il log completo."
  (let* ((success (and (eq (process-status process) 'exit) (= 0 (process-exit-status process))))
         (current (gdev-workbench-operation-current operation))
         (cancelled (or (and current (memq (gdev-workbench-operation-state current) '(stopping cancelled)))
                        (and (eq (process-status process) 'exit) (= 130 (process-exit-status process)))
                        (and (eq (process-status process) 'signal) (= 2 (process-exit-status process)))))
         (text (if (buffer-live-p output) (with-current-buffer output (buffer-string)) ""))
         (id (and success (not cancelled) (equal command "adopt")
                  (string-match "^\\(GT-[0-9]+\\)$" text) (match-string 1 text)))
         (origin (plist-get context :frame)) (space (plist-get context :space))
         (view (plist-get context :buffer)) (root (plist-get context :root))
         (location (or (gdev-workbench-operation-location operation)
                       (and (frame-live-p origin)
                            (when-let* ((tab (gdev-workspace-state-find space origin))) (cons origin tab)))))
         (frame (car location)) (tab (cdr location)))
    (when operation
      (if cancelled (gdev-workbench-operation-report operation 'cancelled)
        (gdev-workbench-operation-finish operation success (unless success (string-trim text)))))
    (when (and tab (buffer-live-p view)
               (eq space (buffer-local-value 'gdev-assurance--space view))
               (equal root (buffer-local-value 'gdev-assurance--root view)))
      (let ((selection-error (and id (gdev-assurance--adoption-complete context id frame tab))))
        (with-current-buffer view
          (setq gdev-assurance--notice
                (concat label
                        (cond (cancelled ": interrotta.")
                              (selection-error (concat ": completata. " selection-error))
                              (success ": completata.")
                              (t (concat ": non riuscita. " (truncate-string-to-width (string-trim text) 1200 nil nil "…")))))
                gdev-assurance--notice-face (cond ((or cancelled selection-error) 'gdev-ui-status-warning)
                                                   (success 'gdev-ui-status-success) (t 'gdev-ui-status-error))))
        (when (eq space (gdev-workspace-state-id frame))
          (with-selected-frame frame
            (with-current-buffer view (gdev-assurance-refresh))))))
    (when (buffer-live-p output)
      (with-current-buffer output (special-mode) (gdev-ui-view-setup 'native)))))

(defun gdev-assurance--background (context command operands label)
  "Esegui COMMAND con OPERANDS fuori dal processo grafico, legato a CONTEXT."
  (gdev-assurance--check-context context)
  (when (memq gdev-process-origin '(agent ci system)) (gdev-process-refuse "Questa operazione richiede una persona"))
  (let* ((root (plist-get context :root)) (space (plist-get context :space))
         (view (plist-get context :buffer)) (output (generate-new-buffer (concat "*Assicurazione · " label "*")))
         (default-directory root) (process-environment (copy-sequence process-environment))
         (operation (gdev-workbench-operation-start label output t space)) finished)
    (with-current-buffer output (setq default-directory root))
    (with-current-buffer view
      (setq gdev-assurance--notice (concat label ": in corso…") gdev-assurance--notice-face 'gdev-ui-status-warning)
      (gdev-assurance--render))
    (setenv "GDEV_ASSURANCE_ACTOR" (or (getenv "GDEV_ASSURANCE_ACTOR") (user-login-name)))
    (condition-case failure
        (make-process
         :name "gdev-assurance" :buffer output :connection-type 'pipe :noquery t :coding 'utf-8-unix
         :command (append (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                "-l" (gdev-config-file "early-init.el") "-L" (gdev-config-file "lisp")
                                "-l" (gdev-config-file "lisp/gdev-assurance-actions.el") "--eval"
                                "(let ((args command-line-args-left)) (setq command-line-args-left nil) (kill-emacs (gdev-assurance-actions-cli (pop args) (pop args) args)))"
                                root command) operands)
         :sentinel
         (lambda (process _event)
           (when (and (not finished) (memq (process-status process) '(exit signal)))
             (setq finished t)
             (gdev-assurance--background-finish context command label operation output process))))
      (error
       (when operation (gdev-workbench-operation-finish operation nil (error-message-string failure)))
       (when (buffer-live-p view)
         (with-current-buffer view
           (setq gdev-assurance--notice (concat label ": non avviata. " (error-message-string failure))
                 gdev-assurance--notice-face 'gdev-ui-status-error)
           (gdev-assurance--render)))
       (kill-buffer output)
       (signal (car failure) (cdr failure))))))

(defun gdev-assurance-adopt ()
  "Crea l'inventario iniziale in secondo piano, senza certificare il passato."
  (interactive)
  (let* ((context (gdev-assurance--context))
         (profile (completing-read "Profilo di adozione: " (mapcar #'symbol-name gdev-process-profiles) nil t nil nil "core")))
    (when (yes-or-no-p "Creare l'inventario iniziale senza attestare le verifiche passate? ")
      (gdev-assurance--background context "adopt" (list profile) "Adozione del progetto"))))

(defun gdev-assurance-install-hooks ()
  "Installa esplicitamente i ganci usando i firmatari esterni scelti."
  (interactive)
  (let* ((context (gdev-assurance--context)) (signers (read-file-name "Firmatari fidati esterni al progetto: " nil nil t))
         (repository (read-string "Identità del repository: ")))
    (when (yes-or-no-p "Installare commit-msg e pre-push per questo progetto? ")
      (gdev-assurance--background context "hooks" (list signers repository) "Installazione dei ganci"))))

(defun gdev-assurance-evidence ()
  "Raccogli un rapporto come prova della transazione selezionata."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (description (read-string "Descrizione della prova: "))
         (file (gdev-assurance--read-file context "File della prova: ")))
    (gdev-assurance--write context "evidence" (list (plist-get context :id) description file))))

(defun gdev-assurance-artifact ()
  "Registra un file del progetto con il suo ruolo e la sua impronta."
  (interactive)
  (let* ((context (gdev-assurance--context t)) (file (gdev-assurance--read-file context "Artefatto del progetto: "))
         (roles '(("Requisito" . "requirement") ("Progettazione" . "design") ("Sorgente" . "source")
                  ("Test" . "test") ("Prova" . "evidence") ("Documento" . "document") ("Configurazione" . "configuration")))
         (role (cdr (assoc (completing-read "Ruolo: " roles nil t) roles))))
    (gdev-assurance--write context "artifact" (list (plist-get context :id) file role))))

(defun gdev-assurance-link ()
  "Collega due artefatti del progetto con una relazione motivata."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (artifacts (alist-get 'artifacts (gdev-assurance-data "trace" (plist-get context :root))))
         (choices (mapcar (lambda (row) (cons (format "%s · %s" (alist-get 'ref row) (alist-get 'path row)) (alist-get 'ref row))) artifacts))
         (from (cdr (assoc (completing-read "Artefatto di partenza: " choices nil t) choices)))
         (to (cdr (assoc (completing-read "Artefatto di arrivo: " choices nil t) choices)))
         (relations '(("Realizza" . "implements") ("Verifica" . "verifies") ("Documenta" . "documents")
                      ("Deriva" . "derives") ("Dipende da" . "depends-on")))
         (relation (cdr (assoc (completing-read "Relazione: " relations nil t) relations)))
         (reason (read-string "Motivo del collegamento: ")))
    (gdev-assurance--write context "link" (list (plist-get context :id) from to relation reason))))

(defun gdev-assurance-record ()
  "Registra la valutazione corrente senza approvare la transazione."
  (interactive)
  (let ((context (gdev-assurance--context t)))
    (gdev-assurance--write context "assess-record" (list (plist-get context :id)))
    (message "Valutazione registrata")))

(defun gdev-assurance-confirm (ref digest)
  "Conferma la proposta REF con il DIGEST mostrato nella vista."
  (let ((context (gdev-assurance--context)))
    (when (yes-or-no-p (format "Confermare la proposta %s con gli argomenti mostrati? " ref))
      (gdev-assurance--write context "confirm" (list ref digest)))))
(defun gdev-assurance-reject (ref digest)
  "Rifiuta la proposta REF con il DIGEST mostrato nella vista."
  (gdev-assurance--write (gdev-assurance--context) "reject" (list ref digest)))

(defun gdev-assurance-check-documents ()
  "Confronta i documenti del progetto con le fonti senza modificarli."
  (interactive)
  (gdev-assurance--write (gdev-assurance--context) "documents" '("check"))
  (setq gdev-assurance--notice "Documenti aggiornati rispetto alle fonti.")
  (gdev-assurance-refresh))
(defun gdev-assurance-generate-documents ()
  "Genera i documenti previsti dal manifesto del progetto."
  (interactive)
  (gdev-assurance--write (gdev-assurance--context) "documents" nil)
  (setq gdev-assurance--notice "Documenti generati dalle fonti del progetto.")
  (gdev-assurance-refresh))

(defun gdev-assurance-sign (&optional amend)
  "Firma l'indice verificato; con AMEND firma i genitori del commit sostituito."
  (interactive)
  (let* ((context (gdev-assurance--context t))
         (repository (read-string "Identità del repository: "))
         (signer (read-string "Firmatario: "))
         (key (read-file-name "Chiave SSH: " nil nil t))
         (result (gdev-assurance--write context (if amend "sign-amend" "sign")
                                        (list (plist-get context :id) repository signer key))))
    (setq gdev-assurance--receipt (cons (cons 'transaction (plist-get context :id)) result)
          gdev-assurance--notice "Ricevuta firmata. I riferimenti per il commit sono nella sezione Audit.")
    (gdev-assurance-refresh)))
(defun gdev-assurance-sign-amend ()
  "Firma l'indice per sostituire l'ultimo commit con amend."
  (interactive) (gdev-assurance-sign t))

(defun gdev-assurance-copy-receipt ()
  "Copia i riferimenti della ricevuta mostrata per il messaggio di commit."
  (interactive)
  (unless (and gdev-assurance--receipt
               (equal gdev-assurance--transaction (alist-get 'transaction gdev-assurance--receipt)))
    (user-error "Nessuna ricevuta per la transazione selezionata"))
  (kill-new (alist-get 'trailers gdev-assurance--receipt))
  (message "Riferimenti della ricevuta copiati"))

(provide 'gdev-assurance-interactive)
;;; gdev-assurance-interactive.el ends here
