;;; attuazione.eld --- Controlli originali GDev per i riferimenti -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Nessun testo normativo. :scope documento indica una verifica documentale
;; riferita alla scheda bibliografica, non una clausola inventata.
;; Ogni obiettivo richiede una prova specifica con esito, oltre ai dati strutturali.
(
 (:standard "iso-iec-ieee-12207" :scope documento :roles (requirement source test)
  :trace ((requirement implements source) (source verifies test)))
 (:standard "iso-iec-ieee-15289" :scope documento :roles (document)
  :due APPROVED :proof-state REVIEWING :human t)
 (:standard "iso-iec-ieee-29148" :scope documento :roles (requirement)
  :trace ((requirement implements source)))
 (:standard "ieee-1012" :scope documento :roles (test) :human t :independent t)
 (:standard "iso-iec-25010" :scope documento :roles (requirement test))
 (:standard "iso-iec-ieee-42010" :scope documento :roles (design))
 (:standard "iso-iec-33020" :scope documento :roles (document) :human t
  :due BASELINED :proof-state REVIEWING :assessment t)
 (:standard "iso-iec-33001" :scope documento :roles (document) :human t)
 (:standard "iso-iec-33002" :scope documento :roles (document) :human t)
 (:standard "iso-iec-33003" :scope documento :roles (document) :human t)
 (:standard "iso-iec-33004" :scope documento :roles (document) :human t)
 (:standard "ecss-e-st-40c" :scope clausola :roles (requirement source test)
  :trace ((requirement implements source) (source verifies test)))
 (:standard "ecss-q-st-80c" :scope clausola :roles (document test) :human t :independent t)
 (:standard "ecss-s-st-00" :scope clausola :roles (document) :human t)
 (:standard "nasa-npr-7150-2" :scope documento :roles (requirement source test)
  :trace ((requirement implements source) (source verifies test)))
 (:standard "nasa-std-8739-8" :scope documento :roles (document test) :human t :independent t)
 (:standard "nist-sp-800-218" :scope clausola :roles (document))
 (:standard "nist-sp-800-160-v1" :scope documento :roles (requirement design test))
 (:standard "nist-ir-8397" :scope documento :roles (test))
 (:standard "owasp-asvs" :scope clausola :roles (test))
 (:standard "slsa" :scope clausola :roles (configuration source) :human t)
)
