;;; config.el --- :emacs dired: il gestore di file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Dired gestisce i file, sia in locale sia sulle macchine remote.
;;
;;   C-x d  C-c o -   apri una cartella / la cartella del file corrente
;;   TAB              espandi una sottocartella sul posto (vista ad albero)
;;   C-o              menu di tutte le operazioni di Dired
;;   C-x C-q          rinomina i file modificando l'elenco (wdired)
;;   C-c C-r          copia i file marcati con rsync (veloce su alberi grandi)
;;
;; Gli elenchi vengono dall'emulazione di ls scritta in Emacs: identici su
;; macOS, Linux e Windows, senza bisogno dei GNU coreutils.

;;; Code:

(require 'gdev-lib)

(declare-function dired-hide-details-mode "dired" (&optional arg))

(use-package dired
  :ensure nil
  :bind ("C-x C-j" . dired-jump)
  :custom
  (dired-listing-switches "-alhv")
  (dired-dwim-target t)                 ; due Dired affiancati: copia tra loro
  (dired-kill-when-opening-new-dired-buffer t)
  (dired-auto-revert-buffer #'dired-directory-changed-p)
  (dired-recursive-copies 'always)
  (dired-recursive-deletes 'top)
  (dired-create-destination-dirs 'ask)
  (dired-vc-rename-file t)              ; rinomina i file tracciati con git mv
  (dired-free-space 'separate)
  (dired-mouse-drag-files t)
  (wdired-allow-to-change-permissions t)
  :config
  (add-hook 'dired-mode-hook #'dired-hide-details-mode)
  (add-hook 'dired-mode-hook #'hl-line-mode))

;; L'ls di Emacs: prima le cartelle, identico ovunque.
(use-package ls-lisp
  :ensure nil
  :after dired
  :demand t
  :custom
  (ls-lisp-use-insert-directory-program nil)
  (ls-lisp-dirs-first t)
  (ls-lisp-verbosity '(links uid gid))
  (ls-lisp-format-time-list '("%Y-%m-%d %H:%M" "%Y-%m-%d %H:%M"))
  (ls-lisp-use-localized-time-format t))

(use-package dired-subtree
  :ensure t
  :after dired
  :bind (:map dired-mode-map
              ("TAB" . dired-subtree-toggle)
              ("<backtab>" . dired-subtree-cycle))
  :custom (dired-subtree-use-backgrounds nil))

(use-package dired-rsync
  :ensure t
  :after dired
  :bind (:map dired-mode-map ("C-c C-r" . dired-rsync)))

;; Menu per le modalità incluse in Emacs: qui Dired, e anche Isearch e Info.
;; I menu si caricano dalle loro librerie. I tasti appartengono alle modalità
;; native e sono pronti prima che la prima pressione carichi il menu.
(use-package casual
  :ensure t
  :defer t)

(declare-function casual-dired-tmenu "casual-dired")
(declare-function casual-isearch-tmenu "casual-isearch")
(declare-function casual-info-tmenu "casual-info")
(defvar Info-mode-map)

(with-eval-after-load 'dired
  (keymap-set dired-mode-map "C-o" #'casual-dired-tmenu))
(with-eval-after-load 'isearch
  (keymap-set isearch-mode-map "C-o" #'casual-isearch-tmenu))
(with-eval-after-load 'info
  (keymap-set Info-mode-map "C-o" #'casual-info-tmenu))

;;; config.el ends here
