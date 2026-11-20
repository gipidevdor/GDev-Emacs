# Gherkin GDev (Ecukes 0.7.0)

Fork del parser di [Ecukes](https://github.com/ecukes/ecukes/tree/5e07d43e4dd05e1633585a7b4ddff9bcf3061c73),
GPL-3.0-or-later. `ecukes-def.el` ed `ecukes-parse.el` conservano il parser
originale con dialetto Lisp esplicito e propagazione dei tag senza liste inutili. La licenza
completa è in `LICENSE`.

Integrazione del 20 novembre 2026: `gdev-gherkin.el` aggiunge le parole
chiave italiane e un punto d'ingresso indipendente dal runner originale.
Le API e le strutture `ecukes-*` del parser restano disponibili.
F, S e Dash sono dipendenze locali già distribuite da GDev. Il runner,
la CLI, i reporter e i generatori di progetti di Ecukes non sono inclusi.
Il ponte `test/gdev-bdd.el` esegue gli scenari con Buttercup e li registra in ERT.
