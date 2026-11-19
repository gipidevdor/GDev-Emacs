;;; config.el --- :lang rust: Rust e Cargo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; F7 compila con Cargo, F6 esegue cargo test e C-F5 avvia cargo run.
;; F5 apre il binario già compilato con LLDB. rust-analyzer offre la
;; navigazione e il completamento. gdev sync prepara la grammatica Rust.

;;; Code:

(require 'gdev-handlers)

(defun gdev-rust-project-p (root)
  "Indica se ROOT contiene Cargo.toml."
  (gdev-project-file-exists-p root "Cargo.toml"))

(defun gdev-rust-command (action _root)
  "Scegli il comando Cargo per ACTION."
  (pcase action
    ('build '("cargo" "build"))
    ('test '("cargo" "test"))
    ('run '("cargo" "run" "--"))
    ('clean '("cargo" "clean"))))

(gdev-set-project-language 'rust '(rust-mode rust-ts-mode rustic-mode)
                           #'gdev-rust-project-p #'gdev-rust-command)
;; Il server conosce anche l'edizione ereditata dal workspace Cargo.
(gdev-set-eglot-server '(rust-ts-mode rust-mode rustic-mode) '("rust-analyzer"))
(gdev-doctor-executable "cargo" "Installa Rust con rustup" 'note)
(gdev-doctor-executable "rust-analyzer" "rustup component add rust-analyzer" 'note)

;;; config.el ends here
