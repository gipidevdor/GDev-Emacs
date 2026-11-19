;;; casual-info.el --- Transient UI for Info -*- lexical-binding: t; -*-

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

;; Casual Info is a Transient user interface for the Info library.

;; INSTALLATION

;; By default, `casual-init' will setup Casual Info by running the hook
;; function `casual-info-init'.

;; Ensure that `casual-info-init' is included in the customizable hook
;; variable `casual-init-hook'.

;; Consult the Info node `(casual) Info Install' for more detail on
;; installation.

;;; Code:
(require 'transient)
(require 'info)
(require 'casual-lib)

(require 'casual-info-variables)
(require 'casual-info-settings)
(require 'casual-info-utils)

;;;###autoload (autoload 'casual-info-init "casual-info" nil t)
(defun casual-info-init ()
  "Initialize and configure Casual Info.

This hook binds `casual-info-tmenu' to `casual-keybinding-primary'.

If `casual-info-add-extra-keybindings' is non-nil, then extra
keybindings specified in `casual-info-setup' will be set."
  (add-hook 'Info-mode-hook #'casual-info-setup))

(defun casual-info-setup ()
  "Setup `Info-mode' for Casual.

To see what keybindings are set by this function, press ‘s’ to view its
source."
  (keymap-set Info-mode-map casual-keybinding-primary #'casual-info-tmenu)

  (when casual-info-add-extra-keybindings
    (keymap-set Info-mode-map "M-[" #'Info-history-back)
    (keymap-set Info-mode-map "M-]" #'Info-history-forward)
    (keymap-set Info-mode-map "p" #'casual-lib-browse-backward-paragraph)
    (keymap-set Info-mode-map "n" #'casual-lib-browse-forward-paragraph)
    (keymap-set Info-mode-map "h" #'Info-prev)
    (keymap-set Info-mode-map "j" #'Info-next-reference)
    (keymap-set Info-mode-map "k" #'Info-prev-reference)
    (keymap-set Info-mode-map "l" #'Info-next)
    (keymap-set Info-mode-map "/" #'Info-search)
    (keymap-set Info-mode-map "B" #'bookmark-set)))

;;; Menus
;;;###autoload (autoload 'casual-info-tmenu "casual-info" nil t)

(transient-define-prefix casual-info-tmenu ()
  "CC Info Transient menu."

  [["Panoramica"
    ("d" "Indice dei manuali" Info-directory)
    ("M" "Manuale…" info-display-manual)
    ("t" "Top" Info-top-node)
    ("T" "ToC" Info-toc :transient nil)]

   ["Vai a"
    ("m" "Voce del menu…" Info-menu)
    ("g" "Capitolo…" Info-goto-node)
    ("i" "Indice analitico…" Info-index)
    ("I" "Indice delle variabili…" Info-virtual-index)]

   ["Cerca"
    :pad-keys t
    ("C-s" "Ricerca incrementale…" isearch-forward)
    ("s" "Cerca…" Info-search)
    ("S" "Distingui maiuscole e minuscole…" Info-search-case-sensitively)
    ("a" "Cerca nei manuali…" info-apropos)]

   ["Cronologia"
    :pad-keys t
    ("L" "Cronologia" Info-history :transient nil)
    ("M-[" "←" Info-history-back
     :description (lambda () (casual-info-unicode-get :history-back))
     :transient t)
    ("M-]" "→" Info-history-forward
     :description (lambda () (casual-info-unicode-get :history-forward))
     :transient t)]

   ["Scorrimento"
    :pad-keys t
    ("S-SPC" "Scorri verso il basso" Info-scroll-down
     :if display-graphic-p
     :description (lambda ()
                    (casual-info-unicode-get :scroll-down))
     :transient t)

    ("DEL" "Scorri verso il basso" Info-scroll-down
     :if-not display-graphic-p
     :description (lambda ()
                    (casual-info-unicode-get :scroll-down))
     :transient t)

    ("SPC" "Scorri verso l’alto" Info-scroll-up
     :description (lambda ()
                    (casual-info-unicode-get :scroll-up))
     :transient t)]]

  ["Navigazione"
   ["Collegamento"
    :description (lambda () (casual-info-unicode-get :link))
    ("k" "Precedente" Info-prev-reference
     :description (lambda () (casual-info-unicode-get :up-arrow))
     :transient t)
    ("j" "Successivo" Info-next-reference
     :description (lambda () (casual-info-unicode-get :down-arrow))
     :transient t)]

   ["Paragrafo"
    :description (lambda () (casual-info-unicode-get :paragraph))
    ("p" "Precedente" casual-lib-browse-backward-paragraph
     :description (lambda () (casual-info-unicode-get :up-arrow))
     :transient t)
    ("n" "Successivo" casual-lib-browse-forward-paragraph
     :description (lambda () (casual-info-unicode-get :down-arrow))
     :transient t)]

   ["Tutti i capitoli"
    ("[" "Indietro" Info-backward-node
     :description (lambda ()
                    (casual-info-unicode-get :backward-node))
     :transient t)
    ("]" "Avanti" Info-forward-node
     :description (lambda ()
                    (casual-info-unicode-get :forward-node))
     :transient t)]

   ["Capitoli allo stesso livello"
    ("h" "Precedente" Info-prev
     :description (lambda () (casual-info-unicode-get :previous))
     :transient t)
    ("l" "Successivo" Info-next
     :description (lambda () (casual-info-unicode-get :next))
     :transient t)]

   [""
    ("<" "Top" Info-top-node
     :description (lambda () (casual-info-unicode-get :top-node))
     :transient nil)
    (">" "Ultimo" Info-final-node
     :description (lambda () (casual-info-unicode-get :final-node))
     :transient nil)]

   [""
    :pad-keys t
    ("^" "Up"  Info-up
     :description (lambda () (casual-info-unicode-get :up-node))
     :transient t)
    ("RET" "Apri" Info-follow-nearest-node :transient t)]]

  ["Azioni rapide"
   [("J" "Vai al segnalibro…" bookmark-jump :transient nil)
    ("B" "Aggiungi un segnalibro…" bookmark-set :transient nil)
    ("b" "Elenca le aree di testo" ibuffer :transient nil)]

   [("c" "Copia il nome del capitolo" Info-copy-current-node-name :transient nil)
    ("G" "Apri il capitolo nel browser…" Info-goto-node-web :transient nil)]

   [:pad-keys t
    ("C-M-n" "Apri il manuale in un’altra finestra" casual-info-new-info-frame
     :transient nil)
    ("M-n" "Duplica l’area" clone-buffer :transient nil)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("," "Preferenze ›" casual-info-settings-tmenu)
   ("q" "Chiudi il manuale" quit-window)])

(defun casual-info-new-info-frame ()
  "Create new Info manual instance (buffer) in a new frame.

This command creates a new frame populated by the
`info-display-manual' command."
  (interactive)
  (other-frame-prefix)
  (call-interactively #'info-display-manual))

(provide 'casual-info)
;;; casual-info.el ends here
