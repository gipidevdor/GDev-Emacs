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

(defun gdev-bdd--scenario-plan (feature scenario definitions)
  "Risolvi tutti i passi di SCENARIO e FEATURE tramite DEFINITIONS."
  (let ((steps (append (when-let* ((background (ecukes-feature-background feature)))
                         (ecukes-background-steps background))
                       (ecukes-scenario-steps scenario))))
    (unless steps (error "Scenario BDD vuoto"))
    (mapcar (lambda (step)
              (let ((definition (gdev-bdd--match step definitions)))
                (list step (car definition)
                      (append (cdr definition)
                              (when (ecukes-step-arg step) (list (ecukes-step-arg step)))))))
            steps)))

(defun gdev-bdd--execute-scenario (scenario plan setup cleanup)
  "Esegui il PLAN validato di SCENARIO, con SETUP e CLEANUP."
  (let ((buttercup-suites nil)
        (buttercup-reporter #'ignore)
        context)
    (unwind-protect
        (progn
          (when setup (setq context (funcall setup)))
          (describe (ecukes-scenario-name scenario)
            (it "esegue tutti i passi"
              (pcase-dolist (`(,step ,function ,arguments) plan)
                (ert-info ((ecukes-step-name step))
                  (apply function context arguments)))))
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

(defun gdev-bdd-run-scenario (feature scenario definitions &optional setup cleanup)
  "Esegui SCENARIO di FEATURE usando DEFINITIONS, SETUP e CLEANUP.
Valida i passi prima di SETUP. Un fallimento o un passo pendente di
Buttercup fallisce anche in ERT. CLEANUP segue ogni avvio di SETUP."
  (gdev-bdd--execute-scenario scenario (gdev-bdd--scenario-plan feature scenario definitions)
                              setup cleanup))

(defun gdev-bdd-register-feature (file prefix definitions &optional setup cleanup)
  "Registra gli scenari di FILE in ERT con PREFIX e DEFINITIONS.
Valida tutti i nomi e i passi prima di registrare il primo test.
SETUP e CLEANUP sono eseguiti per ogni scenario. I passi sono risolti
una volta alla registrazione. Ritorna i nomi ERT."
  (let* ((feature (gdev-gherkin-read file))
         (seen (make-hash-table :test #'equal)) planned)
    (dolist (scenario (ecukes-feature-scenarios feature))
      (let* ((title (ecukes-scenario-name scenario))
             (slug (replace-regexp-in-string "[^[:alnum:]]+" "-" (downcase title)))
             (name (intern (concat prefix slug)))
             (plan (gdev-bdd--scenario-plan feature scenario definitions)))
        (when (gethash name seen) (error "Nome BDD duplicato: %s" title))
        (puthash name t seen)
        ;; Conserva il contratto ERT: in batch una ridefinizione è un errore;
        ;; nell'editor una ricarica esplicita mantiene il comportamento ERT.
        (when (and noninteractive (ert-test-boundp name))
          (error "Test BDD già registrato: %s" name))
        (push (make-ert-test
               :name name :documentation (format "%s: %s" (file-name-nondirectory file) title)
               :tags '(behavior bdd)
               :body (lambda () (gdev-bdd--execute-scenario scenario plan setup cleanup)))
              planned)))
    (setq planned (nreverse planned))
    (dolist (test planned) (ert-set-test (ert-test-name test) test))
    (mapcar #'ert-test-name planned)))

(provide 'gdev-bdd)
;;; gdev-bdd.el ends here
