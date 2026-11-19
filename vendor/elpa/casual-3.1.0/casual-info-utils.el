;;; casual-info-utils.el --- Casual Info Utils  -*- lexical-binding: t; -*-

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

(require 'transient)
(require 'info)
(require 'casual-lib)
(require 'casual-info-variables)

(defgroup casual-info nil
  "Settings for Casual Info."
  :group 'casual)

(defcustom casual-info-add-extra-keybindings t
  "If non-nil then extra module-specific keybindings will be set.

See `casual-info-setup' for more detail for said keybindings."
  :type 'boolean
  :group 'casual-info)

(defconst casual-info-unicode-db
  '((:history-back . '("⟨" "Precedente"))
    (:history-forward . '("⟩" "Successivo"))
    (:backward-node . '("⟪" "Indietro"))
    (:forward-node . '("⟫" "Avanti"))
    (:previous . '("←" "Precedente"))
    (:next . '("→" "Successivo"))
    (:top-node . '("⤒" "Top"))
    (:final-node . '("⤓" "Ultimo"))
    (:up-node . '("^" "Up"))
    (:up-arrow . '("↑" "Precedente"))
    (:down-arrow . '("↓" "Successivo"))
    (:scroll-up . '("📄↓" "Up"))
    (:scroll-down . '("📄↑" "Giù"))
    (:paragraph . '(" ¶" "Paragrafo"))
    (:link . '(" 🔗" "Collegamento")))
  "Unicode symbol DB to use for Info Transient menus.")

(defun casual-info-unicode-get (key)
  "Lookup Unicode symbol for KEY in DB.

- KEY symbol used to lookup Unicode symbol in DB.

If the value of customizable variable `casual-lib-use-unicode'
is non-nil, then the Unicode symbol is returned, otherwise a
plain ASCII-range string."
  (casual-lib-unicode-db-get key casual-info-unicode-db))

(defun casual-info-browse-backward-paragraph ()
  "Move point backward paragraph such that the first line is highlighted.
\nThis function is intended to be used with `hl-line-mode'."
  (interactive)
  (backward-paragraph 2)
  (forward-line))

(make-obsolete 'casual-info-browse-backward-paragraph
               #'casual-lib-browse-backward-paragraph
               "2.6.0")

(defun casual-info-browse-forward-paragraph ()
  "Move point forward paragraph such that the first line is highlighted.
\nThis function is intended to be used with `hl-line-mode'."
  (interactive)
  (forward-paragraph)
  (forward-line))

(make-obsolete 'casual-info-browse-forward-paragraph
               #'casual-lib-browse-forward-paragraph
               "2.6.0")

(provide 'casual-info-utils)
;;; casual-info-utils.el ends here
