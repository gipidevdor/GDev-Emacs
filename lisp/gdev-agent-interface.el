;;; gdev-agent-interface.el --- Interfaccia locale per agenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il CLI legge l'inventario dai sorgenti correnti. Le azioni dal vivo
;; usano il server Emacs locale già esistente, con una lista di operazioni
;; e argomenti espliciti. Questa libreria non apre socket.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'lisp-mode)

(defvar gdev-config-directory)

(defconst gdev-agent-interface--root
  (or (bound-and-true-p gdev-config-directory)
      (file-name-directory
       (directory-file-name (file-name-directory (file-truename load-file-name))))))

(defconst gdev-agent-interface--schema-version 1)

(defvar gdev-modules)
(defvar gdev-active-profile)
(defvar server-name)
(defvar server-socket-dir)
(defvar server-process)
(defvar server-use-tcp)
(declare-function gdev-layout-editor "gdev-layout" (&optional frame))
(declare-function gdev-workspace-roots "gdev-workspace-roots" (&optional frame))
(declare-function gdev-workspace-state-get "gdev-workspace-state" (field &optional frame))
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-open-folder "gdev-commands" (directory))
(declare-function gdev-menu-command-items "gdev-menu" (&optional include-disabled))
(declare-function gdev-menu-key-label "gdev-menu" (sequence))
(declare-function gdev-agent-cursors-request "gdev-agent-cursors" (action &rest args))
(declare-function gdev-lavorazione-agent-richiesta "gdev-lavorazione-agent" (action &rest arguments))
(declare-function gdev-agent-control-request "gdev-agent-control" (action &rest arguments))
(defvar gdev-layout-mode)

(defun gdev-agent-interface--read (file visit &optional needle)
  "Passa a VISIT le forme al livello superiore di FILE con le loro righe.
Con NEEDLE, salta i file in cui la stringa è assente."
  (with-temp-buffer
    (insert-file-contents file)
    (when (or (not needle) (save-excursion (search-forward needle nil t)))
      (let ((read-circle nil))
        (with-syntax-table emacs-lisp-mode-syntax-table
          (while (progn (forward-comment (point-max)) (not (eobp)))
            (let ((line (line-number-at-pos)))
              (funcall visit (read (current-buffer)) line))))))))

(defun gdev-agent-interface--checkout-commands ()
  "Leggi i comandi dalla tabella di smistamento della versione corrente."
  (let (commands)
    (gdev-agent-interface--read
     (expand-file-name "lisp/gdev-cli.el" gdev-agent-interface--root)
     (lambda (form _line)
       (pcase form
         (`(defconst gdev-cli-commands ',entries . ,_)
          (setq commands (mapcar #'car entries))))))
    (unless commands (error "Registro dei comandi gdev assente"))
    (vconcat (sort (append '("agent" "emacs") commands) #'string<))))

(defun gdev-agent-interface--module-entry (category name &optional flags)
  "Crea una voce JSON per CATEGORY, NAME e FLAGS."
  `((category . ,(substring (symbol-name category) 1))
    (name . ,(symbol-name name))
    (flags . ,(vconcat (mapcar #'symbol-name flags)))))

(defun gdev-agent-interface--default-modules ()
  "Leggi il modello distribuito come dati, senza valutare Lisp."
  (let (category entries)
    (gdev-agent-interface--read
     (expand-file-name "templates/init.el" gdev-agent-interface--root)
     (lambda (form _line)
       (when (eq (car-safe form) 'gdev!)
         (dolist (item (cdr form))
           (if (keywordp item)
               (setq category item)
             (push (if (consp item)
                       (gdev-agent-interface--module-entry category (car item) (cdr item))
                     (gdev-agent-interface--module-entry category item))
                   entries))))))
    (unless entries (error "Dichiarazione dei moduli predefiniti assente"))
    (vconcat (nreverse entries))))

(defun gdev-agent-interface--modules ()
  "Elenca i config.el dei moduli forniti dal checkout."
  (let ((root (expand-file-name "modules" gdev-agent-interface--root)))
    (vconcat
     (cl-loop for category in (directory-files root t directory-files-no-dot-files-regexp)
              when (file-directory-p category)
              append (cl-loop for module in (directory-files category t directory-files-no-dot-files-regexp)
                              for source = (expand-file-name "config.el" module)
                              when (file-regular-p source)
                              collect `((category . ,(file-name-nondirectory category))
                                        (name . ,(file-name-nondirectory module))
                                        (file . ,(file-relative-name source gdev-agent-interface--root))))))))

(defun gdev-agent-interface--mode-interactive-p (options)
  "Indica se le coppie iniziali di OPTIONS lasciano interattiva la modalità."
  (let ((interactive t))
    (while (keywordp (car options))
      (let ((keyword (pop options))
            (value (pop options)))
        (when (eq keyword :interactive)
          (setq interactive value))))
    interactive))

(defun gdev-agent-interface--interactive-declaration-p (form)
  "Indica se FORM dichiara un comando senza valutare o espandere il sorgente."
  (pcase (car form)
    ('define-derived-mode
     (let ((options (nthcdr 4 form)))
       (when (or (null (car options)) (stringp (car options)))
         (pop options))
       (gdev-agent-interface--mode-interactive-p options)))
    ('define-minor-mode
     (let ((options (nthcdr 3 form)))
       ;; Emacs ammette ancora INIT-VALUE, LIGHTER e KEYMAP prima delle opzioni.
       (dotimes (_ 3)
         (unless (keywordp (car options)) (pop options)))
       (gdev-agent-interface--mode-interactive-p options)))
    ('define-globalized-minor-mode
     (gdev-agent-interface--mode-interactive-p (nthcdr 4 form)))
    (_ (assq 'interactive (cddr form)))))

(defun gdev-agent-interface--symbols (prefix)
  "Trova nei sorgenti GDev le definizioni il cui nome comincia con PREFIX."
  (let (entries)
    (dolist (directory '("lisp" "modules" "test"))
      (let ((path (expand-file-name directory gdev-agent-interface--root)))
        (when (file-directory-p path)
          (dolist (file (directory-files-recursively path "\\.el\\'"))
            (let ((relative (file-relative-name file gdev-agent-interface--root)))
              (gdev-agent-interface--read
               file
               (lambda (form line)
                 (when (memq (car-safe form)
                             '(defun cl-defun defmacro cl-defmacro defalias defclass cl-defstruct
                               cl-defmethod defvar defcustom defconst ert-deftest define-derived-mode
                               define-minor-mode define-globalized-minor-mode))
                   (let* ((head (cadr form))
                          (name (if (consp head)
                                    (if (eq (car head) 'quote) (cadr head) (car head))
                                  head)))
                     (when (and (symbolp name) (string-prefix-p prefix (symbol-name name)))
                       (push `((name . ,(symbol-name name))
                               (kind . ,(symbol-name (car form)))
                               (file . ,relative)
                               (line . ,line)
                               (interactive . ,(if (gdev-agent-interface--interactive-declaration-p form)
                                                    t :false)))
                             entries)))))
               prefix))))))
    (vconcat (nreverse entries))))

(defconst gdev-agent-interface--live-actions
  '(("status" . 0)
    ("commands" . 0)
    ("shortcuts" . 1)
    ("open-file" . 1)
    ("open-folder" . 1)
    ("lavorazione-catalogo" . 0)
    ("lavorazione-apri" . 1)
    ("lavorazione-leggi" . 1)
    ("lavorazione-componi" . 3)
    ("lavorazione-salva" . 2)
    ("cursor-state" . 2)
    ("cursor-place" . 4)
    ("cursor-write" . 4)
    ("cursor-clear" . 2)
    ("eval" . 3)
    ("command" . 4)
    ("keys" . 3)
    ("open-location" . 3)
    ("buffer-read" . 3)
    ("buffers" . 0)
    ("layout" . 0)
    ("messages" . 1)
    ("assurance" . 3) ("assurance-request" . 3))
  "Nomi delle azioni dal vivo e numero dei loro argomenti.")

(defconst gdev-agent-interface--control-actions
  '("eval" "command" "keys" "open-location" "buffer-read" "buffers" "layout" "messages")
  "Azioni dal vivo che pilotano l'editor, servite da `gdev-agent-control'.")

(define-error 'gdev-agent-interface-failure "Richiesta dell'agente non riuscita")

(defun gdev-agent-interface-inventory (mode &optional prefix)
  "Costruisci l'inventario per MODE, cercando le definizioni con PREFIX."
  (append
   `((schema_version . ,gdev-agent-interface--schema-version)
     (mode . ,mode)
     (root . ,gdev-agent-interface--root)
     (interfaces . ((project_rules . "AGENTS.md")
                    (workflows . "docs/workflows.md")
                    (keymap . "docs/keymap.md")
                    (view_contract . "docs/interfaccia.md")
                    (module_template . "templates/init.el")
                    (dependencies . "vendor/pacchetti.el")
                    (licenses . "docs/dipendenze.md")
                    (cli . "bin/gdev")
                    (agent_protocol . "docs/agenti.md")))
     (cli_commands . ,(gdev-agent-interface--checkout-commands))
     (default_modules . ,(gdev-agent-interface--default-modules))
     (live_actions . ,(vconcat (mapcar #'car gdev-agent-interface--live-actions)))
     (live_signatures . ,(vconcat
                          (mapcar (pcase-lambda (`(,action . ,arity))
                                    `((action . ,action) (arity . ,arity)))
                                  gdev-agent-interface--live-actions))))
   (when (string= mode "develop")
     (list (cons 'modules (gdev-agent-interface--modules))))
   (when prefix (list (cons 'symbols (gdev-agent-interface--symbols prefix))))))

(defun gdev-agent-interface--error (message-text)
  "Costruisci un errore JSON con MESSAGE-TEXT."
  `((schema_version . ,gdev-agent-interface--schema-version)
    (ok . :false)
    (error . ,message-text)))

(defun gdev-agent-interface--status ()
  "Restituisci i dati di navigazione della finestra editor attiva."
  (let* ((window (gdev-layout-editor))
         (buffer (when (window-live-p window) (window-buffer window))))
    `((workspace_roots . ,(vconcat (gdev-workspace-roots)))
      (assurance_transaction . ,(if-let* ((active (gdev-workspace-state-get 'gdev-assurance-transaction)))
                                   `((root . ,(plist-get active :root)) (id . ,(plist-get active :id))) :null))
      (profile . ,(or (bound-and-true-p gdev-active-profile) :null))
      ;; Il parametro `name' segue solo il ridisegno successivo: dopo
      ;; un'apertura riporterebbe ancora il titolo precedente.
      (frame . ,(or (and frame-title-format
                         (substring-no-properties
                          (format-mode-line frame-title-format nil (frame-selected-window))))
                    (frame-parameter nil 'name) :null))
      (editor .
              ,(if (buffer-live-p buffer)
                   (with-current-buffer buffer
                     `((name . ,(buffer-name))
                       (file . ,(or buffer-file-name :null))
                       (mode . ,(symbol-name major-mode))
                       (modified . ,(if (buffer-modified-p) t :false))))
                 :null))
      (configured_modules .
                          ,(vconcat (mapcar (pcase-lambda (`(,category ,module . ,flags))
                                             (gdev-agent-interface--module-entry category module flags))
                                            gdev-modules))))))

(defun gdev-agent-interface--absolute-local-p (path)
  "Restituisci non nil per un PATH locale e assoluto."
  (and (stringp path)
       (not (string-search "\0" path))
       (not (file-remote-p path))
       (file-name-absolute-p path)
       (not (string-prefix-p "~" path))))

(defun gdev-agent-interface--commands ()
  "Restituisci le azioni disponibili nei menu del contesto attivo."
  (unless (fboundp 'gdev-menu-command-items)
    (user-error "La scoperta dei comandi richiede il modulo Workbench"))
  (vconcat
   (cl-loop for (label . command) in (gdev-menu-command-items)
            when (symbolp command)
            collect (let ((key (where-is-internal command (current-active-maps t) t)))
                      `((label . ,label) (command . ,(symbol-name command))
                        (key . ,(if key (key-description key) :null))
                        (display_key . ,(if key (gdev-menu-key-label key) :null)))))))

(defun gdev-agent-interface--shortcuts (query)
  "Descrivi i tasti effettivi del comando, o il comando del tasto, in QUERY."
  (unless (and (stringp query) (<= 1 (length query) 128))
    (user-error "Indica un tasto o il nome di un comando"))
  (let* ((symbol (intern-soft query))
         (by-command (commandp symbol))
         (keys (and (not by-command) (key-valid-p query) (kbd query)))
         (command (if by-command symbol (and keys (key-binding keys)))))
    (unless (and (symbolp command) (commandp command))
      (user-error "Nessun comando attivo per %s" query))
    (list (cons 'shortcut
                `((command . ,(symbol-name command))
                  (keys . ,(vconcat
                            (cl-loop for key in (if by-command
                                                    (where-is-internal command (current-active-maps t))
                                                  (list keys))
                                     when (and (not (seq-intersection
                                                     key [menu-bar tool-bar tab-bar tab-line remap]))
                                               (not (seq-some #'mouse-event-p key))
                                               (eq (key-binding key) command))
                                     collect `((key . ,(key-description key))
                                               (display_key . ,(if (fboundp 'gdev-menu-key-label)
                                                                  (gdev-menu-key-label key)
                                                                (key-description key))))))))))))

;;;###autoload
(defun gdev-agent-copy-socket ()
  "Copia il percorso del socket locale dell'istanza GDev corrente."
  (interactive)
  (require 'server)
  (unless (and (not server-use-tcp) (process-live-p server-process))
    (user-error "Questa istanza non ha un server Emacs locale attivo"))
  (kill-new (expand-file-name server-name server-socket-dir))
  (message "Percorso del socket Emacs copiato"))

(declare-function gdev-assurance-data "gdev-assurance" (command root &optional argument limit))
(declare-function gdev-assurance-db-find-root "gdev-assurance-db" (directory))
(declare-function gdev-assurance-read-command-p "gdev-assurance-api" (command))
(declare-function gdev-assurance-read-commands "gdev-assurance-api" ())
(declare-function gdev-assurance-request-enqueue "gdev-assurance-requests" (root tx-id proposal))
(declare-function gdev-assurance-workspace-active "gdev-assurance-workspace" (&optional frame))
(defvar gdev-assurance-data-limit)

(defun gdev-agent-interface--assurance (arguments)
  "Leggi l'archivio di assicurazione secondo ARGUMENTS: comando, argomento, radice.
È di sola lettura: il nucleo apre l'archivio con una connessione che non
scrive.  Senza radice parte dalla cartella della finestra selezionata e
cerca verso l'alto un archivio."
  (pcase-let ((`(,command ,argument ,root) arguments))
    (require 'gdev-assurance)
    (unless (gdev-assurance-read-command-p command)
      (user-error "Indica uno fra %s" (mapconcat #'identity (gdev-assurance-read-commands) ", ")))
    (let* ((start (if (equal root "")
                      (with-current-buffer (window-buffer (selected-window)) default-directory)
                    root))
           (base (expand-file-name (or (and (equal root "") (gdev-assurance-db-find-root start))
                                       start))))
      (when (and (member command '("work" "show" "assess" "standard-assess")) (equal argument ""))
        (require 'gdev-assurance-workspace)
        (let ((active (gdev-assurance-workspace-active)))
          (unless (and active (or (equal root "") (file-equal-p base (plist-get active :root))))
            (user-error "Indica l'identificativo della transazione, per esempio GT-0001"))
          (setq base (plist-get active :root) argument (plist-get active :id))))
      (condition-case err
          (gdev-assurance-data command base (and (not (equal argument "")) argument)
                               gdev-assurance-data-limit)
        (gdev-assurance-db-missing
         (user-error "Nessun archivio di assicurazione in %s" base))
        (gdev-assurance-no-transaction
         (user-error "La transazione %s non esiste" (cadr err)))
        (gdev-assurance-error
         (user-error "%s" (error-message-string err)))))))

(defun gdev-agent-interface--dispatch (action arguments)
  "Smista ACTION con ARGUMENTS e restituisci i campi specifici dell'esito."
  ;; eval, command e keys controllano da sé il minibuffer: accettano force.
  (when (and (not (member action '("status" "commands" "shortcuts" "cursor-state"
                                  "lavorazione-catalogo" "lavorazione-leggi"
                                  "buffer-read" "buffers" "layout" "messages"
                                  "assurance" "eval" "command" "keys")))
             (active-minibuffer-window))
    (user-error "Completa la richiesta aperta nel minibuffer prima di continuare"))
  (pcase action
    ("status" nil)
    ((pred (lambda (name) (member name gdev-agent-interface--control-actions)))
     (require 'gdev-agent-control)
     (apply #'gdev-agent-control-request action arguments))
    ("assurance"
     (list (cons 'assurance (gdev-agent-interface--assurance arguments))))
    ("assurance-request"
     (require 'gdev-assurance-requests)
     (pcase-let ((`(,id ,proposal ,root) arguments))
       (gdev-assurance-request-enqueue root id proposal)))
    ("commands"
     (with-current-buffer (window-buffer (selected-window))
       (list (cons 'commands (gdev-agent-interface--commands)))))
    ("shortcuts"
     (with-current-buffer (window-buffer (selected-window))
       (gdev-agent-interface--shortcuts (car arguments))))
    ((or "cursor-state" "cursor-place" "cursor-write" "cursor-clear")
     (require 'gdev-agent-cursors)
     (apply #'gdev-agent-cursors-request action arguments))
    ((or "open-file" "open-folder")
     (let ((path (car arguments))
           (file (equal action "open-file")))
       (unless (and (gdev-agent-interface--absolute-local-p path)
                    (if file (file-regular-p path) (file-directory-p path))
                    (file-readable-p path))
         (user-error "Indica un percorso locale assoluto, esistente e leggibile, del tipo richiesto"))
       (if file (gdev-open-file path) (gdev-open-folder path))
       nil))
    (_
     (unless (bound-and-true-p gdev-layout-mode)
       (user-error "Composizione richiede il modulo Workbench"))
     (require 'gdev-lavorazione-agent)
     (apply #'gdev-lavorazione-agent-richiesta action arguments))))

(defun gdev-agent-interface-request (root action &rest arguments)
  "Esegui ACTION con ARGUMENTS nell'Emacs GDev del checkout ROOT.
Questa funzione restituisce JSON, anche in caso di errore."
  (json-serialize
   (condition-case err
       (progn
         (unless (and (boundp 'gdev-config-directory)
                      (equal root gdev-config-directory)
                      (featurep 'gdev-commands))
           (user-error "Il socket non appartiene a questo checkout di GDev"))
         (unless (eql (length arguments) (cdr (assoc action gdev-agent-interface--live-actions)))
           (user-error "Azione o numero di argomenti non valido"))
         (let ((fields (gdev-agent-interface--dispatch action arguments)))
           `((schema_version . ,gdev-agent-interface--schema-version)
             (ok . t) (action . ,action) (root . ,root)
             (state . ,(gdev-agent-interface--status))
             ,@fields)))
     ;; DATA è (MESSAGGIO . CAMPI): l'errore conserva i dettagli raccolti.
     (gdev-agent-interface-failure
      (append (gdev-agent-interface--error (cadr err)) (cddr err)))
     (error (gdev-agent-interface--error (error-message-string err))))))

(defun gdev-agent-interface--client ()
  "Trova emacsclient nella distribuzione di Emacs o in PATH."
  (let ((sibling (expand-file-name "emacsclient" invocation-directory)))
    (or (when (file-executable-p sibling) sibling)
        (executable-find "emacsclient")
        (user-error "emacsclient non disponibile"))))

(defconst gdev-agent-interface-no-reply
  "Emacs non ha restituito un esito. Controlla socket e stato prima di riprovare"
  "Errore di un'istanza raggiungibile che non ha risposto.")

(defun gdev-agent-interface-check-socket (socket)
  "Segnala un errore se SOCKET non è il percorso assoluto di un socket Unix."
  (unless (and socket (gdev-agent-interface--absolute-local-p socket)
               (string-prefix-p "s" (or (file-attribute-modes (file-attributes socket)) "")))
    (user-error "Indica il percorso assoluto di un socket Unix di Emacs")))

(defun gdev-agent-interface--live (socket action arguments)
  "Invia ACTION con ARGUMENTS al SOCKET Unix esplicitamente scelto."
  (gdev-agent-interface-check-socket socket)
  (unless (eql (length arguments) (cdr (assoc action gdev-agent-interface--live-actions)))
    (user-error "Azione o numero di argomenti non valido. Consulta gdev agent use"))
  (with-temp-buffer
    (let* ((default-directory gdev-agent-interface--root)
           (process-environment (copy-sequence process-environment))
           ;; Gli argomenti sono stringhe Lisp stampate, mai testo inserito in una forma.
           (request
            (let ((print-escape-nonascii t)
                  (print-escape-multibyte t)
                  (print-escape-newlines t))
              (prin1-to-string
               `(base64-encode-string
                 (if (and (boundp 'gdev-config-directory)
                          (equal gdev-config-directory ,gdev-agent-interface--root))
                     (progn (require 'gdev-agent-interface)
                            (gdev-agent-interface-request ,gdev-agent-interface--root ,action ,@arguments))
                   ,(json-serialize (gdev-agent-interface--error
                                     "Il socket non appartiene a questo checkout di GDev")))
                 t)))))
      (setenv "ALTERNATE_EDITOR" nil)
      (unless (eql (process-file (gdev-agent-interface--client) nil '(t nil) nil
                                "--timeout=10" "--socket-name" socket "--eval" request)
                   0)
        (user-error "%s" gdev-agent-interface-no-reply))
      (goto-char (point-min))
      (let* ((read-circle nil)
             (reply (read (current-buffer))))
        (unless (stringp reply) (error "Risposta inattesa dal server Emacs"))
        (json-parse-string (decode-coding-string (base64-decode-string reply) 'utf-8-unix)
                           :object-type 'alist :null-object :null :false-object :false)))))

(defun gdev-agent-interface-main ()
  "Stampa un oggetto JSON e termina con stato diverso da zero in caso di errore."
  (set-terminal-coding-system 'utf-8-unix)
  (let* ((arguments command-line-args-left)
         (mode (pop arguments))
         (response
          (condition-case err
              (pcase mode
                ("develop"
                 (unless (or (null arguments)
                             (and (= (length arguments) 1)
                                  (not (string-empty-p (car arguments)))
                                  (not (string-prefix-p "--" (car arguments)))))
                   (user-error "Uso: gdev agent develop [PREFISSO]"))
                 (gdev-agent-interface-inventory mode (car arguments)))
                ("use"
                 (when arguments (user-error "Uso: gdev agent use"))
                 (gdev-agent-interface-inventory mode))
                ("live" (gdev-agent-interface--live (pop arguments) (pop arguments) arguments))
                (_ (user-error "Uso: gdev agent develop [PREFISSO] | use | live SOCKET AZIONE [ARGOMENTI]")))
            (error (gdev-agent-interface--error (error-message-string err))))))
    ;; json-serialize restituisce byte UTF-8. In batch princ stampa testo.
    ;; Questo file si carica da solo, senza gdev-lib, nel percorso rapido di `gdev agent':
    ;; per questo non usa `gdev-json-text'.
    (princ (decode-coding-string (json-serialize response) 'utf-8-unix))
    (terpri)
    (kill-emacs (if (assq 'error response) 1 0))))

(provide 'gdev-agent-interface)
;;; gdev-agent-interface.el ends here
