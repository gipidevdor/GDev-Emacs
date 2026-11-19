;;; gdev-agent-session-test.el --- Verifica arresto e ripristino -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La suite GDev carica queste prove dopo avere definito
;; `gdev-test--with-layout'. I processi di prova restano locali.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun gdev-agent-test--start-process (buffer)
  "Avvia un processo vivo associato a BUFFER per verificare l'arresto."
  (let ((sleep-command (executable-find "sleep")))
    (unless sleep-command (ert-skip "Comando sleep assente"))
    (make-process :name "gdev-agente-prova" :buffer buffer
                  :command (list sleep-command "30") :noquery nil)))

(defun gdev-agent-test--load-package ()
  "Attiva il fork incluso e le sue dipendenze senza avviare Claude."
  (require 'package)
  (package-activate-all)
  (require 'claude-code-ide))

(ert-deftest gdev-test-agent-stop-cancel-keeps-running-session ()
  "Annullare l'arresto lascia vivi il terminale e il processo reale."
  (gdev-agent-test--load-package)
  (let ((buffer (generate-new-buffer "*claude-arresto*"))
        process messages)
    (unwind-protect
        (progn
          (setq process (gdev-agent-test--start-process buffer))
          (let ((session (make-claude-code-ide-mcp-session
                          :instance-name "Prova" :buffer buffer :process process)))
            (cl-letf (((symbol-function 'claude-code-ide--resolve-session) (lambda (&rest _) session))
                      ((symbol-function 'claude-code-ide--session-display-name) (lambda (_) "Prova"))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                      ((symbol-function 'claude-code-ide-log)
                       (lambda (format-string &rest args) (push (apply #'format format-string args) messages))))
              (call-interactively #'claude-code-ide-stop))
            (should (buffer-live-p buffer))
            (should (process-live-p process))
            (should (equal (car messages) "Sessione di Claude Code «Prova» mantenuta"))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest gdev-test-agent-stop-all-confirms-once-and-counts-closed-sessions ()
  "Un assenso basta e il riepilogo conta le sessioni davvero chiuse."
  (gdev-agent-test--load-package)
  (let ((buffers (list (generate-new-buffer "*claude-vincolo*")
                       (generate-new-buffer "*claude-chiusura*")))
        (confirm-kill-processes t)
        processes sessions messages
        (prompts 0))
    (unwind-protect
        (progn
          (dolist (buffer buffers)
            (let ((process (gdev-agent-test--start-process buffer)))
              (push process processes)
              (push (make-claude-code-ide-mcp-session :buffer buffer :process process) sessions)))
          (with-current-buffer (car buffers)
            (add-hook 'kill-buffer-query-functions #'ignore nil t))
          (cl-letf (((symbol-function 'claude-code-ide-mcp--active-sessions) (lambda () sessions))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf prompts)))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf prompts)))
                    ((symbol-function 'claude-code-ide-log)
                     (lambda (format-string &rest args) (push (apply #'format format-string args) messages))))
            (claude-code-ide-stop-all t))
          (should (= prompts 1))
          (should (buffer-live-p (car buffers)))
          (should (process-query-on-exit-flag (get-buffer-process (car buffers))))
          (should-not (buffer-live-p (cadr buffers)))
          (should (equal (car messages) "Sessioni di Claude Code terminate (1 di 2)")))
      (dolist (process processes)
        (when (process-live-p process) (delete-process process)))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (setq-local kill-buffer-query-functions nil))
          (kill-buffer buffer))))))

(ert-deftest gdev-test-agent-panel-quit-and-restores-draft ()
  "Annulla l'uscita con un terminale attivo, poi conserva solo l'editor."
  (require 'gdev-commands)
  (require 'gdev-workspaces)
  (gdev-test--with-layout
    (let* ((gdev-state-directory (make-temp-file "gdev-agent-uscita-" t))
           (gdev-workspaces--session-active nil)
           (gdev-session-hot-exit-function #'gdev-workspaces-quit)
           (gdev-session-load-function #'gdev-workspaces-restore)
           (gdev-drafts-hot-exit t)
           (confirm-kill-processes t)
           (kill-emacs-query-functions nil)
           (save-some-buffers-functions nil)
           (process-buffer (generate-new-buffer "*claude-uscita*"))
           (file (gdev-state-file "documento.txt"))
           (flag (gdev-state-file "restore-session-on-start"))
           (snapshot (gdev-state-file "gdev-workspaces.eld"))
           document process confirm prompts exited)
      (unwind-protect
          (progn
            (with-temp-file file (insert "Sul disco\n"))
            (tab-bar-rename-tab "Riprendi il progetto")
            (gdev-open-file file)
            (setq document (current-buffer))
            (insert "Bozza\n")
            (setq process (gdev-agent-test--start-process process-buffer))
            (let ((panel (display-buffer process-buffer)))
              (select-window panel)
              (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (setq exited t)))
                        ((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt prompts) confirm)))
                (call-interactively #'gdev-quit)
                (should-not exited)
                (should-not (file-exists-p flag))
                (should-not (file-exists-p snapshot))
                (should (process-live-p process))
                (should (eq (selected-window) panel))
                (should (string-search "processi attivi" (car prompts)))
                (setq confirm t)
                (call-interactively #'gdev-quit)
                (should exited)
                (should (file-exists-p flag))
                (should (file-exists-p snapshot))))
            (delete-process process)
            (kill-buffer process-buffer)
            (select-window (gdev-layout-editor))
            (with-current-buffer document (set-buffer-modified-p nil))
            (kill-buffer document)
            (switch-to-buffer "*scratch*")
            (set-frame-parameter nil 'tabs nil)
            (gdev-session--restore-on-start)
            (setq document (find-buffer-visiting file))
            (should-not (file-exists-p flag))
            (should (eq document (window-buffer (gdev-layout-editor))))
            (should (equal (with-current-buffer document (buffer-string)) "Bozza\nSul disco\n"))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "Sul disco\n"))
            (should-not (gdev-layout--panel)))
        (when (process-live-p process) (delete-process process))
        (when (buffer-live-p process-buffer) (kill-buffer process-buffer))
        (when (buffer-live-p document)
          (with-current-buffer document (set-buffer-modified-p nil))
          (kill-buffer document))
        (delete-directory gdev-state-directory t)))))

;;; gdev-agent-session-test.el ends here
