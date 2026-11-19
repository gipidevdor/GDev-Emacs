;;; config.el --- :ui vc-gutter: righe modificate a margine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le righe aggiunte, modificate e cancellate sono segnate nel bordo
;; laterale dei file e degli elenchi di Dired, calcolate in modo
;; asincrono.  C-c g [ e C-c g ] passano da un blocco all'altro,
;; C-c g r ne annulla uno, C-c g s lo prepara, C-c g = lo mostra.

;;; Code:

(require 'gdev-lib)

(use-package diff-hl
  :ensure t
  :hook ((gdev-first-file . global-diff-hl-mode)
         (dired-mode . diff-hl-dired-mode)
         (magit-post-refresh . diff-hl-magit-post-refresh))
  :commands (diff-hl-next-hunk diff-hl-previous-hunk diff-hl-revert-hunk
             diff-hl-show-hunk diff-hl-stage-current-hunk)
  :custom
  ;; Calcola in sottofondo: il buffer non aspetta mai Git.
  (diff-hl-update-async t)
  (diff-hl-draw-borders nil)
  :config
  ;; Nel terminale usa il margine al posto del bordo laterale (fringe).
  (unless (display-graphic-p) (diff-hl-margin-mode 1)))

;;; config.el ends here
