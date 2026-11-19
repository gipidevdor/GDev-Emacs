;;; gdev-documents.el --- Documenti riproducibili da fonti versionate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Sedici tipi editoriali GDev, senza attribuzioni a schemi normativi.
;; Org è riportato come sorgente, senza esportazione, Babel, INCLUDE o BIND.
;; Non si inseriscono date o dati locali: --check confronta gli stessi byte.

;;; Code:

(require 'gdev-trace)
(require 'gdev-standards)

(defconst gdev-documents-types
  '((plan . "Piano di sviluppo") (requirements . "Requisiti")
    (architecture . "Architettura") (design . "Progettazione")
    (risk . "Analisi dei rischi") (security . "Sicurezza")
    (verification-plan . "Piano di verifica") (validation-plan . "Piano di validazione")
    (test-report . "Rapporto delle prove") (review . "Revisione")
    (traceability . "Tracciabilità") (configuration . "Configurazione")
    (change-log . "Registro delle modifiche") (release . "Rilascio")
    (maintenance . "Manutenzione") (adoption . "Adozione"))
  "Tipi editoriali originali di GDev: non sono documenti imposti da uno standard.")

(defconst gdev-documents-manifest ".gdev-assurance/documents.eld")
(defconst gdev-documents-output "docs/assicurazione/generati/")

(defun gdev-documents--destination (destination source target)
  "Rendi DESTINATION di SOURCE raggiungibile dal documento TARGET."
  (let* ((angle (string-prefix-p "<" destination))
         (path (if angle (substring destination 1 -1) destination)))
    (if (or (string-prefix-p "#" path) (string-prefix-p "/" path)
            (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" path))
        destination
      (let ((relative (file-relative-name (expand-file-name path (file-name-directory source))
                                         (file-name-directory target))))
        (if angle (concat "<" relative ">") relative)))))

(defun gdev-documents--markdown (content source target)
  "Rendi i collegamenti Markdown di CONTENT relativi da SOURCE a TARGET.
Conserva i blocchi di codice e i collegamenti assoluti o esterni."
  (let (fence)
    (mapconcat
     (lambda (line)
       (if (string-match "\\`[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)" line)
           (progn
             (let ((run (match-string 1 line)))
               (cond ((null fence) (setq fence run))
                     ((and (eq (aref run 0) (aref fence 0)) (>= (length run) (length fence)))
                      (setq fence nil))))
             line)
         (if fence line
           (with-temp-buffer
             (insert line)
             (dolist (rule '(("\\](\\(<[^>]+>\\|[^ \t()]+\\)" . 1)
                             ("\\`[ \t]*\\[[^]]+\\]:[ \t]*\\(<[^>]+>\\|[^ \t]+\\)" . 1)))
               (goto-char (point-min))
               (while (re-search-forward (car rule) nil t)
                 (let ((replacement (save-match-data
                                      (gdev-documents--destination (match-string (cdr rule)) source target))))
                   (replace-match replacement t t nil (cdr rule)))))
             (buffer-string)))))
     (split-string content "\n") "\n")))

(defun gdev-documents--file (root path)
  "Risolvi PATH in ROOT, rifiutando collegamenti fuori dal progetto."
  (unless (gdev-trace-relative-p path) (gdev-process-refuse "Percorso di documento non valido: %S" path))
  (let ((file (expand-file-name path root)))
    (unless (file-in-directory-p (file-truename file) root)
      (gdev-process-refuse "Il documento esce dal progetto: %s" path))
    file))

(defun gdev-documents--manifest (root)
  "Leggi e controlla il manifesto dei documenti di ROOT."
  (let ((data (gdev-standards-read (gdev-documents--file root gdev-documents-manifest))) ids)
    (unless (and (plistp data) (eq (plist-get data :version) 1)
                 (proper-list-p (plist-get data :documents)))
      (gdev-process-refuse "Manifesto dei documenti non valido"))
    (dolist (row (plist-get data :documents))
      (unless (and (plistp row) (assq (plist-get row :id) gdev-documents-types)
                   (not (memq (plist-get row :id) ids))
                   (proper-list-p (plist-get row :sources)))
        (gdev-process-refuse "Tipo di documento non valido o duplicato"))
      (push (plist-get row :id) ids)
      (dolist (path (plist-get row :sources))
        (unless (and (gdev-trace-relative-p path)
                     (member (file-name-extension path) '("md" "org" "eld"))
                     (not (string-prefix-p gdev-documents-output path)))
          (gdev-process-refuse "Fonte non valida o circolare: %S" path))))
    data))

(defun gdev-documents-render (root)
  "Restituisci i sedici (PERCORSO . CONTENUTO) di ROOT senza scrivere."
  (let* ((root (file-name-as-directory (file-truename root)))
         (manifest (gdev-documents--manifest root))
         (manifest-sha (gdev-evidence-file-sha256 (gdev-documents--file root gdev-documents-manifest)))
         result)
    (dolist (type gdev-documents-types)
      (let* ((id (car type))
             (target (expand-file-name (concat gdev-documents-output (symbol-name id) ".md") root))
             (row (seq-find (lambda (item) (eq id (plist-get item :id))) (plist-get manifest :documents)))
             sources contents)
        (dolist (path (plist-get row :sources))
          (let* ((file (gdev-documents--file root path))
                 (hash (gdev-evidence-file-sha256 file))
                 (content (with-temp-buffer
                            (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
                            (buffer-string))))
            (push `((path . ,path) (sha256 . ,hash)) sources)
            (push (concat "## Fonte: " path "\n\n"
                          (if (equal (file-name-extension path) "md") (gdev-documents--markdown content file target)
                            (let* ((runs (split-string content "[^`]+" t))
                                   (width (1+ (apply #'max 2 (mapcar #'length runs))))
                                   (fence (make-string width ?`)))
                              (concat fence (file-name-extension path) "\n" content
                                      (unless (string-suffix-p "\n" content) "\n") fence)))
                          "\n\n") contents)))
        (let ((digest (gdev-evidence-sha256
                       (gdev-record-json `((generator . "GES-documents-3") (type . ,(symbol-name id))
                                           (manifest . ,manifest-sha) (sources . ,(vconcat (nreverse sources))))))))
          (push (cons (concat gdev-documents-output (symbol-name id) ".md")
                      (replace-regexp-in-string "\n+\\'" "\n"
                       (concat "<!-- Generato da GDev; non modificare. Fonti sha256:" digest " -->\n\n"
                              "# " (cdr type) "\n\n"
                              (if contents (apply #'concat (nreverse contents))
                                "Stato: NOT_VERIFIED. Nessuna fonte dichiarata nel manifesto.\n")))) result))))
    (nreverse result)))

(defun gdev-documents-generate (root &optional check)
  "Genera i documenti di ROOT; con CHECK restituisci i percorsi diversi senza
scrivere.  Un file già presente privo dell'intestazione GDev non si
sovrascrive."
  (let* ((root (file-name-as-directory (file-truename root)))
         (rendered (gdev-documents-render root)) differences)
    ;; Controlla tutti i bersagli prima di iniziare a scrivere.
    (dolist (row rendered)
      (let* ((file (gdev-documents--file root (car row)))
             (old (when (file-exists-p file)
                    (with-temp-buffer (insert-file-contents file) (buffer-string)))))
        (when (and old (not (string-prefix-p "<!-- Generato da GDev; non modificare. Fonti sha256:" old)))
          (gdev-process-refuse "Il file contiene dati dell'utente: %s" (car row)))
        (unless (equal old (cdr row)) (push (car row) differences))))
    (unless check
      (dolist (row rendered)
        (when (member (car row) differences)
          (let ((file (gdev-documents--file root (car row))) (coding-system-for-write 'utf-8-unix))
            (make-directory (file-name-directory file) t)
            (write-region (cdr row) nil file nil 'silent)))))
    (nreverse differences)))

(provide 'gdev-documents)
;;; gdev-documents.el ends here
