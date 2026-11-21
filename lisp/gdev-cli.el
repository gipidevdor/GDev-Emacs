;;; gdev-cli.el --- Il comando gdev: install, sync, doctor... -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; bin/gdev esegue Emacs in modalità non interattiva (batch) con questo
;; file.  Ogni comando è una funzione `gdev-cli-COMMAND' che restituisce lo
;; stato di uscita (nil vale 0):
;;
;;   gdev install      configurazione privata da templates/, ambiente, sync
;;   gdev sync [-u]    installa ciò che serve ai moduli attivi, rimuove ciò
;;                     che non serve più, compila; -u aggiorna anche i
;;                     pacchetti; --no-docs salta lo scaricamento della
;;                     documentazione locale (offline). --native compila
;;                     anche in codice nativo
;;   gdev upgrade      aggiorna la copia di lavoro (git pull) e i pacchetti
;;   gdev fork-merge PACCHETTO BASE NUOVO prepara un merge in una copia temporanea
;;   gdev rollback [REV] prepara una copia di recupero di una revisione Git
;;   gdev --profile NOME COMANDO gestisce configurazione e stato del profilo
;;   gdev [--profile NOME] emacs [ARGOMENTI] avvia Emacs con la configurazione GDev
;;   gdev doctor       diagnosi dell'ambiente, con il rimedio a ogni problema
;;   gdev stato verifica [FILE] | copie | copia [FILE] | recupera COPIA NUOVA_CARTELLA
;;                     verifica, copia o recupera lo stato del profilo
;;   gdev env          salva l'ambiente dell'interprete dei comandi (shell)
;;                     per l'Emacs grafico
;;   gdev compile      compila il nucleo, i moduli attivi e la configurazione
;;                     privata. --native compila anche nucleo e moduli in nativo;
;;                     -w mostra gli avvisi
;;   gdev clean        elimina il bytecode del progetto e dei tre file privati
;;   gdev bench [N]    misura N volte l'avvio grafico (5 se omesso)
;;   gdev docs         rigenera docs/keymap.md dalle mappe dei tasti
;;   gdev audit        inventario JSON di moduli, menu, tasti e viste
;;   gdev test         esegue i test ERT con stato e configurazione temporanei
;;   gdev assurance SOTTOCOMANDO legge l'archivio di assicurazione del progetto
;;                     corrente, senza modificarlo: status, list [STATO],
;;                     show ID, verify, assess ID
;;   gdev info         versioni, cartelle, moduli attivi
;;   gdev agent        inventario JSON e azioni su un'istanza Emacs scelta
;;
;; Niente qui stampa un segreto o scrive nella copia di lavoro (checkout),
;; tranne i file compilati (ignorati da Git) e docs/keymap.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'bytecomp)

(defvar gdev-config-directory)          ; early-init.el
(add-to-list 'load-path (expand-file-name "lisp/" gdev-config-directory))

(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-handlers)
(require 'gdev-env)

;; Con questa variabile attiva, package.el riscrive il file di attivazione
;; dopo ogni installazione; sync lo riscrive una volta sola, alla fine.
(setq package-quickstart nil)

(defvar package-selected-packages)
(defvar gdev-active-profile)
(defvar package-alist)
(defvar gdev-user-directory)
(declare-function package-refresh-contents "package")
(declare-function package-initialize "package")
(declare-function package-quickstart-refresh "package")
(declare-function package-autoremove "package")
(declare-function package-upgrade-all "package")
(declare-function package-vc-upgrade-all "package-vc")
(declare-function gdev-treesit-install-grammars "../modules/tools/tree-sitter/config" (&optional jobs))
(declare-function gdev-doctor-run "gdev-doctor")
(declare-function gdev-doctor-format "gdev-doctor")
(declare-function gdev-fork-merge "gdev-fork-merge" (package base incoming))
(declare-function ert-run-tests-batch "ert" (&optional selector))
(declare-function ert-stats-completed-unexpected "ert" (stats))
(declare-function comp-el-to-eln-filename "comp.c")
(defvar comp-files-queue)
(defvar comp-async-compilations)
(defvar comp-async-buffer-name)
(defvar native-comp-always-compile)
(defvar native-comp-async-on-battery-power)
(defvar native-comp-async-report-warnings-errors)
(defvar native-comp-async-all-done-hook)
(defvar native-comp-async-env-modifier-form)
(defvar native-comp-async-jobs-number)

;;;; Uscita

(defun gdev-cli--run (program &rest arguments)
  "Esegue PROGRAM con ARGUMENTS mostrandone l'output man mano.
Restituisce lo stato di uscita.  `call-process' con destinazione t scrive nel
buffer corrente: in batch l'output non comparirebbe sull'uscita standard."
  (let ((process (make-process :name "gdev-cli" :command (cons program arguments)
                               :connection-type 'pipe :noquery t
                               :filter (lambda (_process output) (princ output)))))
    (while (process-live-p process)
      (accept-process-output process 0.2))
    (accept-process-output process 0)
    (process-exit-status process)))

(defun gdev-cli--say (format-string &rest arguments)
  "Stampa FORMAT-STRING con ARGUMENTS e un a capo sull'uscita standard."
  (princ (concat (apply #'format format-string arguments) "\n")))

(defun gdev-cli--step (title)
  "Annuncia il passo TITLE."
  (gdev-cli--say "\n▸ %s" title))

;;;; Passi comuni

(defun gdev-cli--load-core ()
  "Carica le librerie del nucleo come fa init.el, senza caricare i moduli."
  (dolist (feature '(gdev-core gdev-keys gdev-commands))
    (require feature)))

(defun gdev-cli--read-modules (&optional strict)
  "Legge l'init.el sorgente in `gdev-modules'.  Con STRICT propaga gli errori."
  (let ((init-file-debug (or strict init-file-debug)))
    (gdev-modules-load-selection t))
  (gdev-cli--say "  %d moduli attivi (%s)" (length gdev-modules)
                 (if (file-exists-p (gdev-user-file "init.el"))
                     (abbreviate-file-name (gdev-user-file "init.el"))
                   "templates/init.el: esegui gdev install per personalizzarlo")))

(defun gdev-cli--packages-initialize ()
  "Attiva i pacchetti locali e quelli già installati."
  (require 'package)
  (package-initialize))

(defun gdev-cli--installed ()
  "Restituisce i nomi dei pacchetti installati."
  (mapcar #'car package-alist))

(defun gdev-cli--compile-files (&optional include-bundled)
  "Restituisce i sorgenti del nucleo e dei moduli attivi o automatici.
Aggiunge quelli dei pacchetti inclusi se INCLUDE-BUNDLED è non nil."
  (append (cl-remove-if (lambda (file) (string-suffix-p "/gdev-cli.el" file))
                        (directory-files (gdev-config-file "lisp/") t "\\`gdev-.*\\.el\\'"))
          (unless (gdev-module-p :ui 'workbench)
            (gdev-module-shared-sources))
          (cl-loop for (category module . _) in gdev-modules
                   append (gdev-module-source-files category module))
          (cl-loop for (module . _) in gdev-auto-modules-catalogue
                   unless (gdev-module-p :lang module)
                   when (file-regular-p (gdev-module-file :lang module ".el"))
                   append (gdev-module-source-files :lang module))
          (when include-bundled
            (cl-loop for (name . _) in gdev-bundled-packages
                     when (memq name (bound-and-true-p package-activated-list))
                     append (cl-remove-if
                             (lambda (file)
                               (string-match-p "-\\(?:pkg\\|autoloads\\|tests?\\|subtest\\)\\.el\\'" file))
                             (directory-files (gdev-bundled-package-directory name) t
                                              "\\`[^.].*\\.el\\'"))))))

(defun gdev-cli--compile (&optional show-warnings)
  "Compila in bytecode il nucleo, i moduli attivi e i pacchetti inclusi.
La compilazione verifica che i pacchetti dei moduli siano disponibili localmente.
Con SHOW-WARNINGS stampa anche gli avvisi del compilatore.
Restituisce il numero di file non compilati."
  (let ((files (gdev-cli--compile-files t))
        (byte-compile-warnings (if show-warnings t nil))
        (byte-compile-verbose nil)
        (failed 0)
        (source-only 0))
    (dolist (file files)
      (pcase (let ((inhibit-message (not show-warnings))
                   (gdev--bundled-packages-only (not (gdev-private-module-file-p file))))
               (byte-compile-file file))
        ('no-byte-compile (cl-incf source-only))
        ('nil
         (cl-incf failed)
         (gdev-cli--say "  ✗ %s" (file-relative-name file gdev-config-directory)))))
    (gdev-cli--say "  %d file compilati, %d non riusciti"
                   (- (length files) failed source-only) failed)
    (when (> source-only 0)
      (gdev-cli--say "  solo sorgente (no-byte-compile): %d" source-only))
    failed))

(defun gdev-cli--compile-private-file (file)
  "Compila FILE e pubblica il bytecode solo se il sorgente è ancora lo stesso."
  (let* ((destination (concat file "c"))
         (timestamp (file-attribute-modification-time (file-attributes (file-truename file))))
         (temporary (make-temp-file (concat destination ".") nil ".elc"))
         (original-dest-function byte-compile-dest-file-function)
         (byte-compile-dest-file-function
          (lambda (source)
            (if (equal source file) temporary (funcall original-dest-function source)))))
    (unwind-protect
        (with-file-modes #o600
          (let ((result (byte-compile-file file)))
            (cond
             ((not (equal timestamp (file-attribute-modification-time
                                     (file-attributes (file-truename file)))))
              (gdev-cli--say "  %s è cambiato durante la compilazione" (file-name-nondirectory file))
              nil)
             ((eq result 'no-byte-compile)
              (when (file-exists-p destination) (delete-file destination))
              result)
             (result
              ;; Anche un salvataggio prima del rename rende il .el più recente.
              (set-file-times temporary timestamp)
              (rename-file temporary destination t)
              result))))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun gdev-cli--compile-private (show-warnings)
  "Compila i file privati esistenti.  Restituisce il numero di errori."
  (let ((byte-compile-warnings (and show-warnings t))
        (byte-compile-verbose nil)
        (failed 0))
    (dolist (name gdev-private-config-names)
      (let ((file (gdev-user-file (concat name ".el"))))
        (when (file-exists-p file)
          (pcase (gdev-cli--compile-private-file file)
            ('t (gdev-cli--say "  compilato: %s" (abbreviate-file-name file)))
            ('no-byte-compile
             (gdev-cli--say "  solo sorgente (no-byte-compile): %s" (abbreviate-file-name file)))
            (_ (cl-incf failed)
               (gdev-cli--say "  ✗ %s" (abbreviate-file-name file)))))))
    failed))

(defun gdev-cli--jobs ()
  "Determina quanti processi indipendenti può usare il comando.
`GDEV_JOBS' permette di scegliere un limite a partire da uno."
  (let ((processors (max 1 (if (fboundp 'num-processors) (num-processors) 2)))
        (configured (getenv "GDEV_JOBS")))
    (if configured
        (progn
          (unless (string-match-p "\\`[1-9][0-9]*\\'" configured)
            (user-error "GDEV_JOBS deve essere un intero positivo"))
          (min processors (string-to-number configured)))
      (min processors (max 2 (min 4 (/ processors 2)))))))

(defun gdev-cli--native (&optional show-warnings jobs)
  "Compila in parallelo il nucleo e i moduli attivi in codice nativo.
Con SHOW-WARNINGS mostra anche gli avvisi. JOBS limita i processi.
Restituisce il numero di errori."
  (unless (and (fboundp 'native-comp-available-p) (native-comp-available-p))
    (user-error "Questa versione di Emacs non supporta la compilazione nativa"))
  (require 'comp)
  (gdev-cli--step "Compilazione nativa")
  (let* ((files (gdev-cli--compile-files))
         (finished nil)
         (native-comp-async-jobs-number (or jobs (gdev-cli--jobs)))
         (native-comp-async-on-battery-power t)
         (native-comp-async-report-warnings-errors nil)
         ;; Il bytecode è appena stato riscritto.  Emacs usa l'oggetto nativo
         ;; solo se è aggiornato anche rispetto al bytecode appena prodotto.
         (native-comp-always-compile t)
         (native-comp-async-all-done-hook (list (lambda () (setq finished t))))
         (native-comp-async-env-modifier-form
          `(progn
             (load ,(gdev-config-file "early-init.el") nil t t)
             (setq native-comp-jit-compilation nil package-quickstart nil)
             (require 'package)
             (package-initialize)
             (require 'gdev-modules)
             (setq gdev-modules ',gdev-modules
                   use-package-ensure-function #'ignore)
             (gdev-modules--add-private-load-path))))
    (gdev-cli--say "  fino a %d processi di compilazione" native-comp-async-jobs-number)
    (native-compile-async files)
    (when (or comp-files-queue (> (hash-table-count comp-async-compilations) 0))
      (while (not finished)
        (accept-process-output nil 0.1)))
    (let ((failures
           (seq-filter (lambda (file)
                         (let ((native (comp-el-to-eln-filename file)))
                           (or (file-newer-than-file-p file native)
                               (file-newer-than-file-p (byte-compile-dest-file file) native))))
                       files)))
      (when (or show-warnings failures)
        (when-let* ((log (get-buffer comp-async-buffer-name)))
          (princ (with-current-buffer log (buffer-string)))))
      (dolist (file failures)
        (gdev-cli--say "  ✗ %s" (file-relative-name file gdev-config-directory)))
      (gdev-cli--say "  %d file nativi pronti, %d non riusciti"
                     (- (length files) (length failures)) (length failures))
      (length failures))))

(defvar gdev-cli--modules-loaded nil "Non nil se i moduli sono già caricati.")

(defun gdev-cli--load-modules ()
  "Carica una volta i moduli attivi, che registrano gestori e controlli.
Qui i pacchetti non si installano: `:ensure' è disattivato."
  (unless gdev-cli--modules-loaded
    (setq gdev-cli--modules-loaded t)
    (let ((use-package-ensure-function #'ignore))
      (pcase-dolist (`(,category ,module . ,_) gdev-modules)
        (gdev-modules--load category module)))))

(defun gdev-cli--remove-unused ()
  "Rimuove i pacchetti inutilizzati dalla cartella ELPA dell'utente."
  (let ((needed (delete-dups (append gdev--ensured-packages gdev-packages
                                    (mapcar #'car gdev-bundled-packages)))))
    (setq package-selected-packages needed)
    (let ((before (gdev-cli--installed)))
      (condition-case nil
          (package-autoremove t)          ; Emacs 31: senza conferma
        (wrong-number-of-arguments
         (cl-letf (((symbol-function 'y-or-n-p) #'always))
           (package-autoremove))))
      (let ((removed (cl-set-difference before (gdev-cli--installed))))
        (gdev-cli--say "  %d pacchetti tenuti, %d rimossi%s"
                       (length (gdev-cli--installed)) (length removed)
                       (if removed (format ": %s" (mapconcat #'symbol-name removed " ")) ""))))))

(defun gdev-cli--install-docsets ()
  "Scarica la documentazione locale (offline) dichiarata dai linguaggi attivi."
  (when (gdev-module-p :tools 'lookup)
    (require 'devdocs nil t)
    (if (not (fboundp 'devdocs-install))
        (gdev-cli--say "  devdocs non è ancora installato: esegui di nuovo gdev sync")
      (let ((wanted (delete-dups (apply #'append (mapcar #'cdr (gethash :docsets gdev--handlers)))))
            (installed 0))
        (dolist (slug wanted)
          (unless (file-directory-p (expand-file-name slug (bound-and-true-p devdocs-data-dir)))
            (condition-case err
                (progn (devdocs-install slug) (cl-incf installed))
              (error (gdev-cli--say "  %s: %s" slug (error-message-string err))))))
        (gdev-cli--say "  %d documentazioni locali (offline), %d scaricate ora" (length wanted) installed)))))
(declare-function devdocs-install "devdocs")

;;;; Comandi

(defun gdev-cli-sync (&rest arguments)
  "Allinea pacchetti, file compilati, grammatiche e documentazione.
ARGUMENTS può contenere -u per aggiornare prima tutti i pacchetti."
  (let ((upgrade (member "-u" arguments))
        (jobs (gdev-cli--jobs))
        (failed 0))
    (gdev-cli--step "Moduli")
    (gdev-cli--read-modules t)
    (gdev-cli--step "Pacchetti")
    (gdev-cli--packages-initialize)
    (let ((before (gdev-cli--installed)))
      (when (and upgrade (cl-set-difference before (mapcar #'car gdev-bundled-packages)))
        (gdev-cli--say "  aggiornamento dei pacchetti personali")
        (package-refresh-contents)
        (package-upgrade-all nil)
        (require 'package-vc)
        (package-vc-upgrade-all))
      (let ((init-file-debug t))
        (gdev-modules--load-private "packages" t))
      (gdev-cli--load-core)
      (gdev-cli--step "Compilazione dei sorgenti locali")
      (setq failed (gdev-cli--compile))
      (let ((added (cl-set-difference (gdev-cli--installed) before)))
        (when added
          (gdev-cli--say "  installati: %s" (mapconcat #'symbol-name added " ")))))
    ;; Caricare i moduli registra i loro gestori e controlli, e le loro
    ;; dichiarazioni `gdev-package' (pacchetti da repository Git).
    (gdev-cli--load-modules)
    (cl-incf failed (length gdev-failed-modules))
    (when (zerop failed)
      (gdev-cli--step "Compilazione privata")
      (cl-incf failed (gdev-cli--compile-private nil)))
    (gdev-cli--step "Rimozione dei pacchetti inutilizzati")
    ;; L'elenco dei pacchetti necessari nasce dalla compilazione: se un file
    ;; non si è compilato l'elenco può essere incompleto, quindi questa volta
    ;; non si rimuove nulla.
    (if (zerop failed)
        (gdev-cli--remove-unused)
      (gdev-cli--say "  saltato: prima correggi i file che non si compilano"))
    (when (fboundp 'gdev-treesit-install-grammars)
      (gdev-cli--step "Grammatiche tree-sitter")
      (let ((missing (gdev-treesit-install-grammars jobs)))
        (gdev-cli--say (if missing (format "  non installate: %s" missing) "  tutte installate"))
        (cl-incf failed (length missing))))
    (unless (member "--no-docs" arguments)
      (gdev-cli--step "Documentazione locale (offline)")
      (gdev-cli--install-docsets))
    (gdev-cli--step "File di attivazione")
    (package-quickstart-refresh)
    (gdev-cli--say "  %s" (abbreviate-file-name package-quickstart-file))
    (when (and (zerop failed) (member "--native" arguments))
      (setq failed (gdev-cli--native nil jobs)))
    (gdev-cli--say "\n%s Riavvia Emacs per applicare le modifiche."
                   (if (zerop failed) "Fatto." (format "Fatto. Problemi: %d." failed)))
    (if (zerop failed) 0 1)))

(defun gdev-cli-install ()
  "Crea la configurazione privata, salva l'ambiente e sincronizza."
  (gdev-cli--step "Configurazione privata")
  (make-directory (gdev-user-file "snippets/") t)
  (dolist (name gdev-private-config-names)
    (let* ((source (concat name ".el"))
           (target (gdev-user-file source)))
      (if (file-exists-p target)
          (gdev-cli--say "  tenuto   %s" (abbreviate-file-name target))
        (copy-file (gdev-config-file (concat "templates/" source)) target)
        (gdev-cli--say "  creato   %s" (abbreviate-file-name target)))))
  (gdev-cli-env)
  (let ((status (gdev-cli-sync)))
    (gdev-cli-doctor)
    (when (and (zerop status) (eq system-type 'darwin))
      (require 'gdev-install)
      (gdev-cli--say "Ingresso grafico: %s" (gdev-install-macos-application)))
    status))

(defun gdev-cli--git (&rest arguments)
  "Esegui Git con ARGUMENTS nella copia di GDev-Emacs e restituisci l'output."
  (let ((default-directory gdev-config-directory))
    (with-temp-buffer
      (let* ((status (apply #'process-file "git" nil (list (current-buffer) t) nil arguments))
             (output (string-trim (buffer-string))))
        (unless (eq status 0)
          (user-error "%s" (if (string-empty-p output) "Comando Git non riuscito" output)))
        output))))

(defun gdev-cli--previous-revision ()
  "Leggi la revisione di questo checkout, importando il registro storico."
  (let* ((checkout (file-truename gdev-config-directory))
         (old (gdev-state-db--legacy "revisione-precedente")))
    (or (cdar (gdev-state-db-entries "aggiornamento" checkout "revisione_precedente"))
        (when (file-readable-p old)
          (gdev-state-db-with (db t)
            (let ((scope (gdev-state-db--scope db "aggiornamento" checkout t)))
              (or (cdar (gdev-state-db--entries db scope "revisione_precedente"))
                  (gdev-state-db-set "aggiornamento" checkout "revisione_precedente"
                                     (string-trim (gdev-read-file-contents old))))))))))

(defun gdev-cli-upgrade ()
  "Aggiorna GDev-Emacs e conserva la revisione da usare per il recupero."
  (gdev-cli--step "Copia di lavoro di GDev-Emacs")
  (unless (file-exists-p (gdev-config-file ".git"))
    (user-error "Esegui gdev upgrade da una copia di lavoro Git"))
  (unless (string-empty-p (gdev-cli--git "status" "--porcelain"))
    (user-error "Modifiche locali presenti. Registrale prima di ripetere gdev upgrade"))
  (let ((before (gdev-cli--git "rev-parse" "HEAD")))
    (gdev-cli--say "  %s" (gdev-cli--git "pull" "--ff-only"))
    (unless (equal before (gdev-cli--git "rev-parse" "HEAD"))
      (gdev-state-db-set "aggiornamento" (file-truename gdev-config-directory) "revisione_precedente" before)))
  ;; Il registro e il codice di sync devono appartenere alla nuova revisione.
  (let* ((process-environment (copy-sequence process-environment))
         (default-directory gdev-config-directory)
         (status (progn
                   (setenv "EMACS" (expand-file-name invocation-name invocation-directory))
                   (gdev-cli--run (gdev-config-file "bin/gdev") "sync" "-u"))))
    (unless (eql status 0)
      (gdev-cli--say "gdev sync non è riuscito (stato %s): l'aggiornamento è incompleto." status))
    (if (integerp status) status 1)))

(defun gdev-cli-fork-merge (package base incoming)
  "Prepara il merge del fork PACKAGE a partire da BASE e INCOMING."
  (require 'gdev-fork-merge)
  (let* ((preview (gdev-fork-merge package base incoming))
         (directory (car preview))
         (conflicts (cdr preview)))
    (gdev-cli--say "Anteprima in %s" directory)
    (if conflicts
        (progn
          (gdev-cli--say "Conflitti da risolvere:")
          (dolist (file conflicts) (gdev-cli--say "  %s" file))
          1)
      (gdev-cli--say "Integrazione pronta per la revisione")
      0)))

(defun gdev-cli-rollback (&optional revision)
  "Prepara un'istanza isolata di GDev alla REVISION precedente."
  (let* ((requested (or revision (gdev-cli--previous-revision)))
         (commit (if (and requested (not (string-empty-p requested)))
                     (gdev-cli--git "rev-parse" "--verify" "--end-of-options"
                                    (concat requested "^{commit}"))
                   (user-error "Indica una revisione, per esempio gdev rollback HEAD~1")))
         (recovery (gdev-state-file (concat "recupero/" commit "/")))
         (checkout (expand-file-name "sorgenti" recovery)))
    (unless (file-exists-p checkout)
      (make-directory recovery t)
      (gdev-cli--git "worktree" "add" "--detach" checkout commit))
    (unless (and (file-exists-p (expand-file-name ".git" checkout))
                 (equal commit (gdev-cli--git "-C" checkout "rev-parse" "HEAD")))
      (user-error "La copia di recupero non corrisponde alla revisione richiesta"))
    (gdev-cli--say "Revisione %s pronta in %s" (substring commit 0 12) (abbreviate-file-name checkout))
    (gdev-cli--say "Avviala con")
    (gdev-cli--say "  env -u GDEV_PROFILE GDEV_USER_DIR=%s GDEV_STATE_DIR=%s %s"
                   (shell-quote-argument (expand-file-name "configurazione" recovery))
                   (shell-quote-argument (expand-file-name "stato" recovery))
                   (gdev-command-line (expand-file-name invocation-name invocation-directory)
                                      "--init-directory" checkout))
    0))

(defun gdev-cli-env ()
  "Salva l'ambiente di questa shell per l'Emacs avviato dal Dock."
  (gdev-cli--step "Ambiente della shell")
  (gdev-env-save-current)
  (gdev-cli--say "  salvato %s (nessun segreto: solo %d variabili elencate)"
                 (abbreviate-file-name (gdev-env-file)) (length gdev-env-variables))
  0)

(defun gdev-cli-doctor ()
  "Controlla l'installazione; stato di uscita 1 se manca qualcosa che serve."
  (gdev-cli--step "Diagnosi dell'ambiente (doctor)")
  (gdev-cli--read-modules)
  (gdev-cli--packages-initialize)
  (gdev-cli--load-core)
  (gdev-cli--load-modules)
  (require 'gdev-doctor)
  (let ((results (gdev-doctor-run)))
    (princ (gdev-doctor-format results))
    (if (cl-find 'warning results :key #'car) 1 0)))

(defun gdev-cli-compile (&rest arguments)
  "Compila in bytecode il nucleo, i moduli attivi e i file privati.
Fra gli ARGUMENTS, -w mostra gli avvisi e --native compila anche in nativo."
  (let ((jobs (and (member "--native" arguments) (gdev-cli--jobs)))
        (warnings (member "-w" arguments)))
    (gdev-cli--step "Compilazione")
    (gdev-cli--read-modules t)
    (gdev-cli--packages-initialize)
    (let ((init-file-debug t))
      (gdev-modules--load-private "packages" t))
    (gdev-cli--load-core)
    (let ((failed (gdev-cli--compile warnings)))
      (when (zerop failed)
        (gdev-cli--load-modules)
        (cl-incf failed (length gdev-failed-modules))
        (when (zerop failed)
          (gdev-cli--step "Compilazione privata")
          (cl-incf failed (gdev-cli--compile-private warnings))))
      (when (and (zerop failed) jobs)
        (setq failed (gdev-cli--native warnings jobs)))
      (when (zerop failed)
        (package-quickstart-refresh))
      (if (zerop failed) 0 1))))

(defun gdev-cli-clean ()
  "Elimina il bytecode della copia di lavoro e dei file privati."
  (let ((files (delete-dups
                (append (directory-files-recursively gdev-config-directory "\\.elc\\'")
                        (seq-filter #'file-exists-p
                                    (mapcar (lambda (name) (gdev-user-file (concat name ".elc")))
                                            gdev-private-config-names))))))
    (mapc #'delete-file files)
    (gdev-cli--say "File compilati eliminati: %d." (length files))
    0))

(defun gdev-cli-bench (&optional count)
  "Avvia COUNT volte l'Emacs grafico (5 se omesso).
Riporta il tempo per caricare la configurazione e quello fino al primo
momento di inattività."
  (let* ((runs (string-to-number (or count "5")))
         (_ (unless (and (string-match-p "\\`[0-9]+\\'" (or count "5")) (> runs 0))
              (user-error "Indica un numero intero di avvii maggiore di zero")))
         (emacs (expand-file-name invocation-name invocation-directory))
         (output (make-temp-file "gdev-bench"))
         (probe (format "(add-hook 'window-setup-hook (lambda () (run-at-time 0 nil (lambda () (with-temp-file %S (prin1 (list (float-time (time-subtract after-init-time before-init-time)) (float-time (time-subtract (current-time) before-init-time)) gcs-done (length gdev-modules)) (current-buffer))) (kill-emacs)))) 100)"
                        output))
         samples)
    (gdev-cli--say "Avvio di %s per %d volte…" (file-name-nondirectory emacs) runs)
    (dotimes (_ runs)
      ;; Con la stessa cartella di avvio di `gdev emacs': senza, Emacs sceglie
      ;; ~/.emacs.d o ~/.config/emacs e il benchmark misura un'altra configurazione.
      (call-process emacs nil nil nil "--init-directory" gdev-config-directory "--eval" probe)
      (push (car (read-from-string (gdev-read-file-contents output))) samples))
    (delete-file output)
    (let* ((init (sort (mapcar #'car samples) #'<))
           (ready (sort (mapcar #'cadr samples) #'<))
           (median (lambda (list) (nth (/ (length list) 2) list))))
      (gdev-cli--say "  configurazione caricata: mediana %.0f ms (min %.0f, max %.0f)"
                     (* 1000 (funcall median init)) (* 1000 (car init)) (* 1000 (car (last init))))
      (gdev-cli--say "  pronto all'uso:          mediana %.0f ms (min %.0f, max %.0f)"
                     (* 1000 (funcall median ready)) (* 1000 (car ready)) (* 1000 (car (last ready))))
      (let ((collections (nth 2 (car samples))))
        (gdev-cli--say "  %d moduli, %d raccolt%s della memoria (garbage collection) all'avvio"
                       (nth 3 (car samples)) collections (if (= collections 1) "a" "e"))))
    0))

(defun gdev-cli-info ()
  "Stampa versioni, cartelle e moduli attivi."
  (gdev-cli--read-modules)
  (require 'package)
  (package-initialize)
  (gdev-cli--say "Emacs            %s (%s)" emacs-version system-configuration)
  (gdev-cli--say "codice nativo    %s   tree-sitter  %s"
                 (if (and (fboundp 'native-comp-available-p) (native-comp-available-p)) "sì" "no")
                 (if (treesit-available-p) "sì" "no"))
  (gdev-cli--say "copia di lavoro  %s" (abbreviate-file-name gdev-config-directory))
  (gdev-cli--say "privata          %s" (abbreviate-file-name gdev-user-directory))
  (gdev-cli--say "stato            %s" (abbreviate-file-name gdev-state-directory))
  (gdev-cli--say "profilo          %s" (or gdev-active-profile "abituale"))
  (gdev-cli--say "pacchetti        %d installati" (length package-alist))
  (gdev-cli--say "moduli           %s"
                 (mapconcat (pcase-lambda (`(,category ,module . ,flags))
                              (format "%s %s%s" category module
                                      (if flags (format " %s" flags) "")))
                            gdev-modules "\n                 "))
  0)

;;;; gdev docs: la mappa dei tasti in Markdown

(defconst gdev-cli--function-key-actions
  '((gdev-debug-dwim . "Avvia o riprendi l'esecuzione passo passo")
    (gdev-debug-terminate . "Termina la sessione di esecuzione passo passo")
    (gdev-debug-restart . "Riavvia la sessione di esecuzione passo passo")
    (gdev-run-dwim . "Esegui il programma")
    (gdev-test-dwim . "Esegui i test")
    (gdev-build . "Compila il progetto")
    (gdev-build-configure . "Configura la compilazione")
    (next-error . "Vai al problema successivo")
    (previous-error . "Vai al problema precedente")
    (dape-breakpoint-toggle . "Attiva o disattiva il punto di interruzione")
    (gdev-debug-next . "Avanza di un passo senza entrare nella funzione")
    (gdev-debug-step-in . "Entra nella funzione")
    (gdev-debug-step-out . "Esci dalla funzione")
    (gdev-find-definition . "Vai alla definizione")
    (gdev-find-references . "Cerca i riferimenti"))
  "Descrizioni italiane dei comandi associati ai tasti funzione.")

(defconst gdev-cli--localleader-modes
  '((c-ts-mode c-ts-base-mode-map "C e C++")
    (lisp-mode lisp-mode-map "Common Lisp")
    (elisp-mode emacs-lisp-mode-map "Emacs Lisp")
    (cperl-mode cperl-mode-map "Perl")
    (python python-base-mode-map "Python")
    (sql gdev-database-mode-map "SQL")
    (sql gdev-postgresql-mode-map "PostgreSQL")
    (nxml-mode nxml-mode-map "XML")
    (web-mode web-mode-map "HTML e modelli di pagina")
    (css-mode css-base-mode-map "CSS")
    (js js-base-mode-map "JavaScript"))
  "Librerie da caricare, con la mappa dei tasti della modalità e il titolo.
Servono alle tabelle di C-c l in docs/keymap.md.")

(defun gdev-cli--keymap-rows (keymap &optional prefix)
  "Restituisce le righe (TASTO DESCRIZIONE) di KEYMAP, in ordine.
Le sottomappe con nome, come C-c g h, compaiono come prefisso seguito dai
loro tasti.  PREFIX è la parte del tasto già percorsa."
  (let (rows seen)
    (map-keymap
     (lambda (event binding)
       ;; Una mappa con genitore elenca anche i tasti del genitore: vale il primo.
       (unless (memq event seen)
         (push event seen)
         (let ((key (concat prefix (key-description (vector event)))))
           (pcase binding
             (`(,(and label (pred stringp)) . ,(and map (pred keymapp)))
              (push (list key (concat label " ›")) rows)
              (setq rows (append (gdev-cli--keymap-rows map (concat key " ")) rows)))
             (`(,(and label (pred stringp)) . ,_)
              (push (list key label) rows))
             ((and (pred symbolp) (guard binding))
              (push (list key (format "`%s`" binding)) rows))))))
     keymap)
    (sort rows (lambda (a b) (string< (car a) (car b))))))

(defun gdev-cli--markdown-table (prefix keymap)
  "Restituisce una tabella Markdown di KEYMAP, con i tasti dopo PREFIX."
  (concat "| Scorciatoia | Azione |\n| --- | --- |\n"
          (mapconcat (pcase-lambda (`(,key ,description))
                       (format "| `%s%s` | %s |\n" prefix key
                               (replace-regexp-in-string "|" "\\\\|" description)))
                     (gdev-cli--keymap-rows keymap) "")))

(defun gdev-cli-docs ()
  "Rigenera docs/keymap.md con i tasti dei moduli di templates/init.el."
  ;; Il modello, non l'init.el privato: la documentazione descrive
  ;; GDev-Emacs così come viene distribuito.
  (let ((gdev-user-directory (make-temp-file "gdev-docs" t)))
    (gdev-modules--load-private "init")
    (delete-directory gdev-user-directory))
  (gdev-cli--packages-initialize)
  (gdev-cli--load-core)
  (gdev-cli--load-modules)
  (let ((file (gdev-config-file "docs/keymap.md")))
    (with-temp-file file
      (insert "# Mappa dei tasti\n\n"
              "Premi `C-h d k` per consultare questa mappa in Emacs. Dopo aver digitato un\n"
              "prefisso, attendi un istante per vedere le scorciatoie del gruppo.\n"
              "Nelle scorciatoie, `C` indica Controllo, `M` indica Meta e `S` indica Maiuscole.\n"
              "Per gli esempi d'uso, consulta i [flussi di lavoro](workflows.md).\n\n"
              "Rigenera questa mappa con `gdev docs` dopo aver modificato le scorciatoie.\n")
      (insert "\n## Tasti funzione\n\n| Scorciatoia | Azione | Comando Emacs |\n| --- | --- | --- |\n")
      (dolist (key '("<f5>" "S-<f5>" "C-S-<f5>" "C-<f5>" "<f6>" "<f7>" "S-<f7>" "<f8>" "S-<f8>"
                     "<f9>" "<f10>" "<f11>" "S-<f11>" "<f12>" "S-<f12>"))
        (when-let* ((command (keymap-lookup global-map key)))
          (insert (format "| `%s` | %s | `%s` |\n" key
                          (alist-get command gdev-cli--function-key-actions "Vedi il comando Emacs")
                          command))))
      (pcase-dolist (`(,key ,map ,label) gdev-leader-groups)
        (let ((keymap (symbol-value map)))
          (insert (format "\n## C-c %s — %s\n\n" key label))
          (insert (if (gdev-cli--keymap-rows keymap)
                      (gdev-cli--markdown-table (format "C-c %s " key) keymap)
                    "Questo gruppo è vuoto quando i relativi moduli sono disattivati.\n"))))
      (insert "\n## C-h d — aiuto di GDev\n\n" (gdev-cli--markdown-table "C-h d " gdev-help-map))
      (insert "\n## C-c l — comandi del linguaggio corrente\n")
      (pcase-dolist (`(,library ,map ,title) gdev-cli--localleader-modes)
        (when (require library nil t)
          (when-let* ((keymap (and (boundp map) (gethash (symbol-value map) gdev--localleader-maps))))
            (insert (format "\n### %s\n\n" title) (gdev-cli--markdown-table "C-c l " keymap))))))
    (gdev-cli--say "Mappa dei tasti aggiornata in %s" (file-relative-name file gdev-config-directory))
    0))

(defun gdev-cli-audit ()
  "Stampa l'inventario JSON della configurazione distribuita."
  (gdev-modules--load-private "init" t)
  (gdev-cli--packages-initialize)
  (gdev-cli--load-core)
  (gdev-cli--load-modules)
  (when gdev-failed-modules
    (error "Moduli non caricati: %S" gdev-failed-modules))
  (require 'gdev-audit)
  (princ (decode-coding-string
          (json-serialize (gdev-audit-inventory gdev-cli--localleader-modes)) 'utf-8-unix))
  (terpri)
  0)

(defun gdev-cli-assurance (&rest arguments)
  "Esegue un sottocomando di sola lettura sull'archivio di assicurazione.
Il nucleo carica da solo, senza moduli né pacchetti."
  (require 'gdev-assurance)
  (gdev-assurance-cli arguments))

(defun gdev-cli-test ()
  "Esegui il corpus ERT in stato e configurazione temporanei."
  (gdev-env--add-tool-directories)
  (load (gdev-config-file "test/gdev-test.el") nil t t)
  (let ((stats (ert-run-tests-batch t)))
    (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))

;;;; Punto di ingresso

(defun gdev-cli--operand-p (argument)
  "Restituisci non nil se ARGUMENT è un operando e non un'opzione."
  (and (not (string-empty-p argument)) (not (string-prefix-p "-" argument))))

(defun gdev-cli--positive-integer-p (argument)
  "Restituisci non nil se ARGUMENT è un intero positivo in base dieci."
  (string-match-p "\\`[1-9][0-9]*\\'" argument))

(defconst gdev-cli-commands
  '(("install" gdev-cli-install)
    ("sync" gdev-cli-sync (:flags "-u" "--no-docs" "--native"))
    ("upgrade" gdev-cli-upgrade)
    ("fork-merge" gdev-cli-fork-merge
     (:operands "PACCHETTO BASE NUOVO" 3 3 gdev-cli--operand-p))
    ("rollback" gdev-cli-rollback (:operands "[REVISIONE]" 0 1 gdev-cli--operand-p))
    ("doctor" gdev-cli-doctor)
    ("test" gdev-cli-test)
    ("stato" gdev-cli-stato (:operands "verifica [FILE] | copie | copia [FILE] | recupera COPIA NUOVA_CARTELLA" 1 3 gdev-cli--operand-p))
    ("env" gdev-cli-env)
    ("compile" gdev-cli-compile (:flags "-w" "--native"))
    ("clean" gdev-cli-clean)
    ("bench" gdev-cli-bench (:operands "[N]" 0 1 gdev-cli--positive-integer-p))
    ("docs" gdev-cli-docs)
    ("audit" gdev-cli-audit)
    ("assurance" gdev-cli-assurance
     (:operands "status | list | show | verify | assess | capability | trace | impact | requests | standards | standard-assess | project | work | taxonomy | suggest | snippets | procedures | procedure-plan | runs | model-check | project-init | project-field | project-requirement | project-bind | work-bind | snippet-preview | snippet-write | procedure-run | procedure-resume | project-report | open | advance | evidence | assess-record | adopt | recover | documents | hooks | sign | sign-amend | confirm | reject | artifact | link | standard-select | standard-proof | standard-decision | decision" 1 6
                 gdev-cli--operand-p))
    ("info" gdev-cli-info)
    ("help" gdev-cli-help))
  "Nome, funzione e firma facoltativa dei comandi di manutenzione.")

(cl-defun gdev-cli-stato (&rest args)
  "Gestisci l'archivio anche quando il profilo non può avviarsi."
  (require 'gdev-state-db-maintenance)
  (pcase args
    ((or '("verifica") `("verifica" ,_))
     (gdev-cli--say "Archivio integro · versione %d" (gdev-state-db-inspect (or (cadr args) (gdev-state-db-file)) t)))
    ('("copie") (gdev-cli--say "%s" (or (when-let* ((copies (gdev-state-db-copies)))
                                          (string-join copies "\n")) "Nessuna copia disponibile")))
    ((or '("copia") `("copia" ,_)) (gdev-cli--say "%s" (gdev-state-db-backup (cadr args))))
    (`("recupera" ,source ,dir) (gdev-cli--say "Archivio recuperato in %s" (gdev-state-db-recover source dir)))
    (_ (gdev-cli--say "%s" (gdev-cli--usage "stato" (nth 2 (assoc "stato" gdev-cli-commands))))
       (cl-return-from gdev-cli-stato 2)))
  0)

(defun gdev-cli--valid-arguments-p (signature arguments)
  "Verifica ARGUMENTS secondo SIGNATURE."
  (pcase signature
    ('nil (null arguments))
    (`(:flags . ,flags) (cl-every (lambda (argument) (member argument flags)) arguments))
    (`(:operands ,_ ,minimum ,maximum ,predicate)
     (and (<= minimum (length arguments) maximum) (cl-every predicate arguments)))))

(defun gdev-cli--usage (name signature)
  "Restituisci la sintassi di NAME a partire da SIGNATURE."
  (concat "Uso: gdev " name
          (pcase signature
            (`(:flags . ,flags) (mapconcat (lambda (flag) (format " [%s]" flag)) flags ""))
            (`(:operands ,label . ,_) (concat " " label)))))

(defun gdev-cli-help ()
  "Stampa i comandi."
  (with-temp-buffer
    (insert-file-contents (locate-library "gdev-cli.el"))
    (goto-char (point-min))
    (re-search-forward "^;;   gdev install")
    (let ((start (line-beginning-position)))
      (re-search-forward "^;;$")
      (gdev-cli--say "Uso: gdev COMANDO [OPZIONI]\n\n%s"
                     (replace-regexp-in-string "^;; " "" (buffer-substring start (line-beginning-position))))))
  0)

(defun gdev-cli-main ()
  "Esegui il comando richiesto e restituisci il suo codice di uscita."
  (let* ((arguments command-line-args-left)
         (name (or (car arguments) "help"))
         (entry (assoc name gdev-cli-commands))
         (function (nth 1 entry))
         (signature (nth 2 entry)))
    (setq command-line-args-left nil)
    (cond
     ((null function)
      (gdev-cli--say "Comando sconosciuto: %s\n" name)
      (gdev-cli-help)
      2)
     ((not (gdev-cli--valid-arguments-p signature (cdr arguments)))
      (gdev-cli--say "%s" (gdev-cli--usage name signature))
      2)
     ((getenv "GDEV_DEBUG")            ; mostra la traccia delle chiamate
      (setq debug-on-error t)
      (or (apply function (cdr arguments)) 0))
     (t
      (condition-case err
          (or (apply function (cdr arguments)) 0)
        (error (gdev-cli--say (concat "gdev %s non riuscito: %s; GDEV_DEBUG=1 mostra"
                                     " la traccia delle chiamate (backtrace)")
                             name (error-message-string err))
               1))))))

(provide 'gdev-cli)
;;; gdev-cli.el ends here
