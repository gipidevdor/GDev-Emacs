;;; gdev-trace.el --- Artefatti, tracciabilità e analisi d'impatto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Un artefatto fissa percorso, ruolo e impronta di un file del progetto.
;; Ogni arco va da una dipendenza al suo consumatore: requisito -> sorgente
;; -> prova. Le versioni sono registrazioni distinte, mai riscritture.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-records)
(require 'gdev-graph)

(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))

(defconst gdev-trace-roles '(requirement design source test evidence document configuration))
(defconst gdev-trace-relations '(implements verifies documents derives depends-on))

(defun gdev-trace-root (db root)
  "Controlla che ROOT sia la radice locale del progetto cui appartiene DB."
  (unless (and (stringp root) (file-name-absolute-p root) (not (file-remote-p root))
               (file-directory-p root))
    (gdev-process-refuse "Serve una cartella locale di progetto esistente"))
  (let* ((root (file-name-as-directory (file-truename root)))
         (main (cl-find "main" (sqlite-select db "pragma database_list") :key #'cadr :test #'equal)))
    (unless (and main (file-equal-p (nth 2 main) (gdev-assurance-db-file root)))
      (gdev-process-refuse "L'archivio non appartiene alla radice indicata"))
    root))

(defun gdev-trace-relative-p (path)
  "Restituisci non nil se PATH è un percorso di sorgente relativo e normale."
  (and (stringp path) (< 0 (length path) 4097) (not (file-name-absolute-p path))
       (not (string-match-p "[[:cntrl:]]" path))
       (let ((parts (split-string path "/")))
         (and (not (member (downcase (car parts)) '(".git" ".gdev")))
              (cl-every (lambda (part) (not (member part '("" "." "..")))) parts)))))

(defun gdev-trace-relative (root path)
  "Normalizza PATH dentro ROOT, anche se il file è stato eliminato."
  (gdev-process-check-line "Il percorso" path 4096)
  (when (file-remote-p path) (gdev-process-refuse "Serve un percorso locale"))
  (setq root (file-name-as-directory (file-truename root)))
  (let* ((absolute (expand-file-name path root))
         (normal (expand-file-name (file-name-nondirectory absolute)
                                    (file-truename (file-name-directory absolute))))
         (relative (file-relative-name normal root)))
    (unless (gdev-trace-relative-p relative)
      (gdev-process-refuse "Il percorso deve restare fra i sorgenti del progetto"))
    relative))

(defun gdev-trace-file-sha256 (file)
  "Fissa i byte di FILE; per un collegamento fissa il suo testo, senza seguirlo."
  (if-let* ((target (file-symlink-p file)))
      (gdev-evidence-sha256 target)
    (gdev-evidence-file-sha256 file)))

(defun gdev-trace--artifact-data (_db _tx data)
  "Controlla i dati DATA di un artefatto senza leggere il file corrente."
  (gdev-record-fields data '(path sha256 role label) '(mode))
  (unless (member (alist-get 'mode data) '(nil "file" "symlink"))
    (gdev-process-refuse "Tipo di file dell'artefatto non valido"))
  (unless (gdev-trace-relative-p (alist-get 'path data))
    (gdev-process-refuse "Percorso di artefatto non valido"))
  (unless (and (stringp (alist-get 'sha256 data))
               (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (alist-get 'sha256 data)))
    (gdev-process-refuse "Impronta di artefatto non valida"))
  (unless (member (alist-get 'role data) (mapcar #'symbol-name gdev-trace-roles))
    (gdev-process-refuse "Ruolo di artefatto sconosciuto"))
  (gdev-process-check-line "L'etichetta" (alist-get 'label data) 200))

(defun gdev-trace--link-data (db _tx data)
  "Controlla un arco DATA e i suoi riferimenti in DB."
  (gdev-record-fields data '(from to relation reason))
  (when (equal (alist-get 'from data) (alist-get 'to data))
    (gdev-process-refuse "Un artefatto non dipende da se stesso"))
  (dolist (key '(from to))
    (unless (eq (alist-get 'kind (gdev-record-get db (alist-get key data))) 'artifact)
      (gdev-process-refuse "Il riferimento %s non è un artefatto" (alist-get key data))))
  (unless (member (alist-get 'relation data) (mapcar #'symbol-name gdev-trace-relations))
    (gdev-process-refuse "Relazione di tracciabilità sconosciuta"))
  (gdev-process-check-line "Il motivo" (alist-get 'reason data) 1000))

(gdev-record-register 'artifact #'gdev-trace--artifact-data)
(gdev-record-register 'trace #'gdev-trace--link-data)

(cl-defun gdev-trace-artifact (db tx-id root path role &key label actor actor-kind)
  "Fissa il file PATH di ROOT come artefatto di ROLE nella transazione TX-ID."
  (let* ((root (gdev-trace-root db root))
         (relative (gdev-trace-relative root path))
         (file (expand-file-name relative root)))
    (unless (or (file-symlink-p file)
                (and (file-regular-p file) (file-in-directory-p (file-truename file) root)))
      (gdev-process-refuse "L'artefatto deve essere un file leggibile dentro il progetto"))
    (unless (memq role gdev-trace-roles) (gdev-process-refuse "Ruolo sconosciuto: %S" role))
    (gdev-record-add db tx-id 'artifact
                     `((path . ,relative) (sha256 . ,(gdev-trace-file-sha256 file))
                       (mode . ,(if (file-symlink-p file) "symlink" "file"))
                       (role . ,(symbol-name role))
                       (label . ,(or label (if (> (length relative) 200)
                                              (concat (substring relative 0 199) "…") relative))))
                     :actor actor :actor-kind actor-kind)))

(cl-defun gdev-trace-link (db tx-id from to relation reason &key actor actor-kind)
  "Registra che FROM può influire su TO, con RELATION e REASON."
  (unless (memq relation gdev-trace-relations) (gdev-process-refuse "Relazione sconosciuta"))
  (gdev-record-add db tx-id 'trace
                   `((from . ,from) (to . ,to) (relation . ,(symbol-name relation)) (reason . ,reason))
                   :actor actor :actor-kind actor-kind))

(defun gdev-trace-artifacts (db)
  "Leggi gli artefatti di DB nell'ordine di registrazione."
  (mapcar (lambda (row)
            (append `((ref . ,(alist-get 'ref row)) (transaction . ,(alist-get 'tx_id row)))
                    (gdev-record-data row)))
          (gdev-record-list db nil 'artifact)))

(defun gdev-trace-links (db)
  "Leggi gli archi di DB nell'ordine di registrazione."
  (mapcar (lambda (row) (cons (cons 'ref (alist-get 'ref row)) (gdev-record-data row)))
          (gdev-record-list db nil 'trace)))

(defun gdev-trace-impact (db root &optional paths)
  "Trova gli artefatti influenzati da PATHS o dai file cambiati di ROOT.
Indicizza i percorsi e visita ogni vertice una volta, senza ricorsione.
Esclusi I/O e ordinamento dei percorsi, costo atteso O(A + E + C) per A
artefatti, E relazioni e C percorsi; il fronte di visita occupa O(A)."
  (let* ((root (gdev-trace-root db root))
         (artifacts (gdev-trace-artifacts db))
         (links (gdev-trace-links db))
         (latest (make-hash-table :test #'equal))
         (adjacency (make-hash-table :test #'equal))
         (changed-index (make-hash-table :test #'equal))
         changed seeds)
    (dolist (row artifacts) (puthash (alist-get 'path row) row latest))
    (if paths
        (dolist (path paths)
          (let ((relative (gdev-trace-relative root path)))
            (unless (gethash relative changed-index)
              (puthash relative t changed-index)
              (push relative changed))))
      (maphash
       (lambda (path row)
         (let ((file (expand-file-name path root)))
           (unless (and (if (equal (alist-get 'mode row) "symlink")
                            (file-symlink-p file)
                          (and (not (file-symlink-p file)) (file-regular-p file)
                               (file-in-directory-p (file-truename file) root)))
                        (condition-case nil
                            (equal (alist-get 'sha256 row) (gdev-trace-file-sha256 file))
                          (file-error nil)))
             (puthash path t changed-index)
             (push path changed)))) latest))
    (dolist (link links) (push (alist-get 'to link) (gethash (alist-get 'from link) adjacency)))
    (dolist (row artifacts)
      (when (gethash (alist-get 'path row) changed-index)
        (push (alist-get 'ref row) seeds)))
    (let ((seen (gdev-graph-reachable adjacency seeds)))
      `((changed . ,(vconcat (sort changed #'string-lessp)))
        (affected . ,(vconcat (cl-remove-if-not (lambda (row) (gethash (alist-get 'ref row) seen)) artifacts)))
        (links . ,(vconcat links))))))

(provide 'gdev-trace)
;;; gdev-trace.el ends here
