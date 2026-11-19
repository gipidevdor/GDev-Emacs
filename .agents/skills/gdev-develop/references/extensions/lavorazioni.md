<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Azioni delle lavorazioni

Il motore vive in [gdev-lavorazione.el](../../../../../modules/ui/workbench/gdev-lavorazione.el).
Il [Workbench](../../../../../modules/ui/workbench/config.el) registra i
comandi dell'interfaccia e carica il motore a richiesta. Il percorso
ordinario di `gdev compile` include il suo bytecode.

1. Individua il modulo che governa l'azione e riusa il suo comando
   o la sua funzione di dominio. Per esporla alle lavorazioni usa
   `gdev-lavorazione-registra` con un nome stabile, una descrizione, uno
   schema ordinato e una funzione locale sincrona. La funzione riceve il
   contesto e i valori nell'ordine dichiarato. I tipi attuali sono
   `testo`, `testo-non-vuoto`, `intero-positivo` e `percorso`.
   Dichiara `:apre-documento t` se il passo imposta il documento nel
   contesto, o `:richiede-documento t` se dipende da un'apertura
   precedente. Il riquadro usa queste dipendenze per filtrare il
   catalogo e respingere ordinamenti non validi.
   Usa `:modulo` per indicare il nome del componente nel catalogo.
   Registra le azioni nel modulo proprietario con
   `with-eval-after-load 'gdev-lavorazione` per conservare il
   caricamento a richiesta. Usa `gdev-lavorazione-documento` e
   `gdev-lavorazione-radice` per leggere il bersaglio effettivo.
   Per un argomento con completamento contestuale, registra un
   `:lettore` che riceve nome, tipo, valore iniziale e prefisso del piano.
   Mantieni il controllo del tipo nel motore e ricontrolla a runtime
   ciò che dipende dal documento effettivo. Il lettore degli snippet
   usa `gdev-lavorazione-file-previsto` e propone chiavi senza aprire
   i file di destinazione.
2. Prima di modificare lo stato, verifica le precondizioni sul bersaglio
   effettivo. Mantieni le protezioni della cartella locale e delle bozze.
   Il motore risolve il catalogo prima di eseguire il primo passo ed
   espone lo stesso schema nell'autore guidato. Conserva il significato
   dei nomi già distribuiti. Se il contratto cambia in modo
   incompatibile, introduci un nuovo nome o una versione del formato
   con una migrazione esplicita.
3. Tratta i piani come dati. Usa il registro per risolvere le azioni.
   Evita valutazione di Lisp, esecuzione di stringhe come comandi e
   chiamate arbitrarie a comandi interattivi. Rispetta il contratto
   sincrono senza richieste di input nei passi. Il limite attuale è
   di 128 passi e la verifica completa avviene quando si legge il piano.
4. Verifica il nuovo nome nel catalogo, un piano valido e un piano con un
   passo incompatibile. Controlla che la verifica non modifichi i file,
   che un errore di esecuzione impedisca i passi successivi e che un piano
   già distribuito funzioni ancora. Per modifiche al riquadro, verifica
   che passi non validi e sorgenti modificati altrove lascino il JSON
   intatto. Mantieni i pulsanti e il menu contestuale collegati alle stesse
   azioni. Verifica il passo selezionato con il fuoco sui pulsanti e la
   chiusura con la × del Workbench, lasciando aperto il sorgente. Usa i test in
   [gdev-lavorazione-test.el](../../../../../test/gdev-lavorazione-test.el).
5. Compila il sorgente in una cartella temporanea con gli avvisi abilitati.
   Carica il bytecode in una sessione isolata, apri il file
   `.lavorazione`, esegui `C-c C-c` e controlla l'effetto osservabile
   sul documento di prova. Riporta separatamente l'esito di compilazione,
   apertura ed esecuzione.

L'[interfaccia per agenti](../../../../../modules/ui/workbench/gdev-lavorazione-agent.el)
legge lo stesso registro attivo e modifica il sorgente già aperto
attraverso `gdev-lavorazione--scrivi`. Per modifiche al collegamento,
prova il percorso MCP → CLI → socket nell'istanza isolata. Verifica un
piano invalido, una revisione superata, il ridisegno della vista e il
salvataggio esplicito. Il contratto pubblico è in
[GDev-Emacs per agenti](../../../../../docs/agenti.md).
