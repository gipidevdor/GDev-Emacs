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
