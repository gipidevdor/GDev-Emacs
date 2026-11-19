;;; config.el --- :lang web: HTML, modelli, CSS -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Marcatura e stile, senza npm:
;;
;;   - HTML e modelli elaborati dal servizio in rete:
;;     Template Toolkit, Mojolicious, Jinja/Django, modelli Go...  Si aprono
;;     in web-mode, che riconosce i linguaggi incorporati; emmet espande le
;;     abbreviazioni: ul>li*3  C-j
;;   - CSS in css-ts-mode (integrato, con completamento delle proprietà); i
;;     codici colore appaiono nel loro colore
;;   - C-c c f formatta con deno fmt quando Deno è installato
;;
;;   C-c l b    apre questa pagina nel navigatore
;;   C-c l p    affianca l’anteprima HTML del documento
;;   C-c l s    avvia un servizio locale per una cartella (http.server di Python)

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-language-modes)

(defvar css-indent-offset)
(defvar css-base-mode-map)

;;;; HTML e modelli (template)

(use-package web-mode
  :ensure t
  :mode ("\\.html?\\'" "\\.tt2?\\'" "\\.ep\\'" "\\.j2\\'" "\\.jinja2?\\'"
         "\\.djhtml\\'" "\\.mustache\\'" "\\.hbs\\'" "\\.tmpl\\'" "\\.svelte\\'" "\\.vue\\'")
  :custom
  (web-mode-markup-indent-offset 2)
  (web-mode-css-indent-offset 2)
  (web-mode-code-indent-offset 2)
  (web-mode-enable-auto-pairing t)
  (web-mode-enable-css-colorization t)
  (web-mode-enable-current-element-highlight t)
  (web-mode-enable-auto-closing t)
  ;; Il linguaggio di modello di ogni estensione.
  (web-mode-engines-alist '(("template-toolkit" . "\\.tt2?\\'")
                            ("mojolicious" . "\\.ep\\'")
                            ("django" . "\\.\\(j2\\|jinja2?\\|djhtml\\)\\'")
                            ("go" . "\\.tmpl\\'"))))

;; Dalle abbreviazioni alla marcatura: ul>li*3>a  poi C-j.
(use-package emmet-mode
  :ensure t
  :hook ((web-mode html-mode css-base-mode) . emmet-mode)
  :custom (emmet-move-cursor-between-quotes t))

;; #3a7bd5 e rgb(...) appaiono nel loro colore.
(use-package rainbow-mode
  :ensure t
  :hook (css-base-mode web-mode))

;;;; CSS

(setq css-indent-offset 2)
(gdev-language-register-tree-sitter 'css-mode 'css-ts-mode 'css)
(add-to-list 'auto-mode-alist '("\\.css\\'" . css-mode))

;;;; Formattazione con deno fmt

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-web-deno-fmt ()
  "Formatta l'area di testo con deno fmt e il deno.json del progetto."
  (unless (executable-find "deno") (user-error "deno non è installato (brew install deno)"))
  (gdev-format-with-program "deno" "fmt" "--quiet"
                            (concat "--ext=" (if (derived-mode-p 'css-base-mode) "css" "html"))
                            "-"))

(gdev-set-formatter '(web-mode css-base-mode mhtml-mode) #'gdev-web-deno-fmt)
(gdev-set-docsets '(web-mode mhtml-mode) "html" "css" "dom" "http")
(gdev-set-docsets 'css-base-mode "css")
(gdev-doctor-executable "deno" "brew install deno" 'note)

;;;; Navigatore, anteprima e server statico

(autoload 'gdev-web-preview "gdev-web-preview" nil t)

(defun gdev-web-browse ()
  "Apre nel navigatore il file HTML, o l'URL sotto il cursore."
  (interactive)
  (if (and buffer-file-name (string-match-p "\\.html?\\'" buffer-file-name))
      (browse-url-of-file buffer-file-name)
    (call-interactively #'browse-url-at-point)))

(defgroup gdev-web nil
  "Web, JavaScript e TypeScript."
  :group 'gdev)

(defcustom gdev-web-server-port 8000
  "Porta del server di file statici avviato da `gdev-web-serve'."
  :type 'natnum)

(defun gdev-web--port-in-use-p (port)
  "Indica se qualcuno ascolta già su localhost alla PORT."
  (condition-case nil
      (progn (delete-process (make-network-process :name "gdev-porta" :host "127.0.0.1"
                                                   :service port :noquery t))
             t)
    (error nil)))

(defun gdev-web-serve (directory)
  "Serve DIRECTORY via HTTP solo su localhost e la apre nel navigatore.
Usa la libreria standard di Python: non c'è nulla da installare."
  (interactive (list (read-directory-name "Cartella da servire: " (gdev-project-root))))
  ;; Con la porta occupata il server di Python esce, ma il navigatore mostrerebbe
  ;; comunque l'altra applicazione, come se la cartella scelta fosse servita.
  (when (gdev-web--port-in-use-p gdev-web-server-port)
    (user-error "La porta %d è già occupata: cambia gdev-web-server-port o chiudi l'altro server"
                gdev-web-server-port))
  (gdev-compile (gdev-command-line "python3" "-m" "http.server" "--bind" "127.0.0.1"
                                   (number-to-string gdev-web-server-port))
                (format "Servizio HTTP · %s" (abbreviate-file-name (directory-file-name directory))) directory)
  (browse-url (format "http://127.0.0.1:%d/" gdev-web-server-port)))

(gdev-localleader web-mode web-mode-map
  "b" "apri nel navigatore" #'gdev-web-browse
  "p" "affianca anteprima web" #'gdev-web-preview
  "s" "servi una cartella" #'gdev-web-serve)
(gdev-localleader css-mode css-base-mode-map
  "s" "servi una cartella" #'gdev-web-serve)

;;; config.el ends here
