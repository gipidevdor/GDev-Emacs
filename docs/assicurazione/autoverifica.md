# GDev come banco di prova di se stesso

La distribuzione applica ai propri sorgenti il contratto
[project.eld](../../.gdev-assurance/project.eld);
[self-check.eld](../../.gdev-assurance/self-check.eld) ne richiama gli identificativi. Ogni requisito GDEV-P/GDEV-Q
lega responsabilità, sorgenti e prove eseguibili; i riferimenti indicano
edizioni e obiettivi del catalogo già usato dal Workbench. Gli obiettivi
`@document` sono criteri documentali originali GDev, riferiti alla scheda
bibliografica. Non riproducono né sostituiscono il testo degli standard.

| Requisito | Proprietà osservabile |
| --- | --- |
| GDEV-Q01 | Dipendenze senza cicli, dominio separato dalle viste e persistenza nel proprietario. |
| GDEV-Q02 | Un guasto a ogni istruzione SQL lascia tutte o nessuna delle scritture; le risorse si chiudono anche dopo annullamento. |
| GDEV-Q03 | Sequenze ripetibili su due spazi rispettano un modello indipendente, aggiornamenti atomici e ripristino. |
| GDEV-Q04 | Le connessioni di lettura rifiutano scritture; la verifica rileva una catena alterata. |
| GDEV-Q05 | I contratti dei fork funzionano sulla versione minima e su quella corrente di Emacs. |
| GDEV-Q06 | Il motore registra e valuta i propri artefatti e rileva una loro modifica successiva alla prova. |

La CI esegue la suite ERT, compilazione, avvio, contratti e coperture
richiesti dal progetto. Esegue inoltre la campagna di affidabilità e usa
il suo rapporto nell'autoverifica degli standard. Un rapporto assente,
incompleto, negativo o riferito a sorgenti diversi non soddisfa il controllo.

```sh
python3 test/gdev-reliability-test.py --mutations --output /tmp/gdev-affidabilita.json
GDEV_SELF_ASSURANCE_REPORT=/tmp/gdev-affidabilita.json \
  emacs --batch -Q -l early-init.el -l test/gdev-test.el \
  --eval '(ert-run-tests-batch-and-exit "^gdev-test-self-assurance-")'
```

Con `EMACS=/percorso/emacs` si sceglie l'eseguibile anche per i figli.
`--seed N --steps N` ripete una sequenza; in caso di differenza il rapporto
riporta seme, passo e prefisso delle operazioni. La CI usa otto semi fissati.

Le prove SQL iniettano errori al confine fra Lisp e SQLite, una volta sola
e poi in modo persistente. I casi di arresto terminano soltanto processi
figli isolati con SIGKILL, prima e dopo il commit, in modalità DELETE e WAL.
Un lettore SQLite indipendente controlla contenuto completo, integrità e
chiavi esterne dopo la riapertura. Non si simulano guasti fisici del disco
o del gestore di memoria di SQLite. Le mutazioni cambiano copie temporanee
dei sorgenti: errori di avvio e sintassi non contano come difetti intercettati.

L'esercizio del ciclo con approvazioni usa persone **simulate, dichiarate
come fixture di test**, in un archivio temporaneo. Non approva la distribuzione
né attribuisce a CI o agenti il ruolo di una persona reale. L'adozione del
progetto, la scelta effettiva degli standard, le revisioni e le ricevute
firmate continuano a passare dai comandi normali e dai loro controlli.
Il risultato automatico documenta le proprietà provate; resta distinto
da un'approvazione umana e da una dichiarazione di conformità normativa.

La strategia riprende l'uso congiunto di regressioni, guasti, arresti,
oracoli indipendenti e mutazioni descritto da
[SQLite](https://www.sqlite.org/testing.html), con un perimetro proporzionato
a GDev. La copertura delle righe rimane un controllo aggiuntivo.

La [scheda operativa](../../.gdev-assurance/work/governed-development.eld) identifica il lavoro di questa evoluzione. Il ciclo completo con persone simulate resta isolato nei test; l’archivio reale non riceve approvazioni sintetiche.
