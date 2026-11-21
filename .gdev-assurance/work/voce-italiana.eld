;;; voce-italiana.eld --- Voce integrata nel contesto GDev -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "Voce italiana integrata: comandi, dettatura e lettura"
 :type feature
 :objective "Usare comandi in italiano, scritti o pronunciati, dettare e ascoltare il testo attraverso le normali entrate di GDev, con riconoscimento locale facoltativo e dipendenze minime."
 :scope "Fork locale di Earwig; grammatica italiana e catalogo comune delle azioni; dettatura e correzioni; riconoscimento locale con modello multilingue e lessico GDev; lettura italiana della selezione o del documento; menu, tastiera, controllo operativo e preferenze; preparazione dei prerequisiti senza percorsi richiesti alla persona."
 :requirements ("GDEV-P01" "GDEV-P06" "GDEV-P07" "GDEV-P09" "GDEV-P10" "GDEV-P11" "GDEV-P13" "GDEV-P14" "GDEV-P15" "GDEV-Q01" "GDEV-Q03" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07")
 :inputs ("AGENTS.md" "docs/interfaccia.md" "docs/dipendenze.md" "vendor/pacchetti.el"
          "lisp/gdev-commands.el" "lisp/gdev-command-context.el" "lisp/gdev-workspace-state.el"
          "modules/ui/workbench/gdev-menu.el" "modules/config/default/config.el" "Brewfile")
 :prerequisites ("Mandato dell'utente: integrare Earwig o formarne l'adattamento, con comandi testuali, dettatura e lettura in italiano, calibrati su GDev"
                 "Conservare le scorciatoie e le configurazioni personali; nessun ascolto all'avvio dell'editor"
                 "Whisper è facoltativo: nessun download al bootstrap, all'apertura della vista o al primo tentativo di dettatura; attivazione e download espliciti"
                 "Eliminare dopo le prove il modello scaricato per la verifica; conservare soltanto le evidenze utili"
                 "Usare soltanto dipendenze e modelli con licenze compatibili, registrando origine, versione, revisione e avvisi")
 :owner "Manutentori di GDev e Codex su mandato dell'utente" :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets nil
 :acceptance ("Comandi scritti e vocali usano lo stesso interprete italiano e le azioni esistenti di GDev"
              "La dettatura conserva testo, annullamento, documento e spazio di origine; risposte superate non modificano altri documenti"
              "La preparazione è ripetibile, asincrona e verificata; percorsi e prerequisiti sono ricavati dall'ambiente"
              "La preparazione appartiene all'applicazione e continua mentre si scrive o si legge; arresti e completamenti tardivi rispettano l'identità del proprio processo"
              "La lettura usa una voce italiana disponibile, rispetta la selezione e offre arresto e pausa senza interferire con l'ascolto"
              "Menu, tastiera, puntatore, annullamento e preferenze sono coerenti e in italiano"
              "Grammatica, punteggiatura, lessico, cicli asincroni, errori e arresti hanno prove ERT e BDD"
              "Compilazione, avvio ordinario e prove acustiche effettivamente eseguite sono distinti dai controlli simulati; i limiti di accuratezza e accesso al microfono sono dichiarati")
 :artifacts ("docs/assicurazione/generati/project.md" ".gdev/assurance/reports/reliability.json")
 :revisions ("Analisi iniziale: Earwig 0.2.0, revisione ecfb12505ec72ffb8e45d25390092c0988c3e583, GPL-3.0-or-later. La scelta del riconoscitore e dei pesi verifica separatamente le relative licenze."))
