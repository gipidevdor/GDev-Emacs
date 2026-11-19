;;; casual-ibuffer-filter.el --- Casual IBuffer Filter -*- lexical-binding: t; -*-

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
;;

(require 'transient)
(require 'ibuffer)
(require 'ibuf-ext)
(require 'casual-lib)
(require 'casual-ibuffer-settings)
(require 'casual-ibuffer-utils)

;;; Code:
(defvar casual-ibuffer--current-collection-name nil
  "Internal variable for current filter group collection name.")

(defun casual-ibuffer-switch-to-saved-filter-groups (name)
  "Set this buffer's filter groups to saved version with NAME.
The value from `ibuffer-saved-filter-groups' is used."
  (interactive
   (list
    (cond ((null ibuffer-saved-filter-groups)
           (error "Nessun filtro salvato"))
          ;; `ibuffer-saved-filter-groups' is a user variable that defaults
          ;; to nil.  We assume that with one element in this list the user
          ;; knows what she wants.  See bug#12331.
          ((null (cdr ibuffer-saved-filter-groups))
           (caar ibuffer-saved-filter-groups))
          (t
           (completing-read "Apri gruppo di filtri salvato: "
                            ibuffer-saved-filter-groups nil t)))))

  (setq casual-ibuffer--current-collection-name name)
  (setq ibuffer-filter-groups (cdr (assoc name ibuffer-saved-filter-groups))
        ibuffer-hidden-filter-groups nil)
  (ibuffer-update nil t))

(defun casual-ibuffer--ibuffer-update (arg &optional silent)
  "Advising function after `ibuffer-update' is called with ARG and SILENT."
  (ignore arg)
  (ignore silent)
  (if (not ibuffer-filter-groups)
      (setq casual-ibuffer--current-collection-name nil)))

(advice-add #'ibuffer-update :after #'casual-ibuffer--ibuffer-update)

;; Transients
;;;###autoload (autoload 'casual-ibuffer-filter-tmenu "casual-ibuffer-filter" nil t)
(transient-define-prefix casual-ibuffer-filter-tmenu ()
  "Casual IBuffer filter menu."
  :refresh-suffixes t
  ["Filtra le aree di testo"
   ["Aggiungi"
    :pad-keys t
    ("SPC" "Regola…" ibuffer-filter-chosen-by-completion
     :transient t)
    ("r" "Passa a…" ibuffer-switch-to-saved-filters
     :transient t)
    ("a" "Aggiungi dai filtri salvati…" ibuffer-add-saved-filters :transient t)
    ("g" "Crea gruppo di filtri…" ibuffer-filters-to-filter-group
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)]

   ["Combina"
    ("&" "and" ibuffer-and-filter
     :inapt-if (lambda () (< (length ibuffer-filtering-qualifiers) 2))
     :transient t)
    ("|" "or" ibuffer-or-filter
     :inapt-if (lambda () (< (length ibuffer-filtering-qualifiers) 2))
     :transient t)
    ("!" "not" ibuffer-negate-filter
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)
    ("t" "Scambia" ibuffer-exchange-filters
     :inapt-if (lambda () (< (length ibuffer-filtering-qualifiers) 2))
     :transient t)
    ("d" "Scomponi" ibuffer-decompose-filter
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)]

   ["Rimuovi"
    ("-" "Pop" ibuffer-pop-filter
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)
    ("/" "Azzera" ibuffer-filter-disable
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)]

   ["Salva filtri"
    ("s" "Salva…" ibuffer-save-filters
     :inapt-if (lambda () (null ibuffer-filtering-qualifiers))
     :transient t)
    ("x" "Elimina…" ibuffer-delete-saved-filters :transient t)]

   ["Navigazione"
    :pad-keys t
    ("p" "Precedente" ibuffer-backward-line
     :description (lambda ()
                    (format "%s" (casual-ibuffer-unicode-get :previous)))
     :transient t)
    ("n" "Successivo" ibuffer-forward-line
     :description (lambda () (format "%s" (casual-ibuffer-unicode-get :next)))
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

  ["Gruppo di filtri"
   :description (lambda () (format "Gruppo di filtri %s"
                                   (casual-ibuffer-unicode-get :group)))
   ["Raccolta"
    :description (lambda ()
                   (format "Raccolta%s"
                           (if casual-ibuffer--current-collection-name
                               (format
                                " (%s)"
                                casual-ibuffer--current-collection-name)
                             "")))
    ("R" "Passa a…" casual-ibuffer-switch-to-saved-filter-groups)
    ("S" "Salva…" ibuffer-save-filter-groups
     :inapt-if (lambda () (not ibuffer-filter-groups))
     :transient t)
    ("X" "Elimina…" ibuffer-delete-saved-filter-groups :transient t)]
   ["Modifica"
    ("D" "Scomponi…" ibuffer-decompose-filter-group :transient t)]
   ["Rimuovi"
    ("P" "Pop" ibuffer-pop-filter-group :transient t)
    ("\\" "Azzera tutto" ibuffer-clear-filter-groups :transient t)]]

  [:class transient-row
   ("C-g" "Indietro" transient-quit-one
    :description casual-lib--quit-one-suffix-label
    :if-not casual-lib-hide-navigation-p)
   ("," "Preferenze ›" casual-ibuffer-settings-tmenu)
   ("RET" "Apri o alterna" casual-ibuffer-return-dwim)
   ("$" "Mostra o nascondi il gruppo" ibuffer-toggle-filter-group
    :description (lambda () (format "Mostra o nascondi %s" (casual-ibuffer-unicode-get :group)))
    :inapt-if-not (lambda () (casual-ibuffer-filter-group-p))
    :transient t)
   ("C-q" "Chiudi menu" transient-quit-all
    :if-not casual-lib-quit-all-hide-navigation-p)])

(provide 'casual-ibuffer-filter)
;;; casual-ibuffer-filter.el ends here
