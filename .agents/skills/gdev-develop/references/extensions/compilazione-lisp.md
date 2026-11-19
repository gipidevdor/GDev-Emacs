<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Compilazione Emacs Lisp negli audit

Per un controllo architetturale o delle convenzioni Lisp, esegui
`./bin/gdev compile --native -w` in una copia isolata con i moduli da
verificare. Leggi gli avvisi del bytecode e quelli dei processi di
compilazione nativa. I processi separati rivelano dipendenze e legami
dinamici che gli altri moduli possono aver già dichiarato nel processo
che compila il bytecode.

Un `require` nel corpo di una funzione non rende disponibili le macro durante
la compilazione a freddo. Se il ponte usa una macro SQL definita nel nucleo,
sposta quell'ambito in una funzione pubblica del modulo proprietario e dichiara
la funzione nel ponte. Controlla anche l'oggetto nativo: un bytecode compilato
dopo aver caricato tutti i moduli può nascondere questo errore. Esegui una
richiesta reale al ponte dopo l'avvio ordinario per osservare l'esito.

Risali al sorgente di ogni avviso pertinente, anche quando deriva
dall'espansione di una macro di un pacchetto incluso. Conferma le firme
delle API nella versione minima supportata. Dopo una correzione ripeti
la compilazione e verifica il caricamento con l'avvio ordinario.

Nella copia isolata escludi gli artefatti per percorso, non tutti gli elementi
con lo stesso nome. Per esempio, la cartella di stato `tree-sitter/` è
rigenerabile, ma `modules/tools/tree-sitter/` contiene sorgenti necessari.
Confronta tutti i percorsi restituiti da `git ls-files` con la copia, comprese
le modifiche e i file nuovi. Se manca un modulo, ripristinalo e ripeti la
compilazione prima di interpretare gli avvisi o verificare l'avvio.

Un sottoprocesso `--batch -Q -L lisp` non eredita `load-prefer-newer` dal
processo di prova: può caricare bytecode vecchio anche dopo una modifica.
Per una prova sui sorgenti imposta quella variabile prima dei `require`;
per il codice nativo usa una copia compilata aggiornata e l'avvio ordinario.
Tieni distinti i due riscontri quando interpreti un errore di caricamento.

Per confrontare versioni maggiori o minori di Emacs, usa copie dei sorgenti
prive di `.elc` e `.eln` compilati con l’altra versione. Anche un bytecode
più recente del sorgente può cambiare la diagnosi. Compila ciascuna copia
con il proprio eseguibile e verifica quale libreria viene effettivamente
caricata prima di correggere un presunto difetto di compatibilità.
