;;; gdev-scoped-options.el --- Preferenze dei documenti per progetto e sessione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La stessa opzione può avere un valore di sessione e uno nella cartella
;; del progetto. La base impostata dal modo o dalle variabili locali del
;; documento riemerge quando l'utente rimuove entrambe le preferenze.

;;; Code:

(require 'gdev-state-db)
(require 'seq)
(require 'gdev-project-types)
(declare-function custom-variable-type "cus-edit" (symbol))

(defvar gdev-writing--project-markers)
(defvar gdev-project-languages)
(defvar gdev-scoped-options--type-cache nil)
(defvar gdev-scoped-options--profile nil)
(defvar gdev-scoped-options--projects nil)
(defvar gdev-scoped-options--types nil)
(defvar gdev-scoped-options--session nil)
(defvar gdev-scoped-options--identity
  (format "%s-%d-%s" (system-name) (emacs-pid) (format-time-string "%s%N"))
  "Identità dell'istanza che modifica le proprie preferenze di sessione.")
(defvar-local gdev-scoped-options--base nil)

(defun gdev-scoped-options-project-type (directory)
  "Riconosci il tipo dalla radice più vicina a DIRECTORY.
Considera anche le sottocartelle."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (or (and gdev-scoped-options--type-cache (gethash directory gdev-scoped-options--type-cache))
        (let (type)
          (locate-dominating-file
           directory
           (lambda (parent)
             (setq type
                   (and (file-accessible-directory-p parent)
                        (or (car (seq-find (lambda (entry) (file-regular-p (expand-file-name (cdr entry) parent)))
                                           (bound-and-true-p gdev-writing--project-markers)))
                            (and (file-directory-p (expand-file-name ".gdev-assurance" parent)) 'formale)
                            (car (seq-find (lambda (entry) (funcall (cadr entry) parent))
                                           (append (bound-and-true-p gdev-project-languages) gdev-project-language-markers)))
                            (gdev-project-build-system parent t)
                            (and (file-regular-p (expand-file-name ".project" parent)) 'vuoto)
                            (and (file-exists-p (expand-file-name ".git" parent)) 'generico))))))
          (let ((name (symbol-name (or type 'generico))))
            (when gdev-scoped-options--type-cache (puthash directory name gdev-scoped-options--type-cache))
            name)))))

(defun gdev-scoped-options--canonical-directory (directory)
  (file-name-as-directory
   (if (file-remote-p directory) (expand-file-name directory) (file-truename directory))))

(defun gdev-scoped-options-project-ref (directory)
  "Riusa il riferimento già salvato anche quando DIRECTORY è un collegamento."
  (let ((canonical (gdev-scoped-options--canonical-directory directory))
        (original (file-name-as-directory (expand-file-name directory))))
    (or (gdev-state-db-with (db)
          (or (and (gdev-state-db--scope db "preferenze_progetto" original) original)
              (and (gdev-state-db--scope db "preferenze_progetto" canonical) canonical)
              (seq-find (lambda (path) (equal canonical (gdev-scoped-options--canonical-directory path)))
                        (mapcar #'car (sqlite-select db "SELECT riferimento FROM ambito WHERE tipo='preferenze_progetto' ORDER BY id DESC")))))
        original)))

(defun gdev-scoped-options-refresh ()
  "Rileggi il catalogo del profilo con una sola transazione."
  (let (projects types)
    (gdev-state-db-with (db)
      (pcase-dolist (`(,id ,kind ,ref)
                     (sqlite-select db "SELECT id,tipo,riferimento FROM ambito WHERE tipo IN ('preferenze_progetto','preferenze_tipo_progetto') ORDER BY length(riferimento)"))
        (when-let* ((entries (gdev-state-db--entries db id)))
          (let ((options (cons (if (equal kind "preferenze_progetto") (gdev-scoped-options--canonical-directory ref) ref) (mapcar (lambda (entry) (cons (intern (car entry)) (cdr entry))) entries))))
            (if (equal kind "preferenze_progetto") (push options projects) (push options types))))))
    (unless (equal gdev-scoped-options--profile (gdev-state-db-file))
      (setq gdev-scoped-options--session
            (gdev-state-db-with (db)
              (let ((scope (or (gdev-state-db--scope db "preferenze_sessione" gdev-scoped-options--identity)
                               (caar (sqlite-select db "SELECT id_ambito FROM ultime_preferenze_sessione WHERE unico=1")))))
                (gdev-state-db--entries db scope)))))
    (setq gdev-scoped-options--profile (gdev-state-db-file)
          gdev-scoped-options--projects projects
          gdev-scoped-options--types types)))

(defun gdev-scoped-options-session ()
  (unless (equal gdev-scoped-options--profile (gdev-state-db-file))
    (gdev-scoped-options-refresh))
  gdev-scoped-options--session)

(defun gdev-scoped-options-replace-session (entries)
  "Pubblica le preferenze di questa istanza e il riferimento per il prossimo avvio."
  (gdev-state-db-with (db t)
    (gdev-scoped-options--write-session db entries))
  (setq gdev-scoped-options--profile (gdev-state-db-file)
        gdev-scoped-options--session entries))

(defun gdev-scoped-options--write-session (db entries)
  (let ((scope (gdev-state-db--scope db "preferenze_sessione" gdev-scoped-options--identity t)))
    (gdev-state-db--replace db scope entries)
    (sqlite-execute db "INSERT OR REPLACE INTO ultime_preferenze_sessione VALUES(1,?)" (list scope))))

(defun gdev-scoped-options-local-p (symbol)
  "Indica un'opzione configurabile con semantica locale al documento."
  (and (custom-variable-p symbol) (not (keywordp symbol))
       (or (local-variable-if-set-p symbol) (get symbol 'safe-local-variable))))

(defvar gdev-scoped-options--catalog-profile nil)
(defvar gdev-scoped-options--pending (make-hash-table :test #'eq))
(defvar gdev-scoped-options--timer nil)

(defun gdev-scoped-options--schedule ()
  (unless (or noninteractive (timerp gdev-scoped-options--timer))
    (setq gdev-scoped-options--timer
          (run-with-idle-timer 2 nil #'gdev-scoped-options-catalog-sync))))

(defun gdev-scoped-options--declared (symbol &rest _)
  (puthash symbol t gdev-scoped-options--pending)
  (gdev-scoped-options--schedule))

(defun gdev-scoped-options-catalog-sync ()
  "Indicizza le dichiarazioni anche dei moduli caricati dopo l'avvio."
  (when gdev-scoped-options--timer (cancel-timer gdev-scoped-options--timer))
  (setq gdev-scoped-options--timer nil)
  (let ((full (not (equal gdev-scoped-options--catalog-profile (gdev-state-db-file))))
        rows)
    (when full (mapatoms (lambda (s) (when (custom-variable-p s)
                                       (puthash s t gdev-scoped-options--pending)))))
    (maphash
     (lambda (s _)
       (when (custom-variable-p s)
         (let* ((var (indirect-variable s)) (type (get var 'custom-type)) (default (get var 'standard-value)))
           (push (list (symbol-name s) (and type (gdev-state-db--print type))
                       (and default (gdev-state-db--print (car default)))
                       (if (gdev-scoped-options-local-p var) 1 0)) rows))))
     gdev-scoped-options--pending)
    (when rows
      (gdev-state-db-with (db t)
        (while rows
          (let ((batch (cl-loop repeat 180 while rows collect (pop rows))))
            (sqlite-execute db
             (concat "INSERT OR REPLACE INTO catalogo_opzione VALUES "
                     (mapconcat (lambda (_) "(?,?,?,?)") batch ","))
             (apply #'append batch))))))
    (clrhash gdev-scoped-options--pending)
    (setq gdev-scoped-options--catalog-profile (gdev-state-db-file))))

(defun gdev-scoped-options-choose (personal)
  (gdev-scoped-options-catalog-sync)
  (let ((names (gdev-state-db-with (db)
                 (sqlite-select db (concat "SELECT nome FROM catalogo_opzione "
                                           (unless personal "WHERE locale=1 ") "ORDER BY nome")))))
    (intern (completing-read "Impostazione: " names
                             (lambda (row) (custom-variable-p (intern-soft (car row)))) t))))

(advice-add 'custom-declare-variable :after #'gdev-scoped-options--declared)
(advice-add 'custom-autoload :after #'gdev-scoped-options--declared)
(add-hook 'emacs-startup-hook #'gdev-scoped-options--schedule)

(defun gdev-scoped-options-apply (&optional directory)
  "Applica le opzioni al documento di DIRECTORY o del buffer corrente."
  (unless (equal gdev-scoped-options--profile (gdev-state-db-file))
    (gdev-scoped-options-refresh))
  (when-let* ((path (or directory buffer-file-truename buffer-file-name
                        (and (bound-and-true-p gdev-layout-document-p)
                             (not (derived-mode-p 'special-mode)) default-directory))))
    (let* ((path (cond (directory (gdev-scoped-options--canonical-directory path))
                       (buffer-file-truename buffer-file-truename)
                       (gdev-scoped-options--projects (concat (gdev-scoped-options--canonical-directory (file-name-directory (expand-file-name path))) (file-name-nondirectory path)))
                       (t (expand-file-name path))))
           (project (seq-find (lambda (entry) (and (cdr entry) (string-prefix-p (car entry) path)))
                              gdev-scoped-options--projects))
           (type (and gdev-scoped-options--types
                      (gdev-scoped-options-project-type (or directory (file-name-directory path)))))
           (values (append (cdr project) (cdr (assoc type gdev-scoped-options--types))
                           (mapcar (lambda (entry) (cons (intern (car entry)) (cdr entry)))
                                   gdev-scoped-options--session))))
      (dolist (entry gdev-scoped-options--base)
        (unless (assq (car entry) values)
          (if (cadr entry) (set (car entry) (caddr entry)) (kill-local-variable (car entry)))
          (setq gdev-scoped-options--base (delq entry gdev-scoped-options--base))))
      (dolist (entry (reverse values))
        (let ((var (car entry)))
          (when (and (boundp var) (gdev-scoped-options-local-p var))
            (unless (assq var gdev-scoped-options--base)
              (push (list var (local-variable-p var) (symbol-value var)) gdev-scoped-options--base))
            (set (make-local-variable var) (cdr entry))))))))

(defun gdev-scoped-options-update-buffers ()
  (gdev-scoped-options-refresh)
  (let ((gdev-scoped-options--type-cache (make-hash-table :test #'equal)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (gdev-scoped-options-apply)))))

(defun gdev-scoped-options-set (scope root symbol value &optional remove)
  "Salva o rimuovi SYMBOL nell'ambito SCOPE e aggiorna i documenti aperti."
  (unless (memq scope '(session project project-type))
    (user-error "Ambito di preferenze sconosciuto"))
  (unless (or (eq scope 'session) (and (stringp root) (not (string-empty-p root))))
    (user-error "La preferenza richiede la radice del progetto"))
  (unless (gdev-scoped-options-local-p symbol)
    (user-error "Questa impostazione si applica dalle preferenze personali"))
  (unless remove
    (require 'cus-edit)
    (custom-load-symbol symbol)
    (unless (widget-apply (widget-convert (custom-variable-type symbol)) :match value)
      (user-error "Valore non valido per %s" symbol)))
  (if (eq scope 'session)
      (let* ((name (symbol-name symbol))
             (entries (assoc-delete-all name (copy-sequence (gdev-scoped-options-session)))))
        (unless remove (push (cons name value) entries))
        (gdev-scoped-options-replace-session entries))
    (gdev-state-db-with (db t)
      (let ((kind (if (eq scope 'project-type) "preferenze_tipo_progetto" "preferenze_progetto"))
            (ref (if (eq scope 'project-type) (gdev-scoped-options-project-type root)
                   (gdev-scoped-options-project-ref root))))
        (if remove
            (sqlite-execute db "DELETE FROM impostazione WHERE id_ambito=? AND nome=?"
                            (list (gdev-state-db--scope db kind ref) (symbol-name symbol)))
          (gdev-state-db-set kind ref (symbol-name symbol) value)))))
  (gdev-scoped-options-update-buffers))

(add-hook 'gdev-new-document-hook #'gdev-scoped-options-apply)
(add-hook 'hack-local-variables-hook #'gdev-scoped-options-apply 95)

(provide 'gdev-scoped-options)
;;; gdev-scoped-options.el ends here
