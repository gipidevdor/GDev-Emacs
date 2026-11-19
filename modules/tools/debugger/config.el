;;; config.el --- :tools debugger: esecuzione passo passo e ispezione del programma -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Gli adattatori DAP usano un protocollo comune per eseguire e ispezionare i programmi.
;; Scorciatoie e riquadri valgono per C, C++, Perl e per ogni linguaggio
;; che dispone di un adattatore compatibile.
;;
;;   F5          avvia o riprendi l'esecuzione passo passo
;;   S-F5        termina la sessione
;;   C-S-F5      riavvia
;;   F9          attiva/disattiva un punto di interruzione;
;;               basta anche un clic sul bordo laterale
;;   F10         avanza senza entrare nella funzione
;;   F11         entra nella funzione
;;   S-F11       esci dalla funzione
;;   C-c d e     punto di interruzione condizionale
;;   C-c d l     punto di registrazione: scrive un messaggio
;;               senza fermarsi
;;   C-c d h     punto di interruzione dopo N passaggi
;;   C-c d w     osserva un'espressione
;;   C-c d x     valuta un'espressione nel livello della pila
;;               in pausa
;;   C-c d a     collegati a un processo in esecuzione
;;   C-c d P     gestisci i punti di interruzione dello spazio
;;   C-c d I     ispeziona variabili, espressioni, pila e flussi
;;   C-c d C     apri un'immagine di memoria per l'analisi
;;               post-mortem
;;   C-c d i     pannelli: variabili locali, espressioni osservate, pila
;;               delle chiamate, flussi di esecuzione, punti di
;;               interruzione
;;   C-c d M     codice disassemblato
;;   C-c d m     memoria
;;
;; In pausa, n, s, o, c e gli altri tasti si ripetono senza prefisso.
;;
;; Adattatori:
;;   C, C++      lldb-dap da Xcode (xcrun), altrimenti dal PATH; prima
;;               compila con le informazioni di diagnostica (Debug o
;;               RelWithDebInfo, C-c p y).
;;   Perl        usa Perl::LanguageServer come adattatore.
;;   Common Lisp usa il sistema di diagnosi di SLY (:lang common-lisp).
;;   Emacs Lisp  C-u C-M-x prepara una funzione con Edebug.
;;   GDB         C-c d g avvia GDB in GUD (Linux, FreeBSD).
;;
;; I punti di interruzione si conservano tra i riavvii. Su macOS, per
;; collegarti ai processi abilita la modalità sviluppatore con
;; DevToolsSecurity -enable.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-launch)
(require 'gdev-layout)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)

(declare-function dape "dape")
(declare-function dape-kill "dape" (connection &optional callback with-disconnect))
(declare-function dape-restart "dape" (&optional connection skip-compile valid-p))
(declare-function dape-until "dape" (connection))
(declare-function dape-breakpoint-load "dape")
(declare-function dape-breakpoint-save "dape")
(declare-function dape-breakpoint-global-mode "dape-breakpoint-mode" (&optional arg))
(declare-function dape--read-breakpoint-file "dape-breakpoint-mode" (filename))
(declare-function gdev-call-with-editor "gdev-commands" (function))
(defvar dape-default-breakpoints-file)
(declare-function dape-continue "dape")
(defvar dape-configs)
(defvar dape-active-mode)
(defvar dape--connection-selected)
(defvar dape-default-config-functions)
(declare-function gdev-build--root "../build/config" ())
(declare-function gdev-cmake--cached-source "../build/config" (directory))
(declare-function dape--read-config "dape" ())
(declare-function dape--live-connections "dape" ())
(declare-function dape--live-connection "dape" (kind &optional noerror require-selected))
(declare-function dape--config "dape" (connection))
(declare-function dape--root-of "dape" (connection))
(declare-function dape--state "dape" (connection))
(declare-function dape-config-get "dape" (config prop))
(declare-function dape-select-session "dape" (connection &optional exact))
(declare-function dape--initialized-p "dape" (connection))
(declare-function dape-exception-filter-options "dape" (connection))
(declare-function dape-enabled-exception-filters "dape" (connection))
(declare-function dape-set-exception-filters "dape" (connection filters))
(declare-function gdev-debug-workbench-refresh-visible "gdev-debug-workbench"
                  (&optional system-only))

(when (gdev-module-p :ui 'workbench)
  (autoload 'gdev-debug-breakpoints-show "gdev-debug-breakpoints" nil t)
  (autoload 'gdev-debug-inspector-show "gdev-debug-inspector" nil t))

(defvar gdev-debug--local-targets (make-hash-table :test #'eq :weakness 'key)
  "Processi locali comunicati dagli adattatori, indicizzati per connessione.")

(defvar gdev-debug--workspace-results (make-hash-table :test #'eq :weakness 'key)
  "Ultimo programma e codice di uscita comunicati dal debugger per spazio.")

(defvar gdev-debug--workspace-selection (make-hash-table :test #'eq :weakness 'key)
  "Ultima connessione di debug scelta in ciascuno spazio.")

(defun gdev-debug--add-workspace (config)
  "Associa CONFIG allo spazio di lavoro in cui parte la sessione."
  (if (and (bound-and-true-p gdev-layout-mode)
           (not (plist-get config 'gdev-workspace)))
      (plist-put config 'gdev-workspace (gdev-workspace-state-ensure-id))
    config))

(defun gdev-debug--remember-target (connection body)
  "Registra per CONNECTION il PID locale dichiarato nell'evento BODY."
  (let* ((pid (plist-get body :systemProcessId))
         (config (dape--config (dape--root-of connection)))
         (directory (plist-get config 'command-cwd))
         (host (plist-get config 'host)))
    (if (and (integerp pid) (> pid 0)
             (not (eq (plist-get body :isLocalProcess) :json-false))
             (not (and directory (file-remote-p directory)))
             (or (not host) (member host '("localhost" "127.0.0.1" "::1")))
             (not (and (plist-get config 'source-directories)
                       (plist-get config 'port)
                       (not (plist-get config 'command)))))
        (puthash connection pid gdev-debug--local-targets)
      (remhash connection gdev-debug--local-targets))))

(defun gdev-debug-workspace-connections (owner)
  "Restituisci le connessioni attive avviate nello spazio OWNER."
  (when (and owner (fboundp 'dape--live-connections))
    (seq-filter
     (lambda (connection)
       (eq owner (plist-get (dape--config (dape--root-of connection)) 'gdev-workspace)))
     (dape--live-connections))))

(cl-defun gdev-debug-workspace-connection
    (owner &optional (connections (gdev-debug-workspace-connections owner)))
  "Restituisci la connessione selezionata di OWNER, o la più recente.
Usa CONNECTIONS quando le connessioni sono già state raccolte."
  (or (car (memq (bound-and-true-p dape--connection-selected) connections))
      (car (memq (gethash owner gdev-debug--workspace-selection) connections))
      (car connections)))

(defun gdev-debug-workspace-target (connection)
  "Restituisci il PID del programma locale di CONNECTION quando noto."
  (when (and connection (not (memq (dape--state connection) '(exited terminated))))
    (gethash connection gdev-debug--local-targets)))

(defun gdev-debug-workspace-result (owner)
  "Restituisci (PROGRAMMA . CODICE) dell'ultima uscita nello spazio OWNER."
  (gethash owner gdev-debug--workspace-results))

(defun gdev-debug--record-exit (connection body)
  "Conserva il codice di uscita di CONNECTION quando BODY lo contiene."
  (when (eq connection (dape--root-of connection))
    (let* ((config (dape--config connection))
           (owner (plist-get config 'gdev-workspace))
           (code (plist-get body :exitCode)))
      (when (and owner (integerp code))
        (puthash owner (cons (plist-get config :program) code) gdev-debug--workspace-results)))))

(declare-function gdev-workbench-operation-start "gdev-workbench-operations"
                  (label buffer &optional interruptible owner))
(declare-function gdev-workbench-operation-finish "gdev-workbench-operations"
                  (operation success &optional detail))

(defvar gdev-debug--operations (make-hash-table :test #'eq :weakness 'key)
  "Operazione dello spazio che rappresenta ciascuna sessione principale.")

(defun gdev-debug--operation-label (connection)
  "Nome dell'operazione per la sessione CONNECTION."
  (let* ((config (dape--config connection))
         (program (plist-get config :program)))
    (format "Debug · %s" (cond ((stringp program) (file-name-nondirectory program))
                               ((plist-get config :type))
                               (t "sessione")))))

(defun gdev-debug--finish-operation (connection code)
  "Chiudi l'operazione di CONNECTION con il codice di uscita CODE, se noto."
  (when-let* ((operation (gethash connection gdev-debug--operations)))
    (remhash connection gdev-debug--operations)
    (gdev-workbench-operation-finish operation (or (not (integerp code)) (= code 0))
                                     (and (integerp code) (/= code 0) (format "Codice %d" code)))))

(defun gdev-debug--track-operation (connection)
  "Mostra fra le operazioni dello spazio la sessione principale CONNECTION."
  (when (and (fboundp 'gdev-workbench-operation-start)
             (eq connection (dape--root-of connection)))
    (let ((owner (plist-get (dape--config connection) 'gdev-workspace))
          (state (dape--state connection)))
      (cond ((not owner))
            ;; L'uscita con il suo codice arriva dall'evento `exited'.
            ((eq state 'terminated) (gdev-debug--finish-operation connection nil))
            ((or (eq state 'exited) (gethash connection gdev-debug--operations)))
            ((when-let* ((operation (gdev-workbench-operation-start
                                     (gdev-debug--operation-label connection) nil
                                     (lambda (_)
                                       ;; La stessa conferma del pannello Debug.
                                       (when (yes-or-no-p "Terminare la sessione di questo spazio? ")
                                         (gdev-debug-session-command #'dape-kill connection)
                                         t))
                                     owner)))
               (puthash connection operation gdev-debug--operations)))))))

(defun gdev-debug-select-workspace-session (owner)
  "Scegli una sessione fra quelle attive nello spazio OWNER."
  (let* ((choices
          (cl-loop for conn in (gdev-debug-workspace-connections owner)
                   for n from 1
                   for config = (dape--config conn)
                   collect
                   (cons (format "%d  %s" n (or (plist-get config :program) (plist-get config :type)
                                                "Sessione di debug"))
                         conn)))
         (choice (and choices (completing-read "Sessione dello spazio: " choices nil t))))
    (unless choice (user-error "Nessuna sessione attiva in questo spazio"))
    (let ((connection (cdr (assoc choice choices))))
      (dape-select-session connection t)
      (puthash owner connection gdev-debug--workspace-selection))
    (gdev-debug--refresh-workbench)))

(defun gdev-debug--refresh-workbench (&rest _)
  "Rendi visibile il nuovo stato ai riquadri di debug aperti."
  (when (fboundp 'gdev-debug-workbench-refresh-visible)
    (gdev-debug-workbench-refresh-visible)))

;;;; LLDB (C, C++, Objective-C)

(defun gdev-debug-lldb-dap ()
  "Restituisce l'adattatore lldb-dap: Xcode, poi PATH, poi LLVM di Homebrew."
  (if (file-remote-p default-directory)
      (when-let* ((program (executable-find "lldb-dap" t))) (file-local-name program))
    (or (gdev-xcrun-find "lldb-dap")
        (executable-find "lldb-dap")
        (let ((homebrew (expand-file-name "opt/llvm/bin/lldb-dap"
                                          (or (getenv "HOMEBREW_PREFIX") "/opt/homebrew"))))
          (and (file-executable-p homebrew) homebrew)))))

(defconst gdev-debug--c-modes
  '(c-mode c-ts-mode c++-mode c++-ts-mode objc-mode rust-ts-mode rust-mode rustic-mode swift-mode zig-mode)
  "Modalità che usano LLDB per l'esecuzione passo passo.")

(defvar gdev-debug--developer-mode nil
  "Non nil dopo aver verificato che macOS consente il debug senza conferma.")

(defconst gdev-debug--developer-mode-hint
  "Abilita la modalità sviluppatore con sudo DevToolsSecurity -enable"
  "Rimedio quando macOS chiede l'autorizzazione a ogni sessione di debug.")

(defun gdev-debug-developer-mode-p ()
  "Indica se macOS consente a LLDB di controllare i processi senza conferma.
Fuori da macOS, o senza DevToolsSecurity, non c'è nulla da autorizzare."
  (or gdev-debug--developer-mode
      (not (eq system-type 'darwin))
      (not (executable-find "DevToolsSecurity"))
      (setq gdev-debug--developer-mode
            (with-temp-buffer
              (and (eq 0 (ignore-errors
                           (call-process "DevToolsSecurity" nil t nil "-status")))
                   (progn (goto-char (point-min))
                          (re-search-forward "\\_<enabled\\_>" nil t))
                   t)))))

(defun gdev-debug--lldb-ensure (config)
  "Segnala un errore chiaro se lldb-dap non è installato.
Su macOS avvisa quando il sistema chiederà di autorizzare il debug: senza
conferma il programma resta fermo prima di raggiungere i punti di interruzione."
  (unless (dape-config-get config 'command)
    (user-error "lldb-dap non trovato: installa Xcode o gli strumenti LLVM"))
  (when (and (member (plist-get config :request) '("launch" "attach"))
             (not (plist-get config :coreFile))
             (not (file-remote-p default-directory))
             (not (gdev-debug-developer-mode-p)))
    (message "macOS chiede di autorizzare il debug: conferma la richiesta di sistema. %s"
             gdev-debug--developer-mode-hint)))

(gdev-doctor-check "Debug senza conferma su macOS" #'gdev-debug-developer-mode-p
                   gdev-debug--developer-mode-hint 'note)

(defun gdev-debug--cmake-source-map (program directory)
  "Allinea i percorsi di debug di PROGRAM al progetto CMake in DIRECTORY."
  (when-let* (((stringp program))
              ((not (or (file-remote-p program) (file-remote-p directory))))
              ((fboundp 'gdev-cmake--cached-source))
              ((file-regular-p (expand-file-name "CMakeLists.txt" directory)))
              (build (locate-dominating-file (expand-file-name program directory) "CMakeCache.txt"))
              (source (gdev-cmake--cached-source build))
              (root (directory-file-name directory))
              ((not (equal source root)))
              ((file-equal-p source root)))
    ;; LLDB confronta il percorso del sorgente compilato con quello del breakpoint.
    (vector (vector source root))))

(defun gdev-debug--lldb-config (directory request &rest attributes)
  "Prepara lldb-dap in DIRECTORY con REQUEST e ATTRIBUTES."
  (let ((default-directory directory)
        (source-map (when (equal request "launch")
                      (gdev-debug--cmake-source-map (plist-get attributes :program) directory))))
    (dolist (field '(:program :coreFile))
      (when-let* ((value (plist-get attributes field)) ((stringp value)))
        (setq attributes (plist-put attributes field (file-local-name value)))))
    (nconc (list 'modes gdev-debug--c-modes
                 'ensure #'gdev-debug--lldb-ensure
                 'command (gdev-debug-lldb-dap)
                 'command-cwd directory
                 :type "lldb-dap" :request request :cwd (file-local-name directory))
           (when source-map (list :sourceMap source-map))
           attributes)))

(declare-function gdev-python-debug-config "../../lang/python/config" (file python root args))
(declare-function gdev-python--interpreter "../../lang/python/config" (root))
(declare-function dape-ensure-command "dape" (config))

(defun gdev-debug--environment (entries)
  "Converti gli assegnamenti ENTRIES in un oggetto JSON per DAP."
  (let ((variables (make-hash-table :test #'equal)))
    (dolist (entry entries variables)
      (let ((separator (string-search "=" entry)))
        (puthash (substring entry 0 separator) (substring entry (1+ separator)) variables)))))

(defun gdev-debug-profile-config (adapter program args environment directory)
  "Restituisci la sessione ADAPTER per PROGRAM, ARGS ed ENVIRONMENT in DIRECTORY."
  (let* ((default-directory directory)
         (variables (gdev-debug--environment environment))
         (launch (list 'command-cwd directory :request "launch"
                       :program program :args (vconcat args) :cwd (file-local-name directory))))
    (pcase adapter
      ((or 'nil 'lldb)
       (gdev-debug--lldb-config directory "launch" :program program
                               :args (vconcat args) :env (vconcat environment)))
      ('delve
       (append (list 'command "dlv" 'ensure #'dape-ensure-command 'port :autoport
                     'command-args '("dap" "--listen" "127.0.0.1::autoport")
                     'command-insert-stderr t :type "go" :mode "exec" :env variables)
               launch))
      ('debugpy
       (unless (fboundp 'gdev-python-debug-config) (user-error "Attiva il modulo Python"))
       (append (gdev-python-debug-config program (gdev-python--interpreter directory) directory args)
               (list :env variables)))
      ('netcoredbg
       (append (list 'command "netcoredbg" 'ensure #'dape-ensure-command
                     'command-args '("--interpreter=vscode")
                     :type "coreclr" :stopAtEntry nil :env variables)
               launch))
      ('perl
       (gdev-debug--perl-config program directory args
                                (gdev-debug--perl-environment directory variables)))
      (_ (user-error "Adattatore di debug sconosciuto: %s" adapter)))))

(defun gdev-debug-launch-profile (options root directory environment)
  "Avvia OPTIONS per ROOT in DIRECTORY con ENVIRONMENT."
  (let* ((default-directory directory)
         (adapter (plist-get options :adapter))
         (fields (plist-get options :options))
         (attach (equal (plist-get fields :request) "attach"))
         (path (plist-get options :program))
         (program (when path
                    (if (eq adapter 'custom)
                        (file-local-name (expand-file-name path directory))
                      (gdev-launch-program path directory (memq adapter '(nil lldb delve))))))
         (args (plist-get options :args))
         (command (plist-get options :adapter-command))
         (config (if (eq adapter 'custom)
                     (nconc (list 'command-cwd directory :cwd (file-local-name directory))
                            (when program (list :program program))
                            (when args (list :args (vconcat args)))
                            (when environment (list :env (gdev-debug--environment environment))))
                   (gdev-debug-profile-config adapter program args environment directory))))
    (when (and gdev-layout-mode
               (when-let* ((conn (gdev-debug-workspace-connection (gdev-workspace-state-id))))
                 (not (memq (dape--state conn) '(exited terminated)))))
      (user-error "Debug già attivo in questo spazio"))
    (setq config (plist-put config :cwd (file-local-name directory)))
    (when (and attach (not program)) (cl-remf config :program))
    (when (and attach (not args)) (cl-remf config :args))
    (when (and program (memq adapter '(nil lldb)) (not attach) (not (equal root directory)))
      (when-let* ((source-map (gdev-debug--cmake-source-map program root)))
        (setq config (plist-put config :sourceMap source-map))))
    (when command
      (let ((tool (car command)))
        (setq config (plist-put config 'command
                                (if (file-name-directory tool)
                                    (gdev-launch-program tool directory t)
                                  tool))))
      (setq config (plist-put config 'command-args (cdr command))
            config (plist-put config 'ensure #'dape-ensure-command)))
    (when-let* ((entries (plist-get options :adapter-env)))
      (setq config (plist-put config 'command-env
                              (cl-loop for entry in entries
                                       for separator = (string-search "=" entry)
                                       append (list (substring entry 0 separator)
                                                    (substring entry (1+ separator)))))))
    (dolist (field '((:port . port) (:host . host) (:exception-filters . exception-filters)))
      (when-let* ((value (plist-member options (car field))))
        (setq config (plist-put config (cdr field) (cadr value)))))
    (when-let* ((directories (plist-get options :source-map)))
      (setq config (plist-put config 'source-directories
                              (vector (expand-file-name (cadr directories) root)
                                      (expand-file-name (car directories) "/")))))
    (cl-loop for (key value) on fields by #'cddr do (setq config (plist-put config key value)))
    (when (plist-member options :args)
      (setq config (plist-put config :args (vconcat args))))
    (dape config)))

(defun gdev-debug--context-connection ()
  "Restituisci la sessione attiva del contesto corrente."
  (if gdev-layout-mode
      (gdev-debug-workspace-connection (gdev-workspace-state-id))
    (when (fboundp 'dape--live-connection)
      (or (dape--live-connection 'last t) (dape--live-connection 'parent t)))))

(defun gdev-debug--workspace-open-p (owner)
  "Restituisci non-nil finché lo spazio OWNER è aperto in una finestra."
  (seq-some (lambda (frame) (gdev-workspace-state-find owner frame)) (frame-list)))

(defun gdev-debug-session-command (command &optional connection)
  "Esegui COMMAND sulla CONNECTION indicata o su quella dello spazio attivo.
Fuori dal Workbench usa il comando interattivo del debug."
  (if (or connection gdev-layout-mode)
      (let ((conn (or connection (gdev-debug--context-connection)
                      (user-error "Nessuna sessione attiva in questo spazio"))))
        (pcase command
          ((or 'dape-quit 'dape-kill) (dape-kill (dape--root-of conn)))
          ('dape-restart
           (let* ((root (dape--root-of conn))
                  (owner (plist-get (dape--config root) 'gdev-workspace)))
             (dape-restart root nil (and owner (lambda () (gdev-debug--workspace-open-p owner))))))
          ('dape-until (if (and gdev-layout-mode (gdev-layout-editor))
                           (gdev-call-with-editor (lambda () (dape-until conn)))
                         (dape-until conn)))
          (_ (funcall command conn))))
    (call-interactively command)))

(defun gdev-debug-continue ()
  "Riprendi la sessione di debug di questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-continue))

(defun gdev-debug-next ()
  "Esegui il passo successivo in questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-next))

(defun gdev-debug-step-in ()
  "Entra nella funzione in questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-step-in))

(defun gdev-debug-step-out ()
  "Esci dalla funzione in questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-step-out))

(defun gdev-debug-until ()
  "Esegui fino al cursore nella sessione di questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-until))

(defun gdev-debug-pause ()
  "Metti in pausa la sessione di debug di questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-pause))

(defun gdev-debug-restart ()
  "Riavvia la sessione di debug di questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-restart))

(defun gdev-debug-terminate ()
  "Termina la sessione di questo spazio, oppure termina il debug."
  (interactive)
  (gdev-debug-session-command #'dape-quit))

(defun gdev-debug-kill-process ()
  "Termina il processo della sessione di debug di questo spazio."
  (interactive)
  (gdev-debug-session-command #'dape-kill))

(defun gdev-debug-exceptions-available-p (&optional connection)
  "Indica se CONNECTION, o la sessione corrente, offre filtri."
  (when-let* ((conn (or connection (gdev-debug--context-connection)))
              ((dape--initialized-p conn)))
    (dape-exception-filter-options conn)))

(defun gdev-debug-exceptions (&optional connection)
  "Scegli quali eccezioni mettono in pausa CONNECTION o la sessione corrente."
  (interactive)
  (let* ((conn (or connection (gdev-debug--context-connection)
                   (user-error "Nessuna sessione di debug in questo spazio")))
         (filters (or (gdev-debug-exceptions-available-p conn)
                      (user-error "L'adattatore non offre filtri per le eccezioni")))
         (entries (mapcar (lambda (spec) (cons (plist-get spec :filter) spec)) filters))
         (enabled (dape-enabled-exception-filters conn))
         (completion-extra-properties
          (list :annotation-function
                (lambda (id)
                  (when-let* ((label (plist-get (cdr (assoc id entries)) :label)))
                    (concat "  " label)))))
         (selected (completing-read-multiple "Interrompi sulle eccezioni: " entries nil t
                                             (string-join enabled ", "))))
    (unless (equal (sort (copy-sequence enabled) #'string-lessp)
                   (sort (copy-sequence selected) #'string-lessp))
      (dape-set-exception-filters conn selected))))

(defun gdev-debug-program (&optional ask-arguments)
  "Avvia con LLDB un programma del progetto.
Propone gli eseguibili delle cartelle di compilazione e ricorda l'ultimo;
chiede gli argomenti la prima volta, o con ASK-ARGUMENTS."
  (interactive "P")
  (pcase-let* ((root (gdev-project-build-root))
               (`(,program . ,arguments)
                (gdev-read-program "Programma da avviare nel debugger"
                                   (or ask-arguments (not (gethash root gdev--last-program))) root)))
    (dape (gdev-debug--lldb-config root "launch"
                                   :program program
                                   :args (vconcat (gdev-shell-split arguments))
                                   :stopOnEntry nil))))

(defun gdev-debug-attach (pid)
  "Collega LLDB al processo in esecuzione PID (scelto da un elenco)."
  (interactive (list (gdev-read-process)))
  (dape (gdev-debug--lldb-config (gdev-project-root) "attach" :pid pid)))

(defun gdev-debug-core (program core)
  "Esamina con LLDB l'immagine di memoria CORE di PROGRAM.
Mostra la pila delle chiamate, le variabili locali e la memoria."
  (interactive
   (list (car (gdev-read-program "Programma terminato in modo anomalo (crash)"))
         (read-file-name "File dell'immagine di memoria (core): " "/cores/" nil t)))
  (dape (gdev-debug--lldb-config (gdev-project-root) "attach"
                               :program program :coreFile (expand-file-name core))))

;;;; Perl (Perl::LanguageServer)

(defconst gdev-debug--perl-command-args
  '("-MPerl::LanguageServer" "-e" "Perl::LanguageServer::run" "--" "--port" :autoport "--nostdio")
  "Argomenti per avviare l'adattatore Perl::LanguageServer.
L'adattatore resta in ascolto su una porta libera.")

(defun gdev-debug--perl-environment (&optional root variables)
  "Prepara le VARIABLES con la cartella lib/ di ROOT in PERL5LIB."
  (let* ((root (or root (gdev-project-root)))
         (env (or variables (make-hash-table :test #'equal)))
         (paths (gethash "PERL5LIB" env (getenv "PERL5LIB"))))
    (puthash "PERL5LIB"
             (string-join (delq nil (list (file-local-name (expand-file-name "lib" root)) paths))
                          path-separator)
             env)
    env))

(defun gdev-debug--perl-config (program root args environment &optional program-cwd)
  "Avvia PROGRAM via Perl::LanguageServer, con ARGS ed ENVIRONMENT.
ROOT è la cartella dell'adattatore. PROGRAM-CWD è quella del programma."
  (list 'modes '(cperl-mode perl-mode)
        'command "perl" 'command-args gdev-debug--perl-command-args 'port :autoport
        'command-cwd root :type "perl" :request "launch"
        :cwd (or program-cwd root) :program program
        :args (vconcat args) :env environment :stopOnEntry nil :reloadModules t))

(defun gdev-debug-perl-file (&optional ask-arguments)
  "Avvia il debug del programma Perl aperto con Perl::LanguageServer.
Chiede gli argomenti del programma la prima volta, o con ASK-ARGUMENTS."
  (interactive "P")
  (let* ((file (or buffer-file-name (user-error "Apri prima il programma Perl da eseguire passo passo")))
         (root (gdev-project-root))
         (key (concat "debug:" file))
         (arguments (if (or ask-arguments (not (gethash key gdev--last-program)))
                        (read-string "Argomenti: " (gethash key gdev--last-program)
                                     'gdev-program-arguments-history)
                      (gethash key gdev--last-program))))
    (puthash key arguments gdev--last-program)
    (dape (gdev-debug--perl-config file root (gdev-shell-split arguments)
                                 (gdev-debug--perl-environment root)))))

;;;; Punti di ingresso

(defun gdev-debug--configs ()
  "Restituisce le configurazioni con nome proposte da M-x dape."
  `((gdev-lldb modes ,gdev-debug--c-modes
               ensure gdev-debug--lldb-ensure
               command gdev-debug-lldb-dap
               command-cwd dape-command-cwd
               :type "lldb-dap" :request "launch" :cwd dape-cwd
               :program gdev-debug--read-program-name)
    (gdev-lldb-attach modes ,gdev-debug--c-modes
                      ensure gdev-debug--lldb-ensure
                      command gdev-debug-lldb-dap
                      command-cwd dape-command-cwd
                      :type "lldb-dap" :request "attach"
                      :pid gdev-read-process)
    (gdev-perl ,@(gdev-debug--perl-config 'dape-buffer-default 'dape-command-cwd nil
                                       #'gdev-debug--perl-environment 'dape-cwd))))

(defun gdev-debug--read-program-name ()
  "Legge un programma del progetto per una configurazione dape."
  (car (gdev-read-program "Programma da avviare nel debugger" nil (gdev-project-build-root))))

(gdev-set-debugger gdev-debug--c-modes #'gdev-debug-program)
(gdev-set-debugger '(cperl-mode perl-mode) #'gdev-debug-perl-file)

(defun gdev-debug--start-document (ask-arguments)
  "Avvia il debug dal documento corrente, usando ASK-ARGUMENTS come prefisso."
  (gdev-require-project-environment)
  (let ((current-prefix-arg ask-arguments)
        (default-directory (or (and (not buffer-file-name) (gdev-workspace-directory))
                               default-directory)))
    (cond ((gdev-launch-dispatch 'debug ask-arguments))
          ((gdev-handler :debug) (call-interactively (gdev-handler :debug)))
          ((derived-mode-p 'emacs-lisp-mode)
           (user-error "Emacs Lisp: C-u C-M-x su una funzione la prepara per edebug"))
          ((gdev-project-file-exists-p (gdev-project-build-root)
                                      "CMakeLists.txt" "meson.build" "build.ninja")
           (call-interactively #'gdev-debug-program))
          (gdev-layout-mode
           ;; La scelta di Dape lascia disponibili le sessioni degli altri spazi.
           (require 'dape)
           (dape (dape--read-config)))
          (t (call-interactively #'dape)))))

(defun gdev-debug-start-editor (&optional ask-arguments)
  "Avvia il profilo o il debugger del gruppo editor attivo.
Con ASK-ARGUMENTS chiedi gli argomenti del programma."
  (interactive "P")
  (if (and gdev-layout-mode (gdev-layout-editor))
      (gdev-call-with-editor (lambda () (gdev-debug--start-document ask-arguments)))
    (gdev-debug--start-document ask-arguments)))

(defun gdev-debug-dwim (&optional ask-arguments)
  "Continua il debug dello spazio o avvia il profilo e il programma attivi.
Con ASK-ARGUMENTS chiedi gli argomenti del programma configurato."
  (interactive "P")
  (let* ((workbench (bound-and-true-p gdev-layout-mode))
         (owner (and workbench (gdev-workspace-state-id)))
         (connection (gdev-debug-workspace-connection owner))
         (state (and connection (dape--state connection))))
    (cond ((eq state 'stopped)
           (gdev-debug-session-command #'dape-continue connection))
          ((and connection (not (memq state '(exited terminated))))
           (message "Debug già attivo in questo spazio"))
          ((and (not workbench) (bound-and-true-p dape-active-mode))
           (call-interactively #'dape-continue))
          (t (gdev-debug-start-editor ask-arguments)))))

;;;; dape

(defun gdev-debug--restore-breakpoints ()
  "Carica il debug a riposo se ci sono punti di interruzione salvati."
  (unless (featurep 'dape)
    (when (condition-case nil
              (dape--read-breakpoint-file dape-default-breakpoints-file)
            (file-missing nil))
      (require 'dape))))

(defun gdev-debug--start-breakpoint-controls ()
  "Abilita i clic nel margine e prepara il ripristino dei punti salvati."
  (require 'dape-breakpoint-mode)
  (dape-breakpoint-global-mode 1)
  (when (and (not (featurep 'dape)) (file-exists-p dape-default-breakpoints-file))
    (run-with-idle-timer 2 nil #'gdev-debug--restore-breakpoints)))

;; Dopo le funzioni qui sopra: se dape è già caricato (gdev sync lo carica
;; per compilare questo file), :config parte subito e le chiama.
(use-package dape
  :ensure t
  :commands (dape dape-pause dape-continue dape-next dape-step-in dape-step-out
             dape-restart dape-restart-frame dape-until dape-info dape-repl
             dape-memory dape-disassemble dape-breakpoint-log dape-breakpoint-expression
             dape-breakpoint-hits dape-breakpoint-function dape-breakpoint-toggle
             dape-breakpoint-remove-all dape-select-thread dape-select-stack
             dape-stack-select-up dape-stack-select-down dape-evaluate-expression
             dape-watch-dwim dape-kill dape-quit)
  :custom
  (dape-buffer-window-arrangement (unless gdev-layout-mode 'right))
  (dape-inlay-hints t)                  ; valori delle variabili nel codice
  (dape-key-prefix nil)                 ; i tasti stanno sotto C-c d
  (dape-cwd-function #'gdev-project-root)
  :config
  (add-to-list 'dape-default-config-functions #'gdev-debug--add-workspace t)
  (add-hook 'dape-update-ui-hook #'gdev-debug--refresh-workbench 90)
  (add-hook 'dape-state-change-hook #'gdev-debug--refresh-workbench 90)
  (add-hook 'dape-state-change-hook #'gdev-debug--track-operation)
  (add-hook 'dape-active-mode-hook #'gdev-debug--refresh-workbench 90)
  (cl-defmethod dape-handle-event :after (connection (_event (eql process)) body)
    (gdev-debug--remember-target connection body)
    (gdev-debug--refresh-workbench))
  (cl-defmethod dape-handle-event :after (connection (_event (eql exited)) body)
    (gdev-debug--record-exit connection body)
    (when (eq connection (dape--root-of connection))
      (gdev-debug--finish-operation connection (plist-get body :exitCode)))
    (gdev-debug--refresh-workbench))
  (when gdev-layout-mode
    (remove-hook 'dape-start-hook #'dape-info)
    (setq dape-info-buffer-window-groups
          (list (apply #'append dape-info-buffer-window-groups))))
  ;; Un clic sul bordo laterale mette un punto di interruzione in ogni buffer.
  (unless (bound-and-true-p dape-breakpoint-global-mode)
    (dape-breakpoint-global-mode 1))
  ;; I punti di interruzione sopravvivono ai riavvii.
  (dape-breakpoint-load)
  (add-hook 'kill-emacs-hook #'dape-breakpoint-save)
  ;; Le configurazioni per M-x dape (e C-c d d) vengono prima di quelle di dape.
  (dolist (config (reverse (gdev-debug--configs)))
    (setf (alist-get (car config) dape-configs) (cdr config))))

(add-hook 'emacs-startup-hook #'gdev-debug--start-breakpoint-controls)

;;;; GDB tramite GUD (Linux, i BSD)

(setq gdb-many-windows (not gdev-layout-mode)
      gdb-show-main t
      gdb-debuginfod-enable-setting nil) ; mai scaricare simboli di nascosto

;;; config.el ends here
