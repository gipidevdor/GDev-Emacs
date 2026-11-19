;;; config.el --- :checkers spell: controllo ortografico di commenti, stringhe e testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Controllo ortografico con Jinx: esamina solo il testo visibile, tramite
;; la libreria Enchant, con i dizionari inglese e italiano; nel codice
;; guarda soltanto commenti e stringhe.  M-$ corregge la parola sotto il
;; cursore (o l'errore precedente), C-M-$ cambia lingua, C-c t s attiva o
;; disattiva il controllo.  Richiede enchant (Brewfile).

;;; Code:

(require 'gdev-lib)

(use-package jinx
  :if (gdev-find-executable "enchant-2")
  :ensure t
  :hook (gdev-first-file . global-jinx-mode)
  :bind (("M-$" . jinx-correct)
         ("C-M-$" . jinx-languages))
  :custom
  (jinx-languages "en_US it")
  (jinx-module-cache-directory
   (gdev-state-file (format "native-modules/jinx-%s-%s-%s/"
                            (cadr (assq 'jinx gdev-bundled-packages))
                            emacs-version system-configuration))))

;;; config.el ends here
