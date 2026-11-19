# Lettore PDF di GDev

Il modulo `:tools pdf` usa un [fork locale della vista di GNU Emacs DocView
30.1](../../../vendor/elpa/gdev-doc-view-30.1/gdev-doc-view.el). È attivo
nei nuovi profili. In un profilo esistente aggiungi `pdf` sotto `:tools`
nel tuo `init.el`, esegui `gdev sync` e riavvia.

Su macOS apri un PDF da **File › Apri file…**, con `C-x C-f` o dall’albero.
In un progetto LaTeX, **Apri PDF** (`C-c C-v`) apre il risultato compilato.
Il riquadro destro e il menu contestuale mostrano le azioni disponibili.

| Tasto | Azione |
| --- | --- |
| `n` / `p` | Pagina successiva o precedente |
| `g` | Vai a una pagina |
| `SPC` / `S-SPC` | Scorri e passa alla pagina adiacente al bordo |
| `+` / `-` | Ingrandisci o riduci |
| `0` / `W` | Adatta la pagina o la larghezza |
| `C-s` / `C-r` | Cerca in avanti o indietro. Con `C-u` inserisci una nuova espressione |
| `C-c C-t` | Leggi il testo della pagina. Con `C-u` mostra tutto il PDF |
| `C-c n p` | Annota la pagina in Org e conserva il collegamento |
| `u` | Sblocca un PDF protetto |
| `r` | Ricarica il documento dal disco |

Le pagine vengono rasterizzate su richiesta. Ogni finestra conserva pagina
e zoom. I PNG restano in una cache temporanea per l'apertura corrente.
Il lettore compila il proprio eseguibile PDFKit al primo uso con gli
strumenti a riga di comando di Xcode e lo riusa nelle aperture successive.
PDFKit legge il testo incorporato. Le scansioni senza testo rimangono
consultabili come immagini. Nel terminale e sulle altre piattaforme Emacs
usa DocView con i convertitori disponibili.
