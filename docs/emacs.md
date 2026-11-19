# Guida a Emacs in italiano

Premi `C-h d g` per tornare a questa guida e `C-h d i` per avviare
l'esercitazione ufficiale in italiano. Gli esercizi si svolgono direttamente
in Emacs. Per le scorciatoie proprie di GDev, consulta la
[mappa dei tasti](keymap.md).

## Come si legge una scorciatoia

- `C` indica Controllo, `M` indica Meta e `S` indica Maiuscole.
  In GDev su macOS, Meta è normalmente Opzione sinistra. `⌘` indica Comando.
- In `C-x C-f`, premi prima Controllo insieme a `x`, poiché i due
  tasti formano un prefisso. Premi poi Controllo insieme a `f`.
- `RET` indica Invio, `SPC` la barra spaziatrice e `TAB` la tabulazione.
- `C-g` annulla una richiesta in corso. `M-x` apre la scelta di un comando.
  Scrivine il nome e premi Invio. `C-u` fornisce un argomento al comando che segue.

## File, aree di testo e finestre

Un'area di testo può contenere un file, un documento ancora senza nome o
i risultati di uno strumento. Una finestra di Emacs è un riquadro che
mostra un'area di testo. Più riquadri possono mostrare lo stesso contenuto.
In GDev ogni spazio di lavoro ricorda la disposizione dei propri riquadri.

| Azione | Emacs | GDev su macOS |
| --- | --- | --- |
| Apri un file | `C-x C-f` | `⌘O` |
| Salva il file corrente | `C-x C-s` | `⌘S` |
| Salva con un altro nome | `C-x C-w` | `⇧⌘S` |
| Passa a un'area di testo aperta | `C-x b` | **Vai a › Documento aperto…** |
| Elenca le aree di testo | `C-x C-b` | `C-c b i` |
| Chiudi l'area di testo corrente | `C-x k` | `⌘W` chiude la scheda o la vista attiva |
| Affianca due riquadri | `C-x 3` | **Finestra › Dividi a destra** |
| Dividi il riquadro in alto e in basso | `C-x 2` | **Finestra › Dividi in basso** |
| Passa al riquadro successivo | `C-x o` | **Finestra › Passa all’altro gruppo di modifica** |

Con `⌘P` cerchi un file per nome nel progetto. Con `⌘B` mostri o nascondi
**Esplora file**. Con `⌘J` mostri o nascondi il pannello degli strumenti.
Il [flusso per progetti e spazi di lavoro](workflows.md#progetti-e-spazi-di-lavoro)
spiega come cambiare progetto e riprendere una sessione.

## Muovi il cursore e modifica il testo

| Azione | Scorciatoia |
| --- | --- |
| Vai al carattere successivo o precedente | `C-f` o `C-b` |
| Vai alla riga successiva o precedente | `C-n` o `C-p` |
| Vai all'inizio o alla fine della riga | `C-a` o `C-e` |
| Vai all'inizio o alla fine del documento | `M-<` o `M->` |
| Imposta l'inizio della selezione | `C-SPC`, poi sposta il cursore |
| Copia o taglia la selezione | `M-w` o `C-w` |
| Incolla l'ultimo testo copiato o tagliato | `C-y` |
| Dopo aver incollato, scegli un elemento precedente | `M-y` |
| Annulla una modifica | `C-/` oppure `⌘Z` su macOS |

La cronologia degli appunti permette di recuperare più elementi. Con GDev su
macOS puoi usare anche `⌘C`, `⌘X` e `⌘V`. Quando manca una selezione, il menu
contestuale offre **Copia riga** e **Taglia riga**. Premi `⇧⌘Z` o `⌘Y` per
ripetere una modifica annullata.

## Cerca e sostituisci

`C-s` cerca in avanti mentre scrivi e `C-r` cerca all'indietro. Ripeti
lo stesso tasto per passare all'occorrenza successiva o precedente. Premi Invio
per restare sul risultato oppure `C-g` per annullare la ricerca in corso.
Su macOS, dopo Invio, usa **Cerca › Trova successivo** (`⌘G`) o
**Trova precedente** (`⇧⌘G`) per riprendere l'ultima ricerca.

`M-%` chiede il testo da cercare e il suo sostituto. Premi `y` per confermare
una sostituzione, `n` per passare oltre o `q` per terminare. La ricerca nell'intero
progetto è in **Cerca › Cerca nei file…** (`⇧⌘F`).

## Modalità e aiuto

La modalità principale adatta l'area di testo al contenuto. Per esempio, descrive
come indentare un programma e quali comandi usare su un file Org. Le modalità
minori aggiungono funzioni come il controllo ortografico o i numeri di riga.
`C-h m` elenca le modalità attive nell'area di testo corrente e le loro scorciatoie.

| Per sapere come funziona… | Premi |
| --- | --- |
| Una scorciatoia | `C-h k`, poi digita la scorciatoia |
| Un comando | `C-h f`, poi scrivi il nome |
| Una variabile di configurazione | `C-h v`, poi scrivi il nome |
| Un modulo di GDev | `C-h d m`, poi scegli il modulo |
| Il lettore dei manuali Info | `C-h i` |
| Il manuale GNU installato con Emacs | `C-h r` |

In Info, `m` apre una voce del capitolo, `u` risale al livello superiore,
`l` torna alla pagina precedente e `q` chiude la consultazione.
Il [catalogo dei manuali GNU](https://www.gnu.org/software/emacs/manual/)
raccoglie anche la documentazione di Emacs Lisp e dei singoli strumenti.
