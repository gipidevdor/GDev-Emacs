;;; init.el --- Punto di ingresso di GDev-Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ordine di avvio:
;;
;;   early-init.el                cartelle, raccolta della memoria (garbage
;;                                collection), prima finestra
;;   lisp/                        il nucleo: funzioni di supporto, sistema dei
;;                                moduli, impostazioni predefinite,
;;                                tasto guida (leader)
;;   ~/.config/gdev/init.el       quali moduli sono attivi (blocco gdev!)
;;   ~/.config/gdev/packages.el   pacchetti aggiuntivi
;;   modules/CATEGORY/NAME/       ogni modulo attivo (config.el), nell'ordine
;;                                del blocco
;;   ~/.config/gdev/config.el     impostazioni personali: ultime, così vincono
;;
;; Senza una cartella privata valgono le impostazioni di templates/.
;; Un modulo che non si carica viene segnalato e saltato; avvia Emacs con
;; --debug-init per avere invece la traccia delle chiamate (backtrace).

;;; Code:

(when (version< emacs-version "30.1")
  (error "GDev-Emacs richiede Emacs 30.1 o successivo; questo è %s" emacs-version))

(add-to-list 'load-path (expand-file-name "lisp/" gdev-config-directory))

;; Un errore durante il caricamento del codice compilato di cl-extra
;; impedisce anche a use-package e al cruscotto di funzionare.
(condition-case err
    (require 'cl-extra)
  (setting-constant
   (let* ((library (locate-library "cl-extra"))
          (base (and library (file-name-sans-extension library)))
          (source (and base
                       (cond ((file-readable-p (concat base ".el")) (concat base ".el"))
                             ((file-readable-p (concat base ".el.gz")) (concat base ".el.gz"))))))
     (unless source (signal (car err) (cdr err)))
     (load source nil t t))))

(if (bound-and-true-p gdev-state-startup-issue)
    (display-warning 'gdev
                     (format "Profilo sospeso. %s\nPuoi continuare a modificare file con Emacs. Da terminale usa «gdev stato verifica» e «gdev stato copie»."
                             gdev-state-startup-issue) :error)
  (require 'gdev-lib)        ; utilità, regole dei pacchetti, ricerca dei progetti
  (require 'gdev-modules)    ; gdev!, caricamento dei moduli, file privati
  (require 'gdev-handlers)   ; gestori per linguaggio, registrati dai moduli
  (require 'gdev-env)        ; ambiente della shell salvato
  (require 'gdev-core)       ; predefiniti: velocità, file, cronologia, modifica
  (require 'gdev-keys)       ; tasto guida C-c, linguaggio C-c l, which-key
  (require 'gdev-commands)   ; comandi per file, buffer, finestre e sessioni
  (autoload 'gdev-agent-copy-socket "gdev-agent-interface" nil t)

  (gdev-modules-initialize))

;;; init.el ends here
