;;; magit-pull.el --- Update local objects and refs  -*- lexical-binding:t -*-

;; Copyright (C) 2008-2026 The Magit Project Contributors

;; Author: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>
;; Maintainer: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Modificato per Hit (2026-11-15): aggiornamento del riferimento con un solo fetch.

;; Magit is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library implements pull commands.

;;; Code:

(require 'magit)

;;; Options

(defcustom magit-pull-or-fetch nil
  "Whether `magit-pull' also offers some fetch suffixes."
  :package-version '(magit . "3.0.0")
  :group 'magit-commands
  :type 'boolean)

;;; Commands

;;;###autoload(autoload 'magit-pull "magit-pull" nil t)
(transient-define-prefix magit-pull ()
  "Pull from another repository."
  :man-page "git-pull"
  :incompatible
  '(("--ff-only" "--rebase=true" "--rebase=merges" "--rebase=interactive"))
  [:description
   (lambda () (if magit-pull-or-fetch "Opzioni di integrazione" "Opzioni"))
   ("-f" "Solo avanzamento lineare" "--ff-only")
   ("-r" magit-pull:--rebase)
   ("-A" "Accantona automaticamente" "--autostash" :level 7)
   ("-F" "Forza" ("-f" "--force"))]
  [:description
   (lambda ()
     (if-let ((branch (magit-get-current-branch)))
         (concat
          (propertize "Integra in " 'face 'transient-heading)
          (propertize branch       'face 'magit-branch-local)
          (propertize " da"      'face 'transient-heading))
       (propertize "Scarica e integra da" 'face 'transient-heading)))
   ("p" magit-pull-from-pushremote)
   ("u" magit-pull-from-upstream)
   ("e" "Da un altro remoto"         magit-pull-branch)]
  [:description
   (lambda ()
     (format (propertize "Scarica in %s da" 'face 'transient-heading)
             (magit-get-upstream-branch)))
   ("U" magit-pull-into-upstream :level 7)]
  ["Scarica da"
   :if-non-nil magit-pull-or-fetch
   ("f" "Remoti"           magit-fetch-all-no-prune)
   ("F" "Remoti e rimuovi i riferimenti obsoleti" magit-fetch-all-prune)]
  ["Scarica riferimenti"
   :if-non-nil magit-pull-or-fetch
   ("o" "Un altro ramo"    magit-fetch-branch)
   ("s" "Specifica dei riferimenti"  magit-fetch-refspec)
   ("m" "Sottomoduli"        magit-fetch-modules)]
  ["Configura"
   ("r" magit-branch.<branch>.rebase :if magit-get-current-branch)
   ("C" "Variabili…" magit-branch-configure)]
  (interactive)
  (transient-setup 'magit-pull nil nil :scope (magit-get-current-branch)))

(defun magit-pull-arguments ()
  (transient-args 'magit-pull))

(transient-define-infix magit-pull:--rebase ()
  :class 'transient-option
  :description "Rebase local commits"
  :argument "--rebase="
  :shortarg "-r"
  :choices '("true" "merges" "interactive" "false"))

;;;###autoload(autoload 'magit-pull-from-pushremote "magit-pull" nil t)
(transient-define-suffix magit-pull-from-pushremote (args)
  "Pull from the push-remote of the current branch.

With a prefix argument or when the push-remote is either not
configured or unusable, then let the user first configure the
push-remote."
  :if #'magit-get-current-branch
  :description #'magit-pull--pushbranch-description
  (interactive (list (magit-pull-arguments)))
  (pcase-let ((`(,branch ,remote)
               (magit--select-push-remote "pull from there")))
    (run-hooks 'magit-credential-hook)
    (magit-run-git-with-editor "pull" args remote branch)))

(defun magit-pull--pushbranch-description ()
  ;; Also used by `magit-rebase-onto-pushremote'.
  (let* ((branch (magit-get-current-branch))
         (target (magit-get-push-branch branch t))
         (remote (magit-get-push-remote branch))
         (v (magit--push-remote-variable branch t)))
    (cond (target)
          ((member remote (magit-list-remotes))
           (format "%s, sostituisci quello mancante" v))
          (remote
           (format "%s, correggi quello non valido" v))
          ((format "%s, imposta il ramo" v)))))

;;;###autoload(autoload 'magit-pull-from-upstream "magit-pull" nil t)
(transient-define-suffix magit-pull-from-upstream (args)
  "Pull from the upstream of the current branch.

With a prefix argument or when the upstream is either not
configured or unusable, then let the user first configure
the upstream."
  :if #'magit-get-current-branch
  :description #'magit-pull--upstream-description
  (interactive (list (magit-pull-arguments)))
  (let* ((branch (or (magit-get-current-branch)
                     (user-error "Nessun ramo attivo")))
         (remote (magit-get "branch" branch "remote"))
         (merge  (magit-get "branch" branch "merge")))
    (when (or current-prefix-arg
              (not (or (magit-get-upstream-branch branch)
                       (magit--unnamed-upstream-p remote merge))))
      (magit-set-upstream-branch
       branch (magit-read-upstream-branch
               branch (format "Imposta il ramo di riferimento di %s e integra da lì" branch)))
      (setq remote (magit-get "branch" branch "remote"))
      (setq merge  (magit-get "branch" branch "merge")))
    (run-hooks 'magit-credential-hook)
    (magit-run-git-with-editor "pull" args remote merge)))

(defun magit-pull--upstream-description ()
  (and-let ((branch (magit-get-current-branch)))
    (or (magit-get-upstream-branch branch)
        (let ((remote (magit-get "branch" branch "remote"))
              (merge  (magit-get "branch" branch "merge"))
              (u (magit--propertize-face "@{upstream}" 'bold)))
          (cond
            ((magit--unnamed-upstream-p remote merge)
             (format "%s da %s"
                     (magit--propertize-face merge 'magit-branch-remote)
                     (magit--propertize-face remote 'bold)))
            ((magit--valid-upstream-p remote merge)
             (concat u ", sostituisci quello mancante"))
            ((or remote merge)
             (concat u ", correggi quello non valido"))
            ((concat u ", imposta il ramo")))))))

;;;###autoload(autoload 'magit-pull-into-upstream "magit-pull" nil t)
(transient-define-suffix magit-pull-into-upstream ()
  "Aggiorna il ramo di riferimento locale a partire dal suo remoto.

Il ramo resta nella posizione precedente se il recupero fallisce o se
Git rifiuta l'aggiornamento, per esempio quando i rami sono divergenti."
  :if #'magit-pull--upstreams
  :description (##cdr (magit-pull--upstreams))
  (interactive)
  (if-let ((upstream (car (magit-pull--upstreams))))
      ;; A refspec leaves validation and the update to the same Git process.
      (magit-git-fetch (magit-get "branch" upstream "remote")
                       (list (concat (magit-get "branch" upstream "merge")
                                     ":refs/heads/" upstream)))
    (user-error "Impossibile aggiornare il ramo di riferimento in secondo piano")))

(defun magit-pull--upstreams ()
  (and-let* ((up1 (magit-get-upstream-branch))
             (_   (magit-local-branch-p up1))
             (up2 (magit-get-upstream-branch up1))
             (_   (magit-remote-branch-p up2)))
    (cons up1 up2)))

;;;###autoload
(defun magit-pull-branch (source args)
  "Pull from a branch read in the minibuffer."
  (interactive (list (magit-read-remote-branch "Integra dal ramo remoto" nil nil nil t)
                     (magit-pull-arguments)))
  (run-hooks 'magit-credential-hook)
  (pcase-let ((`(,remote . ,branch)
               (magit-get-tracked source)))
    (magit-run-git-with-editor "pull" args remote branch)))

;;; _
(provide 'magit-pull)
;; Local Variables:
;; read-symbol-shorthands: (
;;   ("and$"         . "cond-let--and$")
;;   ("thread$"      . "cond-let--thread$")
;;   ("when$"        . "cond-let--when$")
;;   ("and-let*"     . "cond-let--and-let*")
;;   ("and-let"      . "cond-let--and-let")
;;   ("if-let*"      . "cond-let--if-let*")
;;   ("if-let"       . "cond-let--if-let")
;;   ("when-let*"    . "cond-let--when-let*")
;;   ("when-let"     . "cond-let--when-let")
;;   ("while-let*"   . "cond-let--while-let*")
;;   ("while-let"    . "cond-let--while-let")
;;   ("match-string" . "match-string")
;;   ("match-str"    . "match-string-no-properties"))
;; End:
;;; magit-pull.el ends here
