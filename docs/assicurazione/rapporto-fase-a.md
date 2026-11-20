# Rapporto tecnico della Fase A

Analisi di GDev-Emacs per il quadro di assicurazione ingegneristica guidato
dagli standard (Engineering Assurance Framework). La Fase A non ha introdotto
moduli, dipendenze né commit di codice; ha prodotto questo rapporto, la
[tabella di marcia](roadmap.md) e il [registro degli standard](standard/README.md).
Dopo l'approvazione è stata realizzata la prima milestone: vedi la sezione 17
e la [guida del nucleo](README.md).

**Legenda.** **[F]** fatto verificato nel repository o nell'ambiente locale.
**[W]** fatto verificato su fonti web il 2026-11-17. **[P]** proposta
architetturale, non ancora approvata. **[?]** punto non verificato.

## 1. Architettura attuale

- **[F]** Distribuzione di Emacs per macOS con interfaccia in italiano. Versione
  minima 30.1 (`init.el:28`); in locale Emacs 31.1.
- **[F]** Modello a moduli: `gdev!` in `init.el`, `modules/<categoria>/<nome>/config.el`.
  Cartelle per categoria: app 1, checkers 2, completion 2, config 1, editor 6,
  emacs 4, lang 22, os 1, term 2, tools 17, ui 12.
- **[F]** Nucleo in `lisp/`, circa 9 800 righe. I file maggiori sono
  `gdev-commands.el` (1 647), `gdev-mcp.el` (934), `gdev-cli.el` (774) e
  `gdev-workspaces.el` (728).
- **[F]** Registri dichiarativi: `gdev-set-handler`, `gdev-bind`,
  `gdev-set-eglot-server`, `gdev-lavorazione-registra`.
- **[F]** `gdev-workspace-state` registra ogni campo condiviso con il suo ciclo di
  vita (`clone`, `persist`, `transient`, `until-close`); AGENTS.md impone che lo
  stato condiviso dello spazio passi da lì.
- **[F]** Modello di fiducia: `gdev-trusted-projects` e `gdev-project-trusted-p`
  (`lisp/gdev-lib.el:234`).
- **[F]** 98 versioni di pacchetti in `vendor/elpa`, registrate in
  `vendor/pacchetti.el` con licenza e revisione; licenze in `vendor/licenze`.
- **[F]** 81 file di test e 673 test ERT, più i controlli di copertura in
  `test/gdev-coverage.el`.

## 2. Funzionalità MCP esistenti

- **[F]** Server MCP in Emacs Lisp su socket Unix privata, con ponte stdio
  `bin/gdev-mcp` e controllo di flusso. Elenco degli strumenti in
  `gdev-mcp-all-tools` (`lisp/gdev-mcp.el:217`).
- **[F]** Catalogo delle azioni dal vivo in `lisp/gdev-agent-interface.el:163-215`.
  `gdev agent use|develop|live` restituisce JSON con `schema_version` 1.
- **[F]** Cursori e scorciatoie degli agenti (`lisp/gdev-agent-cursors.el`) e
  controllo di editor, buffer e riquadri (`lisp/gdev-agent-control.el`).
- **[F]** Una ricerca per parole chiave (`confirm`, `read-only`, `trusted`) nei tre
  file dell'MCP trova solo il campo `read_only` che descrive il buffer
  (`gdev-agent-control.el:266`).
- **[?]** Non ho letto ogni percorso di scrittura: se esista una conferma o un
  limite per le azioni che modificano file va stabilito nella Fase B.

## 3. Integrazione con `.lavorazione`

- **[F]** Le lavorazioni sono piani JSON dichiarativi: né Lisp né shell. Le azioni
  le registrano i moduli con `gdev-lavorazione-registra`.
- **[F]** Azioni di base in `modules/ui/workbench/gdev-lavorazione.el:248-257`:
  `apri-file`, `vai-riga`, `inserisci`, `sostituisci`, `salva`. Altre vengono da
  `editor/format`, `editor/snippets`, `editor/fold`.
- **[F]** La composizione tramite MCP controlla la revisione del piano.
- **[P]** Il processo diventa una famiglia di azioni (`transazione-apri`,
  `prova-registra`, …) che passa dal nucleo: una lavorazione non può
  aggirare un gate perché l'azione chiama le stesse funzioni del nucleo.

## 4. Sistemi di persistenza presenti

- **[F]** Stato in file nella cartella `gdev-state-directory` (creata con modo 0700),
  scritti da `gdev-write-state-file` (`lisp/gdev-lib.el:60-73`): file temporaneo
  e rinomina, modo 0600.
- **[F]** `lisp/gdev-operation-history.el` conserva l'annullamento in memoria, in
  un anello, e non sopravvive al riavvio.
- **[F]** SQLite compare solo in `modules/lang/postgresql/gdev-database-sqlite.el`
  (client `sqlite3` esterno, per i database dell'utente) e nel database di Forge.
  Nessun archivio di processo, prove o audit.
- **[F]** Ambiente locale: `sqlite-available-p` vero in Emacs 31.1, SQLite 3.50.4
  integrato con FTS5 e JSON; client `sqlite3` di sistema 3.54.0.
- **[?]** Le build di Emacs 30.1 e quelle della CI su Linux possono non avere
  FTS5: serve un sondaggio a runtime con ripiego.

## 5. Capacità già riutilizzabili

- **[F]** Scrittura atomica privata (`gdev-write-state-file`).
- **[F]** `gdev-workspace-state` per l'identità della transazione attiva.
- **[F]** `gdev-audit.el`: inventario riproducibile delle entrate, senza invocarle.
  `gdev-doctor.el` per la diagnosi.
- **[F]** CLI con sottocomandi (`lisp/gdev-cli.el`) e contratto verificato da
  `test/gdev-cli-contract-test.py`.
- **[F]** Schema CI con controllo della mappa dei tasti (`./bin/gdev docs`):
  è il modello per verificare i documenti generati.
- **[F]** `gdev-ui-view-setup` e il [modello di vista](../../templates/vista.el)
  per le viste future.
- **[F]** `lisp/gdev-agent-interface.el` carica da solo, senza `gdev-lib`: è il
  precedente per un nucleo indipendente.

## 6. Lacune architetturali

- **[F]** Nessun gancio Git attivo (`.git/hooks` contiene solo esempi, `core.hooksPath`
  vuoto) né CODEOWNERS, SECURITY, CONTRIBUTING o modello di PR.
- **[F]** Gli ultimi cinque commit non sono firmati (`%G?` = `N`). Un solo ramo
  locale, `main`, e nessun tag.
- **[F]** Il repository ha un riferimento rotto: Git avvisa «ignoring ref with
  broken name refs/remotes/origin/main 2».
- **[F]** La CI è un solo workflow (`.github/workflows/ci.yml`): spazi, test,
  copertura, compilazione, mappa dei tasti, avvio, contratti CLI e MCP. Nessun
  controllo di processo.
- **[F]** Mancano archivio delle transazioni, prove, tracciabilità e audit
  persistente. Il registro degli standard è nato con questo lavoro.

## 7. Proposta del Process Kernel

- **[P]** Nucleo in `lisp/`, non nei moduli opzionali: un controllo che si può
  disattivare togliendo una voce da `gdev!` non è un controllo. Ogni file carica
  da solo (`emacs --batch -Q -l …`) e non richiede modelli linguistici né UI.
- **[P]** Moduli, con nomi adattati alle convenzioni (`gdev-` e `lisp/`):

  | File | Responsabilità |
  | --- | --- |
  | `gdev-standards.el` | registro, edizioni, applicabilità |
  | `gdev-process.el` | transazioni e macchina a stati |
  | `gdev-policy.el` | regole deterministiche, nega per impostazione predefinita |
  | `gdev-gates.el` | controlli di passaggio e deroghe |
  | `gdev-evidence.el` | prove, impronte, classi fatto/deduzione/ipotesi |
  | `gdev-trace.el` | tracciabilità e analisi d'impatto |
  | `gdev-assurance.el` | facciata, CLI e strumenti MCP |
  | `gdev-assurance-db.el` | SQLite, migrazioni, integrità |

- **[P]** Interfaccia grafica in un modulo `tools/assurance`, solo dopo la Fase D.
- **[P]** Fail-safe: assenza di dato, errore o tempo scaduto producono «negato».
- **[P]** Sorgenti di verità in testo (`.eld`, Org) sotto controllo di versione;
  SQLite come registro locale e indice, con esportazione dell'audit in JSONL
  concatenato da versionare come àncora.

## 8. Schema dati iniziale

- **[P]** Tabelle: `schema_migrations`, `standard`, `standard_edition`,
  `clause_ref`, `applicability`, `control`, `procedure`, `role`, `activity`,
  `artifact_req`, `evidence_req`, `verification_method`, `approval_rule`, `gate`,
  `profile`, `profile_control`, `tx`, `tx_event`, `evidence`,
  `trace_link`, `assessment`, `assessment_result`, `waiver`, `baseline`,
  `document`. Indice FTS5 `fts_document` solo se disponibile.
- **[F]** M1 realizza `schema_migrations`, `tx`, `tx_event` ed `evidence`. Lo
  schema vive nella migrazione 1 di `lisp/gdev-assurance-db.el`, che è l'unica
  fonte: questo rapporto non la ripete. Differenze dal progetto iniziale:
  - `transaction` è una parola riservata di SQLite e non si usa come nome di
    tabella: per questo `tx` e `tx_event`;
  - `tx_event` ha anche `kind` (`open`, `transition`, `evidence`), `ref` e
    `note`, perché ogni prova è anch'essa un evento della catena;
  - nessuna tabella `STRICT`, per non imporre SQLite 3.37 o successivo: i
    vincoli `check` fanno lo stesso lavoro sulle colonne che contano;
  - il database rifiuta `update` e `delete` su eventi e prove, `delete` su `tx`
    e la modifica dei suoi campi fissi con trigger, e la verifica controlla che
    i trigger ci siano ancora.
- **[P]** Chiavi esterne attive; `delete` e `update` su eventi e prove vietati con
  trigger. I trigger rendono l'alterazione **rilevabile e rifiutata dal
  database**, non impossibile per chi ha accesso al file: vedi sezione 16.

## 9. Modello delle Engineering Transactions

- **[P]** Percorso principale:
  `PROPOSED → CLASSIFIED → ANALYZED → AUTHORIZED → IMPLEMENTING → VERIFYING →
  REVIEWING → APPROVED → BASELINED`.
- **[F]** Ritorni: `VERIFYING → IMPLEMENTING` (verifica fallita),
  `REVIEWING → IMPLEMENTING` (rilavorazione).
- **[F]** Da ogni stato fra `PROPOSED` e `APPROVED`: `BLOCKED` (gate negato; si
  riprende solo dallo stato di partenza), `SUSPENDED` e `CANCELLED` (solo una
  persona); `REJECTED` da `PROPOSED` a `REVIEWING`, per mano di una persona.
  `BASELINED → SUPERSEDED` solo con `gdev-process-supersede`, da una persona e
  con una transazione successiva già in `BASELINED`. Stati finali: `REJECTED`,
  `CANCELLED`, `SUPERSEDED`.
- **[P]** Ogni coppia non elencata è rifiutata. Un test percorre **tutte** le
  coppie di stati.
- **[P]** Invarianti:
  - `AUTHORIZED`, `APPROVED`, `BASELINED` e le deroghe richiedono un attore umano;
    un agente non vi arriva mai, in nessun profilo.
  - Da profilo Secure in su, chi propone non approva.
  - Una prova usata da un gate è creata dopo l'ingresso nello stato che lo
    precede: nessuna prova retroattiva. L'adozione di progetti preesistenti usa
    solo l'origine `reconstructed`, che non soddisfa mai un controllo.
- **[P]** Ogni transizione è un evento concatenato (`prev_hash`) e, insieme al
  cambio di stato e alle sue prove, una sola transazione SQL.

## 10. Strategia di enforcement Git/CI

- **[P]** Commit con trailer `GDev-Transaction: GT-<n>`.
- **[P]** Ganci in `.githooks/` (`commit-msg`, `pre-push`), installati con un comando
  esplicito che imposta `core.hooksPath` del solo repository (cambia la
  configurazione: serve il consenso di chi la usa). Ogni gancio chiama il nucleo
  in `emacs --batch -Q`; il costo va misurato.
- **[P]** I ganci sono una comodità: `--no-verify` li aggira. L'applicazione vera è
  la CI: un job `assurance` verifica che ogni commit dell'intervallo abbia una
  transazione almeno `AUTHORIZED` **al momento del commit** e le prove richieste.
- **[P]** Fail-safe: se il nucleo non parte, il job fallisce.
- **[?]** Protezione dei rami e firma dei commit sono impostazioni del server
  Git: il repository non può imporle da solo.

## 11. Strategia di generazione documentale

- **[P]** I sedici tipi di documento si generano da sorgenti `.eld`, Org e
  Markdown con modelli deterministici in Emacs Lisp, senza modelli linguistici.
- **[P]** I file generati stanno in `docs/assicurazione/generati/`, con
  intestazione «generato, non modificare» e impronta del sorgente.
- **[P]** Un controllo in CI rigenera e confronta, come già fa la mappa dei tasti.
- **[P]** I titoli dei prodotti d'informazione seguono gli identificativi di
  ISO/IEC/IEEE 15289, senza riprenderne il testo.

## 12. Strategia di adozione legacy

- **[P]** (1) Inventario in sola lettura. (2) Un umano sceglie il profilo.
  (3) Versione di riferimento 0 dichiarata: commit e impronte attuali, prove con origine
  `reconstructed`. (4) Valutazione iniziale: tutto `NOT_VERIFIED`. (5) Le lacune
  diventano transazioni. (6) Un controllo passa a `SATISFIED` solo con una
  prova nuova e raccolta dopo l'adozione.
- **[P]** Per GDev stesso: stessa procedura, più un percorso di recupero
  registrato, da applicare se archivio o versione di riferimento risultano danneggiati.

## 13. Gestione delle licenze normative

- **[W]** Edizioni e licenze, verificate il 2026-11-17 (dettaglio in
  [registro.eld](standard/registro.eld)):

  | Riferimento | Edizione trovata | Riuso |
  | --- | --- | --- |
  | ISO/IEC/IEEE 12207 | **2026** (la 2017 è ritirata) | solo riferimento |
  | ISO/IEC/IEEE 15289 | 2019 | solo riferimento |
  | ISO/IEC/IEEE 29148 | 2018 | solo riferimento |
  | IEEE 1012 | 2024, da confermare | solo riferimento |
  | ISO/IEC 25010 | 2023 | solo riferimento |
  | ISO/IEC/IEEE 42010 | 2022 non trovata | solo riferimento |
  | ISO/IEC 33020 | 2019 (riesame in corso) | solo riferimento |
  | ECSS-E-ST-40C | Rev.1, 2025-04-30 | solo riferimento |
  | ECSS-Q-ST-80C | Rev.2, 2025-04-30 | solo riferimento |
  | ECSS-S-ST-00 | non trovata | solo riferimento |
  | NASA NPR 7150.2 | D, valida fino al 2027-03-08 | da verificare |
  | NASA-STD-8739.8 | B | da verificare |
  | NASA-HDBK-2203 | B (etichette divergenti) | da verificare |
  | NIST SP 800-218 | 1.1 finale; Rev.1 in bozza | aperto, senza copyright negli Stati Uniti |
  | NIST IR 8397 | 2021 | aperto, pubblico dominio negli Stati Uniti |
  | OWASP ASVS | 5.0.0 | aperto, CC BY-SA 4.0 |
  | SLSA | 1.2 | aperto, CSL 1.0 |

- **[W]** ECSS: nessun documento si riproduce senza consenso esplicito di ESA;
  conservare copie nel repository richiede il permesso scritto della segreteria.
- **[F]** Scaricati e convertiti: ASVS 5.0.0 (345 requisiti), tabella SSDF 1.1 e
  i PDF di SP 800-218 e NIST IR 8397, con impronte SHA-256 nel registro.
- **[?]** CC BY-SA 4.0 e GPL-3.0-or-later: il riuso del contenuto ASVS in un
  repository GPL richiede conferma legale; per prudenza vive in file separati
  con avviso.
- **[P]** Per le norme protette il repository conserva identificativo, edizione,
  numeri di clausola e controlli operativi scritti da noi. Mai testo normativo.
  Nessuna voce `da-verificare` genera controlli.

## 14. Piano di test

- **[P]** ERT sul nucleo con la CI esistente. Prove negative intenzionali: un
  agente che tenta di approvarsi, di alterare un'impronta, di cancellare un
  evento, di saltare un gate, di cambiare profilo o standard.
- **[P]** Macchina a stati: test esaustivo su tutte le coppie; ogni coppia ha un
  esito atteso (ammessa o rifiutata).
- **[P]** Migrazioni: salita da ogni versione, errore chiaro su archivio
  danneggiato, ripristino dopo scrittura interrotta.
- **[P]** Copertura piena delle righe di `gdev-process.el` e `gdev-policy.el`,
  con lo stesso schema di `gdev-coverage-workspace-state`.
- **[P]** Sondaggio FTS5 con ripiego; prova su Emacs 30.1.
- **[P]** Estensione del contratto CLI e MCP (`python3 test/gdev-cli-contract-test.py`)
  per i nuovi sottocomandi.
- **[P]** Misura del costo dei ganci e delle interrogazioni frequenti.
- **[P]** Isolamento con `GDEV_STATE_DIR` e `GDEV_USER_DIR` su cartelle temporanee.

## 15. Roadmap e dipendenze

Vedi la [tabella di marcia](roadmap.md). In sintesi:
A analisi → B nucleo → C standard e profili → D applicazione, documenti e
adozione → E agenti e auto-applicazione.

## 16. Rischi e compromessi tecnici

- **Radice di fiducia locale.** Chi controlla la macchina può riscrivere
  l'archivio. L'audit concatenato e i trigger lo rendono **rilevabile**; diventa
  difficile da alterare solo con un'àncora esterna (CI, rilascio firmato).
- **Aggiramento.** Un agente con shell può modificare file senza passare dal
  nucleo. L'unico argine reale è CI e protezione dei rami, fuori dal repository.
- **[F] `eval` nell'MCP.** Verificato dopo la M1: il server MCP offre l'azione
  `eval` (`lisp/gdev-mcp.el:147`, segnata come distruttiva), che valuta Lisp nel
  processo del nucleo. Un agente con `eval` può dichiararsi una persona,
  riassegnare le variabili del nucleo, ridefinirne le regole o scrivere
  nell'archivio. Nessuna difesa in questo processo lo impedisce; la M2 ha
  aggiunto l'origine del canale, che ferma le chiamate ingenue ma non
  l'aggiramento volontario. La conseguenza di progetto è che la garanzia «un
  agente non approva» deve poggiare fuori dal processo (CI, protezione dei rami,
  àncora della catena): il rapporto la prevedeva già, ora è un vincolo certo.
- **Falso senso di conformità.** Una valutazione senza prove è rumore: il
  default è `NOT_VERIFIED`, non `SATISFIED`.
- **Licenze.** Il rischio maggiore è incollare testo protetto; la classe
  `solo-riferimento` lo esclude per costruzione.
- **Edizioni che cambiano.** La 12207 è già passata al 2026; il registro
  conserva le edizioni e non ne riscrive il passato.
- **Compatibilità.** SQLite integrato ed FTS5 variano fra le build di
  Emacs 30.1 e quelle della CI.
- **Costo dei ganci.** Avviare Emacs a ogni commit può essere lento; va misurato
  prima di imporlo.
- **Peso del processo.** Un profilo troppo rigido rende lo strumento
  inutilizzabile; per questo i profili sono compositi e il minimo è Core.
- **Auto-applicazione.** Applicare il processo a GDev prima che il nucleo sia
  stabile crea un circolo: la Fase E segue D.

## 17. Prima milestone implementabile

**M1 «Archivio e transazione minima», in sola lettura da CLI: completata.**
Approvata il 2026-11-18 con le decisioni consigliate: archivio in
`<progetto>/.gdev/assurance/` e nucleo in `lisp/` con i nomi proposti.

- **[F]** Nuovi: `lisp/gdev-assurance-db.el` (apertura, migrazioni, integrità),
  `lisp/gdev-process.el` (stati, regole, catena degli eventi, verifica),
  `lisp/gdev-evidence.el` (prove), `lisp/gdev-assurance.el` (facciata e
  sottocomandi) e `test/gdev-assurance-test.el`.
- **[F]** Modificati: `lisp/gdev-cli.el` (`gdev assurance status|list|show|verify`,
  sola lettura), `test/gdev-test.el` e `test/gdev-coverage.el`
  (`gdev-coverage-assurance`), `.github/workflows/ci.yml`, `.gitignore`
  (`/.gdev/`) e il `README.md`.
- **[F]** Guida d'uso e limiti: [README di assicurazione](README.md).
- Fuori da M1: ganci Git, strumenti MCP di scrittura, profili, valutazioni, una
  traccia dei rifiuti e l'àncora esterna della catena.
- **Deviazioni dal progetto:** i test stanno in un solo file; `docs/agenti.md` non
  cambia perché il catalogo dei comandi si ricava dall'intestazione di
  `gdev-cli.el`; l'attore non è autenticato (vedi il README).

### M2 «Regole, controlli e traccia dei rifiuti»: completata (2026-11-18)

- **[F]** Nuovi: `lisp/gdev-policy.el` (motore, nega per impostazione predefinita)
  e `lisp/gdev-gates.el` (controlli di passaggio fondati sulle prove).
- **[F]** Modificati: `lisp/gdev-process.el` (regole registrate nel motore, evento
  `refusal`, origine del canale), `lisp/gdev-evidence.el`,
  `lisp/gdev-assurance-db.el` (migrazione 2, che ricostruisce `tx_event` per
  accettare `refusal` conservando righe e impronte), `lisp/gdev-assurance.el`,
  `lisp/gdev-agent-control.el` (le azioni degli agenti girano con l'origine
  `agent`) e i file di prova e di copertura.
- **Fuori da M2:** strumenti MCP di sola lettura e integrazione con
  `gdev-workspace-state` (restano nella Fase B); un confine contro `eval`, che
  non si ottiene in questo processo.

### M3 «Lettura da un agente e transazione attiva»: completata (2026-11-18)

- **[F]** `gdev-assurance-data` (`lisp/gdev-assurance.el`) restituisce le letture in
  forma pronta per `json-serialize`; il sottocomando le stampa e lo strumento
  MCP `gdev_assurance` le restituisce. È una sola fonte.
- **[F]** Nuova azione dal vivo `assurance` (arità 3) in
  `lisp/gdev-agent-interface.el`, strumento in `lisp/gdev-mcp.el`, riga in
  `docs/agenti.md`. Sola lettura, esente dal controllo del minibuffer come le
  altre letture.
- **[F]** `lisp/gdev-assurance-workspace.el` e il campo transitorio
  `gdev-assurance-transaction` in `lisp/gdev-workspace-state.el`. Transitorio per
  scelta: renderlo salvabile richiederebbe un formato di sessione e una
  convalida al ripristino, che appartengono all'interfaccia (Fase D).
- **Fuori da M3:** strumenti di scrittura per gli agenti, per il vincolo che
  `eval` rende non difendibile in questo processo.

### M4 «Controlli, profili e valutazione»: completata (2026-11-18, Fase C)

- **[F]** Nuovi: `lisp/gdev-standards.el`, `lisp/gdev-controls.el`,
  `lisp/gdev-assessment.el`, i dati `docs/assicurazione/profili/controlli.eld` e
  `profili.eld` e `test/gdev-assessment-test.el`. Modificati: la facciata
  (`gdev assurance assess`, `assess` nello strumento MCP) e le prove.
- **[F]** Ogni clausola citata da un controllo esiste nei dati scaricati (indice
  di 345 requisiti ASVS e di 61 pratiche e compiti SSDF). PW.4.3, ritirato nella
  versione 1.1, è rifiutato. I controlli citano solo SSDF 1.1: nessuna clausola
  ISO, IEEE o ECSS, perché non c'è testo locale con cui verificarla.
- **[?]** I sette controlli e il loro collegamento informativo alle clausole SSDF
  sono una scelta di GDev da rivedere: sono proposte, non requisiti di uno
  standard. `high-assurance` e `critical` non hanno ancora controlli propri.
- **Fuori da M4:** deroghe, decisioni di applicabilità e valutazioni persistenti
  (servono una migrazione e un evento nella catena), valutazione della capacità
  di processo, controlli su ISO, IEEE ed ECSS.

### M5 «Deroghe e decisioni di non applicabilità»: completata (2026-11-18, Fase C)

- **[F]** Nuovi: `lisp/gdev-decisions.el` e `test/gdev-decision-test.el`.
  Modificati: `lisp/gdev-assurance-db.el` (migrazione 3: la tabella `decision`,
  con il vincolo che l'attore sia `human`, e l'evento `decision`, che ricostruisce
  `tx_event` come la 2), `lisp/gdev-process.el` (la verifica e la regola di
  origine), `lisp/gdev-controls.el` e `controlli.eld` (il flag `:decidibile`),
  `lisp/gdev-assessment.el` e la facciata.
- **[F]** La valutazione produce `WAIVED_WITH_AUTHORIZATION` e `NOT_APPLICABLE` solo
  da una decisione registrata. Le regole: una persona, un controllo del profilo
  che ammette decisioni, nessuna transazione conclusa, nessuna decisione di chi
  ha aperto dal profilo `secure` in su.
- **Limite:** nessun canale per prendere una decisione da un agente o dalla riga di
  comando, e in questo processo nulla impedisce a un agente che valuta Lisp di
  dichiararsi una persona.

### M6 «Valutazioni registrate»: completata (2026-11-18, Fase C)

- **[F]** Nuovi: `lisp/gdev-assessment-store.el` e `test/gdev-assessment-record-test.el`.
  Modificati: `lisp/gdev-assurance-db.el` (migrazione 4: le tabelle `assessment` e
  `assessment_result` e l'evento `assessment`, che ricostruisce `tx_event` come la
  2 e la 3), `lisp/gdev-assessment.el` (`gdev-assessment-record` e il campo
  `recorded`), `lisp/gdev-process.el` e la facciata.
- **[F]** Ogni valutazione registrata ha le impronte degli ingressi e dei
  risultati, riportate anche nell'evento della catena, e una riga per controllo in
  ordine. `verify` rileva risultati alterati, impronte che non tornano, eventi
  duplicati o mancanti.
- **Limite:** il confronto usa lo stato attuale dell'archivio, non una
  ricostruzione «com'era»: GES-C02 riguarda sempre l'archivio intero. Nessun canale
  per registrare una valutazione dalla riga di comando o da un agente.
- **Verifica estesa:** gli ingressi devono ricostruire l'impronta registrata,
  la testa della catena deve precedere l'evento, il profilo deve coincidere con
  quello della transazione e le posizioni dei risultati devono essere
  consecutive da 1. Per prove, decisioni e valutazioni, transazione, attore,
  tipo d'attore e data si confrontano con i rispettivi eventi.

### M7 «Controlli per i profili più rigidi»: completata (2026-11-18, Fase C)

- **[F]** `docs/assicurazione/profili/controlli.eld` ha cinque controlli in più
  (12 in tutto) e `profili.eld` li assegna a `high-assurance` (GES-H01, H02, H03) e a
  `critical` (GES-K01, K02). `lisp/gdev-controls.el` convalida e
  `lisp/gdev-assessment.el` valuta le nuove forme di requisito: prova di un tipo
  d'attore, prova indipendente da chi ha portato la transazione in uno stato,
  valutazione registrata prima di un passaggio, attori distinti fra due stati,
  nessuna decisione di un genere.
- **[?]** I cinque controlli sono una proposta di GDev da rivedere, non requisiti di
  uno standard: i riferimenti SSDF sono informativi e i profili restano
  «provvisori». Una transazione critical che segue tutto il percorso soddisfa i
  dodici controlli; il test lo mostra.
- **Fuori da M7:** una versione dei controlli che citi ISO, IEEE o ECSS e la
  valutazione della capacità di processo.

### M9 «Standard scelti e prove specifiche»: implementata (2026-11-19, Fase C)

- **[F]** Il catalogo ha 23 riferimenti e 21 voci selezionabili. I 448 obiettivi
  operativi originali GDev comprendono 345 riferimenti ASVS, 61 SSDF, otto SLSA,
  19 riferimenti a indici parziali ECSS e 15 obiettivi documentali. Questi ultimi
  si riferiscono alla scheda bibliografica: `@document` non è una clausola.
  Le fonti protette restano fuori dal repository.
- **[F]** La scelta umana precede l'autorizzazione e fissa le definizioni
  nell'audit. Una prova specifica dichiara esito, obiettivo, prova raccolta,
  fase e impronta degli ingressi. Ruoli, tracciabilità, indipendenza e
  valutazione registrata sono controllati quando richiesti dai criteri GDev.
  Prove generiche, ricostruite, di un'altra transazione o di un ciclo precedente
  non soddisfano gli obiettivi scelti. Una sola prova ASVS non copre gli altri
  344 riferimenti.
- **[F]** La migrazione 6 conserva eventi, registrazioni e valutazioni
  precedenti; aggiunge il genere `standard` e il contesto degli artefatti.
  Modifiche ai file, alle relazioni o alle definizioni rendono superata la
  valutazione. La firma verifica gli artefatti nell'albero Git immutabile
  rilevato dal verificatore, anche se l'indice cambia nel frattempo.
- **[F]** Le letture `standards` e `standard-assess` e le tre scritture
  `standard-select`, `standard-proof`, `standard-decision` usano lo stesso
  nucleo. MCP può proporre una prova specifica, con conferma monouso della
  persona; l'azione conserva l'identità di agente e non soddisfa un requisito
  di verifica umana. La [guida](standard/attuazione.md) descrive il percorso.
- **Limiti:** i controlli verificano struttura e prove dichiarate, non la
  correttezza del rapporto né la conformità normativa completa. Il catalogo
  non assegna certificazioni, livelli SLSA o capacità ISO. La famiglia 3300x
  rimanda alle singole parti; NASA-HDBK-2203 rimane non selezionabile finché
  l'edizione della fonte ufficiale non è chiarita. Profili avanzati provvisori
  e configurazione dei firmatari esterni mantengono i limiti già descritti.

### M10 «Integrazione nel Workbench»: implementata (2026-11-19)

- **[F]** La vista del progetto collega transazioni, controlli, standard,
  artefatti, proposte, documenti, capacità, audit e impatto. La CLI e
  l'editor condividono le scritture; le letture della pagina condividono una
  sola istantanea SQL. La scelta attiva appartiene allo spazio, compare
  nella barra di stato e permette letture contestuali agli agenti.
- **[F]** Le conferme della vista usano il digest esaminato e mantengono
  l'identità di agente. Cambiare spazio, progetto o transazione durante un
  prompt interrompe la scrittura. Adozione e installazione dei ganci
  lavorano fuori dal processo grafico e ritrovano lo spazio d'origine.
- **[F]** L'inventario iniziale viene ricontrollato dentro la transazione
  SQL: un altro scrittore non può introdurre un secondo inventario tra
  il controllo e la registrazione. Le lavorazioni condividono il criterio
  dei controlli dovuti con CLI, passaggi di stato e firma Git.
- **Limiti invariati:** profili avanzati provvisori, riferimenti normativi
  con gli ambiti dichiarati, identità non autenticata nel processo Emacs
  e configurazione remota dei firmatari e dei controlli obbligatori.
