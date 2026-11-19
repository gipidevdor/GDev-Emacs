;;; config.el --- :tools hithub: HitHub, integrazione con GitHub -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; HitHub integra GitHub tramite gh, il programma ufficiale da riga di
;; comando. Accedi da HitHub › Account o con gh auth login. Le azioni
;; sono nel menu HitHub e sotto C-c g h.
;;
;;   C-c g h h   panoramica dell'archivio: richieste, segnalazioni,
;;               esecuzioni, versioni e notifiche in una vista
;;   C-c g h b   apri nel navigatore l'archivio, o
;;               il file alla riga corrente
;;   C-c g h c   clona uno dei tuoi archivi Git, scelto da un elenco
;;   C-c g h n   crea su GitHub l'archivio Git del progetto corrente
;;   C-c g h p   crea una richiesta di integrazione per il ramo
;;   C-c g h l   richieste di integrazione, differenze e revisioni
;;   C-c g h k   controlli della richiesta del ramo corrente
;;   C-c g h a   ultime esecuzioni dei flussi automatici di
;;               GitHub Actions
;;   C-c g h w   segui l'ultima esecuzione fino alla fine
;;   C-c g h u   avvia un flusso automatico
;;   C-c g h s   esplora le segnalazioni, S ne crea una
;;   C-c g h r   esplora le versioni, R prepara una nuova bozza
;;   C-c g h o   notifiche
;;   C-c g h A   account GitHub
;;   C-c g h d   fork e archivio Git predefinito
;;   C-c g h g   pubblica un frammento di codice dalla selezione o
;;               dall'area di testo
;;   C-c g h i   scegli l'identità Git (nome ed email) di questo archivio Git
;;   C-c g h y   copia il collegamento permanente al file
;;
;; Le identità si elencano nel config.el privato, mai nell'archivio Git:
;;
;;   (setq gdev-git-identities
;;         '(("Nome Cognome" . "nome@example.com")
;;           ("Nome Cognome" . "123+utente@users.noreply.github.com")))
;;
;; Per gli archivi Git pubblici conviene l'indirizzo noreply di GitHub: la
;; propria email resta privata. Le richieste di integrazione e segnalazioni
;; si leggono e commentano anche dentro Hit, con Forge (C-c g F). La chiave
;; d'accesso resta nell'archivio di gh (il Portachiavi di macOS): GDev-Emacs
;; non la legge mai.

;;; Code:

(require 'gdev-lib)
(require 'gdev-keys)
(require 'gdev-handlers)
(require 'gdev-layout)
(require 'gdev-modules)
(require 'gdev-workspace-state)
(require 'json)
(require 'browse-url)

(declare-function gdev-github-topic "gdev-hithub-view" (root kind number))
(declare-function gdev-github-overview "gdev-hithub-view" (&optional root))

(defgroup gdev-github nil
  "HitHub integra GitHub attraverso gh."
  :group 'gdev)

(defcustom gdev-git-identities nil
  "Identità Git fra cui scegliere con `gdev-github-set-identity'.
Ogni elemento è (NOME . EMAIL).  Se vuota si usano `user-full-name' e
`user-mail-address'.  Va impostata nel config.el privato."
  :type '(repeat (cons string string)))

(defcustom gdev-github-clone-directory "~/src/"
  "Cartella in cui `gdev-github-clone' propone di clonare."
  :type 'directory)

;;;; gh

(defun gdev-github--start (directory callback arguments &optional input)
  "Avvia gh con ARGUMENTS in DIRECTORY e invia l'eventuale testo INPUT.
CALLBACK riceve il risultato oppure il messaggio di errore."
  (unless (or (file-remote-p directory) (executable-find "gh"))
    (user-error "HitHub richiede GitHub CLI (gh)"))
  (let ((default-directory directory)
        (process-environment (cons "GH_PROMPT_DISABLED=1" process-environment))
        (output (generate-new-buffer " *gdev-gh*"))
        (errors (generate-new-buffer " *gdev-gh-errors*"))
        process ready)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "gdev-gh" :buffer output :command (cons "gh" arguments)
                 :stderr (unless (file-remote-p directory) errors)
                 :connection-type 'pipe :file-handler t :coding 'utf-8-unix :noquery t
                 :sentinel
                 (lambda (child _event)
                   (when (memq (process-status child) '(exit signal failed))
                     (unwind-protect
                         (if (and (eq (process-status child) 'exit)
                                  (or (zerop (process-exit-status child))
                                      (and (equal (seq-take arguments 2) '("pr" "checks"))
                                           (member "--json" arguments)
                                           (memq (process-exit-status child) '(1 8))
                                           (with-current-buffer output (> (buffer-size) 0)))))
                             (funcall callback (with-current-buffer output (buffer-string)) nil)
                           (progn
                             ;; La pipe degli errori si svuota indipendentemente da gh.
                             (when-let* ((stderr (get-buffer-process errors)))
                               (while (accept-process-output stderr 0 nil 1)))
                             (let ((details (string-trim
                                             (concat (with-current-buffer errors (buffer-string))
                                                     (with-current-buffer output (buffer-string))))))
                               (funcall callback nil (gdev-github--error details)))))
                       (kill-buffer output)
                       (kill-buffer errors))))))
          (when-let* ((stderr (get-buffer-process errors)))
            ;; Nel buffer devono entrare solo i messaggi di gh.
            (set-process-sentinel stderr #'ignore))
          (when (process-live-p process)
            (when input
              (condition-case problem
                  (process-send-string process input)
                (error
                 (when (process-live-p process)
                   (signal (car problem) (cdr problem))))))
            (when (process-live-p process) (ignore-errors (process-send-eof process))))
          (setq ready t)
          process)
      (unless ready
        (if process
            (when (process-live-p process) (delete-process process))
          (kill-buffer output)
          (kill-buffer errors))))))

(defun gdev-github--error (details)
  "Presenta in italiano gli errori comuni, conservando la diagnosi DETAILS."
  (let ((case-fold-search t))
    (cond
     ((string-empty-p details) "HitHub · Richiesta interrotta")
     ;; «please use gh auth login» compare anche quando l'archivio non ha un
     ;; remoto GitHub: non è un problema di accesso.
     ((string-match-p "none of the git remotes\\|known GitHub host\\|no git remotes" details)
      "Questo archivio non ha un remoto su GitHub")
     ((string-match-p "not logged in\\|not logged into\\|To get started with GitHub CLI\\|GH_TOKEN\\|HTTP 401\\|Bad credentials"
                      details)
      "Accedi a GitHub con gh auth login")
     ((string-match-p "must first push\\|must push" details)
      "Invia il ramo a GitHub da Hit prima di creare la richiesta")
     (t (format "HitHub · Operazione non riuscita\n%s" details)))))

(defun gdev-github--request (directory callback &rest arguments)
  "Esegue gh con ARGUMENTS in DIRECTORY. CALLBACK riceve il testo o l'errore."
  (gdev-github--start directory callback arguments))

(defun gdev-github--choose (root prompt require-match &rest arguments)
  "Apri PROMPT subito e completa con le righe che gh trova in ROOT."
  (when (bound-and-true-p vertico-mode)
    (require 'consult nil t))
  (let (lines failure minibuffer process choice done)
    (unwind-protect
        (setq choice
              (minibuffer-with-setup-hook
                  (lambda ()
                    (setq minibuffer (current-buffer)
                          process
                          (apply #'gdev-github--request root
                                 (lambda (text error-message)
                                   (setq done t failure error-message
                                         lines (and text (split-string text "\n" t)))
                                   (when-let* ((window (active-minibuffer-window))
                                               ((eq minibuffer (window-buffer window))))
                                     (with-current-buffer minibuffer
                                       (completion--flush-all-sorted-completions)
                                       (run-hooks 'consult--completion-refresh-hook)
                                       (when (or failure (not lines))
                                         (minibuffer-message "%s" (or failure "Nessun risultato da GitHub"))))))
                                 arguments)))
                (completing-read prompt (lambda (input predicate action)
                                          (complete-with-action action lines input predicate))
                                 nil require-match)))
      (when (process-live-p process) (delete-process process)))
    (cond ((not (string-empty-p choice)) choice)
          (failure (user-error "%s" failure))
          ((and done (not lines)) (user-error "Nessun risultato da GitHub"))
          (t (user-error "Scegli una voce dall'elenco")))))

(defun gdev-github--report-error (_text error-message)
  "Mostra ERROR-MESSAGE se la richiesta è fallita."
  (when error-message (message "%s" error-message)))

(defun gdev-github--run (name interactive &rest arguments)
  "Esegue gh con ARGUMENTS in un'area di testo di compilazione *NAME*.
Con INTERACTIVE non nil l'area di testo accetta risposte alle domande di gh."
  (gdev-compile (apply #'gdev-command-line "gh" arguments) name nil interactive))

(defvar gdev-github-after-change-functions nil
  "Funzioni chiamate con la radice dell'archivio dopo una modifica riuscita.
Le viste di HitHub le usano per aggiornare i dati mostrati.")

(defun gdev-github--changed (root)
  "Comunica alle viste che l'archivio in ROOT è cambiato su GitHub."
  (run-hook-with-args 'gdev-github-after-change-functions root))

(defun gdev-github--submit (root label arguments &optional input)
  "Esegue ARGUMENTS in ROOT, con INPUT facoltativo, e comunica LABEL."
  (message "HitHub · %s…" label)
  (gdev-github--start
   root (lambda (output failure)
          (message "%s" (or failure (gdev-github--success label output)))
          (unless failure (gdev-github--changed root)))
   arguments input))

(defun gdev-github--success (label output)
  "Indica l'esito di LABEL ed espone eventuali indirizzi restituiti in OUTPUT."
  (let ((urls (seq-filter (lambda (line) (string-match-p "\\`https?://[^[:space:]]+\\'" line))
                         (split-string output "\n" t))))
    (string-join (cons (format "HitHub · %s · Operazione riuscita" label) urls) "\n")))

(defun gdev-github--required-text (prompt &optional initial)
  "Legge una riga obbligatoria con PROMPT e valore iniziale INITIAL."
  (let ((value (string-trim (read-string prompt initial))))
    (when (string-empty-p value)
      (user-error "Inserisci un valore per continuare"))
    value))

(defun gdev-github--number (line)
  "Legge il numero all'inizio della voce LINE."
  (unless (string-match "\\`#\\([0-9]+\\)" line)
    (user-error "La voce selezionata non ha un numero GitHub valido"))
  (match-string 1 line))

(defvar-local gdev-github--draft nil)

(defvar-keymap gdev-github-draft-mode-map
  "C-c C-c" #'gdev-github-draft-send
  "C-c C-k" #'gdev-github-draft-cancel)

(define-derived-mode gdev-github-draft-mode text-mode "Bozza HitHub"
  "Scrivi un testo Markdown da inviare a GitHub."
  (gdev-ui-view-setup 'native)
  (setq-local header-line-format "  C-c C-c  Invia     C-c C-k  Annulla"))

(defun gdev-github--compose (root label arguments &optional initial required)
  "Scrive in ROOT il testo per ARGUMENTS, con titolo LABEL.
INITIAL contiene il testo iniziale. REQUIRED richiede testo prima dell'invio."
  (let ((buffer (generate-new-buffer (format "*HitHub · %s*" label)))
        (environment process-environment)
        (path exec-path))
    (with-current-buffer buffer
      (gdev-github-draft-mode)
      (setq-local default-directory root
                  process-environment environment
                  exec-path path
                  gdev-github--draft (list label arguments required))
      (when initial (insert initial))
      (set-buffer-modified-p nil))
    (when-let* ((editor (and gdev-layout-mode (gdev-layout-editor))))
      (select-window editor))
    (pop-to-buffer-same-window buffer)))

(defun gdev-github-draft-cancel ()
  "Chiude la bozza e chiede conferma se contiene modifiche."
  (interactive)
  (when buffer-read-only
    (user-error "Invio in corso"))
  (when (or (not (buffer-modified-p)) (yes-or-no-p "Scartare la bozza HitHub? "))
    (kill-current-buffer)))

(defun gdev-github-draft-send ()
  "Invia la bozza corrente e la conserva se GitHub restituisce un errore."
  (interactive)
  (when buffer-read-only (user-error "Invio in corso"))
  (pcase-let* ((`(,label ,arguments ,required) gdev-github--draft)
               (text (buffer-substring-no-properties (point-min) (point-max)))
               (buffer (current-buffer)))
    (when (and required (string-empty-p (string-trim text)))
      (user-error "Scrivi il testo prima di inviare"))
    (setq buffer-read-only t)
    (condition-case problem
        (gdev-github--start
         default-directory
         (let ((root default-directory))
           (lambda (output failure)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (if failure
                     (setq buffer-read-only nil)
                   (set-buffer-modified-p nil)
                   (kill-buffer buffer))))
             (message "%s" (or failure (gdev-github--success label output)))
             (unless failure (gdev-github--changed root))))
         arguments text)
      (error
       (setq buffer-read-only nil)
       (signal (car problem) (cdr problem))))))

;;;; Repository

(defun gdev-github-browse ()
  "Apre nel navigatore l'archivio Git, o il file alla riga corrente."
  (interactive)
  (let ((root (gdev-project-root)))
    (apply #'gdev-github--request root #'gdev-github--report-error "browse"
           (when buffer-file-name
             (list (format "%s:%d" (file-relative-name buffer-file-name root) (line-number-at-pos)))))))

(defun gdev-github-clone (repository directory)
  "Clona REPOSITORY (proprietario/nome) in DIRECTORY.
Il repository si sceglie fra i propri, o si scrive per intero."
  (interactive
   (let* ((repository (gdev-github--choose (gdev-project-root) "Repository da clonare: " nil
                                          "repo" "list" "--limit" "300"
                                          "--json" "nameWithOwner" "--jq" ".[].nameWithOwner"))
          (name (file-name-nondirectory repository)))
     (list repository
           (read-directory-name "Nella cartella: "
                                (expand-file-name name gdev-github-clone-directory)))))
  (let ((directory (expand-file-name directory)))
    (make-directory (file-name-directory (directory-file-name directory)) t)
    (gdev-github--run "HitHub · Clona repository" nil "repo" "clone" repository directory)))

(defun gdev-github-create-repository (visibility)
  "Crea su GitHub l'archivio Git del progetto e vi invia le modifiche.
VISIBILITY è \"privato\" o \"pubblico\"; prima di procedere chiede conferma."
  (interactive (list (completing-read "Visibilità: " '("privato" "pubblico") nil t)))
  (let* ((root (gdev-project-root))
         (name (file-name-nondirectory (directory-file-name root))))
    (when (yes-or-no-p (format "Creare su GitHub il repository %s (%s) e inviarvi le modifiche (commit)? "
                               name visibility))
      (let ((default-directory root))
        (gdev-github--run "HitHub · Crea repository" nil "repo" "create" name
                          (if (equal visibility "pubblico") "--public" "--private")
                          "--source" "." "--remote" "origin" "--push")))))

;;;; Richieste di integrazione (pull request)

(defun gdev-github-pull-request-create ()
  "Scrive una richiesta per il ramo corrente. Con C-u la crea come bozza."
  (interactive)
  (let* ((root (gdev-project-root))
         (title (gdev-github--required-text "Titolo della richiesta: "))
         (base (string-trim (read-string "Ramo di destinazione (vuoto per quello predefinito): "))))
    (gdev-github--compose
     root "Nuova richiesta di integrazione"
     (append (list "pr" "create" "--title" title "--body-file" "-")
             (unless (string-empty-p base) (list "--base" base))
             (when current-prefix-arg '("--draft"))))))

(defvar gdev-github--diff-requests (make-hash-table :test #'equal)
  "Ultima richiesta in corso per ciascuna vista di HitHub.")

(define-derived-mode gdev-github-result-mode special-mode "HitHub"
  "Mostra i dati scaricati da GitHub."
  (gdev-ui-view-setup 'document)
  (visual-line-mode 1))

(gdev-set-popup-rule '(derived-mode . gdev-github-result-mode))

(defun gdev-github--result-buffer (name root content)
  "Aggiorna la vista NAME con CONTENT, relativo alla radice ROOT."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq default-directory root)
      (gdev-github-result-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (string-trim name "\\*" "\\*") 'face 'gdev-ui-view-title) "\n\n"
                (if (string-blank-p content) "Nessun dato da mostrare.\n" content)))
      (goto-char (point-min)))
    buffer))

(defun gdev-github--diff-buffer (name root diff)
  "Aggiorna la vista NAME con DIFF, relativo alla radice ROOT."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq default-directory root)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff))
      (diff-mode)
      (setq buffer-read-only t)
      (goto-char (point-min)))
    buffer))

(defun gdev-github--show-diff (root number)
  "Scarica le differenze della richiesta NUMBER in ROOT."
  (gdev-github--show root (format "Differenze della richiesta #%s" number)
                    #'gdev-github--diff-buffer "pr" "diff" number))

(defun gdev-github--show (root label render &rest arguments)
  "Scarica ARGUMENTS per la vista LABEL in ROOT e la aggiorna con RENDER."
  (let ((name (format "*HitHub · %s · %s*" label (abbreviate-file-name root)))
        (request (make-symbol "richiesta-github"))
        (window (selected-window))
        (source (current-buffer))
        (workspace (and gdev-layout-mode (gdev-workspace-state-ensure-id)))
        started)
    (puthash name request gdev-github--diff-requests)
    (unwind-protect
        (setq started
              (apply #'gdev-github--request
               root
               (lambda (content error-message)
                 (when (eq request (gethash name gdev-github--diff-requests))
                   (remhash name gdev-github--diff-requests)
                   (if error-message
                       (message "%s" error-message)
                     (let ((buffer (funcall render name root content)))
                       (if (and (eq window (selected-window)) (eq source (window-buffer window))
                                (or (not workspace) (eq workspace (gdev-workspace-state-id)))
                                (not (active-minibuffer-window)))
                           (display-buffer buffer)
                         (message "Risultato di HitHub disponibile in %s" name))))))
               arguments))
      (when (and (not started) (eq request (gethash name gdev-github--diff-requests)))
        (remhash name gdev-github--diff-requests)))))

(defconst gdev-github--status-jq
  (concat "def it: . as $s | ({open: \"Aperta\", closed: \"Chiusa\", merged: \"Unita\", "
          "queued: \"In coda\", requested: \"Richiesta\", pending: \"In attesa\", waiting: \"In attesa\", "
          "in_progress: \"In corso\", completed: \"Conclusa\", success: \"Riuscita\", "
          "failure: \"Fallita\", cancelled: \"Annullata\", skipped: \"Saltata\", "
          "timed_out: \"Tempo scaduto\", neutral: \"Neutra\", action_required: \"Intervento richiesto\", "
          "stale: \"Scaduta\", startup_failure: \"Avvio non riuscito\", "
          "approved: \"Approvata\", changes_requested: \"Modifiche richieste\", "
          "commented: \"Commentata\", dismissed: \"Revocata\"}[($s | ascii_downcase)] // $s); "))

(defun gdev-github--topic-number (root kind label)
  "Sceglie una voce KIND in ROOT, mostrando LABEL e i filtri richiesti."
  (let* ((prefix (prefix-numeric-value current-prefix-arg))
         (search (when (>= prefix 16) (gdev-github--required-text "Cerca su GitHub: ")))
         (fields (if (equal kind "pr")
                     "number,title,state,author,isDraft,headRefName" "number,title,state,author"))
         (format-line (concat gdev-github--status-jq
                              ".[] | \"#\\(.number)  \\(.title)  ·  "
                              "\\(if .isDraft then \"Bozza\" else (.state | it) end)"
                              "\\(if .headRefName then \"  ·  \" + .headRefName else \"\" end)"
                              "  ·  @\\(.author.login // \"—\")\"")))
    (gdev-github--number
     (apply #'gdev-github--choose root label t kind "list" "--limit" "100" "--json" fields "--jq"
            format-line (append (when (>= prefix 4) '("--state" "all"))
                                (when search (list "--search" search)))))))

(defun gdev-github--topic-show (root kind number _label)
  "Apre la conversazione della voce KIND NUMBER di ROOT."
  (gdev-github-topic root (if (equal kind "pr") 'pull 'issue) number))

(defun gdev-github--topic-edit (root kind number label)
  "Aggiorna i metadati della voce KIND NUMBER in ROOT, indicata da LABEL."
  (let* ((action
          (car (read-multiple-choice
                label
                (append '((?t "titolo" "modifica il titolo")
                          (?d "descrizione" "sostituisci la descrizione")
                          (?l "aggiungi etichette" "aggiungi una o più etichette")
                          (?e "rimuovi etichette" "rimuovi una o più etichette")
                          (?a "assegna" "aggiungi uno o più responsabili")
                          (?r "rimuovi responsabili" "rimuovi uno o più responsabili")
                          (?m "traguardo" "imposta il traguardo"))
                        (when (equal kind "pr")
                          '((?v "richiedi revisione" "aggiungi uno o più revisori")
                            (?b "ramo di destinazione" "cambia il ramo di destinazione")))))))
         (flag (alist-get action '((?t . "--title") (?l . "--add-label") (?e . "--remove-label")
                                   (?a . "--add-assignee") (?r . "--remove-assignee")
                                   (?m . "--milestone") (?v . "--add-reviewer") (?b . "--base")))))
    (if (eq action ?d)
        (let ((environment process-environment)
              (path exec-path))
          (gdev-github--request
           root
           (lambda (body failure)
             (if failure
                 (message "%s" failure)
               (let ((process-environment environment) (exec-path path))
                 (gdev-github--compose root label (list kind "edit" number "--body-file" "-") body))))
           kind "view" number "--json" "body" "--jq" ".body"))
      (gdev-github--submit root label (list kind "edit" number flag
                                          (gdev-github--required-text
                                           (if (memq action '(?l ?e ?a ?r ?v))
                                               "Nomi separati da virgole: " "Nuovo valore: ")))))))

(defun gdev-github--review (root number label)
  "Scrive una revisione della richiesta NUMBER in ROOT, indicata da LABEL."
  (let ((flag (alist-get
               (car (read-multiple-choice label '((?a "approva" "approva la richiesta")
                                                 (?m "chiedi modifiche" "indica le modifiche necessarie")
                                                 (?c "commenta" "invia una revisione senza esprimere un esito"))))
               '((?a . "--approve") (?m . "--request-changes") (?c . "--comment")))))
    (gdev-github--compose root (format "Revisione della richiesta #%s" number)
                         (list "pr" "review" number flag "--body-file" "-") nil
                         (not (equal flag "--approve")))))

(defun gdev-github--merge (root number label)
  "Unisce la richiesta NUMBER in ROOT dopo la scelta del metodo per LABEL."
  (let ((flag (alist-get
               (car (read-multiple-choice label '((?u "unisci" "crea una registrazione di unione")
                                                 (?s "compatta" "unisci tutte le registrazioni in una")
                                                 (?r "riallinea" "riapplica le registrazioni al ramo di destinazione"))))
               '((?u . "--merge") (?s . "--squash") (?r . "--rebase")))))
    (when (yes-or-no-p (format "Unire la richiesta #%s su GitHub? " number))
      (gdev-github--submit root label (list "pr" "merge" number flag)))))

(defconst gdev-github--pull-request-actions
  '((?i "leggi" "leggi descrizione, commenti e revisioni")
    (?d "differenze" "mostra i cambiamenti della richiesta")
    (?c "cambia ramo" "scarica e apri il ramo della richiesta")
    (?k "controlli" "mostra lo stato dei controlli automatici")
    (?r "revisiona" "approva, commenta o chiedi modifiche")
    (?m "commenta" "scrivi un commento")
    (?e "modifica" "cambia titolo, descrizione, revisori o etichette")
    (?u "unisci" "scegli il metodo di unione")
    (?p "pronta" "trasforma la bozza in una richiesta da verificare")
    (?t "bozza" "riporta la richiesta allo stato di bozza")
    (?x "chiudi" "chiudi senza unire")
    (?a "riapri" "riapri una richiesta chiusa")
    (?b "apri nel navigatore" "apri la pagina su GitHub"))
  "Azioni su una richiesta di integrazione, nell'ordine dei menu.")

(defun gdev-github--choose-action (label actions)
  "Sceglie con LABEL una delle ACTIONS e ne restituisce il carattere."
  (car (read-multiple-choice label actions)))

(defun gdev-github-pull-requests ()
  "Esplora le richieste. Con C-u include le chiuse, con C-u C-u cerca."
  (interactive)
  (let* ((root (gdev-project-root))
         (default-directory root)
         (number (gdev-github--topic-number root "pr" "Richiesta: ")))
    (gdev-github--pull-request-act
     root number (gdev-github--choose-action (format "Richiesta #%s" number)
                                             gdev-github--pull-request-actions))))

(defun gdev-github--pull-request-act (root number action)
  "Esegue ACTION, uno dei caratteri di `gdev-github--pull-request-actions'.
Agisce sulla richiesta NUMBER dell'archivio in ROOT."
  (let ((default-directory root)
        (label (format "Richiesta #%s" number)))
    (pcase action
      (?i (gdev-github--topic-show root "pr" number label))
      (?c (gdev-github--run "HitHub · Cambia ramo" nil "pr" "checkout" number))
      (?d (gdev-github--show-diff root number))
      (?k (gdev-github--checks root number))
      (?r (gdev-github--review root number label))
      (?m (gdev-github--compose root label (list "pr" "comment" number "--body-file" "-") nil t))
      (?e (gdev-github--topic-edit root "pr" number label))
      (?u (gdev-github--merge root number label))
      (?p (gdev-github--submit root label (list "pr" "ready" number)))
      (?t (gdev-github--submit root label (list "pr" "ready" number "--undo")))
      (?x (when (yes-or-no-p (format "Chiudere la richiesta #%s? " number))
            (gdev-github--submit root label (list "pr" "close" number))))
      (?a (gdev-github--submit root label (list "pr" "reopen" number)))
      (?b (gdev-github--request root #'gdev-github--report-error "pr" "view" number "--web")))))

(defun gdev-github-issue-create ()
  "Scrive in Emacs una segnalazione per il repository corrente."
  (interactive)
  (gdev-github--compose
   (gdev-project-root) "Nuova segnalazione"
   (list "issue" "create" "--title" (gdev-github--required-text "Titolo della segnalazione: ") "--body-file" "-")))

(defconst gdev-github--issue-actions
  '((?i "leggi" "leggi descrizione e commenti")
    (?c "commenta" "scrivi un commento")
    (?e "modifica" "cambia titolo, descrizione, etichette o responsabili")
    (?r "crea ramo" "collega un ramo Git alla segnalazione e aprilo")
    (?x "chiudi" "chiudi indicando il motivo")
    (?a "riapri" "riapri una segnalazione chiusa")
    (?b "apri nel navigatore" "apri la pagina su GitHub"))
  "Azioni su una segnalazione, nell'ordine dei menu.")

(defun gdev-github-issues ()
  "Esplora le segnalazioni. Con C-u include le chiuse, con C-u C-u cerca."
  (interactive)
  (let* ((root (gdev-project-root))
         (number (gdev-github--topic-number root "issue" "Segnalazione: ")))
    (gdev-github--issue-act
     root number (gdev-github--choose-action (format "Segnalazione #%s" number)
                                             gdev-github--issue-actions))))

(defun gdev-github--issue-act (root number action)
  "Esegue ACTION, uno dei caratteri di `gdev-github--issue-actions'.
Agisce sulla segnalazione NUMBER dell'archivio in ROOT."
  (let ((default-directory root)
        (label (format "Segnalazione #%s" number)))
    (pcase action
      (?i (gdev-github--topic-show root "issue" number label))
      (?c (gdev-github--compose root label (list "issue" "comment" number "--body-file" "-") nil t))
      (?e (gdev-github--topic-edit root "issue" number label))
      (?r (let ((branch (gdev-github--required-text "Nome del ramo: ")))
            (gdev-github--submit root label (list "issue" "develop" number "--name" branch "--checkout"))))
      (?x (let ((reason (completing-read "Motivo della chiusura: " '("completata" "non pianificata") nil t)))
            (gdev-github--submit root label (list "issue" "close" number "--reason"
                                                (if (equal reason "completata") "completed" "not planned")))))
      (?a (gdev-github--submit root label (list "issue" "reopen" number)))
      (?b (gdev-github--request root #'gdev-github--report-error "issue" "view" number "--web")))))

(defun gdev-github-pull-request-checks (&optional watch)
  "Mostra i controlli della richiesta del ramo corrente.
Con WATCH (prefisso C-u) li segue fino alla fine."
  (interactive "P")
  (if watch
      (gdev-github--run "HitHub · Controlli della richiesta" nil "pr" "checks" "--watch")
    (gdev-github--checks (gdev-project-root) nil)))

(defun gdev-github--checks (root number)
  "Mostra in ROOT i controlli della richiesta NUMBER o del ramo attivo."
  (apply #'gdev-github--show root
         (if number (format "Controlli della richiesta #%s" number) "Controlli del ramo")
         #'gdev-github--result-buffer "pr" "checks"
         (append (when number (list number))
                 '("--json" "name,bucket,workflow,link" "--jq"
                   ".[] | \"\\(.name) · \\(.workflow) · \\({pass: \"Riuscito\", fail: \"Fallito\", pending: \"In attesa\", skipping: \"Saltato\", cancel: \"Annullato\"}[.bucket] // .bucket)  \\(.link)\""))))

;;;; Flussi automatici (workflow) di GitHub Actions

(defconst gdev-github--run-actions
  '((?i "riepilogo" "mostra stato e processi dell'esecuzione")
    (?l "registro" "mostra il registro completo")
    (?f "errori" "mostra i passaggi non riusciti")
    (?s "segui" "segui l'esecuzione fino alla conclusione")
    (?d "scarica prodotti" "scarica i prodotti in una cartella")
    (?r "riesegui" "riesegui l'intero flusso")
    (?e "riesegui falliti" "riesegui i processi non riusciti")
    (?a "annulla" "interrompi l'esecuzione su GitHub")
    (?b "apri nel navigatore" "apri la pagina su GitHub"))
  "Azioni su un'esecuzione di un flusso automatico, nell'ordine dei menu.")

(defun gdev-github-runs ()
  "Sceglie un'esecuzione e accede a stato, registri e prodotti."
  (interactive)
  (let* ((root (gdev-project-root))
         (default-directory root)
         (id (gdev-github--number
              (gdev-github--choose
               root "Esecuzione: " t "run" "list" "--limit" "50" "--json"
               "databaseId,displayTitle,status,conclusion,workflowName,headBranch" "--jq"
               (concat gdev-github--status-jq
                       ".[] | \"#\\(.databaseId)  \\(.displayTitle)  ·  \\(.workflowName)  ·  "
                       "\\(.headBranch)  ·  \\((if .conclusion == \"\" then .status else .conclusion end) | it)\"")))))
    (gdev-github--run-act root id (gdev-github--choose-action (format "Esecuzione #%s" id)
                                                             gdev-github--run-actions))))

(defun gdev-github--run-act (root id action)
  "Esegue ACTION, uno dei caratteri di `gdev-github--run-actions'.
Agisce sull'esecuzione ID dell'archivio in ROOT."
  (let ((default-directory root)
        (label (format "Esecuzione #%s" id)))
    (pcase action
      (?i (gdev-github--show
           root label #'gdev-github--result-buffer "run" "view" id "--json"
           "displayTitle,status,conclusion,workflowName,headBranch,createdAt,url,jobs" "--jq"
           (concat gdev-github--status-jq
                   "[.displayTitle, \"Flusso · \\(.workflowName)\", \"Ramo · \\(.headBranch)\", "
                   "\"Stato · \\(.status | it)\", \"Esito · \\((.conclusion | it) | select(. != \"\"))\", "
                   ".createdAt, .url, \"\", \"Processi\", "
                   "(.jobs[] | \"\\(.name) · \\(.status | it) \\(.conclusion | it)\")] | join(\"\\n\")")))
      ((or ?l ?f)
       (gdev-github--show root (format "%s · %s" label (if (eq action ?l) "Registro" "Errori"))
                         #'gdev-github--result-buffer "run" "view" id (if (eq action ?l) "--log" "--log-failed")))
      (?s (gdev-github--run (concat "HitHub · " label) nil "run" "watch" id "--exit-status"))
      (?d (gdev-github--submit root label
                              (list "run" "download" id "--dir"
                                    (gdev-github--download-directory root "Scarica i prodotti in: "))))
      ((or ?r ?e ?a)
       (when (yes-or-no-p (format "%s l'esecuzione #%s su GitHub? "
                                 (if (eq action ?a) "Annullare" "Rieseguire") id))
         (gdev-github--submit root label
                             (append (list "run" (if (eq action ?a) "cancel" "rerun") id)
                                     (when (eq action ?e) '("--failed"))))))
      (?b (gdev-github--request root #'gdev-github--report-error "run" "view" id "--web")))))

(defun gdev-github--download-directory (root prompt)
  "Legge con PROMPT una cartella sullo stesso host di ROOT."
  (let ((directory (expand-file-name (read-directory-name prompt root))))
    (unless (equal (file-remote-p directory) (file-remote-p root))
      (user-error "Scegli una cartella sullo stesso host del repository"))
    (file-local-name directory)))

(defun gdev-github-workflow-run ()
  "Avvia un flusso manuale sul ramo o sul tag scelto."
  (interactive)
  (let* ((root (gdev-project-root))
         (id (gdev-github--number
              (gdev-github--choose root "Flusso automatico: " t "workflow" "list"
                                   "--json" "id,name,path" "--jq"
                                   ".[] | \"#\\(.id)  \\(.name)  ·  \\(.path)\"")))
         (ref (string-trim (read-string "Ramo o tag (vuoto per quello predefinito): ")))
         (input (string-trim (read-string "Parametri JSON (vuoto per i valori predefiniti): "))))
    (unless (or (string-empty-p input)
                (condition-case nil (hash-table-p (json-parse-string input)) (json-parse-error nil)))
      (user-error "I parametri devono formare un oggetto JSON"))
    (when (yes-or-no-p (format "Avviare il flusso #%s su GitHub? " id))
      (gdev-github--submit root "Avvio del flusso"
                           (append (list "workflow" "run" id)
                                   (unless (string-empty-p ref) (list "--ref" ref))
                                   (unless (string-empty-p input) '("--json")))
                           (unless (string-empty-p input) input)))))

(defun gdev-github-run-watch ()
  "Segue fino alla fine l'ultima esecuzione di un flusso automatico."
  (interactive)
  (let ((root (gdev-project-root))
        (environment process-environment)
        (path exec-path))
    (gdev-github--request
     root
     (lambda (text error-message)
       (if error-message
           (message "%s" error-message)
         (let ((id (string-trim text)))
           (if (not (string-match-p "\\`[0-9]+\\'" id))
               (message "Nessuna esecuzione in questo repository")
             (with-temp-buffer
               (setq-local process-environment environment
                           exec-path path)
               (gdev-compile (gdev-command-line "gh" "run" "watch" id "--exit-status")
                             (format "HitHub · Esecuzione #%s · %s" id (abbreviate-file-name root)) root))))))
     "run" "list" "--limit" "1" "--json" "databaseId" "--jq" ".[0].databaseId")))

;;;; Versioni pubblicate

(defun gdev-github-release-create ()
  "Scrive una bozza di versione da un tag del repository."
  (interactive)
  (let* ((root (gdev-project-root))
         (tag (gdev-github--required-text "Etichetta (tag) della versione: "))
         (title (gdev-github--required-text "Titolo della versione: " tag))
         (target (string-trim (read-string "Ramo o registrazione per un nuovo tag (facoltativo): "))))
    (gdev-github--compose root "Nuova bozza di versione"
                         (append (list "release" "create" tag "--draft" "--title" title "--notes-file" "-")
                                 (unless (string-empty-p target) (list "--target" target))))))

(defconst gdev-github--release-actions
  '((?i "leggi" "leggi le note e i nomi degli allegati")
    (?d "scarica allegati" "scarica gli allegati in una cartella")
    (?a "carica allegato" "aggiungi un file alla versione")
    (?p "pubblica" "pubblica la bozza")
    (?b "apri nel navigatore" "apri la pagina su GitHub"))
  "Azioni su una versione pubblicata, nell'ordine dei menu.")

(defun gdev-github-releases ()
  "Consulta le versioni e gestisce le bozze e gli allegati."
  (interactive)
  (let* ((root (gdev-project-root))
         (choice (gdev-github--choose
                  root "Versione: " t "release" "list" "--limit" "50" "--json" "tagName,name,isDraft,isPrerelease"
                  "--jq" ".[] | \"\\(.tagName)\\t\\(.name)  ·  \\(if .isDraft then \"Bozza\" elif .isPrerelease then \"Anteprima\" else \"Pubblicata\" end)\""))
         (tag (car (split-string choice "\t"))))
    (gdev-github--release-act root tag (gdev-github--choose-action (format "Versione %s" tag)
                                                                  gdev-github--release-actions))))

(defun gdev-github--release-act (root tag action)
  "Esegue ACTION, uno dei caratteri di `gdev-github--release-actions'.
Agisce sulla versione TAG dell'archivio in ROOT."
  (let ((default-directory root)
        (label (format "Versione %s" tag)))
    (pcase action
      (?i (gdev-github--show
           root label #'gdev-github--result-buffer "release" "view" tag "--json"
           "name,tagName,body,url,assets,isDraft,isPrerelease" "--jq"
           "[.name, .tagName, (if .isDraft then \"Bozza\" elif .isPrerelease then \"Anteprima\" else \"Pubblicata\" end), .url, \"\", .body, \"\", \"Allegati\", (.assets[].name)] | join(\"\\n\")"))
      (?d (gdev-github--submit root label (list "release" "download" tag "--pattern" "*"
                                              "--dir" (gdev-github--download-directory root "Scarica gli allegati in: "))))
      (?a (let ((file (expand-file-name (read-file-name "Allegato: " root nil t))))
            (unless (and (file-regular-p file)
                         (equal (file-remote-p file) (file-remote-p root)))
              (user-error "Scegli un file dove si trova il repository"))
            (when (yes-or-no-p (format "Caricare %s nella versione %s? " (file-name-nondirectory file) tag))
              (gdev-github--submit root label (list "release" "upload" tag (file-local-name file))))))
      (?p (when (yes-or-no-p (format "Pubblicare la bozza della versione %s? " tag))
            (gdev-github--submit root label (list "release" "edit" tag "--draft=false"))))
      (?b (gdev-github--request root #'gdev-github--report-error "release" "view" tag "--web")))))

;;;; Archivi Git, account e notifiche

(defun gdev-github-copy-permalink ()
  "Copia il collegamento permanente al file e alla riga corrente."
  (interactive)
  (unless buffer-file-name (user-error "Apri un file dell'archivio Git"))
  (let ((root (gdev-project-root)))
    (gdev-github--request
     root (lambda (output failure)
            (if failure
                (message "%s" failure)
              (let ((url (string-trim output)))
                (when (string-match-p "\\`https?://" url)
                  (kill-new url)
                  (message "Collegamento permanente copiato")))))
     "browse" "--no-browser" "--commit=HEAD"
     (format "%s:%d" (file-relative-name buffer-file-name root) (line-number-at-pos nil t)))))

(defun gdev-github-repository-fork ()
  "Crea su GitHub un fork dell'archivio corrente."
  (interactive)
  (when (yes-or-no-p "Creare un fork dell'archivio corrente su GitHub? ")
    (gdev-github--submit (gdev-project-root) "Creazione del fork"
                         '("repo" "fork" "--clone=false" "--remote=false"))))

(defun gdev-github-repository-default ()
  "Sceglie da quale archivio remoto leggere richieste, versioni e Actions."
  (interactive)
  (let ((root (gdev-project-root)))
    (gdev-github--submit root "Archivio GitHub predefinito"
                         (list "repo" "set-default"
                               (gdev-github--required-text "Archivio remoto (ad es. origin): " "origin")))))

(defun gdev-github-repository-sync ()
  "Aggiorna su GitHub il fork scelto dal suo progetto di origine."
  (interactive)
  (let ((root (gdev-project-root))
        (fork (gdev-github--required-text "Fork da sincronizzare (proprietario/archivio): "))
        (branch (string-trim (read-string "Ramo da sincronizzare (vuoto per quello predefinito): "))))
    (when (yes-or-no-p (format "Sincronizzare %s su GitHub? " fork))
      (gdev-github--submit root "Sincronizzazione del fork"
                           (append (list "repo" "sync" fork)
                                   (unless (string-empty-p branch) (list "--branch" branch)))))))

(defun gdev-github-repository-projects ()
  "Apre i progetti collegati al repository su GitHub."
  (interactive)
  (gdev-github--request (gdev-project-root) #'gdev-github--report-error "browse" "--projects"))

(defun gdev-github--browse-result (output failure)
  "Apre nel navigatore l'indirizzo in OUTPUT o mostra FAILURE."
  (cond
   (failure (message "%s" failure))
   ((string-match-p "\\`https?://[^[:space:]]+\\'" (string-trim output))
    (browse-url (string-trim output)))
   (t (message "HitHub · Indirizzo non disponibile"))))

(defun gdev-github-repository-discussions ()
  "Apre le discussioni del repository su GitHub."
  (interactive)
  (gdev-github--request (gdev-project-root) #'gdev-github--browse-result
                        "repo" "view" "--json" "url" "--jq" ".url + \"/discussions\""))

(defun gdev-github-local-directory ()
  "Restituisce una cartella locale per le azioni legate all'account."
  (or (unhandled-file-name-directory default-directory) (expand-file-name "~/")))

(defun gdev-github-auth-status ()
  "Mostra gli account GitHub e la validità dell'accesso."
  (interactive)
  (gdev-github--show
   (gdev-github-local-directory) "Account" #'gdev-github--result-buffer "auth" "status" "--json" "hosts"
   "--jq" ".hosts | to_entries[] | .key as $host | .value[] | \"\\($host) · @\\(.login) · \\(if .active then \"In uso\" else \"Disponibile\" end) · \\(if .state == \"success\" then \"Accesso valido\" else \"Verifica l’accesso\" end)\""))

(defun gdev-github-auth-login ()
  "Accede a GitHub con il navigatore e il codice dispositivo di gh."
  (interactive)
  (let* ((default-directory (gdev-github-local-directory))
         (host (gdev-github--required-text "Server GitHub: " "github.com")))
    (gdev-compile (gdev-command-line "gh" "auth" "login" "--hostname" host "--web" "--git-protocol" "https")
                  "HitHub · Accedi" default-directory t)))

(defun gdev-github-auth-switch ()
  "Cambia l'account attivo per un server GitHub."
  (interactive)
  (let* ((root (gdev-github-local-directory))
         (choice (gdev-github--choose
                  root "Account GitHub: " t "auth" "status" "--json" "hosts" "--jq"
                  ".hosts | to_entries[] | .key as $host | .value[] | select(.active | not) | [$host, .login] | @tsv"))
         (fields (split-string choice "\t")))
    (gdev-github--submit root "Cambio account"
                         (list "auth" "switch" "--hostname" (car fields) "--user" (cadr fields)))))

(defun gdev-github--notification-open (root endpoint)
  "Apre nel navigatore la destinazione della notifica ENDPOINT di ROOT."
  (gdev-github--request
   root #'gdev-github--browse-result "api" endpoint "--jq"
   (concat ".repository.html_url + (.subject | "
           "if .url == null then \"\" "
           "elif .type == \"PullRequest\" then \"/pull/\" + (.url | split(\"/\") | last) "
           "elif .type == \"Issue\" then \"/issues/\" + (.url | split(\"/\") | last) "
           "elif .type == \"Discussion\" then \"/discussions/\" + (.url | split(\"/\") | last) "
           "elif .type == \"Release\" then \"/releases\" else \"\" end)")))

(defconst gdev-github--notification-actions
  '((?b "apri nel navigatore" "apri la destinazione della notifica")
    (?l "segna come letta" "segna solo questa notifica come letta"))
  "Azioni su una notifica, nell'ordine dei menu.")

(defun gdev-github-notifications ()
  "Consulta le notifiche GitHub. Con C-u include quelle già lette."
  (interactive)
  (let* ((root (gdev-github-local-directory))
         (number (gdev-github--number
                  (gdev-github--choose
                   root "Notifica: " t "api" "--method" "GET" "notifications" "--raw-field" "per_page=50"
                   "--raw-field" (if current-prefix-arg "all=true" "all=false") "--jq"
                   ".[] | \"#\\(.id)  \\(.repository.full_name)  ·  \\(.subject.title)  ·  \\(if .unread then \"Da leggere\" else \"Letta\" end)\"")))
         (action (gdev-github--choose-action "Notifica GitHub" gdev-github--notification-actions)))
    (gdev-github--notification-act root number action)))

(defun gdev-github--notification-act (root id action)
  "Esegue ACTION, uno dei caratteri di `gdev-github--notification-actions'.
Agisce sulla notifica ID, richiesta da ROOT."
  (let ((endpoint (concat "notifications/threads/" id)))
    (pcase action
      (?b (gdev-github--notification-open root endpoint))
      (?l (gdev-github--submit root "Notifica letta" (list "api" "--method" "PATCH" endpoint))))))

;;;; Frammenti condivisi (gist)

(defvar gdev-github--gist-request nil
  "Richiesta di frammento più recente, autorizzata ad aggiornare gli appunti.")

(defun gdev-github-gist (public)
  "Crea in secondo piano un frammento dalla selezione o dall'area di testo.
Copia l'indirizzo della richiesta più recente appena disponibile.
Il frammento è segreto. Con PUBLIC (prefisso C-u) diventa pubblico
dopo conferma."
  (interactive "P")
  (when (and public (not (yes-or-no-p "Creare un frammento condiviso (gist) pubblico? ")))
    (user-error "Annullato"))
  (let* ((region (use-region-p))
         (start (if region (region-beginning) (point-min)))
         (end (if region (region-end) (point-max)))
         (name (if buffer-file-name (file-name-nondirectory buffer-file-name) "frammento.txt"))
         (request (make-symbol "richiesta-frammento")))
    (setq gdev-github--gist-request request)
    (gdev-github--start
     ;; I frammenti usano gh locale anche quando il documento è remoto.
     (or (unhandled-file-name-directory default-directory) (expand-file-name "~/" "/"))
     (lambda (output failure)
       (if failure
           (message "%s" failure)
         (let ((url (car (last (split-string (string-trim-right output) "\n" t)))))
           (cond ((not url) (message "gh gist: nessun indirizzo restituito"))
                 ((eq request gdev-github--gist-request)
                  (kill-new url)
                  (message "Indirizzo del frammento copiato negli appunti · %s" url))
                 (t (message "Frammento creato · %s" url))))))
     (append (list "gist" "create" "--filename" name) (when public '("--public")) '("-"))
     (buffer-substring-no-properties start end))))

;;;; Identità

(defun gdev-github--identities ()
  "Le identità configurate, oppure quella di `user-full-name'."
  (or gdev-git-identities
      (and user-mail-address (list (cons user-full-name user-mail-address)))))

(defun gdev-github-set-identity (identity)
  "Imposta nome ed email Git di questo archivio Git secondo IDENTITY.
Vale solo per l'archivio Git corrente (git config locale)."
  (interactive
   (let* ((identities (gdev-github--identities))
          (labels (mapcar (pcase-lambda (`(,name . ,mail)) (format "%s <%s>" name mail))
                          identities)))
     (unless identities
       (user-error "Nessuna identità: imposta gdev-git-identities nel config.el privato"))
     (list (nth (cl-position (completing-read "Identità per questo repository: " labels nil t)
                             labels :test #'equal)
                identities))))
  (let ((default-directory (gdev-project-root)))
    (process-file "git" nil nil nil "config" "user.name" (car identity))
    (process-file "git" nil nil nil "config" "user.email" (cdr identity))
    (message "git ▸ %s <%s> per %s" (car identity) (cdr identity) (gdev-project-name))))

;;;; Panoramica e conversazioni

;; Le viste stanno in un file a parte e si caricano al primo uso.
(let ((library (gdev-config-file "modules/tools/hithub/gdev-hithub-view")))
  (autoload 'gdev-github-overview library "Apri la panoramica di HitHub dell'archivio." t)
  (autoload 'gdev-github-topic library))

;;;; Tasti e diagnosi

(defun hithub-guida ()
  "Apri la guida di HitHub per lavorare con GitHub."
  (interactive)
  (gdev-describe-module :tools 'hithub))

(defvar-keymap gdev-github-map :doc "C-c g h: HitHub.")
(defvar-keymap gdev-github-account-map :doc "Account GitHub.")
(defvar-keymap gdev-github-repository-map :doc "Archivi GitHub.")

(gdev-bind gdev-github-account-map
           "s" "stato degli account" #'gdev-github-auth-status
           "a" "accedi a GitHub" #'gdev-github-auth-login
           "c" "cambia account" #'gdev-github-auth-switch)

(gdev-bind gdev-github-repository-map
           "f" "crea un fork" #'gdev-github-repository-fork
           "s" "sincronizza il fork" #'gdev-github-repository-sync
           "p" "apri i progetti nel navigatore" #'gdev-github-repository-projects
           "o" "apri le discussioni nel navigatore" #'gdev-github-repository-discussions
           "d" "scegli l'archivio predefinito" #'gdev-github-repository-default)

(gdev-bind gdev-github-map
           "h" "panoramica dell'archivio" #'gdev-github-overview
           "b" "apri nel navigatore" #'gdev-github-browse
           "c" "clona un archivio Git" #'gdev-github-clone
           "n" "crea l'archivio su GitHub" #'gdev-github-create-repository
           "p" "nuova richiesta di integrazione" #'gdev-github-pull-request-create
           "l" "esplora richieste di integrazione" #'gdev-github-pull-requests
           "k" "controlli della richiesta" #'gdev-github-pull-request-checks
           "a" "esecuzioni (GitHub Actions)" #'gdev-github-runs
           "u" "avvia un flusso automatico" #'gdev-github-workflow-run
           "w" "segui l'ultima esecuzione" #'gdev-github-run-watch
           "s" "esplora segnalazioni" #'gdev-github-issues
           "S" "nuova segnalazione" #'gdev-github-issue-create
           "r" "esplora versioni pubblicate" #'gdev-github-releases
           "R" "nuova bozza di versione" #'gdev-github-release-create
           "o" "notifiche" #'gdev-github-notifications
           "y" "copia il collegamento permanente" #'gdev-github-copy-permalink
           "A" "Account" gdev-github-account-map
           "d" "Archivi Git" gdev-github-repository-map
           "g" "pubblica un frammento di codice" #'gdev-github-gist
           "i" "identità dell'archivio Git" #'gdev-github-set-identity)

(gdev-bind gdev-git-map "h" "HitHub" gdev-github-map)

(gdev-doctor-executable "gh" "brew install gh, poi gh auth login")

;;; config.el ends here
