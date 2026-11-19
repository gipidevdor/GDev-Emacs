;;; config.el --- Impostazioni personali -*- lexical-binding: t; -*-

;; Si carica dopo tutti i moduli, quindi ciò che imposti qui ha la meglio.
;; I dati personali (nome, email, host) vanno qui, mai nella copia di lavoro
;; di GDev-Emacs; i segreti vanno nel Portachiavi (Keychain): vedi la sezione
;; sui segreti nel README.
;;
;; Esempi:
;;
;;   (setq user-full-name "Nome Cognome")
;;   (setq gdev-theme-dark 'modus-vivendi
;;         gdev-font-families '("Iosevka Comfy")
;;         gdev-font-height 150)
;;   (setq gdev-macos-modifier-style 'option-meta)   ; tastiera americana
;;   (setq org-directory "~/Documents/org/")
;;   (setq gdev-perl-docsets '("perl~5.42"))
;;
;;   ;; Un tasto tutto tuo in un gruppo del tasto guida (leader):
;;   (gdev-bind gdev-open-map "x" "il mio comando" #'my-command)

;;; config.el ends here
