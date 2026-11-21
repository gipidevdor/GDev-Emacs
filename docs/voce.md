# Voce italiana

Apri **Strumenti → Voce → Pannello Voce**, oppure premi `C-c v v`.
Il pannello accompagna il documento e usa gli stessi comandi del menu e della
tastiera. Aprirlo non attiva il microfono e non scarica nulla.

| Azione | Tasti | Comportamento |
| --- | --- | --- |
| Comando in italiano | `C-c v x` | Esegue un comando scritto, senza motore vocale. |
| Dettatura | `C-c v d` | Avvia il riconoscimento facoltativo; ripeti per terminare e trascrivere. |
| Comando vocale | `C-c v c` | Registra un comando; ripeti per eseguirlo. |
| Leggi testo | `C-c v l` | Legge la selezione o il testo dal cursore alla fine; con `C-u` legge tutto. |
| Pausa o riprendi lettura | `C-c v p` | Controlla la lettura corrente. |
| Interrompi voce | `C-c v s` oppure `C-g` | Interrompe ascolto, trascrizione, preparazione o lettura. |
| Scegli voce italiana | `C-c v i` | Elenca soltanto le voci di sistema disponibili. |
| Memorizza correzione vocale | `C-c v r` | Conserva una coppia di parole o frasi nelle preferenze. |
| Attiva riconoscimento locale | `C-c v a` | Prepara esplicitamente strumenti mancanti e modello. |

## Comandi e dettatura

I comandi scritti e quelli riconosciuti usano la stessa grammatica e il
catalogo delle azioni di GDev. Per esempio: «salva il file», «compila il
progetto», «vai alla riga ventitré», «seleziona le ultime due parole»,
«maiuscolo la selezione», «copia questa riga».

Puoi concatenare comandi con «e poi» o «quindi». La frase viene interpretata
per intero prima di applicare il primo comando: un seguito sconosciuto
fa rifiutare la sequenza. Un errore durante un'azione interrompe il seguito;
le azioni già completate conservano il loro normale annullamento.
«Non importa», «lascia perdere» o «annulla comando» annullano la sequenza.
Un'etichetta ambigua richiede la sezione del catalogo, per esempio
«apri · progetto».

Il testo tra virgolette resta letterale: «elimina "tutto"» cerca quella parola,
mentre «elimina tutto» agisce sul documento. «Sostituisci TipoA con
"C++::Tipo<T>" ovunque» conserva maiuscole e simboli del codice.

Durante la dettatura attendi l'indicatore **ascolto** prima di parlare.
«Virgola», «punto», «a capo», «nuovo paragrafo», «apri parentesi» e
«chiudi virgolette» producono punteggiatura; «letterale virgola» conserva
la parola. Per impartire un'azione durante la dettatura, inizia con
«comando,» oppure «GDev,». Un comando esplicito sconosciuto viene segnalato
e non inserito nel documento.

Il cambio di documento o spazio, la chiusura e una modifica manuale del testo
interrompono la sessione. Le risposte tardive non vengono applicate a un
altro documento. Il testo già dettato rimane annullabile con i comandi
ordinari. Non viene attivata la modalità globale originale di Earwig:
le scorciatoie personali e quelle già assegnate da GDev restano utilizzabili.
Se il motore non parte, **Diagnosi del motore vocale** apre il suo riscontro
tecnico dal pannello o dal menu. «Ascolto» compare solo dopo l'arrivo di audio;
in assenza di campioni la registrazione si arresta con un'indicazione sul
microfono e sui permessi di sistema.

## Dipendenze facoltative

Comandi scritti e grammatica usano Emacs e i fork già distribuiti.
Su macOS la lettura usa `/usr/bin/say` con le voci italiane di sistema;
non richiede Whisper. Su Linux può usare `espeak-ng` o `espeak` già installato.
La scelta della voce e la velocità sono preferenze del gruppo `gdev-voice`.

Il riconoscimento è **disattivato per impostazione iniziale**. Il bootstrap,
il pannello e il primo tentativo di dettatura non scaricano il modello.
L'attivazione esplicita prepara **Whisper Small multilingue**, con lingua
italiana, usando il [fork gipidevdor/whisper.cpp](https://github.com/gipidevdor/whisper.cpp)
alla revisione `5eaee0cc9024eb9e9a99469199920c8b7f5cb9ec`.
La preparazione compila da quel fork un motore dedicato. Riusa Sox oppure
FFmpeg e curl; su macOS Homebrew prepara soltanto gli strumenti mancanti.
Il preparatore usa la libreria standard di Python 3 già richiesta dalla CLI:
non installa pacchetti Python, ambienti virtuali o servizi cloud.

Il codice del motore è su GitHub. I pesi sono un file distinto,
`ggml-small.bin`, pubblicato su Hugging Face da `ggerganov/whisper.cpp`
alla revisione `5359861c739e955e79d9a303bcbc70fb988958b1`.
Il solo file dei pesi occupa **487.601.967 byte**, circa **488 MB**
decimali. Viene condiviso da tutti i progetti, fuori da Git, nella cartella
degli strumenti GDev, normalmente `~/.local/share/gdev-emacs/voce/`.
Il motore e la sua costruzione occupano spazio aggiuntivo.
`GDEV_TOOLS_DIR` cambia la cartella degli strumenti.
Il download si può riprendere ed è pubblicato solo dopo verifica di dimensione
e SHA-256. Modello, fork effettivamente costruito, origine, revisione e licenza sono registrati in
`installazione.json`; un file preesistente non valido viene conservato.
La preparazione appartiene all'applicazione: puoi continuare a scrivere,
cambiare documento e usare la lettura mentre procede. **Interrompi voce**
annulla esplicitamente anche la preparazione; il file parziale resta riprendibile.

**Disattiva riconoscimento** chiude il motore e mantiene il modello nella
cache per una riattivazione successiva. La cancellazione del modello è
un'operazione distinta: rimuovi il file indicato dal riscontro di installazione
quando nessuna istanza lo usa. Nessun modello viene eliminato implicitamente.

## Personalizzazione e verifica

`gdev-voice-vocabulary` suggerisce nomi tecnici, inizialmente GDev, Emacs,
Elisp, Makefile, CMake, Python, Perl e C++. Puoi aggiungere nomi del progetto.
**Memorizza correzione vocale** usa la selezione come proposta e conserva la
correzione nelle preferenze GDev. Vale per le trascrizioni successive e non
riscrive il documento né i comandi digitati.

Il riconoscimento e la sintesi avvengono sul computer. L'integrazione non
registra trascrizioni nei log e cancella i propri audio temporanei al termine
o all'interruzione. Il download dei pesi e degli strumenti richiede rete;
la dettatura preparata e la lettura usano risorse locali.

Le prove ordinarie comprendono grammatica, editing reale, BDD italiani,
contratti originali di Earwig, risposte superate, arresto e download simulato
con verifica delle impronte. Le prove acustiche con voce sintetica, la verifica
grafica e la prova con un microfono reale attestano aspetti distinti.
Il riconoscitore può sbagliare parole o punteggiatura: la correttezza dei
comandi interpretati non equivale a precisione assoluta dell'audio.

Voce GDev deriva da [Earwig 0.2.0](../vendor/elpa/earwig-0.2.0/GDEV.md),
GPL-3.0-or-later. [Codice e pesi Whisper](https://github.com/openai/whisper#license)
sono MIT, così come [whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE).
Le voci di sistema rimangono componenti del sistema operativo.
