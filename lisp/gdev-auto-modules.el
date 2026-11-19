;;; gdev-auto-modules.el --- Moduli temporanei richiesti dai documenti -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le dichiarazioni private rimangono permanenti. I documenti e le operazioni
;; possiedono concessioni temporanee; l'ultima concessione rilascia i registri.
;; Le librerie restano nella cache di Emacs, senza servizi attivi residui.
;;; Code:
(require 'gdev-handlers)
(require 'gdev-language-modes)

(defvar gdev-modules)
(defvar gdev-auto-modules--entries nil)
(defvar gdev-module-load-times)
(declare-function gdev-module-file "gdev-modules" (category module &optional extension))
(declare-function gdev-modules--load "gdev-modules" (category module))
(declare-function gdev-module--failure "gdev-modules" (category module))
(declare-function gdev-module--configured-declaration "gdev-modules" (category module))

(defconst gdev-auto-modules-catalogue
  '((swift (("\\.swift\\'" . swift-mode)) ((swift-mode . "swift-mode") (swift-repl-mode . "swift-mode-repl")))
    (go (("\\.go\\'" . go-ts-mode) ("/go\\.mod\\'" . go-mod-ts-mode))
        ((go-ts-mode . "go-ts-mode") (go-mod-ts-mode . "go-ts-mode")))
    (rust (("\\.rs\\'" . rust-ts-mode)) ((rust-ts-mode . "rust-ts-mode")))
    (zig (("\\.zig\\(?:\\.zon\\)?\\'" . zig-mode)) ((zig-mode . "zig-mode")))
    (java (("\\.java\\'" . java-mode)) ((java-mode . "cc-mode") (java-ts-mode . "java-ts-mode")))
    (csharp (("\\.cs\\'" . csharp-mode)) ((csharp-mode . "csharp-mode") (csharp-ts-mode . "csharp-mode")))
    (cc nil ((c-mode . "cc-mode") (c++-mode . "cc-mode") (objc-mode . "cc-mode")
             (c-or-c++-mode . "cc-mode") (c-ts-mode . "c-ts-mode") (c++-ts-mode . "c-ts-mode")
             (cmake-ts-mode . "cmake-ts-mode")))
    (common-lisp nil ((lisp-mode . "lisp-mode") (sly-mrepl-mode . "sly-mrepl")))
    (emacs-lisp nil ((emacs-lisp-mode . "elisp-mode") (lisp-interaction-mode . "elisp-mode")))
    (perl (("\\.\\(?:pl\\|pm\\|t\\|psgi\\|cgi\\)\\'" . cperl-mode) ("/cpanfile\\'" . cperl-mode))
          ((cperl-mode . "cperl-mode") (perl-mode . "perl-mode")))
    (web (("\\.\\(?:html?\\|tt2?\\|ep\\|j2\\|jinja2?\\)\\'" . web-mode))
         ((web-mode . "web-mode") (html-mode . "sgml-mode") (html-ts-mode . "html-ts-mode")
          (css-mode . "css-mode") (css-ts-mode . "css-mode")))
    (javascript (("\\.[mc]?ts\\'" . typescript-ts-mode) ("\\.[jt]sx\\'" . tsx-ts-mode))
                ((js-mode . "js") (js-ts-mode . "js")
                 (typescript-ts-mode . "typescript-ts-mode") (tsx-ts-mode . "typescript-ts-mode")))
    (sh nil ((sh-mode . "sh-script") (bash-ts-mode . "sh-script")))
    (python nil ((python-mode . "python") (python-ts-mode . "python") (inferior-python-mode . "python")))
    (data (("\\.ya?ml\\'" . yaml-ts-mode) ("\\.toml\\'" . conf-toml-mode)
           ("\\.jsonc?\\'" . js-json-mode) ("\\.env\\(?:\\..*\\)?\\'" . conf-unix-mode))
          ((yaml-ts-mode . "yaml-ts-mode") (conf-toml-mode . "conf-mode") (toml-ts-mode . "toml-ts-mode")
           (js-json-mode . "js") (json-ts-mode . "json-ts-mode") (conf-mode . "conf-mode")
           (conf-unix-mode . "conf-mode") (makefile-gmake-mode . "make-mode")))
    (postgresql (("\\.\\(?:psql\\|pgsql\\)\\'" . gdev-postgresql-mode) ("\\.sql\\'" . gdev-database-mode))
                ((sql-mode . "sql") (gdev-postgresql-mode) (gdev-database-mode)
                 (gdev-postgresql-console-mode) (gdev-database-sqlite-console-mode)))
    (xml nil ((nxml-mode . "nxml-mode")))
    (markdown (("README\\.md\\'" . gfm-mode) ("\\.\\(?:md\\|markdown\\)\\'" . markdown-mode))
              ((gfm-mode . "markdown-mode") (markdown-mode . "markdown-mode")))
    (org nil ((org-mode . "org") (org-agenda-mode . "org-agenda")))
    (latex (("\\.tex\\'" . gdev-latex--file-mode))
           ((gdev-latex--file-mode) (gdev-latex-mode) (latex-mode . "tex-mode"))))
  "Fornitori di linguaggio: modulo, associazioni file e modalità con libreria.
Le associazioni sono ripieghi: quelle personali conservano la precedenza.")

(defvar gdev-auto-modules--owners (make-hash-table :test #'equal)
  "Stato dell'applicazione: modulo -> concessioni e registri temporanei.")
(defvar gdev-auto-modules--advice (make-hash-table :test #'eq))
(defvar gdev-auto-modules--selecting nil)
(defvar gdev-auto-modules--registration-owners (make-hash-table :test #'eq :weakness 'key)
  "Proprietari delle voci pubblicate, anche durante attivazioni annidate.")
(defvar-local gdev-auto-modules--lease nil
  "Concessione posseduta da questo documento, indipendente dallo spazio visibile.")
(put 'gdev-auto-modules--lease 'permanent-local t)

(defconst gdev-auto-modules--registries
  '((gdev-project-languages . eq) (gdev-doctor-checks . equal)
    (gdev-tool-action-groups . eq) (gdev-writing--project-markers . eq)))
(defconst gdev-auto-modules--lists
  '(gdev-popup-rules auto-mode-alist interpreter-mode-alist major-mode-remap-defaults major-mode-remap-alist))

(defun gdev-auto-modules--delta (before after test &optional scope)
  "Indicizza in un passaggio le associazioni pubblicate da AFTER."
  (let ((index (make-hash-table :test test)) changes)
    (dolist (entry before) (puthash (car entry) entry index))
    (dolist (entry after)
      (let ((previous (gethash (car entry) index)))
        (unless (or (and previous (equal (cdr previous) (cdr entry)))
                    (and scope (gethash entry gdev-auto-modules--registration-owners)))
          (when scope (puthash entry scope gdev-auto-modules--registration-owners))
          (push (list (car entry) previous entry) changes))))
    changes))

(defun gdev-auto-modules--restore (current changes test)
  "Ritira CHANGES ancora possedute, conservando registrazioni successive."
  (let ((index (make-hash-table :test test)) result)
    (dolist (change changes) (puthash (car change) change index))
    (dolist (entry current)
      (let ((change (gethash (car entry) index)))
        (if (and change (eq entry (nth 2 change)))
            (when (nth 1 change) (push (nth 1 change) result))
          (push entry result))))
    (nreverse result)))

(defun gdev-auto-modules--added (before after &optional scope)
  "Trova le voci nuove per identità, con costo atteso O(N + C)."
  (let ((known (make-hash-table :test #'eq)))
    (dolist (entry before) (puthash entry t known))
    (cl-remove-if (lambda (entry)
                    (or (gethash entry known)
                        (and scope (gethash entry gdev-auto-modules--registration-owners))
                        (progn (when scope (puthash entry scope gdev-auto-modules--registration-owners)) nil)))
                  after)))

(defun gdev-auto-modules--scoped-load (function)
  "Esegui FUNCTION e restituisci il suo ambito reversibile dei registri.
Errori e annullamenti ritirano anche gli effetti già pubblicati."
  (let* ((scope (list t))
         (handlers (copy-hash-table gdev--handlers))
         (before (mapcar (lambda (field) (cons (car field) (and (boundp (car field)) (copy-alist (symbol-value (car field))))))
                         gdev-auto-modules--registries))
         (lists (mapcar (lambda (name) (cons name (and (boundp name) (copy-sequence (symbol-value name)))))
                        gdev-auto-modules--lists))
         (gdev--registration-scope scope) complete)
    (unwind-protect
        (progn (funcall function) (setq complete t))
      (let (handler-changes registry-changes list-changes)
        (maphash (lambda (kind entries)
                   (when-let* ((changes (gdev-auto-modules--delta (gethash kind handlers) entries #'eq scope)))
                     (push (cons kind changes) handler-changes))) gdev--handlers)
        (dolist (field gdev-auto-modules--registries)
          (when (boundp (car field))
            (when-let* ((changes (gdev-auto-modules--delta (alist-get (car field) before) (symbol-value (car field)) (cdr field) scope)))
              (push (list (car field) (cdr field) changes) registry-changes))))
        (dolist (field lists)
          (when (boundp (car field))
            (when-let* ((added (gdev-auto-modules--added (cdr field) (symbol-value (car field)) scope)))
              (push (cons (car field) added) list-changes))))
        (gdev-register-module-cleanup
         (lambda ()
           (let ((previous-groups gdev-tool-action-groups))
           (when handler-changes
             (setq gdev--handlers (copy-hash-table gdev--handlers))
             (dolist (change handler-changes)
               (let ((entries (gdev-auto-modules--restore (gethash (car change) gdev--handlers) (cdr change) #'eq)))
                 (if entries (puthash (car change) entries gdev--handlers)
                   (remhash (car change) gdev--handlers)))))
           (dolist (change registry-changes)
             (set (car change) (gdev-auto-modules--restore (symbol-value (car change)) (nth 2 change) (nth 1 change))))
           (dolist (change list-changes)
             (let ((removed (make-hash-table :test #'eq)))
               (dolist (entry (cdr change)) (puthash entry t removed))
               (set (car change) (cl-remove-if (lambda (entry) (gethash entry removed)) (symbol-value (car change))))))
           (unless (equal previous-groups gdev-tool-action-groups)
             (with-demoted-errors "Aggiornamento moduli rilasciati: %S"
               (run-hooks 'gdev-tool-actions-change-hook)))))))
      (unless complete (gdev-module-scope-close scope)))
    scope))

(defun gdev-auto-modules-acquire (category module &optional owner)
  "Attiva MODULE per OWNER e restituisci una concessione da rilasciare.
OWNER predefinito è il buffer corrente. Le scelte private non cambiano."
  (let* ((key (list category module))
         (owner (or owner (current-buffer)))
         (configured (gdev-module--configured-declaration category module)))
    (unless configured
      (let ((record (gethash key gdev-auto-modules--owners)))
        (unless record
          (unless (file-regular-p (gdev-module-file category module ".el"))
            (user-error "Modulo %s %s non disponibile" category module))
          (setq record (list nil (make-hash-table :test #'eq) t))
          (puthash owner (vector key owner record t) (cadr record))
          (puthash key record gdev-auto-modules--owners)
          (push key gdev-auto-modules--entries)
          (condition-case failure
              (let ((scope (gdev-auto-modules--scoped-load
                            (lambda ()
                              (gdev-modules--load category module)
                              (when-let* ((problem (gdev-module--failure category module)))
                                (signal (car (nth 2 problem)) (cdr (nth 2 problem))))))))
                (setcar record scope)
                (setcar (cddr record) nil)
                (gdev-auto-modules--install-modes module))
            ((error quit)
             (maphash (lambda (_ lease) (aset lease 3 nil)) (cadr record))
             (remhash key gdev-auto-modules--owners)
             (setq gdev-auto-modules--entries (delete key gdev-auto-modules--entries)
                   gdev-module-load-times (assoc-delete-all key gdev-module-load-times))
             (signal (car failure) (cdr failure)))))
        (or (gethash owner (cadr record))
            (let ((lease (vector key owner record t)))
              (puthash owner lease (cadr record)) lease))))))

(defun gdev-auto-modules-release (lease)
  "Rilascia LEASE una volta; l'ultima ritira le capacità temporanee."
  (when (and lease (aref lease 3))
    (aset lease 3 nil)
    (let* ((key (aref lease 0)) (record (aref lease 2)) (owners (cadr record)))
      (remhash (aref lease 1) owners)
      (when (and (zerop (hash-table-count owners)) (not (nth 2 record)))
        (remhash key gdev-auto-modules--owners)
        (setq gdev-auto-modules--entries (delete key gdev-auto-modules--entries))
        (unless (gdev-module--configured-declaration (car key) (cadr key))
          (setq gdev-module-load-times (assoc-delete-all key gdev-module-load-times)))
        (gdev-module-scope-close (car record))))))

(defmacro gdev-with-auto-module (spec &rest body)
  "Mantieni il modulo SPEC attivo durante BODY, anche senza documenti aperti."
  (declare (indent 1) (debug (sexp body)))
  (let ((lease (make-symbol "lease")))
    `(let ((,lease (gdev-auto-modules-acquire ,(car spec) ,(cadr spec) (make-symbol "lavorazione"))))
       (unwind-protect (progn ,@body) (gdev-auto-modules-release ,lease)))))

(defun gdev-auto-modules--release-buffer ()
  "Rilascia il vecchio linguaggio dopo una scelta esplicita di altra modalità."
  (unless (eq gdev-auto-modules--selecting (current-buffer))
    (let ((lease gdev-auto-modules--lease))
      (setq gdev-auto-modules--lease nil)
      (gdev-auto-modules-release lease))))

(defun gdev-auto-modules--kill (kill &optional buffer)
  "Rilascia il linguaggio solo se KILL chiude davvero BUFFER."
  (let* ((target (get-buffer (or buffer (current-buffer))))
         (lease (and target (buffer-local-value 'gdev-auto-modules--lease target))))
    (unwind-protect (funcall kill buffer)
      (unless (buffer-live-p target) (gdev-auto-modules-release lease)))))

(defun gdev-auto-modules--call-mode (module function &rest arguments)
  "Attiva MODULE prima di FUNCTION e dei suoi ganci di modalità."
  (if (or (gdev-module--configured-declaration :lang module)
          (eq gdev-auto-modules--selecting (current-buffer))
          (not (file-regular-p (gdev-module-file :lang module ".el"))))
      (prog1 (apply function arguments) (gdev-language-install-command-map))
    (let ((gdev-auto-modules--selecting (current-buffer)) complete)
      (unless (and gdev-auto-modules--lease
                   (equal (aref gdev-auto-modules--lease 0) (list :lang module)))
        (gdev-auto-modules-release gdev-auto-modules--lease)
        (setq gdev-auto-modules--lease nil))
      (setq gdev-auto-modules--lease (gdev-auto-modules-acquire :lang module))
      (unwind-protect
          (prog1 (apply function arguments)
            (gdev-language-install-command-map)
            (setq complete t))
        (unless complete
          (gdev-auto-modules-release gdev-auto-modules--lease)
          (setq gdev-auto-modules--lease nil))))))

(defun gdev-auto-modules--install-modes (module)
  "Collega le modalità già disponibili o autocaricabili di MODULE."
  (let ((provider (assq module gdev-auto-modules-catalogue)))
    (dolist (mode (nth 2 provider))
      (when (or (fboundp (car mode)) (cdr mode))
        (unless (fboundp (car mode)) (autoload (car mode) (cdr mode) nil t))
        (unless (gethash (car mode) gdev-auto-modules--advice)
          (let ((wrapper (lambda (function &rest args)
                           (apply #'gdev-auto-modules--call-mode module function args))))
            (advice-add (car mode) :around wrapper)
            (puthash (car mode) wrapper gdev-auto-modules--advice)))))))

(defun gdev-auto-modules--compile (compile &rest arguments)
  "Mantieni il modulo del documento finché COMPILE termina davvero."
  (if (not (and gdev-auto-modules--lease (aref gdev-auto-modules--lease 3)))
      (apply compile arguments)
    (let* ((key (aref gdev-auto-modules--lease 0))
           (lease (gdev-auto-modules-acquire (car key) (cadr key) (make-symbol "compilazione")))
           transferred)
      (unwind-protect
          (let* ((output (apply compile arguments))
                 (process (and (buffer-live-p output) (get-buffer-process output))))
            (if (process-live-p process)
                (let ((sentinel (process-sentinel process)))
                  (set-process-sentinel
                   process (lambda (child event)
                             (unwind-protect
                                 (when sentinel (funcall sentinel child event))
                               (unless (process-live-p child)
                                 (gdev-auto-modules-release lease))))))
              (gdev-auto-modules-release lease))
            (setq transferred t)
            output)
        (unless transferred (gdev-auto-modules-release lease))))))

(defun gdev-auto-modules-initialize ()
  "Installa la scelta automatica dei fornitori senza caricare i moduli."
  (dolist (provider gdev-auto-modules-catalogue)
    (let ((module (car provider)))
      (gdev-auto-modules--install-modes module)
      (dolist (file (nth 1 provider))
        (let* ((mode (cdr file))
               (library (cdr (assq mode (nth 2 provider))))
               (dispatcher (if library mode (intern (format "gdev-auto-modules--open-%s-%s" module mode)))))
          (unless library
            (defalias dispatcher
              (lambda () (interactive)
                (gdev-auto-modules--call-mode module (lambda () (funcall mode))))))
          (add-to-list 'auto-mode-alist (cons (car file) dispatcher) t)))))
  (add-hook 'change-major-mode-hook #'gdev-auto-modules--release-buffer)
  (remove-hook 'find-file-hook #'gdev-modules-suggest-language)
  (unless (advice-member-p #'gdev-auto-modules--compile 'gdev-compile)
    (advice-add 'gdev-compile :around #'gdev-auto-modules--compile))
  (unless (advice-member-p #'gdev-auto-modules--kill 'kill-buffer)
    (advice-add 'kill-buffer :around #'gdev-auto-modules--kill)))

(provide 'gdev-auto-modules)
;;; gdev-auto-modules.el ends here
