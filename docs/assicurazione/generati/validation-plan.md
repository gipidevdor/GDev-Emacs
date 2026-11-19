<!-- Generato da GDev; non modificare. Fonti sha256:33ee28271a2d92bd1e8487b700618a8696bf81d343fc141c191706dd6b6b6758 -->

# Piano di validazione

## Fonte: docs/interfaccia.md

# Interfaccia di GDev

Su macOS il testo dell'interfaccia parte da 13 pt e usa il carattere di
sistema quando il motore grafico di Emacs lo espone. Titoli, sezioni e
dettagli mantengono la loro gerarchia quando si ingrandisce il testo. Codice,
console e colonne tabulari conservano la spaziatura fissa.
[Apple HIG — Tipografia](https://developer.apple.com/design/human-interface-guidelines/typography)

## Profili obbligatori

Ogni modalità definita in `modules/` dichiara una volta il proprio profilo
con `gdev-ui-view-setup`. I moduli che usano una modalità preesistente
ne ereditano la presentazione. Il [modello per le viste](../../../templates/vista.el)
mostra un'intestazione, uno stato vuoto e un'azione.

| Profilo | Uso |
| --- | --- |
| `document` | Pagine di controllo e consultazione con testo proporzionale |
| `sidebar` | Riquadri laterali con superficie, interlinea e selezione condivise |
| `table` | Tabelle di Emacs con intestazioni e colonne a spaziatura fissa |
| `native` | Editor e console che ereditano lo stile della modalità di Emacs |
| `preview` | Viste non testuali, come la minimappa |

Per i titoli usa `gdev-ui-view-title` o, in un riquadro laterale,
`gdev-ui-side-title`. Usa `gdev-ui-view-heading` per le sezioni e
`gdev-ui-secondary` per i dettagli. Il tipo di pulsante `gdev-ui-action`
usa lo stesso comando con Invio e con un clic. Riserva
`gdev-ui-action-primary` all'azione principale o al controllo selezionato.
Accompagna il colore degli stati con un'etichetta leggibile.

Per gli stati usa `gdev-ui-badge`, che affianca icona, parola e faccia:
`gdev-ui-status-success`, `gdev-ui-status-warning` e `gdev-ui-status-error`
per esito, attesa ed errore, `gdev-ui-status-accent` per uno stato concluso
che non è un errore, come una richiesta unita. `gdev-ui-insert-actions`
dispone una barra di pulsanti con una sola azione principale e va a capo
prima del pulsante che non ci sta. `gdev-ui-align-right` allinea al margine
destro un dato secondario, per esempio il tempo trascorso.
`gdev-ui-buffer-pixel-width` restituisce la finestra più stretta che mostra
la vista: usala per disporre le righe, così restano entro il bordo anche
quando lo stesso buffer compare in due finestre. Ridisponi la vista da
`window-size-change-functions` con i dati già ricevuti, senza rileggerli.
[Apple HIG — Pulsanti](https://developer.apple.com/design/human-interface-guidelines/buttons) ·
[Colore](https://developer.apple.com/design/human-interface-guidelines/color)

Per un trasferimento di scheda, indica il gruppo o il titolo che riceverà
il documento. Offri lo stesso risultato da menu e da tastiera e registra
lo spostamento nella cronologia della disposizione. [Apple HIG — Trascinamento](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)

Nella vista **Operazioni dello spazio** mostra i conteggi quando lo
strumento li rende disponibili. Usa un'etichetta di stato durante le
fasi senza conteggio e una sola azione di interruzione per ogni processo.
[Apple HIG — Indicatori di avanzamento](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

Le anteprime affiancate conservano il fuoco sul documento di partenza.
Usa il pannello degli strumenti quando lo spazio orizzontale non basta
per mantenere leggibili entrambi i riquadri. [Apple HIG — Riquadri affiancati](https://developer.apple.com/design/human-interface-guidelines/split-views)

Usa `help-echo` per rendere comprensibili le icone, le abbreviazioni e i
controlli il cui compito dipende dallo stato. Descrivi l'azione del clic
oppure il significato dell'indicatore. Per una descrizione, cerca di
restare entro 75 caratteri. Per un nome abbreviato, mostra il valore
completo. [Apple HIG — Aiuto contestuale](https://developer.apple.com/design/human-interface-guidelines/offering-help)

Mantieni il fuoco e la selezione usando l'identità della voce durante il
ridisegno. Adatta le righe alla larghezza effettiva. Usa i riquadri del
Workbench per aprire documenti, strumenti e attività.
[Apple HIG — macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) ·
[Viste divise](https://developer.apple.com/design/human-interface-guidelines/split-views)

Una vista ausiliaria che accompagna il lavoro nell'editor può dichiararsi con
`gdev-layout-mark-auxiliary` e aprirsi con il normale `pop-to-buffer`.
Il Workbench le riserva il riquadro inferiore della colonna di destra e usa
il pannello inferiore quando la colonna è troppo stretta o bassa. Appena
la colonna torna disponibile, la vista ancora aperta riprende il suo posto.
Tieni nel buffer lo stato della vista e usa il riquadro per azioni,
riepiloghi e cataloghi da consultare accanto al documento.

La suite ERT in CI verifica profili e contrasto. Per completare una vista,
controllala nella finestra nativa con tema chiaro e scuro, testo normale
e ingrandito, riquadro stretto, nomi lunghi e contenuto vuoto. Prova le
azioni con tastiera e puntatore. Il contrasto minimo del testo nelle
superfici comuni è 4,5:1.
[Apple HIG — Accessibilità](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Stato dello spazio di lavoro

**Assicurazione del progetto** è un documento del Workbench, con una vista
per spazio. Stato e prove si rileggono dal nucleo su un'istantanea SQL;
filtri, pagine, ridimensionamento, zoom e tema ridisegnano i dati già ricevuti.
La voce selezionata resta identificata durante gli aggiornamenti. La
transazione attiva passa da `gdev-assurance-workspace` e compare nella barra
di stato senza letture SQLite durante il ridisegno. Un cambio di cartelle
invalida insieme alle radici una scelta che non appartiene più al progetto.
Le operazioni in secondo piano conservano l'identità dello spazio d'origine.
Vedi la [guida del Workbench](../workbench.md).

`gdev-workspace-state` legge e pubblica lo stato condiviso dello spazio nella
scheda nativa. Il modulo responsabile decide i valori, l'API applica la
transizione. Usa `gdev-workspace-state-get` per leggere,
`gdev-workspace-state-set` per un campo e `gdev-workspace-state-update` per
pubblicare insieme più campi, per esempio cartelle e radice dell'albero.
Tratta i valori restituiti come dati in sola lettura.

Registra i campi con una regola di durata. `clone` ammette il salvataggio
e la copia quando si duplica lo spazio. `persist` ammette il salvataggio
della rappresentazione su disco. `transient` resta in memoria, per esempio
per i buffer dei pannelli. `until-close` scade alla chiusura dello spazio,
anche se lo riapri. È la regola dell'identità e dei seguiti di compilazione
in attesa. Una scheda trasferita tra finestre resta aperta. Rappresenta i
dati del documento nel buffer e i dati geometrici del riquadro nella sua
finestra.

Per un risultato asincrono conserva il frame e l'identità ottenuta con
`gdev-workspace-state-ensure-id`. Alla risposta cerca lo spazio con
`gdev-workspace-state-find` prima di aggiornare lo stato. La copia di una
scheda eredita le cartelle e i profili selezionati e riceve una propria
identità. Anche «Riapri l'ultimo spazio chiuso» riparte con una nuova
identità e recupera le preferenze della scheda. Il ripristino applica i
campi dello spazio dopo aver letto lo stato salvato. [API degli spazi di lavoro](../../../lisp/gdev-workspace-state.el)

Alla chiusura di uno spazio chiudi i buffer delle sue viste con
`tab-bar-tab-pre-close-functions`. Conserva quelli che un altro spazio mostra
ancora, come la copia appena duplicata. Esplora file segue questa regola:
ogni spazio aperto ne ha uno solo, anche dopo più riprese della sessione, e
«Riapri l'ultimo spazio chiuso» lo ricostruisce dalla cartella dello spazio.

Il coordinatore di compilazione gestisce l'accesso all'albero di build e
consegna l'esito al modulo di avvio o al riquadro Test. Il modulo di avvio
decide quale profilo eseguire nello spazio attivo. Il fornitore `mise`
gestisce le richieste di ambiente e riattiva i documenti in attesa.
[Compilazione](../../../lisp/gdev-compilation.el) · [Ambiente](../../../modules/tools/build/gdev-mise.el)

Ogni gruppo conserva l'ordine dei documenti insieme alle sue finestre.
La selezione multipla dell'albero appartiene alla vista che mostra le voci.
Lo spazio conserva la coppia di terminali e il riferimento alla cronologia
aperta come stato transitorio. Le copie dei file hanno una durata propria
nel profilo locale.

L'attività **Lavorazioni** usa il registro delle viste laterali dello
spazio. Risultati della ricerca e selezione appartengono alla vista.
Il motore associa gli esiti di verifica ed esecuzione al sorgente,
alla sua revisione e allo spazio che ha avviato l'azione.

## Contratti tra i moduli

Ogni regola nasce da un difetto corretto e vale per tutta la sua classe.

- **Contesto.** File, cartella e progetto di un comando vengono da
  `gdev-command-file`, `gdev-command-directory` e `gdev-command-project`;
  i nomi relativi da `gdev-command-relative-name`, che parte dalla cartella
  dello spazio come Esplora file. Una vista che mostra file dichiara la riga
  corrente con `gdev-command-file-function`. Durante «Cambia progetto» vale
  la cartella scelta, anche per `gdev-project-root`.
- **Documento attivo.** Un comando sul documento lanciato da Esplora file,
  dal pannello o da Comandi agisce sul documento dell'editor: usa
  `gdev-call-for-document` con l'argomento che distingue tastiera e menu.
  La cartella di compilazione viene da `gdev-build--root`, che sceglie il
  progetto più esterno di CMake o Meson anche da una sottocartella.
- **Pannello.** I moduli aprono e chiudono il pannello in basso con
  `gdev-layout-show-panel` e `gdev-layout-hide-panel`. Una vista
  temporanea che ripristina le finestre, come il confronto, usa
  `gdev-layout-restore-configuration`: le scelte fatte nel frattempo nel
  pannello prevalgono sulla disposizione registrata all'apertura.
- **Chiusura.** `q`, la × e `C-x k` seguono la regola del riquadro: nel
  pannello e nella colonna ausiliaria chiudono la vista con
  `gdev-close-document`, in Esplora file, nelle attività e in Comandi
  riportano all'editor. Una vista temporanea lega `C-x k` alla propria
  chiusura, così il confronto termina e ripristina le finestre.
- **Ripresa.** Uno strumento del pannello che può tornare dopo il riavvio
  si descrive con `gdev-layout-restore-function` e il suo modulo registra
  la funzione che lo ricrea con `gdev-layout-register-panel-restorer`.
  La sessione salva solo i tipi registrati. Lo spazio li ricrea quando
  mostra il pannello, senza processi avviati per le schede non visitate.
- **Operazioni.** Un lavoro asincrono con un esito visibile si registra
  nello spazio che lo avvia con `gdev-workbench-operation-start` e si
  conclude con `gdev-workbench-operation-finish`. Un'interruzione che non
  ferma un processo dichiara la propria funzione di arresto.
- **Persistenza.** La sessione salva solo i campi che la loro regola
  ammette, secondo `gdev-workspace-state-saved-p`. Le viste derivate da
  `special-mode` si ridisegnano dal loro stato e non diventano bozze. Una
  vista che si ridisegna azzera il segno di modifica, così la scheda non
  chiede di salvare.
- **Disponibilità.** Un comando utile solo in un contesto, come le azioni
  del server di linguaggio, dichiara la condizione nella proprietà
  `gdev-menu-available`. Finché la condizione non vale, la barra dei menu
  mostra il comando in grigio e Comandi non lo elenca. La regola vale anche
  per le voci ricavate dalle mappe dei tasti.
- **Reattività.** Il lavoro proporzionale alla lunghezza del documento
  aspetta una pausa nella digitazione e riusa i risultati della stessa
  revisione. Un aggiornamento ridisegna solo le viste che cambiano. Nessuna
  richiesta sincrona al server di linguaggio parte a ogni carattere.
- **Nomi dei fork.** Un modulo che usa un fork con un nome GDev registra il
  prefisso dei suoi comandi con `gdev-keys-register-commands`, insieme alle
  etichette dei comandi che compaiono senza descrizione. which-key e i menu
  ricavati dalle mappe dei tasti mostrano quelle etichette, oppure il nome
  GDev seguito dal resto del nome, come «Hit · log buffer file». Il nome
  originale del fork non compare. Con `:alias`, `M-x` e `M-X` offrono i
  comandi con il nome GDev, per esempio `hit-commit` al posto di
  `magit-commit`. I nomi originali e quelli obsoleti escono dai candidati ma
  restano validi per i tasti, la configurazione Lisp e le integrazioni. Un
  comando GDev con lo stesso nome, come `hit-status`, resta com'è e prende il
  posto dell'originale. Le descrizioni degli alias usano il nome GDev, anche
  per i comandi citati. Gli alias nascono alla prima apertura di `M-x` dopo il
  caricamento di un file del fork, quindi l'avvio non ne paga il costo.
  Accanto agli alias `M-x` mostra i tasti del comando originale, con
  l'annotatore integrato e con quello di Marginalia, e non il suo nome.
  La tavolozza dei comandi elenca per etichetta il comando reale del menu e,
  digitando un nome, offre solo comandi con il nome GDev.

## Dialoghi e conferme

Le conferme grafiche di Emacs usano **Sì**, **No** e **Annulla** dove
previsto. GDev localizza anche le domande più comuni su salvataggio,
sovrascrittura, modifiche sul disco, recupero e uscita. Su macOS traduce
l'intestazione del dialogo e il titolo dei pannelli di apertura e salvataggio.
I controlli dei pannelli di sistema seguono la lingua di AppKit.

## Appunti e gruppi vuoti

Apri **Appunti** con `C-c b x` o dal menu **File**. Appunti conserva la
modalità di modifica di Emacs. Un nuovo spazio, un gruppo senza documenti
o un gruppo ripristinato senza file mostra il Cruscotto, se attivo, o la
pagina iniziale con **Apri file…**.


## Fonte: docs/assicurazione/workbench.md

# Assicurazione nel Workbench

Apri **Progetto › Assicurazione del progetto** con `C-c p i`. La vista si
apre come documento del gruppo attivo; `q`, `⌘W` e la × della scheda la
chiudono. **Progetto › Catalogo degli standard**, `C-c p I`, apre lo stesso
strumento sul catalogo. Le azioni sono disponibili anche in **Comandi** e
in **Strumenti › Moduli › Assicurazione**.

La cartella sotto il titolo è il bersaglio delle operazioni. In uno spazio
con più cartelle, l'apertura parte dal contesto del documento. Con il
prefisso `C-u`, scegli una cartella esplicita. Ogni spazio conserva la propria
vista e la propria transazione attiva. La scelta attiva è transitoria:
dopo il riavvio si sceglie di nuovo, mentre l'archivio conserva la storia.

## Dalla modifica alla verifica

1. Scegli **Nuova transazione…**, scrivi titolo e profilo. La transazione
   diventa attiva e il suo identificativo compare nella barra di stato.
   Un clic sull'identificativo apre il progetto della transazione, anche
   quando il documento corrente appartiene a un'altra cartella dello spazio.
2. In **Controlli**, usa **Scegli standard…** prima dell'autorizzazione.
   Il completamento offre standard interi e singoli `STANDARD#OBIETTIVO`;
   separali con virgole e indica il motivo. Una scelta nuova sostituisce
   quella corrente, conservando la precedente nell'audit.
3. **Passaggio di stato…** applica le stesse regole della CLI:
   autorizzazioni, separazione degli attori, fasi e prove richieste.
4. In **Tracce**, registra gli artefatti e collega requisiti, sorgenti e
   prove. Salva un file modificato prima di registrarlo. L'apertura di un
   artefatto resta nel progetto; un collegamento a un bersaglio esterno non
   permette di uscire dalla cartella attraverso questa vista.
5. Nel ciclo di verifica, usa **Registra prova…** sull'obiettivo interessato.
   Scegli esito e rapporto. **Raccogli prova…** raccoglie una prova generale:
   non soddisfa automaticamente tutti gli obiettivi scelti.
6. **Registra valutazione** conserva gli esiti correnti. **Decisione…**
   segue le regole del controllo: profilo e standard mantengono le loro
   decisioni distinte, con motivo, attore e audit.

L'identità dichiarata segue la CLI: nome di accesso oppure
`GDEV_ASSURANCE_ACTOR`. Non è un'autenticazione. I profili avanzati mantengono
la dicitura «provvisorio». Gli obiettivi GDev non certificano conformità
normativa, livelli SLSA o capacità ISO. Ambiti e fonti sono nella
[guida degli standard](../standard/attuazione.md).

## Consultazione e comandi

| Sezione | Contenuto e azioni |
| --- | --- |
| Progetto | Campi richiesti, requisiti e collegamento della definizione alla lavorazione. |
| Transazioni | Modifiche del progetto, stato e profilo; seleziona una voce per lavorarci o consultarne la storia. |
| Controlli | Esiti del profilo e degli standard scelti, motivi, prove e decisioni. |
| Standard | Catalogo consultabile anche senza archivio, edizioni, criteri e collegamenti espliciti alle fonti ufficiali. |
| Tassonomie | Gerarchie, requisiti, fonti e parti ancora da integrare. |
| Procedure | Passi, input e risultati attesi; anteprima prima dell'avvio. |
| Esecuzioni | Tentativi, stati, risultati, errori e ripresa quando consentita. |
| Tracce | Artefatti con ruolo e relazioni; registrazione e collegamento di file. |
| Proposte | Dati, argomenti e digest delle proposte degli agenti; conferma o rifiuto. |
| Documenti | Sedici tipi editoriali del manifesto, apertura, confronto e generazione esplicita. |
| Capacità | Osservazioni aggregate; le deroghe non diventano controlli soddisfatti. |
| Audit | Integrità, installazione esplicita dei ganci e firma dell'indice ordinario o amend. |
| Impatto | File cambiati e artefatti interessati dalle dipendenze. |

Nelle finestre strette **Sezione: …** sostituisce la barra delle tredici
sezioni e mantiene disponibile l'intero elenco. `S` apre lo stesso selettore,
con la sezione corrente come scelta predefinita.

`Tab` e `Shift-Tab` percorrono i pulsanti; `Invio` esegue la stessa azione
del clic. `g` rilegge il progetto; `f` filtra i dati già ricevuti; `[` e `]`
cambiano pagina e portano il fuoco alla prima voce visibile. **Azzera filtro**
e `F` mostrano di nuovo tutte le voci; annullare l'inserimento conserva il
filtro precedente. Un filtro abbreviato mantiene il testo completo nell'aiuto.
`t` sceglie la transazione, `c` ne apre una, `a` avanza,
`s` sceglie gli standard, `v` registra una prova specifica, `e` una generale,
`d` decide sul controllo selezionato e `r` registra la valutazione.

I nomi restano completi e vanno a capo nelle finestre strette. Filtro,
paginazione, ridimensionamento, zoom e tema riusano i dati della vista senza
riaprire l'archivio. Un aggiornamento conserva la voce selezionata. Se CLI
o un altro processo cambiano l'archivio, premi **Aggiorna** per rileggere
un'istantanea coerente. La barra di stato mostra solo l'identità memorizzata
e non interroga SQLite durante il ridisegno.

La consultazione legge solo i dati necessari alla sezione. Le scelte dei
comandi rimangono disponibili anche senza caricare tutta la storia.
**Controlli**, le verifiche esplicite e i passaggi di stato continuano a
valutare le sorgenti correnti. Aprire un catalogo non produce un esito
positivo di verifica. Un errore di avvio della lettura resta visibile nella
pagina, da cui si può riprovare con **Aggiorna**.
Durante una rilettura i dati rimangono consultabili e **Aggiornamento in
corso…** indica che la risposta nuova non è ancora arrivata.

## Proposte, adozione e Git

La conferma di una proposta riguarda esattamente il digest mostrato. Un altro
evento, un file cambiato o una conferma già usata rendono superata la
proposta. Annullare il dialogo non scrive nell'archivio. L'azione conserva
l'identità di agente e non diventa una verifica umana.

**Adotta progetto esistente…** crea l'inventario iniziale in secondo piano.
La modifica resta proposta e le prove sono marcate come ricostruite.
**Operazioni dello spazio** mostra avanzamento, log ed eventuale interruzione.
Il completamento rimane associato allo spazio di partenza; cambiare spazio
non trasferisce la transazione a un altro progetto. Se nel frattempo cambi
le cartelle dello spazio o scegli un'altra transazione, il risultato non
sostituisce la nuova scelta attiva. Il nucleo rifiuta un
secondo inventario anche se un altro scrittore arriva per primo.

Un'interruzione conserva la selezione corrente anche quando arriva un esito
positivo tardivo. I dati già registrati restano consultabili nell'archivio;
il completamento non riapre uno spazio chiuso e non sposta il fuoco dal
documento su cui stai lavorando.

**Installa ganci Git…** richiede firmatari fidati esterni e identità del
repository; non sovrascrive ganci esistenti. **Firma indice…** e **Firma amend…**
controllano gli artefatti nell'albero Git immutabile. La ricevuta resta in
**Audit**; **Copia riferimenti commit** copia esplicitamente i riferimenti per
il messaggio. Per protezione remota e recupero controllato dell'archivio,
consulta la [guida del processo](../README.md).

Le lavorazioni offrono `assicurazione-valuta` e
`assicurazione-valuta-standard`, con argomento `transazione`. Controllano gli
esiti dovuti senza approvare o modificare la transazione; la seconda richiede
una scelta di standard. `assicurazione-proponi` continua ad accodare proposte
con l'identità di agente.
