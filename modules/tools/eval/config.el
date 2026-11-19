;;; config.el --- :tools eval: interprete interattivo e valutazione del codice -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;;   C-c o r    apre nel pannello l'interprete interattivo del
;;              linguaggio corrente (SLY, perl -de0, IELM, Python, Node...)
;;   C-c c e    valuta la regione; senza regione, la forma di primo
;;              livello o l'intera area di testo
;;
;; I moduli dei linguaggi registrano il proprio interprete interattivo con
;; `gdev-set-repl' e il proprio valutatore con `gdev-set-eval'.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(declare-function gdev-call-with-editor "gdev-commands" (function))

(defun gdev-open-repl ()
  "Apre, o mostra di nuovo, l'interprete interattivo del linguaggio."
  (interactive)
  (gdev-call-with-editor
   (lambda ()
     (let* ((handler (or (gdev-handler :repl)
                         (user-error "Nessun interprete interattivo per %s" (format-mode-line mode-name))))
            (buffer (save-window-excursion (funcall handler))))
       (when (buffer-live-p buffer) (pop-to-buffer buffer))))))

(defun gdev-eval-dwim (beg end)
  "Valuta la regione tra BEG ed END, altrimenti l'intera area di testo.
Nelle modalità Lisp, senza una regione attiva, valuta la forma di primo livello
sotto il cursore."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let ((handler (or (gdev-handler :eval)
                     (user-error "La modalità %s non supporta la valutazione del codice"
                                 (format-mode-line mode-name)))))
    (funcall handler (or beg (point-min)) (or end (point-max)))
    (when (use-region-p) (deactivate-mark))))

;;; config.el ends here
