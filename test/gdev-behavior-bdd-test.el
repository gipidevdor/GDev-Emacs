;;; gdev-behavior-bdd-test.el --- Scenari BDD del banco di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Gli scenari usano i comandi GDev e i fork locali, con file e buffer
;; propri. I tasti passano per il ciclo dei comandi di Emacs.

;;; Code:

(load (gdev-config-file "test/gdev-bdd.el") nil t t)

(defun gdev-behavior-bdd--setup ()
  "Prepara un documento isolato, conservando la disposizione precedente."
  (require 'gdev-commands)
  (require 'multiple-cursors)
  (require 'elec-pair)
  (require 'hideshow)
  (load (gdev-module-file :editor 'fold ".el") nil t t)
  (load (gdev-module-file :editor 'multiple-cursors ".el") nil t t)
  (let* ((root (make-temp-file "gdev-bdd-" t))
         (file (expand-file-name "documento.js" root))
         (buffer (generate-new-buffer "gdev-bdd-documento"))
         (windows (current-window-configuration)))
    (switch-to-buffer buffer)
    (gdev-layout-mark-document)
    (js-mode)
    (setq-local js-indent-level 2
                buffer-file-name file
                create-lockfiles nil
                backup-inhibited t)
    (buffer-enable-undo)
    (electric-pair-local-mode 1)
    (hs-minor-mode 1)
    (list root buffer windows (make-hash-table))))

(defun gdev-behavior-bdd--cleanup (context)
  "Rimuovi esclusivamente i file e i buffer di CONTEXT."
  (when context
    (pcase-let ((`(,root ,buffer ,windows . ,_) context))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (bound-and-true-p multiple-cursors-mode) (gdev-cursors-exit))
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (set-window-configuration windows)
      (delete-directory root t))))

(defconst gdev-behavior-bdd--definitions
  `(("un documento con testo \\(\".*\"\\)" .
     ,(lambda (_context text)
        (insert (json-parse-string text))
        (write-region (point-min) (point-max) buffer-file-name nil 'silent)
        (set-buffer-modified-p nil)
        (setq buffer-undo-list nil)))
    ("un documento Python con testo \\(\".*\"\\)" .
     ,(lambda (context text)
        (python-mode)
        (setq-local python-indent-offset 4 python-indent-guess-indent-offset nil indent-tabs-mode nil)
        (when (bound-and-true-p flymake-mode) (flymake-mode -1))
        (funcall (cdr (assoc "un documento con testo \\(\".*\"\\)" gdev-behavior-bdd--definitions)) context text)))
    ("inserisco \\(\".*\"\\)" .
     ,(lambda (_context text) (undo-boundary) (insert (json-parse-string text)) (undo-boundary)))
    ("salvo il documento" . ,(lambda (_) (gdev-save-document)))
    ("il file contiene \\(\".*\"\\)" .
     ,(lambda (_context text)
        (let ((file buffer-file-name))
          (with-temp-buffer
            (insert-file-contents file)
            (expect (buffer-string) :to-equal (json-parse-string text))))))
    ("il documento contiene \\(\".*\"\\)" .
     ,(lambda (_context text) (expect (buffer-string) :to-equal (json-parse-string text))))
    ("il documento risulta salvato" . ,(lambda (_) (expect (buffer-modified-p) :not :to-be-truthy)))
    ("annullo la modifica" . ,(lambda (_) (undo-boundary) (let ((last-command nil)) (gdev-undo))))
    ("ripeto la modifica" . ,(lambda (_) (gdev-redo)))
    ("piego tutti i blocchi" . ,(lambda (_) (goto-char (point-min)) (gdev-fold-toggle-all)))
    ("riapro tutti i blocchi" . ,(lambda (_) (gdev-fold-toggle-all)))
    ("un blocco è nascosto" .
     ,(lambda (_) (expect (cl-some (lambda (overlay) (overlay-get overlay 'hs))
                                  (overlays-in (point-min) (point-max))) :to-be-truthy)))
    ("nessun blocco è nascosto" .
     ,(lambda (_) (expect (cl-some (lambda (overlay) (overlay-get overlay 'hs))
                                  (overlays-in (point-min) (point-max))) :not :to-be-truthy)))
    ("aggiungo un cursore per riga" .
     ,(lambda (_) (goto-char (point-min)) (push-mark (1- (point-max)) t t) (mc/edit-lines)))
    ("scrivo \\(\".*\"\\) da tastiera" .
     ,(lambda (_context text) (execute-kbd-macro (json-parse-string text))))
    ("esco dai cursori multipli" . ,(lambda (_) (gdev-cursors-exit)))
    ("resta un solo cursore" .
     ,(lambda (_) (expect multiple-cursors-mode :not :to-be-truthy) (expect (mc/all-fake-cursors) :to-equal nil)))
    ("il cursore è tra le parentesi" . ,(lambda (_) (expect (point) :to-equal 2)))
    ("il cursore è dopo le parentesi" . ,(lambda (_) (expect (point) :to-equal 3)))
    ("premo indietro" . ,(lambda (_) (execute-kbd-macro (kbd "DEL"))))
    ("torno all'inizio" . ,(lambda (_) (goto-char (point-min))))
    ("vado alla riga \\([0-9]+\\)" . ,(lambda (_ line) (goto-char (point-min)) (forward-line (1- (string-to-number line)))))
    ("premo TAB" . ,(lambda (_) (execute-kbd-macro (kbd "TAB"))))
    ("commento la riga" . ,(lambda (_) (beginning-of-line) (comment-line 1) (forward-line -1)))
    ("taglio la prima riga" . ,(lambda (_) (kill-whole-line)))
    ("incollo il testo tagliato" . ,(lambda (_) (yank)))
    ("proteggo il documento" . ,(lambda (_) (setq buffer-read-only t)))
    ("scrivere da tastiera viene rifiutato" . ,(lambda (_) (should-error (execute-kbd-macro "x") :type 'buffer-read-only)))
    ("ricordo la posizione" . ,(lambda (context) (puthash 'point (point) (nth 3 context))))
    ("la posizione è conservata" . ,(lambda (context) (expect (point) :to-equal (gethash 'point (nth 3 context)))))
    ("il documento ha modifiche non salvate" . ,(lambda (_) (expect (buffer-modified-p) :to-be-truthy)))
    ("il file sul disco diventa \\(\".*\"\\)" .
     ,(lambda (_ text)
        (let ((file buffer-file-name)) (with-temp-file file (insert (json-parse-string text))))))
    ("ricarico il documento" . ,(lambda (_) (gdev-reload-document)))
    ("annullo il ricaricamento" .
     ,(lambda (_)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (gdev-reload-document))))
    ("confermo il ricaricamento" .
     ,(lambda (_)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (gdev-reload-document))))
    ("sposto la riga in alto" . ,(lambda (_) (gdev-sposta-testo-su 1)))
    ("espando lo snippet con nome \\(\".*\"\\)" .
     ,(lambda (_ text)
        (require 'yasnippet)
        (yas-minor-mode 1)
        (yas-expand-snippet (concat "${1:" (json-parse-string text) "} = $1$0"))))
    ("scrivo \\(\".*\"\\) nel primo campo" . ,(lambda (_ text) (insert (json-parse-string text)) (yas-exit-all-snippets))))
  "Vocabolario condiviso degli scenari di editing.")

(gdev-bdd-register-feature
 (expand-file-name "editor.feature" gdev-behavior-directory)
 "gdev-test-behavior-bdd-" gdev-behavior-bdd--definitions
 #'gdev-behavior-bdd--setup #'gdev-behavior-bdd--cleanup)

(ert-deftest gdev-test-behavior-bdd-propagates-failure-pending-and-cleanup ()
  "Un BDD fallito o pendente fallisce in ERT e svolge comunque la pulizia."
  (let* ((step (make-ecukes-step :name "Then fallisce" :body "fallisce"))
         (scenario (make-ecukes-scenario :name "Prova negativa" :steps (list step)))
         (feature (make-ecukes-feature :scenarios (list scenario))))
    (dolist (body (list (lambda (_) (expect 1 :to-equal 2))
                       (lambda (_) (buttercup-skip "non eseguito"))))
      (let (cleaned)
        (should-error (gdev-bdd-run-scenario
                       feature scenario (list (cons "fallisce" body))
                       (lambda () 'contesto) (lambda (context) (setq cleaned context)))
                      :type 'ert-test-failed)
        (should (eq cleaned 'contesto))))
    (should-error (gdev-bdd--match step nil))
    (should-error (gdev-bdd--match step (list (cons ".*" #'ignore) (cons "fallisce" #'ignore))))))

(ert-deftest gdev-test-behavior-gherkin-outlines-and-strict-validation ()
  "Background e outline producono casi reali; righe sconosciute falliscono."
  (let ((file (make-temp-file "gdev-gherkin-" nil ".feature"))
        (created 0) (cleaned 0))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "Funzionalità: Somme\n\nContesto:\n  Dato contesto vuoto\n\n"
                    "Schema dello scenario: Somma <a> e <b>\n"
                    "  Quando sommo <a> e <b>\n  Allora il totale è <totale>\n\n"
                    "Esempi:\n  | a | b | totale |\n  | 1 | 2 | 3 |\n  | 3 | 5 | 8 |\n"))
          (let* ((feature (gdev-gherkin-read file))
                 (definitions
                  (list
                   (cons "contesto vuoto" (lambda (context) (puthash 'total 0 context)))
                   (cons "sommo \\([0-9]+\\) e \\([0-9]+\\)"
                         (lambda (context a b) (puthash 'total (+ (string-to-number a) (string-to-number b)) context)))
                   (cons "il totale è \\([0-9]+\\)"
                         (lambda (context total) (expect (gethash 'total context) :to-equal (string-to-number total)))))))
            (should (= 2 (length (ecukes-feature-scenarios feature))))
            (dolist (scenario (ecukes-feature-scenarios feature))
              (gdev-bdd-run-scenario feature scenario definitions
                                     (lambda () (cl-incf created) (make-hash-table))
                                     (lambda (_) (cl-incf cleaned)))))
          (should (= created 2))
          (should (= cleaned 2))
          (dolist (text '("Feature: Empty\n"
                          "Feature: Broken\nScenario: No steps\n"
                          "Feature: Broken\nScenario: Typo\n Given a step\n Thne a typo\n"
                          "Feature: Broken\nScenario: String\n Given a step\n \"\"\"\nunfinished\n"))
            (with-temp-file file (insert text))
            (should-error (gdev-gherkin-read file))))
      (delete-file file))))

(ert-deftest gdev-test-behavior-bdd-loads-local-forks ()
  "Buttercup e il parser Gherkin provengono dai fork del checkout."
  (dolist (entry '((buttercup-fail . buttercup) (gdev-gherkin-read . gdev-gherkin)
                   (ecukes-parse-feature . gdev-gherkin)))
    (should (file-in-directory-p (symbol-file (car entry) 'defun)
                                 (gdev-bundled-package-directory (cdr entry))))))

(ert-deftest gdev-test-behavior-bdd-preserves-locally-handled-errors ()
  "Un errore gestito dal codice chiamato non diventa il fallimento del BDD."
  (let ((debug-on-error t))
    (should (equal (buttercup--funcall
                    (lambda ()
                      (condition-case-unless-debug _err
                          (error "Errore previsto e gestito")
                        (error 'recuperato))))
                   '(passed recuperato nil)))))

(load (gdev-config-file "test/gdev-bdd-contract-test.el") nil t t)

(provide 'gdev-behavior-bdd-test)
;;; gdev-behavior-bdd-test.el ends here
