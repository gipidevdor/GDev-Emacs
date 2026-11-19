;;; gdev-project-templates.el --- Modelli parametrizzati senza esecuzione -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Anteprima e scrittura condividono la stessa espansione letterale.
;; Non si interpretano Lisp, comandi, variabili d'ambiente o espressioni.
;;; Code:
(require 'gdev-project)
(require 'pp)

(defun gdev-project-snippet-arguments (text)
  "Leggi TEXT come un oggetto JSON di parametri, senza chiavi duplicate."
  (let ((json-object-type 'alist) (json-array-type 'vector) (json-key-type 'string))
    (with-temp-buffer
      (insert text) (goto-char (point-min))
      (unless (looking-at-p "[ \t\n\r]*{") (gdev-process-refuse "I parametri devono essere un oggetto JSON"))
      (let ((arguments (json-read)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp) (gdev-process-refuse "Dati dopo i parametri del modello"))
        (unless (and (listp arguments)
                     (cl-every (lambda (row) (and (stringp (car row)) (stringp (cdr row)))) arguments)
                     (= (length arguments) (length (delete-dups (mapcar #'car arguments)))))
          (gdev-process-refuse "Parametri non testuali o duplicati"))
        arguments))))

(defun gdev-project-snippet-preview (root id arguments)
  "Espandi lo snippet ID di ROOT con ARGUMENTS, alist di testi, senza scrivere."
  (let* ((project (gdev-project-read root))
         (snippet (or (seq-find (lambda (row) (equal id (plist-get row :id))) (plist-get project :snippets))
                      (gdev-process-refuse "Modello sconosciuto: %s" id)))
         (parameters (plist-get snippet :parameters)) values raw-values)
    (unless (and (proper-list-p arguments)
                 (cl-every (lambda (pair) (and (consp pair) (stringp (car pair)) (stringp (cdr pair)))) arguments)
                 (= (length arguments) (length (delete-dups (mapcar #'car arguments)))))
      (gdev-process-refuse "Parametri del modello non validi o duplicati"))
    (dolist (pair arguments)
      (unless (seq-find (lambda (parameter) (equal (car pair) (plist-get parameter :name))) parameters)
        (gdev-process-refuse "Parametro sconosciuto: %s" (car pair))))
    (dolist (parameter parameters)
      (let* ((name (plist-get parameter :name)) (supplied (assoc name arguments))
             (value (if supplied (cdr supplied) (or (plist-get parameter :default) ""))))
        (when (and (plist-get parameter :required) (not (gdev-project--text-p value)))
          (gdev-process-refuse "Compila il parametro %s: %s" name (plist-get parameter :reason)))
        (push (cons name value) raw-values)
        (setq value
              (pcase (plist-get parameter :type)
                ('symbol
                 (unless (and (string-match-p "\\`[[:alpha:]_][[:alnum:]_+*/<>=!?-]*\\'" value)
                              (not (member value '("nil" "t"))))
                   (gdev-process-refuse "Il parametro %s deve essere un nome Lisp valido" name)) value)
                ('string (let ((print-escape-newlines t) (print-escape-control-characters t))
                           (substring (prin1-to-string (substring-no-properties value)) 1 -1)))
                (_ value)))
        (push (cons name value) values)))
    (let* ((path (plist-get snippet :template)) (file (gdev-project-file root path))
           (text (with-temp-buffer (insert-file-contents file) (buffer-string)))
           (content (replace-regexp-in-string
                     "{{\\([A-Za-z0-9_.-]+\\)}}"
                     (lambda (token)
                       (let ((value (assoc (substring token 2 -2) values)))
                         (unless value (gdev-process-refuse "Parametro del modello non dichiarato: %s" token))
                         (cdr value))) text t t)))
      `((snippet . ,id) (version . ,(plist-get snippet :version)) (template . ,path)
        (template_sha256 . ,(gdev-evidence-file-sha256 file))
        (parameters . ,(vconcat (mapcar (lambda (value) `((name . ,(car value)) (value . ,(cdr value)))) (reverse raw-values))))
        (content . ,content) (sha256 . ,(gdev-evidence-sha256 content)) (status . "PREVIEW")))))

(defun gdev-project-write-file (root path content &optional expected)
  "Scrivi CONTENT in PATH di ROOT, controllando l'impronta EXPECTED.
Senza EXPECTED crea soltanto un file nuovo o conserva contenuto identico.
La sostituzione usa un file temporaneo nella stessa cartella e rename."
  (let* ((file (gdev-project-file root path))
         (current (and (file-exists-p file) (gdev-evidence-file-sha256 file)))
         (bytes (encode-coding-string content 'utf-8-unix))
         (digest (secure-hash 'sha256 bytes)))
    (when-let* ((buffer (find-buffer-visiting file)))
      (when (buffer-modified-p buffer)
        (gdev-process-refuse "Salva o annulla le modifiche aperte in %s prima di proseguire" path)))
    (when (file-locked-p file)
      (gdev-process-refuse "Il file %s è in modifica in un altro contesto" path))
    (cond
     ((equal current digest) digest)
     ((if expected (not (equal current expected)) current)
      (gdev-process-refuse "Conflitto: il file %s esiste o è cambiato; riesamina il contenuto" path))
     (t
      (make-directory (file-name-directory file) t)
      (let ((create-lockfiles t) temporary modes)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'ask-user-about-lock)
                         (lambda (&rest _) (gdev-process-refuse "Il file %s è occupato" path))))
                (lock-file file))
              (setq modes (and (file-exists-p file) (file-modes file)))
              (setq temporary (make-temp-file (expand-file-name ".gdev-write-" (file-name-directory file))))
              (with-temp-buffer
                (set-buffer-multibyte nil) (insert bytes)
                (let ((coding-system-for-write 'no-conversion)) (write-region (point-min) (point-max) temporary nil 'silent)))
              (when modes (set-file-modes temporary modes))
              (unless (and (equal current (and (file-exists-p file) (gdev-evidence-file-sha256 file)))
                           (equal modes (and (file-exists-p file) (file-modes file))))
                (gdev-process-refuse "Il file è cambiato durante la preparazione: %s" path))
              (rename-file temporary file (and expected t))
              digest)
          (when (and temporary (file-exists-p temporary)) (delete-file temporary))
          (unlock-file file)))))))

(defun gdev-project-snippet-write (root id arguments path &optional expected)
  "Materializza ID con ARGUMENTS in PATH di ROOT dopo l'anteprima.
EXPECTED autorizza soltanto la sostituzione della versione esaminata."
  (let ((preview (copy-tree (gdev-project-snippet-preview root id arguments))))
    (gdev-project-write-file root path (alist-get 'content preview) expected)
    (setf (alist-get 'status preview) "MATERIALIZED" (alist-get 'path preview) path)
    (assq-delete-all 'content preview)))

(defun gdev-project-add-requirement (root id arguments expected)
  "Aggiungi un requisito proposto ID da ARGUMENTS al manifesto EXPECTED."
  (let* ((data (gdev-project-read root))
         (keys '("statement" "acceptance" "owner" "origin" "rationale" "source" "tests" "method" "procedure")))
    (dolist (pair arguments)
      (unless (member (car pair) keys) (gdev-process-refuse "Campo del requisito sconosciuto: %s" (car pair))))
    (dolist (key keys)
      (unless (gdev-project--text-p (cdr (assoc key arguments))) (gdev-process-refuse "Compila %s" key)))
    (let ((row (list :id id :version 1 :statement (cdr (assoc "statement" arguments))
                     :acceptance (cdr (assoc "acceptance" arguments)) :owner (cdr (assoc "owner" arguments))
                     :origin (cdr (assoc "origin" arguments)) :rationale (cdr (assoc "rationale" arguments))
                     :sources (list (cdr (assoc "source" arguments)))
                     :tests (split-string (cdr (assoc "tests" arguments)) "," t "[ \t\n]+")
                     :method (intern (cdr (assoc "method" arguments))) :procedure (cdr (assoc "procedure" arguments))
                     :category 'functional :priority 'must :criticality 'normal :status 'proposed :applicability 'proposed)))
      (setq data (plist-put data :requirements (append (plist-get data :requirements) (list row)))))
    (gdev-project-validate data)
    (gdev-project-write-file root gdev-project-manifest (pp-to-string data) expected)
    (gdev-project-data root)))

(defun gdev-project-initialize (root id name)
  "Crea in ROOT una bozza ID NAME e i cataloghi distribuiti, senza sovrascrivere."
  (let* ((directory (expand-file-name "../templates/assurance/" (file-name-directory (locate-library "gdev-project"))))
         (catalog (gdev-standards-read (expand-file-name "catalog.eld" directory)))
         (data (append (gdev-project-default id name)
                       (list :purpose nil :scope nil :owner nil :context nil))) files)
    (dolist (key '(:procedures :snippets :artifacts)) (setq data (plist-put data key (plist-get catalog key))))
    (setq data (plist-put data :standards
                         (list (list :id "nist-sp-800-218" :edition "1.1" :applicability 'proposed
                                     :decision 'proposed :scope 'indexed
                                     :reason "Default proposto: pratiche pubbliche SSDF; esaminare l'applicabilità al progetto."))))
    (dolist (path (directory-files-recursively directory "\\.\\(?:tmpl\\|lavorazione\\)\\'"))
      (push (cons (concat ".gdev-assurance/" (file-relative-name path directory))
                  (with-temp-buffer (insert-file-contents path) (buffer-string))) files))
    (gdev-project-validate data)
    (let ((print-length nil) (print-level nil))
      (setq files (append (nreverse files) (list (cons gdev-project-manifest (concat ";; -*- lisp-data -*-\n" (pp-to-string data)))))))
    ;; Tutti i conflitti vengono rilevati prima della prima scrittura.
    (dolist (entry files)
      (let ((file (gdev-project-file root (car entry))))
        (when (and (file-exists-p file) (not (equal (gdev-evidence-file-sha256 file) (gdev-evidence-sha256 (cdr entry)))))
          (gdev-process-refuse "Il file contiene già dati: %s" (car entry)))))
    (dolist (entry files) (gdev-project-write-file root (car entry) (cdr entry)))
    (gdev-project-data root)))

(provide 'gdev-project-templates)
;;; gdev-project-templates.el ends here
