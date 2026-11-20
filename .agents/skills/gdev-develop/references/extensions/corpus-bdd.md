<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Corpus di comportamenti e BDD

Usa questo riferimento quando importi fixture o aggiungi scenari di editing,
parsing, evidenziazione, completamento, navigazione o refactoring.

Il punto di ingresso è [test/behavior/README.md](../../../../../test/behavior/README.md).
Il corpus è già caricato da `test/gdev-test.el`: selezionalo con il prefisso
`gdev-test-behavior-`, senza ricaricare lo stesso file. Le prove obbligatorie
usano `GDEV_TEST_REQUIRE_BEHAVIORS=1`; un prerequisito mancante deve fallire.

Conserva gli input e gli oracoli originali, revisione completa, SHA-256 e
licenza di ogni file. Registra una traduzione esplicita quando Emacs usa
coordinate, facce, selezioni o comandi diversi. Non confondere una risposta
LSP simulata con la verifica del server reale. Per Gherkin usa i fork locali
Gherkin GDev (Ecukes) e BDD Elisp GDev (Buttercup), tramite `test/gdev-bdd.el`.

Copri anche annullamento, errore e pulizia quando l'azione li offre. Un passo
non definito, ambiguo, pendente o ignorato non deve rendere verde la prova.
Verifica la suite insieme alle altre: ganci, timer e variabili locali dei
test precedenti possono rivelare interferenze assenti nell'esecuzione mirata.
Isola anche `auto-mode-alist` e `interpreter-mode-alist` nei casi registrati:
in Emacs 30 l'entrata in alcuni modi Tree-sitter aggiunge associazioni globali.
Ripeti la compilazione nativa dopo modifiche ai fork e verifica il caricamento
a freddo, in una copia isolata. Conserva soltanto le evidenze utili.
