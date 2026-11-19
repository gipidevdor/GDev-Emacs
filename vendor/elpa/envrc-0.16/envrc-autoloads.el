;;; -*- no-byte-compile: t; lexical-binding: t; -*-
(add-to-list 'load-path (directory-file-name (or (file-name-directory #$) (car load-path))))
(autoload 'envrc-mode "envrc" nil t)
(autoload 'envrc-allow "envrc" nil t)
(autoload 'envrc-deny "envrc" nil t)
(autoload 'envrc-reload "envrc" nil t)
(autoload 'envrc-show-log "envrc" nil t)
(provide 'envrc-autoloads)
