;;; gdev-hithub-view.el --- Panoramica e conversazioni di HitHub -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La panoramica raccoglie in una vista le richieste di integrazione, le
;; segnalazioni, le esecuzioni dei flussi automatici, le versioni e le
;; notifiche dell'archivio GitHub del progetto.  Ogni voce mostra stato,
;; titolo e dettagli su due righe.  Invio apre la conversazione o
;; l'azione principale, `a' tutte le azioni della voce, `c' crea una voce
;; nella sezione, `g' aggiorna, `f' alterna aperte e tutte, `/' cerca.
;; 1-5, `[' e `]' cambiano sezione.  La conversazione di una richiesta o
;; di una segnalazione si legge come un documento, con le azioni in alto.
;;
;; Ogni stato ha un'icona, una parola e un colore.  Le icone sono in
;; icons/, disegnate per GDev-Emacs, e in un terminale lasciano il posto
;; a un simbolo.

;;; Code:

(require 'gdev-ui)
(require 'gdev-layout)
(require 'parse-time)
(require 'seq)
(require 'subr-x)

(defvar gdev-github-after-change-functions)
(defvar gdev-github--pull-request-actions)
(defvar gdev-github--issue-actions)
(defvar gdev-github--run-actions)
(defvar gdev-github--release-actions)
(defvar gdev-github--notification-actions)
(declare-function gdev-github--request "config" (directory callback &rest arguments))
(declare-function gdev-github--choose-action "config" (label actions))
(declare-function gdev-github--pull-request-act "config" (root number action))
(declare-function gdev-github--issue-act "config" (root number action))
(declare-function gdev-github--run-act "config" (root id action))
(declare-function gdev-github--release-act "config" (root tag action))
(declare-function gdev-github--notification-act "config" (root id action))
(declare-function gdev-github-pull-request-create "config" ())
(declare-function gdev-github-issue-create "config" ())
(declare-function gdev-github-workflow-run "config" ())
(declare-function gdev-github-run-watch "config" ())
(declare-function gdev-github-release-create "config" ())
(declare-function gdev-github-auth-login "config" ())
(declare-function gdev-project-root "gdev-lib" (&optional directory))

;;;; Stati

(defun gdev-github-view--age (timestamp &optional now)
  "Descrive in italiano quanto tempo è passato da TIMESTAMP (ISO 8601).
NOW sostituisce l'ora corrente."
  (when-let* (((and (stringp timestamp) (not (string-empty-p timestamp))))
              (time (ignore-errors (parse-iso8601-time-string timestamp))))
    (let ((seconds (float-time (time-subtract (or now (current-time)) time))))
      (cond ((< seconds 60) "adesso")
            ((< seconds 3600) (format "%d min fa" (floor seconds 60)))
            ((< seconds 7200) "1 ora fa")
            ((< seconds 86400) (format "%d ore fa" (floor seconds 3600)))
            ((< seconds 172800) "ieri")
            ((< seconds 604800) (format "%d giorni fa" (floor seconds 86400)))
            (t (format-time-string "%d/%m/%Y" time))))))

(defun gdev-github-view--date (timestamp)
  "Restituisce data e ora complete di TIMESTAMP per i suggerimenti."
  (when-let* (((stringp timestamp))
              (time (ignore-errors (parse-iso8601-time-string timestamp))))
    (format-time-string "%d/%m/%Y %H:%M" time)))

(defun gdev-github-view--checks (rollup)
  "Riassume i controlli automatici ROLLUP in (ICONA FACCIA ETICHETTA)."
  (let ((failed 0) (pending 0) (total 0))
    (dolist (check rollup)
      (let ((conclusion (alist-get 'conclusion check))
            (status (alist-get 'status check))
            (state (alist-get 'state check)))
        (setq total (1+ total))
        (cond ((or (member conclusion '("FAILURE" "TIMED_OUT" "ACTION_REQUIRED" "STARTUP_FAILURE"))
                   (member state '("FAILURE" "ERROR")))
               (setq failed (1+ failed)))
              ((or (member state '("PENDING" "EXPECTED"))
                   (and status (not (equal status "COMPLETED"))))
               (setq pending (1+ pending))))))
    (cond ((zerop total) nil)
          ((> failed 0)
           (list "status-failure" 'gdev-ui-status-error
                 (if (= failed 1) "1 controllo non riuscito"
                   (format "%d controlli non riusciti" failed))))
          ((> pending 0)
           (list "status-pending" 'gdev-ui-status-warning
                 (format "Controlli in corso · %d di %d" (- total pending) total)))
          (t (list "status-success" 'gdev-ui-status-success
                   (if (= total 1) "Controllo riuscito"
                     (format "%d controlli riusciti" total)))))))

(defun gdev-github-view--review (decision)
  "Restituisce (ICONA FACCIA ETICHETTA) per la revisione DECISION."
  (pcase decision
    ("APPROVED" '("review" gdev-ui-status-success "Approvata"))
    ("CHANGES_REQUESTED" '("review" gdev-ui-status-warning "Modifiche richieste"))
    ("REVIEW_REQUIRED" '("review" gdev-ui-secondary "Revisione richiesta"))))

(defun gdev-github-view--login (object)
  "Restituisce @utente dell'autore di OBJECT."
  (concat "@" (or (alist-get 'login (alist-get 'author object)) "—")))

(defconst gdev-github-view--events
  '(("push" . "invio") ("pull_request" . "richiesta di integrazione")
    ("pull_request_target" . "richiesta di integrazione da una copia")
    ("pull_request_review" . "revisione") ("pull_request_review_comment" . "commento di revisione")
    ("workflow_dispatch" . "avvio manuale") ("workflow_run" . "flusso a cascata")
    ("workflow_call" . "flusso richiamato") ("repository_dispatch" . "evento esterno")
    ("schedule" . "pianificazione") ("dynamic" . "automatico")
    ("release" . "versione") ("merge_group" . "coda di unione")
    ("issues" . "segnalazione") ("issue_comment" . "commento")
    ("create" . "creazione") ("delete" . "eliminazione") ("fork" . "copia")
    ("check_run" . "controllo") ("check_suite" . "controlli") ("status" . "stato")
    ("deployment" . "distribuzione") ("page_build" . "pubblicazione delle pagine")
    ("discussion" . "discussione") ("watch" . "stella"))
  "Eventi che avviano un flusso automatico, in italiano.")

(defconst gdev-github-view--subjects
  '(("PullRequest" . "Richiesta") ("Issue" . "Segnalazione") ("Release" . "Versione")
    ("Discussion" . "Discussione") ("CheckSuite" . "Controlli") ("Commit" . "Registrazione")
    ("RepositoryInvitation" . "Invito") ("RepositoryVulnerabilityAlert" . "Avviso di sicurezza")
    ("RepositoryDependabotAlertsThread" . "Avvisi di Dependabot"))
  "Tipi di notifica, in italiano.")

(defconst gdev-github-view--reasons
  '(("review_requested" . "revisione richiesta") ("mention" . "menzione")
    ("team_mention" . "menzione del gruppo") ("assign" . "assegnazione")
    ("author" . "autore") ("comment" . "commento") ("subscribed" . "iscrizione")
    ("manual" . "iscrizione manuale") ("state_change" . "cambio di stato")
    ("ci_activity" . "flussi automatici") ("security_alert" . "avviso di sicurezza")
    ("invitation" . "invito") ("approval_requested" . "approvazione richiesta")
    ("member_feature_requested" . "funzione richiesta da un membro")
    ("security_advisory_credit" . "riconoscimento di sicurezza")
    ("your_activity" . "attività personale"))
  "Motivi delle notifiche, in italiano.")

(defun gdev-github-view--translate (value table)
  "VALUE nella tabella TABLE, o leggibile se GitHub ne ha aggiunto uno nuovo.
Un valore sconosciuto compare senza trattini bassi, mai come identificatore."
  (and value (or (cdr (assoc value table)) (string-replace "_" " " value))))

(defun gdev-github-view--pull (item)
  "Descrive la richiesta ITEM restituita da gh."
  (let* ((state (alist-get 'state item))
         (look (cond ((and (equal state "OPEN") (alist-get 'isDraft item))
                      '("status-draft" gdev-ui-secondary "Bozza"))
                     ((equal state "OPEN") '("git-pull-request" gdev-ui-status-success "Aperta"))
                     ((equal state "MERGED") '("git-merge" gdev-ui-status-accent "Unita"))
                     (t '("git-pull-request" gdev-ui-status-error "Chiusa")))))
    (list :id (number-to-string (alist-get 'number item))
          :title (alist-get 'title item) :look look
          :details (list (format "#%d" (alist-get 'number item))
                         (format "%s → %s" (alist-get 'headRefName item) (alist-get 'baseRefName item))
                         (gdev-github-view--login item))
          :badges (delq nil (list (gdev-github-view--checks (alist-get 'statusCheckRollup item))
                                  (gdev-github-view--review (alist-get 'reviewDecision item))))
          :time (alist-get 'updatedAt item))))

(defun gdev-github-view--issue (item)
  "Descrive la segnalazione ITEM restituita da gh."
  (let* ((reason (alist-get 'stateReason item))
         (labels (mapcar (lambda (label) (alist-get 'name label)) (alist-get 'labels item)))
         (look (cond ((equal (alist-get 'state item) "OPEN") '("issue" gdev-ui-status-success "Aperta"))
                     ((equal reason "NOT_PLANNED") '("status-failure" gdev-ui-secondary "Non pianificata"))
                     (t '("status-success" gdev-ui-status-accent "Completata")))))
    (list :id (number-to-string (alist-get 'number item))
          :title (alist-get 'title item) :look look
          :details (delq nil (list (format "#%d" (alist-get 'number item))
                                   (gdev-github-view--login item)
                                   (when labels
                                     (if (> (length labels) 3)
                                         (format "%s +%d" (string-join (seq-take labels 3) ", ")
                                                 (- (length labels) 3))
                                       (string-join labels ", ")))))
          :time (alist-get 'updatedAt item))))

(defun gdev-github-view--run (item)
  "Descrive l'esecuzione ITEM restituita da gh."
  (let* ((status (alist-get 'status item))
         (conclusion (alist-get 'conclusion item))
         (look (cond ((member status '("queued" "waiting" "requested" "pending"))
                      '("status-pending" gdev-ui-status-warning "In coda"))
                     ((not (equal status "completed"))
                      '("status-pending" gdev-ui-status-warning "In corso"))
                     ((equal conclusion "success") '("status-success" gdev-ui-status-success "Riuscita"))
                     ((member conclusion '("failure" "timed_out" "startup_failure"))
                      '("status-failure" gdev-ui-status-error "Non riuscita"))
                     ((equal conclusion "cancelled") '("status-failure" gdev-ui-secondary "Annullata"))
                     (t '("workflow" gdev-ui-secondary "Conclusa"))))
         (event (alist-get 'event item)))
    (list :id (number-to-string (alist-get 'databaseId item))
          :title (alist-get 'displayTitle item) :look look
          :details (delq nil (list (alist-get 'workflowName item)
                                   (alist-get 'headBranch item)
                                   (gdev-github-view--translate event gdev-github-view--events)))
          :time (alist-get 'updatedAt item))))

(defun gdev-github-view--release (item)
  "Descrive la versione ITEM restituita da gh."
  (let ((tag (alist-get 'tagName item)))
    (list :id tag
          :title (let ((name (alist-get 'name item)))
                   (if (and name (not (string-empty-p name))) name tag))
          :look (cond ((alist-get 'isDraft item) '("status-draft" gdev-ui-secondary "Bozza"))
                      ((alist-get 'isPrerelease item) '("tag" gdev-ui-status-warning "Anteprima"))
                      ((alist-get 'isLatest item) '("tag" gdev-ui-status-success "Più recente"))
                      (t '("tag" gdev-ui-action "Pubblicata")))
          :details (list tag)
          :time (or (alist-get 'publishedAt item) (alist-get 'createdAt item)))))

(defun gdev-github-view--notification (item)
  "Descrive la notifica ITEM restituita dall'API di GitHub."
  (let* ((subject (alist-get 'subject item))
         (type (alist-get 'type subject))
         (reason (alist-get 'reason item)))
    (list :id (alist-get 'id item)
          :title (alist-get 'title subject)
          :look (if (alist-get 'unread item)
                    '("bell" gdev-ui-action "Da leggere")
                  '("bell" gdev-ui-secondary "Letta"))
          :details (delq nil (list (gdev-github-view--translate type gdev-github-view--subjects)
                                   (gdev-github-view--translate reason gdev-github-view--reasons)))
          :time (alist-get 'updated_at item))))

;;;; Sezioni

(defconst gdev-github-view--sections
  `((pulls :label "Richieste" :icon "git-pull-request" :parse gdev-github-view--pull
           :empty "Nessuna richiesta aperta" :empty-all "Nessuna richiesta"
           :hint "Le richieste di integrazione dell'archivio compaiono qui."
           :create ("git-pull-request" "+" "Nuova richiesta" gdev-github-pull-request-create)
           :filter t :search t
           :actions gdev-github--pull-request-actions :act gdev-github--pull-request-act :open ?i)
    (issues :label "Segnalazioni" :icon "issue" :parse gdev-github-view--issue
            :empty "Nessuna segnalazione aperta" :empty-all "Nessuna segnalazione"
            :hint "Le segnalazioni dell'archivio compaiono qui."
            :create ("issue" "+" "Nuova segnalazione" gdev-github-issue-create)
            :filter t :search t
            :actions gdev-github--issue-actions :act gdev-github--issue-act :open ?i)
    (runs :label "Esecuzioni" :icon "workflow" :parse gdev-github-view--run
          :empty "Nessuna esecuzione"
          :hint "Le esecuzioni dei flussi automatici (GitHub Actions) compaiono qui."
          :create ("run" "▶" "Avvia un flusso…" gdev-github-workflow-run)
          :extra (("recent" "◷" "Segui l'ultima" gdev-github-run-watch
                   :help "Segui l'ultima esecuzione fino alla conclusione"))
          :actions gdev-github--run-actions :act gdev-github--run-act :open ?i)
    (releases :label "Versioni" :icon "tag" :parse gdev-github-view--release
              :empty "Nessuna versione pubblicata"
              :hint "Le versioni pubblicate e le bozze compaiono qui."
              :create ("tag" "+" "Nuova bozza…" gdev-github-release-create)
              :actions gdev-github--release-actions :act gdev-github--release-act :open ?i)
    (notifications :label "Notifiche" :icon "bell" :parse gdev-github-view--notification
                   :empty "Nessuna notifica da leggere" :empty-all "Nessuna notifica"
                   :hint "Le notifiche di questo archivio compaiono qui."
                   :filter t
                   :actions gdev-github--notification-actions :act gdev-github--notification-act :open ?b))
  "Sezioni della panoramica, nell'ordine dei pulsanti e dei tasti 1-5.")

(defun gdev-github-view--section (key &optional property)
  "Restituisce la descrizione della sezione KEY o la sua PROPERTY."
  (let ((section (alist-get key gdev-github-view--sections)))
    (if property (plist-get section property) section)))

(defun gdev-github-view--arguments (key all query)
  "Argomenti di gh per la sezione KEY, con ALL e la ricerca QUERY."
  (pcase key
    ('pulls (append '("pr" "list" "--limit" "50" "--json"
                      "number,title,state,isDraft,headRefName,baseRefName,author,updatedAt,reviewDecision,statusCheckRollup")
                    (when all '("--state" "all"))
                    (when query (list "--search" query))))
    ('issues (append '("issue" "list" "--limit" "50" "--json"
                       "number,title,state,stateReason,author,updatedAt,labels")
                     (when all '("--state" "all"))
                     (when query (list "--search" query))))
    ('runs '("run" "list" "--limit" "40" "--json"
             "databaseId,displayTitle,status,conclusion,workflowName,headBranch,event,updatedAt"))
    ('releases '("release" "list" "--limit" "40" "--json"
                 "tagName,name,isDraft,isPrerelease,isLatest,publishedAt,createdAt"))
    ('notifications (list "api" "--method" "GET" "repos/{owner}/{repo}/notifications"
                          "--raw-field" "per_page=50"
                          "--raw-field" (if all "all=true" "all=false")))))

(defun gdev-github-view--parse (text)
  "Legge il JSON TEXT di gh come liste di associazioni."
  (json-parse-string text :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

;;;; Stato della vista

(defvar-local gdev-github-view--root nil "Radice dell'archivio mostrato.")
(defvar-local gdev-github-view--current 'pulls "Sezione mostrata.")
(defvar-local gdev-github-view--all nil "Non nil per includere le voci chiuse o lette.")
(defvar-local gdev-github-view--query nil "Ricerca applicata alle richieste e alle segnalazioni.")
(defvar-local gdev-github-view--data nil
  "Dati per sezione: (SEZIONE . (:items VOCI :time ORA :error ERRORE :key CHIAVE)).")
(defvar-local gdev-github-view--requests nil "Richiesta più recente per ogni sezione.")
(defvar-local gdev-github-view--repository nil "Nome e descrizione dell'archivio su GitHub.")
(defvar-local gdev-github-view--selection nil "Sovrapposizione della voce selezionata.")

(defun gdev-github-view--key ()
  "Identifica i filtri con cui sono stati chiesti i dati della sezione."
  (list gdev-github-view--all gdev-github-view--query))

(defun gdev-github-view--entry (&optional key)
  "Dati della sezione KEY, o di quella mostrata."
  (alist-get (or key gdev-github-view--current) gdev-github-view--data))

(defun gdev-github-view--loading-p (&optional key)
  "Non nil se la sezione KEY attende una risposta."
  (alist-get (or key gdev-github-view--current) gdev-github-view--requests))

;;;; Richieste a GitHub

(defun gdev-github-view--fetch (&optional key)
  "Chiede a GitHub le voci della sezione KEY e ridisegna all'arrivo."
  (let* ((key (or key gdev-github-view--current))
         (buffer (current-buffer))
         (filters (gdev-github-view--key))
         (request (make-symbol "richiesta-panoramica")))
    (setf (alist-get key gdev-github-view--requests) request)
    (condition-case problem
        (apply #'gdev-github--request gdev-github-view--root
               (lambda (text failure)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (eq request (alist-get key gdev-github-view--requests))
                       (setf (alist-get key gdev-github-view--requests nil t) nil)
                       (if (equal filters (gdev-github-view--key))
                           (gdev-github-view--receive key filters text failure)
                         ;; I filtri sono cambiati dopo la richiesta: la risposta non vale più.
                         (gdev-github-view--render))))))
               (gdev-github-view--arguments key gdev-github-view--all gdev-github-view--query))
      (error
       (setf (alist-get key gdev-github-view--requests nil t) nil)
       (gdev-github-view--receive key filters nil (error-message-string problem))))
    (gdev-github-view--render)))

(defun gdev-github-view--receive (key filters text failure)
  "Registra per la sezione KEY la risposta TEXT o l'errore FAILURE.
FILTERS sono i filtri attivi alla richiesta."
  (let* ((parser (gdev-github-view--section key :parse))
         (items (and text (not failure)
                     (condition-case nil
                         (mapcar parser (gdev-github-view--parse text))
                       (error (setq failure "GitHub ha restituito dati non leggibili") nil)))))
    (setf (alist-get key gdev-github-view--data)
          (if failure
              (append (list :error failure) (gdev-github-view--entry key))
            (list :items items :time (current-time) :key filters)))
    (gdev-github-view--render)))

(defun gdev-github-view--fetch-repository ()
  "Legge nome e descrizione dell'archivio per l'intestazione."
  (let ((buffer (current-buffer)))
    (ignore-errors
      (gdev-github--request
       gdev-github-view--root
       (lambda (text failure)
         (when (and (buffer-live-p buffer) text (not failure))
           (with-current-buffer buffer
             (setq gdev-github-view--repository (ignore-errors (gdev-github-view--parse text)))
             (gdev-github-view--render))))
       "repo" "view" "--json" "nameWithOwner,description,url"))))

;;;; Disegno

(defconst gdev-github-view--indent 34
  "Rientro in pixel del titolo e dei dettagli, dopo l'icona di stato.")

(defvar-local gdev-github-view--drawn-width nil
  "Larghezza in pixel usata dall'ultimo disegno della vista.")

(defun gdev-github-view--width ()
  "Larghezza in pixel disponibile in ogni finestra che mostra la vista."
  (setq gdev-github-view--drawn-width
        (or (gdev-ui-buffer-pixel-width) (* 100 (frame-char-width)))))

(defun gdev-github-view--text (text)
  "TEXT di GitHub senza ritorni a capo CRLF e senza spazi agli estremi.
I testi scritti dall'interfaccia web arrivano con CR e LF: nel buffer
comparirebbe ^M a ogni riga."
  (string-trim (replace-regexp-in-string "\r\n?" "\n" (or text ""))))

(defun gdev-github-view--fit (text width)
  "Accorcia TEXT a WIDTH pixel."
  (gdev-ui-fit-text text (max width 0) #'gdev-ui-string-pixel-width))

(defun gdev-github-view--insert-header (width)
  "Inserisce titolo e sottotitolo della panoramica, larghi WIDTH pixel."
  (let* ((repository gdev-github-view--repository)
         (name (or (alist-get 'nameWithOwner repository)
                   (file-name-nondirectory (directory-file-name gdev-github-view--root))))
         (entry (gdev-github-view--entry))
         (status (cond ((gdev-github-view--loading-p) "Aggiornamento…")
                       ((plist-get entry :time)
                        (format-time-string "Aggiornata alle %H:%M" (plist-get entry :time))))))
    (insert (gdev-ui-icon "repository" "▣" nil 'gdev-ui-view-title) " "
            (propertize (gdev-github-view--fit (propertize name 'face 'gdev-ui-view-title) (- width 40))
                        'help-echo (or (alist-get 'url repository) gdev-github-view--root))
            "\n")
    (let ((subtitle (string-join (delq nil (list (alist-get 'description repository) status)) " · ")))
      (unless (string-empty-p subtitle)
        (insert (propertize (gdev-github-view--fit subtitle width) 'face 'gdev-ui-secondary
                            'help-echo subtitle)
                "\n")))
    (insert "\n")))

(defun gdev-github-view--insert-sections (width)
  "Inserisce il selettore delle sezioni entro WIDTH pixel."
  (gdev-ui-insert-actions
   (seq-map-indexed
    (lambda (section index)
      (let* ((key (car section))
             (items (plist-get (gdev-github-view--entry key) :items))
             (label (plist-get (cdr section) :label)))
        (list (plist-get (cdr section) :icon) "·"
              (if (and items (plist-get (gdev-github-view--entry key) :time))
                  (format "%s  %d" label (length items))
                label)
              (lambda () (gdev-github-view-show-section key))
              :primary (eq key gdev-github-view--current)
              :help (format "Mostra %s · %d" (downcase label) (1+ index)))))
    gdev-github-view--sections)
   width))

(defun gdev-github-view--insert-toolbar (width)
  "Inserisce le azioni della sezione mostrata entro WIDTH pixel."
  (let* ((key gdev-github-view--current)
         (create (gdev-github-view--section key :create))
         (filter (gdev-github-view--section key :filter))
         (search (gdev-github-view--section key :search)))
    (gdev-ui-insert-actions
     (append
      (when create (list (append create '(:primary t :help "Crea una voce nella sezione · c"))))
      (list (list "refresh" "↻" "Aggiorna" #'gdev-github-view-refresh :help "Chiedi di nuovo i dati · g"))
      (when filter
        (list (list "toggle" "◐"
                    (format "Stato · %s" (if gdev-github-view--all "Tutte"
                                           (if (eq key 'notifications) "Da leggere" "Aperte")))
                    #'gdev-github-view-toggle-filter :help "Alterna voci aperte e tutte · f")))
      (when search
        (list (list "search" "⌕"
                    (if gdev-github-view--query (format "Cerca · %s" gdev-github-view--query) "Cerca…")
                    #'gdev-github-view-search :help "Filtra con la ricerca di GitHub · /")))
      (gdev-github-view--section key :extra)
      (list (list "open" "↗" "Apri su GitHub" #'gdev-github-view-browse
                  :help "Apri nel navigatore la voce selezionata o l'archivio · b")))
     width)
    (insert "\n")))

(defun gdev-github-view--insert-state (icon face title text &rest actions)
  "Inserisce uno stato vuoto con ICON in FACE, TITLE, TEXT e ACTIONS."
  (insert "\n" (gdev-ui-icon icon " " nil face (* 3 (frame-char-height))) "\n"
          (propertize title 'face 'gdev-ui-view-heading) "\n")
  (when text
    (insert (propertize text 'face 'gdev-ui-secondary) "\n"))
  (when actions
    (insert "\n")
    (gdev-ui-insert-actions actions)))

(defun gdev-github-view--insert-item (item width)
  "Inserisce la voce ITEM su due righe larghe WIDTH pixel."
  (pcase-let* ((`(,icon ,face ,state) (plist-get item :look))
               (start (point))
               (age (gdev-github-view--age (plist-get item :time)))
               (age-text (if age (propertize age 'face 'gdev-ui-secondary
                                             'help-echo (gdev-github-view--date (plist-get item :time)))
                           ""))
               (indent (propertize " " 'display `(space :align-to (,gdev-github-view--indent))))
               (title (or (plist-get item :title) ""))
               (room (- width gdev-github-view--indent (gdev-ui-string-pixel-width age-text) 28))
               (details (concat (propertize state 'face face)
                                (propertize (concat " · " (string-join (plist-get item :details) " · "))
                                            'face 'gdev-ui-secondary)))
               (badges (mapconcat (pcase-lambda (`(,badge-icon ,badge-face ,label))
                                    (gdev-ui-badge badge-icon "•" badge-face label))
                                  (plist-get item :badges) "   ")))
    (insert " " (gdev-ui-icon icon "•" nil face) indent)
    (insert-text-button (gdev-github-view--fit (propertize title 'face 'gdev-ui-view-heading) room)
                        'face 'gdev-ui-view-heading 'mouse-face 'gdev-ui-side-hover
                        'follow-link t 'help-echo title
                        'action (lambda (_) (gdev-github-view-open)))
    (insert (gdev-ui-align-right age-text) "\n" indent)
    (let* ((line (if (string-empty-p badges) details (concat details "   " badges)))
           (room (- width gdev-github-view--indent 12))
           ;; Il testo completo resta leggibile dal puntatore quando la riga si accorcia.
           (help (substring-no-properties line)))
      (if (<= (gdev-ui-string-pixel-width line) room)
          (insert line "\n")
        (insert (propertize (gdev-github-view--fit details room) 'help-echo help) "\n")
        (unless (string-empty-p badges)
          (insert indent (propertize (gdev-github-view--fit badges room) 'help-echo help) "\n"))))
    (add-text-properties start (point) (list 'gdev-github-item (plist-get item :id)))
    (insert (propertize "\n" 'face '(:height 0.45)))))

(defun gdev-github-view--insert-items (width)
  "Inserisce le voci della sezione mostrata, o il suo stato, entro WIDTH."
  (let* ((key gdev-github-view--current)
         (entry (gdev-github-view--entry))
         (items (plist-get entry :items))
         (failure (plist-get entry :error))
         (create (gdev-github-view--section key :create)))
    (cond
     (failure
      (apply #'gdev-github-view--insert-state "status-failure" 'gdev-ui-status-error
             "GitHub non ha risposto" failure
             (append (list (list "refresh" "↻" "Riprova" #'gdev-github-view-refresh :primary t))
                     (when (string-match-p "gh auth login" failure)
                       (list (list "session" "→" "Accedi a GitHub" #'gdev-github-auth-login))))))
     ((and (gdev-github-view--loading-p)
           ;; Le voci di altri filtri non stanno sotto l'intestazione nuova.
           (or (not (plist-get entry :time))
               (not (equal (plist-get entry :key) (gdev-github-view--key)))))
      (gdev-github-view--insert-state "status-pending" 'gdev-ui-secondary
                                      "Caricamento da GitHub…" nil))
     ((null items)
      (apply #'gdev-github-view--insert-state
             (gdev-github-view--section key :icon) 'gdev-ui-secondary
             (if gdev-github-view--query
                 (format "Nessun risultato per «%s»" gdev-github-view--query)
               (or (and gdev-github-view--all (gdev-github-view--section key :empty-all))
                   (gdev-github-view--section key :empty)))
             (gdev-github-view--section key :hint)
             (when create (list (append create '(:primary t))))))
     (t
      (insert (propertize (cond (gdev-github-view--query
                                 (format "Risultati per «%s»" gdev-github-view--query))
                                ((not (gdev-github-view--section key :filter)) "Più recenti")
                                (gdev-github-view--all "Tutte")
                                ((eq key 'notifications) "Da leggere")
                                (t "Aperte"))
                          'face 'gdev-ui-view-heading)
              "\n\n")
      (dolist (item items)
        (gdev-github-view--insert-item item width))))))

(defun gdev-github-view--render ()
  "Ridisegna la panoramica conservando la voce selezionata."
  (let* ((selected (get-text-property (point) 'gdev-github-item))
         (index (gdev-github-view--item-index))
         (starts (gdev-ui-window-starts))
         (width (gdev-github-view--width))
         (inhibit-read-only t))
    (erase-buffer)
    (gdev-github-view--insert-header width)
    (gdev-github-view--insert-sections width)
    (insert "\n")
    (gdev-github-view--insert-toolbar width)
    (gdev-github-view--insert-items width)
    (goto-char (point-min))
    (cond ((and selected
                (when-let* ((match (text-property-search-forward 'gdev-github-item selected t)))
                  (goto-char (prop-match-beginning match)))))
          (index (gdev-github-view--goto-index index)))
    (gdev-ui-restore-windows starts)
    (gdev-github-view--select)))

(defun gdev-github-view--starts ()
  "Posizioni d'inizio delle voci, nell'ordine della vista."
  (let ((position (point-min)) starts)
    (while (setq position (text-property-not-all position (point-max) 'gdev-github-item nil))
      (push position starts)
      (setq position (or (next-single-property-change position 'gdev-github-item) (point-max))))
    (nreverse starts)))

(defun gdev-github-view--item-start (&optional starts)
  "Inizio della voce al cursore, scelto fra STARTS, o nil fuori dalle voci."
  (when (get-text-property (point) 'gdev-github-item)
    (car (last (seq-filter (lambda (start) (<= start (point)))
                           (or starts (gdev-github-view--starts)))))))

(defun gdev-github-view--item-index ()
  "Posizione della voce al cursore fra le voci della vista."
  (let ((starts (gdev-github-view--starts)))
    (when-let* ((start (gdev-github-view--item-start starts)))
      (seq-position starts start))))

(defun gdev-github-view--goto-index (index)
  "Porta il cursore sulla voce INDEX o sull'ultima esistente."
  (when-let* ((starts (gdev-github-view--starts)))
    (goto-char (nth (min index (1- (length starts))) starts))))

(defun gdev-github-view--select ()
  "Evidenzia per intero la voce al cursore."
  (when (overlayp gdev-github-view--selection)
    (if-let* ((id (get-text-property (point) 'gdev-github-item)))
        (let ((start (if (and (> (point) (point-min))
                              (equal (get-text-property (1- (point)) 'gdev-github-item) id))
                         (previous-single-property-change (point) 'gdev-github-item nil (point-min))
                       (point)))
              (end (next-single-property-change (point) 'gdev-github-item nil (point-max))))
          (move-overlay gdev-github-view--selection start end))
      (delete-overlay gdev-github-view--selection))))

;;;; Voci

(defun gdev-github-view--current-item ()
  "Identità della voce selezionata, o errore se manca."
  (or (get-text-property (point) 'gdev-github-item)
      (user-error "Seleziona una voce della panoramica")))

(defun gdev-github-view--act (action)
  "Esegue ACTION sulla voce selezionata della sezione mostrata."
  (let ((id (gdev-github-view--current-item))
        (act (gdev-github-view--section gdev-github-view--current :act)))
    (funcall act gdev-github-view--root id action)))

(defun gdev-github-view-open ()
  "Apre la voce selezionata con la sua azione principale."
  (interactive)
  (gdev-github-view--act (gdev-github-view--section gdev-github-view--current :open)))

(defun gdev-github-view-actions ()
  "Sceglie un'azione per la voce selezionata."
  (interactive)
  (let* ((id (gdev-github-view--current-item))
         (section (gdev-github-view--section gdev-github-view--current))
         (label (format "%s · %s" (plist-get section :label)
                        (if (memq gdev-github-view--current '(pulls issues runs)) (concat "#" id) id))))
    (gdev-github-view--act (gdev-github--choose-action label (symbol-value (plist-get section :actions))))))

(defun gdev-github-view-browse ()
  "Apre nel navigatore la voce selezionata o, senza voce, l'archivio."
  (interactive)
  (if (and (get-text-property (point) 'gdev-github-item)
           (assq ?b (symbol-value (gdev-github-view--section gdev-github-view--current :actions))))
      (gdev-github-view--act ?b)
    (gdev-github--request gdev-github-view--root
                          (lambda (_text failure) (when failure (message "%s" failure)))
                          "repo" "view" "--web")))

(defun gdev-github-view-create ()
  "Crea una voce nella sezione mostrata."
  (interactive)
  (if-let* ((create (gdev-github-view--section gdev-github-view--current :create)))
      (call-interactively (nth 3 create))
    (user-error "In questa sezione non si creano voci")))

(defun gdev-github-view-next (&optional count)
  "Seleziona la voce successiva, o la COUNT-esima; negativa va indietro."
  (interactive "p")
  (let* ((count (or count 1))
         (starts (gdev-github-view--starts))
         (current (gdev-github-view--item-start starts))
         (index (cond (current (+ (seq-position starts current) count))
                      ((> count 0) (seq-position starts (seq-find (lambda (start) (> start (point))) starts)))
                      (t (seq-position starts (car (last (seq-filter (lambda (start) (< start (point))) starts))))))))
    (when (and index starts)
      (goto-char (nth (max 0 (min index (1- (length starts)))) starts))))
  (gdev-github-view--select))

(defun gdev-github-view-previous (&optional count)
  "Seleziona la voce precedente, o la COUNT-esima."
  (interactive "p")
  (gdev-github-view-next (- (or count 1))))

;;;; Sezioni e filtri

(defun gdev-github-view-show-section (key)
  "Mostra la sezione KEY e la aggiorna se i dati mancano o sono vecchi."
  (interactive
   (list (if (and (characterp last-command-event) (<= ?1 last-command-event ?5))
             (car (nth (- last-command-event ?1) gdev-github-view--sections))
           ;; Da M-x o da un menu la sezione si sceglie per nome.
           (let ((choices (mapcar (lambda (section) (cons (plist-get (cdr section) :label) (car section)))
                                  gdev-github-view--sections)))
             (cdr (assoc (completing-read "Sezione: " choices nil t) choices))))))
  (unless (assq key gdev-github-view--sections)
    (user-error "Sezione sconosciuta"))
  (unless (eq key gdev-github-view--current)
    (setq gdev-github-view--query nil))
  (setq gdev-github-view--current key)
  (unless (gdev-github-view--section key :filter) (setq gdev-github-view--all nil))
  (let ((entry (gdev-github-view--entry)))
    (if (and (plist-get entry :time)
             (equal (plist-get entry :key) (gdev-github-view--key))
             (< (float-time (time-since (plist-get entry :time))) 60))
        (gdev-github-view--render)
      (gdev-github-view--fetch))))

(defun gdev-github-view-next-section (&optional count)
  "Passa alla sezione successiva, o di COUNT posizioni."
  (interactive "p")
  (let* ((keys (mapcar #'car gdev-github-view--sections))
         (index (seq-position keys gdev-github-view--current)))
    (gdev-github-view-show-section (nth (mod (+ index (or count 1)) (length keys)) keys))))

(defun gdev-github-view-previous-section (&optional count)
  "Passa alla sezione precedente, o di COUNT posizioni."
  (interactive "p")
  (gdev-github-view-next-section (- (or count 1))))

(defun gdev-github-view-refresh ()
  "Chiede di nuovo a GitHub l'archivio e la sezione mostrata."
  (interactive)
  (gdev-github-view--fetch-repository)
  (gdev-github-view--fetch))

(defun gdev-github-view-toggle-filter ()
  "Alterna le voci aperte, o da leggere, e tutte le voci."
  (interactive)
  (unless (gdev-github-view--section gdev-github-view--current :filter)
    (user-error "Questa sezione non ha filtri"))
  (setq gdev-github-view--all (not gdev-github-view--all))
  (gdev-github-view--fetch))

(defun gdev-github-view-search (query)
  "Filtra richieste o segnalazioni con QUERY; vuota per toglierla."
  (interactive
   (progn
     (unless (gdev-github-view--section gdev-github-view--current :search)
       (user-error "La ricerca vale per richieste e segnalazioni"))
     (list (string-trim (read-string "Cerca su GitHub (vuoto per togliere): "
                                     gdev-github-view--query)))))
  (setq gdev-github-view--query (unless (string-empty-p query) query))
  (gdev-github-view--fetch))

(defun gdev-github-view--after-change (root)
  "Aggiorna le panoramiche di ROOT dopo una modifica fatta da GDev."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'gdev-github-view-mode)
                 (equal gdev-github-view--root root))
        ;; Le altre sezioni non restano «fresche» con i dati di prima della modifica.
        (dolist (section gdev-github-view--data)
          (unless (eq (car section) gdev-github-view--current)
            (setf (plist-get (cdr section) :time) nil)))
        (with-demoted-errors "HitHub: %S"
          (gdev-github-view--fetch))))))

;;;; Modalità

(defvar-keymap gdev-github-view-mode-map
  :parent special-mode-map
  "RET" #'gdev-github-view-open
  "a" #'gdev-github-view-actions
  "b" #'gdev-github-view-browse
  "c" #'gdev-github-view-create
  "f" #'gdev-github-view-toggle-filter
  "g" #'gdev-github-view-refresh
  "/" #'gdev-github-view-search
  "n" #'gdev-github-view-next
  "p" #'gdev-github-view-previous
  "<down>" #'gdev-github-view-next
  "<up>" #'gdev-github-view-previous
  "]" #'gdev-github-view-next-section
  "[" #'gdev-github-view-previous-section
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "1" #'gdev-github-view-show-section
  "2" #'gdev-github-view-show-section
  "3" #'gdev-github-view-show-section
  "4" #'gdev-github-view-show-section
  "5" #'gdev-github-view-show-section)

(define-derived-mode gdev-github-view-mode special-mode "HitHub"
  "Panoramica dell'archivio GitHub del progetto.
\\{gdev-github-view-mode-map}"
  (gdev-ui-view-setup 'document)
  (setq-local truncate-lines t
              gdev-github-view--selection (make-overlay (point-min) (point-min)))
  (overlay-put gdev-github-view--selection 'face 'gdev-ui-side-selection)
  (overlay-put gdev-github-view--selection 'priority -10)
  (gdev-layout-mark-document)
  (add-hook 'post-command-hook #'gdev-github-view--select nil t)
  (add-hook 'window-size-change-functions #'gdev-github-view--resize nil t)
  (add-hook 'window-buffer-change-functions #'gdev-github-view--resize nil t)
  (add-hook 'gdev-github-after-change-functions #'gdev-github-view--after-change))

(defun gdev-github-view--resize (window)
  "Ridisegna la vista di WINDOW quando cambia la larghezza disponibile."
  (with-current-buffer (window-buffer window)
    (unless (eql (or (gdev-ui-buffer-pixel-width) (* 100 (frame-char-width)))
                 gdev-github-view--drawn-width)
      (gdev-github-view--redraw))))

;;;###autoload
(defun gdev-github-overview (&optional root)
  "Apre la panoramica di HitHub dell'archivio in ROOT o del progetto."
  (interactive)
  (let* ((root (file-name-as-directory (expand-file-name (or root (gdev-project-root)))))
         (name (format "*HitHub · %s*" (abbreviate-file-name root)))
         (buffer (get-buffer name))
         (fresh (not buffer)))
    (unless fresh
      (with-current-buffer buffer
        (unless (derived-mode-p 'gdev-github-view-mode) (setq fresh t))))
    (when fresh
      (setq buffer (get-buffer-create name))
      (with-current-buffer buffer
        (gdev-github-view-mode)
        (setq default-directory root
              gdev-github-view--root root)))
    (unless (eq (window-buffer) buffer)
      (when-let* ((editor (and gdev-layout-mode (gdev-layout-editor))))
        (select-window editor)))
    (pop-to-buffer-same-window buffer)
    (if fresh
        (gdev-github-view-refresh)
      (gdev-github-view-show-section gdev-github-view--current))
    buffer))

;;;; Conversazione di una richiesta o di una segnalazione

(defvar-local gdev-github-topic--target nil
  "(RADICE TIPO NUMERO) della conversazione mostrata.")
(defvar-local gdev-github-topic--request nil "Richiesta più recente della conversazione.")
(defvar-local gdev-github-topic--data nil "Ultimi dati ricevuti, per ridisegnare senza chiederli.")

(defun gdev-github-topic--fields (kind)
  "Campi di gh per una conversazione di tipo KIND."
  (if (eq kind 'pull)
      (concat "number,title,state,isDraft,author,url,body,comments,labels,assignees,"
              "baseRefName,headRefName,reviews,reviewDecision,statusCheckRollup,"
              "additions,deletions,changedFiles,updatedAt")
    "number,title,state,stateReason,author,url,body,comments,labels,assignees,milestone,updatedAt"))

(defun gdev-github-topic--fetch ()
  "Chiede a GitHub la conversazione mostrata."
  (pcase-let* ((`(,root ,kind ,number) gdev-github-topic--target)
               (buffer (current-buffer))
               (request (make-symbol "richiesta-conversazione")))
    (setq gdev-github-topic--request request)
    (condition-case problem
        (gdev-github--request
         root
         (lambda (text failure)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (eq request gdev-github-topic--request)
                 (let ((data (unless failure (ignore-errors (gdev-github-view--parse text)))))
                   (setq gdev-github-topic--request nil
                         gdev-github-topic--data data)
                   (gdev-github-topic--render
                    data (or failure (unless data "GitHub ha restituito dati non leggibili"))))))))
         (if (eq kind 'pull) "pr" "issue") "view" number "--json" (gdev-github-topic--fields kind))
      ;; Senza gh o con una cartella non valida la vista mostra l'errore e «Riprova».
      (error
       (setq gdev-github-topic--request nil)
       (gdev-github-topic--render nil (error-message-string problem))))
    ;; Con dati già mostrati la lettura resta dov'è finché arriva la risposta.
    (when (and gdev-github-topic--request (not gdev-github-topic--data))
      (gdev-github-topic--render nil nil))))

(defun gdev-github-topic--insert-field (label value)
  "Inserisce la riga LABEL con VALUE allineato in colonna."
  (when (and value (not (equal value "")))
    (insert (propertize label 'face 'gdev-ui-secondary)
            (propertize " " 'display '(space :align-to (120)))
            value "\n")))

(defun gdev-github-topic--insert-entry (icon heading body)
  "Inserisce un intervento della conversazione con ICON, HEADING e BODY."
  (let ((prefix '(space :width (26))))
    (insert "\n" (gdev-ui-icon icon "•" nil 'gdev-ui-secondary) " " heading "\n")
    (insert (propertize (if (string-blank-p (or body "")) "Nessun testo." (gdev-github-view--text body))
                        'line-prefix prefix 'wrap-prefix prefix
                        'face (when (string-blank-p (or body "")) 'gdev-ui-secondary))
            "\n")))

(defun gdev-github-topic--actions (kind number)
  "Azioni in testa alla conversazione KIND NUMBER."
  (let ((act (lambda (action)
               (lambda () (gdev-github-topic--act action)))))
    (if (eq kind 'pull)
        (list (list "review" "◉" "Revisiona" (funcall act ?r) :primary t
                    :help "Approva, commenta o chiedi modifiche")
              (list "comment" "✎" "Commenta" (funcall act ?m))
              (list "git-diff" "±" "Differenze" (funcall act ?d))
              (list "check" "✓" "Controlli" (funcall act ?k))
              (list "git" "⑂" "Cambia ramo" (funcall act ?c)
                    :help (format "Scarica e apri il ramo della richiesta #%s" number))
              (list "git-merge" "⤵" "Unisci…" (funcall act ?u))
              (list "settings" "…" "Altre azioni…" #'gdev-github-topic-actions)
              (list "open" "↗" "Apri su GitHub" (funcall act ?b)))
      (list (list "comment" "✎" "Commenta" (funcall act ?c) :primary t)
            (list "git" "⑂" "Crea ramo" (funcall act ?r)
                  :help "Collega un ramo Git alla segnalazione e aprilo")
            (list "edit" "✎" "Modifica" (funcall act ?e))
            (list "settings" "…" "Altre azioni…" #'gdev-github-topic-actions)
            (list "open" "↗" "Apri su GitHub" (funcall act ?b))))))

(defun gdev-github-topic--render (data failure)
  "Ridisegna la conversazione con DATA, o con lo stato di FAILURE."
  (pcase-let* ((`(,_root ,kind ,number) gdev-github-topic--target)
               (inhibit-read-only t)
               (position (point))
               (starts (gdev-ui-window-starts))
               (width (gdev-github-view--width)))
    (erase-buffer)
    (cond
     (failure
      (gdev-github-view--insert-state "status-failure" 'gdev-ui-status-error
                                      "GitHub non ha risposto" failure
                                      (list "refresh" "↻" "Riprova" #'gdev-github-topic-refresh :primary t)))
     ((null data)
      (insert (propertize (format "%s #%s" (if (eq kind 'pull) "Richiesta" "Segnalazione") number)
                          'face 'gdev-ui-view-title)
              "\n")
      (gdev-github-view--insert-state "status-pending" 'gdev-ui-secondary "Caricamento da GitHub…" nil))
     (t
      (let* ((item (if (eq kind 'pull) (gdev-github-view--pull data) (gdev-github-view--issue data)))
             (look (plist-get item :look))
             (labels (mapcar (lambda (label) (alist-get 'name label)) (alist-get 'labels data)))
             (assignees (mapcar (lambda (person) (concat "@" (alist-get 'login person)))
                                (alist-get 'assignees data)))
             (entries
              (sort (append
                     (mapcar (lambda (comment)
                               (list (alist-get 'createdAt comment) "comment"
                                     (concat (propertize (gdev-github-view--login comment) 'face 'gdev-ui-view-heading)
                                             (propertize (concat " · " (or (gdev-github-view--age (alist-get 'createdAt comment)) ""))
                                                         'face 'gdev-ui-secondary))
                                     (alist-get 'body comment)))
                             (alist-get 'comments data))
                     (mapcar (lambda (review)
                               (let ((verdict (pcase (alist-get 'state review)
                                                ("APPROVED" '(gdev-ui-status-success "ha approvato"))
                                                ("CHANGES_REQUESTED" '(gdev-ui-status-warning "chiede modifiche"))
                                                ("DISMISSED" '(gdev-ui-secondary "revisione revocata"))
                                                (_ '(gdev-ui-secondary "ha commentato")))))
                                 (list (alist-get 'submittedAt review) "review"
                                       (concat (propertize (gdev-github-view--login review) 'face 'gdev-ui-view-heading)
                                               " " (propertize (cadr verdict) 'face (car verdict))
                                               (propertize (concat " · " (or (gdev-github-view--age (alist-get 'submittedAt review)) ""))
                                                           'face 'gdev-ui-secondary))
                                       (alist-get 'body review))))
                             (alist-get 'reviews data)))
                    (lambda (a b) (string< (or (car a) "") (or (car b) ""))))))
        (insert (gdev-ui-icon (nth 0 look) "•" nil (nth 1 look)) " "
                (propertize (or (alist-get 'title data) "") 'face 'gdev-ui-view-title
                            'wrap-prefix '(space :width (30)))
                "\n"
                (propertize (nth 2 look) 'face (nth 1 look))
                (propertize (format " · #%s · %s · aggiornata %s"
                                    number (gdev-github-view--login data)
                                    (or (gdev-github-view--age (alist-get 'updatedAt data)) ""))
                            'face 'gdev-ui-secondary)
                "\n\n")
        (gdev-ui-insert-actions (gdev-github-topic--actions kind number) width)
        (insert "\n")
        (when (eq kind 'pull)
          (gdev-github-topic--insert-field
           "Rami" (format "%s → %s" (alist-get 'headRefName data) (alist-get 'baseRefName data)))
          (gdev-github-topic--insert-field
           "Controlli" (when-let* ((checks (gdev-github-view--checks (alist-get 'statusCheckRollup data))))
                         (apply #'gdev-ui-badge (car checks) "•" (cdr checks))))
          (gdev-github-topic--insert-field
           "Revisione" (when-let* ((review (gdev-github-view--review (alist-get 'reviewDecision data))))
                         (apply #'gdev-ui-badge (car review) "•" (cdr review))))
          (gdev-github-topic--insert-field
           "Modifiche" (when (alist-get 'changedFiles data)
                         (concat (propertize (format "+%d" (alist-get 'additions data)) 'face 'gdev-ui-status-success)
                                 " "
                                 (propertize (format "−%d" (alist-get 'deletions data)) 'face 'gdev-ui-status-error)
                                 (format " · %d file" (alist-get 'changedFiles data))))))
        (gdev-github-topic--insert-field "Etichette" (string-join labels ", "))
        (gdev-github-topic--insert-field "Responsabili" (string-join assignees ", "))
        (gdev-github-topic--insert-field "Traguardo" (alist-get 'title (alist-get 'milestone data)))
        (insert "\n" (propertize "Descrizione" 'face 'gdev-ui-view-heading) "\n")
        (let ((body (alist-get 'body data)))
          (insert (if (string-blank-p (or body ""))
                      (propertize "Nessuna descrizione." 'face 'gdev-ui-secondary)
                    (gdev-github-view--text body))
                  "\n"))
        (when entries
          (insert "\n" (propertize (format "Conversazione · %d" (length entries)) 'face 'gdev-ui-view-heading)
                  "\n")
          (dolist (entry entries)
            (gdev-github-topic--insert-entry (nth 1 entry) (nth 2 entry) (nth 3 entry)))))))
    (goto-char (min position (point-max)))
    (gdev-ui-restore-windows starts)))

(defun gdev-github-topic--act (action)
  "Esegue ACTION sulla conversazione mostrata."
  (pcase-let ((`(,root ,kind ,number) gdev-github-topic--target))
    (if (eq kind 'pull)
        (gdev-github--pull-request-act root number action)
      (gdev-github--issue-act root number action))))

(defun gdev-github-topic-actions ()
  "Sceglie un'azione per la conversazione mostrata."
  (interactive)
  (pcase-let ((`(,_root ,kind ,number) gdev-github-topic--target))
    (gdev-github-topic--act
     (gdev-github--choose-action
      (format "%s #%s" (if (eq kind 'pull) "Richiesta" "Segnalazione") number)
      (remq (assq ?i (if (eq kind 'pull) gdev-github--pull-request-actions gdev-github--issue-actions))
            (if (eq kind 'pull) gdev-github--pull-request-actions gdev-github--issue-actions))))))

(defun gdev-github-topic-refresh ()
  "Chiede di nuovo a GitHub la conversazione mostrata."
  (interactive)
  (gdev-github-topic--fetch))

(defun gdev-github-topic--after-change (root)
  "Aggiorna le conversazioni di ROOT dopo una modifica fatta da GDev."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'gdev-github-topic-mode)
                 (equal (car gdev-github-topic--target) root))
        ;; Un errore in una vista non deve fermare le altre né il comando che ha modificato.
        (with-demoted-errors "HitHub: %S"
          (gdev-github-topic--fetch))))))

(defun gdev-github-view--redraw ()
  "Ridisegna la vista corrente dai dati già ricevuti, senza chiederli a GitHub."
  (cond ((derived-mode-p 'gdev-github-view-mode) (gdev-github-view--render))
        ((and (derived-mode-p 'gdev-github-topic-mode) gdev-github-topic--data)
         (gdev-github-topic--render gdev-github-topic--data nil))))

(defun gdev-github-view--redraw-all ()
  "Ridisegna panoramiche e conversazioni, per esempio dopo un cambio di tema."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (with-demoted-errors "HitHub: %S"
        (gdev-github-view--redraw)))))

(add-hook 'gdev-ui-after-theme-hook #'gdev-github-view--redraw-all)

(defvar-keymap gdev-github-topic-mode-map
  :parent special-mode-map
  "a" #'gdev-github-topic-actions
  "g" #'gdev-github-topic-refresh
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-github-topic-mode special-mode "HitHub"
  "Conversazione di una richiesta o di una segnalazione di GitHub.
\\{gdev-github-topic-mode-map}"
  (gdev-ui-view-setup 'document)
  (visual-line-mode 1)
  (gdev-layout-mark-document)
  (add-hook 'window-size-change-functions #'gdev-github-view--resize nil t)
  (add-hook 'window-buffer-change-functions #'gdev-github-view--resize nil t)
  (add-hook 'gdev-github-after-change-functions #'gdev-github-topic--after-change))

(defun gdev-github-topic (root kind number)
  "Apre la conversazione KIND (`pull' o `issue') NUMBER dell'archivio in ROOT."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (number (format "%s" number))
         (name (format "*HitHub · %s #%s · %s*" (if (eq kind 'pull) "Richiesta" "Segnalazione")
                       number (abbreviate-file-name root)))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-github-topic-mode)
        (gdev-github-topic-mode))
      (setq default-directory root
            gdev-github-topic--target (list root kind number)))
    (if (and gdev-layout-mode (derived-mode-p 'gdev-github-view-mode))
        (pop-to-buffer-same-window buffer)
      (when-let* ((editor (and gdev-layout-mode (gdev-layout-editor))))
        (select-window editor))
      (pop-to-buffer-same-window buffer))
    (gdev-github-topic--fetch)
    buffer))

(provide 'gdev-hithub-view)
;;; gdev-hithub-view.el ends here
