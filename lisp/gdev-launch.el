;;; gdev-launch.el --- Profili delle operazioni di progetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Il profilo del progetto appartiene allo spazio di lavoro. I comandi
;; dell'editor e del riquadro usano la stessa selezione e lo stesso avvio.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'gdev-lib)
(require 'gdev-compilation)
(require 'gdev-layout)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)
(require 'gdev-xcode)
(require 'gdev-project-operations)

(declare-function gdev-python--interpreter "../modules/lang/python/config" (root))
(declare-function gdev-debug-launch-profile "../modules/tools/debugger/config"
                  (options root directory environment))

(defcustom gdev-launch-profiles nil
  "Profili di progetto, nella forma (RADICE (NOME OPZIONI...) ...).
Le fasi :configure, :build, :test, :run e :clean accettano liste
(PROGRAMMA ARGOMENTO...).  :cwd è relativa a RADICE, :env è una lista
di assegnamenti NOME=VALORE.  :build-before elenca le fasi run e debug
che devono attendere una compilazione riuscita.
:debug accetta :adapter, :program, :args, :options (campi DAP),
:adapter-command, :adapter-env, :port, :host e :exception-filters.
:source-map è una coppia (REMOTA LOCALE) di cartelle sorgenti.
REMOTA è assoluta e LOCALE può essere relativa a RADICE.
È valida anche la forma (NOME PROGRAMMA ARGS [AMBIENTE ADATTATORE])."
  :type '(repeat (cons directory (repeat sexp)))
  :group 'gdev)

(defconst gdev-launch--phases
  gdev-project-operation-phases)

(defvar gdev-launch-selection-change-hook nil
  "Hook eseguito dopo aver scelto un profilo nello spazio corrente.")

(defvar gdev-launch--standalone-selections nil
  "Profili per radice quando la gestione degli spazi è disattivata.")

(defvar gdev-launch-arguments-history nil)

(defvar gdev-launch--native-profiles (make-hash-table :test #'equal)
  "Profili automatici locali per radice; non modifica le scelte personali.")

(defvar gdev-launch--project-profiles (make-hash-table :test #'equal)
  "Profili dichiarati dai progetti e verificati durante apertura o azioni.")

(defun gdev-launch--personal-profiles (root)
  "Leggi i profili personali di ROOT."
  (let ((directory (gdev-launch--directory root)))
    (cdr (seq-find (lambda (entry) (equal directory (gdev-launch--directory (car entry)))) gdev-launch-profiles))))

(defun gdev-launch--configured-profiles (root)
  "Profili effettivi di ROOT: scelta personale, poi dichiarazione del progetto."
  (or (gdev-launch--personal-profiles root)
      (plist-get (gethash (gdev-launch--directory root) gdev-launch--project-profiles) :profiles)))

(defun gdev-launch-refresh-native-profile (&optional directory)
  "Rileggi i metadati del progetto di DIRECTORY durante un'azione o apertura.
Le viste leggono l'indice in memoria, senza scansioni o processi esterni."
  (let* ((directory (or directory default-directory))
         (project (gdev-project-root directory))
         (boundary (or (gdev-workspace-root-for directory (gdev-workspace-roots))
                       (unless (equal project (gdev-launch--directory directory)) project)))
         (root (gdev-project-operation-root directory boundary))
         (previous (gdev-launch-profiles-for root))
         (old-root (gdev-launch-profile-root directory))
         ;; Anche la rimozione dell'unico manifesto può cambiare la radice.
         (_ (when (and old-root (not (equal old-root root))
                       (string-prefix-p old-root (gdev-launch--directory directory)))
              (remhash old-root gdev-launch--project-profiles)
              (remhash old-root gdev-launch--native-profiles)))
         ;; Togli le osservazioni precedenti prima di validare il nuovo file.
         (_ (remhash root gdev-launch--project-profiles))
         (_ (remhash root gdev-launch--native-profiles))
         (declared (unless (gdev-launch--personal-profiles root)
                     (gdev-project-operations-read root #'gdev-launch--options)))
         (_ (when declared (puthash root declared gdev-launch--project-profiles)))
         (profile (and (not (gdev-launch--configured-profiles root)) (gdev-xcode-profile root))))
    (if profile (puthash root (list profile) gdev-launch--native-profiles)
      (remhash root gdev-launch--native-profiles))
    (unless (equal previous (gdev-launch-profiles-for root))
      (run-hooks 'gdev-launch-selection-change-hook))
    (and (or profile declared) root)))

(defun gdev-launch--file-opened ()
  "Prepara il profilo del documento senza avviare programmi."
  (condition-case nil (gdev-launch-refresh-native-profile) (error nil)))

(add-hook 'find-file-hook #'gdev-launch--file-opened 85)

(defun gdev-launch--directory (directory)
  "Rendi DIRECTORY assoluta con un separatore finale."
  (file-name-as-directory (expand-file-name directory)))

(defun gdev-launch-profiles-for (root)
  "Restituisci i profili configurati per ROOT."
  (when root
    (or (gdev-launch--configured-profiles root)
        (gethash (gdev-launch--directory root) gdev-launch--native-profiles))))

(defun gdev-launch-profile-root (&optional directory)
  "Trova la radice con profili più vicina a DIRECTORY o allo spazio."
  (let ((directory (or directory (gdev-default-directory))))
    (or (gdev-workspace-root-for
         directory (append (mapcar (lambda (entry) (gdev-launch--directory (car entry))) gdev-launch-profiles)
                           (hash-table-keys gdev-launch--project-profiles)))
        (gdev-workspace-root-for directory (hash-table-keys gdev-launch--native-profiles))
        (when gdev-layout-mode
          (let ((workspace (gdev-workspace-directory directory)))
            (and (gdev-launch-profiles-for workspace) workspace))))))

(defun gdev-launch-selected (root)
  "Restituisci la voce del profilo selezionato per ROOT."
  (when root
    (let ((choices (if gdev-layout-mode
                       (gdev-workspace-state-get 'gdev-launch-selections)
                     gdev-launch--standalone-selections)))
      (or (when-let* ((name (alist-get root choices nil nil #'equal)))
            (assoc name (gdev-launch-profiles-for root)))
          (unless (gdev-launch--personal-profiles root)
            (let* ((declared (gethash root gdev-launch--project-profiles))
                   (default (plist-get declared :default)))
              (assoc default (plist-get declared :profiles))))
          (unless (gdev-launch--configured-profiles root)
            (car (gethash (gdev-launch--directory root) gdev-launch--native-profiles)))))))

(defun gdev-launch--strings-p (value)
  "Verifica che VALUE sia una lista di argomenti utilizzabili."
  (and (proper-list-p value)
       (seq-every-p (lambda (arg) (and (stringp arg) (not (string-search "\0" arg))))
                    value)))

(defun gdev-launch--argv-p (value)
  "Verifica che VALUE contenga un programma e i suoi argomenti."
  (and (consp value) (gdev-launch--strings-p value) (not (string-empty-p (car value)))))

(defun gdev-launch--check-plist (options keys name)
  "Valida OPTIONS con le chiavi KEYS e indica NAME negli errori.
Con KEYS uguale a t accetta tutte le chiavi di tipo keyword."
  (unless (and (proper-list-p options) (cl-evenp (length options)))
    (user-error "Profilo «%s»: usa coppie opzione e valore" name))
  (let (seen)
    (cl-loop for (key) on options by #'cddr
             unless (and (keywordp key) (or (eq keys t) (memq key keys))
                         (not (memq key seen)))
             do (user-error "Profilo «%s»: chiave sconosciuta o ripetuta %S" name key)
             do (push key seen))))

(defun gdev-launch--check-environment (value name key)
  "Valida gli assegnamenti VALUE per KEY nel profilo NAME."
  (unless (and (gdev-launch--strings-p value)
               (seq-every-p (lambda (entry)
                              (string-match-p "\\`[A-Za-z_][A-Za-z_0-9]*=" entry))
                            value))
    (user-error "Profilo «%s»: usa una lista di stringhe NOME=VALORE in %s" name key)))

(defun gdev-launch--check-debug (debug name)
  "Valida le opzioni DEBUG del profilo NAME."
  (gdev-launch--check-plist
   debug '(:adapter :program :args :options :adapter-command :adapter-env
                    :port :host :exception-filters :source-map) name)
  (gdev-launch--check-plist (plist-get debug :options) t name)
  (let ((adapter (plist-get debug :adapter))
        (program (plist-get debug :program))
        (options (plist-get debug :options))
        (port (plist-get debug :port))
        (host (plist-get debug :host)))
    (unless (memq adapter '(nil lldb delve debugpy netcoredbg perl custom))
      (user-error "Profilo «%s»: adattatore sconosciuto %S" name adapter))
    (unless (or (and (stringp program) (not (string-empty-p program))
                     (gdev-launch--strings-p (list program)))
                (and (null program)
                     (or (eq adapter 'custom)
                         (equal (plist-get options :request) "attach"))))
      (user-error "Profilo «%s»: indica un percorso in :debug :program" name))
    (when (eq adapter 'custom)
      (unless (and (or (and (integerp port) (> port 0)) (plist-get debug :adapter-command))
                   (gdev-launch--argv-p (list (plist-get options :type)))
                   (member (plist-get options :request) '("launch" "attach")))
        (user-error "Profilo «%s»: indica trasporto, :type e :request per il debug" name)))
    (unless (or (null port) (eq port :autoport)
                (and (integerp port) (<= 1 port 65535)))
      (user-error "Profilo «%s»: usa una porta tra 1 e 65535 o :autoport" name))
    (unless (or (null host) (and (gdev-launch--argv-p (list host)) port))
      (user-error "Profilo «%s»: :host richiede una porta" name)))
  (dolist (key '(:args :exception-filters))
    (unless (gdev-launch--strings-p (plist-get debug key))
      (user-error "Profilo «%s»: usa una lista di stringhe in %s" name key)))
  (when-let* ((argv (plist-get debug :adapter-command)))
    (unless (gdev-launch--argv-p argv)
      (user-error "Profilo «%s»: :adapter-command richiede un programma e argomenti" name)))
  (when-let* ((directories (plist-get debug :source-map)))
    (unless (and (gdev-launch--strings-p directories)
                 (= (length directories) 2)
                 (string-prefix-p "/" (car directories))
                 (not (file-remote-p (car directories)))
                 (not (string-empty-p (cadr directories))))
      (user-error "Profilo «%s»: in :source-map indica la cartella remota assoluta e quella locale" name)))
  (gdev-launch--check-environment (plist-get debug :adapter-env) name :adapter-env))

(defun gdev-launch--legacy (profile root)
  "Converti il PROFILE posizionale, relativo a ROOT."
  (let ((name (car profile))
        (file (nth 1 profile))
        (args (nth 2 profile))
        (env (nth 3 profile))
        (adapter (nth 4 profile)))
    (unless (and (<= 3 (length profile) 5) (stringp file) (gdev-launch--strings-p args))
      (user-error "Profilo «%s»: usa la forma (NOME PROGRAMMA ARGOMENTI ...)" name))
    (list :env env :legacy t :debug (list :adapter adapter :program file :args args)
          :cwd root)))

(defun gdev-launch--options (profile root)
  "Restituisci le opzioni convalidate per PROFILE in ROOT."
  (unless (and (proper-list-p profile) (stringp (car-safe profile)) (cdr profile))
    (user-error "Profilo di progetto non valido in %s" root))
  (let* ((name (car profile))
         (legacy (stringp (cadr profile)))
         (options (if legacy (gdev-launch--legacy profile root) (cdr profile)))
         (cwd (plist-get options :cwd))
         (before (plist-get options :build-before)))
    (unless legacy
      (gdev-launch--check-plist
       options (append '(:cwd :env :build-before) (mapcar #'cdr gdev-launch--phases)) name))
    (unless (or (null cwd) (gdev-launch--argv-p (list cwd)))
      (user-error "Profilo «%s»: usa un percorso in :cwd" name))
    (gdev-launch--check-environment (plist-get options :env) name :env)
    (dolist (phase '(:configure :build :run :test :clean))
      (when (and (plist-member options phase)
                 (not (gdev-launch--argv-p (plist-get options phase))))
        (user-error "Profilo «%s»: %s richiede un programma e argomenti" name phase)))
    (when-let* ((debug (plist-get options :debug)))
      (gdev-launch--check-debug debug name))
    (unless (and (proper-list-p before)
                 (or (null before)
                     (and (plist-get options :build)
                          (seq-every-p (lambda (phase)
                                         (and (memq phase '(run debug))
                                              (plist-get options
                                                         (alist-get phase gdev-launch--phases))))
                                       before))))
      (user-error "Profilo «%s»: :build-before richiede :build e le fasi run o debug" name))
    options))

(defun gdev-launch-select-profile (&optional root)
  "Scegli il profilo di ROOT nello spazio corrente."
  (interactive
   (list (when-let* ((editor (and gdev-layout-mode (gdev-layout-editor))))
           (with-current-buffer (window-buffer editor) (gdev-launch-profile-root)))))
  (unless (and root (gdev-launch--personal-profiles root))
    (gdev-launch-refresh-native-profile (or root (gdev-default-directory))))
  (let* ((root (or root (gdev-launch-profile-root)))
         (profiles (gdev-launch-profiles-for root))
         (automatic "Automatico"))
    (unless profiles
      (user-error "Aggiungi i profili del progetto a gdev-launch-profiles"))
    (while (assoc automatic profiles) (setq automatic (concat "[" automatic "]")))
    (let* ((selection (completing-read "Profilo di avvio: " (cons automatic (mapcar #'car profiles))
                                       nil t nil nil (or (car (gdev-launch-selected root)) automatic)))
           (profile (assoc selection profiles))
           (choices (if gdev-layout-mode
                        (gdev-workspace-state-get 'gdev-launch-selections)
                      gdev-launch--standalone-selections)))
      (when profile (gdev-launch--options profile root))
      ;; Le schede duplicate possono condividere la lista fino alla prima modifica.
      (setq choices (assoc-delete-all root (copy-sequence choices)))
      (when profile (push (cons root selection) choices))
      (if gdev-layout-mode
          (gdev-workspace-state-set 'gdev-launch-selections choices)
        (setq gdev-launch--standalone-selections choices))
      (run-hooks 'gdev-launch-selection-change-hook)
      profile)))

(cl-defun gdev-launch--start (argv directory environment &key name scope build profile)
  "Esegui ARGV in DIRECTORY con ENVIRONMENT e mostra il pannello NAME.
NAME identifica un programma interattivo. SCOPE riserva la risorsa della
compilazione. Con BUILD ricorda il piano di compilazione del PROFILE."
  (when name (gdev-compilation-check-idle name))
  (let* ((default-directory directory)
         (compilation-environment (append environment compilation-environment))
         (path (seq-find (lambda (var) (string-prefix-p "PATH=" var)) compilation-environment))
         (exec-path (if path (parse-colon-path (substring path 5)) exec-path))
         (program (car argv)))
    (unless (or (file-remote-p directory)
                (if (file-name-directory program)
                    (and (file-regular-p program) (file-executable-p program))
                  (executable-find program)))
      (user-error "Strumento non disponibile: %s" program))
    (let ((command (gdev-command-line program (cdr argv))))
      (if scope
          (gdev-build-start command directory scope build profile)
        (gdev-compile command name directory t)))))

(defun gdev-launch--pending (_previous _selected)
  "Esegui i seguiti di compilazione nello spazio appena selezionato."
  (when-let* ((pending (gdev-workspace-state-get 'gdev-launch-pending)))
    (gdev-workspace-state-set 'gdev-launch-pending nil)
    (mapc #'funcall (reverse pending))))

(add-hook 'tab-bar-tab-post-select-functions #'gdev-launch--pending 90)

(defun gdev-launch--in-workspace (frame owner callback)
  "Esegui CALLBACK quando lo spazio OWNER di FRAME è visibile.
Scarta il seguito se lo spazio è stato chiuso."
  (if (and (frame-live-p frame)
           (or (not owner) (eq owner (gdev-workspace-state-id frame))))
      (with-selected-frame frame (funcall callback))
    (if-let* (((frame-live-p frame))
              (tab (gdev-workspace-state-find owner frame)))
        (progn
          (gdev-workspace-state-set
           'gdev-launch-pending
           (cons callback (gdev-workspace-state-read 'gdev-launch-pending tab))
           tab)
          (message "Compilazione completata. L'avvio riprenderà nello spazio di origine"))
      (message "Compilazione completata. Avvio annullato: lo spazio di origine è stato chiuso"))))

(defun gdev-launch--build-before (argv root directory environment next profile)
  "Compila con ARGV per ROOT in DIRECTORY, poi esegui NEXT se riesce.
ENVIRONMENT contiene gli assegnamenti delle due fasi."
  (let* ((frame (selected-frame))
         (owner (and gdev-layout-mode (gdev-workspace-state-ensure-id)))
         (source (current-buffer))
         starts
         (output (let ((compilation-start-hook
                        (cons (lambda (started) (push (cons (process-buffer started) started) starts))
                              compilation-start-hook)))
                   (gdev-launch--start argv directory environment
                                       :scope (gdev-build-scope root nil) :build t :profile profile)))
         ;; Un hook può avviare un altro processo durante la compilazione.
         (process (cdr (assq output (nreverse starts)))))
    (unless process (user-error "La compilazione non ha avviato un processo"))
    (gdev-compilation-on-finish
     output
     (lambda (_buffer)
       (when (gdev-compilation-succeeded-p process)
         (gdev-launch--in-workspace
          frame owner
          (lambda ()
            (condition-case err
                (if (buffer-live-p source)
                    (with-current-buffer source (funcall next))
                  (with-temp-buffer (funcall next)))
              (error (message "%s" (error-message-string err)))))))))
    output))

(defun gdev-launch-program (path directory &optional executable)
  "Convalida PATH in DIRECTORY e restituisci il nome sul sistema di lancio.
Con EXECUTABLE richiedi anche il permesso di esecuzione."
  (let ((file (expand-file-name path directory)))
    (unless (and (file-regular-p file)
                 (if executable (file-executable-p file) (file-readable-p file)))
      (user-error "Programma non disponibile: %s" file))
    (file-local-name file)))

(defun gdev-launch--legacy-run (debug directory args)
  "Costruisci il comando storico da DEBUG, DIRECTORY e ARGS."
  (let* ((adapter (plist-get debug :adapter))
         (program (gdev-launch-program (plist-get debug :program) directory
                                       (not (memq adapter '(debugpy netcoredbg perl))))))
    (append (pcase adapter
              ('debugpy
               (unless (fboundp 'gdev-python--interpreter) (user-error "Attiva il modulo Python"))
               (list (gdev-python--interpreter directory) program))
              ('netcoredbg (list "dotnet" program))
              ('perl (list "perl" "-Ilib" program))
              (_ (list program)))
            args)))

(defun gdev-launch--read-arguments (argv)
  "Leggi gli argomenti per una sola operazione, a partire da ARGV."
  (let* ((print-escape-newlines t)
         (input (read-string "Argomenti per questa operazione: "
                             (mapconcat #'prin1-to-string argv " ")
                             'gdev-launch-arguments-history))
         (arguments (condition-case nil (gdev-shell-split input)
                      (end-of-file (user-error "Chiudi le virgolette negli argomenti")))))
    (unless (gdev-launch--strings-p arguments)
      (user-error "Gli argomenti devono essere stringhe senza caratteri nulli"))
    arguments))

(defun gdev-launch-dispatch (phase &optional ask-options)
  "Esegui PHASE del profilo attivo e restituisci un valore non nil.
Con ASK-OPTIONS modifica gli argomenti per questa operazione."
  (let ((current (gdev-launch-profile-root)))
    (unless (and current (gdev-launch--personal-profiles current))
      (gdev-launch-refresh-native-profile (gdev-default-directory))))
  (when-let* ((root (gdev-launch-profile-root))
              ((gdev-launch-profiles-for root))
              ((not (gdev-launch-selected root))))
    (gdev-launch-select-profile root))
  (when-let* ((root (gdev-launch-profile-root))
              (profile (gdev-launch-selected root)))
    (let* ((options (gdev-launch--options profile root))
           (legacy-run (and (eq phase 'run) (plist-get options :legacy)))
           (command (plist-get options (alist-get phase gdev-launch--phases)))
           (debug (plist-get options :debug)))
      (when (and (not (or command legacy-run))
                 (not (gdev-launch--configured-profiles root))
                 (gethash root gdev-launch--native-profiles))
        (user-error "Lo schema «%s» non dichiara l'operazione %s" (car profile) phase))
      (when (or command legacy-run)
        (gdev-use-project-tools root)
        (gdev-require-project-environment)
        (let* ((directory (gdev-launch--directory
                           (expand-file-name (or (plist-get options :cwd) ".") root)))
               (environment (plist-get options :env))
               (debugging (eq phase 'debug))
               (argv (if (or legacy-run debugging) (plist-get debug :args) (cdr command)))
               (input (eq phase 'run))
               (name (when input
                       (format "Esecuzione · %s · %s" (car profile)
                               (abbreviate-file-name (directory-file-name root))))))
          (unless (file-directory-p directory)
            (user-error "Cartella del profilo non disponibile: %s" directory))
          (when (and ask-options
                     (not (and debugging (equal (plist-get (plist-get debug :options) :request)
						"attach"))))
            (setq argv (gdev-launch--read-arguments argv))
            (when debugging
              (setq debug (plist-put (copy-sequence debug) :args argv))))
          (let ((start (lambda ()
                         (if debugging
                             (progn
                               (unless (fboundp 'gdev-debug-launch-profile)
                                 (user-error "Attiva il modulo debugger"))
                               (gdev-debug-launch-profile debug root directory environment))
                           (gdev-launch--start
                            (if legacy-run (gdev-launch--legacy-run debug directory argv)
                              (cons (car command) argv))
                            directory environment :name name
                            :scope (and (not input) (gdev-build-scope root nil))
                            :build (eq phase 'build) :profile (car profile))))))
            (when (eq phase 'configure)
              (setq start (apply-partially #'gdev-compilation-configure root start)))
            (when input (gdev-compilation-check-idle name))
            (if (memq phase (plist-get options :build-before))
                (gdev-launch--build-before (plist-get options :build) root directory environment
                                           start (car profile))
              (funcall start)))
          t)))))

(provide 'gdev-launch)
;;; gdev-launch.el ends here
