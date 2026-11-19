# Org GDev

Org GDev deriva da Org 9.8.10, revisione `80c431fe0c59bb6b6c4d05ad2d4d279f34b5fcd5`, distribuita da [GNU ELPA](https://elpa.gnu.org/packages/org-9.8.10.tar). SHA-256 dell'archivio originale `890a9dd5c4f1d279f6ed0b3d10670d796aaccb7fdc71a2a665cd153bec463f1d`.

GDev ha modificato il fork il 15 novembre 2026. I sorgenti `org-agenda.el` e
`org.el` adattano all'italiano il selettore dei comandi, le viste, i menu e
le richieste dell'Agenda. Le etichette di visualizzazione usano
`org-agenda-state-labels`. La descrizione del pacchetto è in italiano.
L'integrazione iniziale in GDev-Emacs è a cura di Giacomo Picchiarelli
e risale al commit `536697d`.
GDev ha rigenerato `org-loaddefs.el` e aggiunto `org-autoloads.el`.
Dal 15 novembre 2026, il fork raccoglie le voci dell'Agenda per file e
unisce i risultati in un solo passaggio. Calendario, attività, ricerca,
etichette e diario conservano l'ordine originale delle voci.

Il codice è distribuito con la licenza GPL-3.0 o successiva in [COPYING](COPYING).
I manuali originali sono distribuiti sotto GNU FDL 1.3 o successiva e
conservano gli avvisi nelle rispettive [fonti](doc/).
I file `chicago-author-date.csl` e `locales-en-US.xml` sono inclusi con le
attribuzioni originali del progetto Citation Style Language sotto
[CC BY-SA 3.0 Unported](https://creativecommons.org/licenses/by-sa/3.0/).
Gli avvisi originali sono in [etc/csl](etc/csl/README).
