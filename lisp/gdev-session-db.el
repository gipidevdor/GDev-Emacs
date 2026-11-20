;;; gdev-session-db.el --- Archivio relazionale degli spazi di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La rotazione della sessione interrotta e la nuova istantanea hanno lo
;; stesso commit. Un identificativo distingue anche due schede omonime.

;;; Code:

(require 'gdev-scoped-options)

(defconst gdev-session-db--fields
  '((:project . "progetto") (:root . "radice") (:folder . "cartella_attiva")
    (:explorer-visible . "esplora_visibile") (:explorer-width . "larghezza_esplora")
    (:activity . "attivita") (:explorer-hidden . "esplora_nascosto")
    (:commands-visibility . "visibilita_comandi") (:commands-width . "larghezza_comandi")
    (:commands-category . "categoria_comandi") (:launch-selections . "profili_avvio")
    (:minimap . "minimappa") (:panel . "pannello") (:windows . "riquadri")))

(defun gdev-session-db--row (db name)
  (car (sqlite-select db (concat "SELECT id,spazio_attivo,id_ambito FROM sessione WHERE " (if (integerp name) "id=?" "nome=?")) (list name))))

(defun gdev-session-db-exists-p (&optional name)
  (gdev-state-db-with (db) (gdev-session-db--row db (or name "corrente"))))

(defun gdev-session-db--ref (key)
  (pcase key
    ((pred stringp) (list "file" key))
    (`(bozza ,(and (pred stringp) name)) (list "bozza" name))
    (_ (error "Riferimento a documento non valido: %S" key))))

(defun gdev-session-db--key (kind name)
  (if (equal kind "bozza") (list 'bozza name) name))

(defun gdev-session-db--write-tab (db session position record)
  (sqlite-execute db "INSERT INTO ambito(tipo) VALUES('spazio')")
  (let ((scope (caar (sqlite-select db "SELECT last_insert_rowid()"))))
    (sqlite-execute db "INSERT INTO spazio(id_sessione,posizione,nome,id_ambito) VALUES(?,?,?,?)"
                    (list session position (plist-get record :name) scope))
    (let ((id (caar (sqlite-select db "SELECT last_insert_rowid()"))))
      (cl-loop for folder in (plist-get record :folders) for n from 0 do
               (sqlite-execute db "INSERT INTO cartella_spazio VALUES(?,?,?)" (list id n folder)))
      (cl-loop for file in (plist-get record :files) for n from 0 do
               (sqlite-execute db "INSERT INTO documento_spazio VALUES(?,?,?,?)"
                               (append (list id n) (gdev-session-db--ref file))))
      (dolist (field gdev-session-db--fields)
        (when (plist-member record (car field))
          (gdev-state-db--put db scope (cdr field) (plist-get record (car field))))))))

(defun gdev-session-db-save (snapshot name &optional protect expected)
  "Sostituisci NAME con SNAPSHOT.
Con PROTECT conserva anche la sessione non ripresa."
  (gdev-state-db-with (db t)
    (when (and (equal name "corrente")
               (or protect (and expected (not (equal expected (car (gdev-session-db--row db name))))))
               (gdev-session-db--row db name))
      (sqlite-execute db "UPDATE sessione SET nome='recupero-' || id WHERE nome='interrotta'")
      (sqlite-execute db "UPDATE sessione SET nome='interrotta' WHERE nome=?" (list name)))
    (sqlite-execute db "DELETE FROM sessione WHERE nome=?" (list name))
    (sqlite-execute db "INSERT INTO ambito(tipo) VALUES('istantanea_sessione')")
    (let ((scope (caar (sqlite-select db "SELECT last_insert_rowid()"))))
      (gdev-state-db--replace db scope (gdev-scoped-options-session))
      (sqlite-execute db "INSERT INTO sessione(nome,spazio_attivo,id_ambito) VALUES(?,?,?)"
                      (list name (or (plist-get snapshot :active) 0) scope)))
    (let ((id (caar (sqlite-select db "SELECT last_insert_rowid()"))))
      (cl-loop for tab in (plist-get snapshot :tabs) for n from 0 do
               (gdev-session-db--write-tab db id n tab))
      (pcase-dolist (`(,key . ,draft) (plist-get snapshot :drafts))
        (sqlite-execute db "INSERT INTO bozza VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id_sessione,tipo,riferimento) DO NOTHING"
                        (append (list id) (gdev-session-db--ref key)
                                (list (plist-get draft :name) (when-let* ((mode (plist-get draft :mode))) (symbol-name mode))
                                      (plist-get draft :directory) (plist-get draft :file)
                                      (gdev-state-db--print (plist-get draft :modtime))
                                      (if (plist-get draft :modified) 1 0)
                                      (if (plist-get draft :base64) 1 0) (plist-get draft :text)))))
      id)))

(defun gdev-session-db-resume (snapshot promote)
  "Conferma le preferenze di SNAPSHOT e, con PROMOTE, rendilo corrente."
  (let ((id (plist-get snapshot :generazione))
        (entries (plist-get snapshot :preferenze)))
    (gdev-state-db-with (db t)
      (unless (gdev-session-db--row db id) (user-error "La sessione è cambiata. Ripeti il ripristino"))
      (when promote
        (sqlite-execute db "UPDATE sessione SET nome='recupero-' || id WHERE nome='corrente' AND id!=?" (list id))
        (sqlite-execute db "UPDATE sessione SET nome='corrente' WHERE id=?" (list id)))
      (gdev-scoped-options--write-session db entries))
    (setq gdev-scoped-options--profile (gdev-state-db-file)
          gdev-scoped-options--session entries)
    id))

(defun gdev-session-db--read-tab (db row)
  (pcase-let ((`(,id ,name ,scope) row))
    (let ((tab (list :name name :folders
                     (mapcar #'car (sqlite-select db "SELECT percorso FROM cartella_spazio WHERE id_spazio=? ORDER BY posizione" (list id)))
                     :files
                     (mapcar (lambda (pair) (apply #'gdev-session-db--key pair))
                             (sqlite-select db "SELECT tipo,riferimento FROM documento_spazio WHERE id_spazio=? ORDER BY posizione" (list id))))))
      (dolist (entry (gdev-state-db--entries db scope))
        (setq tab (plist-put tab (car (rassoc (car entry) gdev-session-db--fields)) (cdr entry))))
      tab)))

(defun gdev-session-db-read (name)
  (gdev-state-db-with (db)
    (when-let* ((row (gdev-session-db--row db name))
                (key (list (car row))))
      (list :version 1 :generazione (car row) :active (cadr row) :preferenze (gdev-state-db--entries db (nth 2 row))
            :tabs (mapcar (lambda (tab) (gdev-session-db--read-tab db tab))
                          (sqlite-select db "SELECT id,nome,id_ambito FROM spazio WHERE id_sessione=? ORDER BY posizione" key))
            :drafts (cl-loop for (kind ref title mode folder file date modified binary content)
                             in (sqlite-select db "SELECT tipo,riferimento,nome,modalita,cartella,percorso,data_modifica,modificata,binaria,testo FROM bozza WHERE id_sessione=? ORDER BY tipo,riferimento" key)
                             collect (cons (gdev-session-db--key kind ref)
                                           (list :name title :mode (and mode (intern mode)) :directory folder
                                                 :file file :modtime (and date (gdev-state-db--read-literal date)) :modified (= modified 1)
                                                 :base64 (= binary 1) :text content)))))))

(provide 'gdev-session-db)
;;; gdev-session-db.el ends here
