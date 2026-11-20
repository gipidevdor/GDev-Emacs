;;; sviluppo-agentico.eld --- Gestione formale dello sviluppo agentico -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :title "Gestione formale dello sviluppo agentico"
 :type bugfix
 :objective "Usare il progetto formale per sviluppare GDev, conservando l'identità degli agenti, i controlli reali e le autorizzazioni della persona."
 :scope "Istruzioni degli agenti, scoperta e CLI senza editor, registrazione delle lavorazioni e delle prove, avvio isolato ed etichette italiane del processo."
 :requirements ("GDEV-P01" "GDEV-P06" "GDEV-P07" "GDEV-P09" "GDEV-Q05" "GDEV-Q06" "GDEV-P13")
 :inputs ("AGENTS.md" ".agents/skills/gdev-develop/SKILL.md"
          ".gdev-assurance/project.eld" ".gdev-assurance/self-check.eld"
          "bin/gdev" "bin/gdev-agent-entry.el" "bin/gdev-cli-entry.el"
          "lisp/gdev-agent-interface.el" "lisp/gdev-assurance-actions.el"
          "lisp/gdev-process.el" "lisp/gdev-assurance.el" "lisp/gdev-assurance-labels.el"
          "modules/ui/workbench/gdev-lavorazione.el"
          "docs/agenti.md" "docs/assicurazione/progetto-formale.md"
          "test/gdev-agent-interface-test.el" "test/gdev-cli-contract-test.py"
          "test/gdev-coverage.el")
 :prerequisites ("Mandato dell'utente per lo sviluppo governato e i testi in italiano"
                 "Conservare l'archivio reale e le lavorazioni precedenti senza attribuire approvazioni retroattive")
 :owner "Manutentori di GDev e agente incaricato"
 :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1)
 :snippets nil
 :acceptance ("La scoperta indica il progetto formale e il percorso da seguire per lo sviluppo"
              "Un agente può preparare e verificare una lavorazione senza essere registrato come persona"
              "I passaggi riservati restano rifiutati al canale agente; il mandato effettivo della persona e l'esecutore sono registrati quando si opera tramite il suo profilo"
              "La CLI per agenti funziona con l'editor chiuso e isola le cache prima di caricare librerie"
              "Etichette, messaggi e guide del nuovo flusso sono in italiano e le integrazioni esistenti continuano a funzionare"
              "I risultati dichiarati distinguono lavorazione, prove correnti e autorizzazioni della persona")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions nil)
