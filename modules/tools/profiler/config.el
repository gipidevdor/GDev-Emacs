;;; config.el --- :tools profiler: profilatori, analizzatori, misure, copertura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Misurare prima di ottimizzare, senza lasciare l'area di modifica (C-c P):
;;
;;   P   profila ciò che hai davanti: un programma del progetto (samply),
;;       il programma Perl aperto (NYTProf), la forma Lisp prima
;;       del cursore (sb-sprof)
;;   s   samply: profilatore della CPU a campionamento, con
;;       albero delle chiamate e grafico a fiamma nel
;;       navigatore; il profilo resta su questa macchina
;;   i   profilatore di Xcode (Instruments), solo su macOS: Time Profiler,
;;       Allocations, Leaks, System Trace...  La traccia si apre in
;;       Instruments.app
;;   f   grafico a fiamma di un processo in esecuzione (sample su macOS,
;;       perf su Linux)
;;   k   perdite di memoria, con la pila delle allocazioni (leaks di macOS)
;;   h   misura delle prestazioni di comandi, con statistiche
;;       (hyperfine)
;;   a u t   compila e testa con gli analizzatori degli
;;       errori di memoria (AddressSanitizer, ASan), del comportamento
;;       indefinito (UndefinedBehaviorSanitizer, UBSan) e degli accessi
;;       concorrenti (ThreadSanitizer, TSan), in build-asan/ build-ubsan/
;;       build-tsan/; ogni livello della pila segnalato è un
;;       collegamento al sorgente
;;   c   copertura dei test: rapporto HTML di llvm-cov (CMake),
;;       Devel::Cover (Perl)
;;   e   profila Emacs stesso; di nuovo per il rapporto
;;   b   misura i tempi di avvio di GDev-Emacs
;;
;; I rapporti finiscono nella cartella di stato, mai nel progetto.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-modules)
(require 'json)

(declare-function profiler-running-p "profiler" (&optional mode))
(declare-function profiler-report "profiler" ())
(declare-function profiler-stop "profiler" ())

(autoload 'gdev-profile-report-benchmarks
  (expand-file-name "gdev-profile-report" (gdev-module-directory :tools 'profiler)))

(defun gdev-profile--output (name extension)
  "Restituisce un nuovo file di rapporto NAME.EXTENSION.
Il file sta nella cartella di stato."
  (let ((directory (gdev-state-file "profiles/")))
    (make-directory directory t)
    (expand-file-name (format "%s-%s.%s" name (format-time-string "%Y%m%d-%H%M%S") extension)
                      directory)))

(defun gdev-profile--require (program hint)
  "Segnala un errore con il suggerimento HINT se PROGRAM non è installato."
  (unless (executable-find program)
    (user-error "%s non è installato (%s)" program hint)))

(defun gdev-profile--program-command (prompt)
  "Legge un programma del progetto con PROMPT.
Restituisce la riga di comando, con il programma protetto per la shell."
  (pcase-let ((`(,program . ,arguments) (gdev-read-program prompt t (gdev-project-build-root))))
    (concat (shell-quote-argument program) " " arguments)))

(autoload 'gdev-llvm-coverage-tool "gdev-llvm-coverage")
(defalias 'gdev-profile--llvm-tool #'gdev-llvm-coverage-tool)
(autoload 'gdev-llvm-coverage-build-commands "gdev-llvm-coverage")

;;;; Programmi: samply, Instruments, leaks, hyperfine

(defun gdev-profile-samply ()
  "Registra con samply un programma del progetto e apre il profilo."
  (interactive)
  (gdev-profile--require "samply" "brew install samply")
  (let ((program (gdev-profile--program-command "Programma da profilare"))
        (profile (gdev-profile--output "samply" "json.gz")))
    (gdev-compile (concat (gdev-command-line "samply" "record" "--output" profile "--") " " program)
                  "gdev-samply" nil t)))

(defvar gdev-profile--instruments-templates nil
  "Nomi dei modelli (template) xctrace già letti.")

(defun gdev-profile-instruments (template)
  "Registra un programma del progetto con il modello Instruments TEMPLATE.
Funziona solo su macOS."
  (interactive
   (list (completing-read
          "Modello Instruments: "
          (or gdev-profile--instruments-templates
              (setq gdev-profile--instruments-templates
                    (seq-remove (lambda (line) (or (string-empty-p line) (string-prefix-p "==" line)))
                                (process-lines-ignore-status "xcrun" "xctrace" "list" "templates"))))
          nil t nil nil "Time Profiler")))
  (unless gdev-macos-p (user-error "Instruments esiste solo su macOS"))
  (let ((trace (gdev-profile--output "instruments" "trace")))
    (gdev-compile (format "xcrun xctrace record --template %s --output %s --launch -- %s && open %s"
                          (shell-quote-argument template) (shell-quote-argument trace)
                          (gdev-profile--program-command "Programma da profilare")
                          (shell-quote-argument trace))
                  "gdev-instruments" nil t)))

(defun gdev-profile-leaks ()
  "Esegue un programma del progetto e segnala la memoria persa, con le pile."
  (interactive)
  (unless gdev-macos-p
    (user-error "Solo leaks di macOS; su Linux usa la compilazione AddressSanitizer (C-c P a)"))
  (gdev-compile (concat "MallocStackLogging=1 leaks --atExit -- "
                        (gdev-profile--program-command "Programma da controllare (perdite di memoria)"))
                "gdev-leaks" nil t))

(defvar gdev-profile-hyperfine-history nil "Comandi misurati con hyperfine.")

(defun gdev-profile--read-benchmark (file root output)
  "Mostra il risultato di FILE per ROOT, con accesso a OUTPUT."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (gdev-profile-report-benchmarks
         (json-parse-buffer :object-type 'alist :array-type 'list) root output))
    (error (message "Rapporto delle misure non disponibile: %s" (error-message-string err)))))

(defun gdev-profile-hyperfine (commands)
  "Misura COMMANDS (separati da \" ;; \") e mostra il rapporto dei tempi."
  (interactive
   (list (read-string "Comandi da misurare (cmd1 ;; cmd2): "
                      (car gdev-profile-hyperfine-history) 'gdev-profile-hyperfine-history)))
  (gdev-profile--require "hyperfine" "brew install hyperfine")
  (let* ((commands (split-string commands " ;; " t "[ \t]+"))
         (root (gdev-project-root))
         (default-directory root)
         (name (format "Misure · %s" (abbreviate-file-name (directory-file-name root)))))
    (unless commands (user-error "Indica almeno un comando da misurare"))
    (when (process-live-p (get-buffer-process (format "*%s*" name)))
      (user-error "Una misurazione è già in corso in questo progetto"))
    (let* ((scratch (make-nearby-temp-file "gdev-hyperfine-" t))
           (export (expand-file-name "misure.json" scratch))
           (cleanup (lambda () (when (file-directory-p scratch) (delete-directory scratch t))))
           (started nil))
      (unwind-protect
          (let* ((output (gdev-compile
                          (gdev-command-line "hyperfine" "--warmup" "3" "--style" "basic"
                                             "--shell" (if gdev-windows-p "cmd.exe" "/bin/sh")
                                             "--export-json" (file-local-name export) "--" commands)
                          name root))
                 (process (get-buffer-process output))
                 (sentinel (and process (process-sentinel process))))
            (when process
              (add-hook 'kill-emacs-hook cleanup)
              (with-current-buffer output (add-hook 'kill-buffer-hook cleanup nil t))
              (set-process-sentinel
               process
               (lambda (child event)
                 (if (process-live-p child)
                     (when sentinel (funcall sentinel child event))
                   (unwind-protect
                       (progn
                         (when sentinel (funcall sentinel child event))
                         (when (and (eq (process-status child) 'exit)
                                    (zerop (process-exit-status child)) (buffer-live-p output))
                           (gdev-profile--read-benchmark export root output)))
                     (remove-hook 'kill-emacs-hook cleanup)
                     (when (buffer-live-p output)
                       (with-current-buffer output (remove-hook 'kill-buffer-hook cleanup t)))
                     (funcall cleanup)))))
              (setq started t))
            output)
        (unless started (funcall cleanup))))))

;;;; Grafico a fiamma di un processo in esecuzione

(defun gdev-profile-flamegraph (pid seconds)
  "Campiona il processo PID per SECONDS secondi.
Poi mostra nel navigatore il grafico a fiamma (flame graph)."
  (interactive
   (list (gdev-read-process "Processo: ")
         (read-number "Secondi: " 10)))
  (gdev-profile--require "flamegraph.pl" "brew install flamegraph")
  (let ((svg (gdev-profile--output "flamegraph" "svg"))
        (raw (gdev-profile--output "samples" "txt")))
    (gdev-compile
     (if gdev-macos-p
         (format "sample %d %d -file %s && stackcollapse-sample.awk %s | flamegraph.pl > %s && %s %s"
                 pid seconds (shell-quote-argument raw) (shell-quote-argument raw)
                 (shell-quote-argument svg) gdev-open-program (shell-quote-argument svg))
       (format "perf record -F 997 -g -p %d -o %s -- sleep %d && perf script -i %s | stackcollapse-perf.pl | flamegraph.pl > %s && %s %s"
               pid (shell-quote-argument raw) seconds (shell-quote-argument raw)
               (shell-quote-argument svg) gdev-open-program (shell-quote-argument svg)))
     "gdev-flamegraph")))

;;;; Analizzatori (sanitizer) per progetti CMake

(defconst gdev-profile-sanitizers
  '((address   "asan"  "-fsanitize=address -fno-omit-frame-pointer"
               "ASAN_OPTIONS=halt_on_error=1:strict_string_checks=1")
    (undefined "ubsan" "-fsanitize=undefined -fno-omit-frame-pointer -fno-sanitize-recover=all"
               "UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1")
    (thread    "tsan"  "-fsanitize=thread -fno-omit-frame-pointer"
               "TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1"))
  "Analizzatori con suffisso della cartella, flag del compilatore, opzioni.
Le opzioni valgono durante l'esecuzione dei test.")

(declare-function gdev-build--root "../build/config" ())

(defun gdev-profile--cmake-root (message)
  "Restituisci la radice CMake usata anche da compilazione e test.
Senza un progetto CMake interrompi il comando con MESSAGE."
  (let ((root (gdev-project-build-root)))
    (unless (gdev-project-file-exists-p root "CMakeLists.txt") (user-error "%s" message))
    root))

(defun gdev-profile-sanitize (sanitizer)
  "Compila il progetto CMake con SANITIZER in una cartella propria e lo testa.
Il programma resta disponibile in build-SUFFIX per l'esecuzione e il debug."
  (pcase-let* ((root (gdev-profile--cmake-root
                      "Le compilazioni con analizzatore richiedono un progetto CMake"))
               (`(,suffix ,flags ,options) (alist-get sanitizer gdev-profile-sanitizers))
               (directory (concat "build-" suffix))
               (jobs (number-to-string (num-processors))))
    (gdev-compile
     (concat (gdev-command-line
              "cmake" "-S" "." "-B" directory
              (and (gdev-executable-in "ninja" root) '("-G" "Ninja"))
              "-DCMAKE_BUILD_TYPE=Debug"
              (concat "-DCMAKE_C_FLAGS=" flags) (concat "-DCMAKE_CXX_FLAGS=" flags)
              (concat "-DCMAKE_EXE_LINKER_FLAGS=" flags)
              (concat "-DCMAKE_SHARED_LINKER_FLAGS=" flags))
             " && " (gdev-command-line "cmake" "--build" directory "--parallel" jobs)
             " && " options " "
             (gdev-command-line "ctest" "--test-dir" directory "--output-on-failure" "-j" jobs))
     (format "gdev-%s" suffix) root)))

(defun gdev-profile-asan () "Compila e testa con AddressSanitizer." (interactive) (gdev-profile-sanitize 'address))
(defun gdev-profile-ubsan () "Compila e testa con UndefinedBehaviorSanitizer." (interactive) (gdev-profile-sanitize 'undefined))
(defun gdev-profile-tsan () "Compila e testa con ThreadSanitizer." (interactive) (gdev-profile-sanitize 'thread))

;;;; Copertura (coverage)

(defun gdev-profile-llvm-coverage ()
  "Compila il progetto CMake con la copertura, esegue i test, apre il rapporto."
  (interactive)
  (let* ((root (gdev-profile--cmake-root "La copertura con llvm-cov richiede un progetto CMake"))
         (directory "build-coverage")
         (profiles (concat directory "/profiles"))
         (profdata (concat directory "/merged.profdata"))
         (html (concat directory "/html")))
    (gdev-compile
     (string-join
      (append
       (gdev-llvm-coverage-build-commands "." directory (number-to-string (num-processors)))
       (list (concat "rm -rf " profiles)
             (concat "LLVM_PROFILE_FILE=$PWD/" profiles "/%p-%m.profraw "
                     (gdev-command-line "ctest" "--test-dir" directory "--output-on-failure"))
             (concat (gdev-command-line (gdev-profile--llvm-tool "llvm-profdata") "merge" "-sparse")
                     " " profiles "/*.profraw -o " profdata)
             (concat (gdev-command-line (gdev-profile--llvm-tool "llvm-cov") "show" "-format=html"
                                        "-show-line-counts-or-regions"
                                        (concat "-output-dir=" html) (concat "-instr-profile=" profdata))
                     " $(find " directory " -type f -perm -u+x -not -path '*/CMakeFiles/*'"
                     " -not -name '*.sh' | sed 's/^/-object /')")
             (gdev-command-line gdev-open-program (concat html "/index.html"))))
      " && ")
     "gdev-coverage" root)))

(defun gdev-profile-coverage ()
  "Misura la copertura dei test del progetto con lo strumento adatto."
  (interactive)
  (if-let* ((handler (gdev-handler :coverage)))
      (funcall handler)
    (gdev-profile-llvm-coverage)))

;;;; Emacs stesso

(defun gdev-profile-emacs ()
  "Avvia la profilazione di Emacs (CPU e memoria); di nuovo per il rapporto."
  (interactive)
  (require 'profiler)
  (if (profiler-running-p)
      (progn (profiler-report) (profiler-stop))
    (profiler-start 'cpu+mem)
    (message "Profilazione di Emacs: fai l'operazione lenta, poi di nuovo C-c P e")))

(defun gdev-profile-emacs-startup ()
  "Misura i tempi di avvio di GDev-Emacs (bin/gdev bench)."
  (interactive)
  (gdev-compile (gdev-command-line (gdev-config-file "bin/gdev") "bench")
                "gdev-bench" gdev-config-directory))

;;;; Profilare ciò che hai davanti

(defun gdev-profile-dwim ()
  "Profila il codice aperto con il profilatore adatto al linguaggio."
  (interactive)
  (if-let* ((handler (gdev-handler :profile)))
      (call-interactively handler)
    (gdev-profile-samply)))

;;; config.el ends here
