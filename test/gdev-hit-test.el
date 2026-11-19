;;; gdev-hit-test.el --- Prove di regressione per Hit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Usa repository Git locali per esercitare l'aggiornamento di riferimenti,
;; l'apertura di rami e le conferme nella normale interfaccia di Hit.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defvar magit-this-process)
(defvar transient--prefix)
(defvar transient-force-single-column)
(defvar gdev-hit-test--section-map)

(defun gdev-hit-test--git (directory &rest arguments)
  "Esegui Git con ARGUMENTS in DIRECTORY e restituisci la sua risposta."
  (let ((default-directory (file-name-as-directory directory)))
    (with-temp-buffer
      (let ((result (apply #'process-file "git" nil t nil arguments)))
        (unless (eql result 0)
          (error "git %S: %s" arguments (buffer-string))))
      (string-trim (buffer-string)))))

(defun gdev-hit-test--configure-environment ()
  "Isola le impostazioni e l'identità Git delle prove."
  (setenv "GIT_CONFIG_GLOBAL" null-device)
  (setenv "GIT_CONFIG_NOSYSTEM" "1")
  (dolist (role '("AUTHOR" "COMMITTER"))
    (setenv (format "GIT_%s_NAME" role) "GDev")
    (setenv (format "GIT_%s_EMAIL" role) "test@example.org")))

(defun gdev-hit-test--create-upstreams (root)
  "Crea sotto ROOT un remoto, la sua copia e un progetto con due rami concatenati."
  (let ((remote (expand-file-name "remoto.git" root))
        (published (expand-file-name "pubblicazione" root))
        (work (expand-file-name "progetto" root)))
    (gdev-hit-test--git root "init" "-q" "--bare" "--template=" remote)
    (gdev-hit-test--git remote "symbolic-ref" "HEAD" "refs/heads/main")
    (gdev-hit-test--git root "clone" "-q" remote published)
    (gdev-hit-test--git published "commit" "--allow-empty" "-qm" "Base")
    (gdev-hit-test--git published "push" "-q" "origin" "main")
    (gdev-hit-test--git root "clone" "-q" remote work)
    (gdev-hit-test--git work "checkout" "-qb" "integra")
    (gdev-hit-test--git work "branch" "--set-upstream-to=origin/main" "integra")
    (gdev-hit-test--git work "checkout" "-qb" "lavoro")
    (gdev-hit-test--git work "branch" "--set-upstream-to=integra" "lavoro")
    (list remote published work)))

(defun gdev-hit-test--await-git ()
  "Attendi il completamento e la pulizia della sentinella Git."
  (let ((process magit-this-process)
        (deadline (+ (float-time) 10)))
    (should (processp process))
    (while (and (eq process magit-this-process) (< (float-time) deadline))
      (accept-process-output process 0.05))
    (should-not (eq process magit-this-process))
    (process-exit-status process)))

(ert-deftest gdev-hit-test-upstream-fetch-preserves-local-references ()
  "Aggiorna il ramo di riferimento solo se il remoto consente l'avanzamento."
  (skip-unless (executable-find "git"))
  (require 'package)
  (package-activate-all)
  (require 'magit-pull)
  (require 'magit-branch)
  (let ((root (make-temp-file "gdev-hit-ref-" t))
        (process-environment (copy-sequence process-environment)))
    (gdev-hit-test--configure-environment)
    (unwind-protect
        (pcase-let* ((`(,remote ,published ,work) (gdev-hit-test--create-upstreams root))
                     (default-directory (file-name-as-directory work))
                     (base (gdev-hit-test--git work "rev-parse" "integra")))
          (gdev-hit-test--git published "commit" "--allow-empty" "-qm" "Avanzamento remoto")
          (gdev-hit-test--git published "push" "-q" "origin" "main")
          (magit-pull-into-upstream)
          (should (zerop (gdev-hit-test--await-git)))
          (let ((fresh (gdev-hit-test--git work "rev-parse" "integra")))
            (should-not (equal base fresh))
            (should (equal fresh (gdev-hit-test--git published "rev-parse" "HEAD")))
            (should (equal "lavoro" (gdev-hit-test--git work "symbolic-ref" "--short" "HEAD")))

            ;; Una precedente lettura non deve fornire il commit di ripiego.
            (write-region (concat base "\n") nil (expand-file-name ".git/FETCH_HEAD" work) nil 'silent)
            (gdev-hit-test--git work "remote" "set-url" "origin" (expand-file-name "assente" root))
            (magit-pull-into-upstream)
            (should-not (zerop (gdev-hit-test--await-git)))
            (should (equal fresh (gdev-hit-test--git work "rev-parse" "integra")))
            (magit-checkout-remote-ref "origin" "refs/heads/main")
            (should-not (zerop (gdev-hit-test--await-git)))
            (should (equal "lavoro" (gdev-hit-test--git work "symbolic-ref" "--short" "HEAD")))

            (gdev-hit-test--git work "remote" "set-url" "origin" remote)
            (gdev-hit-test--git work "config" "branch.main.pushRemote" "precedente")
            (magit-branch-checkout "main" "origin/main")
            (should-not (zerop (gdev-hit-test--await-git)))
            (should (equal "precedente" (gdev-hit-test--git work "config" "branch.main.pushRemote")))

            (gdev-hit-test--git work "checkout" "-q" "integra")
            (gdev-hit-test--git work "commit" "--allow-empty" "-qm" "Commit locale")
            (gdev-hit-test--git work "checkout" "-q" "lavoro")
            (gdev-hit-test--git published "commit" "--allow-empty" "-qm" "Commit divergente")
            (gdev-hit-test--git published "push" "-q" "origin" "main")
            (let ((local (gdev-hit-test--git work "rev-parse" "integra")))
              (magit-pull-into-upstream)
              (should-not (zerop (gdev-hit-test--await-git)))
              (should (equal local (gdev-hit-test--git work "rev-parse" "integra"))))))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'magit-mode) (file-in-directory-p default-directory root))
            (kill-buffer buffer))))
      (delete-directory root t))))

(ert-deftest gdev-hit-test-commit-explains-which-changes-are-ready ()
  "Un repository pulito, i file nuovi e l'indice producono messaggi distinti."
  (skip-unless (executable-find "git"))
  (require 'package)
  (package-activate-all)
  (require 'magit-commit)
  (require 'git-commit)
  (let* ((root (make-temp-file "gdev-hit-commit-" t))
         (default-directory (file-name-as-directory root))
         (process-environment (copy-sequence process-environment)))
    (gdev-hit-test--configure-environment)
    (unwind-protect
        (progn
          (gdev-hit-test--git root "init" "-q" "--template=")
          (should (equal (cadr (should-error (magit-commit-assert nil) :type 'user-error))
                         "Nessuna modifica da registrare"))
          (write-region "prova\n" nil "nuovo.txt" nil 'silent)
          (should (equal (cadr (should-error (magit-commit-assert nil) :type 'user-error))
                         "Prepara i nuovi file prima di registrare il commit"))
          (gdev-hit-test--git root "add" "nuovo.txt")
          (should (equal (magit-commit-assert nil) '("--")))
          (should (string-search "Registra con" git-commit-default-usage-message))
          (let (prompt)
            (cl-letf (((symbol-function 'magit-y-or-n-p)
                       (lambda (question &optional _) (setq prompt question) nil)))
              (should (equal (cadr (should-error (magit-confirm 'stage-all-changes) :type 'user-error))
                             "Annullato"))
              (should (equal prompt "Preparare tutte le modifiche nell’indice? ")))))
      (delete-directory root t))))

(provide 'gdev-hit-test)
(ert-deftest gdev-hit-test-forge-compact-menu-reflows-a-reused-buffer ()
  "Il menu stretto passa a una colonna e il menu successivo recupera il formato precedente."
  (require 'package)
  (package-activate-all)
  (require 'transient)
  (require 'gdev-modules)
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :tools 'git ".el") nil t t))
  (with-temp-buffer
    (let ((transient--prefix (transient-prefix :command 'forge-dispatch))
          (transient-force-single-column nil)
          (width 66))
      (setq-local truncate-lines t)
      (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) width)))
        (dotimes (_ 2)
          (gdev-git--layout-forge-menu
           (lambda (_) (should transient-force-single-column) (should-not truncate-lines)) nil))
        (setq width 150)
        (gdev-git--layout-forge-menu
         (lambda (_) (should-not transient-force-single-column) (should truncate-lines)) nil)
        (should (local-variable-p 'truncate-lines))
        (setq width 66 transient--prefix (transient-prefix :command 'hit-comandi))
        (gdev-git--layout-forge-menu
         (lambda (_) (should-not transient-force-single-column) (should truncate-lines)) nil)))))

(ert-deftest gdev-hit-test-section-properties-respect-child-and-end ()
  "Assegna le proprietà del genitore solo dove mancano e dentro la sezione."
  (require 'package)
  (package-activate-all)
  (require 'magit-section)
  (with-temp-buffer
    (let ((section (make-instance 'magit-section :type 'parent))
          (child (make-instance 'magit-section :type 'child))
          (other (make-instance 'magit-section :type 'other))
          (gdev-hit-test--section-map (make-sparse-keymap))
          (child-map (make-sparse-keymap)))
      (insert "abcdefghijk")
      (oset section start (copy-marker 3))
      (oset section end (copy-marker 10))
      (oset section keymap 'gdev-hit-test--section-map)
      (oset section children (list child))
      (add-text-properties 5 8 (list 'magit-section child 'keymap child-map))
      (put-text-property 11 12 'magit-section other)
      (goto-char 2)
      (magit-section--set-section-properties section)
      (should (= (point) 2))
      (dolist (position '(3 4 8 9))
        (should (eq (get-text-property position 'magit-section) section))
        (should (eq (get-text-property position 'keymap) gdev-hit-test--section-map)))
      (should (eq (get-text-property 6 'magit-section) child))
      (should (eq (get-text-property 6 'keymap) child-map))
      (should-not (get-text-property 2 'magit-section))
      (should-not (get-text-property 10 'magit-section))
      (should (eq (get-text-property 11 'magit-section) other)))))

(ert-deftest gdev-hit-test-diff-hunk-maps-both-sides ()
  "Calcola entrambe le righe del documento nelle differenze semplici e combinate."
  (require 'package)
  (package-activate-all)
  (require 'magit-diff)
  (pcase-dolist (`(,width ,lines ,positions)
                '((1 (" comune" "+aggiunta" "-tolta" " ultima")
                     ((10 20) (11 21) (11 22) (12 22) (13 23)))
                  (2 ("  comune" " +aggiunta" "- tolta" "+-mista" "  ultima")
                     ((10 20) (11 21) (11 22) (12 22) (12 22) (13 23)))))
    (with-temp-buffer
      (let ((section (make-instance 'magit-hunk-section :type 'hunk)))
        (insert "Intestazione della differenza\n")
        (oset section content (point-marker))
        (oset section combined (> width 1))
        (oset section from-ranges (make-list width '(10 5)))
        (oset section from-range '(10 5))
        (oset section to-range '(20 5))
        (dolist (line lines)
          (insert line "\n"))
        (goto-char (oref section content))
        (dolist (position positions)
          (should (equal (list (magit-diff-hunk-line section t)
                               (magit-diff-hunk-line section nil))
                         position))
          (forward-line))))))

;;; gdev-hit-test.el ends here
