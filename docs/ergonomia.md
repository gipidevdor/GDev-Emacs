# Ergonomia e integrità dei flussi

Da **Strumenti › Tutti i comandi GDev** esplori i moduli attivi. La
**Tavolozza dei comandi** cerca le azioni dei menu per nome. Il riquadro
**Comandi** e **Cerca comandi del contesto…** seguono il documento o lo
strumento attivo. `C-h d m` apre la guida del modulo. In
[Mappa dei tasti](keymap.md) trovi i prefissi e i tasti funzione.

## Inventario riproducibile

La [verifica di ergonomia e reattività](ergonomia-verifica.md) e la campagna
di [ricerca fluida](ricerca-fluida-verifica.md) raccolgono ricognizione,
misure, correzioni e limiti osservati.
Il [catalogo degli algoritmi](algoritmi-e-visualizzazione.md) distingue
complessità, strutture condivise e scelte di visualizzazione.

Dalla radice esegui `./bin/gdev audit` per leggere l'inventario JSON del
checkout con il profilo distribuito. La riga di comando legge i registri
già usati da moduli, menu, viste e tastiera. Puoi confrontare le rilevazioni
di due revisioni in uno stesso ambiente. Ogni rilevazione parte con stato
e configurazione temporanei, anche se hai selezionato un profilo privato.

| Dato | Cosa puoi verificare |
| --- | --- |
| `modules`, `default_modules` | Moduli presenti e moduli attivati dal modello |
| `definitions` | Dichiarazioni interattive nei sorgenti GDev, con file e riga |
| `menu_routes` | Percorsi e scorciatoie dichiarate dei menu, incluse le azioni soggette a condizioni |
| `key_routes` | Tasti GDev globali, dei linguaggi e delle mappe di modalità già caricate, con comando dichiarato ed effettivo |
| `view_routes` | Azioni dichiarate dai profili contestuali delle viste |
| `cli_commands`, `live_actions` | Azioni della riga di comando e dell'interfaccia per agenti |
| `project_operation_contracts`, `project_operation_model` | Motori riconosciuti, capacità e verifica esaustiva dei predicati operativi |

Nell'editor il comando effettivo dipende anche dal profilo privato,
dal buffer, dalla selezione e dall'eventuale strumento aperto. Il menu
mostra le azioni disponibili e i comandi contestuali aggiornano la vista
quando cambia il bersaglio. Per ispezionare i tasti di una sessione usa
[le azioni per agenti `shortcuts` e `commands`](agenti.md).

## Riscontro con VS Code

Il confronto segue le azioni quotidiane su documenti, gruppi, albero e
terminale. Per i titoli delle schede GDev usa l'asterisco come indicatore
testuale delle modifiche. [Interfaccia di VS Code](https://code.visualstudio.com/docs/editing/getting-started/userinterface) · [Modifica e salvataggio](https://code.visualstudio.com/docs/editing/codebasics) · [Terminale integrato](https://code.visualstudio.com/docs/terminal/basics)

| Flusso | In GDev |
| --- | --- |
| Modifiche e salvataggio | Asterisco nel titolo, anche nelle schede inattive. **File › Salva tutti i file** scrive i documenti con un percorso. Le bozze si recuperano alla riapertura. |
| Navigazione tra editor | `⌘P` apre file e posizioni. `⌥⌘←` e `⌥⌘→` percorrono le schede del gruppo. Puoi riordinarle trascinando o con `C-c b ←` e `C-c b →`. **Finestra › Documenti aperti…** porta al gruppo scelto. |
| Anteprima, divisione e riapertura | Clic singolo per l'anteprima, doppio clic o modifica per conservarla. **Dividi** gestisce i gruppi. `⇧⌘T` recupera l'ultima scheda chiusa con la sua posizione. |
| Gestione dell'albero | Rivela il documento attivo, cerca fra le voci visibili e comprimi i rami. Seleziona più voci con `⌘` o `⇧` e aprile, confronta due file o copia i percorsi. Più cartelle possono convivere nello stesso spazio. |
| Ricerca, confronto e segnalazioni | Cerca nei file con anteprima delle sostituzioni, confronto con il file salvato e pannello **Problemi** collegato alle righe del sorgente. |
| Cronologia del file | **File › Cronologia del file** unisce salvataggi locali e registrazioni Git. Puoi filtrare le origini, confrontare due versioni o una versione con il documento, consultare e ripristinare. [Cronologia in VS Code](https://code.visualstudio.com/docs/sourcecontrol/history) |
| Terminale | **+** apre una sessione, **⌄** sceglie il profilo e **◫** affianca una seconda sessione. Puoi cambiare il fuoco con `C-c o ]` e nascondere il pannello lasciando attivi i processi. |

## Percorsi da verificare

Per ogni azione controlla l'elemento a cui si applica, il comando
effettivo e il risultato. Un clic, una scorciatoia e una scelta di menu
equivalenti devono produrre lo stesso documento, posizione e spazio di
lavoro. Se il bersaglio cambia durante l'attesa, l'azione richiede una
nuova scelta. Dopo un annullamento controlla anche contenuto, selezione
e disposizione. La semplicità della vista dipende da regole coerenti
tra le superfici. [Apple HIG per macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) · [Menu](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) · [Tastiera](https://developer.apple.com/design/human-interface-guidelines/keyboards) · [Annulla e ripristina](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) · [Jony Ive, prefazione a *Designed by Apple in California*](https://www.apple.com/newsroom/2016/11/designed-by-apple-in-california-chronicles-20-years-of-apple-design/)

| Percorso | Entrata normale | Esito e recupero da verificare |
| --- | --- | --- |
| File, cartelle e progetti | **File**, ricerca rapida, Esplora file | La scelta apre l'elemento indicato nel gruppo attivo. Uscire da un'anteprima ripristina documento e posizione. |
| Schede e spazi di lavoro | Schede, **Finestra**, `C-c w` | Duplicazione, chiusura e ripristino conservano cartelle, viste e modifiche secondo la scelta. |
| Pannelli e concentrazione | **Vista**, `⌘J`, × del riquadro | Il pannello riapre lo strumento attivo. Un errore durante l'apertura lascia l'editor in concentrazione. La × resta disponibile anche con la riga delle schede nascosta. |
| Barra, riquadro e menu contestuale | Menu, Comandi, clic destro, `Shift-F10` | La stessa azione si applica alla voce o alla selezione indicata. Cambi di radice o selezione invalidano una scelta precedente. |
| Modifica, ortografia e formattazione | **Modifica**, **Codice**, `C-c !` | Annulla e ripristina seguono lo stato del documento. Taglia e copia rispettano la selezione. I risultati di diagnostica superati vengono scartati. |
| Ricerca nel documento e navigazione | **Cerca**, `⌘F`, `⌘G`, `⇧⌘G`, definizioni e riferimenti | Ripetere avanza nella direzione richiesta anche dopo la chiusura della ricerca. Definizioni e riferimenti usano l'editor attivo. |
| Ricerca e sostituzione nel progetto | **Cerca nei file**, anteprima e conferma | Le sostituzioni usano il gruppo di risultati confermato. Una revisione cambiata invalida l'anteprima. Un errore durante l'applicazione ripristina il gruppo. |
| Linguaggi, completamento e REPL | **Codice**, `C-c l`, **Terminali** | Il file e il linguaggio attivi determinano strumenti e comandi. I prefissi del linguaggio rimangono locali. |
| Compilazione ed esecuzione | **Progetto**, `F7`, profili di avvio | Il comando usa radice, argomenti, ambiente e prerequisiti del profilo. Una compilazione fallita arresta la catena. |
| Test | **Vista › Test**, **Rileva test**, `F6` | Il catalogo segue il pacchetto del documento attivo. Una voce del pacchetto precedente perde validità quando cambi pacchetto. |
| Debug | **Debug**, `F5`, riquadro Debug | Sessione, progetto, punti di interruzione e posizione del sorgente coincidono. Dopo una compilazione, la prosecuzione appartiene allo spazio che l'ha avviata. |
| Profilazione | **Profila**, `C-c P` | Il rapporto resta associato all'esecuzione corretta. Risultati assenti e strumenti mancanti hanno uno stato leggibile. |
| Git e collaborazione | **Hit**, **HitHub**, `C-c g` | Repository, ramo, file e revisione corrispondono alla selezione. Una risposta precedente perde validità quando cambia la richiesta. |
| Note e Agenda Org | **Note e procedure**, `C-c n a`, `C-c n A` | L'Agenda mantiene l'identità della voce quando cambia la disposizione. L'apertura porta al documento Org o al repository associato. |
| Scrittura, LaTeX e PDF | **Nuovo progetto**, **Scrittura**, visualizzatore | Il progetto attivo governa fonti, bozze, versioni e compilazione. Aprire una bozza conserva il testo in corso. L'esportazione Org rispetta le esclusioni. |
| Terminali e macchine remote | **Terminali**, `C-c r` | La cartella indicata decide dove si apre il terminale. La scelta dell'host e l'annullamento precedono l'avvio della connessione. |
| Ambiente, infrastruttura e dati | **Strumenti**, comandi dei moduli attivi | Interprete, ambiente, connessione e risorsa vengono risolti dal progetto e dalla scelta esplicita. |
| Agenti e lavorazioni | **Vista › Attività › Lavorazioni**, `C-c w L`, **Agenti**, CLI, MCP | Il pannello cerca i piani dello spazio e apre la composizione accanto al sorgente. Verifica ed esecuzione condividono le azioni del sorgente. L'esito indica i passi completati e il primo fallito. |
| Lettura e comunicazioni | **Strumenti**, **Comunicazioni**, **Scrittura** | La vista segue l'elemento scelto. Per vocabolario, browser, posta e feed contano le impostazioni del servizio effettivo. |
| Impostazioni, manutenzione e ripristino | **Preferenze**, `C-h d`, `gdev doctor` | Il profilo selezionato governa la modifica. Un fork locale conserva le proprie modifiche quando incorpora una revisione a monte. |

## Verifiche ripetibili

- La [suite ERT](../test/gdev-test.el) verifica azioni, precondizioni e
  transizioni. Le prove di avvio usano il profilo distribuito e le prove
  del Workbench esercitano selezione, annullamento, cambio spazio e ripristino.
- La verifica del riquadro Test è stata ripetuta con due pacchetti Node
  adiacenti, scoperta reale dei test e rapporto JUnit. Il cambio di
  pacchetto invalidava una voce già selezionata prima della nuova esecuzione.
- Le prove di AppKit includono ×, testo modificato e riapertura allo
  stesso punto, con tema chiaro e scuro e area editor stretta.
  Le prove dei servizi esterni dipendono da host, credenziali e strumenti
  presenti sulla macchina. L'inventario registra la superficie esposta;
  le prove ERT usano ambienti controllati per tali integrazioni.

## Tavolozza su un progetto grande

Misura della ricerca file su macOS con un repository Git locale di 30.000
percorsi, distribuiti in 300 cartelle. Il banco chiama la stessa tabella di
completamento usata da `⌘P` e misura quando accetta un percorso noto.
Il tempo esclude il rendering grafico. Mediana di sei riaperture nello
stesso processo, dopo una prima ricerca a cache vuota.

| Misura | Prima | Con riuso dell'indice |
| --- | ---: | ---: |
| Prima proposta alla riapertura | 846,4 ms | 2,8 ms |
| Risposta della verifica a file invariati | 1.500.068 B | 67 B |

La prima apertura ha impiegato 816 ms con la cache vuota. La verifica in
secondo piano resta di circa 800 ms. La prova ha trattenuto circa 2,5 MiB
aggiuntivi nell'heap Lisp dopo la raccolta. Il budget globale degli indici è
6 MiB stimati e i file vengono riletti mentre la tavolozza è aperta.

Per ripetere avvio, compilazione e suite in una copia di prova consulta
[i comandi di verifica del repository](../AGENTS.md#comandi-di-verifica-dalla-radice).
