<!-- Generato da GDev; non modificare. Fonti sha256:b32a2e5363ccc8c92f1bb6af7b0362623b785f8d9870f79f8a0210616ba49ad5 -->

# Registro delle modifiche

## Fonte: docs/assicurazione/roadmap.md

# Tabella di marcia dell'assicurazione ingegneristica

Stato: **Fasi A e B completate** (milestone M1, M2 e M3). **Fase C in corso**:
M4–M10 implementate; restano decisioni sui profili provvisori e l'estensione
degli indici di riferimento. **Codice delle Fasi D ed E disponibile**, con attivazione remota e
auto-applicazione tecnica disponibile e chiusure umane da completare. Il [rapporto della Fase A](../rapporto-fase-a.md)
separa i fatti verificati nel repository dalle proposte; questa pagina ordina
le proposte nel tempo. Il [registro degli standard](../standard/README.md)
raccoglie edizioni, licenze e formati dei riferimenti normativi.

## Principi che valgono in ogni fase

- Il nucleo del processo (Process Kernel) è Emacs Lisp puro, carica da solo e
  non dipende da alcun modello linguistico. Gli agenti lo usano come qualunque
  altro client e non possono approvarsi, cambiare standard, profili o linee
  di base, disattivare un controllo (gate) né cancellare la traccia di audit.
- Ogni fase si chiude con prove eseguibili e con il confronto fra flusso
  iniziale e risultato, come chiede [AGENTS.md](../../../AGENTS.md).
- Nessuna fase riproduce testo normativo protetto e nessuna rivendica
  certificazioni o valutazioni ufficiali.
- Ogni fase conserva compatibilità con Emacs 30.1 e i percorsi di avvio e di
  terminale esistenti.

## Fasi

### Fase A — Analisi e riferimenti *(completata)*

- **Uscite**: rapporto tecnico, questa tabella di marcia, registro degli
  standard con edizione, stato e licenza verificati, file aperti scaricati e
  convertiti in `.eld` con impronte.
- **Dipendenze**: nessuna.
- **Esce quando**: l'utente approva il rapporto, il perimetro della prima
  milestone e il trattamento delle licenze.
- **Vincolo**: nessun modulo, nessuna dipendenza, nessun commit di codice.

### Fase B — Nucleo del processo *(completata: M1, M2 e M3)*

- **M1 completata il 2026-11-18**: archivio con migrazioni, transazioni con la
  macchina a stati, catena di audit, prove e sottocomandi `gdev assurance` di
  sola lettura. Vedi la [guida](../README.md).
- **M2 completata il 2026-11-18**: motore delle regole (`gdev-policy`) separato,
  primo controllo di passaggio fondato sulle prove (`gdev-gates`), traccia dei
  rifiuti nella catena (migrazione 2) e origine del canale legata al tipo
  d'attore, con le azioni degli agenti che girano come `agent`.
- **M3 completata il 2026-11-18**: strumento MCP `gdev_assurance` di sola lettura
  (`status`, `list`, `show`, `verify`, con elenchi tagliati alle ultime 200 righe)
  e transazione attiva dello spazio di lavoro, nel campo transitorio
  `gdev-assurance-transaction` di `gdev-workspace-state`.
- **Non resta nel processo**: un'identità dell'attore che un agente con `eval`
  non possa aggirare. Il server MCP offre `eval`, quindi quel confine non esiste
  in questo processo e va costruito fuori, in CI e con un'àncora della catena
  (Fasi D e E). La Fase B non offriva scritture MCP; il canale di proposta e
  conferma della Fase E è descritto più avanti.

- **Uscite**: archivio SQLite con migrazioni e controllo di integrità;
  transazioni ingegneristiche con la macchina a stati completa; registro di
  audit in sola aggiunta con catena di impronte (hash); archivio delle prove
  con la distinzione fra fatto, deduzione e ipotesi; motore delle regole
  deterministico che nega per impostazione predefinita; sottocomandi
  `gdev assurance` e strumenti MCP **di sola lettura**.
- **Dipendenze**: Fase A approvata; `gdev-workspace-state` per l'identità della
  transazione attiva; SQLite integrato in Emacs (verificato: disponibile in
  Emacs 31.1 locale con FTS5 e JSON; da sondare a runtime sulle versioni
  minime e sulla CI).
- **Esce quando**: ogni coppia di stati ha un esito prescritto (ammessa o
  rifiutata) e la copertura delle righe di macchina a stati e regole è piena;
  le migrazioni salgono da ogni versione e falliscono in modo chiaro su un
  archivio danneggiato; la suite ERT esistente resta verde.

### Fase C — Standard, profili e valutazioni *(M4–M10 implementate)*

- **M10 implementata il 2026-11-19**: il Workbench offre transazioni,
  controlli, standard, tracce, proposte, documenti, capacità, audit e impatto.
  Menu, pulsanti e tasti riusano le scritture della CLI e un'istantanea
  coerente per la lettura. L'identità attiva appartiene allo spazio e compare
  nella barra di stato e nei dati per agenti. Adozione e installazione dei
  ganci lavorano in secondo piano, legate allo spazio di origine. Le
  lavorazioni verificano controlli e standard già dovuti. Vedi la
  [guida operativa](../workbench.md).

- **M9 implementata il 2026-11-19**: scelta umana degli standard prima
  dell'autorizzazione, prove specifiche per obiettivo, decisioni motivate,
  valutazione e controlli sui passaggi. La migrazione 6 conserva la catena
  precedente e lega il contesto degli artefatti alle valutazioni registrate.
  Il catalogo comprende 21 voci selezionabili e 448 obiettivi originali GDev:
  433 riferimenti indicizzati e 15 obiettivi documentali. Gli indici ECSS
  sono parziali; per ISO/IEEE senza indice non si inventano clausole.
  La firma confronta gli artefatti con l'albero Git immutabile da firmare.
  CLI e MCP condividono le letture; la proposta `standard-proof` conserva
  l'identità di agente. Vedi il [percorso operativo](../standard/attuazione.md).

- **M8 implementata il 2026-11-18**: `capability` aggrega osservazioni riproducibili
  per controllo senza attribuire livelli normativi. Il catalogo delle letture
  è unico per CLI, agente e MCP; ogni richiesta usa un'istantanea SQL.
  Le fonti SLSA 1.2 Build e Source sono fissate a una revisione, con avvisi,
  licenza, impronte e indice editoriale `.eld`.
- **Riesame tecnico M7**: nuove prove distinguono l'ultimo ciclo di verifica
  da quelli superati; una prova precedente non soddisfa il ciclo nuovo.
  I cinque controlli avanzati restano dichiarati provvisori: la verifica
  tecnica non sostituisce una decisione sul processo dell'organizzazione.

- **M7 completata il 2026-11-18**: cinque controlli proposti per `high-assurance` e
  `critical` (indipendenza della verifica, revisione di una persona, valutazione
  registrata prima della linea di base, autorizzazione e approvazione di persone
  diverse, nessuna deroga) e quattro nuove forme di requisito per scriverli.
  Restano provvisori, da rivedere.

- **M6 completata il 2026-11-18**: valutazioni registrate nell'archivio e nella catena
  (`gdev-assessment-store`, migrazione 4), con il confronto fra la valutazione
  corrente e l'ultima registrata.

- **M5 completata il 2026-11-18**: decisioni di una persona su un controllo, deroga
  e non applicabilità (`gdev-decisions`, migrazione 3). Producono gli esiti
  `WAIVED_WITH_AUTHORIZATION` e `NOT_APPLICABLE` nella valutazione.

- **M4 completata il 2026-11-18**: caricatore del registro e delle clausole
  (`gdev-standards`), sette controlli operativi e cinque profili
  (`gdev-controls`), valutazione di conformità di una transazione
  (`gdev-assessment`) con `gdev assurance assess` e `assess` nello strumento MCP.
  Riferimenti solo a clausole verificabili nei dati locali (SSDF 1.1).
- **Restano nella Fase C**: la revisione dei controlli proposti per
  `high-assurance` e `critical` come politica dell'organizzazione, gli indici
  completi dei testi protetti e il chiarimento dell'edizione NASA-HDBK-2203.
  I controlli operativi non certificano conformità normativa, capacità ISO
  o livelli SLSA. Il riuso resta limitato a metadati, riferimenti e criteri
  originali GDev; nessun testo protetto viene acquisito implicitamente.

- **Uscite**: materializzazione degli standard nel formato del registro
  (riferimenti di clausola, applicabilità, controlli operativi scritti da
  noi, prove richieste, metodi di verifica, regole di approvazione); profili
  GES Core, Quality, Secure, High Assurance e Critical come composizione di
  controlli; valutazione di conformità (soddisfatto, non soddisfatto, non
  verificato, non applicabile, derogato con autorizzazione) e valutazione
  della capacità di processo come riferimento metodologico.
- **Dipendenze**: Fase B; autorizzazioni di licenza per i testi aperti da
  scaricare (vedi registro); revisione legale per la classe «solo
  riferimento».
- **Esce quando**: un profilo si seleziona, si compone e produce una
  valutazione riproducibile dagli stessi dati; la valutazione non può
  dichiarare nulla senza prove registrate.

### Fase D — Applicazione, documentazione e adozione

- **Implementato**: migrazione 5 in sola aggiunta, registrazioni legate alla
  catena, artefatti con impronte, relazioni e impatto transitivo anche con cicli;
  adozione con inventario iniziale e prove ricostruite; sedici tipi editoriali
  da manifesto `.eld` e fonti Org/Markdown; confronto dei documenti in CI.
- **Git disponibile e opt-in**: ricevute SSH legate a repository, indice,
  genitori, transazione e testa della catena; `commit-msg`, `pre-push`, firma
  ordinaria e amend, installazione esplicita senza sovrascrivere altri ganci.
  Il verificatore esterno legge solo gli oggetti Git. Le prove comprendono
  commit e push reali verso un repository effimero e tentativi di saltare i ganci.
- **Per chiudere la fase**: configurare firmatari esterni, variabili del workflow
  e controllo obbligatorio sul ramo. Il workflow verifica il codice proposto
  usando il verificatore della base fidata. Senza la configurazione remota
  il repository non può imporre un divieto di push.

- **Uscite**: ganci Git versionati (`.githooks/`, installazione esplicita) e
  controllo in CI; tracciabilità e analisi d'impatto; generazione dei sedici
  tipi di documento vivo da sorgenti Org e Markdown; procedura di adozione di
  progetti preesistenti con prove marcate come ricostruite, mai come
  retroattive.
- **Dipendenze**: Fase C; `.lavorazione` per le azioni dichiarative;
  configurazione lato server (protezione dei rami) che il repository non può
  imporre da solo.
- **Esce quando**: un commit senza transazione autorizzata è rifiutato in
  locale e in CI, e un progetto preesistente produce una linea di base
  verificabile senza falsificare la storia.

### Fase E — Agenti e auto-applicazione

- **Implementato**: `gdev_assurance_request` accoda proposte; una persona ne
  legge dati e digest e conferma dalla CLI o dal Workbench. Conferme monouso, scadenza a ogni
  altro evento e identità `agent` conservata nell'azione. Nessuna approvazione,
  deroga, adozione o recupero è offerta da MCP o dalle lavorazioni.
- **Recupero e prove negative**: conservazione dell'archivio originale con
  impronte e motivo nel nuovo; ripristino della cartella se il nuovo archivio
  non si apre. Prove su auto-approvazione, digest diverso, file cambiato,
  doppio uso, conferma scaduta, alterazione della ricevuta e `--no-verify`.
- **Auto-applicazione tecnica disponibile**: questo checkout contiene
  quindici requisiti, scheda operativa, sette procedure, nove modelli,
  sedici documenti generati e verifiche CI. L'archivio locale registra anche
  una lavorazione reale con attore agente; i cicli con approvazioni simulate
  restano nelle fixture isolate. La chiusura formale dipende dalla
  configurazione esterna della Fase D e dalle decisioni umane.

- **Uscite**: strumenti MCP di scrittura subordinati al nucleo, con
  conferma esplicita; applicazione del processo a GDev stesso con un
  percorso di recupero controllato e registrato; prove negative
  intenzionali (un agente tenta di approvarsi, di alterare un'impronta, di
  saltare un controllo).
- **Dipendenze**: Fase D.
- **Esce quando**: ogni tentativo vietato fallisce lasciando traccia, e il
  recupero da un archivio o da una linea di base danneggiati è documentato e
  provato.

## Ordine e dipendenze

```
A ──► B ──► C ──► D ──► E
      │     └────────► (profili alimentano i controlli di D)
      └─ sola lettura MCP già in B, scrittura solo in E
```

Le fasi si eseguono in sequenza. Dentro una fase, le parti che non
condividono file possono procedere in parallelo, per esempio nella Fase C la
materializzazione degli standard aperti e la valutazione di capacità.

## Prima milestone implementabile (M1, dentro la Fase B)

Realizzata; il dettaglio è nella sezione 17 del rapporto. In sintesi: archivio con
migrazioni, transazione minima (`PROPOSED → CLASSIFIED → … → BASELINED` con
transizioni rifiutate per le coppie non ammesse), registro di audit
concatenato e lettura da CLI, senza ancora ganci Git né scrittura da agente.

## Rischi che incidono sull'ordine

- **Verifica dei riferimenti prima di usarli**: ISO/IEC/IEEE 12207 ha una
  nuova edizione 2026; nessun controllo si registra su un'edizione ritirata.
- **Licenze**: testi ISO/IEC/IEEE ed ECSS restano fuori dal repository;
  l'attuazione usa la classe «solo riferimento», indici pubblici verificati
  e controlli originali GDev.
- **Radice di fiducia locale**: chi controlla la macchina può alterare
  l'archivio. L'audit è a prova di manomissione solo se ancorato fuori dalla
  macchina (CI o rilascio firmato); altrimenti si dichiara solo come
  «rilevabile».

## Sviluppo governato e autoverifica — 2026-11-19

Implementati manifesto del progetto e scheda operativa, compilazione guidata,
tassonomie con provenienza e copertura, nove modelli, sei procedure iniziali
e GDEV-VERIFY, simulazione, giornale append-only e ripresa controllata. La
migrazione 7 aggiunge istantanee ed esecuzioni senza cambiare le migrazioni
precedenti. Valutazioni e chiusure verificano il contesto dei sorgenti e gli
artefatti. Workbench, CLI e MCP riusano le entrate comuni.

Il modello finito e la campagna di guasti, crash, sequenze e mutazioni sono
controlli riproducibili in CI. Le tassonomie ASVS e SSDF sono confrontate con
CSV e XLSX originali; il PDF NIST IR è indicizzato, con obblighi atomici da
completare. Restano l’integrazione delle fonti normative non disponibili, le
valutazioni umane e l’attivazione dei controlli remoti già descritti. Vedi la
[guida operativa](../progetto-formale.md) per perimetro e limiti effettivi.
