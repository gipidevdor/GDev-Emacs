;;; governed-development.eld --- Sviluppo governato di GDev -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "Piattaforma di sviluppo governato"
 :type feature
 :objective "Realizzare progetti formali, tassonomie tracciate, modelli, procedure eseguibili e prove riproducibili; applicarli alla distribuzione."
 :scope "Nucleo di assicurazione, lavorazioni, Workbench, CLI/MCP, fork e CI"
 :requirements ("GDEV-P01" "GDEV-P02" "GDEV-P03" "GDEV-P04" "GDEV-P05" "GDEV-P06" "GDEV-P07" "GDEV-P08" "GDEV-P09" "GDEV-Q01" "GDEV-Q02" "GDEV-Q03" "GDEV-Q04" "GDEV-Q05" "GDEV-Q06")
 :inputs (".gdev-assurance/project.eld" "AGENTS.md")
 :prerequisites ("Mandato dell'utente: realizzare il prompt allegato"
                 "Fonti pubbliche locali acquisite; lacune normative esplicite")
 :owner "Manutentori di GDev e agente incaricato"
 :priority must :depends-on nil
 :procedure (:id "GDEV-VERIFY" :version 1)
 :snippets ("SNIP-DOCUMENTATION")
 :acceptance ("Tutti i requisiti applicabili hanno controlli eseguibili e artefatti identificabili"
              "Errori e interruzioni conservano una storia ricostruibile"
              "Versione minima e corrente, avvio, contratti e coperture superano le verifiche"
              "Limiti delle tassonomie e approvazioni umane restano espliciti")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions nil)
