;;; config.el --- :lang latex: progetti e scrittura LaTeX -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Nuovo progetto LaTeX apre main.tex e prepara una bibliografia BibTeX.
;; Il riquadro destro offre sezioni, formattazione, ambienti,
;; bibliografia, compilazione e consultazione del PDF.
;; La compilazione usa latexmk con pdflatex, oppure una sola passata di
;; pdflatex quando latexmk manca. Serve una distribuzione TeX.
;;
;; La modalità adatta il codice LaTeX di GNU Emacs 30.1. Il fork locale
;; gdev-tex-mode conserva gli avvisi originali e riusa il motore TeX.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'easymenu)
(require 'project)
(require 'subr-x)
(require 'tex-mode)
(require 'gdev-context)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-writing)

(use-package gdev-tex-mode :ensure t :demand t)

(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-open-folder "gdev-commands" (directory))
(declare-function gdev-pdf-available-p "../../tools/pdf/config" ())
(declare-function reftex-mode "reftex" (&optional arg))
(declare-function reftex-citation "reftex-cite" (&optional arg))
(defvar reftex-default-bibliography)

(defconst gdev-latex--marker ".gdev-latex"
  "File che identifica il progetto LaTeX.")

(defun gdev-latex--find-root (directory)
  "Trova il progetto LaTeX che contiene DIRECTORY."
  (gdev-writing-project-root 'gdev-latex directory))

(cl-defmethod project-root ((project (head gdev-latex)))
  (cdr project))

(gdev-writing-register-project 'gdev-latex gdev-latex--marker)

(defun gdev-latex--title (title)
  "Adatta TITLE al titolo LaTeX su una sola riga."
  (let ((title (string-trim (replace-regexp-in-string "[[:space:]]+" " " title)))
        (escapes '((?\\ . "\\textbackslash{}") (?\{ . "\\{") (?\} . "\\}")
                   (?% . "\\%") (?$ . "\\$") (?& . "\\&") (?# . "\\#")
                   (?_ . "\\_") (?^ . "\\textasciicircum{}") (?~ . "\\textasciitilde{}"))))
    (when (string-empty-p title)
      (user-error "Scrivi un titolo per continuare"))
    (mapconcat (lambda (character)
                 (or (alist-get character escapes) (char-to-string character)))
               title "")))

(defun gdev-latex--initialize (directory title)
  "Prepara DIRECTORY, nuova o vuota, per un documento con TITLE."
  (let* ((title (gdev-latex--title title))
         (root (file-name-as-directory (expand-file-name directory)))
         (coding-system-for-write 'utf-8-unix)
         created-directory created-files complete)
    (unwind-protect
        (progn
          (if (file-directory-p root)
              (unless (gdev-directory-empty-p root)
                (user-error "Scegli una cartella vuota per il progetto LaTeX"))
            (make-directory root)
            (setq created-directory t))
          (dolist (entry
                   (list (cons "main.tex"
                               (concat "\\documentclass[a4paper,11pt]{article}\n"
                                       "\\usepackage[T1]{fontenc}\n"
                                       "\\title{" title "}\n\\author{}\n\\date{}\n\n"
                                       "\\begin{document}\n\\maketitle\n\n"
                                       "\\section{Introduzione}\n\n"
                                       "\\section{Sviluppo}\n\n"
                                       "\\section{Conclusione}\n\n"
                                       "% Attiva queste righe quando aggiungi le citazioni.\n"
                                       "% \\bibliographystyle{plain}\n"
                                       "% \\bibliography{bibliografia}\n\n"
                                       "\\end{document}\n"))
                         (cons "bibliografia.bib" "% Aggiungi qui le voci BibTeX.\n")
                         (cons gdev-latex--marker "latex\n")))
            (let ((file (expand-file-name (car entry) root)))
              (write-region (cdr entry) nil file nil 'silent nil 'excl)
              (push file created-files)))
          (setq complete t)
          root)
      (unless complete
        (dolist (file created-files)
          (ignore-errors (delete-file file)))
        (when created-directory
          (ignore-errors (delete-directory root)))))))

(defun gdev-latex-new-project (directory title)
  "Crea e apri un progetto LaTeX in DIRECTORY con TITLE."
  (interactive
   (let ((directory (read-directory-name "Cartella del progetto LaTeX: ")))
     (list directory (read-string "Titolo del documento: "
                                  (file-name-nondirectory (directory-file-name directory))))))
  (let ((root (gdev-latex--initialize directory title)))
    (gdev-open-folder root)
    (gdev-open-file (expand-file-name "main.tex" root))
    (gdev-writing-open)))

(defun gdev-latex--main-file ()
  "Restituisci il sorgente principale del documento LaTeX corrente."
  (let ((file (or (and tex-main-file (expand-file-name tex-main-file))
                  (when-let* ((root (gdev-latex--find-root default-directory)))
                    (expand-file-name "main.tex" root))
                  buffer-file-name)))
    (unless (and file (file-regular-p file))
      (user-error "Salva il sorgente LaTeX prima di continuare"))
    file))

(defun gdev-latex--compile-command (file)
  "Prepara una compilazione PDF per FILE nella cartella corrente."
  (let* ((remote (file-remote-p default-directory))
         (pdflatex (executable-find "pdflatex" remote))
         (latexmk (executable-find "latexmk" remote))
         (flags '("-interaction=nonstopmode" "-file-line-error" "-halt-on-error"))
         (source (file-local-name file)))
    (unless pdflatex
      (user-error "Installa una distribuzione TeX con pdflatex per compilare il PDF"))
    (if latexmk
        (gdev-command-line
         (file-local-name latexmk) "-norc" "-pdf"
         (concat "-pdflatex=" (gdev-command-line (file-local-name pdflatex) "-no-shell-escape")
                 " %O %S")
         flags source)
      (gdev-command-line (file-local-name pdflatex) "-no-shell-escape" flags source))))

(defun gdev-latex-compile ()
  "Salva i sorgenti scelti e compila il documento LaTeX in PDF."
  (interactive)
  (let* ((file (gdev-latex--main-file))
         (root (file-name-directory file))
         (default-directory root)
         (command (gdev-latex--compile-command file)))
    (save-some-buffers
     nil
     (lambda ()
       (and buffer-file-name
            (member (downcase (or (file-name-extension buffer-file-name) "")) '("tex" "bib"))
            (file-in-directory-p buffer-file-name root))))
    (gdev-compile command (format "LaTeX · %s" (abbreviate-file-name file)) root)))

(defun gdev-latex-open-pdf ()
  "Apri il PDF generato per il sorgente principale."
  (interactive)
  (let ((pdf (concat (file-name-sans-extension (gdev-latex--main-file)) ".pdf")))
    (unless (file-regular-p pdf)
      (user-error "Compila il documento per creare il PDF"))
    (if (or (file-remote-p pdf)
            (and (fboundp 'gdev-pdf-available-p) (gdev-pdf-available-p)))
        (gdev-open-file pdf)
      (browse-url-of-file pdf))))

(defun gdev-latex-open-bibliography ()
  "Apri la bibliografia BibTeX del progetto."
  (interactive)
  (let* ((root (or (gdev-latex--find-root default-directory) default-directory))
         (default-file (expand-file-name "bibliografia.bib" root)))
    (gdev-open-file
     (if (file-regular-p default-file) default-file
       (read-file-name "Scegli la bibliografia: " root nil t)))))

(defun gdev-latex--surround (opening closing)
  "Racchiudi la selezione in OPENING e CLOSING o predisponi la scrittura."
  (atomic-change-group
    (if (use-region-p)
        (let ((start (region-beginning))
              (end (region-end)))
          (goto-char end)
          (insert closing)
          (goto-char start)
          (insert opening)
          (deactivate-mark))
      (insert opening closing)
      (backward-char (length closing)))))

(defun gdev-latex-bold ()
  "Applica il grassetto alla selezione o al testo da inserire."
  (interactive)
  (gdev-latex--surround "\\textbf{" "}"))

(defun gdev-latex-emphasis ()
  "Applica enfasi alla selezione o al testo da inserire."
  (interactive)
  (gdev-latex--surround "\\emph{" "}"))

(defun gdev-latex-inline-math ()
  "Inserisci una formula nella riga del testo."
  (interactive)
  (gdev-latex--surround "\\(" "\\)"))

(defun gdev-latex-insert-section (kind title)
  "Inserisci una sezione di tipo KIND con TITLE."
  (interactive
   (list (cdr (assoc (completing-read "Livello: " '("Sezione" "Sottosezione" "Paragrafo")
                                      nil t nil nil "Sezione")
                     '(("Sezione" . "section") ("Sottosezione" . "subsection")
                       ("Paragrafo" . "paragraph"))))
         (read-string "Titolo: ")))
  (let ((title (gdev-latex--title title)))
    (atomic-change-group
      (unless (bolp) (insert "\n"))
      (insert "\\" kind "{" title "}\n\n"))))

(defun gdev-latex-insert-environment (environment)
  "Inserisci un ambiente LaTeX di tipo ENVIRONMENT."
  (interactive
   (list (completing-read "Ambiente: " '("itemize" "enumerate" "quote" "equation" "verbatim")
                          nil t nil nil "itemize")))
  (atomic-change-group
    (unless (bolp) (insert "\n"))
    (insert "\\begin{" environment "}\n")
    (save-excursion
      (insert "\n\\end{" environment "}\n"))
    (indent-according-to-mode)
    (when (member environment '("itemize" "enumerate"))
      (insert "\\item "))))

(defun gdev-latex-insert-citation ()
  "Cerca una fonte con RefTeX e inserisci la citazione."
  (interactive)
  (require 'reftex)
  (reftex-mode 1)
  (call-interactively #'reftex-citation))

(defconst gdev-latex--actions
  '(["Compila PDF" gdev-latex-compile]
    ["Apri PDF" gdev-latex-open-pdf]
    ["Vai a una sezione…" imenu]
    ["Inserisci sezione…" gdev-latex-insert-section (not buffer-read-only)]
    ["Inserisci ambiente…" gdev-latex-insert-environment (not buffer-read-only)]
    ["Grassetto" gdev-latex-bold (not buffer-read-only) (:target selection)]
    ["Enfasi" gdev-latex-emphasis (not buffer-read-only) (:target selection)]
    ["Formula nella riga" gdev-latex-inline-math (not buffer-read-only) (:target selection)]
    ["Inserisci citazione…" gdev-latex-insert-citation (not buffer-read-only)]
    ["Apri bibliografia" gdev-latex-open-bibliography]
    ["Mostra gli strumenti di scrittura" gdev-writing-open])
  "Azioni LaTeX esposte dal menu della modalità e dal Workbench.")

(define-derived-mode gdev-latex-mode tex-mode "LaTeX"
  "Scrivi un documento LaTeX con le azioni del Workbench."
  (gdev-ui-view-setup 'native)
  (gdev-tex-latex-initialize)
  (visual-line-mode 1)
  (when-let* ((root (gdev-latex--find-root default-directory)))
    (setq-local reftex-default-bibliography (list (expand-file-name "bibliografia.bib" root))))
  (setq-local gdev-context-items
              (append gdev-latex--actions (gdev-writing-actions)))
  (run-mode-hooks 'latex-mode-hook))

(derived-mode-add-parents 'gdev-latex-mode '(latex-mode))
(set-keymap-parent gdev-latex-mode-map latex-mode-map)
(keymap-set gdev-latex-mode-map "C-c C-c" #'gdev-latex-compile)
(keymap-set gdev-latex-mode-map "C-c C-v" #'gdev-latex-open-pdf)
(define-key gdev-latex-mode-map [menu-bar tex] #'undefined)
(define-key gdev-latex-mode-map [menu-bar gdev-latex]
  (list 'menu-item "LaTeX"
        (easy-menu-create-menu
         "LaTeX"
         (mapcar (lambda (item)
                   (vector (aref item 0) (aref item 1) :active
                           (if (> (length item) 2) (aref item 2) t)))
                 gdev-latex--actions))))
(add-to-list 'major-mode-remap-alist '(latex-mode . gdev-latex-mode))

(defun gdev-latex--file-mode ()
  "Usa LaTeX GDev nel suo progetto e rileva gli altri sorgenti TeX."
  (if (gdev-latex--find-root default-directory)
      (gdev-latex-mode)
    (tex-mode)))

(add-to-list 'auto-mode-alist '("\\.tex\\'" . gdev-latex--file-mode))

;;; config.el ends here
