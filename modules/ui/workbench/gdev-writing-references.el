;;; gdev-writing-references.el --- Fonti di consultazione per chi scrive -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Articolo e LaTeX condividono la consultazione di un vocabolario
;; locale, di Wikipedia in italiano e la ricerca sul web. Le fonti online
;; usano il navigatore configurato in Emacs.

;;; Code:

(require 'browse-url)
(require 'help)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)
(require 'url-util)

(declare-function gdev-lookup-online "ext:modules/tools/lookup/config" (query))

(defgroup gdev-writing-references nil
  "Fonti di consultazione per la scrittura."
  :group 'gdev)

(defcustom gdev-writing-stardict-name nil
  "Nome esatto del vocabolario StarDict consultato con sdcv, se presente.
Per cercare in italiano seleziona il nome di un vocabolario italiano
tra quelli elencati da sdcv --list-dicts. Su macOS, in assenza di questa
impostazione, si usano le fonti scelte nell'app Dizionario."
  :type '(choice (const :tag "Usa le fonti di macOS quando disponibili" nil)
                 (string :tag "Nome del vocabolario locale"))
  :group 'gdev-writing-references)

(defconst gdev-writing--wikipedia-search-url
  "https://it.wikipedia.org/w/index.php?title=Special:Search&search=%s"
  "Indirizzo della ricerca in Wikipedia in italiano.")

(defun gdev-writing--reference-query (query)
  "Normalizza QUERY prima di consultare una fonte."
  (let ((term (string-trim (replace-regexp-in-string "[[:space:]\n\r]+" " " query))))
    (when (string-empty-p term)
      (user-error "Inserisci una parola o un argomento"))
    term))

(defun gdev-writing--read-reference-query (prompt)
  "Chiedi una ricerca con PROMPT, proponendo la selezione o la parola corrente."
  (let ((suggestion
         (if (use-region-p)
             (when (<= (- (region-end) (region-beginning)) 160)
               (buffer-substring-no-properties (region-beginning) (region-end)))
           (thing-at-point 'word t))))
    (read-string (format-prompt prompt suggestion) nil nil suggestion)))

(defun gdev-writing--stardict-executable ()
  "Restituisci l'eseguibile locale se è stato scelto un vocabolario StarDict."
  (when (and (stringp gdev-writing-stardict-name)
             (not (string-blank-p gdev-writing-stardict-name)))
    (let ((default-directory "/")
          (exec-path (seq-remove #'file-remote-p exec-path)))
      (executable-find "sdcv"))))

(defun gdev-writing--mac-dictionary-p ()
  "Indica se l'app Dizionario è disponibile su macOS."
  (and (eq system-type 'darwin)
       (file-executable-p "/usr/bin/open")
       (or (file-directory-p "/System/Applications/Dictionary.app")
           (file-directory-p "/Applications/Dictionary.app"))))

(defun gdev-writing-dictionary-available-p ()
  "Indica se sul computer è disponibile un accesso al vocabolario."
  (or (gdev-writing--stardict-executable) (gdev-writing--mac-dictionary-p)))

(defun gdev-writing--stardict-definition (program book term)
  "Cerca TERM nel vocabolario locale BOOK con PROGRAM."
  (let ((definition
         (with-temp-buffer
           (let ((default-directory "/")
                 (coding-system-for-read 'utf-8)
                 (coding-system-for-write 'utf-8))
             (unless (eq 0 (call-process program nil (current-buffer) nil
                                         "--non-interactive" "--exact-search"
                                         "--utf8-input" "--utf8-output"
                                         "--use-dict" book "--" term))
               (user-error "Nessuna definizione di «%s» in %s" term book))
             (string-trim (buffer-string))))))
    (when (string-empty-p definition)
      (user-error "Nessuna definizione di «%s» in %s" term book))
    (with-help-window "*Vocabolario*"
      (princ (format "%s\n\n%s\n" term definition)))))

(defun gdev-writing-dictionary (query)
  "Cerca QUERY nel vocabolario locale configurato."
  (interactive (list (gdev-writing--read-reference-query "Cerca nel vocabolario")))
  (let ((term (gdev-writing--reference-query query))
        (default-directory "/"))
    (if-let* ((program (gdev-writing--stardict-executable)))
        (gdev-writing--stardict-definition program gdev-writing-stardict-name term)
      (unless (gdev-writing--mac-dictionary-p)
        (user-error "Il vocabolario locale non è disponibile"))
      (unless (eq 0 (call-process "/usr/bin/open" nil nil nil
                                  (concat "x-dictionary:d:" (url-hexify-string term))))
        (user-error "Impossibile aprire Dizionario")))))

(defun gdev-writing-encyclopedia (query)
  "Cerca QUERY in Wikipedia in italiano con il navigatore configurato."
  (interactive (list (gdev-writing--read-reference-query "Cerca nell'enciclopedia")))
  (browse-url (format gdev-writing--wikipedia-search-url
                      (url-hexify-string (gdev-writing--reference-query query)))))

(defun gdev-writing-search-topic (query)
  "Cerca QUERY sul web, attraverso il modulo di ricerca se attivo."
  (interactive (list (gdev-writing--read-reference-query "Cerca un argomento sul web")))
  (let ((term (gdev-writing--reference-query query)))
    (if (fboundp 'gdev-lookup-online)
        (gdev-lookup-online term)
      (browse-url (concat "https://duckduckgo.com/?q=" (url-hexify-string term))))))

(defun gdev-writing-reference-actions ()
  "Restituisci le azioni di consultazione per i comandi di scrittura."
  '(["Vocabolario…" gdev-writing-dictionary (gdev-writing-dictionary-available-p)]
    ["Enciclopedia…" gdev-writing-encyclopedia]
    ["Cerca argomento sul web…" gdev-writing-search-topic]))

(provide 'gdev-writing-references)
;;; gdev-writing-references.el ends here
