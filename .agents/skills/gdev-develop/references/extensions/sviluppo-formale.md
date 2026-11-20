<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Progetto formale e mandato degli agenti

Applica questo percorso allo sviluppo del repository GDev e ai progetti
che dichiarano un manifesto formale.

1. Leggi manifesto e archivio con `gdev agente assicurazione RADICE progetto`,
   `elenca` e `valuta ID`. La scoperta indica la presenza del manifesto;
   la consultazione esplicita ne verifica completezza e stato operativo.
2. Apri una lavorazione con `apri TITOLO qualità`, prepara la sua scheda
   versionata e usa `collega-scheda ID PERCORSO` e `collega-progetto ID`.
   Collega requisiti esistenti o definisci quelli nuovi con prove concrete.
3. Registra classificazione e analisi con `avanza ID classificata` e
   `avanza ID in-analisi`. Prima del codice di produzione verifica il
   passaggio ad **Autorizzata**, poi passa a **In lavorazione**.
4. Gli agenti possono operare sul profilo dell'utente quando lui lo richiede.
   Un mandato esplicito riferito alla lavorazione consente di eseguire la
   sua decisione per suo conto. Registra il testo del mandato e l'esecutore
   nella nota del passaggio; il decisore è la persona, l'esecuzione è
   dell'agente. Una decisione autonoma dell'agente conserva il tipo agente.
   Non aggiungere revisioni umane, firme o certificazioni mai avvenute.
5. Dopo il codice finale ricollega scheda e istantanea aggiornate, passa a
   **In verifica** ed esegui la procedura richiesta con
   `esegui-procedura ID PROCEDURA`. Conserva anche errori, interruzioni e
   tentativi superati; non riscrivere l'audit per far apparire un successo.
6. Collega prove native, grafiche e di CI quando pertinenti. Ripeti le prove
   invalidate da modifiche successive. Usa `valuta ID` per leggere ciò che
   manca e `registra-valutazione ID` per conservare l'esito corrente.
7. Riporta identificativo e stato della lavorazione insieme a commit e
   verifiche. **Approvata** e **Consolidata** richiedono le decisioni previste
   dal profilo. Il riferimento consolidato è la **Versione di riferimento**.

Se un comando è rifiutato, leggi il motivo e correggi il presupposto mancante.
Una richiesta di mandato deve riguardare una scheda concreta e riportare il
controllo che la richiede. Usa l'autorizzazione già data nella sessione e
registrala con il suo ambito; non richiederla di nuovo per la stessa azione.

La CLI conserva i codici stabili nei dati JSON e usa nomi italiani nei
comandi e nelle viste. Il canale agente non si promuove cambiando nome.
Il nucleo locale non autentica la persona: per un vincolo esterno servono
ricevute e firmatari effettivamente configurati nel controllo remoto.

In `:tests` collega i nomi effettivamente rendicontati dalla procedura.
Ogni scenario BDD è un caso ERT registrato: il percorso del file Elisp
che lo contiene non costituisce un esito di esecuzione. I controlli di
script usano invece il percorso riportato dall'adattatore che li esegue.
La presenza del file e il successo dei suoi casi sono verifiche distinte.

Quando cambia un modulo dell'assicurazione, esegui anche le entrate
`gdev-coverage-assurance` e `gdev-coverage-assurance-extensions` da
`test/gdev-coverage.el`. Verifica che il selettore della suite strumentata
includa i nuovi casi, anche quando hanno un prefisso diverso. Esercita i
rifiuti prima degli effetti, oltre al percorso riuscito, e conserva il
vincolo del 100% delle righe strumentabili.
