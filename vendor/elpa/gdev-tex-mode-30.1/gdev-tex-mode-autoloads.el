;;; gdev-tex-mode-autoloads.el --- Autoload di LaTeX GDev -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

(add-to-list 'load-path (or (and load-file-name (directory-file-name (file-name-directory load-file-name))) (car load-path)))

(autoload 'gdev-tex-latex-initialize "gdev-tex-mode" nil nil)
(register-definition-prefixes "gdev-tex-mode" '("gdev-tex-"))

(provide 'gdev-tex-mode-autoloads)
;;; gdev-tex-mode-autoloads.el ends here
