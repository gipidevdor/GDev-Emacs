;;; coerenza-viste.eld --- Audit delle viste e dei tempi del Workbench -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :title "Coerenza delle viste e tempi di risposta del Workbench"
 :type refactor
 :objective "Verificare il percorso visibile da tastiera, menu e puntatore, il recupero delle operazioni lunghe e la reattività delle azioni frequenti."
 :scope "Attività laterali, Comandi, viste ausiliarie e strumenti. Misure, feedback, primo avvio, flusso progetto-compilazione-debug, ripristino, diagnosi, API e rilascio. Usare GDev sul proprio checkout e su progetti isolati per provare i flussi; segnalare le integrazioni che richiedono un servizio reale."
 :requirements ("GDEV-P07" "GDEV-Q01" "GDEV-Q03" "GDEV-Q04" "GDEV-Q05" "GDEV-Q06")
 :inputs ("AGENTS.md" "docs/interfaccia.md" "docs/ergonomia.md"
          "docs/audit-viste.md"
          "modules/ui/workbench/gdev-activity.el" "modules/ui/workbench/gdev-layout.el"
          "modules/ui/workbench/gdev-workbench-operations.el" "lisp/gdev-cli.el"
          "lisp/gdev-commands.el" "test/gdev-ui-contract-test.el")
 :prerequisites ("Usare un profilo, uno stato e progetti di prova isolati"
                 "Prima delle modifiche di produzione verificare l'autorizzazione riferita alla lavorazione")
 :owner "Manutentori di GDev" :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets nil
 :acceptance ("Identificare per ciascuna vista entrata, stato vuoto e azione, chiusura, selezione e prove ancora mancanti"
              "Verificare errore, annullamento e accesso alla diagnosi per compilazione, sincronizzazione e installazione"
              "Misurare la riapertura a caldo di Vai a qualsiasi cosa rispetto a 50 ms e il cambio di attività rispetto a 100 ms; distinguere il tempo di risposta da quello del processo esterno"
              "Registrare condizioni e limiti delle prove di ricerca, digitazione e compilazione, distinguendo esecuzione in batch e finestra nativa")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions ("GT-0009, 21 novembre 2026. Decisione della persona: «Sì devi migliorare tutto.» e «Sì hai mandato di risolvere e gestire tutto il flusso rispettando l'assicurazione del prodotto. Poi voglio che usi tutto il prodotto, per migliorare il prodotto stesso.» Esecutore per conto della persona: Codex. Autorizzazione all'esecuzione; la decisione sulla revisione riguarda i risultati finali."))
