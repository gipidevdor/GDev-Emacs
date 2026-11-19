;;; gdev-assurance-git.el --- Ricevute Git legate al processo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Una firma SSH esterna lega l'autorizzazione all'indice e ai genitori Git.
;; La CI usa il verificatore e le chiavi fidati, mai quelli della proposta.

;;; Code:

(require 'gdev-adoption)
(require 'gdev-assurance)
(require 'gdev-assessment)
(declare-function gdev-procedures--rows "gdev-procedures" (db tx-id &optional run))

(defconst gdev-assurance-git-checker
  (expand-file-name "../bin/gdev-assurance-check"
                    (file-name-directory (or load-file-name (locate-library "gdev-assurance-git")))))

(defun gdev-assurance-git--commit-data (_db _tx data)
  "Controlla DATA di una ricevuta registrata."
  (gdev-record-fields data '(receipt source_digest signer))
  (dolist (key '(receipt source_digest))
    (unless (gdev-adoption--digest-p (alist-get key data)) (gdev-process-refuse "Impronta della ricevuta non valida")))
  (gdev-process-check-line "Il firmatario" (alist-get 'signer data) 200))

(gdev-record-register 'commit #'gdev-assurance-git--commit-data)

(defun gdev-assurance-git-project-problems (db id root tree)
  "Confronta l'istantanea formale di ID con l'albero immutabile TREE.
Le impronte Git e SHA-256 derivano dalla stessa lettura dei byte."
  (when-let* ((snapshot (car (last (gdev-project-snapshots db id)))))
    (let* ((data (gdev-project-read root)) (context (alist-get 'context (gdev-record-data snapshot)))
           (source-p (gdev-project-source-selector data))
           (inventory (gdev-project-source-inventory root data))
           (entries (make-hash-table :test #'equal))
           (latest (make-hash-table :test #'equal))
           (required (mapcar (lambda (row) (plist-get row :procedure))
                             (seq-remove (lambda (row) (eq 'not-applicable (plist-get row :applicability)))
                                         (plist-get data :requirements))))
           (expected (append (alist-get 'inputs context) (append inventory nil))) candidate problems)
      (require 'gdev-procedures)
      (dolist (row (gdev-procedures--rows db id))
        (let* ((finish (gdev-record-data row))
               (start (and (equal "finish" (alist-get 'event finish)) (gdev-record-get db (alist-get 'start finish)))))
          (when start (puthash (alist-get 'id (alist-get 'procedure (gdev-record-data start))) finish latest))))
      (dolist (procedure (delete-dups required))
        (let ((finish (gethash procedure latest)))
          (when (equal "SUCCEEDED" (alist-get 'status finish))
            (seq-doseq (output (alist-get 'outputs finish))
              (unless (string-prefix-p ".gdev/" (alist-get 'path output)) (push output expected))))))
      (unless (and (stringp tree) (string-match-p "\\`[0-9a-f]\\{40,64\\}\\'" tree))
        (gdev-process-refuse "Albero Git non valido"))
      (dolist (entry (split-string (gdev-standard--git-bytes root "ls-tree" "-rz" "--full-tree" tree) "\0" t))
        (when (string-match "\\`\\([0-9]+\\) blob \\([0-9a-f]+\\)\t\\(.+\\)\\'" entry)
          (let ((path (decode-coding-string (match-string 3 entry) 'utf-8-unix)))
            (puthash path (cons (match-string 1 entry) (match-string 2 entry)) entries)
            (when (funcall source-p path) (push path candidate)))))
      (unless (and (equal (sort candidate #'string<) (mapcar (lambda (row) (alist-get 'path row)) (append inventory nil)))
                   (equal (alist-get 'source_digest context)
                          (gdev-evidence-sha256 (decode-coding-string (json-serialize inventory) 'utf-8-unix))))
        (push "Inventario delle sorgenti assente o diverso dalla verifica" problems))
      (cl-labels ((check (row)
                    (let* ((path (alist-get 'path row)) (entry (gethash path entries))
                           (oid (cdr entry)) (expected (alist-get (if (and oid (= (length oid) 64)) 'git_sha256 'git_sha1) row)))
                      (unless (and (equal (car entry) (alist-get 'mode row)) (stringp expected) (equal oid expected))
                        (push path problems))
                      (let ((target (alist-get 'target row)))
                        (when (and target (not (eq target :null))) (check target))))))
        (mapc #'check expected))
      (sort (delete-dups problems) #'string<))))

(cl-defun gdev-assurance-git-sign (db tx-id root repository signer key &key actor actor-kind amend)
  "Firma l'indice di ROOT per TX-ID con KEY e SIGNER nel REPOSITORY.
Non aggiunge file all'indice e non legge il materiale privato della chiave."
  (gdev-process-check-actor actor actor-kind)
  (unless (and (eq actor-kind 'human) (not (memq gdev-process-origin '(agent ci system))))
    (gdev-process-refuse "La firma richiede una persona"))
  (gdev-process-check-line "Il repository" repository 300)
  (gdev-process-check-line "Il firmatario" signer 200)
  (gdev-process-check-line "La chiave" key 4096)
  (let ((root (gdev-trace-root db root)))
    (gdev-assurance-db-transaction
     db (lambda ()
          (when-let* ((problems (gdev-assurance-verify db))) (gdev-process-refuse "%s" (car problems)))
          (let* ((tx (gdev-process-require db tx-id))
                 (authorization (seq-find (lambda (event)
                                            (and (eq (alist-get 'kind event) 'transition)
                                                 (eq (alist-get 'to_state event) 'AUTHORIZED)
                                                 (eq (alist-get 'actor_kind event) 'human)))
                                          (reverse (gdev-process-events db tx-id)))))
            (unless (and authorization (memq (alist-get 'state tx)
                                             '(AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED)))
              (gdev-process-refuse "La transazione non è autorizzata per un commit"))
            (let* ((default-directory root)
                   (snapshot (with-temp-buffer
                               (unless (zerop (apply #'process-file gdev-assurance-git-checker nil t nil "snapshot" "--tree"
                                                    (and amend (list "--amend"))))
                                 (gdev-process-refuse "%s" (buffer-string)))
                               (json-parse-string (buffer-string) :object-type 'alist :array-type 'array)))
                   (tree (alist-get 'tree snapshot))
                   (snapshot (assq-delete-all 'tree snapshot))
                   (assessment (gdev-assessment-run db tx-id))
                   (payload (gdev-record-json
                             `((format . "GES-commit-1") (repository . ,repository)
                               (transaction . ,tx-id) (profile . ,(symbol-name (alist-get 'profile tx)))
                               (state . ,(symbol-name (alist-get 'state tx)))
                               (authorized_by . ,(alist-get 'actor authorization)) (signer . ,signer)
                               (chain_head . ,(alist-get 'chain_head assessment))
                               (controls_digest . ,(alist-get 'controls_digest assessment))
                               ,@snapshot)))
                   (digest (gdev-evidence-sha256 payload))
                   (directory (expand-file-name ".gdev-assurance/receipts/" root))
                   (file (expand-file-name (concat digest ".json") directory))
                   (signature (expand-file-name (concat digest ".sig") directory)))
              (unless (file-in-directory-p (file-truename directory) root)
                (gdev-process-refuse "La cartella delle ricevute esce dal progetto"))
              (when-let* ((result (gdev-assurance-blocking-result assessment)))
                (gdev-process-refuse "Controllo dovuto %s: %s" (alist-get 'control result) (alist-get 'reason result)))
              (when-let* ((problems (gdev-standard-staged-problems db tx-id root tree)))
                (gdev-process-refuse "Gli artefatti verificati non corrispondono all'albero da firmare: %s" problems))
              (when (and (memq (alist-get 'state tx) '(REVIEWING APPROVED BASELINED))
                         (gdev-project-snapshots db tx-id))
                (when-let* ((problems (gdev-assurance-git-project-problems db tx-id root tree)))
                  (gdev-process-refuse "Il progetto verificato non corrisponde all'albero da firmare: %s" problems)))
              (when (or (file-exists-p file) (file-exists-p signature)) (gdev-process-refuse "La ricevuta esiste già"))
              (make-directory directory t)
              (let ((coding-system-for-write 'utf-8-unix)) (write-region payload nil file nil 'silent))
              (condition-case err
                  (progn
                    (with-temp-buffer
                      (unless (zerop (process-file "ssh-keygen" nil t nil "-Y" "sign" "-f" (expand-file-name key)
                                                   "-n" "assurance@gdev-emacs" file))
                        (gdev-process-refuse "Firma annullata o non riuscita: %s" (buffer-string))))
                    (rename-file (concat file ".sig") signature)
                    (gdev-record-add db tx-id 'commit `((receipt . ,digest)
                                                      (source_digest . ,(alist-get 'source_digest snapshot))
                                                      (signer . ,signer)) :actor actor :actor-kind 'human)
                    `((receipt . ,digest) (file . ,file) (signature . ,signature)
                      (trailers . ,(format "GDev-Transaction: %s\nGDev-Receipt: %s" tx-id digest))))
                (error (delete-file file)
                       (when (file-exists-p (concat file ".sig")) (delete-file (concat file ".sig")))
                       (when (file-exists-p signature) (delete-file signature))
                       (signal (car err) (cdr err))))))))))

(provide 'gdev-assurance-git)
;;; gdev-assurance-git.el ends here
