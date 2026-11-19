;;; gdev-outline.el --- Struttura del documento attivo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il riquadro segue il gruppo editor attivo. L’indice appartiene al riquadro
;; e le risposte in ritardo valgono soltanto per il documento e lo spazio
;; che le hanno richieste. Per un server Eglot si parte dai simboli LSP.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'imenu)
(require 'jsonrpc)

(declare-function eglot-current-server "eglot" ())
(declare-function eglot-imenu "eglot" ())
(declare-function eglot-managed-p "eglot" ())
(declare-function eglot-server-capable "eglot" (&rest capabilities))
(declare-function eglot-range-region "eglot" (range &optional markers))
(declare-function eglot--TextDocumentIdentifier "eglot" ())
(declare-function eglot--signal-textDocument/didChange "eglot" ())
(declare-function eglot--imenu-SymbolInformation "eglot" (symbols))
(declare-function gdev-close-document "gdev-commands" ())
(defvar gdev-context-items)

(cl-defstruct gdev-outline--node id name target start end children)
(defvar-local gdev-outline--owner nil)
(defvar-local gdev-outline--source nil)
(defvar-local gdev-outline--request nil)
(defvar-local gdev-outline--version nil)
(defvar-local gdev-outline--error nil)
(defvar-local gdev-outline--timer nil)
(defvar-local gdev-outline--nodes nil)
(defvar-local gdev-outline--positions [])
(defvar-local gdev-outline--rows nil)
(defvar-local gdev-outline--folded nil)
(defvar-local gdev-outline--geometry nil)
(defvar-local gdev-outline--current nil)
(defvar-local gdev-outline--highlight nil)
(defvar-local gdev-outline--last-point nil)
(defvar-local gdev-outline--subscribers nil)
;; Un cambio di modalità o `revert-buffer' azzererebbe i ganci locali e l'elenco: la
;; Struttura smetterebbe di seguire il documento.
(put 'gdev-outline--subscribers 'permanent-local t)

(defun gdev-outline--target-position (target)
  "Restituisci la posizione navigabile del TARGET nativo di Imenu."
  (let ((position (if (consp (cdr target)) (cadr target) (cdr target))))
    (cond ((markerp position) (marker-position position))
          ((overlayp position) (overlay-start position))
          ((and (integerp position) (> position 0)) position))))

(defun gdev-outline--nodes (index &optional parent)
  "Ricava la gerarchia navigabile dall'INDEX di Imenu sotto PARENT."
  (let ((occurrences (make-hash-table :test #'equal)) result)
    (dolist (entry index)
      (when (and (consp entry) (stringp (car entry)) (not (eq entry imenu--rescan-item)))
        (let* ((name (car entry))
               (label (substring-no-properties name))
               (number (gethash label occurrences 0))
               (id (cons (cons label number) parent))
               (group (imenu--subalist-p entry))
               (target (if group (get-text-property 0 'gdev-outline-target name) entry))
               (region (get-text-property 0 'breadcrumb-region name))
               (children (and group (gdev-outline--nodes (cdr entry) id)))
               (start (or (car region) (gdev-outline--target-position target))))
          (puthash label (1+ number) occurrences)
          (when (or start children)
            (push (make-gdev-outline--node :id id :name label :target target
                                           :start start :end (cdr region) :children children)
                  result)))))
    (nreverse result)))

(defun gdev-outline--positions (nodes)
  "Costruisci l'indice ordinato delle posizioni in NODES una volta per revisione."
  (let (positions)
    (cl-labels ((collect (entries)
                  (dolist (node entries)
                    (when (gdev-outline--node-start node) (push node positions))
                    (collect (gdev-outline--node-children node)))))
      (collect nodes))
    (vconcat (cl-stable-sort (nreverse positions) #'< :key #'gdev-outline--node-start))))

(defun gdev-outline--at-position (position)
  "Restituisci l'identità del nodo alla POSITION nell'indice corrente."
  (let ((low 0) (high (length gdev-outline--positions)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (gdev-outline--node-start (aref gdev-outline--positions middle)) position)
            (setq low (1+ middle))
          (setq high middle))))
    (when (> low 0)
      (let* ((node (aref gdev-outline--positions (1- low)))
             (id (gdev-outline--node-id node)))
        (while (and node (gdev-outline--node-end node)
                    (>= position (gdev-outline--node-end node)))
          (setq id (cdr id)
                node (and id (car (gethash id gdev-outline--rows)))))
        (and node id)))))

(defun gdev-outline--measure (window text)
  "Misura TEXT nel carattere del riquadro di WINDOW."
  (if (display-graphic-p (window-frame window))
      (string-pixel-width (propertize text 'face 'variable-pitch))
    (string-width text)))

(defun gdev-outline--fit (window text reserve)
  "Adatta TEXT al corpo di WINDOW, riservando RESERVE unità."
  (let* ((graphic (display-graphic-p (window-frame window)))
         (width (max 0 (- (window-body-width window graphic) reserve))))
    (gdev-ui-fit-text text width (apply-partially #'gdev-outline--measure window))))

(defun gdev-outline--row (window node depth)
  "Inserisci NODE alla profondità DEPTH nel riquadro WINDOW."
  (let* ((id (gdev-outline--node-id node))
         (children (gdev-outline--node-children node))
         (name (gdev-outline--node-name node))
         (folded (gethash id gdev-outline--folded))
         (indent (make-string (* 2 (min depth 5 (/ (window-body-width window) 5))) ?\s))
         (icon (cond ((not children) "  ") (folded "▸ ") (t "▾ ")))
         (start (point)))
    (insert indent)
    (if children
        (insert-text-button icon 'type 'gdev-ui-action
                            'help-echo (if folded "Espandi" "Comprimi")
                            'action #'gdev-outline--click-toggle)
      (insert icon))
    (insert-text-button (gdev-outline--fit window name (gdev-outline--measure window (concat indent icon)))
                        'type 'gdev-ui-action 'help-echo name 'action #'gdev-outline--click-activate)
    (insert "\n")
    (put-text-property start (point) 'gdev-outline-node node)
    (setcdr (gethash id gdev-outline--rows) start)
    (unless folded
      (dolist (child children) (gdev-outline--row window child (1+ depth))))))

(defun gdev-outline--row-position (id)
  "Trova la riga visibile di ID o del suo genitore più vicino."
  (when id
    (or (cdr (gethash id gdev-outline--rows)) (gdev-outline--row-position (cdr id)))))

(defun gdev-outline--render (window)
  "Disegna il contenuto nella WINDOW senza perdere selezione o scorrimento."
  (let* ((inhibit-read-only t)
         (selected (get-text-property (window-point window) 'gdev-outline-node))
         (first (get-text-property (window-start window) 'gdev-outline-node))
         (editor (gdev-layout-editor (window-frame window))))
    (setq gdev-outline--geometry (window-body-width window t)
          gdev-outline--rows (make-hash-table :test #'equal)
          gdev-outline--last-point nil)
    (cl-labels ((remember (nodes)
                  (dolist (node nodes)
                    (puthash (gdev-outline--node-id node) (cons node nil) gdev-outline--rows)
                    (remember (gdev-outline--node-children node)))))
      (remember gdev-outline--nodes))
    (erase-buffer)
    (insert (propertize "Struttura" 'face 'gdev-ui-side-title) "\n")
    (cond
     ((not gdev-outline--source)
      (insert (propertize "Apri un documento nell’editor" 'face 'gdev-ui-secondary) "\n"))
     (t
      (let ((name (buffer-name gdev-outline--source)))
        (insert (propertize (gdev-outline--fit window name 0) 'face 'gdev-ui-secondary
                            'help-echo name) "\n\n"))
      (cond (gdev-outline--nodes
             (dolist (node gdev-outline--nodes) (gdev-outline--row window node 0)))
            (gdev-outline--error
             (insert (propertize "Indice non disponibile" 'face 'gdev-ui-secondary
                                 'help-echo gdev-outline--error) "\n"))
            (gdev-outline--version
             (insert (propertize "Nessun simbolo nel documento" 'face 'gdev-ui-secondary) "\n"))
            (t (insert (propertize "Lettura dei simboli…" 'face 'gdev-ui-secondary) "\n")))))
    (set-window-start window (or (and first (gdev-outline--row-position (gdev-outline--node-id first)))
                                 (point-min)) t)
    (set-window-point window (or (and selected (gdev-outline--row-position (gdev-outline--node-id selected)))
                                 (and gdev-outline--nodes
                                      (gdev-outline--row-position (gdev-outline--node-id (car gdev-outline--nodes))))
                                 (point-min)))
    (when (window-live-p editor) (gdev-outline--track editor window))))

(defun gdev-outline--track (editor window)
  "Segui la posizione del cursore di EDITOR nella WINDOW della struttura."
  (let ((position (window-point editor)))
    (unless (or (null gdev-outline--rows) (equal position gdev-outline--last-point))
      (setq gdev-outline--last-point position
            gdev-outline--current (gdev-outline--at-position position))
      (if-let* ((row (gdev-outline--row-position gdev-outline--current)))
          (let ((end (save-excursion (goto-char row) (line-beginning-position 2))))
            (move-overlay gdev-outline--highlight row end (current-buffer))
            (when (eq editor (frame-selected-window (window-frame window)))
              (set-window-point window row)))
        (delete-overlay gdev-outline--highlight)))))

(defun gdev-outline--server ()
  "Restituisci il server che indicizza il documento corrente, se presente."
  (when (and (fboundp 'eglot-managed-p) (eglot-managed-p)
             (eglot-server-capable :documentSymbolProvider))
    (eglot-current-server)))

(defun gdev-outline--revision (source)
  "Restituisci la revisione e il server del documento SOURCE."
  (with-current-buffer source
    (cons (buffer-chars-modified-tick) (gdev-outline--server))))

(defun gdev-outline-symbol-path (editor)
  "Leggi il percorso del simbolo dall'indice di Struttura per EDITOR.
Il risultato ha forma (t . NOMI) quando il riquadro segue il documento,
anche se l'indice è in aggiornamento o il cursore è fuori da un simbolo."
  (when-let* ((frame (window-frame editor))
              (pane (alist-get 'outline (gdev-workspace-state-get 'gdev-activity-buffers frame)))
              ((buffer-live-p pane)))
    (with-current-buffer pane
      (when (and (eq gdev-outline--source (window-buffer editor))
                 (eq gdev-outline--owner (gdev-workspace-state-id frame)))
        (let ((current (equal gdev-outline--version (gdev-outline--revision gdev-outline--source))))
          (when (or current (get-buffer-window pane frame))
            (cons t (when current
                      (mapcar #'car (reverse (gdev-outline--at-position (window-point editor))))))))))))

(defun gdev-outline--showing ()
  "Restituisci la finestra che mostra il riquadro nel suo spazio attivo."
  (seq-find (lambda (window)
              (eq gdev-outline--owner (gdev-workspace-state-id (window-frame window))))
            (get-buffer-window-list (current-buffer) nil 'visible)))

(defun gdev-outline--editor-source (editor)
  "Restituisci il documento di EDITOR quando può esporre un indice."
  (when (window-live-p editor)
    (let ((source (window-buffer editor)))
      (with-current-buffer source
        (when (or buffer-file-name (derived-mode-p 'prog-mode 'text-mode)) source)))))

(defun gdev-outline--index (source)
  "Usa l'indice nativo della modalità di SOURCE senza richieste sincrone a Eglot."
  (with-current-buffer source
    (save-excursion
      (save-restriction
        (widen)
        (let ((imenu-create-index-function imenu-create-index-function))
          (remove-function imenu-create-index-function #'eglot-imenu)
          (condition-case nil (funcall imenu-create-index-function)
            (imenu-unavailable nil)))))))

(defun gdev-outline--document-symbol (symbol)
  "Converti SYMBOL nel formato gerarchico di Imenu, conservando la selezione."
  (let* ((name (plist-get symbol :name))
         (range (plist-get symbol :range))
         (selection (or (plist-get symbol :selectionRange) range)))
    (when (and (stringp name) range)
      (let* ((region (eglot-range-region range))
             (target (cons name (car (eglot-range-region selection))))
             (entry (propertize name 'breadcrumb-region region 'gdev-outline-target target))
             (children (seq-keep #'gdev-outline--document-symbol (plist-get symbol :children))))
        (cons entry (or children (cdr target)))))))

(defun gdev-outline--lsp-index (source identifier symbols)
  "Converti SYMBOLS di IDENTIFIER per il buffer SOURCE."
  (with-current-buffer source
    (save-restriction
      (widen)
      (if (plist-get (elt symbols 0) :location)
          (eglot--imenu-SymbolInformation
           (seq-filter (lambda (symbol)
                         (equal (plist-get (plist-get symbol :location) :uri)
                                (plist-get identifier :uri)))
                       symbols))
        (seq-keep #'gdev-outline--document-symbol symbols)))))

(defun gdev-outline--deliver (pane request producer)
  "Consegna a PANE il risultato di PRODUCER se REQUEST è ancora attuale."
  (when (buffer-live-p pane)
    (with-current-buffer pane
      (when (eq request gdev-outline--request)
        (setq gdev-outline--request nil)
        (when-let* ((window (gdev-outline--showing))
                    ((gdev-workspace-state-find gdev-outline--owner (window-frame window)))
                    (editor (gdev-layout-editor (window-frame window)))
                    (source (car request))
                    ((eq source (gdev-outline--editor-source editor)))
                    ((equal (cdr request) (gdev-outline--revision source))))
          (setq gdev-outline--error nil
                gdev-outline--nodes
                (condition-case err (gdev-outline--nodes (funcall producer))
                  (error (setq gdev-outline--error (error-message-string err)) nil))
                gdev-outline--positions (gdev-outline--positions gdev-outline--nodes)
                gdev-outline--version (cdr request))
          (gdev-outline--render window)
          (force-mode-line-update t))))))

(defun gdev-outline--load (pane)
  "Carica l'indice di PANE, se ancora mostrato, e assorbi richieste duplicate."
  (when (buffer-live-p pane)
    (with-current-buffer pane
      (setq gdev-outline--timer nil)
      (when-let* ((window (gdev-outline--showing))
                  (editor (gdev-layout-editor (window-frame window)))
                  (source (gdev-outline--editor-source editor))
                  ((eq source gdev-outline--source)))
        (let* ((version (gdev-outline--revision source))
               (server (cdr version))
               (request (cons source version))
               (fallback (lambda ()
                           (gdev-outline--deliver pane request (lambda () (gdev-outline--index source))))))
          (unless (or (equal gdev-outline--version version) (equal gdev-outline--request request))
            (setq gdev-outline--request request)
            (if (not server)
                (funcall fallback)
              (with-current-buffer source
                (condition-case nil
                    (let ((identifier (eglot--TextDocumentIdentifier)))
                      (eglot--signal-textDocument/didChange)
                      (jsonrpc-async-request
                       server :textDocument/documentSymbol (list :textDocument identifier)
                       :success-fn
                       (lambda (symbols)
                         (gdev-outline--deliver
                          pane request
                          (lambda () (if (seq-empty-p symbols) (gdev-outline--index source)
                                       (gdev-outline--lsp-index source identifier symbols)))))
                       :error-fn (lambda (_) (funcall fallback))
                       :timeout 4 :timeout-fn fallback))
                  (error (funcall fallback)))))))))))

(defun gdev-outline--cancel ()
  "Annulla la lettura dell'indice ancora in attesa nel riquadro."
  (when (timerp gdev-outline--timer) (cancel-timer gdev-outline--timer))
  (setq gdev-outline--timer nil gdev-outline--request nil))

(defun gdev-outline--schedule ()
  "Attendi che l'utente abbia finito di scrivere prima di leggere l'indice."
  (when (timerp gdev-outline--timer) (cancel-timer gdev-outline--timer))
  (setq gdev-outline--timer (run-with-idle-timer 0.2 nil #'gdev-outline--load (current-buffer))))

(defun gdev-outline--source-changed (&rest _)
  "Pianifica una lettura per i soli riquadri ancora visibili."
  (dolist (pane gdev-outline--subscribers)
    (when (buffer-live-p pane)
      (with-current-buffer pane
        (when (gdev-outline--showing) (gdev-outline--schedule))))))

(defun gdev-outline--source-command ()
  "Segui il cursore nei riquadri che osservano questo documento."
  (dolist (pane gdev-outline--subscribers)
    (when (buffer-live-p pane)
      (with-current-buffer pane
        (when-let* ((window (gdev-outline--showing))
                    (editor (gdev-layout-editor (window-frame window)))
                    ((eq gdev-outline--source (gdev-outline--editor-source editor))))
          (gdev-outline--track editor window))))))

(put 'gdev-outline--source-changed 'permanent-local-hook t)
(put 'gdev-outline--source-command 'permanent-local-hook t)

(defun gdev-outline--watch (source)
  "Collega il riquadro a SOURCE e rilascia gli agganci al documento precedente."
  (let ((pane (current-buffer)))
    (when (buffer-live-p gdev-outline--source)
      (with-current-buffer gdev-outline--source
        (setq gdev-outline--subscribers (delq pane gdev-outline--subscribers))
        (unless gdev-outline--subscribers
          (remove-hook 'after-change-functions #'gdev-outline--source-changed t)
          (remove-hook 'eglot-managed-mode-hook #'gdev-outline--source-changed t)
          (remove-hook 'post-command-hook #'gdev-outline--source-command t))))
    (setq gdev-outline--source source)
    (when source
      (with-current-buffer source
        (cl-pushnew pane gdev-outline--subscribers)
        (add-hook 'after-change-functions #'gdev-outline--source-changed nil t)
        (add-hook 'eglot-managed-mode-hook #'gdev-outline--source-changed nil t)
        (add-hook 'post-command-hook #'gdev-outline--source-command nil t)))))

(defun gdev-outline--sync (window)
  "Collega WINDOW all'editor più recente dello spazio senza muovere il fuoco."
  (let* ((editor (gdev-layout-editor (window-frame window)))
         (source (gdev-outline--editor-source editor)))
    (cond
     ((not (eq source gdev-outline--source))
      (gdev-outline--cancel)
      (gdev-outline--watch source)
      (setq gdev-outline--version nil gdev-outline--nodes nil gdev-outline--positions []
            gdev-outline--error nil)
      (clrhash gdev-outline--folded)
      (set-window-point window (point-min))
      (set-window-start window (point-min) t)
      (gdev-outline--render window))
     ((not (equal gdev-outline--geometry (window-body-width window t)))
      (gdev-outline--render window)))
    (when (and source (not gdev-outline--timer) (not gdev-outline--request)
               (not (equal gdev-outline--version (gdev-outline--revision source))))
      (gdev-outline--schedule))
    (when source (gdev-outline--track editor window))))

(defun gdev-outline--sync-frame (frame)
  "Aggiorna solo il riquadro di FRAME, se lo spazio lo sta mostrando."
  (when-let* ((pane (alist-get 'outline (gdev-workspace-state-get 'gdev-activity-buffers frame)))
              ((buffer-live-p pane)))
    (with-current-buffer pane
      (if-let* ((window (gdev-outline--showing)))
          (gdev-outline--sync window)
        (gdev-outline--cancel)))))

(defun gdev-outline--refresh-theme ()
  "Rimisura le etichette visibili quando cambia il tema."
  (dolist (frame (frame-list))
    (when-let* ((pane (alist-get 'outline (gdev-workspace-state-get 'gdev-activity-buffers frame)))
                ((buffer-live-p pane)))
      (with-current-buffer pane
        (when-let* ((window (gdev-outline--showing))) (gdev-outline--render window))))))

(defun gdev-outline-toggle ()
  "Espandi o comprimi i simboli della riga corrente."
  (interactive)
  (when-let* ((window (gdev-outline--showing))
              (node (get-text-property (point) 'gdev-outline-node))
              ((gdev-outline--node-children node))
              (id (gdev-outline--node-id node)))
    (if (gethash id gdev-outline--folded) (remhash id gdev-outline--folded)
      (puthash id t gdev-outline--folded))
    (gdev-outline--render window)))

(defun gdev-outline-activate ()
  "Vai alla definizione del simbolo o apri il gruppo sulla riga corrente."
  (interactive)
  (when-let* ((window (gdev-outline--showing))
              (node (get-text-property (point) 'gdev-outline-node)))
    (if-let* ((target (gdev-outline--node-target node)))
        (let* ((editor (gdev-layout-editor (window-frame window)))
               (source (gdev-outline--editor-source editor)))
          (unless (and (eq source gdev-outline--source)
                       (equal (car gdev-outline--version) (buffer-chars-modified-tick source)))
            (gdev-outline--sync window)
            (user-error "La struttura si sta aggiornando. Riprova tra poco"))
          (select-window editor)
          (let ((position (gdev-outline--target-position target)))
            (when (and position (not (<= (point-min) position (point-max)))) (widen)))
          (imenu target))
      (gdev-outline-toggle))))

(defun gdev-outline--click-activate (button)
  "Attiva il simbolo indicato da BUTTON."
  (goto-char (button-start button))
  (gdev-outline-activate))

(defun gdev-outline--click-toggle (button)
  "Espandi il gruppo indicato da BUTTON."
  (goto-char (button-start button))
  (gdev-outline-toggle))

(defun gdev-outline-refresh ()
  "Rileggi ora i simboli del documento attivo."
  (interactive)
  (when-let* ((window (gdev-outline--showing)))
    (gdev-outline--sync window)
    (gdev-outline--cancel)
    (setq gdev-outline--version nil)
    (gdev-outline--load (current-buffer))))

(defun gdev-outline--release ()
  "Rilascia il documento e la lettura in attesa quando si chiude lo spazio."
  (gdev-outline--cancel)
  (gdev-outline--watch nil))

(defvar-keymap gdev-outline-mode-map
  "RET" #'gdev-outline-activate
  "SPC" #'gdev-outline-toggle
  "g" #'gdev-outline-refresh
  "q" #'gdev-close-document)

(define-derived-mode gdev-outline-mode special-mode "Struttura"
  "Mostra la gerarchia dei simboli del documento attivo."
  (gdev-ui-view-setup 'sidebar)
  (gdev-layout-mark-auxiliary)
  (setq-local gdev-outline--folded (make-hash-table :test #'equal)
              gdev-outline--highlight (make-overlay (point-min) (point-min))
              gdev-context-items
              '(["Vai al simbolo" gdev-outline-activate (get-text-property (point) 'gdev-outline-node)
                 (:target view)]
                ["Espandi o comprimi" gdev-outline-toggle (get-text-property (point) 'gdev-outline-node)
                 (:target view)]
                ["Aggiorna" gdev-outline-refresh t (:target view)]))
  (overlay-put gdev-outline--highlight 'face 'gdev-ui-side-current)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook #'gdev-outline--release nil t))

;;;###autoload
(defun gdev-outline-show ()
  "Apri la struttura accanto al documento nello spazio corrente."
  (interactive)
  (let* ((owner (gdev-workspace-state-ensure-id))
         (pane (gdev-activity-buffer 'outline "*Struttura*" #'gdev-outline-mode)))
    (with-current-buffer pane
      (setq-local gdev-activity-kind nil gdev-outline--owner owner))
    (pop-to-buffer pane)
    (with-current-buffer pane
      (when-let* ((window (gdev-outline--showing)))
        (gdev-outline--sync window)
        (when (and gdev-outline--source (not gdev-outline--version))
          (gdev-outline--cancel)
          (gdev-outline--load pane))))))

(add-hook 'window-state-change-functions #'gdev-outline--sync-frame)
(add-hook 'gdev-ui-after-theme-hook #'gdev-outline--refresh-theme)

(provide 'gdev-outline)
;;; gdev-outline.el ends here
