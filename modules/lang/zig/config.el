;;; config.el --- :lang zig: Zig e ZLS -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 usa zig build. F6 esegue zig build test nei progetti e zig test
;; sui file singoli. C-F5 avvia zig build run o zig run. I passi run e test
;; di progetto devono essere dichiarati in build.zig. F5 usa LLDB.

;;; Code:

(require 'gdev-handlers)
(require 'gdev-project-types)

(use-package zig-mode
  :ensure t
  :mode ("\\.zig\\(?:\\.zon\\)?\\'" . zig-mode)
  :custom (zig-format-on-save nil))

(defun gdev-zig-command (action _root)
  "Scegli il comando Zig per ACTION."
  (pcase action
    ('build '("zig" "build"))
    ('test '("zig" "build" "test"))
    ('run '("zig" "build" "run" "--"))))

(declare-function gdev-run-file-with "../../tools/build/config")
(defun gdev-zig-run (&optional ask-arguments)
  "Esegui il progetto o il file Zig, con ASK-ARGUMENTS."
  (if (gdev-zig-project-p (gdev-language-root))
      (gdev-language-run ask-arguments)
    (gdev-run-file-with '("zig" "run") ask-arguments)))

(defun gdev-zig-test ()
  "Esegui i test del progetto o del file Zig aperto."
  (if (gdev-zig-project-p (gdev-language-root))
      (gdev-language-test)
    (unless buffer-file-name (user-error "Apri un file Zig"))
    (save-buffer)
    (gdev-compile (gdev-command-line "zig" "test" (file-local-name buffer-file-name))
                  "Zig · test" default-directory)))

(declare-function gdev-format-with-program "../../editor/format/config")
(defun gdev-zig-format ()
  "Formatta il documento con Zig."
  (gdev-format-with-program "zig" "fmt" "--stdin"))

(gdev-set-project-language 'zig '(zig-mode) #'gdev-zig-project-p #'gdev-zig-command)
(gdev-set-runner 'zig-mode :run #'gdev-zig-run :test #'gdev-zig-test)
(gdev-set-formatter 'zig-mode #'gdev-zig-format)
(gdev-set-eglot-server 'zig-mode '("zls"))
(gdev-doctor-executable "zig" "brew install zig" 'note)
(gdev-doctor-executable "zls" "Installa ZLS compatibile con il compilatore Zig" 'note)

;;; config.el ends here
