;;; gdev-merge-test.el --- Verifiche dell'unione di file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verifica conflitti, anteprima indipendente, consegna ed esito asincrono.

;;; Code:

(require 'ert)
(require 'gdev-merge)

(defconst gdev-test-merge--conflict
  "prima\n<<<<<<< HEAD\nsopra\n||||||| vecchio\nbase\n=======\nsotto\n>>>>>>> ramo\nultima\n")

(defun gdev-test-merge--write (directory name text)
  (let ((file (expand-file-name name directory)))
    (write-region text nil file nil 'silent)
    file))

(defun gdev-test-merge--content (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro gdev-test-merge--with-files (&rest body)
  (declare (indent 0))
  `(gdev-test--with-layout
     (let ((directory (make-temp-file "gdev-prova-unione-" t))
           (gdev-merge--discarding t)
           preview source result)
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (list preview source result))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
         (delete-directory directory t)))))

(ert-deftest gdev-test-merge-three-files-export-uses-unsaved-source-without-overwrite ()
  (skip-unless (executable-find "git"))
  (gdev-test-merge--with-files
    (let* ((upper (gdev-test-merge--write directory "Superiore.txt" "a\n\nb\n"))
           (base (gdev-test-merge--write directory "Base.txt" "a\n\nb\n"))
           (lower (gdev-test-merge--write directory "Inferiore.txt" "a\n\nB\n"))
           (output (expand-file-name "Risultato.txt" directory)))
      (setq source (find-file-noselect upper))
      (with-current-buffer source
        (goto-char (point-min))
        (delete-char 1)
        (insert "A"))
      (setq preview (gdev-merge-files upper base lower))
      (gdev-test-launch--wait
       (lambda () (eq 'ready (buffer-local-value 'gdev-merge--state preview))))
      (should (equal "A\n\nB\n" (buffer-string)))
      (should (equal "a\n\nb\n" (gdev-test-merge--content upper)))
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) upper)))
        (should-error (gdev-merge-finish) :type 'file-already-exists))
      (should (eq (gdev-workspace-state-get 'gdev-merge-preview) preview))
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) output)))
        (gdev-merge-finish))
      (setq result (get-file-buffer output))
      (should (eq (current-buffer) result))
      (should (equal "A\n\nB\n" (gdev-test-merge--content output)))
      (should-not (gdev-merge-preview-available-p)))))

(ert-deftest gdev-test-merge-three-files-exposes-base-and-blocks-unresolved-export ()
  (skip-unless (executable-find "git"))
  (gdev-test-merge--with-files
    (let ((upper (gdev-test-merge--write directory "uno" "sopra\n"))
          (base (gdev-test-merge--write directory "due" "origine\n"))
          (lower (gdev-test-merge--write directory "tre" "sotto\n")))
      (setq preview (gdev-merge-files upper base lower))
      (gdev-test-launch--wait
       (lambda () (eq 'ready (buffer-local-value 'gdev-merge--state preview))))
      (should (= 1 (gdev-merge--conflicts)))
      (should (looking-at smerge-begin-re))
      (should-error (gdev-merge-finish) :type 'user-error)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Tieni la base comune")))
        (gdev-merge-choose))
      (should (= 0 (gdev-merge--conflicts)))
      (should (equal (buffer-string) "origine\n"))
      (should (equal "sopra\n" (gdev-test-merge--content upper))))))

(ert-deftest gdev-test-merge-current-conflict-navigate-apply-and-undo ()
  (gdev-test-merge--with-files
    (let* ((contents (concat gdev-test-merge--conflict gdev-test-merge--conflict))
           (path (gdev-test-merge--write directory "Conflitto.txt" contents)))
      (setq source (find-file-noselect path))
      (switch-to-buffer source)
      (should (gdev-merge-conflict-available-p))
      (setq preview (gdev-merge-conflict))
      (should (= 2 (gdev-merge--conflicts)))
      (let ((first (point)))
        (call-interactively (key-binding (kbd "C-c C-n")))
        (should (> (point) first))
        (call-interactively (key-binding (kbd "C-c C-p")))
        (should (= (point) first)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Tieni la versione superiore")))
        (gdev-merge-choose)
        (gdev-merge-next)
        (gdev-merge-choose))
      (should (equal contents (with-current-buffer source (buffer-string))))
      (should (= 0 (gdev-merge--conflicts)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (gdev-merge-finish))
      (should (buffer-live-p preview))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (gdev-merge-finish))
      (should (eq source (current-buffer)))
      (should (equal (buffer-string) "prima\nsopra\nultima\nprima\nsopra\nultima\n"))
      (should (equal contents (gdev-test-merge--content path)))
      (undo)
      (should (equal (buffer-string) contents)))))

(ert-deftest gdev-test-merge-refuses-stale-document-after-dialog ()
  (gdev-test-merge--with-files
    (setq source (find-file-noselect
                  (gdev-test-merge--write directory "Conflitto.txt" gdev-test-merge--conflict)))
    (switch-to-buffer source)
    (setq preview (gdev-merge-conflict))
    (smerge-keep-upper)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _)
                 (with-current-buffer source (goto-char (point-max)) (insert "altra modifica\n"))
                 t)))
      (should-error (gdev-merge-finish) :type 'user-error))
    (should (eq preview (gdev-workspace-state-get 'gdev-merge-preview)))
    (should (equal (concat gdev-test-merge--conflict "altra modifica\n")
                   (with-current-buffer source (buffer-string))))))

(ert-deftest gdev-test-merge-closed-workspace-discards-pending-result ()
  (skip-unless (executable-find "git"))
  (gdev-test-merge--with-files
    (let* ((upper (gdev-test-merge--write directory "uno" "sopra\n"))
           (base (gdev-test-merge--write directory "due" "origine\n"))
           (lower (gdev-test-merge--write directory "tre" "sotto\n"))
           (id (gdev-workspace-state-ensure-id)))
      (setq preview (gdev-merge-files upper base lower))
      (let* ((child (buffer-local-value 'gdev-merge--process preview))
             (output (process-buffer child))
             (previous (gdev-workspace-state-current)))
        (tab-bar-new-tab)
        (should-not (gdev-merge-preview-available-p))
        (should (gdev-merge--attached-p preview))
        (gdev-merge--close-workspace previous nil)
        (should-not (buffer-live-p preview))
        (gdev-test-launch--wait (lambda () (not (buffer-live-p output))))
        (should-not (gdev-workspace-state-read 'gdev-merge-preview (gdev-workspace-state-current)))
        (should (gdev-workspace-state-find id))))))

(ert-deftest gdev-test-merge-dirty-preview-survives-close-cancellation ()
  (gdev-test-merge--with-files
    (setq preview (gdev-merge--new-preview))
    (gdev-merge--load preview "Una proposta\n")
    (gdev-merge-resume)
    (insert "Modifica")
    (let ((gdev-merge--discarding nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (gdev-merge--close-workspace (gdev-workspace-state-current) nil) :type 'user-error)))
    (should (eq preview (current-buffer)))
    (should (equal (buffer-string) "ModificaUna proposta\n"))))

(ert-deftest gdev-test-merge-hit-dispatches-the-selected-path-without-ediff ()
  (skip-unless (executable-find "git"))
  (require 'package)
  (package-activate-all)                ; -Q salta l'attivazione dei fork
  (require 'magit-ediff)
  (let ((directory (make-temp-file "gdev-prova-hit-unione-" t))
        result)
    (unwind-protect
        (let* ((default-directory (file-name-as-directory directory))
               (magit-ediff-preview-conflicts-function (lambda (file) (setq result file))))
          (should (= 0 (call-process "git" nil nil nil "init" "-q" directory)))
          (magit-ediff-preview-conflicts "Nome file.txt")
          (should (file-equal-p (file-name-directory result) default-directory))
          (should (equal (file-name-nondirectory result) "Nome file.txt")))
      (delete-directory directory t))))

(provide 'gdev-merge-test)
;;; gdev-merge-test.el ends here
