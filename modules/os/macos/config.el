;;; config.el --- :os macos: tastiera, Finder, Portachiavi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Tastiera.  Comando funziona come in ogni app del Mac: ⌘S
;; salva, ⌘C ⌘X ⌘V copiano, tagliano e incollano, ⌘Z annulla, ⌘F cerca,
;; ⌘O apre un file, ⌘W lo chiude (le scorciatoie sono nel modulo :config
;; default).  Opzione a sinistra è Meta, il tasto dei comandi di
;; Emacs: ⌥X elenca tutti i comandi.  Opzione a destra resta com'è e
;; scrive i caratteri del codice sulla tastiera italiana: [ ] { } @ # ~ `.
;;
;; Chi preferisce Comando come Meta e Opzione per i caratteri su entrambi i
;; lati (senza le scorciatoie del Mac) scrive nel config.el privato
;;   (setq gdev-macos-modifier-style 'command-meta)
;;
;; Credenziali.  auth-source interroga il Portachiavi di macOS,
;; così chiavi API, chiavi d'accesso e password non stanno mai in
;; un file:
;;   security add-internet-password -a UTENTE -s HOST -w
;;
;;   C-c o o    mostra nel Finder il file corrente (o la cartella di Dired)
;;   C-c o O    aprilo con la sua applicazione predefinita

;;; Code:

(require 'gdev-lib)
(require 'gdev-command-context)
(defvar ns-pop-up-frames)
(defvar ns-use-native-fullscreen)
(defvar ns-use-mwheel-momentum)
(defvar ns-use-proxy-icon)
(defvar ns-use-mwheel-momentum)
(defvar ns-use-native-fullscreen)
(defvar ns-pop-up-frames)

(defgroup gdev-macos nil
  "Integrazione con macOS."
  :group 'gdev)

(defcustom gdev-macos-modifier-style 'mac
  "Stabilisce come i tasti modificatori di macOS diventano quelli di Emacs.
`mac': Comando (Command) dà le scorciatoie del Mac (⌘S, ⌘C, ⌘V...),
  Opzione (Option) a sinistra è Meta, Opzione a destra digita i caratteri
  della tastiera italiana.  È il valore predefinito.
`command-meta': Comando è Meta, Opzione digita caratteri su entrambi i
  lati; niente scorciatoie del Mac.
Il vecchio valore `option-meta' vale come `mac'."
  :type '(choice (const :tag "Come su Mac" mac)
                 (const :tag "Comando come Meta" command-meta)))

(defvar mac-command-modifier)
(defvar mac-right-command-modifier)
(defvar mac-option-modifier)
(defvar mac-right-option-modifier)

(defun gdev-macos-apply-modifiers ()
  "Applica `gdev-macos-modifier-style'."
  (pcase gdev-macos-modifier-style
    ('command-meta
     (setq mac-command-modifier 'meta
           mac-right-command-modifier 'meta
           mac-option-modifier 'none
           mac-right-option-modifier 'none))
    (_
     (setq mac-command-modifier 'super
           mac-right-command-modifier 'super
           mac-option-modifier 'meta
           mac-right-option-modifier 'none))))


;; Il modulo AppKit applica nome e icona ai dialoghi nativi e viene compilato
;; con clang, incluso negli strumenti da riga di comando di Xcode.
(declare-function gdev-macos--set-application-icon "gdev-macos-icon")

(defun gdev-macos--set-icon ()
  "Applica il nome e l'icona di GDev dopo il caricamento del modulo AppKit."
  (unless (gdev-macos--set-application-icon (gdev-config-file gdev-application-icon))
    (error "Immagine GDev non caricata")))

(defun gdev-macos--load-icon-module ()
  "Carica il modulo AppKit o lo ricompila senza bloccare la prima finestra."
  (let* ((source (gdev-config-file "bin/gdev-macos-icon.m"))
         (include (expand-file-name "../include/" data-directory))
         (header (expand-file-name "emacs-module.h" include))
         (directory (gdev-state-file "native-modules/"))
         (module (expand-file-name (concat "icon-" emacs-version "-" system-configuration
                                           module-file-suffix)
                                   directory)))
    (if (or (file-newer-than-file-p source module)
            (and (file-readable-p header) (file-newer-than-file-p header module)))
        (progn
          (make-directory directory t)
          (let* ((default-directory directory)
                 (build (make-temp-file (expand-file-name "icon-" directory) t))
                 (temporary (expand-file-name (concat "icona" module-file-suffix) build))
                 (output (generate-new-buffer " *gdev-icon-build*"))
                 process)
            (unwind-protect
                (setq process
                      (make-process
                       :name "gdev-icon-build" :buffer output :noquery t :connection-type 'pipe
                       :command (list "/usr/bin/clang" "-bundle" "-fobjc-arc" "-framework" "AppKit"
                                      "-I" include source "-o" temporary)
                       :sentinel
                       (lambda (child _event)
                         (when (memq (process-status child) '(exit signal failed))
                           (unwind-protect
                               (condition-case err
                                   (progn
                                     (unless (and (eq (process-status child) 'exit)
                                                  (zerop (process-exit-status child)))
                                       (error "%s" (with-current-buffer output (string-trim (buffer-string)))))
                                     (rename-file temporary module t)
                                     (module-load module)
                                     (gdev-macos--set-icon))
                                 (error (message "Aspetto GDev-Emacs: %s" (error-message-string err))))
                             (kill-buffer output)
                             (delete-directory build t))))))
              (unless process
                (kill-buffer output)
                (delete-directory build t)))))
      (module-load module)
      (gdev-macos--set-icon))))

(defun gdev-macos--apply-application-icon (&optional frame)
  "Applica nome e icona di GDev alla prima finestra grafica macOS."
  (when (eq (framep (or frame (selected-frame))) 'ns)
    (remove-hook 'after-make-frame-functions #'gdev-macos--apply-application-icon)
    (remove-hook 'gdev-after-init-hook #'gdev-macos--apply-application-icon)
    (condition-case err
        (if (fboundp 'gdev-macos--set-application-icon)
            (gdev-macos--set-icon)
          (gdev-macos--load-icon-module))
      (error (message "Aspetto GDev-Emacs: %s" (error-message-string err))))))

(when gdev-macos-p
  ;; Dopo il config.el privato, così vale lo stile scelto lì.
  (add-hook 'gdev-after-init-hook #'gdev-macos-apply-modifiers)
  (add-hook 'gdev-after-init-hook #'gdev-macos--apply-application-icon)
  (add-hook 'after-make-frame-functions #'gdev-macos--apply-application-icon)
  (setq
   ;; I file aperti dal Finder vanno nella finestra di sistema (frame) già
   ;; aperta, non in una nuova.
   ns-pop-up-frames nil
   ;; A tutto schermo nativo Emacs ha un suo Spazio, come le altre app.
   ns-use-native-fullscreen t
   ;; Scorrimento con inerzia dal trackpad.
   ns-use-mwheel-momentum t
   ;; Niente icona del file nella barra del titolo: costa una ricerca a ogni
   ;; cambio di buffer.
   ns-use-proxy-icon nil)
  ;; I file eliminati vanno nel Cestino, da cui il Finder può ripristinarli.
  (unless (fboundp 'system-move-file-to-trash)
    (setq trash-directory (expand-file-name "~/.Trash")))
  ;; Credenziali prima dal Portachiavi; in alternativa da un file cifrato.
  (setq auth-sources '(macos-keychain-internet macos-keychain-generic "~/.authinfo.gpg")))

(defvar ns-use-proxy-icon)

;;;; Finder

(defun gdev-macos--current-file ()
  "Restituisce il file o la cartella a cui si riferisce la vista corrente.
È la riga di Esplora file o di Dired, il documento o la cartella della vista."
  (or (gdev-command-file) (expand-file-name default-directory)))

(defun gdev-macos-reveal-in-finder (&optional file)
  "Mostra FILE nel Finder, o il file della vista corrente.
Senza FILE, in Esplora file e in Dired mostra la voce della riga."
  (interactive)
  (let ((file (or file (gdev-macos--current-file))))
    (when (file-remote-p file) (user-error "%s è su una macchina remota" file))
    (call-process "open" nil 0 nil "-R" file)))

(defun gdev-macos-open-externally ()
  "Apre il file corrente con la sua applicazione predefinita.
In Dired apre il file sotto il cursore."
  (interactive)
  (let ((file (gdev-macos--current-file)))
    (when (file-remote-p file) (user-error "%s è su una macchina remota" file))
    (call-process "open" nil 0 nil file)))

;;; config.el ends here
