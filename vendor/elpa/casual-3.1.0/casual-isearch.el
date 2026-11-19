;;; casual-isearch.el --- Transient UI for I-Search -*- lexical-binding: t; -*-

;; Modificato per GDev-Emacs il 2026-11-15: etichette e richieste in italiano.

;; Copyright (C) 2023-2024-2026  Charles Y. Choi

;; Author: Charles Choi <kickingvegas@gmail.com>
;; Keywords: text

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

;; Casual I-Search is a Transient user interface for the I-Search library.

;; INSTALLATION

;; By default, `casual-init' will setup Casual I-Search by running the hook
;; function `casual-isearch-init'.

;; Ensure that `casual-isearch-init' is included in the customizable hook
;; variable `casual-init-hook'.

;; Consult the Info node `(casual) I-Search Install' for more detail on
;; installation.

;;; Code:
(require 'casual-lib)
(require 'casual-isearch-utils)
(require 'casual-isearch-settings)

;;;###autoload (autoload 'casual-isearch-init "casual-isearch" nil t)
(defun casual-isearch-init ()
  "Initialize and configure Casual I-Search.

This hook binds `casual-isearch-tmenu' to `casual-keybinding-primary'.

If `casual-isearch-add-extra-keybindings' is non-nil, then extra
keybindings specified in `casual-isearch-setup' will be set."
  (add-hook 'isearch-mode-hook #'casual-isearch-setup))

(defun casual-isearch-setup ()
  "Setup `isearch-mode' for Casual.

To see what keybindings are set by this function, press ‘s’ to view its
source."
  (keymap-set isearch-mode-map casual-keybinding-primary #'casual-isearch-tmenu))


;;;###autoload (autoload 'casual-isearch-tmenu "casual-isearch" nil t)
(transient-define-prefix casual-isearch-tmenu ()
  "Transient menu for I-Search."
  :refresh-suffixes t
  [["Modifica la ricerca"
    ("e" "Modifica il testo da cercare" isearch-edit-string
     :transient t)
    ("w" "Aggiungi la parola o il carattere successivo" isearch-yank-word-or-char
     :transient t)
    ("s" "Aggiungi il simbolo o il carattere successivo" isearch-yank-symbol-or-char
     :transient t)
    ("l" "Aggiungi il resto della riga" isearch-yank-line :transient t)
    ("y" "Inserisci dagli appunti" isearch-yank-kill :transient t)
    ("t" "Aggiungi l’elemento al cursore" isearch-forward-thing-at-point)]

   ["Sostituisci"
    :if-nil buffer-read-only
    ("r" "Sostituisci con conferma" isearch-query-replace)
    ("x" "Sostituisci con espressione regolare" isearch-query-replace-regexp)]]

  [["Opzioni"
    ("X" "Ricerca con espressione regolare"
     isearch-toggle-regexp
     :description (lambda () (casual-lib-checkbox-label isearch-regexp
                                                        "Ricerca con espressione regolare")))

    ("S" "Cerca simboli interi"
     isearch-toggle-symbol
     :description (lambda () (casual-lib-checkbox-label
                              (eq isearch-regexp-function #'isearch-symbol-regexp)
                              "Cerca simboli interi")))

    ("W" "Cerca parole intere"
     isearch-toggle-word
     :description (lambda () (casual-lib-checkbox-label
                              (eq isearch-regexp-function #'word-search-regexp)
                              "Cerca parole intere")))

    ("F" "Ignora maiuscole e minuscole"
     isearch-toggle-case-fold
     :description (lambda () (casual-lib-checkbox-label
                              isearch-case-fold-search
                              "Ignora maiuscole e minuscole")))
    ("L" "Ignora differenze negli spazi"
     isearch-toggle-lax-whitespace
     :description (lambda () (casual-lib-checkbox-label
                              (if isearch-regexp
                                  isearch-regexp-lax-whitespace
                                isearch-lax-whitespace)
                              "Ignora differenze negli spazi")))]

   ["Altre azioni"
    ("o" "Elenca le corrispondenze" isearch-occur)
    ("h" "Evidenzia" isearch-highlight-regexp)
    ("H" "Evidenzia le righe" isearch-highlight-lines-matching-regexp)
    ("u" "Rimuovi l’evidenziazione" unhighlight-regexp)]

   ["Navigazione"
    ("p" "Precedente" isearch-repeat-backward
     :description (lambda () (casual-isearch-unicode-get :previous))
     :transient t)
    ("n" "Successivo" isearch-repeat-forward
     :description (lambda () (casual-isearch-unicode-get :next))
     :transient t)
    ("<" "Prima" isearch-beginning-of-buffer
     :description (lambda () (casual-isearch-unicode-get :first))
     :transient t)
    (">" "Ultima" isearch-end-of-buffer
     :description (lambda () (casual-isearch-unicode-get :last))
     :transient t)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("," "Preferenze ›" casual-isearch-settings-tmenu)
   ("RET" "Fine" isearch-exit)
   (casual-lib-quit-all)])

(provide 'casual-isearch)
;;; casual-isearch.el ends here
