;;; gdev-assurance-workspace-test.el --- Prove della transazione attiva dello spazio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La transazione attiva passa da `gdev-workspace-state', si convalida prima di
;; essere pubblicata, si riconferma a ogni lettura e non entra nella sessione.

;;; Code:

(require 'ert)
(require 'gdev-assurance-workspace)

(ert-deftest gdev-test-assurance-workspace-field-is-registered-and-not-saved ()
  "Il campo è dichiarato transitorio: né salvato in sessione né copiato."
  (should (eq (alist-get 'gdev-assurance-transaction gdev-workspace-state-fields) 'transient))
  (should-not (gdev-workspace-state-saved-p 'gdev-assurance-transaction)))

(ert-deftest gdev-test-assurance-workspace-selects-and-rereads-the-transaction ()
  "Selezionare pubblica l'identità; leggere riporta lo stato corrente dell'archivio."
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (should-not (gdev-assurance-workspace-active))
        (should (equal (gdev-assurance-workspace-select root id) (list :root root :id id)))
        (should (equal (gdev-workspace-state-get 'gdev-assurance-transaction)
                       (list :root root :id id)))
        (should (equal (gdev-assurance-workspace-active)
                       (list :root root :id id :state 'PROPOSED :title "Modifica di prova")))
        ;; Lo stato si rilegge: dopo un passaggio il valore lo riflette.
        (gdev-test-assurance--step db id 'CLASSIFIED)
        (should (eq (plist-get (gdev-assurance-workspace-active) :state) 'CLASSIFIED))
        (should-not (gdev-assurance-workspace-clear))
        (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))
        (should-not (gdev-assurance-workspace-active))))))

(ert-deftest gdev-test-assurance-workspace-refuses-before-publishing ()
  "Una selezione non valida lascia lo spazio com'era."
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((active (gdev-test-assurance--open db))
            (closed (gdev-test-assurance--open db)))
        (gdev-test-assurance--step db closed 'CANCELLED 'human)
        (gdev-assurance-workspace-select root active)
        (gdev-test-assurance--with-root empty
          (dolist (case `((,root "GT-0099" "non esiste")
                          (,root ,closed "è in CANCELLED")
                          (,empty ,active "Nessun archivio")
                          (,(concat root "manca/") ,active "cartella locale esistente")
                          ("relativo" ,active "cartella locale esistente")
                          (nil ,active "cartella locale esistente")
                          ("/ssh:host:/" ,active "cartella locale esistente")))
            (let ((err (should-error (gdev-assurance-workspace-select (car case) (cadr case))
                                     :type 'user-error)))
              (should (string-match-p (nth 2 case) (cadr err))))
            (should (equal (gdev-workspace-state-get 'gdev-assurance-transaction)
                           (list :root root :id active)))))))))

(ert-deftest gdev-test-assurance-workspace-drops-a-transaction-that-is-gone-or-concluded ()
  "Se l'archivio non ha più la transazione, o è conclusa, il campo si svuota."
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-assurance-workspace-select root id)
        (gdev-test-assurance--step db id 'CANCELLED 'human)
        (should-not (gdev-assurance-workspace-active))
        (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))
        ;; Un riferimento a una transazione inesistente o a un archivio sparito.
        (gdev-workspace-state-set 'gdev-assurance-transaction (list :root root :id "GT-0099"))
        (should-not (gdev-assurance-workspace-active))
        (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))
        (gdev-workspace-state-set 'gdev-assurance-transaction
                                  (list :root (concat root "src/") :id id))
        (should-not (gdev-assurance-workspace-active))
        (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))))))

(ert-deftest gdev-test-assurance-workspace-keeps-the-field-when-the-archive-is-unreadable ()
  "Un archivio illeggibile per un motivo passeggero non cancella la scelta."
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-assurance-workspace-select root id)
        (gdev-assurance-db-close db)
        (cl-letf (((symbol-function 'gdev-assurance-workspace--read)
                   (lambda (&rest _) (signal 'gdev-assurance-db-unusable '("occupato")))))
          (should-not (gdev-assurance-workspace-active))
          (should (equal (gdev-workspace-state-get 'gdev-assurance-transaction)
                         (list :root root :id id)))
          (let ((err (should-error (gdev-assurance-workspace-select root id) :type 'user-error)))
            (should (string-match-p "Archivio non utilizzabile" (cadr err)))))))))

(ert-deftest gdev-test-assurance-workspace-belongs-to-one-space ()
  "Ogni spazio ha la propria transazione attiva."
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((first (gdev-test-assurance--open db))
            (second (gdev-test-assurance--open db))
            (frame (selected-frame)))
        (gdev-workspace-state-ensure-id frame)
        (gdev-assurance-workspace-select root first)
        (tab-bar-new-tab)
        (gdev-workspace-state-ensure-id frame)
        (should-not (gdev-assurance-workspace-active))
        (gdev-assurance-workspace-select root second)
        (should (equal (plist-get (gdev-assurance-workspace-active) :id) second))
        (tab-bar-select-tab 1)
        (should (equal (plist-get (gdev-assurance-workspace-active) :id) first))
        (should (equal (plist-get (gdev-assurance-workspace-active frame) :id) first))))))

(ert-deftest gdev-test-assurance-workspace-shows-in-the-layout-fields ()
  "La transazione attiva compare fra i campi dello spazio che l'agente legge."
  (require 'gdev-agent-control)
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (let ((id (gdev-test-assurance--open db)))
        (gdev-assurance-workspace-select root id)
        (let* ((layout (gdev-agent-control-request "layout"))
               (fields (alist-get 'fields (alist-get 'workspace layout))))
          (should (equal (alist-get 'gdev-assurance-transaction fields)
                         (vector "root" root "id" id))))))))

(provide 'gdev-assurance-workspace-test)
;;; gdev-assurance-workspace-test.el ends here
