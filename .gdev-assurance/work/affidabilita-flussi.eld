;;; affidabilita-flussi.eld --- Recupero e verifica dei flussi operativi -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :title "Affidabilità dei flussi, recupero e verifica nativa"
 :type bugfix
 :objective "Correggere i problemi riprodotti nell'analisi: conservazione dei comandi personali, diagnosi dei test, runtime coerente, avvio reattivo e recupero degli spazi; rendere eseguibili le verifiche native e i casi prima saltati."
 :scope "Bootstrap macOS e caricamento di GDev dall'icona Emacs sugli altri Mac; scoperta ed esecuzione dei test JavaScript e TypeScript; ambiente della shell; checkpoint della sessione; CI con avvisi e ingresso grafico reale; correzioni del lavoro voce già presente, Earwig nel fork locale e riconoscimento facoltativo con Whisper.cpp, secondo la scelta finale della persona."
 :requirements ("GDEV-P06" "GDEV-P07" "GDEV-P09" "GDEV-P10" "GDEV-P11" "GDEV-P12" "GDEV-P13" "GDEV-P14" "GDEV-P15" "GDEV-Q01" "GDEV-Q02" "GDEV-Q03" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07")
 :inputs ("AGENTS.md" ".github/workflows/ci.yml" "bin/gdev-bootstrap-macos"
          "bin/gdev-startup-check.el" "lisp/gdev-cli.el" "lisp/gdev-install.el"
          "lisp/gdev-env.el" "lisp/gdev-core.el"
          "lisp/gdev-workspaces.el" "lisp/gdev-project-types.el"
          "modules/ui/workbench/gdev-project-view.el" "modules/ui/workbench/gdev-test-catalog.el"
          "modules/lang/javascript/config.el" "test/gdev-test.el"
          "lisp/gdev-voice-backend.el" "lisp/gdev-voice-audio.el"
          "bin/gdev-voice-prepare.py" "bin/gdev-voice-models.json" "test/gdev-voice-contract-test.py"
          "test/gdev-voice-audio-test.el" "test/gdev-operational-recovery-test.el"
          "test/gdev-test-discovery-recovery-test.el" "test/gdev-install-test.el"
          "test/gdev-gui-startup-test.py" "test/gdev-gui-startup-check.el"
          "test/gdev-gui-startup-runner-test.py" "test/gdev-cli-contract-test.py"
          "docs/configurazione.md" "docs/workflows.md" "docs/interfaccia.md")
 :prerequisites ("Analisi del 21 novembre 2026 con riproduzioni isolate dei difetti e compilazione separata della base 505656f"
                 "Mandato dell'utente: Procedi con tutti i miglioramenti e le correzioni. Esecutore: Codex; ambito: i sei miglioramenti e le correzioni individuati nell'analisi."
                 "Preservare il lavoro voce già presente e distinguere le verifiche batch, native e grafiche; nessuna revisione umana attribuita implicitamente")
 :owner "Manutentori di GDev e Codex su mandato dell'utente"
 :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets nil
 :acceptance ("Un comando personale gdev preesistente non viene sovrascritto dal bootstrap"
              "Dopo l'installazione l'ingresso grafico pubblicizzato carica GDev anche su un altro Mac, conservando le configurazioni Emacs precedenti e verificando la precedenza effettiva dei file di avvio"
              "Un rilevamento test fallito conserva la diagnosi e permette apertura del registro e ripetizione, senza applicare risultati annullati o superati"
              "F6 e riquadro Test scelgono lo stesso runtime dai manifesti e dalle scelte di progetto"
              "L'avvio grafico non attende indefinitamente una shell e l'aggiornamento dell'ambiente è annullabile e coerente"
              "Il checkpoint conserva cambiamenti di schede, cartelle e disposizione anche a bozze invariate senza riscrivere testo inutilmente"
              "La CI conserva gli avvisi del compilatore e verifica un'istanza grafica reale isolata con caricamento nativo"
              "La compilazione e i test sono eseguiti sul codice finale; i prerequisiti dei casi precedentemente saltati sono preparati e gli eventuali limiti residui sono espliciti")
 :artifacts ("docs/assicurazione/generati/project.md" ".gdev/assurance/reports/reliability.json")
 :revisions ("Scelta finale esplicita del 21 novembre 2026: Whisper.cpp, con meno dipendenze. Sostituisce la variante Python del riconoscitore; Earwig resta il fork locale GDev. Nessun runtime PyTorch e nessun download implicito."
             "L'autorizzazione riguarda l'esecuzione degli interventi; approvazione della revisione finale e consolidamento restano decisioni distinte."
             "Estensione richiesta dall'utente: Aggiusta anche il fatto che quando installo gdev su altro Mac, l'icona di emacs non mi carica mai l'ambiente, mi torna quello standard. Decisione della persona, esecuzione Codex; nessuna modifica alla sessione personale aperta."
             "Ulteriore mandato: il modello dove si trova? è su github? In tal caso usa il mio forkato. Distinguere pesi e sorgente del riconoscitore; usare effettivamente il fork, senza download impliciti all'avvio."
             "Chiarimento vincolante: Usa il mio fork di whisper.cpp. Fork verificato gipidevdor/whisper.cpp, parent ggml-org/whisper.cpp, MIT, revisione 5eaee0cc9024eb9e9a99469199920c8b7f5cb9ec; conservare GGML e motore C++."))
