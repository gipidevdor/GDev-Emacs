;;; gdev-lib.el --- Funzioni di supporto comuni di GDev-Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Funzioni di supporto senza dipendenze, usate da tutti gli altri moduli:
;;
;;   - predicati di piattaforma e le tre cartelle di GDev;
;;   - la politica dei pacchetti (caricamento differito, verifica
;;     "è installato?" a costo zero);
;;   - ricerca del progetto e cartelle di strumenti locali al progetto;
;;   - avvio di processi nelle aree di testo (buffer) di compilazione;
;;   - scelta del programma da eseguire, da passare al debugger o da
;;     profilare.
;;
;; Tenerle qui permette a ogni modulo di restare breve e dichiarativo.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup gdev nil
  "Ambiente di sviluppo GDev-Emacs."
  :group 'convenience
  :prefix "gdev-")

;;;; Piattaforma e cartelle

;; Definite in early-init.el.  Dichiarate perché ogni modulo si compili da solo.
(defvar gdev-config-directory)
(defvar gdev-state-directory)
(defvar gdev-tools-directory)
(defvar gdev-bundled-packages)

(defconst gdev-macos-p (eq system-type 'darwin) "Non nil su macOS.")
(defconst gdev-linux-p (eq system-type 'gnu/linux) "Non nil su GNU/Linux.")
(defconst gdev-windows-p (memq system-type '(windows-nt cygwin))
  "Non nil su Windows.")

(defconst gdev-open-program
  (cond (gdev-macos-p "open") (gdev-windows-p "start") (t "xdg-open"))
  "Programma che apre un file o un URL con l'applicazione predefinita.")

(defun gdev-state-file (name)
  "Restituisce il nome assoluto di NAME dentro `gdev-state-directory'."
  (expand-file-name name gdev-state-directory))

(defun gdev-write-state-data (file data &optional description)
  "Sostituisci FILE con una rappresentazione Lisp completa di DATA.
DESCRIPTION, se presente, precede i dati come commento."
  (gdev-write-state-file
   file (lambda ()
          (when description (insert ";; " description "\n"))
          (prin1 data (current-buffer)))))

(defun gdev-write-state-file (file write)
  "Sostituisci atomicamente FILE con quanto WRITE inserisce nell'area di testo."
  (let ((temporary (make-temp-file (concat file ".")))
        (coding-system-for-write 'utf-8-unix)
        (print-escape-newlines t)
        print-length print-level print-quoted print-circle)
    (unwind-protect
        (progn
          (with-temp-file temporary
            (funcall write)
            (insert "\n"))
          (rename-file temporary file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun gdev-tools-file (name)
  "Restituisce il nome assoluto di NAME dentro `gdev-tools-directory'."
  (expand-file-name name gdev-tools-directory))

(defun gdev-config-file (name)
  "Restituisce il nome assoluto di NAME nella copia di lavoro di GDev-Emacs."
  (expand-file-name name gdev-config-directory))

(defconst gdev-application-icon "docs/assets/gdev-emacs.svg"
  "Percorso relativo dell'icona del cruscotto e dei dialoghi di GDev-Emacs.")

;;;; Politica dei pacchetti

;; Definite da package.el o dal file quickstart.  Dichiarate, non caricate:
;; caricare package.el costa decine di millisecondi che un avvio normale non
;; richiede.
(defvar package-activated-list)
(declare-function use-package-ensure-elpa "use-package-ensure")
(declare-function use-package-as-symbol "use-package-core")
(declare-function package-vc-install "package-vc")
(declare-function package-load-all-descriptors "package")
(declare-function package-activate "package")
(declare-function package-built-in-p "package")
(defvar package-alist)

(eval-and-compile
  (require 'use-package)

  (defvar gdev--ensured-packages nil
    "Pacchetti indicati da `:ensure' nel codice caricato o compilato finora.
`gdev sync' conserva questi (e le loro dipendenze) e rimuove il resto.")

  (defvar gdev--bundled-packages-only nil
    "Non nil durante il caricamento o la compilazione dei moduli distribuiti.")

  (defun gdev-package-ensure (name args state &optional no-refresh)
    "Installa il pacchetto della forma `use-package' NAME se non è attivo.
ARGS è la lista dei valori di `:ensure'.  STATE e NO-REFRESH passano a
`use-package-ensure-elpa' nel percorso lento.

Percorso rapido: `package-activate-all' (o il file quickstart) riempie
`package-activated-list', così un test di appartenenza risponde \"già
installato\" senza caricare package.el.  Percorso lento, solo quando manca
un pacchetto personale: aggiorna gli archivi e installa."
    ;; Durante la compilazione in codice intermedio (bytecode) NAME e ARGS
    ;; contengono simboli con posizione; package.el deve vedere solo simboli
    ;; semplici.
    (when (fboundp 'byte-run-strip-symbol-positions)
      (setq name (byte-run-strip-symbol-positions name)
            args (byte-run-strip-symbol-positions (copy-tree args))))
    (let ((wanted (cl-loop for ensure in args
                           for package = (cond ((eq ensure t) (use-package-as-symbol name))
                                               ((consp ensure) (car ensure))
                                               (t ensure))
                           when (and package (symbolp package)) collect package)))
      (dolist (package wanted)
        (let ((fork (assq package gdev-bundled-packages)))
          (cond
           ((and fork (not (memq package (bound-and-true-p package-activated-list))))
            (error "Il fork locale di %s non è attivo. Verifica la copia di GDev-Emacs" package))
           ((and gdev--bundled-packages-only (not fork) (not (package-built-in-p package)))
            (error "Il modulo richiede %s, assente dal registro dei fork GDev" package))))
        (cl-pushnew package gdev--ensured-packages))
      (unless (or gdev--bundled-packages-only
                  (cl-every (lambda (package)
                              (memq package (bound-and-true-p package-activated-list)))
                            wanted))
        (use-package-ensure-elpa name args state no-refresh))))

  ;; Tutto è differito, salvo che una forma dica altrimenti: `:demand',
  ;; `:hook', `:bind', `:commands' e `:mode' creano già i giusti inneschi di
  ;; caricamento automatico (autoload).
  (setq use-package-always-defer t
        use-package-always-ensure nil
        use-package-enable-imenu-support t
        use-package-ensure-function #'gdev-package-ensure))

(defun gdev-package-vc-ensure (package url &optional revision)
  "Installa il pacchetto personale PACKAGE da URL, se non è già attivo.
REVISION è una registrazione (commit) o un'etichetta (tag); nil indica il
ramo (branch) predefinito.  Serve solo per i rari pacchetti assenti da ogni
archivio."
  (when (and gdev--bundled-packages-only (not (assq package gdev-bundled-packages)))
    (error "Il modulo richiede %s, assente dal registro dei fork GDev" package))
  (unless (memq package (bound-and-true-p package-activated-list))
    (when (assq package gdev-bundled-packages)
      (error "Il fork locale di %s non è attivo. Verifica la copia di GDev-Emacs" package))
    (require 'package)
    (unless package-alist
      (package-load-all-descriptors))
    (if (assq package package-alist)
        ;; Già scaricato ma non attivo: lo attiva.  Reinstallarlo chiederebbe
        ;; se sovrascrivere la copia, e in modalità non interattiva (batch)
        ;; fallirebbe.
        (package-activate package)
      (package-vc-install (list package :url url) revision))))

;;;; Eseguibili

(defun gdev-find-executable (&rest names)
  "Restituisce il percorso assoluto del primo programma di NAMES trovato.
La ricerca avviene in `exec-path'."
  (cl-some #'executable-find names))

(defvar gdev--xcrun-cache (make-hash-table :test #'equal)
  "Percorsi trovati da `gdev-xcrun-find', per strumento.")

(defun gdev-xcrun-find (tool)
  "Restituisce il percorso di TOOL di Xcode tramite xcrun.
Restituisce nil fuori da macOS o se TOOL manca.  Il percorso trovato si
ricorda finché resta eseguibile: ogni chiamata a xcrun costa un processo."
  (when gdev-macos-p
    (let ((cached (gethash tool gdev--xcrun-cache)))
      (if (and cached (file-executable-p cached))
          cached
        (let ((path (ignore-errors
                      (car (process-lines-ignore-status "xcrun" "-f" tool)))))
          (when (and path (file-executable-p path))
            (puthash tool path gdev--xcrun-cache)
            path))))))

;;;; Progetti

(declare-function project-root "project")

(defun gdev-default-directory ()
  "Restituisce la cartella da cui parte un comando di progetto.
Mentre è in corso un comando di «Cambia progetto» è la cartella scelta,
altrimenti `default-directory'."
  (or (bound-and-true-p project-current-directory-override) default-directory))

(defun gdev-project-root (&optional directory)
  "Restituisce la radice del progetto che contiene DIRECTORY, o DIRECTORY.
Senza DIRECTORY parte da `gdev-default-directory'."
  (let* ((directory (or directory (gdev-default-directory)))
         (project (project-current nil directory)))
    (file-name-as-directory
     (expand-file-name (if project (project-root project) directory)))))

(defun gdev-project-name (&optional directory)
  "Restituisce un nome breve per il progetto che contiene DIRECTORY."
  (file-name-nondirectory (directory-file-name (gdev-project-root directory))))

(defun gdev-project-file-exists-p (root &rest names)
  "Restituisce il primo dei NAMES che esiste direttamente sotto ROOT."
  (cl-find-if (lambda (name) (file-exists-p (expand-file-name name root))) names))

;;;; Strumenti locali al progetto

(defcustom gdev-project-tool-directories
  '(".tools/bin" ".tools/venv/bin" ".venv/bin" "node_modules/.bin")
  "Cartelle del progetto i cui programmi prevalgono su quelli globali.
I percorsi sono relativi alla radice.  Un repository che fissa la propria
versione di clang-format, di un formattatore o di un controllo la tiene in
una di queste.  I buffer di quel progetto trovano prima la versione
fissata, per compilazione, formattazione, server di linguaggio (language
server) e controlli."
  :type '(repeat string))

(defcustom gdev-trusted-projects nil
  "Radici locali autorizzate a fornire strumenti e ambiente ai processi."
  :type '(repeat directory)
  :group 'gdev)

(defun gdev-project-trusted-p (root)
  "Restituisce non nil se ROOT è una radice locale autorizzata."
  (and gdev-trusted-projects
       (not (file-remote-p root))
       (member (file-name-as-directory (file-truename root)) gdev-trusted-projects)))

(defun gdev-trust-project (root)
  "Autorizza l'ambiente e gli strumenti del progetto locale ROOT."
  (interactive (list (gdev-project-operation-context-root)))
  (when (file-remote-p root)
    (user-error "Scegli una cartella locale"))
  (let ((directory (file-name-as-directory (file-truename root))))
    (when (yes-or-no-p (format "Autorizzare gli strumenti e l’ambiente di %s? " directory))
      (customize-save-variable 'gdev-trusted-projects (cons directory (remove directory gdev-trusted-projects)))
      (gdev-refresh-project-environment directory))))

(defun gdev-project-tool-path (root)
  "Restituisce quali `gdev-project-tool-directories' esistono in ROOT.
Si rilegge a ogni apertura: una cartella creata dopo, come .venv dopo
node_modules, vale per i documenti aperti da quel momento.  Bastano pochi
controlli su file locali, circa 60 microsecondi."
  (cl-loop for relative in gdev-project-tool-directories
           for absolute = (expand-file-name relative root)
           when (file-directory-p absolute) collect absolute))

(defvar-local gdev--project-tools-applied nil
  "Non nil se `gdev-use-project-tools' ha già agito su questo buffer.")

(defvar-local gdev--project-environment-base nil
  "Ambiente e percorso del documento prima dei fornitori di progetto.")

(defvar gdev-project-environment-refresh-functions nil
  "Funzioni che invalidano le osservazioni dell'ambiente di una radice.")
(defvar gdev-project-environment-reset-hook nil
  "Fornitori che dimenticano l'ambiente precedente del documento.")
(defvar gdev-project-environment-status)
(defvar gdev-project-environment-detail)

(autoload 'gdev-project-operation-context-root "gdev-project-types")

(defun gdev-reset-project-environment ()
  "Ripristina l'ambiente iniziale del documento e scarta i risultati attesi."
  (when gdev--project-environment-base
    (setq-local process-environment (copy-sequence (car gdev--project-environment-base))
                exec-path (copy-sequence (cadr gdev--project-environment-base))))
  (setq gdev--project-tools-applied nil
        gdev-project-environment-status nil gdev-project-environment-detail nil)
  (run-hooks 'gdev-project-environment-reset-hook))

(defun gdev-refresh-project-environment (&optional root)
  "Riprova l'ambiente di ROOT e aggiorna i documenti già aperti.
Conserva l'autorizzazione della cartella e le impostazioni personali."
  (interactive)
  (require 'gdev-project-types)
  (let* ((root (or root (gdev-project-operation-context-root)))
         (count 0))
    (unless (gdev-project-trusted-p root)
      (user-error "Autorizza prima gli strumenti della cartella: %s" root))
    (run-hook-with-args 'gdev-project-environment-refresh-functions root)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (not (file-remote-p default-directory))
                   (file-equal-p root (gdev-project-operation-context-root)))
          (gdev-reset-project-environment)
          (gdev-use-project-tools root)
          (when (and (bound-and-true-p envrc-mode) (fboundp 'envrc-reload)) (envrc-reload))
          (cl-incf count))))
    (message "Ambiente del progetto aggiornato per %d documenti" count)))

(defvar gdev-project-environment-functions nil
  "Funzioni che preparano l'ambiente di un buffer di progetto.
Ognuna riceve la radice del progetto, gira nel buffer e può impostarvi
localmente `process-environment' ed `exec-path' (per esempio le versioni
degli strumenti fissate da mise, nel modulo :tools build).")

(defvar-local gdev-project-environment-status nil
  "Stato della preparazione dell'ambiente del documento.
Nil indica che il documento non attende un fornitore. Gli altri valori
sono `pending', `ready' e `failed'.")

(defvar gdev-project-environment-ready-hook nil
  "Funzioni da eseguire nel documento quando il suo ambiente è pronto.")

(defvar envrc--running)

(defvar-local gdev-project-environment-detail nil
  "Causa, in una riga, per cui l'ambiente del documento non è disponibile.")

(autoload 'gdev-project-operation-decision "gdev-project-operations")

(defun gdev-project-environment-ready-p ()
  "Indica se i comandi possono usare l'ambiente di questo documento.
Con direnv in esecuzione l'ambiente non è ancora pronto: un comando
partirebbe con il percorso di ricerca globale."
  (not (or (memq gdev-project-environment-status '(pending failed))
           (bound-and-true-p envrc--running))))

(defun gdev-require-project-environment ()
  "Interrompi il comando se l'ambiente del documento non è disponibile."
  (pcase (gdev-project-operation-decision t gdev-project-environment-status t t nil t)
    ('blocked (user-error "Ambiente del progetto non disponibile%s. Usa Aggiorna ambiente del progetto per riprovare"
                         (if gdev-project-environment-detail
                             (format " (%s)" gdev-project-environment-detail)
                           "")))
    (_ (unless (gdev-project-environment-ready-p)
         (user-error "Ambiente del progetto in preparazione. Riprova tra poco")))))

(defun gdev-executable-in (program directory)
  "Percorso di PROGRAM sulla macchina di DIRECTORY, locale o remota, o nil.
Senza questo `executable-find' cercherebbe sul Mac anche per una
cartella TRAMP, dove il comando poi gira."
  (let ((default-directory directory))
    (executable-find program t)))

(defun gdev-prepend-project-tools (root)
  "Aggiunge in testa al percorso gli strumenti locali di ROOT."
  (when-let* (((gdev-project-trusted-p root))
              (directories (gdev-project-tool-path root)))
    (setq-local exec-path
                (append directories (cl-remove-if (lambda (entry) (member entry directories)) exec-path)))
    (setq-local process-environment (copy-sequence process-environment))
    (let ((path (split-string (or (getenv "PATH") "") path-separator)))
      (setenv "PATH" (string-join (append directories
                                         (cl-remove-if (lambda (entry) (member entry directories)) path))
                                 path-separator)))))

(defun gdev-use-project-tools (&optional project-root)
  "Dà a questo buffer l'ambiente del suo progetto.
Prima le funzioni di `gdev-project-environment-functions', poi le cartelle
di strumenti del progetto in testa al percorso di ricerca.  Solo file
locali: interrogare un host remoto a ogni apertura sarebbe lento.  Una
seconda chiamata rilegge le osservazioni dei fornitori e gli strumenti locali."
  (when (and gdev--project-tools-applied
             (or (not (equal gdev--project-tools-applied (or project-root (gdev-project-operation-context-root))))
                 (not (gdev-project-trusted-p gdev--project-tools-applied))))
    (gdev-reset-project-environment))
  (when-let* (
              ;; Senza cartelle autorizzate nessun progetto può dare strumenti:
              ;; `project-current' a ogni file aperto sarebbe lavoro inutile.
              (gdev-trusted-projects)
              (file (or project-root buffer-file-name))
              ((not (file-remote-p file)))
              (root (or project-root (gdev-project-operation-context-root)))
              ((gdev-project-trusted-p root)))
    (unless gdev--project-environment-base
      (setq gdev--project-environment-base (list (copy-sequence process-environment) (copy-sequence exec-path))))
    (setq gdev--project-tools-applied root)
    (run-hook-with-args 'gdev-project-environment-functions root)
    (gdev-prepend-project-tools root)))

;;;; Ambiente ereditato dai processi

;; L'ambiente di progetto vive nelle variabili locali del buffer del file.
;; Compilazione, comandi shell e blocchi Org avviano i processi da altri
;; buffer (di compilazione o temporanei) che non lo vedrebbero: queste
;; funzioni glielo passano.

(defun gdev-inherit-environment (function &rest arguments)
  "Chiama FUNCTION con ARGUMENTS facendole vedere l'ambiente di questo buffer."
  (if (or (local-variable-p 'process-environment) (local-variable-p 'exec-path))
      (cl-letf (((default-value 'process-environment) process-environment)
                ((default-value 'exec-path) exec-path))
        (apply function arguments))
    (apply function arguments)))

(defun gdev--compilation-inherit-environment (function &rest arguments)
  "Come `gdev-inherit-environment', per FUNCTION `compilation-start'.
Il buffer di compilazione conserva l'ambiente, così anche la ripetizione
(recompile, tasto g) usa le stesse versioni degli strumenti."
  (gdev-require-project-environment)
  (let ((local (local-variable-p 'process-environment))
        (environment process-environment)
        (path exec-path)
        (buffer (apply #'gdev-inherit-environment function arguments)))
    (when (and local (buffer-live-p buffer))
      (with-current-buffer buffer
        (setq-local process-environment environment
                    exec-path path)))
    buffer))

(advice-add 'compilation-start :around #'gdev--compilation-inherit-environment)
(dolist (function '(shell-command shell-command-to-string org-babel-eval))
  (advice-add function :around #'gdev-inherit-environment))

;;;; Esecuzione di comandi

(defun gdev-shell-quote (argument)
  "Proteggi ARGUMENT per la shell soltanto quando contiene caratteri speciali.
Le parole composte da lettere, cifre e da - + % , . / : = @ _ restano
leggibili, per esempio -std=c++23. Un = iniziale resta protetto, perché
zsh lo espande nel percorso di un comando."
  (if (and (not (eq system-type 'windows-nt))
           (string-match-p "\\`[-+%,./:@_0-9A-Za-z][-+%,./:=@_0-9A-Za-z]*\\'" argument))
      argument
    (shell-quote-argument argument)))

(defun gdev-command-line (program &rest arguments)
  "Restituisce una riga di comando shell che esegue PROGRAM con ARGUMENTS.
Ogni elemento è protetto per la shell (quoting) quando serve.  ARGUMENTS
può contenere liste annidate; i nil vengono scartati."
  (mapconcat #'gdev-shell-quote
             (cons program (delq nil (flatten-tree arguments)))
             " "))

(defun gdev-compile (command name &optional directory interactive)
  "Esegue il comando shell COMMAND in un buffer di compilazione *NAME*.
DIRECTORY, se omessa, è la radice del progetto.  Con INTERACTIVE non nil
il buffer accetta testo in ingresso (comint), utile a un profilatore
(profiler) o a un interprete interattivo (REPL) di prova.  Restituisce il
buffer di compilazione."
  (let ((default-directory (or directory (gdev-project-root))))
    (compilation-start command interactive (lambda (_mode) (format "*%s*" name)))))

;;;; Scelta del programma per esecuzione, debugger e profilatore

(defcustom gdev-build-directory-patterns
  '("build" "build-*" "cmake-build-*" "out" "bin" "target")
  "Modelli glob delle cartelle che contengono i programmi compilati.
I modelli sono relativi alla radice del progetto."
  :type '(repeat string))

(defvar gdev-program-history nil "Programmi scelti con `gdev-read-program'.")
(defvar gdev-program-arguments-history nil "Argomenti dati ai programmi.")
(defvar gdev--last-program (make-hash-table :test #'equal)
  "Radice del progetto -> ultimo (PROGRAM . ARGUMENTS) scelto lì.")

(declare-function gdev-build-program-context "../modules/tools/build/config" (root))

(defun gdev-project-programs (root)
  "Restituisce i file eseguibili nelle cartelle di compilazione di ROOT.
Usa il catalogo CMake o Meson se presente. Altrimenti cerca nelle
cartelle note ed esclude librerie, oggetti e file interni di configurazione."
  (let ((context (when (fboundp 'gdev-build-program-context) (gdev-build-program-context root))))
    (mapcar
     (lambda (file) (file-relative-name file root))
     (if (plist-get context :catalog)
         (plist-get context :programs)
       (let ((directories
              (seq-filter #'file-directory-p
                          (if context (list (plist-get context :directory))
                            (cl-loop for pattern in gdev-build-directory-patterns
                                     append (file-expand-wildcards (expand-file-name pattern root)))))))
         (when directories
           (apply #'process-lines-ignore-status
                  "find" (append directories
                                 '("-maxdepth" "4" "-type" "f" "-perm" "-u+x"
                                   "-not" "-path" "*/CMakeFiles/*"
                                   "-not" "-name" "*.dylib" "-not" "-name" "*.so*"
                                   "-not" "-name" "*.a" "-not" "-name" "*.o"
                                   "-not" "-name" "*.sh" "-not" "-name" "*.py")))))))))

(defun gdev-read-program (prompt &optional with-arguments root)
  "Chiede con PROMPT un programma da eseguire nel progetto corrente.
Propone gli eseguibili trovati da `gdev-project-programs' e ricorda
l'ultima scelta per ROOT (predefinito: il progetto corrente).
Con WITH-ARGUMENTS chiede anche gli
argomenti.  Restituisce (ABSOLUTE-PROGRAM . ARGUMENT-STRING)."
  (let* ((root (or root (gdev-project-root)))
         (last (gethash root gdev--last-program))
         (candidates (gdev-project-programs root))
         (previous (and (or (member (car last) candidates)
                            (not (gdev-project-file-exists-p root "CMakeLists.txt")))
                        (car last) (file-executable-p (expand-file-name (car last) root)) (car last)))
         (suggested (or previous (when (not (cdr candidates)) (car candidates))))
         (program (completing-read (format-prompt prompt suggested)
                                   candidates nil nil nil
                                   'gdev-program-history suggested))
         (absolute (expand-file-name program root)))
    (unless (and (file-regular-p absolute) (file-executable-p absolute))
      (user-error "Programma da compilare o non eseguibile: %s" (abbreviate-file-name absolute)))
    (let ((arguments (if with-arguments
                         (read-string "Argomenti: " (cdr last)
                                      'gdev-program-arguments-history)
                       (or (cdr last) ""))))
      (puthash root (cons program arguments) gdev--last-program)
      (cons absolute arguments))))

;;;; Piccole utilità

(defcustom gdev-sensitive-file-regexps
  '("\\(?:^\\|/\\)\\.env\\(?:\\.\\|\\'\\)"
    "\\.\\(?:age\\|asc\\|gpg\\|key\\|p12\\|pem\\|pfx\\)\\'"
    "/\\.\\(?:gnupg\\|ssh\\)/"
    "/\\.\\(?:envrc\\|git-credentials\\|netrc\\|npmrc\\|pypirc\\|authinfo\\)\\'"
    "/\\.aws/credentials\\'")
  "Espressioni regolari dei file con segreti, esclusi da copie e cronologie.
Per questi file Emacs non scrive copie di sicurezza né salvataggi automatici,
e la cronologia delle versioni e delle modifiche li salta."
  :type '(repeat regexp)
  :group 'gdev)

(defun gdev-sensitive-file-p (file)
  "Indica se FILE, un percorso, può contenere segreti secondo
`gdev-sensitive-file-regexps'."
  (and (stringp file)
       (let ((case-fold-search nil))
         (seq-some (lambda (regexp) (string-match-p regexp file)) gdev-sensitive-file-regexps))))

(defun gdev-project-build-root ()
  "Radice del progetto usata da compilazione, esecuzione, test, debug e profilo.
La sceglie il linguaggio del documento (gestore `:build-root') o il modulo di
compilazione, quando c'è; altrimenti è la radice del progetto."
  (if (fboundp 'gdev-build--root) (gdev-build--root) (gdev-project-root)))

(defun gdev-read-process (&optional prompt)
  "Scegli con PROMPT un processo dell'utente e restituisci il suo PID."
  (let* ((candidates
          (cl-loop for pid in (list-system-processes)
                   for attributes = (process-attributes pid)
                   when (equal (alist-get 'user attributes) user-login-name)
                   collect (cons (format "%7d  %s" pid (or (alist-get 'args attributes)
                                                           (alist-get 'comm attributes)))
                                 pid)))
         (choice (completing-read (or prompt "Collegati al processo: ") candidates nil t)))
    (cdr (assoc choice candidates))))

(defun gdev-json-text (value)
  "VALUE come testo JSON, da inserire in un buffer o da stampare.
`json-serialize' restituisce byte UTF-8: inseriti così nel buffer, un
carattere non ASCII diventerebbe una sequenza di byte grezzi."
  (decode-coding-string (json-serialize value) 'utf-8-unix))

(defun gdev-completion-table-with-metadata (table metadata)
  "TABLE con i METADATA di completamento indicati, come un alist.
`completion-table-with-metadata' esiste solo da Emacs 31, e la versione
minima è la 30.1."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata ,@metadata)
      (complete-with-action action table string predicate))))

(defun gdev-profile-server-name (profile)
  "Nome del server di Emacs per PROFILE: «server» senza profilo.
Un profilo ha stato isolato, e deve avere anche il suo server: altrimenti,
con l'Emacs abituale già aperto, `emacsclient' e i messaggi di registrazione
di Git partiti da un suo terminale finirebbero nell'altra istanza."
  (if (and (stringp profile) (not (string-empty-p profile)))
      (concat "gdev-" profile)
    "server"))

(defun gdev-directory-empty-p (directory)
  "Indica se DIRECTORY è vuota, senza contare i file che macOS vi crea da solo.
Il Finder scrive `.DS_Store' in ogni cartella che si visita: `directory-empty-p'
la riterrebbe piena anche se l'utente non vi ha messo nulla."
  (seq-every-p (lambda (name) (equal name ".DS_Store"))
               (directory-files directory nil directory-files-no-dot-files-regexp t)))

(defun gdev-load-custom-file (file)
  "Carica le preferenze salvate in FILE; un file guasto non interrompe l'avvio.
Un custom.el troncato o modificato a mano farebbe fallire `require' di
`gdev-core', e con esso ogni modulo e ogni sottocomando di `gdev'."
  (condition-case err
      (load file 'noerror 'nomessage)
    (error
     (display-warning 'gdev (format "Preferenze salvate non caricate da %s: %s"
                                    (abbreviate-file-name file) (error-message-string err))
                      :error)
     nil)))

(defun gdev-shell-split (string)
  "Divide STRING in argomenti con le virgolette e le barre inverse di una shell.
Apici singoli e doppi, come in Esegui: `split-string-and-unquote' leggerebbe
solo le virgolette doppie dello stile di Lisp."
  (split-string-shell-command (or string "")))

(defun gdev-read-file-contents (file)
  "Restituisce il contenuto di FILE come stringa, o nil se non è leggibile."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun gdev-window-state-put (state window &optional ignore)
  "Ripristina STATE in WINDOW con IGNORE anche sul terminale di Emacs 30.
Il lettore 30 usa per errore `min-weight' per la larghezza a caratteri.
L'alias locale non modifica lo stato salvato né le restrizioni di misura."
  (let ((head (copy-tree (car state))))
    (when (and (version< emacs-version "31") (assq 'min-width head))
      (setf (alist-get 'min-weight head) (alist-get 'min-width head)))
    (window-state-put (cons head (cdr state)) window ignore)))

(provide 'gdev-lib)
;;; gdev-lib.el ends here
