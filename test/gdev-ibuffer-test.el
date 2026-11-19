;;; gdev-ibuffer-test.el --- Prove dei gruppi di progetto in Ibuffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'assegnazione dei documenti a gruppi distinti quando le
;; cartelle hanno lo stesso nome, sono annidate o hanno un alias locale.

;;; Code:

(require 'ert)
(require 'gdev-modules)
(require 'ibuffer)
(require 'package)

(ert-deftest gdev-ibuffer-test-groups-follow-project-paths ()
  "Lo stesso nome di cartella e un alias locale non fanno perdere gruppi."
  (skip-unless (executable-find "git"))
  (package-activate-all)
  (load (gdev-module-file :emacs 'ibuffer ".el") nil t t)
  (let* ((fixture (make-temp-file "gdev-ibuffer-test-" t))
         (workspace (expand-file-name "lavoro/" fixture))
         (alias (expand-file-name "alias" fixture))
         (name "*Prova documenti e strumenti*")
         documents)
    (unwind-protect
        (save-window-excursion
          (make-directory workspace)
          (make-symbolic-link (directory-file-name workspace) alias)
          (dolist (entry '(("est/progetto/" . "alfa.txt")
                           ("ovest/progetto/" . "beta.txt")
                           ("est/progetto/fork/progetto/" . "gamma.txt")))
            (let ((directory (expand-file-name (car entry) workspace)))
              (make-directory directory t)
              (should (zerop (call-process "git" nil nil nil "-C" directory "init" "-q")))
              (write-region "Documento\n" nil (expand-file-name (cdr entry) directory)))
            (push (find-file-noselect (expand-file-name (concat (car entry) (cdr entry))
                                                       (file-name-as-directory alias)))
                  documents))
          (ibuffer nil name)
          (with-current-buffer name
            (should (commandp 'gdev-ibuffer-group-by-project))
            (should (string-match-p "\\bNome\\b" (buffer-string)))
            (dolist (entry '(("alfa.txt" . "est/progetto")
                             ("beta.txt" . "ovest/progetto")
                             ("gamma.txt" . "fork/progetto")))
              (ibuffer-jump-to-buffer (car entry))
              (should (equal (get-text-property (point) 'ibuffer-filter-group) (cdr entry)))))
          (should (equal (gdev-ibuffer--project-path workspace)
                         (gdev-ibuffer--project-path alias))))
      (when-let* ((buffer (get-buffer name))) (kill-buffer buffer))
      (mapc #'kill-buffer documents)
      (delete-directory fixture t))))

(ert-deftest gdev-ibuffer-test-narrow-header-keeps-group-identity ()
  "Il titolo abbreviato conserva l'identità, il percorso e l'indicatore di chiusura."
  (package-activate-all)
  (load (gdev-module-file :emacs 'ibuffer ".el") nil t t)
  (let* ((name "cartella-con-un-nome-lungo/progetto")
         (root (concat "/tmp/" name "/"))
         (ibuffer-filter-groups `((,name (predicate gdev-ibuffer--in-project-p '(,root)))))
         (args (list name (concat name " ...") "Testo a monte" nil nil)))
    (cl-letf (((symbol-function 'gdev-ibuffer--view-width) (lambda () 18))
              ((symbol-function 'string-pixel-width) (lambda (label &rest _) (string-width label))))
      (setq args (gdev-ibuffer--fit-group-header args)))
    (should (equal (nth 0 args) name))
    (should (string-suffix-p "… ..." (nth 1 args)))
    (should (<= (string-width (concat "[ " (nth 1 args) " ]")) 18))
    (should (equal (nth 2 args) root))))

(ert-deftest gdev-ibuffer-test-path-labels-cover-nesting-and-remote-hosts ()
  "I nomi restano univoci e leggere un percorso remoto non apre connessioni."
  (package-activate-all)
  (load (gdev-module-file :emacs 'ibuffer ".el") nil t t)
  (require 'tramp)
  (let* ((server-a "/ssh:build-a:/srv/work/progetto/")
         (server-b "/ssh:build-b:/srv/work/progetto/")
         (short "/team/a/progetto/")
         (long "/other/team/a/progetto/"))
    (cl-letf (((symbol-function 'file-truename)
               (lambda (&rest _) (ert-fail "Richiesto il percorso reale a un server")))
              ((symbol-function 'tramp-maybe-open-connection)
               (lambda (&rest _) (ert-fail "Tentata una connessione remota"))))
      (dolist (remote (list server-a server-b))
        (should (equal (gdev-ibuffer--project-path remote) remote)))
      (should (equal (gdev-ibuffer--project-label server-a (list server-a server-b))
                     "ssh:build-a:/srv/work/progetto"))
      (with-temp-buffer
        (setq-local default-directory server-b)
        (should (gdev-ibuffer--in-project-p (list server-b)))
        (should-not (gdev-ibuffer--in-project-p (list server-a)))))
    (should (equal (gdev-ibuffer--project-label short (list short long))
                   "/team/a/progetto"))
    (should (equal (gdev-ibuffer--project-label long (list short long))
                   "other/team/a/progetto"))))

;;; gdev-ibuffer-test.el ends here
