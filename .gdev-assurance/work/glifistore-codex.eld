;;; glifistore-codex.eld --- Progetto esterno e agenti -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "GlifiStore in GDev e supporto Codex" :type feature
 :objective "Collegare cataloghi autorevoli esterni, procedure di GlifiStore e sessioni Codex al progetto formale; trasformare gli errori riproducibili in regressioni generali."
 :scope "Cataloghi esterni, progetto GlifiStore, operazioni CMake, CLI/MCP e integrazione Codex"
 :requirements ("GDEV-P01" "GDEV-P04" "GDEV-P06" "GDEV-P07" "GDEV-P08" "GDEV-P09")
 :inputs ("AGENTS.md" "docs/agenti.md" "docs/operazioni-progetto.md" "docs/assicurazione/progetto-formale.md")
 :prerequisites ("Mandato dell'utente: Procedi, sul prompt di integrazione completo. Estensione: gdev tragga beneficio generico da ogni errore, metti in loop le correzioni per entrambi i progetti rispettando regole. Esecutore Codex."
                 "Conservare modifiche concorrenti, identità degli attori e autorità dei gate di GlifiStore")
 :owner "Manutentori GDev e GlifiStore" :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets nil
 :acceptance ("GlifiStore ha un manifesto valido e procedure eseguibili"
              "I cataloghi esterni mantengono identificativi, stati, fonti e impronte"
              "Codex usa il contesto di progetto e il server MCP corretto"
              "Errori, revisioni superate e annullamenti hanno prove di regressione"
              "Gli esiti sono collegati alla revisione verificata e le decisioni umane restano riconoscibili")
 :artifacts nil :revisions ("Il mandato autorizza l'implementazione; revisione umana e consolidamento restano passaggi distinti."))
