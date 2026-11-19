# Ricognizione e razionalizzazione della base

Campagna del 19 novembre 2026, con requisiti, scheda operativa e verifiche
collegati al progetto formale di GDev. Le modifiche riguardano servizi
condivisi, visualizzazione, ricerca e il fork Consult GDev.

## Perimetro della ricognizione

Il lettore delle forme Lisp ha esaminato 179 sorgenti del nucleo e dei
moduli e 827 file dei 98 pacchetti registrati, per 17.145 definizioni
`defun` e `cl-defun`. Non sono emersi errori di lettura. Il grafo di
caricamento del codice GDev raccoglie 109 feature, senza proprietari
duplicati o cicli. Dipendenze differite e chiamate dinamiche restano
distinte dalle dipendenze immediate analizzate.

Il confronto dei corpi ha prodotto 15 gruppi di candidati nei fork.
L'uguaglianza del corpo non basta per accorpare API: alcuni costruttori
hanno parametri predefiniti diversi; gli esportatori hanno contratti di
backend distinti; helper di pacchetti indipendenti non giustificano una
nuova dipendenza comune. L'analisi conserva queste differenze.

Sono stati inoltre controllati la sintassi di sette sorgenti Python e tre
entrate shell. Un file `.py` della raccolta Yasnippet è un modello con
segnaposto e viene classificato come dato, non come programma Python.
Questi controlli statici non attestano ogni servizio esterno o ogni
linguaggio che l'editor può utilizzare.

## Cambiamenti verificabili

- `gdev-graph` riunisce visite e rilevamento dei cicli. Tassonomie, requisiti
  e impatto conservano le regole del proprio dominio e usano primitive
  iterative, indipendenti da editor, filesystem e SQL. La nuova libreria
  entra nell'impronta dei motori, anche per progetti esterni a GDev.
- Le relazioni dei requisiti e i genitori delle tassonomie usano indici;
  la visita non cerca ogni dipendenza nell'intera lista. Le catene profonde
  non dipendono dalla pila di valutazione Lisp.
- Input e uscite del progetto si raccolgono in un passaggio. Le liste
  restituite sono nuove: ordinamento e deduplicazione non modificano le
  liste del manifesto.
- Inventario e confronto Git usano lo stesso selettore delle sorgenti.
  L'indice delle uscite si costruisce una volta per lettura, evitando una
  ricostruzione per ogni file.
- La capacità osservata indicizza i controlli incontrati e accoda quelli
  dinamici in un passaggio, mantenendo ordine e primo titolo. Il metodo
  continua a descrivere osservazioni, senza attribuire capacità normativa.
- La minimappa usa aggregazione adattiva all'ordine dei dati; Cerca aggiorna
  selettore e riepilogo, conservando fuoco e scorrimento. I dettagli sono
  nel [catalogo degli algoritmi](algoritmi-e-visualizzazione.md) e nella
  [verifica della ricerca](ricerca-fluida-verifica.md).

## Fork Consult GDev

Il fork mantiene nomi Lisp, origine, revisione e licenza di Consult 3.10.
La normalizzazione di Imenu usa una pila esplicita e materializza i prefissi
soltanto per i gruppi che producono candidati. Ordine, facce, proprietà,
marcatori e destinazioni speciali restano invariati; gli input non vengono
modificati. Il confronto usa entrambe le funzioni compilate in bytecode,
nello stesso processo e sugli stessi dati, con sette ripetizioni.

| Caso | Prima, mediana | Dopo, mediana |
| --- | ---: | ---: |
| 3.000 voci piatte | 13,96 ms | 13,97 ms |
| 100 gruppi con 30 voci | 14,83 ms | 14,77 ms |
| 500 gruppi annidati con una foglia | 24,01 ms | 0,39 ms |

Per misurare il caso profondo è stato alzato il limite della pila per
entrambe le versioni. Una prova separata normalizza 3.000 gruppi con limite
100: il comportamento precedente supera quel limite, la visita iterativa
termina. La garanzia riguarda la normalizzazione, non ogni fornitore Imenu.

## Complessità e risultati

Il confronto controllato nello stesso processo, con funzioni valutate
nella stessa forma, misura anche due percorsi algoritmici:

| Caso | Prima, mediana | Dopo, mediana |
| --- | ---: | ---: |
| 100.000 marcatori ordinati, 1.024 righe | 438,78 ms | 194,14 ms |
| Impatto: 8.000 artefatti e percorsi, 7.999 archi | 327,73 ms | 60,30 ms |

Queste misure escludono SQL, lettura dei file e disegno grafico. Le
complessità dichiarate separano tali costi; le prove strutturali impediscono
ricerche ripetute nei casi ottimizzati. Otto controlli negativi rilevano
il comportamento precedente o un algoritmo di visita disattivato, con
fallimenti specifici dei test.

Il contratto di autoverifica controlla entrambi i riferimenti fra requisito
e procedura. La prova aggiuntiva rileva l'assenza di `GDEV-Q07` nell'elenco
dei requisiti verificati, anche quando il requisito richiama già la
procedura corretta.

I rapporti della campagna appartengono a
`.gdev/assurance/reports/search-fluidity/`. Misure, prove di regressione,
controlli statici, compilazione e avvio hanno ambiti diversi e rimangono
identificati separatamente. Il confronto visivo manuale resta impedito
dal blocco della sessione Mac osservato durante questa campagna.
