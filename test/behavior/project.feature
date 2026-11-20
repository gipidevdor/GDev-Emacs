# language: it
# SPDX-License-Identifier: GPL-3.0-or-later
Funzionalità: Operazioni automatiche del progetto

  Scenario: Compilazione Cpp senza Git e con obiettivo predefinito
    Dato un progetto operativo "Make Cpp"
    Quando compilo dalla sottocartella senza aprire un sorgente
    Allora la compilazione termina con successo
    E esiste il prodotto "programma"

  Scenario: Preparazione automatica dei test Perl
    Dato un progetto operativo "Perl"
    Quando eseguo tutti i test dalla cartella
    Allora la compilazione termina con successo
    E esiste il prodotto "Makefile"
    E esiste il prodotto "blib/lib/Fixture.pm"

  Scenario: Compilazione dei sorgenti Python
    Dato un progetto operativo "Python"
    Quando compilo dalla sottocartella senza aprire un sorgente
    Allora la compilazione termina con successo
    E il bytecode del progetto è stato creato

  Scenario: Test Python dalla cartella senza un documento aperto
    Dato un progetto operativo "Python"
    Quando eseguo tutti i test dalla cartella
    Allora la compilazione termina con successo

  Scenario: Un errore di compilazione conserva il percorso di recupero
    Dato un progetto operativo "Make errato"
    Quando compilo dalla sottocartella senza aprire un sorgente
    Allora la compilazione segnala un errore
    E offre il controllo del progetto
