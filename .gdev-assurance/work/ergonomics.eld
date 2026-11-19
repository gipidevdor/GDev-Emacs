;;; ergonomics.eld --- Ergonomia e reattività -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "Ergonomia e reattività del Workbench" :type refactor
 :objective "Ridurre attese e ingombro della consultazione senza indebolire le verifiche formali."
 :scope "Inventario delle entrate, viste, navigazione, filtri, processi e prestazioni del profilo distribuito"
 :requirements ("GDEV-P07" "GDEV-Q01" "GDEV-Q03" "GDEV-Q04" "GDEV-Q05" "GDEV-Q06")
 :inputs ("docs/ergonomia.md" "docs/interfaccia.md")
 :prerequisites ("Confronto sugli stessi dati e sulle stesse dimensioni" "Archivio e configurazione privati preservati")
 :owner "codex:ergonomics" :priority must :depends-on ()
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets ()
 :acceptance ("Le sezioni informative non eseguono valutazioni né caricano la storia completa"
              "Controlli e letture complete mantengono la verifica corrente delle sorgenti"
              "Navigazione, filtri e pagine restano accessibili e coerenti nelle viste strette"
              "Risposte anticipate, avvii falliti e risultati superati lasciano una vista utilizzabile"
              "Suite e avvio positivi sulle versioni supportate; misure prima e dopo conservate")
 :artifacts ("docs/assicurazione/generati/project.md") :revisions ())
