;;; gdev-adoption.el --- Adozione e recupero con provenienza -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La situazione iniziale non riscrive la storia: una transazione PROPOSED
;; contiene l'inventario e una prova ricostruita. Il recupero conserva l'intero
;; archivio precedente prima di aprirne uno nuovo, con il motivo e le impronte.

;;; Code:

(require 'gdev-trace)
(require 'gdev-controls)

(defun gdev-adoption-git (root &rest arguments)
  "Esegui Git in ROOT con ARGUMENTS, senza shell; restituisci l'output."
  (let ((default-directory root) (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil arguments))
        (gdev-process-refuse "Git: %s" (string-trim (buffer-string))))
      (buffer-string))))

(defun gdev-adoption-inventory (root)
  "Leggi senza scritture il commit e i file tracciati attuali di ROOT."
  (let* ((root (file-name-as-directory (file-truename root)))
         (git-root (string-trim (gdev-adoption-git root "rev-parse" "--show-toplevel"))))
    (unless (file-equal-p root git-root) (gdev-process-refuse "Indica la radice del repository"))
    (let ((paths (split-string (gdev-adoption-git root "ls-files" "-z" "--cached") "\0" t)) files)
      (dolist (path (sort (delete-dups paths) #'string-lessp))
        (unless (gdev-trace-relative-p path) (gdev-process-refuse "File privato o percorso non valido: %s" path))
        (let ((file (expand-file-name path root)))
          (unless (or (file-symlink-p file)
                      (and (file-regular-p file) (file-in-directory-p (file-truename file) root)))
            (gdev-process-refuse "File assente, collegamento o sottomodulo da risolvere: %s" path))
          (push `((path . ,path) (sha256 . ,(gdev-trace-file-sha256 file))
                  (mode . ,(if (file-symlink-p file) "symlink" "file"))) files)))
      `((head . ,(string-trim (gdev-adoption-git root "rev-parse" "--verify" "HEAD")))
        (files . ,(vconcat (nreverse files)))))))

(defun gdev-adoption--digest-p (value)
  "Restituisci non nil per un'impronta SHA-256 VALUE."
  (and (stringp value) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" value)))

(defun gdev-adoption--baseline-data (db tx data)
  "Controlla l'inventario storico DATA di TX in DB."
  (gdev-record-fields data '(version head inventory_digest artifacts))
  (unless (and (equal (alist-get 'version data) 0)
               (stringp (alist-get 'head data))
               (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" (alist-get 'head data))
               (gdev-adoption--digest-p (alist-get 'inventory_digest data))
               (vectorp (alist-get 'artifacts data)))
    (gdev-process-refuse "Inventario iniziale non valido"))
  (let (files refs)
    (seq-doseq (ref (alist-get 'artifacts data))
      (let ((row (gdev-record-get db ref)))
        (unless (and (eq (alist-get 'kind row) 'artifact)
                     (equal (alist-get 'tx_id row) (alist-get 'id tx)) (not (member ref refs)))
          (gdev-process-refuse "Artefatto iniziale non valido: %S" ref))
        (push ref refs)
        (let ((artifact (gdev-record-data row)))
          (push `((path . ,(alist-get 'path artifact)) (sha256 . ,(alist-get 'sha256 artifact))
                  (mode . ,(or (alist-get 'mode artifact) "file"))) files))))
    (unless (equal (alist-get 'inventory_digest data)
                   (gdev-evidence-sha256 (gdev-record-encode
                                         `((head . ,(alist-get 'head data))
                                           (files . ,(vconcat (nreverse files)))))))
      (gdev-process-refuse "L'impronta non corrisponde all'inventario iniziale"))))

(defun gdev-adoption--recovery-data (_db _tx data)
  "Controlla la descrizione storica DATA di un recupero."
  (gdev-record-fields data '(reason backup files))
  (gdev-process-check-line "Il motivo" (alist-get 'reason data) 1000)
  (gdev-process-check-line "La copia conservata" (alist-get 'backup data) 4096)
  (unless (and (vectorp (alist-get 'files data)) (> (length (alist-get 'files data)) 0))
    (gdev-process-refuse "Mancano le impronte dell'archivio conservato"))
  (seq-doseq (file (alist-get 'files data))
    (gdev-record-fields file '(name sha256))
    (unless (and (member (alist-get 'name file) '("assurance.sqlite" "assurance.sqlite-wal" "assurance.sqlite-shm"))
                 (gdev-adoption--digest-p (alist-get 'sha256 file)))
      (gdev-process-refuse "File del recupero non valido"))))

(gdev-record-register 'baseline #'gdev-adoption--baseline-data)
(gdev-record-register 'recovery #'gdev-adoption--recovery-data)

(cl-defun gdev-adoption-adopt (root profile &key actor actor-kind)
  "Adotta ROOT nel PROFILE scelto da una persona ACTOR; non certifica il passato."
  (gdev-process-check-actor actor actor-kind)
  (unless (and (eq actor-kind 'human) (not (memq gdev-process-origin '(agent ci system))))
    (gdev-process-refuse "L'adozione richiede una persona"))
  (unless (memq profile gdev-process-profiles) (gdev-process-refuse "Profilo sconosciuto"))
  (let* ((inventory (gdev-adoption-inventory root))
         (digest (gdev-evidence-sha256 (gdev-record-encode inventory))))
    (gdev-assurance-db-with-open (db root 'write)
      (gdev-assurance-db-transaction
       db (lambda ()
            (when (gdev-record-list db nil 'baseline) (gdev-process-refuse "Il progetto ha già un inventario iniziale"))
            (let ((id (gdev-process-open db :title "Adozione: inventario iniziale" :profile profile
                                         :actor actor :actor-kind 'human)) refs)
              (seq-doseq (file (alist-get 'files inventory))
                (let* ((path (alist-get 'path file))
                       (ref (gdev-trace-artifact db id root path 'source :actor actor :actor-kind 'human)))
                  (unless (equal (alist-get 'sha256 file)
                                 (alist-get 'sha256 (gdev-record-data (gdev-record-get db ref))))
                    (gdev-process-refuse "Il file è cambiato durante l'adozione: %s" path))
                  (push ref refs)))
              (unless (equal inventory (gdev-adoption-inventory root))
                (gdev-process-refuse "I sorgenti o il commit sono cambiati durante l'adozione"))
              (gdev-record-add db id 'baseline
                               `((version . 0) (head . ,(alist-get 'head inventory))
                                 (inventory_digest . ,digest) (artifacts . ,(vconcat (nreverse refs))))
                               :actor actor :actor-kind 'human)
              (gdev-evidence-add db id :kind 'fact :origin 'reconstructed
                                 :description "Inventario iniziale; verifiche pregresse non attestate"
                                 :content (gdev-record-encode inventory) :actor actor :actor-kind 'human)
              id))))))

(cl-defun gdev-adoption-recover (root profile reason &key actor actor-kind)
  "Conserva l'archivio di ROOT e aprine uno nuovo con PROFILE e REASON.
Il chiamante deve fermare gli altri scrittori prima del recupero."
  (gdev-process-check-actor actor actor-kind)
  (unless (and (eq actor-kind 'human) (not (memq gdev-process-origin '(agent ci system))))
    (gdev-process-refuse "Il recupero richiede una persona"))
  (gdev-process-check-line "Il motivo" reason 1000)
  (unless (memq profile gdev-process-profiles) (gdev-process-refuse "Profilo sconosciuto"))
  (let* ((directory (file-name-directory (gdev-assurance-db-file root)))
         (backup (concat (directory-file-name directory) "-recovery-"
                         (format-time-string "%Y%m%dT%H%M%S") "-" (substring (secure-hash 'sha256 (format "%s" (random))) 0 8)))
         files success)
    (dolist (name '("assurance.sqlite" "assurance.sqlite-wal" "assurance.sqlite-shm"))
      (let ((file (expand-file-name name directory)))
        (when (file-exists-p file)
          (when (file-symlink-p file) (gdev-process-refuse "L'archivio da conservare non può essere un collegamento"))
          (push `((name . ,name) (sha256 . ,(gdev-evidence-file-sha256 file))) files))))
    (unless files (gdev-process-refuse "Nessun archivio da recuperare"))
    (rename-file (directory-file-name directory) backup)
    (unwind-protect
        (gdev-assurance-db-with-open (db root 'write)
          (let ((id (gdev-process-open db :title "Recupero controllato dell'archivio" :profile profile
                                       :actor actor :actor-kind 'human)))
            (gdev-record-add db id 'recovery `((reason . ,reason) (backup . ,backup) (files . ,(vconcat (nreverse files))))
                             :actor actor :actor-kind 'human)
            (setq success t)
            id))
      (unless success
        (when (file-directory-p directory) (delete-directory directory t))
        (rename-file backup (directory-file-name directory))))))

(provide 'gdev-adoption)
;;; gdev-adoption.el ends here
