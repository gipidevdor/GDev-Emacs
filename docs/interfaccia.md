# Interfaccia di GDev

Su macOS il testo dell'interfaccia parte da 13 pt e usa il carattere di
sistema quando il motore grafico di Emacs lo espone. Titoli, sezioni e
dettagli mantengono la loro gerarchia quando si ingrandisce il testo. Codice,
console e colonne tabulari conservano la spaziatura fissa.
[Apple HIG — Tipografia](https://developer.apple.com/design/human-interface-guidelines/typography)

## Profili obbligatori

Ogni modalità definita in `modules/` dichiara una volta il proprio profilo
con `gdev-ui-view-setup`. I moduli che usano una modalità preesistente
ne ereditano la presentazione. Il [modello per le viste](../templates/vista.el)
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
Vedi la [guida del Workbench](assicurazione/workbench.md).

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
campi dello spazio dopo aver letto lo stato salvato. [API degli spazi di lavoro](../lisp/gdev-workspace-state.el)

Alla chiusura di uno spazio chiudi i buffer delle sue viste con
`tab-bar-tab-pre-close-functions`. Conserva quelli che un altro spazio mostra
ancora, come la copia appena duplicata. Esplora file segue questa regola:
ogni spazio aperto ne ha uno solo, anche dopo più riprese della sessione, e
«Riapri l'ultimo spazio chiuso» lo ricostruisce dalla cartella dello spazio.

Il coordinatore di compilazione gestisce l'accesso all'albero di build e
consegna l'esito al modulo di avvio o al riquadro Test. Il modulo di avvio
decide quale profilo eseguire nello spazio attivo. Il fornitore `mise`
gestisce le richieste di ambiente e riattiva i documenti in attesa.
[Compilazione](../lisp/gdev-compilation.el) · [Ambiente](../modules/tools/build/gdev-mise.el)

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
