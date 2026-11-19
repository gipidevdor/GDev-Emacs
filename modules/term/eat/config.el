;;; config.el --- :term eat: emulatore di terminale veloce dentro Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Eat è un emulatore di terminale scritto in Emacs Lisp, abbastanza veloce
;; per i programmi a schermo intero (htop, less, l'interfaccia a riga di
;; comando di Claude Code) e senza bisogno di moduli compilati.
;;
;;   C-c o t    riprendi il terminale del progetto
;;   C-c o n    apri un nuovo terminale del progetto
;;   C-c o p    scegli il profilo del nuovo terminale
;;   C-c o s    affianca un terminale a quello attivo
;;   C-c o ]    passa all'altro terminale affiancato
;;   C-c o T    apri un nuovo terminale nella cartella corrente
;;
;; Nel terminale la modalità predefinita è semi-char: i tasti di Emacs
;; funzionano ancora.  C-c C-e passa ogni tasto al programma, C-c C-j torna
;; a scrivere la riga con i comandi di Emacs.  Anche Eshell esegue con Eat i
;; suoi comandi a schermo intero.

;;; Code:

(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-workspace-roots)

(defgroup gdev-term nil
  "Terminali integrati di GDev."
  :group 'gdev)

(defcustom gdev-term-profiles nil
  "Profili aggiuntivi per l'interprete dei comandi.
Ogni voce contiene un nome, un programma e i suoi argomenti.
Per esempio (\"Bash di accesso\" \"/bin/bash\" \"--login\").
I nomi devono essere distinti. Un profilo può indicare anche un programma
disponibile soltanto sulla macchina remota del progetto."
  :type '(repeat (list :tag "Profilo" (string :tag "Nome")
                       (string :tag "Programma")
                       (repeat :inline t (string :tag "Argomento"))))
  :group 'gdev-term)

(defconst gdev-term--local-shells '("zsh" "bash" "fish" "sh" "ksh" "tcsh" "nu" "pwsh"))

(use-package eat
  :ensure t
  :commands (eat eat-other-window)
  :hook (eshell-load . eat-eshell-mode)
  :custom
  (eat-buffer-name "*Terminale*")
  ;; Il database del terminale di macOS e degli host SSH conosce xterm.
  (eat-term-name "xterm-256color")
  (eat-kill-buffer-on-exit t)
  (eat-enable-yank-to-terminal t)
  ;; Integrazione con l'interprete dei comandi (shell): la richiesta
  ;; (prompt) comunica la cartella, così Emacs segue cd, e C-c C-p / C-c C-n
  ;; saltano da un comando all'altro.
  (eat-enable-directory-tracking t)
  (eat-term-scrollback-size (* 4 1024 1024)))

(defvar eat-buffer-name)
(declare-function eat-make "ext:eat" (name program &optional startfile &rest switches))
(defvar-local gdev-term--project-root nil)
(defvar-local gdev-term--profile nil)

(defun gdev-term--current-project-root ()
  "Restituisci la radice di progetto del gruppo editor attivo."
  (file-name-as-directory
   (expand-file-name
    (or (bound-and-true-p project-current-directory-override)
        (gdev-workspace-directory)
        (gdev-project-root
         (buffer-local-value 'default-directory (window-buffer (gdev-layout-editor))))))))

(defun gdev-term--project-session-name (root profile)
  "Crea un nome univoco nella radice ROOT per PROFILE."
  (let* ((directory (file-name-nondirectory (directory-file-name root)))
         (base (concat "Terminale · " (if (string-empty-p directory) root directory)
                       (when profile (concat " · " (car profile)))))
         (name base)
         (number 1))
    (while (get-buffer (concat "*" name "*"))
      (setq name (format "%s (%d)" base (cl-incf number))))
    name))

(defun gdev-term--make-profile-session (name profile)
  "Avvia la sessione Eat NAME con PROFILE senza scegliere un riquadro."
  (if profile
      (apply #'eat-make name (cadr profile) nil (cddr profile))
    (eat-make name "/usr/bin/env" nil "sh" "-c"
              (or explicit-shell-file-name (getenv "ESHELL") shell-file-name))))

(defun gdev-term--check-workspace (frame tab)
  "Verifica che FRAME mostri ancora lo spazio TAB alla ripresa."
  (unless (and (eq frame (selected-frame)) (eq tab (gdev-workspace-state-current frame)))
    (user-error "Lo spazio di lavoro è cambiato. Ripeti il comando del terminale")))

(defun gdev-term--open-project (root &optional profile source)
  "Crea una sessione distinta per ROOT con PROFILE.
Se SOURCE è un riquadro, affiancagli la nuova sessione nella stessa cartella."
  (require 'eat)
  (let* ((default-directory (if source (buffer-local-value 'default-directory (window-buffer source)) root))
         (origin (and source (window-buffer source)))
         (frame (selected-frame))
         (tab (gdev-workspace-state-current frame))
         (name (gdev-term--project-session-name root profile))
         (eat-buffer-name (concat "*" name "*"))
         terminal committed)
    (unwind-protect
        (progn
          (when (and profile (not (executable-find (cadr profile) t)))
            (user-error "Interprete dei comandi non disponibile: %s" (cadr profile)))
          (setq terminal (if (or profile source)
                             (gdev-term--make-profile-session name profile)
                           (eat-other-window nil t)))
          (gdev-term--remember-session terminal root profile)
          (when (or profile source)
            (gdev-term--check-workspace frame tab)
            (if source
                (progn
                  (unless (and (eq source (gdev-layout-panel-window))
                               (eq origin (window-buffer source))
                               (gdev-term-split-available-p source))
                    (user-error "Il terminale di partenza è cambiato"))
                  (select-window (gdev-layout-split-panel origin terminal)))
              (if gdev-layout-mode
                  (if-let* ((window (gdev-layout-show-panel terminal)))
                      (select-window window)
                    (user-error "Allarga la finestra per mostrare il terminale"))
                (pop-to-buffer terminal))))
          (setq committed t)
          terminal)
      (unless committed
        (when-let* ((failed (or terminal (get-buffer eat-buffer-name))))
          (when-let* ((process (get-buffer-process failed)))
            (set-process-query-on-exit-flag process nil))
          (kill-buffer failed))))))

(defun gdev-term--remember-session (terminal root profile)
  "Associa a TERMINAL la radice ROOT e PROFILE, anche per il riavvio."
  (with-current-buffer terminal
    (setq gdev-term--project-root root
          gdev-term--profile profile
          gdev-layout-restore-function #'gdev-term--describe)))

(defun gdev-term--describe ()
  "Descrivi il terminale corrente per ricrearlo dopo un riavvio."
  (when (and gdev-term--project-root (not (file-remote-p default-directory)))
    (list 'terminal :root gdev-term--project-root
          :directory (expand-file-name default-directory)
          :profile gdev-term--profile)))

(defun gdev-term--restore (properties)
  "Ricrea il terminale descritto da PROPERTIES senza mostrarlo.
La radice deve essere una cartella locale e il profilo uno di quelli
ancora configurati o rilevati: la sessione non esegue altri programmi."
  (let* ((root (plist-get properties :root))
         (directory (plist-get properties :directory))
         (profile (plist-get properties :profile))
         (local-directory-p (lambda (path)
                              (and (stringp path) (file-name-absolute-p path)
                                   (not (file-remote-p path)) (file-directory-p path)))))
    (when (and (funcall local-directory-p root)
               (or (null profile) (member profile (gdev-term--profiles root))))
      (require 'eat)
      (let* ((root (file-name-as-directory root))
             (default-directory (file-name-as-directory
                                 (if (funcall local-directory-p directory) directory root)))
             (terminal (gdev-term--make-profile-session
                        (gdev-term--project-session-name root profile) profile)))
        (gdev-term--remember-session terminal root profile)
        terminal))))

(gdev-layout-register-panel-restorer 'terminal #'gdev-term--restore)

(defun gdev-term--profiles (root)
  "Elenca i profili configurati e quelli rilevati localmente per ROOT."
  (let ((default-directory root)
        (profiles (cons (list "Predefinito") gdev-term-profiles)))
    (unless (file-remote-p root)
      (dolist (name gdev-term--local-shells)
        (when-let* (((not (assoc name profiles)))
                    (program (executable-find name)))
          (setq profiles (append profiles (list (list name program)))))))
    profiles))

(defun gdev-term-new ()
  "Apri una nuova sessione del terminale nella radice del progetto."
  (interactive)
  (gdev-term--open-project (gdev-term--current-project-root)))

(defun gdev-term-new-profile ()
  "Scegli l'interprete dei comandi per una nuova sessione del progetto."
  (interactive)
  (let* ((frame (selected-frame))
         (tab (gdev-workspace-state-current frame))
         (root (gdev-term--current-project-root))
         (profiles (gdev-term--profiles root))
         (name (completing-read "Profilo del terminale: " profiles nil t
                                nil nil (caar profiles)))
         (profile (assoc name profiles)))
    (gdev-term--check-workspace frame tab)
    (unless (equal root (gdev-term--current-project-root))
      (user-error "La cartella di progetto è cambiata. Scegli di nuovo il profilo"))
    (gdev-term--open-project root (and (cdr profile) profile))))

(defun gdev-term-split-available-p (&optional window)
  "Indica se si può affiancare il terminale di WINDOW o del pannello attivo."
  (let ((window (or window (gdev-layout-panel-window))))
    (and gdev-layout-mode (window-live-p window)
         (eq (window-parameter window 'gdev-layout-panel) t)
         (buffer-local-value 'gdev-term--project-root (window-buffer window))
         (not (gdev-layout-panel-companion))
         (gdev-layout-panel-split-fits-p))))

(defun gdev-term-split ()
  "Affianca una sessione con cartella e profilo del terminale corrente."
  (interactive)
  (let* ((window (gdev-layout-panel-window))
         (buffer (and window (window-buffer window))))
    (unless (and buffer (buffer-local-value 'gdev-term--project-root buffer))
      (user-error "Apri prima un terminale del progetto nel pannello"))
    (when (gdev-layout-panel-companion)
      (user-error "Sono già visibili due terminali affiancati"))
    (unless (gdev-layout-panel-split-fits-p)
      (user-error "Allarga la finestra per affiancare i terminali"))
    (gdev-term--open-project (buffer-local-value 'gdev-term--project-root buffer)
                             (buffer-local-value 'gdev-term--profile buffer)
                             window)))

(defun gdev-term-split-visible-p ()
  "Indica se due terminali del pannello sono visibili."
  (and gdev-layout-mode (gdev-layout-panel-companion)))

(defun gdev-term-focus-other ()
  "Porta il fuoco all'altro riquadro del terminale affiancato."
  (interactive)
  (unless (gdev-term-split-visible-p)
    (user-error "Affianca prima due terminali nel pannello"))
  (let* ((companion (gdev-layout-panel-companion))
         (window (if (eq (selected-window) companion) (gdev-layout-panel-window) companion)))
    (select-window window)
    (gdev-layout--remember-panel (window-buffer window) t)
    window))

(defun gdev-term-project ()
  "Apri o seleziona il terminale del progetto corrente."
  (interactive)
  (let* ((root (gdev-term--current-project-root))
         (tools (if gdev-layout-mode (gdev-layout--panel-buffers) (buffer-list)))
         (active (and gdev-layout-mode (gdev-workspace-state-get 'gdev-layout-panel-active)))
         (buffer (seq-find (lambda (candidate)
                             (equal root (buffer-local-value 'gdev-term--project-root candidate)))
                           (if (memq active tools) (cons active (remq active tools)) tools))))
    (if buffer
        (if-let* ((window (get-buffer-window buffer)))
            (select-window window)
          (pop-to-buffer buffer))
      (gdev-term--open-project root))))

(defun gdev-term-here ()
  "Apre un nuovo terminale nella cartella corrente."
  (interactive)
  (gdev-term--open-project (file-name-as-directory (expand-file-name default-directory))))

;;; config.el ends here
