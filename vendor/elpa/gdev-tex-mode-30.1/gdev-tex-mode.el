;;; gdev-tex-mode.el --- Inizializzazione LaTeX da GNU Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 1985-1986, 1989, 1992, 1994-1999, 2001-2025 Free
;; Software Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Keywords: tex

;; Contributions over the years by William F. Schelter, Dick King,
;; Stephen Gildea, Michael Prange, Jacob Gore, and Edward M. Reingold.

;; This code originates in GNU Emacs, lisp/textmodes/tex-mode.el,
;; revision 8ac894e2246f25d2a2a97d866b10e6e0b0fede5a (Emacs 30.1).
;;
;; Modificato per GDev-Emacs il 2026-11-15.
;; Estrae l'inizializzazione di latex-mode sotto un nome separato.
;; Conserva il motore e le primitive TeX fornite da Emacs.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Inizializzazione di LaTeX per modalità derivate da tex-mode.
;; La modalità originale e il suo motore rimangono disponibili.

;;; Code:

(require 'tex-mode)

;;;###autoload
(defun gdev-tex-latex-initialize ()
  "Inizializza il buffer LaTeX con le regole di GNU Emacs 30.1."
  (setq-local tex-command latex-run-command)
  (setq-local tex-start-of-header "\\\\document\\(style\\|class\\)")
  (setq-local tex-end-of-header "\\\\begin\\s-*{document}")
  (setq-local tex-trailer "\\end{document}\n")
  ;; A line containing just $$ is treated as a paragraph separator.
  ;; A line starting with $$ starts a paragraph,
  ;; but does not separate paragraphs if it has more stuff on it.
  ;; For \pagebreak allow latex optional arg like \pagebreak[2]
  (setq paragraph-start
	(concat "[ \t]*\\(\\$\\$\\|"
		"\\\\[][]\\|"
		"\\\\" (regexp-opt (append
				    (mapcar #'car latex-section-alist)
				    '("begin" "label" "end"
				      "item" "bibitem" "newline" "noindent"
				      "newpage" "footnote" "marginpar"
				      "parbox" "caption"))
                                   t)
		"\\>\\|\\\\[a-z]*" (regexp-opt '("space" "skip" "page") t)
		"\\>\\)"))
  (setq paragraph-separate
	(concat "\\([ \t]*%\\)\\|[\f]\\|[ \t]*\\($\\|"
		"\\\\[][]\\|"
		"\\\\" (regexp-opt (append
				    (mapcar #'car latex-section-alist)
				    '("begin" "label" "end" ))
                                   t)
		"\\>\\|\\\\\\(" (regexp-opt '("item" "bibitem" "newline"
					      "noindent" "newpage" "footnote"
					      "marginpar" "parbox" "caption"))
		"\\|\\$\\$\\|[a-z]*\\(space\\|skip\\|page[a-z]*\\)"
		"\\>\\)[][0-9 \t]*\\($\\|%\\)\\)"))
  (setq-local imenu-create-index-function #'latex-imenu-create-index)
  (setq-local tex-face-alist tex-latex-face-alist)
  (add-hook 'fill-nobreak-predicate #'latex-fill-nobreak-predicate nil t)
  (setq-local indent-line-function #'latex-indent)
  (setq-local fill-indent-according-to-mode t)
  (add-hook 'completion-at-point-functions
            #'latex-complete-data nil 'local)
  (add-hook 'flymake-diagnostic-functions #'tex-chktex nil t)
  (setq-local outline-regexp latex-outline-regexp)
  (setq-local outline-level #'latex-outline-level)
  (setq-local forward-sexp-function #'latex-forward-sexp)
  (setq-local skeleton-end-hook nil))

(provide 'gdev-tex-mode)
;;; gdev-tex-mode.el ends here
