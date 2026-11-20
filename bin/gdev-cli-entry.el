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
  "Esegui la CLI, isolando l'inventario prima di leggere early-init.el."
  (kill-emacs
   (if (equal (car command-line-args-left) "audit")
       (let ((directory (make-temp-file "gdev-audit-" t))
             (process-environment (copy-sequence process-environment)))
         (unwind-protect
             (progn
               (setenv "GDEV_PROFILE" nil)
               (setenv "GDEV_STATE_DIR" (expand-file-name "stato" directory))
               (setenv "GDEV_USER_DIR" (expand-file-name "configurazione" directory))
               (gdev-cli-entry--run))
           (delete-directory directory t)))
     (gdev-cli-entry--run))))

;;; gdev-cli-entry.el ends here
