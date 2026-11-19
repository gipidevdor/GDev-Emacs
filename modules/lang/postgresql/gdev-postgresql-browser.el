;;; gdev-postgresql-browser.el --- Adattatore PostgreSQL per Database SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Legge il catalogo mediante libpq e un processo psql distinto dalla
;; console. Gli identificatori viaggiano come variabili di psql e i dati
;; come JSON, anche per nomi con spazi, virgolette e ritorni a capo.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'gdev-lib)
(require 'gdev-database-browser
         (gdev-config-file "modules/lang/postgresql/gdev-database-browser"))

(declare-function gdev-postgresql--choose "config" ())
(declare-function gdev-postgresql--client "config" ())
(declare-function gdev-postgresql--label "config" (connection))
(defvar gdev-postgresql--connection)

(defconst gdev-postgresql-browser--queries
  '("SELECT coalesce(json_agg(nspname ORDER BY nspname), '[]')
       FROM pg_catalog.pg_namespace
      WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
        AND pg_catalog.has_schema_privilege(oid, 'USAGE');"
    "SELECT coalesce(json_agg(json_build_array(c.relname, c.relkind) ORDER BY c.relname), '[]')
       FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = :'schema' AND c.relkind IN ('r','p','v','m','f');"
    "SELECT coalesce(json_agg(json_build_array(a.attname,
               pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull)
               ORDER BY a.attnum), '[]')
       FROM pg_catalog.pg_attribute a
       JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = :'schema' AND c.relname = :'relation'
        AND a.attnum > 0 AND NOT a.attisdropped;"
    "SELECT coalesce(json_agg((SELECT coalesce(json_agg(json_build_array(key,
                CASE WHEN length(value) > 160 THEN left(value, 160) || '…' ELSE value END)), '[]')
               FROM json_each_text(row_to_json(sample)))), '[]')
       FROM (SELECT * FROM :\"schema\".:\"relation\" LIMIT 50) sample;")
  "Interrogazioni per schemi, relazioni, colonne e anteprima.")

(defconst gdev-postgresql-browser--max-output (* 8 1024 1024)
  "Dimensione massima in byte di una risposta del catalogo.")

(defconst gdev-postgresql-browser--max-diagnostic 4096
  "Numero massimo di caratteri del rapporto mostrati nell'interfaccia.")

(defun gdev-postgresql-browser--request (connection path finish)
  "Leggi PATH in sola lettura e consegna a FINISH le righe o l'errore.
CONNECTION è la coppia (radice . servizio) usata da libpq.
Restituisci una funzione che sopprime la consegna e libera il processo."
  (let ((environment (copy-sequence process-environment))
        (executables exec-path)
        launch timeout process errors output
        (bytes 0))
    (cl-labels
        ((release ()
           (when launch (cancel-timer launch))
           (when timeout (cancel-timer timeout))
           (when (process-live-p process) (delete-process process))
           (when (buffer-live-p errors)
             (when-let* ((stderr (get-buffer-process errors)))
               (set-process-query-on-exit-flag stderr nil))
             (kill-buffer errors))
           (setq launch nil timeout nil process nil errors nil output nil))
         (deliver (rows failure)
           (when finish
             (let ((callback finish))
               (setq finish nil)
               (release)
               (funcall callback rows failure))))
         (collect (child chunk)
           (when (and finish (eq process child))
             (cl-incf bytes (string-bytes chunk))
             (if (<= bytes gdev-postgresql-browser--max-output)
                 (push chunk output)
               (deliver nil "Il risultato PostgreSQL supera il limite di lettura"))))
         (complete (child _event)
           (when (and finish (eq process child)
                      (memq (process-status child) '(exit signal failed)))
             (if (and (eq (process-status child) 'exit) (zerop (process-exit-status child)))
                 (let ((result
                        (condition-case failure
                            (cons (json-parse-string (apply #'concat (nreverse output))
                                                     :array-type 'list :null-object nil) nil)
                          (error (cons nil (error-message-string failure))))))
                   (deliver (car result) (cdr result)))
               (let ((diagnostic (with-current-buffer errors
                                   (string-trim
                                    (buffer-substring-no-properties
                                     (point-min)
                                     (min (point-max)
                                          (+ (point-min) gdev-postgresql-browser--max-diagnostic)))))))
                 (deliver nil (if (string-empty-p diagnostic)
                                  "Connessione o interrogazione PostgreSQL non riuscita"
                                diagnostic))))))
         (start ()
           (setq launch nil)
           (when finish
             (condition-case failure
                 (let* ((default-directory (car connection))
                        (process-environment environment)
                        (exec-path executables)
                        (program (gdev-postgresql--client))
                        (sql (nth (length path) gdev-postgresql-browser--queries)))
                   (unless sql (user-error "Livello del catalogo PostgreSQL non valido"))
                   (setenv "PGSERVICE" (cdr connection))
                   (setenv "PGCLIENTENCODING" "UTF8")
                   (unless (getenv "PGCONNECT_TIMEOUT") (setenv "PGCONNECT_TIMEOUT" "5"))
                   (setq errors (generate-new-buffer " *gdev-postgresql-errori*")
                         process
                         (make-process
                          :name "gdev-postgresql" :buffer nil :stderr errors :noquery t
                          :file-handler t :connection-type 'pipe :coding 'utf-8-unix
                          :command (append
                                    (list (file-local-name program) "-XwqAt" "--file=-"
                                          "--set=ON_ERROR_STOP=1")
                                    (when (car path) (list (concat "--set=schema=" (car path))))
                                    (when (cadr path) (list (concat "--set=relation=" (cadr path)))))
                          :filter #'collect :sentinel #'complete)
                         timeout (run-at-time 20 nil #'deliver nil
                                              "Tempo di lettura PostgreSQL esaurito"))
                   (process-send-string
                    process
                    (concat "BEGIN READ ONLY; SET LOCAL statement_timeout = '5s'; "
                            "SET LOCAL search_path = pg_catalog;\n" sql "\nCOMMIT;\n"))
                   (when (process-live-p process) (process-send-eof process)))
               (quit (deliver nil "Lettura PostgreSQL annullata"))
               (error (deliver nil (error-message-string failure)))))))
      (setq launch (run-at-time 0 nil #'start))
      (lambda ()
        (setq finish nil)
        (release)))))

(define-derived-mode gdev-postgresql-browser-mode gdev-database-browser-mode "Database SQL"
  "Esplora un database PostgreSQL usando la vista comune."
  (gdev-ui-view-setup 'table))

(defalias 'gdev-postgresql-browser-open #'gdev-database-browser-open)
(defalias 'gdev-postgresql-browser-click #'gdev-database-browser-click)
(defalias 'gdev-postgresql-browser-up #'gdev-database-browser-up)
(defalias 'gdev-postgresql-browser-refresh #'gdev-database-browser-refresh)
(defalias 'gdev-postgresql-browser-preview #'gdev-database-browser-preview)

(defun gdev-postgresql-browser-display (connection)
  "Apri in Database SQL la consultazione di CONNECTION."
  (let ((buffer (gdev-database-browser-display
                 'postgresql connection (gdev-postgresql--label connection)
                 (car connection) #'gdev-postgresql-browser--request
                 #'gdev-postgresql-browser-mode)))
    (with-current-buffer buffer
      (setq-local gdev-postgresql--connection connection))
    buffer))

(defun gdev-postgresql-browse (&optional choose)
  "Mostra Database SQL per PostgreSQL.
Con CHOOSE seleziona un servizio libpq per la consultazione."
  (interactive "P")
  (gdev-postgresql-browser-display
   (or (and (not choose) gdev-postgresql--connection)
       (gdev-postgresql--choose))))

(provide 'gdev-postgresql-browser)
;;; gdev-postgresql-browser.el ends here
