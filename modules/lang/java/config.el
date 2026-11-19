;;; config.el --- :lang java: Java, Maven e Gradle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 compila, F6 esegue i test. Maven e Gradle usano il wrapper del
;; progetto quando eseguibile. C-F5 avvia un sorgente Java singolo
;; oppure un progetto con il passo run di Gradle o exec:java di Maven.
;; JDT LS offre analisi e refactoring. Per F5 con JDT LS serve
;; java-debug-server già configurato nel server.

;;; Code:

(require 'gdev-handlers)
(require 'gdev-language-modes)

(gdev-language-register-tree-sitter 'java-mode 'java-ts-mode 'java)

(defconst gdev-java-gradle-files '("build.gradle" "build.gradle.kts" "settings.gradle" "settings.gradle.kts"))

(defun gdev-java-project-p (root)
  "Indica se ROOT contiene un progetto Maven o Gradle."
  (apply #'gdev-project-file-exists-p root "pom.xml" gdev-java-gradle-files))

(defun gdev-java-command (action root)
  "Scegli Maven o Gradle per ACTION in ROOT."
  (let* ((maven (gdev-project-file-exists-p root "pom.xml"))
         (wrapper (if maven "mvnw" "gradlew"))
         (program (cond ((file-executable-p (expand-file-name wrapper root)) (concat "./" wrapper))
                        (maven "mvn")
                        (t "gradle")))
         (task (pcase action
                 ('build (if maven "package" "assemble"))
                 ('test "test")
                 ('clean "clean")
                 ('run (if maven "exec:java" "run")))))
    (when task (list program task))))

(declare-function gdev-run-file-with "../../tools/build/config")
(defun gdev-java-run (&optional ask-arguments)
  "Avvia il progetto Java o il sorgente aperto."
  (if (gdev-java-project-p (gdev-language-root))
      (gdev-language-run ask-arguments)
    (gdev-run-file-with '("java") ask-arguments)))

(gdev-set-project-language 'java '(java-mode java-ts-mode) #'gdev-java-project-p #'gdev-java-command)
(gdev-set-runner '(java-mode java-ts-mode) :run #'gdev-java-run)
(gdev-set-eglot-server '(java-mode java-ts-mode) '("jdtls"))
(gdev-doctor-executable "java" "Installa un JDK" 'note)
(gdev-doctor-executable "jdtls" "Installa Eclipse JDT Language Server" 'note)

;;; config.el ends here
