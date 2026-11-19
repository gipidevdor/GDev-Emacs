;;; gdev-fork-merge.el --- Anteprima di integrazione dei fork locali -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Prepara un merge a tre vie in un repository temporaneo per la revisione.

;;; Code:

(require 'seq)
(require 'subr-x)

(defvar gdev-bundled-packages)
(defvar gdev-config-directory)
(declare-function gdev-bundled-package-directory "../early-init" (name))

(defun gdev-fork-merge--git (allowed &rest arguments)
  "Esegui Git con ARGUMENTS accettando i codici di uscita in ALLOWED."
  (with-temp-buffer
    (let* ((status (apply #'call-process "git" nil '(t t) nil arguments))
           (output (string-trim (buffer-string))))
      (unless (memq status allowed)
        (user-error "Git %s: %s" (car arguments) output))
      output)))

(defun gdev-fork-merge--snapshot (source label &optional parent)
  "Registra SOURCE come LABEL con PARENT nel repository di anteprima."
  (gdev-fork-merge--git '(0) "read-tree" "--empty")
  (gdev-fork-merge--git '(0) (concat "--work-tree=" source) "add" "--all" "--force" "--" "."
                       ":(exclude,glob)**/*.elc" ":(exclude,glob)**/*.eln"
                       ":(exclude,glob)**/.DS_Store")
  (apply #'gdev-fork-merge--git '(0) "commit-tree" (gdev-fork-merge--git '(0) "write-tree")
         "-m" label (when parent (list "-p" parent))))

(defun gdev-fork-merge (package base incoming)
  "Integra BASE, il fork PACKAGE e INCOMING in una copia temporanea.
BASE e INCOMING sono directory locali del pacchetto distribuito a monte.
Restituisci la directory dell'anteprima e i percorsi con conflitti."
  (let* ((name (intern-soft package))
         (fork (and (assq name gdev-bundled-packages) (gdev-bundled-package-directory name)))
         (inputs (list base fork incoming)))
    (unless fork (user-error "Pacchetto fuori registro: %s" package))
    (dolist (directory inputs)
      (unless (and (not (file-remote-p directory)) (file-directory-p directory))
        (user-error "Cartella locale non disponibile: %s" directory)))
    (let* ((sources (mapcar #'file-truename inputs))
           (parent (file-truename temporary-file-directory))
           (process-environment (seq-remove (lambda (entry) (string-prefix-p "GIT_" entry))
                                           process-environment))
           directory ready)
      (when (seq-some (lambda (source)
                        (or (file-equal-p parent source) (file-in-directory-p parent source)))
                      (cons gdev-config-directory sources))
        (user-error "La cartella temporanea deve essere esterna al checkout e alle sorgenti"))
      (setenv "GIT_CONFIG_NOSYSTEM" "1")
      (setenv "GIT_CONFIG_GLOBAL" null-device)
      (setenv "GIT_AUTHOR_NAME" "GDev-Emacs")
      (setenv "GIT_AUTHOR_EMAIL" "fork-merge@localhost")
      (setenv "GIT_COMMITTER_NAME" "GDev-Emacs")
      (setenv "GIT_COMMITTER_EMAIL" "fork-merge@localhost")
      (setq directory (make-temp-file (expand-file-name "gdev-fork-" parent) t))
      (unwind-protect
          (let ((default-directory (file-name-as-directory directory)))
            (gdev-fork-merge--git '(0) "init" "--quiet" "--template=")
            (let* ((original (gdev-fork-merge--snapshot (nth 0 sources) "Base a monte"))
                   (local (gdev-fork-merge--snapshot (nth 1 sources) "Fork GDev" original))
                   (updated (gdev-fork-merge--snapshot (nth 2 sources) "Nuova versione a monte" original)))
              (gdev-fork-merge--git '(0) "checkout" "--quiet" "--force" "-b" "gdev" local)
              (gdev-fork-merge--git '(0) "branch" "upstream" updated)
              (let* ((output (gdev-fork-merge--git '(0 1) "-c" "merge.conflictStyle=diff3"
                                                   "merge" "--no-commit" "--no-ff" "upstream"))
                     (conflicts (split-string (gdev-fork-merge--git
                                               '(0) "diff" "--name-only" "--diff-filter=U")
                                              "\n" t)))
                (unless (or conflicts (file-exists-p ".git/MERGE_HEAD"))
                  (user-error "Integrazione Git non completata: %s" output))
                (setq ready t)
                (cons directory conflicts))))
        (unless ready (delete-directory directory t))))))

(provide 'gdev-fork-merge)
;;; gdev-fork-merge.el ends here
