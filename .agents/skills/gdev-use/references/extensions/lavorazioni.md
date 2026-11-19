<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Lavorazioni

Usa un file `.lavorazione` per rendere ripetibile una sequenza di azioni di
GDev. Apri **Strumenti › Lavorazioni › Catalogo delle azioni** nel profilo
attivo. Una voce nella tavolozza **Comandi** o una funzione Lisp esistente
non è di per sé un'azione disponibile nelle lavorazioni.

1. Crea il file con **Nuova lavorazione…** per aprire **Composizione**.
   Per un file esistente, aprilo e premi `C-c C-e`. Aggiungi un passo
   dal catalogo del riquadro, compilane gli argomenti e usa i pulsanti
   per modificare, spostare o rimuovere le righe. La composizione
   rifiuta le modifiche che lasciano un passo senza il documento
   richiesto. Salva con **Salva** nel riquadro o `⌘S`. Se modifichi
   il sorgente JSON a mano, premi `g` nel riquadro prima di continuare.
2. Premi `C-c C-v` per verificare versione, nomi e tipi di tutti i passi.
   Il controllo dello schema non verifica la presenza dei file o delle
   occorrenze al momento dell'esecuzione. Se il catalogo non offre
   l'azione richiesta, individua il modulo pertinente e usa la procedura
   di sviluppo per aggiungerla.
3. Per eseguire una lavorazione, usa **Esegui…** in Composizione oppure
   premi `C-c C-c` nel riquadro o nel sorgente. Scegli la cartella
   locale di destinazione e controlla il riepilogo prima di confermare.
   Se il JSON è cambiato, usa **Aggiorna** nel riquadro e rileggi i passi.
   Ogni `apri-file` determina il documento dei passi successivi. Usa
   percorsi relativi interni alla cartella e assicurati che la cartella
   padre esista. Un passo `salva` scrive sul disco. Senza di esso, il
   testo modificato rimane nel buffer.
4. Controlla i file e le modifiche risultanti. Se un passo fallisce,
   GDev indica il passo e interrompe la sequenza. Controlla gli effetti
   dei passi precedenti prima di ripetere il piano. Per esempio,
   rieseguire un inserimento già riuscito può duplicare il testo.

Per una sostituzione precisa, usa `sostituisci` con il testo letterale
`prima` e `dopo`. Serve una sola occorrenza del testo originale. Per una
prova usa documenti temporanei e verifica il contenuto effettivamente
scritto. Vedi [Lavorazioni nel flusso di lavoro](../../../../../docs/workflows.md#lavorazioni).

Per uno snippet usa `inserisci-snippet` dopo `apri-file`. Scegli la
`chiave` tra le proposte del riquadro per il documento previsto.
Se non ci sono proposte, indica la chiave a mano e controllala al momento
dell'esecuzione. Il passo usa i
valori predefiniti e segnala chiavi ambigue o frammenti che richiedono
espansione interattiva. Il catalogo indica il modulo di ogni azione.

Con un agente collegato al socket dell'istanza, usa
`gdev_lavorazione_catalogo`, `gdev_lavorazione_apri` e
`gdev_lavorazione_leggi`. Invia a `gdev_lavorazione_componi` il piano
completo con la revisione appena letta. La bozza aggiornata compare
nel riquadro aperto. Se la revisione è cambiata, rileggi la bozza e
conserva le modifiche presenti. Salva solo quando richiesto con
`gdev_lavorazione_salva` e la nuova revisione. Per verificare
o eseguire dalla GUI usa il riquadro e la sua conferma.
Vedi [Componi con un agente](../../../../../docs/agenti.md#componi-una-lavorazione-con-un-agente)
per la configurazione e i comandi CLI.
