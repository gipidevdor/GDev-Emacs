;;; gdev-context.el --- Menu contestuali per documenti e strumenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il menu nativo di Emacs mostra prima le azioni della vista sotto il
;; puntatore. Le azioni riusano i comandi di tastiera. I menu delle
;; modalità e le azioni locali, per esempio quelle di un link, restano
;; accessibili quando il modulo ne fornisce.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'mouse)
(require 'seq)
(require 'gdev-command-context)
(require 'gdev-layout)
(require 'gdev-menu)

(declare-function gdev-comparison-control-at-window "gdev-commands" (&optional window))
(declare-function gdev-editor-document "gdev-commands" ())
(declare-function gdev-sidebar--path-at-point "../sidebar/config" ())
(declare-function gdev-sidebar--selection-at-point "../sidebar/config" ())
(declare-function gdev-timeline--entry-at-point "gdev-timeline" ())
(declare-function gdev-editor-pin-preview "gdev-editor-tabs" (&optional buffer))
(declare-function gdev-workspaces-document-move-available-p "../workspaces/config" (step &optional buffer editor))
(declare-function gdev-workspaces--select-document "../workspaces/config" (editor buffer))
(declare-function gdev-macos-reveal-in-finder "../../os/macos/config" (&optional file))
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function tab-line-select-tab "tab-line" (&optional event))
(declare-function tab-line-close-tab "tab-line" (&optional event))
(declare-function tab-line-close-other-tabs "tab-line" (&optional event))
(declare-function tab-line--get-tab-property "tab-line")
(defvar tab-line-tab-map)

(defvar-local gdev-context-items nil
  "Azioni della vista, nella forma [ETICHETTA COMANDO CONDIZIONE OPZIONI].
CONDIZIONE è facoltativa. Le opzioni :target e :prefix specificano il
contesto (point, selection o view) e il prefisso da passare al comando.")

;;;; Azioni delle viste

(defconst gdev-context--profiles
  '(((gdev-sidebar-mode)
     ["Apri selezione" gdev-sidebar-open (gdev-sidebar--row)]
     ["Apri terminale qui" gdev-sidebar-terminal (gdev-sidebar--row)]
     ["Copia percorsi" gdev-sidebar-copy-paths (gdev-sidebar--path-at-point)]
     ["Copia percorsi relativi" gdev-sidebar-copy-relative-path (gdev-sidebar--path-at-point)]
     ["Confronta file selezionati" gdev-sidebar-compare-selection (gdev-sidebar-compare-selection-p)]
     ["Cronologia del file" gdev-timeline-open (gdev-context--timeline-target)]
     ["Mostra il file aperto" gdev-sidebar-reveal-current-file]
     ["Cerca nell’albero…" gdev-sidebar-find-entry t (:target view)]
     ["Comprimi tutti i rami" gdev-sidebar-collapse-folders t (:target view)]
     ["Aggiorna l’albero" gdev-sidebar-refresh]
     ["Legenda Git" gdev-sidebar-git-legend])
    ((gdev-timeline-mode)
     ["Confronta con il documento" gdev-timeline-compare (gdev-timeline--entry-at-point)]
     ["Confronta con un’altra versione…" gdev-timeline-compare-versions (gdev-timeline--entry-at-point)]
     ["Apri versione" gdev-timeline-visit (gdev-timeline--entry-at-point)]
     ["Ripristina nell’editor…" gdev-timeline-restore (gdev-timeline--entry-at-point)]
     ["Filtra la cronologia…" gdev-timeline-filter t (:target view)]
     ["Aggiorna la cronologia" gdev-timeline-refresh t (:target view)])
    ((gdev-assurance-mode)
     ["Apri voce" push-button (button-at (point))]
     ["Scegli sezione…" gdev-assurance-section t (:target view)]
     ["Filtra voci…" gdev-assurance-filter t (:target view)]
     ["Azzera filtro" gdev-assurance-clear-filter (not (string-empty-p gdev-assurance--filter)) (:target view)]
     ["Passaggio di stato…" gdev-assurance-advance gdev-assurance--transaction]
     ["Scegli standard…" gdev-assurance-select-standards gdev-assurance--transaction]
     ["Registra prova specifica…" gdev-assurance-proof gdev-assurance--transaction]
     ["Decisione sullo standard…" gdev-assurance-standard-decision gdev-assurance--transaction]
     ["Aggiorna" gdev-assurance-refresh t (:target view)]
     ["Guida dell'assicurazione" gdev-assurance-help])
    ((gdev-dashboard-mode)
     ["Apri voce" push-button (button-at (point))]
     ["Nuovo progetto…" gdev-new-project]
     ["Apri file…" gdev-open-file]
     ["Apri cartella…" gdev-open-folder]
     ["Apri recenti…" consult-recent-file]
     ["Aggiorna il cruscotto" gdev-dashboard-refresh])
    ((gdev-search-mode)
     ["Apri cartella…" gdev-open-folder (not (bound-and-true-p gdev-search--roots))]
     ["Apri il risultato" gdev-search-visit (gdev-search--hit-at-point)]
     ["Risultato successivo" gdev-search-next-hit]
     ["Modifica la ricerca…" gdev-search-query]
     ["Filtra i file…" gdev-search-filters]
     ["Azzera filtri" gdev-search-clear-filters (gdev-search-path-filters-p)]
     ["Ripeti la ricerca" gdev-search-repeat]
     ["Anteprima sostituzione…" gdev-search-preview gdev-search--results]
     ["Applica le sostituzioni" gdev-search-apply gdev-search--plan])
    ((gdev-project-view-mode)
     ["Apri voce" push-button (button-at (point))]
     ["Scegli profilo di avvio…" gdev-project-view-select-profile
      (eq (bound-and-true-p gdev-activity-kind) 'run)]
     ["Avvia" gdev-project-view-launch (eq (bound-and-true-p gdev-activity-kind) 'run)]
     ["Apri stato Git" gdev-git-status (eq (bound-and-true-p gdev-activity-kind) 'git)])
    ((dired-mode)
     ["Apri" dired-find-file (dired-get-filename nil t)]
     ["Apri a fianco" dired-find-file-other-window (dired-get-filename nil t)]
     ["Nuova cartella…" dired-create-directory]
     ["Rinomina…" dired-do-rename (gdev-context--dired-entry-p) (:prefix 1)]
     ["Copia file…" dired-do-copy (gdev-context--dired-entry-p) (:prefix 1)]
     ["Aggiorna la cartella" revert-buffer]
     ["Segna per l’eliminazione" dired-flag-file-deletion (gdev-context--dired-entry-p)])
    ((forge-topic-mode forge-topics-mode forge-repository-list-mode forge-notifications-mode)
     ["Apri argomento" forge-visit-this-topic]
     ["Scrivi un commento…" forge-create-post (derived-mode-p 'forge-topic-mode)]
     ["Apri su GitHub" forge-browse]
     ["Aggiorna" magit-refresh])
    ((magit-status-mode)
     ["Apri voce Git" magit-visit-thing]
     ["Prepara modifica" magit-stage (memq (magit-diff-type) '(unstaged untracked))
      (:target selection)]
     ["Rimuovi dalla selezione per il commit" magit-unstage (eq (magit-diff-type) 'staged)
      (:target selection)]
     ["Differenze…" magit-diff]
     ["Cronologia…" magit-log]
     ["Registra…" magit-commit]
     ["Aggiorna lo stato" magit-refresh])
    ((magit-diff-mode)
     ["Apri il file della modifica" magit-diff-visit-file]
     ["Vai al blocco successivo" magit-section-forward]
     ["Prepara modifica" magit-stage (memq (magit-diff-type) '(unstaged untracked))
      (:target selection)]
     ["Rimuovi dalla selezione per il commit" magit-unstage (eq (magit-diff-type) 'staged)
      (:target selection)]
     ["Aggiorna le differenze" magit-refresh])
    ((magit-mode)
     ["Apri voce Git" magit-visit-thing]
     ["Mostra le differenze…" magit-diff]
     ["Vai alla sezione successiva" magit-section-forward]
     ["Aggiorna" magit-refresh])
    ((gdev-github-draft-mode)
     ["Invia bozza" gdev-github-draft-send (not buffer-read-only) (:target view)]
     ["Annulla bozza" gdev-github-draft-cancel (not buffer-read-only) (:target view)]
     ["Guida di HitHub" hithub-guida t (:target view)])
    ((gdev-github-result-mode)
     ["Guida di HitHub" hithub-guida t (:target view)])
    ((gdev-github-view-mode)
     ["Apri la voce" gdev-github-view-open (get-text-property (point) 'gdev-github-item) (:target view)]
     ["Azioni sulla voce…" gdev-github-view-actions (get-text-property (point) 'gdev-github-item)
      (:target view)]
     ["Apri su GitHub" gdev-github-view-browse t (:target view)]
     ["Nuova voce nella sezione" gdev-github-view-create t (:target view)]
     ["Aggiorna" gdev-github-view-refresh t (:target view)]
     ["Guida di HitHub" hithub-guida t (:target view)])
    ((gdev-github-topic-mode)
     ["Azioni sulla conversazione…" gdev-github-topic-actions t (:target view)]
     ["Aggiorna" gdev-github-topic-refresh t (:target view)]
     ["Guida di HitHub" hithub-guida t (:target view)])
    ;; Gli stessi comandi della tastiera: agiscono sulla sessione di questo spazio.
    ((dape-info-parent-mode dape-repl-mode dape-memory-mode dape-disassemble-mode)
     ["Continua" gdev-debug-continue]
     ["Passo successivo" gdev-debug-next]
     ["Entra nella funzione" gdev-debug-step-in]
     ["Esci dalla funzione" gdev-debug-step-out]
     ["Riavvia" gdev-debug-restart]
     ["Termina la sessione" gdev-debug-terminate])
    ((flymake-diagnostics-buffer-mode flymake-project-diagnostics-mode)
     ["Apri la segnalazione" flymake-goto-diagnostic (tabulated-list-get-id)]
     ["Problema precedente" (gdev-checkers-previous previous-line) (tabulated-list-get-id)]
     ["Problema successivo" (gdev-checkers-next next-line) (tabulated-list-get-id)]
     ["Problemi del documento" gdev-checkers-document-problems
      (derived-mode-p 'flymake-project-diagnostics-mode) (:target view)]
     ["Problemi del progetto" gdev-checkers-project-problems
      (derived-mode-p 'flymake-diagnostics-buffer-mode) (:target view)]
     ["Mostra solo gli errori" gdev-checkers-toggle-errors
      (not (bound-and-true-p gdev-checkers-errors-only)) (:target view)]
     ["Mostra tutte le segnalazioni" gdev-checkers-toggle-errors
      (bound-and-true-p gdev-checkers-errors-only) (:target view)]
     ["Aggiorna le segnalazioni" revert-buffer t (:target view)])
    ((grep-edit-mode)
     ["Termina la modifica" grep-edit-save-changes])
    ((grep-mode)
     ["Apri il risultato" compile-goto-error (gdev-context--compilation-location-p)]
     ["Risultato precedente" compilation-previous-error]
     ["Risultato successivo" compilation-next-error]
     ["Modifica i risultati" (grep-change-to-grep-edit-mode wgrep-change-to-wgrep-mode)
      (and buffer-read-only (not (get-buffer-process (current-buffer))))]
     ["Applica le modifiche" wgrep-finish-edit (not buffer-read-only)]
     ["Annulla le modifiche" wgrep-abort-changes (not buffer-read-only)]
     ["Ripeti la ricerca" recompile])
    ((occur-edit-mode occur-mode)
     ["Apri il risultato" occur-mode-goto-occurrence]
     ["Risultato precedente" occur-prev]
     ["Risultato successivo" occur-next]
     ["Modifica i risultati" occur-edit-mode buffer-read-only]
     ["Termina la modifica" occur-cease-edit (not buffer-read-only)]
     ["Aggiorna i risultati" revert-buffer])
    ((xref--xref-buffer-mode)
     ["Apri il riferimento" xref-goto-xref]
     ["Mostra il riferimento" xref-show-location-at-point])
    ((compilation-mode)
     ["Apri la segnalazione" compile-goto-error (gdev-context--compilation-location-p)]
     ["Problema precedente" compilation-previous-error]
     ["Problema successivo" compilation-next-error]
     ["Ripeti il comando" recompile (not (get-buffer-process (current-buffer)))]
     ["Interrompi l’operazione" gdev-workbench-operation-cancel (process-live-p (get-buffer-process (current-buffer)))
      (:target view)])
    ((diff-mode)
     ["Apri il file della modifica" diff-goto-source]
     ["Blocco precedente" diff-hunk-prev]
     ["Blocco successivo" diff-hunk-next]
     ["Vai al file successivo" diff-file-next])
    ((ediff-mode)
     ["Differenza precedente" ediff-previous-difference]
     ["Differenza successiva" ediff-next-difference]
     ["Vai alla differenza…" ediff-jump-to-difference]
     ["Aggiorna le differenze" ediff-update-diffs])
    ((ibuffer-mode)
     ["Apri il buffer" ibuffer-visit-buffer]
     ["Raggruppa per progetto" gdev-ibuffer-group-by-project]
     ["Segna il buffer" ibuffer-mark-forward]
     ["Aggiorna l’elenco" ibuffer-update])
    ((Buffer-menu-mode)
     ["Apri il buffer" Buffer-menu-this-window]
     ["Apri a fianco" Buffer-menu-other-window]
     ["Aggiorna l’elenco" revert-buffer])
    ((vundo-mode)
     ["Modifica precedente" vundo-backward]
     ["Modifica successiva" vundo-forward]
     ["Mostra le differenze" vundo-diff]
     ["Conferma la versione" vundo-confirm]
     ["Annulla l’anteprima" vundo-quit])
    ((devdocs-mode)
     ["Cerca nella documentazione…" devdocs-lookup]
     ["Pagina precedente" devdocs-go-back]
     ["Pagina successiva" devdocs-go-forward])
    ((Info-mode)
     ["Apri il collegamento" Info-follow-nearest-node]
     ["Cerca nel manuale…" Info-search]
     ["Pagina precedente" Info-history-back]
     ["Pagina successiva" Info-history-forward]
     ["Indice del manuale" Info-up])
    ((help-mode)
     ["Apri collegamento" push-button (button-at (point))]
     ["Pagina precedente" help-go-back]
     ["Pagina successiva" help-go-forward])
    ((Man-mode woman-mode)
     ["Apri riferimento" Man-follow-manual-reference]
     ["Sezione precedente" Man-previous-section]
     ["Sezione successiva" Man-next-section])
    ((eww-mode)
     ["Apri collegamento" eww-follow-link (get-text-property (point) 'shr-url)]
     ["Pagina precedente" eww-back-url]
     ["Pagina successiva" eww-forward-url]
     ["Ricarica pagina" eww-reload])
    ((eat-mode)
     ["Nuovo terminale con profilo…" gdev-term-new-profile t (:target view)]
     ["Affianca un terminale" gdev-term-split (gdev-term-split-available-p) (:target view)]
     ["Vai al terminale affiancato" gdev-term-focus-other (gdev-term-split-visible-p) (:target view)]
     ["Incolla nel terminale" eat-yank (and (bound-and-true-p eat-terminal) (not buffer-read-only))]
     ["Attiva la selezione del testo" eat-emacs-mode (not buffer-read-only)]
     ["Torna all’immissione nel terminale" eat-semi-char-mode
      (and buffer-read-only (bound-and-true-p eat-terminal))]
     ["Reimposta il terminale" eat-reset (bound-and-true-p eat-terminal)])
    ((eshell-mode)
     ["Nuovo terminale qui" gdev-eshell-here]
     ["Cerca nella cronologia…" consult-history]
     ["Interrompi il processo" eshell-interrupt-process]
     ["Pulisci l’output" eshell-clear])
    ((comint-mode sly-mrepl-mode)
     ["Cerca nella cronologia…" consult-history]
     ["Pulisci l’output" comint-clear-buffer (derived-mode-p 'comint-mode)]
     ["Interrompi il processo" comint-interrupt-subjob (derived-mode-p 'comint-mode)])
    ((logview-mode)
     ["Voce precedente" logview-previous-entry]
     ["Voce successiva" logview-next-entry]
     ["Mostra solo gli errori" logview-show-only-errors]
     ["Rimuovi i filtri" logview-reset-all-filters])
    ((x509-asn1-mode)
     ["Mostra o nascondi i byte" x509-asn1-toggle-hexl])
    ((org-mode)
     ["Apri il collegamento" org-open-at-point (org-in-regexp org-link-any-re)]
     ["Espandi o comprimi sezione" org-cycle (org-at-heading-p)]
     ["Cambia stato dell’attività" org-todo (org-at-heading-p)]
     ["Esporta…" org-export-dispatch])
    ((gdev-minimap-mode)
     ["Torna all’editor" gdev-focus-editor]
     ["Nascondi la minimappa" gdev-minimap-toggle]))
  "Azioni principali per modalità. Le modalità più specifiche vengono prima.")

(defun gdev-context--editor-p ()
  "Restituisce non nil se qui hanno senso le azioni sul testo."
  (or (minibufferp) buffer-file-name (derived-mode-p 'text-mode 'prog-mode 'conf-mode)))

(defun gdev-context--dired-entry-p ()
  "Restituisci non nil per una voce di Dired modificabile individualmente."
  (when-let* ((file (dired-get-filename nil t)))
    (not (member (file-name-nondirectory file) '("." "..")))))

(defun gdev-context--compilation-location-p ()
  "Restituisci non nil se la riga corrente rinvia a un file o a una cartella."
  (or (get-text-property (point) 'compilation-directory)
      (text-property-not-all (line-beginning-position) (line-end-position)
                             'compilation-message nil)))

(defun gdev-context-view-items ()
  "Restituisci le azioni dichiarate dalla vista corrente e dal suo profilo."
  (let ((profile (seq-find (lambda (entry) (apply #'derived-mode-p (car entry)))
                           gdev-context--profiles)))
    (append gdev-context-items (cdr profile))))

(defun gdev-context-item-command (item)
  "Restituisci il primo comando interattivo dichiarato da ITEM."
  (let ((choice (aref item 1)))
    (cond ((commandp choice) choice)
          ((consp choice) (seq-find #'commandp choice)))))

(defun gdev-context--timeline-target ()
  "Restituisci il file locale indicato nell'albero o nel gruppo attivo."
  (let* ((sidebar (derived-mode-p 'gdev-sidebar-mode))
         (file (if sidebar
                   (when-let* ((selection (gdev-sidebar--selection-at-point))
                               ((null (cdr selection))))
                     (car selection))
                 (when-let* ((document (gdev-editor-document))) (buffer-file-name document)))))
    (and file (not (file-remote-p file)) (not (and sidebar (file-directory-p file))) file)))

(defun gdev-context-copy-path (&optional file)
  "Copia negli appunti il percorso di FILE o di quello nel contesto corrente."
  (interactive)
  (kill-new (or file (gdev-command-file) (user-error "Nessun file nel contesto")))
  (message "Percorso copiato"))

;;;; Contesto ed esecuzione

(cl-defstruct (gdev-context--target (:constructor gdev-context--target-create))
  window buffer mode tick position region click sidebar-selection)

(defun gdev-context--same-view-p (target scope)
  "Verifica che TARGET rappresenti ancora la vista richiesta da SCOPE."
  (let ((window (gdev-context--target-window target))
        (buffer (gdev-context--target-buffer target)))
    (and (window-live-p window) (eq (window-buffer window) buffer)
         (eq (gdev-context--target-mode target) (buffer-local-value 'major-mode buffer))
         (or (eq scope 'view)
             (= (gdev-context--target-tick target) (buffer-chars-modified-tick buffer))))))

(defun gdev-context--position (target scope)
  "Restituisci la posizione da usare in TARGET per SCOPE."
  (unless (or (eq scope 'view)
              (and (eq scope 'selection) (gdev-context--target-region target)))
    (gdev-context--target-position target)))

(defun gdev-context--inspect (target scope function)
  "Valuta FUNCTION nel contesto di TARGET e SCOPE, conservando il fuoco."
  (when (gdev-context--same-view-p target scope)
    (with-selected-window (gdev-context--target-window target)
      (save-mark-and-excursion
        (let ((position (gdev-context--position target scope)))
          (when (or (null position) (<= (point-min) position (point-max)))
            (let ((mark-active (and mark-active (null position))))
              (when position (goto-char position))
              (funcall function))))))))

(defun gdev-context--dispatch (target scope command prefix condition)
  "Esegui COMMAND nel TARGET di SCOPE con PREFIX se vale ancora CONDITION."
  (unless (gdev-context--inspect
           target scope
           (lambda ()
             (when (and (gdev-context--position target scope) (derived-mode-p 'gdev-sidebar-mode)
                        (not (equal (gdev-context--target-sidebar-selection target)
                                    (gdev-sidebar--selection-at-point))))
               (user-error "La selezione è cambiata. Riapri il menu contestuale"))
             (when-let* (((eq scope 'selection))
                         (region (gdev-context--target-region target)))
               (unless (equal region (and (use-region-p)
                                          (cons (region-beginning) (region-end))))
                 (user-error "La selezione è cambiata. Riapri il menu contestuale")))
             (eval condition t)))
    (user-error "La vista è cambiata. Riapri il menu contestuale"))
  (select-window (gdev-context--target-window target))
  (when-let* ((position (gdev-context--position target scope)))
    (goto-char position)
    (when mark-active (deactivate-mark)))
  (let* ((click (gdev-context--target-click target))
         (last-input-event (and (mouse-event-p click) click))
         (current-prefix-arg prefix))
    (setq this-command command)
    (call-interactively command nil (and last-input-event (vector click)))))

(defun gdev-context--add-items (menu items target &optional scope)
  "Aggiungi a MENU le azioni ITEMS per TARGET, con contesto SCOPE."
  (dolist (item items)
    (let* ((command (gdev-context-item-command item))
           (condition (if (> (length item) 2) (aref item 2) t))
           (options (when (> (length item) 3) (aref item 3)))
           (at (or (plist-get options :target) scope 'point))
           (prefix (plist-get options :prefix)))
      (when (and command (gdev-context--inspect target at (lambda () (eval condition t))))
        (define-key-after menu (vector (if (symbolp command) command (make-symbol "azione")))
          `(menu-item ,(aref item 0)
                      ,(lambda ()
                         (interactive)
                         (gdev-context--dispatch target at command prefix condition))
                      :keys ""))))))

(defun gdev-context--language-items (items &optional group)
  "Appiattisci le voci ITEMS, anteponendo a ogni etichetta il GROUP."
  (mapcan (lambda (item)
            (if (vectorp item)
                (list (vector (concat group (aref item 0)) (aref item 1)))
              (gdev-context--language-items
               (cdr item) (concat group (car item) " · "))))
          items))

(defun gdev-context--action-labels ()
  "Raccogli i nomi delle azioni disponibili nel contesto corrente."
  (let ((labels (make-hash-table :test #'eq)))
    (dolist (item (gdev-menu-command-items)) (puthash (cdr item) (car item) labels))
    (dolist (item (gdev-context-view-items))
      (when-let* ((command (gdev-context-item-command item)))
        (puthash command (aref item 0) labels)))
    labels))

(defun gdev-context-mode-actions ()
  "Scegli un comando dalle scorciatoie della modalità corrente."
  (interactive)
  (let ((shortcuts (make-hash-table :test #'eq))
        (labels (gdev-context--action-labels))
        commands)
    (dolist (entry (accessible-keymaps (current-local-map)))
      (unless (seq-intersection (car entry) [menu-bar tool-bar tab-bar tab-line])
        (map-keymap
         (lambda (event binding)
           (let* ((command (if (stringp (car-safe binding)) (cdr binding) binding))
                  (keys (vconcat (car entry) (vector event))))
             (when (and (symbolp command) (commandp command)
                        (not (mouse-event-p event))
                        (eq (key-binding keys) command))
               (let ((previous (gethash command shortcuts)))
                 (unless previous (push command commands))
                 (when (or (not previous) (< (length keys) (length previous)))
                   (puthash command keys shortcuts))))))
         (cdr entry))))
    (unless commands (user-error "Questa vista non definisce comandi propri"))
    (let* ((choices
            (mapcar (lambda (command)
                      (cons (concat (or (gethash command labels) (gdev-menu--command-label command))
                                    " · " (gdev-menu-key-label (gethash command shortcuts)))
                            command))
                    commands))
           (command (cdr (assoc-string (completing-read "Comando della vista: " choices nil t) choices))))
      (setq this-command command)
      (call-interactively command))))

(defun gdev-context--add-shortcuts (menu label event map prefix target)
  "Aggiungi a MENU le scorciatoie di MAP come sottomenu LABEL con EVENT."
  (when map
    (let ((submenu (make-sparse-keymap label))
          (items (gdev-context--language-items (gdev-menu--items map prefix))))
      (gdev-context--add-items submenu items target 'selection)
      (when (seq-some #'consp (cdr submenu))
        (define-key-after menu (vector event) (list 'menu-item label submenu))))))

(defun gdev-context--native-expression (target expression)
  "Rinvia EXPRESSION al momento in cui il menu la valuta in TARGET."
  `(gdev-context--inspect ',target 'selection (lambda () ,expression)))

(defconst gdev-context--native-labels
  '(("Operate" . "Operazioni") ("Immediate" . "Azioni dirette") ("Mark" . "Seleziona")
    ("Regexp" . "Espressioni regolari") ("Subdir" . "Sottocartelle") ("View" . "Vista")
    ("Help-Mode" . "Aiuto") ("Info" . "Manuale") ("Diff" . "Differenze")
    ("Directory" . "Cartella") ("New Directory" . "Nuova cartella")
    ("Copy" . "Copia") ("Delete" . "Elimina") ("Rename" . "Rinomina")
    ("Search" . "Cerca") ("Revert" . "Ricarica") ("Refresh" . "Aggiorna")
    ("Quit" . "Chiudi vista") ("Next" . "Successivo") ("Previous" . "Precedente"))
  "Etichette dei menu forniti da Emacs riutilizzate nel menu contestuale.")

(defun gdev-context--native-label (label)
  "Restituisci il testo di LABEL secondo le etichette del menu contestuale."
  (or (cdr (assoc label gdev-context--native-labels)) label))

(defun gdev-context--native-entry (binding target)
  "Adatta BINDING, conservandone le proprietà e il contesto TARGET."
  (pcase binding
    ((pred (lambda (item) (equal item menu-bar-separator))) binding)
    (`(menu-item ,label ,action . ,properties)
     (let* ((properties (copy-sequence properties))
            (filter (plist-get properties :filter))
            (enabled (if (plist-member properties :enable) (plist-get properties :enable) t))
            (visible (if (plist-member properties :visible) (plist-get properties :visible) t))
            (condition `(and ,enabled ,visible)))
       (dolist (property '(:enable :visible :help))
         (when-let* ((value (plist-get properties property))
                     ((not (stringp value))))
           (setq properties (plist-put properties property
                                       (gdev-context--native-expression target value)))))
       (when-let* ((button (plist-get properties :button)))
         (setq properties (plist-put properties :button
                                     (cons (car button)
                                           (gdev-context--native-expression target (cdr button))))))
       `(menu-item
         ,(if (stringp label) (gdev-context--native-label label)
            (gdev-context--native-expression target `(gdev-context--native-label ,label)))
         ,action
         ,@(plist-put properties :filter
                      (lambda (definition)
                        (let ((value (if filter
                                         (gdev-context--inspect target 'selection
                                                                (lambda () (funcall filter definition)))
                                       definition)))
                          (cond
                           ((keymapp value) (gdev-context--native-map value target))
                           ((commandp value)
                            (lambda ()
                              (interactive)
                              (gdev-context--dispatch target 'selection value nil condition)))
                           (t value))))))))
    (`(,(and label (pred stringp)) . ,action)
     (gdev-context--native-entry
      (list 'menu-item label (if (stringp (car-safe action)) (cdr action) action)) target))))

(defun gdev-context--native-map (original target)
  "Ricostruisci un livello di ORIGINAL per TARGET."
  (let ((menu (make-sparse-keymap (gdev-context--native-label (keymap-prompt original)))))
    (map-keymap (lambda (event binding)
                  (when-let* ((entry (gdev-context--native-entry binding target)))
                    (define-key-after menu (vector event) entry)))
                original)
    menu))

(defun gdev-context--extra-menus (menu native target)
  "Aggiungi a MENU le azioni secondarie di NATIVE e della modalità di TARGET."
  (gdev-context--add-shortcuts menu "Linguaggio" 'gdev-language
                               (gdev-menu--language-map) "C-c l" target)
  (when (derived-mode-p 'prog-mode 'conf-mode)
    (gdev-context--add-shortcuts menu "Codice" 'gdev-code gdev-code-map
                                 "C-c c" target))
  (when (keymapp native)
    (when-let* ((map (local-key-binding [menu-bar]))
                (mode-menu (menu-bar-keymap map))
                ((keymapp mode-menu)))
      (map-keymap (lambda (event binding)
                    (when (and (consp binding) (not (assq event (cdr native))))
                      (define-key-after native (vector event) (copy-sequence binding))))
                  mode-menu))
    (let ((extra (gdev-context--native-map native target)))
      (when (seq-some #'consp (cdr extra))
        (define-key-after menu [gdev-other] (list 'menu-item "Altri comandi" extra)))))
  (gdev-context--add-items menu '(["Cerca un comando della vista…" gdev-context-mode-actions
                                  (current-local-map)])
                           target 'selection))

(defconst gdev-context--stock-functions
  '(context-menu-undo context-menu-region context-menu-middle-separator
    context-menu-local context-menu-minor context-menu-send-to)
  "Gruppi di Emacs sostituiti dal menu contestuale di GDev.")

(defun gdev-context--view-menu (target native)
  "Costruisci il menu di TARGET con le estensioni raccolte in NATIVE."
  (let ((menu (make-sparse-keymap (propertize "Menu contestuale" 'hide t))))
    (gdev-context--add-items menu (gdev-context-view-items) target)
    (gdev-context--add-items
     menu '(["Guida di Hit" hit-guida (derived-mode-p 'magit-mode) (:target view)]
            ["Copia percorso" gdev-context-copy-path
             (and (not (derived-mode-p 'gdev-sidebar-mode)) (gdev-command-file))]
            ["Mostra nel Finder" gdev-macos-reveal-in-finder
             (and (commandp 'gdev-macos-reveal-in-finder)
                  (when-let* ((file (gdev-command-file))) (not (file-remote-p file))))]
            ["Annulla" gdev-undo (gdev-undo-available-p) (:target view)]
            ["Ripeti" gdev-redo (gdev-redo-available-p) (:target view)])
     target)
    (when (or (gdev-context--editor-p) (gdev-context--target-region target))
      (let ((region (gdev-context--target-region target)))
        (gdev-context--add-items
         menu (list (vector (if region "Taglia" "Taglia riga") 'gdev-cut-dwim
                            '(and (not buffer-read-only) (or (use-region-p) (not (minibufferp)))))
                    (vector (if region "Copia" "Copia riga") 'gdev-copy-dwim
                            '(or (use-region-p) (not (minibufferp)))))
         target 'selection))
      (gdev-context--add-items
       menu '(["Incolla" yank (not buffer-read-only)]
              ["Confronta con un altro file…" gdev-compare-files buffer-file-name (:target view)]
              ["Confronta con il file salvato" gdev-compare-with-saved buffer-file-name (:target view)]
              ["Cronologia del file" gdev-timeline-open
               (and buffer-file-name (not (file-remote-p buffer-file-name))) (:target view)]
              ["Esegui test al cursore" gdev-project-view-test-at-point
               (and (gdev-module-p :tools 'build) buffer-file-name (derived-mode-p 'prog-mode))]
              ["Riesegui i test falliti" gdev-project-view-test-failed
               (and (gdev-module-p :tools 'build) buffer-file-name (derived-mode-p 'prog-mode))]
              ["Commenta" comment-line (and comment-start (not buffer-read-only)
                                           (derived-mode-p 'prog-mode 'conf-mode))]
              ["Formatta" gdev-format-dwim (gdev-menu--can-format-p)]
              ["Definizione" gdev-find-definition (derived-mode-p 'prog-mode)]
              ["Tutti i riferimenti" gdev-find-references (derived-mode-p 'prog-mode)]
              ["Vai all’implementazione" gdev-lsp-find-implementation
               (gdev-lsp-capable-p :implementationProvider)]
              ["Vai alla definizione del tipo" gdev-lsp-find-type-definition
               (gdev-lsp-capable-p :typeDefinitionProvider)]
              ["Rinomina simbolo…" gdev-lsp-rename (gdev-lsp-capable-p :renameProvider)]
              ["Estrai selezione…" gdev-lsp-extract (and (use-region-p)
                                                       (gdev-lsp-capable-p :codeActionProvider))]
              ["Correzioni rapide…" gdev-lsp-quick-fix (gdev-lsp-capable-p :codeActionProvider)])
       target 'selection))
    (gdev-context--extra-menus menu native target)
    (when (seq-some #'consp (cdr menu))
      (define-key-after menu [gdev-context-separator] menu-bar-separator))
    (gdev-context--add-items
     menu (if (window-minibuffer-p (gdev-context--target-window target))
              '(["Annulla" abort-recursive-edit t (:target view)])
            (list ["Cerca nella vista…" isearch-forward]
                  (vector (if (and (fboundp 'gdev-comparison-control-at-window)
                                   (gdev-comparison-control-at-window))
                              "Termina il confronto"
                            "Chiudi vista")
                          'gdev-close-document t '(:target view))))
     target)
    menu))

(defun gdev-context--map (original &optional click)
  "Costruisci il menu del CLICK. ORIGINAL raccoglie le estensioni di Emacs."
  (let* ((click (or click last-input-event))
         (start (event-start click))
         (window (posn-window start)))
    (if (not (window-live-p window))
        (funcall original click)
      (with-selected-window window
        (let* ((at (posn-point start))
               (position (and (integer-or-marker-p at) (if (markerp at) (marker-position at) at)))
               (position (and position (<= (point-min) position (point-max)) position))
               (region (when (and position (use-region-p)
                                  (<= (region-beginning) position (region-end)))
                         (cons (region-beginning) (region-end))))
               (target (gdev-context--target-create
                        :window window :buffer (current-buffer) :mode major-mode
                        :tick (buffer-chars-modified-tick) :position position :region region
                        :click click
                        :sidebar-selection (when (and position (derived-mode-p 'gdev-sidebar-mode))
                                             (save-excursion (goto-char position)
                                                             (gdev-sidebar--selection-at-point)))))
               (context-menu-functions
                (seq-remove (lambda (function) (memq function gdev-context--stock-functions))
                            context-menu-functions))
               (native (gdev-context--inspect target 'selection (lambda () (funcall original click)))))
          (gdev-context--view-menu target native))))))

;;;; Schede di documento e spazi di lavoro

(defun gdev-context-tab (event)
  "Apri il menu della scheda di documento o strumento indicata da EVENT."
  (interactive "e")
  (let* ((menu (make-sparse-keymap (propertize "Scheda" 'hide t)))
         (string (car (posn-string (event-start event))))
         (tab (and string (tab-line--get-tab-property 'tab string)))
         (source (posn-window (event-start event)))
         (buffer (if (bufferp tab) tab (cdr (assq 'buffer tab))))
         (file (and (buffer-live-p buffer) (buffer-file-name buffer))))
    (define-key-after menu [select]
      `(menu-item "Apri scheda"
                  ,(lambda ()
                     (interactive)
                     (if (and (window-live-p source) (buffer-live-p buffer)
                              (gdev-layout-document-tab-p buffer)
                              (fboundp 'gdev-workspaces--select-document))
                         (gdev-workspaces--select-document source buffer)
                       (tab-line-select-tab event)))))
    (when (and (window-live-p source) (buffer-live-p buffer)
               (fboundp 'gdev-workspaces-document-move-available-p))
      (let* ((frame (window-frame source))
             (owner (gdev-workspace-state-id frame)))
        (dolist (entry '((-1 "Sposta scheda a sinistra" . gdev-workspaces-move-document-left)
                         (1 "Sposta scheda a destra" . gdev-workspaces-move-document-right)))
          (pcase-let ((`(,step ,title . ,command) entry))
            (define-key-after menu (vector command)
              `(menu-item ,title
                          ,(lambda ()
                             (interactive)
                             (unless (and (window-live-p source)
                                          (eq owner (gdev-workspace-state-id frame))
                                          (gdev-workspaces-document-move-available-p step buffer source))
                               (user-error "Lo spazio o la scheda sono cambiati. Riapri il menu"))
                             (funcall command buffer source))
                          :enable ,(gdev-workspaces-document-move-available-p step buffer source)))))))
    (when (and gdev-layout-mode (window-live-p source) (not (window-parameter source 'window-side))
               (buffer-live-p buffer) (gdev-layout-document-tab-p buffer)
               (not (eq buffer (window-buffer source))))
      (dolist (direction '(right below))
        (let ((side direction))
          (define-key-after menu (vector side)
            `(menu-item ,(if (eq side 'right) "Apri a destra" "Apri in basso")
                        ,(lambda ()
                           (interactive)
                           (gdev-layout-open-document-beside buffer source side)))))))
    (when (and buffer (fboundp 'gdev-editor-preview-buffer-p)
               (gdev-editor-preview-buffer-p buffer))
      (define-key-after menu [pin]
        `(menu-item "Fissa anteprima" ,(lambda () (interactive) (gdev-editor-pin-preview buffer)))))
    (when file
      (define-key-after menu [copy-path]
        `(menu-item "Copia percorso" ,(lambda () (interactive) (gdev-context-copy-path file))))
      (when (and (commandp 'gdev-macos-reveal-in-finder) (not (file-remote-p file)))
        (define-key-after menu [reveal]
          `(menu-item "Mostra nel Finder" ,(lambda () (interactive) (gdev-macos-reveal-in-finder file))))))
    (when (commandp 'tab-line-close-other-tabs)
      (define-key-after menu [close-others]
        `(menu-item "Chiudi le altre schede"
                    ,(lambda () (interactive) (tab-line-close-other-tabs event)))))
    (define-key-after menu [close]
      `(menu-item "Chiudi scheda" ,(lambda () (interactive) (tab-line-close-tab event))))
    (popup-menu menu event)))

(defun gdev-context--workspace-index (frame tab)
  "Restituisci l'indice corrente di TAB in FRAME e seleziona FRAME."
  (unless (frame-live-p frame) (user-error "La finestra dello spazio è stata chiusa"))
  (let ((position (seq-position (tab-bar-tabs frame) tab #'eq)))
    (unless position (user-error "Lo spazio è cambiato. Riapri il menu contestuale"))
    (select-frame frame)
    (1+ position)))

(defun gdev-context-workspace (event)
  "Apri il menu dello spazio di lavoro indicato da EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (window (posn-window start))
         (frame (if (framep window) window (window-frame window)))
         (item (tab-bar--event-to-item start))
         (number (tab-bar--key-to-number (car item)))
         (tabs (tab-bar-tabs frame))
         (tab (cond ((integerp number) (nth (1- number) tabs))
                    ((null number) (assq 'current-tab tabs))))
         (menu (make-sparse-keymap (propertize "Spazio di lavoro" 'hide t))))
    (if (eq number t)
        (progn
          (define-key-after menu [new] '(menu-item "Nuovo spazio di lavoro" tab-bar-new-tab))
          (when (bound-and-true-p tab-bar-closed-tabs)
            (define-key-after menu [reopen]
              '(menu-item "Riapri l’ultimo spazio chiuso" tab-bar-undo-close-tab))))
      (when tab
        (unless (eq (car tab) 'current-tab)
          (define-key-after menu [select]
            `(menu-item "Apri spazio di lavoro"
                        ,(lambda () (interactive)
                           (tab-bar-select-tab (gdev-context--workspace-index frame tab))))))
        (define-key-after menu [rename]
          `(menu-item "Rinomina…"
                      ,(lambda ()
                         (interactive)
                         (gdev-context--workspace-index frame tab)
                         (let ((name (read-string "Nome dello spazio: " (alist-get 'name (cdr tab)))))
                           (unless (string-blank-p name)
                             (tab-bar-rename-tab name (gdev-context--workspace-index frame tab)))))))
        (define-key-after menu [duplicate]
          `(menu-item "Duplica"
                      ,(lambda () (interactive)
                         (tab-bar-duplicate-tab nil (gdev-context--workspace-index frame tab)))))
        (when (cdr tabs)
          (define-key-after menu [close]
            `(menu-item "Chiudi spazio di lavoro"
                        ,(lambda ()
                           (interactive)
                           (when (cdr (tab-bar-tabs frame))
                             (tab-bar-close-tab (gdev-context--workspace-index frame tab)))))))))
    (popup-menu menu event)))

(defvar gdev-context--priority-map
  (list (cons 'context-menu-mode context-menu-mode-map))
  "Dà la precedenza al menu anche nelle aree di testo che inoltrano il mouse.")

(defun gdev-context-install ()
  "Installa i menu contestuali di GDev."
  (advice-add 'context-menu-map :around #'gdev-context--map)
  (add-to-list 'emulation-mode-map-alists 'gdev-context--priority-map)
  (context-menu-mode 1)
  (when (fboundp 'tab-bar-mouse-context-menu)
    (keymap-set tab-bar-map "<down-mouse-3>" #'gdev-context-workspace))
  (with-eval-after-load 'tab-line
    (keymap-set tab-line-tab-map "<tab-line> <down-mouse-3>" #'gdev-context-tab)
    (when (featurep 'ns)
      (keymap-set tab-line-tab-map "<tab-line> C-<down-mouse-1>" #'gdev-context-tab))))

(provide 'gdev-context)
;;; gdev-context.el ends here
