;;; gdev-article-sources.el --- Raccolta delle fonti per Articolo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Raccoglie nel piano di ricerca collegamenti, appunti ed estratti
;; senza spostare chi scrive dal documento corrente.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-src)
(require 'subr-x)
(require 'url-parse)

(declare-function gdev-article--project-root "gdev-article" ())
(declare-function gdev-article--title "gdev-article" (title))

(defun gdev-article-sources--link (source plan)
  "Valida SOURCE e prepara il collegamento da inserire in PLAN."
  (let ((source (string-trim source))
        (case-fold-search t))
    (cond
     ((string-match "\\`https?://" source)
      (let ((scheme-end (match-end 0))
            (url (url-generic-parse-url source)))
        (unless (and (not (string-match-p "[[:space:][:cntrl:]\\\\]" source))
                     (not (string-empty-p (or (url-host url) "")))
                     (not (url-user url)))
          (user-error "Inserisci un indirizzo HTTP o HTTPS valido"))
        (concat (downcase (substring source 0 scheme-end))
                (substring source scheme-end))))
     ((or (string-empty-p source)
          (string-match-p "[[:cntrl:]]\\|\\`[a-z][a-z0-9+.-]*:" source))
      (user-error "Usa un indirizzo web o il percorso di un file locale"))
     (t
      (let ((path (expand-file-name source)))
        (unless (and (not (file-remote-p path))
                     (not (string-search "::" path))
                     (file-regular-p path))
          (user-error "Scegli un file locale esistente con un percorso utilizzabile"))
        (concat "file:" (file-relative-name path (file-name-directory plan))))))))

(defun gdev-article-sources--insert-literal (label text)
  "Inserisci TEXT sotto LABEL come testo letterale."
  (when (and text (not (string-blank-p text)))
    (insert "\n" label "\n#+begin_example\n"
            (org-escape-code-in-string text))
    (unless (bolp) (insert "\n"))
    (insert "#+end_example\n")))

(defun gdev-article-sources--append (title link notes excerpt)
  "Aggiungi una fonte con TITLE, LINK, NOTES ed EXCERPT al piano corrente."
  (let* ((heading "Fonti da consultare")
         (section
          (org-element-map (org-element-parse-buffer 'headline) 'headline
            (lambda (node)
              (when (and (= (org-element-property :level node) 1)
                         (equal (org-element-property :raw-value node) heading))
                node))
            nil t)))
    (goto-char (if section (org-element-property :end section) (point-max)))
    (unless (bolp) (insert "\n"))
    (unless (or (bobp) (eq (char-before (1- (point))) ?\n))
      (insert "\n"))
    (unless section (insert "* " heading "\n\n"))
    (insert (make-string (org-get-valid-level 1 1) ?*) " " title "\n"
            (org-link-make-string link "Apri la fonte")
            (format-time-string " · Raccolta il [%Y-%m-%d]\n"))
    (gdev-article-sources--insert-literal "Estratto" excerpt)
    (gdev-article-sources--insert-literal "Appunti" notes)
    (insert "\n")))

;;;###autoload
(defun gdev-article-capture-source (source title &optional notes excerpt)
  "Raccogli SOURCE con TITLE, NOTES ed EXCERPT nel piano di ricerca.
SOURCE è un indirizzo HTTP o HTTPS oppure un file locale.
Da tastiera, usa la selezione attiva come EXCERPT.
Salva il piano se era pulito e conserva in memoria le modifiche in corso."
  (interactive
   (let ((excerpt (when (use-region-p)
                    (buffer-substring-no-properties (region-beginning) (region-end)))))
     (gdev-article--project-root)
     (list (read-string "Fonte (indirizzo o percorso): ")
           (read-string "Titolo della fonte: ")
           (read-string "Appunti (facoltativi): ")
           excerpt)))
  (let* ((deactivate-mark nil)
         (plan (expand-file-name "ricerche/indice.org" (gdev-article--project-root)))
         (link (gdev-article-sources--link source plan))
         (title (gdev-article--title title)))
    (unless (file-regular-p plan)
      (user-error "Piano di ricerca non trovato: ricerche/indice.org"))
    (let* ((buffer (or (find-buffer-visiting plan) (find-file-noselect plan)))
           (modified (buffer-modified-p buffer)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'org-mode)
          (user-error "Apri il piano di ricerca come documento Org"))
        (save-mark-and-excursion
          (save-restriction
            (widen)
            (atomic-change-group
              (gdev-article-sources--append title link notes excerpt)
              (unless modified (save-buffer))))))
      (message (if modified "Fonte aggiunta al piano di ricerca. Salva il piano per conservarla."
                 "Fonte salvata nel piano di ricerca"))
      buffer)))

(provide 'gdev-article-sources)
;;; gdev-article-sources.el ends here
