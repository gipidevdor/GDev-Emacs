;;; gdev-writing.el --- Strumenti comuni per Articolo e LaTeX -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Articolo e LaTeX condividono correzione, ricerca, fonti e comunicazioni
;; nel riquadro Comandi. Il riquadro usa la finestra del documento come
;; contesto, così selezione e cartella sono quelle del testo.

;;; Code:

(require 'gdev-layout)
(require 'gdev-writing-references)
(require 'project)
(require 'seq)

(declare-function gdev-command-sidebar-select "gdev-command-sidebar" (&optional category keep-focus))
(declare-function gdev-command-sidebar-find "gdev-command-sidebar" ())

(defvar gdev-writing--project-markers nil
  "Associa il tipo di progetto di scrittura al file che ne indica la radice.")

(defun gdev-writing-register-project (type marker)
  "Registra il file MARKER per il tipo di progetto TYPE."
  (setf (alist-get type gdev-writing--project-markers) marker)
  (add-hook 'project-find-functions #'gdev-writing-find-project))

(defun gdev-writing-find-project (directory)
  "Trova il progetto di scrittura più vicino a DIRECTORY."
  (let (type)
    (when-let* ((root (locate-dominating-file
                       directory
                       (lambda (parent)
                         (setq type
                               (seq-some (lambda (entry)
                                           (when (file-regular-p (expand-file-name (cdr entry) parent))
                                             (car entry)))
                                         gdev-writing--project-markers))))))
      (cons type (file-name-as-directory (expand-file-name root))))))

(defun gdev-writing-project-root (type directory)
  "Restituisci la radice se il progetto più vicino a DIRECTORY è di TYPE."
  (when-let* ((project (gdev-writing-find-project directory))
              ((eq (car project) type)))
    (cdr project)))

(defun gdev-writing-context-p ()
  "Restituisci non nil se l'area corrente offre gli strumenti di scrittura."
  (derived-mode-p 'gdev-article-mode 'gdev-latex-mode))

(defun gdev-writing-count-words (start end)
  "Conta le parole da START a END, nella selezione o nel testo intero."
  (interactive (if (use-region-p) (list (region-beginning) (region-end))
                 (list (point-min) (point-max))))
  (let ((total (count-words start end)))
    (if (= total 1) (message "Una parola") (message "%d parole" total))
    total))

(defun gdev-writing-actions ()
  "Restituisci le azioni condivise da Articolo e LaTeX."
  (append '(["Conta parole" gdev-writing-count-words]
            ["Trova nel testo…" isearch-forward]
            ["Ortografia…" jinx-correct (bound-and-true-p jinx-mode)]
            ["Cerca nel progetto…" gdev-search-query])
          (gdev-writing-reference-actions)
          '(["Feed RSS e Atom" gdev-rss t (:target view)]
            ["Posta e gruppi" gdev-mail t (:target view)]
            ["Chat IRC…" gdev-irc t (:target view)])))

(defun gdev-writing-open (&optional search-if-narrow)
  "Mostra gli strumenti di scrittura lasciando attivo il testo.
Con SEARCH-IF-NARROW, usa la ricerca dei comandi se il riquadro non entra."
  (interactive (list t))
  (let ((editor (if (gdev-writing-context-p) (selected-window) (gdev-layout-editor))))
    (if (and (window-live-p editor)
             (with-current-buffer (window-buffer editor) (gdev-writing-context-p)))
        (when (fboundp 'gdev-command-sidebar-select)
          (with-selected-window editor
            (or (gdev-command-sidebar-select 'context t)
                (when search-if-narrow (gdev-command-sidebar-find)))))
      (when search-if-narrow (user-error "Apri un documento Articolo o LaTeX")))))

(provide 'gdev-writing)
;;; gdev-writing.el ends here
