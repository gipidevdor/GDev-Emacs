;;; gdev-org-agenda-git-test.el --- Cronologia Git nell'Agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica le date reali del reflog, il repository senza commit e i worktree.

;;; Code:

(require 'ert)
(require 'gdev-org-agenda-git)

(defvar gdev-org-calendar-context-root)

(defun gdev-test-org-agenda-git--run (&rest arguments)
  "Avvia Git con ARGUMENTS nel repository temporaneo corrente."
  (with-temp-buffer
    (let ((status (apply #'call-process "git" nil '(t t) nil arguments)))
      (unless (eq status 0) (error "Git %S: %s" arguments (buffer-string))))
    (string-trim-right (buffer-string))))

(defun gdev-test-org-agenda-git--read (root start end)
  "Attendi la lettura di Git per ROOT tra START ed END escluso."
  (let ((deadline (+ (float-time) 8)) done data)
    (gdev-org-agenda-git-request root start end (lambda (result) (setq data result done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should done)
    data))

(ert-deftest gdev-test-org-agenda-git-uses-reflog-date-and-linked-worktree ()
  "Una registrazione vecchia e un cambio di ramo hanno le proprie date."
  (skip-unless (executable-find "git"))
  (let* ((temporary (make-temp-file "gdev-agenda-git-test-" t))
         (worktree (expand-file-name "altra copia" temporary))
         (root (expand-file-name "progetto" temporary))
         (start (calendar-absolute-from-gregorian '(11 10 2026)))
         (end (1+ start))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (dolist (variable '("GIT_DIR" "GIT_WORK_TREE" "GIT_COMMON_DIR" "GIT_INDEX_FILE"))
            (setenv variable nil))
          (make-directory root)
          (with-temp-buffer
            (let ((default-directory (file-name-as-directory root)))
              (should-not (gdev-test-org-agenda-git--read root start end))
              (gdev-test-org-agenda-git--run "init" "-q" "-b" "main")
              ;; Invalidare la lettura precedente simula il comando di aggiornamento.
              (setq gdev-org-agenda-git--query nil)
              (let ((empty (gdev-test-org-agenda-git--read root start end)))
                (should (equal (plist-get empty :branch) "main"))
                (should-not (gdev-org-agenda-git--entries empty)))
              (gdev-test-org-agenda-git--run "config" "user.name" "Prova")
              (gdev-test-org-agenda-git--run "config" "user.email" "agenda")
              (gdev-test-org-agenda-git--run "config" "commit.gpgsign" "false")
              (let ((old-date (format "@%d +0000" (+ (gdev-org-agenda-git--timestamp (1- start)) 3600))))
                (setenv "GIT_AUTHOR_DATE" old-date)
                (setenv "GIT_COMMITTER_DATE" old-date)
                (gdev-test-org-agenda-git--run "commit" "--allow-empty" "-m" "Commit precedente"))
              (let ((current-date (format "@%d +0000" (+ (gdev-org-agenda-git--timestamp start) 3600))))
                (setenv "GIT_AUTHOR_DATE" current-date)
                (setenv "GIT_COMMITTER_DATE" current-date)
                (gdev-test-org-agenda-git--run "checkout" "-qb" "ramo-agenda")
                (setq gdev-org-agenda-git--query nil)
                (let* ((change (gdev-test-org-agenda-git--read root start end))
                       (entry (car (gdev-org-agenda-git--entries change))))
                  (should-not (plist-get change :commits))
                  (should (equal (gdev-org-agenda-git--action-title (plist-get entry :subject))
                                 "Cambio ramo · ramo-agenda"))
                  (should (= (plist-get entry :time) (+ (gdev-org-agenda-git--timestamp start) 3600))))
                (gdev-test-org-agenda-git--run "commit" "--allow-empty" "-m" "Commit di oggi")
                (gdev-test-org-agenda-git--run "worktree" "add" "-q" "-b" "ramo-copia" worktree)))
            (let* ((nested (file-name-as-directory (expand-file-name "src" worktree)))
                   (default-directory (file-name-as-directory worktree))
                   (git-directory (gdev-test-org-agenda-git--run "rev-parse" "--absolute-git-dir")))
              (make-directory nested)
              (write-region "" nil (expand-file-name "MERGE_HEAD" git-directory) nil 'silent)
              (let ((data (gdev-test-org-agenda-git--read nested start end)))
                (should (file-equal-p (plist-get data :root) worktree))
                (should (equal (plist-get data :branch) "ramo-copia"))
                (should (equal (plist-get data :operation) "Unione in corso"))
                (should (equal (mapcar (lambda (entry) (plist-get entry :subject)) (plist-get data :commits))
                               '("Commit di oggi")))
                (should (eq data (gdev-test-org-agenda-git--read nested start end)))))))
      (delete-directory temporary t))))

(ert-deftest gdev-test-org-agenda-git-summary-links-to-visible-period ()
  "Il collegamento Git conserva lo stato e sposta il fuoco nel periodo corretto."
  (with-temp-buffer
    (let* ((start (calendar-absolute-from-gregorian '(11 10 2026)))
           (end (1+ start))
           (root default-directory)
           (gdev-org-calendar-context-root root)
           (gdev-org-agenda-git--query (list root start end))
           (gdev-org-agenda-git--data (list :root root :branch "principale" :operation "Unione in corso")))
      (gdev-org-agenda-git-insert-summary 18 end (1+ end))
      (should (= (point-min) (point-max)))
      (gdev-org-agenda-git-insert-summary 18 start end)
      (goto-char (point-min))
      (let ((summary (button-at (point))))
        (should (equal (button-get summary 'gdev-org-calendar-item) '(git summary)))
        (forward-line 1)
        (should (equal (get-text-property (point) 'help-echo) "Unione in corso"))
        (goto-char (point-max))
        (gdev-org-agenda-git-insert start end)
        (button-activate summary)
        (should (equal (get-text-property (point) 'gdev-org-calendar-item) '(git status)))))))

(provide 'gdev-org-agenda-git-test)
;;; gdev-org-agenda-git-test.el ends here
