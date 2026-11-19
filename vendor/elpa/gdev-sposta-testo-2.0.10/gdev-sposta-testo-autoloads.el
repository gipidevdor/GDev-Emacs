;;; gdev-sposta-testo-autoloads.el --- Autoload di Sposta testo -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

(let* ((directory (file-name-directory load-file-name))
       (library (expand-file-name "gdev-sposta-testo" directory)))
  (add-to-list 'load-path (directory-file-name directory))
  (autoload 'gdev-sposta-testo-giu library nil t)
  (autoload 'gdev-sposta-testo-su library nil t))
(register-definition-prefixes "gdev-sposta-testo" '("gdev-sposta-testo-"))

(provide 'gdev-sposta-testo-autoloads)
;;; gdev-sposta-testo-autoloads.el ends here
