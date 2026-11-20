;;; gdev-project-types.el --- Riconoscimento dei progetti distribuiti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Le preferenze e i comandi dei linguaggi riconoscono gli stessi manifesti
;; anche prima di aprire il primo documento di quel linguaggio.

;;; Code:

(require 'gdev-lib)
(autoload 'gdev-xcode-container "gdev-xcode")

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
  '("pyproject.toml" "setup.py" "setup.cfg" "pytest.ini")
  "File che identificano la cartella di un progetto Python.")

(defconst gdev-article--marker ".gdev-article")
(defconst gdev-latex--marker ".gdev-latex")

(defvar gdev-writing--project-markers
  `((gdev-article . ,gdev-article--marker) (gdev-latex . ,gdev-latex--marker))
  "Associa il tipo di progetto di scrittura al file che ne indica la radice.")

(defun gdev-project-build-system (root python)
  "Riconosci il sistema in ROOT, incluso Python quando PYTHON è attivo."
  (cond ((gdev-project-file-exists-p root "CMakeLists.txt") 'cmake)
        ((gdev-project-file-exists-p root "meson.build") 'meson)
        ((gdev-xcode-container root) 'xcode)
        ((gdev-project-file-exists-p root "Build.PL") 'perl-build)
        ((gdev-project-file-exists-p root "Makefile.PL") 'perl-make)
        ((gdev-project-file-exists-p root "deno.json" "deno.jsonc") 'deno)
        ((gdev-project-file-exists-p root "GNUmakefile" "Makefile" "makefile") 'make)
        ((gdev-project-file-exists-p root "build.ninja") 'ninja)
        ((gdev-project-file-exists-p root "package.json") 'node)
        ((directory-files root nil "\\.asd\\'" t 1) 'asdf)
        ((and (file-directory-p (expand-file-name "t" root))
              (file-directory-p (expand-file-name "lib" root)))
         'perl-prove)
        ((and python
              (apply #'gdev-project-file-exists-p root gdev-python-project-files))
         'python)))

(defconst gdev-project-language-markers
  '((rust gdev-rust-project-p) (go gdev-go-project-p) (swift gdev-swift-project-p)
    (zig gdev-zig-project-p) (java gdev-java-project-p) (csharp gdev-csharp-project-p)))

(provide 'gdev-project-types)
;;; gdev-project-types.el ends here
