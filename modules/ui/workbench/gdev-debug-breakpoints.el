;;; gdev-debug-breakpoints.el --- Punti di interruzione del sorgente -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il riquadro è una proiezione dei punti sorgente del fork Dape.
;; I risultati di verifica appartengono alla connessione scelta nello spazio.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'dape)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-roots)

(declare-function gdev-close-document "gdev-commands" ())
(declare-function gdev-focus-editor "gdev-commands" ())
(declare-function gdev-debug-workspace-connection "../../tools/debugger/config"
                  (owner &optional connections))
(defvar gdev-context-items)

(defconst gdev-debug-breakpoints--types
  '((nil "●" "Semplice") (expression "◇" "Condizione" "Espressione")
    (hits "#" "Passaggi" "Condizione sul numero di passaggi")
    (log "□" "Messaggio" "Messaggio da registrare (espressioni tra {})")
    (until "→" "Temporaneo"))
  "Simboli, nomi e richieste di valore dei punti sorgente.")

(defvar-local gdev-debug-breakpoints--owner nil)
(defvar-local gdev-debug-breakpoints--snapshot nil)

(defun gdev-debug-breakpoints--state (breakpoint connection)
  "Descrivi lo stato di BREAKPOINT per CONNECTION."
  (let ((verification (dape--breakpoint-verified breakpoint)))
    (cond
     ((dape--breakpoint-disabled breakpoint)
      '("○ Disattivato" gdev-ui-secondary))
     ((null connection) '("Attivo" gdev-ui-secondary))
     ((not (dape-source-breakpoint-supported-p connection breakpoint))
      '("! Tipo non supportato" gdev-ui-status-warning))
     ((plist-get verification connection) '("✓ Verificato" gdev-ui-status-success))
     ((plist-member verification connection) '("! Non verificato" gdev-ui-status-warning))
     (t '("◌ In attesa di verifica" gdev-ui-secondary)))))

(defun gdev-debug-breakpoints--entries (roots connection)
  "Raccogli i punti sorgente di ROOTS e quelli della CONNECTION attiva."
  (cl-loop for breakpoint in dape--breakpoints
           for file = (dape--breakpoint-file-name breakpoint)
           for line = (dape--breakpoint-line breakpoint)
           for root = (and file (gdev-workspace-root-for file roots))
           when (and line (or (null roots) root
                              (and connection
                                   (plist-member (dape--breakpoint-verified breakpoint)
                                                 connection))))
           collect (list breakpoint (if root (substring file (length root))
                                      (or file (buffer-name (dape--breakpoint-buffer breakpoint))))
                         file line (dape--source-breakpoint-type breakpoint)
                         (dape--source-breakpoint-value breakpoint)
                         (dape--breakpoint-disabled breakpoint)
                         (gdev-debug-breakpoints--state breakpoint connection))))

(defun gdev-debug-breakpoints--entry ()
  "Restituisci l'identità del punto sorgente sotto il cursore."
  (get-text-property (point) 'gdev-breakpoint))

(defun gdev-debug-breakpoints--editable-p ()
  "Indica se il punto attuale ammette la modifica del tipo o del valore."
  (when-let* ((breakpoint (gdev-debug-breakpoints--entry)))
    (not (eq (dape--source-breakpoint-type breakpoint) 'until))))

(defun gdev-debug-breakpoints--current ()
  "Restituisci il punto selezionato se esiste ancora nel debug."
  (let ((breakpoint (gdev-debug-breakpoints--entry)))
    (unless (memq breakpoint dape--breakpoints)
      (user-error "Seleziona un punto di interruzione"))
    breakpoint))

(defun gdev-debug-breakpoints--visit ()
  "Apri la posizione selezionata nel gruppo editor."
  (interactive)
  (let* ((breakpoint (gdev-debug-breakpoints--current))
         (line (dape--breakpoint-line breakpoint))
         (buffer (or (dape--breakpoint-buffer breakpoint)
                     (when-let* ((file (dape--breakpoint-file-name breakpoint))
                                 ((file-readable-p file)))
                       (find-file-noselect file)))))
    (unless (buffer-live-p buffer) (user-error "Il sorgente non è disponibile"))
    (when gdev-layout-mode (gdev-focus-editor))
    (switch-to-buffer buffer)
    (let ((position (save-restriction
                      (widen)
                      (save-excursion
                        (goto-char (point-min))
                        (forward-line (1- line))
                        (point)))))
      (unless (<= (point-min) position (point-max)) (widen))
      (goto-char position))))

(defun gdev-debug-breakpoints--edit ()
  "Cambia tipo e valore del punto selezionato."
  (interactive)
  (let* ((breakpoint (gdev-debug-breakpoints--current))
         (old-type (dape--source-breakpoint-type breakpoint))
         (choices (cl-loop for (kind _ label) in gdev-debug-breakpoints--types
                           unless (eq kind 'until) collect (cons label kind))))
    (unless (gdev-debug-breakpoints--editable-p)
      (user-error "Il punto temporaneo non è modificabile"))
    (let* ((default (nth 2 (assq old-type gdev-debug-breakpoints--types)))
           (type (cdr (assoc (completing-read "Tipo di interruzione: " choices nil t nil nil default)
                             choices)))
           (prompt (nth 3 (assq type gdev-debug-breakpoints--types)))
           (value (when prompt
                    (read-string (concat prompt ": ")
                                 (and (eq type old-type)
                                      (dape--source-breakpoint-value breakpoint))))))
      (dape-source-breakpoint-edit breakpoint type value))))

(defun gdev-debug-breakpoints--toggle ()
  "Attiva o disattiva il punto selezionato."
  (interactive)
  (let ((breakpoint (gdev-debug-breakpoints--current)))
    (dape-source-breakpoint-set-enabled breakpoint (dape--breakpoint-disabled breakpoint))))

(defun gdev-debug-breakpoints--delete ()
  "Elimina il punto selezionato."
  (interactive)
  (dape--breakpoint-remove (gdev-debug-breakpoints--current)))

(defun gdev-debug-breakpoints--add ()
  "Aggiungi un punto semplice alla riga del gruppo editor attivo."
  (interactive)
  (let ((breakpoint (with-selected-window (gdev-layout-editor)
                      (unless buffer-file-name (user-error "Apri un sorgente nell'editor"))
                      (or (car (dape--breakpoints-at-point)) (dape--breakpoint-place)))))
    (when-let* ((position (text-property-any (point-min) (point-max) 'gdev-breakpoint breakpoint)))
      (goto-char position))))

(defun gdev-debug-breakpoints--move (direction)
  "Sposta il cursore all'inizio del punto successivo secondo DIRECTION."
  (let* ((property 'gdev-breakpoint)
         (current (gdev-debug-breakpoints--entry))
         (target (if (> direction 0)
                     (let ((end (if current (next-single-property-change (point) property)
                                  (point))))
                       (and end (next-single-property-change end property)))
                   (let* ((start (if current
                                     (previous-single-property-change (1+ (point)) property)
                                   (point)))
                          (previous (and start (previous-single-property-change start property))))
                     (and previous (previous-single-property-change previous property))))))
    (when target (goto-char target))))

(defun gdev-debug-breakpoints--next ()
  "Seleziona il punto successivo."
  (interactive)
  (gdev-debug-breakpoints--move 1))

(defun gdev-debug-breakpoints--previous ()
  "Seleziona il punto precedente."
  (interactive)
  (gdev-debug-breakpoints--move -1))

(defun gdev-debug-breakpoints--action (label command help)
  "Inserisci il pulsante LABEL che richiama COMMAND e mostra HELP."
  (insert-text-button label 'type 'gdev-ui-action 'help-echo help
                      'action (lambda (button)
                                (goto-char (button-start button))
                                (call-interactively command))))

(defun gdev-debug-breakpoints--row (entry)
  "Disegna il punto descritto da ENTRY."
  (pcase-let* ((`(,breakpoint ,name ,file ,line ,type ,value ,disabled (,state ,face)) entry)
               (start (point))
               (`(,_ ,symbol ,label . ,_) (or (assq type gdev-debug-breakpoints--types)
                                              (car gdev-debug-breakpoints--types))))
    (gdev-debug-breakpoints--action (format "%s:%d" name line) #'gdev-debug-breakpoints--visit
                                   (format "Apri %s:%d" (or file name) line))
    (insert "\n" (propertize (concat symbol " " label) 'face 'gdev-ui-view-heading)
            " · " (propertize state 'face face))
    (when value
      (insert "\n" (propertize (replace-regexp-in-string "[[:space:]]+" " " value)
                               'face 'gdev-ui-secondary 'help-echo value)))
    (insert "\n")
    (unless (eq type 'until)
      (gdev-debug-breakpoints--action "Modifica…" #'gdev-debug-breakpoints--edit
                                     "Cambia tipo o valore del punto")
      (insert "  "))
    (gdev-debug-breakpoints--action (if disabled "Attiva" "Disattiva")
                                   #'gdev-debug-breakpoints--toggle "Mantieni la posizione")
    (insert "  ")
    (gdev-debug-breakpoints--action "Elimina" #'gdev-debug-breakpoints--delete
                                   "Elimina il punto di interruzione")
    (insert "\n")
    (put-text-property start (point) 'gdev-breakpoint breakpoint)
    (insert "\n")))

(defun gdev-debug-breakpoints--render (&optional force frame)
  "Rileggi il riquadro di FRAME. Con FORCE ridisegna anche a dati invariati."
  (let* ((connection (if gdev-debug-breakpoints--owner
                         (when (fboundp 'gdev-debug-workspace-connection)
                           (gdev-debug-workspace-connection gdev-debug-breakpoints--owner))
                       (dape--live-connection 'last t)))
         (entries (gdev-debug-breakpoints--entries (gdev-workspace-roots frame) connection))
         (previous gdev-debug-breakpoints--snapshot))
    (unless (and (not force) (equal entries previous))
      (let* ((selected (gdev-debug-breakpoints--entry))
             (index (and selected (cl-position selected previous :key #'car)))
             (starts (gdev-ui-window-starts))
             (inhibit-read-only t))
        (setq gdev-debug-breakpoints--snapshot entries)
        (erase-buffer)
        (insert (propertize "Punti di interruzione" 'face 'gdev-ui-view-title) "\n")
        (gdev-debug-breakpoints--action "Aggiungi sulla riga" #'gdev-debug-breakpoints--add
                                       "Aggiungi alla riga attiva dell'editor")
        (insert "\n\n")
        (let ((first (point)))
          (if entries
              (mapc #'gdev-debug-breakpoints--row entries)
            (insert (propertize "Nessun punto di interruzione" 'face 'gdev-ui-secondary) "\n"))
          (goto-char (or (and selected (text-property-any first (point-max) 'gdev-breakpoint selected))
                         (and index entries
                              (text-property-any first (point-max) 'gdev-breakpoint
                                                 (car (nth (min index (1- (length entries))) entries))))
                         first))
          (gdev-ui-restore-windows starts))))))

(defun gdev-debug-breakpoints--refresh-visible (&rest _)
  "Aggiorna le viste visibili durante una modifica o un evento del debug."
  (walk-windows (lambda (window)
                  (with-current-buffer (window-buffer window)
                    (when (derived-mode-p 'gdev-debug-breakpoints-mode)
                      (gdev-debug-breakpoints--render nil (window-frame window)))))
                'no-minibuffer 'visible))

(defun gdev-debug-breakpoints--refresh ()
  "Aggiorna lo stato dei punti di interruzione dallo spazio."
  (interactive)
  (gdev-debug-breakpoints--render t (selected-frame)))

(defvar-keymap gdev-debug-breakpoints-mode-map
  "n" #'gdev-debug-breakpoints--next
  "p" #'gdev-debug-breakpoints--previous
  "a" #'gdev-debug-breakpoints--add
  "RET" #'gdev-debug-breakpoints--visit
  "SPC" #'gdev-debug-breakpoints--toggle
  "e" #'gdev-debug-breakpoints--edit
  "d" #'gdev-debug-breakpoints--delete
  "g" #'gdev-debug-breakpoints--refresh
  "q" #'gdev-close-document)

(define-derived-mode gdev-debug-breakpoints-mode special-mode "Punti di interruzione"
  "Consulta e modifica i punti di interruzione nel sorgente."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local hl-line-face 'gdev-ui-side-selection
              gdev-context-items
              '(["Aggiungi sulla riga" gdev-debug-breakpoints--add t (:target view)]
                ["Apri il sorgente" gdev-debug-breakpoints--visit (gdev-debug-breakpoints--entry)]
                ["Modifica il punto…" gdev-debug-breakpoints--edit (gdev-debug-breakpoints--editable-p)]
                ["Attiva o disattiva" gdev-debug-breakpoints--toggle (gdev-debug-breakpoints--entry)]
                ["Elimina il punto" gdev-debug-breakpoints--delete (gdev-debug-breakpoints--entry)]))
  (hl-line-mode 1))

(defun gdev-debug-breakpoints-show ()
  "Apri il riquadro dei punti di interruzione del sorgente."
  (interactive)
  (let ((frame (selected-frame))
        (buffer (if gdev-layout-mode
                    (gdev-activity-buffer 'breakpoints "*Punti di interruzione*"
                                          #'gdev-debug-breakpoints-mode)
                  (get-buffer-create "*Punti di interruzione*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-debug-breakpoints-mode) (gdev-debug-breakpoints-mode))
      (setq gdev-debug-breakpoints--owner (and gdev-layout-mode (gdev-workspace-state-ensure-id)))
      (gdev-debug-breakpoints--render t frame))
    (pop-to-buffer buffer)))

(add-hook 'dape-update-ui-hook #'gdev-debug-breakpoints--refresh-visible)
(add-hook 'dape-state-change-hook #'gdev-debug-breakpoints--refresh-visible)
(add-hook 'dape-active-mode-hook #'gdev-debug-breakpoints--refresh-visible)

(provide 'gdev-debug-breakpoints)
;;; gdev-debug-breakpoints.el ends here
