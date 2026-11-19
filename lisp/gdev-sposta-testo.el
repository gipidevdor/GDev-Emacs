;;; gdev-sposta-testo.el --- Carica il fork locale di Sposta testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Conserva il percorso usato prima che il fork avesse un descrittore ELPA.

;;; Code:

(declare-function gdev-bundled-package-directory "../early-init" (name))

(load (expand-file-name "gdev-sposta-testo"
                        (gdev-bundled-package-directory 'gdev-sposta-testo))
      nil t)

;;; gdev-sposta-testo.el ends here
