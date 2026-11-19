;;; gdev-database-editor-test.el --- Connessioni e comandi di Database SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la compatibilità del modulo e il legame tra l'editor, la
;; connessione di esecuzione e il pannello di consultazione.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gdev-modules)
(require 'gdev-commands)

(defmacro gdev-test--with-database-editor (&rest body)
  "Esegui BODY con i gestori del modulo Database SQL."
  (declare (indent 0))
  `(let ((auto-mode-alist (copy-tree auto-mode-alist))
         (gdev--handlers (make-hash-table :test #'eq))
         (gdev-popup-rules nil)
         (gdev-doctor-checks nil))
     (load (gdev-module-file :lang 'sql ".el") nil t)
     ,@body))

(ert-deftest gdev-test-database-editor-dialects-and-entry-points ()
  (gdev-test--with-database-editor
    (should (equal (gdev-module-directory :lang 'sql)
                   (gdev-module-directory :lang 'postgresql)))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/query.sql")
      (cl-letf (((symbol-function 'gdev-postgresql--client)
                 (lambda () (ert-fail "Apertura SQL con avvio di psql")))
                ((symbol-function 'gdev-database-sqlite-client)
                 (lambda () (ert-fail "Apertura SQL con avvio di sqlite3"))))
        (set-auto-mode))
      (should (derived-mode-p 'gdev-database-mode 'gdev-postgresql-mode))
      (should (eq (gdev-handler :run) 'gdev-database-run-file))
      (should (eq (key-binding (kbd "C-c l e")) 'gdev-database-send-region))
      (should-not (gdev-database--connection))
      (let* ((connection (cons default-directory "/tmp/banca dati.sqlite3"))
             (target (cons 'sqlite connection)))
        (gdev-database--associate target)
        (should (equal (gdev-database--connection) target))
        (should (eq (buffer-local-value 'sql-product (current-buffer)) 'sqlite))
        (should (eq (key-binding (kbd "C-c l t")) 'gdev-database-list-tables))))))

(ert-deftest gdev-test-database-editor-browsing-does-not-rebind-source ()
  (gdev-test--with-database-editor
    (gdev-test--with-layout
      (with-temp-buffer
        (gdev-database-mode)
        (let* ((postgres (cons default-directory "collaudo"))
               (sqlite (cons default-directory "/tmp/sola lettura.sqlite3")))
          (gdev-database--associate (cons 'postgresql postgres))
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "SQLite"))
                    ((symbol-function 'gdev-database-sqlite-choose) (lambda () sqlite))
                    ((symbol-function 'gdev-database-sqlite-label) (lambda (_) "prova"))
                    ((symbol-function 'gdev-database-browser-display)
                     (lambda (engine connection _label directory request)
                       (should (eq engine 'sqlite))
                       (should (equal connection sqlite))
                       (should (equal directory (car sqlite)))
                       (should (eq request 'gdev-database-sqlite-request))
                       'vista)))
            (should (eq (gdev-database-browse t) 'vista)))
          (should (equal (gdev-database--connection) (cons 'postgresql postgres)))
          (should (eq (buffer-local-value 'sql-product (current-buffer)) 'postgres)))))))

(ert-deftest gdev-test-database-editor-selection-is-pinned-to-its-revision ()
  (gdev-test--with-database-editor
    (gdev-test--with-layout
      (with-temp-buffer
        (gdev-database-mode)
        (insert "SELECT 1;")
        (let ((transient-mark-mode t)
              (connection (cons default-directory "/tmp/revisione.sqlite3")))
          (set-mark (point-min))
          (activate-mark)
          (cl-letf (((symbol-function 'gdev-database--choose)
                     (lambda (&optional _)
                       (insert " ")
                       (cons 'sqlite connection)))
                    ((symbol-function 'gdev-database-sqlite-run)
                     (lambda (&rest _) (ert-fail "Richiesta con una revisione superata"))))
            (should-error (gdev-database-send-region (point-min) (point-max)) :type 'user-error))
          (should-not (gdev-database--connection)))))))

(provide 'gdev-database-editor-test)
;;; gdev-database-editor-test.el ends here
