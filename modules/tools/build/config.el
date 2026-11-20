;;; config.el --- :tools build: configura, compila, testa ed esegui ogni progetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un solo punto di accesso alla compilazione: riconosce il sistema
;; di compilazione del progetto ed esegue il comando giusto in un'area di
;; testo di compilazione, dove gli errori sono collegamenti:
;;
;;   C-c p C  S-F7   configura   (preimpostazioni CMake o cartella Ninja)
;;   C-c p c  F7     compila     (C-u: scegli un obiettivo o modifica gli argomenti)
;;   C-c p T         tutti i test (ctest, prove, make test, deno test...)
;;   C-c p t  F6     testa il file aperto, altrimenti tutti i test
;;   C-c p r  C-F5   esegui il programma aperto, o uno compilato
;;   C-c p g         ricompila con l'ultimo comando
;;
;; Riconosce i progetti CMake, Meson, Ninja, Make, Perl (Makefile.PL, Build.PL, prove),
;; ASDF (Common Lisp), Deno e package.json. Le scelte restano memorizzate per
;; progetto: preimpostazione, tipo di compilazione, obiettivo, argomenti del
;; programma. I moduli dei linguaggi indicano come eseguire e testare un file
;; con `gdev-set-runner'.

;;; Code:

(require 'gdev-lib)
(require 'gdev-state-db)
(require 'gdev-project-types)
(require 'gdev-handlers)
(require 'gdev-compilation)
(require 'gdev-launch)
(require 'gdev-layout)
(require 'gdev-workspace-roots)
(require 'gdev-commands)
(require 'gdev-auto-modules)
(require 'compile)
(require 'json)

(declare-function gdev-python-project-command "../../lang/python/config")
(declare-function gdev-make-command "gdev-make" (root action &optional goal))
(declare-function gdev-make-inspect "gdev-make" (root))
(declare-function gdev-make-configure "gdev-make" (root))
(declare-function gdev-project-control-compilation-finished "gdev-project-control" (buffer status))
(let ((library (gdev-config-file "modules/tools/build/gdev-make")))
  (autoload 'gdev-make-command library)
  (autoload 'gdev-make-inspect library)
  (autoload 'gdev-make-configure library))
(let ((library (gdev-config-file "modules/tools/build/gdev-project-control")))
  (autoload 'gdev-project-control-show library nil t)
  (autoload 'gdev-project-control-compilation-finished library))
(add-hook 'compilation-finish-functions #'gdev-project-control-compilation-finished)
(defvar project-kill-buffers-display-buffer-list)
(defvar project-switch-commands)
(defvar savehist-additional-variables)

;;;; project.el

(setq project-kill-buffers-display-buffer-list t
      project-switch-commands
      '((project-find-file "File" ?f)
        (consult-ripgrep "Cerca" ?g)
        (gdev-project-open-folder "Esplora file" ?d)
        (magit-project-status "Hit" ?m)
        (gdev-term-project "Terminale" ?t)
        (gdev-eshell-project "Interprete Lisp" ?e)
        (gdev-build "Compila" ?b)
        (claude-code-ide "Claude Code" ?a)))

;;;; Buffer di compilazione

(setq compilation-scroll-output 'first-error
      compilation-always-kill t
      compilation-ask-about-save nil    ; salva i buffer senza chiedere
      compilation-skip-threshold 1      ; next-error salta le righe informative
      compilation-max-output-line-length 2000)

;; I colori di compilatori, esecutori di test e analizzatori (sanitizer).
(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)

(defun gdev-build--exit-label (status code detail)
  "Restituisce il messaggio e il codice da mostrare per STATUS e CODE."
  (cons (pcase status
          ('exit (if (zerop code) "completata\n" (format "terminata con codice %d\n" code)))
          ('signal (format "interrotta dal segnale %d\n" code))
          (_ detail))
        code))

(defvar gdev-build--default-exit-message-function compilation-exit-message-function)

(defun gdev-build--configure-output ()
  "Usa etichette italiane nell'area di compilazione."
  (when (eq major-mode 'compilation-mode)
    (when (equal mode-name "Compilation") (setq-local mode-name "Compilazione"))
    (when (eq compilation-exit-message-function gdev-build--default-exit-message-function)
      (setq-local compilation-exit-message-function #'gdev-build--exit-label))))

(add-hook 'compilation-mode-hook #'gdev-build--configure-output 80)

;; compile.el scrive in inglese l'avvio («started at …») e la fine («at …, duration …»).
(defconst gdev-build--weekdays ["dom" "lun" "mar" "mer" "gio" "ven" "sab"]
  "Giorni della settimana abbreviati, indipendenti dalla lingua del sistema.")

(defconst gdev-build--months
  ["gen" "feb" "mar" "apr" "mag" "giu" "lug" "ago" "set" "ott" "nov" "dic"]
  "Mesi abbreviati, indipendenti dalla lingua del sistema.")

(defun gdev-build--time-label (&optional time)
  "Data e ora di TIME come «lun 17 nov 12:00:00», in italiano."
  (let ((parts (decode-time time)))
    (format "%s %d %s %02d:%02d:%02d"
            (aref gdev-build--weekdays (decoded-time-weekday parts))
            (decoded-time-day parts)
            (aref gdev-build--months (1- (decoded-time-month parts)))
            (decoded-time-hour parts) (decoded-time-minute parts) (decoded-time-second parts))))

(defun gdev-build--translate-annotation (arguments)
  "Traduce in italiano le annotazioni di avvio e di fine che compile.el inserisce.
ARGUMENTS sono quelli di `compilation-insert-annotation'."
  (mapcar (lambda (argument)
            (cond
             ((not (stringp argument)) argument)
             ((string-match "\\`\\(.+\\) started at [A-Z][a-z]\\{2\\} [A-Z][a-z]\\{2\\} [ 0-9]+ [0-9:]\\{8\\}\n\n\\'"
                            argument)
              (format "%s avviata il %s\n\n" (match-string 1 argument) (gdev-build--time-label)))
             ((equal argument " at ") " il ")
             ((equal argument ", duration ") ", durata ")
             ((string-match-p "\\`[A-Z][a-z]\\{2\\} [A-Z][a-z]\\{2\\} [ 0-9]+ [0-9:]\\{8\\}\\'" argument)
              (gdev-build--time-label))
             ((string-match-p "\\`[0-9]+\\.[0-9]+ s\\'" argument)
              (string-replace "." "," argument))
             (t argument)))
          arguments))

(advice-add 'compilation-insert-annotation :filter-args #'gdev-build--translate-annotation)

;; Formati di errore in più, perché le posizioni stampate siano cliccabili.
(with-eval-after-load 'compile
  (dolist (entry
           '(;; GoogleTest:    path/file.cpp:42: Failure
             (gdev-gtest "^\\([^ \n:]+\\):\\([0-9]+\\): Failure$" 1 2)
             ;; Catch2:        path/file.cpp:42: FAILED:
             (gdev-catch2 "^\\([^ \n:]+\\):\\([0-9]+\\): FAILED:" 1 2)
             ;; Analizzatori:  #3 0x10f in func /abs/path/file.cpp:42:7
             (gdev-sanitizer "^ *#[0-9]+ 0x[0-9a-f]+ in .* \\(/[^ :\n]+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?$" 1 2 3 0)))
    (add-to-list 'compilation-error-regexp-alist-alist entry)
    (add-to-list 'compilation-error-regexp-alist (car entry))))

;; Se una compilazione lunga finisce con Emacs in secondo piano, avvisa macOS.
(defun gdev-build--notify (buffer status)
  "Invia una notifica macOS quando BUFFER finisce con STATUS, se serve."
  (when (and gdev-macos-p
             (not (frame-focus-state (selected-frame)))
             (with-current-buffer buffer
               (> (float-time (time-since (or (bound-and-true-p gdev-build--started-at)
                                              (current-time))))
                  10)))
    (let* ((tool (executable-find "osascript"))
           (process (get-buffer-process buffer))
           (label (if process
                      (car (gdev-build--exit-label (process-status process) (process-exit-status process) status))
                    status)))
      (when tool
        (ignore-errors
          (make-process :name "gdev-notifica" :noquery t :connection-type 'pipe :buffer nil
                        :command (list tool "-e"
                                       (format "display notification %S with title %S"
                                               (string-trim label) (buffer-name buffer)))))))))
(defvar-local gdev-build--started-at nil
  "Momento in cui è iniziata la compilazione in quest'area di testo.")
(add-hook 'compilation-start-hook
          (lambda (_process) (setq gdev-build--started-at (current-time))))
(add-hook 'compilation-finish-functions #'gdev-build--notify)

;;;; Attività del progetto

(defcustom gdev-project-tasks nil
  "Attività richiamabili per nome con `gdev-run-project-task'.
Ogni elemento ha la forma (RADICE (NOME . COMANDO) ...).
Imposta le attività nel config.el privato."
  :type '(alist :key-type directory
                :value-type (alist :key-type string :value-type string))
  :group 'gdev)

(defvar gdev-project-task-history nil)

(defun gdev-build-configured-tasks (root)
  "Leggi le attività personali di ROOT senza interrogare programmi."
  (copy-tree
                (cdr (seq-find (lambda (entry)
                                 (equal (expand-file-name (file-name-as-directory (car entry))) root))
                               gdev-project-tasks))))

(defun gdev-build-project-tasks (root)
  "Leggi le attività personali e quelle dichiarate dal motore di ROOT.
Una voce personale con lo stesso nome conserva la precedenza. Make
viene interrogato qui, durante una richiesta, mai nel ridisegno."
  (let ((tasks (gdev-build-configured-tasks root)))
    (when (and (file-directory-p root) (eq (gdev-build-system root) 'make))
      (dolist (target (plist-get (gdev-make-inspect root) :targets))
        (unless (assoc target tasks)
          (setq tasks (append tasks (list (cons target (gdev-make-command root 'build target))))))))
    tasks))

(defun gdev-run-project-task (&optional repeat)
  "Scegli un'attività configurata ed eseguila nel pannello del progetto.
Con REPEAT usa l'ultima attività eseguita in questo progetto."
  (interactive)
  (let* ((editor (gdev-layout-editor))
         (directory (or (gdev-workspace-directory)
                        (and editor (buffer-local-value 'default-directory (window-buffer editor)))
                        default-directory))
         (root (gdev-project-operation-root directory
                                            (unless (equal (gdev-project-root directory) directory)
                                              (gdev-project-root directory))))
         (key (file-name-as-directory (abbreviate-file-name root)))
         (tasks (gdev-build-project-tasks root)))
    (unless tasks
      (user-error "Nessuna attività rilevata in %s. Usa Configura compilazione o le Preferenze del progetto" key))
    (let* ((last (gdev-build--get :last-task root))
           (name (if repeat
                     (or last (user-error "Scegli prima un'attività in questo progetto"))
                   (completing-read "Esegui attività: " tasks nil t nil 'gdev-project-task-history
                                    (and (assoc last tasks) last))))
           (command (cdr (assoc name tasks)))
           (output (format "%s · %s" name key)))
      (unless command
        (user-error (if repeat "L'ultima attività non è più configurata: %s"
                      "Scegli un'attività del progetto: %s") name))
      (when (process-live-p (get-buffer-process (format "*%s*" output)))
        (user-error "L'attività «%s» è già in esecuzione" name))
      (prog1 (gdev-build-compile command output root (gdev-build-scope root nil))
        (gdev-build--put :last-task name root)))))

(defun gdev-repeat-project-task ()
  "Esegui di nuovo l'ultima attività di questo progetto."
  (interactive)
  (gdev-run-project-task t))

;;;; Impostazioni per progetto, ricordate tra un riavvio e l'altro

(defvar gdev-build-settings nil
  "Alist: radice del progetto -> plist delle scelte (:preset :type :target...).")

(defun gdev-build--import-settings ()
  "Importa le scelte di compilazione caricate dalla vecchia cronologia."
  (when gdev-build-settings
    (gdev-state-db-with (_db t)
      (unless (gdev-state-db-entries "migrazione" "" "compilazione")
        (pcase-dolist (`(,root . ,options) gdev-build-settings)
          (cl-loop for (key value) on options by #'cddr
                   unless (gdev-state-db-entries "compilazione" root (symbol-name key))
                   do (gdev-state-db-set "compilazione" root (symbol-name key) value)))
        (gdev-state-db-set "migrazione" "" "compilazione" t)))
    (setq gdev-build-settings nil)))

(defun gdev-build--get (key &optional root)
  "Restituisce l'impostazione KEY per ROOT (predefinito: il progetto corrente)."
  (gdev-build--import-settings)
  (cdar (gdev-state-db-entries "compilazione" (or root (gdev-project-root)) (symbol-name key))))

(defun gdev-build--put (key value &optional root)
  "Memorizza subito l'impostazione KEY = VALUE per ROOT."
  (gdev-build--import-settings)
  (gdev-state-db-set "compilazione" (or root (gdev-project-root)) (symbol-name key) value))

;;;; Riconoscere il sistema di compilazione

(defun gdev-build-system (&optional root)
  "Restituisce il sistema di compilazione del progetto in ROOT.
Il risultato è un simbolo, oppure nil."
  (gdev-project-build-system (or root (gdev-project-root)) (fboundp 'gdev-python-project-command)))

(defun gdev-build--jobs ()
  "Restituisce il numero di processi paralleli per compilazioni e test."
  (number-to-string (num-processors)))

;;;; CMake

(defgroup gdev-build nil
  "Compilazione, esecuzione, test."
  :group 'gdev)

(defun gdev-cmake--safe-build-directory-p (value)
  "Indica se VALUE è una cartella di compilazione relativa e dentro il progetto.
Un .dir-locals.el di un repository clonato non deve poter far scrivere CMake
in una cartella qualsiasi: niente percorsi assoluti, «~» né «..»."
  (and (stringp value)
       (not (string-empty-p value))
       (not (file-name-absolute-p value))
       (not (string-prefix-p "~" value))
       (not (member ".." (split-string value "/" t)))))

(defcustom gdev-cmake-build-directory "build"
  "Cartella di compilazione usata se il progetto non ha preimpostazioni CMake.
In \"build\" clangd trova compile_commands.json da solo."
  :type 'string
  :safe #'gdev-cmake--safe-build-directory-p)

(defcustom gdev-cmake-build-types '("Debug" "RelWithDebInfo" "Release" "MinSizeRel")
  "Tipi di compilazione CMake proposti da `gdev-build-set-type'."
  :type '(repeat string))

(defun gdev-cmake--preset-groups ()
  "Leggi le preimpostazioni raggruppate emesse da CMake."
  (let (groups section)
    (while (re-search-forward "^\\(?:Available \\([[:alpha:]]+\\) presets:\\| +\"\\([^\"]+\\)\"\\)" nil t)
      (if-let* ((heading (match-string-no-properties 1)))
          (progn
            (setq section heading)
            (unless (assoc section groups) (push (list section) groups)))
        (when section
          (push (match-string-no-properties 2) (alist-get section groups nil nil #'equal)))))
    (dolist (entry groups) (setcdr entry (nreverse (cdr entry))))
    groups))

(defun gdev-cmake--presets (kind &optional root report-errors)
  "Restituisce le preimpostazioni (preset) CMake del tipo KIND.
KIND è \"configure\", \"build\" o \"test\".
Con \"all\", restituisce un'associazione per tipo.
Con REPORT-ERRORS, mostra gli errori di CMake."
  (let ((default-directory (or root (gdev-project-root))))
    (when (gdev-project-file-exists-p default-directory
                                      "CMakePresets.json" "CMakeUserPresets.json")
      (with-temp-buffer
        (let ((status (condition-case err
                          (process-file "cmake" nil '(t t) nil (concat "--list-presets=" kind))
                        (file-missing (when report-errors (signal (car err) (cdr err)))))))
          (if (equal status 0)
              (progn
                (goto-char (point-min))
                (if (equal kind "all")
                    (gdev-cmake--preset-groups)
                  (cl-loop while (re-search-forward "^ +\"\\([^\"]+\\)\"" nil t)
                           collect (match-string 1))))
            (when report-errors (user-error "%s" (string-trim (buffer-string))))))))))

(defun gdev-cmake--json (file)
  "Leggi i dati JSON di FILE quando esiste."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'alist :array-type 'list))))

(defun gdev-cmake--expand (value root preset file &optional environment generator)
  "Espandi le macro di CMake in VALUE.
ENVIRONMENT e GENERATOR provengono dalla preimpostazione.
Restituisci nil quando una macro non è risolvibile."
  (let* ((source (directory-file-name (file-local-name root)))
         (macros (list (cons "sourceDir" source)
                       (cons "sourceParentDir" (directory-file-name (file-name-directory source)))
                       (cons "sourceDirName" (file-name-nondirectory source))
                       (cons "presetName" preset)
                       (cons "generator" (and preset (or generator "")))
                       (cons "fileDir" (directory-file-name (file-local-name (file-name-directory file))))
                       (cons "hostSystemName" (pcase system-type
                                               ('darwin "Darwin") ('gnu/linux "Linux")
                                               ('windows-nt "Windows")))
                       (cons "dollar" "$") (cons "pathListSep" path-separator))))
    (cl-labels
        ((expand-value (text visited)
           (replace-regexp-in-string
            "\\$\\([[:alpha:]]*\\){\\([^}]+\\)}"
            (lambda (match)
              (let ((namespace (match-string 1 match))
                    (name (match-string 2 match)))
                (pcase namespace
                  ("" (or (cdr (assoc name macros)) (throw 'unresolved nil)))
                  ("penv" (or (getenv name) ""))
                  ("env"
                   (when (member name visited) (throw 'unresolved nil))
                   (let ((setting (alist-get (intern-soft name) environment)))
                     (if (stringp setting)
                         (expand-value setting (cons name visited))
                       (or (getenv name) ""))))
                  (_ (throw 'unresolved nil)))))
            text t t)))
      (catch 'unresolved (expand-value value nil)))))

(defun gdev-cmake--preset-files (root)
  "Leggi i file delle preimpostazioni di ROOT e i relativi include."
  (let ((pending (list (expand-file-name "CMakeUserPresets.json" root)
                       (expand-file-name "CMakePresets.json" root)))
        seen files)
    (while pending
      (let ((file (pop pending)))
        (unless (member file seen)
          (push file seen)
          (when-let* ((data (gdev-cmake--json file)))
            (push (cons file data) files)
            (dolist (include (alist-get 'include data))
              (when-let* ((path (gdev-cmake--expand include root nil file)))
                (push (expand-file-name path (file-name-directory file)) pending)))))))
    (nreverse files)))

(defun gdev-cmake--entries (kind files)
  "Restituisci le preimpostazioni KIND presenti nei FILES."
  (let ((key (intern (concat kind "Presets"))))
    (cl-loop for (file . data) in files
             append (mapcar (lambda (entry) (cons (cons 'gdev-file file) entry))
                            (alist-get key data)))))

(defun gdev-cmake--entry (name entries)
  "Trova la preimpostazione NAME in ENTRIES."
  (seq-find (lambda (entry) (equal (alist-get 'name entry) name)) entries))

(defun gdev-cmake--field (key entry entries &optional seen)
  "Trova il campo KEY di ENTRY o del primo antenato che lo definisce."
  (when (and entry (not (memq entry seen)))
    (or (assq key entry)
        (cl-some (lambda (parent)
                   (gdev-cmake--field key (gdev-cmake--entry parent entries) entries (cons entry seen)))
                 (ensure-list (alist-get 'inherits entry))))))

(defun gdev-cmake--environment (entry entries &optional seen)
  "Raccogli le variabili di ENTRY e dei suoi antenati in ENTRIES.
Restituisci le variabili in ordine di precedenza."
  (when (and entry (not (memq entry seen)))
    (append (alist-get 'environment entry)
            (cl-loop for parent in (ensure-list (alist-get 'inherits entry))
                     append (gdev-cmake--environment (gdev-cmake--entry parent entries)
                                                     entries (cons entry seen))))))

(defun gdev-cmake--choose (kind candidates root ask &optional preferred)
  "Scegli una preimpostazione KIND tra CANDIDATES.
Con ASK chiedi conferma quando non c'è una scelta univoca o PREFERRED."
  (let* ((key (intern (concat ":" kind "-preset")))
         (remembered (gdev-build--get key root))
         (choice
          (cond ((member remembered candidates) remembered)
                ((member preferred candidates) preferred)
                ((not (cdr candidates)) (car candidates))
                (ask (completing-read
                      (format "Preimpostazione CMake per %s: "
                              (pcase kind ("configure" "la configurazione")
                                ("build" "la compilazione") ("test" "i test")))
                      candidates nil t)))))
    (if (and ask choice) (gdev-build--put key choice root) choice)))

(defun gdev-cmake--context (root &optional ask action)
  "Risolvi la cartella e le preimpostazioni CMake di ROOT per ACTION."
  (let* ((groups (unless (eq action 'configure) (gdev-cmake--presets "all" root)))
         (available (if groups (alist-get "configure" groups nil nil #'equal)
                      (gdev-cmake--presets "configure" root ask)))
         (files (when available (gdev-cmake--preset-files root)))
         (entries (gdev-cmake--entries "configure" files))
         (name (gdev-cmake--choose "configure" available root ask))
         (selected (gdev-cmake--entry name entries))
         (type (and name (gdev-build--get :cmake-preset-type root)))
         (binary (cdr (gdev-cmake--field 'binaryDir selected entries))))
    (unless (and available (not name))
      (let* ((folder
              (cond (type (expand-file-name (concat name "/" type)
                                            (expand-file-name "build-gdev/" root)))
                    (name
                     (or (and binary
                              (gdev-cmake--expand binary root name (alist-get 'gdev-file selected)
                                                  (gdev-cmake--environment selected entries)
                                                  (cdr (gdev-cmake--field 'generator selected entries))))
                         (unless binary ".")
                         (when ask (user-error "Cartella non risolta per la preimpostazione CMake «%s»" name))))
                    (t (or (gdev-build--get :build-directory root) gdev-cmake-build-directory))))
             (context
              (when folder
                (list :configure name :type type :directory
                      (file-name-as-directory
                       (expand-file-name (if (and (file-remote-p root) (file-name-absolute-p folder)
                                                 (not (file-remote-p folder)))
                                             (concat (file-remote-p root) folder) folder)
                                         root))))))
        (when (and context name (not type))
          (dolist (kind (pcase action
                          ((or 'build 'run 'clean) '("build"))
                          ('configure nil)
                          (_ '("build" "test"))))
            (let* ((items (gdev-cmake--entries kind files))
                   (associated
                    (cl-loop for item in items
                             when (equal name (cdr (gdev-cmake--field 'configurePreset item items)))
                             collect (alist-get 'name item)))
                   (available (when associated
                                (if groups (alist-get kind groups nil nil #'equal)
                                  (gdev-cmake--presets kind root ask))))
                   (matching (seq-filter (lambda (candidate) (member candidate available)) associated))
                   (choice (gdev-cmake--choose kind matching root
                                               (and ask (eq action (intern kind))) name))
                   (entry (gdev-cmake--entry choice items)))
              (setq context (plist-put context (intern (concat ":" kind)) choice))
              (when-let* ((configuration (cdr (gdev-cmake--field 'configuration entry items))))
                (setq context (plist-put context (intern (concat ":" kind "-configuration")) configuration))))))
        context))))

(defun gdev-cmake--cached-source (directory)
  "Leggi dal cache di DIRECTORY la cartella sorgente configurata."
  (when-let* ((cache (gdev-read-file-contents (expand-file-name "CMakeCache.txt" directory)))
              ((string-match "^CMAKE_HOME_DIRECTORY:INTERNAL=\\(.+\\)$" cache)))
    (match-string 1 cache)))

(defun gdev-cmake--check-directory (directory root)
  "Controlla che DIRECTORY non sia usata da un altro progetto."
  (when-let* ((source (gdev-cmake--cached-source directory))
              ((not (file-equal-p (concat (file-remote-p directory) source) root))))
    (user-error "La cartella di compilazione %s appartiene a un altro progetto" directory)))

(defun gdev-cmake--prepare (directory)
  "Prepara la richiesta del catalogo CMake in DIRECTORY."
  (let ((query (expand-file-name ".cmake/api/v1/query/client-gdev/codemodel-v2" directory)))
    (unless (file-exists-p query)
      (make-directory (file-name-directory query) t)
      (write-region "" nil query nil 'silent))))

(defun gdev-cmake--reply-index (directory)
  "Trova l'indice della risposta CMake più recente in DIRECTORY."
  (let ((reply (expand-file-name ".cmake/api/v1/reply/" directory)))
    (when (file-directory-p reply)
      (car (last (directory-files reply t "^index-.*\\.json$"))))))

(defun gdev-cmake--codemodel (directory &optional index-file)
  "Leggi il catalogo CMake in DIRECTORY, usando INDEX-FILE se già noto."
  (let* ((index-file (or index-file (gdev-cmake--reply-index directory)))
         (index (and index-file (gdev-cmake--json index-file)))
         (client (alist-get 'client-gdev (alist-get 'reply index))))
    (when-let* ((name (alist-get 'jsonFile (alist-get 'codemodel-v2 client)))
                ((equal name (file-name-nondirectory name)))
                (reply (file-name-directory index-file)))
      (cons reply (gdev-cmake--json (expand-file-name name reply))))))

(defun gdev-cmake-program-context (root)
  "Restituisci la cartella attiva e il catalogo degli eseguibili CMake di ROOT."
  (when (file-regular-p (expand-file-name "CMakeLists.txt" root))
    (when-let* ((context (gdev-cmake--context root nil 'run))
                (directory (plist-get context :directory)))
      (let* ((index (gdev-cmake--reply-index directory))
             (model (and index (gdev-cmake--codemodel directory index)))
             (model-name (or (plist-get context :type) (plist-get context :build-configuration)))
             (programs (when model (gdev-cmake--program-artifacts model directory model-name index))))
        (list :directory directory :catalog model :programs programs)))))

(defvar gdev-cmake--artifact-cache nil
  "Percorsi degli eseguibili negli indici CMake locali usati di recente.")

(defun gdev-cmake--artifact-paths (model directory name &optional types)
  "Raccogli i percorsi prodotti da MODEL in DIRECTORY per NAME.
TYPES elenca i tipi da includere, normalmente solo gli eseguibili.
Restituisci (COMPLETO . PERCORSI); COMPLETO è nil se manca una risposta."
  (let* ((types (or types '("EXECUTABLE")))
         (complete t)
         (paths
          (cl-loop for configuration in (alist-get 'configurations (cdr model))
                   when (or (not name) (equal name (alist-get 'name configuration)))
                   append (cl-loop for target in (alist-get 'targets configuration)
                                   for file = (alist-get 'jsonFile target)
                                   when (and (stringp file) (equal file (file-name-nondirectory file)))
                                   append (let ((info (gdev-cmake--json (expand-file-name file (car model)))))
                                            (unless info (setq complete nil))
                                            (when (member (alist-get 'type info) types)
                                              (cl-loop for artifact in (alist-get 'artifacts info)
                                                       collect (expand-file-name
                                                                (alist-get 'path artifact) directory))))))))
    (cons complete (delete-dups paths))))

(defun gdev-cmake--program-artifacts (model directory name &optional index)
  "Restituisci gli eseguibili di MODEL in DIRECTORY per NAME.
Con INDEX, riusa i percorsi se la risposta CMake locale è la stessa."
  ;; La File API pubblica un nuovo indice a ogni generazione e non sostituisce
  ;; con contenuto diverso i file di risposta che hanno lo stesso nome.
  (let* ((attributes (and index (cdr model) (not (file-remote-p directory))
                          (file-attributes index)))
         (revision (when attributes
                     (list index (file-attribute-device-number attributes)
                           (file-attribute-inode-number attributes)
                           (file-attribute-status-change-time attributes)
                           (file-attribute-modification-time attributes)
                           (file-attribute-size attributes))))
         (key (list directory name))
         (entry (and revision (assoc key gdev-cmake--artifact-cache)))
         (paths (if (and entry (equal (cadr entry) revision))
                    (caddr entry)
                  (pcase-let ((`(,complete . ,paths) (gdev-cmake--artifact-paths model directory name)))
                    (when (and revision complete (<= (length paths) 2048))
                      (setq gdev-cmake--artifact-cache
                            (cons (list key revision paths)
                                  (seq-take (assoc-delete-all key gdev-cmake--artifact-cache) 7))))
                    paths))))
    ;; La risposta può esistere già prima della compilazione e sopravvivere
    ;; alla rimozione degli eseguibili. Ricontrolla il disco a ogni invocazione.
    (seq-filter (lambda (path) (and (file-regular-p path) (file-executable-p path))) paths)))

(defun gdev-cmake-test-context (root)
  "Restituisci la cartella CTest, la preimpostazione e la compilazione per ROOT."
  (when (file-regular-p (expand-file-name "CMakeLists.txt" root))
    (when-let* ((context (gdev-cmake--context root))
                (directory (plist-get context :directory))
                ((file-regular-p (expand-file-name "CTestTestfile.cmake" directory))))
      (list :directory directory :preset (plist-get context :test)
            :configuration (or (plist-get context :type)
                               (plist-get context :test-configuration)
                               (plist-get context :build-configuration))
            :build-command (gdev-cmake-build-command nil context (plist-get context :test-configuration))))))

(defun gdev-cmake-configure-command (&optional context root)
  "Restituisci il comando di configurazione CMake per CONTEXT in ROOT.
ROOT è la radice in cui `gdev-build-set-type' salva il tipo di compilazione;
il valore predefinito è quella di `gdev-build--root'."
  (let* ((root (or root (gdev-build--root)))
         (context (or context (gdev-cmake--context root t 'configure)))
         (directory (plist-get context :directory)))
    (if-let* ((preset (plist-get context :configure)))
        (gdev-command-line "cmake" "--preset" preset
                           (when-let* ((type (plist-get context :type)))
                             (list "-B" (file-local-name directory)
                                   (concat "-DCMAKE_BUILD_TYPE=" type))))
      (gdev-command-line
       "cmake" "-S" "." "-B" (file-local-name directory)
       (and (not (gdev-cmake--cached-source directory)) (gdev-executable-in "ninja" root)
            '("-G" "Ninja"))
       (concat "-DCMAKE_BUILD_TYPE=" (or (gdev-build--get :type root) "Debug"))
       "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
       (and (gdev-executable-in "ccache" root) "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")))))

(defun gdev-cmake-build-command (&optional target context configuration)
  "Restituisci il comando di compilazione di TARGET per CONTEXT e CONFIGURATION."
  (let ((context (or context (gdev-cmake--context (gdev-build--root) t 'build))))
    (gdev-command-line
     "cmake" "--build"
     (if-let* ((preset (plist-get context :build)))
         (list "--preset" preset)
       (file-local-name (plist-get context :directory)))
     (and target (list "--target" target))
     (when-let* ((type (or configuration (plist-get context :type)))) (list "--config" type))
     "--parallel" (gdev-build--jobs))))

(defun gdev-cmake-test-command (&optional context)
  "Restituisci il comando di esecuzione dei test CTest per CONTEXT."
  (let ((context (or context (gdev-cmake--context (gdev-build--root) t 'test))))
    (gdev-command-line
     "ctest" "--output-on-failure" "-j" (gdev-build--jobs)
     (if-let* ((preset (plist-get context :test)))
         (list "--preset" preset)
       (list "--test-dir" (file-local-name (plist-get context :directory))))
     (when-let* ((configuration (or (plist-get context :type)
                                   (plist-get context :test-configuration)
                                   (plist-get context :build-configuration))))
       (list "-C" configuration)))))

(defun gdev-cmake--command (action root context)
  "Prepara il flusso CMake per ACTION in ROOT."
  (let* ((directory (plist-get context :directory))
         (configured (gdev-cmake--codemodel directory)))
    (gdev-cmake--check-directory directory root)
    (if (eq action 'clean)
        (progn
          (unless (gdev-cmake--cached-source directory)
            (user-error "Configura prima il progetto CMake"))
          (gdev-cmake-build-command "clean" context))
      (gdev-cmake--prepare directory)
      (string-join
       (delq nil
             (list (when (or (eq action 'configure) (not configured))
                     (gdev-cmake-configure-command context root))
                   (when (memq action '(build test))
                     (gdev-cmake-build-command
                      (and (eq action 'build) (gdev-build--get :target root))
                      context (and (eq action 'test) (plist-get context :test-configuration))))
                   (when (eq action 'test)
                     (gdev-cmake-test-command context))))
       " && "))))

(defun gdev-cmake-targets (&optional root)
  "Restituisci gli obiettivi dell'albero CMake già configurato in ROOT.
Il valore predefinito di ROOT è la radice di `gdev-build--root'."
  (let* ((root (or root (gdev-build--root)))
         (default-directory root)
         (context (gdev-cmake--context root t 'build))
         (directory (plist-get context :directory)))
    (when (gdev-cmake--cached-source directory)
      (cl-loop for line in (process-lines-ignore-status
                            "cmake" "--build" (file-local-name directory) "--target" "help")
               when (or (string-match "^\\([^ /:]+\\): phony$" line)
                        (string-match "^\\.\\.\\. \\([^ /]+\\)" line))
               collect (match-string 1 line)))))

;;;; Comandi per ogni sistema di compilazione

(defcustom gdev-meson-build-directory "build-meson"
  "Cartella per le nuove configurazioni Meson, relativa al progetto."
  :type 'string
  :group 'gdev-build)

(defun gdev-build--meson-source (directory)
  "Leggi il percorso sorgente dai metadati Meson in DIRECTORY."
  (when-let* ((info (gdev-build--meson-info directory "meson-info.json"))
              (source (alist-get 'source (alist-get 'directories info)))
              ((stringp source)))
    (concat (file-remote-p directory) source)))

(defun gdev-build--meson-info (directory file)
  "Leggi FILE da meson-info in DIRECTORY."
  (condition-case nil
      (gdev-cmake--json (expand-file-name (concat "meson-info/" file) directory))
    (json-parse-error
     (user-error "Metadati Meson non leggibili in %s" directory))))

(defun gdev-build--meson-targets (root)
  "Leggi gli obiettivi della configurazione Meson di ROOT."
  (gdev-build--meson-info (gdev-build--meson-directory root) "intro-targets.json"))

(defun gdev-build-program-context (root)
  "Restituisci il catalogo e la cartella di compilazione di ROOT."
  (or (gdev-cmake-program-context root)
      (when (gdev-project-file-exists-p root "meson.build")
        (let* ((directory (gdev-build--meson-directory root))
               (targets (gdev-build--meson-info directory "intro-targets.json"))
               (remote (file-remote-p directory)))
          (list :directory directory :catalog t
                :programs (cl-loop for target in targets
                                   when (equal (alist-get 'type target) "executable")
                                   append (cl-loop for name in (alist-get 'filename target)
                                                   for path = (concat remote name)
                                                   when (and (file-regular-p path) (file-executable-p path))
                                                   collect path)))))))

(defun gdev-build--meson-directory (root)
  "Scegli una cartella di compilazione Meson appartenente a ROOT."
  (let* ((directory (expand-file-name gdev-meson-build-directory root))
         (standard (expand-file-name "build" root))
         (source (gdev-build--meson-source directory)))
    (cond ((or (and source (file-equal-p source root))
               (and (not source) (not (file-exists-p directory))))
           (let ((standard-source (gdev-build--meson-source standard)))
             (if (and (not source) standard-source (file-equal-p standard-source root))
                 standard directory)))
          ((and (not source) (file-directory-p directory)
                (not (directory-files directory nil directory-files-no-dot-files-regexp t 1)))
           directory)
          (t (user-error "Scegli una cartella Meson vuota o associata a %s: %s" root directory)))))

(defun gdev-build--meson-command (action root directory)
  "Restituisci la riga Meson per ACTION in ROOT."
  (let* ((configured (gdev-build--meson-source directory))
         (build-dir (file-local-name directory))
         (target (gdev-build--get :meson-target root))
         (setup (gdev-command-line "meson" "setup" (and configured "--reconfigure")
                                   build-dir (file-local-name root)))
         (command
          (pcase action
            ('configure setup)
            ('build (gdev-command-line "meson" "compile" "-C" build-dir target))
            ('test (gdev-command-line "meson" "test" "-C" build-dir "--print-errorlogs"))
            ('clean (unless configured (user-error "Configura Meson prima di pulire"))
                    (gdev-command-line "meson" "compile" "-C" build-dir "--clean")))))
    (if (or configured (eq action 'configure))
        command
      (concat setup " && " command))))

(defun gdev-build--ninja-command (action root)
  "Restituisci la riga Ninja per ACTION in ROOT."
  (pcase action
    ('build (gdev-command-line "ninja" (gdev-build--get :ninja-target root)))
    ('clean (gdev-command-line "ninja" "-t" "clean"))
    ('test (gdev-command-line "ninja" "test"))
    ('configure (read-shell-command "Comando per generare build.ninja: " nil 'compile-history))))

(defun gdev-build--choose-target (root)
  "Scegli l'obiettivo del sistema di compilazione di ROOT."
  (let* ((default-directory root)
         (system (gdev-build-system root))
         (key (cdr (assq system '((cmake . :target) (meson . :meson-target)
                                  (ninja . :ninja-target) (make . :make-target))))))
    (when key
      (let* ((targets
              (pcase system
                ('cmake (gdev-cmake-targets root))
                ('meson (mapcar (lambda (target) (alist-get 'name target))
                                (gdev-build--meson-targets root)))
                ('make (condition-case err (plist-get (gdev-make-inspect root) :targets)
                         (user-error (message "%s" (error-message-string err)) nil)))
                ('ninja
                 (cl-loop for line in (process-lines-ignore-status "ninja" "-t" "targets" "all")
                          when (string-match "^\\(.*\\): [^ ]+$" line)
                          collect (match-string 1 line)))))
             (target (completing-read "Obiettivo (vuoto = predefinito): " targets)))
        (gdev-build--put key (unless (string-empty-p target) target) root)))))

(defun gdev-build--command-scope (action root)
  "Prepara (COMANDO . AMBITO) per ACTION nel progetto ROOT."
  (let* ((root (or root (gdev-project-root)))
         (system (gdev-build-system root))
         (jobs (gdev-build--jobs))
         (language-command (or (gdev-language-command action root t)
                               (unless system (gdev-language-command action root))))
         (cmake (when (and (not language-command) (eq system 'cmake))
                  (gdev-cmake--context root t action)))
         (directory (unless language-command
                      (pcase system
                        ('cmake (plist-get cmake :directory))
                        ('meson (gdev-build--meson-directory root))
                        ((or 'make 'ninja 'perl-make 'perl-build) root))))
         (asd-system (and (eq system 'asdf)
                          (file-name-base (car (directory-files root nil "\\.asd\\'" t 1)))))
         (scope (gdev-build-scope root directory)))
    (gdev-build-check-scope scope)
    (cons
     (if language-command
         (gdev-command-line (car language-command) (cdr language-command))
       (pcase (list system action)
         (`(cmake ,_) (gdev-cmake--command action root cmake))
         (`(meson ,_) (gdev-build--meson-command action root directory))
         (`(ninja ,_) (gdev-build--ninja-command action root))
         (`(make ,(or 'build 'test 'clean)) (gdev-make-command root action))
         (`(perl-make ,_)
          (gdev-build--generated-command root action "Makefile" "perl Makefile.PL"
                                          (unless (eq action 'configure) (gdev-make-command root action))))
         (`(perl-build ,_)
          (gdev-build--generated-command root action "Build" "perl Build.PL"
                                          (pcase action ('build "./Build") ('test "./Build test") ('clean "./Build clean"))))
         (`(perl-prove test) (gdev-command-line "prove" "-lr" "-j" jobs "t"))
         (`(perl-prove build) "find lib -name '*.pm' -exec perl -Ilib -c {} \\;")
         (`(deno build) "deno task build")
         (`(deno test) "deno test")
         (`(node build) "npm run build")
         (`(node test) "npm test")
         (`(python ,(or 'configure 'build 'test)) (gdev-python-project-command action root))
         (`(asdf build) (gdev-command-line "sbcl" "--non-interactive" "--eval"
                                           (format "(ql:quickload :%s)" asd-system)))
         (`(asdf test) (gdev-command-line "sbcl" "--non-interactive" "--eval"
                                          (format "(progn (ql:quickload :%s) (asdf:test-system :%s))"
                                                  asd-system asd-system)))
         (_ (read-shell-command (format "Comando per %s: "
                                        (pcase action
                                          ('configure "configurare") ('build "compilare")
                                          ('test "i test") ('run "eseguire")
                                          (_ (symbol-name action))))
                                nil 'compile-history))))
     scope)))

(defun gdev-build--generated-command (root action artifact prepare command)
  "Prepara ARTIFACT con PREPARE prima di COMMAND per ACTION in ROOT.
Un errore della preparazione arresta la catena. La pulizia non crea un
nuovo albero; il motore gestisce poi l'invalidazione dei propri metadati."
  (let ((exists (file-exists-p (expand-file-name artifact root))))
    (when (and (eq action 'clean) (not exists))
      (user-error "Il progetto non è ancora configurato: nessun albero da pulire"))
    (if (eq action 'configure) prepare
      (unless command (user-error "Operazione non disponibile: %s" action))
      (if exists command (concat prepare " && " command)))))

(defun gdev-build--command (action &optional root)
  "Restituisci il comando per ACTION nel progetto ROOT."
  (let ((root (or root (gdev-build--root))))
    (gdev-auto-modules-call-for-project
     root (lambda () (car (gdev-build--command-scope action root))))))

(defun gdev-build--outermost (directory project markers)
  "Trova la cartella più esterna con MARKERS tra DIRECTORY e PROJECT.
PROJECT è escluso.  In CMake e Meson anche le sottocartelle hanno il loro
file: la radice della compilazione è la più esterna, non la più vicina."
  (let ((directory (file-name-as-directory (expand-file-name directory)))
        (project (file-name-as-directory (expand-file-name project)))
        found)
    (while (and (string-prefix-p project directory) (not (equal directory project)))
      (when (apply #'gdev-project-file-exists-p directory markers)
        (setq found directory))
      (setq directory (file-name-directory (directory-file-name directory))))
    found))

(defun gdev-build--root ()
  "Restituisce la cartella del progetto scelta dal linguaggio attivo."
  (or (bound-and-true-p project-current-directory-override)
      ;; Il linguaggio sceglie solo per il documento, non per «Cambia progetto».
      (when-let* ((resolver (gdev-handler :build-root))) (funcall resolver))
      (let* ((project (gdev-project-root))
             (workspace (gdev-workspace-directory))
             (boundary (cond
                        ((and workspace (string-prefix-p workspace default-directory)) workspace)
                        ((not (equal project (file-name-as-directory (expand-file-name default-directory))))
                         project))))
        (gdev-project-operation-root default-directory boundary))))

(defun gdev-build--run (action)
  "Esegue ACTION per il progetto corrente nel suo buffer di compilazione."
  (let* ((profile (car (gdev-launch-selected (gdev-launch-profile-root))))
         (root (gdev-build--root))
         (default-directory root))
    (gdev-use-project-tools root)
    (gdev-require-project-environment)
    (gdev-auto-modules-call-for-project
     root
     (lambda ()
       (pcase-let ((`(,command . ,scope) (gdev-build--command-scope action root)))
         (setq-local compile-command command)
         (gdev-build-start command root scope (eq action 'build) profile))))))

(defun gdev-build-configure (&optional choose-preset from-user)
  "Configura il progetto.
Con CHOOSE-PRESET scegli una preimpostazione CMake o imposta gli argomenti
della fase definita dal profilo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'configure choose-preset)
         (when (eq (gdev-build-system (gdev-build--root)) 'make)
           (gdev-make-configure (gdev-build--root)) t)
         (progn
           (when choose-preset
             (let* ((root (gdev-build--root))
                    (presets (gdev-cmake--presets "configure" root)))
               (when presets
                 (gdev-build--put :configure-preset
                                  (completing-read "Preimpostazione CMake: " presets nil t)
                                  root)
                 (gdev-build--put :cmake-preset-type nil root))))
           (gdev-build--run 'configure))))
   from-user))

(defun gdev-build (&optional choose-target from-user)
  "Compila il progetto.
Con CHOOSE-TARGET scegli un obiettivo o modifica gli argomenti del profilo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'build choose-target)
         (progn
           (when choose-target (gdev-build--choose-target (gdev-build--root)))
           (gdev-build--run 'build))))
   from-user))

(defun gdev-build--test-project ()
  "Esegui tutti i test del progetto in modalità automatica."
  (if-let* ((runner (gdev-handler :test-project)))
      (funcall runner)
    (gdev-build--run 'test)))

(defun gdev-build-test (&optional ask-options from-user)
  "Esegui tutti i test del progetto.
Con ASK-OPTIONS modifica gli argomenti di test del profilo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'test ask-options) (gdev-build--test-project)))
   from-user))

(defun gdev-build-clean (&optional ask-options from-user)
  "Pulisci l'albero di compilazione.
Con ASK-OPTIONS modifica gli argomenti di pulizia del profilo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'clean ask-options) (gdev-build--run 'clean)))
   from-user))

(defun gdev-build-set-type (&optional from-user)
  "Sceglie il tipo di compilazione CMake, poi configura.
Per una preimpostazione usa una cartella distinta, mantenendone la toolchain.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list t))
  (gdev-call-for-document
   (lambda ()
     (let ((root (gdev-build--root)))
       (unless (eq (gdev-build-system root) 'cmake)
         (user-error "Apri un progetto CMake per scegliere il tipo di compilazione"))
       (let ((key (if (gdev-cmake--presets "configure" root) :cmake-preset-type :type)))
         (gdev-build--put key (completing-read "Tipo di compilazione: " gdev-cmake-build-types nil t) root)
         (gdev-build-configure))))
   from-user))

(defun gdev-build-forget (&optional from-user)
  "Dimentica le scelte di compilazione di questo progetto.
Preimpostazioni, tipo di compilazione e obiettivo tornano da scegliere.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list t))
  (gdev-call-for-document
   (lambda ()
     (let ((root (gdev-build--root)))
       (gdev-build--import-settings)
       (gdev-state-db-with (db t)
         (sqlite-execute db "DELETE FROM ambito WHERE tipo='compilazione' AND riferimento=?" (list root)))
       (message "Scelte di compilazione di %s dimenticate" (abbreviate-file-name root))))
   from-user))

(defun gdev-build-run (&optional ask-arguments from-user)
  "Esegue un programma compilato in un'area di testo interattivo.
Chiede gli argomenti la prima volta; con il prefisso ASK-ARGUMENTS, di nuovo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (pcase-let* ((root (gdev-build--root))
                  (`(,program . ,arguments)
                   (gdev-read-program "Programma da eseguire"
                                      (or ask-arguments (not (gethash root gdev--last-program))) root)))
       (gdev-compile (concat (shell-quote-argument (file-local-name program)) " " arguments)
                     (format "Esecuzione · %s" (abbreviate-file-name program))
                     root t)))
   from-user))

(defun gdev-build-recompile (&optional from-user)
  "Ripeti l'ultima compilazione del progetto e del profilo nello spazio corrente.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list t))
  (gdev-call-for-document
   (lambda ()
     (let* ((profile-root (gdev-launch-profile-root))
            (profile (gdev-launch-selected profile-root))
            (root (if (and profile (plist-get (gdev-launch--options profile profile-root) :build))
                      profile-root (gdev-build--root)))
            (plan (gdev-build-last-plan root (car profile))))
       (if plan
           (gdev-build-execute-plan plan)
         (gdev-build))))
   from-user))

;;;; Il file aperto: script e file di test

(defun gdev-run-dwim (&optional ask-arguments from-user)
  "Esegue il programma aperto, o un programma compilato del progetto.
Con il prefisso ASK-ARGUMENTS, chiede di nuovo gli argomenti.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'run ask-arguments)
         (if-let* ((runner (gdev-handler :run)))
             (funcall runner ask-arguments)
           (gdev-build-run ask-arguments))))
   from-user))

(defun gdev-test-dwim (&optional ask-options from-user)
  "Esegui i test del file aperto o del progetto.
Con ASK-OPTIONS modifica gli argomenti di test del profilo.
Con FROM-USER, vero da tastiera e menu, agisce sul documento attivo."
  (interactive (list current-prefix-arg t))
  (gdev-call-for-document
   (lambda ()
     (or (gdev-launch-dispatch 'test ask-options)
         (if-let* ((runner (gdev-handler :test)))
             (funcall runner)
           (gdev-build--test-project))))
   from-user))

(defun gdev-run-file-with (interpreter-arguments &optional ask-arguments directory name)
  "Esegue il file aperto come INTERPRETER-ARGUMENTS seguiti dal nome del file.
Gli argomenti del programma si chiedono la prima volta, o con
ASK-ARGUMENTS, e restano memorizzati per file.  Gira in DIRECTORY
\(predefinita: la radice del progetto), in un'area di testo interattiva
identificata da NAME, o dal nome del programma."
  (let* ((file buffer-file-name)
         (key (concat "file:" (or file (user-error "Apri prima il file da eseguire"))))
         (arguments (if (or ask-arguments (not (gethash key gdev--last-program)))
                        (read-string "Argomenti: " (gethash key gdev--last-program)
                                     'gdev-program-arguments-history)
                      (gethash key gdev--last-program))))
    (puthash key arguments gdev--last-program)
    (save-buffer)
    (gdev-compile (concat (apply #'gdev-command-line
                                (append interpreter-arguments (list (file-local-name file))))
                          " " arguments)
                  (or name (format "Esecuzione · %s" (abbreviate-file-name file)))
                  directory t)))

;;;; Versioni degli strumenti per progetto

;; Caricate al bisogno con `autoload': dichiarale al compilatore.
(declare-function gdev-mise--prepare-folder "gdev-mise" (folder))
(declare-function gdev-mise-apply "gdev-mise" (root))
(declare-function gdev-mise-refresh "gdev-mise" (root))

(let ((library (gdev-config-file "modules/tools/build/gdev-mise")))
  (autoload 'gdev-mise-environment library)
  (autoload 'gdev-mise--prepare-folder library)
  (autoload 'gdev-mise-apply library)
  (autoload 'gdev-mise-refresh library)
  (add-hook 'gdev-open-folder-hook #'gdev-mise--prepare-folder)
  (add-hook 'gdev-project-environment-refresh-functions #'gdev-mise-refresh)
  (add-hook 'gdev-project-environment-functions #'gdev-mise-apply))

;;; config.el ends here
