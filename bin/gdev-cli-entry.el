;;; gdev-cli-entry.el --- Avvio della riga di comando di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Prepara lo stato temporaneo per audit prima di caricare early-init.el.

;;; Code:

(defconst gdev-cli-entry--root
  (file-name-directory
   (directory-file-name (file-name-directory (file-truename load-file-name)))))

(declare-function gdev-cli-main "../lisp/gdev-cli" ())
(defvar gdev-state-maintenance-startup nil)

(defun gdev-cli-entry--run ()
  "Prepara i percorsi e invoca il comando richiesto."
  (let ((gdev-state-maintenance-startup (equal (car command-line-args-left) "stato")))
    (load (expand-file-name "early-init.el" gdev-cli-entry--root) nil t t))
  (load (expand-file-name "lisp/gdev-cli.el" gdev-cli-entry--root) nil t t)
  (gdev-cli-main))

(defun gdev-cli-entry ()
  "Isola inventario e test prima di leggere early-init.el."
  (let ((kill-emacs-hook kill-emacs-hook))
    (kill-emacs
     (if (member (car command-line-args-left) '("audit" "test"))
         (let ((directory (make-temp-file "gdev-audit-" t))
               (process-environment (copy-sequence process-environment)))
           (unwind-protect
               (progn
                 (when (and (equal (car command-line-args-left) "test")
                            (not (getenv "GDEV_TEST_GRAMMARS")))
                   (let* ((base (or (getenv "GDEV_STATE_DIR")
                                    (expand-file-name "gdev-emacs/" (or (getenv "XDG_STATE_HOME")
                                                                        "~/.local/state/"))))
                          (profile (getenv "GDEV_PROFILE"))
                          (state (if profile (expand-file-name (concat "profiles/" profile) base) base))
                          (grammars (expand-file-name "tree-sitter/" state)))
                     (when (file-directory-p grammars) (setenv "GDEV_TEST_GRAMMARS" grammars))))
                 (setenv "GDEV_PROFILE" nil)
                 (setenv "GDEV_STATE_DIR" (expand-file-name "stato" directory))
                 (setenv "GDEV_USER_DIR" (expand-file-name "configurazione" directory))
                 (gdev-cli-entry--run))
             ;; I moduli possono registrare salvataggi durante i test. Devono
             ;; terminare prima che lo stato temporaneo venga rimosso.
             (with-demoted-errors "Chiusura della prova: %S" (run-hooks 'kill-emacs-hook))
             (setq kill-emacs-hook nil)
             (delete-directory directory t)))
       (gdev-cli-entry--run)))))

;;; gdev-cli-entry.el ends here
