;;; gdev-doc-view.el --- Vista paginata da GNU Emacs DocView -*- lexical-binding: t; -*-
;; GDev 2026-11-19: Dichiarazioni esplicite e pulizia delle immagini compatibile con i backend disponibili.

;; Copyright (C) 2007-2025 Free Software Foundation, Inc.
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Author: Tassilo Horn <tsdh@gnu.org>
;; Keywords: files, pdf
;;
;; Derived from lisp/doc-view.el at GNU Emacs revision
;; 8ac894e2246f25d2a2a97d866b10e6e0b0fede5a (Emacs 30.1).
;; Modified for GDev-Emacs on 2026-11-15: retain the paginated view,
;; window state and navigation.  Separate page conversion from the view.
;;
;; This file is part of GNU Emacs.
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The viewer keeps the original buffer and uses one image overlay per
;; window.  A backend supplies image files and sets the page count once
;; known.  The viewer owns page selection, scrolling and image sizing.

;;; Code:

(declare-function image-size "image.c" (spec &optional pixels frame))

(require 'image-mode)
(require 'subr-x)

(defvar-local gdev-doc-view-page-count nil
  "Numero di pagine, oppure nil finché il documento non è aperto.")

(defvar-local gdev-doc-view-update-function #'ignore
  "Funzione chiamata con la finestra quando cambia la pagina o lo zoom.")

(defvar-local gdev-doc-view-continuous t
  "Se non nil, scorrere oltre il bordo porta alla pagina adiacente.")

(defvar gdev-doc-view-shrink-factor 1.125
  "Fattore di ingrandimento e riduzione delle pagine.")

(defun gdev-doc-view-current-page (&optional window)
  "Restituisci il numero di pagina richiesto nella WINDOW corrente."
  (let ((page (or (image-mode-window-get 'page window) 1)))
    (if gdev-doc-view-page-count (min page gdev-doc-view-page-count) page)))

(defun gdev-doc-view--new-window (winprops)
  "Crea per WINPROPS un overlay nuovo, invece di ereditare quello copiato."
  (let ((window (car winprops)))
    (when (windowp window)
      (dolist (overlay (overlays-at (point-min) t))
        (when (and (overlay-get overlay 'gdev-doc-view)
                   (eq (overlay-get overlay 'window) window))
          (delete-overlay overlay)))
      (let ((overlay (make-overlay (point-min) (point-max) nil t)))
        (overlay-put overlay 'gdev-doc-view t)
        (overlay-put overlay 'window window)
        (image-mode-window-put 'overlay overlay winprops)))))

(defun gdev-doc-view--update (window)
  "Aggiorna WINDOW quando mostra il documento corrente."
  (when (eq (window-buffer window) (current-buffer))
    (funcall gdev-doc-view-update-function window)))

(defun gdev-doc-view-insert-image (window file &optional status)
  "Mostra in WINDOW la pagina PNG da FILE, oppure il testo STATUS."
  (let* ((overlay (image-mode-window-get 'overlay window))
         (zoom (image-mode-window-get 'zoom window))
         (width (max 1 (- (window-body-width window t) 24)))
         (height (max 1 (- (window-body-height window t) 12)))
         (image (when (and file (display-graphic-p (window-frame window)))
                  (apply #'create-image file 'png nil
                         :scale 1 :pointer 'arrow :transform-smoothing t
                         (pcase zoom
                           ((pred numberp) (list :width zoom))
                           ('width (list :width width))
                           (_ (list :max-width width :max-height height))))))
         (pixels (and image (car (image-size image t (window-frame window)))))
         (padding (when (and pixels (< pixels (window-body-width window t)))
                    (propertize " " 'display
                                `(space :align-to (+ center (,(floor pixels -2)))))))
         (content (or image status)))
    (when overlay
      (move-overlay overlay (point-min) (point-max))
      (overlay-put overlay 'before-string
                   (if (= (point-min) (point-max))
                       (and content (if (stringp content) content (propertize " " 'display content)))
                     padding))
      (overlay-put overlay 'display content)
      (unless image
        (set-window-hscroll window 0)
        (set-window-vscroll window 0 t)))))

(defun gdev-doc-view-search-pages (regexp buffer)
  "Cerca REGEXP nelle singole pagine testuali di BUFFER.
Le pagine sono separate da avanzamenti di pagina."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((page 0)
            (case-fold-search t)
            (start (point))
            matches)
        (while start
          (let* ((separator (search-forward "\f" nil 'move))
                 (end (if separator (1- separator) (point-max))))
            (setq page (1+ page))
            (save-excursion
              (save-restriction
                (narrow-to-region start end)
                (goto-char start)
                (when (re-search-forward regexp nil t)
                  (push page matches))))
            (setq start separator)))
        (nreverse matches)))))

(defun gdev-doc-view-goto-page (page &optional window)
  "Mostra PAGE in WINDOW, che per impostazione predefinita è la finestra corrente."
  (interactive (list (read-number "Vai a pagina: " (gdev-doc-view-current-page))))
  (unless (integerp page) (user-error "Inserisci un numero di pagina intero"))
  (let* ((window (or window
                     (and (eq (window-buffer) (current-buffer)) (selected-window))
                     (get-buffer-window (current-buffer) 'visible)))
         (props (image-mode-winprops (or window t)))
         (old (gdev-doc-view-current-page (car props))))
    (setq page (max 1 (if gdev-doc-view-page-count (min page gdev-doc-view-page-count) page)))
    (image-mode-window-put 'page page props)
    (when window
      (unless (= old page)
        (image-mode-window-put 'hscroll 0 props)
        (image-mode-window-put 'vscroll 0 props)
        (set-window-hscroll window 0)
        (set-window-vscroll window 0 t))
      (gdev-doc-view--update window))))

(defun gdev-doc-view-next-page (&optional arg)
  "Avanza di ARG pagine."
  (interactive "p")
  (gdev-doc-view-goto-page (+ (gdev-doc-view-current-page) (or arg 1))))

(defun gdev-doc-view-previous-page (&optional arg)
  "Torna indietro di ARG pagine."
  (interactive "p")
  (gdev-doc-view-goto-page (- (gdev-doc-view-current-page) (or arg 1))))

(defun gdev-doc-view-first-page ()
  "Vai alla prima pagina."
  (interactive)
  (gdev-doc-view-goto-page 1))

(defun gdev-doc-view-last-page ()
  "Vai all'ultima pagina."
  (interactive)
  (gdev-doc-view-goto-page (or gdev-doc-view-page-count (gdev-doc-view-current-page))))

(defun gdev-doc-view--image ()
  "Restituisci l'immagine della pagina quando è visibile."
  (let ((value (image-get-display-property)))
    (and (eq (car-safe value) 'image) value)))

(defun gdev-doc-view-scroll-up-or-next-page (&optional arg)
  "Scorri di ARG righe verso il basso, oppure passa alla pagina seguente."
  (interactive "P")
  (let ((before (window-vscroll nil t)))
    (when (gdev-doc-view--image)
      (image-scroll-up arg)
      (when (and (or gdev-doc-view-continuous (null arg))
                 (= before (window-vscroll nil t)))
        (gdev-doc-view-next-page)))))

(defun gdev-doc-view-scroll-down-or-previous-page (&optional arg)
  "Scorri di ARG righe verso l'alto, oppure torna alla pagina precedente."
  (interactive "P")
  (let ((before (window-vscroll nil t)))
    (when (gdev-doc-view--image)
      (image-scroll-down arg)
      (when (and (or gdev-doc-view-continuous (null arg))
                 (= before (window-vscroll nil t)))
        (gdev-doc-view-previous-page)))))

(defun gdev-doc-view-scroll-horizontally (columns)
  "Scorri di COLUMNS colonne nell'immagine corrente."
  (when (gdev-doc-view--image)
    (image-forward-hscroll columns)))

(defun gdev-doc-view--set-zoom (zoom)
  "Applica ZOOM solo alla finestra corrente."
  (image-mode-window-put 'zoom zoom)
  (gdev-doc-view--update (selected-window)))

(defun gdev-doc-view-enlarge (factor)
  "Ingrandisci di un FACTOR la pagina corrente."
  (interactive (list gdev-doc-view-shrink-factor))
  (when-let* ((image (gdev-doc-view--image)))
    (gdev-doc-view--set-zoom
     (max 24 (min 4096 (ceiling (* factor (car (image-size image t)))))))))

(defun gdev-doc-view-shrink (factor)
  "Riduci di un FACTOR la pagina corrente."
  (interactive (list gdev-doc-view-shrink-factor))
  (gdev-doc-view-enlarge (/ 1.0 factor)))

(defun gdev-doc-view-fit-page ()
  "Adatta la pagina intera alla finestra, anche quando viene ridimensionata."
  (interactive)
  (gdev-doc-view--set-zoom nil))

(defun gdev-doc-view-fit-width ()
  "Adatta la pagina alla larghezza della finestra."
  (interactive)
  (gdev-doc-view--set-zoom 'width))

(defvar-keymap gdev-doc-view-mode-map
  :parent special-mode-map
  "n" #'gdev-doc-view-next-page
  "p" #'gdev-doc-view-previous-page
  "<next>" #'gdev-doc-view-next-page
  "<prior>" #'gdev-doc-view-previous-page
  "SPC" #'gdev-doc-view-scroll-up-or-next-page
  "S-SPC" #'gdev-doc-view-scroll-down-or-previous-page
  "DEL" #'gdev-doc-view-scroll-down-or-previous-page
  "<down>" (lambda () (interactive) (gdev-doc-view-scroll-up-or-next-page 1))
  "<up>" (lambda () (interactive) (gdev-doc-view-scroll-down-or-previous-page 1))
  "<left>" (lambda () (interactive) (gdev-doc-view-scroll-horizontally -1))
  "<right>" (lambda () (interactive) (gdev-doc-view-scroll-horizontally 1))
  "M-<" #'gdev-doc-view-first-page
  "M->" #'gdev-doc-view-last-page
  "g" #'gdev-doc-view-goto-page
  "+" #'gdev-doc-view-enlarge
  "=" #'gdev-doc-view-enlarge
  "-" #'gdev-doc-view-shrink
  "0" #'gdev-doc-view-fit-page
  "P" #'gdev-doc-view-fit-page
  "W" #'gdev-doc-view-fit-width)

;;;###autoload
(define-derived-mode gdev-doc-view-mode special-mode "Documento"
  "Mostra un documento per pagine, con uno stato distinto per finestra."
  (setq-local cursor-type nil
              truncate-lines t
              auto-hscroll-mode nil
              display-line-numbers nil)
  (add-hook 'image-mode-new-window-functions #'gdev-doc-view--new-window nil t)
  (image-mode-setup-winprops)
  (add-hook 'window-size-change-functions #'gdev-doc-view--update nil t)
  (add-hook 'change-major-mode-hook
            (lambda () (remove-overlays (point-min) (point-max) 'gdev-doc-view t)) nil t)
  (when (boundp 'mwheel-scroll-up-function)
    (setq-local mwheel-scroll-up-function #'gdev-doc-view-scroll-up-or-next-page))
  (when (boundp 'mwheel-scroll-down-function)
    (setq-local mwheel-scroll-down-function #'gdev-doc-view-scroll-down-or-previous-page)))

(provide 'gdev-doc-view)
;;; gdev-doc-view.el ends here
