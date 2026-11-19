;;; gdev-xcode.el --- Profili automatici per progetti Xcode -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Legge solo metadati locali. La compilazione e i seguiti usano il motore
;; comune dei profili: nessun programma esterno durante la lettura delle viste.
;;; Code:
(require 'gdev-lib)
(require 'xml)

(defcustom gdev-xcode-build-directory "build/gdev"
  "Cartella dei prodotti Xcode, relativa al progetto."
  :type 'string :group 'gdev)
(defcustom gdev-xcode-destination "platform=macOS"
  "Destinazione Xcode delle operazioni automatiche."
  :type 'string :group 'gdev)

(defun gdev-xcode-container (root)
  "Trova il contenitore Xcode principale di ROOT, senza chiedere percorsi."
  (when (and root (not (file-remote-p root)) (file-directory-p root))
    (let* ((name (file-name-nondirectory (directory-file-name root)))
           (workspaces (seq-filter #'file-directory-p (directory-files root t "\\.xcworkspace\\'")))
           (projects (seq-filter (lambda (file) (file-regular-p (expand-file-name "project.pbxproj" file)))
                                 (directory-files root t "\\.xcodeproj\\'")))
           (candidates (or workspaces projects)))
      (or (seq-find (lambda (file) (equal name (file-name-base file))) candidates)
          (and (= (length candidates) 1) (car candidates))))))

(defun gdev-xcode--node (tree path)
  "Trova in TREE il discendente indicato da PATH."
  (dolist (tag path tree)
    (setq tree (seq-find (lambda (node) (eq (car-safe node) tag)) (cddr tree)))))

(defun gdev-xcode--schemes (container root)
  "Elenca gli schemi condivisi di CONTAINER e dei progetti di ROOT."
  (let ((containers (cons container (seq-filter #'file-directory-p (directory-files root t "\\.xcodeproj\\'"))))
        files)
    (dolist (directory (delete-dups containers))
      (let ((schemes (expand-file-name "xcshareddata/xcschemes/" directory)))
        (when (file-directory-p schemes)
          (setq files (nconc (directory-files schemes t "\\.xcscheme\\'") files)))))
    (sort files #'string<)))

(defun gdev-xcode-profile (root)
  "Produci il profilo locale di ROOT, oppure nil se non è un progetto Xcode.
Schema, prodotto e configurazione derivano dal file di schema. L'uscita
rimane nella cartella di compilazione del progetto."
  (when-let* ((container (gdev-xcode-container root)))
    (let* ((schemes (gdev-xcode--schemes container root))
           (scheme-file (or (seq-find (lambda (file) (equal (file-name-base file) (file-name-base container))) schemes)
                            (and (= (length schemes) 1) (car schemes))))
           (scheme (if scheme-file (file-name-base scheme-file) (file-name-base container)))
           (tree (and scheme-file (car (xml-parse-file scheme-file))))
           (launch (and tree (gdev-xcode--node tree '(LaunchAction))))
           (configuration (or (alist-get 'buildConfiguration (cadr launch)) "Debug"))
           (reference (and launch (gdev-xcode--node launch '(BuildableProductRunnable BuildableReference))))
           (product (alist-get 'BuildableName (cadr reference)))
           (directory (expand-file-name gdev-xcode-build-directory root))
           (products (expand-file-name (concat "Build/Products/" configuration "/") directory))
           (base (list "xcodebuild" (if (string-suffix-p ".xcworkspace" container) "-workspace" "-project")
                       (file-relative-name container root) "-scheme" scheme "-configuration" configuration
                       "-destination" gdev-xcode-destination "-derivedDataPath" (file-local-name directory)))
           (app (and product (expand-file-name product products)))
           (program (and app (if (string-suffix-p ".app" product)
                                 (expand-file-name (concat "Contents/MacOS/" (file-name-sans-extension product)) app)
                               app)))
           (options (list :cwd root :configure (append base '("-resolvePackageDependencies"))
                          :build (append base '("build")) :test (append base '("test")) :clean (append base '("clean")))))
      (unless (file-in-directory-p directory root)
        (user-error "La cartella Xcode deve appartenere al progetto: %s" directory))
      (unless (and (not (file-name-directory configuration))
                   (not (member configuration '("" "." "..")))
                   (string-prefix-p (file-name-as-directory (file-truename directory))
                                    (file-truename products)))
        (user-error "Configurazione Xcode non valida: %s" configuration))
      (when (and product (or (file-name-directory product) (member product '("." "..")) (string-search "\0" product)))
        (user-error "Prodotto Xcode non valido nello schema: %s" product))
      (when program
        (setq options (append options
                              (list :run (if (string-suffix-p ".app" product) (list "open" "-n" app) (list program))
                                    :debug (list :adapter 'lldb :program program)
                                    :build-before '(run debug)))))
      (cons scheme options))))

(provide 'gdev-xcode)
;;; gdev-xcode.el ends here
