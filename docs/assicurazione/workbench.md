# Assicurazione nel Workbench

Apri **Progetto › Assicurazione del progetto** con `C-c p i`. La vista si
apre come documento del gruppo attivo; `q`, `⌘W` e la × della scheda la
chiudono. **Progetto › Catalogo degli standard**, `C-c p I`, apre lo stesso
strumento sul catalogo. Le azioni sono disponibili anche in **Comandi** e
in **Strumenti › Moduli › Assicurazione**.

La cartella sotto il titolo è il bersaglio delle operazioni. In uno spazio
con più cartelle, l'apertura parte dal contesto del documento. Con il
prefisso `C-u`, scegli una cartella esplicita. Ogni spazio conserva la propria
vista e la propria transazione attiva. La scelta attiva è transitoria:
dopo il riavvio si sceglie di nuovo, mentre l'archivio conserva la storia.

## Dalla modifica alla verifica

1. Scegli **Nuova transazione…**, scrivi titolo e profilo. La transazione
   diventa attiva e il suo identificativo compare nella barra di stato.
   Un clic sull'identificativo apre il progetto della transazione, anche
   quando il documento corrente appartiene a un'altra cartella dello spazio.
2. In **Controlli**, usa **Scegli standard…** prima dell'autorizzazione.
   Il completamento offre standard interi e singoli `STANDARD#OBIETTIVO`;
   separali con virgole e indica il motivo. Una scelta nuova sostituisce
   quella corrente, conservando la precedente nell'audit.
3. **Passaggio di stato…** applica le stesse regole della CLI:
   autorizzazioni, separazione degli attori, fasi e prove richieste.
4. In **Tracce**, registra gli artefatti e collega requisiti, sorgenti e
   prove. Salva un file modificato prima di registrarlo. L'apertura di un
   artefatto resta nel progetto; un collegamento a un bersaglio esterno non
   permette di uscire dalla cartella attraverso questa vista.
5. Nel ciclo di verifica, usa **Registra prova…** sull'obiettivo interessato.
   Scegli esito e rapporto. **Raccogli prova…** raccoglie una prova generale:
   non soddisfa automaticamente tutti gli obiettivi scelti.
6. **Registra valutazione** conserva gli esiti correnti. **Decisione…**
   segue le regole del controllo: profilo e standard mantengono le loro
   decisioni distinte, con motivo, attore e audit.

L'identità dichiarata segue la CLI: nome di accesso oppure
`GDEV_ASSURANCE_ACTOR`. Non è un'autenticazione. I profili avanzati mantengono
la dicitura «provvisorio». Gli obiettivi GDev non certificano conformità
normativa, livelli SLSA o capacità ISO. Ambiti e fonti sono nella
[guida degli standard](standard/attuazione.md).

## Consultazione e comandi

| Sezione | Contenuto e azioni |
| --- | --- |
| Progetto | Campi richiesti, requisiti e collegamento della definizione alla lavorazione. |
| Transazioni | Modifiche del progetto, stato e profilo; seleziona una voce per lavorarci o consultarne la storia. |
| Controlli | Esiti del profilo e degli standard scelti, motivi, prove e decisioni. |
| Standard | Catalogo consultabile anche senza archivio, edizioni, criteri e collegamenti espliciti alle fonti ufficiali. |
| Tassonomie | Gerarchie, requisiti, fonti e parti ancora da integrare. |
| Procedure | Passi, input e risultati attesi; anteprima prima dell'avvio. |
| Esecuzioni | Tentativi, stati, risultati, errori e ripresa quando consentita. |
| Tracce | Artefatti con ruolo e relazioni; registrazione e collegamento di file. |
| Proposte | Dati, argomenti e digest delle proposte degli agenti; conferma o rifiuto. |
| Documenti | Sedici tipi editoriali del manifesto, apertura, confronto e generazione esplicita. |
| Capacità | Osservazioni aggregate; le deroghe non diventano controlli soddisfatti. |
| Audit | Integrità, installazione esplicita dei ganci e firma dell'indice ordinario o amend. |
| Impatto | File cambiati e artefatti interessati dalle dipendenze. |

Nelle finestre strette **Sezione: …** sostituisce la barra delle tredici
sezioni e mantiene disponibile l'intero elenco. `S` apre lo stesso selettore,
con la sezione corrente come scelta predefinita.

`Tab` e `Shift-Tab` percorrono i pulsanti; `Invio` esegue la stessa azione
del clic. `g` rilegge il progetto; `f` filtra i dati già ricevuti; `[` e `]`
cambiano pagina e portano il fuoco alla prima voce visibile. **Azzera filtro**
e `F` mostrano di nuovo tutte le voci; annullare l'inserimento conserva il
filtro precedente. Un filtro abbreviato mantiene il testo completo nell'aiuto.
`t` sceglie la transazione, `c` ne apre una, `a` avanza,
`s` sceglie gli standard, `v` registra una prova specifica, `e` una generale,
`d` decide sul controllo selezionato e `r` registra la valutazione.

I nomi restano completi e vanno a capo nelle finestre strette. Filtro,
paginazione, ridimensionamento, zoom e tema riusano i dati della vista senza
riaprire l'archivio. Un aggiornamento conserva la voce selezionata. Se CLI
o un altro processo cambiano l'archivio, premi **Aggiorna** per rileggere
un'istantanea coerente. La barra di stato mostra solo l'identità memorizzata
e non interroga SQLite durante il ridisegno.

La consultazione legge solo i dati necessari alla sezione. Le scelte dei
comandi rimangono disponibili anche senza caricare tutta la storia.
**Controlli**, le verifiche esplicite e i passaggi di stato continuano a
valutare le sorgenti correnti. Aprire un catalogo non produce un esito
positivo di verifica. Un errore di avvio della lettura resta visibile nella
pagina, da cui si può riprovare con **Aggiorna**.
Durante una rilettura i dati rimangono consultabili e **Aggiornamento in
corso…** indica che la risposta nuova non è ancora arrivata.

## Proposte, adozione e Git

La conferma di una proposta riguarda esattamente il digest mostrato. Un altro
evento, un file cambiato o una conferma già usata rendono superata la
proposta. Annullare il dialogo non scrive nell'archivio. L'azione conserva
l'identità di agente e non diventa una verifica umana.

**Adotta progetto esistente…** crea l'inventario iniziale in secondo piano.
La modifica resta proposta e le prove sono marcate come ricostruite.
**Operazioni dello spazio** mostra avanzamento, log ed eventuale interruzione.
Il completamento rimane associato allo spazio di partenza; cambiare spazio
non trasferisce la transazione a un altro progetto. Se nel frattempo cambi
le cartelle dello spazio o scegli un'altra transazione, il risultato non
sostituisce la nuova scelta attiva. Il nucleo rifiuta un
secondo inventario anche se un altro scrittore arriva per primo.

Un'interruzione conserva la selezione corrente anche quando arriva un esito
positivo tardivo. I dati già registrati restano consultabili nell'archivio;
il completamento non riapre uno spazio chiuso e non sposta il fuoco dal
documento su cui stai lavorando.

**Installa ganci Git…** richiede firmatari fidati esterni e identità del
repository; non sovrascrive ganci esistenti. **Firma indice…** e **Firma amend…**
controllano gli artefatti nell'albero Git immutabile. La ricevuta resta in
**Audit**; **Copia riferimenti commit** copia esplicitamente i riferimenti per
il messaggio. Per protezione remota e recupero controllato dell'archivio,
consulta la [guida del processo](README.md).

Le lavorazioni offrono `assicurazione-valuta` e
`assicurazione-valuta-standard`, con argomento `transazione`. Controllano gli
esiti dovuti senza approvare o modificare la transazione; la seconda richiede
una scelta di standard. `assicurazione-proponi` continua ad accodare proposte
con l'identità di agente.
