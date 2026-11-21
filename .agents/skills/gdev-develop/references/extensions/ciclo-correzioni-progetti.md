<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Correzioni tra GDev e un progetto esterno

Applica questo ciclo quando un progetto espone cataloghi esterni o usa
agenti, procedure e strumenti di GDev. L'errore appartiene al livello che
governa il contratto violato. Una convenzione locale resta nel progetto;
un difetto comune di percorsi, revisioni, annullamento o diagnosi si corregge
in GDev con una prova su una fixture indipendente dal progetto originale.

1. Leggi scoperta, radice, progetto, scheda e stato della lavorazione.
   Conserva il tipo agente e registra il mandato della persona dove previsto.
   Consulta gli hazard pertinenti nel catalogo autorevole, i requisiti
   collegati e i rischi residui. Distingui difetti, limiti architetturali e
   comportamenti intenzionali del contratto, compresi i rifiuti previsti.
   Un errore osservato non autorizza a cambiare routing, retry, visibilità
   o punti di conferma. Verifica la necessità di una decisione architetturale
   e di campagne dedicate prima di scegliere la correzione. I risultati
   tecnici e l'accettazione del rischio restano separati.
2. Riproduci il minimo caso fallito e conserva input, revisione, esito e
   diagnosi. Le fonti modificate invalidano i risultati precedenti.
3. Correggi il proprietario del comportamento. Aggiungi una regressione che
   fallisce prima della correzione e verifica anche il flusso preesistente.
4. Ripeti il controllo locale, poi il flusso del progetto esterno attraverso
   la stessa entrata CLI/MCP o Workbench. Non usare cataloghi superati né
   modificare gli stati dei gate per eliminare un errore di integrazione.
5. Ripeti finché il controllo riesce o emerge un vincolo esterno concreto.
   Un ciclo che ripete lo stesso errore senza nuove informazioni richiede
   diagnosi e una condizione di arresto, senza reiterazioni illimitate.
6. Registra esiti e limiti sulla revisione finale. Conserva nell'audit i
   tentativi falliti e gli annullamenti; rimuovi solo i file temporanei.

Per i cataloghi leggi `catalogs` nei dati `progetto`. Un elemento `INVALID`
espone `problem` e `recovery` con radice e argv dichiarati dal progetto.
L'argv è un suggerimento visibile, mai un comando eseguito dalla lettura.
Ricontrolla le fonti e l'autorizzazione prima di eseguirlo, quindi rileggi
il progetto. Un catalogo corrente non attesta i gate che contiene.
