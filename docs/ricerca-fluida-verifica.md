# Ricerca fluida e navigazione coerente

Campagna del 19 novembre 2026, collegata a
[search-fluidity.eld](../.gdev-assurance/work/search-fluidity.eld) e al
requisito `GDEV-P07`, versione 3.

## Comportamento

Da **Cerca › Cerca nei file…** (`⇧⌘F`) si raggiunge la vista Cerca.
Prima, selezionare una riga ricostruiva tutti i risultati. Ora cambiano
solo il selettore e il riepilogo; il testo delle altre righe resta al suo
posto. Il ridisegno completo rimane necessario dopo un cambio di geometria
o quando i componenti precedenti non sono più disponibili.

Le frecce `↑` e `↓` percorrono direttamente i risultati, come `p` e `n`.
`Invio` apre il risultato indicato; `Spazio` lo seleziona per la sostituzione.
`Tab` e `Shift-Tab` continuano a percorrere i pulsanti. Il suggerimento del
selettore ricorda il tasto Spazio.

Un confronto isolato usa gli stessi tre risultati e lo stesso punto iniziale:
la navigazione per righe porta alla seconda riga dell'intestazione; quella
per risultati raggiunge subito la prima corrispondenza. Ai limiti e con un
elenco vuoto le frecce conservano la posizione.

Il ripristino conserva anche l'identità del pulsante dentro la riga.
Un caso riprodotto con riempimento diverso fra i simboli spostava il fuoco
da selezione ad apertura. Ora l'offset appartiene al pulsante scelto, così
il cambio di simbolo non cambia il significato dell'azione successiva.

## Misure nell'app nativa

Emacs 31.1, codice nativo caricato tramite avvio ordinario, stessa finestra
di 239 colonne, stessi percorsi e testi. Mediana di sette selezioni per
dimensione, dopo un disegno iniziale. La misura comprende aggiornamento
del buffer e `redisplay`; esclude avvio dell'app e immissione fisica.

| Risultati | Prima | Dopo | Righe dei risultati ricostruite per selezione |
| ---: | ---: | ---: | ---: |
| 100 | 23,18 ms | 19,06 ms | 100 → 0 |
| 1.000 | 48,10 ms | 19,61 ms | 1.000 → 0 |
| 2.000 | 75,05 ms | 20,41 ms | 2.000 → 0 |

Il vantaggio riguarda la selezione di una singola riga. Una ricerca nuova,
un cambio di dimensione e la selezione di tutte le righe mantengono il
normale ridisegno. Non si conservano copie dei conteggi o esiti di verifica:
il riepilogo deriva dai risultati correnti.

## Verifiche e limiti

Le 28 prove mirate coprono ricerca, sostituzione, aggiornamenti, annullamento,
geometria, risultati superati, navigazione e le cinque nuove regressioni.
La suite completa seleziona 974 casi: 972 superati e due saltati su Emacs
30.1; 973 superati e uno saltato su 31.1, senza errori inattesi. La
compilazione con avvisi visibili produce 716 file bytecode per versione e
178 file nativi su 31.1, senza errori o avvisi del compilatore.
Con 2.000 risultati la vista aggiornata coincide con il ridisegno completo.
Due finestre mantengono ciascuna il proprio risultato e lo scorrimento;
una nuova selezione invalida l'anteprima delle sostituzioni.

Tre controlli negativi distinguono i difetti: ridisegno completo durante la
selezione, frecce che percorrono le intestazioni e scambio dei pulsanti con
riempimenti diversi. Le prove falliscono sul comportamento errato per
questi motivi, senza contare errori di sintassi o di avvio come evidenza.

La prova geometrica usa l'entrata normale del riquadro Cerca, tema chiaro e
scuro, due larghezze e due dimensioni del testo. Nella finestra stretta la
riga più larga occupa 294 dei 304 pixel disponibili, oppure 288 col testo
ingrandito. Dopo due selezioni il fuoco resta sul pulsante di apertura.

I rapporti locali sono in `.gdev/assurance/reports/search-fluidity/`.
La sessione Mac risulta ancora bloccata al controllo grafico: misure e
attivazioni programmatiche nell'app restano distinte dalla prova fisica con
il puntatore e dal confronto visivo finale. Queste ultime verifiche non
sono dichiarate superate.

Il comportamento segue le indicazioni di Apple su
[liste e tabelle](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
e [campi di ricerca](https://developer.apple.com/design/human-interface-guidelines/search-fields):
riscontri leggibili, navigazione coerente e accesso ai filtri.
