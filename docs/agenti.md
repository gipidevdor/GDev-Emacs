# GDev-Emacs per agenti IA

<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

Scegli **gdev-develop** per migliorare GDev-Emacs. Scegli **gdev-use** per
lavorare in un progetto con l’editor. In Codex usa `$gdev-develop` e
`$gdev-use`. In Claude Code usa `/gdev-develop` e `/gdev-use`.
Entrambi leggono le stesse [skill](../.agents/skills/) nel repository.
Per usarle in un progetto esterno, puoi indicare il percorso del
relativo `SKILL.md` all’agente.

## Inizia dalla CLI

Dalla radice del repository:

```sh
./bin/gdev agent use
./bin/gdev agent develop gdev-search-
```

Il primo comando scopre i comandi della CLI, i moduli del modello distribuito e
i percorsi delle guide. Il secondo aggiunge l’elenco dei moduli installabili
dal repository e cerca le definizioni che iniziano con `gdev-search-`. Ometti
il prefisso per l’inventario senza ricerca. I due comandi leggono il checkout
corrente, anche con modifiche locali. La scoperta legge solo i sorgenti
distribuiti e funziona con l’editor chiuso.

## Collega il server MCP

Il server locale `bin/gdev-mcp` parla MCP su stdio. È un Emacs batch che
resta attivo per tutta la sessione del client e carica `lisp/gdev-mcp.el`,
senza altri linguaggi. La configurazione del repository lo offre in Codex e
Claude Code. Apri il repository nel client e, se richiesto, autorizza il
server di progetto. Puoi verificare la configurazione con `codex mcp get gdev`
o `claude mcp get gdev`.

Il server funziona in due modalità:

- **Dal vivo.** Subito dopo l’avvio di GDev il modulo `:tools agent` apre un
  socket Unix privato con `gdev-mcp-server`. Senza argomenti, `bin/gdev-mcp` cerca
  l’istanza avviata dallo stesso checkout con la stessa cartella di stato e
  offre tutti gli strumenti. Ogni chiamata passa da quel socket e diventa una
  chiamata di funzione nell’editor, senza altri processi. Uno strumento
  semplice risponde in meno di un millisecondo. Senza il modulo, apri il
  socket con `M-x gdev-mcp-server-start` e chiudilo con
  `M-x gdev-mcp-server-stop`. Per non aprirlo all’avvio, imposta
  `gdev-agent-mcp-autostart` a `nil` nella configurazione privata.
- **Senza editor.** Se nessuna istanza è raggiungibile, il server offre solo
  `gdev_discover` e legge i sorgenti del checkout nel proprio processo.

Il server sceglie la modalità quando il client elenca gli strumenti. Se avvii
GDev dopo il client, riapri la sessione del client.

Per collegare una finestra precisa, per esempio un’istanza con un’altra
cartella di stato, usa `M-x gdev-agent-copy-socket` in quell’istanza. Incolla
il percorso copiato nel comando per il tuo client, dalla radice del
repository:

```sh
codex mcp add gdev-live -- "$PWD/bin/gdev-mcp" --socket "/percorso/al/socket"
claude mcp add --transport stdio --scope local gdev-live -- "$PWD/bin/gdev-mcp" --socket "/percorso/al/socket"
```

Con `--socket` il server chiede una volta a quell’istanza, attraverso il
server Emacs, di aprire il socket MCP, poi usa solo quello. Riapri la sessione
del client dopo la configurazione. Per un altro client MCP, configura il
percorso assoluto di `bin/gdev-mcp` come comando stdio e passa gli stessi
argomenti. Imposta `EMACS` per scegliere l’eseguibile di Emacs.

| Strumento | Operazione |
| --- | --- |
| `gdev_discover` | Inventario `use` o `develop`, con ricerca per prefisso in modalità `develop`. |
| `gdev_status` | Profilo, radici, documento, moduli e identità della transazione attiva in `state.assurance_transaction`. Il dato non interroga l'archivio durante il ridisegno. |
| `gdev_commands` | Azioni disponibili nei menu del contesto corrente. Richiede Workbench. |
| `gdev_shortcuts` | Cerca i tasti effettivi di un comando o il comando assegnato a un tasto. |
| `gdev_open_file` | Apre un file locale esistente nel gruppo editor attivo. |
| `gdev_open_folder` | Apre una cartella locale e sostituisce le radici dello spazio attivo. |
| `gdev_lavorazione_catalogo` | Legge le azioni pubblicate dai moduli attivi, con tipi e dipendenze. |
| `gdev_lavorazione_apri` | Apre o crea una bozza `.lavorazione` in Composizione. |
| `gdev_lavorazione_leggi` | Legge il piano aperto, la revisione e l'eventuale errore di validazione. |
| `gdev_lavorazione_componi` | Valida il piano completo, aggiorna la bozza e ridisegna il riquadro aperto. |
| `gdev_lavorazione_salva` | Salva la revisione indicata della bozza. |
| `gdev_cursor_state` | Legge un tratto del documento aperto, la revisione e i cursori degli agenti. |
| `gdev_cursor_place` | Posiziona uno o più cursori dello stesso agente nel documento. |
| `gdev_cursor_write` | Inserisce lo stesso testo ai cursori dell'agente con un solo annullamento. |
| `gdev_cursor_clear` | Rimuove i cursori dell'agente dal documento. |
| `gdev_eval` | Valuta Emacs Lisp nell’editor e restituisce il valore stampato e i messaggi. |
| `gdev_command` | Esegue un comando interattivo nella finestra selezionata, con un argomento prefisso facoltativo. |
| `gdev_keys` | Preme una sequenza di tasti in notazione Emacs, comprese le risposte ai prompt. |
| `gdev_open_location` | Apre un file locale esistente alla riga e alla colonna indicate. |
| `gdev_buffer_read` | Legge un tratto di un buffer con file, modalità, modifiche, punto e regione. |
| `gdev_buffers` | Elenca i buffer aperti con file, modalità e modifiche. |
| `gdev_layout` | Descrive finestre e ruoli nel Workbench, spazi di lavoro e stato dello spazio corrente. |
| `gdev_messages` | Legge le ultime righe di `*Messages*`. |
| `gdev_assurance` | Legge l'archivio di [assicurazione ingegneristica](assicurazione/README.md): `status`, `list`, `show`, `verify`, `assess`, `capability`, `trace`, `impact`, `requests`, `standards`, `standard-assess`. `standards` consulta il catalogo anche senza archivio. Nessuna scrittura. |
| `gdev_assurance_request` | Accoda una proposta per una transazione: `advance`, `evidence`, `assess`, `artifact`, `link`, `standard-proof`. La persona legge dati e digest e conferma dalla CLI o in **Assicurazione › Proposte**. L'azione conserva l'identità di agente; non soddisfa un obiettivo che richiede una verifica umana. Scelta degli standard e decisioni sono riservate alla persona. |

Nelle letture `show`, `assess` e `standard-assess`, `argument` vuoto usa la
transazione scelta nel Workbench se `root` è vuoto o coincide. Una radice
esplicita diversa non eredita la scelta. Senza una scelta attiva occorre
indicare l'identificativo. Le scritture degli agenti restano proposte:
la vista non converte l'identità dell'agente in quella della persona.

Le operazioni dal vivo compaiono quando il server raggiunge un’istanza. Il
server usa il processo Emacs già in esecuzione e verifica che appartenga allo
stesso checkout. Ogni richiesta legge lo stato corrente. Per esempio, «Apri il README
in GDev e dimmi in quale spazio si trova» usa l’apertura e verifica lo stato.
Per aggiungere una cartella allo spazio usa **Progetto › Aggiungi cartella allo
spazio…** nell’editor.

## Pilota l’editor

`gdev_eval` valuta una o più forme Emacs Lisp nel buffer della finestra
selezionata. In `value` restituisce la stampa dell’ultimo valore, fino a
65536 caratteri, e `truncated` indica un eventuale taglio. `gdev_command`
esegue un comando come da tastiera. Il campo `prefix` accetta un intero, `-`
oppure `C-u` ripetuto fino a quattro volte. `gdev_keys` preme tasti come
`C-x b *scratch* RET`. Le tre operazioni riportano in `messages` le righe
comparse in `*Messages*` durante l’esecuzione, anche in caso di errore.

`gdev_buffer_read` legge fino a `length` caratteri da `offset`, contati da zero
sull’intero buffer, e restituisce `next_offset` per il tratto successivo. I
dati del buffer riportano `point`, contato da zero, con `line` e `column`
della finestra che lo mostra. `gdev_open_location` conta righe e colonne da 1.
`gdev_layout` assegna a ogni finestra un ruolo: `editor`, `panel`, `left`,
`commands`, `auxiliary` o `side`.

Il server applica queste regole di sicurezza:

- Il socket è accessibile solo all’utente, in una cartella con permessi 0700
  come quella di `server-start`. Il server non apre porte TCP. Un processo
  collegato al socket esegue codice con i tuoi permessi, come con il server
  Emacs. Una cartella dei socket che sia un collegamento simbolico è rifiutata.
  Se la pulizia di `$TMPDIR` rimuove il file mentre GDev ascolta, un controllo
  ogni cinque minuti, o un nuovo `gdev-mcp-server-start`, riapre il socket.
  Una riga in ingresso oltre 8 MiB senza fine riga chiude la connessione.
- `gdev_eval`, `gdev_command` e `gdev_keys` non partono mentre il minibuffer o
  una modifica ricorsiva attendono l’utente. Con `force: true` agiscono
  comunque, per esempio per rispondere con `gdev_keys` a un prompt aperto.
- Ogni esecuzione ha un tempo massimo in `timeout`, da 1 a 300 secondi, con
  10 come valore predefinito. Allo scadere l’esecuzione si interrompe con un
  errore. Un ciclo Lisp che non attende mai non vede la scadenza: interrompilo
  con **C-g** nell’editor. Il server attende la risposta per `timeout` più 5
  secondi, e almeno 30.
- In `gdev_eval`, `gdev_command` e `gdev_open_location` una richiesta di
  input diventa un errore e l’editor non resta in attesa; l’apertura di un
  file ha un tempo massimo di 25 secondi. Passa i valori nella forma o usa `gdev_keys`,
  che risponde ai prompt con i tasti indicati.
- Durante l’esecuzione il debugger resta spento. Un errore diventa una
  risposta con `ok: false` e non chiude né l’editor né il socket.

## Scorciatoie e cursori degli agenti

Usa `gdev_commands` per orientarti nella vista attiva. Con
`gdev_shortcuts` puoi cercare, per esempio, `gdev-undo`, `s-z` o
`C-c c L` nel campo `query`. La risposta verifica il collegamento
effettivo con le personalizzazioni e i tasti locali e restituisce anche
la forma mostrata a schermo, per esempio **⌘Z**.

1. Apri il documento in GDev e usa `gdev_cursor_state` con il
   `path` assoluto. Ricevi testo, revisione e posizioni già occupate.
   Usa `offset` per leggere il tratto successivo. Ogni risposta
   include fino a 4096 caratteri della bozza in memoria.
2. Usa `gdev_cursor_place` con `path`, `revision`, un nome `agent`
   stabile e da 1 a 32 `offsets` distinti. Gli offset partono da zero
   e contano caratteri Unicode. Ogni agente sceglie un nome diverso.
   Il cursore è sottolineato nel testo e mostra il nome al passaggio
   del puntatore.
3. Usa `gdev_cursor_write` con `path`, `agent`, `revision` e `text`.
   GDev inserisce il testo in tutti i punti dell'agente, nella bozza.
   Il cursore dell'utente conserva il suo punto nel testo e gli altri
   cursori seguono le modifiche. Se la revisione è superata, rileggi il
   documento prima di riprovare. Con la selezione disattivata, **⌘Z**
   annulla l'intera scrittura. Per le lavorazioni usa **Composizione**.
4. Rimuovi i cursori dell'agente con `gdev_cursor_clear`. Dall'editor,
   `M-x gdev-agent-cursors-clear-buffer` rimuove tutti quelli del documento.

La CLI espone `shortcuts QUERY`, `cursor-state FILE OFFSET`,
`cursor-place FILE AGENTE REVISIONE POSIZIONI.json`,
`cursor-write FILE AGENTE REVISIONE TESTO.json` e `cursor-clear FILE AGENTE`
dopo `gdev agent live SOCKET`. I file di richiesta contengono
rispettivamente un array di offset e una stringa JSON UTF-8.

Allo stesso modo la CLI espone `eval FORMA TIMEOUT FORCE`,
`command COMANDO PREFISSO TIMEOUT FORCE`, `keys TASTI TIMEOUT FORCE`,
`open-location FILE RIGA COLONNA`, `buffer-read BUFFER OFFSET LUNGHEZZA`,
`buffers`, `layout` e `messages RIGHE`. `FORCE` vale `true` o `false`.
`PREFISSO` e `BUFFER` accettano la stringa vuota.

## Componi una lavorazione con un agente

Chiedi all'agente di leggere il catalogo della tua sessione, aprire il
file `.lavorazione` e proporre il piano in **Composizione**. Le
operazioni usano un `path` locale assoluto. **Apri** e **Leggi**
restituiscono `composition` con il `plan` in memoria e la sua
`revision`. Passa a `gdev_lavorazione_componi` il percorso, la revisione
letta e il nuovo piano completo nel campo `plan`. Se hai modificato il sorgente nel
frattempo, rileggi la bozza e integra le modifiche prima di riprovare.
Per il salvataggio usa la revisione restituita dopo la composizione.
Puoi rivedere i passi e usare **Esegui…** nella GUI con la normale conferma.

Le stesse operazioni si usano con `gdev agent live SOCKET` seguito
da `lavorazione-catalogo`, `lavorazione-apri FILE`,
`lavorazione-leggi FILE`, `lavorazione-componi FILE REVISIONE PIANO.json`
o `lavorazione-salva FILE REVISIONE`. In `lavorazione-componi`,
`PIANO.json` è un file locale UTF-8 con il documento completo.
Una bozza con errori ha `plan: null` e una stringa in
`validation_error`. Rimane disponibile la sua revisione per proporre
una correzione.

## Contratto JSON

`gdev agent` scrive un oggetto JSON su stdout. Leggi `schema_version` prima
di interpretare il risultato. La versione iniziale è `1`. Un errore contiene
`ok: false` ed `error` e produce un codice di uscita diverso da zero.

- `use` e `develop` restituiscono `root`, `mode`, `interfaces`,
  `cli_commands`, `default_modules`, `live_actions` e `live_signatures`.
  Ogni firma riporta `action` e `arity`, il numero di argomenti dopo il nome
  dell'azione. Il campo facoltativo `offset` di MCP viene inoltrato come
  argomento CLI con valore predefinito zero. I percorsi in
  `interfaces` sono relativi a `root`. `default_modules` descrive il
  modello distribuito.
- `develop` restituisce anche `modules`, con il file di configurazione di
  ciascun modulo. Con un prefisso include `symbols`, con nome, tipo, file
  relativo, riga a partire da 1 e indicatore di comando interattivo.
  La ricerca copre le dichiarazioni al livello superiore nei sorgenti
  `lisp/`, `modules/` e `test/`.
- `live SOCKET status`, `live SOCKET commands`, `live SOCKET open-file FILE`
  e `live SOCKET open-folder CARTELLA` restituiscono `ok`, `action`,
  `root` e `state`. `state` descrive il profilo, le radici, il nome della
  finestra, il documento attivo e i moduli configurati. `commands` aggiunge
  le etichette e i nomi Lisp delle azioni, con scorciatoia quando disponibile.
  Le aperture richiedono un percorso assoluto locale e rispettano il normale
  flusso dell’editor. Se scade l’attesa, rileggi `status` prima di ritentare.
- `eval`, `command` e `keys` aggiungono `messages`, presente anche negli
  errori. `eval` restituisce `value` e `truncated`, `command` il nome in
  `command` e `keys` la sequenza in `keys`. `open-location` aggiunge
  `location` con `line` e `column`. `buffer-read` aggiunge `buffer`, `offset`,
  `text` e `next_offset`. `buffers`, `layout` e `messages` aggiungono
  rispettivamente `buffers`, `windows` con `workspaces` e `workspace`, e
  `messages`.

L’inventario viene ricostruito su richiesta. La ricerca salta i sorgenti privi
del prefisso. Dalla CLI le azioni dal vivo usano il socket Unix del server
Emacs, mentre il server MCP usa il proprio socket privato. La scoperta dei
comandi usa i menu già in memoria. La CI confronta nomi e arità con
`tools/list` e prova il trasporto su un processo Emacs isolato. Le prove ERT
in `test/gdev-mcp-test.el` coprono protocollo, strumenti di pilotaggio,
socket e controllo di flusso.

Le skill possono aggiungere
procedure verificate nelle proprie cartelle `references/extensions/`,
preservando quelle esistenti e riprovando i flussi già supportati.
