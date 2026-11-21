;;; gdev-project-view.el --- Git, esecuzione e test nello spazio corrente -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Le viste laterali danno accesso a Git e ai comandi di sviluppo. La vista
;; Test legge il catalogo CTest, pytest, Deno o Node e conserva gli esiti.

;;; Code:

(require 'gdev-activity)
(require 'gdev-compilation)
(require 'gdev-debug-workbench)
(require 'gdev-launch)
(require 'gdev-test-catalog)
(require 'gdev-workspace-state)
(require 'project)
(require 'json)
(require 'compile)

(declare-function gdev-git-status "gdev-commands")
(declare-function gdev-open-file "gdev-commands")
(declare-function gdev-call-with-editor "gdev-commands" (function))
(declare-function gdev-workspace-directory "gdev-workspace-roots")
(declare-function gdev-run-dwim "../../tools/build/config")
(declare-function gdev-test-dwim "../../tools/build/config")
(declare-function gdev-debug-dwim "../../tools/debugger/config" (&optional ask-arguments))
(declare-function gdev-build "../../tools/build/config")
(declare-function gdev-build-configure "../../tools/build/config")
(declare-function gdev-cmake-test-context "../../tools/build/config" (root))
(declare-function gdev-python-root "../../lang/python/config" (&optional directory))
(declare-function gdev-test-coverage-show "gdev-test-coverage" (&optional root))
(declare-function gdev-test-coverage-run "gdev-test-coverage-providers" (&optional root provider))
(declare-function gdev-workbench-operation-progress "gdev-workbench-operations" (buffer detail))

(defcustom gdev-project-test-jobs nil
  "Numero di processi di prova per CTest, Deno e Node.
Con nil usa le impostazioni del progetto e quelle predefinite dello strumento."
  :type '(choice (const :tag "Impostazioni del progetto" nil) (integer :tag "Processi"))
  :safe (lambda (value) (or (null value) (and (integerp value) (> value 0))))
  :group 'gdev)

(defvar-local gdev-project-view--root nil)
(defvar-local gdev-project-view--context nil)
(defvar-local gdev-project-view--test-family nil)
(defvar-local gdev-project-view--lines nil)
(defvar-local gdev-project-view--process nil)
(defvar-local gdev-project-view--request nil)
(defvar-local gdev-project-view--discovery-log nil)
(defvar-local gdev-project-view--test-run nil)
(defvar-local gdev-project-view--status nil)
(defvar-local gdev-project-view--test-dir nil)
(defvar-local gdev-project-view--test-configuration nil)
(defvar-local gdev-project-view--test-preset nil)
(defvar-local gdev-project-view--test-build-command nil)
(defvar-local gdev-project-view--test-provider nil)
(defvar-local gdev-project-view--results nil)
(defvar-local gdev-project-view--collapsed nil)
(defvar-local gdev-project-view--result-filter nil)
(defvar-local gdev-project-view--group-filter nil)
(defvar-local gdev-project-view--test-status-marker nil)

(define-derived-mode gdev-project-view-mode special-mode "Attività"
  "Vista degli strumenti del progetto."
  (gdev-ui-view-setup 'sidebar)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (gdev-project-view--cancel-request)
              (gdev-project-view--clear-discovery-log)) nil t))

(defun gdev-project-view--clear-discovery-log ()
  "Rilascia il registro temporaneo posseduto da questa vista."
  (when (buffer-live-p gdev-project-view--discovery-log)
    (kill-buffer gdev-project-view--discovery-log))
  (setq gdev-project-view--discovery-log nil))

(defun gdev-project-view--cancel-request ()
  "Invalida la richiesta prima di interrompere il suo processo."
  (let ((process gdev-project-view--process))
    (setq gdev-project-view--request nil gdev-project-view--process nil)
    (when (process-live-p process) (delete-process process))))

(defun gdev-project-view-cancel-discovery ()
  "Interrompi il rilevamento dei test della vista corrente."
  (interactive)
  (unless (and (eq gdev-activity-kind 'test) gdev-project-view--request)
    (user-error "Nessun rilevamento dei test in corso"))
  (gdev-project-view--cancel-request)
  (setq gdev-project-view--status "Rilevamento interrotto")
  (gdev-project-view--render))

(defun gdev-project-view-discovery-log ()
  "Apri il registro dell'ultimo rilevamento dei test non riuscito."
  (interactive)
  (unless (buffer-live-p gdev-project-view--discovery-log)
    (user-error "Nessun registro di rilevamento disponibile"))
  (gdev-layout-show-panel gdev-project-view--discovery-log))

(put 'gdev-project-view-cancel-discovery 'gdev-menu-available
     (lambda () (and (eq gdev-activity-kind 'test) gdev-project-view--request)))
(put 'gdev-project-view-discovery-log 'gdev-menu-available
     (lambda () (buffer-live-p gdev-project-view--discovery-log)))

(defun gdev-project-view--retain-discovery-log (output command directory reason)
  "Conserva OUTPUT di COMMAND in DIRECTORY con la diagnosi REASON."
  (let ((detail (with-current-buffer output
                  (car (split-string (buffer-string) "[\r\n]+" t "[[:blank:]]+")))))
    (setq gdev-project-view--status
          (concat reason (when detail (concat "\n" (truncate-string-to-width detail 180 nil nil "…"))))
          gdev-project-view--discovery-log output)
    (with-current-buffer output
      (rename-buffer (format "*Rilevamento test · %s*"
                             (abbreviate-file-name (directory-file-name directory))) t)
      (goto-char (point-min))
      (insert "Rilevamento dei test\n\nCartella: " directory "\nComando: "
              (gdev-command-line (car command) (cdr command)) "\nEsito: " reason "\n\n")
      (compilation-mode)
      (gdev-ui-view-setup 'native)
      (setq-local default-directory directory)
      (goto-char (point-min))
      (set-buffer-modified-p nil))))

(defun gdev-project-view--run-command (command)
  "Esegui COMMAND dal gruppo di modifica attivo."
  (when (commandp command)
    (gdev-call-with-editor (lambda () (call-interactively command)))))

(defun gdev-project-view--button (label action &optional id primary)
  (insert-text-button label 'type 'gdev-ui-action
                      'action action 'help-echo label 'gdev-project-view-id id
                      'face (if primary 'gdev-ui-action-primary 'gdev-ui-action))
  (insert "\n"))

(defun gdev-project-view--test-controls (root)
  "Mostra i passi disponibili per i test di ROOT."
  (setq-local truncate-lines nil word-wrap t)
  (if (and (commandp 'gdev-build-configure)
           (not (file-remote-p root))
           (gdev-project-file-exists-p root "CMakeLists.txt"))
      (progn
        (unless (or gdev-project-view--status gdev-project-view--test-provider)
          (insert (propertize "Configura CMake per rilevare i test, poi compila per eseguirli."
                              'face 'gdev-ui-secondary)
                  "\n\n"))
        (gdev-project-view--button
         "Configura CMake" (lambda (_) (gdev-project-view--run-command #'gdev-build-configure))
         'configure (not gdev-project-view--test-provider))
        (gdev-project-view--button
         "Compila" (lambda (_) (gdev-project-view--run-command #'gdev-build)) 'build))
    (gdev-project-view--button
     "Esegui test del documento" (lambda (_) (gdev-project-view--run-command #'gdev-test-dwim))
     'test-document))
  (gdev-project-view--button
   (if (buffer-live-p gdev-project-view--discovery-log) "Riprova" "Rileva test")
   (lambda (_) (gdev-project-view-refresh)) 'discover)
  (when (buffer-live-p gdev-project-view--discovery-log)
    (gdev-project-view--button "Apri registro" (lambda (_) (gdev-project-view-discovery-log)) 'discovery-log))
  (when gdev-project-view--request
    (gdev-project-view--button "Interrompi rilevamento"
                              (lambda (_) (gdev-project-view-cancel-discovery)) 'discovery-stop))
  (gdev-project-view--button "Esegui test al cursore" (lambda (_) (gdev-project-view-test-at-point)) 'test-point)
  (when gdev-project-view--lines
    (gdev-project-view--button "Esegui tutti i test" (lambda (_) (gdev-project-view-test-all)) 'test-all t)
    (when (member "Fallito" (hash-table-values gdev-project-view--results))
      (gdev-project-view--button "Riesegui i falliti" (lambda (_) (gdev-project-view-test-failed)) 'test-failed))
    (gdev-project-view--button (concat "Esito · " (or gdev-project-view--result-filter "Tutti"))
                              (lambda (_) (gdev-project-view-test-filter-result)) 'test-filter-result)
    (gdev-project-view--button (concat "Gruppo · " (or gdev-project-view--group-filter "Tutti"))
                              (lambda (_) (gdev-project-view-test-filter-group)) 'test-filter-group)
    (when (or gdev-project-view--result-filter gdev-project-view--group-filter)
      (gdev-project-view--button "Esegui i test filtrati"
                                (lambda (_) (gdev-project-view-test-filtered)) 'test-filtered)))
  (when (commandp 'gdev-test-coverage-run)
    (gdev-project-view--button "Misura copertura…"
                              (lambda (_) (gdev-test-coverage-run root))
                              'test-coverage-run))
  (when (commandp 'gdev-test-coverage-show)
    (gdev-project-view--button "Rapporto di copertura"
                              (lambda (_) (gdev-test-coverage-show root)) 'test-coverage-show))
  (when (buffer-live-p gdev-project-view--test-run)
    (gdev-project-view--button "Mostra output dei test"
                              (lambda (_) (pop-to-buffer gdev-project-view--test-run)) 'test-output)
    (when (process-live-p (get-buffer-process gdev-project-view--test-run))
      (gdev-project-view--button
       "Interrompi test" (lambda (_)
                          (with-current-buffer gdev-project-view--test-run
                            (call-interactively (if (commandp 'gdev-workbench-operation-cancel)
                                                    'gdev-workbench-operation-cancel
                                                  #'kill-compilation)))) 'test-stop)))
  (when gdev-project-view--lines (insert "\n")))

(defun gdev-project-view--test-groups (test)
  "Ricava le etichette o la cartella di TEST."
  (or (alist-get 'gdev-groups test)
      (if-let* ((location (alist-get 'gdev-location test)))
          (let ((directory (file-relative-name (file-name-directory (car location))
                                              gdev-project-view--root)))
            (list (if (equal directory "./") "Test del progetto" (directory-file-name directory))))
        '("Test del progetto"))))

(defun gdev-project-view--test-group (test)
  "Scegli il gruppo in cui presentare TEST dopo il filtro."
  (or gdev-project-view--group-filter (car (gdev-project-view--test-groups test))))

(defun gdev-project-view--test-result (test)
  "Restituisci l'esito registrato per TEST."
  (or (gethash (alist-get 'name test) gdev-project-view--results) "Da eseguire"))

(defun gdev-project-view--filtered-tests ()
  "Restituisci i test corrispondenti ai filtri di gruppo ed esito."
  (seq-filter
   (lambda (test)
     (and (or (not gdev-project-view--group-filter)
              (member gdev-project-view--group-filter (gdev-project-view--test-groups test)))
          (or (not gdev-project-view--result-filter)
              (equal (gdev-project-view--test-result test) gdev-project-view--result-filter))))
   gdev-project-view--lines))

(defun gdev-project-view-test-filter-result ()
  "Filtra il catalogo Test per esito."
  (interactive)
  (unless (eq gdev-activity-kind 'test) (user-error "Apri la vista Test"))
  (let ((choice (completing-read "Esito: " '("Tutti" "Passato" "Fallito" "Saltato" "Da eseguire")
                                 nil t nil nil (or gdev-project-view--result-filter "Tutti"))))
    (setq gdev-project-view--result-filter (unless (equal choice "Tutti") choice)))
  (gdev-project-view--render))

(defun gdev-project-view-test-filter-group ()
  "Filtra il catalogo Test per gruppo."
  (interactive)
  (unless (eq gdev-activity-kind 'test) (user-error "Apri la vista Test"))
  (let* ((groups (sort (seq-uniq (apply #'append (mapcar #'gdev-project-view--test-groups
                                                        gdev-project-view--lines))) #'string<))
         (choice (completing-read "Gruppo: " (cons "Tutti i gruppi" groups)
                                  nil t nil nil (or gdev-project-view--group-filter "Tutti i gruppi"))))
    (setq gdev-project-view--group-filter (unless (equal choice "Tutti i gruppi") choice)))
  (gdev-project-view--render))

(defun gdev-project-view--render-tests ()
  "Disegna gruppi richiudibili con esiti e collegamenti ai sorgenti."
  (let ((tests (gdev-project-view--filtered-tests)))
    (when (and gdev-project-view--lines (not tests))
      (insert (propertize "Nessun test corrisponde ai filtri" 'face 'gdev-ui-secondary) "\n"))
    (dolist (group (seq-group-by #'gdev-project-view--test-group tests))
      (let* ((name (car group))
             (closed (member name gdev-project-view--collapsed)))
        (gdev-project-view--button
         (concat (if closed "▸ " "▾ ") name)
         (lambda (_)
           (setq gdev-project-view--collapsed
                 (if closed (remove name gdev-project-view--collapsed)
                   (cons name gdev-project-view--collapsed)))
           (gdev-project-view--render))
         (cons 'group name))
        (unless closed
          (dolist (test (cdr group))
            (let* ((test-name (alist-get 'name test))
                   (result (gdev-project-view--test-result test)))
              (gdev-project-view--button (concat "  " result "  " test-name)
                                         (lambda (_) (gdev-project-view--test test-name)) test-name)
              (when-let* ((location (alist-get 'gdev-location test)))
                (gdev-project-view--button
                 (if (eq gdev-project-view--test-provider 'ctest)
                     "    Vai alla registrazione" "    Apri sorgente")
                 (lambda (_)
                   (gdev-open-file (car location))
                   (goto-char (point-min))
                   (forward-line (1- (cdr location))))
                 (cons 'code test-name))))))))))

(defun gdev-project-view--render ()
  "Aggiorna il contenuto della vista corrente."
  (let* ((inhibit-read-only t)
         (old-point (point))
         (old-id (when-let* ((button (button-at (point))))
                   (button-get button 'gdev-project-view-id)))
         (starts (gdev-ui-window-starts))
         (root gdev-project-view--root))
    (erase-buffer)
    (unless (eq gdev-activity-kind 'run)
      (insert (propertize (nth 1 (assq gdev-activity-kind gdev-activity-views)) 'face 'gdev-ui-side-title)
              "\n" (propertize (abbreviate-file-name root) 'face 'gdev-ui-secondary 'help-echo root) "\n\n"))
    (when gdev-project-view--status
      (when (eq gdev-activity-kind 'test)
        (unless (markerp gdev-project-view--test-status-marker)
          (setq gdev-project-view--test-status-marker (make-marker)))
        (set-marker gdev-project-view--test-status-marker (point)))
      (insert (propertize gdev-project-view--status 'face 'gdev-ui-secondary) "\n\n"))
    (pcase gdev-activity-kind
      ('git
       (gdev-project-view--button "Apri Hit" (lambda (_) (gdev-project-view--run-command #'gdev-git-status))
                                  'git-open t)
       (gdev-project-view--button "Aggiorna modifiche" (lambda (_) (gdev-project-view-refresh)) 'git-refresh)
       (insert "\n")
       (dolist (entry gdev-project-view--lines)
         (pcase-let ((`(,status . ,file) entry))
           (gdev-project-view--button
            (concat status "  " file)
            (lambda (_)
              (let ((path (gdev-project-view--git-path file root)))
                (if (file-exists-p path) (gdev-open-file path)
                  (gdev-project-view--run-command #'gdev-git-status)))) file))))
      ('run (gdev-debug-workbench-render root (car (gdev-launch-selected root))))
      ('test
       (gdev-project-view--test-controls root)
       (gdev-project-view--render-tests)))
    (goto-char (min old-point (point-max)))
    (when old-id
      (goto-char (point-min))
      (let ((button (next-button (point-min) t)))
        (while (and button (not (equal old-id (button-get button 'gdev-project-view-id))))
          (setq button (next-button (button-end button))))
        (if button (goto-char (button-start button))
          (goto-char (min old-point (point-max))))))
    (gdev-ui-restore-windows starts)))

(defun gdev-project-view-buffer (view)
  "Restituisce il buffer di VIEW senza interrogare gli strumenti."
  (let ((buffer (gdev-activity-buffer view (format "*GDev %s*" (nth 1 (assq view gdev-activity-views)))
                                     #'gdev-project-view-mode)))
    (when (and (eq view 'run) (not (buffer-local-value 'gdev-debug-workbench--owner buffer)))
      (with-current-buffer buffer (gdev-debug-workbench-initialize)))
    (gdev-project-view-sync buffer)
    buffer))

(defun gdev-project-view-sync (buffer)
  "Allinea BUFFER al gruppo editor e restituisci t se lo ridisegni."
  (let* ((editor (window-buffer (gdev-layout-editor)))
         (directory (buffer-local-value 'default-directory editor))
         (workspace (and (fboundp 'gdev-workspace-directory) (gdev-workspace-directory directory))))
    (with-current-buffer buffer
      (let* ((run (eq gdev-activity-kind 'run))
             (test (eq gdev-activity-kind 'test))
             (mode (when test (buffer-local-value 'major-mode editor)))
             (language (when test (gdev-test-catalog-language mode)))
             (profiles (and run gdev-launch-profiles))
             (context (list workspace directory profiles language)))
        (unless (equal context gdev-project-view--context)
          (let* ((profiles-changed (not (equal profiles (nth 2 gdev-project-view--context))))
                 (base (or (and run (gdev-launch-profile-root directory))
                           workspace (gdev-project-root directory)))
                 (root (if test (gdev-project-view--test-root language base directory) base))
                 (new-root (not (equal root gdev-project-view--root)))
                 (family (when (and test (not (file-remote-p root)))
                           (or language
                               (pcase (gdev-test-catalog-provider
                                       mode root (and (not new-root)
                                                      (eq gdev-project-view--test-provider 'ctest)
                                                      gdev-project-view--test-dir))
                                 ((or 'node 'deno) 'javascript)
                                 ('pytest 'python)))))
                 (reset (or new-root (not (eq family gdev-project-view--test-family)))))
            (setq gdev-project-view--context context
                  gdev-project-view--test-family family)
            (when reset
              (gdev-project-view--cancel-request)
              (gdev-project-view--clear-discovery-log)
              (setq default-directory root
                    gdev-project-view--root root gdev-project-view--lines nil
                    gdev-project-view--test-dir nil gdev-project-view--test-run nil
                    gdev-project-view--test-configuration nil
                    gdev-project-view--test-preset nil
                    gdev-project-view--test-build-command nil
                    gdev-project-view--test-provider nil
                    gdev-project-view--status nil gdev-project-view--collapsed nil
                    gdev-project-view--group-filter nil gdev-project-view--result-filter nil
                    gdev-project-view--results (make-hash-table :test #'equal)))
            (when (or reset profiles-changed)
              (gdev-project-view--render)
              t)))))))

(defun gdev-project-view--start (command directory callback &optional accepted-statuses)
  "Esegui COMMAND in DIRECTORY, poi consegna l'output a CALLBACK.
ACCEPTED-STATUSES contiene i codici di uscita ammessi."
  (unless (file-executable-p (or (executable-find (car command)) ""))
    (user-error "Comando non disponibile: %s" (car command)))
  (let ((view (current-buffer))
        (default-directory directory)
        (output (generate-new-buffer " *gdev attività*"))
        (request (list command directory)))
    (gdev-project-view--cancel-request)
    (gdev-project-view--clear-discovery-log)
    ;; L'identità precede make-process, che può già consegnare la sentinella.
    (setq gdev-project-view--request request)
    (condition-case err
        (let ((process
               (make-process
               :name "gdev-attività" :buffer output :command command :noquery t
               :sentinel (lambda (process _event)
                           (when (memq (process-status process) '(exit signal))
                             (let (retained)
                               (unwind-protect
                                   (when (and (buffer-live-p view) (buffer-live-p output))
                                     (with-current-buffer view
                                       (when (eq request gdev-project-view--request)
                                         (setq gdev-project-view--process nil gdev-project-view--request nil)
                                         (condition-case problem
                                             (if (and (eq (process-status process) 'exit)
                                                      (memq (process-exit-status process)
                                                            (or accepted-statuses '(0))))
                                                 (funcall callback (with-current-buffer output (buffer-string)))
                                               (setq gdev-project-view--status
                                                     (format "Comando non riuscito (uscita %d)"
                                                             (process-exit-status process)))
                                               (when (eq gdev-activity-kind 'test)
                                                 (gdev-project-view--retain-discovery-log
                                                  output command directory
                                                  (format "Rilevamento non riuscito (uscita %d)"
                                                          (process-exit-status process)))
                                                 (setq retained t)))
                                           (error
                                            (setq gdev-project-view--status (error-message-string problem))
                                            (when (eq gdev-activity-kind 'test)
                                              (gdev-project-view--retain-discovery-log
                                               output command directory (error-message-string problem))
                                              (setq retained t))))
                                         (gdev-project-view--render))))
                                 (unless retained
                                   (when (buffer-live-p output) (kill-buffer output))))))))))
          (when (eq request gdev-project-view--request)
            (setq gdev-project-view--process process))
          process)
      (error
       (setq gdev-project-view--request nil gdev-project-view--process nil)
       (when (buffer-live-p output) (kill-buffer output))
       (signal (car err) (cdr err))))))

(defun gdev-project-view--git-parse (output)
  "Leggi da OUTPUT lo stato Git in formato porcelain con separatori NUL."
  (let ((entries (split-string output "\0" t))
        changed)
    (while entries
      (let* ((entry (pop entries))
             (status (substring entry 0 2)))
        (push (cons status (substring entry 3)) changed)
        (when (string-match-p "[RC]" status) (pop entries))))
    (nreverse changed)))

(defun gdev-project-view--ctest-parse (output root)
  "Leggi il catalogo CTest OUTPUT e associa i test alle posizioni in ROOT."
  (let* ((data (json-parse-string output :object-type 'alist :array-type 'array))
         (graph (alist-get 'backtraceGraph data))
         (files (alist-get 'files graph))
         (nodes (alist-get 'nodes graph)))
    (mapcar (lambda (test)
              (let ((labels (seq-find (lambda (entry) (equal (alist-get 'name entry) "LABELS"))
                                      (alist-get 'properties test))))
                (when-let* ((groups (seq-filter #'stringp (alist-get 'value labels))))
                  (push (cons 'gdev-groups (append groups nil)) test)))
              (if-let* ((index (alist-get 'backtrace test))
                        (node (and nodes (aref nodes index)))
                        (file (and files (aref files (alist-get 'file node))))
                        (line (alist-get 'line node)))
                  (cons (cons 'gdev-location (cons (expand-file-name file root) line)) test)
                test))
            (alist-get 'tests data))))

(defun gdev-project-view--ctest-context ()
  "Ricava la configurazione CTest per il progetto visualizzato."
  (let ((root gdev-project-view--root))
    (if (fboundp 'gdev-cmake-test-context)
        (gdev-cmake-test-context root)
      (when-let* ((directory (seq-find
                              (lambda (dir) (file-regular-p (expand-file-name "CTestTestfile.cmake" dir)))
                              (list (expand-file-name "build" root) root))))
        (list :directory directory)))))

(defun gdev-project-view--ctest-options (directory preset configuration)
  "Restituisci le opzioni del catalogo per DIRECTORY, PRESET e CONFIGURATION."
  (append (if preset (list "--preset" preset) (list "--test-dir" directory))
          (when configuration (list "-C" configuration))))

(defun gdev-project-view--test-root (language root directory)
  "Trova la radice annidata di LANGUAGE sopra DIRECTORY, entro ROOT."
  (if (eq language 'javascript)
      (gdev-project-javascript-root directory root)
    (let* ((predicate (lambda (dir)
                        (or (gdev-project-javascript-runtime dir)
                            (gdev-project-file-exists-p dir "pyproject.toml" "pytest.ini" "setup.cfg"))))
           (candidate (unless (or (file-remote-p root) (file-remote-p directory))
                        (if (eq language 'python) (gdev-python-root directory)
                          (locate-dominating-file directory predicate)))))
      (if (and candidate (file-in-directory-p candidate root))
          (file-name-as-directory (expand-file-name candidate))
        root))))

(defun gdev-project-view--test-refresh (&optional ctest-context callback)
  "Rileva i test, riusa CTEST-CONTEXT e consegna il catalogo a CALLBACK."
  (let* ((root gdev-project-view--root)
         (editor (window-buffer (gdev-layout-editor)))
         (ctest-context (progn
                          (with-current-buffer editor (gdev-require-project-environment))
                          (or ctest-context (gdev-project-view--ctest-context))))
         (ctest (plist-get ctest-context :directory))
         (provider (gdev-test-catalog-provider (buffer-local-value 'major-mode editor) root ctest))
         (configuration (when (eq provider 'ctest) (plist-get ctest-context :configuration)))
         (preset (when (eq provider 'ctest) (plist-get ctest-context :preset)))
         (directory (if (eq provider 'ctest) ctest root))
         (command (pcase provider
                    ('ctest (append '("ctest" "--show-only=json-v1")
                                    (gdev-project-view--ctest-options directory preset configuration)))
                    ('pytest (with-current-buffer editor
                               (gdev-test-catalog-pytest-command directory "--collect-only" "-q")))
                    ('deno gdev-test-catalog-deno-files)
                    ('node gdev-test-catalog-node-files)
                    (_ (if (gdev-project-file-exists-p root "CMakeLists.txt")
                           (user-error "Configura CMake con i test abilitati, poi scegli Rileva test")
                         (user-error "Apri un progetto Python o JavaScript, oppure configura CMake per CTest")))))
         (exec-path (buffer-local-value 'exec-path editor))
         (process-environment (buffer-local-value 'process-environment editor))
         (reader (pcase provider
                   ('ctest #'gdev-project-view--ctest-parse)
                   ('pytest #'gdev-test-catalog-pytest)
                   ((or 'deno 'node) #'gdev-test-catalog-files)))
         (title (gdev-test-catalog-title provider)))
    (gdev-project-view--start
     command (if preset root directory)
     (lambda (output)
       (let* ((entries (funcall reader output (if (eq provider 'ctest) root directory)))
              (results (make-hash-table :test #'equal)))
         (if (and (eq provider gdev-project-view--test-provider)
                  (equal directory gdev-project-view--test-dir)
                  (equal preset gdev-project-view--test-preset)
                  (equal configuration gdev-project-view--test-configuration))
             (dolist (entry entries)
               (let ((id (alist-get 'name entry)))
                 (when-let* ((result (gethash id gdev-project-view--results)))
                   (puthash id result results))))
           (setq gdev-project-view--collapsed nil gdev-project-view--test-run nil))
         (setq gdev-project-view--test-provider provider
               gdev-project-view--test-dir directory
               gdev-project-view--test-configuration configuration
               gdev-project-view--test-preset preset
               gdev-project-view--test-build-command (when (eq provider 'ctest)
                                                       (plist-get ctest-context :build-command))
               gdev-project-view--lines entries
               gdev-project-view--results results
               gdev-project-view--status (if entries (format "%d test · %s" (length entries) title)
                                           (format "Nessun test · %s" title)))
         (when callback (funcall callback))))
     (pcase provider ('pytest '(0 5)) ((or 'deno 'node) '(0 1))))
    (when gdev-project-view--request
      (setq gdev-project-view--status (format "Rilevamento dei test · %s…" title)))
    (gdev-project-view--render)))

(defun gdev-project-view-refresh ()
  "Aggiorna le modifiche Git o individua i test della vista corrente."
  (interactive)
  (unless (memq gdev-activity-kind '(git test)) (user-error "Apri prima Git o Test"))
  (gdev-project-view-sync (current-buffer))
  (let ((root gdev-project-view--root))
    (when (file-remote-p root) (user-error "Aggiornamento laterale disponibile per progetti locali"))
    (pcase gdev-activity-kind
      ('git (gdev-project-view--start
             ;; Senza --no-optional-locks il comando prende il blocco dell'indice
             ;; e può far fallire un commit in corso da Hit.
             '("git" "--no-optional-locks" "status" "--porcelain=v1" "-z") root
             (lambda (output)
               (setq gdev-project-view--lines (gdev-project-view--git-parse output)
                     gdev-project-view--status
                     (if gdev-project-view--lines nil "Albero di lavoro pulito")))))
      ('test (gdev-project-view--test-refresh)))))

(defun gdev-project-view--git-path (file root)
  "Percorso di FILE, letto da git status nella cartella ROOT.
Il formato porcelain indica i percorsi dalla radice del repository, che può
contenere ROOT."
  (expand-file-name file (or (locate-dominating-file root ".git") root)))

(defun gdev-project-view--ctest-results (&optional start end results)
  "Aggiungi a RESULTS gli esiti CTest compresi tra START ed END."
  (let ((results (or results (make-hash-table :test #'equal))))
    (save-excursion
      (goto-char (or start (point-min)))
      (while (re-search-forward
              "Test +#[0-9]+: +\\(.*?\\) +\\.\\.+ *\\(Passed\\|\\*\\*\\*Not Run\\|\\*\\*\\*[^[:space:]]+\\)" end t)
        (puthash (match-string-no-properties 1)
                 (pcase (match-string 2) ("Passed" "Passato") ("***Not Run" "Saltato") (_ "Fallito"))
                 results)))
    results))

(defun gdev-project-view--test-results (provider directory &optional start end results)
  "Aggiungi a RESULTS gli esiti del PROVIDER in DIRECTORY tra START ed END."
  (if (memq provider '(nil ctest))
      (gdev-project-view--ctest-results start end results)
    (gdev-test-catalog-results provider directory start end results)))

(defun gdev-project-view--test-progress (view buffer completed)
  "Aggiorna solo lo stato di VIEW se BUFFER ha prodotto COMPLETED esiti."
  (when (and (> completed 0) (buffer-live-p view))
    (with-current-buffer view
      (when (eq buffer gdev-project-view--test-run)
        (let ((status (if (= completed 1) "Test in esecuzione · 1 completato"
                        (format "Test in esecuzione · %d completati" completed))))
          (unless (equal status gdev-project-view--status)
            (setq gdev-project-view--status status)
            (when (fboundp 'gdev-workbench-operation-progress)
              (gdev-workbench-operation-progress buffer
                                                 (if (= completed 1) "1 test completato"
                                                   (format "%d test completati" completed))))
            (when (and (get-buffer-window view t)
                       (markerp gdev-project-view--test-status-marker)
                       (marker-position gdev-project-view--test-status-marker))
              (let ((inhibit-read-only t))
                (save-excursion
                  (goto-char gdev-project-view--test-status-marker)
                  (delete-region (point) (line-end-position))
                  (insert (propertize status 'face 'gdev-ui-secondary)))))))))))

(defun gdev-project-view--track-test-progress (view output provider directory)
  "Leggi per VIEW solo le nuove righe di OUTPUT del PROVIDER in DIRECTORY."
  (when (and (memq provider '(ctest pytest)) (get-buffer-process output))
    (with-current-buffer output
      (let ((offset (copy-marker (point-min)))
            (results (make-hash-table :test #'equal)))
        (let ((filter
               (lambda ()
                 (save-restriction
                   (widen)
                   (let ((end (save-excursion (goto-char (point-max)) (line-beginning-position))))
                     (when (< offset end)
                       (gdev-project-view--test-results provider directory offset end results)
                       (set-marker offset end)
                       (gdev-project-view--test-progress view output (hash-table-count results))))))))
          (add-hook 'compilation-filter-hook filter nil t)
          filter)))))

(defun gdev-project-view--test-finish (view root buffer status &optional provider)
  "Aggiorna in VIEW gli esiti del PROVIDER nel BUFFER per ROOT."
  (when (buffer-live-p view)
    (with-current-buffer view
      (when (and (eq buffer gdev-project-view--test-run) (equal root gdev-project-view--root))
        (let* ((directory gdev-project-view--test-dir)
               (results (with-current-buffer buffer (gdev-project-view--test-results provider directory)))
               (count (hash-table-count results)))
          (maphash (lambda (name result) (puthash name result gdev-project-view--results)) results)
          (setq gdev-project-view--status
                (cond ((eq status 'signal) "Esecuzione interrotta")
                      ((= count 1) "Esecuzione terminata · 1 esito")
                      ((> count 1) (format "Esecuzione terminata · %d esiti" count))
                      (t "Consulta l’output dei test")))
          (gdev-project-view--render))))))

(defun gdev-project-view--ctest-selection (names)
  "Seleziona esattamente i test CTest chiamati NAMES.
CTest assegna i numeri prima di applicare i filtri del preset."
  (when names
    (list "-R" (concat "^("
                      (mapconcat (lambda (name)
                                   (mapconcat (lambda (char)
                                                (if (memq char '(?\\ ?. ?^ ?$ ?* ?+ ?? ?\( ?\) ?\[ ?\] ?|))
                                                    (string ?\\ char)
                                                  (string char)))
                                              name ""))
                                 names "|")
                      ")$"))))

(defun gdev-project-view--test (selection)
  "Esegui SELECTION, tutti i test o quelli precedentemente falliti."
  (when (or (gdev-project-view-sync (current-buffer)) (not gdev-project-view--lines))
    (user-error "Il progetto dei test è cambiato. Scegli Rileva test"))
  (unless (or (null gdev-project-test-jobs)
              (and (integerp gdev-project-test-jobs) (> gdev-project-test-jobs 0)))
    (user-error "Il numero di processi di prova deve essere positivo"))
  (let* ((view (current-buffer))
         (root gdev-project-view--root)
         (provider gdev-project-view--test-provider)
         (directory gdev-project-view--test-dir)
         (editor (window-buffer (gdev-layout-editor)))
         (frame (selected-frame))
         (owner (gdev-workspace-state-ensure-id frame))
         (preset gdev-project-view--test-preset)
         (jobs gdev-project-test-jobs)
         (ids (cond ((stringp selection) (list selection))
                    ((eq selection 'failed)
                     (cl-loop for test in gdev-project-view--lines for id = (alist-get 'name test)
                              when (equal (gethash id gdev-project-view--results) "Fallito")
                              collect id))
                    (t selection)))
         (command (if (eq provider 'ctest)
                      (append '("ctest" "--output-on-failure")
                              (gdev-project-view--ctest-options directory preset
                                                               gdev-project-view--test-configuration)
                              (when jobs (list "--parallel" (number-to-string jobs)))
                              (gdev-project-view--ctest-selection ids))
                    (with-current-buffer editor
                      (gdev-test-catalog-command provider directory ids jobs))))
         (test-command (gdev-command-line (car command) (cdr command)))
         (line (if gdev-project-view--test-build-command
                   (concat gdev-project-view--test-build-command " && " test-command)
                 test-command))
         (name (concat (gdev-test-catalog-title provider) " · " (abbreviate-file-name directory))))
    (when (and selection (not ids)) (user-error "Nessun test corrisponde alla selezione"))
    (when ids
      (let ((known (make-hash-table :test #'equal)))
        (dolist (test gdev-project-view--lines) (puthash (alist-get 'name test) t known))
        (unless (seq-every-p (lambda (id) (gethash id known)) ids)
          (user-error "Un test selezionato non è più nel catalogo"))))
    (when (process-live-p (get-buffer-process (format "*%s*" name)))
      (user-error "I test sono già in esecuzione per questo progetto"))
    (setq gdev-project-view--test-run
          (with-current-buffer editor
            (let ((process-environment (copy-sequence process-environment)))
              (when (and (eq provider 'deno) jobs) (setenv "DENO_JOBS" (number-to-string jobs)))
              (if (eq provider 'ctest)
                  (gdev-build-compile line name root (gdev-build-scope root directory))
                (gdev-compile line name directory)))))
    (setq gdev-project-view--status "Test in esecuzione…")
    (gdev-project-view--render)
    (let* ((output gdev-project-view--test-run)
           (process (get-buffer-process output))
           (filter (gdev-project-view--track-test-progress view output provider directory)))
      (gdev-compilation-on-finish
       output
       (lambda (buffer)
         (when filter
           (with-current-buffer buffer (remove-hook 'compilation-filter-hook filter t)))
         (when (and (frame-live-p frame) (gdev-workspace-state-find owner frame))
           (gdev-project-view--test-finish view root buffer (and process (process-status process)) provider)))))))

(defun gdev-project-view--test-buffer ()
  "Usa il catalogo Test dello spazio attivo dalla vista o dal sorgente."
  (if (eq gdev-activity-kind 'test) (current-buffer) (gdev-project-view-buffer 'test)))

(defun gdev-project-view-test-all ()
  "Esegui il catalogo della vista corrente."
  (interactive)
  (with-current-buffer (gdev-project-view--test-buffer)
    (unless gdev-project-view--lines (user-error "Rileva prima i test nella vista Test"))
    (gdev-project-view--test nil)))

(defun gdev-project-view-test-failed ()
  "Riesegui i test falliti nel catalogo dello spazio corrente."
  (interactive)
  (with-current-buffer (gdev-project-view--test-buffer)
    (unless (and (hash-table-p gdev-project-view--results)
                 (member "Fallito" (hash-table-values gdev-project-view--results)))
      (user-error "Nessun test fallito nel progetto attivo"))
    (gdev-project-view--test 'failed)))

(defun gdev-project-view-test-filtered ()
  "Esegui i test corrispondenti ai filtri della vista corrente."
  (interactive)
  (unless (eq gdev-activity-kind 'test) (user-error "Apri la vista Test"))
  (let ((ids (mapcar (lambda (test) (alist-get 'name test)) (gdev-project-view--filtered-tests))))
    (unless ids (user-error "Nessun test corrisponde ai filtri"))
    (gdev-project-view--test ids)))

(defun gdev-project-view--test-at-position (source position)
  "Esegui i test del catalogo corrente corrispondenti a POSITION in SOURCE."
  (let ((provider gdev-project-view--test-provider)
        (entries gdev-project-view--lines)
        (root gdev-project-view--root))
    (let ((ids (with-current-buffer source
                 (save-excursion
                   (goto-char position)
                   (gdev-test-catalog-at-point provider entries root)))))
      (unless ids (user-error "Nessun test del catalogo corrisponde al cursore"))
      (gdev-project-view--test ids))))

(defun gdev-project-view-test-at-point ()
  "Esegui il test sotto il cursore nell'editor attivo."
  (interactive)
  (let* ((editor (gdev-layout-editor))
         (source (and editor (window-buffer editor)))
         (file (and source (buffer-file-name source))))
    (unless file (user-error "Apri nell'editor un file di test"))
    (when (file-remote-p file) (user-error "La vista Test rileva il catalogo dei progetti locali"))
    (with-current-buffer source (when (buffer-modified-p) (save-buffer)))
    (let ((position (window-point editor))
          (tick (buffer-chars-modified-tick source))
          (frame (selected-frame))
          (owner (gdev-workspace-state-ensure-id)))
      (with-current-buffer (gdev-project-view--test-buffer)
        (gdev-project-view-sync (current-buffer))
        (if gdev-project-view--test-provider
            (gdev-project-view--test-at-position source position)
          (gdev-project-view--test-refresh
           nil (lambda ()
                 (if (and (frame-live-p frame) (eq frame (selected-frame))
                          (eq owner (gdev-workspace-state-id frame)) (buffer-live-p source)
                          (eq source (window-buffer (gdev-layout-editor frame)))
                          (= tick (buffer-chars-modified-tick source)))
                     (gdev-project-view--test-at-position source position)
                   (message "Rilevamento completato. Ripeti il comando dal documento di origine")))))))))

(defun gdev-project-view-select-profile ()
  "Scegli la configurazione di avvio per il progetto."
  (interactive)
  (unless (eq gdev-activity-kind 'run) (user-error "Apri prima Debug dello spazio"))
  (gdev-project-view-sync (current-buffer))
  (gdev-launch-select-profile gdev-project-view--root))

(defun gdev-project-view--profile-changed ()
  "Aggiorna la vista Debug dello spazio corrente dopo la scelta."
  (when-let* ((view (alist-get 'run (gdev-workspace-state-get 'gdev-activity-buffers)))
              ((buffer-live-p view)))
    (unless (gdev-project-view-sync view)
      (with-current-buffer view (gdev-project-view--render)))))

(add-hook 'gdev-launch-selection-change-hook #'gdev-project-view--profile-changed)

(defun gdev-project-view-launch (&optional debug)
  "Avvia il profilo corrente o il relativo adattatore quando DEBUG è richiesto."
  (interactive "P")
  (unless (eq gdev-activity-kind 'run) (user-error "Apri prima Debug dello spazio"))
  (gdev-project-view--run-command
   (if debug
       (if (commandp 'gdev-debug-dwim) #'gdev-debug-dwim
         (user-error "Attiva il modulo debugger"))
     #'gdev-run-dwim)))

(defun gdev-project-view-debug ()
  "Avvia nel debugger il profilo indicato dalla vista Debug dello spazio."
  (interactive)
  (gdev-project-view-launch t))

(defun gdev-project-view-git ()
  "Mostra le modifiche Git nel riquadro delle attività."
  (interactive)
  (let ((buffer (gdev-project-view-buffer 'git)))
    (when (gdev-activity-display buffer 'git) (with-current-buffer buffer (gdev-project-view-refresh)))))

(defun gdev-project-view-run ()
  "Apri Debug nello spazio corrente e mostra sessione, profili e risorse."
  (interactive)
  (when-let* ((window (gdev-activity-display (gdev-project-view-buffer 'run) 'run)))
    (with-current-buffer (window-buffer window)
      (set-window-margins window left-margin-width right-margin-width))
    (gdev-debug-workbench-refresh-visible)))

(defun gdev-project-view-tests ()
  "Mostra i test del progetto."
  (interactive)
  (let ((buffer (gdev-project-view-buffer 'test)))
    (when (gdev-activity-display buffer 'test)
      (with-current-buffer buffer
        (when-let* (((not gdev-project-view--test-provider))
                    ((not (file-remote-p gdev-project-view--root)))
                    ((with-current-buffer (window-buffer (gdev-layout-editor))
                       (and (gdev-project-environment-ready-p) (executable-find "ctest"))))
                    (context (gdev-project-view--ctest-context))
                    ((eq 'ctest (gdev-test-catalog-provider
                                 (buffer-local-value 'major-mode (window-buffer (gdev-layout-editor)))
                                 gdev-project-view--root (plist-get context :directory)))))
          (gdev-project-view--test-refresh context))))))

(provide 'gdev-project-view)
;;; gdev-project-view.el ends here
