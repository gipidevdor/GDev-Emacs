;;; gdev-writing-references-test.el --- Verifiche delle fonti di scrittura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Prove delle ricerche e del vocabolario, con risposte locali di esempio.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gdev-writing-references)

(ert-deftest gdev-test-writing-encyclopedia-encodes-an-italian-query ()
  "La ricerca nella lingua prevista tratta i termini come dati."
  (let (url)
    (cl-letf (((symbol-function 'browse-url) (lambda (address) (setq url address))))
      (gdev-writing-encyclopedia "  Perché\nè & non #altro? ")
      (should (equal url (concat "https://it.wikipedia.org/w/index.php?title=Special:Search"
                                 "&search=Perch%C3%A9%20%C3%A8%20%26%20non%20%23altro%3F")))
      (setq url nil)
      (should-error (gdev-writing-encyclopedia " \n\t ") :type 'user-error)
      (should-not url))))

(ert-deftest gdev-test-writing-web-search-reuses-the-configured-lookup ()
  "La ricerca sul web passa l'intero argomento normalizzato."
  (let (query url)
    (cl-letf (((symbol-function 'gdev-lookup-online) (lambda (term) (setq query term)))
              ((symbol-function 'browse-url) (lambda (address) (setq url address))))
      (gdev-writing-search-topic " fonti   di ricerca ")
      (should (equal query "fonti di ricerca"))
      (should-not url))
    (cl-letf (((symbol-function 'gdev-lookup-online) nil)
              ((symbol-function 'browse-url) (lambda (address) (setq url address))))
      (gdev-writing-search-topic "ricerca & fonti")
      (should (equal url "https://duckduckgo.com/?q=ricerca%20%26%20fonti")))))

(ert-deftest gdev-test-writing-reference-reads-the-selection-and-cancels ()
  "La selezione propone un termine e l'annullamento lascia il testo intatto."
  (with-temp-buffer
    (insert "prime ricerche")
    (goto-char (point-min))
    (set-mark (point-max))
    (let ((transient-mark-mode t)
          (mark-active t)
          suggestion)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt _initial _history default &optional _inherit)
                   (setq suggestion default)
                   (signal 'quit nil)))
                ((symbol-function 'browse-url) (lambda (&rest _) (ert-fail "Ricerca avviata"))))
        (should (eq (condition-case nil (call-interactively #'gdev-writing-encyclopedia)
                      (quit 'annullata))
                    'annullata))
        (should (equal suggestion "prime ricerche"))
        (should (equal (buffer-string) "prime ricerche"))))))

(ert-deftest gdev-test-writing-dictionary-is-optional-and-local ()
  "L'azione evita accessi remoti e usa il Dizionario di macOS quando rilevato."
  (let ((gdev-writing-stardict-name nil)
        (initial-directory "/ssh:autore@progetto:/bozze/")
        (available nil)
        call)
    (cl-letf (((symbol-function 'gdev-writing--mac-dictionary-p) (lambda () available))
              ((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest arguments)
                 (setq call (list default-directory program arguments))
                 0)))
      (let ((default-directory initial-directory))
        (should-not (gdev-writing-dictionary-available-p))
        (should-error (gdev-writing-dictionary "virtù") :type 'user-error)
        (should-not call)
        (setq available t)
        (should (gdev-writing-dictionary-available-p))
        (gdev-writing-dictionary " virtù ")
        (should (equal call '("/" "/usr/bin/open" ("x-dictionary:d:virt%C3%B9"))))
        (should (equal default-directory initial-directory))))))

(ert-deftest gdev-test-writing-dictionary-uses-the-local-book-and-safe-arguments ()
  "StarDict riceve il nome esatto e una frase UTF-8 in un solo argomento."
  (require 'tramp)
  (let ((gdev-writing-stardict-name "Vocabolario italiano")
        (exec-path '("/ssh:autore@progetto:/bin" "/bin"))
        (help-buffer "*Vocabolario*")
        call)
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (name &optional _remote)
                       (should (equal default-directory "/"))
                       (should (equal exec-path '("/bin")))
                       (and (equal name "sdcv") "/bin/esempio")))
                    ((symbol-function 'call-process)
                     (lambda (program _infile destination _display &rest arguments)
                       (setq call (list default-directory program arguments))
                       (with-current-buffer destination (insert "Definizione italiana.\n"))
                       0)))
            (gdev-writing-dictionary "-virtù civica")
            (should (equal call
                           '("/" "/bin/esempio"
                             ("--non-interactive" "--exact-search" "--utf8-input" "--utf8-output"
                              "--use-dict" "Vocabolario italiano" "--" "-virtù civica"))))
            (with-current-buffer help-buffer
              (should (string-search "Definizione italiana." (buffer-string)))
              (should (derived-mode-p 'help-mode)))))
      (when (get-buffer help-buffer) (kill-buffer help-buffer)))))

(provide 'gdev-writing-references-test)
;;; gdev-writing-references-test.el ends here
