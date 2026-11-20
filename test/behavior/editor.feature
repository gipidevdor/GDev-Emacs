# language: it
# SPDX-License-Identifier: GPL-3.0-or-later
Funzionalità: Modifica dei documenti nel banco di lavoro

  Scenario: Salvataggio del documento attivo
    Dato un documento con testo "prima\n"
    Quando inserisco "dopo\n"
    E salvo il documento
    Allora il file contiene "prima\ndopo\n"
    E il documento risulta salvato

  Scenario: Annullamento e ripetizione
    Dato un documento con testo "prima\n"
    Quando inserisco "dopo\n"
    E annullo la modifica
    Allora il documento contiene "prima\n"
    Quando ripeto la modifica
    Allora il documento contiene "prima\ndopo\n"

  Scenario: Piegatura reversibile
    Dato un documento con testo "function prova() {\n  return 1;\n}\n"
    Quando piego tutti i blocchi
    Allora un blocco è nascosto
    E il documento risulta salvato
    Quando riapro tutti i blocchi
    Allora nessun blocco è nascosto
    E il documento contiene "function prova() {\n  return 1;\n}\n"

  Scenario: Cursori multipli e uscita
    Dato un documento con testo "uno\ndue\n"
    Quando aggiungo un cursore per riga
    E scrivo "!" da tastiera
    Allora il documento contiene "!uno\n!due\n"
    Quando esco dai cursori multipli
    Allora resta un solo cursore

  Scenario: Chiusura automatica delle parentesi
    Dato un documento con testo ""
    Quando scrivo "(" da tastiera
    Allora il documento contiene "()"
    E il cursore è tra le parentesi

  Scenario: Superamento della parentesi già chiusa
    Dato un documento con testo ""
    Quando scrivo "()" da tastiera
    Allora il documento contiene "()"
    E il cursore è dopo le parentesi

  Scenario: Cancellazione della coppia vuota
    Dato un documento con testo ""
    Quando scrivo "(" da tastiera
    E premo indietro
    Allora il documento contiene ""

  Scenario: Commento e riapertura di una riga
    Dato un documento con testo "const x = 1;\n"
    Quando torno all'inizio
    E commento la riga
    Allora il documento contiene "// const x = 1;\n"
    Quando commento la riga
    Allora il documento contiene "const x = 1;\n"

  Scenario: Rientro JavaScript da tastiera
    Dato un documento con testo "function prova() {\nreturn 1;\n}\n"
    Quando vado alla riga 2
    E premo TAB
    Allora il documento contiene "function prova() {\n  return 1;\n}\n"

  Scenario: Rientro Python da tastiera
    Dato un documento Python con testo "def prova():\nreturn 1\n"
    Quando vado alla riga 2
    E premo TAB
    Allora il documento contiene "def prova():\n    return 1\n"

  Scenario: Taglio e incolla con caratteri Unicode
    Dato un documento con testo "caffè 😀\nseconda\n"
    Quando torno all'inizio
    E taglio la prima riga
    Allora il documento contiene "seconda\n"
    Quando incollo il testo tagliato
    Allora il documento contiene "caffè 😀\nseconda\n"

  Scenario: Protezione del documento in sola lettura
    Dato un documento con testo "protetto\n"
    Quando proteggo il documento
    Allora scrivere da tastiera viene rifiutato
    E il documento contiene "protetto\n"
    E il documento risulta salvato

  Scenario: Salvataggio di un documento vuoto
    Dato un documento con testo ""
    Quando salvo il documento
    Allora il file contiene ""
    E il documento risulta salvato

  Scenario: Il salvataggio conserva la posizione
    Dato un documento con testo "prima\nseconda\n"
    Quando torno all'inizio
    E inserisco "😀 "
    E ricordo la posizione
    E salvo il documento
    Allora la posizione è conservata
    E il file contiene "😀 prima\nseconda\n"

  Scenario: Ricaricamento del documento dal disco
    Dato un documento con testo "prima\n"
    Quando il file sul disco diventa "nuovo\n"
    E ricarico il documento
    Allora il documento contiene "nuovo\n"
    E il documento risulta salvato

  Scenario: Annullamento del ricaricamento
    Dato un documento con testo "prima\n"
    Quando inserisco "bozza\n"
    E il file sul disco diventa "nuovo\n"
    E annullo il ricaricamento
    Allora il documento contiene "prima\nbozza\n"
    E il documento ha modifiche non salvate

  Scenario: Conferma del ricaricamento
    Dato un documento con testo "prima\n"
    Quando inserisco "bozza\n"
    E il file sul disco diventa "nuovo\n"
    E confermo il ricaricamento
    Allora il documento contiene "nuovo\n"
    E il documento risulta salvato

  Scenario: Spostamento della riga con il comando GDev
    Dato un documento con testo "uno\ndue\ntre\n"
    Quando vado alla riga 2
    E sposto la riga in alto
    Allora il documento contiene "due\nuno\ntre\n"

  Scenario: Snippet con campi collegati
    Dato un documento con testo ""
    Quando espando lo snippet con nome "nome"
    E scrivo "caffè" nel primo campo
    Allora il documento contiene "caffè = caffè"

  Scenario: Annullamento della scrittura multipla
    Dato un documento con testo "uno\ndue\n"
    Quando aggiungo un cursore per riga
    E scrivo "!" da tastiera
    E esco dai cursori multipli
    E annullo la modifica
    Allora il documento contiene "uno\ndue\n"
