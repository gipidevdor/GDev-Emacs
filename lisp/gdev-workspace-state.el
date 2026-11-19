;;; gdev-workspace-state.el --- Stato condiviso dello spazio di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La scheda nativa conserva i dati GDev dello spazio di lavoro. I moduli
;; leggono e pubblicano i propri campi tramite questa libreria. I dati
;; locali di documenti, finestre e applicazione appartengono ai rispettivi
;; moduli. Un'operazione sospesa ritrova lo spazio per identità, anche dopo
;; un cambio di scheda.

;;; Code:

(require 'subr-x)
(require 'tab-bar)

(defconst gdev-workspace-state-fields
  '((gdev-workspace-roots . clone)
    (gdev-layout-folder . clone)
    (gdev-layout-explorer-root . clone)
    (gdev-layout-explorer-hidden . clone)
    (gdev-layout-explorer-width . clone)
    (gdev-activity-view . clone)
    (gdev-launch-selections . clone)
    (gdev-layout-commands-visibility . persist)
    (gdev-layout-commands-width . persist)
    (gdev-command-sidebar-category . persist)
    (gdev-layout-minimap-visible . persist)
    (gdev-layout-panel-session . persist)
    (gdev-workspaces-layout . persist)
    (gdev-activity-buffers . transient)
    (gdev-activity-positions . transient)
    (gdev-assurance-transaction . transient)
    (gdev-build-last-plans . transient)
    (gdev-command-sidebar-buffer . transient)
    (gdev-comparison-control . transient)
    (gdev-database-browser-buffers . until-close)
    (gdev-debug-workspace-id . until-close)
    (gdev-launch-pending . until-close)
    (gdev-layout-auxiliary-buffer . transient)
    (gdev-layout-auxiliary-panel-origin . transient)
    (gdev-layout-closed-documents . transient)
    (gdev-layout-editor-state . transient)
    (gdev-layout-explorer-buffer . transient)
    (gdev-layout-panel-active . transient)
    (gdev-layout-panel-buffers . transient)
    (gdev-layout-panel-height . transient)
    (gdev-layout-panel-hidden . transient)
    (gdev-layout-panel-split . transient)
    (gdev-merge-preview . until-close)
    (gdev-operation-history . transient)
    (gdev-preferences-buffer . transient)
    (gdev-test-coverage-reports . until-close)
    (gdev-timeline-buffer . transient)
    (gdev-workbench-operations . until-close))
  "Campi GDev della scheda e regole sul loro ciclo di vita.
`clone' ammette salvataggio e copia in uno spazio duplicato.
`persist' ammette solo salvataggio, `transient' resta in memoria.
`until-close' scade anche se la scheda viene riaperta con Tab Bar.")

(defun gdev-workspace-state-saved-p (key)
  "Indica se la regola di KEY ammette il salvataggio con la sessione."
  (memq (alist-get key gdev-workspace-state-fields) '(clone persist)))

(defconst gdev-workspace-state--close-changes
  (delq nil (mapcar (lambda (field)
                     (when (eq (cdr field) 'until-close)
                       (list (car field))))
                   gdev-workspace-state-fields))
  "Campi da rimuovere quando Tab Bar chiude uno spazio.")

(defvar gdev-workspace-state--moving-tab nil
  "Indica che Tab Bar sta trasferendo una scheda fra due finestre.")

(defun gdev-workspace-state-tabs (&optional frame)
  "Restituisci le schede native di FRAME come riferimenti allo stato."
  (funcall tab-bar-tabs-function frame))

(defun gdev-workspace-state-current (&optional frame)
  "Restituisci il riferimento alla scheda corrente di FRAME.
Usa il riferimento per operazioni immediate. Per un'operazione sospesa
conserva l'identità dello spazio e cercala alla ripresa."
  (assq 'current-tab
        (or (and (eq tab-bar-tabs-function #'tab-bar-tabs)
                 (frame-parameter frame 'tabs))
            (gdev-workspace-state-tabs frame))))

(defun gdev-workspace-state-read (key tab)
  "Leggi KEY dal riferimento TAB.
Tratta liste e altri valori composti restituiti come dati in sola lettura."
  (alist-get key (cdr tab)))

(defun gdev-workspace-state-get (key &optional frame)
  "Leggi KEY dallo spazio corrente di FRAME."
  (gdev-workspace-state-read key (gdev-workspace-state-current frame)))

(defun gdev-workspace-state--put (entries key value)
  "Restituisci ENTRIES con KEY impostata a VALUE, conservando ENTRIES."
  (let ((entry (assq key entries)))
    (if (eq (cdr entry) value)
        entries
      (let ((remaining (if entry (remq entry entries) entries)))
        (if value (cons (cons key value) remaining) remaining)))))

(defun gdev-workspace-state--check-key (key)
  "Segnala un errore se KEY non appartiene allo stato GDev."
  (unless (assq key gdev-workspace-state-fields)
    (error "Campo dello spazio di lavoro sconosciuto: %S" key)))

(defun gdev-workspace-state--set (key value tab)
  "Aggiorna KEY in TAB, oppure nella scheda corrente, e restituisci VALUE."
  (let ((tab (or tab (gdev-workspace-state-current))))
    (setcdr tab (gdev-workspace-state--put (cdr tab) key value)))
  value)

(defun gdev-workspace-state-set (key value &optional tab)
  "Pubblica VALUE per KEY in TAB o nello spazio corrente.
Usa nil per rimuovere un valore."
  (gdev-workspace-state--check-key key)
  (gdev-workspace-state--set key value tab))

(defun gdev-workspace-state-update (changes &optional tab)
  "Pubblica insieme le coppie (KEY . VALUE) di CHANGES in TAB.
Senza TAB usa lo spazio corrente. Se un campo non è registrato, non
pubblicare alcuna modifica. Un VALUE nil rimuove il campo."
  (when changes
    (let* ((tab (or tab (gdev-workspace-state-current)))
           (entries (cdr tab)))
      (dolist (change changes)
        (gdev-workspace-state--check-key (car change))
        (setq entries (gdev-workspace-state--put entries (car change) (cdr change))))
      (setcdr tab entries))))

(defun gdev-workspace-state--after-close (close &rest arguments)
  "Esegui CLOSE con ARGUMENTS e invalida i campi degli spazi chiusi.
Conserva i riferimenti delle schede ancora aperte se la chiusura si interrompe."
  (let ((previous tab-bar-closed-tabs)
        (frame (selected-frame)))
    (unwind-protect
        (apply close arguments)
      (unless (or gdev-workspace-state--moving-tab (eq previous tab-bar-closed-tabs))
        (let ((inhibit-quit t)
              (closed tab-bar-closed-tabs)
              (live (and (frame-live-p frame) (gdev-workspace-state-tabs frame))))
          (while (and closed (not (eq closed previous)))
            (let ((tab (alist-get 'tab (pop closed))))
              (when (and tab (not (memq tab live)))
                (gdev-workspace-state-update gdev-workspace-state--close-changes tab)))))))))

(dolist (command '(tab-bar-close-tab tab-bar-close-other-tabs))
  (advice-add command :around #'gdev-workspace-state--after-close))

(defun gdev-workspace-state--move-tab (move &rest arguments)
  "Esegui MOVE senza far scadere l'identità della scheda trasferita."
  (let ((gdev-workspace-state--moving-tab t))
    (apply move arguments)))

;; Tab Bar usa la chiusura per rimuovere la scheda dalla finestra di partenza.
(advice-add 'tab-bar-move-tab-to-frame :around #'gdev-workspace-state--move-tab)

(defun gdev-workspace-state-snapshot (tab)
  "Acquisisci lo stato di TAB in memoria prima di una transizione reversibile."
  (cons tab (copy-alist (cdr tab))))

(defun gdev-workspace-state-restore (snapshot)
  "Ripristina la stessa scheda catturata in SNAPSHOT."
  (setcdr (car snapshot) (cdr snapshot)))

(defun gdev-workspace-state-id (&optional frame)
  "Leggi l'identità già assegnata allo spazio corrente di FRAME."
  (gdev-workspace-state-get 'gdev-debug-workspace-id frame))

(defun gdev-workspace-state-ensure-id (&optional frame)
  "Restituisci l'identità dello spazio corrente di FRAME, creandola se manca."
  (let ((tab (gdev-workspace-state-current frame)))
    (or (gdev-workspace-state-read 'gdev-debug-workspace-id tab)
        (gdev-workspace-state-set 'gdev-debug-workspace-id (make-symbol "spazio") tab))))

(defun gdev-workspace-state-find (id &optional frame)
  "Ritrova la scheda di ID in FRAME, se è ancora aperta."
  (when id
    (catch 'found
      (dolist (tab (gdev-workspace-state-tabs frame))
        (when (eq id (gdev-workspace-state-read 'gdev-debug-workspace-id tab))
          (throw 'found tab))))))

(defun gdev-workspace-state-clone-values (&optional frame)
  "Copia i campi ereditabili dello spazio corrente di FRAME."
  (let ((tab (gdev-workspace-state-current frame)))
    (delq nil
          (mapcar (lambda (field)
                    (when (eq (cdr field) 'clone)
                      (when-let* ((key (car field))
                                  (value (gdev-workspace-state-read key tab)))
                        (cons key (copy-tree value)))))
                  gdev-workspace-state-fields))))

;; I nomi precedenti restano disponibili alle configurazioni personali.
(defalias 'gdev-layout--tab #'gdev-workspace-state-current)
(defalias 'gdev-layout-tab-value #'gdev-workspace-state-get)
(defun gdev-layout-set-tab-value (key value)
  "Conserva il supporto alle chiavi KEY delle configurazioni precedenti."
  (gdev-workspace-state--set key value nil))
(defalias 'gdev-layout-workspace-id #'gdev-workspace-state-ensure-id)

(provide 'gdev-workspace-state)
;;; gdev-workspace-state.el ends here
