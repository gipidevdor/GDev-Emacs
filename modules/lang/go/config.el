;;; config.el --- :lang go: Go e moduli Go -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 compila il modulo, F6 esegue go test ./..., F5 apre Delve
;; (dlv dap).  gopls aggiunge completamento, riferimenti e rinomina.
;; gdev sync prepara la grammatica di Emacs per Go.

;;; Code:

(require 'gdev-handlers)
(require 'gdev-project-types)

(defun gdev-go-command (action _root)
  "Scegli il comando Go per ACTION."
  (pcase action
    ('build '("go" "build" "./..."))
    ('test '("go" "test" "./..."))
    ('clean '("go" "clean" "./..."))))

(defun gdev-go-run (&optional ask-arguments)
  "Esegui il pacchetto del documento corrente, con ASK-ARGUMENTS se richiesto."
  (let ((args (when ask-arguments (read-shell-command "Argomenti del programma: "))))
    (save-buffer)
    (gdev-compile (concat "go run ." (when args (concat " " args))) "Go · esecuzione"
                  default-directory t)))

(declare-function gdev-format-with-program "../../editor/format/config")
(defun gdev-go-format ()
  "Formatta il documento con gofmt."
  (gdev-format-with-program "gofmt"))

(gdev-set-project-language 'go '(go-mode go-ts-mode) #'gdev-go-project-p #'gdev-go-command)
(gdev-set-runner '(go-mode go-ts-mode) :run #'gdev-go-run)
(gdev-set-formatter '(go-mode go-ts-mode) #'gdev-go-format)
(gdev-set-eglot-server '(go-ts-mode go-mode) '("gopls"))
(gdev-doctor-executable "go" "brew install go" 'note)
(gdev-doctor-executable "gopls" "brew install gopls" 'note)
(gdev-doctor-executable "dlv" "brew install delve" 'note)

;;; config.el ends here
