;;; casual-ibuffer.el --- Transient UI for IBuffer -*- lexical-binding: t; -*-

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

;; Casual IBuffer is a Transient user interface for the IBuffer library.

;; INSTALLATION

;; By default, `casual-init' will setup Casual IBuffer by running the hook
;; function `casual-ibuffer-init'.

;; Ensure that `casual-ibuffer-init' is included in the customizable hook
;; variable `casual-init-hook'.

;; Consult the Info node `(casual) IBuffer Install' for more detail on
;; installation.

;;; Code:
(require 'ibuffer)
(require 'bookmark)
(require 'casual-lib)
(require 'casual-ibuffer-utils)
(require 'casual-ibuffer-settings)
(require 'casual-ibuffer-filter)

;;;###autoload (autoload 'casual-ibuffer-init "casual-ibuffer" nil t)
(defun casual-ibuffer-init ()
  "Initialize and configure Casual IBuffer.

This hook binds `casual-ibuffer-tmenu' to `casual-keybinding-primary'.

If `casual-ibuffer-add-extra-keybindings' is non-nil, then extra
keybindings specified in `casual-ibuffer-setup' will be set."
  (add-hook 'ibuffer-mode-hook #'casual-ibuffer-setup))

(defun casual-ibuffer-setup ()
  "Setup `ibuffer-mode' for Casual.

To see what keybindings are set by this function, press ‘s’ to view its
source."
  (keymap-set ibuffer-mode-map casual-keybinding-primary #'casual-ibuffer-tmenu)
  (when casual-ibuffer-add-extra-keybindings
    (keymap-set ibuffer-mode-map "F" #'casual-ibuffer-filter-tmenu)
    (keymap-set ibuffer-mode-map "s" #'casual-ibuffer-sortby-tmenu)))

;;;###autoload (autoload 'casual-ibuffer-tmenu "casual-ibuffer" nil t)
(transient-define-prefix casual-ibuffer-tmenu ()
  :refresh-suffixes t
  ["Documenti e strumenti"
   ["Operazioni"
    ("o" "Apri in un altro riquadro" ibuffer-visit-buffer-other-window)
    ("S" "Salva" ibuffer-do-save :transient t)
    ("D" "Elimina…" ibuffer-do-delete :transient t)

    ("=" "Confronta con il file salvato" ibuffer-diff-with-file)
    ("w" "Copia nome del file" ibuffer-copy-filename-as-kill)
    ("M" "Altre operazioni ›" casual-ibuffer-operations-tmenu)]

   ["Segna"
    ("m" "Segna" ibuffer-mark-forward :transient t)
    ("t" "Tipo ›" casual-ibuffer-mark-tmenu :transient t)
    ("r" "Espressione regolare ›" casual-ibuffer-mark-regexp-tmenu :transient t)
    ("u" "Togli il segno" ibuffer-unmark-forward :transient t)
    ("d" "Da eliminare" ibuffer-mark-for-delete :transient t)
    ("x" "Elimina le aree segnate…" ibuffer-do-kill-on-deletion-marks)
    ("U" "Togli tutti i segni" ibuffer-unmark-all-marks :transient t)]

   ["Visualizzazione"
    ("s" "Ordina per ›" casual-ibuffer-sortby-tmenu :transient t)
    ("`" "Cambia formato" ibuffer-switch-format :transient t)
    ("b" "Nascondi l’area di testo" ibuffer-bury-buffer :transient t)
    ("g" "Aggiorna" ibuffer-update :transient t)
    ("$" "Mostra o nascondi il gruppo" ibuffer-toggle-filter-group
     :description (lambda () (format "Mostra o nascondi %s" (casual-ibuffer-unicode-get :group)))
     :inapt-if-not (lambda () (casual-ibuffer-filter-group-p))
     :transient t)]

   ["Navigazione"
    :pad-keys t
    ("p" "Precedente" ibuffer-backward-line
     :description (lambda ()
                    (format "%s" (casual-ibuffer-unicode-get :previous)))
     :transient t)
    ("n" "Successivo" ibuffer-forward-line
     :description (lambda () (format "%s" (casual-ibuffer-unicode-get :next)))
     :transient t)
    ("{" "Segnata precedente" ibuffer-backwards-next-marked
     :description (lambda ()
                    (format "%s %s"
                            (casual-ibuffer-unicode-get :previous)
                            (casual-ibuffer-unicode-get :marked)))
     :transient t)
    ("}" "Segnata successiva" ibuffer-forward-next-marked
     :description (lambda ()
                    (format "%s %s"
                            (casual-ibuffer-unicode-get :next)
                            (casual-ibuffer-unicode-get :marked)))
     :transient t)
    ("[" "Gruppo precedente" ibuffer-backward-filter-group
     :description (lambda ()
                    (format "%s %s"
                            (casual-ibuffer-unicode-get :previous)
                            (casual-ibuffer-unicode-get :group)))
     :transient t)
    ("]" "Gruppo successivo" ibuffer-forward-filter-group
     :description (lambda ()
                    (format "%s %s"
                            (casual-ibuffer-unicode-get :next)
                            (casual-ibuffer-unicode-get :group)))
     :transient t)
    ("j" "Vai a…" ibuffer-jump-to-buffer
     :description (lambda () (format "%s…" (casual-ibuffer-unicode-get :jump)))
     :transient t)
    ("M-j" "Vai a…" ibuffer-jump-to-filter-group
     :description (lambda () (format "%s…"
                                     (casual-ibuffer-unicode-get :jumpgroup)))
     :transient t)]]

  [["Filtra"
    :pad-keys t
    ("SPC" "Aggiungi regola…" ibuffer-filter-chosen-by-completion)
    ("/" "Azzera" ibuffer-filter-disable)
    ("F" "Filtri ›" casual-ibuffer-filter-tmenu :transient t)]

   ["Cerca nelle aree segnate"
    :pad-keys t
    ("C-s" "Ricerca incrementale…" ibuffer-do-isearch)
    ("C-M-s" "Ricerca incrementale con espressione regolare…" ibuffer-do-isearch-regexp)
    ("O" "Elenca le corrispondenze…" ibuffer-do-occur)]

   ["Sostituisci nelle aree segnate"
    :pad-keys t
    ("M-r" "Sostituisci con conferma…" ibuffer-do-query-replace)
    ("C-M-r" "Sostituisci con espressione regolare…" ibuffer-do-query-replace-regexp)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("RET" "Apri o alterna" casual-ibuffer-return-dwim
    :description (lambda () (if (casual-ibuffer-filter-group-p)
                                "Opzioni"
                              "Apri")))
   ("," "Preferenze ›" casual-ibuffer-settings-tmenu)
   ("J" "Vai al segnalibro…" bookmark-jump :transient nil)
   (casual-lib-quit-all)
   ("q" "Chiudi l’elenco" quit-window)])


(transient-define-prefix casual-ibuffer-operations-tmenu ()
  ["Operazioni sulle aree di testo"
   [("R" "Rinomina con un nome univoco…" ibuffer-do-rename-uniquely)
    ("!" "Comando della shell…" ibuffer-do-shell-command-file)
    ("|" "Invia a un comando della shell…" ibuffer-do-shell-command-pipe)]

   [("E" "Valuta…" ibuffer-do-eval)
    ("V" "Mostra e valuta…" ibuffer-do-view-and-eval)
    ("B" "Copia nome dell’area" ibuffer-copy-buffername-as-kill)]

   [("T" "Attiva o disattiva sola lettura" ibuffer-do-toggle-read-only)
    ("L" "Blocca o sblocca" ibuffer-do-toggle-lock)]]

  casual-lib-navigation-group-plain)

;;;###autoload (autoload 'casual-ibuffer-sortby-tmenu "casual-ibuffer" nil t)
(transient-define-prefix casual-ibuffer-sortby-tmenu ()
  ["Ordina le aree di testo"
   [("v" "Ultimo accesso" ibuffer-do-sort-by-recency)
    ("a" "Nome dell’area" ibuffer-do-sort-by-alphabetic)
    ("f" "Percorso o processo" ibuffer-do-sort-by-filename/process)]

   [("m" "Modalità principale" ibuffer-do-sort-by-major-mode)
    ("s" "Dimensione" ibuffer-do-sort-by-size)]

   [("i" "Inverti l’ordine" ibuffer-invert-sorting)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("," "Cambia ordinamento" ibuffer-toggle-sorting-mode)
   (casual-lib-quit-all)])

(transient-define-prefix casual-ibuffer-mark-tmenu ()
  ["Segna aree di testo"
   [("m" "Modalità" ibuffer-mark-by-mode)
    ("d" "Gestore file" ibuffer-mark-dired-buffers)
    ("h" "Aiuto" ibuffer-mark-help-buffers)]

   [("*" "Modificate" ibuffer-mark-modified-buffers)
    ("r" "Sola lettura" ibuffer-mark-read-only-buffers)
    ("u" "Da salvare" ibuffer-mark-unsaved-buffers)]

   [("D" "Senza file associato" ibuffer-mark-dissociated-buffers)
    ("s" "Aree di servizio" ibuffer-mark-special-buffers)
    ("z" "Compresse" ibuffer-mark-compressed-file-buffers)]]

  [:class transient-row
   (casual-lib-quit-one)
   ("U" "Togli tutti i segni" ibuffer-unmark-all-marks :transient t)
   (casual-lib-quit-all)])

(transient-define-prefix casual-ibuffer-mark-regexp-tmenu ()
  ["Segna con espressione regolare"
   ("f" "Nome del file" ibuffer-mark-by-file-name-regexp)
   ("n" "Nome dell’area" ibuffer-mark-by-name-regexp)
   ("m" "Modalità" ibuffer-mark-by-mode-regexp)
   ("c" "Contenuto" ibuffer-mark-by-content-regexp)]
  [:class transient-row
   (casual-lib-quit-one)
   ("U" "Togli tutti i segni" ibuffer-unmark-all-marks :transient t)
   (casual-lib-quit-all)])

(provide 'casual-ibuffer)
;;; casual-ibuffer.el ends here
