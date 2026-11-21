;;; gdev-project-types.el --- Riconoscimento dei progetti distribuiti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Le preferenze e i comandi dei linguaggi riconoscono gli stessi manifesti
;; anche prima di aprire il primo documento di quel linguaggio.

;;; Code:

(require 'gdev-lib)
(autoload 'gdev-xcode-container "gdev-xcode")
(defvar gdev-project-language-markers)

(defun gdev-go-project-p (root)
  "Indica se ROOT contiene go.mod."
  (gdev-project-file-exists-p root "go.mod"))

(defun gdev-rust-project-p (root)
  "Indica se ROOT contiene Cargo.toml."
  (gdev-project-file-exists-p root "Cargo.toml"))

(defconst gdev-java-gradle-files '("build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts"))

(defun gdev-java-project-p (root)
  "Indica se ROOT contiene un progetto Maven o Gradle."
  (apply #'gdev-project-file-exists-p root "pom.xml" gdev-java-gradle-files))

(defun gdev-csharp--files (root suffix)
  "Elenca i file con SUFFIX per i progetti .NET in ROOT."
  (directory-files root nil (concat "\\." suffix "\\'")))

(defun gdev-csharp-project-p (root)
  "Indica se ROOT contiene una soluzione o un progetto .NET."
  (gdev-csharp--files root "\\(?:slnx?\\|csproj\\)"))

(defun gdev-zig-project-p (root)
  "Indica se ROOT contiene build.zig."
  (gdev-project-file-exists-p root "build.zig"))

(defun gdev-swift-project-p (root)
  "Indica se ROOT contiene Package.swift."
  (gdev-project-file-exists-p root "Package.swift"))

(defconst gdev-python-project-files
  '("pyproject.toml" "setup.py" "setup.cfg" "pytest.ini" "requirements.txt" "Pipfile")
  "File che identificano la cartella di un progetto Python.")

(defconst gdev-article--marker ".gdev-article")
(defconst gdev-latex--marker ".gdev-latex")
(defconst gdev-project-operations-file ".gdev-project.eld"
  "File di dati con le operazioni condivise del progetto.")

(defconst gdev-project-build-file-markers
  `((cmake "CMakeLists.txt") (meson "meson.build")
    (perl-build "Build.PL") (perl-make "Makefile.PL")
    (deno "deno.json" "deno.jsonc")
    (make "GNUmakefile" "Makefile" "makefile")
    (ninja "build.ninja") (node "package.json")
    (python ,@gdev-python-project-files))
  "Manifesti dei motori distribuiti, in ordine di precedenza.
Il catalogo è condiviso dal riconoscimento e dalla ricerca delle radici.")

(defun gdev-project-javascript-runtime (root)
  "Restituisci il motore JavaScript dichiarato in ROOT, oppure nil.
I manifesti Deno prevalgono su package.json. La scelta non dipende dagli
eseguibili installati: un motore mancante va preparato, non sostituito."
  (cond ((gdev-project-file-exists-p root "deno.json" "deno.jsonc") 'deno)
        ((gdev-project-file-exists-p root "package.json") 'node)))

(defun gdev-project-javascript-root (directory boundary)
  "Trova il pacchetto JavaScript sopra DIRECTORY, entro BOUNDARY.
Senza un manifesto annidato conserva BOUNDARY. Non interroga host remoti."
  (let ((candidate
         (unless (or (file-remote-p directory) (file-remote-p boundary))
           (locate-dominating-file directory #'gdev-project-javascript-runtime))))
    (if (and candidate (or (equal candidate boundary) (file-in-directory-p candidate boundary)))
        (file-name-as-directory (expand-file-name candidate))
      boundary)))

(defun gdev-project-build-marked-p (root)
  "Indica se ROOT dichiara un sistema di progetto conosciuto.
Non richiede un repository Git o il caricamento del linguaggio."
  (and (file-directory-p root)
   (or (file-regular-p (expand-file-name gdev-project-operations-file root))
      (cl-some (lambda (entry) (apply #'gdev-project-file-exists-p root (cdr entry)))
               gdev-project-build-file-markers)
      (cl-some (lambda (entry) (funcall (cadr entry) root))
               gdev-project-language-markers)
      (gdev-xcode-container root)
      (and (file-directory-p (expand-file-name "t" root))
           (file-directory-p (expand-file-name "lib" root)))
      (directory-files root nil "\\.asd\\'" t 1))))

(defun gdev-project-operation-root (directory &optional boundary)
  "Trova il progetto operativo di DIRECTORY nel limite BOUNDARY.
Una radice dichiarata prevale sui sottoalberi. Dentro un repository il
primo sottoprogetto completo racchiude i file di supporto del suo motore.
Senza repository cerca il manifesto più vicino, come una cartella aperta."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (boundary (and boundary (file-name-as-directory (expand-file-name boundary)))))
    (if (and boundary (string-prefix-p boundary directory)
             (gdev-project-build-marked-p boundary))
        boundary
      (let ((current directory) found)
        (while (and current (or (not boundary) (string-prefix-p boundary current)))
          (when (gdev-project-build-marked-p current)
            (setq found current)
            (unless boundary (setq current nil)))
          (when current
            (setq current (unless (or (equal current boundary)
                                     (equal current (file-name-directory (directory-file-name current))))
                            (file-name-directory (directory-file-name current))))))
        (or found boundary directory)))))

(defun gdev-project-operation-context-root (&optional directory boundary)
  "Risolvi il contesto operativo di DIRECTORY.
Rispetta BOUNDARY o il confine del repository."
  (let* ((directory (file-name-as-directory (expand-file-name (or directory (gdev-default-directory)))))
         (project (gdev-project-root directory)))
    (gdev-project-operation-root directory (or boundary (unless (equal directory project) project)))))

(defvar gdev-writing--project-markers
  `((gdev-article . ,gdev-article--marker) (gdev-latex . ,gdev-latex--marker))
  "Associa il tipo di progetto di scrittura al file che ne indica la radice.")

(defun gdev-project-build-system (root python)
  "Riconosci il sistema in ROOT, incluso Python quando PYTHON è attivo."
  (let ((entry (seq-find (lambda (candidate)
                           (and (or python (not (eq (car candidate) 'python)))
                                (apply #'gdev-project-file-exists-p root (cdr candidate))))
                         gdev-project-build-file-markers)))
    (cond ((memq (car entry) '(cmake meson)) (car entry))
        ((gdev-xcode-container root) 'xcode)
        ((and entry (not (eq (car entry) 'python))) (car entry))
        ((directory-files root nil "\\.asd\\'" t 1) 'asdf)
        ((and (file-directory-p (expand-file-name "t" root))
              (file-directory-p (expand-file-name "lib" root)))
         'perl-prove)
        ((and python entry) 'python))))

(defconst gdev-project-language-markers
  '((rust gdev-rust-project-p) (go gdev-go-project-p) (swift gdev-swift-project-p)
    (zig gdev-zig-project-p) (java gdev-java-project-p) (csharp gdev-csharp-project-p)))

(provide 'gdev-project-types)
;;; gdev-project-types.el ends here
