;;; gdev-bdd.el --- Ponte Gherkin e Buttercup verso ERT -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; `gdev-bdd-register-feature' registra ogni scenario come test ERT.
;; I passi sono funzioni Elisp esplicite: i file .feature sono dati.
;; SETUP restituisce il contesto passato ai passi e a CLEANUP. CLEANUP
;; viene eseguito anche quando un passo fallisce. Nessun runner esterno.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'package)
(package-activate-all)
(require 'buttercup)
(require 'gdev-gherkin)

(defun gdev-bdd--match (step definitions)
  "Risolvi STEP in DEFINITIONS; richiedi un'unica corrispondenza completa."
  (let ((body (ecukes-step-body step)) matches)
    (dolist (definition definitions)
      (when (and (string-match (concat "\\`" (car definition) "\\'") body))
        (push (cons (cdr definition)
                    (cl-loop for index from 1 below (/ (length (match-data)) 2)
                             collect (match-string index body))) matches)))
    (unless (= (length matches) 1)
      (error "Passo BDD %s: %s" (if matches "ambiguo" "non definito") (ecukes-step-name step)))
    (car matches)))

(defun gdev-bdd-run-scenario (feature scenario definitions &optional setup cleanup)
  "Esegui SCENARIO di FEATURE usando DEFINITIONS, SETUP e CLEANUP.
Un fallimento o un passo pendente di Buttercup fallisce anche in ERT."
  (let ((buttercup-suites nil)
        (buttercup-reporter #'ignore)
        (steps (append (when-let* ((background (ecukes-feature-background feature)))
                         (ecukes-background-steps background))
                       (ecukes-scenario-steps scenario)))
        context)
    (unless steps (error "Scenario BDD vuoto"))
    (unwind-protect
        (progn
          (when setup (setq context (funcall setup)))
          (describe (ecukes-scenario-name scenario)
            (it "esegue tutti i passi"
              (dolist (step steps)
                (let ((definition (gdev-bdd--match step definitions)))
                  (ert-info ((ecukes-step-name step))
                    (apply (car definition) context
                           (append (cdr definition)
                                   (when (ecukes-step-arg step) (list (ecukes-step-arg step))))))))))
          (let ((passed (buttercup-run t)))
            (unless (and (eq passed t)
                         (= 1 (buttercup-suites-total-specs-defined buttercup-suites))
                         (zerop (buttercup-suites-total-specs-pending buttercup-suites)))
              (ert-fail
               (cl-loop for suite in buttercup-suites
                        append (cl-loop for spec in (buttercup-suite-children suite)
                                        collect (list (buttercup-spec-description spec)
                                                      (buttercup-spec-status spec)
                                                      (buttercup-spec-failure-description spec))))))))
      (when cleanup (funcall cleanup context)))))

(defun gdev-bdd-register-feature (file prefix definitions &optional setup cleanup)
  "Registra gli scenari di FILE in ERT con PREFIX e DEFINITIONS.
SETUP e CLEANUP sono eseguiti per ogni scenario. Ritorna i nomi ERT."
  (let* ((feature (gdev-gherkin-read file))
         (seen (make-hash-table :test #'equal)) names)
    (dolist (scenario (ecukes-feature-scenarios feature))
      (let* ((title (ecukes-scenario-name scenario))
             (slug (replace-regexp-in-string "[^[:alnum:]]+" "-" (downcase title)))
             (name (intern (concat prefix slug))))
        (when (gethash name seen) (error "Nome BDD duplicato: %s" title))
        (puthash name t seen)
        (dolist (step (append (when-let* ((background (ecukes-feature-background feature)))
                                (ecukes-background-steps background))
                              (ecukes-scenario-steps scenario)))
          (gdev-bdd--match step definitions))
        (ert-set-test name
                      (make-ert-test
                       :name name :documentation (format "%s: %s" (file-name-nondirectory file) title)
                       :tags '(behavior bdd)
                       :body (lambda () (gdev-bdd-run-scenario feature scenario definitions setup cleanup))))
        (push name names)))
    (nreverse names)))

(provide 'gdev-bdd)
;;; gdev-bdd.el ends here
