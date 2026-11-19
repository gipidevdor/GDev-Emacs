;; -*- no-byte-compile: t; lexical-binding: nil -*-
;; Modificato per GDev-Emacs il 2026-11-15: descrizione del pacchetto in italiano.
(define-package "forge" "20261114.1200"
  "Richieste di integrazione e segnalazioni Git"
  '((emacs         "29.1")
    (compat        "31.0")
    (closql        "2.4")
    (cond-let      "1.1")
    (emacsql       "4.4")
    (ghub          "5.3")
    (llama         "1.0")
    (magit         "4.7")
    (markdown-mode "2.8")
    (transient     "0.13")
    (yaml          "1.2"))
  :url "https://github.com/magit/forge"
  :commit "3d39bc7d6759cc4769df53889bce121283b0bfcd"
  :revdesc "3d39bc7d6759"
  :keywords '("git" "tools" "vc")
  :authors '(("Jonas Bernoulli" . "emacs.forge@jonas.bernoulli.dev"))
  :maintainers '(("Jonas Bernoulli" . "emacs.forge@jonas.bernoulli.dev")))
