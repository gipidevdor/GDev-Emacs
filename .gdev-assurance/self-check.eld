;;; self-check.eld --- Contratto di autoverifica della distribuzione -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :profile quality
 :references
 ((:target "nist-sp-800-218#PW.8.2" :edition "1.1")
  (:target "nist-ir-8397#@document" :edition "2021")
  (:target "iso-iec-25010#@document" :edition "2023")
  (:target "iso-iec-ieee-42010#@document" :edition "2022")
  (:target "iso-iec-ieee-29148#@document" :edition "2018")
  (:target "iso-iec-ieee-12207#@document" :edition "2026"))
 :project ".gdev-assurance/project.eld"
 :requirements ("GDEV-P01" "GDEV-P02" "GDEV-P03" "GDEV-P04" "GDEV-P05" "GDEV-P06" "GDEV-P07" "GDEV-P08" "GDEV-P09" "GDEV-Q01" "GDEV-Q02" "GDEV-Q03" "GDEV-Q04" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07" "GDEV-P10" "GDEV-P11" "GDEV-P12" "GDEV-Q08" "GDEV-P13")
 :reliability-cases ("audit" "crashes" "migration_faults" "read" "resource" "workspace" "write_faults")
 :minimum-model-operations 1280 :minimum-crash-points 8 :minimum-sql-faults 16
 :minimum-mutations 7)
