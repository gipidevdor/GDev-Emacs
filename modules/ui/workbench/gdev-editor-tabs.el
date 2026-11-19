;;; gdev-editor-tabs.el --- Anteprime e schede dei gruppi editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ogni gruppo editor può mostrare un solo documento in anteprima.  I
;; documenti usano gli stessi buffer e la stessa cronologia delle altre
;; schede.  Un'apertura esplicita o la prima modifica li rende permanenti.

;;; Code:

(require 'gdev-layout)
(require 'gdev-operation-history)
(require 'gdev-workspace-state)

(declare-function gdev-comparison-control-at-window "gdev-commands" (&optional window))
(declare-function tab-line-tabs-window-buffers "tab-line" ())
(declare-function tab-line-tabs-fixed-window-buffers "tab-line" ())

(defvar-local gdev-editor--transient-preview nil
  "Non nil per un documento visitato attraverso un'anteprima non confermata.")
(put 'gdev-editor--transient-preview 'permanent-local t)

(add-to-list 'window-persistent-parameters '(gdev-editor-preview . t))

(defun gdev-editor-preview-buffer-p (buffer)
  "Restituisce non nil se BUFFER è ancora un'anteprima temporanea."
  (and (buffer-live-p buffer)
       (buffer-local-value 'gdev-editor--transient-preview buffer)
       (not (buffer-modified-p buffer))))

(defun gdev-editor-preview-p (buffer &optional window)
  "Restituisce non nil se BUFFER è la scheda di anteprima di WINDOW."
  (and (eq buffer (window-parameter window 'gdev-editor-preview))
       (gdev-editor-preview-buffer-p buffer)))

(defun gdev-editor-pin-preview (&optional buffer)
  "Conserva BUFFER, o il documento del gruppo attivo, come scheda permanente."
  (interactive)
  (let ((document (or buffer (window-buffer (gdev-layout-editor)))))
    (when (and (buffer-live-p document)
               (buffer-local-value 'gdev-editor--transient-preview document))
      (with-current-buffer document
        (setq gdev-editor--transient-preview nil)
        (remove-hook 'first-change-hook #'gdev-editor--pin-after-edit t))
      (walk-windows
       (lambda (window)
         (when (eq document (window-parameter window 'gdev-editor-preview))
           (set-window-parameter window 'gdev-editor-preview nil)
           (set-window-parameter window 'tab-line-cache nil)))
       'no-minibuffer t)
      (force-mode-line-update t))))

(defun gdev-editor--pin-after-edit ()
  "Conferma il documento che sta per essere modificato."
  (gdev-editor-pin-preview (current-buffer)))
(put 'gdev-editor--pin-after-edit 'permanent-local-hook t)

(defun gdev-editor--forget-tab (window buffer)
  "Rimuove BUFFER dalle schede in memoria di WINDOW."
  (unrecord-window-buffer window buffer)
  (set-window-parameter window 'tab-line-buffers
                        (remq buffer (window-parameter window 'tab-line-buffers)))
  (set-window-parameter window 'tab-line-cache nil))

(defun gdev-editor--saved-view-refers-to-p (node reference)
  "Indica se NODE contiene REFERENCE nella vista o nella cronologia."
  (let ((entries (cdr node)))
    (pcase (car node)
      ('leaf
       (or (equal reference (cadr (assq 'buffer entries)))
           (assoc reference (alist-get 'prev-buffers entries))
           (member reference (alist-get 'next-buffers entries))))
      ((or 'hc 'vc)
       (seq-some (lambda (entry) (gdev-editor--saved-view-refers-to-p entry reference))
                 entries)))))

(defun gdev-editor--preview-in-use-p (buffer)
  "Indica se un altro gruppo conserva BUFFER, anche in una scheda inattiva."
  (or (get-buffer-window buffer t)
      (catch 'preview-in-use
        (walk-windows
         (lambda (window)
           (when (and (not (window-parameter window 'window-side))
                      (or (assq buffer (window-prev-buffers window))
                          (memq buffer (window-next-buffers window))))
             (throw 'preview-in-use t)))
         'no-minibuffer t)
        (seq-some
         (lambda (frame)
           (seq-some
            (lambda (tab)
              (when (eq (car tab) 'tab)
                (if-let* ((state (plist-get (gdev-workspace-state-read 'gdev-workspaces-layout tab)
                                             :windows)))
                    (gdev-editor--saved-view-refers-to-p (cdr state) buffer)
                  (gdev-editor--saved-view-refers-to-p (cdr (alist-get 'ws tab)) (buffer-name buffer)))))
            ;; Il Tab Bar nativo può inizializzare schede e chiamare hook
            ;; alla prima lettura. Esamina solo quelle già esistenti.
            (if (eq tab-bar-tabs-function #'tab-bar-tabs)
                (frame-parameter frame 'tabs)
              (gdev-workspace-state-tabs frame))))
         (frame-list)))))

(defun gdev-editor--release-preview (window buffer)
  "Rilascia BUFFER dopo che WINDOW ha smesso di mostrarne l'anteprima."
  (when (gdev-editor-preview-p buffer window)
    (gdev-editor--forget-tab window buffer)
    (set-window-parameter window 'gdev-editor-preview nil)
    (unless (gdev-editor--preview-in-use-p buffer)
      (kill-buffer buffer))))

(defun gdev-editor-open-preview (file &optional window)
  "Mostra FILE nello spazio di anteprima di WINDOW, senza spostarvi il fuoco."
  (let ((editor (or window (gdev-layout-editor))))
    (unless (and (window-live-p editor) (not (window-parameter editor 'window-side))
                 (not (window-dedicated-p editor)))
      (user-error "Apri un gruppo editor per mostrare l'anteprima"))
    (let* ((previous (window-parameter editor 'gdev-editor-preview))
           (visiting (find-buffer-visiting file))
           (buffer (find-file-noselect file))
           (position (assq buffer (window-prev-buffers editor)))
           (preview (or (not visiting) (gdev-editor-preview-buffer-p buffer))))
      (unless (eq buffer (window-buffer editor))
        (set-window-buffer-start-and-point editor buffer (nth 1 position) (nth 2 position)))
      (unless (eq previous buffer)
        (gdev-editor--release-preview editor previous))
      (when (and preview (not (buffer-modified-p buffer)))
        (with-current-buffer buffer
          (setq gdev-editor--transient-preview t)
          (add-hook 'first-change-hook #'gdev-editor--pin-after-edit nil t))
        (set-window-parameter editor 'gdev-editor-preview buffer)
        (set-window-parameter editor 'tab-line-cache nil))
      (force-mode-line-update t)
      buffer)))

(defun gdev-editor--pin-opened-file (buffer)
  "Conferma BUFFER dopo l'apertura esplicita di un file."
  (when (buffer-live-p buffer)
    (gdev-editor-pin-preview buffer))
  buffer)

(defun gdev-editor--close-tab (close buffer)
  "Chiudi l'anteprima BUFFER. Delega a CLOSE gli altri casi."
  (let ((window (selected-window)))
    (if (and (gdev-editor-preview-p buffer window)
             (not (and (eq buffer (window-buffer window))
                       (fboundp 'gdev-comparison-control-at-window)
                       (gdev-comparison-control-at-window window))))
        (progn
          (when (eq buffer (window-buffer window))
            (gdev-layout--restore-document window))
          (gdev-editor--release-preview window buffer)
          (force-mode-line-update t))
      (funcall close buffer))))

(defun gdev-editor-transfer-group-p (window)
  "Indica se WINDOW consente il trasferimento di documenti."
  (and (window-live-p window) (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side)) (not (window-dedicated-p window))
       (not (and (fboundp 'gdev-comparison-control-at-window)
                 (gdev-comparison-control-at-window window)))))

(defun gdev-editor-move-to-group-available-p (&optional source)
  "Indica se SOURCE ha un documento e un gruppo di destinazione."
  (let ((source (or source (gdev-layout-editor))))
    (and (gdev-editor-transfer-group-p source)
         (gdev-layout-document-tab-p (window-buffer source))
         (seq-some #'gdev-editor-transfer-group-p
                   (remq source (gdev-layout--editors (window-frame source)))))))

(defun gdev-editor--move-target (&optional source)
  "Chiedi in quale gruppo spostare il documento da SOURCE."
  (let* ((source (or source (gdev-layout-editor)))
         (frame (window-frame source))
         (owner (gdev-workspace-state-ensure-id frame))
         (document (window-buffer source))
         (groups (seq-remove (lambda (window) (window-parameter window 'window-side))
                             (window-list frame 'no-minibuffer (frame-first-window frame))))
         (targets
          (cl-loop for window in groups
                   for number from 1
                   when (and (not (eq window source)) (gdev-editor-transfer-group-p window))
                   collect (cons (format "Gruppo %d · %s" number
                                         (buffer-name (window-buffer window)))
                                 window))))
    (unless (and (gdev-editor-transfer-group-p source) (gdev-layout-document-tab-p document))
      (user-error "Seleziona una scheda di documento da spostare"))
    (unless targets
      (user-error "Affianca un gruppo editor prima di spostare il documento"))
    (let ((target (alist-get (completing-read "Sposta nel gruppo: " targets nil t nil nil (caar targets))
                             targets nil nil #'equal)))
      (unless (and (eq frame (selected-frame)) (eq owner (gdev-workspace-state-id frame))
                   (window-live-p source) (eq document (window-buffer source)))
        (user-error "Lo spazio o il documento sono cambiati. Riprova"))
      (list target source document))))

(defun gdev-editor--tab-order (tabs document before)
  "Inserisci DOCUMENT tra TABS prima di BEFORE oppure in coda.
Se è già presente, mantieni l'ordine fino a un rilascio esplicito."
  (if (or (eq before document) (and (not before) (memq document tabs)))
      tabs
    (let* ((remaining (remq document tabs))
           (index (and before (seq-position remaining before #'eq))))
      (if index
          (append (seq-take remaining index) (list document) (seq-drop remaining index))
        (append remaining (list document))))))

(defun gdev-editor-move-to-group (target &optional source document before)
  "Sposta DOCUMENT da SOURCE a TARGET prima della scheda BEFORE.
Senza SOURCE o DOCUMENT usa il gruppo o il documento attivo."
  (interactive (gdev-editor--move-target))
  (require 'tab-line)
  (let* ((source (or source (gdev-layout-editor)))
         (document (or document (and (window-live-p source) (window-buffer source)))))
    (unless (and (gdev-editor-transfer-group-p source) (gdev-editor-transfer-group-p target)
                 (not (eq source target)) (eq (window-frame source) (window-frame target)))
      (user-error "Scegli un altro gruppo editor nello spazio di lavoro"))
    (unless (and (buffer-live-p document) (gdev-layout-document-tab-p document)
                 (with-selected-window source (memq document (tab-line-tabs-window-buffers))))
      (user-error "Seleziona una scheda di documento da spostare"))
    (unless (or (not before)
                (with-selected-window target (memq before (tab-line-tabs-window-buffers))))
      (user-error "La scheda di destinazione è cambiata"))
    (let ((configuration (current-window-configuration (window-frame source)))
          (source-tabs (gdev-operation-window-tab-state source))
          (target-tabs (gdev-operation-window-tab-state target))
          (shown (eq document (window-buffer source)))
          completed)
      (unwind-protect
          (let* ((tabs (with-selected-window target (tab-line-tabs-fixed-window-buffers)))
                 (order (gdev-editor--tab-order tabs document before)))
            (unless (eq document (window-buffer target))
              (let ((previous (or (assq document (window-prev-buffers target))
                                  (and (not shown) (assq document (window-prev-buffers source))))))
                (set-window-buffer-start-and-point
                 target document (if previous (nth 1 previous) (and shown (window-start source)))
                 (if previous (nth 2 previous) (and shown (window-point source))))
                (set-window-hscroll target (if (and shown (not previous)) (window-hscroll source) 0))
                (set-window-vscroll target (if (and shown (not previous)) (window-vscroll source t) 0) t)))
            (when shown (gdev-layout--restore-document source))
            (gdev-editor--forget-tab source document)
            (set-window-parameter target 'tab-line-buffers order)
            (set-window-parameter target 'tab-line-cache nil)
            (set-window-parameter target 'tab-line-hscroll nil)
            (setq completed t))
        (unless completed
          (set-window-configuration configuration)
          (gdev-operation-restore-window-tab-state source source-tabs)
          (gdev-operation-restore-window-tab-state target target-tabs)))
      (gdev-editor-pin-preview document)
      (select-window target)
      (force-mode-line-update t))))

(defun gdev-editor-tabs-install ()
  "Collega le transizioni delle anteprime ai comandi del workbench."
  (advice-add 'gdev-open-file :filter-return #'gdev-editor--pin-opened-file)
  (advice-add 'gdev-layout-close-editor-tab :around #'gdev-editor--close-tab))

(provide 'gdev-editor-tabs)
;;; gdev-editor-tabs.el ends here
