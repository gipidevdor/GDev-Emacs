;;; packages.el --- Pacchetti aggiuntivi -*- lexical-binding: t; -*-

;; Pacchetti che GDev-Emacs non include.  `gdev sync' li installa e li
;; mantiene; togli una riga e la sincronizzazione successiva rimuove il
;; pacchetto.
;;
;;   (gdev-package 'rainbow-mode)
;;   (gdev-package 'some-package :vc "https://github.com/someone/some-package")
;;
;; Configurali in config.el con `use-package' (non serve :ensure).

;;; packages.el ends here
