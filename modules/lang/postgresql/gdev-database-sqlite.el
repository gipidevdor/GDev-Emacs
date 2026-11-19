;;; gdev-database-sqlite.el --- Adattatore SQLite per Database SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il client sqlite3 di sistema esplora il catalogo in processi annullabili
;; di sola lettura. Le esecuzioni esplicite usano il pannello di compilazione.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'gdev-lib)
(require 'gdev-compilation)

(defconst gdev-database-sqlite--timeout 5
  "Secondi concessi a ogni interrogazione dell'esploratore.")

(defconst gdev-database-sqlite--output-limit (* 2 1024 1024)
  "Numero massimo di byte restituiti da un'interrogazione dell'esploratore.")

(defvar-local gdev-database-sqlite--script nil
  "Copia della selezione disponibile per ripetere l'esecuzione.")
(put 'gdev-database-sqlite--script 'permanent-local t)

(defun gdev-database-sqlite-client ()
  "Restituisci il client sqlite3 disponibile nell'ambiente locale."
  (or (executable-find "sqlite3")
      (user-error "sqlite3 non disponibile nell’ambiente corrente")))

(defun gdev-database-sqlite--file (connection)
  "Restituisci il file locale leggibile di CONNECTION."
  (let ((file (cdr connection)))
    (unless (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file))
                 (file-regular-p file) (file-readable-p file))
      (user-error "Scegli un file SQLite locale e leggibile"))
    (expand-file-name file)))

(defun gdev-database-sqlite-choose ()
  "Chiedi un file SQLite esistente e restituisci la connessione del progetto."
  (when (file-remote-p default-directory)
    (user-error "Apri un progetto locale per usare SQLite"))
  (let* ((root (gdev-project-root))
         (file (expand-file-name (read-file-name "File SQLite: " root nil t)))
         (connection (cons root file)))
    (gdev-database-sqlite--file connection)
    connection))

(defun gdev-database-sqlite-label (connection)
  "Restituisci il nome breve del file di CONNECTION."
  (file-name-nondirectory (cdr connection)))

(defun gdev-database-sqlite--literal (name)
  "Proteggi NAME come valore testuale SQLite."
  (concat "'" (string-replace "'" "''" name) "'"))

(defun gdev-database-sqlite--identifier (name)
  "Proteggi NAME come identificatore SQLite."
  (concat "\"" (string-replace "\"" "\"\"" name) "\""))

(defun gdev-database-sqlite--columns (relation)
  "Costruisci la richiesta delle colonne visibili di RELATION."
  (format (concat "SELECT name, type, \"notnull\" AS required "
                  "FROM pragma_table_xinfo(%s, 'main') WHERE hidden <> 1 ORDER BY cid;")
          (gdev-database-sqlite--literal relation)))

(defun gdev-database-sqlite--preview (relation columns)
  "Costruisci l'anteprima di RELATION nelle COLUMNS ordinate per posizione."
  (format
   "SELECT %s FROM main.%s LIMIT 50;"
   (string-join
    (cl-loop for name in columns for index from 0
             for column = (gdev-database-sqlite--identifier name)
             collect
             (format (concat "CASE WHEN typeof(%1$s) = 'blob' THEN "
                             "'BLOB (' || length(%1$s) || ' byte)' "
                             "WHEN typeof(%1$s) = 'text' AND length(%1$s) > 160 "
                             "THEN substr(%1$s, 1, 160) || '…' ELSE CAST(%1$s AS TEXT) END AS c%2$d")
                     column index))
    ", ")
   (gdev-database-sqlite--identifier relation)))

(defun gdev-database-sqlite--decode (output)
  "Leggi le righe JSON di OUTPUT, che può essere vuoto."
  (unless (string-empty-p output)
    (let ((rows (json-parse-string output :array-type 'list :null-object nil)))
      (unless (and (listp rows) (cl-every #'hash-table-p rows))
        (signal 'json-parse-error nil))
      rows)))

(defun gdev-database-sqlite--result (process output diagnostic)
  "Ricava da PROCESS le righe di OUTPUT o il DIAGNOSTIC."
  (cond
   (diagnostic (cons nil diagnostic))
   ((and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
    (condition-case nil (cons (gdev-database-sqlite--decode output) nil)
      (json-parse-error (cons nil "Risposta SQLite non leggibile"))))
   (t (cons nil (if (string-empty-p output) "Interrogazione SQLite non riuscita"
                  (truncate-string-to-width output 400))))))

(defun gdev-database-sqlite--query (program directory file sql finish)
  "Interroga FILE con SQL in DIRECTORY usando PROGRAM.
FINISH riceve le righe o il diagnostico. Restituisci un comando di annullamento."
  (let ((default-directory directory)
        (bytes 0)
        chunks process timer delivery started canceled done diagnostic)
    (cl-labels
        ((cancel ()
           (setq canceled t chunks nil)
           (when timer (cancel-timer timer))
           (when delivery (cancel-timer delivery))
           (when (process-live-p process) (delete-process process)))
         (deliver ()
           (unless (or canceled delivery)
             (setq delivery
                   (run-at-time
                    0 nil
                    (lambda ()
                      (unless canceled
                        (let* ((output (string-trim (apply #'concat (nreverse chunks))))
                               (result (gdev-database-sqlite--result process output diagnostic)))
                          (setq chunks nil)
                          (funcall finish (car result) (cdr result))))))))))
      (unwind-protect
          (progn
            (setq process
                  (make-process
                   :name "gdev-sqlite" :buffer nil :noquery t :connection-type 'pipe
                   :coding 'utf-8-unix
                   :command (list program "-batch" "-bail" "-init" null-device
                                  "-safe" "-readonly" "-json" file)
                   :filter
                   (lambda (child text)
                     (cl-incf bytes (string-bytes text))
                     (if (> bytes gdev-database-sqlite--output-limit)
                         (progn
                           (setq diagnostic "Il risultato SQLite supera la dimensione massima")
                           (delete-process child))
                       (push text chunks)))
                   :sentinel
                   (lambda (child _event)
                     (unless (or done (process-live-p child))
                       (setq done t)
                       (when timer (cancel-timer timer))
                       (when started (deliver))))))
            (unless done
              (setq timer
                    (run-at-time
                     gdev-database-sqlite--timeout nil
                     (lambda ()
                       (when (process-live-p process)
                         (setq diagnostic "Tempo massimo per l’interrogazione SQLite superato")
                         (delete-process process)))))
              (when (process-live-p process)
                (process-send-string process (concat "PRAGMA query_only=ON;\n"
                                                     "PRAGMA trusted_schema=OFF;\n" sql "\n")))
              (when (process-live-p process) (process-send-eof process)))
            (setq started t)
            (when done (deliver)))
        (unless started (cancel)))
      #'cancel)))

(defun gdev-database-sqlite-request (connection path finish)
  "Richiedi PATH in CONNECTION e invoca FINISH con le righe o un errore.
Restituisci una funzione senza argomenti che annulla la richiesta."
  (let* ((file (gdev-database-sqlite--file connection))
         (directory (car connection))
         (program (gdev-database-sqlite-client))
         (relation (cadr path))
         cancel)
    (when (file-remote-p directory)
      (user-error "Scegli un progetto locale per usare SQLite"))
    (when (and path (not (equal (car path) "main")))
      (user-error "Schema SQLite non disponibile"))
    (cl-labels
        ((query (sql transform)
           (setq cancel
                 (gdev-database-sqlite--query
                  program directory file sql
                  (lambda (rows diagnostic)
                    (if diagnostic (funcall finish nil diagnostic)
                      (funcall transform rows)))))))
      (pcase (length path)
        (0 (query "SELECT 'main' AS name, count(*) FROM main.sqlite_master;"
                  (lambda (rows) (funcall finish (mapcar (lambda (r) (gethash "name" r)) rows) nil))))
        (1 (query (concat "SELECT name, type FROM main.sqlite_master "
                          "WHERE type IN ('table', 'view') AND name NOT GLOB 'sqlite_*' ORDER BY name;")
                  (lambda (rows)
                    (funcall finish
                             (mapcar (lambda (r) (list (gethash "name" r)
                                                       (if (equal (gethash "type" r) "view") "v" "r")))
                                     rows)
                             nil))))
        (2 (query (gdev-database-sqlite--columns relation)
                  (lambda (rows)
                    (funcall finish
                             (mapcar (lambda (r) (list (gethash "name" r) (gethash "type" r)
                                                       (eql (gethash "required" r) 1)))
                                     rows)
                             nil))))
        (3 (query (gdev-database-sqlite--columns relation)
                  (lambda (rows)
                    (if (not rows) (funcall finish nil "Tabella o vista SQLite non disponibile")
                      (let ((columns (mapcar (lambda (r) (gethash "name" r)) rows)))
                        (query (gdev-database-sqlite--preview relation columns)
                               (lambda (preview)
                                 (funcall finish
                                          (mapcar
                                           (lambda (r)
                                             (cl-loop for name in columns for index from 0
                                                      collect (list name (gethash (format "c%d" index) r))))
                                           preview)
                                          nil))))))))
        (_ (user-error "Livello del catalogo SQLite non disponibile"))))
    (lambda () (when cancel (funcall cancel)))))

(defun gdev-database-sqlite--release-script ()
  "Rimuovi la copia della selezione associata al pannello corrente."
  (when gdev-database-sqlite--script
    (ignore-error file-missing (delete-file gdev-database-sqlite--script))
    (setq gdev-database-sqlite--script nil)))
(put 'gdev-database-sqlite--release-script 'permanent-local-hook t)

(defun gdev-database-sqlite--release-scripts ()
  "Rimuovi le copie di selezioni rimaste disponibili a fine sessione."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer (gdev-database-sqlite--release-script))))

(defun gdev-database-sqlite-run-file (connection source directory label)
  "Esegui SOURCE su CONNECTION usando DIRECTORY e il pannello LABEL."
  (when (or (file-remote-p directory) (file-remote-p source))
    (user-error "Esegui gli script SQLite da una cartella locale"))
  (let ((default-directory directory))
    (gdev-compilation-check-idle label)
    (with-current-buffer
        (gdev-compile (concat (gdev-command-line (gdev-database-sqlite-client)
                                                "-batch" "-bail" "-init" null-device
                                                "-header" "-column" (gdev-database-sqlite--file connection))
                              " < " (shell-quote-argument source))
                      label directory)
      (gdev-database-sqlite--release-script)
      (current-buffer))))

(defun gdev-database-sqlite-run (connection sql directory label)
  "Esegui il testo SQL su CONNECTION usando DIRECTORY e il pannello LABEL."
  (let ((file (make-temp-file "gdev-sqlite-" nil ".sql"))
        (coding-system-for-write 'utf-8-unix)
        output)
    (unwind-protect
        (progn
          (write-region sql nil file nil 'silent)
          (with-current-buffer (gdev-database-sqlite-run-file connection file directory label)
            (setq gdev-database-sqlite--script file
                  output (current-buffer))
            (add-hook 'kill-buffer-hook #'gdev-database-sqlite--release-script nil t))
          (add-hook 'kill-emacs-hook #'gdev-database-sqlite--release-scripts)
          output)
      (unless output (ignore-error file-missing (delete-file file))))))

(provide 'gdev-database-sqlite)
;;; gdev-database-sqlite.el ends here
