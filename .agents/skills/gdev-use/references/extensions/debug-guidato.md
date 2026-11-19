<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Debug guidato da un agente

Usa questa procedura quando devi portare una sessione di debug in uno stato
preciso senza tastiera: per riprodurre un difetto, osservare una pausa o
preparare una cattura. Ogni passo usa i comandi dell'editor, quindi vale
anche come prova del flusso visibile.

## Prepara l'istanza

1. Avvia un'istanza dedicata con `server-name` distinto nella
   configurazione utente di prova, così il socket non si confonde con la
   sessione dell'utente. Valuta le espressioni con
   `emacsclient -s SOCKET --eval`, oppure con `./bin/gdev agent live SOCKET`
   per stato e aperture.
2. Per C e C++ il server di linguaggio clangd segnala errori falsi, per
   esempio `std` non dichiarato, se manca un database di compilazione.
   Registra la compilazione del profilo con Bear dentro una cartella già
   esclusa dal controllo di versione, per esempio
   `bear --output build/compile_commands.json -- make …`, quindi ricollega
   Eglot con `(eglot-reconnect (eglot-current-server))`. Non scrivere nella
   radice di un progetto con modifiche dell'utente.
3. Scegli il profilo senza prompt:
   `(cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "NOME"))) (gdev-launch-select-profile RADICE))`.

## Porta la sessione allo stato voluto

- Punto di interruzione: visita il documento nella finestra dell'editor,
  vai alla riga e chiama `dape-breakpoint-toggle`. Rileggi
  `dape--breakpoints` per conferma.
- Avvio e prosecuzione: `(with-selected-window (gdev-layout-editor) (call-interactively #'gdev-debug-dwim))`.
- Passi: `(dape-next CONN)` con
  `CONN = (gdev-debug-workspace-connection (gdev-workspace-state-id))`.
- Riavvio: `(gdev-debug-session-command #'dape-restart CONN)`.
- Stato: interroga `(dape--state CONN)` e `(dape--state-reason CONN)` a
  intervalli brevi. Dopo un riavvio attendi prima un cambio di stato o di
  `dape--thread-id`: la vecchia pausa resta visibile finché l'adattatore
  non conferma.
- Console: `comint-clear-buffer` nel buffer `*Debug · Console*` svuota la
  cronologia; per valutare un'espressione inseriscila dopo il prompt e
  chiama `comint-send-input`.
- Ispezione: imposta `gdev-debug-inspector--page` su `stack`, `locals` o
  `watches` e chiama `gdev-debug-inspector--draw-visible`. Per aprire un
  nodo preferisci il clic sul pulsante, che prova anche il puntatore.

## Recupera dagli imprevisti

- Un prompt rimasto aperto blocca le valutazioni successive. Controlla
  `(minibuffer-depth)` e il testo del minibuffer; esci con
  `(run-at-time 0 nil #'top-level)`. `abort-minibuffers` lanciato da un
  timer fallisce perché non è nel minibuffer.
- Se lo stato cambia senza tuoi comandi, leggi `(recent-keys t)` e
  cerca eventi di puntatore, rotella o tasti: la finestra può essere in
  uso. Chiedi di non toccarla fino al termine e ricostruisci lo stato
  dall'inizio invece di correggerlo a metà.
- Un comando che apre una vista temporanea, come `eldoc` con argomento,
  cambia la disposizione: chiudi la vista e rileggi le finestre prima di
  proseguire.
