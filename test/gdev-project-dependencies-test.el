;;; gdev-project-dependencies-test.el --- Verifiche della vista Dipendenze -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica lettura dei manifesti, ricerca dalle sottocartelle, modifica
;; di una dichiarazione nel buffer e identità della selezione.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-project-dependencies)

(defconst gdev-test-dependencies--package
  "{\n  \"name\": \"prova\",\n  \"dependencies\": { \"react\": \"^18.2.0\", \"zod\": \"3.23.0\" },\n  \"devDependencies\": { \"eslint\": \"~9.1.0\" },\n  \"peerDependencies\": { \"react-dom\": \"*\" }\n}\n")

(defconst gdev-test-dependencies--cargo
  "[package]\nname = \"prova\"\n\n[dependencies]\nserde = { version = \"1.0\", features = [\"derive\"] }\nlocale = { path = \"../locale\" }\n\n[dev-dependencies]\nproptest = \"1.4\"\n\n[target.'cfg(unix)'.dependencies]\nlibc = \"0.2\"\n\n[workspace.dependencies]\ntokio = \"1.38\"\n")

(defconst gdev-test-dependencies--pyproject
  "[project]\nname = \"prova\"\ndependencies = [\"requests>=2.31\", \"rich[jupyter]~=13.0\"]\n\n[project.optional-dependencies]\ndocs = [\"sphinx>=7\"]\n\n[dependency-groups]\ntest = [\"pytest>=8\", {include-group = \"lint\"}]\nlint = [\"ruff\"]\n\n[tool.poetry.dependencies]\npython = \"^3.11\"\nhttpx = \"^0.27\"\n")

(defmacro gdev-test-dependencies--with-project (files &rest body)
  "Crea un progetto Git con FILES, una lista di (NOME . TESTO), ed esegui BODY.
Dentro BODY `root' è la radice del progetto."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev-prova-dipendenze-" t)))
          (buffers (buffer-list)))
     (unwind-protect
         (progn
           (call-process "git" nil nil nil "init" "-q" root)
           (pcase-dolist (`(,name . ,text) ,files)
             (let ((file (expand-file-name name root)))
               (make-directory (file-name-directory file) t)
               (write-region text nil file nil 'silent)))
           ,@body)
       (dolist (buffer (buffer-list))
         (unless (memq buffer buffers)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun gdev-test-dependencies--summary (entries)
  "Riduci ENTRIES a terne (gruppo nome valore)."
  (mapcar (lambda (entry)
            (list (gdev-project-dependencies--entry-group entry)
                  (gdev-project-dependencies--entry-name entry)
                  (gdev-project-dependencies--entry-value entry)))
          entries))

(ert-deftest gdev-test-dependencies-node-groups-follow-the-manifest ()
  "package.json produce un gruppo per sezione con valori modificabili."
  (skip-unless (executable-find "git"))
  (gdev-test-dependencies--with-project `(("package.json" . ,gdev-test-dependencies--package))
    (let ((entries (gdev-project-dependencies--read (expand-file-name "package.json" root))))
      (should (equal (gdev-test-dependencies--summary entries)
                     '(("Produzione" "react" "^18.2.0") ("Produzione" "zod" "3.23.0")
                       ("Sviluppo" "eslint" "~9.1.0") ("Compatibilità" "react-dom" "*"))))
      (if (treesit-language-available-p 'json)
          (should (cl-every #'gdev-project-dependencies--entry-literal entries))
        ;; Senza grammatica la vista legge i valori ma non offre la modifica.
        (should-not (cl-some #'gdev-project-dependencies--entry-literal entries))))))

(ert-deftest gdev-test-dependencies-toml-manifests-keep-groups-and-notes ()
  "Cargo e pyproject distinguono gruppi, bersagli, percorsi e gruppi inclusi."
  (skip-unless (and (executable-find "git") (treesit-language-available-p 'toml)))
  (gdev-test-dependencies--with-project `(("Cargo.toml" . ,gdev-test-dependencies--cargo)
                                          ("pyproject.toml" . ,gdev-test-dependencies--pyproject))
    (let ((cargo (gdev-test-dependencies--summary
                  (gdev-project-dependencies--read (expand-file-name "Cargo.toml" root))))
          (python (gdev-project-dependencies--read (expand-file-name "pyproject.toml" root))))
      (should (equal cargo '(("Produzione" "serde" "1.0")
                             ("Produzione" "locale" "Percorso · ../locale")
                             ("Sviluppo" "proptest" "1.4")
                             ("Produzione · cfg(unix)" "libc" "0.2")
                             ("Produzione · Spazio Cargo" "tokio" "1.38"))))
      (should (equal (gdev-test-dependencies--summary python)
                     '(("Produzione" "requests" "requests>=2.31")
                       ("Produzione" "rich" "rich[jupyter]~=13.0")
                       ("Facoltative · docs" "sphinx" "sphinx>=7")
                       ("Gruppo · test" "pytest" "pytest>=8")
                       ("Gruppo · test" "lint" "Includi gruppo")
                       ("Gruppo · lint" "ruff" "ruff")
                       ("Produzione · Poetry" "httpx" "^0.27"))))
      ;; Un gruppo incluso non ha un letterale da modificare.
      (should-not (gdev-project-dependencies--entry-literal (nth 4 python))))))

(ert-deftest gdev-test-dependencies-finds-manifests-from-a-subfolder ()
  "Dalla sottocartella la vista risale fino alla radice senza scandire l'albero."
  (skip-unless (executable-find "git"))
  (gdev-test-dependencies--with-project `(("package.json" . ,gdev-test-dependencies--package)
                                          ("pacchetti/web/package.json" . ,gdev-test-dependencies--package)
                                          ("altro/package.json" . ,gdev-test-dependencies--package))
    (let ((found (gdev-project-dependencies--paths (expand-file-name "pacchetti/web/src/" root))))
      (should (equal (mapcar (lambda (file) (file-relative-name file root)) found)
                     '("pacchetti/web/package.json" "package.json"))))))

(ert-deftest gdev-test-dependencies-edit-changes-only-the-buffer-and-keeps-selection ()
  "La modifica riguarda il solo letterale, non salva e conserva la riga scelta."
  (skip-unless (and (executable-find "git") (treesit-language-available-p 'json)))
  (gdev-test-dependencies--with-project `(("package.json" . ,gdev-test-dependencies--package))
    (gdev-test--with-layout
      (let* ((manifest (expand-file-name "package.json" root))
             (view (progn (find-file manifest)
                          (gdev-project-dependencies-show)
                          (current-buffer))))
        (should (eq major-mode 'gdev-project-dependencies-mode))
        (should (string-search "Produzione" (buffer-string)))
        (goto-char (point-min))
        (goto-char (1- (search-forward "^18.2.0")))
        (should (eq (car (get-text-property (point) 'gdev-dependencies-focus)) 'edit))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "^19.0.0")))
          (gdev-project-dependencies-edit))
        (with-current-buffer view
          (should (string-search "^19.0.0" (buffer-string)))
          (should (equal (get-text-property (point) 'gdev-dependencies-focus)
                         '(edit "Produzione" "react"))))
        (with-current-buffer (find-buffer-visiting manifest)
          (should (buffer-modified-p))
          (should (string-search "\"react\": \"^19.0.0\"" (buffer-string)))
          (should (string-search "\"zod\": \"3.23.0\"" (buffer-string))))
        (should (string-search "^18.2.0" (with-temp-buffer
                                           (insert-file-contents manifest)
                                           (buffer-string))))))))

(ert-deftest gdev-test-dependencies-edit-refuses-a-stale-declaration ()
  "Se la dichiarazione è cambiata dopo la lettura, la vista non la sovrascrive."
  (skip-unless (executable-find "git"))
  (gdev-test-dependencies--with-project `(("package.json" . ,gdev-test-dependencies--package))
    (gdev-test--with-layout
      (let ((manifest (expand-file-name "package.json" root)))
        (find-file manifest)
        (gdev-project-dependencies-show)
        (let ((entry (seq-find (lambda (entry)
                                 (equal "react" (gdev-project-dependencies--entry-name entry)))
                               gdev-project-dependencies--entries)))
          (with-current-buffer (find-buffer-visiting manifest)
            (goto-char (point-min))
            (search-forward "^18.2.0")
            (replace-match "^18.3.0" t t))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "^19.0.0")))
            (should-error (gdev-project-dependencies--edit entry) :type 'user-error))
          (with-current-buffer (find-buffer-visiting manifest)
            (should (string-search "^18.3.0" (buffer-string)))
            (should-not (string-search "^19.0.0" (buffer-string)))))))))

(provide 'gdev-project-dependencies-test)
;;; gdev-project-dependencies-test.el ends here
