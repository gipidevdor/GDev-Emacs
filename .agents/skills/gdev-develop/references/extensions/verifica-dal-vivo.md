<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Verifica dal vivo e insidie del batch

Usa questa procedura quando una correzione riguarda il disegno o un flusso
che il batch non riproduce del tutto: riga di stato, margini, viste a
larghezza variabile, sessioni di debug o server di linguaggio.

Un'istanza separata può comunque prendere il fuoco e interrompere chi lavora.
Se l'utente chiede di non aprire finestre, usa solo prove in batch e registra
la verifica grafica come non eseguita. Non avviare né riavviare applicazioni
per completare quella verifica.

## Applica la correzione in un'istanza aperta

1. Valuta soltanto le definizioni cambiate, lette dal file:
   ```elisp
   (with-temp-buffer
     (insert-file-contents FILE)
     (goto-char (point-min))
     (condition-case nil
         (while t
           (let ((form (read (current-buffer))))
             (when (and (eq (car-safe form) 'defun) (memq (nth 1 form) NOMI))
               (eval form t))))
       (end-of-file nil)))
   ```
   Ricaricare un intero pacchetto con `load` può ridefinire classi e
   registrazioni ancora in uso. Restituisci l'elenco dei nomi valutati per
   confermare che ogni definizione è stata trovata.
2. Le modifiche a variabili già impostate, come `global-mode-string`, vanno
   applicate a mano nell'istanza: `defvar` e `add-to-list` non sostituiscono
   un valore presente.
3. Riproduci il flusso dalla sua entrata e osserva l'esito nella finestra.
   La valutazione dal vivo non sostituisce compilazione nativa e avvio
   ordinario nella copia di prova.

## Insidie delle prove in batch

- Per ripristinare il fuoco in una riga con più pulsanti, conserva sia
  l'identità della voce sia il comando del pulsante e l'offset al suo interno.
  Il riempimento aggiunto per allineare glifi di larghezze diverse può
  cambiare la lunghezza del testo: verifica che selezione e apertura non si
  scambino dopo due attivazioni consecutive.
- Per misurare un riquadro laterale aprilo dal comando pubblico e ridimensiona
  la sua finestra. `delete-other-windows` non rende unica una side window;
  spostare il buffer nell'editor può inoltre attivare il ripristino del layout.

- Sostituire una primitiva con `cl-letf` può compilare un trampolino nativo
  prima del corpo della prova. Se si contano file o processi creati dal
  comportamento, lega `native-comp-enable-subr-trampolines` a nil nella
  fixture, oppure inoltra le chiamate estranee alle primitive originali.
  Non attribuire al comando le operazioni del compilatore.
  Le chiamate native possono fornire anche gli argomenti opzionali nil:
  nei mock controlla la posizione dichiarata dall'API, non l'ultimo elemento.

- In una finestra nativa i ridisegni possono invocare i costruttori grafici
  durante una prova. Se sostituisci `create-image` o una primitiva di file,
  limita il conteggio ai dati della prova e inoltra le altre chiamate alla
  funzione originale. Un contatore globale può misurare anche l'interfaccia.

- `-Q` salta l'attivazione dei pacchetti. Per verificare il caricamento normale
  di `init.el`, carica prima `early-init.el`, esegui `(require 'package)` e
  `(package-activate-all)`, poi carica `init.el`. Controlla anche l'output:
  un errore di `use-package` può non comparire in `gdev-failed-modules`.
- Anche le sonde brevi con `-Q` devono caricare `early-init.el` prima delle
  librerie, oppure usare `--init-directory` su una cartella temporanea.
  Altrimenti la compilazione automatica può creare `~/.emacs.d/eln-cache`:
  la nuova `~/.emacs.d` prende precedenza su `~/.config/emacs` e l'app si
  riapre senza GDev. Per diagnosticare confronta `user-init-file` nell'avvio
  diretto e nell'avvio con `gdev emacs`. Se la cartella contiene solo cache
  generate, spostala fuori dal percorso di avvio; conserva tutorial e altri
  file creati dalla persona. Non cancellare né sovrascrivere configurazioni
  esistenti.
- Una prova `--eval` dopo il primo file della riga di comando non deve
  eliminarlo prima che `command-line` ne abbia terminato la gestione.
  Verifica lì modalità e comandi; per il rilascio usa un cambio di modalità
  oppure una prova separata di chiusura del buffer.
- Per verificare `kill-buffer-hook`, usa `generate-new-buffer` e rilascialo
  con `unwind-protect`: `with-temp-buffer` inibisce quegli hook e non
  riproduce la chiusura di un documento normale. Controlla anche il valore
  restituito da `kill-buffer` prima di asserire gli effetti della chiusura.
- Per i processi asincroni cattura buffer di output e sentinella prima
  della fine del lavoro. Attendi la pubblicazione del risultato o il
  rilascio delle risorse: `process-live-p` può diventare nil prima della
  consegna della notifica finale. Usa un gate esplicito per ordinare gli
  eventi; se la prova fallisce, termina il figlio e rilascia le sue risorse
  nella pulizia, dopo le asserzioni.
- `after-change-functions` si attiva anche per le sole proprietà del testo.
  Prima di annullare un risultato legato ai caratteri confronta
  `buffer-chars-modified-tick`; prova separatamente testo e facce.
- `format-mode-line` restituisce una stringa vuota senza una finestra
  grafica. Verifica la struttura del formato con un percorritore che segua
  le regole di `mode-line-format`: una lista che inizia con un simbolo è un
  condizionale `(SIMBOLO ALLORA ALTRIMENTI)`, non una sequenza. Per questo
  `(variabile " ")` mostra solo lo spazio; serve `("" variabile " ")`.
- Le variabili automaticamente locali al buffer, come
  `cursor-in-non-selected-windows`, cambiano con `setq` solo nel buffer
  corrente. Per un'impostazione globale usa `setq-default` e verifica il
  valore in un buffer nuovo in un processo separato.
- `test/gdev-test.el` carica già i file di prova: aggiungere `-l` sullo
  stesso file ridefinisce i test e interrompe l'esecuzione. Seleziona i
  test con l'espressione passata a `ert-run-tests-batch-and-exit`.
- Per una sonda caricata con `-l` durante l'avvio ordinario, programma la
  verifica con un timer breve e richiedi esplicitamente i moduli caricati
  solo all'apertura delle viste. La sonda deve produrre un esito e terminare
  l'istanza isolata; un messaggio di avvio non dimostra che sia stata eseguita.
- Per il primo avvio verifica l'ingresso distribuito (`gdev emacs` e l'app
  dedicata), con profilo e stato vuoti. Richiedi il riscontro dell'istanza
  sul checkout, gli errori d'inizializzazione e l'interfaccia effettivamente
  caricata. Prova anche la precedenza di configurazioni Emacs già esistenti.
  Non dedurre il successo della finestra dall'esito dell'installazione e non
  spostare file personali per far funzionare un lanciatore esplicito.
- Per riprodurre l'icona Emacs ordinaria usa `CFBundleExecutable` da
  `Contents/Info.plist`, non il solo `invocation-name`: alcune app riportano
  lì un eseguibile interno specifico dell'architettura. Esegui la prova in
  una HOME temporanea con ingressi oscuranti, verifica il loro backup e
  togli dall'ambiente di lancio le variabili che l'installatore deve
  ripristinare dal Dock. Richiedi i percorsi effettivi di `early-init-file`
  e `user-init-file`, oltre al riscontro del Workbench. In assenza di
  riscontri conserva log e PID avviato, termina solo quella istanza e
  controlla l'eseguibile scelto prima di attribuire il problema ai wrapper.
- Dimostra che una prova di regressione coglie il difetto: ripeti il test
  dopo aver sostituito la funzione corretta con `fset` a `ignore`, o dopo
  aver ripristinato il valore errato, e verifica che fallisca. Per
  ripristinare il comportamento precedente salva `git show HEAD:FILE` in
  una cartella temporanea, valuta da lì le definizioni cambiate con la
  procedura sopra e passa il file con `-l` dopo `test/gdev-test.el`.
- Gli agganci di uscita di Ediff (`ediff-quit-hook`) partono dopo che
  Ediff ha chiuso le sue finestre e il pannello di controllo: lo stato da
  confrontare va letto dallo spazio di lavoro, non dalle finestre.
- Nelle prove di manomissione dell'archivio, ripristina la definizione originale
  dei trigger dopo aver alterato i dati e controlla separatamente schema e
  catena. Il test deve cogliere il dato alterato anche quando i trigger sono
  presenti: la loro sola assenza può nascondere una verifica mancante.

## Percorri tutte le voci visibili

Usa questa procedura quando chi usa l'editor segnala voci di menu, pulsanti
o righe di Comandi che «non portano da nessuna parte».

1. Avvia un'istanza separata con `open -n -a Emacs.app --env
   GDEV_STATE_DIR=… --env GDEV_USER_DIR=… --args --init-directory RADICE`.
   Il `config.el` privato di prova imposta un `server-name` proprio. Non
   usare mai l'istanza di chi lavora.
   Per evitare l'avvio di un server MCP nella prova dichiara
   `(defvar gdev-agent-mcp-autostart)` e imposta
   `(setq gdev-agent-mcp-autostart nil)` nel suo `config.el`.
   La dichiarazione serve anche alla compilazione a freddo della fixture;
   `gdev-mcp-auto-start` non è un'opzione del progetto.
2. Raccogli le voci dalle loro fonti: `gdev-menu-command-items` con
   argomento non nil per la barra, i pulsanti del cruscotto e delle
   Preferenze, le righe di Comandi dopo aver espanso le categorie. Salta
   le intestazioni ▸ e ▾, che aprono e chiudono la categoria.
3. Esegui ogni voce dopo `select-window` sull'editor. `with-selected-window`
   ripristina il fuoco e fa sembrare senza effetto i comandi che spostano
   il fuoco. Confronta il buffer selezionato, i buffer nelle finestre,
   `buffer-chars-modified-tick`, le modalità e i nuovi messaggi.
4. Intercetta le richieste con una funzione in `minibuffer-setup-hook` che
   esce con `throw`. `read-string` e le specifiche `interactive` leggono
   dal C e ignorano le ridefinizioni Lisp di `read-from-minibuffer`.
   Ridefinisci a parte `yes-or-no-p`, `y-or-n-p`, `read-key` e
   `read-key-sequence-vector`.
5. Escludi uscita e riavvio, la rete (HitHub, agenti, macchine remote,
   navigatore), i processi lunghi e la stampa, che apre il dialogo nativo.
   Escludi anche i comandi come root: TRAMP avvia `sudo` e aspetta solo il
   suo processo, quindi l'istanza smette di rispondere al server. Se
   accade, termina il processo `sudo` figlio e usa `kill -USR2` sul
   processo di Emacs per tornare al ciclo dei comandi.
6. Procedi a blocchi di circa 40 voci, con `timeout` su `emacsclient`, e
   salva gli esiti dopo ogni voce. Separa così i tre esiti:
   - un `user-error` in italiano segnala una precondizione mancante;
   - un errore di tipo indica un difetto;
   - una voce senza esito è un difetto se resta attiva.
   Una voce che dipende dal contesto dichiara la condizione con
   `gdev-menu-available` (vedi «Disponibilità» in `docs/interfaccia.md`).
