;;; gdev-reliability-worker.el --- Processo isolato delle prove di affidabilità -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il controllore Python conserva il modello indipendente e termina soltanto
;; questo figlio nei casi di arresto. Non carica init.el o dati personali.
;;; Code:
(require 'json)
(require 'cl-lib)
(setq load-prefer-newer t)
(add-to-list 'load-path (expand-file-name "lisp" gdev-config-directory))
(when-let* ((overlay (getenv "GDEV_RELIABILITY_OVERLAY"))) (add-to-list 'load-path overlay))
(require 'gdev-assurance)
(require 'gdev-workspace-state)

(defun gdev-reliability-worker--read (file)
  "Leggi i dati JSON di FILE."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil :false-object :false)))

(defun gdev-reliability-worker--write (file data)
  "Scrivi DATA in FILE, chiudendolo prima di proseguire."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (json-serialize data :null-object nil :false-object :false))
    (let ((coding-system-for-write 'no-conversion)) (write-region nil nil file nil 'silent))))

(defun gdev-reliability-worker--open (db)
  "Apri una transazione applicativa ripetibile in DB."
  (gdev-process-open db :title "Prova di affidabilità" :profile 'quality :actor "ci-fixture" :actor-kind 'ci))

(defun gdev-reliability-worker--evidence (db)
  "Registra in DB una prova attraverso il servizio di dominio."
  (gdev-evidence-add db "GT-0001" :kind 'fact :description "Esito ripetibile"
                     :content "risultato" :actor "ci-fixture" :actor-kind 'ci))

(defun gdev-reliability-worker--operation (config)
  "Esegui l'operazione di CONFIG, con guasto o arresto al punto richiesto."
  (let* ((root (alist-get 'root config)) (operation (alist-get 'operation config))
         (fault (or (alist-get 'fault config) 0)) (sticky (eq t (alist-get 'sticky config)))
         (stop (or (alist-get 'stop config) 0)) (calls 0)
         (execute (symbol-function 'sqlite-execute)) db result condition)
    (unwind-protect
        (condition-case err
            (progn
              (unless (equal operation "initialize") (setq db (gdev-assurance-db-open root 'write)))
              (cl-letf (((symbol-function 'sqlite-execute)
                         (lambda (connection query &optional values)
                           (cl-incf calls)
                           (when (and (> fault 0) (if sticky (>= calls fault) (= calls fault)))
                             (signal 'sqlite-error '("disk I/O error (iniettato al confine Lisp/SQLite)")))
                           (prog1 (funcall execute connection query values)
                             (when (= calls stop)
                               (gdev-reliability-worker--write (alist-get 'checkpoint config) `((call . ,calls)))
                               ;; Il controllore termina questo processo con SIGKILL.
                               (while t (sleep-for 0.05)))))))
                (setq result
                      (pcase operation
                        ("initialize" (setq db (gdev-assurance-db-open root 'write)) "initialized")
                        ("open" (gdev-reliability-worker--open db))
                        ("evidence" (gdev-reliability-worker--evidence db))
                        (_ (error "Operazione sconosciuta: %s" operation))))))
          ((error quit) (setq condition (symbol-name (car err)))))
      (when db (gdev-assurance-db-close db)))
    `((ok . ,(if condition :false t)) (condition . ,condition) (calls . ,calls) (result . ,result))))

(defun gdev-reliability-worker--workspace (config)
  "Applica le operazioni di CONFIG a due spazi separati e restituisci gli esiti."
  (let ((tabs (vector (list 'tab '(name . "primo")) (list 'tab '(name . "secondo")))) responses)
    (dolist (operation (alist-get 'operations config))
      (let* ((tab (aref tabs (alist-get 'tab operation)))
             (action (alist-get 'action operation)) rejected)
        (condition-case nil
            (pcase action
              ("set" (gdev-workspace-state-set (intern (alist-get 'key operation)) (alist-get 'value operation) tab))
              ("batch" (gdev-workspace-state-update
                        (mapcar (lambda (entry) (cons (intern (alist-get 'key entry)) (alist-get 'value entry)))
                                (alist-get 'changes operation)) tab))
              ("restore"
               (let ((snapshot (gdev-workspace-state-snapshot tab)))
                 (gdev-workspace-state-set 'gdev-layout-folder "cambiamento da annullare" tab)
                 (gdev-workspace-state-restore snapshot)))
              (_ (error "Azione sconosciuta: %s" action)))
          (error (setq rejected t)))
        (push `((rejected . ,(if rejected t :false))
                (tabs . ,(vconcat
                          (mapcar (lambda (candidate)
                                    (mapcar (lambda (key) (cons (intern key) (gdev-workspace-state-read (intern key) candidate)))
                                            (alist-get 'keys config)))
                                  (append tabs nil))))) responses)))
    `((ok . t) (responses . ,(vconcat (nreverse responses))))))

(defun gdev-reliability-worker--resource (config)
  "Verifica la chiusura dopo errori, quit e throw nell'apertura di CONFIG."
  (let ((close (symbol-function 'gdev-assurance-db-close)) opened closed responses)
    (dolist (kind '(error quit throw))
      (setq opened nil closed nil)
      (let ((open (symbol-function 'sqlite-open)))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'sqlite-open)
                         (lambda (&rest args) (setq opened (apply open args))))
                        ((symbol-function 'gdev-assurance-db-close)
                         (lambda (db) (setq closed (eq db opened)) (funcall close db)))
                        ((symbol-function 'gdev-assurance-db--migrate)
                         (lambda (_db)
                           (pcase kind ('error (error "Guasto nel migratore"))
                             ('quit (signal 'quit nil)) ('throw (throw 'escape t))))))
                (condition-case nil
                    (catch 'escape (gdev-assurance-db-open (alist-get 'root config) 'write))
                  ((error quit) nil)))
              (push (cons kind (if closed t :false)) responses))
          ;; Recupero della sola connessione di prova anche sul codice difettoso.
          (when opened (ignore-errors (funcall close opened))))))
    `((ok . t) (closed . ,(nreverse responses)))))

(defun gdev-reliability-worker--run (config)
  "Esegui CONFIG sulle API pubbliche del checkout."
  (let ((gdev-process-origin 'ci)
        (gdev-assurance-db-clock-function (lambda () (encode-time '(0 0 0 1 1 2026 nil nil t)))))
    (pcase (alist-get 'scenario config)
      ("setup"
       (gdev-assurance-db-with-open (db (alist-get 'root config) 'write)
         (gdev-reliability-worker--open db))
       '((ok . t)))
      ("operation" (gdev-reliability-worker--operation config))
      ("workspace" (gdev-reliability-worker--workspace config))
      ("resource" (gdev-reliability-worker--resource config))
      ("read"
       (gdev-assurance-db-with-open (db (alist-get 'root config))
         (let (rejected)
           (condition-case nil (sqlite-execute db "update tx set state = 'CLASSIFIED'")
             (sqlite-error (setq rejected t)))
           `((ok . t) (rejected . ,(if rejected t :false))))))
      ("verify"
       (gdev-assurance-db-with-open (db (alist-get 'root config))
         `((ok . t) (problems . ,(vconcat (gdev-assurance-verify db))))))
      (_ (error "Scenario sconosciuto")))))

(let* ((config (gdev-reliability-worker--read (getenv "GDEV_RELIABILITY_INPUT")))
       (result (gdev-reliability-worker--run config)))
  (gdev-reliability-worker--write (getenv "GDEV_RELIABILITY_RESULT") result))
;;; gdev-reliability-worker.el ends here
