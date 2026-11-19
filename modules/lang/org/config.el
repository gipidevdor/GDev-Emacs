;;; config.el --- :lang org: note, attività e Agenda del fork Org GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I file Org in `org-directory' (~/org, se non lo cambi) raccolgono note,
;; attività e procedure operative:
;;
;;   C-c n c    annotazione rapida: un'attività, una nota, una voce
;;              del registro operativo
;;   C-c n a    agenda: cosa è pianificato, in scadenza, in corso
;;   C-c n A    selettore classico dell'Agenda di Org
;;   C-c n n    apre un file di note      C-c n s   cerca in tutte le note
;;   C-c n r    apre una procedura operativa
;;
;; Org GDev è il fork incluso di Org. Nell'Agenda, a apre il calendario,
;; t elenca le attività, m filtra per etichette e s cerca il testo.
;; I comandi e le date dell'Agenda sono in italiano.
;;
;; Una procedura operativa è un file Org i cui passi sono blocchi di codice.
;; C-c C-c su un blocco lo esegue e ne incolla il risultato subito sotto:
;; così il file registra ciò che è stato fatto.  Con una :dir remota il
;; blocco gira su una macchina remota:
;;
;;   #+begin_src sh :dir /ssh:web1:/var/log
;;   tail -n 20 nginx/error.log
;;   #+end_src
;;
;;   #+begin_src sh :dir /ssh:web1|sudo:web1:/
;;   systemctl restart nginx
;;   #+end_src
;;
;; Emacs chiede conferma prima di eseguire qualsiasi blocco: una procedura
;; aperta per errore non parte mai da sola.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-layout)
(require 'gdev-ui)

(declare-function gdev-module-directory "gdev-modules" (kind name))
(autoload 'gdev-org-calendar
  (expand-file-name "gdev-org-calendar" (gdev-module-directory :lang 'org)) nil t)

(defun gdev-org--edit-in-editor (switch buffer context)
  "Apri BUFFER nel gruppo editor durante una modifica di sorgente Org."
  (if (and gdev-layout-mode (memq context '(edit continue exit)))
      (progn
        (when (memq context '(edit continue))
          (with-current-buffer buffer
            (setq gdev-layout-document-p t)))
        (pop-to-buffer-same-window buffer))
    (funcall switch buffer context)))

(defun gdev-org--mark-source-document ()
  "Applica la scheda documento dopo l'inizializzazione del linguaggio."
  (when (and gdev-layout-mode (bound-and-true-p org-src-mode))
    (gdev-layout-mark-document)))

(defgroup gdev-org nil
  "Note e procedure operative (runbook) in Org."
  :group 'gdev)

(defcustom gdev-org-runbooks-directory "runbooks/"
  "Cartella delle procedure operative (runbook), relativa a `org-directory'."
  :type 'string)

(use-package org
  :ensure t
  :commands (org-agenda org-capture org-store-link)
  :custom
  (org-directory (expand-file-name "~/org/")) ; il config.el privato può cambiarla
  (org-startup-indented t)
  (org-startup-folded 'content)
  (org-ellipsis " …")
  (org-pretty-entities t)
  (org-agenda-window-setup 'current-window)
  (org-return-follows-link t)
  (org-log-done 'time)
  (org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "WAIT(w@)" "|" "DONE(d)" "CANCELLED(c@)")))
  (org-refile-targets '((org-agenda-files :maxlevel . 3)))
  (org-refile-use-outline-path 'file)
  (org-outline-path-complete-in-steps nil)
  ;; Blocchi di codice: modificati sul posto, con il rientro con cui sono
  ;; scritti, eseguiti solo su richiesta.
  (org-src-window-setup 'current-window)
  (org-src-preserve-indentation t)
  (org-src-fontify-natively t)
  (org-confirm-babel-evaluate t)
  (org-babel-lisp-eval-fn #'sly-eval)
  (org-capture-templates
   '(("t" "Attività" entry (file "inbox.org")
      "* TODO %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n%a" :empty-lines 1)
     ("n" "Nota" entry (file "notes.org")
      "* %?\n:PROPERTIES:\n:CREATED: %U\n:END:\n" :empty-lines 1)
     ("l" "Registro operativo" entry (file+olp+datetree "ops-log.org")
      "* %<%H:%M> %?\n" :empty-lines 1)
     ("p" "Nota di lettura" entry (file "reading.org")
      "* %?\n%a\n" :empty-lines 1)))
  :config
  (make-directory org-directory t)
  (setq org-default-notes-file (expand-file-name "inbox.org" org-directory))
  (unless org-agenda-files
    (setq org-agenda-files (list org-directory)))
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((emacs-lisp . t) (shell . t) (perl . t) (C . t) (lisp . t) (python . t) (js . t) (sql . t))))

(defun gdev-org-find-note ()
  "Apre un file di `org-directory'."
  (interactive)
  (require 'org)
  (let ((default-directory org-directory))
    (find-file (read-file-name "File di note: " org-directory))))

(defun gdev-org-search-notes ()
  "Cerca in tutti i file di `org-directory'."
  (interactive)
  (require 'org)
  (if (fboundp 'consult-ripgrep)
      (consult-ripgrep org-directory)
    (let ((default-directory org-directory))
      (call-interactively #'rgrep))))
(declare-function consult-ripgrep "consult")

(defun gdev-org-open-runbook ()
  "Apre una procedura operativa (runbook), o ne crea una nuova."
  (interactive)
  (require 'org)
  (let ((directory (expand-file-name gdev-org-runbooks-directory org-directory)))
    (make-directory directory t)
    (find-file (read-file-name "Procedura operativa: " directory))))

(gdev-set-popup-rule "\\`\\*Org \\(Babel\\|Select\\)")
(gdev-set-popup-rule "\\`CAPTURE-" :select t)

(declare-function gdev-pdf-current-page "../../tools/pdf/gdev-pdf" ())

(defun gdev-org-pdf-note ()
  "Aggiungi una nota Org con un collegamento alla pagina del PDF aperto."
  (interactive)
  (unless (and (derived-mode-p 'doc-view-mode 'gdev-pdf-mode) buffer-file-name
               (string-suffix-p ".pdf" buffer-file-name t))
    (user-error "Apri prima un PDF nel lettore"))
  (when (and (derived-mode-p 'gdev-pdf-mode) (not (gdev-pdf-current-page)))
    (user-error "Attendi il caricamento della pagina"))
  (require 'ol-docview)
  (org-capture nil "p"))

(declare-function org-cite-insert "oc")
(defun gdev-org-insert-citation ()
  "Inserisci una citazione da una bibliografia Org."
  (interactive)
  (unless (derived-mode-p 'org-mode) (user-error "Apri prima un documento Org"))
  (require 'oc)
  (call-interactively #'org-cite-insert))

(declare-function org-beamer-export-to-pdf "ox-beamer")
(defun gdev-org-export-slides ()
  "Esporta il documento Org come presentazione PDF Beamer in background."
  (interactive)
  (unless (derived-mode-p 'org-mode) (user-error "Apri prima un documento Org"))
  (require 'ox-beamer)
  (org-beamer-export-to-pdf t))

(gdev-module-after-load 'org-src
  (gdev-module-advice-add 'org-src-switch-to-buffer :around #'gdev-org--edit-in-editor)
  (gdev-module-add-hook 'org-src-mode-hook #'gdev-org--mark-source-document))

(defvar gdev-menu-local-events)

(defun gdev-org--agenda-view ()
  "Applica all'Agenda il profilo grafico comune delle viste di GDev."
  (gdev-ui-view-setup 'table)
  (setq-local display-line-numbers nil
              gdev-layout-document-p t
              gdev-menu-local-events '(agenda)))

(gdev-module-add-hook 'org-agenda-mode-hook #'gdev-org--agenda-view)

;;; config.el ends here
