;;; gdev-sposta-testo.el --- Sposta righe e selezioni -*- lexical-binding: t; -*-

;; Derivato da move-text.el di Jason Milkins <jasonm23@gmail.com>.
;; L'originale riconosce Andy Stewart (LazyCat) per basic-edit-toolkit.el.
;; Sorgente: https://github.com/emacsfodder/move-text/blob/142890cfb46d9c374113b4b49021a4202033147b/move-text.el
;; Modificato per GDev-Emacs il 2026-11-15: nomi e guida in italiano,
;; spostamenti atomici, gestione del prefisso e dei limiti del buffer.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  See COPYING.

;;; Commentary:

;; I comandi del modulo :editor motion spostano la riga corrente o il testo
;; selezionato. Il prefisso numerico indica di quante righe spostarsi.

;;; Code:

(declare-function evil-visual-state-p "evil-states")
(declare-function evil-visual-select "evil-states")
(declare-function evil-visual-type "evil-states")

(defun gdev-sposta-testo--riga (righe)
  "Sposta la riga corrente di RIGHE, conservando la colonna del cursore."
  (let* ((colonna (current-column))
         (inizio (line-beginning-position))
         (fine (line-end-position))
         (destinazione
          (save-excursion
            (forward-line righe)
            ;; Un fine buffer subito dopo il ritorno a capo non è una riga.
            (when (and (> righe 0) (eobp) (bolp))
              (forward-line -1))
            (line-beginning-position))))
    (unless (= inizio (point-max))
      (cond
       ((< destinazione inizio)
        (transpose-regions destinazione (1- inizio) inizio fine)
        (goto-char destinazione)
        (move-to-column colonna))
       ((> destinazione inizio)
        (let ((fine-destinazione (save-excursion
                                   (goto-char destinazione)
                                   (line-end-position))))
          (transpose-regions inizio fine (1+ fine) fine-destinazione)
          (goto-char (- fine-destinazione (- fine inizio)))
          (move-to-column colonna)))))))

(defun gdev-sposta-testo--regione (righe)
  "Sposta di RIGHE il testo esatto della regione e mantienilo selezionato."
  (let* ((inizio (region-beginning))
         (fine (region-end))
         (cursore-all-inizio (= (point) inizio))
         (destinazione (save-excursion
                         (goto-char (if (< righe 0) inizio fine))
                         (forward-line righe)
                         (point))))
    (cond
     ((and (< righe 0) (< destinazione (save-excursion (goto-char inizio) (line-beginning-position))))
      (transpose-regions destinazione destinazione inizio fine))
     ((and (> righe 0) (> destinazione fine))
      (transpose-regions inizio fine destinazione destinazione)
      (setq destinazione (- destinazione (- fine inizio))))
     (t (setq destinazione inizio)))
    (let ((nuova-fine (+ destinazione (- fine inizio))))
      (goto-char (if cursore-all-inizio destinazione nuova-fine))
      (set-mark (if cursore-all-inizio nuova-fine destinazione)))
    (setq deactivate-mark nil)
    (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
      (evil-visual-select (region-beginning) (region-end) (evil-visual-type)))))

(defun gdev-sposta-testo-giu (righe)
  "Sposta verso il basso di RIGHE la riga o la selezione corrente."
  (interactive "p")
  (unless (zerop righe)
    (atomic-change-group
      (if (use-region-p)
          (gdev-sposta-testo--regione righe)
        (gdev-sposta-testo--riga righe)))))

(defun gdev-sposta-testo-su (righe)
  "Sposta verso l'alto di RIGHE la riga o la selezione corrente."
  (interactive "p")
  (gdev-sposta-testo-giu (- righe)))

(provide 'gdev-sposta-testo)
;;; gdev-sposta-testo.el ends here
