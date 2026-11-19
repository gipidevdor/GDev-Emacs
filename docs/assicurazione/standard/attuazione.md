# Attuazione degli standard nel processo

GDev permette di scegliere gli obiettivi di uno standard per una transazione,
registrare una verifica specifica e controllare prove e struttura prima dei
passaggi di stato. La scelta si aggiunge al profilo GES: i controlli del
profilo continuano ad applicarsi.

Il catalogo distingue due ambiti. **Clausola** usa identificativi presenti
nei dati locali: ASVS, SSDF, SLSA e gli indici parziali ECSS. **Documento** usa
la scheda ufficiale di uno standard di cui non è disponibile un indice
verificato. `@document` è un identificatore interno del controllo documentale,
non un numero di clausola. I criteri sono originali GDev, dichiarati in
[attuazione.eld](attuazione.eld): non riproducono testo normativo e non
attestano conformità, certificazioni o livelli ISO/SLSA.

## Consultare e scegliere

```sh
gdev assurance standards
gdev assurance standards owasp-asvs
gdev assurance standards ecss-e-st-40c
gdev assurance open "Verifica della modifica" core
gdev assurance standard-select GT-0001 "owasp-asvs#V1.2.1" "Requisito applicabile alla modifica"
```

Il catalogo si legge anche senza un archivio. Mostra edizione, stato, fonte,
ambito, obiettivi e fasi richieste. Le voci non verificate non sono
selezionabili. La voce di famiglia `iso-iec-3300x` rimanda alle quattro
edizioni individuali; NASA-HDBK-2203 resta da verificare perché le etichette
di versione delle fonti divergono.

La scelta richiede una persona e avviene in `PROPOSED`, `CLASSIFIED` o
`ANALYZED`, prima di qualsiasi autorizzazione. Si può usare l'identificativo
dello standard per scegliere tutti i suoi obiettivi, oppure `STANDARD#CLAUSOLA`
per un sottoinsieme. Più scelte si separano con virgole, senza spazi. Il limite
è 512 obiettivi per transazione. Una nuova scelta sostituisce quella corrente
e richiede prove nuove; le scelte precedenti restano nella catena.

La scelta fissa edizioni, criteri e impronte del catalogo. Se uno di questi
cambia dopo l'autorizzazione, la valutazione è `NOT_VERIFIED` e non si può
forzare la vecchia scelta: serve una nuova transazione con l'autorizzazione
appropriata. Un indice parziale non dichiara copertura delle clausole assenti.

## Raccogliere prove specifiche

Ogni obiettivo ha un controllo GDev distinto. Un rapporto generico non
soddisfa automaticamente tutti i requisiti ASVS o SSDF. L'operatore deve
confrontare la verifica con il riferimento applicabile, usando una copia del
testo cui ha diritto di accedere quando necessaria. Il nucleo controlla
l'esito dichiarato, la fase, l'attore, le impronte e i criteri strutturali;
non interpreta il testo del rapporto per stabilire la verità tecnica.

```sh
# Dopo CLASSIFIED, ANALYZED, AUTHORIZED e IMPLEMENTING:
gdev assurance advance GT-0001 VERIFYING
gdev assurance artifact GT-0001 test/caso-test.el test
gdev assurance standard-proof GT-0001 "owasp-asvs#V1.2.1" pass rapporti/verifica.txt
gdev assurance advance GT-0001 REVIEWING
gdev assurance standard-assess GT-0001
gdev assurance assess GT-0001
gdev assurance assess-record GT-0001
```

`standard-proof` raccoglie il file come prova `fact/collected` e registra
`pass` o `fail` per l'obiettivo scelto nella stessa transazione SQL. Dall'API
Lisp, `gdev-standard-proof` collega invece una prova `EV-*` già raccolta. La
prova deve appartenere alla stessa transazione ed essere successiva alla
scelta e all'ultimo ingresso nella fase richiesta. Prove ricostruite, vecchie
prove rietichettate e rapporti di un'altra transazione vengono rifiutati.

I criteri possono richiedere artefatti con ruoli specifici e relazioni
`requisito → sorgente → test`. Ogni artefatto di partenza deve avere il
collegamento richiesto: una sola relazione non copre tutti i requisiti. Per
IEEE 1012 e altri criteri di assicurazione serve una verifica umana indipendente
da chi ha portato la transazione nella fase di prova. Il nome dell'attore è
una dichiarazione, non un'autenticazione: vale lo stesso limite del nucleo.

Un nuovo ciclo di verifica richiede nuove prove. Registrare versioni nuove
degli artefatti o cambiare la tracciabilità rende superati i rapporti precedenti.
Anche modifiche, eliminazioni e cambi di tipo dei file correnti impediscono
di usare le vecchie prove. Le valutazioni registrate conservano un'impronta
del contesto: il confronto segnala i cambiamenti anche senza nuovi eventi.

## Decisioni e passaggi

```sh
gdev assurance standard-decision GT-0001 "owasp-asvs#V1.2.1" not-applicable "Motivo verificabile"
gdev assurance standard-decision GT-0001 "owasp-asvs#V1.2.1" waiver "Motivo e responsabilità"
gdev assurance standard-decision GT-0001 "owasp-asvs#V1.2.1" revoke "Revoca della decisione"
```

Le decisioni richiedono una persona. Dal profilo `secure` chi ha aperto la
transazione non decide sui propri controlli; `critical` non ammette deroghe.
Non si può derogare a un archivio incoerente o a una definizione cambiata.
La revoca ripristina la valutazione fondata sulle prove. Decisioni e rifiuti
restano nell'audit.

I passaggi a `REVIEWING`, `APPROVED` e `BASELINED` controllano gli obiettivi
scelti e già dovuti, compresi quelli che diventano dovuti con il passaggio.
Un esito negativo o non verificato blocca il passaggio. La firma Git applica
gli stessi esiti e confronta i byte degli artefatti con l'albero immutabile
da firmare, senza filtri o conversioni: l'indice e le prove devono riferirsi
agli stessi file. Aggiornare solo la copia di lavoro non convalida un indice
diverso. Anche i collegamenti simbolici sono confrontati come dati.

## Agenti, riproducibilità e archivio

Le letture MCP `standards` e `standard-assess` riusano la facciata CLI.
`gdev_assurance_request` può proporre `standard-proof` con gli argomenti
`["STANDARD#CLAUSOLA", "EV-0001", "pass"]`, ma non può scegliere standard o
prendere decisioni. La conferma resta esplicita e l'azione conserva il tipo
`agent`: non diventa una revisione umana per effetto della conferma.

La migrazione 6 aggiunge il genere di registrazione `standard` e il contesto
delle valutazioni senza riscrivere eventi, impronte o risultati precedenti.
Le definizioni storiche rimangono verificabili quando cambia il catalogo.
Le letture condividono una cache solo entro la richiesta; quella successiva
rilegge i dati e vede le modifiche. Non vengono introdotti timer o scansioni
durante la digitazione.

`capability` include i controlli scelti solo nelle transazioni che li adottano.
Le deroghe non contano come soddisfatte e il risultato non attribuisce un
livello ufficiale di capacità. Le garanzie contro chi controlla la shell o
può valutare Lisp arbitrario continuano a dipendere dai firmatari esterni e
dalla configurazione remota descritta nella [guida](../README.md).
