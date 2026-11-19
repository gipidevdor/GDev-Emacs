;;; gdev-fork-annullamento-test.el --- Regressioni dei fork di annullamento -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'package)

(ert-deftest gdev-test-fork-vundo-shortest-route-ties ()
  "Scegli lo stato più recente a parità di distanza e rispetta la direzione."
  (package-activate-all)
  (require 'vundo)
  (let ((sources (mapcar (lambda (i) (make-vundo-m :idx i)) '(2 4 7)))
        (destinations (mapcar (lambda (i) (make-vundo-m :idx i)) '(1 3 6))))
    (vundo--eqv-merge sources)
    (vundo--eqv-merge destinations)
    (should (equal (vundo--calculate-shortest-route (car sources) (car destinations))
                   '(7 6)))
    (should (equal (vundo--calculate-shortest-route (car destinations) (car sources))
                   '(3 2)))
    (should-not (vundo--calculate-shortest-route (make-vundo-m :idx 0)
                                                (car destinations)))))

(ert-deftest gdev-test-fork-vundo-timestamp-shared-states ()
  "Usa la data più recente per gli stati equivalenti e mantieni l'ordine dei pari."
  (package-activate-all)
  (require 'vundo)
  (let* ((first (make-vundo-m :idx 0))
         (equivalent (make-vundo-m :idx 2))
         (other (make-vundo-m :idx 3 :timestamp 10))
         (nodes (vector first (make-vundo-m :idx 1 :timestamp 20)
                        equivalent other (make-vundo-m :idx 4 :timestamp 20))))
    (vundo--eqv-merge (list first equivalent))
    (let ((timestamps (vundo--record-timestamps nodes)))
      (should (= (length timestamps) 2))
      (should (eq (caar timestamps) other))
      (should (eq (caadr timestamps) first))
      (should (= (cdar timestamps) 20))
      (should (= (cdadr timestamps) 20)))))

(ert-deftest gdev-test-fork-undo-fu-session-encode-equivalences ()
  "Evita la scansione per la tabella vuota e ripristina gli stati in sospeso."
  (package-activate-all)
  (require 'undo-fu-session)
  (let ((history (list '(1 . 2) nil '(2 . 3) nil))
        (pending (list '(3 . 4) nil))
        (equivalences (make-hash-table :test #'eq)))
    (cl-letf (((symbol-function 'undo-fu-session--list-to-index-map)
               (lambda (&rest _) (ert-fail "Scansione della cronologia con tabella vuota"))))
      (should-not (undo-fu-session--equivtable-encode equivalences history pending)))
    (puthash history pending equivalences)
    (puthash (nthcdr 2 history) t equivalences)
    (let* ((encoded (undo-fu-session--equivtable-encode equivalences history pending))
           (recovered (undo-fu-session--equivtable-decode encoded history pending)))
      (should (equal (cdr (assq 0 encoded)) -1))
      (should (eq (gethash history recovered) pending))
      (should (eq (gethash (nthcdr 2 history) recovered) t)))))

;;; gdev-fork-annullamento-test.el ends here
