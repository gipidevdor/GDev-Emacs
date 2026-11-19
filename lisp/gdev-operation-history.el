;;; gdev-operation-history.el --- Cronologia delle operazioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il registro dei comandi contiene solo i loro nomi. Le azioni con un
;; inverso esplicito conservano in memoria lo stato dello spazio corrente.

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'gdev-layout)
(require 'gdev-workspace-state)

(defgroup gdev-operation nil
  "Annullamento delle operazioni dello spazio di lavoro."
  :group 'gdev)

(defcustom gdev-operation-limit 128
  "Numero massimo di operazioni conservate in ciascuno spazio."
  :type '(integer :match (lambda (widget value)
                            (and (integerp value) (> value 0))))
  :group 'gdev-operation)

(defcustom gdev-operation-text-budget (* 8 1024 1024)
  "Limite in byte dei dati delle sostituzioni conservati per spazio."
  :type 'natnum
  :group 'gdev-operation)

(cl-defstruct gdev-operation label inverse forward (bytes 0))
(cl-defstruct gdev-operation-history undo redo)
(cl-defstruct gdev-operation-document buffer before after patches)

(defvar-local gdev-operation--text-revision nil
  "Ultima coppia (tick del buffer . revisione logica) pubblicata da GDev.")
(put 'gdev-operation--text-revision 'permanent-local t)

(defvar gdev-operation-commands (make-ring 128)
  "Ultimi comandi interattivi osservati, senza argomenti né testo.")
(defvar gdev-operation--replaying nil)
(defvar gdev-operation--capturing-layout nil)

(defun gdev-operation--observe ()
  "Registra il comando osservato dal ciclo di Emacs."
  (when this-command
    (ring-insert gdev-operation-commands
                 (if (symbolp this-command) this-command 'comando-anonimo))))

(defun gdev-operation--history ()
  "Leggi la cronologia dello spazio corrente."
  (gdev-workspace-state-get 'gdev-operation-history))

(defun gdev-operation-record (label undo redo &optional bytes)
  "Registra LABEL con UNDO e REDO, contabilizzando BYTES nello spazio."
  (unless gdev-operation--replaying
    (let* ((history (gdev-operation--history))
           (entries (cons (make-gdev-operation :label label :inverse undo :forward redo
                                                :bytes (or bytes 0))
                          (and history (gdev-operation-history-undo history))))
           (remaining gdev-operation-text-budget)
           (count 0)
           retained)
      (while (and entries (< count (max 1 gdev-operation-limit))
                  (<= (gdev-operation-bytes (car entries)) remaining))
        (let ((entry (pop entries)))
          (cl-decf remaining (gdev-operation-bytes entry))
          (cl-incf count)
          (push entry retained)))
      (gdev-workspace-state-set 'gdev-operation-history
                                (make-gdev-operation-history :undo (nreverse retained))))))

(defun gdev-operation--move (redo)
  "Esegui la prossima operazione in direzione REDO."
  (when gdev-operation--replaying (user-error "Operazione già in corso"))
  (let* ((history (gdev-operation--history))
         (undo-list (and history (gdev-operation-history-undo history)))
         (redo-list (and history (gdev-operation-history-redo history)))
         (entry (car (if redo redo-list undo-list))))
    (unless entry (user-error "Nessuna operazione dello spazio da %s"
                             (if redo "ripetere" "annullare")))
    (let* ((frame (selected-frame))
           (owner (gdev-workspace-state-ensure-id frame))
           (gdev-operation--replaying t))
      (funcall (if redo (gdev-operation-forward entry) (gdev-operation-inverse entry)))
      ;; Pubblica solo dopo la riuscita e sempre nello spazio di origine.
      (when-let* (((frame-live-p frame))
                  (tab (gdev-workspace-state-find owner frame)))
        (gdev-workspace-state-set
         'gdev-operation-history
         (make-gdev-operation-history
          :undo (if redo (cons entry undo-list) (cdr undo-list))
          :redo (if redo (cdr redo-list) (cons entry redo-list)))
         tab)))
    (message "%s · %s" (if redo "Ripetuto" "Annullato") (gdev-operation-label entry))))

(defun gdev-operation-undo ()
  "Annulla l'ultima operazione reversibile dello spazio corrente."
  (interactive)
  (gdev-operation--move nil))

(defun gdev-operation-redo ()
  "Ripeti l'ultima operazione dello spazio annullata."
  (interactive)
  (gdev-operation--move t))

(defun gdev-operation--visible-layout ()
  "Restituisci documenti e geometria in ordine indipendente dal fuoco."
  (mapcar (lambda (window)
            (cons (window-buffer window) (window-edges window nil nil t)))
          (window-list nil 'nomini (frame-first-window))))

(defun gdev-operation-window-tab-state (window)
  "Conserva ordine e cronologia delle schede di WINDOW."
  (list (copy-sequence (window-parameter window 'tab-line-buffers))
        (window-prev-buffers window) (window-next-buffers window)
        (window-parameter window 'tab-line-hscroll)))

(defun gdev-operation-restore-window-tab-state (window state)
  "Ripristina STATE in WINDOW insieme alla configurazione nativa."
  (set-window-parameter window 'tab-line-buffers (car state))
  (set-window-prev-buffers window (nth 1 state))
  (set-window-next-buffers window (nth 2 state))
  (set-window-parameter window 'tab-line-hscroll (nth 3 state))
  (set-window-parameter window 'tab-line-cache nil))

(defun gdev-operation--layout-snapshot ()
  "Conserva configurazione, documenti visibili e schede chiuse."
  (let ((closed (gdev-workspace-state-get 'gdev-layout-closed-documents)))
    (list (current-window-configuration) (gdev-operation--visible-layout) closed
          (mapcar #'gdev-operation-window-tab-state
                  (window-list nil 'nomini (frame-first-window))))))

(defun gdev-operation--restore-layout (expected target)
  "Ripristina TARGET se EXPECTED descrive ancora la disposizione."
  (unless (and (equal (nth 1 expected) (gdev-operation--visible-layout))
               (eq (nth 2 expected) (gdev-workspace-state-get 'gdev-layout-closed-documents))
               (eq (window-configuration-frame (car target)) (selected-frame))
               (cl-every (lambda (entry) (buffer-live-p (car entry))) (nth 1 target)))
    (user-error "La disposizione o i documenti sono cambiati"))
  (set-window-configuration (car target))
  (cl-mapc #'gdev-operation-restore-window-tab-state
           (window-list nil 'nomini (frame-first-window)) (nth 3 target))
  (gdev-workspace-state-set 'gdev-layout-closed-documents (nth 2 target))
  ;; Emacs può rettificare la geometria quando ricrea le finestre.
  (setcar (cdr target) (gdev-operation--visible-layout)))

(defun gdev-operation--capture-layout (function &rest arguments)
  "Registra la transizione prodotta da FUNCTION con ARGUMENTS."
  (if (or gdev-operation--replaying
          gdev-operation--capturing-layout
          (not gdev-layout-mode)
          (and (fboundp 'gdev-comparison-control-at-window)
               (gdev-comparison-control-at-window)))
      (apply function arguments)
    (let* ((before (gdev-operation--layout-snapshot))
           (result (let ((gdev-operation--capturing-layout t))
                     (apply function arguments)))
           (after (gdev-operation--layout-snapshot)))
      (unless (and (equal (nth 1 before) (nth 1 after))
                   (eq (nth 2 before) (nth 2 after))
                   (equal (mapcar #'car (nth 3 before)) (mapcar #'car (nth 3 after))))
        (gdev-operation-record
         "disposizione e schede"
         (lambda () (gdev-operation--restore-layout after before))
         (lambda () (gdev-operation--restore-layout before after))))
      result)))

(defun gdev-operation-undo-label ()
  "Restituisci il nome dell'operazione reversibile corrente, se esiste."
  (when-let* ((history (gdev-operation--history))
              (entry (car (gdev-operation-history-undo history))))
    (gdev-operation-label entry)))

(defun gdev-operation-redo-label ()
  "Restituisci il nome dell'operazione ripetibile corrente, se esiste."
  (when-let* ((history (gdev-operation--history))
              (entry (car (gdev-operation-history-redo history))))
    (gdev-operation-label entry)))

(defun gdev-operation--stamp-text-revision (revision)
  "Associa REVISION al testo corrente del buffer."
  (setq gdev-operation--text-revision (cons (buffer-chars-modified-tick) revision)))

(defun gdev-operation--apply-patches (documents redo)
  "Applica le modifiche di DOCUMENTS in direzione REDO, come un solo gruppo."
  (let ((expected (if redo #'gdev-operation-document-before #'gdev-operation-document-after))
        (target (if redo #'gdev-operation-document-after #'gdev-operation-document-before))
        group activated accepted)
    (unwind-protect
        (progn
          ;; Controlla tutti i documenti prima di toccare il primo.
          (dolist (document documents)
            (let ((buffer (gdev-operation-document-buffer document)))
              (unless (and (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (and (not buffer-read-only)
                                  (not (eq buffer-undo-list t))
                                  (eql (car gdev-operation--text-revision) (buffer-chars-modified-tick))
                                  (eq (cdr gdev-operation--text-revision) (funcall expected document))
                                  (verify-visited-file-modtime buffer))))
                (user-error "Un documento è cambiato o è stato chiuso: %s" (or (buffer-name buffer) buffer)))
              (with-current-buffer buffer
                (save-restriction
                  (widen)
                  (pcase-dolist (`(,original ,changed ,before ,after)
                                 (gdev-operation-document-patches document))
                    (let* ((start (if redo original changed))
                           (text (if redo before after))
                           (end (+ start (length text))))
                      (unless (and (<= (point-min) start end (point-max))
                                   (equal text (buffer-substring-no-properties start end)))
                        (user-error "Il testo non corrisponde più in %s" (buffer-name))))))
                (setq group (nconc (prepare-change-group) group)))))
          (activate-change-group group)
          (setq activated t)
          (dolist (document documents)
            (with-current-buffer (gdev-operation-document-buffer document)
              (undo-boundary)
              (save-excursion
                (save-restriction
                  (widen)
                  (pcase-dolist (`(,original ,changed ,before ,after)
                                 (gdev-operation-document-patches document))
                    (let ((start (if redo original changed)))
                      (goto-char start)
                      (delete-region start (+ start (length (if redo before after))))
                      (insert (if redo after before))))))))
          (accept-change-group group)
          (setq accepted t)
          (dolist (document documents)
            (with-current-buffer (gdev-operation-document-buffer document)
              (gdev-operation--stamp-text-revision (funcall target document))
              (undo-boundary))))
      (when (and activated (not accepted))
        (cancel-change-group group)
        ;; Anche il ripristino del testo fa avanzare il tick di Emacs.
        (dolist (document documents)
          (with-current-buffer (gdev-operation-document-buffer document)
            (gdev-operation--stamp-text-revision (funcall expected document))))))))

(defun gdev-operation-replacement-size (changes)
  "Calcola il costo di CHANGES, oppure nil se supera il limite per operazione.
CHANGES contiene un elenco di righe di modifica per documento."
  (let ((limit (min (* 1024 1024) gdev-operation-text-budget))
        (bytes 0))
    (catch 'too-large
      (dolist (rows changes)
        (pcase-dolist (`(,_line ,_start ,_end ,before ,after) rows)
          (cl-incf bytes (+ 128 (string-bytes before) (string-bytes after)))
          (when (> bytes limit) (throw 'too-large nil))))
      bytes)))

(defun gdev-operation-record-replacement (documents &optional previous-ticks label)
  "Registra DOCUMENTS: coppie di buffer e righe prima e dopo la sostituzione.
PREVIOUS-TICKS associa ogni buffer al tick prima della modifica.
LABEL indica l'operazione da mostrare nella cronologia dello spazio."
  (unless gdev-operation--replaying
    (when-let* ((bytes (gdev-operation-replacement-size (mapcar #'cdr documents))))
      (let (patches)
        (dolist (document documents)
          (let ((buffer (car document))
                (delta 0)
                rows)
            (pcase-dolist (`(,_line ,start ,_end ,before ,after) (reverse (cdr document)))
              (push (list start (+ start delta) before after) rows)
              (cl-incf delta (- (length after) (length before))))
            (with-current-buffer buffer
              (let ((previous (and previous-ticks (gethash buffer previous-ticks))))
                (push (make-gdev-operation-document
                       :buffer buffer :patches rows
                       :before (or (and (eql previous (car gdev-operation--text-revision))
                                        (cdr gdev-operation--text-revision))
                                   (make-symbol "revisione"))
                       :after (make-symbol "revisione"))
                      patches)))))
        (dolist (document patches)
          (with-current-buffer (gdev-operation-document-buffer document)
            (gdev-operation--stamp-text-revision (gdev-operation-document-after document))))
        (gdev-operation-record
         (or label (format "sostituzione in %d file" (length patches)))
         (lambda () (gdev-operation--apply-patches patches nil))
         (lambda () (gdev-operation--apply-patches patches t))
         bytes)))))

(defun gdev-operation-install ()
  "Collega l'osservazione dei comandi e la cronologia del banco di lavoro."
  (add-hook 'pre-command-hook #'gdev-operation--observe)
  (dolist (command '(gdev-layout-close-editor-tab gdev-layout-reopen-document
                     gdev-editor-move-to-group gdev-workspaces--reorder-document
                     gdev-close-editor-group gdev-split-editor-right
                     gdev-split-editor-below gdev-split-editor-grid
                     gdev-rotate-editor-pair gdev-toggle-maximize-window))
    (unless (advice-member-p #'gdev-operation--capture-layout command)
      (advice-add command :around #'gdev-operation--capture-layout))))

(provide 'gdev-operation-history)
;;; gdev-operation-history.el ends here
