;;; controlli.eld --- Controlli operativi di GDev  -*- lisp-data -*-

;; Dati puri: si leggono con `read', non si valutano.
;;
;; Ogni controllo è scritto da GDev e non riproduce testo normativo.  Dice che
;; cosa si osserva nell'archivio di assicurazione, non che cosa chiede uno
;; standard.  I :riferimenti sono un collegamento informativo a una clausola di
;; uno standard del registro: ogni clausola citata esiste nei dati scaricati e
;; l'edizione è fissata.  Il collegamento non afferma conformità allo standard.
;;
;; :dovuto-da   stato che la transazione deve avere raggiunto perché il controllo
;;              si applichi; prima il controllo resta NOT_VERIFIED
;; :richiede    condizioni che l'archivio deve mostrare, tutte:
;;   (:passaggio :a STATO :attore TIPO)         passaggio a STATO di un attore di quel tipo
;;   (:prova :genere G :origine O :minimo N :in STATO)
;;                                              N prove di genere G e origine O
;;                                              registrate mentre era in STATO; si può
;;                                              aggiungere :attore TIPO (la prova è di
;;                                              un attore di quel tipo) e
;;                                              :indipendente-da-chi-porta-a STATO (chi
;;                                              la registra non è chi ha portato la
;;                                              transazione a STATO)
;;   (:separazione :stato STATO)                chi porta a STATO non è chi ha aperto
;;   (:archivio-integro)                        la verifica dell'archivio non trova problemi
;;   (:valutazione-registrata :prima-di STATO)  una valutazione registrata precede il
;;                                              passaggio a STATO
;;   (:attori-distinti :stati (S1 S2))          chi porta a S1 non è chi porta a S2
;;   (:nessuna-decisione :genere G)             la transazione non ha decisioni di genere G
;; :decidibile  t se una persona può derogare al controllo o dichiararlo non
;;              applicabile per una transazione; nil per i controlli che non si
;;              possono decidere, come l'integrità della catena di audit
;; :metodo      come si verifica, in parole

(
 (:id "GES-C01"
  :decidibile t
  :titolo "Autorizzazione di una persona prima dell'implementazione"
  :dovuto-da IMPLEMENTING
  :richiede ((:passaggio :a AUTHORIZED :attore human))
  :metodo "Si legge nella catena di audit il passaggio a AUTHORIZED e il tipo d'attore."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.2.3"
                 :relazione informativa)))

 (:id "GES-C02"
  :decidibile nil
  :titolo "Catena di audit integra"
  :dovuto-da PROPOSED
  :richiede ((:archivio-integro))
  :metodo "Si rifanno le impronte della catena e si controllano schema, stati e prove."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.4.2"
                 :relazione informativa)))

 (:id "GES-C03"
  :decidibile t
  :titolo "Approvazione di una persona prima del consolidamento"
  :dovuto-da BASELINED
  :richiede ((:passaggio :a APPROVED :attore human)
             (:passaggio :a BASELINED :attore human))
  :metodo "Si leggono nella catena i passaggi a APPROVED e a BASELINED e il tipo d'attore."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.4.1"
                 :relazione informativa)))

 (:id "GES-Q01"
  :decidibile t
  :titolo "Prova di verifica raccolta durante la verifica"
  :dovuto-da REVIEWING
  :richiede ((:prova :genere fact :origine collected :minimo 1 :in VERIFYING))
  :metodo "Si contano le prove di genere fact e origine collected registrate in VERIFYING."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.8.2"
                 :relazione informativa)))

 (:id "GES-S01"
  :decidibile t
  :titolo "Chi propone non autorizza"
  :dovuto-da AUTHORIZED
  :richiede ((:separazione :stato AUTHORIZED))
  :metodo "Si confronta l'attore che ha aperto la transazione con quello che l'ha autorizzata."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.2.1"
                 :relazione informativa)))

 (:id "GES-S02"
  :decidibile t
  :titolo "Analisi del rischio registrata prima dell'autorizzazione"
  :dovuto-da AUTHORIZED
  :richiede ((:prova :genere deduction :origine collected :minimo 1 :in ANALYZED))
  :metodo "Si contano le prove di genere deduction e origine collected registrate in ANALYZED."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.1.1"
                 :relazione informativa)))

 (:id "GES-S03"
  :decidibile t
  :titolo "Revisione registrata prima dell'approvazione"
  :dovuto-da APPROVED
  :richiede ((:prova :genere fact :origine collected :minimo 1 :in REVIEWING))
  :metodo "Si contano le prove di genere fact e origine collected registrate in REVIEWING."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.7.2"
                 :relazione informativa)))

 ;; Controlli propri dei profili high-assurance e critical: proposta di GDev da
 ;; rivedere.  Non discendono da uno standard; i riferimenti sono informativi.

 (:id "GES-H01"
  :decidibile t
  :titolo "Verifica registrata da chi non ha portato la transazione in verifica"
  :dovuto-da REVIEWING
  :richiede ((:prova :genere fact :origine collected :minimo 1 :in VERIFYING
                     :indipendente-da-chi-porta-a VERIFYING))
  :metodo "Si cerca una prova di verifica il cui autore non è chi ha portato la transazione a VERIFYING."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.2.1"
                 :relazione informativa)))

 (:id "GES-H02"
  :decidibile t
  :titolo "Revisione registrata da una persona"
  :dovuto-da APPROVED
  :richiede ((:prova :genere fact :origine collected :minimo 1 :in REVIEWING :attore human))
  :metodo "Si cerca una prova di revisione registrata da un attore di tipo human."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.7.2"
                 :relazione informativa)))

 (:id "GES-H03"
  :decidibile t
  :titolo "Valutazione registrata prima del consolidamento"
  :dovuto-da BASELINED
  :richiede ((:valutazione-registrata :prima-di BASELINED))
  :metodo "Si cerca nella catena una valutazione registrata prima del passaggio a BASELINED."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.4.2"
                 :relazione informativa)))

 (:id "GES-K01"
  :decidibile t
  :titolo "Autorizzazione e approvazione di persone diverse"
  :dovuto-da APPROVED
  :richiede ((:attori-distinti :stati (AUTHORIZED APPROVED)))
  :metodo "Si confrontano gli attori dei passaggi a AUTHORIZED e a APPROVED."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.2.1"
                 :relazione informativa)))

 (:id "GES-K02"
  :decidibile nil
  :titolo "Nessuna deroga a una transazione critica"
  :dovuto-da PROPOSED
  :richiede ((:nessuna-decisione :genere waiver))
  :metodo "Si cercano deroghe fra le decisioni della transazione."
  :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PO.4.1"
                 :relazione informativa)))
)
