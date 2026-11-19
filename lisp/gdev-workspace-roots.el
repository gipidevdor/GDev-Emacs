;;; gdev-workspace-roots.el --- Cartelle degli spazi di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le cartelle esplicite appartengono allo spazio di lavoro. Il documento
;; nel gruppo attivo determina quale cartella usare per i comandi di progetto.

;;; Code:

(require 'gdev-layout)
(require 'gdev-workspace-state)

(defvar gdev-workspace-root-state-functions nil
  "Funzioni che preparano altri campi per un cambiamento delle radici.
Ogni funzione riceve le radici nuove e restituisce coppie (CAMPO . VALORE).
Il proprietario del campo decide se conservarlo o invalidarlo.")

(defun gdev-workspace-roots (&optional frame)
  "Restituisce le cartelle dello spazio di lavoro di FRAME, in ordine."
  (or (gdev-workspace-state-get 'gdev-workspace-roots frame)
      (when-let* ((directory (or (gdev-workspace-state-get 'gdev-layout-folder frame)
                                 (gdev-workspace-state-get 'gdev-layout-explorer-root frame))))
        (list (file-name-as-directory (expand-file-name directory))))))

(defun gdev-workspace-root-for (path roots)
  "Restituisce la più specifica fra ROOTS che contiene PATH."
  (when path
    (let ((directory (file-name-as-directory (expand-file-name path)))
          match)
      (dolist (root roots match)
        (when (and (string-prefix-p root directory)
                   (or (not match) (> (length root) (length match))))
          (setq match root))))))

(defun gdev-workspace-directory (&optional directory frame)
  "Restituisce la cartella di FRAME che contiene DIRECTORY.
Parti dalla cartella del gruppo editor attivo se DIRECTORY è nil.
Se il percorso è esterno allo spazio, usa la prima cartella registrata."
  (let ((roots (gdev-workspace-roots frame)))
    (when roots
      (or (gdev-workspace-root-for
           (or directory
               (when-let* ((editor (gdev-layout-editor frame)))
                 (with-current-buffer (window-buffer editor)
                   (or buffer-file-truename default-directory))))
           roots)
          (car roots)))))

(defun gdev-workspace-root-fields (roots)
  "Prepara i campi dello spazio corrispondenti alle ROOTS già convalidate."
  (let ((first (car roots)))
    (append `((gdev-workspace-roots . ,roots)
              (gdev-layout-folder . ,first)
              (gdev-layout-explorer-root . ,first))
            (apply #'append (mapcar (lambda (function) (funcall function roots))
                                    gdev-workspace-root-state-functions)))))

(defun gdev-workspace-set-roots (roots)
  "Imposta ROOTS, già convalidate, per lo spazio di lavoro attivo."
  (gdev-workspace-state-update (gdev-workspace-root-fields roots)))

(provide 'gdev-workspace-roots)
;;; gdev-workspace-roots.el ends here
