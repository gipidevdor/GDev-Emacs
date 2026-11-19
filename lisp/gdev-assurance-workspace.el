;;; gdev-assurance-workspace.el --- Transazione attiva dello spazio di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Uno spazio di lavoro può avere una transazione attiva: la modifica su cui si
;; sta lavorando in quel progetto.  Il dato appartiene allo spazio e passa da
;; `gdev-workspace-state' come ogni dato condiviso.
;;
;; Il campo `gdev-assurance-transaction' ha il ciclo di vita `transient': resta
;; in memoria, non entra nella sessione salvata e non si copia in uno spazio
;; duplicato.  Dopo un riavvio la transazione si sceglie di nuovo.
;;
;; Il campo contiene solo l'identità, (:root RADICE :id ID): lo stato vero sta
;; nell'archivio, che è la sola fonte.  Ogni lettura lo riconferma in sola
;; lettura; se la transazione non c'è più o è conclusa, il campo si svuota e
;; non resta un riferimento a ciò che non esiste.  Se l'archivio non si legge
;; per un motivo passeggero, il campo resta com'è.
;;
;; Un'impostazione convalida prima di pubblicare: un errore lascia lo spazio
;; com'era.  Il nucleo non dipende da questo file: lo usano l'interfaccia e gli
;; strumenti che conoscono lo spazio.

;;; Code:

(require 'subr-x)
(require 'gdev-workspace-state)
(require 'gdev-assurance)

(defconst gdev-assurance-workspace--field 'gdev-assurance-transaction
  "Campo di `gdev-workspace-state-fields' con la transazione attiva.")

(defconst gdev-assurance-workspace--closed-states '(BASELINED REJECTED CANCELLED SUPERSEDED)
  "Stati in cui una transazione non può essere attiva: il lavoro è concluso.")

(defun gdev-assurance-workspace--root (root)
  "Restituisci ROOT come cartella locale assoluta, o segnala un errore."
  (unless (and (stringp root) (not (string-empty-p root)) (not (file-remote-p root))
               (file-name-absolute-p root) (file-directory-p root))
    (user-error "La radice del progetto deve essere una cartella locale esistente"))
  (file-name-as-directory (expand-file-name root)))

(defun gdev-assurance-workspace--read (root id)
  "Leggi la transazione ID dell'archivio di ROOT e restituisci (:state S :title
T).  Segnala `gdev-assurance-db-missing' senza archivio e
`gdev-assurance-no-transaction' senza transazione; un'altra anomalia
dell'archivio segnala `gdev-assurance-error'."
  (gdev-assurance-db-with-open (db root)
    (if-let* ((tx (gdev-process-get db id)))
        (list :state (alist-get 'state tx) :title (alist-get 'title tx))
      (signal 'gdev-assurance-no-transaction (list id)))))

(defun gdev-assurance-workspace-active (&optional frame)
  "Restituisci la transazione attiva dello spazio corrente di FRAME, o nil.
Il valore è (:root RADICE :id ID :state STATO :title TITOLO), riletto
dall'archivio.  Una transazione che non esiste più, o è conclusa, svuota il
campo."
  (when-let* ((value (gdev-workspace-state-get gdev-assurance-workspace--field frame)))
    (let ((root (plist-get value :root))
          (id (plist-get value :id)))
      (condition-case nil
          (let ((read (gdev-assurance-workspace--read root id)))
            (if (memq (plist-get read :state) gdev-assurance-workspace--closed-states)
                (gdev-assurance-workspace-clear frame)
              (append (list :root root :id id) read)))
        ((gdev-assurance-db-missing gdev-assurance-no-transaction)
         (gdev-assurance-workspace-clear frame))
        (gdev-assurance-error nil)))))

(defun gdev-assurance-workspace-select (root id &optional frame space)
  "Rendi attiva la transazione ID dell'archivio di ROOT nello spazio corrente
di FRAME.  Convalida prima di pubblicare: la radice deve avere un archivio
leggibile, la transazione deve esistere e non essere conclusa.  Restituisci
il valore pubblicato; un errore lascia lo spazio com'era. SPACE, se
indicato, è l'identità di uno spazio ancora aperto in FRAME, anche non
selezionato."
  (let* ((tab (if space (or (gdev-workspace-state-find space frame) (user-error "Lo spazio è stato chiuso"))
                (gdev-workspace-state-current frame)))
         (root (gdev-assurance-workspace--root root))
         (read (condition-case err
                   (gdev-assurance-workspace--read root id)
                 (gdev-assurance-db-missing
                  (user-error "Nessun archivio di assicurazione in %s" root))
                 (gdev-assurance-no-transaction
                  (user-error "La transazione %s non esiste in %s" (cadr err) root))
                 (gdev-assurance-error
                  (user-error "%s" (error-message-string err))))))
    (when (memq (plist-get read :state) gdev-assurance-workspace--closed-states)
      (user-error "%s è in %s: il lavoro è concluso" id (plist-get read :state)))
    (let ((value (list :root root :id id)))
      (gdev-workspace-state-update
       (list (cons gdev-assurance-workspace--field value))
       tab)
      value)))

(defun gdev-assurance-workspace-clear (&optional frame)
  "Rimuovi la transazione attiva dello spazio corrente di FRAME e restituisci nil."
  (gdev-workspace-state-update
   (list (cons gdev-assurance-workspace--field nil))
   (gdev-workspace-state-current frame))
  nil)

(defun gdev-assurance-workspace-root-fields (roots)
  "Invalida l'identità attiva se ROOTS esclude il suo progetto.
Le modifiche sono pubblicate insieme ai campi delle cartelle. Una radice
che contiene il progetto, o una sua sottocartella, conserva la scelta."
  (when-let* ((active (gdev-workspace-state-get gdev-assurance-workspace--field)))
    (let ((project (file-name-as-directory (file-truename (plist-get active :root)))))
      (unless (seq-some (lambda (root)
                         (and (not (file-remote-p root))
                              (let ((path (file-name-as-directory (file-truename root))))
                                (or (string-prefix-p path project) (string-prefix-p project path))))) roots)
        (list (cons gdev-assurance-workspace--field nil))))))

(with-eval-after-load 'gdev-workspace-roots
  (add-hook 'gdev-workspace-root-state-functions #'gdev-assurance-workspace-root-fields))

(provide 'gdev-assurance-workspace)
;;; gdev-assurance-workspace.el ends here
