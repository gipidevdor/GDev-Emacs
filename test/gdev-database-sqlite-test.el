;;; gdev-database-sqlite-test.el --- Prove dell'adattatore SQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le prove usano il client di sistema e un database temporaneo. Verificano
;; navigazione, sola lettura, annullamento ed esecuzione nel pannello comune.

;;; Code:

(require 'ert)
(require 'gdev-database-sqlite
         (gdev-config-file "modules/lang/postgresql/gdev-database-sqlite.el"))

(defun gdev-test-database-sqlite--exec (file sql)
  "Esegui SQL su FILE con sqlite3 e restituisci il testo."
  (with-temp-buffer
    (let ((status (call-process (gdev-database-sqlite-client) nil t nil
                                "-batch" "-bail" "-init" null-device file sql)))
      (should (equal status 0))
      (buffer-string))))

(defun gdev-test-database-sqlite--wait (connection path)
  "Raccogli il risultato asincrono di PATH in CONNECTION."
  (let (result cancel)
    (unwind-protect
        (progn
          (setq cancel
                (gdev-database-sqlite-request connection path
                                             (lambda (rows error)
                                               (setq result (cons rows error)))))
          (should-not result)
          (with-timeout (8 (ert-fail "SQLite non ha consegnato il risultato"))
            (while (not result) (accept-process-output nil 0.02)))
          (should-not (cdr result))
          (car result))
      (when cancel (funcall cancel)))))

(ert-deftest gdev-test-database-sqlite-catalogue-and-preview ()
  (skip-unless (executable-find "sqlite3"))
  (let* ((root (make-temp-file "gdev-prova-sqlite-" t))
         (file (expand-file-name "città; #%.sqlite" root))
         (connection (cons (file-name-as-directory root) file))
         (table "vendite \"d'oggi\"\narchivio")
         (sql (concat "CREATE TABLE \"vendite \"\"d'oggi\"\"\narchivio\" "
                      " (\"nome\ncompleto\" TEXT NOT NULL, importo INTEGER, nota TEXT, dati BLOB); "
                      "CREATE VIEW riepilogo AS SELECT 1; "
                      "INSERT INTO \"vendite \"\"d'oggi\"\"\narchivio\" VALUES "
                      "('città' || char(10) || 'oggi', 42, NULL, X'FF00'); "
                      "INSERT INTO \"vendite \"\"d'oggi\"\"\narchivio\" VALUES "
                      "(printf('%0161d', 0), 7, 'altro', NULL);")))
    (unwind-protect
        (progn
          (gdev-test-database-sqlite--exec file sql)
          (should (equal (gdev-test-database-sqlite--wait connection nil) '("main")))
          (should (equal (gdev-test-database-sqlite--wait connection '("main"))
                         (list '("riepilogo" "v") (list table "r"))))
          (should (equal (gdev-test-database-sqlite--wait connection (list "main" table))
                         '(("nome\ncompleto" "TEXT" t) ("importo" "INTEGER" nil)
                           ("nota" "TEXT" nil) ("dati" "BLOB" nil))))
          (let ((rows (gdev-test-database-sqlite--wait connection (list "main" table 'anteprima))))
            (should (equal (car rows)
                           '(("nome\ncompleto" "città\noggi") ("importo" "42")
                             ("nota" nil) ("dati" "BLOB (2 byte)"))))
            (should (equal (cadar (cadr rows)) (concat (make-string 160 ?0) "…"))))
          (should (equal (gdev-test-database-sqlite--exec
                          file "SELECT count(*) FROM main.sqlite_master WHERE type = 'table';")
                         "1\n")))
      (delete-directory root t))))

(ert-deftest gdev-test-database-sqlite-readonly-and-cancel ()
  (skip-unless (executable-find "sqlite3"))
  (let* ((root (make-temp-file "gdev-prova-sqlite-" t))
         (file (expand-file-name "prova.sqlite" root))
         (connection (cons (file-name-as-directory root) file))
         (program (gdev-database-sqlite-client))
         result cancel)
    (unwind-protect
        (progn
          (should-error (gdev-database-sqlite-request connection nil #'ignore) :type 'user-error)
          (should-not (file-exists-p file))
          (gdev-test-database-sqlite--exec file "CREATE TABLE prova (id INTEGER);")
          (setq cancel
                (gdev-database-sqlite--query program root file "DROP TABLE prova;"
                                            (lambda (rows error) (setq result (cons rows error)))))
          (with-timeout (8 (ert-fail "Manca il risultato della richiesta di sola lettura"))
            (while (not result) (accept-process-output nil 0.02)))
          (should-not (car result))
          (should (stringp (cdr result)))
          (should (equal (gdev-test-database-sqlite--wait connection '("main")) '(("prova" "r"))))
          (setq result nil
                cancel (gdev-database-sqlite-request connection nil
                                                    (lambda (&rest args) (setq result args))))
          (funcall cancel)
          (funcall cancel)
          (accept-process-output nil 0.05)
          (should-not result))
      (when cancel (funcall cancel))
      (delete-directory root t))))

(ert-deftest gdev-test-database-sqlite-run-stops-and-releases-selection ()
  (skip-unless (executable-find "sqlite3"))
  (let* ((root (file-name-as-directory (make-temp-file "gdev-prova-sqlite-" t)))
         (file (expand-file-name "prova ; #.sqlite" root))
         (connection (cons root file))
         (source (expand-file-name "script ; #.sql" root))
         output run temporary)
    (unwind-protect
        (save-window-excursion
          (gdev-test-database-sqlite--exec file "CREATE TABLE prova (id INTEGER);")
          (setq output (gdev-database-sqlite-run connection
                                                (concat "INSERT INTO prova VALUES (1);\n"
                                                        "SELECT no_such_column FROM prova;\n"
                                                        "INSERT INTO prova VALUES (2);\n")
                                                root "Esecuzione SQLite di prova")
                run (get-buffer-process output)
                temporary (buffer-local-value 'gdev-database-sqlite--script output))
          (should (file-exists-p temporary))
          (should (= (logand (file-modes temporary) #o077) 0))
          (with-timeout (8 (ert-fail "L'esecuzione SQLite non è terminata"))
            (while (process-live-p run) (accept-process-output run 0.02)))
          (should-not (zerop (process-exit-status run)))
          (should (equal (gdev-test-database-sqlite--exec file "SELECT id FROM prova;") "1\n"))
          (kill-buffer output)
          (should-not (file-exists-p temporary))
          (write-region "INSERT INTO prova VALUES (3);\n" nil
                        (expand-file-name "parte.sql" root) nil 'silent)
          (write-region ".read parte.sql\n" nil source nil 'silent)
          (setq output (gdev-database-sqlite-run-file connection source root "Script SQLite di prova")
                run (get-buffer-process output))
          (with-timeout (8 (ert-fail "Lo script SQLite non è terminato"))
            (while (process-live-p run) (accept-process-output run 0.02)))
          (should (zerop (process-exit-status run)))
          (should (equal (gdev-test-database-sqlite--exec file "SELECT id FROM prova ORDER BY id;")
                         "1\n3\n"))
          (kill-buffer output)
          (should (file-exists-p source)))
      (when (buffer-live-p output) (kill-buffer output))
      (delete-directory root t))))

(provide 'gdev-database-sqlite-test)
;;; gdev-database-sqlite-test.el ends here
