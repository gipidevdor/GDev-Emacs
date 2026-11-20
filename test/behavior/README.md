# Corpus dei comportamenti e BDD

Il corpus è caricato da `test/gdev-test.el`, fa parte della suite ordinaria
e ha un passaggio CI obbligatorio dopo l'installazione delle grammatiche.
I casi ERT iniziano con `gdev-test-behavior-`. Non occorrono Cucumber,
Node, npm o download durante l'esecuzione dei test.
Ogni caso registrato isola le associazioni di file e interpreti che alcuni
modi Tree-sitter di Emacs 30 aggiungono all'attivazione, conservando la
selezione della modalità nelle prove successive.

## Copertura

| Area | Fonte e adattamento | Prove |
| --- | --- | --- |
| Parsing e recupero incrementale | Corpus originali Tree-sitter JavaScript, Python e JSON; alberi, campi dichiarati e nodi mancanti confrontati con il parser Emacs | 233 sezioni, ciascuna con confronto iniziale e dopo una modifica |
| Evidenziazione | Marcatori Tree-sitter delle parole chiave; baseline TextMate TypeScript per commenti, stringhe e parole chiave, tradotto nelle facce semantiche Emacs | 3 test con asserzioni sui caratteri dei token |
| Comportamenti nativi | Selezione esplicita dai test GNU Emacs 30.1 di Electric Pair, JavaScript e Python | 25 test, con oracoli originali |
| Editing | Input, selezione e risultato estratti dai casi CodeMirror; TAB, ritorno a capo, spostamento delle righe con i comandi Emacs/GDev | 9 test |
| Colonne | Casi Monaco per spazi, TAB, testo e documento vuoto | 8 insiemi di colonne in un test |
| Completamento, definizioni e rinomina | Fourslash TypeScript con Eglot e il vero `deno lsp` configurato dal modulo JavaScript | 6 test; includono completamento assente, oscuramento dei nomi e JSDoc |
| Flussi BDD | [editor.feature](editor.feature), in italiano; Buttercup, Gherkin GDev ed ERT | 20 scenari |
| Contratti dei test | Impronte e licenze, oracoli incompleti, Unicode, errori e passi pendenti, pulizia, outline, registrazione completa delle feature, tabelle grandi e caricamento locale dei fork | Test di controllo dedicati |

Gli scenari BDD coprono salvataggio normale e vuoto, conservazione del
cursore, ricaricamento con conferma e annullamento, annulla/ripeti,
sola lettura, coppie di parentesi, cancellazione e superamento della
chiusura, commenti, rientro JavaScript/Python da tastiera, taglia/incolla
Unicode, spostamento delle righe, snippet con campi collegati, folding,
cursori multipli, uscita e annullamento della scrittura multipla.

Le altre suite del progetto continuano a verificare navigazione e
refactoring GDev, menu e tasti, pannelli, workspace, persistenza, debug
e strumenti. Il corpus le affianca; non sostituisce le verifiche native
dell'interfaccia e non attesta da solo ogni comportamento di ogni IDE
o server a monte.

## Esecuzione

Dalla radice, dopo `./bin/gdev sync --no-docs`, con Deno disponibile:

```sh
GDEV_TEST_REQUIRE_BEHAVIORS=1 emacs --batch -Q -l early-init.el -l test/gdev-test.el \
  --eval '(ert-run-tests-batch-and-exit "gdev-test-behavior-")'
```

Per le prove locali imposta `GDEV_STATE_DIR` e `GDEV_USER_DIR` su cartelle
temporanee prima di installare le grammatiche o eseguire il comando.
Occorrono JavaScript, JSDoc, Python, JSON e TypeScript. In CI il flag rende
ogni prerequisito assente un fallimento; senza flag ERT indica i singoli
casi saltati con il motivo. Deno 2.9.8 è fissato nel workflow CI.
Le prove LSP usano solo documenti locali e cache temporanee, chiudono il
server e verificano che la rinomina non salvi il documento implicitamente.
La pulizia chiude il trasporto JSON-RPC e verifica la terminazione del
processo anche dopo un errore. Questo evita di dipendere dal messaggio
di chiusura di Eglot 30, i cui parametri null vengono rifiutati da Deno;
il dialogo LSP di chiusura non è fra gli oracoli Fourslash adattati.

Anche le sonde brevi devono caricare `early-init.el` prima delle librerie:
un Emacs `-Q` senza una directory isolata può creare `~/.emacs.d` e
cambiare la ricerca della configurazione nell'avvio successivo.

## Moduli BDD Elisp

- [BDD Elisp GDev (Buttercup 1.41)](../../vendor/elpa/buttercup-1.41/GDEV.md):
  `describe`, `it`, `expect`, fixture e segnalazioni dei risultati.
- [Gherkin GDev (parser di Ecukes 0.7.0)](../../vendor/elpa/gdev-gherkin-0.7.0/GDEV.md):
  italiano e inglese, background, outline, esempi, tabelle e stringhe
  multilinea; rifiuta feature vuote, scenari vuoti, righe non riconosciute
  e stringhe non terminate. Gli esempi richiedono colonne uniche e non
  vuote, righe complete e almeno una riga di dati. Ogni riga ha un titolo
  distinto: `Somma <a>` diventa per esempio `Somma 1 [1]` e `Somma 2 [2]`.
- [Ponte del progetto](../gdev-bdd.el): `gdev-bdd-register-feature`
  registra un test ERT per scenario. Le definizioni dei passi sono
  coppie `(REGEXP . FUNZIONE)`; la funzione riceve il contesto restituito
  da `setup`, le catture della regexp ed eventualmente tabella o stringa
  multilinea. `cleanup` riceve lo stesso contesto anche dopo un errore.
  Tutti i nomi e i passi sono validati prima di registrare il primo test.
  I passi sono risolti alla registrazione e riusati nelle esecuzioni;
  dopo una modifica alle definizioni ricarica anche la feature.
  Passi mancanti o ambigui, fallimenti e pending non diventano successi.
  L'esecuzione diretta valida i passi prima di creare il contesto con `setup`.

Le dipendenze F, S e Dash erano già incluse. Non sono richiesti il runner
CLI, i reporter, Commander, ANSI o Espuds di Ecukes. I fork sono registrati
in `vendor/pacchetti.el`; si caricano dalle copie locali anche in presenza
di versioni ELPA omonime. Le definizioni dei passi dell'editor sono in
[gdev-behavior-bdd-test.el](../gdev-behavior-bdd-test.el).

Per aggiungere una feature, scrivila accanto a `editor.feature`, definisci
i passi in Elisp e richiamane `gdev-bdd-register-feature` da un file caricato
dalla suite. Usa un prefisso distinto e un contesto temporaneo per ciascuno
scenario. Il parser legge dati: le azioni possibili sono quelle registrate
dalle funzioni Elisp del progetto.

## Traduzioni dichiarate

Gli alberi Tree-sitter confrontano i nodi nominati e i nodi mancanti.
Quando un oracolo dichiara i nomi dei campi, il confronto li include.
Gli alberi attesi restano quelli originali, inclusi i casi `:error`.

TextMate usa scope, Emacs usa facce: il ponte confronta le categorie
comuni per cui esiste un significato equivalente, compresi i delimitatori
dei commenti. Non importa la grammatica TextMate nell'editor e non equipara
ogni scope a una faccia. I fixture delle parole chiave Tree-sitter vengono
letti con le coordinate dei marcatori originali, anche sulle righe rientrate.

I marcatori CodeMirror vengono tradotti in posizioni Emacs Unicode.
Il bordo iniziale di una regione Emacs resta prima del rientro inserito;
il confronto adatta solo quell'affinità e verifica comunque entrambi gli
estremi. I casi di testo semplice usano `text-mode`; quelli di codice usano
`js-ts-mode` con rientro di due spazi. Lo spostamento di una selezione
parziale in GDev riguarda il testo esatto, mentre CodeMirror sposta righe
intere: quei casi non sono presentati come equivalenti. I casi CodeMirror
non selezionati restano nel file originale per consentire la revisione.

I test classici GNU Emacs usano i predefiniti di quel corpus, tra cui
rientro JavaScript di quattro spazi, senza i ganci personali del workspace.
La selezione e i soli helper valutabili sono elencati in
[emacs-cases.json](emacs-cases.json). I BDD e i casi CodeMirror controllano
separatamente i comandi e i rientri distribuiti da GDev.

I fixture Fourslash conservano gli input e i marcatori originali. La loro
parte di verifica viene tradotta in CAPF, xref e rinomina Eglot; non viene
eseguito il framework TypeScript. Il server reale risponde alle richieste.
La rinomina del parametro include il suo riferimento JSDoc.

## Provenienza, licenze e aggiornamento

[sources.json](sources.json) è il registro delle copie originali: repository,
commit completo, percorso, licenza e SHA-256 di ogni file. Le licenze
complete sono conservate accanto ai rispettivi file in `upstream/`.
Le fonti sono MIT, Apache-2.0 e GPL-3.0-or-later, compatibili con la
GPL-3.0-or-later del progetto; il riferimento di compatibilità è la
[lista GNU](https://www.gnu.org/licenses/license-list.html).
Il codice dei nuovi adattatori resta GPL-3.0-or-later.

Le copie originali mantengono CRLF, spazi e attribuzioni. La regola Git
specifica preserva quei byte; la prova di provenienza controlla ogni
digest e rifiuta file aggiunti o mancanti. Gli avvisi di terzi delle
implementazioni non importate non cambiano la licenza dei fixture:
non vengono distribuiti il compilatore TypeScript, le grammatiche TextMate
o i motori JavaScript di CodeMirror/Monaco.

Per aggiornare una fonte, scegli una revisione immutabile, controlla la
licenza e gli avvisi dei singoli file, recupera gli originali, aggiorna
percorso e digest nel registro e verifica le traduzioni sul nuovo input.
Ripeti il corpus obbligatorio e la suite completa. Non rigenerare gli
oracoli dall'output dell'editor per far passare un test. Un nuovo tipo di
marcatore o metadato richiede un adattatore esplicito e una prova negativa.
