<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Linguaggi e operazioni nel contesto del progetto

La segnalazione su ChitarraTune ha evidenziato tre interruzioni del flusso:
Swift assente dalla configurazione privata lasciava i file senza modalità;
i nuovi linguaggi non pubblicavano il prefisso comune letto da Comandi;
il progetto Xcode non era riconosciuto dalle operazioni del progetto.
Il ripiego sull'esecuzione del singolo file poteva quindi chiedere
salvataggio e programma anziché compilare l'applicazione.

## Responsabilità e ciclo di vita

`gdev-auto-modules` associa i documenti ai 20 fornitori di linguaggio
distribuiti. L'attivazione precede la costruzione della modalità, i suoi
hook e la colorazione. Le dichiarazioni personali restano permanenti;
le associazioni personali dei file prevalgono sui ripieghi distribuiti.
Le librerie caricate rimangono nella cache di Emacs. Lo stato temporaneo
comprende proprietari, gestori, controlli, comandi, associazioni dei file,
hook e registrazioni differite del modulo.

Ogni documento possiede una concessione. Più documenti e processi attivi
condividono il modulo. Un annullamento della chiusura conserva la concessione;
un cambio di modalità la rilascia. La sentinella del processo conserva
la concessione di compilazione indipendentemente dalla vita del buffer
di output. L'ultimo proprietario ritira le registrazioni ancora possedute,
preservando quelle preesistenti o sostituite successivamente. Gli effetti
differiti verificano che l'attivazione sia ancora valida.

`gdev-language-modes` pubblica il prefisso locale quando manca, usando i
comandi e i gestori comuni. Menu, tasti e Comandi leggono la stessa mappa.
In una finestra che non contiene il riquadro, Menu apre la ricerca dei
comandi. Nessuna nuova vista o faccia è necessaria.

`gdev-xcode` legge metadati locali e produce un profilo per `gdev-launch`.
La lettura delle viste usa l'indice in memoria, senza interrogare Xcode.
L'apertura di un documento o un'azione esplicita aggiorna i metadati.
I profili personali prevalgono. Il motore esistente gestisce compilazione,
test e seguiti asincroni nello spazio di origine; un'uscita diversa da zero
blocca il seguito. Non si introduce un secondo coordinatore dei processi.

## Costi e verifiche

L'indice dei proprietari usa tabelle hash; acquisizioni e rilasci ordinari
hanno costo atteso costante. Attivazione e ultimo rilascio confrontano i
registri in tempo lineare rispetto alle voci osservate, senza scansioni
del repository. La mappa locale eredita la mappa della modalità senza
copiarla. Il catalogo ha dimensione fissa. XML e contenitori Xcode vengono
letti soltanto all'apertura e nelle azioni esplicite, senza processi durante
la consultazione dei comandi.

Le prove mirate coprono aperture normali e primo file all'avvio, colori
Swift, condivisione, riapertura, annullamento, errori, attivazioni annidate,
callback tardive, prefissi personali e tutti i fornitori del catalogo.
Le prove Xcode usano processi reali con programmi finti per attraversare
il comando pubblico, gli argomenti con spazi, le sentinelle e il blocco
dell'avvio dopo un errore. Nessun programma finto apre applicazioni.

La compilazione reale di ChitarraTune con Xcode ha prodotto
`build/gdev/Build/Products/Debug/ChitarraTune.app`. L'applicazione non è
stata avviata. La destinazione automatica verificata è macOS; destinazioni
diverse richiedono `gdev-xcode-destination` o un profilo personale.
Più schemi e prodotti non convenzionali possono richiedere un profilo
esplicito. Il debug generato usa LLDB e il percorso convenzionale del
prodotto: non è stata eseguita una sessione di debug dell'applicazione.

I requisiti autorevoli sono `GDEV-P10` e `GDEV-P11`, collegati alla
procedura `GDEV-VERIFY` e al contratto di autoverifica. La lavorazione è
`.gdev-assurance/work/automatic-project-context.eld`.
Le evidenze della consegna risiedono in
`.gdev/assurance/reports/automatic-project-context/`.

La verifica grafica nella finestra dell'utente non è stata eseguita:
l'utente ha chiesto di non interrompere il suo lavoro. Le prove in batch
e la compilazione reale attestano percorsi distinti dalla validazione
manuale dell'esperienza grafica. Non producono approvazioni umane.
