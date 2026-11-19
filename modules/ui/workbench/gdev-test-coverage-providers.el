;;; gdev-test-coverage-providers.el --- Esecuzione delle misure di copertura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il runner consegna al Workbench un rapporto LCOV completo. Il lavoro
;; resta associato allo spazio di origine anche durante una compilazione.

;;; Code:

(require 'cl-lib)
(require 'gdev-commands)
(require 'gdev-compilation)
(require 'gdev-lib)
(require 'gdev-llvm-coverage)
(require 'gdev-test-catalog)
(require 'gdev-workspace-state)
(require 'seq)

(declare-function gdev-cmake--artifact-paths "../../tools/build/config" (model directory name &optional types))
(declare-function gdev-cmake--codemodel "../../tools/build/config" (directory &optional index-file))
(declare-function gdev-cmake--prepare "../../tools/build/config" (directory))
(declare-function gdev-python--interpreter "../../lang/python/config" (root))
(declare-function gdev-python-root "../../lang/python/config" (&optional directory))
(declare-function gdev-test-coverage-publish "gdev-test-coverage" (report root owner frame))
(declare-function gdev-test-coverage-show "gdev-test-coverage" (&optional root))
(declare-function gdev-workbench-operation-start "gdev-workbench-operations" (label buffer &optional interruptible))
(declare-function gdev-workbench-operation-report "gdev-workbench-operations" (operation state &optional detail))
(defvar gdev-workbench-operation-manual)

(autoload 'gdev-test-coverage-publish "gdev-test-coverage")
(autoload 'gdev-test-coverage-show "gdev-test-coverage" nil t)

(cl-defstruct (gdev-test-coverage--job (:constructor gdev-test-coverage--make-job))
  root owner frame scratch buffer process cleanup operation)

(defvar-local gdev-test-coverage--job nil)
(defvar-local gdev-test-coverage--retry nil)

(defun gdev-test-coverage--python-command (python scratch)
  "Produci il rapporto LCOV con PYTHON, usando solo dati temporanei in SCRATCH."
  ;; L'esito dei test rimane visibile anche se riesce l'esportazione.
  (gdev-command-line
   "sh" "-c"
   (concat "export COVERAGE_FILE=$2; status=0\n"
           "\"$1\" -m coverage run -m pytest --color=no || status=$?\n"
           "[ \"$status\" -le 1 ] || exit \"$status\"\n"
           "set -- \"$1\" \"$3\" \"$COVERAGE_FILE\".*\n"
           "if [ -f \"$3\" ]; then \"$1\" -m coverage combine --append || exit $?; fi\n"
           "report_status=0\n"
           "\"$1\" -m coverage lcov -o \"$2.pending\" || report_status=$?\n"
           "[ \"$report_status\" -eq 0 ] || [ \"$report_status\" -eq 2 ] || exit \"$report_status\"\n"
           "mv \"$2.pending\" \"$2\" || exit $?\n"
           "[ \"$status\" -eq 0 ] || exit \"$status\"\n"
           "exit \"$report_status\"")
   "gdev-copertura" python (expand-file-name ".coverage" scratch)
   (expand-file-name "rapporto.lcov" scratch)))

(defun gdev-test-coverage--cmake-command (root build raw profdata tools)
  "Configura, compila e prova ROOT in BUILD, raccogliendo RAW e PROFDATA con TOOLS."
  (let* ((jobs (number-to-string (num-processors)))
         (configure (list (concat "-DCMAKE_C_COMPILER=" (plist-get tools :cc))
                          (concat "-DCMAKE_CXX_COMPILER=" (plist-get tools :cxx))))
         (commands (gdev-llvm-coverage-build-commands root build jobs configure "Debug"))
         (test (gdev-command-line "ctest" "--test-dir" build "-C" "Debug"
                                  "--parallel" jobs "--output-on-failure"))
         (merge (gdev-command-line (plist-get tools :profdata) "merge" "-sparse" "-o" profdata)))
    (gdev-command-line
     "sh" "-c"
     (concat (string-join commands " && ") " || exit $?\n"
             "status=0\nLLVM_PROFILE_FILE=" (shell-quote-argument (expand-file-name "%p-%m.profraw" raw))
             " " test " || status=$?\n"
             merge " " (shell-quote-argument (file-name-as-directory raw)) "*.profraw || exit $?\n"
             "exit \"$status\""))))

(defun gdev-test-coverage--frame (job)
  "Ritrova il frame dello spazio di JOB anche dopo un trasferimento di scheda."
  (let ((owner (gdev-test-coverage--job-owner job))
        (frame (gdev-test-coverage--job-frame job)))
    (if (and (frame-live-p frame) (gdev-workspace-state-find owner frame))
        frame
      (seq-find (lambda (candidate) (gdev-workspace-state-find owner candidate)) (frame-list)))))

(defun gdev-test-coverage--cleanup (job)
  "Ferma la fase di JOB e rimuovi i soli artefatti del suo avvio."
  (when-let* ((scratch (gdev-test-coverage--job-scratch job)))
    (gdev-test-coverage--operation-report job 'cancelled)
    (setf (gdev-test-coverage--job-scratch job) nil)
    (let ((process (gdev-test-coverage--job-process job))
          (buffer (gdev-test-coverage--job-buffer job))
          (cleanup (gdev-test-coverage--job-cleanup job)))
      (when cleanup (remove-hook 'kill-emacs-hook cleanup))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when cleanup (remove-hook 'kill-buffer-hook cleanup t))
          (when (eq gdev-test-coverage--job job) (setq gdev-test-coverage--job nil))))
      (when (process-live-p process) (delete-process process)))
    (when (file-directory-p scratch) (delete-directory scratch t))))

(defun gdev-test-coverage--operation-report (job state &optional detail)
  "Aggiorna lo stato dell'operazione di JOB quando il Workbench la segue."
  (when-let* ((operation (gdev-test-coverage--job-operation job)))
    (gdev-workbench-operation-report operation state detail)))

(defun gdev-test-coverage--finish (job report)
  "Consegna REPORT allo spazio ancora aperto e chiudi JOB."
  (when (gdev-test-coverage--job-scratch job)
    (unwind-protect
        (when-let* ((frame (gdev-test-coverage--frame job)))
          (condition-case err
              (if (and report (file-regular-p report)
                       (gdev-test-coverage-publish report (gdev-test-coverage--job-root job)
                                                  (gdev-test-coverage--job-owner job) frame))
                  (progn
                    (gdev-test-coverage--operation-report job 'completed "Rapporto pronto nella vista Copertura")
                    (message "Rapporto pronto nella vista Copertura"))
                (gdev-test-coverage--operation-report job 'failed "Rapporto non disponibile")
                (message "Copertura non disponibile. Consulta la compilazione"))
            (error
             (gdev-test-coverage--operation-report job 'failed (error-message-string err))
             (message "Copertura non disponibile. %s" (error-message-string err)))))
      (gdev-test-coverage--cleanup job))))

(defun gdev-test-coverage--export-llvm (job cov build profdata report)
  "Esporta con COV il rapporto di BUILD e PROFDATA al file REPORT per JOB."
  (if-let* (((gdev-test-coverage--job-scratch job))
            ((gdev-test-coverage--frame job))
            ((file-regular-p profdata)))
      (condition-case err
          (let* ((model (gdev-cmake--codemodel build))
                 (files (and model (seq-filter #'file-regular-p
                                              (cdr (gdev-cmake--artifact-paths
                                                    model build "Debug"
                                                    '("EXECUTABLE" "SHARED_LIBRARY" "MODULE_LIBRARY"))))))
                 (buffer (gdev-test-coverage--job-buffer job))
                 (default-directory (gdev-test-coverage--job-root job))
                 (exec-path (buffer-local-value 'exec-path buffer))
                 (process-environment (buffer-local-value 'process-environment buffer)))
            (unless files (user-error "Nessun eseguibile o libreria nel catalogo CMake"))
            (gdev-test-coverage--operation-report job 'running "Esportazione LCOV")
            (setf (gdev-test-coverage--job-process job)
                  (make-process
                   :name "gdev-llvm-cov" :connection-type 'pipe :noquery t :buffer buffer
                   :command (list "sh" "-c"
                                  (concat "exec "
                                          (gdev-command-line
                                           cov "export" "-format=lcov" (concat "-instr-profile=" profdata)
                                           (car files) (mapcar (lambda (file) (concat "-object=" file))
                                                               (cdr files)))
                                          " > " (shell-quote-argument report)))
                   :sentinel (lambda (child _event)
                               (pcase (process-status child)
                                 ('signal (gdev-test-coverage--cleanup job))
                                 ('exit (gdev-test-coverage--finish
                                         job (and (zerop (process-exit-status child)) report))))))))
        (error
         (gdev-test-coverage--operation-report job 'failed (error-message-string err))
         (message "Esportazione della copertura non riuscita. %s" (error-message-string err))
         (gdev-test-coverage--cleanup job)))
    (gdev-test-coverage--finish job nil)))

(defun gdev-test-coverage--start (root provider)
  "Avvia la misura di PROVIDER in ROOT e conserva l'origine del rapporto."
  (gdev-require-project-environment)
  (when (file-remote-p root) (user-error "Avvia la copertura da un progetto locale o importa un rapporto LCOV"))
  (let* ((root (file-name-as-directory (file-truename root)))
         (name (format "Copertura · %s" (abbreviate-file-name (directory-file-name root))))
         (previous (get-buffer (format "*%s*" name)))
         (python (when (eq provider 'pytest)
                   (unless (fboundp 'gdev-python--interpreter) (user-error "Attiva il modulo Python"))
                   (gdev-python--interpreter root)))
         (tools (when (eq provider 'ctest)
                  (unless (and (fboundp 'gdev-cmake--prepare)
                               (gdev-project-file-exists-p root "CMakeLists.txt"))
                    (user-error "Apri un progetto CMake e attiva il modulo Compilazione"))
                  (list :cc (gdev-llvm-coverage-tool "clang")
                        :cxx (gdev-llvm-coverage-tool "clang++")
                        :cov (gdev-llvm-coverage-tool "llvm-cov")
                        :profdata (gdev-llvm-coverage-tool "llvm-profdata"))))
         (parent (gdev-state-file "coverage/"))
         (frame (selected-frame))
         (owner (gdev-workspace-state-ensure-id frame)))
    (gdev-compilation-check-idle name)
    (when (and previous (buffer-local-value 'gdev-test-coverage--job previous))
      (user-error "La copertura è già in fase di esportazione"))
    (make-directory parent t)
    (let* ((scratch (make-temp-file (expand-file-name "misura-" parent) t))
           (job (gdev-test-coverage--make-job :root root :owner owner :frame frame :scratch scratch))
           (cleanup (lambda () (gdev-test-coverage--cleanup job)))
           (report (expand-file-name "rapporto.lcov" scratch))
           (build (expand-file-name "build/" scratch))
           (raw (expand-file-name "profili/" scratch))
           (profdata (expand-file-name "insieme.profdata" scratch))
           started)
      (setf (gdev-test-coverage--job-cleanup job) cleanup)
      (add-hook 'kill-emacs-hook cleanup)
      (unwind-protect
          (let* ((command (if python (gdev-test-coverage--python-command python scratch)
                            (gdev-cmake--prepare build)
                            (make-directory raw t)
                            (gdev-test-coverage--cmake-command root build raw profdata tools)))
                 (buffer (let ((gdev-workbench-operation-manual t))
                           (if python (gdev-compile command name root)
                             (gdev-build-compile command name root (gdev-build-scope root build)))))
                 (process (get-buffer-process buffer)))
            (setf (gdev-test-coverage--job-buffer job) buffer
                  (gdev-test-coverage--job-process job) process
                  (gdev-test-coverage--job-operation job)
                  (when (fboundp 'gdev-workbench-operation-start)
                    (gdev-workbench-operation-start name buffer t)))
            (with-current-buffer buffer
              (setq-local gdev-test-coverage--job job
                          gdev-test-coverage--retry (list root provider))
              (add-hook 'kill-buffer-hook cleanup nil t)
              (use-local-map (make-composed-keymap
                              (define-keymap "<remap> <recompile>" #'gdev-test-coverage-repeat)
                              (current-local-map))))
            (gdev-compilation-on-finish
             buffer
             (lambda (_)
               (cond ((and process (eq (process-status process) 'signal))
                      (gdev-test-coverage--cleanup job))
                     (python (gdev-test-coverage--finish job report))
                     (t (gdev-test-coverage--export-llvm job (plist-get tools :cov) build profdata report)))))
            (setq started t)
            buffer)
        (unless started (gdev-test-coverage--cleanup job))))))

(defun gdev-test-coverage-repeat ()
  "Ripeti la misura del pannello con una nuova cartella temporanea."
  (interactive)
  (unless gdev-test-coverage--retry (user-error "Apri prima una compilazione di copertura"))
  (apply #'gdev-test-coverage--start gdev-test-coverage--retry))

(declare-function gdev-build--root "../../tools/build/config" ())

(defun gdev-test-coverage-run (&optional root provider)
  "Misura la copertura con PROVIDER in ROOT, altrimenti usa il documento attivo."
  (interactive)
  (gdev-call-with-editor
   (lambda ()
     (when (file-remote-p (or root default-directory))
       (user-error "Avvia la copertura da un progetto locale o importa un rapporto LCOV"))
     (let* ((language (gdev-test-catalog-language major-mode))
            (root (or root (and (eq language 'python) (fboundp 'gdev-python-root) (gdev-python-root))
                      ;; La stessa radice di compilazione e test, anche in una sottocartella.
                      (gdev-project-build-root)))
            (provider (or provider (gdev-test-catalog-provider
                                    major-mode root (gdev-project-file-exists-p root "CMakeLists.txt")))))
       (unless (memq provider '(pytest ctest))
         (user-error "Misura la copertura con pytest o CMake, oppure importa un rapporto LCOV"))
       (gdev-test-coverage--start root provider)))))

(defun gdev-test-coverage-import (report &optional root)
  "Mostra REPORT in formato LCOV, risolvendo i percorsi relativi a ROOT."
  (interactive
   (gdev-call-with-editor
    (lambda ()
      (list (read-file-name "Rapporto LCOV: " (gdev-project-root) nil t)))))
  (gdev-call-with-editor
   (lambda ()
     (unless (file-regular-p report) (user-error "Apri un file di rapporto LCOV"))
     (let* ((frame (selected-frame))
            (root (file-name-as-directory (expand-file-name (or root (gdev-project-root))))))
       (when (gdev-test-coverage-publish report root (gdev-workspace-state-ensure-id frame) frame)
         (gdev-test-coverage-show root))))))

(provide 'gdev-test-coverage-providers)
;;; gdev-test-coverage-providers.el ends here
