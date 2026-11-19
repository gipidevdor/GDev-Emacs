;;; gdev-database-postgresql-test.el --- Prove del catalogo PostgreSQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'annullamento prima della connessione e la consultazione di
;; un cluster temporaneo attraverso un socket locale.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-lib)
(require 'gdev-postgresql-browser
         (gdev-config-file "modules/lang/postgresql/gdev-postgresql-browser"))

(defun gdev-test-database-postgresql--read (connection path)
  "Attendi la risposta della consultazione di PATH in CONNECTION."
  (let* ((deadline (+ (float-time) 6))
         done received
         (cancel (gdev-postgresql-browser--request
                  connection path (lambda (rows failure)
                                    (setq received (cons rows failure) done t)))))
    (unwind-protect
        (progn
          (while (and (not done) (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (should done)
          received)
      (funcall cancel))))

(ert-deftest gdev-test-database-postgresql-annulla-prima-di-avviare ()
  "Annullare una lettura in attesa evita la connessione e la consegna."
  (let (client-opened delivered)
    (cl-letf (((symbol-function 'gdev-postgresql--client)
               (lambda () (setq client-opened t) (user-error "Client inatteso"))))
      (let ((cancel (gdev-postgresql-browser--request
                     (cons default-directory nil) nil
                     (lambda (&rest _) (setq delivered t)))))
        (funcall cancel)
        (funcall cancel)
        (accept-process-output nil 0.05))
      (should-not client-opened)
      (should-not delivered))))

(ert-deftest gdev-test-database-postgresql-catalogo-reale ()
  "Adattatore, identificatori eterogenei, anteprima limitata ed errore."
  (skip-unless (and (memq system-type '(darwin gnu/linux berkeley-unix))
                    (not (zerop (user-uid)))
                    (executable-find "pg_ctl") (executable-find "initdb")
                    (executable-find "psql")))
  (let* ((root (make-temp-file "/tmp/gdev-pg-" t))
         (default-directory (file-name-as-directory root))
         (directory (expand-file-name "dati" root))
         (log (expand-file-name "postgres.log" root))
         (services (expand-file-name "pg_service.conf" root))
         (schema "ì vendite")
         (table "fatture \"2026\"\narchivio")
         (column "codice \"cliente\"")
         (connection (cons default-directory "consultazione"))
         (process-environment (copy-sequence process-environment))
         (auto-mode-alist (copy-tree auto-mode-alist))
         (gdev--handlers (make-hash-table :test #'eq))
         (gdev-popup-rules nil)
         (gdev-doctor-checks nil)
         started)
    (cl-labels ((exec (program &rest args)
                  (with-temp-buffer
                    (unless (eq 0 (apply #'process-file program nil (list t t) nil args))
                      (ert-fail (buffer-string)))))
                (ident (name)
                  (concat "\"" (replace-regexp-in-string "\"" "\"\"" name t t) "\""))
                (read-level (path)
                  (let ((result (gdev-test-database-postgresql--read connection path)))
                    (should-not (cdr result))
                    (car result))))
      (unwind-protect
          (progn
            (load (gdev-module-file :lang 'sql ".el") nil t)
            (exec "initdb" "-D" directory "--auth=trust" "--locale=C" "--encoding=UTF8" "--no-sync")
            (exec "pg_ctl" "-D" directory "-l" log "-o" (concat "-k " root " -c listen_addresses=")
                  "-w" "start")
            (setq started t)
            (dolist (name '("PGHOSTADDR" "PGSERVICE" "PGOPTIONS" "PGPORT" "PGPASSWORD"))
              (setenv name nil))
            (setenv "PGHOST" root)
            (setenv "PGUSER" (user-login-name))
            (setenv "PGDATABASE" "postgres")
            (setenv "PGCLIENTENCODING" "UTF8")
            (let* ((relation (concat (ident schema) "." (ident table)))
                   (sql (format "CREATE SCHEMA %s; CREATE TABLE %s (%s text NOT NULL, facoltativa integer); INSERT INTO %s SELECT repeat('à', 170), NULL FROM pg_catalog.generate_series(1, 60);"
                                (ident schema) relation (ident column) relation)))
              (exec "psql" "-Xqw" "--set=ON_ERROR_STOP=1" "-c" sql))
            (with-temp-file services
              (insert "[consultazione]\ndbname=postgres\n"))
            (setenv "PGSERVICEFILE" services)
            (setenv "PGDATABASE" "non_e_il_database_del_servizio")
            (let (result)
              (unwind-protect
                  (save-window-excursion
                    (with-temp-buffer
                      (gdev-database-mode)
                      (setq-local gdev-postgresql--connection connection)
                      (insert "SELECT 73419 AS valore;\n"
                              "SELECT funzione_inesistente_di_prova();\n"
                              "SELECT 81943 AS dopo_errore;\n")
                      (let ((transient-mark-mode t))
                        (set-mark (point-min))
                        (activate-mark)
                        (setq result (gdev-database-send-region (point-min) (point-max)))))
                    (let ((process (get-buffer-process result))
                          (deadline (+ (float-time) 5)))
                      (while (and (process-live-p process) (< (float-time) deadline))
                        (accept-process-output nil 0.05))
                      (should-not (process-live-p process)))
                    (with-current-buffer result
                      (should (string-search "73419" (buffer-string)))
                      (should (string-search "funzione_inesistente_di_prova" (buffer-string)))
                      (should-not (string-search "81943" (buffer-string)))))
                (when (buffer-live-p result) (kill-buffer result))))
            (should (member schema (read-level nil)))
            (should (equal (read-level (list schema)) (list (list table "r"))))
            (should (equal (read-level (list schema table))
                           (list (list column "text" t) '("facoltativa" "integer" :false))))
            (let ((rows (read-level (list schema table 'anteprima))))
              (should (= (length rows) 50))
              (should (equal (car rows)
                             (list (list column (concat (make-string 160 ?à) "…"))
                                   (list "facoltativa" nil)))))
            (let ((failure (gdev-test-database-postgresql--read connection
                                                               (list schema "assente" 'anteprima))))
              (should (null (car failure)))
              (should (string-match-p "assente" (cdr failure))))
            (setenv "PGSERVICE" "consultazione")
            (exec "psql" "-Xqw" "--set=ON_ERROR_STOP=1"
                  "-c" "CREATE VIEW public.lettura_lenta AS SELECT pg_sleep(3)::text AS dato")
            (setenv "PGSERVICE" nil)
            (let* ((deadline (+ (float-time) 2))
                   child delivered
                   (cancel (gdev-postgresql-browser--request
                            connection '("public" "lettura_lenta" anteprima)
                            (lambda (&rest _) (setq delivered t)))))
              (unwind-protect
                  (progn
                    (while (and (not (process-live-p (setq child (get-process "gdev-postgresql"))))
                                (< (float-time) deadline))
                      (accept-process-output nil 0.05))
                    (should (process-live-p child))
                    (funcall cancel)
                    (should-not (process-live-p child))
                    (should-not delivered))
                (funcall cancel)))
            (should (equal (getenv "PGDATABASE") "non_e_il_database_del_servizio"))
            (should-not (getenv "PGSERVICE")))
        (when started
          (process-file "pg_ctl" nil nil nil "-D" directory "-m" "immediate" "-w" "stop"))
        (delete-directory root t)))))

(provide 'gdev-database-postgresql-test)
;;; gdev-database-postgresql-test.el ends here
