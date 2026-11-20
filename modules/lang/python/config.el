;;; config.el --- :lang python: ambienti, controlli, test e strumenti Python -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Usa l'ambiente .venv del progetto, oppure Python disponibile nel
;; percorso degli strumenti. Puoi scegliere un interprete nel file
;; .dir-locals.el con python-shell-interpreter.
;;
;;   C-F5       esegui il file aperto
;;   F5         avvia l'esecuzione passo passo con debugpy
;;   F6         prova il file di test o l'intero progetto
;;   C-c p T    esegui tutti i test del progetto
;;   C-c o r    apri l'interprete interattivo del progetto
;;   C-c c e    invia all'interprete la selezione o l'intera area di testo
;;   C-c c f    formatta con Ruff
;;   C-c l i    riordina le importazioni con Ruff
;;   C-c l a    applica le correzioni sicure di Ruff
;;   C-c l t    prova la funzione di test sotto il cursore con pytest
;;   C-c l v    crea .venv nella cartella del progetto
;;   C-c l s    installa gli strumenti di sviluppo nella .venv
;;   C-c l b    genera i pacchetti distribuibili
;;   C-c P P    profila il programma aperto con cProfile
;;   C-c P c    misura la copertura dei test
;;
;; Ruff controlla in secondo piano il testo che stai modificando. Eglot
;; avvia il primo server di tipi disponibile fra ty, basedpyright, Pyright
;; e pylsp. I processi usano i riquadri di GDev e non installano pacchetti
;; all'apertura di un file.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-language-modes)

(gdev-language-register-tree-sitter 'python-mode 'python-ts-mode 'python)

(defvar python-shell-interpreter)
(defvar python-shell-buffer-name)
(defvar python-indent-guess-indent-offset-verbose)
(defvar python-base-mode-map)
(defvar python-shell--first-prompt-received)
(defvar flymake-diagnostic-functions)
(defvar gdev-format--background)

(declare-function run-python "python")
(declare-function python-shell-buffer-substring "python")
(declare-function python-shell-send-string "python")
(declare-function python-info-current-defun "python")
(declare-function flymake-make-diagnostic "flymake")
(declare-function dape "dape")
(declare-function gdev-run-file-with "../../tools/build/config")
(declare-function gdev-format-with-program "../../editor/format/config")
(declare-function gdev-profile--output "../../tools/profiler/config")

(defconst gdev-python-modes '(python-mode python-ts-mode)
  "Modalità principali del codice Python.")

(setq python-indent-guess-indent-offset-verbose nil
      python-shell-interpreter "python3")

(require 'gdev-project-types)

(defun gdev-python--find-root (directory)
  "Trova la prima cartella con un file di progetto sopra DIRECTORY."
  (locate-dominating-file
   directory
   (lambda (candidate)
     (apply #'gdev-project-file-exists-p candidate gdev-python-project-files))))

(defun gdev-python--project-find (directory)
  "Riconosci una cartella Python DIRECTORY anche senza controllo di versione."
  (when (and (derived-mode-p 'python-mode 'python-ts-mode)
             (not (file-remote-p directory)))
    (when-let* ((root (gdev-python--find-root directory)))
      (cons 'transient root))))

(gdev-module-add-hook 'project-find-functions #'gdev-python--project-find 90)

(defun gdev-python-root (&optional directory)
  "Trova la cartella Python più vicina a DIRECTORY, entro il progetto."
  (let* ((directory (file-name-as-directory (expand-file-name (or directory default-directory))))
         (project (gdev-project-root directory))
         (root (gdev-python--find-root directory)))
    (if (and root (or (equal project directory) (string-prefix-p project root)))
        root
      project)))

(defun gdev-python--venv-exists-p (root)
  "Indica se ROOT contiene un ambiente .venv, autorizzato o no."
  (file-readable-p (expand-file-name ".venv/pyvenv.cfg" root)))

(defun gdev-python--venv-bin (root)
  "Restituisce gli eseguibili di .venv in ROOT se la cartella è autorizzata."
  (let ((venv (expand-file-name ".venv/" root)))
    (when (and (or (file-remote-p root) (gdev-project-trusted-p root))
               (file-readable-p (expand-file-name "pyvenv.cfg" venv)))
      (cl-loop for name in '("bin/python" "Scripts/python.exe")
               for file = (expand-file-name name venv)
               when (file-executable-p file) return (file-name-directory file)))))

(defun gdev-python--tool (root name)
  "Cerca NAME nell'ambiente di ROOT e nel percorso degli strumenti."
  (let* ((bin (gdev-python--venv-bin root))
         (suffix (if (and bin (string-suffix-p "/Scripts/" bin)) ".exe" ""))
         (local (and bin (expand-file-name (concat name suffix) bin)))
         (file (if (and local (file-executable-p local)) local
                 (executable-find name (file-remote-p root)))))
    (when file (file-local-name file))))

(defun gdev-python--interpreter (root)
  "Scegli l'interprete da usare in ROOT."
  (let ((configured python-shell-interpreter))
    (when (equal configured "python3")
      (gdev-python--activate-venv root))
    (or (if (equal configured "python3")
            (or (when (gdev-python--venv-bin root) (gdev-python--tool root "python"))
                (gdev-python--tool root "python3")
                (gdev-python--tool root "python"))
          (if (file-name-absolute-p configured)
              (let ((path (expand-file-name (concat (file-remote-p root) configured))))
                (and (file-executable-p path) (file-local-name path)))
            (when-let* ((file (executable-find configured (file-remote-p root))))
              (file-local-name file))))
        (user-error "Interprete Python non trovato. Controlla python-shell-interpreter"))))

(defun gdev-python--file ()
  "Restituisci il percorso del file visitato per il processo Python."
  (file-local-name (or buffer-file-name (user-error "Apri prima un file Python"))))

(defun gdev-python--output-name (kind root &optional file)
  "Identifica il processo di KIND per ROOT e, se presente, per FILE."
  (format "gdev-%s: %s · %s" kind
          (file-name-nondirectory (directory-file-name (or file root)))
          (substring (secure-hash 'sha256 (or file root)) 0 8)))

;;;; Ambiente per Eglot e per i comandi del progetto

(defun gdev-python--activate-venv (root)
  "Dà ai processi locali l'ambiente virtuale del progetto ROOT."
  (when-let* (((not (file-remote-p root)))
              (bin (gdev-python--venv-bin root))
              (venv (directory-file-name (file-name-directory (directory-file-name bin))))
              ((not (equal (getenv "VIRTUAL_ENV") venv))))
    (setq-local exec-path (cons bin exec-path))
    (setq-local process-environment (copy-sequence process-environment))
    (setenv "PATH" (concat bin path-separator (getenv "PATH")))
    (setenv "VIRTUAL_ENV" venv)
    (setenv "PYTHONHOME" nil)))

(defun gdev-python--project-environment (_root)
  "Prepara l'ambiente Python quando si apre un file del linguaggio."
  (when (and (derived-mode-p 'python-mode 'python-ts-mode)
             (equal python-shell-interpreter "python3"))
    (gdev-python--activate-venv (gdev-python-root))))

(gdev-module-add-hook 'gdev-project-environment-functions #'gdev-python--project-environment)

(defconst gdev-python-servers
  '(("ty" "server") ("basedpyright-langserver" "--stdio")
    ("pyright-langserver" "--stdio") ("pylsp"))
  "Server di linguaggio Python e rispettivi argomenti.")

(defun gdev-python--server (&optional _interactive project)
  "Restituisce il comando per il primo server Python installato."
  (let ((root (gdev-python-root)))
    (when (and project (equal python-shell-interpreter "python3"))
      (gdev-python--activate-venv root))
    (cl-loop for (program . args) in gdev-python-servers
             for executable = (gdev-python--tool root program)
             when executable return (cons executable args))))

(gdev-set-eglot-server gdev-python-modes #'gdev-python--server :when #'gdev-python--server)

;;;; Esecuzione e interprete interattivo

(defun gdev-python-run-file (&optional ask-arguments)
  "Esegue il programma aperto. Con ASK-ARGUMENTS chiede di nuovo gli argomenti."
  (let ((root (gdev-python-root)))
    (gdev-run-file-with (list (gdev-python--interpreter root)) ask-arguments root
                        (gdev-python--output-name "run" root buffer-file-name))))

(defun gdev-python-repl ()
  "Restituisce l'area di testo dell'interprete interattivo del progetto."
  (require 'python)
  (let* ((root (gdev-python-root))
         (default-directory root)
         (python-shell-interpreter (gdev-python--interpreter root))
         (identity (substring (secure-hash 'sha256 (concat root "\0" python-shell-interpreter)) 0 8))
         (python-shell-buffer-name
          (format "Python[%s · %s]" (file-name-nondirectory (directory-file-name root)) identity)))
    (process-buffer (run-python nil nil nil))))

(defvar-local gdev-python--pending-evaluations nil
  "Valutazioni in attesa che l'interprete interattivo sia pronto.")

(defun gdev-python--flush-evaluations ()
  "Invia le valutazioni in coda dopo l'inizializzazione di Python."
  (let ((process (get-buffer-process (current-buffer)))
        (evaluations (nreverse gdev-python--pending-evaluations)))
    (setq gdev-python--pending-evaluations nil)
    (remove-hook 'python-shell-first-prompt-hook #'gdev-python--flush-evaluations t)
    (dolist (evaluation evaluations)
      (when (buffer-live-p (car evaluation))
        (with-current-buffer (car evaluation)
          (python-shell-send-string (cdr evaluation) process))))))

(defun gdev-python-eval (beg end)
  "Invia il testo fra BEG ed END all'interprete interattivo del progetto."
  (let* ((source (current-buffer))
         (repl (gdev-python-repl))
         (process (get-buffer-process repl))
         (text (python-shell-buffer-substring beg end t)))
    (unless (process-live-p process)
      (user-error "L'interprete Python è terminato durante l'avvio"))
    (if (buffer-local-value 'python-shell--first-prompt-received repl)
        (python-shell-send-string text process)
      (with-current-buffer repl
        (push (cons source text) gdev-python--pending-evaluations)
        (add-hook 'python-shell-first-prompt-hook #'gdev-python--flush-evaluations 90 t)))))

;;;; Test e distribuzione

(defconst gdev-python--pytest-probe
  "import importlib.util, sys; sys.exit(importlib.util.find_spec('pytest') is None)"
  "Controllo di pytest eseguito insieme ai test, con lo stesso interprete.")

(defun gdev-python--test-command (root &optional file prefix)
  "Componi il comando dei test in ROOT, limitato a FILE se indicato.
PREFIX avvia il modulo dei test tramite uno strumento come coverage."
  (let* ((python (gdev-python--interpreter root))
         (runner (or prefix (list python))))
    (concat "if " (gdev-command-line python "-c" gdev-python--pytest-probe)
            "; then " (gdev-command-line (car runner) (cdr runner) "-m" "pytest" "-q" file)
            "; else " (gdev-command-line (car runner) (cdr runner) "-m" "unittest"
                                         (if file (list "discover" "-v"
                                                        "-s" (file-name-directory file)
                                                        "-p" (file-name-nondirectory file))
                                           (append '("discover" "-v")
                                                   (when (file-directory-p (expand-file-name "tests" root))
                                                     '("-s" "tests")))))
            "; fi")))

(defun gdev-python--test-file-p (file)
  "Restituisce non nil se FILE segue il nome convenzionale dei test."
  (and file (string-match-p "\\(?:\\`test_.*\\|.*_test\\)\\.py\\'"
                            (file-name-nondirectory file))))

(defun gdev-python--companion (file root)
  "Trova il test di FILE o il suo sorgente, entro ROOT."
  (let* ((stem (file-name-base file))
         (directory (file-name-directory file))
         (relative (file-relative-name directory root))
         (tested (gdev-python--test-file-p file))
         (source-stem (string-remove-suffix "_test" (string-remove-prefix "test_" stem)))
         (under-tests (string-remove-prefix "tests/" relative))
         (under-source (string-remove-prefix "src/" relative))
         (directories (if tested
                          (list (expand-file-name under-tests root)
                                (expand-file-name (concat "src/" under-tests) root)
                                directory)
                        (list (expand-file-name (concat "tests/" under-source) root)
                              (expand-file-name "tests/" root) directory)))
         (names (if tested (list (concat source-stem ".py"))
                  (list (concat "test_" stem ".py") (concat stem "_test.py")))))
    (cl-loop for dir in directories
             thereis (cl-loop for name in names
                              for candidate = (expand-file-name name dir)
                              when (file-regular-p candidate) return candidate))))

(defun gdev-python-open-companion ()
  "Apri il test del file corrente o il suo sorgente."
  (if-let* ((file buffer-file-name)
            (companion (gdev-python--companion file (gdev-python-root))))
      (find-file companion)
    (user-error "Non ho trovato un file Python corrispondente")))

(defun gdev-python-test-project ()
  "Esegue tutti i test Python dalla cartella del progetto."
  (interactive)
  (let ((root (gdev-python-root)))
    (gdev-compile (gdev-python--test-command root) (gdev-python--output-name "test" root) root)))

(defun gdev-python-test-file ()
  "Esegue il test aperto, il test del sorgente oppure l'intero progetto."
  (let* ((root (gdev-python-root))
         (file (cond ((gdev-python--test-file-p buffer-file-name) buffer-file-name)
                     (buffer-file-name (gdev-python--companion buffer-file-name root)))))
    (if file
        (progn
          (save-buffer)
          (gdev-compile (gdev-python--test-command root (file-local-name file))
                        (gdev-python--output-name "test" root file) root))
      (gdev-python-test-project))))

(defun gdev-python-test-at-point ()
  "Esegue con pytest il test sotto il cursore."
  (interactive)
  (if (and (bound-and-true-p gdev-layout-mode)
           (fboundp 'gdev-project-view-test-at-point)
           buffer-file-name (not (file-remote-p buffer-file-name)))
      (gdev-project-view-test-at-point)
    (require 'python)
    (let* ((name (python-info-current-defun))
           (root (gdev-python-root)))
      (unless (and (gdev-python--test-file-p buffer-file-name)
                   name (string-prefix-p "test_" (car (last (split-string name "\\.")))))
        (user-error "Porta il cursore all'interno di una funzione di test"))
      (save-buffer)
      (gdev-compile (gdev-command-line (gdev-python--interpreter root) "-m" "pytest" "-q"
                                       (concat (gdev-python--file) "::"
                                               (string-replace "." "::" name)))
                    (gdev-python--output-name "test-funzione" root buffer-file-name) root))))

(declare-function gdev-project-view-test-at-point "gdev-project-view" ())

(defun gdev-python-project-command (action root)
  "Restituisce il comando Python per ACTION in ROOT."
  (let ((python (gdev-python--interpreter root)))
    (pcase action
      ('test (gdev-python--test-command root))
      ('build (gdev-command-line python "-m" "build"))
      ('configure
       (when (file-exists-p (expand-file-name ".venv" root))
         (user-error "La cartella .venv esiste già"))
       (gdev-command-line python "-m" "venv" ".venv")))))

(defun gdev-python-build ()
  "Genera i pacchetti distribuibili del progetto Python."
  (interactive)
  (let ((root (gdev-python-root)))
    (gdev-compile (gdev-python-project-command 'build root)
                  (gdev-python--output-name "build" root) root)))

(defun gdev-python-create-venv ()
  "Crea un ambiente virtuale .venv nel progetto."
  (interactive)
  (let ((root (gdev-python-root)))
    (gdev-compile (gdev-python-project-command 'configure root)
                  (gdev-python--output-name "build-venv" root) root)))

(defun gdev-python-install-tools ()
  "Installa gli strumenti di sviluppo nell'ambiente .venv del progetto."
  (interactive)
  (let* ((root (gdev-python-root))
         (bin (or (gdev-python--venv-bin root)
                  (if (gdev-python--venv-exists-p root)
                      (user-error "L'ambiente .venv c'è, ma la cartella non è autorizzata: usa M-x gdev-trust-project")
                    (user-error "Crea prima l'ambiente del progetto con C-c l v"))))
         (python (expand-file-name
                  (if (string-suffix-p "/Scripts/" bin) "python.exe" "python") bin)))
    (gdev-compile (gdev-command-line (file-local-name python) "-m" "pip" "install"
                                    "pytest" "coverage" "debugpy" "build")
                  (gdev-python--output-name "build-strumenti" root) root)))

;;;; Esecuzione passo passo e misure

(defun gdev-python-debug-config (file python root args)
  "Restituisci la configurazione debugpy per FILE, PYTHON, ROOT e ARGS."
  (list 'modes gdev-python-modes
        'command python 'command-args '("-m" "debugpy.adapter") 'command-cwd root
        :type "python" :request "launch" :program file
        :cwd (file-local-name root) :python (vector python)
        :args (vconcat args)
        :justMyCode t :console "integratedTerminal"))

(defun gdev-python-debug (&optional ask-arguments)
  "Esegue il file Python passo passo con debugpy.
Con ASK-ARGUMENTS, chiede nuovamente gli argomenti del programma."
  (interactive "P")
  (let* ((file (gdev-python--file))
         (root (gdev-python-root))
         (python (gdev-python--interpreter root))
         (key (concat "python-debug:" buffer-file-name))
         (previous (gethash key gdev--last-program))
         (arguments (if (or ask-arguments (not previous))
                        (read-string "Argomenti: " previous 'gdev-program-arguments-history)
                      previous)))
    (save-buffer)
    (puthash key arguments gdev--last-program)
    (dape (gdev-python-debug-config file python root (gdev-shell-split arguments)))))

(defun gdev-python-profile (&optional ask-arguments)
  "Profila il file Python aperto, chiedendo di nuovo ASK-ARGUMENTS se richiesto."
  (interactive "P")
  (let ((root (gdev-python-root)))
    (gdev-run-file-with (list (gdev-python--interpreter root) "-m" "cProfile" "-s" "cumulative")
                        ask-arguments root
                        (gdev-python--output-name "profilo" root buffer-file-name))))

(defun gdev-python--run-then-report (test report)
  "Comando di shell: esegue TEST, poi REPORT anche se i test falliscono.
Lo stato di uscita è quello di TEST: con un test rosso la copertura dei dati
già raccolti compare lo stesso, e la compilazione risulta comunque fallita."
  (concat test "; status=$?; " report "; exit $status"))

(defun gdev-python-coverage ()
  "Misura la copertura dei test Python e mostra il rapporto nel pannello."
  (interactive)
  (let* ((root (gdev-python-root))
         (python (gdev-python--interpreter root)))
    (when (file-remote-p root)
      (user-error "La copertura con rapporto nello stato di GDev richiede un progetto locale"))
    (let* ((path (gdev-profile--output "python-coverage" "sqlite"))
           (data (expand-file-name "dati.sqlite"
                                   (make-temp-file (file-name-sans-extension path) t)))
           (prefix (list python "-m" "coverage")))
      (gdev-compile
       (gdev-python--run-then-report
        (gdev-python--test-command root nil
                                   (append prefix (list "run" "--branch" "--data-file" data)))
        (gdev-command-line python "-m" "coverage" "report" "--data-file" data "-m"))
       (gdev-python--output-name "coverage" root) root))))

;;;; Ruff

(defun gdev-python--ruff ()
  "Trova Ruff, privilegiando l'ambiente del progetto."
  (or (gdev-python--tool (gdev-python-root) "ruff")
      (user-error "Ruff non trovato. Su macOS puoi installarlo con brew install ruff")))

(defun gdev-python--stdin-name ()
  "Nome da passare a Ruff, anche per aree di testo senza file."
  (file-local-name (or buffer-file-name (expand-file-name "programma.py" default-directory))))

(defun gdev-python-ruff-format ()
  "Formatta l'area di testo con la configurazione di Ruff del progetto."
  (gdev-format-with-program (gdev-python--ruff) "format" "--quiet" "--stdin-filename"
                            (gdev-python--stdin-name) "-"))

(defun gdev-python--style-declared-p ()
  "Restituisce non nil se il progetto locale dichiara la configurazione di Ruff."
  (unless (file-remote-p default-directory)
    (let* ((root (gdev-python-root))
           (pyproject (expand-file-name "pyproject.toml" root)))
      (and (gdev-python--tool root "ruff")
           (or (gdev-project-file-exists-p root "ruff.toml" ".ruff.toml")
               (and (file-readable-p pyproject)
                    (with-temp-buffer
                      (insert-file-contents pyproject)
                      (re-search-forward "^[ \t]*\\[\\[?tool\\.ruff\\(?:\\.\\|]\\)"
                                         nil t))))))))

(defun gdev-python-organize-imports ()
  "Riordina le importazioni con Ruff."
  (interactive)
  (let ((gdev-format--background t))
    (gdev-format-with-program (gdev-python--ruff) "check" "--select" "I" "--fix-only"
                              "--no-unsafe-fixes" "--quiet" "--stdin-filename"
                              (gdev-python--stdin-name) "-")))

(defun gdev-python-fix ()
  "Applica le correzioni sicure abilitate nella configurazione di Ruff."
  (interactive)
  (let ((gdev-format--background t))
    (gdev-format-with-program (gdev-python--ruff) "check" "--fix-only"
                              "--no-unsafe-fixes" "--quiet" "--stdin-filename"
                              (gdev-python--stdin-name) "-")))

(defvar-local gdev-python--lint-process nil)
(defvar-local gdev-python--lint-root nil)

(defun gdev-python--position (source location)
  "Converte riga e colonna di Ruff in una posizione di SOURCE."
  (with-current-buffer source
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (max 0 (1- (alist-get 'row location))))
        (min (line-end-position) (+ (point) (max 0 (1- (alist-get 'column location)))))))))

(defun gdev-python--diagnostics (source)
  "Legge i risultati di Ruff e li riferisce all'area di testo SOURCE."
  (goto-char (point-min))
  (mapcar
   (lambda (entry)
     (let* ((location (alist-get 'location entry))
            (end-location (alist-get 'end_location entry))
            (start (gdev-python--position source location))
            (end (if end-location (gdev-python--position source end-location)
                   (with-current-buffer source
                     (save-restriction (widen) (min (point-max) (1+ start)))))))
       (flymake-make-diagnostic source start (max start end)
                                (if (member (alist-get 'code entry) '("invalid-syntax" "E999"))
                                    :error :warning)
                                (format "Ruff %s · %s" (alist-get 'code entry)
                                        (alist-get 'message entry)))))
   (json-parse-buffer :array-type 'list :object-type 'alist)))

(defun gdev-python-flymake (report-fn &rest _)
  "Controlla il testo con Ruff in secondo piano e chiama REPORT-FN."
  (when-let* ((previous gdev-python--lint-process))
    (setq gdev-python--lint-process nil)
    (when (process-live-p previous) (delete-process previous)))
  (if-let* (((not (file-remote-p default-directory)))
            (ruff (gdev-python--tool (or gdev-python--lint-root (gdev-python-root)) "ruff")))
      (let ((source (current-buffer))
            (output (generate-new-buffer " *Controllo Ruff*"))
            (errors (generate-new-buffer " *Errori Ruff*")))
        (condition-case err
            (progn
              (setq gdev-python--lint-process
                    (make-process
                     :name "gdev-ruff" :noquery t :connection-type 'pipe
                     :buffer output :stderr errors
                     :command (list ruff "check" "--no-fix" "--output-format" "json"
                                    "--stdin-filename" (gdev-python--stdin-name) "-")
                     :sentinel
                     (lambda (process _event)
                       (when (memq (process-status process) '(exit signal failed))
                         (unwind-protect
                             (when (and (buffer-live-p source)
                                        (eq process (buffer-local-value 'gdev-python--lint-process source)))
                               (with-current-buffer source
                                 (setq gdev-python--lint-process nil)
                                 (if (and (eq (process-status process) 'exit)
                                          (<= (process-exit-status process) 1))
                                     (condition-case err
                                         (funcall report-fn (with-current-buffer output
                                                              (gdev-python--diagnostics source)))
                                       (json-parse-error
                                        (funcall report-fn :panic :explanation
                                                 (format "Risposta di Ruff illeggibile: %s"
                                                         (error-message-string err)))))
                                   (funcall report-fn :panic :explanation
                                            (with-current-buffer errors
                                              (string-trim (buffer-string)))))))
                           (kill-buffer output)
                           (kill-buffer errors))))))
              (save-restriction
                (widen)
                (process-send-region gdev-python--lint-process (point-min) (point-max))
                (process-send-eof gdev-python--lint-process)))
          (file-error
           (kill-buffer output)
           (kill-buffer errors)
           (funcall report-fn :panic :explanation (error-message-string err)))))
    (funcall report-fn nil)))

(defun gdev-python--enable-checks ()
  "Attiva le segnalazioni locali di Ruff per Python."
  (when-let* (((derived-mode-p 'python-mode 'python-ts-mode))
              ((not (file-remote-p default-directory)))
              (root (gdev-python-root))
              ((gdev-python--tool root "ruff")))
    (setq-local gdev-python--lint-root root)
    (add-hook 'flymake-diagnostic-functions #'gdev-python-flymake nil t)
    (flymake-mode 1)))

(gdev-module-add-hook 'python-mode-hook #'gdev-python--enable-checks)
(gdev-module-add-hook 'python-ts-mode-hook #'gdev-python--enable-checks)
(gdev-module-add-hook 'eglot-managed-mode-hook #'gdev-python--enable-checks)

(gdev-set-runner gdev-python-modes :run #'gdev-python-run-file :test #'gdev-python-test-file)
(gdev-set-handler :test-project gdev-python-modes #'gdev-python-test-project)
(gdev-set-handler :build-root gdev-python-modes #'gdev-python-root)
(gdev-set-repl gdev-python-modes #'gdev-python-repl)
(gdev-set-eval gdev-python-modes #'gdev-python-eval)
(gdev-set-debugger gdev-python-modes #'gdev-python-debug)
(gdev-set-profiler gdev-python-modes #'gdev-python-profile)
(gdev-set-coverage gdev-python-modes #'gdev-python-coverage)
(gdev-set-formatter gdev-python-modes #'gdev-python-ruff-format)
(gdev-set-handler :organize-imports gdev-python-modes #'gdev-python-organize-imports)
(gdev-set-handler :format-style gdev-python-modes #'gdev-python--style-declared-p)
(gdev-set-docsets gdev-python-modes "python~3.14")
(gdev-set-other-file gdev-python-modes #'gdev-python-open-companion)
(gdev-set-popup-rule "\\`\\*Python\\[.*\\]\\*\\'" :select t)

(gdev-localleader python python-base-mode-map
  "a" "applica le correzioni sicure" #'gdev-python-fix
  "b" "genera i pacchetti distribuibili" #'gdev-python-build
  "i" "riordina le importazioni" #'gdev-python-organize-imports
  "s" "installa gli strumenti Python" #'gdev-python-install-tools
  "t" "esegui il test sotto il cursore" #'gdev-python-test-at-point
  "v" "crea l'ambiente virtuale" #'gdev-python-create-venv
  "T" "esegui i test del progetto" #'gdev-python-test-project)

(gdev-doctor-executable "python3" "brew install python3")
(gdev-doctor-executable "ruff" "brew install ruff" 'note)
(gdev-doctor-executable "ty" "brew install ty" 'note)

;;; config.el ends here
