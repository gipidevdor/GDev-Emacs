# Algoritmi, visualizzazione e complessità

Il requisito `GDEV-Q07` lega le scelte algoritmiche a sorgenti, prove e
limiti verificabili. La ricognizione attraversa nucleo, moduli e fork;
le modifiche mantengono le entrate pubbliche e i formati dei risultati.
L'inventario statico e le prove dei percorsi sono evidenze distinte.

## Visualizzazione dell'informazione

La vista d'insieme precede l'accesso al dettaglio: minimappa ed editor
rimangono coordinati; il riquadro Cerca raggruppa le occorrenze per file,
offre filtri e apre il dettaglio nella posizione esatta. La selezione e il
fuoco conservano l'identità durante gli aggiornamenti. È l'applicazione
al dominio dell'editor dei compiti descritti da
[Shneiderman, *The Eyes Have It* (1996)](https://www.cs.umd.edu/~ben/publications.html).

La minimappa aggrega i marcatori alla risoluzione delle righe visibili.
Per ogni intervallo conserva il numero totale, il livello più grave e la
prima posizione di quel livello. Un errore raro non scompare nella media
di molti risultati di ricerca. La scelta è indipendente dall'ordine dei
marcatori e il clic mantiene la destinazione effettiva.

La scansione riconosce posizioni crescenti e decrescenti. Due cursori
attraversano una sola volta marcatori e righe; una sequenza disordinata usa
la ricerca binaria esistente. Non si ordina una copia dei dati per ottenere
il caso lineare. Le corsie di ricerca e diagnostica restano separate.

## Contratti di complessità

Le stime separano lavoro dell'algoritmo, dimensione del testo prodotto,
accessi al filesystem e disegno di Emacs. Per le tabelle hash il costo
dichiarato è atteso; l'elaborazione delle stringhe comprende i loro caratteri.

| Operazione | Tempo | Memoria aggiuntiva | Condizioni |
| --- | --- | --- | --- |
| Aggregazione minimappa ordinata | O(M + R) | O(R) | M marcatori monotoni, R righe visibili. Ogni cursore avanza in un solo verso. |
| Aggregazione minimappa disordinata | O(M log R + R) | O(R) | Ricerca del predecessore nei campioni, senza riordinare l'input. |
| Raggiungibilità e rilevamento dei cicli | O(V + E) atteso | O(V) | Liste di adiacenza, visita iterativa e nodi registrati prima dell'inserimento nella pila. |
| Semi dell'analisi d'impatto | O(A + C) atteso | O(C + A) | A versioni di artefatti, C percorsi; eliminata l'associazione O(A × C). |
| Riferimenti di requisiti e tassonomie | O(V + E) atteso | O(V + E) | Indici costruiti una volta; non si cercano i genitori nella lista per ogni discendente. |
| Raccolta di input e uscite | O(K) prima della deduplicazione e dell'ordinamento | O(K) | K riferimenti; concatenazione in un passaggio, senza ricopiare ogni prefisso. |
| Filtro dell'inventario | O(K + F × P) atteso | O(K) | K uscite indicizzate una volta, F percorsi, P costo di verifica delle radici e del percorso. |
| Normalizzazione Imenu di Consult GDev | O(T + L) | O(H + L) | T voci visitate, H altezza, L testo materializzato; prefissi condivisi e costruiti su richiesta. |
| Selezione di un risultato di Cerca | O(N × (W + 1)) nella logica attuale | O(W) oltre i dati | N risultati per conteggio e ritrovamento delle ancore; W finestre. Si ridisegnano solo controllo e riepilogo. |

La selezione di Cerca non è dichiarata costante: scansioni e aggiornamenti
del buffer rimangono costi reali. La [misura nell'app](ricerca-fluida-verifica.md)
include il ridisegno. Separare questo costo impedisce di attribuire al
solo algoritmo le prestazioni dell'interfaccia.

L'inventario richiede inoltre lettura e impronta dei byte delle sorgenti e
ordinamento dei percorsi. Questi costi non vengono rimossi usando esiti di
verifica precedenti. Il controllo dell'albero Git usa lo stesso predicato
dell'inventario, costruito per la singola istantanea.

## Responsabilità e razionalizzazione

`gdev-graph` possiede soltanto raggiungibilità e rilevamento dei cicli.
Non carica editor, SQL o filesystem. `gdev-taxonomy`, `gdev-project` e
`gdev-trace` conservano validazione del dominio, messaggi, ordinamento e
provenienza. La versione del motore comune entra nelle impronte del contesto.

La raccolta delle sorgenti non modifica le liste del manifesto. Gli indici
delle uscite appartengono alla lettura corrente e non diventano stato
persistente. La stessa politica decide quali file confrontare nel lavoro
corrente e nell'albero immutabile Git.

Consult GDev conserva versione, origine, revisione e licenza di Consult nel
[catalogo](../vendor/pacchetti.el). La visita Imenu mantiene ordine,
proprietà del testo, tipi, marcatori e destinazioni speciali. Il limite
rimosso riguarda la normalizzazione del catalogo; i fornitori di Imenu
mantengono i propri costi e limiti.

## Prove

Le prove includono 20.000 livelli di grafo, una chiusura transitiva
matriciale indipendente su 32 grafi, cicli, archi ripetuti, diamanti e
componenti isolate. Progetti e tassonomie verificano catene di 2.000 nodi;
Consult GDev normalizza 3.000 gruppi con profondità di valutazione limitata.

Per la minimappa si confrontano permutazioni degli stessi dati e si vieta
la ricerca binaria per ogni marcatore nel caso monotono. L'analisi d'impatto
vieta la ricerca lineare nella lista dei percorsi cambiati. L'inventario
verifica che le uscite vengano indicizzate una sola volta.

I rapporti e i confronti prima/dopo sono conservati in
`.gdev/assurance/reports/search-fluidity/`. Non si attribuisce copertura
globale, ottimalità di ogni operazione o validazione manuale a controlli
che misurano soltanto una di queste proprietà.
