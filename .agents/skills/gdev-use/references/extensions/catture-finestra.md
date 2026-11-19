<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Catture della finestra nativa per la documentazione

Usa questa procedura quando servono immagini di GDev su macOS per il
README o una guida. Una cattura della finestra nativa attesta disegno,
caratteri e colori reali; il terminale e il batch non li mostrano.

## Avvia la finestra

1. Avvia l'istanza con
   `open -n -a /Applications/Emacs.app --env GDEV_USER_DIR=… --env GDEV_STATE_DIR=… --args --init-directory RADICE`.
   Un Emacs lanciato direttamente dalla shell eredita i permessi di
   privacy (TCC) del processo padre. `screencapture` richiede inoltre il
   permesso Registrazione schermo per Emacs: se manca, usa lo strumento
   di cattura per finestra dell'agente, che legge la finestra anche in
   secondo piano.
2. Fissa la dimensione con `(set-frame-size nil 1360 850 t)` e
   `(set-frame-position nil 80 60)`, così le immagini chiara e scura
   coincidono al pixel.
3. Lo schermo bloccato o spento fa fallire la cattura. Controlla lo stato
   della sessione grafica prima di insistere e tieni acceso lo schermo con
   `caffeinate -d -t SECONDI` per la durata del lavoro.

## Componi la scena

- Prepara lo stato con i comandi dell'editor, come in
  [Debug guidato](debug-guidato.md). Riporta il fuoco nella finestra
  principale con `(select-window (gdev-layout-editor))` e svuota l'area
  dei messaggi con `(message "")` subito prima di catturare.
- Cambia tema con `(gdev-ui-set-appearance 'light)` o `'dark`: non salva
  le preferenze. Cattura la stessa scena in entrambi i temi senza altri
  comandi in mezzo.
- Il puntatore reale compare nell'immagine e un clic dell'agente lo
  sposta. Dopo i clic parcheggialo sulla barra del titolo e togli quella
  zona in post-produzione riempiendo ogni riga con il colore campionato
  poco a sinistra. Un clic sintetico sulla barra del titolo può arrivare
  a Emacs come `<nil> <mouse-1>`: svuota poi l'area dei messaggi.
- Esamina ogni cattura come un utente: valori troncati, righe a capo,
  indicatori sovrapposti nel margine, messaggi in inglese, schede aperte
  per errore. Correggi il modulo responsabile, ricarica la definizione
  nell'istanza e ripeti la cattura.

## Pubblica

Converti con `cwebp -q 88 -m 6` in `docs/assets/` e usa un elemento
`<picture>` con `prefers-color-scheme: dark` per la variante scura,
larghezza esplicita e testo alternativo in italiano che descrive lo stato
mostrato. Indica nel testo che si tratta di catture della finestra nativa.
Conserva soltanto le immagini pubblicate.
