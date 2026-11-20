;;; gdev-core.el --- Impostazioni di base: prestazioni, file, cronologia, scrittura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ciò che ogni modulo dà per scontato, raggruppato per tema: memoria e
;; reattività, file e copie di sicurezza (backup), cronologia, impostazioni
;; di scrittura, il servizio (server) per emacsclient.  Impostazioni
;; integrate più due piccoli pacchetti che rendono piacevole il codice
;; altrui: dtrt-indent (adotta il rientro del file) e ws-butler (toglie gli
;; spazi finali solo dalle righe che hai toccato).

;;; Code:

(require 'gdev-lib)
(require 'gdev-dialog)

(declare-function xref-window-local-history "xref" (&optional new-value))
(declare-function server-running-p "server" (&optional name))
(defvar w32-get-true-file-attributes)
(defvar w32-pipe-read-delay)
(defvar w32-pipe-buffer-size)
(defvar w32-lwindow-modifier)
(defvar w32-pass-lwindow-to-system)
(defvar ffap-machine-p-known)
(defvar auto-revert-avoid-polling)
(defvar auto-revert-check-vc-info)
(defvar auto-revert-verbose)
(defvar global-auto-revert-non-file-buffers)
(defvar savehist-additional-variables)
(defvar savehist-autosave-interval)
(defvar recentf-max-saved-items)
(defvar recentf-auto-cleanup)
(defvar recentf-keep)
(defvar recentf-exclude)
(defvar xref-history-storage)
(defvar xref-search-program)
(defvar auth-source-save-behavior)

;;;; Memoria: raccolta (garbage collection) dopo l'avvio

;; early-init.el ha sospeso la raccolta della memoria durante l'avvio.  Da
;; qui in poi: una soglia generosa (meno raccolte mentre si scrive) più una
;; raccolta secondo la soglia normale durante il lavoro.

(defgroup gdev-core nil
  "Impostazioni di base dell'editor."
  :group 'gdev)

(defcustom gdev-gc-threshold (* 64 1024 1024)
  "Byte allocati tra due raccolte della memoria durante il lavoro normale."
  :type 'integer)

(defun gdev-core--restore-gc ()
  "Applica la politica di raccolta della memoria per il lavoro normale."
  (setq gc-cons-threshold gdev-gc-threshold
        gc-cons-percentage 0.2))

(defun gdev-core--schedule-gc-restore ()
  "Ripristina la raccolta della memoria al primo momento di inattività.
La prima raccolta dopo l'avvio è la più lunga (raccoglie tutto ciò che
l'avvio ha allocato): così avviene dopo che la finestra è pronta, non prima."
  (run-with-idle-timer 1 nil #'gdev-core--restore-gc))

(add-hook 'emacs-startup-hook #'gdev-core--schedule-gc-restore 90)

;;;; Primo file aperto

(defvar gdev-first-file-hook nil
  "Funzioni eseguite una sola volta, all'apertura del primo file o cartella.
Qui partono le modalità globali che servono solo nei buffer di file (righe
modificate, ortografia, .editorconfig): avviarli all'avvio lo
allungherebbe senza alcun vantaggio.  Il gancio (hook) gira prima che il
file scelga la sua modalità principale, quindi anche quel file ne
beneficia.")

(defun gdev-core--run-first-file-hook (&rest _)
  "Esegue `gdev-first-file-hook' e si disattiva."
  (advice-remove 'after-find-file #'gdev-core--run-first-file-hook)
  (remove-hook 'dired-mode-hook #'gdev-core--run-first-file-hook)
  (run-hooks 'gdev-first-file-hook))

(advice-add 'after-find-file :before #'gdev-core--run-first-file-hook)
(add-hook 'dired-mode-hook #'gdev-core--run-first-file-hook -90)

;;;; Reattività

(setq
 ;; I server di linguaggio mandano messaggi JSON grandi: si leggono a
 ;; blocchi ampi.
 read-process-output-max (* 4 1024 1024)
 process-adaptive-read-buffering nil
 ;; Il testo da destra a sinistra costa tempo su ogni riga; il codice va da
 ;; sinistra a destra.
 bidi-inhibit-bpa t
 ;; Scorrimento: ridisegna meno e colora solo ciò che resta visibile.
 fast-but-imprecise-scrolling t
 redisplay-skip-fontification-on-input t
 jit-lock-defer-time 0
 ;; Nessun lavoro nelle finestre che non hanno il fuoco.
 highlight-nonselected-windows nil
 ;; Il confronto con auto-mode-alist è più veloce se distingue le maiuscole.
 auto-mode-case-fold nil
 ;; Mai interrogare un nome di host solo perché è sotto il cursore.
 ffap-machine-p-known 'reject)

(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right
              ;; Locale a ogni buffer: `setq' varrebbe solo per quello corrente.
              cursor-in-non-selected-windows nil)

;; L'apertura degli argomenti da riga di comando precede `emacs-startup-hook'.
;; Proteggi anche il primo file dalle righe troppo lunghe, prima che venga
;; scelta la sua modalità principale.
(add-hook 'gdev-first-file-hook #'global-so-long-mode -90)

;; Il lampeggio del cursore impone un ridisegno due volte al secondo.
(blink-cursor-mode -1)

;;;; Codifica

(prefer-coding-system 'utf-8)
(setq locale-coding-system 'utf-8)

;;;; File: copie di sicurezza, salvataggi automatici, blocchi, ricarica

(setq
 ;; Copie di sicurezza (backup) numerate, tutte nella cartella di stato.
 backup-directory-alist `(("." . ,(gdev-state-file "backups/")))
 backup-by-copying t
 version-control t
 delete-old-versions t
 kept-new-versions 6
 kept-old-versions 2
 ;; Anche i salvataggi automatici vanno nella cartella di stato.
 auto-save-file-name-transforms `((".*" ,(gdev-state-file "auto-save/") t))
 auto-save-list-file-prefix (gdev-state-file "auto-save/sessions-")
 kill-buffer-delete-auto-save-files t
 ;; I file di blocco (.#name) confondono chi osserva i file e gli strumenti
 ;; di compilazione.
 create-lockfiles t
 ;; La configurazione è una copia di lavoro Git raggiunta da un collegamento
 ;; simbolico: lo segue senza chiedere.
 vc-follow-symlinks t
 require-final-newline t
 large-file-warning-threshold (* 100 1024 1024)
 ;; Eliminare un file lo sposta nel cestino di sistema, da cui si recupera.
 delete-by-moving-to-trash t
 ;; Emacs legge le credenziali dal Portachiavi (Keychain), vedi os/macos, e
 ;; non le scrive mai su file.
 auth-source-save-behavior nil)

(gdev-make-private-directory (gdev-state-file "auto-save/"))

;; I file con segreti (.env, chiavi, credenziali) non lasciano testo né in
;; copie di sicurezza né in salvataggi automatici, che stanno in chiaro su disco.
(setq backup-enable-predicate
      (lambda (name)
        (and (normal-backup-enable-predicate name)
             (not (gdev-sensitive-file-p name)))))

(defun gdev-core--protect-sensitive-file ()
  "Disattiva il salvataggio automatico nel buffer di un file con segreti."
  (when (and buffer-file-name (gdev-sensitive-file-p buffer-file-name))
    (auto-save-mode -1)))

(add-hook 'find-file-hook #'gdev-core--protect-sensitive-file)

(defun gdev-core--make-auto-save-file-name (make-name)
  "Usa MAKE-NAME, con un hash per i nomi troppo lunghi generati da GDev."
  (let ((name (funcall make-name))
        (directory (gdev-state-file "auto-save/")))
    (if (and buffer-file-name
             (equal auto-save-file-name-transforms `((".*" ,directory t)))
             (equal (file-name-directory name) directory)
             ;; Conta la forma già convertita da Emacs, con i delimitatori
             ;; e gli eventuali punti esclamativi raddoppiati.
             (> (string-bytes
                 (encode-coding-string (file-name-nondirectory name)
                                       (or file-name-coding-system
                                           default-file-name-coding-system
                                           'utf-8)))
                255)
             ;; Conserva i salvataggi esistenti sui volumi che li ammettono.
             (not (file-exists-p name)))
        (let ((auto-save-file-name-transforms `((".*" ,directory sha256))))
          (funcall make-name))
      name)))

(advice-add 'make-auto-save-file-name :around #'gdev-core--make-auto-save-file-name)

;; Mai copiare file remoti o privilegiati (spesso segreti, per esempio
;; /etc/shadow aperto con sudo) in copie di sicurezza locali.
(setq backup-enable-predicate
      (lambda (name)
        (and (normal-backup-enable-predicate name)
             (not (file-remote-p name)))))

;; Ricarica i file cambiati su disco da un cambio di ramo (git checkout),
;; dal formattatore o dalla compilazione.  Usa le notifiche dei file
;; (kqueue/inotify), non l'interrogazione periodica (polling).
(setq auto-revert-avoid-polling t
      auto-revert-check-vc-info nil
      auto-revert-verbose nil
      global-auto-revert-non-file-buffers t)
(add-hook 'emacs-startup-hook #'global-auto-revert-mode)

;; Questo percorso identifica le preferenze gestite dal profilo e permette
;; di importare un precedente custom.el al primo avvio.
(setq custom-file (gdev-state-file "custom.el"))

;;;; Cronologia e posizioni

(setq history-length 1000
      history-delete-duplicates t
      savehist-additional-variables '(search-ring regexp-search-ring
                                      compile-command
                                      gdev-program-history
                                      gdev-program-arguments-history)
      savehist-autosave-interval 300)
(add-hook 'emacs-startup-hook #'savehist-mode)

(add-hook 'emacs-startup-hook #'save-place-mode)

;; File recenti.  Le voci remote restano senza verificare che esistano
;; ancora: la verifica aprirebbe una connessione TRAMP per ogni voce.
(setq recentf-max-saved-items 500
      recentf-auto-cleanup 'never
      recentf-keep '(file-remote-p file-readable-p)
      recentf-exclude (list "/elpa/" "/eln-cache/" "COMMIT_EDITMSG\\'"
                            (regexp-quote (expand-file-name gdev-state-directory))))
(add-hook 'emacs-startup-hook #'recentf-mode)

;; La disposizione delle finestre si può annullare: C-c w u / C-c w U.
(add-hook 'emacs-startup-hook #'winner-mode)
(autoload 'winner-undo "winner" nil t)
(autoload 'winner-redo "winner" nil t)

;;;; Scrittura di tutti i giorni

(setq-default indent-tabs-mode nil
              fill-column 100
              truncate-lines t)

(add-hook 'text-mode-hook #'visual-line-mode)

(defun gdev-core--enable-precision-scroll ()
  "Abilita lo scorrimento di precisione nelle sessioni grafiche."
  (when (display-graphic-p)
    (pixel-scroll-precision-mode 1)))

(add-hook 'after-make-frame-functions
          (lambda (frame)
            (with-selected-frame frame (gdev-core--enable-precision-scroll))))
(add-hook 'window-setup-hook #'gdev-core--enable-precision-scroll)

(setq
 use-short-answers nil
 confirm-kill-emacs #'y-or-n-p
 ring-bell-function #'ignore
 sentence-end-double-space nil
 kill-do-not-save-duplicates t
 save-interprogram-paste-before-kill t
 enable-recursive-minibuffers t
 ;; M-x nasconde i comandi che non valgono nella modalità corrente.
 read-extended-command-predicate #'command-completion-default-include-p
 help-window-select t
 uniquify-buffer-name-style 'forward
 ;; Scorrimento riga per riga; il cursore resta fermo sullo schermo.
 scroll-conservatively 101
 scroll-margin 0
 scroll-preserve-screen-position t
 mouse-wheel-scroll-amount '(2 ((shift) . hscroll))
 mouse-wheel-progressive-speed nil
 ;; Niente completamento ispell, che text-mode aggiunge di serie (Emacs 30).
 text-mode-ispell-word-completion nil
 show-paren-context-when-offscreen 'overlay
 show-paren-delay 0.05)

(add-hook 'emacs-startup-hook #'delete-selection-mode)
(add-hook 'emacs-startup-hook #'minibuffer-depth-indicate-mode)
;; Ripete l'ultimo comando di una famiglia con un solo tasto (es. C-x o o o).
(add-hook 'emacs-startup-hook #'repeat-mode)
;; Menu al clic destro nelle finestre di sistema (frame) grafiche.
(add-hook 'emacs-startup-hook #'context-menu-mode)
;; I file .editorconfig fissano rientri e spazi per progetto.
(add-hook 'gdev-first-file-hook #'editorconfig-mode)

;; Annullamenti più profondi: i 160 KB predefiniti non bastano per una
;; ristrutturazione del codice (refactoring).
(setq undo-limit (* 64 1024 1024)
      undo-strong-limit (* 96 1024 1024)
      undo-outer-limit (* 256 1024 1024))

;; Inserisce il delimitatore di chiusura.  I buffer Lisp usano paredit.
(add-hook 'prog-mode-hook #'electric-pair-local-mode)

;; Nei linguaggi simili al C ci si sposta per sotto-parole dentro gli
;; identificatori CamelCase.
(dolist (hook '(c-ts-base-mode-hook js-base-mode-hook typescript-ts-base-mode-hook))
  (add-hook hook #'subword-mode))

;; Adotta il rientro dei file il cui progetto non ha un .editorconfig.  Le
;; impostazioni esplicite (variabili locali al file, editorconfig) vincono
;; sempre.
(use-package dtrt-indent
  :ensure t
  :hook (emacs-startup . dtrt-indent-global-mode)
  :custom (dtrt-indent-verbosity 0))

;; Toglie gli spazi finali solo dalle righe modificate: il codice altrui non
;; riceve mai differenze (diff) fatte di soli spazi.
(use-package ws-butler
  :ensure t
  :hook ((prog-mode conf-mode) . ws-butler-mode))

;;;; Documentazione al cursore e riferimenti incrociati (integrati)

(setq eldoc-echo-area-use-multiline-p nil ; una riga: l'area messaggi non salta
      ;; Il valore di Emacs: con Eglot ogni pausa invia descrizione, firma,
      ;; evidenziazione e azioni al server; una pausa più breve li manda
      ;; anche mentre si scrive.
      eldoc-idle-delay 0.5
      ;; Ogni finestra ha la sua cronologia di M-, come la scheda di un editor.
      xref-history-storage #'xref-window-local-history
      xref-search-program (if (executable-find "rg") 'ripgrep 'grep))

;;;; Strumenti locali al progetto in ogni file aperto

(add-hook 'find-file-hook #'gdev-use-project-tools 90)

;;;; Server: emacsclient, $EDITOR, messaggi di registrazione (commit) Git, agenti

(defvar gdev-active-profile)            ; early-init.el
(defvar server-name)
(defvar server-socket-dir)

(defun gdev-core-start-server ()
  "Avvia il server di Emacs, se non ne è già attivo uno.
Con un profilo il server ha il nome del profilo e i processi figli lo
raggiungono con EMACS_SOCKET_NAME."
  (require 'server)
  (when (equal server-name "server")
    (setq server-name (gdev-profile-server-name (bound-and-true-p gdev-active-profile))))
  (unless (or (daemonp) (server-running-p))
    (server-start)
    (when (bound-and-true-p gdev-active-profile)
      (setenv "EMACS_SOCKET_NAME" (expand-file-name server-name server-socket-dir)))))

(add-hook 'emacs-startup-hook
          (lambda () (run-with-idle-timer 1 nil #'gdev-core-start-server)))

;;;; Windows (seconda fase)

(when gdev-windows-p
  (setq w32-get-true-file-attributes nil  ; evita lente letture dei proprietari NTFS
        w32-pipe-read-delay 0             ; uscita dei sottoprocessi più rapida
        w32-pipe-buffer-size (* 64 1024)
        w32-lwindow-modifier 'super
        w32-pass-lwindow-to-system nil))

;;;; Resoconto dell'avvio

(defun gdev-core--report-startup ()
  "Mostra quanto è durato l'avvio e quante raccolte della memoria ha richiesto."
  (message "gdev ▸ pronto in %s s · %d raccolt%s della memoria"
           (string-replace "." "," (emacs-init-time "%.2f"))
           gcs-done (if (= gcs-done 1) "a" "e")))
(add-hook 'emacs-startup-hook #'gdev-core--report-startup 100)

;;;; Preferenze salvate

;; Dopo i valori predefiniti del nucleo, così le scelte fatte con Customize o
;; con le Preferenze li sostituiscono; il config.el privato resta l'ultimo.
(require 'gdev-custom-db)
(require 'gdev-scoped-options)
(declare-function gdev-state-db-auto-backup "gdev-state-db-maintenance" ())
(declare-function gdev-state-db-exit-backup "gdev-state-db-maintenance" ())
(gdev-custom-db-load)
(unless noninteractive
  (autoload 'gdev-state-db-auto-backup "gdev-state-db-maintenance")
  (autoload 'gdev-state-db-exit-backup "gdev-state-db-maintenance")
  (defvar gdev-state-db-backup-timer nil)
  (unless (timerp gdev-state-db-backup-timer)
    (setq gdev-state-db-backup-timer (run-with-idle-timer 15 t #'gdev-state-db-auto-backup)))
  (add-hook 'kill-emacs-hook #'gdev-state-db-exit-backup 99))

(provide 'gdev-core)
;;; gdev-core.el ends here
