;;; gdev-behavior-emacs-test.el --- Casi ufficiali GNU Emacs adattati -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Seleziona solo definizioni nominate da emacs-cases.json. Gli oracoli
;; originali restano intatti; il prefisso ERT evita collisioni. Le prove
;; del modo classico usano i valori documentati da Emacs 30.1: la suite
;; CodeMirror e gli scenari BDD verificano i valori e i comandi GDev.

;;; Code:

(require 'ert-x)
(require 'js)
(require 'python)
(require 'elec-pair)
(require 'electric)
(require 'cc-mode)
(require 'lisp-mode)

(dolist (entry (gdev-behavior-json "emacs-cases.json"))
  (let ((helpers (mapcar #'intern (plist-get entry :helpers)))
        (tests (mapcar #'intern (plist-get entry :tests))) found)
    (with-temp-buffer
      (insert (gdev-behavior-read (concat "upstream/emacs/" (plist-get entry :file))))
      (set-syntax-table emacs-lisp-mode-syntax-table)
      (goto-char (point-min))
      (let ((read-circle nil))
        (while (progn (forward-comment (point-max)) (not (eobp)))
          (let* ((form (read (current-buffer)))
                 (kind (car-safe form))
                 (name (cadr form)))
            (cond
             ((and (memq kind '(defun defmacro define-derived-mode)) (memq name helpers))
              (eval form t))
             ((and (eq kind 'ert-deftest) (memq name tests))
              (push name found)
              (let* ((body (nthcdr 3 form))
                     (documentation (when (stringp (car body)) (pop body))))
                ;; Il modulo GDev può fissare il rientro a due durante
                ;; l'attivazione. Questo oracolo classico dichiara quattro:
                ;; applica lo stile della fixture dopo l'entrata nel modo.
                (when (eq name 'js-mode-regexp-syntax)
                  (setq body (cl-subst '(progn (js-mode) (setq-local js-indent-level 4))
                                      '(js-mode) body :test #'equal)))
                (gdev-behavior-register
                 (intern (concat "gdev-test-behavior-emacs-" (symbol-name name)))
                 (or documentation (format "GNU Emacs 30.1: %s." name))
                 (lambda ()
                   ;; Un buffer di prova precedente può avere binding locali:
                   ;; lega i predefiniti in un buffer nuovo prima di crearne
                   ;; altri con le fixture originali.
                   (with-temp-buffer
                     (let ((js-indent-level 4) (fill-column 70)
                           (python-indent-offset 4) (python-indent-guess-indent-offset-verbose nil)
                           (indent-tabs-mode nil)
                           (prog-mode-hook nil) (js-mode-hook nil) (js-base-mode-hook nil)
                           (python-mode-hook nil) (python-base-mode-hook nil)
                           (after-change-major-mode-hook nil))
                       (eval (cons 'progn body) t)))) 'emacs))))))))
    (unless (equal (sort (copy-sequence found) #'string<) (sort tests #'string<))
      (error "Selezione GNU Emacs incompleta: %s" (plist-get entry :file)))))

(provide 'gdev-behavior-emacs-test)
;;; gdev-behavior-emacs-test.el ends here
