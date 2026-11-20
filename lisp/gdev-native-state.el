;;; gdev-native-state.el --- Stato dei servizi nativi di Emacs nel profilo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; I servizi di Emacs conservano i propri agganci, limiti e formati. Un
;; file privato temporaneo scambia i dati con le API che richiedono un nome
;; di file. Nell'archivio ogni variabile e i suoi elementi sono distinti.

;;; Code:

(require 'gdev-state-db)
(require 'lisp-mode)
(defvar gdev-state-directory)

(defvar desktop-base-file-name)
(defvar savehist-file)
(defvar savehist-last-checksum)
(defvar save-place-loaded)

(defun gdev-native-state--read-forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let (forms)
        (while (progn (forward-comment (point-max)) (not (eobp)))
          (push (read (current-buffer)) forms))
        (nreverse forms)))))

(defun gdev-native-state--parse (file format)
  (let ((forms (gdev-native-state--read-forms file)))
    (pcase format
      ('variables
       (mapcar (lambda (form)
                 (pcase form
                   (`(setq ,(and (pred symbolp) var) ,expr)
                    (cons (symbol-name var) expr))
                   (_ (error "Forma di cronologia sconosciuta: %S" (car-safe form)))))
               forms))
      ('lista (unless (= 1 (length forms)) (error "Elenco di stato non valido"))
              (list (cons "elementi" (car forms))))
      ('desktop (list (cons "istruzioni" forms))))))

(defun gdev-native-state--emit (file format entries)
  (let ((coding-system-for-write 'utf-8-emacs)
        (print-length nil) (print-level nil) (print-circle t)
        (print-escape-control-characters t))
    (with-temp-file file
      (insert ";;; -*- lexical-binding: t; coding: utf-8-emacs -*-\n")
      (dolist (form (pcase format
                      ('variables (mapcar (lambda (e) (list 'setq (intern (car e)) (cdr e))) entries))
                      ('lista (list (cdr (assoc "elementi" entries))))
                      ('desktop (cdr (assoc "istruzioni" entries)))))
        (prin1 form (current-buffer))
        (insert "\n")))))

(defconst gdev-native-state--paths
  '(("file_recenti" "recentf" "recentf.eld") ("progetti_conosciuti" "projects" "projects.eld")
    ("cronologie" "history") ("posizioni" "places" "places.eld") ("cursori_multipli" "mc-lists.el")
    ("comandi_eshell" "eshell/history") ("cartelle_eshell" "eshell/lastdir")
    ("alias_eshell" "eshell/alias") ("cronologia_ielm" "ielm-history")
    ("cronologia_sly" "sly-mrepl-history")))

(defun gdev-native-state--managed-p (path type)
  (and (stringp path) (not (string-empty-p path))
       (member (file-relative-name (expand-file-name path) gdev-state-directory)
               (cdr (assoc type gdev-native-state--paths)))))

(defvar gdev-native-state--observed (make-hash-table :test #'equal))

(defun gdev-native-state--remember (type entries)
  ;; Alcuni lettori nativi modificano poi le liste ricevute.
  (puthash (cons (gdev-state-db-file) type) (copy-tree entries t) gdev-native-state--observed))

(defun gdev-native-state--store (type entries)
  "Scrivi le chiavi cambiate e segnala modifiche incompatibili.
Due istanze non possono sostituire in silenzio la stessa chiave."
  (let ((seen (gethash (cons (gdev-state-db-file) type) gdev-native-state--observed 'ignoto)))
    (gdev-state-db-with (db t)
      (let* ((scope (gdev-state-db--scope db type "" t))
             (current (gdev-state-db--entries db scope))
             (base (if (eq seen 'ignoto) current seen)))
        (dolist (name (delete-dups (append (mapcar #'car base) (mapcar #'car entries))))
          (let ((old (assoc name base)) (new (assoc name entries)) (saved (assoc name current)))
            (unless (or (equal new old) (equal new saved))
              (unless (equal saved old)
                (user-error "Il dato %s di %s è cambiato in un’altra istanza. Ricarica il servizio" name type))
              (if new (gdev-state-db--put db scope name (cdr new))
                (sqlite-execute db "DELETE FROM impostazione WHERE id_ambito=? AND nome=?" (list scope name))))))))
    (gdev-native-state--remember type entries)))

(defun gdev-native-state--call (original args variable type format write &optional desktop)
  (let* ((path (symbol-value variable))
         (managed (or desktop (gdev-native-state--managed-p path type)))
         (path (and managed (expand-file-name path desktop))))
    (if (not managed) (apply original args)
      (let* ((stored (gdev-state-db-with (db)
                       (when-let* ((scope (gdev-state-db--scope db type "")))
                         (cons t (unless write (gdev-state-db--entries db scope))))))
             (directory (make-temp-file "gdev-scambio-" t))
             (temporary (expand-file-name "dati" directory)))
        (unwind-protect
            (cond
             (write
              (let ((checksum (and (boundp 'savehist-last-checksum) savehist-last-checksum)) done)
                (unwind-protect
                    (prog1 (cl-progv (list variable) (list temporary) (apply original args))
                      (when (file-exists-p temporary)
                        (gdev-native-state--store type (gdev-native-state--parse temporary format)))
                      (setq done t))
                  (when (and (not done) (eq variable 'savehist-file))
                    (setq savehist-last-checksum checksum)))))
             (stored
              (gdev-native-state--remember type (cdr stored))
              (gdev-native-state--emit temporary format (cdr stored))
              (cl-progv (list variable) (list temporary) (apply original args)))
             ((file-readable-p path)
              (let ((entries (gdev-native-state--parse path format)))
                (prog1 (apply original args)
                  (gdev-state-db-with (db t)
                    (unless (gdev-state-db--scope db type "")
                      (gdev-state-db--replace db (gdev-state-db--scope db type "" t) entries)))
                  (gdev-native-state--remember type entries))))
             (t (gdev-native-state--remember type nil) (apply original args)))
          (delete-directory directory t))))))

(defmacro gdev-native-state--service (library variable type format reader writer)
  "Collega le due API del servizio LIBRARY al suo ambito TYPE."
  (let ((load-fn (intern (format "gdev-native-state--%s" reader)))
        (save-fn (intern (format "gdev-native-state--%s" writer))))
    `(progn
       (defun ,load-fn (original &rest args)
         (gdev-native-state--call original args ',variable ,type ',format nil))
       (defun ,save-fn (original &rest args)
         (gdev-native-state--call original args ',variable ,type ',format t))
       (with-eval-after-load ',library
         (advice-add ',reader :around #',load-fn)
         (advice-add ',writer :around #',save-fn)))))

(gdev-native-state--service recentf recentf-save-file "file_recenti" variables recentf-load-list recentf-save-list)
(gdev-native-state--service project project-list-file "progetti_conosciuti" lista project--read-project-list project--write-project-list)
(gdev-native-state--service savehist savehist-file "cronologie" variables savehist-mode savehist-save)

;; save-place chiama il lettore per ogni file. Dopo la prima lettura si
;; conserva il percorso in memoria, senza aprire il database o creare file.
(defun gdev-native-state--places-load (original &rest args)
  (unless save-place-loaded
    (gdev-native-state--call original args 'save-place-file "posizioni" 'lista nil)))
(defun gdev-native-state--places-save (original &rest args)
  (gdev-native-state--call original args 'save-place-file "posizioni" 'lista t))
(with-eval-after-load 'saveplace
  (advice-add 'save-place-load-alist-from-file :around #'gdev-native-state--places-load)
  (advice-add 'save-place-alist-to-file :around #'gdev-native-state--places-save))

(defun gdev-native-state-desktop (directory write)
  (require 'desktop)
  (gdev-native-state--call (if write #'desktop-save #'desktop-read)
                           (if write (list directory t) (list directory))
                           'desktop-base-file-name "sessione_desktop" 'desktop write directory))

(defvar mc--list-file-loaded)
(defun gdev-native-state--cursors-load (original)
  (unless mc--list-file-loaded
    (gdev-native-state--call original nil 'mc/list-file "cursori_multipli" 'variables nil)))
(defun gdev-native-state--cursors-save (original)
  (gdev-native-state--call original nil 'mc/list-file "cursori_multipli" 'variables t))
(with-eval-after-load 'multiple-cursors-core
  (advice-add 'mc/load-lists :around #'gdev-native-state--cursors-load)
  (advice-add 'mc/save-lists :around #'gdev-native-state--cursors-save))

(defvar eshell-history-file-name)
(defvar eshell-hist--new-items)
(defvar eshell-command-aliases-list)
(defvar eshell-aliases-file)
(defvar comint-input-ring-file-name)
(defvar sly-mrepl-history-file-name)
(declare-function eshell-read-aliases-list "em-alias" ())

(defun gdev-native-state--lines (file)
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" nil)))

(defun gdev-native-state--ring (original args variable type write &optional append)
  "Adatta il file del ring, conservando separatori, limiti e filtri del servizio."
  (let ((file (symbol-value variable)))
    (if (not (gdev-native-state--managed-p file type)) (apply original args)
      (if write
          (gdev-state-db-with (db t)
            (let* ((scope (gdev-state-db--scope db type ""))
                   (temporary (make-temp-file "gdev-cronologia-"))
                   (previous (and (boundp 'eshell-hist--new-items) eshell-hist--new-items))
                   done)
              (unwind-protect
                  (progn
                    (if append
                        (cond (scope (write-region (string-join (cdar (gdev-state-db--entries db scope)) "\n")
                                                   nil temporary nil 'silent))
                              ((file-readable-p file) (copy-file file temporary t)))
                      (delete-file temporary))
                    (prog1 (cl-progv (list variable) (list temporary) (apply original args))
                      (when (file-exists-p temporary)
                        (gdev-state-db--put db (or scope (gdev-state-db--scope db type "" t))
                                            "righe" (gdev-native-state--lines temporary)))
                      (setq done t)))
                (unless (or done (not (eq variable 'eshell-history-file-name)))
                  (setq eshell-hist--new-items previous))
                (when (file-exists-p temporary) (delete-file temporary)))))
        (let ((entries (gdev-state-db-entries type "" "righe")))
          (cond
           (entries
            (let ((temporary (make-temp-file "gdev-cronologia-" nil nil (string-join (cdar entries) "\n"))))
              (unwind-protect (cl-progv (list variable) (list temporary) (apply original args))
                (delete-file temporary))))
           ((file-readable-p file)
            (gdev-state-db-with (db t)
              (unless (gdev-state-db--scope db type "")
                (gdev-state-db-set type "" "righe" (gdev-native-state--lines file))))
            (apply original args))
           (t (apply original args))))))))

(defun gdev-native-state--eshell-history (original file flag write)
  (let ((eshell-history-file-name (or file eshell-history-file-name)))
    (gdev-native-state--ring original (list nil flag) 'eshell-history-file-name "comandi_eshell" write flag)))

(with-eval-after-load 'em-hist
  (advice-add 'eshell-read-history :around
              (lambda (fn &optional file silent) (gdev-native-state--eshell-history fn file silent nil)))
  (advice-add 'eshell-write-history :around
              (lambda (fn &optional file append) (gdev-native-state--eshell-history fn file append t))))

(with-eval-after-load 'em-dirs
  (advice-add 'eshell-read-last-dir-ring :around
              (lambda (fn) (gdev-native-state--ring fn nil 'eshell-last-dir-ring-file-name "cartelle_eshell" nil)))
  (advice-add 'eshell-write-last-dir-ring :around
              (lambda (fn) (gdev-native-state--ring fn nil 'eshell-last-dir-ring-file-name "cartelle_eshell" t))))

(defun gdev-native-state--comint (original args write)
  (let ((kind (seq-find (lambda (type) (gdev-native-state--managed-p comint-input-ring-file-name type))
                        '("cronologia_ielm" "cronologia_sly"))))
    (if kind (gdev-native-state--ring original args 'comint-input-ring-file-name kind write)
      (apply original args))))

(with-eval-after-load 'comint
  (advice-add 'comint-read-input-ring :around
              (lambda (fn &rest args) (gdev-native-state--comint fn args nil)))
  (advice-add 'comint-write-input-ring :around
              (lambda (fn) (gdev-native-state--comint fn nil t))))

(with-eval-after-load 'sly-mrepl
  (advice-add 'sly-mrepl--merge-and-save-history :around
              (lambda (fn)
                (if (gdev-native-state--managed-p sly-mrepl-history-file-name "cronologia_sly")
                    (gdev-state-db-with (_db t) (funcall fn))
                  (funcall fn)))))

(defun gdev-native-state--aliases-save (original)
  (if (gdev-native-state--managed-p eshell-aliases-file "alias_eshell")
      (gdev-state-db-with (db t)
        (gdev-state-db--replace db (gdev-state-db--scope db "alias_eshell" "" t)
                                (mapcar (lambda (entry) (cons (car entry) (cadr entry)))
                                        eshell-command-aliases-list)))
    (funcall original)))

(defun gdev-native-state--aliases-read (original)
  (if (gdev-native-state--managed-p eshell-aliases-file "alias_eshell")
      (let ((stored (gdev-state-db-with (db)
                      (when-let* ((scope (gdev-state-db--scope db "alias_eshell" "")))
                        (cons t (gdev-state-db--entries db scope))))))
        (cond (stored (setq eshell-command-aliases-list
                            (mapcar (lambda (entry) (list (car entry) (cdr entry))) (cdr stored))))
              ((file-readable-p eshell-aliases-file)
               (gdev-state-db-with (_db t)
                 (funcall original)
                 (gdev-native-state--aliases-save nil)))))
    (funcall original)))

(with-eval-after-load 'em-alias
  (advice-add 'eshell-read-aliases-list :around #'gdev-native-state--aliases-read)
  (advice-add 'eshell-write-aliases-list :around #'gdev-native-state--aliases-save)
  (advice-add 'eshell/alias :around
              (lambda (fn &rest args)
                (if (and (car args) (gdev-native-state--managed-p eshell-aliases-file "alias_eshell"))
                    (gdev-state-db-with (_db t)
                      (eshell-read-aliases-list)
                      (apply fn args))
                  (apply fn args)))))

(defvar undo-fu-session-directory)
(defvar undo-fu-session-file-limit)
(defconst gdev-native-state--undo-fields
  '((emacs-buffer-undo-list . "annullamenti") (emacs-pending-undo-list . "pendenti")
    (emacs-undo-equiv-table . "equivalenze")))

(defun gdev-native-state-undo-read (file)
  (when (equal (file-name-as-directory (expand-file-name undo-fu-session-directory))
               (expand-file-name "undo/" gdev-state-directory))
    (when-let* ((entries (gdev-state-db-entries "annullamenti" (expand-file-name file))))
      (cons (list (cons 'buffer-size (cdr (assoc "dimensione" entries)))
                  (cons 'buffer-checksum (cdr (assoc "impronta" entries))))
            (mapcar (lambda (field) (cons (car field) (cdr (assoc (cdr field) entries))))
                    gdev-native-state--undo-fields)))))

(defun gdev-native-state-undo-save (file header data)
  (when (equal (file-name-as-directory (expand-file-name undo-fu-session-directory))
               (expand-file-name "undo/" gdev-state-directory))
    (gdev-state-db-with (db t)
      ;; Un nuovo id colloca il documento in testa all’ordine di utilizzo.
      (let* ((path (expand-file-name file)) (old (gdev-state-db--scope db "annullamenti" path)))
        (when old (sqlite-execute db "DELETE FROM ambito WHERE id=?" (list old)))
        (let ((scope (gdev-state-db--scope db "annullamenti" path t)))
          (gdev-state-db--put db scope "dimensione" (alist-get 'buffer-size header))
          (gdev-state-db--put db scope "impronta" (alist-get 'buffer-checksum header))
          (dolist (field gdev-native-state--undo-fields)
            (gdev-state-db--put db scope (cdr field) (alist-get (car field) data))))
        (when (and (not old) (natnump undo-fu-session-file-limit))
          (sqlite-execute db "DELETE FROM ambito WHERE id IN
 (SELECT id FROM ambito WHERE tipo='annullamenti' ORDER BY id DESC LIMIT -1 OFFSET ?)"
                          (list undo-fu-session-file-limit)))))
    t))

(defvar transient-values-file)
(defvar transient-levels-file)
(defvar transient-history-file)
(defun gdev-native-state--transient-kind (file)
  (when (and (stringp file)
             (string-prefix-p (file-name-as-directory (expand-file-name gdev-state-directory))
                              (expand-file-name file)))
    (cond ((equal file (bound-and-true-p transient-levels-file)) "livelli_menu")
          ((equal file (bound-and-true-p transient-values-file)) "valori_menu")
          ((equal file (bound-and-true-p transient-history-file)) "cronologia_menu"))))

(defun gdev-native-state--transient-save (original value file)
  (if-let* ((kind (gdev-native-state--transient-kind file)))
      (gdev-native-state--store kind (mapcar (lambda (entry) (cons (symbol-name (car entry)) (cdr entry))) value))
    (funcall original value file)))

(defun gdev-native-state--transient-load (original file)
  (if-let* ((kind (gdev-native-state--transient-kind file)))
      (let ((stored (gdev-state-db-with (db)
                      (when-let* ((scope (gdev-state-db--scope db kind "")))
                        (cons t (gdev-state-db--entries db scope))))))
        (gdev-native-state--remember kind (cdr stored))
        (if stored
            (mapcar (lambda (entry) (cons (intern (car entry)) (cdr entry))) (cdr stored))
          (when (file-readable-p file)
            (let ((value (funcall original file)))
              (when value (gdev-native-state--transient-save nil value file))
              value))))
    (funcall original file)))

;; Le tre variabili vengono inizializzate durante il caricamento del fork.
(advice-add 'transient--read-file-contents :around #'gdev-native-state--transient-load)
(advice-add 'transient--pp-to-file :around #'gdev-native-state--transient-save)

(defvar bookmark-alist)
(defvar bookmark-default-file)
(defvar bookmark-bookmarks-timestamp)
(defvar bookmark-watch-bookmark-file)
(defvar bookmark-alist-modification-count)
(declare-function bookmark-import-new-list "bookmark")
(declare-function bookmark-bmenu-surreptitiously-rebuild-list "bookmark")
(declare-function bookmark-load "bookmark")

(defun gdev-native-state--bookmark-file-p (file)
  (and (equal (expand-file-name file) (expand-file-name bookmark-default-file))
       (equal (file-name-directory (expand-file-name file))
              (file-name-as-directory (expand-file-name gdev-state-directory)))))

(defun gdev-native-state--bookmarks-write (original file)
  (if (gdev-native-state--bookmark-file-p file)
      (gdev-native-state--store "segnalibri" (list (cons "elenco" bookmark-alist) (cons "revisione" (current-time))))
    (funcall original file)))

(defun gdev-native-state--bookmarks-read (original file &optional overwrite no-msg default)
  (let ((saved (and (gdev-native-state--bookmark-file-p file)
                    (gdev-state-db-entries "segnalibri" ""))))
    (if saved
        (let ((items (cdr (assoc "elenco" saved))))
          (gdev-native-state--remember "segnalibri" saved)
          (if overwrite (setq bookmark-alist items bookmark-alist-modification-count 0)
            (bookmark-import-new-list items)
            (cl-incf bookmark-alist-modification-count))
          (when (or default (equal (expand-file-name file)
                                   (or (car bookmark-bookmarks-timestamp) (expand-file-name bookmark-default-file))))
            (setq bookmark-bookmarks-timestamp (cons (expand-file-name file) (cdr (assoc "revisione" saved)))))
          (bookmark-bmenu-surreptitiously-rebuild-list)
          (run-hooks 'bookmark-after-load-file-hook))
      (prog1 (funcall original file overwrite no-msg default)
        (when (gdev-native-state--bookmark-file-p file)
          (gdev-native-state--bookmarks-write nil file))))))

(defun gdev-native-state--bookmarks-initialize (original)
  (cond ((not (gdev-native-state--bookmark-file-p
               (or (car bookmark-bookmarks-timestamp) bookmark-default-file))) (funcall original))
        ((and (null bookmark-bookmarks-timestamp) (null bookmark-alist))
         (if (gdev-state-db-entries "segnalibri" "" "revisione")
             (bookmark-load bookmark-default-file t t)
           (funcall original)))
        ((and bookmark-watch-bookmark-file bookmark-bookmarks-timestamp)
         (let ((revision (cdar (gdev-state-db-entries "segnalibri" "" "revisione"))))
           (when (and revision (not (equal revision (cdr bookmark-bookmarks-timestamp)))
                      (or (eq bookmark-watch-bookmark-file 'silent)
                          (yes-or-no-p "I segnalibri sono cambiati. Ricaricarli? ")))
             (bookmark-load bookmark-default-file t t))))))

(with-eval-after-load 'bookmark
  (advice-add 'bookmark-write-file :around #'gdev-native-state--bookmarks-write)
  (advice-add 'bookmark-load :around #'gdev-native-state--bookmarks-read)
  (advice-add 'bookmark-maybe-load-default-file :around #'gdev-native-state--bookmarks-initialize))

(provide 'gdev-native-state)
;;; gdev-native-state.el ends here
