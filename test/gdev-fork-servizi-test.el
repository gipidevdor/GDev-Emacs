;;; gdev-fork-servizi-test.el --- Regressioni di Feed RSS e Terminale -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la conservazione delle marche durante la ricerca nei feed e
;; l'interpretazione dei caratteri di controllo tra blocchi del terminale.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'package)

(defvar elfeed-search--marked)

(ert-deftest gdev-fork-servizi-test-eat-sequenze-divise ()
  "Conserva il testo Unicode, i colori e il titolo attraverso i blocchi."
  (package-activate-all)
  (require 'eat)
  (let ((sample "Prova è \e[31mrosso\e[m.\e]2;Titolo della prova\e\\"))
    (dotimes (split (1+ (length sample)))
      (with-temp-buffer
        (let ((terminal (eat-term-make (current-buffer) (point))))
          (eat-term-resize terminal 80 24)
          (eat-term-process-output terminal (substring sample 0 split))
          (eat-term-process-output terminal (substring sample split))
          (let ((text (buffer-string)))
            (should (equal (substring-no-properties text) "Prova è rosso."))
            (should (equal (eat-term-title terminal) "Titolo della prova"))
            (let ((red (get-text-property (string-search "rosso" text) 'face text)))
              (should red)
              (should-not (equal red (get-text-property 0 'face text)))
              (should-not (equal red
                                 (get-text-property (1- (length text)) 'face text))))))))))

(ert-deftest gdev-fork-servizi-test-elfeed-marche-nel-filtro ()
  "Conserva le marche per identità e mantiene l'ordine della selezione."
  (package-activate-all)
  (require 'elfeed-search)
  (with-temp-buffer
    (let* ((results (cl-loop for n below 320
                             collect (elfeed-entry--create :id (list "feed" n))))
           (first (car results))
           (last (car (last results)))
           (retained (append (list last) (reverse (cl-subseq results 5 80))
                             (list first)))
           (elfeed-search--marked
            (append (list (copy-elfeed-entry last)) retained)))
      (cl-letf (((symbol-function 'elfeed-search-entries)
                 (lambda (&rest _) results)))
        (should (elfeed-search--update-list :force)))
      (should (= (length elfeed-search--marked) (length retained)))
      (should (cl-every #'eq elfeed-search--marked retained)))))

(provide 'gdev-fork-servizi-test)
;;; gdev-fork-servizi-test.el ends here
