;;; gdev-codex-test.el --- Contratti della sessione Codex -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'gdev-codex)

(ert-deftest gdev-test-codex-mcp-is-independent-of-the-external-project ()
  (let* ((root "/external/a project/")
         (arguments (gdev-codex--arguments root)))
    (should (equal (seq-take arguments 3) (list "--cd" root "--no-alt-screen")))
    (should (member (concat "mcp_servers.gdev.command="
                           (json-serialize (expand-file-name "bin/gdev-mcp" gdev-config-directory))) arguments))
    (should-not (seq-some (lambda (arg) (string-match-p "bypass\\|approval\\|sandbox" arg)) arguments))
    (should (equal "resume" (car (last (gdev-codex--arguments root t)))))
    (should-not (equal (gdev-codex--name "/one/project/") (gdev-codex--name "/two/project/")))))

(ert-deftest gdev-test-codex-missing-tools-and-stop-without-session-are-actionable ()
  (let ((gdev-codex-executable "gdev-nonexistent-codex")
        (gdev-codex-root default-directory))
    (should-error (gdev-codex) :type 'user-error)
    (should-error (gdev-codex-stop) :type 'user-error)))

(ert-deftest gdev-test-codex-stop-targets-only-the-current-project ()
  (let* ((gdev-codex-root default-directory)
         (root (gdev-codex--root))
         (buffer (get-buffer-create (concat "*" (gdev-codex--name root) "*")))
         (process (start-process "codex-fixture" buffer "cat"))
         (other (start-process "codex-other" nil "cat")))
    (with-current-buffer buffer (setq-local gdev-codex-root root))
    (unwind-protect
        (progn (gdev-codex-stop) (should-not (process-live-p process)) (should (process-live-p other)))
      (delete-process other)
      (kill-buffer buffer))))

(ert-deftest gdev-test-codex-preserves-a-buffer-with-the-same-display-name ()
  (let* ((gdev-codex-root default-directory)
         (root (gdev-codex--root))
         (buffer (get-buffer-create (concat "*" (gdev-codex--name root) "*"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "User content"))
          (should-error (gdev-codex--buffer root) :type 'user-error)
          (should-error (gdev-codex-stop) :type 'user-error)
          (should (equal "User content" (with-current-buffer buffer (buffer-string)))))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(provide 'gdev-codex-test)
