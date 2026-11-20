;;; gdev-agent-entry.el --- Avvio isolato degli strumenti per agenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La scoperta deve leggere i sorgenti senza inizializzare il profilo.
;; Isola le cache prima di caricare le librerie, anche con Emacs -Q.

;;; Code:

(defconst gdev-agent-entry--root
  (file-name-directory
   (directory-file-name (file-name-directory (file-truename load-file-name)))))

(defvar native-comp-eln-load-path)
(defvar native-comp-jit-compilation)
(defvar native-comp-enable-subr-trampolines)
(declare-function gdev-agent-interface-cli "../lisp/gdev-agent-interface" ())
(declare-function startup-redirect-eln-cache "startup" (cache-directory))

(defun gdev-agent-entry ()
  "Prepara cache temporanee e avvia la richiesta senza aprire l'editor."
  (kill-emacs
   (let* ((directory (make-temp-file "gdev-agente-" t))
          (user-emacs-directory (file-name-as-directory directory))
          (native-comp-eln-load-path (and (boundp 'native-comp-eln-load-path)
                                          (copy-sequence native-comp-eln-load-path)))
          (native-comp-jit-compilation nil)
          (native-comp-enable-subr-trampolines nil))
     (unwind-protect
         (progn
           (setq load-prefer-newer t)
           (when (and native-comp-eln-load-path (fboundp 'startup-redirect-eln-cache))
             (startup-redirect-eln-cache (expand-file-name "eln-cache/" directory)))
           (load (expand-file-name "lisp/gdev-agent-interface.el" gdev-agent-entry--root) nil t t)
           (gdev-agent-interface-cli))
       (delete-directory directory t)))))

;;; gdev-agent-entry.el ends here
