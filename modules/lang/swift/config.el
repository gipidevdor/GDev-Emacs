;;; config.el --- :lang swift: Swift e Swift Package Manager -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 compila il pacchetto, F6 esegue swift test e C-F5 avvia swift run.
;; Usa SourceKit-LSP dalla catena di strumenti Swift e il formattatore
;; integrato nel comando swift. F5 apre un binario compilato in LLDB.

;;; Code:

(require 'gdev-handlers)

(use-package swift-mode
  :ensure t
  :mode "\\.swift\\'")

(defun gdev-swift-project-p (root)
  "Indica se ROOT contiene Package.swift."
  (gdev-project-file-exists-p root "Package.swift"))

(defun gdev-swift-command (action _root)
  "Scegli il comando Swift per ACTION."
  (pcase action
    ('build '("swift" "build"))
    ('test '("swift" "test"))
    ('run '("swift" "run"))
    ('clean '("swift" "package" "clean"))))

(declare-function gdev-run-file-with "../../tools/build/config")
(defun gdev-swift-run (&optional ask-arguments)
  "Avvia un pacchetto Swift o il file aperto, con ASK-ARGUMENTS."
  (if (gdev-swift-project-p (gdev-language-root))
      (gdev-language-run ask-arguments)
    (gdev-run-file-with '("swift") ask-arguments)))

(defun gdev-swift--server (&rest _)
  "Trova SourceKit-LSP anche dentro la catena di strumenti Xcode."
  (when-let* ((program (or (executable-find "sourcekit-lsp") (gdev-xcrun-find "sourcekit-lsp"))))
    (list program)))

(declare-function gdev-format-with-program "../../editor/format/config")
(defun gdev-swift-format ()
  "Formatta il documento Swift, cercando lo stile accanto al file."
  (apply #'gdev-format-with-program "swift" "format"
         (append (when buffer-file-name (list "--assume-filename" (file-local-name buffer-file-name)))
                 '("-"))))

(gdev-set-project-language 'swift '(swift-mode) #'gdev-swift-project-p #'gdev-swift-command)
(gdev-set-runner 'swift-mode :run #'gdev-swift-run)
(gdev-set-formatter 'swift-mode #'gdev-swift-format)
(gdev-set-eglot-server 'swift-mode #'gdev-swift--server :when #'gdev-swift--server)
(gdev-doctor-executable "swift" "Installa gli strumenti da riga di comando di Xcode" 'note)

;;; config.el ends here
