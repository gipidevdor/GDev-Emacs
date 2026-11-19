;;; config.el --- :completion corfu: completamento a comparsa nelle aree di testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Mentre scrivi, una finestra a comparsa mostra i completamenti forniti
;; da Eglot, SLY o dalla modalità principale, per esempio in Emacs Lisp
;; o nelle proprietà CSS. Cape aggiunge nomi di file e parole delle aree
;; di testo aperte quando non ci sono altre proposte.
;; TAB rientra la riga, oppure completa se la riga è già rientrata.

;;; Code:

(require 'gdev-lib)

(defvar savehist-additional-variables)

(setq tab-always-indent 'complete
      completion-cycle-threshold 3)

(use-package corfu
  :ensure t
  :hook (emacs-startup . global-corfu-mode)
  :custom
  (corfu-auto t)                        ; compare mentre scrivi
  (corfu-auto-delay 0.15)
  (corfu-auto-prefix 2)
  (corfu-cycle t)
  (corfu-preselect 'prompt)             ; RET non inserisce mai per sbaglio
  (corfu-quit-no-match 'separator)
  (corfu-popupinfo-delay '(0.6 . 0.2))
  :config
  (corfu-popupinfo-mode 1)              ; documentazione accanto al riquadro
  (corfu-history-mode 1)                ; prima le scelte frequenti
  (with-eval-after-load 'savehist
    (add-to-list 'savehist-additional-variables 'corfu-history)))

(use-package cape
  :ensure t
  :init
  ;; In coda: le fonti della modalità (Eglot, SLY) vengono sempre prima.
  (add-hook 'completion-at-point-functions #'cape-file 90)
  ;; Eglot filtra in locale l'elenco che il server dichiara completo e lo
  ;; richiede di nuovo quando è parziale.  `cape-wrap-buster' lo
  ;; svuoterebbe a ogni tasto, con una richiesta sincrona per carattere.
  (add-hook 'completion-at-point-functions #'cape-dabbrev 95))

;;; config.el ends here
