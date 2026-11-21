;;; ergonomia-autoconfigurazione.eld --- Operazioni automatiche del progetto -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :title "Ergonomia operativa e autoconfigurazione della compilazione"
 :type bugfix
 :objective "Aprire una cartella e usare le operazioni del progetto con riconoscimento, preparazione, esecuzione reale ed errori recuperabili governati da un contratto comune."
 :scope "Riconoscimento delle radici e dei sistemi distribuiti; modulo Make; scelta e conservazione di obiettivi e variabili; ambiente e prerequisiti; configurazione e compilazione; menu, tastiera, pannello operativo e riscontri. Primo avvio macOS con ingresso dedicato e riscontro della distribuzione effettivamente caricata. Controllo tematico delle integrazioni presenti, con modelli finiti e prove di contratto."
 :requirements ("GDEV-P01" "GDEV-P06" "GDEV-P07" "GDEV-P09" "GDEV-P10" "GDEV-P11" "GDEV-P12" "GDEV-P13" "GDEV-P14" "GDEV-Q01" "GDEV-Q03" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07")
 :inputs (".gdev-project.eld" "lisp/gdev-project-types.el" "lisp/gdev-project-operations.el"
          "lisp/gdev-auto-modules.el" "lisp/gdev-formal.el" "lisp/gdev-lib.el" "lisp/gdev-env.el"
          "lisp/gdev-launch.el" "lisp/gdev-compilation.el"
          "bin/gdev" "bin/gdev-bootstrap-macos" "bin/gdev-startup-check.el"
          "lisp/gdev-cli.el" "lisp/gdev-install.el"
          "test/gdev-install-test.el" "test/gdev-cli-contract-test.py" "docs/configurazione.md"
          "modules/tools/build/config.el" "modules/tools/build/gdev-make.el"
          "modules/tools/build/gdev-project-control.el" "modules/tools/build/gdev-mise.el"
          "modules/lang/python/config.el" "test/gdev-make-test.el"
          "test/gdev-project-operations-test.el" "test/gdev-project-bdd-test.el"
          "modules/ui/workbench/gdev-project-view.el" "modules/ui/workbench/gdev-workbench-operations.el"
          "modules/ui/workbench/gdev-menu.el" "lisp/gdev-handlers.el"
          "test/gdev-test.el" "test/gdev-tools-test.el" "test/gdev-cmake-test.el" "test/gdev-workbench-operations-test.el"
          "docs/workflows.md" "docs/operazioni-progetto.md" "docs/ergonomia-verifica.md")
 :prerequisites ("Mandato dell'utente per controllo e sviluppo dell'ergonomia e dell'autoconfigurazione, con soluzioni generali per ogni tipo di progetto"
                 "Riproduzione nativa: Compila avvia make nella radice corretta ma la toolchain richiesta non viene trovata; il riscontro non propone recupero"
                 "Conservare tutte le modifiche preesistenti del progetto AlacreOS e la sessione nativa; nessuna regola dedicata al suo nome o alle sue architetture")
 :owner "Manutentori di GDev e Codex su mandato dell'utente"
 :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1)
 :snippets nil
 :acceptance ("Il comando Compila identifica un progetto anche da sottocartelle e senza un documento aperto, e avvia un processo reale nella radice corretta"
              "Il motore del progetto governa le regole; la configurazione esplicita ha precedenza sulle deduzioni"
              "Make offre obiettivo predefinito, scelta degli obiettivi e variabili di progetto senza modificare i Makefile"
              "La preparazione necessaria precede la compilazione; errore e annullamento arrestano la catena e liberano le risorse"
              "Prerequisiti mancanti ed esiti negativi sono spiegati con azioni di recupero nel contesto corretto"
              "Un controllo tematico collega i sistemi e le capacità distribuite a osservazioni, stati, azioni e prove; i limiti di inferenza sono espliciti"
              "Invarianti di radice, precedenza, isolamento, freschezza, unicità e conservazione delle scelte sono verificati su modelli finiti e casi reali"
              "Tastiera, menu e pannello condividono il servizio e sono verificati nella finestra nativa"
              "Il bootstrap macOS sceglie il checkout senza domande sul percorso, conserva i profili esistenti e dichiara il primo avvio verificato soltanto dopo il riscontro della finestra GDev")
 :artifacts ("docs/assicurazione/generati/project.md"
             ".gdev/assurance/reports/reliability.json")
 :revisions ("Il documento di ergonomia è un input mantenuto con i sorgenti; gli artefatti della verifica sono le uscite effettive di GDEV-VERIFY."
             "Seconda iterazione: contesto e ambiente delle attività, preparazione Python in un passaggio e aggiornamento comune dopo configurazione; mandato rinnovato dall'utente, esecuzione Codex, nessuna revisione umana dichiarata."))
