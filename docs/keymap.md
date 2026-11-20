# Mappa dei tasti

Premi `C-h d k` per consultare questa mappa in Emacs. Dopo aver digitato un
prefisso, attendi un istante per vedere le scorciatoie del gruppo.
Nelle scorciatoie, `C` indica Controllo, `M` indica Meta e `S` indica Maiuscole.
Per gli esempi d'uso, consulta i [flussi di lavoro](workflows.md).

Rigenera questa mappa con `gdev docs` dopo aver modificato le scorciatoie.

## Tasti funzione

| Scorciatoia | Azione | Comando Emacs |
| --- | --- | --- |
| `<f5>` | Avvia o riprendi l'esecuzione passo passo | `gdev-debug-dwim` |
| `S-<f5>` | Termina la sessione di esecuzione passo passo | `gdev-debug-terminate` |
| `C-S-<f5>` | Riavvia la sessione di esecuzione passo passo | `gdev-debug-restart` |
| `C-<f5>` | Esegui il programma | `gdev-run-dwim` |
| `<f6>` | Esegui i test | `gdev-test-dwim` |
| `<f7>` | Compila il progetto | `gdev-build` |
| `S-<f7>` | Configura la compilazione | `gdev-build-configure` |
| `<f8>` | Vai al problema successivo | `next-error` |
| `S-<f8>` | Vai al problema precedente | `previous-error` |
| `<f9>` | Attiva o disattiva il punto di interruzione | `dape-breakpoint-toggle` |
| `<f10>` | Avanza di un passo senza entrare nella funzione | `gdev-debug-next` |
| `<f11>` | Entra nella funzione | `gdev-debug-step-in` |
| `S-<f11>` | Esci dalla funzione | `gdev-debug-step-out` |
| `<f12>` | Vai alla definizione | `gdev-find-definition` |
| `S-<f12>` | Cerca i riferimenti | `gdev-find-references` |

## C-c a — agenti

| Scorciatoia | Azione |
| --- | --- |
| `C-c a C` | menu di Claude Code |
| `C-c a a` | conversazione |
| `C-c a c` | Claude Code |
| `C-c a f` | aggiungi file al contesto |
| `C-c a g` | agente |
| `C-c a k` | interrompi |
| `C-c a m` | menu |
| `C-c a q` | ferma una sessione di Claude Code… |
| `C-c a r` | riscrivi selezione |
| `C-c a s` | invia |
| `C-c a x` | aggiungi al contesto |

## C-c b — aree di testo

| Scorciatoia | Azione |
| --- | --- |
| `C-c b <left>` | sposta scheda a sinistra |
| `C-c b <right>` | sposta scheda a destra |
| `C-c b K` | chiudi gli altri del progetto |
| `C-c b M` | elimina segnalibro |
| `C-c b R` | rinomina |
| `C-c b S` | salva tutti i file |
| `C-c b [` | precedente |
| `C-c b ]` | successivo |
| `C-c b b` | scegli un'area di testo |
| `C-c b i` | elenca le aree di testo |
| `C-c b k` | chiudi l'area di testo |
| `C-c b m` | imposta segnalibro |
| `C-c b n` | nuova area di testo |
| `C-c b o` | documenti aperti |
| `C-c b r` | ricarica dal disco |
| `C-c b s` | salva |
| `C-c b t` | riapri l’ultima scheda chiusa |
| `C-c b x` | apri Appunti |
| `C-c b y` | copia tutto il testo |
| `C-c b z` | manda in fondo all'elenco |

## C-c c — codice

| Scorciatoia | Azione |
| --- | --- |
| `C-c c .` | area di testo della guida |
| `C-c c ;` | commenta riga |
| `C-c c D` | riferimenti |
| `C-c c E` | anteprima di estrazione |
| `C-c c H` | gerarchia dei tipi |
| `C-c c L` | cursori sulle righe selezionate |
| `C-c c M` | cursori su tutte le occorrenze |
| `C-c c R` | riconnetti server di linguaggio |
| `C-c c S` | ferma server di linguaggio |
| `C-c c Z` | piega/espandi tutto |
| `C-c c a` | azioni sul codice |
| `C-c c c` | compila |
| `C-c c d` | definizione |
| `C-c c e` | valuta |
| `C-c c f` | formatta |
| `C-c c h` | gerarchia delle chiamate |
| `C-c c i` | vai all'implementazione |
| `C-c c j` | altro file (intestazione/sorgente) |
| `C-c c k` | documentazione |
| `C-c c o` | riordina importazioni |
| `C-c c q` | correzione rapida |
| `C-c c r` | rinomina simbolo |
| `C-c c s` | avvia server di linguaggio |
| `C-c c t` | vai alla definizione del tipo |
| `C-c c w` | togli gli spazi a fine riga |
| `C-c c z` | piega o espandi |

## C-c d — esecuzione passo passo

| Scorciatoia | Azione |
| --- | --- |
| `C-c d <` | livello superiore della pila |
| `C-c d >` | livello inferiore della pila |
| `C-c d B` | togli tutti i punti di interruzione |
| `C-c d C` | immagine della memoria |
| `C-c d I` | ispeziona la sessione |
| `C-c d M` | disassembla |
| `C-c d P` | gestisci i punti di interruzione |
| `C-c d R` | interprete interattivo |
| `C-c d W` | debug dello spazio |
| `C-c d a` | collegati a un processo |
| `C-c d b` | punto di interruzione |
| `C-c d c` | continua |
| `C-c d d` | avvia (scegli configurazione) |
| `C-c d e` | punto di interruzione condizionale |
| `C-c d f` | livello della pila delle chiamate |
| `C-c d g` | GDB (GUD) |
| `C-c d h` | interruzione dopo N passaggi |
| `C-c d i` | pannelli informativi |
| `C-c d k` | termina il processo |
| `C-c d l` | punto di registrazione |
| `C-c d m` | memoria |
| `C-c d n` | passo successivo |
| `C-c d o` | esci |
| `C-c d p` | pausa |
| `C-c d q` | termina la sessione |
| `C-c d r` | riavvia |
| `C-c d s` | entra |
| `C-c d t` | scegli il flusso di esecuzione |
| `C-c d u` | fino al cursore |
| `C-c d w` | osserva espressione |
| `C-c d x` | valuta espressione |

## C-c f — file

| Scorciatoia | Azione |
| --- | --- |
| `C-c f C` | copia |
| `C-c f D` | elimina |
| `C-c f P` | file di GDev-Emacs |
| `C-c f R` | rinomina |
| `C-c f S` | salva con nome |
| `C-c f U` | riapri come root |
| `C-c f d` | cartella |
| `C-c f e` | .dir-locals.el del progetto |
| `C-c f f` | apri |
| `C-c f h` | cronologia del file |
| `C-c f l` | copia file:riga |
| `C-c f p` | configurazione privata |
| `C-c f r` | recenti |
| `C-c f s` | salva |
| `C-c f u` | apri come root |
| `C-c f y` | copia nome |

## C-c g — Hit e HitHub

| Scorciatoia | Azione |
| --- | --- |
| `C-c g !` | risolvi i conflitti |
| `C-c g 3` | unisci tre file |
| `C-c g =` | mostra blocco |
| `C-c g B` | autori riga per riga |
| `C-c g D` | differenze strutturali (difftastic) |
| `C-c g F` | richieste e segnalazioni (Forge) |
| `C-c g L` | cronologia del file |
| `C-c g [` | blocco di modifiche precedente |
| `C-c g ]` | blocco successivo |
| `C-c g b` | cambia ramo |
| `C-c g c` | clona |
| `C-c g d` | comandi di Hit |
| `C-c g f` | comandi di Hit per il file |
| `C-c g g` | apri Hit |
| `C-c g h` | HitHub › |
| `C-c g h A` | Account › |
| `C-c g h A a` | accedi a GitHub |
| `C-c g h A c` | cambia account |
| `C-c g h A s` | stato degli account |
| `C-c g h R` | nuova bozza di versione |
| `C-c g h S` | nuova segnalazione |
| `C-c g h a` | esecuzioni (GitHub Actions) |
| `C-c g h b` | apri nel navigatore |
| `C-c g h c` | clona un archivio Git |
| `C-c g h d` | Archivi Git › |
| `C-c g h d d` | scegli l'archivio predefinito |
| `C-c g h d f` | crea un fork |
| `C-c g h d o` | apri le discussioni nel navigatore |
| `C-c g h d p` | apri i progetti nel navigatore |
| `C-c g h d s` | sincronizza il fork |
| `C-c g h g` | pubblica un frammento di codice |
| `C-c g h h` | panoramica dell'archivio |
| `C-c g h i` | identità dell'archivio Git |
| `C-c g h k` | controlli della richiesta |
| `C-c g h l` | esplora richieste di integrazione |
| `C-c g h n` | crea l'archivio su GitHub |
| `C-c g h o` | notifiche |
| `C-c g h p` | nuova richiesta di integrazione |
| `C-c g h r` | esplora versioni pubblicate |
| `C-c g h s` | esplora segnalazioni |
| `C-c g h u` | avvia un flusso automatico |
| `C-c g h w` | segui l'ultima esecuzione |
| `C-c g h y` | copia il collegamento permanente |
| `C-c g o` | collegamento alla riga |
| `C-c g r` | annulla blocco |
| `C-c g s` | prepara il blocco di modifiche |
| `C-c g t` | macchina del tempo |
| `C-c g v` | controllo di versione |

## C-c i — inserisci

| Scorciatoia | Azione |
| --- | --- |
| `C-c i S` | nuovo frammento |
| `C-c i d` | duplica riga/selezione |
| `C-c i e` | emoji |
| `C-c i s` | frammento di codice |
| `C-c i u` | carattere Unicode |
| `C-c i y` | dalla cronologia degli appunti |

## C-c n — note e procedure

| Scorciatoia | Azione |
| --- | --- |
| `C-c n A` | comandi dell’Agenda Org |
| `C-c n a` | agenda |
| `C-c n b` | inserisci una citazione |
| `C-c n c` | aggiungi una nota rapida |
| `C-c n e` | esporta le slide PDF |
| `C-c n l` | memorizza collegamento |
| `C-c n n` | file delle note |
| `C-c n p` | annota la pagina del PDF |
| `C-c n r` | procedura operativa |
| `C-c n s` | cerca nelle note |

## C-c o — apri

| Scorciatoia | Azione |
| --- | --- |
| `C-c o -` | cartella di questo file |
| `C-c o E` | interprete Lisp qui |
| `C-c o M` | risorse del Mac (CPU, RAM, rete) |
| `C-c o O` | apri nel programma predefinito |
| `C-c o P` | processi |
| `C-c o T` | terminale qui |
| `C-c o W` | anteprima web affiancata |
| `C-c o ]` | vai al terminale affiancato |
| `C-c o b` | database SQL |
| `C-c o c` | calcolatrice |
| `C-c o e` | interprete Lisp del progetto |
| `C-c o h` | cruscotto |
| `C-c o m` | pagina di manuale |
| `C-c o n` | nuovo terminale del progetto |
| `C-c o o` | mostra nel Finder |
| `C-c o p` | nuovo terminale con profilo |
| `C-c o r` | interprete interattivo |
| `C-c o s` | affianca un terminale |
| `C-c o t` | terminale (progetto) |
| `C-c o w` | navigatore web |

## C-c p — progetto

| Scorciatoia | Azione |
| --- | --- |
| `C-c p !` | comando nella cartella principale |
| `C-c p &` | comando in secondo piano |
| `C-c p A` | ripeti ultima attività |
| `C-c p C` | configura |
| `C-c p D` | modifica .dir-locals.el |
| `C-c p F` | azzera impostazioni di compilazione |
| `C-c p I` | catalogo degli standard |
| `C-c p K` | interrompi l'operazione |
| `C-c p Q` | riesegui i test falliti |
| `C-c p T` | tutti i test |
| `C-c p V` | rapporto di copertura |
| `C-c p a` | esegui attività… |
| `C-c p b` | aree di testo del progetto |
| `C-c p c` | compila |
| `C-c p d` | apri in Esplora file |
| `C-c p e` | dipendenze del progetto |
| `C-c p f` | apri file |
| `C-c p g` | ripeti l'ultima compilazione |
| `C-c p i` | assicurazione del progetto |
| `C-c p k` | chiudi le aree di testo del progetto |
| `C-c p l` | elenca i promemoria del progetto |
| `C-c p n` | nuovo progetto… |
| `C-c p p` | cambia progetto |
| `C-c p q` | esegui test al cursore |
| `C-c p r` | esegui |
| `C-c p s` | simbolo nel progetto |
| `C-c p t` | test del file o tutti i test |
| `C-c p v` | misura copertura |
| `C-c p x` | pulisci |
| `C-c p y` | tipo di compilazione |

## C-c P — profilazione

| Scorciatoia | Azione |
| --- | --- |
| `C-c P P` | profila secondo il contesto |
| `C-c P a` | errori di memoria (ASan) |
| `C-c P b` | misura l'avvio di Emacs |
| `C-c P c` | copertura dei test |
| `C-c P e` | profila Emacs |
| `C-c P f` | grafico a fiamma di un processo |
| `C-c P h` | misura prestazioni (hyperfine) |
| `C-c P i` | profilatore di Xcode (Instruments) |
| `C-c P k` | perdite di memoria (leaks) |
| `C-c P s` | profilo CPU (samply) |
| `C-c P t` | accessi concorrenti (TSan) |
| `C-c P u` | comportamento indefinito (UBSan) |

## C-c q — esci e sessioni

| Scorciatoia | Azione |
| --- | --- |
| `C-c q L` | riprendi la sessione interrotta |
| `C-c q Q` | esci senza salvare |
| `C-c q R` | riavvia e ripristina |
| `C-c q f` | chiudi la finestra di Emacs |
| `C-c q l` | ripristina sessione |
| `C-c q q` | esci |
| `C-c q r` | riavvia |
| `C-c q s` | salva sessione |

## C-c r — macchine remote

| Scorciatoia | Azione |
| --- | --- |
| `C-c r c` | chiudi le connessioni |
| `C-c r d` | interrogazione DNS (dig) |
| `C-c r h` | modifica ~/.ssh/config |
| `C-c r l` | registro di sistema |
| `C-c r n` | raggiungibilità (ping) |
| `C-c r o` | apri cartella via SSH |
| `C-c r p` | processi |
| `C-c r r` | macchina remota in Dired |
| `C-c r s` | apri come amministratore |
| `C-c r t` | terminale sulla macchina remota |
| `C-c r u` | servizi di sistema (systemctl) |
| `C-c r x` | comando sulla macchina remota |

## C-c s — cerca

| Scorciatoia | Azione |
| --- | --- |
| `C-c s *` | simbolo nel progetto |
| `C-c s .` | simbolo sotto il cursore |
| `C-c s I` | indice di tutte le aree di testo |
| `C-c s K` | installa documentazione |
| `C-c s O` | righe corrispondenti |
| `C-c s P` | in un altro progetto |
| `C-c s S` | nelle aree di testo aperte |
| `C-c s b` | segnalibri |
| `C-c s d` | in una cartella |
| `C-c s f` | file per nome |
| `C-c s g` | cerca nei file tracciati da Git |
| `C-c s h` | titoli |
| `C-c s i` | indice dell'area di testo |
| `C-c s k` | documentazione locale |
| `C-c s m` | posizioni segnate |
| `C-c s o` | cerca in rete |
| `C-c s p` | nel progetto |
| `C-c s r` | sostituisci nel progetto |
| `C-c s s` | nell'area di testo |
| `C-c s t` | promemoria nell'area di testo |
| `C-c s y` | simbolo nello spazio di lavoro |
| `C-c s z` | ripeti l'ultima ricerca |

## C-c t — attiva/disattiva

| Scorciatoia | Azione |
| --- | --- |
| `C-c t A` | preferenze di aspetto |
| `C-c t F` | schermo intero |
| `C-c t L` | numeri di riga relativi |
| `C-c t M` | statistiche della macchina |
| `C-c t W` | spazi visibili |
| `C-c t b` | carattere grande |
| `C-c t c` | margine destro |
| `C-c t d` | segnalazioni in linea |
| `C-c t e` | esplora file e stato Git |
| `C-c t f` | formatta al salvataggio |
| `C-c t h` | suggerimenti in linea |
| `C-c t i` | guide di rientro |
| `C-c t l` | numeri di riga |
| `C-c t m` | minimappa |
| `C-c t r` | sola lettura |
| `C-c t s` | controllo ortografico |
| `C-c t t` | tema chiaro/scuro |
| `C-c t w` | a capo automatico |
| `C-c t x` | controllo della sintassi |
| `C-c t z` | modalità concentrazione |

## C-c w — finestre e spazi di lavoro

| Scorciatoia | Azione |
| --- | --- |
| `C-c w 1` | scheda 1 |
| `C-c w 2` | scheda 2 |
| `C-c w 3` | scheda 3 |
| `C-c w 4` | scheda 4 |
| `C-c w 5` | scheda 5 |
| `C-c w 6` | scheda 6 |
| `C-c w 7` | scheda 7 |
| `C-c w 8` | scheda 8 |
| `C-c w 9` | scheda 9 |
| `C-c w <down>` | dividi in basso |
| `C-c w <right>` | dividi a destra |
| `C-c w =` | uniforma le finestre |
| `C-c w A` | apri documento in basso |
| `C-c w J` | scegli lo strumento aperto |
| `C-c w L` | pannello Lavorazioni |
| `C-c w M` | sposta documento in un altro gruppo |
| `C-c w N` | operazioni dello spazio |
| `C-c w O` | struttura del documento |
| `C-c w R` | rinomina spazio di lavoro |
| `C-c w T` | passa tra Comandi ed editor |
| `C-c w U` | ripeti disposizione |
| `C-c w W` | strumenti di scrittura |
| `C-c w Z` | ripeti operazione dello spazio |
| `C-c w [` | spazio di lavoro precedente |
| `C-c w ]` | spazio di lavoro successivo |
| `C-c w a` | affianca documento |
| `C-c w b` | rimuovi area di testo dallo spazio |
| `C-c w c` | chiudi spazio di lavoro |
| `C-c w d` | chiudi finestra |
| `C-c w g` | griglia 2×2 |
| `C-c w j` | mostra o nascondi il pannello |
| `C-c w k` | chiudi spazio e aree di testo |
| `C-c w m` | massimizza / ripristina |
| `C-c w n` | nuovo spazio di lavoro |
| `C-c w o` | passa al gruppo editor successivo |
| `C-c w p` | apri spazio di lavoro del progetto |
| `C-c w r` | sposta strumento nell'area di modifica |
| `C-c w s` | cambia spazio di lavoro |
| `C-c w t` | mostra o nascondi Comandi |
| `C-c w u` | annulla disposizione |
| `C-c w v` | scegli vista laterale |
| `C-c w w` | scegli finestra |
| `C-c w x` | scambia finestre |
| `C-c w z` | annulla operazione dello spazio |

## C-c ! — segnalazioni

| Scorciatoia | Azione |
| --- | --- |
| `C-c ! D` | problemi del progetto |
| `C-c ! P` | pannello Problemi |
| `C-c ! S` | lingua del controllo ortografico |
| `C-c ! d` | problemi del documento |
| `C-c ! l` | segnalazioni dell'area di testo |
| `C-c ! n` | problema successivo |
| `C-c ! p` | problema precedente |
| `C-c ! s` | correggi parola |

## C-h d — aiuto di GDev

| Scorciatoia | Azione |
| --- | --- |
| `C-h d a` | cerca nella documentazione |
| `C-h d c` | configurazione privata |
| `C-h d d` | diagnosi dell'ambiente |
| `C-h d e` | aggiorna l'ambiente dei comandi |
| `C-h d f` | file di GDev-Emacs |
| `C-h d g` | guida a Emacs in italiano |
| `C-h d i` | esercitazione di Emacs in italiano |
| `C-h d k` | promemoria dei tasti |
| `C-h d m` | descrivi modulo |
| `C-h d t` | tempi di caricamento dei moduli |

## C-c l — comandi del linguaggio corrente

### C e C++

| Scorciatoia | Azione |
| --- | --- |
| `C-c l a` | disassemblato |
| `C-c l b` | genera compile_commands.json con Bear |
| `C-c l o` | intestazione/sorgente |

### Common Lisp

| Scorciatoia | Azione |
| --- | --- |
| `C-c l P` | profila allocazioni |
| `C-c l h` | cerca nella HyperSpec |
| `C-c l i` | ispeziona |
| `C-c l l` | carica sistema ASDF |
| `C-c l m` | espandi macro |
| `C-c l p` | profila la CPU |
| `C-c l q` | carica una libreria con Quicklisp |
| `C-c l t` | misura il tempo |

### Emacs Lisp

| Scorciatoia | Azione |
| --- | --- |
| `C-c l b` | valuta l'intera area di testo |
| `C-c l c` | compila in codice intermedio |
| `C-c l d` | controlla documentazione (checkdoc) |
| `C-c l m` | espandi macro |
| `C-c l t` | esegui test |
| `C-c l x` | esegui funzione passo passo (edebug) |

### Perl

| Scorciatoia | Azione |
| --- | --- |
| `C-c l c` | controllo Perl::Critic del progetto |
| `C-c l d` | esegui passo passo con perldb |
| `C-c l k` | perldoc |
| `C-c l n` | profila (NYTProf) |
| `C-c l v` | copertura dei test |

### Python

| Scorciatoia | Azione |
| --- | --- |
| `C-c l T` | esegui i test del progetto |
| `C-c l a` | applica le correzioni sicure |
| `C-c l b` | genera i pacchetti distribuibili |
| `C-c l i` | riordina le importazioni |
| `C-c l s` | installa gli strumenti Python |
| `C-c l t` | esegui il test sotto il cursore |
| `C-c l v` | crea l'ambiente virtuale |

### SQL

| Scorciatoia | Azione |
| --- | --- |
| `C-c l a` | esegui file SQL |
| `C-c l b` | database SQL |
| `C-c l c` | scegli motore e connessione |
| `C-c l e` | esegui selezione SQL |
| `C-c l k` | manuale del motore |
| `C-c l t` | elenca tabelle |

### PostgreSQL

| Scorciatoia | Azione |
| --- | --- |
| `C-c l a` | esegui file SQL |
| `C-c l b` | database SQL per PostgreSQL |
| `C-c l c` | scegli connessione PostgreSQL |
| `C-c l e` | esegui selezione SQL |
| `C-c l k` | manuale di PostgreSQL |
| `C-c l t` | elenca tabelle |

### XML

| Scorciatoia | Azione |
| --- | --- |
| `C-c l c` | chiudi elemento |
| `C-c l d` | inserisci dichiarazione XML |
| `C-c l e` | segnalazione successiva |
| `C-c l k` | guida XML |
| `C-c l p` | segnalazione precedente |
| `C-c l s` | scegli schema RELAX NG |
| `C-c l x` | convalida con XSD |

### HTML e modelli di pagina

| Scorciatoia | Azione |
| --- | --- |
| `C-c l b` | apri nel navigatore |
| `C-c l p` | affianca anteprima web |
| `C-c l s` | servi una cartella |

### CSS

| Scorciatoia | Azione |
| --- | --- |
| `C-c l s` | servi una cartella |

### JavaScript

| Scorciatoia | Azione |
| --- | --- |
| `C-c l d` | esegui passo passo (node inspect) |
