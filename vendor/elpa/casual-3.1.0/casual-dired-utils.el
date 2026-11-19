;;; casual-dired-utils.el --- Casual Dired Utils Menu  -*- lexical-binding: t; -*-

;; Modificato per GDev-Emacs il 2026-11-15: etichette e richieste in italiano.

;; Copyright (C) 2024-2026  Charles Y. Choi

;; Author: Charles Choi <kickingvegas@gmail.com>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'dired)
(require 'dired-x)
(require 'checkdoc)
(require 'casual-lib)
(require 'project)
(require 'casual-dired-variables)

(defconst casual-dired-unicode-db
  '((:up-arrow . '("↑" "Up"))
    (:down-arrow . '("↓" "Giù"))
    (:goto . '("→" "Vai a"))
    (:directory . '("📁" "Dir"))
    (:file . '("📄" "File"))
    (:subdir . '("🗂️" "Sottocartella")))
  "Unicode symbol DB to use for Dired Transient menus.")

(defun casual-dired-unicode-get (key)
  "Lookup Unicode symbol for KEY in DB.

- KEY symbol used to lookup Unicode symbol in DB.

If the value of customizable variable `casual-lib-use-unicode' is
non-nil, then the Unicode symbol is returned, otherwise a plain
ASCII-range string."
  (casual-lib-unicode-db-get key casual-dired-unicode-db))


(defun casual-dired-marked-p ()
  "Predicate if Dired item is marked."
  (if (and (derived-mode-p 'dired-mode)
           (> (- (line-end-position) (line-beginning-position)) 0))
      (char-equal (char-after (line-beginning-position)) dired-marker-char)
    nil))

(defun casual-dired-marked-files-p ()
  "Predicate if any marked files are in place."
  (if (and (derived-mode-p 'dired-mode) (dired-file-name-at-point))
      (let* ((current (expand-file-name (dired-file-name-at-point)))
             (current (if (directory-name-p current)
                          (directory-file-name current)
                        current))
             (files (dired-get-marked-files))
             (count (length files))
             (is-current-marked (casual-dired-marked-p)))

        (if (and (eq count 1) (member current files))
            is-current-marked
          t))
    nil))


;;; Transients

;;;###autoload (autoload 'casual-dired-utils-tmenu "casual-dired-utils" nil t)
(transient-define-prefix casual-dired-utils-tmenu ()
  ["File segnati o file selezionato"
   ["File"
    ("F" "Apri" dired-do-find-marked-files :transient nil)
    ("Z" "Comprimi" dired-do-compress :transient nil)]

   ["Rinomina"
    ("u" "Converti in maiuscolo…" dired-upcase :transient nil)
    ("d" "Converti in minuscolo…" dired-downcase :transient nil)]

   ["Altre azioni"
    ("s" "Cerca e sostituisci ›" casual-dired-search-replace-tmenu :transient nil)
    ("e" "Emacs Lisp›" casual-dired-elisp-tmenu :transient nil)
    ("l" "Collegamento ›" casual-dired-link-tmenu :transient nil)]]

  casual-lib-navigation-group-with-return)

;;;###autoload (autoload 'casual-dired-search-replace-tmenu "casual-dired-utils" nil t)
(transient-define-prefix casual-dired-search-replace-tmenu ()
  ["Cerca e sostituisci"
   ["Cerca nei file"
    :pad-keys t
    ("C-s" "Ricerca incrementale…" dired-do-isearch)
    ("M-s" "Ricerca incrementale con espressione regolare…" dired-do-isearch-regexp)
    ("s" "Trova la prima corrispondenza…" dired-do-search)]
   ["Sostituisci nei file"
    ("r" "Sostituisci con espressione regolare…" dired-do-query-replace-regexp)
    ("p" "Sostituisci nel progetto con espressione regolare…" project-query-replace-regexp)]]

  ["Espressioni regolari di grep"
   [("g" "Cerca con espressione regolare…" dired-do-find-regexp)
    ("G" "Cerca e sostituisci con espressione regolare…" dired-do-find-regexp-and-replace)]

   [("f" "Cerca nei file ricorsivamente…" rgrep)]]

  casual-lib-navigation-group-with-return)

;;;###autoload (autoload 'casual-dired-elisp-tmenu "casual-dired-utils" nil t)
(transient-define-prefix casual-dired-elisp-tmenu ()
  ["Emacs Lisp"
   ["Compila in bytecode"
    ("B" "Compila in bytecode…" dired-do-byte-compile :transient nil)
    ("D" "Compila la cartella in bytecode…" byte-recompile-directory :transient nil)]

   ["Carica"
    ("L" "Carica" dired-do-load :transient nil)]

   ["Verifica"
    ("c" "Controlla le stringhe di documentazione" checkdoc-dired :transient nil)]]

  casual-lib-navigation-group-with-return)

;;;###autoload (autoload 'casual-dired-link-tmenu "casual-dired-utils" nil t)
(transient-define-prefix casual-dired-link-tmenu ()
  ["Collegamento"
   ["Simbolico"
    ("s" "Assoluto…" dired-do-symlink)
    ("S" "Assoluto con espressione regolare…" dired-do-symlink-regexp)]

   ["Relativo"
    ("r" "Relativo…" dired-do-relsymlink)
    ("R" "Relativo con espressione regolare…" dired-do-relsymlink-regexp)]

   ["Fisico"
    ("h" "Fisico…" dired-do-hardlink)
    ("H" "Fisico con espressione regolare…" dired-do-hardlink-regexp)]]

  casual-lib-navigation-group-with-return)

(provide 'casual-dired-utils)
;;; casual-dired-utils.el ends here
