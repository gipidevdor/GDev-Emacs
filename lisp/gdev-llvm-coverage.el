;;; gdev-llvm-coverage.el --- Compilazione strumentata con LLVM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Configurazione comune ai rapporti di Test e Profila.

;;; Code:

(require 'gdev-lib)

(defun gdev-llvm-coverage-tool (name)
  "Restituisci lo strumento LLVM NAME della catena di compilazione locale."
  (or (gdev-xcrun-find name) (executable-find name)
      (user-error "%s non trovato" name)))

(defun gdev-llvm-coverage-build-commands (root directory jobs &optional compiler-options configuration)
  "Configura ROOT in DIRECTORY e compila con JOBS e COMPILER-OPTIONS.
CONFIGURATION seleziona la configurazione nelle build multiple."
  (let ((flags "-fprofile-instr-generate -fcoverage-mapping"))
    (list (gdev-command-line "cmake" "-S" root "-B" directory
                             (when (gdev-executable-in "ninja" root) '("-G" "Ninja"))
                             "-DCMAKE_BUILD_TYPE=Debug"
                             (concat "-DCMAKE_C_FLAGS=" flags)
                             (concat "-DCMAKE_CXX_FLAGS=" flags)
                             (concat "-DCMAKE_EXE_LINKER_FLAGS=" flags)
                             ;; Una libreria condivisa strumentata ha bisogno del runtime.
                             (concat "-DCMAKE_SHARED_LINKER_FLAGS=" flags)
                             (concat "-DCMAKE_MODULE_LINKER_FLAGS=" flags)
                             compiler-options)
          (gdev-command-line "cmake" "--build" directory "--parallel" jobs
                             (when configuration (list "--config" configuration))))))

(provide 'gdev-llvm-coverage)
;;; gdev-llvm-coverage.el ends here
