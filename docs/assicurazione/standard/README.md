# Registro degli standard

Il [registro](registro.eld) elenca i riferimenti normativi dell'assicurazione
ingegneristica in un formato che Emacs legge senza dipendenze. Una voce
indica edizione, stato, fonte e licenza. Non contiene testo normativo.

## Come si usa

La CLI espone `gdev assurance standards [ID]` e il percorso di
[attuazione per transazione](attuazione.md). Il catalogo contiene 23 voci:
21 selezionabili, con 448 obiettivi originali GDev. Sono 433 riferimenti
indicizzati e 15 obiettivi documentali. La famiglia `iso-iec-3300x` si sceglie
attraverso le singole parti; `nasa-hdbk-2203` resta sospeso perché la scheda
ufficiale presenta dati di edizione non coerenti.

```elisp
(with-temp-buffer
  (insert-file-contents "docs/assicurazione/standard/registro.eld")
  (read (current-buffer)))
```

Il risultato è un elenco di plist. `read` non valuta il contenuto: il file è
dato, non codice. Le chiavi obbligatorie sono `:id`, `:titolo`, `:ente`,
`:edizione`, `:stato`, `:verificato`, `:fonte`, `:licenza`, `:classe-riuso`,
`:formati-ufficiali` e `:note`.

## Classi di riuso

| Classe | Cosa si può conservare nel repository |
| --- | --- |
| `aperto` | Il testo, con attribuzione e con l'avviso di licenza. |
| `pubblico-da-verificare` | Il testo, dopo aver letto la dichiarazione di copyright dell'ente e averla registrata. |
| `solo-riferimento` | Solo identificativo, edizione, numeri di clausola, titoli brevi nostri e controlli operativi scritti da noi. Mai testo normativo. |

Le norme ISO, IEC e IEEE e gli standard ECSS sono `solo-riferimento`. ECSS
chiede il consenso esplicito di ESA per riprodurre i suoi documenti;
conservare una copia richiede il permesso scritto della segreteria.

## Regole di aggiornamento

- Una voce `da-verificare` non genera controlli finché edizione e stato non
  sono confermati su una fonte ufficiale.
- Ogni cambio di edizione aggiorna la voce corrente e registra l'edizione
  sostituita in `:sostituisce`. Il registro ha un solo identificativo per voce;
  le scelte nell'audit conservano le definizioni storiche e le loro impronte.
- Ogni file scaricato registra fonte, data, dimensione e impronta SHA-256 nella
  voce, in `:acquisizioni`.

## File scaricati

Scaricati il 2026-11-17 con l'approvazione dell'utente, ciascuno nella sua
cartella in `fonti/`. Fonte, dimensione e SHA-256 stanno in `:acquisizioni`.
I file `.eld` accanto al registro sono le conversioni leggibili da Emacs;
conservano intestazione, licenza e impronta dell'originale.

| Voce | File | Dimensione | Licenza |
| --- | --- | --- | --- |
| `owasp-asvs` | CSV 5.0.0 → [owasp-asvs-5.0.0.eld](owasp-asvs-5.0.0.eld), 345 requisiti | 105 100 byte | CC-BY-SA-4.0 |
| `nist-sp-800-218` | Tabella SSDF XLSX → [nist-sp-800-218-v1.1.eld](nist-sp-800-218-v1.1.eld), 4 fogli | 50 039 byte | non soggetto a copyright negli Stati Uniti, con indicazione della fonte |
| `nist-sp-800-218` | PDF della versione 1.1 | 739 891 byte | idem |
| `nist-ir-8397` | PDF 2021 | 1 575 676 byte | pubblico dominio negli Stati Uniti |
| `slsa` | fonti Build e Source 1.2 → [slsa-1.2.eld](slsa-1.2.eld), indice editoriale di otto livelli | 6 469 + 32 143 byte | CSL 1.0; avvisi in [NOTICE](fonti/slsa/NOTICE.md) |

Le fonti SLSA sono state acquisite il 2026-11-18 dalla revisione
`ae7fc76215004e8fae250c877eff8919bf048e3b` del ramo `releases/v1.2`, insieme
alla licenza CSL (16 129 byte) e alla copia Apache 2.0 (11 358 byte) per le parti
preesistenti. Il registro conserva URL, data e SHA-256 di
ciascun file. L'indice non attribuisce un livello SLSA al progetto.

La conversione ha usato uno script temporaneo in Emacs Lisp, rimosso a lavoro
finito. Il caricatore `gdev-standards` verifica i dati locali; una nuova
acquisizione deve conservare provenienza e impronte. Fuori dagli Stati Uniti
lo stato di pubblico dominio dei testi NIST non è verificato.

## Indici di solo riferimento

Il 2026-11-19 sono stati verificati i sommari ufficiali di ECSS E-ST-40C
Rev.1, Q-ST-80C Rev.2 e S-ST-00C Rev.2. I tre file `*-indice.eld` conservano
19 identificativi e titoli brevi originali GDev; sono indici parziali, non
copie delle norme. I PDF protetti non sono stati aggiunti al repository.
ISO/IEEE senza indice locale usano obiettivi documentali senza numeri di
clausola inventati. Il registro distingue edizione normativa e data di
pubblicazione (per esempio IEEE 1012-2024, pubblicata nel 2025).

## Ancora da scaricare o verificare

- Testi NASA e NIST SP 800-160: prima verificare edizione e copyright.
