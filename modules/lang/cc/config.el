;;; config.el --- :lang cc: C, C++ e CMake -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; C e C++ con le modalità tree-sitter e clangd:
;;
;;   - clangd della catena di compilazione nel PATH (Xcode su macOS), con LLVM di Homebrew
;;     come ripiego.  Con --query-driver legge le intestazioni di sistema
;;     del compilatore scelto per la compilazione, che sia Apple clang, clang di
;;     Homebrew o GCC.
;;   - i controlli clang-tidy girano dentro clangd (con il .clang-tidy del
;;     progetto);
;;   - i file CMake usano il server di linguaggio
;;     neocmakelsp.
;;
;;   C-c c j    intestazione <-> sorgente, dall'indice di clangd
;;   C-c c f    clang-format con il .clang-format del progetto
;;   C-c l a    disassemblato del file, a lato,
;;              aggiornato a ogni salvataggio
;;   C-c l b    compile_commands.json per un progetto Makefile (bear)
;;
;; Compilazione, esecuzione e test sono in tools/build (F7, C-F5, F6); la
;; esecuzione passo passo in tools/debugger (F5, lldb-dap);
;; profilazione, analizzatori e copertura in
;; tools/profiler (C-c P).

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-language-modes)

(defvar c-ts-mode-indent-offset)
(defvar c-ts-mode-indent-style)
(defvar c-ts-base-mode-map)
(defvar c-mode-map)
(defvar c++-mode-map)
(declare-function gdev-cmake--context "../../tools/build/config" (root &optional ask action))

(defun gdev-cc-compilation-database ()
  "Trova il database del preset CMake selezionato, senza chiedere una scelta."
  (when-let* ((root (locate-dominating-file (or buffer-file-name default-directory) "CMakePresets.json"))
              (_ (fboundp 'gdev-cmake--context))
              (directory (plist-get (gdev-cmake--context root nil 'build) :directory))
              (_ (file-regular-p (expand-file-name "compile_commands.json" directory))))
    directory))

(defconst gdev-cc-modes '(c-ts-mode c++-ts-mode c-mode c++-mode objc-mode)
  "Modalità principali per il codice della famiglia C.")

;;;; Modalità

;; L'analisi nativa delle intestazioni consulta poi la scelta C/C++.
(gdev-language-register-tree-sitter 'c-mode 'c-ts-mode 'c)
(gdev-language-register-tree-sitter 'c++-mode 'c++-ts-mode 'cpp)
(add-to-list 'auto-mode-alist '("\\.h\\'" . c-or-c++-mode))
;; Moduli C++, file di implementazione dei modelli (template), intestazioni
;; inline.
(add-to-list 'auto-mode-alist '("\\.\\(cppm\\|ixx\\|ipp\\|tpp\\|inl\\)\\'" . c++-mode))

(setq c-ts-mode-indent-offset 4
      c-ts-mode-indent-style 'k&r)

;;;; clangd

(defun gdev-cc-llvm-tool (name)
  "Restituisce NAME di LLVM di Homebrew se installato, altrimenti dal PATH."
  (let ((homebrew (expand-file-name (concat "opt/llvm/bin/" name)
                                    (or (getenv "HOMEBREW_PREFIX") "/opt/homebrew"))))
    (if (file-executable-p homebrew) homebrew (or (executable-find name) name))))

(defconst gdev-cc-query-drivers
  '("/usr/bin/clang*" "/usr/bin/c++" "/usr/bin/g++*" "/usr/bin/gcc*"
    "/Library/Developer/CommandLineTools/usr/bin/clang*"
    "/Applications/Xcode*.app/Contents/Developer/Toolchains/*/usr/bin/clang*"
    "/opt/homebrew/opt/llvm/bin/clang*" "/opt/homebrew/bin/g++*" "/opt/homebrew/bin/gcc*"
    "/usr/local/bin/g++*" "/usr/local/bin/clang*")
  "Compilatori che clangd può eseguire per scoprirne i percorsi di include.")

(defun gdev-cc-clangd-command ()
  "Restituisce la riga di comando di clangd usata da Eglot."
  (append
   ;; Rispetta la toolchain nel PATH, inclusa quella di Xcode su macOS.
   (list (or (executable-find "clangd") (gdev-cc-llvm-tool "clangd"))
         "--background-index"                 ; indice del progetto, su disco
         "--background-index-priority=low"    ; non rallenta il compilatore
         "--clang-tidy"
         "--completion-style=detailed"        ; una voce per variante (overload)
         "--header-insertion=iwyu"            ; #include automatico al completamento
         "--header-insertion-decorators=0"
         "--function-arg-placeholders=1"
         "--pch-storage=memory"               ; rianalisi più rapide, più RAM
         (format "-j=%d" (max 2 (/ (num-processors) 2)))
         (concat "--query-driver=" (string-join gdev-cc-query-drivers ","))
         "--log=error")
    (when-let* ((directory (gdev-cc-compilation-database)))
      (list (concat "--compile-commands-dir=" directory)))
    (when gdev-linux-p '("--malloc-trim"))))

(defun gdev-cc-clangd-server (&optional _interactive _project)
  "Comando di clangd per il buffer corrente.
Lo cerca all'avvio del server e non al caricamento del modulo: così valgono
gli strumenti fissati dal progetto e un clangd installato a Emacs già avviato."
  (gdev-cc-clangd-command))

(gdev-set-eglot-server gdev-cc-modes #'gdev-cc-clangd-server
                       :when (lambda () (executable-find (car (gdev-cc-clangd-command)))))
(gdev-set-eglot-server '(cmake-ts-mode cmake-mode) '("neocmakelsp" "stdio"))

(gdev-doctor-check "clangd"
                   (lambda () (executable-find (car (gdev-cc-clangd-command))))
                   (if gdev-macos-p "xcode-select --install (oppure brew install llvm)"
                     "installa clangd con il gestore dei pacchetti di sistema"))
(gdev-doctor-executable "cmake" "brew install cmake")
(gdev-doctor-executable "ninja" "brew install ninja" 'note)
(gdev-doctor-executable "neocmakelsp" "brew install neocmakelsp" 'note)
(gdev-doctor-executable "bear" "brew install bear" 'note)

;;;; Intestazione <-> sorgente

(declare-function eglot-current-server "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function jsonrpc-request "jsonrpc")

(defun gdev-cc-switch-source-header ()
  "Passa dal sorgente alla sua intestazione (header), o viceversa.
Lo chiede a clangd, che conosce la struttura del progetto; senza server
ripiega su `ff-find-other-file'."
  (interactive)
  (let ((uri (and (bound-and-true-p eglot--managed-mode)
                  (ignore-errors
                    ;; Con l'indice ancora in costruzione clangd può tardare: non si
                    ;; blocca l'interfaccia fino al tempo massimo predefinito di 10 s.
                    (jsonrpc-request (eglot-current-server)
                                     :textDocument/switchSourceHeader
                                     (list :uri (eglot-path-to-uri buffer-file-name))
                                     :timeout 2 :cancel-on-input t)))))
    ;; Una risposta vuota vuol dire «nessuna controparte»: `find-file' aprirebbe la cartella.
    (if (and (stringp uri) (not (string-empty-p uri)))
        (find-file (eglot-uri-to-path uri))
      (ff-find-other-file nil t))))

(gdev-set-other-file gdev-cc-modes #'gdev-cc-switch-source-header)

;;;; Formattazione senza server

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-cc-check-format-version (program)
  "Richiedi a PROGRAM la versione fissata dal progetto, prima di modificare testo."
  (when-let* ((root (locate-dominating-file (or buffer-file-name default-directory) ".clang-format-version")))
    (let ((expected (string-trim (with-temp-buffer
                                  (insert-file-contents (expand-file-name ".clang-format-version" root)) (buffer-string)))))
      (unless (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)+\\'" expected)
        (user-error "Versione clang-format del progetto non valida"))
      (with-temp-buffer
        (unless (and (eq 0 (process-file program nil t nil "--version"))
                     (string-match "version \\([0-9]+\\(?:\\.[0-9]+\\)+\\)" (buffer-string))
                     (equal expected (match-string 1 (buffer-string))))
          (user-error "Il progetto richiede clang-format %s; controlla %s e gli strumenti locali" expected program))))))

(defun gdev-cc-clang-format ()
  "Formatta l'area di testo con clang-format e il .clang-format del progetto.
Vince il clang-format fissato dal progetto (vedi
`gdev-project-tool-directories'), poi quello nel PATH, poi quello di LLVM
di Homebrew."
  (let ((program (or (executable-find "clang-format") (gdev-cc-llvm-tool "clang-format"))))
    (gdev-cc-check-format-version program)
    (gdev-format-with-program program (concat "--assume-filename=" (or buffer-file-name "x.cpp")))))

(gdev-set-formatter gdev-cc-modes #'gdev-cc-clang-format)

;;;; Documentazione

(gdev-set-docsets '(c-ts-mode c-mode) "c")
(gdev-set-docsets '(c++-ts-mode c++-mode) "cpp" "c")
(gdev-set-docsets '(cmake-ts-mode cmake-mode) "cmake")

;;;; compile_commands.json per i progetti senza CMake

(defun gdev-cc-generate-compile-commands ()
  "Esegue il make del progetto sotto bear(1) e genera compile_commands.json.
clangd ha bisogno di quel file per capire un progetto basato su Makefile."
  (interactive)
  (unless (executable-find "bear") (user-error "bear non è installato (brew install bear)"))
  (gdev-compile (gdev-command-line "bear" "--" "make" "-j" (number-to-string (num-processors)))
                "Indice di compilazione C e C++"))

;;;; Codice macchina leggibile (assembly) accanto al sorgente

;; rmsbolt compila il file corrente con le opzioni (flag) del progetto e
;; mostra l'assembly in una finestra laterale; ogni riga ha lo stesso
;; colore della riga di sorgente da cui nasce.
(use-package rmsbolt
  :ensure t
  :commands (rmsbolt rmsbolt-mode)
  :custom
  (rmsbolt-asm-format "intel")
  (rmsbolt-demangle t))

;;;; Tasti del linguaggio (localleader)

(defun gdev-cc--localleader (map)
  "Installa i comandi C/C++ nella mappa MAP del modo attivo."
  (gdev-bind (gdev-localleader-map map)
             "a" "disassemblato" #'rmsbolt
             "b" "genera compile_commands.json con Bear" #'gdev-cc-generate-compile-commands
             "o" "intestazione/sorgente" #'gdev-cc-switch-source-header))

(gdev-register-after-module
 (lambda ()
   (with-eval-after-load 'c-ts-mode
     (gdev-cc--localleader c-ts-base-mode-map))
   (with-eval-after-load 'cc-mode
     (gdev-cc--localleader c-mode-map)
     (gdev-cc--localleader c++-mode-map))))

;;; config.el ends here
