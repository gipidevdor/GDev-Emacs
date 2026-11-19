<!-- Generato da GDev; non modificare. Fonti sha256:897ef54c70b50a727699ae2a514370d63fce5878d6b5f286a5acd8772001c543 -->

# Rilascio

## Fonte: docs/assicurazione/stato-verifiche.md

# Stato delle verifiche della piattaforma governata

La definizione di progetto e la scheda operativa sono versionate nel
repository. Le esecuzioni reali e i loro log appartengono all'archivio
`.gdev/assurance`; le campagne isolate conservano rapporti con impronte.
Il ciclo completo con approvazioni simulate è una fixture di test.

Campagna locale del **19 novembre 2026**, su macOS. I risultati descrivono
le proprietà esercitate; questo documento non è una ricevuta di approvazione
o di rilascio.

## Risultati automatici

| Verifica | Esito osservato |
| --- | --- |
| ERT e avvio, Emacs 30.1 | 974 selezionati, 972 superati, 2 saltati, nessun errore. |
| ERT e avvio, Emacs 31.1 | 974 selezionati, 973 superati, 1 saltato, nessun errore. |
| Compilazione con avvisi espliciti | 716 file per versione, nessun errore o avviso; 5 file dichiarati intenzionalmente solo sorgente. |
| Compilazione nativa Emacs 31.1 | 178 file pronti senza errori o avvisi; avvio ordinario dell'app con vista Assicurazione e codice nativo caricati. |
| Contratti CLI e trasporto MCP | 14 casi superati, comprese letture paginate, Unicode e parametri mancanti. |
| Contratto Git e firme SSH | 9 casi superati, inclusi aggiramento dei ganci e ricevute alterate. |
| Tassonomie e fonti originali | 3 confronti indipendenti superati su CSV, XLSX e PDF locali. |
| Modello finito | 364 casi; i test rilevano anche guardie rese intenzionalmente scorrette. |
| Affidabilità | 7 casi; 1.280 operazioni generate, 174 guasti SQL, 8 punti di arresto DELETE/WAL. |
| Mutazioni | Tutte le 7 mutazioni intercettate da errori di comportamento; avvio e sintassi non valgono come intercettazione. |
| Documenti e rapporti | 16 documenti editoriali e rapporto del progetto riproducibili; controllo senza scrittura. |

La build terminale di Emacs 30.1 non dispone di compilazione nativa: quel
controllo viene saltato su tale build. La lettura del rapporto esterno di
affidabilità è saltata nella suite ordinaria e viene eseguita separatamente,
con il rapporto completo e le impronte dei sorgenti correnti. I test saltati
non vengono trasformati in risultati positivi.

Le coperture obbligatorie raggiungono il **100% delle righe strumentabili**
per stato condiviso, cinque flussi di stato, dodici moduli del nucleo di
assicurazione e tredici estensioni. Le relative campagne eseguono
rispettivamente 23, 155, 263 e 214 test, senza errori. La misurazione
aggiuntiva dei nuovi moduli di dominio resta distinta: non si rivendica
copertura completa dell'intera distribuzione. Le Preferenze raggiungono 198/200 righe nella loro campagna.

Le regressioni mirate comprendono piani vuoti, parametri Lisp con virgolette
e Unicode, conflitti con file aperti, permessi dei file, collegamenti
simbolici concatenati, artefatti verificati ma non inclusi nell'albero da
firmare, dipendenze fra lavorazioni, interruzioni, ripresa e processi Python
che ignorano la prima richiesta di arresto. Le prove dell'interfaccia
coprono anche scansioni terminate prima del ritorno dalla creazione del
processo e l'apertura del pannello Problemi senza segnalazioni sulle
versioni recenti di Flymake.

Una lettura completa del contesto del checkout ha identificato 3.920 file
sorgenti in 3,863 secondi. La vista esegue questa scansione in un processo
separato; i test verificano annullamento e risposte fuori ordine.

## Auto-applicazione e limiti

La lavorazione reale locale `GT-0001` collega
`.gdev-assurance/work/governed-development.eld`, applica
`SNIP-DOCUMENTATION` e usa `GDEV-VERIFY`. Scheda, parametri, istantanea,
tentativi, log e impronte restano nell'archivio locale. L'agente non la porta
oltre ANALYZED: autorizzazione e approvazione restano riservate a una persona.
Il successo tecnico della procedura non equivale alla chiusura formale.

Le evidenze automatiche utili si conservano in
`.gdev/assurance/reports/verification/`; il rapporto di affidabilità è
`.gdev/assurance/reports/reliability.json`. La CI ripete la campagna sui
propri sorgenti e conserva il rapporto come artefatto. I risultati locali
non dichiarano anticipatamente l'esito di una futura esecuzione remota.

**Verifica grafica finale incompleta**: l'app nativa ha caricato la vista
in una sessione isolata e i prototipi sono stati confrontati; il controllo
del Mac è tornato bloccato durante le prove finali. Il confronto visivo
conclusivo di temi, dimensioni e puntatore resta da completare. I controlli
automatici di profilo, chiusura delle viste e contrasto restano distinti.

Approvazione umana della distribuzione: **NOT_VERIFIED**. Configurazione
remota di firmatari e protezioni: da attivare nell'ambiente destinatario.
Nessuna certificazione normativa viene attribuita automaticamente.

Le lacune normative restano esplicite nella guida del progetto formale:
obblighi atomici NIST IR, altri documenti SLSA, tassonomie ISO/IEEE non
acquisite e indici ECSS parziali. Le fonti PDF già disponibili restano nel
repository e sono verificate tramite impronte e rigenerazione dell'indice.


## Fonte: docs/assicurazione/README.md

# Assicurazione ingegneristica

Il nucleo dell'assicurazione ingegneristica (Process Kernel) porta una
modifica da una proposta a una linea di base attraverso stati ammessi, e
conserva per ogni passaggio chi l'ha compiuto, quando e con quali prove. Carica
da solo, senza la configurazione di GDev, i moduli o un modello linguistico.

**Stato:** nucleo, profili, valutazioni, osservazioni di capacità e dati SLSA
disponibili. Sono implementati tracciabilità, adozione e recupero, generazione
di documenti, ricevute Git firmate e proposte MCP da confermare. I ganci sono
facoltativi; il controllo remoto richiede firmatari fidati e protezione del
ramo. Questi ultimi non si attivano modificando soltanto i sorgenti.
Restano le decisioni normative indicate nella [tabella di marcia](../roadmap.md).
L'analisi che ha portato a queste scelte è nel [rapporto della Fase A](../rapporto-fase-a.md)
e i riferimenti normativi sono nel [registro degli standard](../standard/README.md).

La [guida ai progetti formali](../progetto-formale.md) descrive compilazione dei
requisiti, tassonomie, schede delle lavorazioni, modelli e procedure eseguibili.
L’[autoverifica](../autoverifica.md) applica questi strumenti alla distribuzione.

## Leggere l'archivio

Dalla cartella di un progetto, o da una sua sottocartella:

```sh
gdev assurance status
gdev assurance list [STATO]
gdev assurance show GT-0001
gdev assurance verify
gdev assurance assess GT-0001
gdev assurance capability [PROFILO]
gdev assurance trace
gdev assurance impact [PERCORSO]
gdev assurance requests [RC-ID]
gdev assurance standards [STANDARD]
gdev assurance standard-assess GT-0001
```

- `status` mostra radice, file, versione dello schema, versione di SQLite,
  transazioni per stato, numero di eventi, prove e rifiuti e l'ultimo evento.
- `list` elenca le transazioni; con `STATO` (per esempio `proposed`) mostra
  solo quelle.
- `show` mostra una transazione con eventi, rifiuti e prove.
- `verify` rifà ogni impronta, controlla la catena e il legame fra prove ed
  eventi. Esce con 0 se tutto torna, con 1 se trova problemi.
- `assess` valuta una transazione rispetto ai controlli del suo profilo (vedi
  sotto). Esce con 1 se un controllo dovuto non è soddisfatto.
- `capability` aggrega osservazioni per controllo e profilo: distingue prove
  soddisfatte, assenti, ricostruite, deroghe e non applicabilità. Un archivio
  vuoto è `NOT_VERIFIED`; una deroga non aumenta la percentuale soddisfatta.
  Non assegna livelli ISO o SLSA, né certifica la capacità di un'organizzazione.
- `trace` elenca artefatti immutabili e relazioni dalla dipendenza al suo
  consumatore; `impact` segue anche dipendenze transitive e cicli. Senza percorso
  confronta i file correnti con l'ultima versione registrata di ciascun percorso.
  File eliminati, cambi di tipo e collegamenti modificati risultano cambiati.
- `requests` mostra i dati completi e il digest delle proposte, prima della
  conferma. Le letture CLI e MCP condividono il catalogo delle operazioni e
  una sola istantanea SQL per richiesta.

I sottocomandi non creano, non migrano e non modificano l'archivio: la
connessione rifiuta ogni scrittura. Lo stesso vale per lo strumento MCP. Senza un archivio, `status` lo dice ed esce
con 0; gli altri escono con 1. Un sottocomando o un operando sbagliato esce con
2.

## Controlli, profili e valutazione

Un **controllo operativo** dice che cosa l'archivio deve mostrare perché una
transazione sia in regola: un passaggio compiuto da una persona, una prova
raccolta in un certo stato, un'integrità verificata. I controlli stanno in
[controlli.eld](../profili/controlli.eld) e li scrive GDev: non riproducono testo
normativo. Un **profilo** è una composizione di controlli, i propri più quelli
dei profili che eredita ([profili.eld](../profili/profili.eld)). Gli
identificativi sono quelli dello schema dell'archivio.

| Profilo | Controlli propri | Eredita |
| --- | --- | --- |
| `core` | GES-C01 autorizzazione di una persona prima dell'implementazione; GES-C02 catena di audit integra; GES-C03 approvazione di una persona prima della linea di base | |
| `quality` | GES-Q01 prova di verifica raccolta in `VERIFYING` | `core` |
| `secure` | GES-S01 chi propone non autorizza; GES-S02 analisi del rischio registrata in `ANALYZED`; GES-S03 revisione registrata in `REVIEWING` | `quality` |
| `high-assurance` | provvisorio: GES-H01 verifica registrata da chi non ha portato la transazione in `VERIFYING`; GES-H02 revisione registrata da una persona; GES-H03 valutazione registrata prima della linea di base | `secure` |
| `critical` | provvisorio: GES-K01 autorizzazione e approvazione di persone diverse; GES-K02 nessuna deroga | `high-assurance` |

**I controlli di `high-assurance` e `critical` sono una proposta di GDev, da
rivedere**: non discendono da uno standard e non sono stati decisi. La
valutazione lo dice con «provvisorio» a ogni uscita. Si cambiano modificando
`controlli.eld` e `profili.eld`, senza toccare il codice. GES-K02 non ammette
decisioni: non si può derogare alla regola «nessuna deroga».

**Riferimenti agli standard.** I controlli del profilo citano clausole SSDF 1.1,
per esempio PW.8.2, con `:standard`, `:edizione` e `:clausola`. Il caricatore
([gdev-standards.el](../../../lisp/gdev-standards.el)) richiede una voce corrente
all'edizione indicata e una clausola presente nei dati locali. Gli obiettivi
scelti per transazione estendono i riferimenti a ASVS, SLSA e indici parziali
ECSS. Dove manca un indice verificato, ISO, IEEE, NASA e NIST usano soltanto
un riferimento bibliografico esplicito (`:ambito standard` senza `:clausola`)
e criteri documentali originali GDev. **Il collegamento non afferma che il
controllo soddisfi uno standard.** Vedi la [guida di attuazione](../standard/attuazione.md).

I file `.eld` si leggono come dati, senza valutarli. In Emacs 31 `#.` non si legge
mai; in Emacs 30.1, la versione minima, il caricatore spegne `read-eval`. Quest'ultimo
percorso non l'ho potuto provare, perché qui c'è solo Emacs 31.1: la prova con un
effetto collaterale vale dove la variabile esiste.

**Esiti.** `gdev assurance assess` calcola per ogni controllo:

| Esito | Quando |
| --- | --- |
| `SATISFIED` | l'archivio mostra tutto ciò che il controllo richiede |
| `NOT_SATISFIED` | il controllo è dovuto e manca ciò che richiede |
| `NOT_VERIFIED` | lo stato da cui il controllo è dovuto non è stato raggiunto, oppure le prove sono solo ricostruite o di un altro genere |
| `NOT_APPLICABLE` | la transazione è `REJECTED` o `CANCELLED`, oppure una persona ha dichiarato il controllo non applicabile |
| `WAIVED_WITH_AUTHORIZATION` | una persona ha derogato a un controllo che non sarebbe soddisfatto: l'esito riporta chi, perché e che cosa sarebbe risultato senza la deroga. **È l'unico modo di ottenerlo** |

Senza prove un controllo dovuto non è soddisfatto: la valutazione non dichiara
nulla che l'archivio non mostri. Non si fida del nucleo: rilegge la catena e
trova anche ciò che le regole avrebbero impedito, per esempio un passaggio a
`AUTHORIZED` di un agente in una catena riscritta. **La valutazione riguarda i
controlli di GDev, non la conformità a uno standard**, e lo ripete a ogni uscita.

## Decisioni su un controllo

Una persona può decidere, per una transazione, che un controllo del suo profilo
non è soddisfatto e lo accetta (`waiver`, deroga) oppure non si applica
(`not-applicable`). Si registra con `gdev-decision-add`, che chiede il genere, il
controllo, il motivo, in una riga, e chi decide. La decisione ha una riga
nell'archivio, `DC-0001`, ed è un evento `decision` della catena, che riporta il
genere, il controllo e l'impronta del motivo.

- **Solo una persona.** Lo chiedono la regola `decision-human-only` e un vincolo
  dell'archivio, che rifiuta una riga con un attore diverso da `human`.
- **Solo controlli del profilo che ammettono decisioni.** La catena di audit
  integra (GES-C02, `:decidibile nil`) non si deroga né si dichiara non
  applicabile.
- **Non retroattive.** Una transazione `BASELINED`, `REJECTED`, `CANCELLED` o
  `SUPERSEDED` non ne accetta di nuove.
- **Dal profilo `secure` in su non decide chi ha aperto** la transazione.
- Un rifiuto resta nella catena con la regola, come ogni altro.
- Una decisione non si revoca: ne vale la più recente di ciascun genere. Una
  dichiarazione di non applicabilità prevale sulla deroga.
- Una deroga a un controllo già soddisfatto non cambia l'esito. I controlli di
  passaggio (`gdev-gates`) non si derogano: sono regole del processo.

`gdev assurance show` elenca le decisioni, `status` le conta e `verify` controlla
che ogni decisione abbia il suo evento e viceversa. Non esiste ancora un canale
per prenderle da un agente o dalla riga di comando: per lo stesso motivo di
tutto il nucleo, in questo processo nulla impedisce a chi valuta Lisp di
dichiararsi una persona.

## Valutazioni registrate

`gdev assurance assess` calcola e stampa: non scrive. Per conservare una
valutazione si usa `gdev-assessment-record`, che la calcola e la registra con
`AS-0001`, chi l'ha richiesta e quando. L'archivio tiene una riga per valutazione
(impronte degli ingressi e dei risultati), una riga per ogni controllo, in ordine,
e un evento `assessment` nella catena che riporta le due impronte. Alterare i
risultati registrati senza rifare la catena lo rileva `verify`.

`verify` ricostruisce anche l'impronta degli ingressi dai dati registrati,
controlla che la testa della catena preceda l'evento della valutazione e che
il profilo sia quello della transazione. Le posizioni dei risultati devono
essere consecutive da 1: spostarle lasciando invariato l'ordine è un errore.

- **Confronto.** `assess` riporta la valutazione registrata più recente: quanti
  eventi sono arrivati dopo, se i controlli sono cambiati e quali esiti sono
  cambiati, con l'esito di prima e di adesso. Per i controlli aggiunti o rimossi,
  il lato mancante appare come «assente» nel testo e come `null` nei dati JSON.
  Mostra, per esempio, che un
  controllo soddisfatto è diventato non soddisfatto perché la catena è stata
  alterata.
- **Chi.** Qualunque attore può registrare una valutazione: è un risultato
  calcolato dal nucleo, non una dichiarazione. Il dominio `assessment` ha la sola
  regola di origine del canale.
- **Che cosa non fa.** Una valutazione registrata non si ricalcola «com'era»: il
  confronto usa lo stato attuale dell'archivio, e il controllo sull'integrità della
  catena (GES-C02) riguarda sempre l'archivio intero.
- `assess-record` registra dalla CLI; un agente propone `assess` e attende la
  conferma dei dati esaminati.

**Riproducibilità.** Gli stessi dati danno lo stesso risultato. Ogni valutazione
riporta l'impronta della catena, quella dei controlli e quella dei due insieme
(`input_digest`): se una cambia, la valutazione non è più confrontabile con la
precedente.

## Nell'editor

**Progetto › Assicurazione del progetto**, `C-c p i`, apre la vista dello
spazio: transazioni, controlli, standard, tracce, proposte, documenti,
capacità, audit e impatto. `C-c p I` apre il catalogo. La barra di stato
mostra la transazione attiva; il suo clic apre il progetto corrispondente.
Le azioni passano dalla stessa entrata di scrittura della CLI, senza
aggirare le regole. Vedi la [guida del Workbench](../workbench.md).

## Lettura da un agente

Lo strumento MCP `gdev_assurance` offre le stesse undici letture a un agente
collegato a un'istanza di GDev. Prende `command` (`status`, `list`, `show`,
`verify`, `assess`, `capability`, `trace`, `impact`, `requests`, `standards`,
`standard-assess`), `argument`
(stato per `list`, identificativo per `show` e `assess`, profilo per `capability`,
percorso per `impact`, riferimento per `requests`) e
`root`, una cartella assoluta; senza `root` cerca l'archivio dalla cartella della
finestra selezionata. Restituisce JSON: per `show` gli ultimi 200 eventi e prove
con i totali a parte. È di sola lettura e non richiede il minibuffer libero. Un
agente che deve proporre una scrittura usa `gdev_assurance_request`, descritto
sotto: non può confermarla da MCP. Con `argument` vuoto, `show`, `assess` e
`standard-assess` possono usare la transazione attiva dello spazio. Una
radice esplicita diversa richiede un identificativo esplicito.

La fonte è una sola: `gdev-assurance-data` restituisce i dati e il sottocomando
li stampa.

## Standard scelti per transazione

`standards` consulta il catalogo anche senza archivio; `standard-select`
registra una scelta umana prima dell'autorizzazione. `standard-proof` lega
una prova raccolta e un esito a un obiettivo preciso; `standard-decision`
registra non applicabilità, deroga o revoca. I controlli scelti partecipano
a `assess`, alle valutazioni registrate, a `capability`, ai passaggi di stato
e alla firma Git. Non sono certificazioni normative: la [guida di attuazione](../standard/attuazione.md)
descrive ambiti documentali e clausole indicizzate, criteri, ruoli e limiti.

## Scritture esplicite dalla CLI

Eseguire dalla radice del progetto. Con un archivio esistente, vale quello
più vicino alla cartella corrente. L'attore dichiarato è il nome di accesso,
oppure `GDEV_ASSURANCE_ACTOR`; non è un'autenticazione.

```sh
gdev assurance open "Descrizione della modifica" core
gdev assurance advance GT-0001 CLASSIFIED
gdev assurance advance GT-0001 ANALYZED
gdev assurance advance GT-0001 AUTHORIZED
gdev assurance evidence GT-0001 "Esito delle prove" risultati.txt
gdev assurance assess-record GT-0001
gdev assurance decision GT-0001 GES-C03 not-applicable "Motivo verificabile"
gdev assurance artifact GT-0001 src/esempio.el source
gdev assurance artifact GT-0001 test/esempio-test.el test
gdev assurance link GT-0001 RC-0001 RC-0002 verifies "Copertura del comportamento"
```

Le transizioni e le decisioni restano nelle API del nucleo. La CLI non salta
i controlli di passaggio. Una prova vale solo nel ciclo successivo all'ultimo
ingresso nello stato pertinente: ripetere la verifica richiede nuove prove.
Un artefatto registra ruolo, percorso e SHA-256; per un collegamento simbolico
registra il testo del collegamento senza leggere il bersaglio. Percorsi remoti,
uscite dalla radice, `.git` e `.gdev` non sono artefatti di progetto.

### Adozione e recupero

```sh
gdev assurance adopt core
gdev assurance recover core "Motivo del recupero"
```

`adopt` richiede il profilo scelto esplicitamente e un repository con un commit.
L'inventario preliminare è di sola lettura. L'operazione registra commit,
impronte dei file tracciati, una situazione iniziale di versione zero e una
prova `reconstructed`. La transazione rimane `PROPOSED`: autorizzazioni,
verifiche e approvazioni del passato non vengono inventate. Solo l'integrità
del nuovo archivio può risultare già verificata. Un file tracciato assente o un
sottomodulo da risolvere ferma l'adozione. La dimensione massima di una singola
registrazione è 128 KiB; l'inventario completo si riassume con la sua impronta.

Prima di `recover` fermare tutte le istanze e gli altri scrittori del progetto.
Il comando conserva l'intera cartella precedente, inclusi WAL e SHM presenti,
in `.gdev/assurance-recovery-*`, poi registra motivo, posizione e impronte nel
nuovo archivio. Non ripara né ricrea eventi storici. Se l'apertura nuova
fallisce, ripristina la cartella precedente. Le copie conservate sono dati
dell'utente e non si eliminano durante la pulizia delle prove.

### Sedici documenti riproducibili

Il manifesto versionato `.gdev-assurance/documents.eld` elenca fonti `.eld`,
Org e Markdown per i sedici tipi editoriali originali GDev. I tipi si leggono
in `gdev-documents-types`: piano, requisiti, architettura, progettazione,
rischi, sicurezza, piani di verifica e validazione, prove, revisione,
tracciabilità, configurazione, modifiche, rilascio, manutenzione e adozione.
Non sono modelli attribuiti a uno standard.

```sh
gdev assurance documents
gdev assurance documents check
```

Il primo comando genera `docs/assicurazione/generati/`; il secondo controlla
senza scrivere ed esce con 1 se qualcosa differisce. La CI ordinaria lo esegue.
Intestazione e SHA-256 dipendono solo da generatore, manifesto e fonti, senza
date o stato privato. Org e `.eld` sono citati come sorgente, senza esportazione,
Babel, valutazione Lisp o inclusione di file. Fonti mancanti o fuori radice,
ricorsioni e destinazioni con dati dell'utente fermano la generazione. Un tipo
senza fonti dichiara `NOT_VERIFIED`. I rapporti di prova reali vanno aggiunti
come fonti versionate; l'esistenza di un documento non attesta un'attività.

### Git e CI con ricevute firmate

Servono Git, Python 3.9 o successivo e OpenSSH con `ssh-keygen -Y`. Python
verifica oggetti Git e firme senza caricare Emacs o eseguire codice del progetto.
Questa separazione permette alla CI di usare un verificatore fidato.

```sh
# Indice pronto per il commit; KEY può essere la chiave pubblica in ssh-agent.
gdev assurance sign GT-0001 organizzazione/repository persona /percorso/chiave.pub
# Il comando stampa percorsi e trailer. Aggiungere JSON e firma all'indice.
git add .gdev-assurance/receipts/
# Nel messaggio: GDev-Transaction: GT-0001 e GDev-Receipt: DIGEST
gdev assurance hooks /percorso/esterno/allowed-signers organizzazione/repository
```

La firma lega repository, contenuto dell'indice (percorsi, modi e oggetti),
genitori del commit, transazione autorizzata, stato, impronta dei controlli e
testa della catena. Non si firma una transazione bloccata o con controlli già
dovuti non verificati o non soddisfatti. Le ricevute sono dati esclusi dal
digest del contenuto per evitare una dipendenza circolare; la loro cartella
ammette solo JSON e firme regolari con nome SHA-256. Modificare il contenuto,
i genitori o la ricevuta richiede una nuova firma. Per `git commit --amend`
usare `sign-amend` con gli stessi operandi di `sign`: lega la ricevuta ai
genitori del commit sostituito. Il controllo remoto confronta sempre i
genitori effettivi, anche dopo amend, rebase e merge.

`hooks` imposta `core.hooksPath` e i percorsi del verificatore e dei firmatari
nella configurazione locale. Conserva i ganci già configurati rifiutando di
sovrascriverli. `commit-msg` controlla l'indice; `pre-push` ricontrolla tutti i
commit dopo il riferimento remoto, o dopo la base fissata all'installazione
per un ramo nuovo. Le cancellazioni di rami non aggiungono commit.
`--no-verify` può saltare un gancio locale: non è una protezione remota.

Il workflow `GDev assurance / signed-receipts` è predisposto e resta disattivo
finché l'amministratore non configura `GDEV_ASSURANCE_ENFORCE=true`, il contenuto
di `GDEV_ASSURANCE_SIGNERS` nelle variabili protette del repository e il controllo
obbligatorio sul ramo. Per una richiesta di integrazione carica il verificatore
dalla base fidata e legge solo gli oggetti della proposta, senza eseguirla;
controlla anche i commit intermedi e i merge. Le chiavi fidate non si leggono
dalla proposta. Proteggere anche workflow e verificatore con le regole del ramo.
Questa configurazione esterna è necessaria per chiudere le Fasi D ed E.

Integrare sul ramo la stessa revisione verificata, con il commit di merge e
la sua ricevuta preparati localmente quando serve un merge. I merge automatici
del server non aggiungono trailer o ricevute: il controllo li rifiuta. Le
regole remote devono impedire di sostituire dopo la verifica il commit
approvato con un merge o un rebase generato dal server.

### Proposte MCP e lavorazioni

`gdev_assurance_request` prende `transaction`, `root` assoluta e `proposal`,
un testo JSON con `operation` e `arguments`. Registra una proposta in attesa;
le sole operazioni sono `advance`, `evidence`, `assess`, `artifact` e `link`.
`advance` non offre gli stati riservati a una persona. `artifact` prende
percorso relativo, ruolo e SHA-256 da confermare. Un cambiamento del file dopo
la proposta impedisce di registrarlo come quello esaminato.

```sh
gdev assurance requests RC-0001
gdev assurance confirm RC-0001 DIGEST_ESAMINATO
# Oppure:
gdev assurance reject RC-0001 DIGEST_ESAMINATO
```

La conferma esige i byte esaminati, si consuma una volta sola e scade quando
arriva un altro evento. Anche dopo la conferma l'azione resta di tipo `agent`:
non acquista il diritto di approvare, derogare, adottare o recuperare. Rifiuti
di regole, conferme errate e proposte respinte restano nella catena; dati
malformati rifiutati prima di identificare una transazione non vi entrano.
Le azioni `.lavorazione` `assicurazione-verifica`, `assicurazione-documenti`,
`assicurazione-valuta`, `assicurazione-valuta-standard` e `assicurazione-proponi`
riusano queste API senza richieste interattive. Non
esiste un'azione per confermare o approvare da una macro.

La CLI e il protocollo di conferma non possono autenticare una persona contro
chi possiede la stessa shell o può valutare Lisp arbitrario. Il confine resta
la firma con una chiave esterna e il controllo remoto obbligatorio.

## Transazione attiva dello spazio

Uno spazio di lavoro può avere una transazione attiva, per esempio quella su cui
si sta lavorando in quel progetto. L'identità passa da `gdev-workspace-state` nel
campo `gdev-assurance-transaction`, con ciclo di vita `transient`: resta in
memoria, non entra nella sessione salvata e non si copia in uno spazio
duplicato; dopo un riavvio la si sceglie di nuovo. Il campo contiene solo
`(:root RADICE :id ID)`: lo stato vero sta nell'archivio.

- `gdev-assurance-workspace-select` convalida prima di pubblicare: la radice deve
  avere un archivio leggibile e la transazione deve esistere e non essere
  conclusa (`BASELINED`, `REJECTED`, `CANCELLED`, `SUPERSEDED`). Un errore lascia lo
  spazio com'era.
- `gdev-assurance-workspace-active` rilegge la transazione dall'archivio a ogni
  chiamata e ne riporta lo stato corrente. Se non esiste più o è conclusa,
  svuota il campo. Se l'archivio non si legge per un motivo passeggero, lo lascia.
- `gdev-assurance-workspace-clear` lo svuota.

Ogni spazio ha la propria transazione. Non esiste ancora un comando o un menu
per sceglierla: arriverà con l'interfaccia, nella Fase D.

## Dove stanno i dati

`<radice del progetto>/.gdev/assurance/assurance.sqlite`, in una cartella
`0700` con file `0600`. È un registro locale e non un sorgente: GDev-Emacs lo
esclude da Git con `/.gdev/`. Se due progetti annidati hanno ciascuno il proprio
archivio, vale quello più vicino alla cartella corrente.

## Stati e regole

Una transazione nasce in `PROPOSED` e arriva in `BASELINED` passando da
`CLASSIFIED`, `ANALYZED`, `AUTHORIZED`, `IMPLEMENTING`, `VERIFYING`,
`REVIEWING` e `APPROVED`. Da `VERIFYING` e `REVIEWING` si torna a
`IMPLEMENTING`. Da ogni stato fra `PROPOSED` e `APPROVED` si può passare a
`BLOCKED`, `SUSPENDED` e `CANCELLED`; a `REJECTED` da `PROPOSED` a `REVIEWING`.
`BASELINED` passa solo a `SUPERSEDED`. `REJECTED`, `CANCELLED` e `SUPERSEDED`
sono finali. La tabella completa è `gdev-process-transitions`; ogni altra coppia
è rifiutata e una prova esamina tutte e 196 le coppie.

| Regola | Effetto |
| --- | --- |
| Passaggi riservati | `AUTHORIZED`, `APPROVED`, `BASELINED`, `REJECTED`, `CANCELLED`, `SUSPENDED` e `SUPERSEDED` richiedono un attore umano. Un agente, la CI o il sistema non li compiono. |
| Separazione dei ruoli | Dal profilo `secure` in su chi ha aperto la transazione non la autorizza, non la approva e non fissa la linea di base. |
| Ripresa | Da `BLOCKED` o `SUSPENDED` si torna solo allo stato di partenza. Un agente non rimuove un blocco; solo una persona riprende un lavoro sospeso. |
| Sostituzione | Una linea di base si sostituisce con `gdev-process-supersede`, da una persona, con una transazione successiva già in `BASELINED`. |
| Prove | Il nucleo fissa l'istante della prova. Una transazione in `BASELINED`, `REJECTED`, `CANCELLED` o `SUPERSEDED` non ne accetta di nuove. |
| Canale | Se un canale lega `gdev-process-origin` a un tipo d'attore, chi dichiara un altro tipo è rifiutato. Le azioni che un agente esegue dall'editor (`eval`, `command`, `keys`) girano con l'origine `agent`. |
| Controllo di passaggio | Da `VERIFYING` a `REVIEWING`, dal profilo `quality` in su, serve almeno una prova `fact` con origine `collected` registrata in `VERIFYING` dopo l'ultimo ingresso. Il profilo `core` non ha controlli. |

## Regole e rifiuti

Le regole stanno nel motore [gdev-policy.el](../../../lisp/gdev-policy.el), che non
conosce stati né prove: ogni dominio (`open`, `transition`, `supersede`,
`evidence`) registra le proprie e il motore le applica nell'ordine di
registrazione. Una regola riceve il contesto, un plist, e restituisce nil se
l'azione le sta bene o il motivo del rifiuto. La prima che nega decide. Si nega
per impostazione predefinita: un dominio senza regole nega, e così una regola
che segnala un errore o restituisce un valore diverso da nil e da una stringa.

Un rifiuto non cambia lo stato. Se la transazione esiste e l'attore è valido, il
rifiuto entra nella catena come evento `refusal`, con lo stato di partenza, lo
stato richiesto, chi, la regola e il motivo; `gdev assurance show` lo mostra con
`✗`. Un rifiuto non lascia un evento se manca la transazione (per esempio
l'apertura) o se i dati sono invalidi: non c'è nulla a cui riferirlo. Chiamata
dentro una transazione dell'archivio aperta dal chiamante, la traccia del
rifiuto resta solo se il chiamante gestisce l'errore e conferma.

I controlli di passaggio sono in [gdev-gates.el](../../../lisp/gdev-gates.el). La
tabella `gdev-gates-table` è provvisoria: contiene l'unico controllo che il
nucleo applica da solo, e i controlli che discendono da standard e profili li
definirà la Fase C. Una prova conta per un controllo solo se ha il genere e
l'origine richiesti ed è successiva all'ultimo ingresso nello stato: chi torna in
`VERIFYING` non riusa le prove di prima.

## Prove

Una prova lega a una transazione l'impronta SHA-256 di un testo o di un file; il
contenuto non resta nell'archivio. Il genere è `fact` (osservato), `deduction`
(dedotto) o `hypothesis` (assunto). L'origine è `collected` (raccolta durante la
transazione) o `reconstructed` (ricostruita a posteriori). Ogni prova è anche un
evento della catena, con la sua impronta.

## Garanzie e limiti

- **Che cosa è garantito.** Ogni evento include l'impronta del precedente.
  Modificare, togliere o inserire un evento, cambiare lo stato di una
  transazione, toccare l'impronta di una prova, togliere un trigger o cambiare
  una migrazione si rileva con `gdev assurance verify`. I trigger e i vincoli
  del database rifiutano `update` e `delete` su eventi e prove.
- **Metadati confrontati con la catena.** Prove, decisioni e valutazioni
  devono riportare la stessa transazione, lo stesso attore, il suo tipo e la
  stessa data del rispettivo evento. Cambiare uno di questi dati si rileva
  anche quando i trigger sono stati rimessi al loro posto e la catena non è
  stata toccata. CLI e strumento MCP restituiscono gli stessi problemi.
- **Che cosa non è garantito.** Chi ha accesso al file può riscrivere l'intera
  catena e ricalcolare tutte le impronte: questo non si distingue da un
  originale senza un'àncora esterna (CI, esportazione firmata), prevista nelle
  fasi successive. Anche cancellare gli ultimi eventi insieme alla loro
  transazione non lascia incongruenze.
- **Chi agisce.** Il nucleo non autentica l'attore: il tipo (`human`, `agent`,
  `ci`, `system`) lo dichiara chi lo chiama. Un canale lo fissa con
  `gdev-process-origin` e il nucleo rifiuta e registra chi ne dichiara un altro.
  Questo ferma gli errori e le chiamate ingenue, per esempio una forma
  valutata da un agente che si dichiara una persona per autorizzare una
  transazione.
- **Un agente che valuta Lisp.** Il server MCP offre l'azione `eval` (segnata
  come distruttiva), che valuta Emacs Lisp nel processo che ospita il nucleo. Chi
  può farlo può anche riassegnare `gdev-process-origin`, ridefinire le regole,
  chiamare `sqlite-execute` sul file dell'archivio o programmare un timer che
  agisca più tardi, fuori dal canale. **In questo processo non esiste un
  confine che lo impedisca**: la sola difesa locale è che il client chieda a una
  persona di confermare ogni `eval`. L'argine reale sta fuori dal processo: il
  controllo in CI su una copia pulita, con la protezione dei rami e un'àncora
  della catena che l'agente non possa riscrivere (Fasi D e E).
- **Un agente con una shell** può modificare i file di un progetto senza
  passare dal nucleo, per lo stesso motivo.

## Uso da Lisp

```elisp
(require 'gdev-assurance)
(gdev-assurance-db-with-open (db "/percorso/del/progetto/" 'write)
  (let ((id (gdev-process-open db :title "Aggiorna la guida" :profile 'core
                               :actor "giacomo" :actor-kind 'human)))
    (gdev-process-advance db id 'CLASSIFIED :actor "giacomo" :actor-kind 'human)
    (gdev-evidence-add db id :kind 'fact :description "Test ERT verdi"
                       :content "esito dei test" :actor "ci" :actor-kind 'ci)
    (gdev-assurance-verify db)))   ; nil se tutto torna
```

`gdev-assurance-db-open` con `'write` crea e migra l'archivio; con `'read`
(predefinito) apre una connessione che non scrive. I rifiuti segnalano
`gdev-process-refused` con il motivo e, se la transazione esiste, lasciano un
evento `refusal`.

## File

| File | Contenuto |
| --- | --- |
| [gdev-assurance-db.el](../../../lisp/gdev-assurance-db.el) | apertura, migrazioni, integrità |
| [gdev-policy.el](../../../lisp/gdev-policy.el) | motore delle regole, si nega per impostazione predefinita |
| [gdev-gates.el](../../../lisp/gdev-gates.el) | controlli di passaggio fondati sulle prove |
| [gdev-process.el](../../../lisp/gdev-process.el) | stati, regole del processo, catena di audit, rifiuti, verifica |
| [gdev-evidence.el](../../../lisp/gdev-evidence.el) | prove e loro legame con la catena |
| [gdev-assurance.el](../../../lisp/gdev-assurance.el) | dati strutturati, facciata e sottocomandi |
| [gdev-assurance-workspace.el](../../../lisp/gdev-assurance-workspace.el) | transazione attiva dello spazio di lavoro |
| [gdev-standards.el](../../../lisp/gdev-standards.el) | registro degli standard e verifica dei riferimenti |
| [gdev-standard-catalog.el](../../../lisp/gdev-standard-catalog.el) | obiettivi originali GDev, ambito, fase e impronta delle definizioni |
| [gdev-standard-assessment.el](../../../lisp/gdev-standard-assessment.el) | scelta per transazione, prove specifiche, decisioni e controlli di passaggio |
| [gdev-assurance-workbench.el](../../../modules/ui/workbench/gdev-assurance-workbench.el) | vista del progetto, catalogo, esiti e lettura coerente |
| [gdev-assurance-interactive.el](../../../modules/ui/workbench/gdev-assurance-interactive.el) | azioni da tastiera e puntatore, conferme e operazioni in secondo piano |
| [gdev-controls.el](../../../lisp/gdev-controls.el) | controlli e profili: caricamento, controllo, composizione, impronta |
| [gdev-assessment.el](../../../lisp/gdev-assessment.el) | valutazione di una transazione rispetto ai controlli del suo profilo |
| [gdev-decisions.el](../../../lisp/gdev-decisions.el) | deroghe e decisioni di non applicabilità |
| [gdev-assessment-store.el](../../../lisp/gdev-assessment-store.el) | valutazioni registrate: righe, impronte, verifica |
| [gdev-assurance-test.el](../../../test/gdev-assurance-test.el) | prove ERT, comprese le manomissioni |
| [gdev-assurance-workspace-test.el](../../../test/gdev-assurance-workspace-test.el) | prove dello spazio di lavoro |
| [gdev-assessment-test.el](../../../test/gdev-assessment-test.el) | prove di standard, controlli, profili e valutazione |
| [gdev-decision-test.el](../../../test/gdev-decision-test.el) | prove delle decisioni |
| [gdev-assessment-record-test.el](../../../test/gdev-assessment-record-test.el) | prove delle valutazioni registrate |

Le migrazioni sono blocchi numerati e immutabili: un blocco pubblicato non si
modifica, se ne aggiunge uno nuovo. L'archivio ne registra l'impronta.

## Verifiche

```sh
emacs --batch -Q -l early-init.el -l test/gdev-test.el -l test/gdev-coverage.el -f gdev-coverage-assurance
```

Richiede tutte le righe strumentabili dei dodici file originali del nucleo.
Lo stesso requisito vale per i dieci moduli aggiunti dalla roadmap, con
`-f gdev-coverage-assurance-extensions`, eseguito anch'esso in CI.
Le prove delle fasi successive comprendono migrazione 4→5 con impronte
invariate, inventario e recupero, documenti deterministici, dipendenze cicliche,
conferme scadute, doppio utilizzo e identità dell'agente. Il contratto Git usa
repository e chiavi effimere:

```sh
python3 test/gdev-assurance-git-test.py
```
