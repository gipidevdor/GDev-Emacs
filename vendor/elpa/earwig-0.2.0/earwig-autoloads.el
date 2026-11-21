;;; earwig-autoloads.el --- Attivazione del fork Voce GDev -*- lexical-binding: t; no-byte-compile: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(add-to-list 'load-path (directory-file-name (or (file-name-directory load-file-name) (car load-path))))
(autoload 'earwig-mode "earwig" nil t)
(autoload 'earwig-dictate "earwig" nil t)
(autoload 'earwig-command "earwig" nil t)
(provide 'earwig-autoloads)
