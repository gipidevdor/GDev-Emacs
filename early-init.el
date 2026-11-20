;;; early-init.el --- GDev-Emacs: prima dei pacchetti e delle finestre -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Emacs legge questo file prima di inizializzare il sistema dei pacchetti e
;; prima di creare la prima finestra di sistema (frame) grafica.  Ogni
;; impostazione qui ha uno di tre motivi:
;;
;;   1. velocità di avvio: raccolta della memoria (garbage collection),
;;      gestori dei file, codice nativo;
;;   2. un archivio Git (repository) pulito: lo stato di esecuzione sta fuori
;;      dalla copia di lavoro;
;;   3. nessuno sfarfallio: le decorazioni della finestra sono decise prima
;;      che la finestra esista.
;;
;; Il lettore dello stato usa il supporto SQLite incluso in Emacs.

;;; Code:

;;;; Raccolta della memoria (garbage collection) durante l'avvio

;; L'avvio alloca molti oggetti di vita breve.  Raccogliere la memoria durante
;; quella raffica è lavoro sprecato, quindi la soglia si alza finché
;; l'inizializzazione non termina.  Poi `gdev-core' ripristina una regola
;; ragionevole per l'uso normale.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 1.0)

;;;; Gestori dei nomi di file (file-name handlers)

;; `load' consulta `file-name-handler-alist' (TRAMP, file compressi...) per
;; ogni file che apre.  L'avvio legge solo file locali, quindi fino alla fine
;; dell'inizializzazione resta solo il gestore dei file compressi .el.gz.
(defvar gdev--saved-file-name-handler-alist file-name-handler-alist
  "Valore di `file-name-handler-alist' prima che l'avvio lo riducesse.")

(unless (or noninteractive (daemonp))
  (setq file-name-handler-alist
        (list (rassq 'jka-compr-handler file-name-handler-alist)))
  (add-hook 'emacs-startup-hook
            (lambda ()
              ;; Riunisce i due elenchi, senza perdere i gestori registrati
              ;; durante l'avvio.
              (setq file-name-handler-alist
                    (delete-dups (append file-name-handler-alist
                                         gdev--saved-file-name-handler-alist))))
            101))

;;;; Dove stanno i file

(defconst gdev-config-directory
  (file-name-directory (file-truename (or load-file-name buffer-file-name)))
  "La copia di lavoro (checkout) di GDev-Emacs: solo configurazione, in Git.")

(defun gdev--xdg-directory (environment-variable fallback leaf)
  "Restituisce LEAF in $ENVIRONMENT-VARIABLE, o in FALLBACK se non impostata."
  (file-name-as-directory
   (expand-file-name leaf (or (getenv environment-variable)
                              (if (eq system-type 'windows-nt)
                                  (getenv "LOCALAPPDATA")
                                fallback)))))

(defconst gdev-active-profile
  (when-let* ((name (getenv "GDEV_PROFILE")))
    (unless (and (string-match "^[[:alnum:]_-]+$" name)
                 (= (match-end 0) (length name))
                 (= (match-beginning 0) 0))
      (error "Nome profilo non valido: %s" name))
    name)
  "Profilo nominato chiesto dal lanciatore, o nil per il profilo abituale.")

(defun gdev--profile-directory (directory)
  "Restituisci DIRECTORY per il profilo attivo."
  (if gdev-active-profile
      (file-name-as-directory (expand-file-name (concat "profiles/" gdev-active-profile) directory))
    directory))

(defconst gdev-state-directory
  (gdev--profile-directory
   (or (and (getenv "GDEV_STATE_DIR")
            (file-name-as-directory (expand-file-name (getenv "GDEV_STATE_DIR"))))
       (gdev--xdg-directory "XDG_STATE_HOME" "~/.local/state" "gdev-emacs")))
  "Cartella dei dati di Emacs: pacchetti, cache, cronologia, codice nativo.
Contiene anche preferenze, sessioni e bozze. Salvale prima di rimuoverla. Imposta
GDEV_STATE_DIR per un'istanza isolata (test, CI, esperimenti).")

(defconst gdev-tools-directory
  (or (and (getenv "GDEV_TOOLS_DIR")
           (file-name-as-directory (expand-file-name (getenv "GDEV_TOOLS_DIR"))))
      (gdev--xdg-directory "XDG_DATA_HOME" "~/.local/share" "gdev-emacs"))
  "Programmi esterni di supporto, installati dallo script di preparazione.")

(defconst gdev-user-directory
  (gdev--profile-directory
   (or (and (getenv "GDEV_USER_DIR")
            (file-name-as-directory (expand-file-name (getenv "GDEV_USER_DIR"))))
       (gdev--xdg-directory "XDG_CONFIG_HOME" "~/.config" "gdev")))
  "Configurazione privata: init.el (moduli), packages.el, config.el.
Sta fuori dalla copia di lavoro: aggiornare GDev non la tocca mai e può
vivere in un repository tutto suo.  `gdev install' la crea da templates/.")

;; La "casa" di Emacs diventa la cartella di stato: ogni pacchetto che
;; scrive tramite `locate-user-emacs-file' (cronologia, cache, cartella dei
;; pacchetti, ...) scrive lì e mai nella copia di lavoro.  Emacs carica
;; comunque init.el dalla cartella originale (`startup-init-directory').
(defun gdev-make-private-directory (directory)
  "Crea DIRECTORY accessibile solo all'utente, o ne stringe i permessi.
Il testo non salvato dei buffer (salvataggi automatici), le copie di
sicurezza e la cronologia stanno qui: con i permessi predefiniti di una
cartella creata da noi, e non da Emacs, resterebbero leggibili dagli altri
utenti del Mac."
  (with-file-modes #o700 (make-directory directory t))
  (ignore-errors (set-file-modes directory #o700)))

(gdev-make-private-directory gdev-state-directory)
(setq user-emacs-directory gdev-state-directory)

;;;; Compilazione nativa

;; Anche il codice nativo compilato in anticipo sta nella cartella di stato.
;; Gli avvisi della compilazione asincrona di codice di terzi qui non si
;; possono risolvere, quindi finiscono in silenzio nel registro invece di
;; aprire una finestra.
(when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
  (startup-redirect-eln-cache (expand-file-name "eln-cache/" gdev-state-directory))
  (setq native-comp-async-report-warnings-errors 'silent
        native-comp-warning-on-missing-source nil
        native-comp-jit-compilation t
        ;; La compilazione asincrona gira in processi `-Q' che non leggono
        ;; questo file: compilando un modulo, `:ensure' vi installerebbe i
        ;; pacchetti dentro la copia di lavoro, e il codice nativo nascerebbe
        ;; senza i pacchetti a disposizione.  `gdev compile --native' prepara
        ;; l'ambiente esplicitamente per compilare GDev in anticipo.
        native-comp-jit-compilation-deny-list
        (list (concat "\\`" (regexp-quote gdev-config-directory))
              (concat "\\`" (regexp-quote (file-name-directory (or load-file-name buffer-file-name))))))
  ;; libgccjit ricava la versione minima di macOS (deployment target) dalla
  ;; versione del kernel Darwin; sulle versioni recenti di macOS ne calcola
  ;; una che clang rifiuta ("-mmacosx-version-min=18.0") e ogni compilazione
  ;; nativa fallisce.  Qui si indica una versione valida (11.0, il macOS più
  ;; vecchio su Apple silicon), prima che si carichi comp.el: così il suo
  ;; valore predefinito non si applica.
  (when (eq system-type 'darwin)
    (setq native-comp-driver-options '("-Wl,-w" "-mmacosx-version-min=11.0"))))

;;;; Sistema dei pacchetti

;; I pacchetti si attivano da un unico file precalcolato ("quickstart")
;; invece di esplorare la cartella di ogni pacchetto: un solo caricamento
;; invece di circa 60.  In un avvio normale `package.el' non si carica
;; nemmeno.
(setq package-user-dir (expand-file-name "elpa/" gdev-state-directory)
      package-gnupghome-dir (expand-file-name "elpa/gnupg/" gdev-state-directory)
      package-quickstart t
      package-native-compile t
      package-enable-at-startup t)

;; Il registro governa l'attivazione, la compilazione e le attribuzioni.
(defconst gdev-bundled-packages
  (with-temp-buffer
    (insert-file-contents (expand-file-name "vendor/pacchetti.el" gdev-config-directory))
    (read (current-buffer)))
  "Pacchetti Lisp inclusi, con versione, licenza, origine e revisione.")

(defconst gdev--bundled-package-directories (make-hash-table :test #'eq)
  "Percorsi dei fork calcolati dal registro al primo utilizzo.")

(defun gdev-bundled-package-directory (name)
  "Restituisce la cartella della versione inclusa di NAME, o nil se assente."
  (or (gethash name gdev--bundled-package-directories)
      (when-let* ((version (cadr (assq name gdev-bundled-packages))))
        (puthash name (expand-file-name (format "vendor/elpa/%s-%s/" name version)
                                        gdev-config-directory)
                 gdev--bundled-package-directories))))

(defun gdev--select-fork-descriptor (descriptor)
  "Conserva DESCRIPTOR se appartiene alla copia GDev o a un pacchetto personale."
  (let* ((name (and descriptor (package-desc-name descriptor)))
         (fork-directory (gdev-bundled-package-directory name)))
    (if (and fork-directory
             (not (equal (file-name-as-directory (expand-file-name (package-desc-dir descriptor)))
                         fork-directory)))
        (let ((entry (assq name package-alist)))
          (setcdr entry (delq descriptor (cdr entry)))
          (unless (cdr entry)
            (setq package-alist (delq entry package-alist)))
          nil)
      descriptor)))

;; La versione da sola non distingue un fork dalla copia omonima di ELPA.
(advice-add 'package-load-descriptor :filter-return #'gdev--select-fork-descriptor)

(defun gdev--activatable-fork (select name)
  "Usa il descrittore locale per NAME. Delega gli altri pacchetti a SELECT."
  (if (gdev-bundled-package-directory name)
      (let ((descriptor (cadr (assq name package-alist))))
        (when (and descriptor (not (package-disabled-p name (package-desc-version descriptor))))
          descriptor))
    (funcall select name)))

;; Emacs preferisce normalmente le proprie librerie, anche a versione pari.
(advice-add 'package--get-activatable-pkg :around #'gdev--activatable-fork)

(defvar find-library-source-path)

(defun gdev--reload-embedded-fork (reload descriptor &optional warn)
  "Rende disponibili le dipendenze locali mentre RELOAD ricarica DESCRIPTOR."
  (if (gdev-bundled-package-directory (package-desc-name descriptor))
      (let ((find-library-source-path (or (bound-and-true-p find-library-source-path) load-path))
            (load-path (cons (package-desc-dir descriptor) load-path)))
        (funcall reload descriptor))
    (funcall reload descriptor warn)))

(advice-add 'package--reload-previously-loaded :around #'gdev--reload-embedded-fork)

(defun gdev--activate-quickstart-seq ()
  "Carica l'implementazione GDev di Seq dopo l'attivazione da quickstart."
  ;; Il file quickstart registra gli autoload, senza ricaricare il Seq
  ;; già presente nel dump di Emacs.
  (when (and (memq 'seq package-activated-list) (not (featurep 'seq-25)))
    (load (expand-file-name "seq" (gdev-bundled-package-directory 'seq)) nil t)))

(advice-add 'package-activate-all :after #'gdev--activate-quickstart-seq)
(defvar package-load-list '(all))
(defvar package-pinned-packages nil)
(add-to-list 'package-directory-list (expand-file-name "vendor/elpa/" gdev-config-directory) t)
(setq package-quickstart-file
      (expand-file-name (format "package-quickstart-%s.el"
                                (substring (secure-hash 'sha256
                                                        (prin1-to-string
                                                         (list 'forks-v4 gdev-config-directory gdev-bundled-packages)))
                                           0 16))
                        gdev-state-directory))
(dolist (package gdev-bundled-packages)
  (add-to-list 'package-load-list (list (car package) (cadr package)))
  ;; Un archivio assente esclude gli aggiornamenti ELPA per le copie locali.
  (add-to-list 'package-pinned-packages (cons (car package) "gdev")))

;; Prima GNU e NonGNU ELPA (curati e firmati); MELPA solo per i pacchetti
;; che non si trovano altrove.
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))

;; Preferisce un .el più recente a un .elc superato.  Costa una lettura dei
;; metadati (stat) in più per ogni caricamento ed evita la classica trappola
;; "ho modificato il file ma non cambia nulla".
(setq load-prefer-newer t)

;;;; Finestra di sistema (frame): tutto deciso prima che esista

;; Ridimensionare la finestra quando cambiano caratteri o barre è lento e
;; causa sfarfallio.
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t
      frame-title-format '("%b — GDev-Emacs"))

;; Niente barra degli strumenti né barre di scorrimento, mai.  Impostare i
;; parametri della finestra (non le modalità) evita di crearle e poi
;; distruggerle.
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(horizontal-scroll-bars) default-frame-alist)
(push '(internal-border-width . 12) default-frame-alist)
(setq tool-bar-mode nil
      scroll-bar-mode nil)

;; macOS mostra la barra dei menu fuori dalla finestra: lì non occupa
;; spazio e resta utile per scoprire i comandi.  Altrove è nascosta.
(unless (eq system-type 'darwin)
  (push '(menu-bar-lines . 0) default-frame-alist)
  (setq menu-bar-mode nil))

;; Avvio a finestra massimizzata: l'editor di lavoro occupa lo schermo.
(push '(fullscreen . maximized) initial-frame-alist)

(add-to-list 'load-path (expand-file-name "lisp" gdev-config-directory))
(require 'gdev-state-db)
(defvar gdev-state-maintenance-startup nil)
(defvar gdev-state-startup-issue nil)

;; Usa lo stesso valore che governa i cambi di tema nella sessione.
(let ((dark (unless gdev-state-maintenance-startup
              (condition-case err (eq (gdev-state-db-appearance) 'dark)
                (error (setq gdev-state-startup-issue (error-message-string err)) nil)))))
  (push `(background-color . ,(if dark "#1e1e20" "#ffffff")) default-frame-alist)
  (when (eq system-type 'darwin)
    (push '(ns-transparent-titlebar . t) default-frame-alist)
    (push `(ns-appearance . ,(if dark 'dark 'light)) default-frame-alist)))

;;;; Schermate di avvio e ridisegno

(setq inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name
      inhibit-default-init t
      initial-scratch-message nil
      ;; I caratteri con molti glifi rallentano la compattazione della loro
      ;; cache.
      inhibit-compacting-font-caches t)

;;; early-init.el ends here
