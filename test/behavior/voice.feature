# language: it
# SPDX-License-Identifier: GPL-3.0-or-later
Funzionalità: Comandi italiani sul documento effettivo

  Scenario: Selezione strutturale e modifica annullabile
    Dato un documento vocale con testo "uno due tre"
    Quando impartisco il comando italiano "seleziona le ultime due parole"
    Allora la selezione vocale contiene "due tre"
    Quando impartisco il comando italiano "maiuscolo la selezione"
    Allora il documento vocale contiene "uno DUE TRE"
    Quando annullo la modifica vocale
    Allora il documento vocale contiene "uno due tre"

  Scenario: Sostituzione letterale del codice
    Dato un documento vocale con testo "TipoA e TipoA"
    Quando impartisco il comando italiano "sostituisci TipoA con C++::Tipo<T> ovunque"
    Allora il documento vocale contiene "C++::Tipo<T> e C++::Tipo<T>"

  Scenario: Sequenza incompleta senza effetti parziali
    Dato un documento vocale con testo "prima"
    Quando impartisco il comando italiano "maiuscolo tutto e poi frase ignota"
    Allora il comando vocale viene rifiutato
    E il documento vocale contiene "prima"

  Scenario: Annullamento esplicito di una sequenza
    Dato un documento vocale con testo "prima"
    Quando impartisco il comando italiano "maiuscolo tutto e poi non importa"
    Allora il comando vocale termina regolarmente
    E il documento vocale contiene "prima"

  Scenario: Documento in sola lettura
    Dato un documento vocale con testo "protetto"
    E il documento vocale è in sola lettura
    Quando impartisco il comando italiano "elimina tutto"
    Allora il comando vocale viene rifiutato
    E il documento vocale contiene "protetto"

  Scenario: Navigazione con numero italiano
    Dato un documento vocale con testo "prima\nseconda\nterza"
    Quando impartisco il comando italiano "vai alla riga due"
    Allora il cursore vocale è alla riga 2

  Scenario: Riga assente senza spostare il cursore
    Dato un documento vocale con testo "prima"
    Quando impartisco il comando italiano "vai alla riga novantanove"
    Allora il comando vocale viene rifiutato
    E il documento vocale contiene "prima"
