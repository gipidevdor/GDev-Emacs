;;; gdev-doc-view-autoloads.el --- Autoload della vista paginata GDev -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

(add-to-list 'load-path (or (and load-file-name (directory-file-name (file-name-directory load-file-name))) (car load-path)))

(autoload 'gdev-doc-view-mode "gdev-doc-view" nil t)
(register-definition-prefixes "gdev-doc-view" '("gdev-doc-view-"))

(provide 'gdev-doc-view-autoloads)
;;; gdev-doc-view-autoloads.el ends here
