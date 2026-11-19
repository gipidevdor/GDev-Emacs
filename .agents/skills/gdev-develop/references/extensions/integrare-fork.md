<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Integrare un rilascio a monte in un fork

Usa il [registro e la guida dei fork](../../../../../docs/dipendenze.md)
quando devi integrare una revisione del progetto originale. Parti dalla
base registrata in `vendor/pacchetti.el`, dal fork presente nel checkout e
dal rilascio da integrare. Prepara gli alberi dei due rilasci con lo stesso
layout distribuito. Con `./bin/gdev fork-merge PACCHETTO BASE NUOVO` ottieni
una copia temporanea con la cronologia delle tre versioni.

Per un fork che estrae alcune funzioni da una libreria inclusa in Emacs,
ricostruisci la base e il nuovo rilascio con gli stessi confini e nomi
del pacchetto GDev. Registra il file originale e la revisione nella guida
o nel sorgente. Prova il caricamento dalla prima azione che usa il fork,
anche quando la funzione viene caricata dopo l'avvio.

Controlla `git status` e `git diff --cached HEAD` nella copia temporanea.
Quando compaiono conflitti, usa tutti e tre gli stati e verifica il
comportamento che ciascuna modifica proteggeva. Anche dopo un merge pulito,
prova le personalizzazioni GDev e gli ingressi del modulo. Se la base
esatta è indisponibile, recuperala dalla provenienza registrata prima di
applicare la modifica a `vendor`.

Conserva gli avvisi a monte e le note di modifica GDev. Aggiungi ai
sorgenti modificati una nota con data e intervento. Attribuisci i contributi
individuali a chi li ha fatti. Verifica descrittore, autoload, licenze e
registro. Prima di concludere controlla che Emacs carichi la copia locale,
anche se è presente un omonimo ELPA. Rimuovi l'anteprima terminata.
