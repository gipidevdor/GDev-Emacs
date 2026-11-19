;;; config.el --- :completion vertico: completamento e ricerca nel minibuffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ogni domanda che Emacs pone nella riga delle richieste
;; riceve un elenco verticale e filtrabile.  Pacchetti piccoli, ognuno
;; estende un'interfaccia già presente in Emacs:
;;
;;   vertico     elenco verticale dei candidati
;;   orderless   parole in qualunque ordine: "buf proj" trova project-buffer
;;   marginalia  note accanto ai candidati (descrizioni, dimensioni, modalità)
;;   consult     Consult GDev (originale Consult): ricerca e navigazione con
;;               anteprima dal vivo (C-x b, M-s r...)
;;   embark      azioni sul candidato o su ciò che è sotto il cursore (C-.)
;;
;; In una ricerca, C-. E esporta i risultati in un'area di testo
;; modificabile sul posto, poi da salvare: così si cerca e sostituisce in
;; tutto il progetto.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-layout)

(use-package vertico
  :ensure t
  :hook (emacs-startup . vertico-mode)
  :custom
  (vertico-count 10)
  (vertico-cycle t)
  (vertico-resize 'grow-only)
  :config
  ;; vertico-repeat (C-c s z) riprende l'ultima sessione di completamento.
  (add-hook 'minibuffer-setup-hook #'vertico-repeat-save))

(use-package vertico-directory
  :after vertico
  :ensure nil                           ; incluso in vertico
  ;; Backspace cancella un intero tratto del percorso; ~/ e / lo ricominciano.
  :bind (:map vertico-map
              ("RET" . vertico-directory-enter)
              ("DEL" . vertico-directory-delete-char)
              ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package vertico-multiform
  :after vertico
  :ensure nil                           ; incluso in vertico
  :demand t
  :custom
  ;; Nella disposizione GDev la ricerca resta nella riga delle richieste.
  (vertico-multiform-categories
   (unless (gdev-module-p :ui 'workbench) '((consult-grep buffer))))
  :config (vertico-multiform-mode 1))

(use-package orderless
  :ensure t
  :demand t
  :custom
  (completion-styles '(orderless basic))
  ;; I percorsi si completano un tratto alla volta (/u/l/b -> /usr/local/bin).
  (completion-category-overrides '((file (styles partial-completion))))
  (completion-category-defaults nil)
  ;; Uno spazio letterale si scrive "\ ".
  (orderless-component-separator #'orderless-escapable-split-on-space))

(use-package marginalia
  :ensure t
  :hook (emacs-startup . marginalia-mode)
  :bind (:map minibuffer-local-map ("M-A" . marginalia-cycle)))

;;;; Ricerca e navigazione

(defun gdev-consult--non-document-p (name _)
  "Esclude dall'anteprima le aree di servizio."
  (unless (eq (gdev-layout--role (get-buffer name)) 'editor) t))

(defun gdev-search-symbol-at-point ()
  "Cerca nell'area di testo il simbolo sotto il cursore."
  (interactive)
  (consult-line (thing-at-point 'symbol t)))

(defun gdev-search-project-for-symbol-at-point ()
  "Cerca nel progetto il simbolo sotto il cursore."
  (interactive)
  (consult-ripgrep (gdev-project-root) (thing-at-point 'symbol t)))

(defun gdev-search-directory (directory)
  "Cerca con ripgrep in DIRECTORY (richiesta) e nelle sue sottocartelle."
  (interactive "DCerca nella cartella: ")
  (consult-ripgrep directory))

(defun gdev-search-other-project ()
  "Cerca in un progetto noto diverso da quello corrente."
  (interactive)
  (consult-ripgrep (project-prompt-project-dir)))
(declare-function consult-line "consult")
(declare-function consult-ripgrep "consult")
;; Serve alla macro `consult-customize', che la espande: nessun uso esplicito.
(declare-function consult--customize-put "consult" (cmds prop form))
(declare-function project-prompt-project-dir "project" (&optional prompt predicate require-known))
(defvar xref-show-xrefs-function)
(defvar xref-show-definitions-function)

(use-package consult
  :ensure t
  :bind (;; Tasti standard, potenziati con anteprima e restringimento (narrow).
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("C-x 5 b" . consult-buffer-other-frame)
         ("C-x p b" . consult-project-buffer)
         ("C-x r b" . consult-bookmark)
         ("C-x C-r" . consult-recent-file)
         ("M-y" . consult-yank-pop)
         ("M-g g" . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-g e" . consult-compile-error)
         ("M-g f" . consult-flymake)
         ("M-g o" . consult-outline)
         ("M-g m" . consult-mark)
         ("M-g k" . consult-global-mark)
         ("M-g i" . consult-imenu)
         ("M-g I" . consult-imenu-multi)
         ("M-s r" . consult-ripgrep)
         ("M-s g" . consult-git-grep)
         ("M-s f" . consult-find)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ("M-s k" . consult-keep-lines)
         ("M-s u" . consult-focus-lines)
         ("M-s e" . consult-isearch-history)
         :map isearch-mode-map
         ("M-e" . consult-isearch-history)
         ("M-s l" . consult-line)
         :map minibuffer-local-map
         ("M-s" . consult-history)
         ("M-r" . consult-history))
  :commands (consult-theme consult-locate consult-man)
  :init
  ;; xref (M-. M-?) elenca i risultati multipli con consult, in anteprima.
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref
        register-preview-delay 0.3
        register-preview-function #'consult-register-format)
  :custom
  (consult-narrow-key "<")
  (consult-preview-partial-size (* 512 1024))
  :config
  ;; L'anteprima di altri file è esplicita e parte da un gruppo editor.
  (consult-customize
   consult-ripgrep consult-git-grep consult-grep consult-find
   consult-bookmark consult-recent-file consult-xref
   consult-buffer consult-project-buffer
   gdev-search-directory gdev-search-other-project gdev-search-project-for-symbol-at-point
   :preview-key (if gdev-layout-mode
                    (unless (window-parameter nil 'window-side) "M-.")
                  '(:debounce 0.25 any))
   consult-buffer-other-window :preview-key nil)
  (when gdev-layout-mode
    (setq consult-preview-excluded-buffers #'gdev-consult--non-document-p)))

;; In ogni richiesta di file, C-x C-d salta a cartelle recenti e host SSH.
(use-package consult-dir
  :ensure t
  :bind ("C-x C-d" . consult-dir)
  :commands consult-dir-jump-file
  :init
  (with-eval-after-load 'vertico
    (keymap-set vertico-map "C-x C-d" #'consult-dir)
    (keymap-set vertico-map "C-x C-j" #'consult-dir-jump-file))
  :custom
  (consult-dir-project-list-function #'consult-dir-project-dirs)
  :config
  ;; Gli host di ~/.ssh/config diventano candidati /ssh:host:.
  (add-to-list 'consult-dir-sources 'consult-dir--source-tramp-ssh t))

;;;; Azioni contestuali

(use-package embark
  :ensure t
  :bind (("C-." . embark-act)          ; agisci su cursore o selezione
         ("M-'" . embark-dwim)         ; l'azione ovvia, subito
         ("C-h B" . embark-bindings))  ; cerca tra tutte le scorciatoie attive
  :init
  ;; Dopo un tasto prefisso, C-h elenca le continuazioni con il completamento.
  (setq prefix-help-command #'embark-prefix-help-command))

;; L'anteprima nelle raccolte la registra embark-consult da solo: il vecchio
;; `consult-preview-at-point-mode' è stato rimosso da Consult 3.4.
(use-package embark-consult
  :ensure t
  :after (embark consult))

;; I risultati di ricerca modificabili sono inclusi in Emacs 31 (tasto e in un
;; buffer di grep); su Emacs 30 li fornisce wgrep.  La scelta avviene in
;; compilazione, quindi Emacs 31 non lo installa mai (se cambi versione di
;; Emacs serve un `gdev sync').
(static-if (< emacs-major-version 31)
    (use-package wgrep
      :ensure t
      :custom (wgrep-auto-save-buffer t)))

;;; config.el ends here
