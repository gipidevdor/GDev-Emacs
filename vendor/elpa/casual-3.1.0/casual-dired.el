;;; casual-dired.el --- Transient UI for Dired -*- lexical-binding: t; -*-

;; Modificato per GDev-Emacs il 2026-11-15: etichette e richieste in italiano.

;; Copyright (C) 2024-2026 Charles Y. Choi

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

;; Casual Dired is a Transient user interface for the Dired library.

;; INSTALLATION

;; By default, `casual-init' will setup Casual Dired by running the hook
;; function `casual-dired-init'.

;; Ensure that `casual-dired-init' is included in the customizable hook
;; variable `casual-init-hook'.

;; Consult the Info node `(casual) Dired Install' for more detail on
;; installation.


;;; Code:
(require 'dired)
(require 'dired-x)
(require 'wdired)
(require 'image-dired)
(require 'casual-lib)
(require 'casual-dired-sort-by)
(require 'casual-dired-variables)
(require 'casual-dired-settings)
(require 'casual-dired-utils)

;;;###autoload (autoload 'casual-dired-init "casual-dired" nil t)
(defun casual-dired-init ()
  "Initialize and configure Casual Dired.

This hook binds `casual-dired-tmenu' to `casual-keybinding-primary'.

If `casual-dired-add-extra-keybindings' is non-nil, then extra
keybindings specified in `casual-dired-setup' will be set."
  (add-hook 'dired-mode-hook #'casual-dired-setup))

(defun casual-dired-setup ()
  "Setup `dired-mode' for Casual.

To see what keybindings are set by this function, press ‘s’ to view its
source."
  (keymap-set dired-mode-map casual-keybinding-primary #'casual-dired-tmenu)

  (when casual-dired-add-extra-keybindings
    (keymap-set dired-mode-map "s" #'casual-dired-sort-by-tmenu)
    (keymap-set dired-mode-map "/" #'casual-dired-search-replace-tmenu)
    (keymap-set dired-mode-map "E" #'wdired-change-to-wdired-mode)
    (keymap-set dired-mode-map "M-n" #'dired-next-dirline)
    (keymap-set dired-mode-map "M-p" #'dired-prev-dirline)
    (keymap-set dired-mode-map "]" #'dired-next-subdir)
    (keymap-set dired-mode-map "[" #'dired-prev-subdir)
    (keymap-set dired-mode-map "M-]" #'dired-next-marked-file)
    (keymap-set dired-mode-map "M-[" #'dired-prev-marked-file)
    (keymap-set dired-mode-map "M-j" #'dired-goto-subdir)
    (keymap-set dired-mode-map ";" #'image-dired-dired-toggle-marked-thumbs)))

;;; Menus
;;;###autoload (autoload 'casual-dired-tmenu "casual-dired" nil t)
(transient-define-prefix casual-dired-tmenu ()
  "Transient menu for Dired."
  :refresh-suffixes t

  [:inapt-if-not-derived 'dired-mode
   ["File"
    ("o" "Apri in un altro riquadro" dired-find-file-other-window)
    ("v" "Consulta" dired-view-file)
    ("C" "Copia in…" dired-do-copy :transient t)
    ("R" "Rinomina…" dired-do-rename :transient t)
    ("D" "Elimina…" dired-do-delete :transient t)
    ("l" "Collegamento ›" casual-dired-link-tmenu)
    ("c" "Modifica ›" casual-dired-change-tmenu)
    ("y" "Tipo" dired-show-file-type :transient t)
    ("w" "Copia nome" dired-copy-filename-as-kill)
    ("!" "Comando della shell…" dired-do-shell-command)
    ("&" "Comando in secondo piano…" dired-do-async-shell-command)
    (";" "Miniatura" image-dired-dired-toggle-marked-thumbs
     :if casual-dired-image-file-p
     :transient t)
    ("W" "Apri nel browser" browse-url-of-dired-file)]

   ["Cartella"
    ("s" "Ordina per ›" casual-dired-sort-by-tmenu
     :if casual-dired-show-sort-by-tmenu-p
     :transient t)
    ("h" "Nascondi dettagli" dired-hide-details-mode
     :description
     (lambda ()
       (casual-lib-checkbox-label dired-hide-details-mode "Nascondi dettagli"))
     :if-not casual-dired-lisp-dired-buffer-p
     :transient t)
    ("O" "Ometti i file esclusi" dired-omit-mode
     :description
     (lambda () (casual-lib-checkbox-label dired-omit-mode "Ometti i file esclusi"))
     :transient t)
    ("i" "Mostra sottocartella" dired-maybe-insert-subdir
     :if casual-dired-directory-p
     :transient t)
    ("$" "Mostra o nascondi la sottocartella" dired-hide-subdir
     :if-not casual-dired-lisp-dired-buffer-p
     :transient t)
    ("k" "Nascondi righe" dired-do-kill-lines
     :description (lambda () (if prefix-arg "Nascondi sottocartella" "Nascondi righe"))
     :if casual-dired-marked-files-p
     :transient t)
    ("g" "Aggiorna" revert-buffer :transient t)
    ("f" "Filtra per nome…" casual-dired-find-dired-regexp)
    ("E" "Modifica l’elenco dei file" wdired-change-to-wdired-mode)
    ("T" "Miniature…" image-dired :if display-graphic-p)
    ("d" "Apri cartella…" dired)]

   ["Operazioni multiple"
    ("m" "Segna" dired-mark
     :if-not casual-dired-marked-p
     :transient t)
    ("u" "Togli il segno" dired-unmark
     :if casual-dired-marked-p
     :transient t)
    ("U" "Togli tutti i segni" dired-unmark-all-marks
     :if casual-dired-marked-files-p
     :transient t)
    ("t" "Inverti i segni" dired-toggle-marks :transient t)
    ("r" "Espressione regolare ›" casual-dired-regexp-tmenu)
    ("/" "Cerca e sostituisci ›" casual-dired-search-replace-tmenu)
    ("#" "Altre operazioni ›" casual-dired-utils-tmenu)
    ("~" "Segna le copie di riserva" dired-flag-backup-files :transient t)
    ("x" "Elimina i file segnati" dired-do-flagged-delete :transient t)]

   ["Navigazione"
    :pad-keys t
    ("^" ".." dired-up-directory
     :description (lambda ()
                    (format ".. %s" (casual-dired-unicode-get :directory)))
     :transient t)

    ("p" " ↑ 📄" dired-previous-line
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :up-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :file)))
     :transient t)

    ("n" " ↓ 📄" dired-next-line
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :down-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :file)))
     :transient t)
    ("M-[" " ↑ *📄" dired-prev-marked-file
     :if casual-dired-marked-p
     :description (lambda ()
                    (format "%s %s%s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :up-arrow)
                             casual-lib-use-unicode)
                            (char-to-string dired-marker-char)
                            (casual-dired-unicode-get :file)))
     :transient t)
    ("M-]" " ↓ *📄" dired-next-marked-file
     :if casual-dired-marked-p
     :description (lambda ()
                    (format "%s %s%s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :down-arrow)
                             casual-lib-use-unicode)
                            (char-to-string dired-marker-char)
                            (casual-dired-unicode-get :file)))
     :transient t)
    ("M-p" " ↑ 📁" dired-prev-dirline
     :if-not casual-dired-lisp-dired-buffer-p
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :up-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :directory)))
     :transient t)
    ("M-n" " ↓ 📁" dired-next-dirline
     :if-not casual-dired-lisp-dired-buffer-p
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :down-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :directory)))
     :transient t)
    ("[" " ↑ 🗂️" dired-prev-subdir
     :if-not casual-dired-lisp-dired-buffer-p
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :up-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :subdir)))
     :transient t)
    ("]" " ↓ 🗂️" dired-next-subdir
     :if-not casual-dired-lisp-dired-buffer-p
     :description (lambda ()
                    (format "%s %s"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :down-arrow)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :subdir)))
     :transient t)
    ("j" " → 📄…" dired-goto-file
     :description (lambda ()
                    (format "%s %s…"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :goto)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :file)))
     :transient t)
    ("M-j" " → 🗂️…" dired-goto-subdir
     :description (lambda ()
                    (format "%s %s…"
                            (casual-dired-format-arrow
                             (casual-dired-unicode-get :goto)
                             casual-lib-use-unicode)
                            (casual-dired-unicode-get :subdir)))
     :transient t)]]

  [:inapt-if-not-derived 'dired-mode
   ["Azioni rapide"
    ("J" "Vai al segnalibro…" bookmark-jump)
    ("B" "Aggiungi segnalibro…" bookmark-set-no-overwrite)
    ("b" "Elenca le aree di testo" ibuffer)]

   ["Cerca"
    :pad-keys t
    ("C-s" "Cerca per nome…" dired-isearch-filenames)
    ("M-s" "Cerca per nome con espressione regolare…" dired-isearch-filenames-regexp)
    ("M-f" "Cerca nei file…" rgrep)]

   ["Crea"
    ("+" "Cartella" dired-create-directory :transient t)
    ("F" "File" dired-create-empty-file :transient t)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("RET" "Apri" dired-find-file)
   ("," "Preferenze ›" casual-dired-settings-tmenu)
   ("q" "Chiudi il gestore file" quit-window)])

(transient-define-prefix casual-dired-regexp-tmenu ()
  "Transient menu for Dired regexp functions."
  :refresh-suffixes t
  ["Espressione regolare"
   ["Segna"
    ("m" "File…" dired-mark-files-regexp :transient t)
    ("c" "File che contengono…" dired-mark-files-containing-regexp :transient t)
    ("u" "Togli il segno" dired-unmark
     :inapt-if-not casual-dired-marked-p
     :transient t)
    ("U" "Togli tutti i segni" dired-unmark-all-marks
     :inapt-if-not casual-dired-marked-files-p
     :transient t)]
   ["Operazioni"
    ("F" "File da aprire…" dired-do-find-marked-files)
    ("C" "File da copiare…" dired-do-copy-regexp)
    ("r" "File da rinominare…" dired-do-rename-regexp)
    ("D" "File da eliminare…" dired-do-delete)]
   ["Contrassegna"
    ("d" "File da contrassegnare per l’eliminazione…" dired-flag-files-regexp)
    ("x" "Elimina i file contrassegnati" dired-do-flagged-delete)]]
  casual-lib-navigation-group-with-return)

(transient-define-prefix casual-dired-change-tmenu ()
  ["Modifica"
   [("M" "Permessi…" dired-do-chmod :transient t)
    ("G" "Gruppo…" dired-do-chgrp :transient t)
    ("O" "Proprietario…" dired-do-chown :transient t)]
   [("T" "Data di modifica…" dired-do-touch :transient t)]]
  casual-lib-navigation-group-with-return)

;;; Functions

(defun casual-dired-directory-p ()
  "Predicate if Dired item is a directory."
  (condition-case nil
      (and (file-directory-p (thing-at-point 'filename))
           (not (casual-dired-lisp-dired-buffer-p)))
    (error nil)))

(defun casual-dired-image-file-p ()
  "Predicate if Dired item is an image file."
  (if (and (display-graphic-p) (derived-mode-p 'dired-mode))
      (let ((fname (dired-file-name-at-point)))
        (if fname
            (string-match-p (image-file-name-regexp)
                            fname)
          nil))
    nil))

(defun casual-dired-lisp-dired-buffer-p ()
  "Predicate if buffer name is “*Find Lisp Dired*”.

This buffer is created by the command `find-lisp-find-dired'."
  (and (derived-mode-p 'dired-mode)
       (string-equal (buffer-name) "*Find Lisp Dired*")))

(defun casual-dired-show-sort-by-tmenu-p ()
  "Predicate to show `casual-dired-sort-by-tmenu'."
  (and (equal dired-use-ls-dired t)
       (not (casual-dired-lisp-dired-buffer-p))))

(defun casual-dired-find-dired-regexp (REGEXP)
  "Recursively find file names in current directory matching REGEXP.

Recursively find all files whose name matches the Elisp REGEXP
from the current directory `default-directory'. The value of
REGEXP will be interactively prompted for.

The command `find-lisp-find-dired' does all the heavy lifting
here.

* References
- Info node `(elisp) Regular Expressions'"
  (interactive "sCerca i nomi con espressione regolare: ")
  (find-lisp-find-dired default-directory REGEXP))

;;; Labels
(defun casual-dired-format-arrow (buf typeset)
  "If TYPESET is non-nil, then format BUF string to have space."
  (if typeset
      (format " %s" buf)
    buf))

(provide 'casual-dired)
;;; casual-dired.el ends here
