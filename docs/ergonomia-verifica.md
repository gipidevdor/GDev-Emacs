# Verifica di ergonomia e reattività

Rilevazione del 19 novembre 2026 su macOS, con Emacs 31.1 e il profilo
distribuito. La scheda versionata è
[ergonomics.eld](../.gdev-assurance/work/ergonomics.eld); i criteri appartengono
al requisito `GDEV-P07`, versione 2. Le prove su Emacs 30.1 restano distinte.

## Ricognizione

L'inventario iniziale raccoglie 70 moduli, 602 dichiarazioni interattive,
690 percorsi di menu, 560 scorciatoie e 179 azioni contestuali. È un
riscontro delle entrate, non l'esecuzione di tutti i servizi esterni.
Nel profilo caricato le voci di menu hanno un comando risolto. I provider
contestuali vengono attivati insieme alle rispettive viste. La differenza
fra `quit-window` e `gdev-quit-view` nel Cruscotto è una rimappatura voluta.

La ricognizione segue la matrice di [flussi](ergonomia.md#percorsi-da-verificare):
file, gruppi e spazi; ricerca e sostituzione; strumenti del progetto;
test, debug e rapporti; Git; terminali; documenti; impostazioni; agenti e
lavorazioni. Le regressioni mirate preesistenti eseguono 47 casi, tutti
positivi. Le prove dei servizi esterni dipendono dalle loro precondizioni:
non si inviano messaggi, non si pubblicano contenuti e non si avviano
connessioni per costruire l'inventario.

## Misure sugli stessi dati

Il confronto usa lo stesso archivio reale e lo stesso processo, alternando
la funzione precedente e quella aggiornata. Comprende lettura dei dati e
preparazione del modello; esclude avvio del processo e disegno grafico.

| Sezione | Prima | Dopo | Dati prima | Dati dopo |
| --- | ---: | ---: | ---: | ---: |
| Transazioni | 4.185 ms | 28 ms | 905.147 B | 6.260 B |
| Progetto | 4.082 ms | 98 ms | 954.790 B | 50.793 B |
| Esecuzioni | 4.049 ms | 23 ms | 1.352.439 B | 448.442 B |

Il costo dominante era la valutazione completa, che ricostruiva
l'inventario delle sorgenti anche per consultare una sezione informativa.
Il modello della vista ora richiede solo i dati necessari. **Controlli** e
le letture complete conservano la valutazione corrente; non si riusano
verifiche precedenti per ottenere questi tempi.

Nel profilo caricato la raccolta dei comandi impiega circa 3,4 ms e quella
dei menu 11 ms per chiamata. Non è emersa la necessità di aggiungere cache
a queste operazioni. Tre avvii grafici isolati caricano la configurazione
in 931 ms mediani e raggiungono il primo giro inattivo in 1.534 ms; questo
indicatore non misura la prima interazione della persona.

## Interazione e recupero

Due prototipi testuali usano gli stessi dati a 96 e 40 colonne. A 40 colonne
la barra precedente sposta il contenuto alla riga 19; il selettore lo porta
alla riga 14. La soluzione mantiene la barra nelle finestre ampie e usa
**Sezione: …** in quelle strette. Tutte le tredici sezioni sono disponibili
con `S`, clic e completamento.

Il filtro offre un'azione esplicita di rimozione, mantiene il valore completo
nell'aiuto e conserva quello precedente dopo un annullamento. Il cambio di
pagina porta il fuoco alla prima voce effettivamente mostrata; ai limiti
conserva la posizione. Le azioni contestuali richiamano gli stessi comandi.

La lettura asincrona pubblica identità e contesto prima di ricevere una
risposta già conclusa. Un processo che non parte lascia un errore leggibile
e la possibilità di riprovare. Risposte di sezioni o spazi superati vengono
scartate. Il comando `bench` rifiuta conteggi non validi prima di creare
file o avviare un processo.

## Evidenze e limiti

La suite completa seleziona 954 casi: 952 superati e due saltati su Emacs
30.1; 953 superati e uno saltato su 31.1. Nessun errore inatteso. Le campagne
obbligatorie mantengono la copertura completa delle righe strumentabili
dei moduli previsti; la misura non si estende automaticamente a tutto il prodotto.
La ripetizione sul checkout finale supera 950 casi e ne salta quattro per
le precondizioni dell'ambiente, senza errori inattesi. La compilazione con
avvisi visibili produce 715 file bytecode e 177 file nativi, senza errori o
avvisi; anche la compilazione sulla versione minima è pulita. I contratti
CLI/MCP, Git e tassonomie superano rispettivamente 14, nove e tre prove.

I rapporti locali appartengono a `.gdev/assurance/reports/ergonomics/`.
Le nuove prove controllano consultazione senza valutazioni implicite,
permanenza delle verifiche complete, selettore stretto, filtro, pagine,
risposte anticipate, errori di avvio e argomenti della CLI. Tre regressioni
falliscono ripristinando il codice precedente, senza contare errori di
sintassi o di avvio come dimostrazione.

Una prova nell'app nativa verifica inoltre tema chiaro e scuro, due
larghezze e due dimensioni del testo: nel caso stretto il filtro occupa
301 dei 304 pixel disponibili, oppure 296 con il testo ingrandito. Sono
misure geometriche dell'app, distinte dall'ispezione visiva e dal puntatore.

Il controllo del Mac rileva ancora il blocco della sessione. I prototipi
testuali e le misure non attestano il confronto visivo finale: temi,
dimensioni e puntatore nella finestra nativa restano da verificare. Le prove
automatiche di profilo, contrasto e interazione sono evidenze diverse.

## Operazioni automatiche del progetto, 20 novembre 2026

La lavorazione `GT-0006` e il requisito `GDEV-P14` aggiungono il
[contratto operativo comune](operazioni-progetto.md). Il controllo segue
manifesti, radice, adattatore, preparazione, processo effettivo, esito e
recupero. L'inventario espone 19 contratti, comprendendo le operazioni
dichiarate dal progetto; il modello rileva i tipi riconosciuti privi di
contratto. Le 158 combinazioni operative si aggiungono alle 364 del ciclo
formale, con controesempi verificati anche alterando i predicati.

La riproduzione iniziale nella finestra nativa ha mostrato che **Progetto ›
Compila** avviava realmente Make nella cartella di AlacreOS. La costruzione
si arrestava perché il compilatore incrociato richiesto non era disponibile.
Questo caso resta distinto dalle regressioni dell'IDE: il nuovo controllo
offre configurazione e recupero, senza dedurre una toolchain sostitutiva dai
nomi degli eseguibili. I sorgenti e le modifiche preesistenti di AlacreOS
sono stati conservati.

Le prove eseguono compilazioni C e C++, generazione e costruzione MakeMaker,
test Perl, bytecode Python e distribuzioni wheel/sdist con il frontend
PyPA reale. Cinque scenari Gherkin esercitano i comandi pubblici dalla
cartella e dalle sottocartelle, senza un sorgente aperto, incluso il
recupero dopo un processo fallito. Le regressioni verificano anche precedenza
personale, modifica e cancellazione dei manifesti, limiti del catalogo Make,
aggiornamento dei documenti aperti e rimozione delle variabili obsolete.

Una campagna completa locale ha superato 1.400 casi su 1.401, con il solo
controllo del rapporto di affidabilità demandato alla campagna dedicata.
Le successive prove mirate hanno superato 85 casi. La procedura formale
registra il risultato conclusivo sul codice corrente, compresi gli ultimi
casi aggiunti. Il corpus obbligatorio comprende i cinque nuovi scenari.
Le coperture richieste restano al 100%: 61 righe dello stato condiviso e,
nei flussi, 174/174, 507/507, 97/97, 91/91 e 300/300 righe strumentabili.

La compilazione nella copia isolata produce 734 file bytecode e 191 nativi,
senza errori o avvisi. Un avvio ordinario da terminale carica sei funzioni
centrali del nuovo flusso in codice nativo, senza moduli falliti. Questa
prova attesta avvio e caricamento; non è un controllo grafico. La ricerca
della radice sul checkout GDev impiega circa 0,060 ms per chiamata su 1.000
iterazioni, senza raccolte della memoria nella misura.

La vista riusa il profilo documento, le facce semantiche e la chiusura
comune. Le azioni sono su righe distinte, i percorsi completi vanno a capo
e il ridisegno conserva il pulsante selezionato. Le prove automatiche
verificano profilo, contrasto comune, assenza di processi durante osservazione
e disegno, contesto delle azioni e conservazione della selezione.
I tentativi successivi di ispezione grafica hanno ricevuto dallo strumento
«Mac bloccato», anche dopo l'avvio di una finestra isolata. Il controllo
visivo finale con puntatore, temi e dimensioni resta da completare; non è
stato sostituito dalle prove batch o dall'avvio in terminale.
