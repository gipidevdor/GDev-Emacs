# Configurazione e manutenzione

## Installa e apri un progetto

Su macOS servono [Homebrew](https://brew.sh/) e gli strumenti da riga di comando di Apple, che puoi installare con `xcode-select --install`. Scarica i sorgenti e avvia il programma di installazione.

```sh
git clone https://github.com/gipidevdor/GDev-Emacs.git
cd GDev-Emacs
./bin/gdev-bootstrap-macos
```

Se hai già i sorgenti, esegui solo l’ultimo comando dalla radice del repository. Il programma prepara Emacs e gli strumenti di sviluppo, installa `gdev` in `~/.local/bin` e crea **GDev-Emacs.app** in `~/Applications`. Poi apre GDev e attende il riscontro della finestra e del banco di lavoro prima di dichiarare l’avvio verificato. Non devi inserire alcuna directory: il lanciatore ricava il checkout automaticamente.

Per le aperture successive usa l'icona **Emacs** oppure **GDev-Emacs.app**,
che puoi aggiungere al Dock. Da terminale usa `./bin/gdev emacs` dalla
cartella dei sorgenti. Dopo la sincronizzazione riuscita, l'installazione
prepara un ingresso gestito in `~/.emacs.d`: anche l'applicazione Emacs
ordinaria carica il checkout GDev e i percorsi scelti, senza dipendere
dall'ambiente del terminale.

I file preesistenti `~/.emacs`, `~/.emacs.el`, `~/.emacs.elc` e
`~/.emacs.d` vengono conservati in
`~/.gdev-emacs-backups/installazione-…/`. Il programma stampa la cartella
effettiva; `ripristino.eld` e `LEGGIMI.txt` descrivono come ripristinare i
percorsi originali. La configurazione XDG esistente resta intatta. Un
ingresso GDev già identico viene riusato, senza nuovi spostamenti.
Il collegamento `~/.config/emacs` viene creato soltanto se assente.

Se un'installazione precedente apre ancora Emacs standard dall'icona,
aggiorna il checkout ed esegui `./bin/gdev install`, poi riapri Emacs.
La procedura prepara entrambi gli ingressi grafici anche senza rieseguire
l'intero bootstrap. Un comando personale `~/.local/bin/gdev` preesistente
resta conservato: in quel caso usa l'ingresso dalla cartella dei sorgenti.

Puoi rieseguire il bootstrap dopo un’interruzione. Per controllare l’installazione usa `./bin/gdev doctor`. L’opzione `--no-launch`, destinata alle installazioni automatiche, salta l’apertura e dichiara esplicitamente che la finestra non è stata verificata. `GDEV_APPLICATIONS_DIR` permette di scegliere una posizione diversa per l’app dedicata.

1. Nel cruscotto GDev scegli **Nuovo progetto…** (`C-c p n`) per creare un progetto oppure **Apri cartella…** (`⇧⌘O`) per lavorare su file esistenti.
2. Premi `⌘P`, scrivi parte del nome di un file e aprilo.
3. In un progetto C o C++, premi `F7` per compilare. I risultati compaiono sotto il codice. Con `F8` raggiungi il problema successivo.

## Scegli cosa caricare

La tua configurazione sta in `~/.config/gdev` (o `$GDEV_USER_DIR`), fuori dall'archivio dei sorgenti. Puoi
versionarla a parte e conservarla tra un aggiornamento e l'altro.

| File | Contiene |
| --- | --- |
| `init.el` | Moduli attivi e opzioni nel blocco `gdev!` |
| `packages.el` | Pacchetti aggiuntivi, uno per chiamata a `gdev-package` |
| `config.el` | Impostazioni personali, caricate per ultime |

```elisp
(gdev! :editor (format +onsave) fold
       :ui workbench
       :lang cc perl
       :config default)
```

Trovi l'elenco dei moduli nel [modello di configurazione](../templates/init.el).
I linguaggi distribuiti si attivano anche all'apertura di un file che ne
richiede la modalità: per esempio un `.swift` riceve colorazione e comandi
senza aggiungere `swift` a `init.el`. Documenti dello stesso linguaggio e
compilazioni in corso condividono l'attivazione. Alla chiusura dell'ultimo
documento o termine dell'ultima operazione GDev ritira le capacità temporanee;
le librerie rimangono nella cache di Emacs per le aperture successive.
Un linguaggio dichiarato nel blocco `gdev!` resta una scelta permanente.
Le associazioni personali tra file e modalità hanno la precedenza.

Dopo aver modificato `init.el` o `packages.el`, esegui `gdev sync` e premi
`C-c q R` per riavviare Emacs e ripristinare la sessione.

Il modulo `:ui workbench` attiva tema, caratteri, menu in italiano e gestione dei
riquadri e delle aree di testo. Le configurazioni che usano `popup` attivano lo stesso modulo.
`gdev compile` genera il codice intermedio dell'interfaccia in `modules/ui/workbench/`.

`gdev compile` e `gdev sync` compilano anche i file privati presenti. I rispettivi
`.elc` vengono salvati accanto ai sorgenti. Se modifichi un `.el`, al prossimo
avvio Emacs carica il sorgente più recente. Dopo un aggiornamento, esegui
`gdev compile --native` per rigenerare il codice compilato.
`gdev clean` rimuove i file compilati.

`GDEV_STATE_DIR` cambia la cartella di stato. Puoi usarne una separata
per eseguire prove in un'istanza isolata. `GDEV_TOOLS_DIR` cambia la cartella
dei programmi di supporto installati dal programma d'installazione.

## Stato e impostazioni in SQLite

Ogni profilo usa `stato.sqlite` nella propria cartella di stato. Serve una
build di Emacs con supporto SQLite, verificabile con `M-: (sqlite-available-p)`.
Con una cartella di stato vuota, la prima scrittura crea il database e lo
schema dai sorgenti. Non servono un server, un account del database o un
archivio copiato da un'altra installazione. I percorsi possono contenere
spazi e caratteri non ASCII; le prove di contratto verificano due avvii
separati e quattro processi che inizializzano lo stesso profilo.
Il registro di audit dei progetti formali ha un ciclo di vita distinto e vive
nel progetto. La definizione versionata del progetto e i file Lisp privati
continuano a viaggiare con i rispettivi sorgenti.

| Dato | Dove si trova nell'archivio del profilo |
| --- | --- |
| Opzioni disponibili, tipo dichiarato, espressione predefinita e possibilità di applicazione locale | `catalogo_opzione`, aggiornato anche quando un modulo dichiara nuove opzioni |
| Valori scelti, facce, icone, scorciatoie e variabili dell'ambiente della shell | `ambito`, `impostazione` e `componente` |
| Preferenze dei documenti | Ambiti distinti per sessione, tipo di progetto e radice del singolo progetto |
| Scelte di compilazione | Ambito del progetto |
| Sessione corrente, sessioni interrotte, schede e riquadri | `sessione`, `spazio` e proprietà dello spazio |
| Cartelle, documenti e bozze degli editor | `cartella_spazio`, `documento_spazio` e `bozza` |
| Alias, comandi e cartelle di Eshell, cronologie IELM e SLY | Ambiti distinti per ciascun servizio. I percorsi personalizzati esterni continuano a usare il formato del servizio |
| Cronologia degli annullamenti | Ambito del documento con dimensione, impronta, passi annullabili, passi pendenti ed equivalenze |
| Revisione Git precedente a un aggiornamento | Ambito del checkout, usato da `gdev rollback` |
| File recenti, posizioni del cursore, progetti conosciuti, segnalibri e cronologie di Emacs | Ambiti dedicati a ciascun servizio |

Lo schema è in terza forma normale. Il nome identifica la dichiarazione di
un'opzione. Il tipo e il riferimento identificano il suo ambito. La coppia
ambito e nome identifica un valore scelto, e ogni sua componente ha un padre
e una posizione. Una scheda appartiene a una sessione. Le associazioni ordinate
alle cartelle e ai documenti hanno ciascuna una riga. Una bozza appartiene alla
sessione e può essere aperta da più schede. Liste e vettori sono scomposti in
componenti, mentre le espressioni predefinite del catalogo sono codice Lisp
conservato a scopo descrittivo.

GDev importa i dati precedenti al primo utilizzo del servizio. Le successive
scritture avvengono in transazioni SQLite. I file precedenti restano disponibili
per il recupero. Per una copia del profilo, chiudi Emacs prima di copiare
la cartella di stato, che contiene anche le copie dei documenti e i dati
autonomi dei pacchetti.

### Verifica e recupero del profilo

Alla prima apertura GDev verifica l'identità dell'archivio, la struttura,
le pagine e i riferimenti tra le tabelle. La migrazione alla versione 2
conserva una copia verificata della versione 1 prima di aggiornare le
sessioni. Un'interruzione annulla la transazione. Un altro processo attende
il lock fino a cinque secondi. Se l'archivio è danneggiato, estraneo o di
una versione incompatibile, Emacs consente di aprire e modificare i file
con il profilo GDev sospeso.

Durante l'uso GDev prepara una copia giornaliera in un processo separato.
Alla chiusura completa la copia se necessario. La cartella `copie-stato/`
conserva le ultime tre giornate e le copie precedenti alle migrazioni.
Una copia danneggiata viene conservata. GDev ne pubblica una valida con un nome distinto.
Le copie vengono preparate con un nome ancora assente in una cartella
temporanea privata, verificate e poi pubblicate senza sovrascrivere file
esistenti. Questo permette di usare anche librerie SQLite che rifiutano
una destinazione vuota già creata. Una copia interrotta non viene pubblicata.
La rotazione usa il giorno riportato nel nome. Se `copie-stato` è un collegamento simbolico,
GDev consente di elencarne e recuperarne le copie e sospende le scritture automatiche in quella cartella.
Per conservare una copia su un altro disco puoi indicare un file nuovo.

```sh
./bin/gdev stato verifica
./bin/gdev stato copia /Volumes/Archivio/gdev-oggi.sqlite
./bin/gdev stato copie
./bin/gdev stato recupera ultima "$HOME/gdev-recuperato"
GDEV_STATE_DIR="$HOME/gdev-recuperato" ./bin/gdev emacs
```

Con `ultima`, GDev cerca la copia valida con la data più recente nel nome.
A parità di giorno usa l'ora nel nome. Per i nomi con la sola data usa l'ora di
modifica se coincide il giorno, altrimenti li colloca all'inizio di quella giornata.
Puoi anche indicare il percorso di una copia esterna. GDev prepara il database,
l'eventuale migrazione e la prima copia verificata in una cartella temporanea
privata accanto alla destinazione. Pubblica l'intera cartella con una rinomina.
Se il processo viene terminato durante la preparazione puoi rilanciare lo stesso
comando. Può rimanere una cartella temporanea `.gdev-recupero-…`.
Una destinazione già occupata viene rifiutata. Il profilo di origine resta disponibile per l'ispezione.
La data della copia determina l'ultimo stato recuperabile da quella copia.
Per operare sul database di un profilo nominato usa `gdev --profile NOME stato`.

In **Preferenze › Personali › Moduli del profilo…** puoi attivare un modulo
con le sue opzioni, disattivarlo o ripristinare la scelta di `init.el`.
L'editor e `gdev sync` leggono la stessa selezione. Dopo aver cambiato
i moduli, esegui `gdev sync` e riavvia Emacs.

## Profili e moduli personali

Un modulo personale vive in `~/.config/gdev/modules/CATEGORIA/NOME/config.el`.
Attivalo in `gdev!` nel tuo `init.el`. Se ti serve un pacchetto aggiuntivo,
dichiaralo in `packages.el`. Dopo `gdev sync`, trovi il modulo in `C-h d m`.
Un modulo che fallisce durante l'attivazione viene segnalato da `gdev doctor`.
I registri GDev pubblicano le sue capacità una volta riuscito il caricamento.
Durante la valutazione di `config.el`, `gdev-module-status` restituisce
`loading`. Usa `gdev-register-after-module` per le operazioni che devono
vedere il modulo `active` e i suoi nuovi gestori. Se annulli un tentativo
durante la valutazione, resta disponibile l'esito precedente.

Le azioni di un modulo possono comparire in **Comandi** e in **Strumenti › Moduli**
con una sola dichiarazione in `config.el`. Usa un identificatore del modulo,
il nome del gruppo, un’icona in `icons/` e i comandi interattivi già definiti.

```elisp
(gdev-set-tool-actions 'note-di-lavoro "Note di lavoro" "notes"
  ["Apri le note…" mie-note-apri]
  ["Registra una voce…" mie-note-registra :visible (derived-mode-p 'org-mode)])
```

I predicati facoltativi `:visible` e `:active` si valutano nella vista in uso.
Le azioni locali di una vista possono usare `gdev-context-items` e i linguaggi
continuano a pubblicare le proprie scorciatoie tramite `gdev-localleader`.

Per provare un profilo con configurazione, cache e sessioni proprie:

```sh
gdev --profile laboratorio install
gdev --profile laboratorio emacs
```

Una configurazione personale già esistente può mantenere permanenti i moduli
desiderati copiandone le voci da [templates/init.el](../templates/init.el).

## Tieni in ordine l'installazione

| Azione | Comando |
| --- | --- |
| Allineare i pacchetti ai moduli attivi | `gdev sync` |
| Rigenerare il codice intermedio del nucleo, dei moduli attivi e dei file privati | `gdev compile` |
| Compilare anche il nucleo e i moduli attivi in codice nativo | `gdev compile --native` |
| Aggiornare i sorgenti e i pacchetti | `gdev upgrade` |
| Preparare un avvio da una revisione precedente | `gdev rollback [REVISIONE]` |
| Controllare strumenti e grammatiche | `gdev doctor` |
| Aggiornare l'ambiente di Emacs quando lo apri dal Dock | `gdev env` |
| Misurare i tempi di avvio | `gdev bench` |
| Rigenerare la mappa dei tasti | `gdev docs` |

Da Emacs, `M-x gdev-env-refresh` aggiorna l'ambiente in secondo piano.
La lettura della shell scade dopo cinque secondi; fino a un risultato
completo restano attivi i valori precedenti. `M-x gdev-env-refresh-cancel`
annulla l'aggiornamento. Anche un avvio dal Dock senza ambiente salvato
lascia disponibile l'editor durante la lettura.

GDev usa fino a quattro processi per la compilazione nativa e per le
grammatiche indipendenti. Imposta `GDEV_JOBS=1` per eseguire queste operazioni
una alla volta.

`gdev help` elenca i comandi e le opzioni. I pacchetti, la cronologia e
le sessioni salvate risiedono in `~/.local/state/gdev-emacs`.

Per usare GitHub da HitHub, apri **HitHub › Account › Accedi a GitHub**. Le istruzioni per salvare le
credenziali nel Portachiavi di macOS sono nelle sezioni [Hit e HitHub](workflows.md#hit-e-hithub)
e [Agenti](workflows.md#agenti).
