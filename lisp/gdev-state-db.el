;;; gdev-state-db.el --- Stato privato del profilo in SQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Un ambito identifica il proprietario di un insieme di impostazioni.
;; Ogni valore ha una radice e componenti ordinate. Anche liste, vettori e
;; coppie improprie sono interrogabili senza eseguire codice Lisp.

;;; Code:

(require 'cl-lib)
(require 'sqlite)

(defvar gdev-state-directory)
(defvar gdev-state-db--connection nil)
(defvar gdev-state-db--connection-file nil)
(defvar gdev-state-db--writable nil)
(defvar gdev-state-db--abort nil)

(defun gdev-state-db-file ()
  (expand-file-name "stato.sqlite" gdev-state-directory))

(defconst gdev-state-db--schema
  '("CREATE TABLE catalogo_opzione (nome TEXT PRIMARY KEY, tipo_dichiarato TEXT, espressione_predefinita TEXT, locale INTEGER NOT NULL CHECK(locale IN (0,1))) WITHOUT ROWID"
    "CREATE INDEX indice_catalogo_locale ON catalogo_opzione(locale,nome)"
    "CREATE TABLE ambito (id INTEGER PRIMARY KEY, tipo TEXT NOT NULL, riferimento TEXT, CHECK(riferimento IS NOT NULL OR tipo IN ('spazio','istantanea_sessione')))"
    "CREATE UNIQUE INDEX indice_ambito_identita ON ambito(tipo,riferimento)"
    "CREATE TABLE ultime_preferenze_sessione (unico INTEGER PRIMARY KEY CHECK(unico=1), id_ambito INTEGER NOT NULL REFERENCES ambito)"
    "CREATE TABLE impostazione (id INTEGER PRIMARY KEY, id_ambito INTEGER NOT NULL REFERENCES ambito ON DELETE CASCADE, nome TEXT NOT NULL)"
    "CREATE UNIQUE INDEX indice_impostazione_nome ON impostazione(id_ambito,nome)"
    "CREATE TABLE componente (id_impostazione INTEGER NOT NULL REFERENCES impostazione ON DELETE CASCADE, numero INTEGER NOT NULL, padre INTEGER, posizione INTEGER NOT NULL, tipo TEXT NOT NULL, valore, PRIMARY KEY(id_impostazione,numero), FOREIGN KEY(id_impostazione,padre) REFERENCES componente(id_impostazione,numero) DEFERRABLE INITIALLY DEFERRED, CHECK ((padre IS NULL AND numero=0 AND posizione=0) OR (padre IS NOT NULL AND padre<numero)), CHECK(posizione>=0)) WITHOUT ROWID"
    "CREATE UNIQUE INDEX indice_componente_figli ON componente(id_impostazione,padre,posizione)"
    "CREATE TABLE sessione (id INTEGER PRIMARY KEY AUTOINCREMENT, nome TEXT NOT NULL, spazio_attivo INTEGER NOT NULL, id_ambito INTEGER NOT NULL REFERENCES ambito)"
    "CREATE UNIQUE INDEX indice_sessione_ambito ON sessione(id_ambito)"
    "CREATE TRIGGER elimina_campi_sessione AFTER DELETE ON sessione BEGIN DELETE FROM ambito WHERE id=old.id_ambito; END"
    "CREATE UNIQUE INDEX indice_sessione_nome ON sessione(nome)"
    "CREATE TABLE spazio (id INTEGER PRIMARY KEY, id_sessione INTEGER NOT NULL REFERENCES sessione ON DELETE CASCADE, posizione INTEGER NOT NULL, nome TEXT NOT NULL, id_ambito INTEGER NOT NULL REFERENCES ambito)"
    "CREATE UNIQUE INDEX indice_spazio_ordine ON spazio(id_sessione,posizione)"
    "CREATE UNIQUE INDEX indice_spazio_ambito ON spazio(id_ambito)"
    "CREATE TRIGGER elimina_campi_spazio AFTER DELETE ON spazio BEGIN DELETE FROM ambito WHERE id=old.id_ambito; END"
    "CREATE TABLE cartella_spazio (id_spazio INTEGER NOT NULL REFERENCES spazio ON DELETE CASCADE, posizione INTEGER NOT NULL, percorso TEXT NOT NULL, PRIMARY KEY(id_spazio,posizione)) WITHOUT ROWID"
    "CREATE TABLE documento_spazio (id_spazio INTEGER NOT NULL REFERENCES spazio ON DELETE CASCADE, posizione INTEGER NOT NULL, tipo TEXT NOT NULL, riferimento TEXT NOT NULL, PRIMARY KEY(id_spazio,posizione)) WITHOUT ROWID"
    "CREATE TABLE bozza (id_sessione INTEGER NOT NULL REFERENCES sessione ON DELETE CASCADE, tipo TEXT NOT NULL, riferimento TEXT NOT NULL, nome TEXT NOT NULL, modalita TEXT, cartella TEXT, percorso TEXT, data_modifica TEXT, modificata INTEGER NOT NULL, binaria INTEGER NOT NULL, testo TEXT NOT NULL, PRIMARY KEY(id_sessione,tipo,riferimento)) WITHOUT ROWID"))

(defconst gdev-state-db--version 2)
(defconst gdev-state-db--application #x47444556) ; GDEV
(defvar gdev-state-db--checked nil)
(define-error 'gdev-state-db-invalid "Archivio di stato non utilizzabile")

(defun gdev-state-db--invalid (detail)
  (signal 'gdev-state-db-invalid
          (list (format "%s. Usa «gdev stato verifica» o «gdev stato copie» per il recupero" detail))))

(defun gdev-state-db--explain-error (err)
  (let* ((details (if (consp (cadr err)) (cadr err) (cdr err)))
         (code (cl-find-if #'integerp details))
         ;; Alcune build di Emacs espongono soltanto il messaggio di SQLite.
         (code (if code (logand code 255)
                 (pcase (car details)
                   ("database disk image is malformed" 11)
                   ("file is not a database" 26)
                   ("database is locked" 5)
                   ((or "database table is locked" "database schema is locked") 6)
                   ("database or disk is full" 13)
                   ("attempt to write a readonly database" 8)))))
    (pcase code
      ((or 11 26) (gdev-state-db--invalid "SQLite segnala un archivio danneggiato"))
      ((or 5 6) (error "Archivio occupato da un altro processo. Riprova fra poco"))
      (13 (error "Spazio esaurito durante l'operazione SQLite"))
      (8 (error "Archivio SQLite in sola lettura"))
      (_ (signal (car err) (cdr err))))))

(autoload 'gdev-state-db-create "gdev-state-db-maintenance")
(autoload 'gdev-state-db-migrate "gdev-state-db-maintenance")
(autoload 'gdev-state-db-validate "gdev-state-db-maintenance")

(defun gdev-state-db--header (db)
  (car (sqlite-select db "SELECT application_id,user_version,schema_version FROM pragma_application_id, pragma_user_version, pragma_schema_version")))

(defun gdev-state-db--use (file write function)
  (let* ((inode (file-attribute-inode-number (file-attributes file)))
         (gdev-state-db--connection (with-file-modes #o600 (sqlite-open file)))
         (db gdev-state-db--connection)
         (gdev-state-db--connection-file file)
         (gdev-state-db--abort nil)
         (gdev-state-db--writable write))
    (unwind-protect
        (progn
          (sqlite-execute db "PRAGMA busy_timeout=5000")
          (sqlite-execute db "PRAGMA trusted_schema=OFF")
          (when (equal (cl-subseq (gdev-state-db--header db) 0 2) '(0 1))
            (gdev-state-db-migrate db file))
          (sqlite-execute db "PRAGMA foreign_keys=ON")
          (sqlite-execute db "PRAGMA synchronous=FULL")
          (unless write (sqlite-execute db "PRAGMA query_only=ON"))
          (sqlite-execute db (if write "BEGIN IMMEDIATE" "BEGIN"))
          (pcase-let* ((`(,app ,version ,cookie) (gdev-state-db--header db))
                       (key (list file inode cookie)))
            (unless (and (= app gdev-state-db--application) (= version gdev-state-db--version))
              (gdev-state-db--invalid (format "Archivio estraneo o versione incompatibile (%s)" version)))
            (unless (equal key gdev-state-db--checked)
              (gdev-state-db-validate db)
              (setq gdev-state-db--checked key)))
          (prog1 (funcall function db)
            (when gdev-state-db--abort (error "Transazione annullata per una scrittura interrotta"))
            (when (and write (not (equal inode (file-attribute-inode-number (file-attributes file)))))
              (gdev-state-db--invalid "Il file del database è stato sostituito durante la scrittura"))
            (sqlite-execute db "COMMIT")))
      ;; La chiusura rilascia il lock e annulla una transazione interrotta da C-g.
      (sqlite-close db))))

(defun gdev-state-db--call (write function)
  "Esegui FUNCTION con una transazione coerente; WRITE abilita la scrittura."
  (if gdev-state-db--connection
      (progn
        (unless (equal gdev-state-db--connection-file (gdev-state-db-file))
          (setq gdev-state-db--abort t)
          (error "Cambio di profilo durante una transazione dello stato"))
        (when (and write (not gdev-state-db--writable))
          (error "Scrittura dentro una lettura dello stato"))
        (let (completed)
          (unwind-protect
              (prog1 (funcall function gdev-state-db--connection) (setq completed t))
            (when (and write (not completed)) (setq gdev-state-db--abort t)))))
    (let ((file (gdev-state-db-file)))
      (unless (sqlite-available-p) (error "Lo stato di GDev richiede Emacs con SQLite integrato"))
      (unless (file-exists-p file)
        (when (and (or (file-symlink-p file) (equal (car gdev-state-db--checked) file)
                       (file-attributes (expand-file-name "copie-stato" gdev-state-directory)))
                   (not (file-exists-p file)))
          (gdev-state-db--invalid "Il database del profilo è scomparso"))
        (when write (gdev-state-db-create file)))
      (when (file-exists-p file)
        (condition-case err
            (gdev-state-db--use file write function)
          (sqlite-error (gdev-state-db--explain-error err)))))))

(cl-defmacro gdev-state-db-with ((db &optional write) &rest body)
  (declare (indent 1) (debug ((symbolp &optional form) body)))
  `(gdev-state-db--call ,write (lambda (,db) ,@body)))

(defun gdev-state-db--scope (db type ref &optional create)
  (let ((key (list type ref)))
    (when create
      (sqlite-execute db "INSERT OR IGNORE INTO ambito(tipo,riferimento) VALUES(?,?)" key))
    (caar (sqlite-select db "SELECT id FROM ambito WHERE tipo=? AND riferimento=?" key))))

(defun gdev-state-db--print (object)
  (let ((print-length nil) (print-level nil) (print-circle t)
        (print-escape-control-characters t) (print-escape-nonascii t))
    (prin1-to-string object)))

(defun gdev-state-db--read-literal (text)
  (unless (stringp text) (gdev-state-db--invalid "Un valore Lisp salvato è privo di testo"))
  (condition-case nil
      (pcase-let ((`(,value . ,end) (read-from-string text)))
        (unless (= end (length text)) (gdev-state-db--invalid "Dati in eccesso in un valore Lisp salvato"))
        value)
    ((invalid-read-syntax end-of-file) (gdev-state-db--invalid "Un valore Lisp salvato è illeggibile"))))

(defun gdev-state-db--encode (id value)
  "Prepara righe per VALUE in ordine di visita.
I parametri restano separati dal SQL."
  (let ((number -1) (ancestors (make-hash-table :test #'eq)) rows)
    (cl-labels
        ((visit (item parent position)
           (let ((n (cl-incf number)) kind scalar children)
             (when (gethash item ancestors) (throw 'circular t))
             (cond
              ((null item) (setq kind "nullo"))
              ((and (stringp item) (or (multibyte-string-p item) (not (string-match-p "[^[:ascii:]]" item)))
                    (equal-including-properties item (substring-no-properties item)))
               (setq kind "testo" scalar item))
              ((and (integerp item) (<= (- (expt 2 63)) item (1- (expt 2 63))))
               (setq kind "intero" scalar item))
              ((symbolp item) (setq kind "simbolo" scalar (symbol-name item)))
              ((and (consp item) (proper-list-p item))
               (setq kind "lista" children item))
              ((consp item)
               (setq kind "coppia" children (list (car item) (cdr item))))
              ((vectorp item) (setq kind "vettore" children (append item nil)))
              (t (setq kind "letterale" scalar (gdev-state-db--print item))
                 ;; Un oggetto vivo senza rappresentazione leggibile non è persistibile.
                 (read scalar)))
             (push (list id n parent position kind scalar) rows)
             (when children
               (puthash item t ancestors)
               (cl-loop for child in children for i from 0 do (visit child n i))
               (remhash item ancestors)))))
      (if (catch 'circular (visit value nil 0) nil)
          (list (list id 0 nil 0 "letterale" (gdev-state-db--print value)))
        (nreverse rows)))))

(defun gdev-state-db--put (db scope name value)
  (let ((key (list scope name)))
    (sqlite-execute db "INSERT OR IGNORE INTO impostazione(id_ambito,nome) VALUES(?,?)" key)
    (let* ((id (caar (sqlite-select db "SELECT id FROM impostazione WHERE id_ambito=? AND nome=?" key)))
           (rows (gdev-state-db--encode id value)))
      (sqlite-execute db "DELETE FROM componente WHERE id_impostazione=?" (list id))
      ;; 100 righe per chiamata, anche con il limite storico di 999 parametri.
      (while rows
        (let ((batch (cl-loop repeat 100 while rows collect (pop rows))))
          (sqlite-execute db
                          (concat "INSERT INTO componente VALUES "
                                  (mapconcat (lambda (_) "(?,?,?,?,?,?)") batch ","))
                          (apply #'append batch)))))))

(defun gdev-state-db--decode (rows)
  (let ((nodes (make-hash-table :test #'eql)) root)
    ;; I figli precedono il padre e arrivano dall'ultimo al primo.
    (pcase-dolist (`(,n ,parent ,kind ,scalar) (nreverse rows))
      (let* ((children (gethash n nodes))
             (value (pcase kind
                      ("nullo" nil) ("simbolo" (intern scalar))
                      ((or "testo" "intero") scalar)
                      ("letterale" (gdev-state-db--read-literal scalar)) ("lista" children)
                      ("vettore" (vconcat children))
                      ("coppia" (cons (car children) (cadr children)))
                      (_ (error "Tipo del valore sconosciuto: %s" kind)))))
        (if parent (push value (gethash parent nodes)) (setq root value))))
    root))

(defun gdev-state-db--entries (db scope &optional name)
  (let (entries rows previous)
    (pcase-dolist (`(,key . ,row)
                   (sqlite-select db
                    (concat "SELECT i.nome,c.numero,c.padre,c.tipo,c.valore FROM impostazione i
 JOIN componente c ON c.id_impostazione=i.id WHERE i.id_ambito=?"
                            (when name " AND i.nome=?") " ORDER BY i.nome,c.padre,c.posizione")
                    (if name (list scope name) (list scope))))
      (unless (equal key previous)
        (when previous (push (cons previous (gdev-state-db--decode (nreverse rows))) entries))
        (setq previous key rows nil))
      (push row rows))
    (when previous (push (cons previous (gdev-state-db--decode (nreverse rows))) entries))
    (nreverse entries)))

(defun gdev-state-db-entries (type ref &optional name)
  (gdev-state-db-with (db)
    (gdev-state-db--entries db (gdev-state-db--scope db type ref) name)))

(defun gdev-state-db-set (type ref name value)
  (gdev-state-db-with (db t)
    (gdev-state-db--put db (gdev-state-db--scope db type ref t) name value))
  value)

(defun gdev-state-db--replace (db scope entries)
  (sqlite-execute db "DELETE FROM impostazione WHERE id_ambito=?" (list scope))
  (dolist (entry entries) (gdev-state-db--put db scope (car entry) (cdr entry))))

(defun gdev-state-db--legacy (name)
  (expand-file-name name gdev-state-directory))

(defun gdev-state-db-appearance ()
  (or (cdar (gdev-state-db-entries "applicazione" "" "aspetto"))
      (let ((old (gdev-state-db--legacy "appearance")))
        (when (file-readable-p old)
          (with-temp-buffer
            (insert-file-contents old)
            (gdev-state-db-set "applicazione" "" "aspetto"
                               (if (looking-at "dark") 'dark 'light)))))))

(provide 'gdev-state-db)
;;; gdev-state-db.el ends here
