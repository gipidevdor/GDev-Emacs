;;; gdev-lsp-refactor.el --- Anteprima di rinomina ed estrazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Eglot negozia le coordinate con il server. GDev mostra e applica
;; insieme le modifiche testuali, come operazione dello spazio di lavoro.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'diff-mode)
(require 'eglot)
(require 'seq)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-operation-history)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function gdev-close-document "gdev-commands" ())

(defvar eglot--docver)
(defvar eglot--versioned-identifier)

(cl-defstruct gdev-lsp-refactor--request
  frame owner source source-file source-tick server time buffers column move-to-column)

(cl-defstruct gdev-lsp-refactor--file path stamp visiting tick rows)

(cl-defstruct gdev-lsp-refactor--preview request label files)

(defvar-local gdev-lsp-refactor--preview nil)

(defun gdev-lsp-refactor--capture ()
  "Acquisisci lo spazio, il server e le revisioni alla richiesta."
  (let ((buffers (make-hash-table :test #'eq)))
    (dolist (buffer (buffer-list))
      (when (buffer-file-name buffer)
        (puthash buffer (buffer-chars-modified-tick buffer) buffers)))
    (make-gdev-lsp-refactor--request
     :frame (selected-frame) :owner (gdev-workspace-state-ensure-id)
     :source (current-buffer) :source-file buffer-file-name
     :source-tick (buffer-chars-modified-tick) :server (eglot-current-server)
     :time (current-time) :buffers buffers
     :column eglot-current-linepos-function :move-to-column eglot-move-to-linepos-function)))

(defun gdev-lsp-refactor--check-origin (request &optional changing-text)
  "Valida REQUEST. Con CHANGING-TEXT il gruppo ha già iniziato a scrivere."
  (let ((source (gdev-lsp-refactor--request-source request)))
    (unless (and (eq (selected-frame) (gdev-lsp-refactor--request-frame request))
                 (eq (gdev-workspace-state-id) (gdev-lsp-refactor--request-owner request))
                 (buffer-live-p source)
                 (with-current-buffer source
                   (and (equal buffer-file-name (gdev-lsp-refactor--request-source-file request))
                        (eq (eglot-current-server) (gdev-lsp-refactor--request-server request))
                        (or changing-text
                            (eql (gdev-lsp-refactor--request-source-tick request)
                                 (buffer-chars-modified-tick))))))
      (user-error "Lo spazio o il documento di origine è cambiato. Ripeti l'azione"))))

(defun gdev-lsp-refactor--stamp (file)
  "Restituisci la revisione su disco di FILE."
  (when-let* ((attrs (file-attributes file)))
    (list (file-attribute-modification-time attrs) (file-attribute-size attrs)
          (file-attribute-file-identifier attrs))))

(defun gdev-lsp-refactor--entries (workspace-edit)
  "Leggi i gruppi (URI VERSIONE MODIFICHE) di WORKSPACE-EDIT."
  (if-let* ((documents (plist-get workspace-edit :documentChanges)))
      (mapcar (lambda (document)
                (let ((identity (plist-get document :textDocument)))
                  (list (plist-get identity :uri) (plist-get identity :version)
                        (plist-get document :edits))))
              documents)
    (cl-loop for (uri edits) on (plist-get workspace-edit :changes) by #'cddr
             collect (list uri nil edits))))

(defun gdev-lsp-refactor--file-operations-p (edit)
  "Indica se EDIT include creazione, rinomina o cancellazione di file."
  (seq-some (lambda (change) (plist-get change :kind)) (plist-get edit :documentChanges)))

(defun gdev-lsp-refactor--coordinate (value)
  "Controlla VALUE e trasformala in una coppia (RIGA . COLONNA)."
  (let ((line (plist-get value :line))
        (column (plist-get value :character)))
    (unless (and (natnump line) (natnump column))
      (user-error "Il server ha indicato una posizione non valida"))
    (cons line column)))

(defun gdev-lsp-refactor--rows (edits request)
  "Prepara le righe di EDITS usando le coordinate di REQUEST, in ordine inverso."
  (let ((entries (mapcar (lambda (edit)
                           (let ((range (plist-get edit :range))
                                 (text (plist-get edit :newText)))
                             (unless (stringp text) (user-error "Il server ha restituito testo non valido"))
                             (list (gdev-lsp-refactor--coordinate (plist-get range :start))
                                   (gdev-lsp-refactor--coordinate (plist-get range :end)) text)))
                         edits)))
    (setq entries (cl-stable-sort entries (lambda (first second)
                                             (or (< (car first) (car second))
                                                 (and (= (car first) (car second))
                                                      (< (cdr first) (cdr second)))))
                                  :key #'car))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((line 0) (last-end (point)) rows)
          (cl-labels ((locate (position)
                        (let ((target (car position))
                              (column (cdr position)))
                          (unless (and (>= target line)
                                       (zerop (forward-line (- target line))))
                            (user-error "La riga indicata dal server è fuori dal documento"))
                          (setq line target)
                          (funcall (gdev-lsp-refactor--request-move-to-column request) column)
                          (unless (= (funcall (gdev-lsp-refactor--request-column request)) column)
                            (user-error "La colonna indicata dal server è fuori dal documento"))
                          (point))))
            (pcase-dolist (`(,start ,end ,new) entries)
              (let* ((beginning (locate start))
                     (ending (locate end)))
                (unless (<= last-end beginning ending)
                  (user-error "Il server ha proposto cambiamenti sovrapposti"))
                (setq last-end ending)
                (let ((old (buffer-substring-no-properties beginning ending)))
                  (unless (equal old new)
                    (push (list (1+ (car start)) beginning ending old new) rows))))))
          rows)))))

(defun gdev-lsp-refactor--version ()
  "Leggi la versione del documento da Eglot in Emacs 30 o successivo."
  (if (boundp 'eglot--docver) eglot--docver
    (bound-and-true-p eglot--versioned-identifier)))

(defun gdev-lsp-refactor--prepare-file (path version edits request)
  "Prepara EDITS per PATH alla VERSIONE associata a REQUEST."
  (let* ((stamp (gdev-lsp-refactor--stamp path))
         (buffer (find-buffer-visiting path))
         (tick (and buffer (buffer-chars-modified-tick buffer)))
         rows)
    (unless (and stamp (file-regular-p path) (file-writable-p path)
                 (or (file-remote-p path)
                     (not (time-less-p (gdev-lsp-refactor--request-time request) (car stamp)))))
      (user-error "Il file è cambiato o non è scrivibile. Ripeti l'azione per %s" path))
    (when (and version
               (not (and (integerp version) buffer
                         (with-current-buffer buffer
                           (and (eq (eglot-current-server) (gdev-lsp-refactor--request-server request))
                                (eql version (gdev-lsp-refactor--version)))))))
      (user-error "La versione del server non corrisponde al documento %s" path))
    (setq rows
          (if buffer
              (with-current-buffer buffer
                (let ((before (gethash buffer (gdev-lsp-refactor--request-buffers request))))
                  (unless (and (not buffer-read-only) (not (eq buffer-undo-list t))
                               (verify-visited-file-modtime buffer)
                               (if before (= before tick) (not (buffer-modified-p))))
                    (user-error "Il documento è cambiato o è in sola lettura. Ripeti l'azione per %s" path)))
                (gdev-lsp-refactor--rows edits request))
            (with-temp-buffer
              (insert-file-contents path)
              (gdev-lsp-refactor--rows edits request))))
    (when rows
      (make-gdev-lsp-refactor--file :path path :stamp stamp :visiting buffer :tick tick :rows rows))))

(defun gdev-lsp-refactor--prepare (edit request)
  "Compila l'anteprima di EDIT per REQUEST senza visitare nuovi file."
  (gdev-lsp-refactor--check-origin request)
  (let ((seen (make-hash-table :test #'equal)))
    (delq nil
          (mapcar (pcase-lambda (`(,uri ,version ,edits))
                    (unless (and (or (stringp uri) (keywordp uri)) (sequencep edits))
                      (user-error "Il server ha restituito un documento non valido"))
                    (let* ((path (with-current-buffer (gdev-lsp-refactor--request-source request)
                                   (eglot-uri-to-path uri)))
                           (key (and (file-name-absolute-p path) (file-truename path))))
                      (unless (and key (not (gethash key seen)))
                        (user-error "Il server ha restituito un documento ripetuto o non gestito"))
                      (puthash key t seen)
                      (gdev-lsp-refactor--prepare-file path version edits request)))
                  (gdev-lsp-refactor--entries edit)))))

(defun gdev-lsp-refactor--check-file (file buffer)
  "Verifica che BUFFER corrisponda ancora all'anteprima FILE."
  (let ((visiting (gdev-lsp-refactor--file-visiting file))
        (path (gdev-lsp-refactor--file-path file)))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (unless (and (not buffer-read-only) (not (eq buffer-undo-list t))
                     (file-writable-p path) (verify-visited-file-modtime buffer)
                     (equal (gdev-lsp-refactor--file-stamp file) (gdev-lsp-refactor--stamp path))
                     (if visiting
                         (and (eq visiting buffer)
                              (= (buffer-chars-modified-tick) (gdev-lsp-refactor--file-tick file)))
                       (not (buffer-modified-p)))
                     (cl-every (pcase-lambda (`(,_line ,beginning ,end ,old ,_new))
                                 (and (<= (point-min) beginning end (point-max))
                                      (equal old (buffer-substring-no-properties beginning end))))
                               (gdev-lsp-refactor--file-rows file)))
          (user-error "Il documento è cambiato o è in sola lettura. Ricrea l'anteprima per %s" path))))))

(defun gdev-lsp-refactor--change (preview)
  "Applica PREVIEW ai buffer come gruppo indivisibile e registra l'inverso."
  (let ((request (gdev-lsp-refactor--preview-request preview))
        (ticks (make-hash-table :test #'eq))
        opened documents group activated accepted)
    (unwind-protect
        (progn
          (gdev-lsp-refactor--check-origin request)
          (unless (gdev-operation-replacement-size
                   (mapcar #'gdev-lsp-refactor--file-rows (gdev-lsp-refactor--preview-files preview)))
            (user-error "Le modifiche superano la capacità della cronologia dello spazio"))
          (dolist (file (gdev-lsp-refactor--preview-files preview))
            (let* ((path (gdev-lsp-refactor--file-path file))
                   (existing (find-buffer-visiting path))
                   (buffer (or existing (find-file-noselect path))))
              (unless existing (push buffer opened))
              (push (cons buffer file) documents)))
          (dolist (entry documents)
            (let ((buffer (car entry)))
              (gdev-lsp-refactor--check-file (cdr entry) buffer)
              (with-current-buffer buffer
                (puthash buffer (buffer-chars-modified-tick) ticks)
                (undo-boundary)
                (setq group (nconc (prepare-change-group) group)))))
          (gdev-lsp-refactor--check-origin request)
          (activate-change-group group)
          (setq activated t)
          (pcase-dolist (`(,buffer . ,file) documents)
            (with-current-buffer buffer
              (save-excursion
                (save-restriction
                  (widen)
                  (pcase-dolist (`(,_line ,beginning ,end ,_old ,new) (gdev-lsp-refactor--file-rows file))
                    (goto-char beginning)
                    (delete-region beginning end)
                    (insert new))))))
          (gdev-lsp-refactor--check-origin request t)
          (accept-change-group group)
          (setq accepted t)
          (gdev-operation-record-replacement
           (mapcar (lambda (entry)
                     (with-current-buffer (car entry) (undo-boundary))
                     (cons (car entry) (gdev-lsp-refactor--file-rows (cdr entry))))
                   documents)
           ticks (gdev-lsp-refactor--preview-label preview)))
      (unless accepted
        (when activated (cancel-change-group group))
        (dolist (buffer opened)
          (when (and (buffer-live-p buffer) (not (buffer-modified-p buffer)))
            (kill-buffer buffer)))))))

(defun gdev-lsp-refactor-apply ()
  "Conferma e applica le modifiche testuali dell'anteprima corrente."
  (interactive)
  (let ((preview (or gdev-lsp-refactor--preview (user-error "Ricrea l'anteprima"))))
    (when (yes-or-no-p (format "Applica le modifiche a %d file? "
                              (length (gdev-lsp-refactor--preview-files preview))))
      (unless (eq preview gdev-lsp-refactor--preview) (user-error "L'anteprima è cambiata"))
      (gdev-lsp-refactor--change preview)
      (gdev-lsp-refactor-cancel)
      (message "Modifiche applicate. Salva i documenti quando hai finito"))))

(defun gdev-lsp-refactor-cancel ()
  "Chiudi l'anteprima tenendo le modifiche fuori dai documenti."
  (interactive)
  (setq gdev-lsp-refactor--preview nil)
  (gdev-close-document))

(defun gdev-lsp-refactor--window-changed (_window)
  "Scarta il piano se l'anteprima è stata chiusa dal comando comune."
  (unless (get-buffer-window (current-buffer) t)
    (setq gdev-lsp-refactor--preview nil)))

(defvar-keymap gdev-lsp-refactor-preview-mode-map
  "C-c C-a" #'gdev-lsp-refactor-apply
  "q" #'gdev-lsp-refactor-cancel
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-lsp-refactor-preview-mode special-mode "Anteprima modifiche"
  "Verifica e applica la ristrutturazione proposta dal server di linguaggio."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (add-hook 'window-buffer-change-functions #'gdev-lsp-refactor--window-changed nil t))

(defun gdev-lsp-refactor--show (edit label request)
  "Mostra EDIT, con LABEL, nello spazio di REQUEST."
  (let* ((files (gdev-lsp-refactor--prepare edit request))
         (directory (buffer-local-value 'default-directory (gdev-lsp-refactor--request-source request))))
    (unless files (user-error "Il server non ha proposto cambiamenti"))
    (setf (gdev-lsp-refactor--request-buffers request) nil)
    (let ((buffer (gdev-activity-buffer 'refactor "*Anteprima modifiche*" #'gdev-lsp-refactor-preview-mode)))
      (with-current-buffer buffer
        (setq-local gdev-activity-kind nil)
        (setq gdev-lsp-refactor--preview
              (make-gdev-lsp-refactor--preview :request request :label label :files files))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize label 'face 'gdev-ui-view-title) "\n"
                  (propertize (format "%d file · Esamina le modifiche prima di applicarle" (length files))
                              'face 'gdev-ui-secondary) "\n\n")
          (dolist (action '(("Applica modifiche" gdev-lsp-refactor-apply gdev-ui-action-primary)
                            ("Annulla" gdev-lsp-refactor-cancel gdev-ui-action)))
            (insert-text-button (car action) 'type 'gdev-ui-action 'face (nth 2 action)
                                'action (lambda (_) (call-interactively (cadr action))))
            (insert "  "))
          (insert "\n")
          (dolist (file files)
            (let* ((path (gdev-lsp-refactor--file-path file))
                   (name (file-relative-name path directory)))
              (insert "\n" (propertize name 'face 'gdev-ui-view-heading 'help-echo path) "\n")
              (pcase-dolist (`(,line ,_beginning ,_end ,before ,after)
                             (reverse (gdev-lsp-refactor--file-rows file)))
                (insert (propertize (format "Riga %d" line) 'face 'gdev-ui-secondary) "\n")
                (unless (string-empty-p before)
                  (insert (propertize (concat "− " (string-replace "\n" "\n− " before))
                                      'face '(diff-removed fixed-pitch)) "\n"))
                (unless (string-empty-p after)
                  (insert (propertize (concat "+ " (string-replace "\n" "\n+ " after))
                                      'face '(diff-added fixed-pitch)) "\n")))))
          (goto-char (point-min))
          (set-buffer-modified-p nil)))
      (pop-to-buffer buffer))))

(defun gdev-lsp-refactor--delegate (edit action request)
  "Conferma un EDIT su file o un'azione opaca ACTION da passare a Eglot."
  (when (yes-or-no-p "Il server richiede un'azione senza anteprima testuale o annullamento di gruppo. Continuare con Eglot? ")
    (gdev-lsp-refactor--check-origin request)
    (let ((server (gdev-lsp-refactor--request-server request)))
      (if action
          (eglot-execute server action)
        (let ((apply-edit (symbol-function 'eglot--apply-workspace-edit)))
          (if (= (car (func-arity apply-edit)) 2)
              (funcall apply-edit edit 'eglot-rename)
            (funcall apply-edit server edit 'eglot-rename)))))))

(defun gdev-lsp-refactor-rename ()
  "Richiedi la rinomina del simbolo e mostra tutte le modifiche testuali."
  (interactive)
  (let* ((request (gdev-lsp-refactor--capture))
         (server (gdev-lsp-refactor--request-server request))
         (position (eglot--TextDocumentPositionParams))
         (prepare (when (eglot-server-capable :renameProvider :prepareProvider)
                    (or (eglot--request server :textDocument/prepareRename position)
                        (user-error "Il server non permette di rinominare questo simbolo"))))
         (symbol (or (plist-get prepare :placeholder)
                     (when-let* ((range (or (plist-get prepare :range)
                                            (and (plist-member prepare :start) prepare)))
                                 (bounds (eglot-range-region range)))
                       (buffer-substring-no-properties (car bounds) (cdr bounds)))
                     (thing-at-point 'symbol t)))
         (name (read-string (if symbol (format "Nuovo nome per «%s»: " symbol) "Nuovo nome: ")
                            nil nil symbol)))
    (unless (string-blank-p name)
      (gdev-lsp-refactor--check-origin request)
      (let ((edit (eglot--request server :textDocument/rename (append position (list :newName name)))))
        (if (gdev-lsp-refactor--file-operations-p edit)
            (gdev-lsp-refactor--delegate edit nil request)
          (gdev-lsp-refactor--show edit (format "Rinomina in «%s»" name) request))))))

(defun gdev-lsp-refactor--extract-actions (server bounds)
  "Richiedi al SERVER soltanto azioni di estrazione nei BOUNDS."
  (let* ((beginning (car bounds))
         (end (or (cadr bounds) beginning))
         (diagnostics (seq-keep (lambda (diagnostic)
                                 (alist-get 'eglot-lsp-diag (flymake-diagnostic-data diagnostic)))
                               (flymake-diagnostics beginning end)))
         (actions (eglot--request
                   server :textDocument/codeAction
                   (list :textDocument (eglot--TextDocumentIdentifier)
                         :range (list :start (eglot--pos-to-lsp-position beginning)
                                      :end (eglot--pos-to-lsp-position end))
                         :context (list :only ["refactor.extract"] :diagnostics (vconcat diagnostics))))))
    (seq-filter (lambda (action)
                  (let ((kind (plist-get action :kind)))
                    (and (stringp (plist-get action :title)) (not (plist-get action :disabled))
                         (if (stringp kind)
                             (or (equal kind "refactor.extract") (string-prefix-p "refactor.extract." kind))
                           (stringp (plist-get action :command))))))
                actions)))

(defun gdev-lsp-refactor-extract ()
  "Mostra le estrazioni disponibili per il simbolo o la selezione correnti."
  (interactive)
  (let* ((request (gdev-lsp-refactor--capture))
         (server (gdev-lsp-refactor--request-server request))
         (bounds (eglot--code-action-bounds))
         (actions (gdev-lsp-refactor--extract-actions server bounds))
         (items (mapcar (lambda (action) (cons (plist-get action :title) action)) actions)))
    (unless items (user-error "Il server non offre estrazioni qui"))
    (gdev-lsp-refactor--check-origin request)
    (let ((action (if (cdr items) (cdr (assoc (completing-read "Estrai: " items nil t) items))
                    (cdar items))))
      (gdev-lsp-refactor--check-origin request)
      (when (and (null (plist-get action :edit)) (null (plist-get action :command))
                 (plist-get action :data) (eglot-server-capable :codeActionProvider :resolveProvider))
        (setq action (eglot--request server :codeAction/resolve action)))
      (unless action (user-error "Il server non ha restituito le modifiche dell'estrazione"))
      (let ((edit (plist-get action :edit)))
        (if (and edit (null (plist-get action :command)) (not (gdev-lsp-refactor--file-operations-p edit)))
            (gdev-lsp-refactor--show edit "Estrazione" request)
          (gdev-lsp-refactor--delegate nil action request))))))

(provide 'gdev-lsp-refactor)
;;; gdev-lsp-refactor.el ends here
