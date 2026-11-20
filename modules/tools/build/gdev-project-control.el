;;; gdev-project-control.el --- Contesto e recupero delle operazioni -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Osservazioni locali e azioni comuni; nessun processo nel ridisegno.
;; L'esito e la concorrenza restano di proprietà del gestore delle operazioni.
;;; Code:
(require 'button)
(require 'gdev-project-operations)
(require 'gdev-compilation)
(require 'gdev-launch)
(require 'gdev-ui)

(declare-function gdev-build--root "config" ())
(declare-function gdev-build-system "config" (&optional root))
(declare-function gdev-build--get "config" (key &optional root))
(declare-function gdev-build "config" (&optional choose-target from-user))
(declare-function gdev-run-project-task "config" (&optional repeat))
(declare-function gdev-build-configured-tasks "config" (root))
(declare-function gdev-python-install-tools "../../lang/python/config" ())
(declare-function gdev-call-for-document "gdev-commands" (function &optional from-user))
(defvar project-current-directory-override)
(defvar-local gdev-project-control--origin nil)
(defvar-local gdev-project-control--root nil)

(define-derived-mode gdev-project-control-mode special-mode "Controllo progetto"
  "Mostra contesto, prerequisiti e azioni del progetto."
  (gdev-ui-view-setup 'document)
  (setq-local truncate-lines nil))

(defun gdev-project-control-observe (root)
  "Osserva ROOT senza avviare programmi o costruire comandi interattivi."
  (let* ((profile (gdev-launch-selected root))
         (options (and profile (gdev-launch--options profile root)))
         (system (or (and profile 'declared) (gdev-project-build-system root t)
                     (car (seq-find (lambda (entry) (funcall (cadr entry) root))
                                    gdev-project-language-markers))))
         (contract (assq system gdev-project-operation-contracts))
         (tool (if profile (car (or (plist-get options :build) (plist-get options :test)
                                    (plist-get options :configure) (plist-get options :run)))
                 (if (and (eq system 'make) (boundp 'gdev-make-program))
                     (symbol-value 'gdev-make-program) (nth 2 contract))))
         (directory (if profile (expand-file-name (or (plist-get options :cwd) ".") root) root))
         (executable (and tool (gdev-executable-in tool directory)))
         (state (gdev-project-operation-decision
                 contract gdev-project-environment-status (or (null tool) executable) t nil t)))
    (list :root root :system system :name (or (nth 1 contract) "Da definire")
          :profile (car profile) :tool tool :executable executable :state state
          :phases (if profile
                      (cl-loop for (phase . key) in gdev-project-operation-phases
                               when (plist-get options key) collect phase)
                    (nth 3 contract))
          :environment gdev-project-environment-status :detail gdev-project-environment-detail)))

(defun gdev-project-control--call (command root origin)
  "Invoca COMMAND per ROOT, conservando il documento ORIGIN quando è pertinente."
  (let ((buffer (and (buffer-live-p origin)
                     (with-current-buffer origin
                       (and (equal root (gdev-build--root)) origin)))))
    (if buffer
        (with-current-buffer buffer
          (let ((default-directory root) (project-current-directory-override root))
            (funcall command)))
      (with-temp-buffer
        (let ((default-directory root) (project-current-directory-override root))
          (funcall command))))))

(defun gdev-project-control--button (label command root origin)
  "Inserisci LABEL che invoca COMMAND per ROOT e ORIGIN."
  (insert-text-button label 'type 'gdev-ui-action
                      'action (lambda (_) (gdev-project-control--call command root origin))))

(defun gdev-project-control-render (observation root origin &optional selected-action)
  "Mostra OBSERVATION e le azioni del progetto ROOT con documento ORIGIN."
  (let ((inhibit-read-only t)
        (selected-action (or selected-action (when-let* ((button (button-at (point)))) (button-label button)))))
    (erase-buffer)
    (insert (propertize "Controllo del progetto" 'face 'gdev-ui-view-title) "\n\n")
    (insert "Cartella: " (abbreviate-file-name root) "\n"
            "Sistema: " (plist-get observation :name) "\n"
            "Profilo: " (or (plist-get observation :profile) "Automatico, dai file del progetto") "\n\n")
    (insert (propertize
             (pcase (plist-get observation :state)
               ('ready "Motore disponibile") ('missing-tool "Strumento del motore non trovato")
               ('preparing "Ambiente in preparazione") ('blocked "Ambiente non disponibile")
               (_ "Operazioni da dichiarare"))
             'face (if (eq (plist-get observation :state) 'ready) 'gdev-ui-status-success 'gdev-ui-status-warning)) "\n")
    (when-let* ((tool (plist-get observation :tool)))
      (insert "Strumento: " (or (plist-get observation :executable) tool) "\n"))
    (when-let* ((detail (plist-get observation :detail))) (insert detail "\n"))
    (insert (propertize "I compilatori e le dipendenze interne sono verificati dal motore durante l'operazione.\n"
                        'face 'gdev-ui-secondary) "\n")
    (dolist (entry '((build "Compila" gdev-build) (configure "Configura compilazione…" gdev-build-configure)
                     (test "Esegui tutti i test" gdev-build-test)))
      (when (memq (car entry) (plist-get observation :phases))
        (gdev-project-control--button (cadr entry) (nth 2 entry) root origin) (insert "\n")))
    (when (or (eq (plist-get observation :system) 'make) (gdev-build-configured-tasks root))
      (gdev-project-control--button "Scegli attività…" #'gdev-run-project-task root origin) (insert "\n"))
    (when (gdev-launch-profiles-for root)
      (gdev-project-control--button "Scegli profilo…" #'gdev-launch-select-profile root origin) (insert "\n"))
    (if (gdev-project-trusted-p root)
        (gdev-project-control--button "Aggiorna ambiente" #'gdev-refresh-project-environment root origin)
      (gdev-project-control--button "Autorizza ambiente…" (lambda () (gdev-trust-project root)) root origin))
    (insert "\n")
    (when (eq (plist-get observation :system) 'make)
      (insert "\nObiettivo: " (or (gdev-build--get :make-target root) "Predefinito del Makefile")
              "\nVariabili personali: "
              (mapconcat #'identity (gdev-build--get :make-variables root) ", ") "\n")
      (gdev-project-control--button
       "Scegli obiettivo e compila…" (lambda () (gdev-build t)) root origin) (insert "\n"))
    (when (eq (plist-get observation :system) 'python)
      (gdev-project-control--button
       "Prepara gli strumenti Python…"
       (lambda ()
         (gdev-auto-modules-call-for-project root #'gdev-python-install-tools)) root origin)
      (insert "\n"))
    (insert "\n")
    (gdev-project-control--button
     "Apri le operazioni condivise…"
     (lambda () (find-file (expand-file-name gdev-project-operations-file root))) root origin)
    (insert "\n")
    (gdev-project-control--button "Rileggi il progetto" (lambda () (gdev-project-control-show root)) root origin)
    (insert "\n")
    (goto-char (point-min))
    (when selected-action
      (let ((button (next-button (point-min))))
        (while (and button (not (equal selected-action (button-label button))))
          (setq button (next-button (button-end button))))
        (when button (goto-char (button-start button)))))))

(defun gdev-project-control-show (&optional root from-user)
  "Controlla il progetto ROOT e mostra le azioni per proseguire."
  (interactive (list nil t))
  (gdev-call-for-document
   (lambda ()
     (let* ((root (or root (gdev-build--root))) (origin (current-buffer))
            (configuration-error (condition-case failure (progn (gdev-launch-refresh-native-profile root) nil)
                                   (error (error-message-string failure))))
            (observation (gdev-project-control-observe root))
            (buffer (get-buffer-create (format "*Progetto · %s*" (abbreviate-file-name root)))))
       (with-current-buffer buffer
         (let ((selected-action (when-let* ((button (button-at (point)))) (button-label button))))
           (gdev-project-control-mode)
           (setq-local default-directory root gdev-project-control--origin origin gdev-project-control--root root)
           (gdev-project-control-render observation root origin selected-action))
         (when configuration-error
           (let ((inhibit-read-only t))
             (goto-char (point-min)) (forward-line 2)
             (insert (propertize configuration-error 'face 'gdev-ui-status-error) "\n\n")
             (goto-char (point-min)))))
       (pop-to-buffer buffer)))
   from-user))

(defun gdev-project-control-compilation-finished (buffer status)
  "Aggiungi a BUFFER un percorso di recupero dopo un esito negativo STATUS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and gdev-build--buffer-scope
                 (if-let* ((process (get-buffer-process buffer)))
                     (not (eq 'completed (gdev-project-operation-result
                                          (process-status process) (process-exit-status process) nil)))
                   (not (string-prefix-p "finished" status))))
        (let* ((root (gdev-build-scope-root gdev-build--buffer-scope))
               (inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert "\nPer controllare strumenti, configurazione e ambiente: ")
            (insert-text-button "Controlla progetto" 'type 'gdev-ui-action
                                'action (lambda (_) (gdev-project-control-show root)))
            (insert "\n")))))))

(provide 'gdev-project-control)
;;; gdev-project-control.el ends here
