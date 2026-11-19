;;; gdev-command-context-test.el --- Prove del contesto dei comandi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ogni ingresso di un comando deve ricavare lo stesso file, la stessa
;; cartella e lo stesso progetto.

;;; Code:

(require 'ert)
(require 'project)
(require 'gdev-command-context)
(require 'gdev-commands)

(defvar project-vc-extra-root-markers)

(defmacro gdev-test-command-context--with-projects (names &rest body)
  "Crea un progetto temporaneo per ciascuno dei NAMES ed esegui BODY.
Ogni nome è legato alla cartella del suo progetto."
  (declare (indent 1))
  `(let* ((gdev-test-base (file-name-as-directory (make-temp-file "gdev-contesto-" t)))
          (project-vc-extra-root-markers '(".project"))
          ,@(mapcar (lambda (name)
                      `(,name (file-name-as-directory
                               (expand-file-name ,(symbol-name name) gdev-test-base))))
                    names))
     (unwind-protect
         (progn
           (dolist (root (list ,@names))
             (make-directory (expand-file-name "sorgenti/interni" root) t)
             (write-region "" nil (expand-file-name ".project" root) nil 'silent))
           ,@body)
       (delete-directory gdev-test-base t))))

(ert-deftest gdev-test-command-context-follows-the-chosen-project ()
  "Durante «Cambia progetto» i comandi usano il progetto scelto."
  (gdev-test-command-context--with-projects (primo secondo)
    (let ((default-directory (expand-file-name "sorgenti/interni/" primo)))
      (should (equal (gdev-project-root) primo))
      (let ((project-current-directory-override secondo))
        (should (equal (gdev-default-directory) secondo))
        (should (equal (gdev-project-root) secondo))
        (should (equal (gdev-command-directory) secondo))
        (should (equal (gdev-command-project) secondo))
        ;; Una cartella esplicita resta quella indicata.
        (should (equal (gdev-project-root default-directory) primo))))))

(ert-deftest gdev-test-command-context-reads-the-row-of-the-view ()
  "Esplora file, Dired e documento indicano il file su cui agisce un comando."
  (require 'dired)
  (gdev-test-command-context--with-projects (primo)
    (let* ((file (expand-file-name "sorgenti/interni/nota.txt" primo))
           (folder (expand-file-name "sorgenti" primo))
           (view (generate-new-buffer " *vista di file*"))
           (document (progn (write-region "testo\n" nil file nil 'silent)
                            (find-file-noselect file)))
           (listing (dired-noselect (expand-file-name "sorgenti/interni/" primo))))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer view
              (setq-local gdev-command-file-function (lambda () folder)))
            (switch-to-buffer view)
            (should (equal (gdev-command-file) folder))
            (should (equal (gdev-command-directory) (file-name-as-directory folder)))
            (should (equal (gdev-command-project) primo))
            (let ((other (split-window)))
              (set-window-buffer other document)
              (should (equal (gdev-command-file other) file))
              (should (equal (gdev-command-directory other) (file-name-directory file)))
              ;; La vista selezionata non cambia leggendo l'altra finestra.
              (should (eq (window-buffer (selected-window)) view)))
            (with-current-buffer listing
              (goto-char (point-min))
              (dired-goto-file file)
              (should (equal (gdev-command-file) file))))
        (dolist (buffer (list view document listing))
          (kill-buffer buffer))))))

(ert-deftest gdev-test-command-context-relative-names-agree-across-entries ()
  "Menu File, Esplora file e menu contestuale copiano lo stesso nome relativo."
  (gdev-test-command-context--with-projects (primo)
    (let* ((folder (file-name-as-directory (expand-file-name "sorgenti" primo)))
           (file (expand-file-name "sorgenti/interni/nota.txt" primo))
           (outside (expand-file-name "fuori.txt" primo))
           (document (progn (write-region "testo\n" nil file nil 'silent)
                            (find-file-noselect file)))
           copied)
      (unwind-protect
          (cl-letf (((symbol-function 'gdev-workspace-roots) (lambda (&optional _) (list folder)))
                    ((symbol-function 'kill-new) (lambda (text &rest _) (setq copied text))))
            (should (equal (gdev-command-relative-name file) "interni/nota.txt"))
            ;; Fuori dalle cartelle dello spazio vale la radice del progetto.
            (should (equal (gdev-command-relative-name outside) "fuori.txt"))
            (with-current-buffer document
              (gdev-copy-file-name)
              (should (equal copied "interni/nota.txt"))
              (gdev-copy-file-location)
              (should (equal copied "interni/nota.txt:1")))
            (with-temp-buffer
              (setq-local gdev-command-file-function (lambda () file))
              (gdev-copy-file-name)
              (should (equal copied "interni/nota.txt"))
              (gdev-copy-file-name t)
              (should (equal copied file))))
        (kill-buffer document)))))

(ert-deftest gdev-test-command-context-finder-shows-the-row-of-the-view ()
  "«Mostra nel Finder» dal menu indica la voce della vista, come il menu contestuale."
  (unless (fboundp 'gdev-macos-reveal-in-finder)
    (let ((config (gdev-module-file :os 'macos ".el"))
          ;; Solo le definizioni: niente impostazioni di sistema nella prova.
          (gdev-macos-p nil))
      (skip-unless (file-exists-p config))
      (load config nil t t)))
  (let (opened)
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program _infile _destination _display &rest args)
                 (setq opened args) 0)))
      (with-temp-buffer
        (setq-local gdev-command-file-function (lambda () "/lavoro/nota.txt"))
        (gdev-macos-reveal-in-finder)
        (should (equal opened '("-R" "/lavoro/nota.txt"))))
      (with-temp-buffer
        (setq default-directory "/lavoro/")
        (gdev-macos-reveal-in-finder)
        (should (equal opened '("-R" "/lavoro/")))))))

;;; gdev-command-context-test.el ends here
