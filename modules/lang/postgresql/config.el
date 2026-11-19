;;; config.el --- :lang sql: Database SQL, interrogazioni e console -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I file .sql seguono il motore della connessione. I file .pgsql e .psql
;; usano PostgreSQL. C-c l c sceglie la connessione e apre la console.
;; C-c o r torna alla console associata al documento.
;; C-c o b e C-c l b aprono Database SQL: schemi, tabelle, colonne e dati.
;; C-c l e (o C-c c e) esegue il testo selezionato. Nei file PostgreSQL
;; dedicati invia il testo alla console. C-c l t elenca le tabelle.
;; C-c l a esegue il file salvato in un processo separato, con arresto
;; al primo errore.  C-c c f formatta con pg_format, quando installato.
;;
;; Definisci i servizi in ~/.pg_service.conf e inserisci i loro nomi
;; in gdev-postgresql-services.  Usa .pgpass per le credenziali.
;; La console è condivisa fra documenti della stessa cartella di progetto
;; che scelgono lo stesso servizio.  Aprire un file è un'azione di modifica
;; del testo e non avvia alcuna connessione.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function comint-send-string "comint" (process string))
(declare-function make-comint-in-buffer "comint" (name buffer program &optional startfile &rest switches))
(declare-function gdev-format-with-program "../../editor/format/config")
(declare-function gdev-compilation-check-idle "gdev-compilation" (name))
(declare-function sql-set-product "sql" (product))
(declare-function sql-interactive-mode "sql" ())
(defvar compilation-environment)
(defvar comint-prompt-regexp)
(defvar gdev-context-items)
(defvar sql-buffer)
(defvar sql-interactive-product)
(defvar sql-prompt-regexp)
(defvar sql-prompt-cont-regexp)
(defvar sql-postgres-program)

(autoload 'gdev-postgresql-browse
  (gdev-config-file "modules/lang/postgresql/gdev-postgresql-browser") nil t)
(autoload 'gdev-postgresql-browser-display
  (gdev-config-file "modules/lang/postgresql/gdev-postgresql-browser"))
(autoload 'gdev-database-browser-display
  (gdev-config-file "modules/lang/postgresql/gdev-database-browser"))
(autoload 'gdev-database-sqlite-choose
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))
(autoload 'gdev-database-sqlite-label
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))
(autoload 'gdev-database-sqlite-client
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))
(autoload 'gdev-database-sqlite-request
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))
(autoload 'gdev-database-sqlite-run
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))
(autoload 'gdev-database-sqlite-run-file
  (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite"))

(defgroup gdev-postgresql nil
  "Sviluppo con PostgreSQL."
  :group 'gdev)

(defcustom gdev-postgresql-services nil
  "Nomi dei servizi PostgreSQL disponibili in ~/.pg_service.conf.
Ogni nome identifica solo una configurazione di libpq."
  :type '(repeat string))

(defvar-local gdev-postgresql--connection nil
  "Coppia (radice . servizio) scelta per questo documento o console.")

(defvar-local gdev-postgresql--sent-at nil
  "Posizione dell'ultimo invio dalla finestra dell'editor.")

(defconst gdev-postgresql--prompt "^PostgreSQL .*=[#>] "
  "Espressione che riconosce una console pronta per una nuova istruzione.")

(define-derived-mode gdev-postgresql-console-mode sql-interactive-mode "Console PostgreSQL"
  "Console interattiva di PostgreSQL nel pannello degli strumenti."
  (gdev-ui-view-setup 'native)
  (setq-local sql-prompt-regexp gdev-postgresql--prompt
              sql-prompt-cont-regexp "^SQL … .* "
              comint-prompt-regexp (concat gdev-postgresql--prompt "\\|^SQL … .* ")
              sql-buffer (current-buffer)
              gdev-context-items
              '(["Database SQL…" gdev-postgresql-browse])))

(defun gdev-postgresql--choose ()
  "Scegli il servizio libpq per il progetto del documento corrente."
  (let* ((environment "Connessione predefinita")
         (profiles (cons environment gdev-postgresql-services))
         (choice (completing-read "Connessione PostgreSQL: " profiles nil t nil nil environment)))
    (cons (gdev-project-root)
          (if (equal choice environment) (getenv "PGSERVICE") choice))))

(defun gdev-postgresql--client ()
  "Restituisci l'eseguibile psql configurato per l'ambiente corrente."
  (require 'sql)
  (or (executable-find sql-postgres-program (file-remote-p default-directory))
      (user-error "psql non disponibile nell’ambiente corrente")))

(defun gdev-postgresql--label (connection)
  "Restituisci il titolo breve di CONNECTION per il pannello."
  (format "%s · %s"
          (file-name-nondirectory (directory-file-name (car connection)))
          (or (cdr connection) "connessione predefinita")))

(defun gdev-postgresql--find-console (connection)
  "Trova la console ancora in esecuzione per CONNECTION."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'gdev-postgresql-console-mode)
                     (equal connection gdev-postgresql--connection)
                     (when-let* ((process (get-buffer-process buffer)))
                       (process-live-p process)))))
            (buffer-list)))

(defun gdev-postgresql--open (connection)
  "Apri o riutilizza la console di CONNECTION e associa il documento."
  (let ((console
         (or (gdev-postgresql--find-console connection)
             (let* ((default-directory (car connection))
                    (program (gdev-postgresql--client))
                    (process-environment (copy-sequence process-environment))
                    (buffer (generate-new-buffer
                             (format "*PostgreSQL · %s*" (gdev-postgresql--label connection))))
                    ready)
               (unwind-protect
                   (progn
                     (setenv "PGSERVICE" (cdr connection))
                     (with-current-buffer buffer
                       (setq default-directory (car connection)))
                     (make-comint-in-buffer "postgresql" buffer (file-local-name program) nil
                                            "--no-psqlrc" "--pset=pager=off"
                                            "--set=PROMPT1=PostgreSQL %/%x%R%# "
                                            "--set=PROMPT2=SQL … %R%# ")
                     (with-current-buffer buffer
                       (let ((sql-interactive-product 'postgres))
                         (gdev-postgresql-console-mode))
                       (setq-local gdev-postgresql--connection connection))
                     (setq ready t)
                     buffer)
                 (unless ready (kill-buffer buffer)))))))
    (setq gdev-postgresql--connection connection)
    console))

(defun gdev-postgresql-console ()
  "Restituisci la console associata al documento o chiedi un servizio."
  (gdev-postgresql--open (or gdev-postgresql--connection (gdev-postgresql--choose))))

(defun gdev-postgresql-connect ()
  "Scegli una connessione PostgreSQL e mostra la sua console."
  (interactive)
  (pop-to-buffer (gdev-postgresql--open (gdev-postgresql--choose))))

(defun gdev-postgresql-show-console ()
  "Mostra la console PostgreSQL associata al documento."
  (interactive)
  (pop-to-buffer (gdev-postgresql-console)))

(defun gdev-postgresql--send (text)
  "Invia TEXT quando la console del documento è pronta per un comando."
  (let* ((console (gdev-postgresql--find-console gdev-postgresql--connection))
         (process (and console (get-buffer-process console))))
    (unless process
      (user-error "Apri prima la console PostgreSQL con C-c l c"))
    (with-current-buffer console
      (save-excursion
        (goto-char (process-mark process))
        (unless (and (eobp)
                     (not (equal (point) (and gdev-postgresql--sent-at
                                              (marker-position gdev-postgresql--sent-at))))
                     (let ((inhibit-field-text-motion t))
                       (beginning-of-line)
                       (looking-at-p (concat gdev-postgresql--prompt "\\'"))))
          (user-error "La console PostgreSQL ha un comando in corso o del testo da completare"))
        (comint-send-string process (concat text "\n"))
        (setq gdev-postgresql--sent-at (copy-marker (process-mark process)))))
    (display-buffer console)))

(defun gdev-postgresql-send-region (beg end)
  "Invia il testo selezionato tra BEG ed END alla console del documento."
  (interactive "r")
  (unless (and (use-region-p) (< beg end))
    (user-error "Seleziona le istruzioni SQL da eseguire"))
  (gdev-postgresql--send (buffer-substring-no-properties beg end)))

(defun gdev-postgresql-list-tables ()
  "Elenca le tabelle visibili nella connessione PostgreSQL corrente."
  (interactive)
  (gdev-postgresql--send "\\dt"))

(defun gdev-postgresql-run-file (&optional choose)
  "Esegui il file SQL in un processo separato.
Con CHOOSE, chiedi di scegliere di nuovo il servizio."
  (interactive "P")
  (require 'compile)
  (let* ((file (or buffer-file-name (user-error "Salva il documento SQL prima di eseguirlo")))
         (program (gdev-postgresql--client))
         (connection (if choose (gdev-postgresql--choose)
                       (or gdev-postgresql--connection (gdev-postgresql--choose))))
         (compilation-environment
          (cons (if-let* ((service (cdr connection))) (concat "PGSERVICE=" service) "PGSERVICE")
                compilation-environment)))
    (save-buffer)
    (prog1
        (gdev-compile
         (gdev-command-line (file-local-name program) "--no-psqlrc" "--no-password"
                            "--set=ON_ERROR_STOP=1" "--file" (file-local-name file))
         (format "Esecuzione · PostgreSQL · %s · %s" (gdev-postgresql--label connection)
                 (file-name-nondirectory file))
         (file-name-directory file))
      (setq gdev-postgresql--connection connection))))

(defun gdev-postgresql-format ()
  "Formatta il documento SQL con pg_format."
  (interactive)
  (unless (executable-find "pg_format")
    (user-error "Installa pg_format con brew install pgformatter"))
  (if (fboundp 'gdev-format-with-program)
      (gdev-format-with-program "pg_format" "-")
    (user-error "Attiva il modulo di formattazione :editor format")))

(defun gdev-postgresql-docs ()
  "Apri il manuale ufficiale di PostgreSQL nel navigatore."
  (interactive)
  (browse-url "https://www.postgresql.org/docs/current/"))

(define-derived-mode gdev-postgresql-mode sql-mode "PostgreSQL"
  "Modifica script SQL nel dialetto PostgreSQL."
  (gdev-ui-view-setup 'native)
  (sql-set-product 'postgres)
  (setq-local sql-buffer nil
              gdev-context-items
              '(["Scegli connessione…" gdev-postgresql-connect]
                ["Apri console PostgreSQL" gdev-postgresql-show-console]
                ["Database SQL…" gdev-postgresql-browse]
                ["Esegui selezione SQL" gdev-postgresql-send-region (use-region-p)
                 (:target selection)]
                ["Esegui file SQL" gdev-postgresql-run-file buffer-file-name]
                ["Elenca tabelle" gdev-postgresql-list-tables])))

;;;; Connessioni e comandi condivisi

(defvar-local gdev-database--sqlite-connection nil
  "Connessione SQLite associata al documento o alla console corrente.")

(defun gdev-database--connection ()
  "Restituisci la connessione del documento o della console, con il motore."
  (cond (gdev-database--sqlite-connection (cons 'sqlite gdev-database--sqlite-connection))
        (gdev-postgresql--connection (cons 'postgresql gdev-postgresql--connection))))

(defun gdev-database--choose (&optional engine)
  "Scegli una connessione per ENGINE, o chiedi anche il motore."
  (let* ((frame (selected-frame))
         (origin (gdev-workspace-state-ensure-id frame))
         (source (current-buffer))
         (choices '(("PostgreSQL" . postgresql) ("SQLite" . sqlite)))
         (engine (or engine (cdr (assoc (completing-read "Motore SQL: " choices nil t
                                                         nil nil "PostgreSQL")
                                        choices))))
         (connection (pcase engine
                       ('postgresql (gdev-postgresql--choose))
                       ('sqlite (gdev-database-sqlite-choose)))))
    (unless (and connection (eq frame (selected-frame)) (buffer-live-p source)
                 (eq source (current-buffer))
                 (eq origin (gdev-workspace-state-id frame)))
      (user-error "Il contesto è cambiato. Scegli di nuovo la connessione"))
    (cons engine connection)))

(defun gdev-database--associate (target)
  "Associa TARGET al documento corrente e applica il dialetto."
  (when (derived-mode-p 'gdev-database-mode)
    (let ((sqlite (eq (car target) 'sqlite)))
      (setq gdev-database--sqlite-connection (and sqlite (cdr target))
            gdev-postgresql--connection (and (not sqlite) (cdr target)))
      (sql-set-product (if sqlite 'sqlite 'postgres)))))

(defun gdev-database-browse (&optional choose)
  "Mostra Database SQL. Con CHOOSE, scegli motore e connessione."
  (interactive "P")
  (if (and (not choose) (derived-mode-p 'gdev-database-browser-mode))
      (current-buffer)
    (pcase-let* ((`(,engine . ,connection)
                  (or (and (not choose) (gdev-database--connection))
                      (gdev-database--choose
                       (and (not choose)
                            (or (derived-mode-p 'gdev-postgresql-console-mode)
                                (and (derived-mode-p 'gdev-postgresql-mode)
                                     (not (derived-mode-p 'gdev-database-mode))))
                            'postgresql)))))
      (pcase engine
        ('postgresql (gdev-postgresql-browser-display connection))
        ('sqlite
         (gdev-database-browser-display
          engine connection (gdev-database-sqlite-label connection) (car connection)
          #'gdev-database-sqlite-request))))))

(define-derived-mode gdev-database-sqlite-console-mode sql-interactive-mode "Console SQLite"
  "Usa l'interprete SQLite nel pannello degli strumenti."
  (gdev-ui-view-setup 'native)
  (setq-local sql-buffer (current-buffer)
              gdev-context-items '(["Database SQL…" gdev-database-browse])))

(defun gdev-database--sqlite-console (connection)
  "Apri o riutilizza la console SQLite di CONNECTION."
  (or (seq-find (lambda (buffer)
                  (with-current-buffer buffer
                    (and (derived-mode-p 'gdev-database-sqlite-console-mode)
                         (equal connection gdev-database--sqlite-connection)
                         (process-live-p (get-buffer-process buffer)))))
                (buffer-list))
      (let* ((default-directory (car connection))
             (database (cdr connection))
             (client (gdev-database-sqlite-client))
             (buffer (generate-new-buffer
                      (format "*Console SQLite · %s*" (gdev-database-sqlite-label connection))))
             ready)
        (unwind-protect
            (progn
              (unless (and (not (file-remote-p database)) (file-regular-p database))
                (user-error "Scegli un file di database SQLite locale esistente"))
              (make-comint-in-buffer "sqlite" buffer client nil
                                     "-init" null-device "-interactive" "-header" "-column" database)
              (with-current-buffer buffer
                (let ((sql-interactive-product 'sqlite))
                  (gdev-database-sqlite-console-mode))
                (setq gdev-database--sqlite-connection connection
                      ready t))
              buffer)
          (unless ready (kill-buffer buffer))))))

(defun gdev-database--open-console (target)
  "Apri la console di TARGET e applica la connessione al sorgente."
  (let ((console (pcase (car target)
                   ('postgresql (gdev-postgresql--open (cdr target)))
                   ('sqlite (gdev-database--sqlite-console (cdr target))))))
    (gdev-database--associate target)
    console))

(defun gdev-database-connect ()
  "Scegli il motore e la connessione del documento."
  (interactive)
  (pop-to-buffer (gdev-database--open-console (gdev-database--choose))))

(defun gdev-database-console ()
  "Restituisci la console della connessione del documento."
  (gdev-database--open-console (or (gdev-database--connection) (gdev-database--choose))))

(defun gdev-database-show-console ()
  "Porta il fuoco alla console del documento."
  (interactive)
  (pop-to-buffer (gdev-database-console)))

(defun gdev-database-list-tables ()
  "Mostra le tabelle della connessione del documento."
  (interactive)
  (gdev-database-browse))

(defun gdev-database--postgres-selection (connection text label)
  "Esegui TEXT sulla CONNECTION in un pannello con LABEL."
  (require 'compile)
  (require 'gdev-compilation)
  (gdev-compilation-check-idle label)
  (let* ((program (gdev-postgresql--client))
         (compilation-environment
          (cons (if-let* ((service (cdr connection))) (concat "PGSERVICE=" service) "PGSERVICE")
                compilation-environment))
         (process-connection-type nil)
         (buffer (gdev-compile (gdev-command-line (file-local-name program)
                                                 "--no-psqlrc" "--no-password"
                                                 "--set=ON_ERROR_STOP=1" "--file=-")
                               label default-directory))
         (process (get-buffer-process buffer)))
    (unless (process-live-p process) (user-error "Esecuzione PostgreSQL non avviata"))
    (process-send-string process (concat text "\n"))
    (when (process-live-p process) (process-send-eof process))
    buffer))

(defun gdev-database-send-region (beg end)
  "Esegui la selezione tra BEG ed END sulla connessione del documento."
  (interactive "r")
  (unless (and (use-region-p) (< beg end))
    (user-error "Seleziona le istruzioni SQL da eseguire"))
  (let* ((source (current-buffer))
         (revision (buffer-chars-modified-tick))
         (target (or (gdev-database--connection) (gdev-database--choose)))
         (connection (cdr target)))
    (unless (= revision (buffer-chars-modified-tick))
      (user-error "Il sorgente è cambiato. Seleziona di nuovo le istruzioni"))
    (let* ((text (buffer-substring-no-properties beg end))
           (buffer
            (pcase (car target)
              ('postgresql
               (gdev-database--postgres-selection
                connection text (concat "Selezione SQL · " (gdev-postgresql--label connection))))
              ('sqlite
               (gdev-database-sqlite-run connection text default-directory
                                         (concat "Selezione SQL · "
                                                 (abbreviate-file-name (cdr connection))))))))
      (with-current-buffer source (gdev-database--associate target))
      buffer)))

(defun gdev-database-run-file (&optional choose)
  "Salva ed esegui il documento SQL. Con CHOOSE, cambia connessione."
  (interactive "P")
  (let* ((source (current-buffer))
         (file (or buffer-file-name (user-error "Salva il documento SQL prima di eseguirlo")))
         (target (or (and (not choose) (gdev-database--connection))
                     (gdev-database--choose)))
         (connection (cdr target)))
    (unless (equal file buffer-file-name)
      (user-error "Il documento SQL è cambiato. Ripeti l’esecuzione"))
    (let ((buffer
          (pcase (car target)
            ('postgresql
             (let ((gdev-postgresql--connection connection))
               (gdev-postgresql-run-file)))
            ('sqlite
             (when (file-remote-p file) (user-error "Scegli uno script SQL locale per SQLite"))
             (save-buffer)
             (gdev-database-sqlite-run-file
              connection file
              (file-name-directory file)
              (format "Esecuzione · %s · %s" (abbreviate-file-name (cdr connection))
                      (file-name-nondirectory file)))))))
      (with-current-buffer source (gdev-database--associate target))
      buffer)))

(defun gdev-database-format ()
  "Formatta il documento quando il dialetto ha un formattatore."
  (interactive)
  (if gdev-database--sqlite-connection
      (user-error "Nessun formattatore SQLite configurato")
    (gdev-postgresql-format)))

(defun gdev-database-docs ()
  "Apri la guida del motore associato al documento."
  (interactive)
  (if gdev-database--sqlite-connection
      (browse-url "https://www.sqlite.org/lang.html")
    (gdev-postgresql-docs)))

(define-derived-mode gdev-database-mode gdev-postgresql-mode "SQL"
  "Modifica script nel dialetto della connessione selezionata."
  (gdev-ui-view-setup 'native)
  (setq-local gdev-context-items
              '(["Scegli connessione…" gdev-database-connect]
                ["Apri console SQL" gdev-database-show-console]
                ["Database SQL…" gdev-database-browse]
                ["Esegui selezione SQL" gdev-database-send-region (use-region-p)
                 (:target selection)]
                ["Esegui file SQL" gdev-database-run-file buffer-file-name]
                ["Elenca tabelle" gdev-database-list-tables])))

(add-to-list 'auto-mode-alist '("\\.\\(?:pgsql\\|psql\\)\\'" . gdev-postgresql-mode))
(add-to-list 'auto-mode-alist '("\\.sql\\'" . gdev-database-mode))
(keymap-set gdev-postgresql-mode-map "C-c C-r" #'gdev-postgresql-send-region)
(keymap-set gdev-postgresql-mode-map "C-c C-b" #'gdev-postgresql-run-file)
(keymap-set gdev-postgresql-mode-map "C-c C-i" #'gdev-postgresql-connect)
(keymap-set gdev-postgresql-mode-map "C-c C-z" #'gdev-postgresql-show-console)
(gdev-bind gdev-open-map "b" "database SQL" #'gdev-database-browse)
(gdev-set-tool-actions 'postgresql "Database SQL" "buffer"
  ["Apri Database SQL…" gdev-database-browse :key-sequence "C-c o b"]
  ["Scegli connessione…" gdev-database-connect :visible (derived-mode-p 'gdev-database-mode)]
  ["Scegli servizio PostgreSQL…" gdev-postgresql-connect
   :visible (and (derived-mode-p 'gdev-postgresql-mode) (not (derived-mode-p 'gdev-database-mode)))])
(gdev-bind (gdev-localleader-map gdev-postgresql-console-mode-map)
  "b" "database SQL per PostgreSQL" #'gdev-postgresql-browse)
(gdev-bind (gdev-localleader-map gdev-postgresql-mode-map)
  "b" "database SQL per PostgreSQL" #'gdev-postgresql-browse
  "c" "scegli connessione PostgreSQL" #'gdev-postgresql-connect
  "e" "esegui selezione SQL" #'gdev-postgresql-send-region
  "a" "esegui file SQL" #'gdev-postgresql-run-file
  "t" "elenca tabelle" #'gdev-postgresql-list-tables
  "k" "manuale di PostgreSQL" #'gdev-postgresql-docs)
(gdev-set-popup-rule "\\`\\*PostgreSQL · ")
(gdev-set-repl 'gdev-postgresql-mode #'gdev-postgresql-console)
(gdev-set-popup-rule (rx bos "*Esplora PostgreSQL · "))
(gdev-set-eval 'gdev-postgresql-mode #'gdev-postgresql-send-region)
(gdev-set-runner 'gdev-postgresql-mode :run #'gdev-postgresql-run-file)
(gdev-set-formatter 'gdev-postgresql-mode #'gdev-postgresql-format)
(gdev-set-documentation 'gdev-postgresql-mode #'gdev-postgresql-docs)
(keymap-set gdev-database-mode-map "C-c C-r" #'gdev-database-send-region)
(keymap-set gdev-database-mode-map "C-c C-b" #'gdev-database-run-file)
(keymap-set gdev-database-mode-map "C-c C-i" #'gdev-database-connect)
(keymap-set gdev-database-mode-map "C-c C-z" #'gdev-database-show-console)
(gdev-bind (gdev-localleader-map gdev-database-mode-map)
  "b" "database SQL" #'gdev-database-browse
  "c" "scegli motore e connessione" #'gdev-database-connect
  "e" "esegui selezione SQL" #'gdev-database-send-region
  "a" "esegui file SQL" #'gdev-database-run-file
  "t" "elenca tabelle" #'gdev-database-list-tables
  "k" "manuale del motore" #'gdev-database-docs)
(gdev-bind (gdev-localleader-map gdev-database-sqlite-console-mode-map)
  "b" "database SQL" #'gdev-database-browse)
(gdev-set-popup-rule '(derived-mode . gdev-database-sqlite-console-mode))
(gdev-set-repl 'gdev-database-mode #'gdev-database-console)
(gdev-set-eval 'gdev-database-mode #'gdev-database-send-region)
(gdev-set-runner 'gdev-database-mode :run #'gdev-database-run-file)
(gdev-set-formatter 'gdev-database-mode #'gdev-database-format)
(gdev-set-documentation 'gdev-database-mode #'gdev-database-docs)
(gdev-doctor-check "Client Database SQL"
                   (lambda ()
                     (or (executable-find "sqlite3")
                         (ignore-errors (gdev-postgresql--client))))
                   "Installa almeno un client SQL: sqlite3 o psql")
(gdev-doctor-check "psql" (lambda () (ignore-errors (gdev-postgresql--client)))
                   "Installa il client PostgreSQL, per esempio con brew install libpq" 'note)
(gdev-doctor-executable "pg_format" "brew install pgformatter" 'note)
(gdev-doctor-executable "sqlite3" "Installa il client SQLite, per esempio con brew install sqlite" 'note)

;;; config.el ends here
