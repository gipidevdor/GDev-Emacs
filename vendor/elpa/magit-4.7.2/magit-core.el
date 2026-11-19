;;; magit-core.el --- Core functionality  -*- lexical-binding:t -*-

;; Modificato da GDev-Emacs il 2026-11-15: interfaccia, messaggi e guide di Hit in italiano.

;; Copyright (C) 2008-2026 The Magit Project Contributors

;; Author: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>
;; Maintainer: Jonas Bernoulli <emacs.magit@jonas.bernoulli.dev>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library requires several other libraries, so that yet other
;; libraries can just require this one, instead of having to require
;; all the other ones.  In other words this separates the low-level
;; stuff from the rest.  It also defines some Custom groups.

;;; Code:

(require 'magit-base)
(require 'magit-git)
(require 'magit-mode)
(require 'magit-margin)
(require 'magit-process)
(require 'magit-transient)
(require 'magit-autorevert)

;;; Options

(defgroup magit nil
  "Hit, gli strumenti Git integrati in GDev."
  :tag "Hit"
  :link '(url-link "https://magit.vc")
  :link '(info-link "(magit)FAQ")
  :link '(info-link "(magit)")
  :group 'tools)

(defgroup magit-essentials nil
  "Impostazioni principali di Hit per comportamento e prestazioni."
  :tag "Impostazioni principali"
  :link '(info-link "(magit)Essential Settings")
  :group 'magit)

(defgroup magit-miscellaneous nil
  "Altre impostazioni di Hit."
  :tag "Altre impostazioni"
  :group 'magit)

(defgroup magit-commands nil
  "Impostazioni dei comandi di Hit."
  :tag "Comandi"
  :group 'magit)

(defgroup magit-modes nil
  "Modalità delle viste di Hit."
  :tag "Modalità"
  :group 'magit)

(defgroup magit-buffers nil
  "Nomi e disposizione delle viste di Hit."
  :tag "Viste"
  :link '(info-link "(magit)Modes and Buffers")
  :group 'magit)

(defgroup magit-refresh nil
  "Aggiornamento delle viste di Hit."
  :tag "Aggiornamento delle viste"
  :link '(info-link "(magit)Automatic Refreshing of Magit Buffers")
  :group 'magit
  :group 'magit-buffers)

(defgroup magit-faces nil
  "Stili del testo nelle viste di Hit."
  :tag "Aspetto"
  :group 'magit
  :group 'faces)

(custom-add-to-group 'magit-faces 'diff-refine-added   'custom-face)
(custom-add-to-group 'magit-faces 'diff-refine-removed 'custom-face)

(defgroup magit-extensions nil
  "Estensioni di Hit."
  :tag "Estensioni"
  :group 'magit)

(custom-add-to-group 'magit-modes   'git-commit        'custom-group)
(custom-add-to-group 'magit-faces   'git-commit-faces  'custom-group)
(custom-add-to-group 'magit-modes   'git-rebase        'custom-group)
(custom-add-to-group 'magit-faces   'git-rebase-faces  'custom-group)
(custom-add-to-group 'magit         'magit-section     'custom-group)
(custom-add-to-group 'magit-faces   'magit-section-faces 'custom-group)
(custom-add-to-group 'magit-process 'with-editor       'custom-group)

(defgroup magit-related nil
  "Impostazioni di Emacs usate anche da Hit."
  :tag "Integrazione con Emacs"
  :link '(custom-group-link vc)
  :link '(custom-group-link smerge)
  :link '(custom-group-link ediff)
  :link '(custom-group-link auto-revert)
  :group 'magit
  :group 'magit-extensions
  :group 'magit-essentials)

(custom-add-to-group 'magit-related     'auto-revert-check-vc-info 'custom-variable)
(custom-add-to-group 'magit-auto-revert 'auto-revert-check-vc-info 'custom-variable)

(custom-add-to-group 'magit-related 'ediff-window-setup-function 'custom-variable)
(custom-add-to-group 'magit-related 'smerge-refine-ignore-whitespace 'custom-variable)
(custom-add-to-group 'magit-related 'vc-follow-symlinks 'custom-variable)

;;; _
(provide 'magit-core)
;; Local Variables:
;; read-symbol-shorthands: (
;;   ("and$"         . "cond-let--and$")
;;   ("thread$"      . "cond-let--thread$")
;;   ("when$"        . "cond-let--when$")
;;   ("and-let*"     . "cond-let--and-let*")
;;   ("and-let"      . "cond-let--and-let")
;;   ("if-let*"      . "cond-let--if-let*")
;;   ("if-let"       . "cond-let--if-let")
;;   ("when-let*"    . "cond-let--when-let*")
;;   ("when-let"     . "cond-let--when-let")
;;   ("while-let*"   . "cond-let--while-let*")
;;   ("while-let"    . "cond-let--while-let")
;;   ("match-string" . "match-string")
;;   ("match-str"    . "match-string-no-properties"))
;; End:
;;; magit-core.el ends here
