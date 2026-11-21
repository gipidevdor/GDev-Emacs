;;; gdev-coverage.el --- Misura ripetibile della copertura ERT -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Conta le righe delle funzioni raggiungibili dalla strumentazione Edebug.
;; I casi ERT verificano anche le alternative che condividono la stessa riga.

;;; Code:

(require 'cl-lib)
(require 'edebug)
(require 'ert)
(require 'seq)

(defvar byte-compile-warnings)

(defvar gdev-coverage--counts nil)

(defun gdev-coverage--enter (function _arguments body)
  (let ((gdev-coverage--counts (get function 'edebug-freq-count))) (funcall body)))

(defun gdev-coverage--before (index)
  (cl-incf (aref gdev-coverage--counts index)))

(defun gdev-coverage--after (_before index value)
  (cl-incf (aref gdev-coverage--counts index))
  value)

(defun gdev-coverage--instrument (file)
  ;; I buffer di Edebug non partecipano agli elenchi dei documenti o ai
  ;; ripristini di uno spazio durante le prove.
  (with-current-buffer (generate-new-buffer " *gdev-coverage*")
    (insert-file-contents file)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (setq-local lexical-binding t)
    (let ((default-directory (file-name-directory file))
          (load-file-name file)
          (edebug-form-data nil)
          (edebug-all-defs t)
          (edebug-new-definition-function
           (lambda (symbol) (put symbol 'edebug-behavior 'gdev-coverage))))
      (eval-buffer nil nil file)
      (mapcar #'car edebug-form-data))))

(defun gdev-coverage--lines (functions)
  (let ((lines (make-hash-table :test #'eql)))
    (dolist (function functions)
      (pcase-let ((`(,start ,_ ,offsets . ,_) (get function 'edebug))
                  (counts (get function 'edebug-freq-count)))
        (with-current-buffer (marker-buffer start)
          (cl-loop for offset across offsets for count across counts
                   for line = (line-number-at-pos (+ start offset))
                   do (puthash line (or (gethash line lines) (> count 0)) lines)))))
    lines))

(defun gdev-coverage--report (entry)
  "Stampa la copertura del file in ENTRY e restituisci le righe scoperte."
  (let* ((path (car entry))
         (lines (gdev-coverage--lines (cdr entry)))
         (total (hash-table-count lines))
         missed)
    (maphash (lambda (line reached) (unless reached (push line missed))) lines)
    (unless (> total 0) (error "Nessuna riga strumentata in %s" path))
    (princ (format "%s · %d/%d righe strumentabili (%.1f%%)\n"
                   path (- total (length missed)) total
                   (* 100.0 (/ (- total (length missed)) (float total)))))
    (when missed
      (princ (format "Righe da esercitare · %s\n" (mapconcat #'number-to-string (sort missed #'<) ", "))))
    missed))

(defun gdev-coverage--run (paths selector &optional complete)
  "Misura PATHS eseguendo SELECTOR. Con COMPLETE richiedi tutte le righe."
  (unless noninteractive (user-error "Avvia la verifica in modalità batch"))
  (let* (;; Edebug legge anche gli argomenti ignorati per registrare le chiamate.
         (byte-compile-warnings '(not not-unused))
         (edebug-behavior-alist
          (cons '(gdev-coverage gdev-coverage--enter gdev-coverage--before gdev-coverage--after)
                edebug-behavior-alist))
         (entries (mapcar (lambda (path)
                            (cons path (gdev-coverage--instrument (gdev-config-file path))))
                          paths))
         (stats (ert-run-tests-batch selector))
         (missed (mapcar #'gdev-coverage--report entries)))
    (kill-emacs (if (and (> (ert-stats-total stats) 0)
                         (zerop (ert-stats-completed-unexpected stats))
                         (or (not complete) (not (seq-some #'identity missed))))
                    0 1))))

(defun gdev-coverage-preferences ()
  "Esegui in batch i test mirati e stampa la copertura delle Preferenze."
  (gdev-coverage--run '("modules/ui/workbench/gdev-preferences.el") "^gdev-test-preferences-"))

(defun gdev-coverage-workspace-state ()
  "Richiedi la copertura di ogni riga strumentabile dello stato condiviso."
  (gdev-coverage--run '("lisp/gdev-workspace-state.el") "^gdev-test-workspace-state-" t))

(defun gdev-coverage-state-flows ()
  "Richiedi tutte le righe strumentabili dei flussi di stato."
  (gdev-coverage--run
   '("lisp/gdev-operation-history.el" "lisp/gdev-workspaces.el"
     "lisp/gdev-drafts.el" "lisp/gdev-compilation.el" "lisp/gdev-launch.el")
   "\\(?:operation-history\\|workspace-\\|workspaces-\\|draft\\|gdev-test-operational-checkpoint-\\|gdev-test-launch-\\|gdev-test-project-operation-\\|gdev-test-xcode-\\|gdev-test-panel-session-\\|gdev-test-terminal-sessions-\\|gdev-test-debug-\\|gdev-test-lsp-refactor-\\|gdev-test-tabs-\\|gdev-test-run-view-\\|gdev-cpp-\\|gdev-cmake-test-\\)"
   t))

(defun gdev-coverage-assurance ()
  "Richiedi tutte le righe strumentabili del nucleo dell'assicurazione."
  (gdev-coverage--run
   '("lisp/gdev-assurance-db.el" "lisp/gdev-policy.el" "lisp/gdev-gates.el"
     "lisp/gdev-process.el" "lisp/gdev-evidence.el" "lisp/gdev-assurance.el"
     "lisp/gdev-assurance-workspace.el" "lisp/gdev-standards.el" "lisp/gdev-controls.el"
     "lisp/gdev-assessment.el" "lisp/gdev-decisions.el"
     "lisp/gdev-assessment-store.el")
   "^gdev-test-\\(?:project\\|assurance\\|process\\|evidence\\|policy\\|gates\\|standards\\|controls\\|assessment\\|decision\\)-" t))

(defun gdev-coverage-assurance-extensions ()
  "Richiedi tutte le righe strumentabili delle estensioni della roadmap."
  (gdev-coverage--run
   '("lisp/gdev-assurance-api.el" "lisp/gdev-graph.el" "lisp/gdev-records.el" "lisp/gdev-capability.el"
     "lisp/gdev-trace.el" "lisp/gdev-adoption.el" "lisp/gdev-documents.el"
     "lisp/gdev-assurance-git.el" "lisp/gdev-assurance-requests.el"
     "lisp/gdev-assurance-actions.el" "lisp/gdev-assurance-lavorazione.el"
     "lisp/gdev-standard-catalog.el" "lisp/gdev-standard-assessment.el" "lisp/gdev-project-catalog.el")
   "^\\(?:gdev-test-\\(?:project\\|assurance\\|capability\\|assessment\\|standards\\)-\\|gdev-agent-interface-headless-\\)" t))

(provide 'gdev-coverage)
;;; gdev-coverage.el ends here
