# Catalogo dei frammenti

Apri un file e premi **C-c i s** o scegli **Modifica › Inserisci › Frammento di codice**.
Emacs mostra i frammenti disponibili nel documento corrente. Cerca per abbreviazione
(`dp-strategy`), nome (`Strategy`) o gruppo (`Idiomi`, `Sistemi distribuiti`). Con
Orderless puoi combinare le parole, per esempio `pattern strategy`.

Puoi anche scrivere l'abbreviazione su una riga e premere **TAB**. Il cursore si sposta
tra i campi con **TAB** e **S-TAB**. Prova `dp-builder` in Python, sostituisci
`Report` con `Invoice` nel primo campo e vedrai aggiornarsi tipo, builder e riferimenti.
Con **C-g** esci dalla ricerca prima di inserire. Nei frammenti come `g-fence`
(Markdown) o `g-src` (Org), seleziona il contenuto prima di richiamare il comando per
racchiuderlo nel blocco.

## Pattern di progettazione

Le abbreviazioni `dp-` sono stabili tra linguaggi. Se un pattern ha più implementazioni,
il documento attivo determina quale ricevi. C++, Python, JavaScript, TypeScript, Java
e C# hanno ognuno i 23 pattern GoF. [Catalogo originale di Gamma, Helm, Johnson e Vlissides](https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610)

| Famiglia | Abbreviazioni dopo `dp-` |
| --- | --- |
| Creazionali | `abstract-factory`, `builder`, `factory-method`, `prototype`, `singleton` |
| Strutturali | `adapter`, `bridge`, `composite`, `decorator`, `facade`, `flyweight`, `proxy` |
| Comportamentali | `chain-of-responsibility`, `command`, `interpreter`, `iterator`, `mediator`, `memento`, `observer`, `state`, `strategy`, `template-method`, `visitor` |

C, Objective-C, Perl, Common Lisp, Emacs Lisp, Go, Rust, Swift e Zig hanno esempi
adatti alle primitive del linguaggio. Per esempio, `dp-visitor` usa `std::visit`
in C++, i metodi generici CLOS in Common Lisp e un trait in Rust.

| Gruppo da cercare | Esempi |
| --- | --- |
| Architettura | `dp-ports-and-adapters`, `dp-dependency-injection`, `dp-cqrs`, `dp-middleware`, `dp-type-erasure` |
| Dominio e funzioni | `dp-value-object`, `dp-aggregate`, `dp-specification`, `dp-typestate`, `dp-reducer`, `dp-result` |
| Dati | `dp-repository`, `dp-unit-of-work`, `dp-data-mapper`, `dp-cache-aside` |
| Concorrenza | `dp-task-group`, `dp-worker-pool`, `dp-single-flight`, `dp-bulkhead`, `dp-actor` |
| Affidabilità e sistemi distribuiti | `dp-retry`, `dp-circuit-breaker`, `dp-rate-limiter`, `dp-event-sourcing`, `dp-saga`, `dp-transactional-outbox`, `dp-outbox-relay`, `dp-idempotent-consumer` |
| Risorse e interfaccia | `dp-raii`, `dp-arena`, `dp-scope-exit`, `dp-custom-hook`, `dp-controlled-component`, `dp-design-tokens` |

I commenti indicano i confini di ogni esempio. In Python, per esempio,
`dp-transactional-outbox` scrive riga ed evento nella stessa transazione SQLite.
`dp-outbox-relay` usa l'identificatore dell'evento per consentire la deduplicazione.
`dp-saga` mostra l'orchestrazione in un processo. [Pattern di affidabilità e messaggistica](https://learn.microsoft.com/en-us/azure/architecture/patterns/)

## Idiomi e ricette

Cerca `Idiomi` per esempi commentati che spiegano l'effetto della scelta. Inizia
con uno di questi frammenti dal documento corrispondente.

| File | Prova |
| --- | --- |
| C e C++ | `g-ctype`, `g-designated-init`, `g-borrow-view`, `g-transparent-lookup` |
| Python | `g-exit-stack`, `g-zip-strict`, `g-pairwise`, `g-pytest` |
| JavaScript, TypeScript e JSX/TSX | `g-nullish`, `g-promise-timeout`, `g-satisfies-narrow`, `g-set-state` |
| Go, Rust, Swift e Zig | `g-defer-close`, `g-entry`, `g-collect-result`, `g-weak-self`, `g-errdefer` |
| Java e C# | `g-read-lines`, `g-map-merge`, `g-await-using`, `g-cancellation` |
| Perl e Lisp | `g-slurp`, `g-defined-or`, `g-multiple-values`, `g-once-only-macro`, `g-preserve-point` |
| Shell e build | `g-argv`, `g-while-read`, `g-pipe-status` (Bash), `g-target-warnings` (CMake), `g-order-only` (Make) |
| HTML, CSS e modelli | `g-landmarks`, `g-dialog`, `g-container`, `g-layers`, `g-jinja-escape`, `g-tt-foreach` |
| JSON, YAML, TOML, INI e Terraform | `g-schema-ref`, `g-anchor`, `g-literal-string`, `g-ini`, `g-tf-for-each`, `g-kube-probes` |
| Markdown, Org e HTTP | `g-adr`, `g-named-src`, `g-tangle`, `g-verb-get`, `g-verb-auth` |

Le ricette con import e dichiarazioni includono il contesto da cui partire in un file
nuovo. Le varianti per librerie di test, React e altri strumenti indicano la dipendenza
nel nome o nel codice. Per gli esempi più recenti, usa Python 3.11+, Perl 5.36+,
C++20 con le eccezioni C++23 indicate, Go 1.23+, Swift 6, Zig 0.15, C# 12
e la versione Java indicata dal frammento. Le ricette JSX usano JavaScript
e i campi tipizzati sono disponibili in TSX. I frammenti JSON conservano le note
utili nell'intestazione del sorgente YASnippet.

## Frammenti personali

**C-c i S** apre un frammento da compilare. Usa **C-c C-c** nell'editor del frammento
per caricarlo e scegliere dove salvarlo. La cartella iniziale è `snippets/` del profilo
attivo, normalmente `~/.config/gdev/snippets/`. Lo stesso identificatore YASnippet
(`# uuid:` o, in sua assenza, `# name:`) nella stessa modalità fa prevalere la copia
personale. Puoi riaprire un esempio con `M-x yas-visit-snippet-file`. Per rileggere le
cartelle al prossimo uso di ogni modalità, usa `C-u M-x yas-reload-all`.

I [sorgenti del catalogo](../snippets/) contengono un file per abbreviazione.
I file `.yas-parents` indicano quali cataloghi ereditare. C++ Tree-sitter, per
esempio, eredita il catalogo di C++. Ogni catalogo viene caricato quando serve
alla modalità corrente. [Manuale YASnippet incluso](../vendor/elpa/yasnippet-0.14.3/doc/snippet-development.org)
