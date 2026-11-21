---
name: gdev-develop
description: Sviluppa e migliora GDev-Emacs nel suo repository. Usa questa skill per correggere regressioni, aggiungere funzioni, evolvere moduli, interfaccia, prestazioni, CLI, test, fork o il motore delle lavorazioni e il suo catalogo di azioni. Per usare l’editor o i file .lavorazione in un progetto, usa gdev-use.
---

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Sviluppa GDev-Emacs

## Scopri il checkout corrente

Individua la radice di GDev-Emacs da `bin/gdev` e leggi `AGENTS.md` e le istruzioni applicabili alla zona da modificare. Controlla `git status --short --branch` e leggi le differenze pertinenti prima di scrivere. Includi nella base di lavoro le modifiche già presenti e isola le tue quando si sovrappongono.

Dalla radice esegui `./bin/gdev agente sviluppo` oppure chiama lo strumento MCP `gdev_discover` in modalità `develop`. Verifica che `root` corrisponda al checkout su cui lavori. Usa `interfaces`, `cli_commands` e `modules` per scegliere le fonti e gli strumenti pertinenti. `default_modules` descrive il modello distribuito. Con un prefisso, per esempio `./bin/gdev agente sviluppo gdev-search-`, ottieni anche i simboli corrispondenti con file, riga e indicazione dei comandi interattivi. Apri il sorgente per verificare il percorso chiamato e i relativi vincoli.

Usa `./bin/gdev agente uso` per il lavoro in un progetto. Le forme tecniche
`./bin/gdev agent develop` e `./bin/gdev agent use` restano disponibili. Se `development.manifest_present` è vero, leggi
il progetto formale e la lavorazione attraverso `gdev agente assicurazione
RADICE progetto`, `elenca`, `scheda ID` e `valuta ID`. Questa entrata funziona
con l'editor chiuso e registra le azioni con il tipo agente.

Prima del codice di produzione prepara o seleziona una lavorazione, collega
scheda e istantanea e registra analisi e autorizzazione. Segui il ciclo
descritto in [Progetto formale e mandato degli agenti](references/extensions/sviluppo-formale.md).
Il profilo dell'utente può essere usato su suo mandato esplicito: conserva
decisione, esecutore e ambito nell'audit. Mantieni distinta l'autorizzazione
a eseguire da una revisione effettivamente svolta dalla persona.

Rileggi il catalogo dopo un cambio di revisione o un intervento sulle dichiarazioni esposte. Se la revisione o l'installazione di Emacs non espone il comando, parti da `bin/gdev`, `lisp/gdev-cli.el`, `templates/init.el` e dal codice pertinente. Per aggiornare i sorgenti serve che l'utente abbia chiesto l'aggiornamento.

## Passa dalla richiesta alla verifica

1. Parti dal comando, menu o tasto effettivo. Segui l'azione fino al modulo che possiede lo stato, usando la mappa dei tasti e le guide della revisione corrente come punti di ingresso. Formula l'esito osservabile e riproduci il difetto o stabilisci il comportamento di partenza.
2. Modifica il punto che governa il comportamento, riusando comandi e registri comuni. Se cambia un'azione visibile, controlla il percorso da tastiera e puntatore e verifica che coincidano fuoco, documento, cartella e riquadro. Verifica conferma, annullamento e recupero dagli errori quando si applicano.
3. Scegli le verifiche dal flusso toccato. Parti dai test ERT mirati, estendi a suite e avvio se cambi inizializzazione o attraversi più moduli. Per codice destinato alla compilazione nativa, verifica anche il caricamento normale. Per usare un ambiente di prova separato imposta `GDEV_STATE_DIR` e `GDEV_USER_DIR` su directory temporanee. Per evitare artefatti nella copia di lavoro, compila in una copia di prova che includa le modifiche da verificare.
4. Quando una prova fallisce, separa i difetti della modifica dai problemi dell'ambiente, riproduci il caso minimo e ripeti la verifica dopo la correzione. Se una parte resta bloccata, completa i controlli indipendenti e descrivi il limite osservato.
5. Aggiorna le indicazioni che cambiano con il flusso. Per tasti documentati rigenera la mappa con `./bin/gdev docs` e controlla la differenza. Chiudi con `git diff --check`, revisione del diff e pulizia degli artefatti temporanei di tua creazione. Riporta esito, prove sul codice finale e limiti rimasti. Usa l'autorizzazione dell'utente per commit, push e modifiche che coinvolgono la sua sessione attiva.

## Scegli i controlli pertinenti

- **Interfaccia o stato del banco di lavoro.** Leggi `docs/interfaccia.md` e usa `templates/vista.el` come riferimento per una nuova vista. Verifica profilo, pulsante ×, protezione dei buffer modificati e identità della selezione durante ridisegno e ripristino. Per interazioni con più soluzioni plausibili, confronta prototipi isolati. Quando disponibile, prova il flusso nella finestra nativa su macOS, con temi chiaro e scuro e spazio ristretto. Distingui questa prova dal batch e dal terminale.
- **Operazioni frequenti.** Misura il percorso prima e dopo sugli stessi dati quando aggiungi scansioni, timer o processi. Controlla invalidazione, annullamento e risultati asincroni fuori ordine.
- **Moduli o fork.** Leggi `docs/dipendenze.md` e `vendor/pacchetti.el`. Conserva gli avvisi originali, registra provenienza, revisione, licenze e avvisi datati per i fork modificati e verifica il caricamento della copia locale. Per le API che variano tra versioni, usa la versione minima dichiarata dal progetto.
- **Nuovi rilasci dei fork.** Usa [Integrare un rilascio a monte](references/extensions/integrare-fork.md) per preparare un merge e verificare le personalizzazioni.
- **Interfaccia per agenti.** Ricava dati da sorgenti e registri del checkout. Se cambia una capacità esposta, verifica la scoperta prima e dopo sul codice effettivo e aggiorna il contratto quando cambia il significato dei dati. Per le scorciatoie verifica una personalizzazione effettiva nella vista. Per i cursori prova due agenti sullo stesso documento, revisione superata, annullamento e rimozione degli indicatori. Vedi [Scorciatoie e cursori degli agenti](../../../docs/agenti.md#scorciatoie-e-cursori-degli-agenti).
- **Motore e catalogo delle lavorazioni.** Leggi [Azioni delle lavorazioni](references/extensions/lavorazioni.md) per registrare un'azione, modificare il formato dei file o verificare il caricamento in bytecode.
- **Progetti formali.** Leggi `docs/assicurazione/progetto-formale.md`. Modifica i requisiti autorevoli in `.gdev-assurance/project.eld`, collega i controlli reali e ripeti tassonomie, modello, procedure e rapporti pertinenti. Mantieni distinti esiti tecnici, copertura delle fonti e approvazioni umane.
- **Audit di Emacs Lisp.** Per controllare le dipendenze a freddo e gli avvisi, leggi [Compilazione Emacs Lisp negli audit](references/extensions/compilazione-lisp.md).
- **Avvio dopo una compilazione.** Per verificare catene asincrone, profili e debugger, leggi [Operazioni di progetto](references/extensions/operazioni-di-progetto.md).
- **Prove dal vivo e in batch.** Per applicare una correzione in un'istanza aperta e per le differenze tra batch e finestra grafica, leggi [Verifica dal vivo e insidie del batch](references/extensions/verifica-dal-vivo.md).
- **Corpus e BDD.** Per importare test a monte o aggiungere scenari `.feature`, leggi [Corpus di comportamenti e BDD](references/extensions/corpus-bdd.md). Usa i fork locali e collega ogni caso alla suite ERT ordinaria e alla CI.

Per difetti emersi in un progetto esterno, applica il [ciclo di correzioni tra progetti](references/extensions/ciclo-correzioni-progetti.md). Mantieni la regressione nel livello che governa il comportamento.

## Riesamina la skill a ogni utilizzo

Prima di concludere, confronta le istruzioni seguite con le prove del
lavoro. Se un'istruzione ha causato un errore, è obsoleta o ha lasciato
scoperta una verifica necessaria, correggila nel punto in cui si trova e
ripeti le prove pertinenti. Conserva le istruzioni che restano valide.

Quando emerge un passaggio riutilizzabile, aggiungilo o aggiorna il
riferimento pertinente in `references/extensions/`. Usa la licenza
GPL-3.0-or-later e indica quando applicarlo, come osservare l'esito e come
recuperare da un errore. Consulta le estensioni pertinenti alla richiesta.
Per un'estensione di `gdev-use`, usa la cartella di quella skill.

Per nuove capacità, scegli nomi e precondizioni distinti, mantieni comandi
e campi JSON già esposti e ripeti almeno una prova del flusso precedente
insieme a quella nuova.
Se il comportamento esistente è errato, tratta la sua correzione come
un intervento separato dalla crescita della skill.
