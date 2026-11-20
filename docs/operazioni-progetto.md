# Operazioni automatiche del progetto

Apri una cartella e usa **Progetto › Compila** (`F7`, `⌘B`). Il comando
cerca i manifesti anche dalle sottocartelle e senza Git; funziona da un
README e dalle viste laterali. Il sistema del progetto governa le regole
di costruzione. CMake e Meson preparano l'albero quando manca; Perl
genera il Makefile o `Build` prima della costruzione e dei test. I moduli
dei linguaggi si attivano anche senza un sorgente aperto, per il tempo
richiesto dall'operazione.

**Progetto › Controlla progetto** mostra cartella, sistema, profilo e
strumento del motore, con azioni per compilare, configurare, eseguire i
test e recuperare l'ambiente. La vista legge osservazioni locali; aprirla
o ridisegnarla non avvia compilatori né interrogazioni Make. Dopo un
errore, il pannello di compilazione offre lo stesso controllo.

## Make e progetti generati

Senza una scelta personale, Make esegue il proprio obiettivo predefinito.
`C-u F7` permette di scegliere un obiettivo. **Esegui attività…** unisce
gli obiettivi scoperti alle attività personali; una voce personale con
lo stesso nome prevale. **Configura compilazione** (`⇧F7`) modifica gli
assegnamenti `NOME=VALORE`, conservati per progetto in SQLite. Per esempio:

```text
CC=clang CXX=clang++ 'CXXFLAGS=-O2 -g'
```

I Makefile esistenti restano di proprietà del progetto. GDev delega
include, variabili e dipendenze a Make. Per CMake, Meson e MakeMaker, il
generatore produce e aggiorna i propri file: GDev avvia la preparazione
necessaria, senza sostituirla con un Makefile dedotto dai nomi dei sorgenti.

Il catalogo usa GNU Make con `-qp`, limiti di tempo e di dimensione, solo
durante la richiesta di un obiettivo o di un'attività. Anche questa
interrogazione può valutare espressioni dei Makefile e ricette ricorsive;
non è un'analisi pura. Un motore diverso o un catalogo non leggibile
consentono comunque di indicare un obiettivo esplicito.
[Database e opzioni di Make](https://www.gnu.org/software/make/manual/html_node/Options-Summary.html).

## Perl e Python

Perl usa l'interprete del percorso del progetto, compresi perlbrew e
plenv. Con `Makefile.PL` o `Build.PL`, compilazione e test preparano gli
artefatti necessari. I moduli puri con `lib/` e `t/` usano il controllo
sintattico e `prove`. Non si presenta il controllo sintattico come un
compilatore di estensioni native: quelle passano dal motore dichiarato.

Python conserva `python-shell-interpreter` e usa `.venv` nelle cartelle
autorizzate. Un progetto con metadati di pacchetto usa `python -m build`,
che costruisce distribuzione sorgente e wheel tramite il backend del
progetto. Con soli sorgenti, riconosciuti anche da `requirements.txt` o
`Pipfile`, usa `compileall` e produce bytecode; esclude gli ambienti e le
cartelle di supporto più comuni. La compilazione esplicita rilegge i
sorgenti anche sulle versioni Python che riusano il bytecode dalla sola
data al secondo. I test usano pytest quando disponibile, altrimenti unittest.
[PyPA build](https://build.pypa.io/en/stable/) ·
[Compilazione del bytecode](https://docs.python.org/3/library/compileall.html).

**Configura compilazione** crea `.venv`; **Prepara gli strumenti Python…**
nel controllo installa gli strumenti nell'ambiente autorizzato. Queste
azioni sono esplicite. L'apertura di una cartella non installa pacchetti.
Un compilatore incrociato richiesto dal progetto deve essere disponibile:
GDev conserva la toolchain dichiarata e permette di impostarne i percorsi
tramite configurazione del progetto o variabili Make.

## Operazioni condivise e scelte personali

Un progetto può versionare `.gdev-project.eld`, letto come dati:

```elisp
(:version 1
 :default "Sviluppo"
 :profiles (("Sviluppo" :cwd "."
             :configure ("cmake" "-S" "." "-B" "build")
             :build ("cmake" "--build" "build")
             :test ("ctest" "--test-dir" "build" "--output-on-failure"))))
```

Le fasi possono comprendere `:configure`, `:build`, `:test`, `:run`,
`:clean` e `:debug`, con le stesse opzioni dei profili di avvio. Le liste
dei comandi contengono programma e argomenti separati. I profili personali
in `gdev-launch-profiles` prevalgono su quelli condivisi; seguono i profili
nativi e il riconoscimento del motore. Un solo profilo diventa predefinito;
con più profili senza `:default`, la prima operazione chiede la scelta.
Ogni azione rilegge la dichiarazione: un file errato invalida la copia
precedente e segnala il percorso, senza eseguire un vecchio comando.

GDev stesso dichiara in questo formato configurazione, compilazione nativa
e test. `./bin/gdev test` usa stato e configurazione temporanei e le
grammatiche installate, conservando il profilo reale. Per strumenti di
prova separati sono disponibili `GDEV_TEST_GRAMMARS` e
`GDEV_TEST_PYTHON_BUILD`. I requisiti Python delle prove sono fissati in
`test/requirements-project-build.txt`; gli strumenti diretti hanno licenza MIT.

**Aggiorna ambiente del progetto** rilegge i fornitori e aggiorna i
documenti aperti. Mise condivide le richieste, scarta le risposte superate
e ripristina le variabili rimosse. Un ambiente in preparazione o fallito
impedisce di avviare processi con strumenti incompleti. L'aggiornamento
conserva autorizzazioni e configurazione privata.

## Contratto tematico e modello finito

`gdev-project-operation-contracts` copre tutti i motori e linguaggi
riconosciuti. `gdev audit` espone `project_operation_contracts` e
`project_operation_model` insieme all'inventario di menu, tasti e viste.
Ogni nuovo fornitore deve avere riconoscimento, capacità, autorità delle
regole e prove di esecuzione e recupero. Il controllo del modello fallisce
se si registra un tipo senza contratto.

Il predicato di prontezza riceve cinque fatti booleani — contesto
riconosciuto, strumento disponibile, configurazione pronta, operazione
in corso e osservazione corrente — e quattro stati dell'ambiente. Si
esplorano tutte le `2⁵ × 4 = 128` combinazioni. Altri 30 casi classificano
stato del processo, codice e richiesta di interruzione. Il modello usa
gli stessi predicati del controllo operativo e del registro degli esiti.

Gli invarianti impongono che un'osservazione superata venga scartata, che
la prontezza richieda tutti i prerequisiti e che il successo derivi solo
da un processo terminato con codice zero. I test alterano deliberatamente
i predicati per verificare che il controllo produca controesempi
serializzabili. Con i 364 casi del ciclo formale, `model-check` esplora
522 casi. Le prove di integrazione verificano separatamente radici,
precedenze, isolamento, concorrenza e prodotti reali.

Il modello dimostra queste proprietà sui fatti finiti dichiarati. La
correttezza dei compilatori, delle ricette arbitrarie e dei servizi esterni
richiede le loro verifiche; l'inventario non equivale all'esecuzione di
tutte le funzionalità.
