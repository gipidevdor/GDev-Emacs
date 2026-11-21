;;; config.el --- :tools tree-sitter: analisi del codice per evidenziare e navigare -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Tree-sitter analizza il codice in modo incrementale. Lo usano
;; l'evidenziazione precisa, il rientro, i movimenti strutturali (C-M-f per
;; nodo), imenu e le guide di rientro. I moduli dei linguaggi scelgono la
;; modalità durante l'apertura dei documenti. `gdev sync' installa le
;; grammatiche tree-sitter elencate in `gdev-treesit-languages'.

;;; Code:

(require 'gdev-lib)

(defvar treesit-font-lock-level)

(setq treesit-font-lock-level 4)        ; l'evidenziazione più ricca

(defconst gdev-treesit-languages
  '((bash . sh-script) (c . c-ts-mode) (cpp . c-ts-mode) (cmake . cmake-ts-mode)
    (c-sharp . csharp-mode) (css . css-mode) (go . go-ts-mode) (gomod . go-ts-mode)
    (html . html-ts-mode) (java . java-ts-mode) (javascript . js) (jsdoc . js)
    (json . json-ts-mode) (python . python) (rust . rust-ts-mode) (toml . toml-ts-mode)
    (tsx . typescript-ts-mode) (typescript . typescript-ts-mode) (yaml . yaml-ts-mode))
  "Grammatiche che GDev installa in anticipo (`gdev sync').
Ogni voce associa la grammatica alla libreria la cui modalità la usa.
Caricare quella libreria registra la ricetta della grammatica per cui la
modalità è stata scritta.")

(defconst gdev-treesit-fallback-sources
  '((bash "https://github.com/tree-sitter/tree-sitter-bash" "v0.23.3")
    (c "https://github.com/tree-sitter/tree-sitter-c" "v0.23.6")
    (cmake "https://github.com/uyha/tree-sitter-cmake" "v0.5.0")
    (cpp "https://github.com/tree-sitter/tree-sitter-cpp" "v0.23.4")
    (c-sharp "https://github.com/tree-sitter/tree-sitter-c-sharp" "v0.23.1")
    (css "https://github.com/tree-sitter/tree-sitter-css" "v0.23.2")
    (go "https://github.com/tree-sitter/tree-sitter-go" "v0.23.4")
    (gomod "https://github.com/camdencheek/tree-sitter-go-mod" "v1.1.0")
    (html "https://github.com/tree-sitter/tree-sitter-html" "v0.23.2")
    (java "https://github.com/tree-sitter/tree-sitter-java" "v0.23.5")
    (javascript "https://github.com/tree-sitter/tree-sitter-javascript" "v0.23.1" "src")
    (jsdoc "https://github.com/tree-sitter/tree-sitter-jsdoc" "v0.23.2")
    (json "https://github.com/tree-sitter/tree-sitter-json" "v0.24.8")
    (python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6")
    (rust "https://github.com/tree-sitter/tree-sitter-rust" "v0.23.2")
    (toml "https://github.com/tree-sitter-grammars/tree-sitter-toml" "v0.7.0")
    (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "v0.23.2" "tsx/src")
    (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "v0.23.2" "typescript/src")
    (yaml "https://github.com/tree-sitter-grammars/tree-sitter-yaml" "v0.7.0"))
  "Sorgenti delle grammatiche per gli Emacs le cui modalità non le dichiarano.
Le modalità di Emacs 31 portano ricette allineate alla libreria tree-sitter
inclusa; queste versioni fissate funzionano con Emacs 30.")

;; Emacs 31 dichiara le proprie ricette nelle modalità. Emacs 30 usa
;; le versioni fissate. I moduli registrano associazioni controllate al
;; posto del rimappamento globale di treesit-auto, che aggirerebbe la soglia.
(static-if (< emacs-major-version 31)
  (with-eval-after-load 'treesit
    (dolist (source gdev-treesit-fallback-sources)
      (unless (assq (car source) treesit-language-source-alist)
        (add-to-list 'treesit-language-source-alist source t)))))

;;;; Installare le grammatiche

(defvar treesit-language-source-alist)
(defvar treesit--install-language-grammar-out-dir-history)
(declare-function treesit-language-available-p "treesit.c")
(declare-function treesit-install-language-grammar "treesit")

(defun gdev-treesit--install-one (language)
  (message "Installo la grammatica %s…" language)
  (condition-case problem
      (treesit-install-language-grammar language)
    (error (message "  %s: %s" language (error-message-string problem)))))

(defun gdev-treesit--worker-command (recipe staging)
  "Prepara un Emacs separato che installa RECIPE nella cartella STAGING."
  (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
        (prin1-to-string
         `(progn
            (require 'treesit)
            (let ((exec-path ',exec-path)
                  (temporary-file-directory ,(file-name-as-directory staging))
                  (treesit-language-source-alist ',(list recipe))
                  (treesit-extra-load-path ',(list staging)))
              (treesit-install-language-grammar ',(car recipe) ,staging)
              (kill-emacs (if (treesit-language-available-p ',(car recipe)) 0 1)))))))

(defun gdev-treesit--start-worker (recipe staging)
  (let ((output (generate-new-buffer " *gdev-grammar*")) process)
    (unwind-protect
        (setq process
              (make-process :name (format "gdev-grammar-%s" (car recipe))
                            :command (gdev-treesit--worker-command recipe staging)
                            :buffer output :connection-type 'pipe
                            :noquery t :sentinel #'ignore))
      (unless process (kill-buffer output)))))

(defun gdev-treesit--publish (language staging destination)
  "Pubblica una grammatica compilata in STAGING sullo stesso filesystem."
  (let* ((library (format "libtree-sitter-%s%s" language (car dynamic-library-suffixes)))
         (compiled (expand-file-name library staging))
         (queries (expand-file-name "queries" staging)))
    (unless (file-regular-p compiled) (error "Libreria compilata assente"))
    (when (file-directory-p queries)
      (dolist (file (directory-files-recursively queries "."))
        (let ((target (expand-file-name (file-relative-name file staging) destination)))
          (make-directory (file-name-directory target) t)
          (rename-file file target t))))
    ;; Una grammatica diventa visibile a Emacs tutta insieme.
    (rename-file compiled (expand-file-name library destination) t)))

(defun gdev-treesit--finish-worker (job destination)
  (pcase-let ((`(,language ,staging ,process) job))
    (unwind-protect
        (condition-case problem
            (progn
              (while (accept-process-output process 0 nil t))
              (if (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
                  (unless (treesit-language-available-p language)
                    (gdev-treesit--publish language staging destination))
                (let ((details (with-current-buffer (process-buffer process)
                                 (string-trim (buffer-string)))))
                  (if (string-empty-p details)
                      (message "  %s: processo terminato (%s)" language (process-exit-status process))
                    (message "  %s: %s" language details)))))
          (error (message "  %s: %s" language (error-message-string problem))))
      (kill-buffer (process-buffer process)))))

(defun gdev-treesit--install-workers (recipes jobs)
  "Installa le ricette indipendenti con al massimo JOBS processi."
  (let* ((destination (locate-user-emacs-file "tree-sitter/"))
         running scratch)
    (make-directory destination t)
    (setq scratch (make-temp-file (expand-file-name ".gdev-grammars-" destination) t))
    (unwind-protect
        (while (or recipes running)
          (while (and recipes (< (length running) jobs))
            (let* ((recipe (pop recipes))
                   (language (car recipe)))
              (unless (treesit-language-available-p language)
                (message "Installo la grammatica %s…" language)
                (condition-case problem
                    (let* ((staging (make-temp-file (expand-file-name "grammatica-" scratch) t))
                           (process (gdev-treesit--start-worker recipe staging)))
                      (push (list language staging process) running))
                  (error (message "  %s: %s" language (error-message-string problem)))))))
          (when running (accept-process-output nil 0.1))
          (setq running
                (seq-filter (lambda (job)
                              (or (process-live-p (nth 2 job))
                                  (progn (gdev-treesit--finish-worker job destination) nil)))
                            running)))
      (dolist (job running)
        (let ((process (nth 2 job)))
          (when (process-live-p process)
            (ignore-errors (kill-process process))
            (delete-process process))
          (when (buffer-live-p (process-buffer process)) (kill-buffer (process-buffer process)))))
      (delete-directory scratch t))))

(defun gdev-treesit-install-grammars (&optional jobs background)
  "Installa le grammatiche mancanti, con JOBS processi se richiesto.
Le ricette locali usano il programma di installazione ordinario.
Richiede git e un compilatore C. Restituisce i linguaggi non installati.
Con BACKGROUND restituisce il buffer del processo, come dal menu."
  (interactive (list nil t))
  (require 'treesit)
  (if background
      (gdev-maintenance-run
       "Grammatiche dei linguaggi" (expand-file-name invocation-name invocation-directory)
       "--batch" "-Q" "-l" (gdev-config-file "early-init.el")
       "-L" (gdev-config-file "lisp") "-l" (gdev-config-file "modules/tools/tree-sitter/config.el")
       "--eval" (prin1-to-string
                 `(progn
                    (require 'treesit)
                    (let ((gdev-treesit-languages ',gdev-treesit-languages)
                          (treesit-language-source-alist ',treesit-language-source-alist)
                          (treesit-extra-load-path ',treesit-extra-load-path)
                          (exec-path ',exec-path))
                      (kill-emacs (if (gdev-treesit--install-grammars) 1 0))))))
    (gdev-treesit--install-grammars jobs)))

(defun gdev-treesit--install-grammars (&optional jobs)
  "Installa con JOBS processi e restituisci le grammatiche ancora assenti."
  (let ((parallel (and jobs (> jobs 1)
                       (not (memq system-type '(windows-nt cygwin)))
                       (not (file-remote-p user-emacs-directory))
                       (not (bound-and-true-p treesit--install-language-grammar-out-dir-history))))
        missing recipes)
    (pcase-dolist (`(,language . ,library) gdev-treesit-languages)
      (unless (treesit-language-available-p language)
        (push language missing)
        (require library nil t)
        (when-let* ((recipe (assq language treesit-language-source-alist)))
          ;; Le ricette locali possono compilare nella stessa copia di lavoro.
          (if (and parallel (stringp (cadr recipe)) (string-prefix-p "https://" (cadr recipe)))
              (unless (assq language recipes) (push recipe recipes))
            (gdev-treesit--install-one language)))))
    (when recipes
      (condition-case problem
          (gdev-treesit--install-workers (nreverse recipes) jobs)
        (file-error (message "Grammatiche: %s" (error-message-string problem)))))
    (let ((failed (seq-remove #'treesit-language-available-p (nreverse missing))))
      (when failed (message "Grammatiche mancanti: %s. Consulta il registro e riprova." failed))
      failed)))

;;; config.el ends here
