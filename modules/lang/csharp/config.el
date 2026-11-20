;;; config.el --- :lang csharp: C# e .NET -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 compila la soluzione o il progetto SDK, F6 esegue dotnet test.
;; C-F5 usa dotnet run. Completamento, rinomina e formattazione passano
;; da csharp-ls. F5 propone netcoredbg se disponibile.

;;; Code:

(require 'gdev-handlers)
(require 'gdev-project-types)
(require 'gdev-language-modes)

(gdev-language-register-tree-sitter 'csharp-mode 'csharp-ts-mode 'c-sharp)

(defun gdev-csharp-command (action root)
  "Scegli un comando dotnet per ACTION in ROOT."
  (pcase action
    ('run (let ((projects (gdev-csharp--files root "csproj")))
            (when projects
              (list "dotnet" "run" "--project"
                    (if (cdr projects)
                        (completing-read "Progetto da avviare: " projects nil t)
                      (car projects))
                    "--"))))
    ((or 'build 'test 'clean)
     (let* ((solutions (gdev-csharp--files root "slnx?"))
            (projects (or solutions (gdev-csharp--files root "csproj")))
            (target (if (cdr projects)
                        (completing-read "Progetto o soluzione: " projects nil t)
                      (car projects))))
       (list "dotnet" (symbol-name action) target)))))

(gdev-set-project-language 'csharp '(csharp-mode csharp-ts-mode)
                           #'gdev-csharp-project-p #'gdev-csharp-command)
(gdev-set-eglot-server '(csharp-mode csharp-ts-mode) '("csharp-ls"))
(gdev-doctor-executable "dotnet" "Installa il kit di sviluppo .NET" 'note)
(gdev-doctor-executable "csharp-ls" "dotnet tool install --global csharp-ls" 'note)
(gdev-doctor-executable "netcoredbg" "Installa NetCoreDbg per .NET" 'note)

;;; config.el ends here
