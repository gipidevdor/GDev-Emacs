;;; automatic-project-context.eld --- Linguaggi e progetto integrati -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "Linguaggi automatici e operazioni nel progetto" :type bugfix
 :objective "Aprire un documento abilita il suo linguaggio e le operazioni agiscono sul progetto senza chiedere dove salvare il buffer."
 :scope "Moduli di linguaggio temporanei, Comandi e profili Xcode locali"
 :requirements ("GDEV-P07" "GDEV-P10" "GDEV-P11" "GDEV-Q03" "GDEV-Q05")
 :inputs ("docs/configurazione.md" "docs/workflows.md" "docs/contesto-progetto-verifica.md")
 :prerequisites ("Stato e configurazione di prova separati" "Nessuna finestra aperta o riavvio della sessione dell’utente")
 :owner "codex:automatic-project-context" :priority must :depends-on ()
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets ()
 :acceptance ("Swift si colora al primo file anche senza dichiarazione privata"
              "Documenti e processi condividono il modulo fino al rilascio dell’ultimo proprietario"
              "Menu e Comandi trovano le azioni del documento attivo"
              "Xcode compila con il profilo del progetto e prodotti in build/gdev"
              "Un errore di compilazione impedisce l’avvio successivo"
              "Suite e compilazione superate nelle versioni supportate")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions ("Correzioni ricostruite dalle segnalazioni reali su ChitarraTune"))
