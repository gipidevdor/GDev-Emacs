<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Operazioni di progetto

Usa questa verifica per compilazione, preparazione automatica, avvio dopo
compilazione o nuove azioni di un adattatore DAP nel riquadro Debug.

## Contesto e preparazione automatica

Parti da una cartella senza Git, da una sottocartella e da un README.
Usa la radice di `gdev-project-operation-context-root`, il registro
`gdev-project-operation-contracts` e il modello di
[operazioni di progetto](../../../../../docs/operazioni-progetto.md).
Ogni fornitore nuovo deve entrare nel controllo tematico e avere una
prova di esecuzione con prodotti osservabili. Il riconoscimento del file
e la costruzione di una stringa di comando non attestano una compilazione.

Prova dichiarazione `.gdev-project.eld`, preferenza personale, scelta
ambigua, annullamento e rimozione dell'unico manifesto. Quest'ultima può
cambiare la radice: invalida anche l'osservazione della radice precedente.
Per Make delega al motore regole e obiettivo predefinito; interroga il
catalogo solo su richiesta, con limiti e senza compilazioni concorrenti.
`make -qp` può valutare espressioni e ricette ricorsive.

In Perl verifica MakeMaker o Module::Build prima dei test; in Python
distingui distribuzioni e bytecode. Usa il frontend reale per costruire
wheel e sdist, con gli strumenti isolati di `test/requirements-project-build.txt`.
La versione Python di sistema può riusare il bytecode dalla sola data al
secondo: il test deve cambiare il sorgente subito e rilevarne gli errori.
Per la CLI di test controlla anche che gli hook di chiusura finiscano prima
della rimozione dello stato temporaneo.

## Catene asincrone e contesto di esecuzione

1. Avvia attraverso i tasti e il riquadro con lo stesso profilo. Usa un
   percorso e un argomento con spazi, un argomento vuoto e una variabile
   di ambiente con un valore composto.
2. Nella sentinella verifica lo stato del processo e il codice di uscita.
   Prova uscita zero, uscita non zero e interruzione con i messaggi
   localizzati di GDev. Solo l'uscita zero può avviare la fase successiva.
3. Cambia spazio durante la compilazione e torna dopo la fine. Verifica
   che l'avvio riprenda nello spazio di origine. Se fallisce una fase,
   recupera l'output dal suo pannello prima di ripeterla. Prova F5 dal
   pannello di un altro progetto e duplica uno spazio con Debug aperto.
   Verifica separatamente il profilo copiato e la sessione dello spazio.
4. Per le eccezioni usa un adattatore che pubblica i filtri tramite DAP.
   Prova una richiesta accettata e una rifiutata. La scelta visualizzata
   deve corrispondere alla risposta dell'adattatore e valere per la sola
   sessione scelta. Invia anche un cambio di capacità a programma in
   pausa e controlla le azioni e la selezione del riquadro.
5. Per il costo a riposo, controlla funzioni caricate e timer dopo il
   primo intervallo di inattività. Apri Sessione, Profila e Sistema con
   e senza PID, poi cambia vista o fuoco. I timer di campionamento
   devono seguire il processo effettivamente osservato.

Per un'operazione in secondo piano che pubblica una scelta nello spazio,
prova anche un cambio di cartelle senza cambiare scheda. Conserva nel
contesto iniziale l'identità dello spazio e le cartelle lette attraverso
`gdev-workspace-state`; al completamento confrontale con quelle dello
spazio d'origine, anche se è inattivo o spostato in un'altra finestra.
Un risultato del vecchio progetto non deve sostituire la scelta nuova.
Se il processo non parte, chiudi lo stato «in corso», conserva l'errore e
permetti di ripetere il comando. Verifica separatamente il lavoro riuscito
nel progetto d'origine e la mancata attivazione nel contesto cambiato.

Il registro può sostituire l'oggetto restituito all'avvio: leggi l'esito
corrente attraverso il proprietario prima di applicare il risultato.
Prova un successo tardivo dopo l'interruzione e due notifiche finali dello
stesso processo. La vista deve mostrare un esito coerente con il registro,
pubblicarlo una volta e conservare la selezione e il fuoco correnti.
Nelle prove attendi la pubblicazione dell'esito: l'uscita del processo può
precedere l'esecuzione della sentinella.
