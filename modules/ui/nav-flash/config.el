;;; config.el --- :ui nav-flash: fa lampeggiare la riga dopo un salto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un breve lampo mostra dove è arrivato il cursore dopo un salto tra
;; finestre, una ricentratura o un risultato di ricerca.  Usa `pulse',
;; incluso in Emacs.

;;; Code:

(require 'gdev-lib)

(defun gdev-nav-flash-line (&rest _)
  "Evidenzia per un istante la riga corrente."
  (pulse-momentary-highlight-one-line (point)))

(dolist (command '(recenter-top-bottom other-window scroll-up-command
                   scroll-down-command ace-window))
  (advice-add command :after #'gdev-nav-flash-line))
(add-hook 'consult-after-jump-hook #'gdev-nav-flash-line)
(add-hook 'xref-after-jump-hook #'gdev-nav-flash-line)

;;; config.el ends here
