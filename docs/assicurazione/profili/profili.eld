;;; profili.eld --- Profili di rigore di GDev  -*- lisp-data -*-

;; Dati puri: si leggono con `read', non si valutano.
;;
;; Un profilo è una composizione di controlli: i propri :controlli più quelli dei
;; profili di cui :eredita.  Gli identificativi sono quelli dello schema
;; dell'archivio (`gdev-process-profiles').  :provvisorio dice che i controlli
;; propri del profilo sono una proposta di GDev, ancora da rivedere.

(
 (:id core
  :titolo "GES Core"
  :eredita ()
  :controlli ("GES-C01" "GES-C02" "GES-C03"))

 (:id quality
  :titolo "GES Quality"
  :eredita (core)
  :controlli ("GES-Q01"))

 (:id secure
  :titolo "GES Secure"
  :eredita (quality)
  :controlli ("GES-S01" "GES-S02" "GES-S03"))

 (:id high-assurance
  :titolo "GES High Assurance"
  :eredita (secure)
  :controlli ("GES-H01" "GES-H02" "GES-H03")
  :provvisorio t)

 (:id critical
  :titolo "GES Critical"
  :eredita (high-assurance)
  :controlli ("GES-K01" "GES-K02")
  :provvisorio t)
)
