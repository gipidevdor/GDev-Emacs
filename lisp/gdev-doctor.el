;;; gdev-doctor.el --- Diagnosi dell'installazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; `gdev doctor' in un terminale, o C-h d d dentro Emacs, è la diagnosi
;; dell'ambiente: controlla ciò su cui contano i moduli attivi, cioè come è
;; compilato Emacs, la configurazione privata, le grammatiche tree-sitter e
;; ogni programma esterno che un modulo ha registrato con
;; `gdev-doctor-executable' o `gdev-doctor-check'.  Ogni problema arriva con
;; il comando che lo risolve.  Niente qui stampa un segreto: i controlli
;; sulle credenziali dicono solo se esistono.

;;; Code:

(require 'seq)
(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-handlers)

(defvar gdev-treesit-languages)         ; tools/tree-sitter
(declare-function gdev-env-file "gdev-env")

(defun gdev-doctor--core-checks ()
  "Restituisce i controlli che non dipendono dai moduli."
  (append
   (list
    (list "Emacs 30.1 o successivo" (lambda () (version<= "30.1" emacs-version))
          "installa un Emacs recente: brew install --cask emacs-app" 'warning)
    (list "compilazione nativa" (lambda () (and (fboundp 'native-comp-available-p)
                                                (native-comp-available-p)))
          "usa un Emacs con compilazione nativa (quello installato con brew install --cask)"
          'warning)
    (list "tree-sitter" #'treesit-available-p
          "usa un Emacs con tree-sitter (quello installato con brew install --cask)"
          'warning)
    (list "configurazione privata" (lambda () (file-exists-p (gdev-user-file "init.el")))
          "gdev install  (crea ~/.config/gdev da templates/)" 'note)
    (list "git" (lambda () (executable-find "git")) "xcode-select --install" 'warning)
    (list "ripgrep" (lambda () (executable-find "rg")) "brew install ripgrep" 'warning))
   (when gdev-macos-p
     (list (list "ambiente della shell salvato" (lambda () (file-exists-p (gdev-env-file)))
                 "gdev env  (eseguilo da un terminale)" 'warning)))
   (mapcar (lambda (entry)
             (list (format "modulo facoltativo %s %s" (car entry) (cadr entry)) #'ignore
                   (format "aggiungi %s a %s in %s, poi esegui gdev sync"
                           (cadr entry) (car entry) (abbreviate-file-name (gdev-user-file "init.el")))
                   'note))
           (gdev-modules-missing-from-template))
   (when (and (gdev-module-p :tools 'tree-sitter) (boundp 'gdev-treesit-languages))
     (mapcar (lambda (entry)
               (let ((language (car entry)))
                 (list (format "grammatica tree-sitter: %s" language)
                       (lambda () (treesit-language-available-p language))
                       "gdev sync" 'warning)))
             gdev-treesit-languages))
   (when gdev-modules-private-errors
     (mapcar (lambda (failure)
               (list (format "configurazione privata %s" (abbreviate-file-name (car failure)))
                     #'ignore (format "non si carica: %s" (cdr failure)) 'warning))
             gdev-modules-private-errors))
   (when gdev-failed-modules
     (mapcar (lambda (failure)
               (list (format "modulo %s %s" (nth 0 failure) (nth 1 failure)) #'ignore
                     (format "non si carica: %s" (error-message-string (nth 2 failure)))
                     'warning))
             gdev-failed-modules))))

(defun gdev-doctor-run ()
  "Esegue tutti i controlli.  Restituisce una lista di (STATUS LABEL HINT).
STATUS è `ok', `warning' o `note'."
  (mapcar (pcase-lambda (`(,label ,predicate ,hint ,severity))
            (list (if (ignore-errors (funcall predicate)) 'ok severity) label hint))
          (append (gdev-doctor--core-checks) (reverse gdev-doctor-checks))))

(defun gdev-doctor-format (results)
  "Restituisce come testo i RESULTS di `gdev-doctor-run', prima i problemi."
  (let ((problems (seq-filter (lambda (result) (eq (car result) 'warning)) results))
        (notes (seq-filter (lambda (result) (eq (car result) 'note)) results))
        (fine (seq-filter (lambda (result) (eq (car result) 'ok)) results)))
    (concat
     (format "Diagnosi di GDev-Emacs (doctor): %d problem%s, %d suggeriment%s, %d a posto.\n"
             (length problems) (if (= (length problems) 1) "a" "i")
             (length notes) (if (= (length notes) 1) "o" "i")
             (length fine))
     (when problems
       (concat "\nProblemi:\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,hint)) (format "  ✗ %s\n      %s\n" label hint))
                          problems "")))
     (when notes
       (concat "\nSuggerimenti (facoltativi):\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,hint)) (format "  · %s\n      %s\n" label hint))
                          notes "")))
     (when fine
       (concat "\nA posto:\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,_)) (format "  ✓ %s\n" label)) fine ""))))))

;;;###autoload
(defun gdev-doctor ()
  "Controlla l'installazione e mostra cosa manca, con il rimedio."
  (interactive)
  (let ((text (gdev-doctor-format (gdev-doctor-run))))
    (with-current-buffer (get-buffer-create "*gdev-doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (special-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(provide 'gdev-doctor)
;;; gdev-doctor.el ends here
