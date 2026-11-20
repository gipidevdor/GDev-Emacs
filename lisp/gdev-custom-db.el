;;; gdev-custom-db.el --- Preferenze Customize nel profilo SQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Customize resta responsabile di setter, facce, opzioni differite e reset.
;; La sua rappresentazione pubblica include espressioni, commenti e richieste
;; di caricamento. Ogni opzione ha una chiave indipendente.

;;; Code:

(require 'gdev-state-db)
(require 'cl-lib)

(declare-function custom-save-variables "cus-edit")
(declare-function custom-save-faces "cus-edit")
(declare-function custom-save-icons "cus-edit")
(declare-function gdev-load-custom-file "gdev-lib")
(defconst gdev-custom-db--kinds
  '((custom-set-variables . "variabile") (custom-set-faces . "faccia")
    (custom-set-icons . "icona")))
(defvar gdev-custom-db--baseline nil)
(declare-function custom-file "cus-edit" ())

(defun gdev-custom-db--collect ()
  (with-temp-buffer
    (let ((print-length nil) (print-level nil) (print-escape-control-characters t))
      (delay-mode-hooks (emacs-lisp-mode))
      (custom-save-variables)
      (custom-save-faces)
      (when (fboundp 'custom-save-icons) (custom-save-icons))
      (goto-char (point-min))
      (let (result)
        (while (progn (forward-comment (point-max)) (not (eobp)))
          (pcase-let* ((`(,setter . ,arguments) (read (current-buffer)))
                       (kind (alist-get setter gdev-custom-db--kinds)))
            (dolist (quoted arguments)
              (pcase-let ((`(quote (,name . ,spec)) quoted))
                (push (cons (cons kind (symbol-name name)) spec) result)))))
        result))))

(defun gdev-custom-db--save (original &rest args)
  (if (not (equal custom-file (gdev-state-db--legacy "custom.el")))
      (apply original args)
    (custom-file)
    (let ((current (gdev-custom-db--collect))
          (previous (make-hash-table :test #'equal)))
      (dolist (entry gdev-custom-db--baseline) (puthash (car entry) entry previous))
      (gdev-state-db-with (db t)
        (dolist (entry current)
          (pcase-let ((`((,kind . ,name) . ,spec) entry))
            (unless (equal entry (gethash (car entry) previous))
              (gdev-state-db-set kind "" name spec))
            (remhash (car entry) previous)))
        (maphash (lambda (key _)
                   (sqlite-execute db "DELETE FROM impostazione WHERE id_ambito=? AND nome=?"
                                   (list (gdev-state-db--scope db (car key) "") (cdr key))))
                 previous)
        (gdev-state-db-set "migrazione" "" "preferenze" t))
      (setq gdev-custom-db--baseline current))))

(defun gdev-custom-db--import (file)
  ;; Il file privato può contenere anche codice personale. Lascia che Emacs
  ;; lo esegua nel suo ordine e raccogli solo le impostazioni di Customize.
  (let (captured)
    (cl-letf* ((variables (symbol-function 'custom-set-variables))
               (faces (symbol-function 'custom-set-faces))
               (icons (and (fboundp 'custom-set-icons) (symbol-function 'custom-set-icons)))
               ((symbol-function 'custom-set-variables)
                (lambda (&rest specs) (push (cons "variabile" specs) captured) (apply variables specs)))
               ((symbol-function 'custom-set-faces)
                (lambda (&rest specs) (push (cons "faccia" specs) captured) (apply faces specs)))
               ((symbol-function 'custom-set-icons)
                (lambda (&rest specs) (push (cons "icona" specs) captured) (when icons (apply icons specs)))))
      (when (gdev-load-custom-file file)
        (gdev-state-db-with (_db t)
          (unless (gdev-state-db-entries "migrazione" "" "preferenze")
            (dolist (group (nreverse captured))
              (dolist (spec (cdr group))
                (gdev-state-db-set (car group) "" (symbol-name (car spec)) (cdr spec))))
            (gdev-state-db-set "migrazione" "" "preferenze" t)))))))

(defun gdev-custom-db-load ()
  "Carica le scelte del profilo conservando ordine e setter nativi di Customize."
  (let* ((legacy (gdev-state-db--legacy "custom.el"))
         (import (and (file-readable-p legacy)
                      (not (gdev-state-db-entries "migrazione" "" "preferenze"))))
         pending)
    (when import (gdev-custom-db--import legacy))
    ;; Base e valori applicati provengono dalla stessa istantanea, anche con
    ;; un salvataggio concorrente di un secondo processo.
    (setq gdev-custom-db--baseline nil)
    (gdev-state-db-with (_db)
      (pcase-dolist (`(,setter . ,kind) gdev-custom-db--kinds)
        (let* ((entries (gdev-state-db-entries kind ""))
               (first (assoc "default" entries)) specs)
          (when first (setq entries (cons first (delq first entries))))
          (dolist (entry entries)
            (push (cons (cons kind (car entry)) (cdr entry)) gdev-custom-db--baseline)
            (push (cons (intern (car entry)) (cdr entry)) specs))
          (when specs (push (cons setter (nreverse specs)) pending)))))
    (unless import
      (cl-labels ((restore (setter original)
                    (when-let* ((specs (alist-get setter pending)))
                      (setq pending (assq-delete-all setter pending))
                      (apply original specs))))
        (when (file-readable-p legacy)
          (cl-letf* ((variables (symbol-function 'custom-set-variables))
                     (faces (symbol-function 'custom-set-faces))
                     (icons (and (fboundp 'custom-set-icons) (symbol-function 'custom-set-icons)))
                     ((symbol-function 'custom-set-variables)
                      (lambda (&rest _) (restore 'custom-set-variables variables)))
                     ((symbol-function 'custom-set-faces)
                      (lambda (&rest _) (restore 'custom-set-faces faces)))
                     ((symbol-function 'custom-set-icons)
                      (lambda (&rest _) (when icons (restore 'custom-set-icons icons)))))
            (gdev-load-custom-file legacy)))
        (dolist (kind gdev-custom-db--kinds)
          (when (fboundp (car kind)) (restore (car kind) (car kind))))))))

(with-eval-after-load 'cus-edit
  (advice-add 'custom-save-all :around #'gdev-custom-db--save))

(provide 'gdev-custom-db)
;;; gdev-custom-db.el ends here
