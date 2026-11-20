;;; sqlite-first-install.eld --- Profilo vuoto e copie compatibili -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :title "SQLite al primo avvio" :type bugfix
 :objective "Inizializzare un profilo vuoto e conservarne i dati alla riapertura con le build supportate di Emacs."
 :scope "Creazione e copia del database del profilo; prove di primo avvio, concorrenza e prerequisiti"
 :requirements ("GDEV-P12" "GDEV-Q08" "GDEV-Q05")
 :inputs ("docs/configurazione.md" "test/gdev-state-db-test.el" "test/gdev-cli-contract-test.py")
 :prerequisites ("Stato e configurazione temporanei" "Nessuna finestra aperta o riavvio della sessione dell’utente")
 :owner "codex:sqlite-first-install" :priority must :depends-on ()
 :procedure (:id "GDEV-VERIFY" :version 1) :snippets ()
 :acceptance ("Un profilo assente carica i moduli e crea schema e prima copia senza dati ereditati"
              "Un secondo processo ritrova il valore salvato dal primo"
              "Quattro primi scrittori conservano tutti i valori confermati"
              "SQLite assente viene segnalato e lascia disponibile la modifica dei documenti"
              "Una copia interrotta non viene pubblicata e i file esistenti restano protetti"
              "Le build Emacs 30.1 e 31.1 superano le verifiche mirate; i limiti ambientali restano espliciti")
 :artifacts ("docs/assicurazione/generati/project.md")
 :revisions ("Errore output file already exists riprodotto con Emacs 30.1 e SQLite 3.54.0"))
