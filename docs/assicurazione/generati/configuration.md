<!-- Generato da GDev; non modificare. Fonti sha256:4f77fde3c0568819527a83a52f449ba1461e8ebeb70ea6b5fed3e172b6cbad61 -->

# Configurazione

## Fonte: docs/dipendenze.md

# Dipendenze e licenze

Provenienza, versioni e licenze dei componenti distribuiti con GDev-Emacs.
Per l'installazione e la configurazione, torna alla [guida introduttiva](../../../README.md).

Per i fork con un nome GDev, la guida del modulo e il catalogo riportano
anche il nome originale. Le etichette dell'interfaccia usano il nome GDev.

| Nome GDev | Nome e versione originali | Licenza e modifiche |
| --- | --- | --- |
| [Cronologia degli annullamenti](../../../modules/emacs/undo/config.el) | [undo-fu-session 0.8](../../../vendor/elpa/undo-fu-session-0.8/undo-fu-session.el) | GPL-3.0-or-later. Il fork permette al profilo di conservare gli annullamenti in SQLite. Verifica dimensione e impronta del documento prima del ripristino. |
| [Hit](../../../modules/tools/git/config.el) | [Magit 4.7.2](https://github.com/magit/magit/tree/602760478f6d4a67e7064f5bcd2e294aa3f38f8e) | [GPL-3.0-or-later](../../../vendor/elpa/magit-4.7.2/LICENSE). Fork per il controllo versione in GDev-Emacs, con menu, viste e azioni localizzate. Sorgenti, attribuzioni e manuale inclusi. |
| Sezioni Hit | [Magit-Section 4.7.2](https://github.com/magit/magit/blob/602760478f6d4a67e7064f5bcd2e294aa3f38f8e/lisp/magit-section.el) | [GPL-3.0-or-later](../../../vendor/elpa/magit-section-4.7.2/LICENSE). Nomi delle viste e azioni delle sezioni in italiano. |
| [Org GDev](../../../modules/lang/org/config.el) | [Org 9.8.10](https://elpa.gnu.org/packages/org-9.8.10.tar) | [GPL-3.0-or-later](../../../vendor/elpa/org-9.8.10/COPYING), GNU FDL per i manuali e [CC BY-SA 3.0 Unported](https://creativecommons.org/licenses/by-sa/3.0/) per i dati CSL. [Modifiche e attribuzioni](../../../vendor/elpa/org-9.8.10/GDEV.md). |
| [LaTeX GDev](../../../modules/lang/latex/config.el) | [GNU Emacs TeX mode 30.1](https://github.com/emacs-mirror/emacs/blob/8ac894e2246f25d2a2a97d866b10e6e0b0fede5a/lisp/textmodes/tex-mode.el) | [GPL-3.0-or-later](../../../vendor/elpa/gdev-tex-mode-30.1/COPYING). Fork dell'inizializzazione della modalità LaTeX, con nomi separati e riuso del motore TeX di Emacs. |
| [Lettore PDF](../../../modules/tools/pdf/README.md) | [GNU Emacs DocView 30.1](https://github.com/emacs-mirror/emacs/blob/8ac894e2246f25d2a2a97d866b10e6e0b0fede5a/lisp/doc-view.el) | [GPL-3.0-or-later](../../../vendor/elpa/gdev-doc-view-30.1/COPYING). Fork della vista paginata e della navigazione. Per i PDF su macOS usa PDFKit, fornito dal sistema. |
| [Debug dello spazio](../../../modules/tools/debugger/config.el) (Dape GDev) | [Dape 0.28.0](https://github.com/svaante/dape/tree/1d45904b40bfdbdbe0e29546a13d7859a478f710) | [GPL-3.0-or-later](../../../vendor/elpa/dape-0.28.0/dape.el). Interfaccia italiana, filtri delle eccezioni per sessione, avvio in base al codice di uscita della compilazione, [controlli del margine](../../../vendor/elpa/dape-0.28.0/dape-breakpoint-mode.el) caricabili in modo indipendente, aggiornamento dei punti nello stesso oggetto, errori di lettura delle variabili, riavvio che azzera i valori in linea, riga di stato in italiano e mappa bidirezionale dei sorgenti. |
| [Sposta testo](../../../modules/editor/motion/config.el) | [move-text 2.0.10](https://github.com/emacsfodder/move-text/blob/142890cfb46d9c374113b4b49021a4202033147b/move-text.el), di Jason Milkins | [GPL-3.0-or-later](../../../vendor/elpa/gdev-sposta-testo-2.0.10/COPYING). Nomi e guida in italiano. Gestione dei prefissi numerici, dell'ultima riga e della selezione. |
| [Consult GDev](../../../modules/completion/vertico/config.el) | [Consult 3.10](https://github.com/minad/consult/tree/3c64214db5cd61a8f8186e4dce89c0e04be1652c) | [GPL-3.0-or-later](../../../vendor/elpa/consult-3.10/consult.el). Interfaccia in italiano, [riferimenti distinti per colonna](../../../vendor/elpa/consult-3.10/consult-xref.el) e [visita iterativa dei simboli](../../../vendor/elpa/consult-3.10/consult-imenu.el), con prefissi costruiti su richiesta. |
| [Breadcrumb GDev](../../../modules/ui/breadcrumb/config.el) | [Breadcrumb 1.0.1](https://elpa.gnu.org/packages/breadcrumb.html) | [GPL-3.0-or-later](../../../vendor/elpa/breadcrumb-1.0.1/breadcrumb.el). Espone i segmenti dei simboli per la navigazione, conserva nomi e posizioni Imenu e riusa l'indice già calcolato. |
| [Convertitore regex GDev](../../../modules/tools/git/config.el) | [pcre2el 1.12](../../../vendor/elpa/pcre2el-1.12/pcre2el.el) | GPL-3.0-or-later, con attribuzione BSD incorporata. Usato dai Promemoria di Hit; aggiorna i flag del minibuffer con l'API delle regioni, conservando testo, prompt e comportamento del cursore. |
| [BDD Elisp GDev](../../../test/gdev-bdd.el) | [Buttercup 1.41](../../../vendor/elpa/buttercup-1.41/GDEV.md) | GPL-3.0-or-later. Fork locale del motore BDD, con segnali falliti e pendenti intercettabili anche da ERT. |
| [Gherkin GDev](../../../test/behavior/README.md) | [Parser Ecukes 0.7.0](../../../vendor/elpa/gdev-gherkin-0.7.0/GDEV.md) | GPL-3.0-or-later. Parser italiano/inglese, outline e controllo dei passi ignorati; riusa F, S e Dash già inclusi. |
| [Cursori multipli GDev](../../../modules/editor/multiple-cursors/config.el) | [multiple-cursors 1.5.0](../../../vendor/elpa/multiple-cursors-1.5.0/multiple-cursors-core.el) | GPL-3.0-or-later. Numero di riga corretto anche in batch e colonna coerente per il primo cursore aggiunto dalla selezione. |
| Certificati GDev | [x509-mode 20261112.729](../../../vendor/elpa/x509-mode-20261112.729/x509-mode.el) | MIT. Il caricamento a freddo durante la compilazione di un altro modulo trova i dati nella cartella del fork. |

Hit si attiva con `:tools git`. I simboli Lisp `magit-…` restano disponibili
alle integrazioni come Forge e alla configurazione, mentre in `M-x` gli stessi
comandi compaiono come `hit-…`. Quando il modulo è attivo, `gdev compile` compila anche
il sorgente del fork incluso nella distribuzione.

## Registro dei fork locali

Il [corpus dei comportamenti](../../../test/behavior/README.md) conserva separatamente
fixture da Tree-sitter, GNU Emacs, TypeScript/Fourslash, TypeScript-TmLanguage,
CodeMirror e Monaco/VS Code. Il suo [registro](../../../test/behavior/sources.json)
riporta revisioni e impronte di ogni originale e collega le licenze complete:
MIT, Apache-2.0 e GPL-3.0-or-later. Gli adattatori sono GPL-3.0-or-later.
I fixture sono dati di prova; i due moduli BDD eseguibili sono anche nel
registro dei pacchetti seguente.

Il [registro delle versioni](../../../vendor/pacchetti.el) elenca i pacchetti Lisp distribuiti,
con licenza, indirizzo del progetto originale e revisione. Ogni versione è in
[`vendor/elpa`](../../../vendor/elpa), con i sorgenti e le attribuzioni distribuite dal
pacchetto. Per i pacchetti con più licenze valgono anche le note dei singoli file.
Il test del registro confronta tutte le directory con i descrittori, verifica i
riferimenti alle revisioni e controlla la presenza di sorgenti e autoload.

- [GPL-3.0](../../../LICENSE), [GPL-2.0](../../../vendor/licenze/GPL-2.0.txt),
  [GNU FDL 1.3](../../../vendor/licenze/GFDL-1.3.txt) e [Unlicense](../../../vendor/licenze/Unlicense.txt).
- La licenza MIT di `x509-mode` è nel [sorgente](../../../vendor/elpa/x509-mode-20261112.729/x509-mode.el).
- I manuali di [Compat](../../../vendor/elpa/compat-31.1.0.0/compat.texi),
  [Dash](../../../vendor/elpa/dash-2.20.0/dash.texi) ed [Eat](../../../vendor/elpa/eat-0.9.4)
  includono i sorgenti e conservano gli avvisi GNU FDL.
- `pcre2el` conserva l’attribuzione BSD del codice incorporato.
- [Dati di `datetime`](../../../vendor/elpa/datetime-0.10.2/NOTICE.md) con le
  versioni di OpenJDK usate dal progetto originale e gli avvisi Unicode CLDR e TZDB.
- Elfeed include il [sorgente di `xml-query.el`](https://github.com/skeeto/elfeed/blob/d76d43699a1348077bada2c4a313f256f8b377c3/xml-query.el) della stessa revisione, con la sua dichiarazione di pubblico dominio.

Per i pacchetti registrati Emacs attiva soltanto il fork in questo repository,
anche quando una copia con la stessa versione è già installata. `gdev compile`
compila i sorgenti locali e rigenera il file di attivazione. I moduli GDev
usano questi fork e le librerie fornite da Emacs. Gli archivi ELPA restano
disponibili per i pacchetti aggiunti nella configurazione personale.
`gdev compile --native` compila anche il nucleo e i moduli attivi in codice nativo.

Swift, Zig, Terraform, direnv e i feed usano i fork locali di
Swift Mode, Zig Mode, Terraform Mode, Envrc ed Elfeed. HCL Mode,
Reformatter e InheritEnv sono le rispettive dipendenze Lisp incluse.
Le modalità di Go, Rust, Java e C# usano le librerie distribuite con Emacs.

## Integrare una nuova versione in un fork

Gli aggiornamenti da ELPA e `gdev sync -u` mantengono le copie in
`vendor/elpa`. `gdev upgrade` segue i commit del repository GDev-Emacs. Per
integrare un nuovo rilascio del progetto originale, recupera la base esatta
indicata nel [registro](../../../vendor/pacchetti.el) e il nuovo rilascio. Prepara
due cartelle con la stessa struttura del pacchetto distribuito.

```sh
./bin/gdev fork-merge dape /percorso/base-a-monte /percorso/nuovo-rilascio
```

Il comando usa la base originale, la copia GDev presente in `vendor/elpa`
e la nuova versione. Il risultato è un repository temporaneo. `git status`
elenca i conflitti e `git diff --cached HEAD` mostra i cambiamenti già
integrati. In presenza di conflitti, il comando restituisce codice `1` e
lascia disponibile l'anteprima. Risolvi ciascun conflitto lì e usa `git add`
per registrare la risoluzione. Verifica le personalizzazioni visibili
anche dopo un merge pulito.

Porta in GDev il risultato verificato insieme al descrittore, agli autoload
e agli avvisi pertinenti. Aggiorna la revisione in `vendor/pacchetti.el`
nello stesso commit. Se cambia la versione, aggiorna il numero nel registro
e nel nome della cartella del pacchetto. Esegui la compilazione, le prove del
modulo e il controllo del caricamento locale.
Elimina il repository temporaneo quando hai finito.

## Interfaccia italiana

Le descrizioni dei pacchetti nel catalogo sono in italiano. Sono localizzati anche
la ricerca, la selezione delle cartelle, la modifica dei risultati della ricerca nel testo,
la scelta degli spazi di lavoro, le azioni Git aggiornate, i messaggi dell'esecuzione passo passo,
la consultazione della documentazione, alcuni avvisi di annullamento e la
compilazione di Jinx. Le note datate nei file modificati indicano gli interventi
di localizzazione. Il manuale italiano di Hit è stato adattato da quello di
Magit il 15 novembre 2026. Il [sorgente Texinfo](../../../vendor/elpa/magit-4.7.2/magit.texi)
conserva l'attribuzione originale e accompagna il manuale Info.

## Icone

Le icone in [`icons/`](../../../icons) sono disegnate per GDev-Emacs e seguono la
licenza del progetto, GPL-3.0-or-later. Sono SVG di 24×24 punti a tratto
continuo, spesso 1,75, con estremità arrotondate e colore `currentColor`:
`gdev-ui-icon` le colora con la faccia del contesto e, nel terminale, mostra
il carattere di riserva. Un'icona di terzi può entrare solo con una licenza
compatibile con la GPL-3.0, per esempio MIT, Apache-2.0 o ISC, con
l'attribuzione richiesta. Registrala in questa guida con origine, versione e
licenza. Le licenze Creative Commons si valutano caso per caso: verifica
l'elenco delle licenze compatibili della Free Software Foundation prima di
includerle. SF Symbols resta
escluso perché la sua licenza ne limita l'uso alle app per piattaforme Apple.

## Avvisi e condizioni di distribuzione

Le copie locali conservano gli avvisi originali. Le modifiche riportano una nota
datata. Per i fork GPLv3, una nota come `Modificato per GDev-Emacs il
AAAA-MM-GG: breve descrizione` indica l'intervento. Si può aggiungere il nome
dell'autore effettivo delle modifiche. Conserva copyright, licenze e
attribuzioni originali. Includi i sorgenti corrispondenti e gli avvisi richiesti
quando prepari una distribuzione compilata. [GNU GPL v3, sezioni 4–6](https://www.gnu.org/licenses/gpl-3.0.html)

I sorgenti di Dash sono inclusi senza l’illustrazione `rainbow-dash.png`, i cui
diritti di redistribuzione non sono documentati. [Segnalazione Debian](https://www.mail-archive.com/debian-bugs-rc%40lists.debian.org/msg456731.html)

Il [fork di SLY 1.0.43](../../../vendor/elpa/sly-1.0.43/) include Slynk e il
manuale. GDev usa SBCL, Clozure CL ed ECL. La copia esclude il backend
CLISP e il suo file `slynk/xref.lisp`, che contiene condizioni proprie
sui compensi per l'accesso e la distribuzione. Il backend Clozure CL mantiene
la [LLGPL](../../../vendor/licenze/LLGPL.txt) e la [GNU LGPL 2.1](../../../vendor/licenze/LGPL-2.1.txt).
I [riferimenti HyperSpec](../../../vendor/elpa/sly-1.0.43/lib/hyperspec.el) e i
[test di SLY](../../../vendor/elpa/sly-1.0.43/lib/sly-tests.el) conservano gli avvisi
[GNU GPL 2.0 o successiva](../../../vendor/licenze/GPL-2.0.txt).
I file Common Lisp mantengono i rispettivi avvisi e le dichiarazioni di pubblico dominio.
Il REPL si avvia anche senza Quicklisp. Il [fork di sly-quicklisp](../../../vendor/elpa/sly-quicklisp-20211206.948/)
attiva l'integrazione quando si usa il comando per caricare un sistema.

I programmi di sistema come Git e i server di linguaggio, Enchant e le grammatiche
tree-sitter seguono il proprio percorso di installazione.

L'assicurazione usa SQLite e JSON integrati in Emacs, senza pacchetti Lisp nuovi.
La verifica esterna delle ricevute Git usa Python 3.9 o successivo (sola libreria
standard), Git e OpenSSH con `ssh-keygen -Y sign/verify`. Il processo esterno è
necessario perché la CI possa verificare gli oggetti senza caricare il codice
della proposta. Le chiavi private restano nella gestione di OpenSSH/ssh-agent;
il verificatore riceve solo il file dei firmatari pubblici. Nessun fork già
usato dal progetto governa questi contratti, quindi questa integrazione non
modifica i pacchetti Lisp di terze parti.

## Manutenzione dei fork del 19 novembre 2026

Le versioni e revisioni nel registro identificano la base originale. Le
modifiche locali restano nel repository e sono indicate con un avviso datato
nei sorgenti interessati; nessuna licenza o attribuzione originale è rimossa.
I nomi seguenti affiancano la denominazione GDev all’identificatore originale.

| Fork GDev | Originale | Intervento locale |
| --- | --- | --- |
| ace-window GDev | `ace-window` | Conservazione dei collegamenti dinamici del selettore di finestre. |
| apache-mode GDev | `apache-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| avy GDev | `avy` | Conservazione dei collegamenti dinamici del selettore e dichiarazioni esplicite. |
| casual GDev | `casual` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| consult-dir GDev | `consult-dir` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| corfu GDev | `corfu` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| csv-mode GDev | `csv-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| dash GDev | `dash` | Shim storico escluso dalla compilazione intenzionalmente; semantica e avviso runtime conservati. |
| diff-hl GDev | `diff-hl` | Opzioni Mercurial dichiarate dinamicamente prima del caricamento del backend. |
| difftastic GDev | `difftastic` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| dired-hacks-utils GDev | `dired-hacks-utils` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| dired-subtree GDev | `dired-subtree` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| dtrt-indent GDev | `dtrt-indent` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| emmet-mode GDev | `emmet-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| envrc GDev | `envrc` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| gdev-doc-view GDev | `gdev-doc-view` | Dichiarazioni esplicite e pulizia delle immagini compatibile con i backend disponibili. |
| git-timemachine GDev | `git-timemachine` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| gptel GDev | `gptel` | Firma aggiornata dell’assistente per le anteprime in linea. |
| gptel-agent GDev | `gptel-agent` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| hcl-mode GDev | `hcl-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| indent-bars GDev | `indent-bars` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| magit-todos GDev | `magit-todos` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| multiple-cursors GDev | `multiple-cursors` | Conservazione della semantica dinamica; importazione degli appunti senza invertire distruttivamente i dati condivisi. |
| nginx-mode GDev | `nginx-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| org GDev | `org` | Dichiarazioni delle dipendenze opzionali e gestione coerente della cache. |
| paredit GDev | `paredit` | Conservazione dei collegamenti dinamici negli adattatori storici. |
| pcre2el GDev | `pcre2el` | Consigli moderni e sostituzione del minibuffer con ripristino esplicito del cursore, anche su Emacs 30.1. |
| popup GDev | `popup` | Conservazione della semantica dinamica nei percorsi storici della tendina. |
| rmsbolt GDev | `rmsbolt` | Configurazione delle lingue compatibile con le versioni 30 e 31. |
| seq GDev | `seq` | Compatibilità con Emacs 30 senza ridefinire le primitive già disponibili. |
| sly GDev | `sly` | Consigli moderni e completamento nella finestra effettivamente mostrata prima del ridimensionamento. |
| sly-asdf GDev | `sly-asdf` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| sly-macrostep GDev | `sly-macrostep` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| ssh-config-mode GDev | `ssh-config-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| terraform-mode GDev | `terraform-mode` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| tramp-hlo GDev | `tramp-hlo` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| verb GDev | `verb` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| vundo GDev | `vundo` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |
| web-mode GDev | `web-mode` | Variabili locali inizializzate senza alterare i valori globali. |
| web-server GDev | `web-server` | Chiusure lessicali e API cl-lib esplicite per le risposte asincrone. |
| yasnippet GDev | `yasnippet` | Filtro degli avvisi dichiarato dinamicamente anche su Emacs 30.1. |
| yasnippet-snippets GDev | `yasnippet-snippets` | API e dichiarazioni aggiornate; compatibilità con Emacs 30.1 e compilazione senza avvisi obsoleti. |

Le prove dedicate coprono ordine degli appunti, conversione delle espressioni
regolari, posizione del cursore nel minibuffer, completamento SLY nella finestra
visualizzata, isolamento delle variabili di Web Mode e caricamento locale. La
compilazione completa controlla anche i file meno frequentemente caricati.
