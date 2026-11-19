;;; init.el --- I moduli attivi di GDev-Emacs -*- lexical-binding: t; -*-

;; Questo file è tuo: GDev-Emacs non lo sovrascrive mai.  Sta in
;; ~/.config/gdev/ (o in $GDEV_USER_DIR) accanto a packages.el e config.el.
;;
;; Togli un modulo per disattivarlo: non se ne installa né se ne carica
;; nulla.  Un modulo dentro una lista accetta opzioni (flag), per esempio
;; (format +onsave).  C-h d m descrive un modulo, i suoi tasti e le sue
;; opzioni.  Dopo una modifica, esegui in un terminale
;;
;;   gdev sync
;;
;; e riavvia Emacs (C-c q R riavvia e ripristina la sessione).

(gdev! :completion
       vertico                  ; elenchi nel minibuffer, anteprima, azioni
       corfu                    ; completamento a comparsa mentre scrivi

       :ui
       workbench                ; tema, menu in italiano e disposizione dei riquadri
       dashboard                ; pagina iniziale: progetti, sessioni, tasti
       modeline                 ; barra di stato sobria: Git, segnalazioni, LSP
       sidebar                  ; albero dei file, stato Git, shell, SSH e Web
       system-monitor           ; CPU, RAM e traffico della macchina locale
       workspaces               ; una scheda per progetto, con i suoi buffer
       window-select            ; M-o: salta a una finestra con una lettera
       hl-todo                  ; TODO FIXME HACK evidenziati
       indent-guides            ; guide verticali a ogni livello di rientro
       vc-gutter                ; righe modificate segnate nel bordo laterale (fringe)
       nav-flash                ; fa lampeggiare la riga dopo un salto
       breadcrumb               ; percorso di file e funzione in alto

       :editor
       (format +onsave)         ; C-c c f; +onsave: se c'è un file di stile
       fold                     ; piega i blocchi (fold)
       multiple-cursors         ; più cursori
       snippets                 ; frammenti di testo (snippet) con yasnippet
       motion                   ; avy, espandi selezione, sposta righe
       paredit                  ; modifica strutturale del Lisp

       :emacs
       dired                    ; gestore di file
       ibuffer                  ; elenco dei buffer per progetto
       undo                     ; annullamenti ad albero, anche dopo un riavvio
       vc                       ; macchina del tempo Git, collegamenti, conflitti

       :term
       eat                      ; emulatore di terminale veloce
       eshell                   ; la shell di Emacs

       :checkers
       syntax                   ; segnalazioni (diagnostics) con Flymake
       spell                    ; ortografia (jinx, richiede enchant)

       :tools
       tree-sitter              ; analisi sintattica per colori e navigazione
       lsp                      ; server di linguaggio (Eglot)
       build                    ; compila, esegui, test: CMake, Make, prove...
       debugger                 ; adattatori di debug (dape): lldb, Perl
       profiler                 ; profilatori (samply, Instruments), analizzatori, copertura
       eval                     ; REPL e valutazione
       lookup                   ; documentazione, locale (offline) e in rete (online)
       pdf                      ; Lettore PDF, testo e collegamenti alle pagine
       git                      ; stato Git, richieste e segnalazioni (Forge)
       remote                   ; TRAMP, macchine remote via SSH, amministrazione di sistema
       direnv                   ; ambiente autorizzato nei progetti con .envrc
       terraform                ; HCL, validazione e piani
       kubernetes               ; risorse ed eventi, log dei pod
       jupyter                  ; console dei kernel ed esecuzione dei notebook
       llm                      ; Claude in qualunque buffer (gptel)
       agent                    ; Claude Code dentro Emacs
       hithub                   ; HitHub: GitHub con gh, richieste, Actions, gist

       :os
       macos                    ; scorciatoie del Mac, Finder, Portachiavi

       :lang
       cc                       ; C, C++, CMake
       common-lisp              ; SLY
       emacs-lisp
       perl
       web                      ; HTML, modelli di pagina, CSS
       javascript               ; JavaScript e TypeScript (Deno)
       sh                       ; script di shell
       python
       go                       ; moduli Go, gopls e Delve
       rust                     ; Cargo, rust-analyzer e LLDB
       swift                    ; Swift Package Manager e SourceKit-LSP
       zig                      ; zig build e ZLS
       java                     ; Maven, Gradle e JDT LS
       csharp                   ; .NET, csharp-ls e NetCoreDbg
       data                     ; YAML, TOML, JSON, file di configurazione
       sql                      ; Database SQL, PostgreSQL e SQLite
       xml                      ; modifica e convalida di XML e schemi
       markdown
       org                      ; note, attività, procedure operative
       article                  ; progetti di scrittura, bozze e ricerca
       latex                    ; documenti e progetti LaTeX
       rest                     ; richieste HTTP da Org

       :app
       communications           ; posta, feed RSS e chat IRC

       :config
       default)                 ; mappa dei tasti: gruppi C-c, tasti funzione

;;; init.el ends here
