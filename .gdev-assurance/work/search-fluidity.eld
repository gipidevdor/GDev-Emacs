;;; search-fluidity.eld --- Ricerca fluida -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "Interazioni fluide e algoritmi di visualizzazione" :type refactor
 :objective "Rendere immediate e prevedibili le interazioni e verificare la complessità degli algoritmi usati."
 :scope "Base Lisp e fork: ricerca, minimappa, grafi, tassonomie, inventari, capacità osservata e normalizzazione Imenu"
 :requirements ("GDEV-P07" "GDEV-Q01" "GDEV-Q03" "GDEV-Q04" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07")
 :inputs ("docs/ergonomia.md" "docs/interfaccia.md" "docs/workflows.md"
          "docs/algoritmi-e-visualizzazione.md" "docs/razionalizzazione-verifica.md")
 :prerequisites ("Misure confrontate sugli stessi risultati" "Configurazione e stato privati preservati")
 :owner "codex:search-fluidity" :priority must :depends-on ()
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets ()
 :acceptance ("Selezionare una riga fra 2000 risultati non ridisegna gli altri risultati"
              "La vista coincide con il ridisegno completo e invalida le anteprime superate"
              "Le finestre conservano identità, posizione e scorrimento"
              "Le frecce navigano, Invio apre e Spazio seleziona il risultato indicato"
              "Ridimensionamenti e componenti superati richiedono una ricostruzione coerente"
              "L'aggregazione ordinata usa O(M + R) e conserva salienza, conteggi e destinazioni"
              "La visita del grafo elimina l'associazione quadratica dei percorsi"
              "Suite, compilazione e avvio positivi sulle versioni supportate")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions ("Perimetro esteso alla visualizzazione e alla complessità su richiesta dell’utente"
             "Ricognizione estesa a tutta la base e ai fork; razionalizzazione delle primitive comuni e dei percorsi verificabili"))
