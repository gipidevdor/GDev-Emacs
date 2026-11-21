;;; gdev-compilation.el --- Piani e processi di compilazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coordina le compilazioni e riserva le cartelle prodotte. I chiamanti
;; risolvono comandi e profili. Il coordinatore conserva i piani eseguibili
;; nello spazio di origine e consegna i completamenti.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'seq)
(require 'gdev-lib)
(require 'gdev-workspace-state)

(autoload 'gdev-project-operation-result "gdev-project-operations")
(declare-function gdev-workbench-operation-current "../modules/ui/workbench/gdev-workbench-operations" (operation))
(declare-function gdev-workbench-operation-state "../modules/ui/workbench/gdev-workbench-operations" (operation))

(defun gdev-build--output-name (root)
  "Identifica il pannello di compilazione di ROOT."
  (format "Compilazione · %s" (abbreviate-file-name (directory-file-name root))))

(cl-defstruct gdev-build-plan command directory scope compilation-environment environment path)
(cl-defstruct gdev-build-scope root key resource)

(defvar gdev-build--standalone-plans nil)
(defvar gdev-build--active nil
  "Compilazioni attive, ciascuna con ambito e processo.")
(defvar-local gdev-build--buffer-scope nil)

(defun gdev-build--canonical-directory (directory)
  "Normalizza DIRECTORY identificando anche gli alias simbolici locali."
  (file-name-as-directory
   (if (file-remote-p directory) (expand-file-name directory) (file-truename directory))))

(defun gdev-build-scope (root directory)
  "Identifica la risorsa di ROOT scritta dalla compilazione in DIRECTORY.
Una DIRECTORY nil indica un comando dal raggio d'azione sconosciuto."
  (make-gdev-build-scope :root root :key (gdev-build--canonical-directory root)
                         :resource (and directory (gdev-build--canonical-directory directory))))

(defun gdev-build-check-scope (scope)
  "Verifica che nessun processo stia scrivendo la risorsa di SCOPE."
  (let ((key (gdev-build-scope-key scope))
        (directory (gdev-build-scope-resource scope)))
    (when (seq-some
           (pcase-lambda (`(,other . ,process))
             (and (or (null process) (process-live-p process))
                  (if-let* ((other-directory (and directory (gdev-build-scope-resource other))))
                      (equal directory other-directory)
                    (equal key (gdev-build-scope-key other)))))
           gdev-build--active)
      (user-error "Compilazione già in corso per %s" (abbreviate-file-name (or directory key))))))

(defun gdev-build--start-tracked (scope starter &rest arguments)
  "Prenota SCOPE durante STARTER e per la durata del processo restituito."
  (gdev-build-check-scope scope)
  (let ((job (cons scope nil)))
    (push job gdev-build--active)
    (unwind-protect
        (let* ((buffer (apply starter arguments))
               (process (and (buffer-live-p buffer) (get-buffer-process buffer))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (setq-local gdev-build--buffer-scope scope)))
          (when (process-live-p process)
            (let ((sentinel (process-sentinel process)))
              (set-process-sentinel
               process (lambda (child event)
                         (unwind-protect
                             (when sentinel (funcall sentinel child event))
                           (unless (process-live-p child)
                             (setq gdev-build--active (delq job gdev-build--active)))))))
            (setcdr job process))
          buffer)
      (unless (cdr job) (setq gdev-build--active (delq job gdev-build--active))))))

(defun gdev-build--recompile-output (original &rest arguments)
  "Ripeti con ORIGINAL l'output corrente, mantenendo la stessa risorsa."
  (if gdev-build--buffer-scope
      (let* ((scope gdev-build--buffer-scope)
             ;; Un comando modificato può scrivere altrove nello stesso progetto.
             (scope (if (car arguments)
                        (gdev-build-scope (gdev-build-scope-root scope) nil)
                      scope)))
        (apply #'gdev-build--start-tracked scope original arguments))
    (apply original arguments)))

(advice-add 'recompile :around #'gdev-build--recompile-output)

(defun gdev-build-compile (command name directory scope)
  "Avvia COMMAND nel pannello NAME riservando SCOPE."
  (gdev-compilation-check-idle name)
  (gdev-build--start-tracked scope #'gdev-compile command name directory))

(defun gdev-compilation-on-finish (buffer callback)
  "Chiama CALLBACK una volta con BUFFER quando termina la compilazione.
Se la sentinella ha già consegnato il risultato, chiama subito CALLBACK."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (get-buffer-process buffer)
          (letrec ((finish (lambda (output _status)
                             (remove-hook 'compilation-finish-functions finish t)
                             (funcall callback output))))
            (add-hook 'compilation-finish-functions finish nil t))
        (funcall callback buffer)))))

(defun gdev-compilation-succeeded-p (process)
  "Ammetti un seguito soltanto dopo il successo di PROCESS e del suo registro.
Una richiesta di interruzione o la chiusura dello spazio prevalgono anche
su un'uscita zero tardiva. Il registro resta posseduto dal Workbench."
  (let* ((operation (process-get process 'gdev-workbench-operation))
         (current (and operation (fboundp 'gdev-workbench-operation-current)
                       (gdev-workbench-operation-current operation))))
    (eq 'completed
        (gdev-project-operation-result
         (process-status process) (process-exit-status process)
         (and operation (or (null current)
                            (not (memq (gdev-workbench-operation-state current) '(running completed)))))))))

(defun gdev-compilation-configure (root starter &rest arguments)
  "Avvia STARTER con ARGUMENTS e aggiorna l'ambiente di ROOT dopo un successo.
Conserva il processo effettivo anche se termina prima del ritorno di STARTER.
L'aggiornamento riguarda soltanto i documenti ancora appartenenti a ROOT;
non concede autorizzazioni e non dipende dallo spazio visibile alla fine."
  (let* ((source (current-buffer)) starts
         (buffer (let ((compilation-start-hook
                        (cons (lambda (process) (push (cons (process-buffer process) process) starts))
                              compilation-start-hook)))
                   (apply starter arguments)))
         (process (cdr (assq buffer (nreverse starts)))))
    (when process
      (gdev-compilation-on-finish
       buffer
       (lambda (_output)
         (when (and (gdev-compilation-succeeded-p process)
                    (gdev-project-trusted-p root))
           (condition-case failure
               (gdev-refresh-project-environment root)
             (error
              (when (and (buffer-live-p source)
                         (with-current-buffer source
                           (file-equal-p root (gdev-project-operation-context-root))))
                (with-current-buffer source
                  (setq-local gdev-project-environment-status 'failed
                              gdev-project-environment-detail (error-message-string failure))))
              (message "Configurazione terminata; aggiornamento dell'ambiente non riuscito: %s"
                       (error-message-string failure))))))))
    buffer))

(defun gdev-build--plans ()
  "Leggi gli ultimi piani di compilazione del contesto corrente."
  (if (bound-and-true-p gdev-layout-mode)
      (gdev-workspace-state-get 'gdev-build-last-plans)
    gdev-build--standalone-plans))

(defun gdev-build-last-plan (root profile)
  "Leggi l'ultimo piano per ROOT e PROFILE nello spazio corrente."
  (alist-get (cons (gdev-build--canonical-directory root) profile)
             (gdev-build--plans) nil nil #'equal))

(defun gdev-build--remember-plan (plan profile tab)
  "Conserva PLAN come ultima compilazione del PROFILE in TAB."
  (let* ((key (cons (gdev-build-scope-key (gdev-build-plan-scope plan)) profile))
         (prior (if tab (gdev-workspace-state-read 'gdev-build-last-plans tab)
                  gdev-build--standalone-plans))
         (plans (cons (cons key plan)
                      (seq-remove (lambda (entry) (equal (car entry) key)) prior))))
    (if tab
        (gdev-workspace-state-set 'gdev-build-last-plans plans tab)
      (setq gdev-build--standalone-plans plans))))

(defun gdev-build-execute-plan (plan)
  "Avvia PLAN recuperando la riga di comando e l'ambiente originali."
  (let* ((scope (gdev-build-plan-scope plan))
         (base (gdev-build--output-name (gdev-build-scope-root scope)))
         (resource (gdev-build-scope-resource scope))
         (name (if (and resource (not (equal resource (gdev-build-scope-key scope))))
                   (format "%s · %s" base (directory-file-name
                                           (file-relative-name resource (gdev-build-scope-key scope))))
                 base))
         (compilation-environment (gdev-build-plan-compilation-environment plan))
         (process-environment (gdev-build-plan-environment plan))
         (exec-path (gdev-build-plan-path plan)))
    (gdev-build-compile (gdev-build-plan-command plan) name (gdev-build-plan-directory plan)
                        scope)))

(defun gdev-build-start (command directory scope &optional build profile)
  "Avvia COMMAND in DIRECTORY, riservando SCOPE.
Con BUILD conserva il piano per ripetere la compilazione del PROFILE."
  (let* ((frame (and build (bound-and-true-p gdev-layout-mode) (selected-frame)))
         (owner (and frame (gdev-workspace-state-ensure-id frame)))
         (plan (make-gdev-build-plan :command command :directory directory :scope scope
                                     :compilation-environment (copy-sequence compilation-environment)
                                     :environment (copy-sequence process-environment)
                                     :path (copy-sequence exec-path)))
         (buffer (gdev-build-execute-plan plan)))
    (when (and build (buffer-live-p buffer))
      (if (not owner)
          (gdev-build--remember-plan plan profile nil)
        (when-let* (((frame-live-p frame))
                    (tab (gdev-workspace-state-find owner frame)))
          (gdev-build--remember-plan plan profile tab))))
    buffer))

(defun gdev-compilation-check-idle (name)
  "Verifica che il pannello NAME sia disponibile."
  (when (process-live-p (get-buffer-process (format "*%s*" name)))
    (user-error "Operazione già in corso. Interrompila dal pannello di compilazione")))

(provide 'gdev-compilation)
;;; gdev-compilation.el ends here
