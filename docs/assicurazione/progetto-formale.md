# Progetti, lavorazioni e procedure controllate

La definizione autorevole è `.gdev-assurance/project.eld`, letta come dati.
Il nucleo SQL conserva istantanee ed esecuzioni immutabili; il Workbench, la
CLI e MCP leggono gli stessi servizi. I piani automatici restano file
`.lavorazione`: non esiste un secondo interprete di comandi.

GDev applica questa struttura a se stesso con ventuno requisiti in
[project.eld](../../.gdev-assurance/project.eld), sette procedure e nove
modelli. Il [contratto di autoverifica](../../.gdev-assurance/self-check.eld)
richiama gli identificativi del progetto e aggiunge le dimensioni della
campagna di affidabilità, senza duplicare i requisiti.

## Creare e compilare un progetto

Dal cruscotto scegli **Nuovo progetto… › Formale…** oppure usa **Progetto ›
Nuovo progetto › Formale…**. Scegli una cartella locale nuova o vuota, poi
inserisci l’identificativo e il nome. Si apre la sezione **Progetto** con
i campi da compilare. Per aggiungere la definizione a una cartella già in uso,
aprila e scegli **Definisci progetto…** nella sezione **Progetto**
dell’assicurazione.

Da terminale, nella cartella del progetto:

```sh
gdev assurance project-init DEMO "Progetto dimostrativo"
gdev assurance project
gdev assurance taxonomy
gdev assurance taxonomy nist-sp-800-218
gdev assurance suggest nist-sp-800-218
```

L'inizializzazione prepara una bozza e copia procedure e modelli versionati.
Non sovrascrive file differenti e non crea l'archivio SQL. SSDF è una scelta
**proposta**: occorre dichiarare applicabilità, perimetro e motivazione.
I suggerimenti non diventano requisiti accettati o prove positive.

Il manifesto richiede scopo, perimetro, responsabile, contesto e strategia di
verifica dall'analisi; dalla revisione richiede anche validazione,
configurazione, rilascio e manutenzione. `project` elenca i campi mancanti,
la fase in cui sono dovuti e i riferimenti non risolti. Il Workbench offre
**Compila campo**, **Nuovo requisito**, **Apri definizione** e **Tassonomie**.
Le scelte strutturate, compresa l'accettazione delle proposte, restano nel
manifesto versionato e sono soggette a revisione.

Un requisito dichiara identificativo e versione, enunciato, origine,
motivazione, categoria, priorità, criticità, responsabile, applicabilità,
accettazione, metodo, sorgenti, controlli e procedura. Sono disponibili
vincoli, assunzioni, dipendenze e conflitti. Riferimenti inesistenti, cicli,
identificativi duplicati e conflitti fra requisiti applicabili impediscono
il proseguimento. Le categorie iniziali coprono funzione, qualità,
sicurezza, dati, interfaccia, prestazioni, compatibilità, usabilità,
processo e rilascio; i metodi sono test, analisi, revisione e modello finito.
Un metodo descrittivo da solo non costituisce una prova.

## Scheda della lavorazione e ciclo di vita

L'identificativo della lavorazione è quello della transazione (`GT-…`).
Una scheda `.eld` conserva titolo, tipo, obiettivo, ambito, requisiti,
input, prerequisiti, responsabile, priorità, dipendenze, procedura e versione,
modelli previsti, criteri di accettazione, artefatti e revisioni.
Un esempio reale è [governed-development.eld](../../.gdev-assurance/work/governed-development.eld).

```sh
gdev assurance open "Sviluppo governato" quality
gdev assurance work-bind GT-0001 .gdev-assurance/work/governed-development.eld
gdev assurance project-bind GT-0001
gdev assurance work GT-0001
gdev assurance assess GT-0001
```

Usare l'identificativo restituito da `open`, senza presumere `GT-0001`.
Il Workbench crea e seleziona le transazioni e offre **Collega scheda**.
La scheda non introduce una seconda macchina a stati:

| Stato operativo | Stati del nucleo |
| --- | --- |
| Bozza | Proposta, Classificata |
| Pronta | In analisi, Autorizzata |
| In corso | In lavorazione |
| In verifica | In verifica, In revisione |
| Completata | Approvata, Consolidata |
| Bloccata / sospesa | Bloccata, Sospesa, con motivo e stato di origine |
| Annullata | Annullata |

I passaggi si effettuano con **Avanza** o `advance ID STATO`. I passaggi
riservati a una persona mantengono le regole esistenti. Le dipendenze fra
lavorazioni devono essere concluse prima dell'autorizzazione. Le riprese da
blocco o sospensione tornano allo stato di origine; un nuovo tentativo di
procedura non modifica automaticamente lo stato della lavorazione.

## Modelli e inserimento

Il catalogo contiene progetto, requisito, lavorazione, procedura, funzione
Lisp, test ERT, documentazione, configurazione e gestione degli errori.
Ogni voce identifica versione, descrizione, formato, file e parametri con
obbligatorietà, valore predefinito e motivazione. La ricerca usa il
completamento di Emacs; **Modelli** raccoglie i parametri e apre un'anteprima
con il pulsante **Crea file e registra**.

```sh
gdev assurance snippets
gdev assurance snippet-preview SNIP-DOCUMENTATION '{"title":"Titolo","content":"Contenuto"}'
gdev assurance snippet-write GT-0001 SNIP-DOCUMENTATION esempio.md '{"title":"Titolo","content":"Contenuto"}'
```

La sintassi `{{parametro}}` non esegue Lisp, shell o espansioni annidate.
I parametri dichiarati come simboli Lisp sono validati; quelli destinati a
stringhe Lisp ricevono la quotatura necessaria per virgolette e caratteri di
controllo. Gli input originali restano distinti dal testo generato. Parametri assenti, sconosciuti o duplicati sono errori espliciti.
La creazione rifiuta contenuti differenti già presenti, percorsi esterni,
collegamenti che escono dal progetto, file aperti con modifiche e blocchi di
scrittura. Le sostituzioni interne richiedono l'impronta esaminata e usano
un file temporaneo nella stessa cartella. Un programma esterno che ignora
ogni coordinamento può ancora scrivere fra controllo e sostituzione: il
filesystem non offre un confronto e scambio portabile fra applicazioni.
La registrazione conserva modello, versione, parametri e impronte. Evitare
credenziali nei parametri: questi dati fanno parte dell'audit.
Gli inserimenti manuali archiviano questi valori come registrazioni
immutabili di progetto, consultabili con `work ID` e nella vista della
lavorazione anche dopo la riapertura dell'archivio. Le regole sono controllate
prima di creare file: una lavorazione conclusa non li può produrre. Se SQL
fallisce dopo la scrittura, il comando segnala errore e il file resta da
riconciliare; ripetere con contenuto identico registra l'applicazione senza
sovrascriverlo. Non si promette atomicità fra filesystem e SQLite.

I modelli di funzione e test contengono un errore esplicito finché non sono
completati. Il loro inserimento non produce una verifica positiva.

## Pianificare, eseguire, interrompere e riprendere

```sh
gdev assurance procedures
gdev assurance procedure-plan PROC-FEATURE
gdev assurance procedure-run GT-0001 PROC-FEATURE
gdev assurance runs GT-0001
gdev assurance procedure-resume GT-0001 RUN-identificativo
gdev assurance project-report
gdev assurance project-report check
```

`procedure-plan` valida tutte le azioni e mostra gli effetti dichiarati,
senza applicarli e senza creare un archivio. Ogni procedura dichiara versione,
tipi di lavoro, passi ordinati, input, uscite, controlli obbligatori o
facoltativi, timeout e modalità di ripetizione. Il catalogo iniziale offre
feature, bugfix, refactor, documentazione, dipendenze e rilascio. I loro
controlli iniziali riguardano la struttura del progetto, il modello del
nucleo e il rapporto; vanno estesi con i test del comportamento sviluppato.
Le procedure iniziali sono di verifica (`:mode verification`). Una
procedura `:mode implementation` può produrre i sorgenti pianificati soltanto
in IMPLEMENTING; ne registra il contesto prima e dopo. Il suo successo non
vale come prova di verifica. Dopo la produzione si collega una nuova
istantanea e si avvia il ciclo VERIFYING. I file pianificati possono essere
assenti in analisi; devono esistere alla verifica.

Le dipendenze fra input e uscite possono essere eseguite in una procedura di
produzione ordinata. La verifica richiede input già prodotti e congelati:
produzione e verifica dello stesso file vanno separate da una nuova
istantanea. Una prova generica del nucleo non soddisfa un requisito che
richiede un altro controllo. `GDEV-VERIFY` esegue anche ERT, contratti CLI/Git e la
campagna di affidabilità sui sorgenti della distribuzione.

I testi dei piani vengono fissati nell'avvio del giornale, insieme a
procedura, contesto, strumenti e scheda. Prima di ogni effetto viene
registrato l'avvio del passo. Ogni esito conserva controlli realmente
superati, uscite, effetti e impronta del log. I test saltati restano distinti;
una suite vuota o composta soltanto da test saltati fallisce. I figli ERT e
Python usano cartelle di stato e configurazione temporanee e argomenti
espliciti, senza shell.

Nel Workbench l'esecuzione è in secondo piano e si arresta dalle Operazioni
dello spazio. Da terminale si usa l'interruzione normale. I timeout e
l'annullamento sono cooperativi fra azioni e nelle attese; una funzione Lisp
che non restituisce il controllo non è preemptibile in modo generale.
Si interrompono soltanto i processi figli creati dalla procedura.

Un blocco locale impedisce due procedure contemporanee nello stesso
progetto. Una ripresa richiede sorgenti, definizioni e scheda invariati.
I passi conclusi si saltano solo se le uscite dichiarate sono ancora uguali.
Dopo una produzione che ha cambiato i sorgenti, si avvia un nuovo tentativo
sul nuovo contesto; non si ricostruisce automaticamente una ripresa parziale.
Un passo `manual` interrotto o con uscite cambiate richiede riconciliazione e
un nuovo tentativo: non si promette un annullamento automatico degli effetti.
Le esecuzioni fallite e annullate restano consultabili dopo quelle riuscite.

## Chiusura, invalidazione e rapporti

Prima di revisione, approvazione e versione di riferimento servono definizione completa,
istantanea corrente, procedure riuscite nel ciclo VERIFYING attuale,
controlli richiesti da ogni requisito ed artefatti obbligatori esistenti e
identificati. `assess` include queste condizioni e le mostra nel Workbench.
L'impronta include manifesto, input, modelli, piani, tassonomie e motore;
`source-roots` estende il confronto a intere cartelle, comprese aggiunte e
rimozioni; `source-files` aggiunge file singoli. Le uscite dichiarate restano
separate dagli input. Le impronte comprendono anche le regole distribuite e
gli input della scheda operativa. Una modifica di contenuto, collegamento o esecuzione richiede nuova istantanea e nuove prove.
Le ricevute restano fuori dall’inventario per evitare dipendenze circolari.
La definizione di GDev include anche le istruzioni degli agenti e la licenza
nel perimetro dei sorgenti verificati.
Nelle chiusure, la firma Git confronta anche input, inventario e uscite pubbliche
con i blob e i tipi dell’albero immutabile da firmare.
Le scansioni del progetto formale avvengono fuori dal processo grafico; un
risultato tardivo non cambia progetto, transazione o spazio di destinazione.

Il rapporto `generati/project.md` è deterministico e protetto contro la
sovrascrittura di file dell'utente. Riporta definizione, accettazione,
standard, lacune e impronte; gli esiti effettivi restano nel giornale e
nell'audit. `project-report check` non scrive e fallisce se va rigenerato.
I sedici documenti editoriali del manifesto documentale restano una
funzione distinta, con proprie sorgenti e controllo di aggiornamento.

## Tassonomie e verifiche formali

- ASVS 5.0.0: 345 requisiti confrontati con il CSV originale, con capitoli e sezioni.
- SSDF 1.1: 4 gruppi, 19 pratiche e 42 compiti ricostruiti dalla tabella XLSX acquisita.
- NIST IR 8397: tutte le 35 sezioni numerate del sommario del PDF locale; la scomposizione degli obblighi atomici rimane da integrare.
- SLSA 1.2: intestazioni e candidati delle due fonti locali Build e Source; integrazione degli altri documenti e revisione degli obblighi ancora necessarie.
- ISO/IEEE bibliografici e indici ECSS parziali: lacune visibili, nessuna clausola inventata.

Indice completo nel suo perimetro, obblighi estratti e attuazione verificata
sono tre condizioni distinte. Il perimetro `full` rifiuta anche un indice
completo che non abbia obblighi estratti. Per gli agenti, `taxonomy ID@200`
e `suggest ID@200` continuano la lettura usando il cursore `next_argument`.
Gli identificativi SLSA generati da GDev non sono identificativi ufficiali.

```sh
python3 -m pip install -r test/requirements-taxonomy.txt
python3 bin/gdev-taxonomy-import.py --check
python3 test/gdev-taxonomy-test.py
gdev assurance model-check
```

`pypdf` serve soltanto al rigeneratore e alle verifiche PDF, mai all'avvio di
Emacs. Il modello finito esplora 522 casi: 364 del ciclo formale e 158 delle
[operazioni di progetto](../operazioni-progetto.md), con controesempi se un invariante è violato. Verifica il perimetro
dichiarato; non è una prova matematica dell'intero programma, del sistema
operativo o di SQLite e non attribuisce approvazioni umane o certificazioni.
