;;; config.el --- :lang perl: cperl, server di linguaggio, test, profilazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Perl usa cperl-mode, incluso in Emacs, e Perl::LanguageServer, che
;; permette anche l'esecuzione passo passo con il modulo :tools debugger.
;;
;;   C-F5       esegue questo programma con perl -Ilib, in un'area
;;              di testo interattiva
;;   F6         esegue questo file di test (prove -lv); da un modulo, l'intera
;;              serie di test
;;   F5         esecuzione passo passo con punti di interruzione e
;;              ispezione delle variabili
;;   C-c c f    perltidy (anche al salvataggio, se il progetto ha .perltidyrc)
;;   C-c c k    perldoc per la parola sotto il cursore
;;   C-c o r    interprete interattivo di Perl: reply o re.pl se
;;              installati, altrimenti perl -de0
;;   C-c P P    profila questo programma con Devel::NYTProf e apre il rapporto
;;   C-c P c    copertura dei test con Devel::Cover, apre il rapporto
;;   C-c l c    Perl::Critic su tutto il progetto, come elenco cliccabile
;;   C-c l d    esecuzione passo passo con perldb in GUD
;;
;; Perl::Critic mostra le segnalazioni con Flymake quando il progetto
;; ha un .perlcriticrc: le regole sono quelle del progetto, mai
;; imposte da fuori.  Senza server di linguaggio,
;; `perl -c' segnala comunque gli errori di sintassi, ma solo in una cartella
;; autorizzata con `gdev-trust-project': esegue i blocchi BEGIN del file.
;;
;; Ogni strumento viene dal perl attivo (perlbrew, plenv, local::lib),
;; cioè dal primo perl nel PATH. Il cpanfile di GDev elenca i moduli CPAN
;; che il programma d'installazione scarica.

;;; Code:

(require 'seq)
(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)

(defvar cperl-indent-level)
(defvar cperl-close-paren-offset)
(defvar cperl-continued-statement-offset)
(defvar cperl-indent-parens-as-block)
(defvar cperl-indent-subs-specially)
(defvar cperl-tab-always-indent)
(defvar cperl-electric-keywords)
(defvar cperl-electric-parens)
(defvar cperl-invalid-face)
(defvar cperl-highlight-variables-indiscriminately)
(defvar cperl-mode-map)

(defconst gdev-perl-modes '(cperl-mode perl-mode)
  "Modalità principali del codice Perl.")

;;;; Modalità

;; cperl-mode ovunque si userebbe perl-mode, anche con #!/usr/bin/perl.
(add-to-list 'major-mode-remap-alist '(perl-mode . cperl-mode))
;; Test, applicazioni PSGI, script CGI, elenchi di dipendenze.
(add-to-list 'auto-mode-alist '("\\.\\(t\\|psgi\\|cgi\\)\\'" . cperl-mode))
(add-to-list 'auto-mode-alist '("/cpanfile\\'" . cperl-mode))

(setq cperl-indent-level 4
      cperl-close-paren-offset -4
      cperl-continued-statement-offset 4
      cperl-indent-parens-as-block t
      cperl-indent-subs-specially nil
      cperl-tab-always-indent t
      ;; Nessuna abbreviazione che trasforma "if" in un modello mentre scrivi.
      cperl-electric-keywords nil
      cperl-electric-parens nil
      ;; Gli spazi a fine riga sono già evidenziati in ogni buffer di codice.
      cperl-invalid-face nil
      cperl-highlight-variables-indiscriminately t)

;;;; Server di linguaggio

;; La voce predefinita di Eglot esegue "perl -MPerl::LanguageServer".  perl
;; è sempre installato, quindi si cerca il modulo, una volta per ogni perl.
;; Trovare il file costa un semplice avvio di perl; caricare il modulo
;; costerebbe di più.
(defvar gdev-perl--language-server-cache (make-hash-table :test #'equal)
  "Per ogni eseguibile perl, se ha Perl::LanguageServer installato.")

(defun gdev-perl-language-server-p ()
  "Restituisce non nil se il perl attivo ha Perl::LanguageServer."
  (when-let* ((perl (executable-find "perl")))
    (let ((known (gethash perl gdev-perl--language-server-cache 'unknown)))
      (when (eq known 'unknown)
        (setq known (zerop (call-process perl nil nil nil "-e"
                                         "for (@INC) { exit 0 if -f \"$_/Perl/LanguageServer.pm\" } exit 1")))
        (puthash perl known gdev-perl--language-server-cache))
      known)))

(gdev-set-handler :eglot gdev-perl-modes (list :when #'gdev-perl-language-server-p))
(defconst gdev-perl--install-hint
  (format "cpanm --installdeps %s"
          (shell-quote-argument (directory-file-name gdev-config-directory)))
  "Comando che installa i moduli Perl del cpanfile di GDev-Emacs.")

(gdev-doctor-check "Perl::LanguageServer" #'gdev-perl-language-server-p gdev-perl--install-hint)

;; Senza server, `perl -c' segnala comunque gli errori di sintassi.  Nota:
;; `perl -c' esegue i blocchi BEGIN e le dichiarazioni `use' del file: parte
;; solo in una cartella autorizzata, come gli strumenti e gli ambienti di
;; progetto, e conosce `lib/' come Esegui.
(declare-function perl-flymake "perl-mode")
(defvar perl-flymake-command)
(defun gdev-perl-syntax-check-fallback ()
  "Controlla la sintassi con `perl -c' tramite Flymake se manca un server.
Un file scaricato con un blocco BEGIN non deve poter eseguire codice
solo perché è stato aperto: serve che la cartella sia autorizzata."
  (unless (or (file-remote-p default-directory) (gdev-perl-language-server-p))
    (let ((root (gdev-project-root)))
      (when (gdev-project-trusted-p root)
        (require 'perl-mode)
        (setq-local perl-flymake-command
                    (list "perl" "-w" "-c" (concat "-I" (expand-file-name "lib" root))))
        (add-hook 'flymake-diagnostic-functions #'perl-flymake nil t)
        (flymake-mode 1)))))
(gdev-module-add-hook 'cperl-mode-hook #'gdev-perl-syntax-check-fallback)

;;;; Perl::Critic nel buffer, se il progetto ha un file di regole

(defun gdev-perl--critic-profile ()
  "Restituisce il .perlcriticrc del progetto, o nil."
  (when-let* ((directory (locate-dominating-file default-directory ".perlcriticrc")))
    (expand-file-name ".perlcriticrc" directory)))

(defvar-local gdev-perl--critic-process nil
  "Il controllo perlcritic in corso, se c'è.")

(defun gdev-perl-flymake-perlcritic (report-fn &rest _)
  "Fonte Flymake con Perl::Critic; chiama REPORT-FN.
Usa il profilo del progetto.  Il buffer arriva a perlcritic tramite un
canale (pipe), quindi vengono controllate anche le modifiche non salvate.  Le
regole di gravità 4-5 diventano avvisi, quelle inferiori note."
  (when (process-live-p gdev-perl--critic-process)
    (kill-process gdev-perl--critic-process))
  (let ((source (current-buffer))
        (profile (gdev-perl--critic-profile)))
    (save-restriction
      (widen)
      (setq gdev-perl--critic-process
            (make-process
             :name "gdev-perlcritic" :noquery t :connection-type 'pipe
             :buffer (generate-new-buffer " *gdev-perlcritic*")
             :command (list "perlcritic" "--quiet" "--profile" profile
                            "--verbose" "%l:%c:%s:%m [%p]\\n")
             :sentinel
             (lambda (process _event)
               (when (memq (process-status process) '(exit signal))
                 (unwind-protect
                     (when (and (buffer-live-p source)
                                (eq process (buffer-local-value 'gdev-perl--critic-process source)))
                       (with-current-buffer (process-buffer process)
                         (goto-char (point-min))
                         (let (diagnostics)
                           (while (re-search-forward
                                   "^\\([0-9]+\\):\\([0-9]+\\):\\([1-5]\\):\\(.*\\)$" nil t)
                             (let ((region (flymake-diag-region
                                            source
                                            (string-to-number (match-string 1))
                                            (string-to-number (match-string 2)))))
                               (push (flymake-make-diagnostic
                                      source (car region) (cdr region)
                                      (if (>= (string-to-number (match-string 3)) 4) :warning :note)
                                      (match-string 4))
                                     diagnostics)))
                           (funcall report-fn diagnostics))))
                   (kill-buffer (process-buffer process)))))))
      (process-send-region gdev-perl--critic-process (point-min) (point-max))
      (process-send-eof gdev-perl--critic-process))))

(defun gdev-perl-enable-perlcritic ()
  "Aggiunge qui la fonte Perl::Critic se il progetto ha un file di regole.
Eglot sostituisce le fonti di Flymake quando prende in carico un'area di testo,
quindi questa funzione gira anche da `eglot-managed-mode-hook'."
  (when (and (derived-mode-p 'cperl-mode)
             (not (file-remote-p default-directory))
             (executable-find "perlcritic")
             (gdev-perl--critic-profile))
    (add-hook 'flymake-diagnostic-functions #'gdev-perl-flymake-perlcritic nil t)
    (flymake-mode 1)))

(gdev-module-add-hook 'cperl-mode-hook #'gdev-perl-enable-perlcritic)
(gdev-module-add-hook 'eglot-managed-mode-hook #'gdev-perl-enable-perlcritic)

(defun gdev-perl-critic-project ()
  "Esegue Perl::Critic su tutto il progetto; i risultati sono cliccabili."
  (interactive)
  (let ((root (gdev-project-root)))
    (gdev-compile (gdev-command-line "perlcritic" "--quiet" "--verbose" "%f:%l:%c: %m [%p]\\n"
                                     (seq-filter (lambda (name) (file-exists-p (expand-file-name name root)))
                                                 '("lib" "bin" "script" "t")))
                  (format "Controlli Perl · %s" (abbreviate-file-name root)) root)))

;;;; Formattazione

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-perl-perltidy ()
  "Formatta l'area di testo con perltidy e il .perltidyrc del progetto.
perltidy cerca .perltidyrc nella sua cartella di lavoro, quindi parte
dalla cartella che ne contiene uno."
  (let ((default-directory (or (locate-dominating-file default-directory ".perltidyrc")
                               default-directory)))
    (gdev-format-with-program "perltidy" "--standard-output" "--standard-error-output"
                              "--nobackup")))

(gdev-set-formatter gdev-perl-modes #'gdev-perl-perltidy)

;;;; Esecuzione e test del file corrente

(declare-function gdev-run-file-with "../../tools/build/config")

(defun gdev-perl-run-file (&optional ask-arguments)
  "Esegue il programma aperto dalla radice del progetto, con lib/ in @INC.
Con ASK-ARGUMENTS richiede di nuovo gli argomenti del programma."
  (gdev-run-file-with '("perl" "-Ilib") ask-arguments (gdev-project-root)))

(defun gdev-perl-test-file ()
  "Esegue con prove il file di test aperto, o tutti i test da un modulo."
  (when buffer-file-name (save-buffer))
  (let ((root (gdev-project-root)))
    (gdev-compile (if (and buffer-file-name (string-suffix-p ".t" buffer-file-name))
                      (gdev-command-line "prove" "-lv" (file-local-name buffer-file-name))
                    (gdev-command-line "prove" "-lr" "-j" (number-to-string (num-processors)) "t"))
                  (format "Test Perl · %s" (abbreviate-file-name root)) root)))

(gdev-set-runner gdev-perl-modes :run #'gdev-perl-run-file :test #'gdev-perl-test-file)

;;;; REPL e debugger classico

(defun gdev-perl-repl ()
  "Restituisci un'area di testo con l'interprete interattivo Perl.
Usa reply o re.pl se disponibili e perl -de0 come ripiego."
  (let* ((default-directory (gdev-project-root))
         (name (format "Interprete Perl · %s"
                       (abbreviate-file-name (directory-file-name default-directory)))))
    (if-let* ((program (gdev-find-executable "reply" "re.pl")))
        (make-comint name program nil "-Ilib")
      (make-comint name "perl" nil "-Ilib" "-de0"))))

(defvar gud-chdir-before-run)

(defun gdev-perl-perldb ()
  "Avvia in GUD il debugger Perl per il programma aperto.
I punti di interruzione si mettono dal sorgente con C-x C-a C-b."
  (interactive)
  (require 'gud)
  (let ((file (or buffer-file-name (user-error "Apri prima il programma da eseguire passo passo")))
        (default-directory (gdev-project-root))
        (gud-chdir-before-run nil))
    (perldb (read-shell-command "Comando per l'esecuzione passo passo: "
                                (concat (combine-and-quote-strings (list "perl" "-Ilib" "-d" (file-local-name file)))
                                        " ")))))

(gdev-set-repl gdev-perl-modes #'gdev-perl-repl)
(gdev-set-popup-rule "\\`\\*Interprete Perl · " :select t)

;;;; Profilazione e copertura (coverage)

(defun gdev-perl-profile-file ()
  "Profila il programma aperto con Devel::NYTProf e apre il rapporto HTML.
NYTProf misura ogni istruzione e ogni sub, con tempo esclusivo e
inclusivo, grafo delle chiamate e grafico a fiamma (flame graph).  I
risultati vanno nella cartella di stato."
  (interactive)
  (let* ((file (or buffer-file-name (user-error "Apri prima il programma da profilare")))
         (directory (gdev-state-file (format "profiles/nytprof-%s/" (format-time-string "%Y%m%d-%H%M%S"))))
         (data (expand-file-name "nytprof.out" directory)))
    (make-directory directory t)
    (save-buffer)
    (gdev-compile (format "NYTPROF=file=%s %s && %s"
                          (shell-quote-argument data)
                          (gdev-command-line "perl" "-Ilib" "-d:NYTProf" file)
                          (gdev-command-line "nytprofhtml" "--file" data "--out"
                                             (expand-file-name "html" directory) "--open"))
                  (format "Profilazione Perl · %s" (abbreviate-file-name file))
                  (gdev-project-root) t)))

(defun gdev-perl-coverage ()
  "Esegue la suite di test sotto Devel::Cover e apre il rapporto di copertura."
  (interactive)
  (let ((root (gdev-project-root)))
    (gdev-compile (concat "cover -delete"
                          " && HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t"
                          " && cover -report html"
                          " && " (gdev-command-line gdev-open-program "cover_db/coverage.html"))
                  (format "Copertura Perl · %s" (abbreviate-file-name root)) root)))

(gdev-set-profiler gdev-perl-modes #'gdev-perl-profile-file)
(gdev-set-coverage gdev-perl-modes #'gdev-perl-coverage)

(dolist (program '("perltidy" "perlcritic" "nytprofhtml" "cover"))
  (gdev-doctor-executable program gdev-perl--install-hint 'note))

;;;; Documentazione

(defgroup gdev-perl nil
  "Perl."
  :group 'gdev)

(defcustom gdev-perl-docsets '("perl~5.44")
  "Documentazione locale di devdocs per la versione di perl in uso."
  :type '(repeat string))

(autoload 'cperl-perldoc "cperl-mode" nil t)

(defun gdev-perl-documentation ()
  "Mostra perldoc per la parola sotto il cursore."
  (call-interactively #'cperl-perldoc))

(defun gdev-perl--register-docsets ()
  "Registra `gdev-perl-docsets' dopo il config.el privato, che può cambiarlo."
  (apply #'gdev-set-docsets gdev-perl-modes gdev-perl-docsets))

(gdev-set-documentation gdev-perl-modes #'gdev-perl-documentation)
(if after-init-time
    (gdev-perl--register-docsets)
  (gdev-module-add-hook 'gdev-after-init-hook #'gdev-perl--register-docsets))

;;;; Tasti del linguaggio (localleader)

(gdev-localleader cperl-mode cperl-mode-map
  "c" "controllo Perl::Critic del progetto" #'gdev-perl-critic-project
  "d" "esegui passo passo con perldb" #'gdev-perl-perldb
  "n" "profila (NYTProf)" #'gdev-perl-profile-file
  "v" "copertura dei test" #'gdev-perl-coverage
  "k" "perldoc" #'cperl-perldoc)

;;; config.el ends here
