;;; gdev-workbench-operations-test.el --- Verifiche di operazioni e aspetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verifica proprietà delle operazioni, interruzione e preferenze di aspetto.

;;; Code:

(require 'ert)
(require 'gdev-workbench-operations)

(ert-deftest gdev-test-workbench-operations-current-follows-the-owner-and-releases-a-closed-space ()
  (gdev-test--with-layout
    (should-not (gdev-workbench-operation-current nil))
    (let ((operation (gdev-workbench-operation-start "Operazione" nil)))
      (gdev-workbench-operation-report operation 'stopping)
      (tab-bar-new-tab)
      (should (eq 'running (gdev-workbench-operation-state operation)))
      (should (eq 'stopping (gdev-workbench-operation-state (gdev-workbench-operation-current operation))))
      (tab-bar-close-tab 1)
      (should-not (gdev-workbench-operation-current operation)))))

(ert-deftest gdev-test-workbench-operations-ignores-responses-after-completion-or-close ()
  "Gli aggiornamenti seguono lo spazio d'origine e l'esito è definitivo."
  (gdev-test--with-layout
    (let* ((operation (gdev-workbench-operation-start "Prima operazione" nil))
           (owner (gdev-workbench-operation-owner operation)))
      (tab-bar-new-tab)
      (gdev-workbench-operation-report operation 'running "Passo 2")
      (should-not (gdev-workspace-state-get 'gdev-workbench-operations))
      (let* ((tab (gdev-workspace-state-find owner))
             (saved (car (gdev-workspace-state-read 'gdev-workbench-operations tab))))
        (should (equal (gdev-workbench-operation-detail saved) "Passo 2")))
      (gdev-workbench-operation-report operation 'completed "Conclusa")
      (gdev-workbench-operation-report operation 'running "In ritardo")
      (tab-bar-select-tab 1)
      (let ((saved (car (gdev-workspace-state-get 'gdev-workbench-operations))))
        (should (eq (gdev-workbench-operation-state saved) 'completed))
        (should (equal (gdev-workbench-operation-detail saved) "Conclusa")))
      (tab-bar-select-tab 2)
      (tab-bar-close-tab 1)
      (should-not (gdev-workspace-state-find owner))
      (gdev-workbench-operation-report operation 'failed "Fuori tempo")
      (should-not (gdev-workspace-state-get 'gdev-workbench-operations)))))

(ert-deftest gdev-test-workbench-operations-tool-stop-in-the-origin-space ()
  "Uno strumento registra l'operazione nel suo spazio e la ferma con la propria azione."
  (gdev-test--with-layout
    (let ((owner (gdev-workspace-state-ensure-id))
          stopped)
      (tab-bar-new-tab)
      (let ((operation (gdev-workbench-operation-start
                        "Debug · prova" nil (lambda (item) (push item stopped)) owner)))
        (should-not (gdev-workspace-state-get 'gdev-workbench-operations))
        (should-not (gdev-workbench-operation-start "Spazio chiuso" nil nil (make-symbol "altro")))
        (tab-bar-select-tab 1)
        (should (equal (gdev-workspace-state-get 'gdev-workbench-operations) (list operation)))
        ;; Senza indicazione l'interruzione resta riservata ai processi.
        (should-error (gdev-workbench-operation-cancel) :type 'user-error)
        (should-not stopped)
        (with-temp-buffer
          (insert (propertize "Debug · prova" 'gdev-workbench-operation operation))
          (goto-char (point-min))
          (gdev-workbench-operation-cancel))
        (should (= (length stopped) 1))
        ;; Chi rinuncia alla conferma ritrova l'operazione in corso.
        (let ((declined (gdev-workbench-operation-start "Debug · rinuncia" nil #'ignore owner)))
          (with-temp-buffer
            (insert (propertize "Debug · rinuncia" 'gdev-workbench-operation declined))
            (goto-char (point-min))
            (gdev-workbench-operation-cancel))
          (should (eq (gdev-workbench-operation-state
                       (car (gdev-workspace-state-get 'gdev-workbench-operations)))
                      'running))
          (gdev-workbench-operation-finish declined t))
        (gdev-workbench-operation-finish operation nil "Codice 137")
        (let ((saved (car (gdev-workspace-state-get 'gdev-workbench-operations))))
          (should (eq (gdev-workbench-operation-state saved) 'cancelled))
          (should-not (gdev-workbench-operation-detail saved))))
      (let ((failed (gdev-workbench-operation-start "Debug · uscita" nil #'ignore owner)))
        (gdev-workbench-operation-finish failed nil "Codice 3")
        (let ((saved (car (gdev-workspace-state-get 'gdev-workbench-operations))))
          (should (eq (gdev-workbench-operation-state saved) 'failed))
          (should (equal (gdev-workbench-operation-detail saved) "Codice 3")))))))

(ert-deftest gdev-test-workbench-operations-keeps-active-and-recent-completions ()
  "Il limite dei risultati conserva le operazioni attive e l'ultimo esito."
  (gdev-test--with-layout
    (let* ((old (gdev-workbench-operation-start "Lunga" nil))
           (gdev-workbench-operations--recent-limit 2))
      (dotimes (step 4)
        (gdev-workbench-operation-report (gdev-workbench-operation-start (format "Breve %d" step) nil)
                                        'completed))
      (let ((records (gdev-workspace-state-get 'gdev-workbench-operations)))
        (should (= 3 (length records)))
        (should (memq old records)))
      (gdev-workbench-operation-report old 'completed)
      (should (equal (mapcar #'gdev-workbench-operation-label
                             (gdev-workspace-state-get 'gdev-workbench-operations))
                     '("Lunga" "Breve 3"))))))

(ert-deftest gdev-test-workbench-operations-cancel-real-compilation-in-its-space ()
  "L'interruzione da tastiera si limita allo spazio a cui appartiene il processo."
  (gdev-test--with-layout
    (let ((compilation-start-hook '(gdev-workbench-operation-compilation-start))
          output process)
      (unwind-protect
          (progn
            (setq output (gdev-compile "exec sleep 8" "Prova interruzione")
                  process (get-buffer-process output))
            (should (process-live-p process))
            (should (equal (gdev-workbench-operation-id (process-get process 'gdev-workbench-operation))
                           (gdev-workbench-operation-id (car (gdev-workspace-state-get 'gdev-workbench-operations)))))
            (tab-bar-new-tab)
            (should-error (gdev-workbench-operation-cancel) :type 'user-error)
            (should (process-live-p process))
            (tab-bar-select-tab 1)
            (gdev-workbench-operation-progress output "Avanzamento di prova")
            (should (equal "Avanzamento di prova"
                           (gdev-workbench-operation-detail (car (gdev-workspace-state-get 'gdev-workbench-operations)))))
            (gdev-workbench-operation-cancel)
            (gdev-test-launch--wait
             (lambda () (eq (gdev-workbench-operation-state
                             (car (gdev-workspace-state-get 'gdev-workbench-operations))) 'cancelled)))
            (should-not (process-live-p process)))
        (when (process-live-p process) (delete-process process))
        (when (buffer-live-p output) (kill-buffer output))))))

(ert-deftest gdev-test-workbench-appearance-choice-uses-shared-setter-and-save ()
  "La scelta nelle Preferenze applica l'aspetto e invalida una vecchia richiesta."
  (require 'gdev-preferences)
  (let ((gdev-macos-p t) (gdev-follow-system-appearance t)
        (gdev-ui--appearance-request 'superata) (gdev-ui--appearance 'light)
        saved)
    (cl-letf (((symbol-function 'gdev-ui-apply-appearance)
               (lambda (mode &optional _) (setq gdev-ui--appearance mode)))
              ((symbol-function 'customize-save-variable)
               (lambda (option value) (setq saved (cons option value)))))
      (with-temp-buffer
        (gdev-preferences-mode)
        (setq-local gdev-preferences--scope 'appearance)
        (gdev-preferences--render)
        (goto-char (text-property-any (point-min) (point-max) 'gdev-preferences-entry 'dark))
        (push-button)
        (should (eq gdev-ui--appearance 'dark))
        (should-not gdev-ui--appearance-request)
        (should (equal saved '(gdev-follow-system-appearance)))
        (should (eq 'gdev-ui-action-primary (button-get (button-at (point)) 'face)))))))

(ert-deftest gdev-test-workbench-operations-reports-unexpected-process-signal ()
  "La terminazione anomala del processo compare tra gli errori."
  (gdev-test--with-layout
    (let* ((compilation-start-hook '(gdev-workbench-operation-compilation-start))
           (output (gdev-compile "kill -TERM $$" "Prova segnale")))
      (unwind-protect
          (progn
            (gdev-test-launch--wait
             (lambda () (eq (gdev-workbench-operation-state
                             (car (gdev-workspace-state-get 'gdev-workbench-operations))) 'failed)))
            (should (equal "Segnale 15" (gdev-workbench-operation-detail
                                         (car (gdev-workspace-state-get 'gdev-workbench-operations))))))
        (when (buffer-live-p output) (kill-buffer output))))))

(provide 'gdev-workbench-operations-test)
;;; gdev-workbench-operations-test.el ends here
