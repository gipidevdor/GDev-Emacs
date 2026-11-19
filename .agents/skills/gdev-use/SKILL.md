---
name: gdev-use
description: Usa GDev-Emacs per lavorare in un progetto, aprire file e spazi di lavoro, cercare nel codice, eseguire attività, test o debug, gestire riquadri, diagnosticare l’installazione e creare, verificare o eseguire macro dichiarative .lavorazione. Per cambiare il motore o registrare nuove azioni usa gdev-develop.
---

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Lavora con GDev-Emacs

Porta a termine l’azione richiesta e verificane l’effetto sul progetto o nell’editor. Identifica la cartella di GDev-Emacs, la cartella su cui lavorare e il profilo interessato. Se lavori da un altro progetto, risali al checkout dal percorso di `gdev` installato. Un progetto aperto può avere più radici. Controlla a quale radice appartiene il documento attivo e ricava dal contesto il bersaglio quando è univoco.

## Scopri l’interfaccia corrente

1. Se il server MCP di GDev è disponibile, usa `gdev_discover`. In alternativa, dalla radice del checkout esegui `./bin/gdev agent use`. Verifica `schema_version` e `root`. `interfaces` indica le fonti correnti, `cli_commands` le operazioni da terminale, `live_actions` le azioni offerte per una sessione aperta e `default_modules` i moduli del modello distribuito. Rileggi l’inventario quando cambia il checkout.
2. Per il contesto effettivo della sessione usa `gdev_status` e consulta `state.profile`, `state.workspace_roots`, `state.editor` e `state.configured_modules`. Usa `gdev_commands` per sapere quali comandi di menu sono disponibili nel contesto corrente. Rileggi lo stato dopo un cambio di profilo, spazio o documento. Nell’editor trovi il contesto attuale in **Comandi**, nel menu della vista e in **Strumenti › Scorciatoie…**. Il [flusso di lavoro](../../../docs/workflows.md) descrive le singole operazioni, la [mappa dei tasti](../../../docs/keymap.md) copre le scorciatoie distribuite e il [README](../../../README.md) documenta avvio e profili.
3. Se il checkout precede il comando `agent`, consulta `./bin/gdev help` e i riferimenti locali. Se l’avvio fallisce, leggi l’errore e controlla con `./bin/gdev doctor` nel profilo interessato. Distingui un modulo disattivato, uno strumento assente e un problema del progetto prima di scegliere un rimedio.

## Agisci sul bersaglio giusto

- **Nella sessione dell’utente**, usa la finestra o il terminale già identificati e i comandi interattivi visibili. Prima di un’azione controlla spazio attivo, cartella e documento. Conferma il risultato sul bersaglio, specialmente quando l’azione parte da un pannello.
- **Per riprodurre o verificare**, avvia `./bin/gdev emacs` con cartelle temporanee esplicite in `GDEV_USER_DIR` e `GDEV_STATE_DIR`, un progetto di prova e il profilo appropriato. Chiudi l’istanza di prova e rimuovi solo i file che hai creato quando l’evidenza è acquisita.
- **Dal terminale**, esegui il comando di progetto equivalente se il compito riguarda il risultato e non richiede la sessione grafica. Usa la directory corretta e il comando già configurato nel progetto. Indica se l’esito è stato verificato dal terminale o nella finestra.

Usa MCP per osservare e pilotare la sessione associata al suo server. Senza argomenti il server trova l’istanza avviata dallo stesso checkout con la stessa cartella di stato; con `--socket` si collega a una finestra precisa. `gdev_layout`, `gdev_buffers`, `gdev_buffer_read` e `gdev_messages` leggono riquadri, buffer e messaggi. `gdev_eval`, `gdev_command` e `gdev_keys` agiscono nell’editor: preferiscili ai comandi visibili solo quando il compito lo richiede, e usa `force` soltanto per rispondere a un prompt che hai aperto tu. Se il server offre soltanto `gdev_discover`, non è associato a una finestra: proponi all’utente il server `gdev-live` descritto in [Collega il server MCP](../../../docs/agenti.md#collega-il-server-mcp), che vale dalla sessione successiva del client, e intanto usa la CLI. Parti da `gdev_status` per riconoscere il bersaglio. Quando l’utente chiede di aprire una risorsa esistente, usa `gdev_open_file` o `gdev_open_folder` con il percorso locale assoluto. L’apertura di una cartella sostituisce le radici dello spazio attivo. Per estenderlo usa **Progetto › Aggiungi cartella allo spazio…**.

Per la CLI, copia il socket Unix nella sessione richiesta con `M-x gdev-agent-copy-socket`. Passa il suo percorso assoluto a `./bin/gdev agent live SOCKET status` per riconoscere profilo, radici e checkout. `./bin/gdev agent live SOCKET commands` elenca le azioni contestuali. Per aprire usa `open-file` o `open-folder` al posto di `status`, seguiti dal percorso assoluto. Con più sessioni candidabili, risolvi il bersaglio prima di inviare un’azione. Se il server manca, usa la finestra identificata oppure avvia un’istanza quando il compito lo consente.

Scegli l’entrata adatta all’esito richiesto. Per aprire una cartella usa il cruscotto o **File › Apri cartella…**. Per trovare un file o un punto nel documento usa **Vai a qualsiasi cosa…**. Per cercare più file usa **Cerca** nello spazio di lavoro. Per compilare, lanciare test e attività del progetto usa **Progetto** e osserva l’esito nel pannello. Se il comando di un linguaggio non compare, verifica il modulo, il tipo di documento e l’eventuale server di linguaggio. Se una ricerca è asincrona attendi il risultato, scarta le risposte di richieste precedenti e controlla il percorso prima di aprire o sostituire testo.

Per il debug su macOS controlla prima `./bin/gdev doctor`: senza la modalità sviluppatore ogni avvio di lldb attende un’autorizzazione di sistema che solo l’utente può concedere. Chiedila prima di avviare la sessione e termina l’adattatore se la richiesta resta senza risposta. Per portare la sessione in uno stato preciso senza tastiera leggi [Debug guidato](references/extensions/debug-guidato.md); per immagini della finestra destinate alla documentazione leggi [Catture della finestra nativa](references/extensions/catture-finestra.md).

Rispetta i passaggi di anteprima, salvataggio, conferma e annullamento dell’editor. Quando il compito include sostituzioni o modifiche, verifica quali file e righe verranno interessati e controlla le modifiche risultanti. Conserva le modifiche e le bozze altrui. Tratta `sync`, `upgrade`, le modifiche alle preferenze, la fiducia nella cartella e l’uso di integrazioni esterne secondo quanto autorizzato dalla richiesta. Usa i flussi dell’app per il consenso e i servizi credenziali quando servono.

Per creare, modificare, verificare o eseguire un file `.lavorazione`, leggi
[Lavorazioni](references/extensions/lavorazioni.md). Ricava i passi dal
catalogo del profilo effettivo. Verifica il piano e controlla la cartella
scelta prima di eseguirlo.

Per leggere una scorciatoia effettiva o scrivere nella bozza con più
cursori, usa [Scorciatoie e cursori degli agenti](../../../docs/agenti.md#scorciatoie-e-cursori-degli-agenti).
Assegna a ciascun agente un nome distinto, rileggi la revisione prima di
scrivere e rimuovi i suoi cursori quando hai finito.

## Concludi con una verifica osservabile

Per un’apertura controlla lo stato effettivo con `gdev_status` o `agent live SOCKET status` sulla stessa sessione. Per le altre azioni controlla il file e la posizione raggiunti, il risultato finale del processo o lo stato del riquadro e del progetto. In caso di errore, conserva il messaggio pertinente, correggi le cause recuperabili e rileggi lo stato prima di ritentare. Se manca una possibilità concreta di agire o osservare la sessione, completa le verifiche possibili e indica l’operazione rimasta in sospeso.

## Impara dai flussi verificati

Consulta i titoli delle estensioni in `references/extensions/`, quando
presenti, e leggi quelle pertinenti. Quando l’utente chiede di far crescere
la skill e hai verificato un nuovo flusso riutilizzabile, aggiungilo lì in
un file GPL-3.0-or-later. Includi condizioni d’uso, azioni ed esito da
verificare. Conserva le procedure già presenti e riprova un flusso
esistente insieme al nuovo.
