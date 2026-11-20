;;; gdev-state-db-maintenance.el --- Migrazione e recupero dello stato -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Convalida le copie prima di pubblicarle. Il recupero crea un profilo
;; separato, sicuro anche se un altro editor tiene aperto il file guasto.

;;; Code:

(require 'gdev-state-db)
(require 'seq)
(require 'subr-x)
(defvar gdev-state-directory)

(defconst gdev-state-db--old-tables
  '("CREATE TABLE ambito (id INTEGER PRIMARY KEY, tipo TEXT NOT NULL, riferimento TEXT, CHECK(riferimento IS NOT NULL OR tipo='spazio'))"
    "CREATE TABLE sessione (id INTEGER PRIMARY KEY, nome TEXT NOT NULL, spazio_attivo INTEGER NOT NULL)"))

(defun gdev-state-db--ddl (table)
  (cl-find-if (lambda (sql) (string-prefix-p (concat "CREATE TABLE " table " (") sql))
              gdev-state-db--schema))

(defun gdev-state-db-validate (db &optional full)
  "Controlla identità, versione, struttura, pagine e relazioni.
FULL controlla anche gli indici."
  (pcase-let* ((`(,app ,version ,_) (gdev-state-db--header db))
               (old (and (= app 0) (= version 1)))
               (rows (sqlite-select db "SELECT sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'"))
               (schema (mapcar #'car rows)))
    (unless (or old (and (= app gdev-state-db--application) (= version gdev-state-db--version)))
      (gdev-state-db--invalid (format "Identità o versione del database incompatibile (%s)" version)))
    (unless (if old
                (and (cl-subsetp schema (append gdev-state-db--old-tables gdev-state-db--schema) :test #'equal)
                     (cl-every (lambda (table) (seq-some (lambda (sql) (string-prefix-p (concat "CREATE TABLE " table " (") sql)) schema))
                               '("ambito" "impostazione" "componente" "sessione" "spazio" "cartella_spazio" "documento_spazio" "bozza")))
              (and (= (length schema) (length gdev-state-db--schema))
                   (cl-subsetp schema gdev-state-db--schema :test #'equal)))
      (gdev-state-db--invalid "La struttura del database è stata alterata"))
    (unless (and (equal '(("ok")) (sqlite-select db (if full "PRAGMA integrity_check" "PRAGMA quick_check")))
                 (null (sqlite-select db "PRAGMA foreign_key_check")))
      (gdev-state-db--invalid "Controllo delle pagine o delle relazioni fallito"))
    (when (sqlite-select db "SELECT 1 FROM impostazione i WHERE NOT EXISTS (SELECT 1 FROM componente c WHERE c.id_impostazione=i.id AND c.numero=0) LIMIT 1")
      (gdev-state-db--invalid "Una impostazione è priva di valore"))
    (when (sqlite-select db "SELECT 1 FROM componente WHERE CASE tipo
 WHEN 'intero' THEN typeof(valore) != 'integer'
 WHEN 'testo' THEN typeof(valore) != 'text' WHEN 'simbolo' THEN typeof(valore) != 'text'
 WHEN 'letterale' THEN typeof(valore) != 'text'
 ELSE tipo NOT IN ('nullo','lista','coppia','vettore') OR valore IS NOT NULL END LIMIT 1")
      (gdev-state-db--invalid "È presente un valore di tipo errato"))
    (when (or (sqlite-select db "SELECT 1 FROM spazio s JOIN ambito a ON a.id=s.id_ambito WHERE a.tipo!='spazio' OR a.riferimento IS NOT NULL LIMIT 1")
              (and (or (not old) (member "id_ambito" (mapcar #'cadr (sqlite-select db "PRAGMA table_info(sessione)"))))
                   (sqlite-select db "SELECT 1 FROM sessione s JOIN ambito a ON a.id=s.id_ambito WHERE a.tipo!='istantanea_sessione' OR a.riferimento IS NOT NULL LIMIT 1"))
              (and (member (gdev-state-db--ddl "ultime_preferenze_sessione") schema)
                   (sqlite-select db "SELECT 1 FROM ultime_preferenze_sessione u JOIN ambito a ON a.id=u.id_ambito WHERE a.tipo!='preferenze_sessione' LIMIT 1")))
      (gdev-state-db--invalid "La sessione o lo spazio fa riferimento alle impostazioni di un altro proprietario"))
    (when (or (sqlite-select db "SELECT 1 FROM documento_spazio WHERE tipo NOT IN ('file','bozza') OR typeof(riferimento)!='text' LIMIT 1")
              (sqlite-select db "SELECT 1 FROM bozza WHERE tipo NOT IN ('file','bozza') OR modificata NOT IN (0,1) OR binaria NOT IN (0,1) OR typeof(testo)!='text' LIMIT 1"))
      (gdev-state-db--invalid "Documento o bozza con metadati non validi"))
    (when full
      (dolist (relation '(("spazio" . "id_sessione") ("cartella_spazio" . "id_spazio")
                          ("documento_spazio" . "id_spazio")))
        (when (sqlite-select db (format "SELECT 1 FROM %s GROUP BY %s HAVING min(posizione)!=0 OR max(posizione)!=count(*)-1 LIMIT 1"
                                        (car relation) (cdr relation)))
          (gdev-state-db--invalid "Le posizioni salvate nella sessione non sono consecutive")))
      (when (sqlite-select db "SELECT 1 FROM sessione s LEFT JOIN spazio z ON z.id_sessione=s.id GROUP BY s.id
 HAVING typeof(s.spazio_attivo)!='integer' OR s.spazio_attivo<0 OR s.spazio_attivo>=max(1,count(z.id)) LIMIT 1")
        (gdev-state-db--invalid "La selezione della sessione è fuori dai suoi spazi"))
      (when (sqlite-select db "SELECT 1 FROM componente p LEFT JOIN componente f
 ON p.id_impostazione=f.id_impostazione AND f.padre=p.numero GROUP BY p.id_impostazione,p.numero
 HAVING (p.tipo='coppia' AND count(f.numero)!=2) OR (p.tipo NOT IN ('lista','coppia','vettore') AND count(f.numero)>0)
 OR (count(f.numero)>0 AND (min(f.posizione)!=0 OR max(f.posizione)!=count(f.numero)-1)) LIMIT 1")
        (gdev-state-db--invalid "Le componenti di un valore non sono coerenti"))
      (dolist (row (sqlite-select db "SELECT testo FROM bozza WHERE binaria=1"))
        (condition-case nil (base64-decode-string (car row))
          (error (gdev-state-db--invalid "Testo di una bozza binaria illeggibile"))))
      (dolist (row (sqlite-select db "SELECT valore FROM componente WHERE tipo='letterale' UNION ALL SELECT data_modifica FROM bozza WHERE data_modifica IS NOT NULL"))
        (gdev-state-db--read-literal (car row))))
    version))

(defun gdev-state-db--open-existing (file)
  "Apri FILE per ispezione, senza creare un archivio per un nome sbagliato."
  (unless (file-regular-p file) (user-error "Archivio assente: %s" file))
  ;; Il secondo argomento di sqlite-open è disponibile da Emacs 31.
  ;; Il compilatore controlla anche il ramo non eseguito: non fissare una
  ;; chiamata a due argomenti nel bytecode destinato a Emacs 30.
  (apply #'sqlite-open (if (>= (cdr (func-arity #'sqlite-open)) 2) (list file t) (list file))))

(defun gdev-state-db-inspect (file &optional full)
  (let ((db (gdev-state-db--open-existing file)))
    (unwind-protect
        (progn (sqlite-execute db "PRAGMA busy_timeout=5000")
               (sqlite-execute db "PRAGMA trusted_schema=OFF")
               (sqlite-execute db "PRAGMA query_only=ON")
               (sqlite-execute db "BEGIN")
               (condition-case err (gdev-state-db-validate db full)
                 (sqlite-error (gdev-state-db--explain-error err))))
      (sqlite-close db))))

(defun gdev-state-db--publish (temporary target)
  ;; Il collegamento esclusivo, sullo stesso volume, pubblica il file completo
  ;; senza sovrascrivere un archivio creato nel frattempo da un'altra istanza.
  (add-name-to-file temporary target nil))

(defun gdev-state-db-create (file)
  (unless (sqlite-available-p) (error "Lo stato di GDev richiede Emacs con SQLite integrato"))
  (let ((tmp (make-temp-file (expand-file-name ".stato-nuovo-" (file-name-directory file)))))
    (unwind-protect
        (progn
          (let ((db (sqlite-open tmp)))
            (unwind-protect
                (progn
                  (sqlite-execute db "BEGIN")
                  (dolist (sql gdev-state-db--schema) (sqlite-execute db sql))
                  (sqlite-execute db (format "PRAGMA application_id=%d" gdev-state-db--application))
                  (sqlite-execute db (format "PRAGMA user_version=%d" gdev-state-db--version))
                  (sqlite-execute db "COMMIT"))
              (sqlite-close db)))
          (condition-case nil (gdev-state-db--publish tmp file) (file-already-exists nil))
          (with-file-modes #o700 (make-directory (gdev-state-db--copies-directory t) t)))
      (delete-file tmp))))

(defun gdev-state-db--copies-directory (&optional write)
  (let ((dir (expand-file-name "copie-stato" gdev-state-directory)))
    (when (and write (file-symlink-p dir))
      (user-error "La cartella copie-stato è un collegamento. Per esportare usa «gdev stato copia FILE»"))
    (file-name-as-directory dir)))

(defun gdev-state-db--copy (source target)
  "Pubblica in TARGET una copia coerente verificata, senza sovrascrivere."
  (when (or (file-exists-p target) (file-symlink-p target))
    (signal 'file-already-exists (list "La destinazione esiste già" target)))
  (gdev-state-db-inspect source t)
  ;; Alcune librerie SQLite rifiutano anche una destinazione vuota già
  ;; esistente. La cartella privata riserva il nome senza creare il database
  ;; e conserva la pubblicazione esclusiva sullo stesso volume di TARGET.
  (let* ((stage (make-temp-file (expand-file-name ".stato-copia-" (file-name-directory target)) t))
         (tmp (expand-file-name "stato.sqlite" stage)))
    (unwind-protect
        (progn
          (let ((db (gdev-state-db--open-existing source)))
            (unwind-protect
                (progn (sqlite-execute db "PRAGMA busy_timeout=5000")
                       (sqlite-execute db "PRAGMA trusted_schema=OFF")
                       (sqlite-execute db "VACUUM INTO ?" (list tmp)))
              (sqlite-close db)))
          (set-file-modes tmp #o600)
          (gdev-state-db-inspect tmp t)
          (gdev-state-db--publish tmp target)
          target)
      (delete-directory stage t))))

(defun gdev-state-db-migrate (db file)
  "Aggiorna la versione 1 prima di servire la prima lettura."
  (sqlite-execute db "PRAGMA foreign_keys=OFF")
  (sqlite-execute db "PRAGMA legacy_alter_table=ON")
  (sqlite-execute db "BEGIN IMMEDIATE")
  ;; Una seconda istanza può aver migrato durante l'attesa del lock.
  (when (equal (cl-subseq (gdev-state-db--header db) 0 2) '(0 1))
    (gdev-state-db-validate db t)
    (let ((dir (gdev-state-db--copies-directory t)))
      (with-file-modes #o700 (make-directory dir t))
      (gdev-state-db--copy file (expand-file-name (format-time-string "prima-v2-%Y%m%dT%H%M%S-%N.sqlite") dir)))
    (when (equal (caar (sqlite-select db "SELECT sql FROM sqlite_schema WHERE name='ambito'"))
                 (car gdev-state-db--old-tables))
      ;; Con legacy_alter_table e FK disattivate, i riferimenti delle tabelle
      ;; figlie restano ai nomi originali durante la sostituzione.
      (sqlite-execute db "ALTER TABLE ambito RENAME TO ambito_precedente")
      (sqlite-execute db (gdev-state-db--ddl "ambito"))
      (sqlite-execute db "INSERT INTO ambito SELECT id,tipo,riferimento FROM ambito_precedente")
      (sqlite-execute db "DROP TABLE ambito_precedente"))
    (unless (assoc-string "id_ambito" (mapcar #'cadr (sqlite-select db "PRAGMA table_info(sessione)")))
      (sqlite-execute db "ALTER TABLE sessione RENAME TO sessione_precedente")
      (sqlite-execute db (gdev-state-db--ddl "sessione"))
      (dolist (row (sqlite-select db "SELECT id,nome,spazio_attivo FROM sessione_precedente ORDER BY id"))
        (sqlite-execute db "INSERT INTO ambito(tipo) VALUES('istantanea_sessione')")
        (sqlite-execute db "INSERT INTO sessione VALUES(?,?,?,last_insert_rowid())" row))
      (sqlite-execute db "DROP TABLE sessione_precedente"))
    (let ((existing (mapcar #'car (sqlite-select db "SELECT sql FROM sqlite_master"))))
      (dolist (sql gdev-state-db--schema)
        (unless (member sql existing) (sqlite-execute db sql))))
    (sqlite-execute db "INSERT OR IGNORE INTO ultime_preferenze_sessione SELECT 1,id FROM ambito WHERE tipo='preferenze_sessione' ORDER BY id DESC LIMIT 1")
    (sqlite-execute db (format "PRAGMA application_id=%d" gdev-state-db--application))
    (sqlite-execute db (format "PRAGMA user_version=%d" gdev-state-db--version))
    (gdev-state-db-validate db t))
  (sqlite-execute db "COMMIT")
  (sqlite-execute db "PRAGMA legacy_alter_table=OFF"))

(defconst gdev-state-db--daily-pattern
  "stato-\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\(?:-\\([0-9]+\\)\\)?\\.sqlite")

(defconst gdev-state-db--migration-pattern
  "prima-v[0-9]+-\\([0-9]\\{8\\}\\)T\\([0-9]\\{6\\}\\)-\\([0-9]+\\)\\.sqlite")

(defun gdev-state-db--backup-files (pattern)
  (let ((dir (gdev-state-db--copies-directory)))
    (when (file-directory-p dir)
      (seq-filter (lambda (entry) (null (file-attribute-type (cdr entry))))
                  (directory-files-and-attributes dir t pattern)))))

(defun gdev-state-db--copy-timestamp (entry)
  (let ((name (file-name-nondirectory (car entry))))
    (if (string-match gdev-state-db--migration-pattern name)
        (concat (match-string 1 name) (match-string 2 name) (match-string 3 name))
      (string-match gdev-state-db--daily-pattern name)
      (let* ((day (match-string 1 name))
             (hour (match-string 2 name))
             (modified (file-attribute-modification-time (cdr entry))))
        ;; I nomi giornalieri originari riportano soltanto il giorno.
        (concat (string-replace "-" "" day)
                (or hour (and (equal day (format-time-string "%Y-%m-%d" modified))
                              (format-time-string "%H%M%S%N" modified))
                    "000000000000000"))))))

(defun gdev-state-db-copies ()
  "Elenca le copie dalla più recente secondo la data registrata nel nome."
  (let* ((pattern (concat "\\`\\(?:" gdev-state-db--daily-pattern
                          "\\|" gdev-state-db--migration-pattern "\\)\\'"))
         (entries (gdev-state-db--backup-files pattern)))
    (mapcar #'car (cl-stable-sort entries #'string-greaterp :key #'gdev-state-db--copy-timestamp))))

(defun gdev-state-db--today ()
  (gdev-state-db--backup-files
   (concat "\\`" (format-time-string "stato-%Y-%m-%d") "\\(?:-[0-9]+\\)?\\.sqlite\\'")))

(defun gdev-state-db--prune-copies ()
  (let (days)
    (dolist (file (gdev-state-db-copies))
      (when (string-match (concat "\\`" gdev-state-db--daily-pattern "\\'") (file-name-nondirectory file))
        (let ((day (match-string 1 (file-name-nondirectory file))))
          (when (ignore-errors (gdev-state-db-inspect file t))
            (if (or (member day days) (>= (length days) 3))
                (ignore-error file-missing (delete-file file))
              (push day days))))))))

(defvar gdev-state-db--backup-checked nil)

(defun gdev-state-db--copy-signature ()
  (cons (gdev-state-db-file)
        (mapcar (pcase-lambda (`(,name . ,attrs))
                  (list name (file-attribute-inode-number attrs) (file-attribute-size attrs)
                        (file-attribute-modification-time attrs) (file-attribute-status-change-time attrs)))
                (gdev-state-db--today))))

(defun gdev-state-db-backup (&optional destination)
  "Crea una copia esplicita o conserva le ultime tre giornate verificabili."
  (if destination (gdev-state-db--copy (gdev-state-db-file) (expand-file-name destination))
    (let* ((dir (gdev-state-db--copies-directory t))
           (target (expand-file-name (format-time-string "stato-%Y-%m-%d.sqlite") dir))
           (good (seq-find (lambda (entry) (ignore-errors (gdev-state-db-inspect (car entry) t)))
                           (gdev-state-db--today))))
      (unless (file-regular-p (gdev-state-db-file)) (user-error "Nessun database del profilo"))
      (unless good
        (with-file-modes #o700 (make-directory dir t))
        (when (or (file-exists-p target) (file-symlink-p target))
          (setq target (expand-file-name (format-time-string "stato-%Y-%m-%d-%H%M%S%N.sqlite") dir)))
        (condition-case nil (gdev-state-db--copy (gdev-state-db-file) target)
          (file-already-exists (gdev-state-db-inspect target t)))
        (gdev-state-db--prune-copies))
      (setq gdev-state-db--backup-checked (gdev-state-db--copy-signature))
      (or (car good) target))))

(defvar gdev-config-directory)
(defvar gdev-state-db--backup-process nil)
(defvar gdev-state-db--backup-retry nil)

(defun gdev-state-db--backup-due-p ()
  (and (file-regular-p (gdev-state-db-file))
       (let ((signature (gdev-state-db--copy-signature)))
         (or (null (cdr signature)) (not (equal signature gdev-state-db--backup-checked))))))

(defun gdev-state-db-auto-backup ()
  "Crea la copia giornaliera in un altro processo Emacs."
  (when (and (not (process-live-p gdev-state-db--backup-process))
             (or (null gdev-state-db--backup-retry) (time-less-p gdev-state-db--backup-retry nil))
             (gdev-state-db--backup-due-p))
    (let ((process-environment (copy-sequence process-environment))
          (signature (gdev-state-db--copy-signature)))
      (setenv "GDEV_STATE_DIR" gdev-state-directory)
      (setenv "GDEV_PROFILE" nil)
      (setq gdev-state-db--backup-process
            (make-process :name "gdev-copia-stato" :noquery t :connection-type 'pipe :buffer nil
                          :command (list (expand-file-name invocation-name invocation-directory)
                                         "--batch" "-Q" "-l" (expand-file-name "bin/gdev-cli-entry.el" gdev-config-directory)
                                         "-f" "gdev-cli-entry" "stato" "copia")
                          :sentinel
                          (lambda (process _)
                            (when (and (eq (process-status process) 'exit) (= 0 (process-exit-status process)))
                              (setq gdev-state-db--backup-checked signature))
                            (when (and (memq (process-status process) '(exit signal))
                                       (/= (process-exit-status process) 0))
                              (setq gdev-state-db--backup-retry (time-add nil 3600))
                              (display-warning 'gdev "Copia dello stato non riuscita. Esegui «gdev stato verifica»."))))))))

(defun gdev-state-db-exit-backup ()
  "Completa la prima copia della giornata anche nelle sessioni brevi."
  (when (gdev-state-db--backup-due-p)
    (condition-case err (gdev-state-db-backup)
      (error (display-warning 'gdev (format "Copia dello stato non riuscita. %s" (error-message-string err)))))))

(defun gdev-state-db-recover (source directory)
  "Ricostruisci da SOURCE lo stato in una DIRECTORY nuova e separata."
  (when (equal source "ultima")
    (setq source (or (seq-find (lambda (file) (ignore-errors (gdev-state-db-inspect file t)))
                               (gdev-state-db-copies))
                     (user-error "Nessuna copia verificabile disponibile per il profilo"))))
  (let ((dir (directory-file-name (expand-file-name directory))))
    (when (or (file-exists-p dir) (file-symlink-p dir))
      (signal 'file-already-exists (list "La destinazione esiste già" dir)))
    ;; La rinomina pubblica insieme database e copia, sullo stesso volume.
    (let ((stage (make-temp-file (expand-file-name ".gdev-recupero-" (file-name-directory dir)) t)))
      (unwind-protect
          (progn
            (let ((gdev-state-directory (file-name-as-directory stage)))
              (gdev-state-db--copy source (gdev-state-db-file))
              (gdev-state-db-with (db) (gdev-state-db-validate db t))
              (gdev-state-db-backup))
            (rename-file stage dir nil)
            (setq stage nil)
            (expand-file-name "stato.sqlite" dir))
        (when (and stage (file-directory-p stage)) (delete-directory stage t))))))


(provide 'gdev-state-db-maintenance)
;;; gdev-state-db-maintenance.el ends here
