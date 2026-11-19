# Tabella di marcia di GDev-Emacs

Le priorità seguono la numerazione della proposta. I [flussi di lavoro](workflows.md)
descrivono le funzioni disponibili oggi. Questa pagina raccoglie le evoluzioni
del banco di lavoro.

## 2. Debug visuale e uniforme

- Disponibile l'elenco dei punti di interruzione, con accesso al sorgente,
  indicatori nel margine, condizioni, conteggi e punti di registrazione.
- Disponibile la vista di ispezione con variabili, espressioni osservate,
  thread e pila navigabile.
- Disponibili il riavvio della sessione e la corrispondenza fra cartelle
  sorgenti per gli adattatori remoti e nei contenitori.
- Da integrare il ricaricamento a caldo specifico del linguaggio e
  dell'adattatore.

## 3. Ristrutturazione e navigazione del codice

- Disponibile l'anteprima delle modifiche testuali per rinomina ed
  estrazione, con conferma e annullamento di gruppo. Le azioni che il
  server espone come comandi opachi passano da una conferma esplicita.
- Disponibile la vista dei risultati per **Tutti i riferimenti**,
  **Vai all'implementazione** e **Vai alla definizione del tipo**.
- Disponibile la struttura del documento sincronizzata con l'editor.
  Le gerarchie delle chiamate e dei tipi aprono i rami su richiesta
  quando il server dichiara il supporto.

## 4. Esecuzione dei test e copertura

- Disponibili **Esegui test al cursore** e **Riesegui i test falliti**
  dalla vista Test e dal sorgente. CTest usa la registrazione CMake,
  pytest seleziona funzione e parametri, Deno e Node operano per file.
- Disponibili filtri per gruppo ed esito, esecuzione della selezione,
  avanzamento per CTest e pytest e parallelismo configurabile.
- Disponibili rapporto navigabile e indicatori nel margine destro.
  La misura con Coverage.py e LLVM e l'importazione LCOV alimentano
  la stessa vista.

## 8. Interfaccia e flussi quotidiani

- Disponibile il trascinamento tra gruppi, con indicazione della
  destinazione e ripristino della disposizione.
- La minimappa mostra le corrispondenze di Cerca e la diagnostica già
  disponibile per il documento.
- Il percorso in alto riunisce cartelle, file e simboli e usa l'indice di
  Struttura quando è disponibile.
- **Operazioni dello spazio** riunisce avanzamento, esiti e interruzione
  dei processi. Le scelte di aspetto si aprono anche dal cruscotto.

## 9. Strumenti complementari

### Database SQL

La prima integrazione unifica PostgreSQL e SQLite nella vista
[Database SQL](workflows.md#database-sql). I due motori verificano lo stesso
flusso su un server e su un database locale. Questi sono i requisiti da
conservare quando si aggiungono altri adattatori.

- Condividere gestione delle connessioni, navigazione di schemi, tabelle e
  viste, anteprima in sola lettura e risultati tabellari. Eseguire la
  selezione o l'intero script, con arresto al primo errore. Ogni adattatore
  gestisce dialetto, credenziali e operazioni del motore.
- Scegliere il dialetto dei file `.sql` dalla connessione attiva e mantenere
  l'associazione PostgreSQL per `.pgsql` e `.psql`. Conservare il legame
  tra documento, spazio di lavoro e connessione.
- Conservare servizi e credenziali libpq, la compatibilità con il modulo
  `:lang postgresql` e le scorciatoie esistenti. La consultazione in
  sottofondo resta separata dalla console e usa la sola lettura.

### Web, dipendenze, confronto e prestazioni

- Disponibili il navigatore e l'[anteprima web affiancata](workflows.md#navigatore-e-anteprima-web).
  L'anteprima segue le modifiche del documento HTML e, per un servizio su
  `localhost`, i salvataggi dei file del progetto.
- Disponibile la vista [Dipendenze del progetto](workflows.md#dipendenze-del-progetto)
  per `package.json`, `Cargo.toml` e `pyproject.toml`, con modifica della
  dichiarazione nel buffer del manifesto. Da valutare l'indicazione delle
  versioni più recenti, che richiede l'accesso ai registri dei pacchetti.
- Disponibile l'[unione a tre vie](workflows.md#unione-a-tre-vie) in
  un'anteprima indipendente, con navigazione dei conflitti, scelte per
  conflitto e consegna verificata. Hit apre la stessa anteprima.
- Misurata la tavolozza dei file su un progetto Git di 30.000 file. Alla
  riapertura la prima proposta passa da circa 816 ms a 3 ms, perché GDev
  conserva gli indici recenti entro 6 MiB. La verifica in secondo piano
  resta intorno agli 800 ms, e restituisce solo l'impronta se l'indice è
  invariato. Restano da misurare memoria e indicizzazione dei server LSP
  sugli stessi progetti.
