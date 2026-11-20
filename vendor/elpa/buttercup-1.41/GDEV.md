# BDD Elisp GDev (Buttercup 1.41)

Fork locale di [Buttercup](https://github.com/jorgenschaefer/emacs-buttercup/tree/3bcf6cf0e164d558072a484f467169a0e77bd791),
GPL-3.0-or-later, di Jorgen Schaefer e Ola Nilsson. Sorgenti e avvisi
originali sono conservati. La licenza completa è in `LICENSE`.

Integrazione del 20 novembre 2026: descrittore e autoload per il registro
GDev. Il fork intercetta i segnali Buttercup prima del gestore esterno ERT,
conservando il risultato e la descrizione del motore originale. Usa i normali
gestori Elisp, così un errore già gestito da un callback non fallisce uno
scenario estraneo. Il campo della traccia può essere nil, come previsto
dall'API del motore.
`test/gdev-bdd.el` lo collega a ERT e al parser Gherkin GDev, con esiti
falliti e pendenti propagati alla CI e pulizia anche in caso di errore.
