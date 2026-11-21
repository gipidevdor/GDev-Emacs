;;; gdev-workbench-operations.el --- Operazioni dello spazio di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Raccoglie gli stati delle operazioni avviate dal Workbench.
;; I processi e i risultati restano in carico ai rispettivi strumenti.

;;; Code:

(require 'button)
(require 'compile)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'gdev-project-operations)

(declare-function gdev-close-document "gdev-commands" ())

(cl-defstruct gdev-workbench-operation id owner frame label buffer interruptible state detail)
(defvar-local gdev-workbench-operations--output nil)
(defvar gdev-workbench-operation-manual nil
  "Delega il ciclo di vita allo strumento che avvia la compilazione.")
(defconst gdev-workbench-operations--recent-limit 12)

(defvar-keymap gdev-workbench-operations-mode-map
  "q" #'gdev-close-document
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-workbench-operations-mode special-mode "Operazioni"
  "Consulta le operazioni attive e gli esiti dello spazio."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1))

(defun gdev-workbench-operations--find (owner frame)
  "Trova (FRAME . SCHEDA) dello spazio OWNER, a partire da FRAME."
  (let ((tab (and (frame-live-p frame) (gdev-workspace-state-find owner frame))))
    (or (and tab (cons frame tab))
        (seq-some (lambda (candidate)
                    (when-let* ((tab (gdev-workspace-state-find owner candidate)))
                      (cons candidate tab)))
                  (frame-list)))))

(defun gdev-workbench-operations--location (operation)
  "Trova la scheda di OPERATION anche quando cambia frame."
  (gdev-workbench-operations--find (gdev-workbench-operation-owner operation)
                                   (gdev-workbench-operation-frame operation)))

(defun gdev-workbench-operations--active-p (operation)
  (memq (gdev-workbench-operation-state operation) '(running stopping)))

(defun gdev-workbench-operations--current (operation records)
  (seq-find (lambda (item) (eq (gdev-workbench-operation-id item) (gdev-workbench-operation-id operation)))
            records))

(defun gdev-workbench-operations--record (operation location)
  "Pubblica OPERATION in LOCATION conservando tutte le operazioni in corso."
  (let* ((frame (car location))
         (tab (cdr location))
         (prior (gdev-workspace-state-read 'gdev-workbench-operations tab))
         (previous (gdev-workbench-operations--current operation prior))
         (records (if (and previous (gdev-workbench-operations--active-p operation))
                      (mapcar (lambda (item) (if (eq item previous) operation item)) prior)
                    (cons operation (remq previous prior))))
         (recent 0))
    (gdev-workspace-state-set
     'gdev-workbench-operations
     (seq-filter (lambda (item)
                   (or (gdev-workbench-operations--active-p item)
                       (<= (cl-incf recent) gdev-workbench-operations--recent-limit)))
                 records)
     tab)
    (when-let* (((eq tab (gdev-workspace-state-current frame)))
                (pane (alist-get 'operations (gdev-workspace-state-read 'gdev-activity-buffers tab)))
                ((buffer-live-p pane))
                (window (get-buffer-window pane frame)))
      (with-demoted-errors "Riquadro Operazioni: %S"
        (with-current-buffer pane (gdev-workbench-operations--render window))))))

(defun gdev-workbench-operation-start (label buffer &optional interruptible owner)
  "Registra LABEL e BUFFER nello spazio attivo, o nello spazio OWNER.
Con INTERRUPTIBLE l'operazione si può interrompere: una funzione riceve
l'operazione, la ferma e restituisce non nil, oppure nil se l'utente rinuncia;
ogni altro valore interrompe il processo di BUFFER.
Restituisce nil se lo spazio OWNER non è più aperto."
  (when-let* ((gdev-layout-mode)
              (location (if owner
                            (gdev-workbench-operations--find owner (selected-frame))
                          (cons (selected-frame) (gdev-workspace-state-current)))))
    (let ((operation (make-gdev-workbench-operation
                      :id (make-symbol "operazione")
                      :owner (or owner (gdev-workspace-state-ensure-id (car location)))
                      :frame (car location) :label label :buffer buffer
                      :interruptible interruptible :state 'running)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (setq gdev-workbench-operations--output operation)))
      (gdev-workbench-operations--record operation location)
      operation)))

(defun gdev-workbench-operation-location (operation)
  "Restituisci (FRAME . SCHEDA) di OPERATION finché il suo spazio è aperto."
  (when operation (gdev-workbench-operations--location operation)))

(defun gdev-workbench-operation-current (operation)
  "Leggi la registrazione corrente di OPERATION finché lo spazio è aperto.
Il risultato è in sola lettura; l'oggetto iniziale può essere superato."
  (when-let* ((location (gdev-workbench-operation-location operation)))
    (gdev-workbench-operations--current
     operation (gdev-workspace-state-read 'gdev-workbench-operations (cdr location)))))

(defun gdev-workbench-operation-report (operation state &optional detail)
  "Pubblica insieme STATE e DETAIL di OPERATION finché lo spazio esiste."
  (when-let* ((operation) (location (gdev-workbench-operations--location operation))
              (records (gdev-workspace-state-read 'gdev-workbench-operations (cdr location)))
              (previous (gdev-workbench-operations--current operation records))
              ((gdev-workbench-operations--active-p previous))
              ((or (not (eq state (gdev-workbench-operation-state previous)))
                   (not (equal detail (gdev-workbench-operation-detail previous))))))
    (unless (and (eq state 'running) (eq (gdev-workbench-operation-state previous) 'stopping))
      (let ((updated (copy-gdev-workbench-operation previous)))
        (setf (gdev-workbench-operation-state updated) state
              (gdev-workbench-operation-detail updated) detail)
        (gdev-workbench-operations--record updated location)))))

(defun gdev-workbench-operation-finish (operation success &optional detail)
  "Chiudi OPERATION: completata con SUCCESS, altrimenti non riuscita con DETAIL.
Dopo una richiesta di interruzione l'esito è sempre «Interrotta»."
  (when-let* ((location (gdev-workbench-operations--location operation))
              (current (gdev-workbench-operations--current
                        operation (gdev-workspace-state-read 'gdev-workbench-operations
                                                             (cdr location)))))
    (if (eq (gdev-workbench-operation-state current) 'stopping)
        (gdev-workbench-operation-report operation 'cancelled)
      (gdev-workbench-operation-report operation (if success 'completed 'failed) detail))))

(defun gdev-workbench-operation-progress (buffer detail)
  "Mostra DETAIL per l'operazione associata a BUFFER."
  (when (buffer-live-p buffer)
    (gdev-workbench-operation-report
     (buffer-local-value 'gdev-workbench-operations--output buffer) 'running detail)))

(defun gdev-workbench-operations--finish-process (operation process message)
  "Registra l'esito finale del PROCESS di OPERATION, precisato da MESSAGE."
  (let* ((exit (process-exit-status process))
         (status (process-status process))
         (location (gdev-workbench-operations--location operation))
         (current (and location (gdev-workbench-operations--current
                                 operation (gdev-workspace-state-read
                                            'gdev-workbench-operations (cdr location))))))
    (pcase (gdev-project-operation-result
            status exit (and current (eq (gdev-workbench-operation-state current) 'stopping)))
      ('cancelled
       (gdev-workbench-operation-report operation 'cancelled))
      ('completed
       (gdev-workbench-operation-report operation 'completed))
      (_ (gdev-workbench-operation-report
          operation 'failed (pcase status
                              ('exit (format "Codice %d" exit))
                              ('signal (format "Segnale %d" exit))
                              (_ (string-trim message))))))))

(defun gdev-workbench-operation-compilation-start (process)
  "Segui PROCESS tramite le normali notifiche di compilazione."
  (when-let* ((gdev-layout-mode) ((not gdev-workbench-operation-manual))
              (buffer (process-buffer process))
              ((buffer-live-p buffer))
              (label (string-trim (buffer-name buffer) "\\*" "\\*"))
              (operation (gdev-workbench-operation-start label buffer t)))
    (process-put process 'gdev-workbench-operation operation)
    (if (not (process-live-p process))
        (gdev-workbench-operations--finish-process operation process "Processo terminato")
      (with-current-buffer buffer
        (letrec ((cancelled (lambda () (gdev-workbench-operation-report operation 'cancelled)))
                 (finish (lambda (_ status)
                           (remove-hook 'compilation-finish-functions finish t)
                           (remove-hook 'kill-buffer-hook cancelled t)
                           (gdev-workbench-operations--finish-process operation process status))))
          (add-hook 'kill-buffer-hook cancelled nil t)
          (add-hook 'compilation-finish-functions finish nil t))))))

(defun gdev-workbench-operations--output-live-p (operation)
  (let ((buffer (gdev-workbench-operation-buffer operation)))
    (when (buffer-live-p buffer)
      (let ((current (buffer-local-value 'gdev-workbench-operations--output buffer)))
        (and current (eq (gdev-workbench-operation-id current) (gdev-workbench-operation-id operation)))))))

(defun gdev-workbench-operations--process (operation)
  (when (and (eq (gdev-workbench-operation-state operation) 'running)
             (gdev-workbench-operation-interruptible operation)
             (gdev-workbench-operations--output-live-p operation))
    (when-let* ((process (get-buffer-process (gdev-workbench-operation-buffer operation)))
                ((process-live-p process)))
      process)))

(defun gdev-workbench-operations--stop-function (operation)
  "Restituisci la funzione che ferma OPERATION in corso, se lo strumento ne ha una."
  (let ((stop (gdev-workbench-operation-interruptible operation)))
    (and (eq (gdev-workbench-operation-state operation) 'running) (functionp stop) stop)))

(defun gdev-workbench-operations--cancellable-p (operation)
  (or (gdev-workbench-operations--stop-function operation)
      (gdev-workbench-operations--process operation)))

(defun gdev-workbench-operations--interrupt (operation)
  "Richiedi l'interruzione di OPERATION nel suo spazio."
  (unless (eq (gdev-workbench-operation-owner operation) (gdev-workspace-state-id))
    (user-error "Scegli un'operazione di questo spazio"))
  (let* ((current (gdev-workbench-operations--current
                   operation (gdev-workspace-state-get 'gdev-workbench-operations)))
         (stop (and current (gdev-workbench-operations--stop-function current)))
         (process (and current (not stop) (gdev-workbench-operations--process current))))
    (unless (or stop process) (user-error "L'operazione non è più in corso"))
    ;; Prima lo stato: lo strumento può concludere l'operazione mentre si ferma.
    (gdev-workbench-operation-report operation 'stopping)
    (cond ((not stop) (interrupt-process process))
          ;; Una funzione che restituisce nil ha rinunciato, per esempio alla conferma.
          ((not (funcall stop current)) (gdev-workbench-operations--resume current)))))

(defun gdev-workbench-operations--resume (operation)
  "Riporta in corso OPERATION se attende ancora l'interruzione."
  (when-let* ((location (gdev-workbench-operations--location operation))
              (current (gdev-workbench-operations--current
                        operation (gdev-workspace-state-read 'gdev-workbench-operations
                                                             (cdr location))))
              ((eq (gdev-workbench-operation-state current) 'stopping)))
    (let ((resumed (copy-gdev-workbench-operation current)))
      (setf (gdev-workbench-operation-state resumed) 'running)
      (gdev-workbench-operations--record resumed location))))

(defun gdev-workbench-operation-cancel ()
  "Interrompi l'operazione indicata o l'ultimo processo in corso di questo spazio.
Una sessione di debug si ferma solo indicandola, dalla vista Operazioni."
  (interactive)
  (if (not gdev-layout-mode)
      (kill-compilation)
    (let* ((focus (or (get-text-property (point) 'gdev-workbench-operation)
                      (and (compilation-buffer-p (current-buffer)) gdev-workbench-operations--output)))
           (operation (or focus (seq-find #'gdev-workbench-operations--process
                                         (gdev-workspace-state-get 'gdev-workbench-operations)))))
      (unless operation (user-error "Nessuna operazione interrompibile in questo spazio"))
      (gdev-workbench-operations--interrupt operation))))

(defun gdev-workbench-operations--row (operation)
  (let* ((start (point))
         (buffer (gdev-workbench-operation-buffer operation))
         (detail (gdev-workbench-operation-detail operation))
         (status (pcase (gdev-workbench-operation-state operation)
                   ('running '("In corso" gdev-ui-secondary))
                   ('stopping '("Interruzione richiesta" gdev-ui-secondary))
                   ('completed '("Completata" gdev-ui-status-success))
                   ('failed '("Non riuscita" gdev-ui-status-warning))
                   (_ '("Interrotta" gdev-ui-secondary)))))
    (insert (propertize (gdev-workbench-operation-label operation) 'face 'gdev-ui-view-heading) "\n"
            (propertize (car status) 'face (cadr status)))
    (when detail (insert " · " (propertize detail 'face 'gdev-ui-secondary)))
    (insert "\n")
    (when (gdev-workbench-operations--output-live-p operation)
      (insert-text-button "Apri dettagli" 'type 'gdev-ui-action 'gdev-operation-control 'details
                          'action (lambda (_)
                                    (unless (gdev-workbench-operations--output-live-p operation)
                                      (user-error "I dettagli non sono più disponibili"))
                                    (pop-to-buffer buffer)))
      (insert "  "))
    (when (gdev-workbench-operations--cancellable-p operation)
      (insert-text-button "Interrompi" 'type 'gdev-ui-action 'gdev-operation-control 'cancel
                          'action (lambda (_) (gdev-workbench-operations--interrupt operation))))
    (put-text-property start (point) 'gdev-workbench-operation operation)
    (insert "\n\n")))

(defun gdev-workbench-operations--render (window)
  (let* ((position (window-point window))
         (operation (get-text-property position 'gdev-workbench-operation))
         (first (get-text-property (window-start window) 'gdev-workbench-operation))
         (control (get-text-property position 'gdev-operation-control))
         (records (gdev-workspace-state-get 'gdev-workbench-operations (window-frame window)))
         (inhibit-read-only t)
         selected start-of-window)
    (erase-buffer)
    (insert (propertize "Operazioni dello spazio" 'face 'gdev-ui-view-title) "\n\n")
    (if (not records)
        (insert (propertize "Nessuna operazione in questo spazio" 'face 'gdev-ui-secondary) "\n")
      (dolist (item (append (seq-filter #'gdev-workbench-operations--active-p records)
                            (seq-remove #'gdev-workbench-operations--active-p records)))
        (let ((start (point)))
          (gdev-workbench-operations--row item)
          (when (and first (eq (gdev-workbench-operation-id item) (gdev-workbench-operation-id first)))
            (setq start-of-window start))
          (when (and operation (eq (gdev-workbench-operation-id item) (gdev-workbench-operation-id operation)))
            (setq selected (or (and control (text-property-any start (point) 'gdev-operation-control control))
                               start))))))
    (set-window-start window (or start-of-window (point-min)))
    (set-window-point window (or selected (point-min)))))

(defun gdev-workbench-operations-show ()
  "Mostra le operazioni e gli ultimi esiti dello spazio corrente."
  (interactive)
  (unless gdev-layout-mode (user-error "Attiva il Workbench"))
  (let ((buffer (gdev-activity-buffer 'operations "*Operazioni dello spazio*" #'gdev-workbench-operations-mode)))
    (with-current-buffer buffer (setq-local gdev-activity-kind nil))
    (pop-to-buffer buffer)
    (gdev-workbench-operations--render (selected-window))))

(provide 'gdev-workbench-operations)
;;; gdev-workbench-operations.el ends here
