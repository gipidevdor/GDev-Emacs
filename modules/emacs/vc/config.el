;;; config.el --- :emacs vc: controllo di versione di base, cronologia, conflitti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Controllo di versione di Emacs, complementare al modulo :tools git:
;;
;;   C-c g t     macchina del tempo: scorri le versioni passate del file
;;   C-c g o     copia il collegamento alla riga corrente sul sito
;;               che ospita l'archivio Git
;;   C-c g m     prefisso per risolvere i conflitti (smerge): n/p conflitto
;;               successivo/precedente, u/l tieni la parte sopra/sotto,
;;               a tieni tutto, E apri ediff
;;
;; .gitignore, .gitattributes e .gitconfig hanno le loro modalità.

;;; Code:

(require 'gdev-lib)

(declare-function ediff-setup-windows-plain "ediff-wind")
(declare-function gdev-comparison--split-window "gdev-commands" ())
(defvar vc-git-diff-switches)
(defvar smerge-command-prefix)
(defvar ediff-window-setup-function)
(defvar ediff-split-window-function)
(defvar ediff-keep-variants)

(setq vc-handled-backends '(Git)        ; non cerca SVN, Hg, Bzr...
      vc-git-diff-switches '("--histogram")
      vc-make-backup-files nil)

(use-package git-timemachine
  :ensure t
  :commands git-timemachine-toggle)

(use-package git-link
  :ensure t
  :commands (git-link git-link-commit git-link-homepage)
  :custom (git-link-use-commit t))       ; collegamenti sempre validi

(use-package git-modes :ensure t)

;; Con repeat-mode, dopo il primo comando di smerge, n, p, u e l si ripetono.
(setq smerge-command-prefix (kbd "C-c g m"))

;; Ediff resta nella finestra di sistema (frame) corrente, senza aprirne altre.
(setq ediff-window-setup-function #'ediff-setup-windows-plain
      ediff-split-window-function #'gdev-comparison--split-window
      ediff-keep-variants nil)

;;; config.el ends here
