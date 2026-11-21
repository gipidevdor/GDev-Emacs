;;; config.el --- :config default: la mappa dei tasti, in un solo posto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Tutte le scorciatoie del tasto guida di GDev-Emacs, divise nei gruppi C-c
;; di lisp/gdev-keys.el: C-c a agenti, C-c b aree di testo, C-c c codice e
;; così via. Una scorciatoia che richiede un modulo esiste solo se quel
;; modulo è attivo, così which-key non propone mai un comando che non può
;; funzionare.
;;
;; I tasti funzione seguono la disposizione degli ambienti di sviluppo
;; (IDE), con l'esecuzione passo passo su F5 e F9-F11:
;;
;;   F5  avvia o riprendi          S-F5 termina  C-S-F5 riavvia  C-F5 esegui
;;   F6  test del file            F7   compila  S-F7   configura
;;   F8  errore successivo        S-F8 errore precedente
;;   F9  punto di interruzione    F10  passo successivo   F11 entra   S-F11 esci
;;   F12 definizione              S-F12 riferimenti
;;
;; Senza questo modulo i gruppi restano vuoti e il config.el privato può
;; definire una mappa propria con `gdev-bind'.  docs/keymap.md è generato da
;; queste mappe (`gdev docs').

;;; Code:

(require 'gdev-lib)
(require 'gdev-keys)
(require 'gdev-modules)
(require 'gdev-commands)

(declare-function gdev-lsp-start "../../tools/lsp/config" ())

(defmacro gdev-default--with (category module &rest body)
  "Esegue BODY quando MODULE di CATEGORY è attivo."
  (declare (indent 2))
  `(when (gdev-module-p ,category ',module) ,@body))

;; Le mappe conservano i simboli dei comandi forniti dai moduli attivi.
;; Le definizioni possono caricarsi su richiesta, al primo utilizzo.

;;;; Tasti globali: comportamenti predefiniti migliori

(keymap-global-set "M-/" #'hippie-expand)
(keymap-global-set "C-x k" #'kill-current-buffer)
(keymap-global-set "M-z" #'zap-up-to-char)
(keymap-global-set "M-c" #'capitalize-dwim)
(keymap-global-set "M-l" #'downcase-dwim)
(keymap-global-set "M-u" #'upcase-dwim)
(keymap-global-set "C-x C-z" #'ignore)  ; sospendere Emacs grafico lo nasconde

;; Mantieni la scorciatoia X nelle viste di consultazione, anche quando il
;; modo ha un proprio comando per X.  Nei buffer di testo passa al modo.
(defun gdev-default--close-view-binding (command)
  "Restituisce COMMAND se l'area di testo corrente è una vista di consultazione."
  (when (and buffer-read-only
             (derived-mode-p 'special-mode 'dired-mode 'magit-mode)
             (not (gdev-layout-document-tab-p (current-buffer))))
    command))

(defvar gdev-default--close-buffer-key-enabled t)

(defvar-keymap gdev-default--close-buffer-map
  "X" '(menu-item "Chiudi vista" gdev-close-document :filter gdev-default--close-view-binding))

(defvar gdev-default--close-buffer-maps
  `((gdev-default--close-buffer-key-enabled . ,gdev-default--close-buffer-map)))

(add-to-list 'emulation-mode-map-alists 'gdev-default--close-buffer-maps)

;;;; ⌘ come su Mac

;; Con `gdev-macos-modifier-style' uguale a `mac' (il predefinito, modulo
;; :os macos) il tasto Comando manda Super (s-): queste sono le scorciatoie
;; di ogni app del Mac, e quelle di Xcode per compilare ed eseguire.  Su
;; Linux e Windows Super è il tasto con il logo, quasi sempre preso dal
;; sistema: lì restano C-c e i tasti funzione.

(keymap-global-set "s-n" #'gdev-new-buffer)
(keymap-global-set "s-o" #'gdev-open-file)
(keymap-global-set "s-O" #'gdev-open-folder)
(keymap-global-set "s-s" #'gdev-save-document)
(keymap-global-set "s-S" #'gdev-save-document-as)
(keymap-global-set "M-s-s" #'gdev-save-all-documents)
(keymap-global-set "s-w" #'gdev-close-document)
(keymap-global-set "s-W" #'gdev-close-editor-group)
(keymap-global-set "s-q" #'gdev-quit)
(keymap-global-set "C-x C-c" #'gdev-quit)
(when gdev-macos-p (keymap-global-set "<ns-power-off>" #'gdev-quit))
(keymap-global-set "s-z" #'gdev-undo)
(keymap-global-set "s-y" #'gdev-redo)
(keymap-global-set "s-Z" #'gdev-redo)
;; I comandi di annullamento devono restare gli stessi in tutti i riquadri,
;; anche quando la modalità corrente o le preferenze ridefiniscono il tasto.
(defvar-keymap gdev-undo-shortcut-map
  "s-z" #'gdev-undo
  "s-y" #'gdev-redo
  "s-Z" #'gdev-redo)
(defvar gdev-undo-shortcuts-active t)
(defvar gdev-undo-shortcut-alist
  `((gdev-undo-shortcuts-active . ,gdev-undo-shortcut-map)))
(add-to-list 'emulation-mode-map-alists 'gdev-undo-shortcut-alist)
(keymap-global-set "s-x" #'gdev-cut-dwim)
(keymap-global-set "s-c" #'gdev-copy-dwim)
(keymap-global-set "s-v" #'yank)
(keymap-global-set "s-a" #'mark-whole-buffer)
(keymap-global-set "s-f" #'isearch-forward)
(keymap-global-set "s-g" #'gdev-find-next)
(keymap-global-set "s-G" #'gdev-find-previous)
(keymap-global-set "s-F" #'project-find-regexp)
(keymap-global-set "s-l" #'goto-line)
(keymap-global-set "s-p" #'gdev-quick-open)
(keymap-global-set "s-P" #'gdev-command-palette)
(keymap-global-set "s-," #'gdev-open-private-config)
;; Impostazioni… nel menu dell'app di macOS apre lo stesso comando di ⌘,.
(when gdev-macos-p (keymap-global-set "<ns-show-prefs>" #'gdev-open-private-config))
(keymap-global-set "s-/" #'comment-line)
(keymap-global-set "s-D" #'duplicate-dwim)
(gdev-default--with :editor multiple-cursors
  (keymap-global-set "s-d" #'mc/mark-next-like-this-word))
(keymap-global-set "s-]" #'gdev-indent-right)
(keymap-global-set "s-[" #'gdev-indent-left)
(keymap-global-set "s-=" #'global-text-scale-adjust)
(keymap-global-set "s-+" #'global-text-scale-adjust)
(keymap-global-set "s--" #'global-text-scale-adjust)
(keymap-global-set "s-<up>" #'beginning-of-buffer)
(keymap-global-set "s-<down>" #'end-of-buffer)
(keymap-global-set "s-<left>" #'move-beginning-of-line)
(keymap-global-set "s-<right>" #'move-end-of-line)
(keymap-global-set "s-<backspace>" #'gdev-kill-to-line-start)
(keymap-global-set "s-t" #'tab-bar-new-tab)
(keymap-global-set "s-T" #'gdev-layout-reopen-document)
(keymap-global-set "s-\\" #'gdev-split-editor-right)
(keymap-global-set "s-'" #'gdev-focus-other-editor)
(with-eval-after-load 'isearch
  (keymap-set isearch-mode-map "s-g" #'gdev-find-next)
  (keymap-set isearch-mode-map "s-G" #'gdev-find-previous)
  (keymap-set isearch-mode-map "s-v" #'isearch-yank-kill))
(gdev-default--with :completion vertico
  (keymap-global-set "s-F" #'consult-ripgrep))
(gdev-default--with :tools build
  (keymap-global-set "s-B" 'gdev-build)
  (unless (gdev-module-p :ui 'sidebar)
    (keymap-global-set "s-b" 'gdev-build))
  (keymap-global-set "s-r" 'gdev-run-dwim)
  (keymap-global-set "s-u" 'gdev-test-dwim)
  (keymap-global-set "s-." 'kill-compilation))

;;;; C-c a  agenti

(gdev-default--with :tools llm
  (gdev-bind gdev-agent-map
             "a" "conversazione" #'gptel
             "s" "invia" #'gptel-send
             "r" "riscrivi selezione" #'gptel-rewrite
             "x" "aggiungi al contesto" #'gptel-add
             "f" "aggiungi file al contesto" #'gptel-add-file
             "m" "menu" #'gptel-menu
             "g" "agente" #'gptel-agent
             "k" "interrompi" 'gptel-abort))
(gdev-default--with :tools agent
  (gdev-bind gdev-agent-map
             "o" "Codex" #'gdev-codex
             "O" "riprendi Codex" #'gdev-codex-resume
             "d" "rivedi modifiche del progetto" #'gdev-codex-diff
             "Q" "ferma Codex" #'gdev-codex-stop
             "c" "Claude Code" #'claude-code-ide
             "C" "menu di Claude Code" #'claude-code-ide-menu
             "q" "ferma una sessione di Claude Code…" #'claude-code-ide-stop))

;;;; C-c b  aree di testo

(gdev-bind gdev-buffer-map
           "b" "scegli un'area di testo" #'switch-to-buffer
           "i" "elenca le aree di testo" #'ibuffer
           "k" "chiudi l'area di testo" #'kill-current-buffer
           "K" "chiudi gli altri del progetto" #'project-kill-buffers
           "n" "nuova area di testo" #'gdev-new-buffer
           "t" "riapri l’ultima scheda chiusa" #'gdev-layout-reopen-document
           "x" "apri Appunti" #'gdev-scratch
           "r" "ricarica dal disco" #'gdev-reload-document
           "R" "rinomina" #'rename-buffer
           "s" "salva" #'gdev-save-document
           "S" "salva tutti i file" #'gdev-save-all-documents
           "y" "copia tutto il testo" #'gdev-copy-buffer
           "z" "manda in fondo all'elenco" #'bury-buffer
           "[" "precedente" #'previous-buffer
           "]" "successivo" #'next-buffer
           "m" "imposta segnalibro" #'bookmark-set
           "M" "elimina segnalibro" #'bookmark-delete)

;;;; C-c c  codice

(gdev-bind gdev-code-map
           "c" "compila" #'compile
           "d" "definizione" #'gdev-find-definition
           "D" "riferimenti" #'gdev-find-references
           "j" "altro file (intestazione/sorgente)" #'gdev-find-other-file
           "w" "togli gli spazi a fine riga" #'delete-trailing-whitespace
           "." "area di testo della guida" #'eldoc-doc-buffer
           ";" "commenta riga" #'comment-line)
(gdev-default--with :tools lsp
  (gdev-bind gdev-code-map
             "a" "azioni sul codice" 'gdev-lsp-code-actions
             "r" "rinomina simbolo" 'gdev-lsp-rename
             "i" "vai all'implementazione" 'gdev-lsp-find-implementation
             "t" "vai alla definizione del tipo" 'gdev-lsp-find-type-definition
             "E" "anteprima di estrazione" 'gdev-lsp-extract
             "o" "riordina importazioni" 'gdev-organize-imports
             "q" "correzione rapida" 'gdev-lsp-quick-fix
             "h" "gerarchia delle chiamate" 'gdev-lsp-call-hierarchy
             "H" "gerarchia dei tipi" 'gdev-lsp-type-hierarchy
             "s" "avvia server di linguaggio" #'gdev-lsp-start
             "S" "ferma server di linguaggio" 'eglot-shutdown
             "R" "riconnetti server di linguaggio" 'eglot-reconnect))
(gdev-default--with :editor format
  (gdev-bind gdev-code-map "f" "formatta" 'gdev-format-dwim))
(gdev-default--with :tools eval
  (gdev-bind gdev-code-map "e" "valuta" 'gdev-eval-dwim))
(gdev-default--with :tools lookup
  (gdev-bind gdev-code-map "k" "documentazione" 'gdev-lookup-documentation))
(gdev-default--with :editor fold
  (gdev-bind gdev-code-map
             "z" "piega o espandi" 'hs-toggle-hiding
             "Z" "piega/espandi tutto" 'gdev-fold-toggle-all))
(gdev-default--with :editor multiple-cursors
  (gdev-bind gdev-code-map
             "M" "cursori su tutte le occorrenze" #'mc/mark-all-dwim
             "L" "cursori sulle righe selezionate" #'mc/edit-lines))

;;;; C-c d  esecuzione passo passo

(gdev-default--with :ui workbench
  (gdev-bind gdev-debug-map "W" "debug dello spazio" 'gdev-project-view-run))

(gdev-default--with :tools debugger
  (gdev-bind gdev-debug-map
             "d" "avvia (scegli configurazione)" #'dape
             "b" "punto di interruzione" 'dape-breakpoint-toggle
             "B" "togli tutti i punti di interruzione" 'dape-breakpoint-remove-all
             "e" "punto di interruzione condizionale" 'dape-breakpoint-expression
             "l" "punto di registrazione" 'dape-breakpoint-log
             "h" "interruzione dopo N passaggi" 'dape-breakpoint-hits
             "c" "continua" 'gdev-debug-continue
             "n" "passo successivo" 'gdev-debug-next
             "s" "entra" 'gdev-debug-step-in
             "o" "esci" 'gdev-debug-step-out
             "u" "fino al cursore" 'gdev-debug-until
             "p" "pausa" 'gdev-debug-pause
             "r" "riavvia" 'gdev-debug-restart
             "q" "termina la sessione" 'gdev-debug-terminate
             "k" "termina il processo" 'gdev-debug-kill-process
             "w" "osserva espressione" 'dape-watch-dwim
             "x" "valuta espressione" 'dape-evaluate-expression
             "i" "pannelli informativi" 'dape-info
             "R" "interprete interattivo" 'dape-repl
             "t" "scegli il flusso di esecuzione" 'dape-select-thread
             "f" "livello della pila delle chiamate" 'dape-select-stack
             "<" "livello superiore della pila" 'dape-stack-select-up
             ">" "livello inferiore della pila" 'dape-stack-select-down
             "m" "memoria" 'dape-memory
             "M" "disassembla" 'dape-disassemble
             "a" "collegati a un processo" 'gdev-debug-attach
             "C" "immagine della memoria" 'gdev-debug-core
             "g" "GDB (GUD)" #'gdb)
  (gdev-default--with :ui workbench
    (gdev-bind gdev-debug-map
               "I" "ispeziona la sessione" 'gdev-debug-inspector-show
               "P" "gestisci i punti di interruzione" 'gdev-debug-breakpoints-show))
  (dolist (command '(gdev-debug-continue gdev-debug-next gdev-debug-step-in
                     gdev-debug-step-out gdev-debug-until gdev-debug-pause
                     gdev-debug-restart))
    (put command 'repeat-map 'gdev-debug-map)))

;;;; C-c v  voce

(gdev-bind gdev-voice-map
           "v" "pannello voce" #'gdev-voice-open
           "x" "comando in italiano" #'gdev-voice-execute
           "d" "dettatura" #'gdev-voice-start-dictation
           "c" "comando vocale" #'gdev-voice-start-command
           "l" "leggi testo" #'gdev-voice-read
           "p" "pausa o riprendi lettura" #'gdev-voice-pause
           "s" "interrompi voce" #'gdev-voice-stop
           "i" "scegli voce italiana" #'gdev-voice-select-voice
           "r" "memorizza correzione vocale" #'gdev-voice-learn-correction
           "a" "attiva riconoscimento locale" #'gdev-voice-prepare)

;;;; C-c f  file

(gdev-bind gdev-file-map
           "f" "apri" #'gdev-open-file
           "r" "recenti" #'recentf-open
           "R" "rinomina" #'rename-visited-file
           "D" "elimina" #'gdev-delete-visited-file
           "C" "copia" #'copy-file
           "s" "salva" #'gdev-save-document
           "S" "salva con nome" #'gdev-save-document-as
           "y" "copia nome" #'gdev-copy-file-name
           "l" "copia file:riga" #'gdev-copy-file-location
           "u" "apri come root" #'gdev-sudo-find-file
           "U" "riapri come root" #'gdev-sudo-this-file
           "d" "cartella" #'dired
           "e" ".dir-locals.el del progetto" #'gdev-edit-dir-locals
           "p" "configurazione privata" #'gdev-open-private-config
           "P" "file di GDev-Emacs" #'gdev-find-framework-file)
(gdev-default--with :completion vertico
  (gdev-bind gdev-file-map "r" "recenti" #'consult-recent-file))
(gdev-default--with :ui workbench
  (gdev-bind gdev-file-map "h" "cronologia del file" 'gdev-timeline-open))

;;;; C-c g  Hit e HitHub

(gdev-bind gdev-git-map
           "g" "stato Git" #'gdev-git-status
           "v" "controllo di versione" #'vc-next-action
           "=" "differenze del file (diff)" #'vc-diff)
(gdev-default--with :ui workbench
  (gdev-bind gdev-git-map
             "3" "unisci tre file" 'gdev-merge-files
             "!" "risolvi i conflitti" 'gdev-merge-conflict))
(gdev-default--with :tools git
  (gdev-bind gdev-git-map
             "g" "apri Hit" 'hit-status
             "d" "comandi di Hit" 'hit-comandi
             "f" "comandi di Hit per il file" 'hit-comandi-file
             "B" "autori riga per riga" #'magit-blame-addition
             "L" "cronologia del file" #'magit-log-buffer-file
             "b" "cambia ramo" #'magit-branch-checkout
             "c" "clona" #'magit-clone
             "F" "richieste e segnalazioni (Forge)" #'forge-dispatch
             "D" "differenze strutturali (difftastic)" #'difftastic-magit-diff))
(gdev-default--with :emacs vc
  (gdev-bind gdev-git-map
             "t" "macchina del tempo" #'git-timemachine-toggle
             "o" "collegamento alla riga" #'git-link))
(gdev-default--with :ui vc-gutter
  (gdev-bind gdev-git-map
             "[" "blocco di modifiche precedente" 'diff-hl-previous-hunk
             "]" "blocco successivo" 'diff-hl-next-hunk
             "r" "annulla blocco" 'diff-hl-revert-hunk
             "s" "prepara il blocco di modifiche" 'diff-hl-stage-current-hunk
             "=" "mostra blocco" #'diff-hl-show-hunk))

;;;; C-c i  inserisci

(gdev-bind gdev-insert-map
           "d" "duplica riga/selezione" #'duplicate-dwim
           "u" "carattere Unicode" #'insert-char
           "e" "emoji" #'emoji-search
           "y" "dalla cronologia degli appunti" #'yank-pop)
(gdev-default--with :completion vertico
  (gdev-bind gdev-insert-map "y" "dalla cronologia degli appunti" #'consult-yank-pop))
(gdev-default--with :editor snippets
  (gdev-bind gdev-insert-map
             "s" "frammento di codice" 'yas-insert-snippet
             "S" "nuovo frammento" 'yas-new-snippet))

;;;; C-c n  note e procedure

(gdev-default--with :lang org
  (gdev-bind gdev-notes-map
             "a" "agenda" 'gdev-org-calendar
             "A" "comandi dell’Agenda Org" #'org-agenda
             "c" "aggiungi una nota rapida" #'org-capture
             "l" "memorizza collegamento" 'org-store-link
             "n" "file delle note" 'gdev-org-find-note
             "s" "cerca nelle note" 'gdev-org-search-notes
             "r" "procedura operativa" 'gdev-org-open-runbook
             "b" "inserisci una citazione" 'gdev-org-insert-citation
             "p" "annota la pagina del PDF" 'gdev-org-pdf-note
             "e" "esporta le slide PDF" 'gdev-org-export-slides))

;;;; C-c o  apri

(gdev-bind gdev-open-map
           "-" "cartella di questo file" #'dired-jump
           "c" "calcolatrice" #'calc
           "m" "pagina di manuale" #'man
           "P" "processi" #'proced
           "w" "navigatore" #'eww)
(gdev-default--with :ui workbench
  (gdev-bind gdev-open-map
             "w" "navigatore web" 'gdev-web-browser
             "W" "anteprima web affiancata" 'gdev-web-preview))
(gdev-default--with :term eat
  (unless (gdev-module-p :ui 'workbench)
    (keymap-global-set "s-j" 'gdev-term-project))
  (gdev-bind gdev-open-map
             "t" "terminale (progetto)" 'gdev-term-project
             "n" "nuovo terminale del progetto" 'gdev-term-new
             "p" "nuovo terminale con profilo" 'gdev-term-new-profile
             "s" "affianca un terminale" 'gdev-term-split
             "]" "vai al terminale affiancato" 'gdev-term-focus-other
             "T" "terminale qui" 'gdev-term-here))
(gdev-default--with :term eshell
  (gdev-bind gdev-open-map
             "e" "interprete Lisp del progetto" 'gdev-eshell-project
             "E" "interprete Lisp qui" 'gdev-eshell-here))
(gdev-default--with :tools eval
  (gdev-bind gdev-open-map "r" "interprete interattivo" 'gdev-open-repl))
(gdev-default--with :ui dashboard
  (gdev-bind gdev-open-map "h" "cruscotto" 'gdev-dashboard))
(gdev-default--with :ui system-monitor
  (gdev-bind gdev-open-map "M" "risorse del Mac (CPU, RAM, rete)" 'gdev-system-monitor-show))
(gdev-default--with :os macos
  (gdev-bind gdev-open-map
             "o" "mostra nel Finder" 'gdev-macos-reveal-in-finder
             "O" "apri nel programma predefinito" 'gdev-macos-open-externally))

;;;; C-c p  progetto

(gdev-bind gdev-project-map
           "p" "cambia progetto" #'project-switch-project
           "f" "apri file" #'project-find-file
           "b" "aree di testo del progetto" #'project-switch-to-buffer
           "d" "apri in Esplora file" #'gdev-project-open-folder
           "k" "chiudi le aree di testo del progetto" #'project-kill-buffers
           "!" "comando nella cartella principale" #'project-shell-command
           "&" "comando in secondo piano" #'project-async-shell-command
           "K" "interrompi la compilazione" 'kill-compilation
           "D" "modifica .dir-locals.el" #'gdev-edit-dir-locals)
(gdev-default--with :completion vertico
  (gdev-bind gdev-project-map "b" "aree di testo del progetto" #'consult-project-buffer))
(gdev-default--with :tools lsp
  (gdev-bind gdev-project-map "s" "simbolo nel progetto" #'gdev-find-project-symbol))
(gdev-default--with :tools build
  (gdev-bind gdev-project-map
             "a" "esegui attività…" 'gdev-run-project-task
             "A" "ripeti ultima attività" 'gdev-repeat-project-task
             "c" "compila" 'gdev-build
             "C" "configura" 'gdev-build-configure
             "g" "ripeti l'ultima compilazione" 'gdev-build-recompile
             "t" "test del file o tutti i test" 'gdev-test-dwim
             "T" "tutti i test" 'gdev-build-test
             "r" "esegui" 'gdev-run-dwim
             "y" "tipo di compilazione" 'gdev-build-set-type
             "x" "pulisci" 'gdev-build-clean
             "F" "azzera impostazioni di compilazione" 'gdev-build-forget)
  (gdev-default--with :ui workbench
    (gdev-bind gdev-project-map
               "q" "esegui test al cursore" 'gdev-project-view-test-at-point
               "Q" "riesegui i test falliti" 'gdev-project-view-test-failed
               "v" "misura copertura" 'gdev-test-coverage-run
               "V" "rapporto di copertura" 'gdev-test-coverage-show)))
(gdev-default--with :ui workbench
  (gdev-bind gdev-project-map
             "n" "nuovo progetto…" 'gdev-new-project
             "i" "assicurazione del progetto" 'gdev-assurance-show
             "I" "catalogo degli standard" 'gdev-assurance-catalog))
(gdev-default--with :tools git
  (gdev-bind gdev-project-map "l" "elenca i promemoria del progetto" #'magit-todos-list))

;;;; C-c P  profilazione

(gdev-default--with :tools profiler
  (gdev-bind gdev-profile-map
             "P" "profila secondo il contesto" 'gdev-profile-dwim
             "s" "profilo CPU (samply)" 'gdev-profile-samply
             "f" "grafico a fiamma di un processo" 'gdev-profile-flamegraph
             "h" "misura prestazioni (hyperfine)" 'gdev-profile-hyperfine
             "a" "errori di memoria (ASan)" 'gdev-profile-asan
             "u" "comportamento indefinito (UBSan)" 'gdev-profile-ubsan
             "t" "accessi concorrenti (TSan)" 'gdev-profile-tsan
             "c" "copertura dei test" 'gdev-profile-coverage
             "e" "profila Emacs" 'gdev-profile-emacs
             "b" "misura l'avvio di Emacs" 'gdev-profile-emacs-startup)
  ;; Solo su macOS, ma sempre elencati: fuori dal Mac spiegano perché non
  ;; funzionano, e la mappa dei tasti generata è uguale ovunque.
  (gdev-bind gdev-profile-map
             "i" "profilatore di Xcode (Instruments)" 'gdev-profile-instruments
             "k" "perdite di memoria (leaks)" 'gdev-profile-leaks))

;;;; C-c q  esci e sessioni

(gdev-bind gdev-quit-map
           "q" "esci" #'gdev-quit
           "Q" "esci senza salvare" #'gdev-quit-without-saving
           "r" "riavvia" #'restart-emacs
           "R" "riavvia e ripristina" #'gdev-restart-and-restore
           "s" "salva sessione" #'gdev-session-save
           "l" "ripristina sessione" #'gdev-session-load
           "f" "chiudi la finestra di Emacs" #'gdev-close-frame)

;;;; C-c r  macchine remote

(gdev-default--with :tools remote
  (gdev-bind gdev-remote-map
             "r" "macchina remota in Dired" 'gdev-remote-dired
             "o" "apri cartella via SSH" 'gdev-remote-open-folder
             "s" "apri come amministratore" 'gdev-remote-sudo-dired
             "t" "terminale sulla macchina remota" 'gdev-remote-terminal
             "x" "comando sulla macchina remota" 'gdev-remote-shell-command
             "l" "registro di sistema" 'gdev-remote-journal
             "u" "servizi di sistema (systemctl)" 'gdev-remote-systemctl
             "p" "processi" #'proced
             "h" "modifica ~/.ssh/config" 'gdev-remote-ssh-config
             "n" "raggiungibilità (ping)" #'ping
             "d" "interrogazione DNS (dig)" #'dig
             "c" "chiudi le connessioni" 'tramp-cleanup-all-connections))

;;;; C-c s  cerca

(gdev-bind gdev-search-map
           "s" "nell'area di testo" #'isearch-forward
           "p" "nel progetto" #'project-find-regexp
           "i" "indice dell'area di testo" #'imenu
           "r" "sostituisci nel progetto" #'project-query-replace-regexp
           "y" "simbolo nello spazio di lavoro" #'xref-find-apropos
             "O" "righe corrispondenti" #'occur)
(gdev-default--with :completion vertico
  (gdev-bind gdev-search-map
             "s" "nell'area di testo" #'consult-line
             "S" "nelle aree di testo aperte" #'consult-line-multi
             "p" "nel progetto" #'consult-ripgrep
             "P" "in un altro progetto" 'gdev-search-other-project
             "d" "in una cartella" 'gdev-search-directory
             "g" "cerca nei file tracciati da Git" #'consult-git-grep
             "f" "file per nome" #'consult-find
             "i" "indice dell'area di testo" #'consult-imenu
             "I" "indice di tutte le aree di testo" #'consult-imenu-multi
             "h" "titoli" #'consult-outline
             "m" "posizioni segnate" #'consult-mark
             "b" "segnalibri" #'consult-bookmark
             "z" "ripeti l'ultima ricerca" #'vertico-repeat
             "." "simbolo sotto il cursore" 'gdev-search-symbol-at-point
             "*" "simbolo nel progetto" 'gdev-search-project-for-symbol-at-point))
(gdev-default--with :tools lookup
  (gdev-bind gdev-search-map
             "k" "documentazione locale" #'devdocs-lookup
             "K" "installa documentazione" #'devdocs-install
             "o" "cerca in rete" 'gdev-lookup-online))
(gdev-default--with :ui hl-todo
  (gdev-bind gdev-search-map "t" "promemoria nell'area di testo" #'hl-todo-occur))

;;;; C-c t  attiva/disattiva

(gdev-bind gdev-toggle-map
           "l" "numeri di riga" #'display-line-numbers-mode
           "w" "a capo automatico" #'visual-line-mode
           "W" "spazi visibili" #'whitespace-mode
           "c" "margine destro" #'display-fill-column-indicator-mode
           "r" "sola lettura" #'read-only-mode
           "F" "schermo intero" #'toggle-frame-fullscreen
           "x" "controllo della sintassi" #'flymake-mode)
(gdev-default--with :ui workbench
  (gdev-bind gdev-toggle-map
             "t" "tema chiaro/scuro" #'gdev-ui-toggle-theme
             "A" "preferenze di aspetto" 'gdev-preferences-open-appearance
             "L" "numeri di riga relativi" #'gdev-ui-toggle-relative-line-numbers
             "b" "carattere grande" #'gdev-big-font-mode
             "z" "modalità concentrazione" #'gdev-layout-toggle-focus
             "m" "minimappa" 'gdev-minimap-toggle))
(gdev-default--with :editor format
  (gdev-bind gdev-toggle-map "f" "formatta al salvataggio" 'gdev-format-toggle-on-save))
(gdev-default--with :tools lsp
  (gdev-bind gdev-toggle-map "h" "suggerimenti in linea" 'eglot-inlay-hints-mode))
(gdev-default--with :checkers syntax
  (gdev-bind gdev-toggle-map "d" "segnalazioni in linea" 'gdev-checkers-toggle-inline))
(gdev-default--with :checkers spell
  (when (gdev-find-executable "enchant-2")
    (gdev-bind gdev-toggle-map "s" "controllo ortografico" #'jinx-mode)))
(gdev-default--with :ui indent-guides
  (gdev-bind gdev-toggle-map "i" "guide di rientro" #'indent-bars-mode))
(gdev-default--with :ui sidebar
  (keymap-global-set "s-b" 'gdev-sidebar-toggle)
  (keymap-global-set "s-0" 'gdev-sidebar-focus)
  (gdev-bind gdev-toggle-map "e" "esplora file e stato Git" 'gdev-sidebar-focus))
(gdev-default--with :ui system-monitor
  (gdev-bind gdev-toggle-map "M" "statistiche della macchina" 'gdev-system-monitor-mode))

;;;; C-c w  finestre e spazi di lavoro

(gdev-bind gdev-workspace-map
           "u" "annulla disposizione" 'winner-undo
           "U" "ripeti disposizione" 'winner-redo
           "<right>" "dividi a destra" #'gdev-split-editor-right
           "<down>" "dividi in basso" #'gdev-split-editor-below
           "o" "passa al gruppo editor successivo" #'gdev-focus-other-editor
           "m" "massimizza / ripristina" #'gdev-toggle-maximize-window
           "d" "chiudi finestra" #'delete-window
           "=" "uniforma le finestre" #'balance-windows
           "n" "nuovo spazio di lavoro" #'tab-bar-new-tab
           "R" "rinomina spazio di lavoro" #'tab-bar-rename-tab
           "[" "spazio di lavoro precedente" #'tab-bar-switch-to-prev-tab
           "]" "spazio di lavoro successivo" #'tab-bar-switch-to-next-tab)
(dotimes (index 9)
  (keymap-set gdev-workspace-map (number-to-string (1+ index))
              (cons (format "scheda %d" (1+ index)) #'tab-bar-select-tab)))
(gdev-default--with :ui workspaces
  (keymap-global-set "M-s-<right>" 'gdev-workspaces-next-document)
  (keymap-global-set "M-s-<left>" 'gdev-workspaces-previous-document)
  (gdev-bind gdev-buffer-map
             "o" "documenti aperti" 'gdev-workspaces-switch-document
             "<left>" "sposta scheda a sinistra" 'gdev-workspaces-move-document-left
             "<right>" "sposta scheda a destra" 'gdev-workspaces-move-document-right)
  (gdev-bind gdev-workspace-map
             "a" "affianca documento" 'gdev-workspaces-open-beside
             "A" "apri documento in basso" 'gdev-workspaces-open-below
             "M" "sposta documento in un altro gruppo" 'gdev-editor-move-to-group
             "p" "apri spazio di lavoro del progetto" #'tabspaces-open-or-create-project-and-workspace
             "s" "cambia spazio di lavoro" #'tabspaces-switch-or-create-workspace
             "c" "chiudi spazio di lavoro" 'tabspaces-close-workspace
             "k" "chiudi spazio e aree di testo" 'tabspaces-kill-buffers-close-workspace
             "b" "rimuovi area di testo dallo spazio" 'tabspaces-remove-current-buffer))
(gdev-default--with :ui workbench
  (keymap-global-set "s-j" 'gdev-popup-toggle)
  (keymap-global-set "s-J" #'gdev-layout-choose-panel)
  (keymap-global-set "s-b" 'gdev-activity-toggle)
  (keymap-global-set "M-s-b" 'gdev-command-sidebar-toggle)
  (keymap-global-set "s-F" 'gdev-search-query)
  (keymap-global-set "s-," 'gdev-preferences-open)
  (when gdev-macos-p (keymap-global-set "<ns-show-prefs>" 'gdev-preferences-open))
  (keymap-global-set "s-." 'gdev-workbench-operation-cancel)
  (gdev-bind gdev-project-map
             "K" "interrompi l'operazione" 'gdev-workbench-operation-cancel
             "e" "dipendenze del progetto" 'gdev-project-dependencies-show)
  (gdev-bind gdev-workspace-map
             "z" "annulla operazione dello spazio" 'gdev-operation-undo
             "Z" "ripeti operazione dello spazio" 'gdev-operation-redo
             "N" "operazioni dello spazio" 'gdev-workbench-operations-show
             "g" "griglia 2×2" #'gdev-split-editor-grid
             "j" "mostra o nascondi il pannello" 'gdev-popup-toggle
             "J" "scegli lo strumento aperto" #'gdev-layout-choose-panel
             "t" "mostra o nascondi Comandi" 'gdev-command-sidebar-toggle
             "T" "passa tra Comandi ed editor" 'gdev-command-sidebar-focus
             "v" "scegli vista laterale" 'gdev-activity-select
             "O" "struttura del documento" 'gdev-outline-show
             "L" "pannello Lavorazioni" 'gdev-lavorazioni-pannello
             "r" "sposta strumento nell'area di modifica" 'gdev-popup-raise)
  (gdev-bind gdev-workspace-map "W" "strumenti di scrittura" 'gdev-writing-open))
(gdev-default--with :ui window-select
  (gdev-bind gdev-workspace-map
             "w" "scegli finestra" #'ace-window
             "x" "scambia finestre" #'ace-swap-window))

;;;; C-c !  segnalazioni

(gdev-default--with :checkers syntax
  (keymap-global-set "s-M" 'gdev-checkers-toggle-problems)
  (gdev-bind gdev-checkers-map
             "n" "problema successivo" 'gdev-checkers-next
             "p" "problema precedente" 'gdev-checkers-previous
             "d" "problemi del documento" 'gdev-checkers-document-problems
             "D" "problemi del progetto" 'gdev-checkers-project-problems
             "l" "segnalazioni dell'area di testo" 'gdev-checkers-document-problems
             "P" "pannello Problemi" 'gdev-checkers-toggle-problems))
(gdev-default--with :completion vertico
  (gdev-bind gdev-checkers-map "l" "segnalazioni dell'area di testo" #'consult-flymake))
(gdev-default--with :checkers spell
  ;; Senza enchant il modulo non si carica: i tasti compaiono solo se possono funzionare.
  (when (gdev-find-executable "enchant-2")
    (gdev-bind gdev-checkers-map
               "s" "correggi parola" #'jinx-correct
               "S" "lingua del controllo ortografico" #'jinx-languages)))

;;;; C-h d  aiuto di GDev

(gdev-bind gdev-help-map
           "k" "promemoria dei tasti" #'gdev-cheat-sheet
           "g" "guida a Emacs in italiano" #'gdev-emacs-guide
           "i" "esercitazione di Emacs in italiano" #'gdev-emacs-tutorial-italian
           "m" "descrivi modulo" #'gdev-describe-module
           "t" "tempi di caricamento dei moduli" #'gdev-module-load-report
           "d" "diagnosi dell'ambiente" #'gdev-doctor
           "c" "configurazione privata" #'gdev-open-private-config
           "f" "file di GDev-Emacs" #'gdev-find-framework-file
           "e" "aggiorna l'ambiente dei comandi" 'gdev-env-refresh
           "a" "cerca nella documentazione" #'apropos-documentation)

;;;; Tasti funzione

(gdev-default--with :tools build
  (keymap-global-set "C-<f5>" 'gdev-run-dwim)
  (keymap-global-set "<f6>" 'gdev-test-dwim)
  (keymap-global-set "<f7>" 'gdev-build)
  (keymap-global-set "S-<f7>" 'gdev-build-configure))
(keymap-global-set "<f8>" #'next-error)
(keymap-global-set "S-<f8>" #'previous-error)
(keymap-global-set "<f12>" #'gdev-find-definition)
(keymap-global-set "S-<f12>" #'gdev-find-references)
(keymap-global-set "M-." #'gdev-find-definition)
(keymap-global-set "M-?" #'gdev-find-references)
(gdev-default--with :tools debugger
  (keymap-global-set "<f5>" 'gdev-debug-dwim)
  (keymap-global-set "S-<f5>" 'gdev-debug-terminate)
  (keymap-global-set "C-S-<f5>" 'gdev-debug-restart)
  (keymap-global-set "<f9>" 'dape-breakpoint-toggle)
  (keymap-global-set "<f10>" 'gdev-debug-next)
  (keymap-global-set "<f11>" 'gdev-debug-step-in)
  (keymap-global-set "S-<f11>" 'gdev-debug-step-out))

;;; config.el ends here
