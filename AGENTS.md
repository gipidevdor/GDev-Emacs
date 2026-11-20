# Metodo di sviluppo di GDev-Emacs

Per sviluppare GDev usa [gdev-develop](.agents/skills/gdev-develop/SKILL.md).
Per operare nell’editor usa [gdev-use](.agents/skills/gdev-use/SKILL.md).
La [guida agli agenti](docs/agenti.md) descrive il catalogo del checkout
e il collegamento locale a una sessione Emacs.

## Dalla richiesta alla verifica

Lo sviluppo di GDev usa il progetto formale in `.gdev-assurance/project.eld`.
Prima di modificare codice di produzione seleziona o apri una lavorazione,
collega scheda e progetto, registra l'analisi e verifica l'autorizzazione.
Usa `gdev agente sviluppo` per la scoperta e `gdev agente assicurazione`
per operare senza editor conservando l'identità dell'agente. La sola
presenza del manifesto e un risultato CI positivo non attestano la
conclusione della lavorazione.

Gli agenti possono usare il profilo dell'utente nei limiti del suo mandato.
Quando la persona chiede esplicitamente di eseguire un suo passaggio, registra
la decisione effettiva, il riferimento alla lavorazione e chi la esegue per
suo conto. Non attribuire alla persona revisioni che non ha svolto. Un nome
utente da solo non cambia il tipo dell'attore e un agente non si concede
autorizzazioni. Per le normali operazioni conserva il canale agente.

A sorgenti stabilizzati aggiorna l'istantanea, passa a **In verifica** ed
esegui le procedure collegate. Registra prove, esiti e limiti nell'archivio;
le evidenze esterne vanno collegate al ciclo corrente. Prima della consegna
riporta identificativo, stato, controlli eseguiti e decisioni ancora dovute.
Usa **Consolidata** per lo stato conclusivo e **Versione di riferimento**
per la versione fissata e verificata.

1. Ricostruisci il flusso dalla sua normale entrata. Individua il comando, la scorciatoia, il menu e il modulo che lo governa. Registra il comportamento osservato e quello atteso in termini visibili a chi usa Emacs.
2. Controlla lo stato della copia di lavoro e conserva le modifiche già presenti. Limita le modifiche al comportamento richiesto e alle sue dipendenze dirette.
3. Per effetti visivi o interazioni con più soluzioni plausibili, riproduci il caso e realizza prototipi isolati prima di cambiare l'implementazione. Confrontali sugli stessi dati e alla stessa dimensione. Scegli in base a leggibilità, facilità d'uso, costo di manutenzione e prestazioni. Conserva le catture essenziali quando servono a mostrare la differenza.
4. Trasforma la soluzione scelta in una modifica verificabile. Conserva un solo punto di verità per ogni comportamento. Riusa i comandi, le facce e le primitive di Emacs già presenti. Documenta il motivo di ogni nuova dipendenza.
5. Prima di chiudere il lavoro, confronta il risultato con il flusso iniziale e controlla i casi limite pertinenti. Riporta le verifiche eseguite sul codice finale, con i limiti effettivi e le decisioni di interazione prese durante il lavoro.

Per le operazioni di progetto usa il [contratto tematico](docs/operazioni-progetto.md#contratto-tematico-e-modello-finito): radice comune, manifesti e scelte esplicite, preparazione, processo reale, esito e recupero. Registra ogni nuovo fornitore in `gdev-project-operation-contracts` e verifica anche l'uso dalla cartella senza un sorgente aperto. Un catalogo di capacità non sostituisce una prova di esecuzione.

## Criteri per interfaccia e interazione

- Ogni buffer visibile deve avere un pulsante × per chiuderlo, incluse le viste future e quelle senza schede. Usa la X della scheda o quella comune del Workbench. Il clic deve agire sulla vista indicata e rispettare le protezioni per le modifiche non salvate. Il minibuffer mantiene il normale comando di annullamento.

- Ogni modalità aggiunta da un modulo deve dichiarare un profilo con `gdev-ui-view-setup`. Per una vista nuova usa il [modello Lisp](templates/vista.el) e le facce semantiche della [guida dell'interfaccia](docs/interfaccia.md). La suite obbligatoria in CI verifica la dichiarazione del profilo, la compatibilità con la modalità padre e il contrasto delle superfici comuni.
- Per il lavoro grafico usa la finestra nativa di Emacs su macOS quando è disponibile. Un prototipo, una prova in terminale e una cattura dalla finestra nativa attestano aspetti diversi. Identifica la provenienza di ogni evidenza condivisa.
- Controlla tema chiaro e scuro, dimensione normale e ridotta, nomi lunghi e contenuto vuoto quando incidono sulla modifica. Per ciascuna variante verifica testo leggibile, contrasto, assenza di sovrapposizioni e accesso alle azioni per cui la vista esiste.
- Verifica tastiera, puntatore, conferma e annullamento nei flussi che li offrono. Selezione, fuoco e apertura devono corrispondere all'elemento visibile. Durante aggiornamenti, cambi di tema o ridimensionamenti, conserva l'identità dell'elemento selezionato quando è ancora presente.
- Applica le [Human Interface Guidelines di Apple](https://developer.apple.com/design/human-interface-guidelines/) pertinenti al componente. Usa il carattere di sistema per l'interfaccia, etichette concise in italiano e simboli affiancati a informazioni leggibili. Per il testo piccolo nelle tavolozze personalizzate verifica un contrasto di almeno 4,5:1 sulle superfici effettive.
- Misura il testo con il carattere mostrato. Mantieni accessibili i dati completi dei nomi abbreviati. Dimostra con un caso stretto che selezione e indicatori restano entro la colonna prevista.
- Per gli elementi senza uno stile dedicato usa le facce semantiche di Emacs e le regole del riquadro. Verifica una vista nuova con intestazione, selezione, testo secondario e azioni. Conserva le colonne a spaziatura fissa per tabelle, codice e terminali.

## Stato della personalizzazione

- Per ogni azione visibile identifica lo stato di partenza, la transizione e l'esito. Assegna a un solo modulo la responsabilità di ogni dato condiviso. Distingui lo stato del documento, del riquadro, dello spazio di lavoro e dell'applicazione.
- Fai passare lo stato condiviso dello spazio attraverso `gdev-workspace-state`. Registra ogni campo e il suo ciclo di vita. Pubblica insieme i campi che descrivono la stessa transizione. Per i risultati asincroni conserva l'identità dello spazio di origine e verifica che sia ancora aperto prima di applicarli. La suite ERT verifica l'accesso attraverso l'API.
- Collega clic, menu, tastiera e scorciatoie allo stesso comando quando rappresentano la stessa azione. Verifica che producano lo stesso stato osservabile, compresi fuoco, cartella attiva e disposizione dei riquadri quando pertinenti.
- Distingui lo stato da salvare dalle viste temporanee. Al ripristino ricostruisci l'interfaccia a partire dallo stato salvato. Valida le precondizioni prima di aggiornare lo stato condiviso e verifica che annullamenti ed errori lascino uno stato coerente.

## Criteri per il codice e la consegna

- Mantieni i moduli e i pacchetti Lisp di terze parti usati da GDev come fork nel repository. Registra ogni fork in `vendor/pacchetti.el` con versione, licenza, origine e revisione. Conserva gli avvisi e verifica che Emacs carichi la copia locale anche in presenza di una versione ELPA omonima.
- A ogni intervento valuta le correzioni e le ottimizzazioni pertinenti nei fork già usati. Se la modifica riguarda un comportamento comune, intervieni nel fork e verifica che i contratti esistenti continuino a funzionare.
- Affianca il nome scelto da GDev al nome originale del fork nella guida del modulo e nel catalogo delle dipendenze. Usa il nome GDev nelle etichette dell'interfaccia e conserva gli identificatori Lisp necessari alle integrazioni.
- Mantieni la compatibilità con la versione minima dichiarata nel progetto. Verifica le firme delle API quando differiscono tra versioni. Conserva i percorsi di avvio, l'uso da terminale e le configurazioni private pertinenti al lavoro richiesto.
- Mantieni reattivi digitazione e ridisegno. Misura il costo delle operazioni frequenti quando introduci scansioni, processi o operazioni temporizzate. Sfrutta indici, dati memorizzati per consultazioni successive e processi asincroni già disponibili.
- Copri le regressioni specifiche con prove mirate. Esegui i test ERT e la prova di avvio quando la modifica attraversa l'inizializzazione o più moduli. Per le modifiche a Emacs Lisp che devono essere native, esegui la compilazione e verifica il caricamento attraverso l'avvio ordinario.
- Esegui `git diff --check`. Ispeziona la modifica finale, il suo effetto sulle entrate utente e le eventuali modifiche concorrenti. Aggiorna documentazione e indicazioni a schermo quando cambia un flusso.
- A fine lavoro rimuovi prototipi temporanei, download ridondanti e risultati di compilazioni o prove rigenerabili che hanno esaurito il loro scopo. Conserva consegne, prove utili, dipendenze attive e file dell'utente. Riporta il risparmio di spazio quando lo hai misurato.

## Comandi di verifica dalla radice

```sh
./bin/gdev compile --native
GDEV_TEST_SMOKE=1 emacs --batch -Q -l early-init.el -l test/gdev-test.el -f ert-run-tests-batch-and-exit
git diff --check
```

Per una diagnosi mirata seleziona i test pertinenti con ERT. Quando cambiano i tasti documentati, rigenera la mappa con `./bin/gdev docs` e controlla le differenze.

Per non toccare la cartella di stato e la configurazione privata reali, esegui le prove con `GDEV_STATE_DIR` e `GDEV_USER_DIR` su cartelle temporanee. Il contratto della CLI e del server MCP si verifica con `python3 test/gdev-cli-contract-test.py`.

La CI richiede anche la copertura completa dei flussi di stato: dopo il comando seguente per `gdev-coverage-workspace-state` esegui lo stesso con `-f gdev-coverage-state-flows`.

La verifica di copertura dello stato condiviso richiede tutte le righe strumentabili di `lisp/gdev-workspace-state.el`. Eseguila con `emacs --batch -Q -l early-init.el -l test/gdev-test.el -l test/gdev-coverage.el -f gdev-coverage-workspace-state`. I test ERT coprono anche gli esiti diversi di una stessa riga e le transizioni tra più moduli.
