# Configurazione e manutenzione

## Installa e apri un progetto

Su macOS servono [Homebrew](https://brew.sh/) e gli strumenti da riga di comando di Apple, che puoi installare con `xcode-select --install`. Scarica i sorgenti e avvia il programma di installazione.

```sh
git clone https://github.com/gipidevdor/GDev-Emacs.git
cd GDev-Emacs
./bin/gdev-bootstrap-macos
```

Se hai già i sorgenti, esegui solo l’ultimo comando dalla radice del repository. Il programma prepara Emacs e gli strumenti di sviluppo, collega il checkout a `~/.config/emacs` e installa `gdev` in `~/.local/bin`. Puoi rieseguirlo dopo un’interruzione. Per controllare l’installazione usa `gdev doctor`.

1. Apri Emacs e scegli **Apri cartella…** (`⇧⌘O`) dal cruscotto.
2. Premi `⌘P`, scrivi parte del nome di un file e aprilo.
3. In un progetto C o C++, premi `F7` per compilare. I risultati compaiono sotto il codice. Con `F8` raggiungi il problema successivo.

## Scegli cosa caricare

La tua configurazione sta in `~/.config/gdev` (o `$GDEV_USER_DIR`), fuori dall'archivio dei sorgenti. Puoi
versionarla a parte e conservarla tra un aggiornamento e l'altro.

| File | Contiene |
| --- | --- |
| `init.el` | Moduli attivi e opzioni nel blocco `gdev!` |
| `packages.el` | Pacchetti aggiuntivi, uno per chiamata a `gdev-package` |
| `config.el` | Impostazioni personali, caricate per ultime |

```elisp
(gdev! :editor (format +onsave) fold
       :ui workbench
       :lang cc perl
       :config default)
```

Trovi l'elenco dei moduli nel [modello di configurazione](../templates/init.el).
Dopo aver modificato `init.el` o `packages.el`, esegui `gdev sync` e premi
`C-c q R` per riavviare Emacs e ripristinare la sessione.

Il modulo `:ui workbench` attiva tema, caratteri, menu in italiano e gestione dei
riquadri e delle aree di testo. Le configurazioni che usano `popup` attivano lo stesso modulo.
`gdev compile` genera il codice intermedio dell'interfaccia in `modules/ui/workbench/`.

`gdev compile` e `gdev sync` compilano anche i file privati presenti. I rispettivi
`.elc` vengono salvati accanto ai sorgenti. Se modifichi un `.el`, al prossimo
avvio Emacs carica il sorgente più recente. Dopo un aggiornamento, esegui
`gdev compile --native` per rigenerare il codice compilato.
`gdev clean` rimuove i file compilati.

`GDEV_STATE_DIR` cambia la cartella di stato. Puoi usarne una separata
per eseguire prove in un'istanza isolata. `GDEV_TOOLS_DIR` cambia la cartella
dei programmi di supporto installati dal programma d'installazione.

## Profili e moduli personali

Un modulo personale vive in `~/.config/gdev/modules/CATEGORIA/NOME/config.el`.
Attivalo in `gdev!` nel tuo `init.el`. Se ti serve un pacchetto aggiuntivo,
dichiaralo in `packages.el`. Dopo `gdev sync`, trovi il modulo in `C-h d m`.
Un modulo che fallisce durante l'attivazione viene segnalato da `gdev doctor`.
I registri GDev pubblicano le sue capacità una volta riuscito il caricamento.
Durante la valutazione di `config.el`, `gdev-module-status` restituisce
`loading`. Usa `gdev-register-after-module` per le operazioni che devono
vedere il modulo `active` e i suoi nuovi gestori. Se annulli un tentativo
durante la valutazione, resta disponibile l'esito precedente.

Le azioni di un modulo possono comparire in **Comandi** e in **Strumenti › Moduli**
con una sola dichiarazione in `config.el`. Usa un identificatore del modulo,
il nome del gruppo, un’icona in `icons/` e i comandi interattivi già definiti.

```elisp
(gdev-set-tool-actions 'note-di-lavoro "Note di lavoro" "notes"
  ["Apri le note…" mie-note-apri]
  ["Registra una voce…" mie-note-registra :visible (derived-mode-p 'org-mode)])
```

I predicati facoltativi `:visible` e `:active` si valutano nella vista in uso.
Le azioni locali di una vista possono usare `gdev-context-items` e i linguaggi
continuano a pubblicare le proprie scorciatoie tramite `gdev-localleader`.

Per provare un profilo con configurazione, cache e sessioni proprie:

```sh
gdev --profile laboratorio install
gdev --profile laboratorio emacs
```

Una configurazione personale già esistente può attivare i nuovi moduli
copiando le voci desiderate da [templates/init.el](../templates/init.el).

## Tieni in ordine l'installazione

| Azione | Comando |
| --- | --- |
| Allineare i pacchetti ai moduli attivi | `gdev sync` |
| Rigenerare il codice intermedio del nucleo, dei moduli attivi e dei file privati | `gdev compile` |
| Compilare anche il nucleo e i moduli attivi in codice nativo | `gdev compile --native` |
| Aggiornare i sorgenti e i pacchetti | `gdev upgrade` |
| Preparare un avvio da una revisione precedente | `gdev rollback [REVISIONE]` |
| Controllare strumenti e grammatiche | `gdev doctor` |
| Aggiornare l'ambiente di Emacs quando lo apri dal Dock | `gdev env` |
| Misurare i tempi di avvio | `gdev bench` |
| Rigenerare la mappa dei tasti | `gdev docs` |

GDev usa fino a quattro processi per la compilazione nativa e per le
grammatiche indipendenti. Imposta `GDEV_JOBS=1` per eseguire queste operazioni
una alla volta.

`gdev help` elenca i comandi e le opzioni. I pacchetti, la cronologia e
le sessioni salvate risiedono in `~/.local/state/gdev-emacs`.

Per usare GitHub da HitHub, apri **HitHub › Account › Accedi a GitHub**. Le istruzioni per salvare le
credenziali nel Portachiavi di macOS sono nelle sezioni [Hit e HitHub](workflows.md#hit-e-hithub)
e [Agenti](workflows.md#agenti).
