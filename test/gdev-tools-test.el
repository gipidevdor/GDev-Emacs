;;; gdev-tools-test.el --- Prove di ambiente, argomenti e strumenti di progetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Gli argomenti dei programmi si dividono come in una shell, i comandi
;; aspettano direnv, gli strumenti si cercano sulla macchina del progetto e
;; un buffer riceve un solo server di linguaggio.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-lib)
(require 'gdev-llvm-coverage)
(require 'gdev-language-modes)
(require 'gdev-doctor)
(require 'gdev-cli)

(defvar envrc--running)

(ert-deftest gdev-test-shell-split-follows-posix-quoting ()
  "Esegui e Debug dividono gli argomenti allo stesso modo, apici singoli compresi."
  (should (equal (gdev-shell-split "--name=\"John Doe\" --p='a b' x\\ y")
                 '("--name=John Doe" "--p=a b" "x y")))
  (should (equal (gdev-shell-split "") nil))
  (should (equal (gdev-shell-split nil) nil)))

(ert-deftest gdev-test-commands-wait-for-a-running-direnv ()
  "Con direnv in esecuzione l'ambiente non è pronto e i comandi non partono."
  (with-temp-buffer
    (should (gdev-project-environment-ready-p))
    (should-not (gdev-require-project-environment))
    (setq-local envrc--running t)
    (should-not (gdev-project-environment-ready-p))
    (should-error (gdev-require-project-environment) :type 'user-error)
    (setq-local envrc--running nil)
    (should (gdev-project-environment-ready-p))
    (setq-local gdev-project-environment-status 'failed)
    (should-error (gdev-require-project-environment) :type 'user-error)))

(ert-deftest gdev-test-executables-are-found-on-the-project-machine ()
  "Per una cartella remota gli strumenti si cercano sulla macchina remota."
  (let (calls)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program &optional remote)
                 (push (list program default-directory remote) calls)
                 nil)))
      (gdev-executable-in "ninja" "/ssh:host:/progetto/")
      (gdev-executable-in "ccache" "/tmp/locale/"))
    (should (equal (reverse calls)
                   '(("ninja" "/ssh:host:/progetto/" t)
                     ("ccache" "/tmp/locale/" t))))))

(ert-deftest gdev-test-llvm-coverage-links-shared-libraries-with-the-runtime ()
  "Librerie condivise e moduli ricevono i flag della copertura."
  (let ((configure (car (gdev-llvm-coverage-build-commands "/tmp/progetto/" "build-copertura" "4"))))
    (dolist (variable '("CMAKE_EXE_LINKER_FLAGS" "CMAKE_SHARED_LINKER_FLAGS"
                        "CMAKE_MODULE_LINKER_FLAGS"))
      ;; `shell-quote-argument' può proteggere il segno «=» con una barra inversa.
      (should (string-match-p (concat variable "\\\\?=-fprofile-instr-generate") configure)))))

(ert-deftest gdev-test-lsp-starts-one-server-per-buffer ()
  "Il gancio di direnv richiamato durante la preparazione non avvia un secondo server."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :tools 'lsp ".el") nil t t))
  (let ((started 0))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "prova.c" temporary-file-directory))
      (cl-letf (((symbol-function 'gdev-handler)
                 (lambda (&rest _) (list :contact '("sh") :when #'always)))
                ((symbol-function 'gdev-use-project-tools)
                 ;; Con il risultato di direnv in cache il gancio gira subito.
                 (lambda () (gdev-lsp-maybe-start)))
                ((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
        (let ((gdev-lsp-auto-start t))
          (gdev-lsp-maybe-start)))
      (set-buffer-modified-p nil)
      (setq buffer-file-name nil))
    (should (= started 1))))

(ert-deftest gdev-test-corrupt-custom-file-does-not-stop-startup ()
  "Un custom.el troncato diventa un avviso: il nucleo si carica comunque."
  (let ((file (make-temp-file "gdev-custom-" nil ".el" "(setq gdev-test-variabile\n")))
    (unwind-protect
        (let (warned)
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (type message &rest _) (setq warned (list type message)))))
            (should-not (gdev-load-custom-file file)))
          (should (eq (car warned) 'gdev))
          (should (string-search "Preferenze salvate non caricate" (cadr warned)))
          ;; Un file mancante resta un caso normale, senza avvisi.
          (setq warned nil)
          (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warned t))))
            (gdev-load-custom-file (concat file ".assente")))
          (should-not warned))
      (delete-file file))))

(ert-deftest gdev-test-tree-sitter-remap-entries-are-symbols ()
  "Emacs chiama `fboundp' sul valore del rimappamento: dev'essere un simbolo."
  (let ((major-mode-remap-defaults nil))
    (unwind-protect
        (progn
          (gdev-language-register-tree-sitter 'gdev-test-classic-mode 'gdev-test-native-mode
                                              'gdev-test-grammar)
          (should (symbolp (alist-get 'gdev-test-classic-mode major-mode-remap-defaults)))
          (should (fboundp (major-mode-remap 'gdev-test-classic-mode))))
      (fmakunbound 'gdev-language--open-gdev-test-classic-mode))))

(ert-deftest gdev-test-cli-run-shows-the-output-and-the-status ()
  "Un comando lanciato dalla CLI mostra l'output man mano e riporta lo stato."
  (let (status)
    (should (equal (with-output-to-string
                     (setq status (gdev-cli--run "/bin/sh" "-c" "echo uno; echo due >&2; exit 3")))
                   "uno\ndue\n"))
    (should (= status 3))))

(ert-deftest gdev-test-env-detects-an-emacs-started-from-a-shell ()
  "Con SHLVL l'Emacs ha l'ambiente della shell e non serve quello salvato."
  (load (gdev-config-file "lisp/gdev-env.el") nil t t)
  (let ((process-environment (cons "SHLVL=1" process-environment)))
    (should (gdev-env--from-shell-p)))
  (let ((process-environment (cons "SHLVL" process-environment)))
    (should-not (gdev-env--from-shell-p))))

(ert-deftest gdev-test-env-adds-the-tool-directory-once ()
  "La cartella bin degli strumenti entra una sola volta nel PATH."
  (load (gdev-config-file "lisp/gdev-env.el") nil t t)
  (let* ((bin (make-temp-file "gdev-bin-" t))
         (process-environment (copy-sequence process-environment))
         (exec-path (copy-sequence exec-path)))
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-tools-file) (lambda (&rest _) bin)))
          (setenv "PATH" "/usr/bin:/bin")
          (gdev-env--add-tool-directories)
          (gdev-env--add-tool-directories)
          (should (= 1 (seq-count (lambda (entry) (equal (file-name-as-directory entry)
                                                         (file-name-as-directory bin)))
                                  (split-string (getenv "PATH") path-separator t)))))
      (delete-directory bin t))))

(ert-deftest gdev-test-doctor-reports-a-broken-private-file ()
  "Un init.el privato che non si carica compare tra i problemi della diagnosi."
  (let ((gdev-modules-private-errors '(("/utente/init.el" . "End of file"))))
    (let ((result (seq-find (lambda (entry) (string-prefix-p "configurazione privata /utente" (nth 1 entry)))
                            (gdev-doctor-run))))
      (should result)
      (should (eq (car result) 'warning)))))

(ert-deftest gdev-test-directory-empty-ignores-finder-files ()
  "Una cartella con il solo .DS_Store del Finder conta come vuota."
  (let ((directory (make-temp-file "gdev-vuota-" t)))
    (unwind-protect
        (progn
          (should (gdev-directory-empty-p directory))
          (write-region "" nil (expand-file-name ".DS_Store" directory) nil 'silent)
          (should (gdev-directory-empty-p directory))
          (write-region "" nil (expand-file-name "testo.txt" directory) nil 'silent)
          (should-not (gdev-directory-empty-p directory)))
      (delete-directory directory t))))

(ert-deftest gdev-test-python-coverage-reports-even-when-tests-fail ()
  "Il rapporto di copertura compare anche con un test rosso, e lo stato resta quello dei test."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :lang 'python ".el") nil t t))
  (let ((command (gdev-python--run-then-report "sh -c 'echo test; exit 4'" "echo rapporto")))
    (with-temp-buffer
      (let ((status (call-process "/bin/sh" nil t nil "-c" command)))
        (should (= status 4))
        (should (equal (buffer-string) "test\nrapporto\n"))))))

(ert-deftest gdev-test-python-venv-message-names-the-real-cause ()
  "Un .venv esistente ma non autorizzato si distingue da un ambiente mancante."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :lang 'python ".el") nil t t))
  (let ((root (file-name-as-directory (make-temp-file "gdev-venv-" t))))
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-python-root) (lambda () root)))
          (let ((gdev-trusted-projects nil))
            ;; Senza ambiente: il suggerimento è crearlo.
            (should-not (gdev-python--venv-exists-p root))
            (should (string-search "Crea prima"
                                   (cadr (should-error (gdev-python-install-tools) :type 'user-error))))
            ;; Con l'ambiente ma senza fiducia: il suggerimento è autorizzare la cartella.
            (make-directory (expand-file-name ".venv/bin" root) t)
            (write-region "" nil (expand-file-name ".venv/pyvenv.cfg" root) nil 'silent)
            (should (gdev-python--venv-exists-p root))
            (should-not (gdev-python--venv-bin root))
            (should (string-search "gdev-trust-project"
                                   (cadr (should-error (gdev-python-install-tools) :type 'user-error))))
            ;; Autorizzata, e con un interprete eseguibile, l'ambiente si usa.
            (let ((python (expand-file-name ".venv/bin/python" root)))
              (write-region "#!/bin/sh\n" nil python nil 'silent)
              (set-file-modes python #o755))
            (let ((gdev-trusted-projects (list (file-name-as-directory (file-truename root)))))
              (should (gdev-python--venv-bin root)))))
      (delete-directory root t))))

(ert-deftest gdev-test-perl-syntax-check-needs-a-trusted-project ()
  "`perl -c' esegue i blocchi BEGIN: il controllo parte solo in una cartella autorizzata."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :lang 'perl ".el") nil t t))
  (let ((root (file-name-as-directory (make-temp-file "gdev-perl-" t))) enabled)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (cl-letf (((symbol-function 'gdev-perl-language-server-p) #'ignore)
                    ((symbol-function 'gdev-project-root) (lambda (&rest _) root))
                    ((symbol-function 'flymake-mode) (lambda (&rest _) (setq enabled t))))
            (let ((gdev-trusted-projects nil))
              (gdev-perl-syntax-check-fallback)
              (should-not enabled))
            (let ((gdev-trusted-projects (list (file-name-as-directory (file-truename root)))))
              (gdev-perl-syntax-check-fallback)
              (should enabled)
              (should (member (concat "-I" (expand-file-name "lib" root)) perl-flymake-command)))))
      (delete-directory root t))))

(ert-deftest gdev-test-clangd-is-looked-up-when-the-server-starts ()
  "Il clangd del progetto, nel percorso del buffer, vince su quello globale."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :lang 'cc ".el") nil t t))
  (let* ((directory (file-name-as-directory (make-temp-file "gdev-clangd-" t)))
         (clangd (expand-file-name "clangd" directory)))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\n" nil clangd nil 'silent)
          (set-file-modes clangd #o755)
          (let ((exec-path (cons (directory-file-name directory) exec-path)))
            (should (equal (car (gdev-cc-clangd-server)) clangd))))
      (delete-directory directory t))))

(ert-deftest gdev-test-compilation-annotations-are-in-italian ()
  "L'avvio e la fine di una compilazione non mostrano più «started at» e «duration»."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :tools 'build ".el") nil t t))
  (with-temp-buffer
    (compilation-mode)
    (let ((inhibit-read-only t))
      (compilation-insert-annotation "Compilazione started at Mon Nov 17 12:00:00\n\n" "make\n")
      (compilation-insert-annotation " at " "Mon Nov 17 12:00:05" ", duration " "4.20 s"))
    (let ((text (buffer-string)))
      (should (string-match-p "Compilazione avviata il [a-z]\\{3\\} [0-9]+ [a-z]\\{3\\} [0-9:]\\{8\\}" text))
      (should (string-match-p " il [a-z]\\{3\\} [0-9]+ [a-z]\\{3\\} [0-9:]\\{8\\}, durata 4,20 s" text))
      (should-not (string-match-p "started at\\|duration\\| at [A-Z]" text)))))

(ert-deftest gdev-test-environment-failure-names-its-cause ()
  "Il messaggio di un ambiente non disponibile riporta l'errore di mise."
  (with-temp-buffer
    (setq-local gdev-project-environment-status 'failed)
    (let ((message (cadr (should-error (gdev-require-project-environment) :type 'user-error))))
      (should (string-match-p "non disponibile\\." message)))
    (setq-local gdev-project-environment-detail "mise ERROR config non fidata: esegui mise trust")
    (let ((message (cadr (should-error (gdev-require-project-environment) :type 'user-error))))
      (should (string-search "mise trust" message)))))

(ert-deftest gdev-test-mise-last-line-is-the-cause ()
  "L'ultima riga di stderr di mise diventa la causa, accorciata."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :tools 'build ".el") nil t t))
  (load (expand-file-name "gdev-mise" (file-name-directory (gdev-module-file :tools 'build ".el"))) nil t)
  (with-temp-buffer
    (insert "avviso\n\nmise ERROR errore vero  \n")
    (should (equal (gdev-mise--last-line (current-buffer)) "mise ERROR errore vero")))
  (with-temp-buffer
    (insert (make-string 400 ?x))
    (should (= (length (gdev-mise--last-line (current-buffer))) 160)))
  (with-temp-buffer
    (should-not (gdev-mise--last-line (current-buffer))))
  (should-not (gdev-mise--last-line nil)))

(ert-deftest gdev-test-format-selection-without-a-range-server-asks-first ()
  "Un formattatore che non sa formattare una selezione non riformatta tutto in silenzio."
  (let ((use-package-ensure-function #'ignore) formatted)
    (load (gdev-module-file :editor 'format ".el") nil t t)
    (with-temp-buffer
      (insert "uno due tre")
      (cl-letf (((symbol-function 'gdev-format-buffer) (lambda (&rest _) (setq formatted t))))
        ;; Con la selezione e un rifiuto non si formatta nulla.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
          (should-error (gdev-format-dwim 1 4 nil) :type 'user-error))
        (should-not formatted)
        ;; Con il consenso, o senza selezione, si formatta come prima.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
          (gdev-format-dwim 1 4 nil))
        (should formatted)
        (setq formatted nil)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (ert-fail "Nessuna domanda"))))
          (gdev-format-dwim nil nil nil))
        (should formatted)))))

(ert-deftest gdev-test-cc-source-header-does-not-wait-for-clangd ()
  "Il passaggio sorgente/intestazione ha un tempo massimo breve e scarta la risposta vuota."
  (let ((use-package-ensure-function #'ignore) call fallback)
    (load (gdev-module-file :lang 'cc ".el") nil t t)
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "prova.cpp" temporary-file-directory))
      (setq-local eglot--managed-mode t)
      (cl-letf (((symbol-function 'jsonrpc-request) (lambda (&rest arguments) (setq call arguments) ""))
                ((symbol-function 'eglot-current-server) (lambda () 'server))
                ((symbol-function 'eglot-path-to-uri) (lambda (_) "file:///prova.cpp"))
                ((symbol-function 'ff-find-other-file) (lambda (&rest _) (setq fallback t)))
                ((symbol-function 'find-file) (lambda (&rest _) (ert-fail "Nessun file da aprire"))))
        (gdev-cc-switch-source-header))
      (set-buffer-modified-p nil)
      (setq buffer-file-name nil))
    (should (= (plist-get (nthcdr 3 call) :timeout) 2))
    (should fallback)))

(ert-deftest gdev-test-web-serve-refuses-a-busy-port ()
  "Con la porta già occupata il servizio non parte e il navigatore non si apre."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :lang 'web ".el") nil t t))
  (let* ((listener (make-network-process :name "gdev-prova-porta" :server t :host "127.0.0.1"
                                         :service t :noquery t))
         (port (process-contact listener :service))
         (gdev-web-server-port port))
    (unwind-protect
        (progn
          (should (gdev-web--port-in-use-p port))
          (cl-letf (((symbol-function 'gdev-compile) (lambda (&rest _) (ert-fail "Il servizio non deve partire")))
                    ((symbol-function 'browse-url) (lambda (&rest _) (ert-fail "Il navigatore non deve aprirsi"))))
            (should-error (gdev-web-serve "/tmp/") :type 'user-error)))
      (delete-process listener))
    (should-not (gdev-web--port-in-use-p port))))

(ert-deftest gdev-test-coverage-refuses-a-huge-report ()
  "Un rapporto LCOV enorme si rifiuta con un messaggio, senza leggerlo."
  (require 'gdev-test-coverage)
  (let ((file (make-temp-file "gdev-lcov-" nil ".info" "SF:a.c\nDA:1,1\nend_of_record\n")))
    (unwind-protect
        (progn
          ;; Un rapporto piccolo si legge.
          (should (gdev-test-coverage--read file "/tmp/"))
          ;; Il limite si abbassa: stubbare `file-attribute-size' non vale per il
          ;; codice compilato, che la espande in linea.
          (let ((gdev-test-coverage--report-limit 10))
            (should-error (gdev-test-coverage--read file "/tmp/") :type 'user-error)))
      (delete-file file))))

(ert-deftest gdev-test-profiles-get-their-own-server-name ()
  "Un profilo ha un server proprio, così emacsclient non raggiunge un'altra istanza."
  (should (equal (gdev-profile-server-name nil) "server"))
  (should (equal (gdev-profile-server-name "") "server"))
  (should (equal (gdev-profile-server-name "prova") "gdev-prova")))

(ert-deftest gdev-test-xcrun-lookups-are-remembered ()
  "Lo stesso strumento di Xcode non lancia xcrun a ogni richiesta."
  (let ((gdev-macos-p t)
        (gdev--xcrun-cache (make-hash-table :test #'equal))
        (calls 0))
    (cl-letf (((symbol-function 'process-lines-ignore-status)
               (lambda (&rest _) (cl-incf calls) (list "/bin/sh")))
              ((symbol-function 'file-executable-p) (lambda (file) (equal file "/bin/sh"))))
      (should (equal (gdev-xcrun-find "sh") "/bin/sh"))
      (should (equal (gdev-xcrun-find "sh") "/bin/sh"))
      (should (= calls 1))
      ;; Uno strumento mancante non si ricorda: potrebbe essere installato dopo.
      (cl-letf (((symbol-function 'process-lines-ignore-status) (lambda (&rest _) (cl-incf calls) nil)))
        (should-not (gdev-xcrun-find "assente"))
        (should-not (gdev-xcrun-find "assente"))
        (should (= calls 3))))))

(ert-deftest gdev-test-project-tools-skip-the-project-lookup-without-trust ()
  "Senza cartelle autorizzate l'apertura di un file non cerca il progetto."
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "prova.c" temporary-file-directory))
    (let ((gdev-trusted-projects nil))
      (cl-letf (((symbol-function 'gdev-project-root)
                 (lambda (&rest _) (ert-fail "Nessuna ricerca del progetto"))))
        (gdev-use-project-tools)))
    (set-buffer-modified-p nil)
    (setq buffer-file-name nil)))

(ert-deftest gdev-test-sensitive-files-are-recognized ()
  "I file con segreti si riconoscono, gli altri no."
  (dolist (file '("/p/.env" "/p/.env.local" "/p/chiave.pem" "/home/u/.ssh/config"
                  "/home/u/.netrc" "/home/u/.aws/credentials" "/p/segreto.gpg"))
    (should (gdev-sensitive-file-p file)))
  (dolist (file '("/p/src/main.c" "/p/README.md" "/p/environment.el" nil))
    (should-not (gdev-sensitive-file-p file))))

(ert-deftest gdev-test-completion-table-carries-its-metadata ()
  "La tabella con metadati funziona anche senza `completion-table-with-metadata' di Emacs 31."
  (let ((table (gdev-completion-table-with-metadata
                '(("alfa" . 1) ("beta" . 2)) '((display-sort-function . identity)))))
    (should (eq (completion-metadata-get (completion-metadata "" table nil) 'display-sort-function)
                'identity))
    (should (equal (all-completions "a" table) '("alfa")))
    (should (equal (try-completion "be" table) "beta"))))

(ert-deftest gdev-test-cmake-build-directory-from-dir-locals-stays-in-the-project ()
  "Un .dir-locals.el non può puntare CMake fuori dal progetto."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :tools 'build ".el") nil t t))
  (dolist (value '("build" "out/debug" "build-release"))
    (should (gdev-cmake--safe-build-directory-p value)))
  (dolist (value '("" "/tmp/fuori" "~/fuori" "../fuori" "build/../../fuori" nil 3))
    (should-not (gdev-cmake--safe-build-directory-p value))))

(ert-deftest gdev-test-private-directories-are-tightened ()
  "La cartella creata, e una già esistente più larga, restano accessibili solo all'utente."
  (let* ((root (make-temp-file "gdev-privata-" t))
         (nuova (expand-file-name "nuova/dentro" root))
         (esistente (expand-file-name "esistente" root)))
    (unwind-protect
        (progn
          (gdev-make-private-directory nuova)
          (should (= (file-modes nuova) #o700))
          (make-directory esistente)
          (set-file-modes esistente #o755)
          (gdev-make-private-directory esistente)
          (should (= (file-modes esistente) #o700)))
      (delete-directory root t))))

(ert-deftest gdev-test-sidebar-reopens-after-undo-close-on-emacs-30 ()
  "Senza il gancio di Emacs 31 Esplora file si ricostruisce con un consiglio."
  (let ((use-package-ensure-function #'ignore) argument (called nil))
    (load (gdev-module-file :ui 'sidebar ".el") nil t t)
    (cl-letf (((symbol-function 'gdev-sidebar--reopen-tab)
               (lambda (tab) (setq called t argument tab))))
      (gdev-sidebar--after-undo-close-tab 'argomento-ignorato))
    (should called)
    (should-not argument)))

(ert-deftest gdev-test-trust-project-asks-and-saves-the-real-path ()
  "Autorizzare una cartella chiede conferma, rifiuta le remote e salva il percorso reale."
  (let* ((root (file-name-as-directory (make-temp-file "gdev-fiducia-" t)))
         (link (concat (directory-file-name root) "-collegamento"))
         saved)
    (make-symbolic-link (directory-file-name root) link)
    (unwind-protect
        (cl-letf (((symbol-function 'customize-save-variable)
                   (lambda (variable value) (setq saved (cons variable value))))
                  ((symbol-function 'gdev-use-project-tools) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (let ((gdev-trusted-projects nil))
            ;; Una cartella remota non si autorizza e non si chiede nulla.
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Nessuna domanda"))))
              (should-error (gdev-trust-project "/ssh:host:/progetto/") :type 'user-error))
            ;; Con il rifiuto non si salva nulla.
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
              (gdev-trust-project link))
            (should-not saved)
            ;; Con il consenso si salva il percorso reale, non quello del collegamento.
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (gdev-trust-project link))
            (should (eq (car saved) 'gdev-trusted-projects))
            (should (equal (cdr saved) (list (file-name-as-directory (file-truename root)))))
            (let ((gdev-trusted-projects (cdr saved)))
              (should (gdev-project-trusted-p root))
              (should-not (gdev-project-trusted-p "/ssh:host:/progetto/")))))
      (delete-file link)
      (delete-directory root t))))

(ert-deftest gdev-test-project-build-root-follows-the-build-module ()
  "Debug, profilo e copertura usano la radice di compilazione, o quella del progetto."
  (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) "/progetto/")))
    (cl-letf (((symbol-function 'gdev-build--root) nil))
      (fmakunbound 'gdev-build--root)
      (should (equal (gdev-project-build-root) "/progetto/")))
    (cl-letf (((symbol-function 'gdev-build--root) (lambda () "/progetto/nativo/")))
      (should (equal (gdev-project-build-root) "/progetto/nativo/")))))

(ert-deftest gdev-test-read-process-returns-the-chosen-pid ()
  "Il selettore di processo mostra solo i processi dell'utente e restituisce il PID scelto."
  (let (offered)
    (cl-letf (((symbol-function 'list-system-processes) (lambda () '(10 20 30)))
              ((symbol-function 'process-attributes)
               (lambda (pid)
                 (pcase pid
                   (10 `((user . ,user-login-name) (args . "emacs --daemon")))
                   (20 '((user . "altro") (args . "launchd")))
                   (30 `((user . ,user-login-name) (comm . "zsh"))))))
              ((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (setq offered (mapcar #'car candidates))
                 (car (last offered)))))
      (should (= (gdev-read-process "Processo: ") 30))
      (should (= (length offered) 2))
      (should (string-search "emacs --daemon" (car offered)))
      (should-not (cl-some (lambda (label) (string-search "launchd" label)) offered)))))

;;; gdev-tools-test.el ends here
