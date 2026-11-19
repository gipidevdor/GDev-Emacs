;;; config.el --- :tools pdf: lettore PDF di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Apre i PDF nella finestra grafica di Emacs su macOS con PDFKit
;; e un fork della vista paginata di GNU Emacs DocView 30.1.
;; Nel terminale e sulle altre piattaforme usa DocView di Emacs.
;;
;; n e p cambiano pagina, g salta a un numero, C-s cerca nel PDF.
;; C-c C-t apre il testo, u sblocca i PDF protetti, r li ricarica.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)

(use-package gdev-doc-view :ensure t :commands gdev-doc-view-mode)

(declare-function doc-view-mode-maybe "doc-view" ())
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function gdev-pdf-goto-page "gdev-pdf" (page &optional window))
(declare-function gdev-pdf-current-page "gdev-pdf" ())
(declare-function org-open-file "org" (path &optional in-emacs line search))
(declare-function org-link-set-parameters "ol" (type &rest rest))
(declare-function org-link-store-props "ol" (&rest props))
(declare-function org-docview-store-link "ol-docview" (&optional interactive))

(autoload 'gdev-pdf-mode
  (expand-file-name "gdev-pdf" (gdev-module-directory :tools 'pdf)) nil t)

(defun gdev-pdf-available-p ()
  "Restituisci non nil quando la finestra corrente può usare PDFKit."
  (and gdev-macos-p (eq (framep (selected-frame)) 'ns) (image-type-available-p 'png)))

(defun gdev-pdf-visit ()
  "Apri un PDF con il lettore disponibile nella finestra corrente."
  (if (and (gdev-pdf-available-p) buffer-file-name)
      (gdev-pdf-mode)
    (doc-view-mode-maybe)))

(when gdev-macos-p
  (add-to-list 'auto-mode-alist '("\\.[Pp][Dd][Ff]\\'" . gdev-pdf-visit)))

(defun gdev-pdf--org-store-link (&optional interactive)
  "Memorizza la pagina corrente nel formato dei collegamenti del Lettore PDF.
INTERACTIVE viene passato al Lettore PDF per gli altri documenti."
  (if (and buffer-file-name (derived-mode-p 'gdev-pdf-mode))
      (let ((page (gdev-pdf-current-page)))
        (when page
          (org-link-store-props
           :type "docview"
           :link (format "docview:%s::%d" buffer-file-name page)
           :description (format "%s · pagina %d" (file-name-nondirectory buffer-file-name) page))))
    (org-docview-store-link interactive)))

(defun gdev-pdf--org-follow-link (link _arg)
  "Apri LINK nel documento e vai alla pagina indicata, se presente."
  (require 'org)
  (string-match "\\`\\(.*?\\)\\(?:::\\([0-9]+\\)\\)?\\'" link)
  (let ((path (match-string 1 link))
        (page (and (match-beginning 2) (string-to-number (match-string 2 link)))))
    (unless (file-exists-p path)
      (user-error "Documento non trovato: %s" path))
    (org-open-file path 1)
    (when page
      (if (derived-mode-p 'gdev-pdf-mode)
          (gdev-pdf-goto-page page)
        (when (derived-mode-p 'doc-view-mode)
          (doc-view-goto-page page))))))

(with-eval-after-load 'ol-docview
  (org-link-set-parameters "docview"
                           :follow #'gdev-pdf--org-follow-link
                           :store #'gdev-pdf--org-store-link))

;;; config.el ends here
