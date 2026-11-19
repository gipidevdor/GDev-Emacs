;;; gdev-ergonomics-test.el --- Ergonomia e letture del Workbench -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le consultazioni non ricalcolano verifiche; i controlli restano attuali.
;;; Code:
(require 'ert)
(defvar native-comp-enable-subr-trampolines)

(ert-deftest gdev-test-assurance-view-keeps-informational-reads-small ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-evidence-add db id :kind 'fact :description "Rapporto lungo"
                         :content (make-string 200000 ?x) :actor "a" :actor-kind 'agent)
      (gdev-standard-select db id '("nist-ir-8397#@document") "Scelta della fixture"
                            :actor "persona" :actor-kind 'human)
      (cl-letf (((symbol-function 'gdev-assessment-run) (lambda (&rest _) (ert-fail "Valutazione durante la consultazione")))
                ((symbol-function 'gdev-process-events) (lambda (&rest _) (ert-fail "Storia durante la consultazione")))
                ((symbol-function 'gdev-evidence-list) (lambda (&rest _) (ert-fail "Prove durante la consultazione"))))
        (dolist (section '(transactions standards taxonomy procedures runs documents))
          (let* ((detail (unless (memq section '(transactions documents)) (symbol-name section)))
                 (data (gdev-assurance-project-data root id detail nil 30 section))
                 (tx (alist-get 'transaction (alist-get 'show data))))
            (should-not (alist-get 'assessment data))
            (should (equal id (alist-get 'id tx)))
            (should (equal ["nist-ir-8397#@document"] (alist-get 'standard_targets tx)))
            (should (= 1 (length (alist-get 'transactions (alist-get 'transactions data)))))
            (when (eq section 'transactions) (should (< (string-bytes (json-serialize data)) 10000)))))))))

(ert-deftest gdev-test-assurance-view-controls-and-full-data-recheck-sources ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)) (calls 0))
      (cl-letf (((symbol-function 'gdev-assessment-run)
                 (lambda (&rest _) (cl-incf calls) '((current . t)))))
        (should (alist-get 'current (alist-get 'assessment (gdev-assurance-project-data root id))))
        (should (alist-get 'current (alist-get 'assessment (gdev-assurance-project-data root id nil nil 30 'controls))))
        (should (= calls 2)))
      (should-error (gdev-assurance-project-data root id nil nil 30 'unknown) :type 'user-error))))

(ert-deftest gdev-test-assurance-ui-actions-use-unverified-choice-metadata ()
  "Prove e decisioni restano disponibili senza fabbricare una valutazione."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'quality)) written)
      (gdev-standard-select db id '("nist-ir-8397#@document") "Fixture"
                            :actor "persona" :actor-kind 'human)
      (gdev-test-assurance-ui--view root
        (setq gdev-assurance--transaction id
              gdev-assurance--model (gdev-assurance-project-data root id nil nil 30 'transactions))
        (should-not (alist-get 'assessment gdev-assurance--model))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_ choices &rest _) (should (member "nist-ir-8397#@document" choices))
                     "nist-ir-8397#@document")))
          (should (equal "nist-ir-8397#@document" (gdev-assurance--read-target nil))))
        (let ((control (alist-get 'control
                                 (seq-find (lambda (row) (eq t (alist-get 'decidable row)))
                                           (alist-get 'profile_controls
                                                      (alist-get 'transaction (alist-get 'show gdev-assurance--model)))))))
          (should control)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_ choices &rest _) (if (member control choices) control "Non applicabile")))
                    ((symbol-function 'read-string) (lambda (&rest _) "Motivo"))
                    ((symbol-function 'gdev-assurance--write) (lambda (_ command operands) (setq written (cons command operands)))))
            (gdev-assurance-control-decision))
          (should (equal "decision" (car written)))
          (should (equal control (nth 2 written))))))))

(ert-deftest gdev-test-assurance-ui-compact-navigation-and-filter-reset ()
  (with-temp-buffer
    (gdev-assurance-mode)
    (setq gdev-assurance--root "/prova/" gdev-assurance--section 'standards
          gdev-assurance--model '((status . ((archive . :false))) (detail . ((standards . [])))))
    (let ((width 40))
      (cl-letf (((symbol-function 'gdev-ui-buffer-pixel-width) (lambda (&rest _) width))
                ((symbol-function 'gdev-ui-string-pixel-width) (lambda (text) (string-width text)))
                ((symbol-function 'gdev-assurance-data) (lambda (&rest _) (ert-fail "Lettura durante un ridisegno"))))
        (gdev-assurance--render)
        (should (string-search "Sezione: Standard…" (buffer-string)))
        (should (eq (keymap-lookup gdev-assurance-mode-map "S") #'gdev-assurance-section))
        (setq width 96)
        (gdev-assurance--render)
        (should-not (string-search "Sezione:" (buffer-string)))
        (dolist (entry gdev-assurance--sections) (should (string-search (cdr entry) (buffer-string))))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_ choices &rest arguments)
                     (should (= 13 (length choices)))
                     (should (equal "Standard" (nth 4 arguments)))
                     "Procedure"))
                  ((symbol-function 'gdev-assurance-refresh) #'ignore))
          (call-interactively (keymap-lookup gdev-assurance-mode-map "S")))
        (should (eq 'procedures gdev-assurance--section))
        (setq gdev-assurance--section 'standards)
        (setq width 40 gdev-assurance--filter (make-string 300 ?è))
        (gdev-assurance--render)
        (let ((button (gdev-test-assurance-ui--button '(filter))))
          (should (<= (string-width (button-label button)) width))
          (should (equal (button-get button 'help-echo) (concat "Filtro: " gdev-assurance--filter))))
        (should (gdev-test-assurance-ui--button '(filter clear)))
        (call-interactively (keymap-lookup gdev-assurance-mode-map "F"))
        (should (string-empty-p gdev-assurance--filter))
        (should-not (gdev-test-assurance-ui--button '(filter clear)))
        (setq gdev-assurance--filter "precedente")
        (gdev-assurance--render)
        (button-activate (gdev-test-assurance-ui--button '(filter clear)))
        (should (string-empty-p gdev-assurance--filter))
        (setq gdev-assurance--filter "conservato")
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (signal 'quit nil))))
          (should (eq 'cancelled (condition-case nil (gdev-assurance-filter) (quit 'cancelled)))))
        (should (equal "conservato" gdev-assurance--filter))))))

(ert-deftest gdev-test-assurance-ui-page-focus-follows-visible-data ()
  (with-temp-buffer
    (gdev-assurance-mode)
    (setq gdev-assurance--root "/prova/" gdev-assurance--section 'standards
          gdev-assurance--model
          `((detail . ((standards . ,(vconcat
                                      (cl-loop for number from 1 to 65 collect
                                               `((id . ,(format "S%d" number)) (title . "Standard")
                                                 (edition . "1") (scope . "Fixture") (target_count . 0)))))))))
    (gdev-assurance--render)
    (gdev-assurance-next)
    (should (equal '(standard "S31") (get-text-property (point) 'gdev-assurance-row)))
    (gdev-assurance-previous)
    (should (equal '(standard "S1") (get-text-property (point) 'gdev-assurance-row)))
    (let ((before (point))) (gdev-assurance-previous) (should (= before (point))))))

(ert-deftest gdev-test-assurance-ui-reader-handles-immediate-result-and-startup-error ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (let ((native-comp-enable-subr-trampolines nil)
            (create (symbol-function 'make-process)) output diagnostics command)
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest arguments)
                     (setq output (plist-get arguments :buffer) diagnostics (plist-get arguments :stderr)
                           command (plist-get arguments :command))
                     (let ((process (apply create (plist-put arguments :command
                                                           '("/usr/bin/printf" "{\"status\":{\"archive\":true}}"))))
                           (deadline (+ (float-time) 5)))
                       (while (and (process-live-p process) (< (float-time) deadline)) (accept-process-output nil 0.01))
                       (should (eq (process-status process) 'exit))
                       process))))
          (gdev-assurance--read-async))
        (should-not gdev-assurance--reader-process)
        (should-not gdev-assurance--error)
        (should (eq t (alist-get 'archive (alist-get 'status gdev-assurance--model))))
        (should (equal "transactions" (car (last command))))
        (should-not (buffer-live-p output))
        (should-not (buffer-live-p diagnostics))
        (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (signal 'file-error '("Fixture")))))
          (gdev-assurance--read-async))
        (should-not gdev-assurance--reader-process)
        (should (string-search "Impossibile leggere" gdev-assurance--error))))))

(ert-deftest gdev-test-assurance-ui-reader-drains-terminal-output-once ()
  "Il risultato già terminato viene consegnato dopo il pipe, anche con rientro."
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (let* ((native-comp-enable-subr-trampolines nil)
             (process (make-process :name "gdev-reader-finished-test" :buffer nil
                                    :command '("/usr/bin/true") :noquery t :sentinel #'ignore))
             (accept (symbol-function 'accept-process-output))
             output diagnostics delivered)
        (while (process-live-p process) (accept-process-output process 0.01))
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest arguments)
                     (setq output (plist-get arguments :buffer) diagnostics (plist-get arguments :stderr))
                     process))
                  ((symbol-function 'accept-process-output)
                   (lambda (&optional target &rest arguments)
                     (if (not (eq target process)) (apply accept target arguments)
                       (unless delivered
                         (setq delivered t)
                         (with-current-buffer output (insert "{\"status\":{\"archive\":true}}"))
                         (funcall (process-sentinel process) process "finished\n")
                         (should (buffer-live-p output))
                         t)))))
          (gdev-assurance--read-async))
        (should delivered)
        (should-not gdev-assurance--error)
        (should (eq t (alist-get 'archive (alist-get 'status gdev-assurance--model))))
        (should-not (buffer-live-p output))
        (should-not (buffer-live-p diagnostics))
        (funcall (process-sentinel process) process "finished\n")
        (should-not gdev-assurance--error)))))

(ert-deftest gdev-test-cli-bench-refuses-invalid-counts-before-starting ()
  "Un conteggio non valido non avvia Emacs e non lascia file temporanei."
  (require 'gdev-cli)
  (let ((native-comp-enable-subr-trampolines nil))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Avvio non richiesto")))
              ((symbol-function 'make-temp-file) (lambda (&rest _) (ert-fail "File non necessario"))))
      (dolist (value '("" "0" "-1" "abc" "1.5" " 3 "))
        (should-error (gdev-cli-bench value) :type 'user-error)))))

(provide 'gdev-ergonomics-test)
;;; gdev-ergonomics-test.el ends here
