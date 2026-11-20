;;; gdev-bdd-contract-test.el --- Contratti di registrazione dei BDD -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica le feature dall'entrata pubblica: tutti gli esempi diventano
;; test, una registrazione fallita non lascia un corpus parziale e gli
;; input grandi restano utilizzabili con il limite ordinario dello stack.

;;; Code:

(defmacro gdev-bdd-contract--with-feature (binding &rest body)
  "Scrivi la feature in BINDING ed esegui BODY eliminando il file alla fine."
  (declare (indent 1))
  (let ((file (car binding)) (text (cadr binding)))
    `(let ((,file (make-temp-file "gdev-bdd-contract-" nil ".feature")))
       (unwind-protect
           (progn (with-temp-file ,file (insert ,text)) ,@body)
         (delete-file ,file)))))

(ert-deftest gdev-test-behavior-bdd-contract-registers-every-outline-example ()
  "Un outline registra tutte le righe, con o senza parametri nel titolo."
  (dolist (title '("Somma" "Somma <a>"))
    (let (names observed)
      (gdev-bdd-contract--with-feature
          (file (concat "Funzionalità: Somme\nSchema dello scenario: " title
                        "\n Dato valore <a>\nEsempi:\n | a |\n | 1 |\n | 2 |\n"))
        (unwind-protect
            (progn
              (setq names (gdev-bdd-register-feature
                           file "gdev-bdd-contract-outline-"
                           (list (cons "valore \\([0-9]+\\)"
                                       (lambda (_ value) (push value observed))))))
              (should (= 2 (length names)))
              (should-not (eq (car names) (cadr names)))
              (dolist (name names) (funcall (ert-test-body (ert-get-test name))))
              (should (equal (nreverse observed) '("1" "2")))
              (let ((scenarios (ecukes-feature-scenarios (gdev-gherkin-read file))))
                (should (equal (ecukes-scenario-name (car scenarios))
                               (if (equal title "Somma") "Somma [1]" "Somma 1 [1]")))))
          (dolist (name names) (ert-make-test-unbound name)))))))

(ert-deftest gdev-test-behavior-bdd-contract-rejects-incomplete-examples ()
  "Un outline errato non scompare accanto a uno scenario valido."
  (dolist (outline '("Scenario Outline: Empty\nExamples:\n | a |\n | 1 |\n"
                     "Scenario Outline: Missing\n Given value <a>\n"
                     "Scenario Outline: No rows\n Given value <a>\nExamples:\n | a |\n"
                     "Scenario Outline: Short\n Given value <a>\nExamples:\n | a | b |\n | 1 |\n"
                     "Scenario Outline: Long\n Given value <a>\nExamples:\n | a |\n | 1 | 2 |\n"
                     "Scenario Outline: Duplicate\n Given value <a>\nExamples:\n | a | a |\n | 1 | 2 |\n"
                     "Scenario Outline: Blank\n Given value <a>\nExamples:\n | a |  |\n | 1 | 2 |\n"))
    (gdev-bdd-contract--with-feature
        (file (concat "Feature: Examples\nScenario: Control\n Given control\n" outline))
      (should-error (gdev-gherkin-read file)))))

(ert-deftest gdev-test-behavior-bdd-contract-parses-large-tables ()
  "Una tabella di 3000 righe e commenti lunghi non esauriscono lo stack."
  (gdev-bdd-contract--with-feature
      (file (concat "Feature: Large input\nScenario: Table\n Given table\n"
                    (apply #'concat (make-list 3000 " | valore |\n"))
                    (apply #'concat (make-list 1000 " # commento\n"))
                    " Then done\n"))
    (let* ((max-lisp-eval-depth 400)
           (scenario (car (ecukes-feature-scenarios (gdev-gherkin-read file))))
           (steps (ecukes-scenario-steps scenario)))
      (should (= 2 (length steps)))
      (should (= 3000 (length (ecukes-step-arg (car steps)))))
      (should (equal (ecukes-step-body (cadr steps)) "done")))))

(ert-deftest gdev-test-behavior-bdd-contract-registration-validates-all-steps ()
  "Un passo mancante nel secondo scenario non registra il primo."
  (let ((name 'gdev-bdd-contract-atomic-first))
    (gdev-bdd-contract--with-feature
        (file "Feature: Atomic\nScenario: First\n Given known\nScenario: Second\n Given unknown\n")
      (unwind-protect
          (progn
            (should-error (gdev-bdd-register-feature file "gdev-bdd-contract-atomic-" '(("known" . ignore))))
            (should-not (ert-test-boundp name)))
        (ert-make-test-unbound name)))))

(ert-deftest gdev-test-behavior-bdd-contract-registration-validates-all-names ()
  "Due titoli con lo stesso nome ERT non registrano un corpus parziale."
  (let ((name 'gdev-bdd-contract-duplicate-first-))
    (gdev-bdd-contract--with-feature
        (file "Feature: Atomic\nScenario: First!\n Given known\nScenario: First?\n Given known\n")
      (unwind-protect
          (progn
            (should-error (gdev-bdd-register-feature file "gdev-bdd-contract-duplicate-" '(("known" . ignore))))
            (should-not (ert-test-boundp name)))
        (ert-make-test-unbound name)))))

(ert-deftest gdev-test-behavior-bdd-contract-registration-preserves-existing-tests ()
  "Una collisione conserva il test esistente e non pubblica quelli precedenti."
  (let* ((first 'gdev-bdd-contract-existing-first)
         (occupied 'gdev-bdd-contract-existing-second)
         (original (make-ert-test :name occupied :body #'ignore)))
    (ert-set-test occupied original)
    (gdev-bdd-contract--with-feature
        (file "Feature: Atomic\nScenario: First\n Given known\nScenario: Second\n Given known\n")
      (unwind-protect
          (progn
            (should-error (gdev-bdd-register-feature file "gdev-bdd-contract-existing-" '(("known" . ignore))))
            (should-not (ert-test-boundp first))
            (should (eq original (ert-get-test occupied))))
        (ert-make-test-unbound first)
        (ert-make-test-unbound occupied)))))

(ert-deftest gdev-test-behavior-bdd-contract-validates-before-setup ()
  "Una definizione mancante viene rifiutata prima di creare risorse."
  (let* ((step (make-ecukes-step :name "Given unknown" :body "unknown"))
         (scenario (make-ecukes-scenario :name "Unknown" :steps (list step)))
         (feature (make-ecukes-feature :scenarios (list scenario)))
         created cleaned)
    (should-error (gdev-bdd-run-scenario feature scenario nil
                                       (lambda () (setq created t))
                                       (lambda (_) (setq cleaned t))))
    (should-not created)
    (should-not cleaned)))

(provide 'gdev-bdd-contract-test)
;;; gdev-bdd-contract-test.el ends here
