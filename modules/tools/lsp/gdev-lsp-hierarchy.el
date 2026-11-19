;;; gdev-lsp-hierarchy.el --- Gerarchie delle chiamate e dei tipi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il server fornisce i simboli e le relazioni. La vista conserva soltanto
;; i rami consultati nello spazio di lavoro e i siti delle chiamate.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'eglot)
(require 'gdev-activity)
(require 'gdev-commands)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'url-util)

(declare-function gdev-lsp-visit-location "config" (file position encoding))
(defvar gdev-context-items)

(defconst gdev-lsp-hierarchy--kinds
  '((call "Gerarchia delle chiamate" :callHierarchyProvider :textDocument/prepareCallHierarchy
          (:callHierarchy/incomingCalls "Chiamanti" :from)
          (:callHierarchy/outgoingCalls "Chiamate" :to))
    (type "Gerarchia dei tipi" :typeHierarchyProvider :textDocument/prepareTypeHierarchy
          (:typeHierarchy/supertypes "Supertipi")
          (:typeHierarchy/subtypes "Sottotipi")))
  "Titolo, capacità, richiesta iniziale e direzioni per ogni gerarchia.")

(cl-defstruct (gdev-lsp-hierarchy--context
               (:constructor gdev-lsp-hierarchy--make-context))
  origin tick server encoding owner frame)

(cl-defstruct (gdev-lsp-hierarchy--node (:constructor gdev-lsp-hierarchy--make-node))
  item parent sites cycle branches)

(cl-defstruct (gdev-lsp-hierarchy--branch (:constructor gdev-lsp-hierarchy--make-branch))
  open pending error (children :unfetched))

(defvar-local gdev-lsp-hierarchy--context nil)
(defvar-local gdev-lsp-hierarchy--kind nil)
(defvar-local gdev-lsp-hierarchy--direction nil)
(defvar-local gdev-lsp-hierarchy--roots nil)
(defvar-local gdev-lsp-hierarchy--status nil)
(defvar-local gdev-lsp-hierarchy--requests nil)

(defvar-keymap gdev-lsp-hierarchy-mode-map
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "SPC" #'gdev-lsp-hierarchy-toggle
  "q" #'gdev-lsp-hierarchy-close)

(define-derived-mode gdev-lsp-hierarchy-mode special-mode "Gerarchia"
  "Mostra le relazioni di un simbolo fornite dal server di linguaggio."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local hl-line-face 'gdev-ui-side-selection)
  (hl-line-mode 1)
  (setq-local gdev-lsp-hierarchy--requests (make-hash-table :test 'eq)
              gdev-context-items
              '(["Espandi o comprimi il ramo" gdev-lsp-hierarchy-toggle
                 (get-text-property (point) 'gdev-lsp-hierarchy-node) (:target view)]))
  (add-hook 'kill-buffer-hook #'gdev-lsp-hierarchy--cancel-all nil t))

(defun gdev-lsp-hierarchy--origin-current-p (context)
  "Verifica che il documento e il server di CONTEXT siano ancora validi."
  (let ((origin (marker-buffer (gdev-lsp-hierarchy--context-origin context))))
    (and (buffer-live-p origin)
         (with-current-buffer origin
           (and (= (buffer-chars-modified-tick) (gdev-lsp-hierarchy--context-tick context))
                (eq (eglot-current-server) (gdev-lsp-hierarchy--context-server context)))))))

(defun gdev-lsp-hierarchy--active-p (context view)
  "Verifica che VIEW appartenga ancora allo spazio aperto di CONTEXT."
  (let ((owner (gdev-lsp-hierarchy--context-owner context))
        (frame (gdev-lsp-hierarchy--context-frame context)))
    (or (not owner)
        (when-let* ((tab (or (and (frame-live-p frame) (gdev-workspace-state-find owner frame))
                             (seq-some (lambda (other)
                                         (unless (eq other frame)
                                           (gdev-workspace-state-find owner other)))
                                       (frame-list)))))
          (eq view (gdev-workspace-state-read 'gdev-layout-auxiliary-buffer tab))))))

(defun gdev-lsp-hierarchy--cancel (token)
  "Invalida TOKEN nella vista e avvisa il server se l'identificatore è noto."
  (let ((id (gethash token gdev-lsp-hierarchy--requests)))
    (remhash token gdev-lsp-hierarchy--requests)
    (when (integerp id)
      (let ((server (gdev-lsp-hierarchy--context-server gdev-lsp-hierarchy--context)))
        (when (jsonrpc-running-p server)
          (ignore-errors (jsonrpc-notify server :$/cancelRequest (list :id id))))))))

(defun gdev-lsp-hierarchy--cancel-all ()
  "Invalida tutte le richieste della ricerca corrente."
  (maphash (lambda (token _id) (gdev-lsp-hierarchy--cancel token))
           gdev-lsp-hierarchy--requests))

(defun gdev-lsp-hierarchy-close ()
  "Annulla l'attesa e chiudi la vista della gerarchia."
  (interactive)
  (gdev-lsp-hierarchy--cancel-all)
  (gdev-close-document))

(defun gdev-lsp-hierarchy--request (token method parameters receive)
  "Invia METHOD con PARAMETERS e conserva il TOKEN finché è in attesa.
RECEIVE riceve il risultato e l'eventuale messaggio di errore."
  (let* ((view (current-buffer))
         (context gdev-lsp-hierarchy--context)
         (server (gdev-lsp-hierarchy--context-server context))
         (finish
          (lambda (result failure)
            (when (buffer-live-p view)
              (with-current-buffer view
                (when (and (eq context gdev-lsp-hierarchy--context)
                           (not (eq (gethash token gdev-lsp-hierarchy--requests 'revoked) 'revoked)))
                  (remhash token gdev-lsp-hierarchy--requests)
                  (when (gdev-lsp-hierarchy--active-p context view)
                    (if (gdev-lsp-hierarchy--origin-current-p context)
                        (funcall receive result failure)
                      (setq gdev-lsp-hierarchy--roots nil
                            gdev-lsp-hierarchy--status "Il documento è cambiato. Avvia di nuovo la ricerca.")
                      (gdev-lsp-hierarchy--cancel-all))
                    (gdev-lsp-hierarchy--render))))))))
    (puthash token nil gdev-lsp-hierarchy--requests)
    (condition-case problem
        (let ((id (car-safe
                   (jsonrpc-async-request
                    server method parameters
                    :success-fn (lambda (result) (funcall finish result nil))
                    :error-fn (lambda (failure)
                                (funcall finish nil (or (plist-get failure :message)
                                                        "Richiesta rifiutata dal server.")))
                    :timeout-fn (lambda () (funcall finish nil "Il server non ha risposto."))))))
          ;; Emacs 30 completa la stessa richiesta asincrona e restituisce nil.
          (unless (eq (gethash token gdev-lsp-hierarchy--requests 'revoked) 'revoked)
            (puthash token id gdev-lsp-hierarchy--requests)))
      (error (funcall finish nil (error-message-string problem))))))

(defun gdev-lsp-hierarchy--position (item)
  "Restituisci la posizione del nome del simbolo ITEM."
  (plist-get (or (plist-get item :selectionRange) (plist-get item :range)) :start))

(defun gdev-lsp-hierarchy--ancestors-contain-p (item parent)
  "Riconosci ITEM tra PARENT e i suoi antenati, anche con dati LSP diversi."
  (let ((uri (plist-get item :uri))
        (position (gdev-lsp-hierarchy--position item)))
    (cl-loop for ancestor = parent then (gdev-lsp-hierarchy--node-parent ancestor)
             while ancestor
             for current = (gdev-lsp-hierarchy--node-item ancestor)
             thereis (and (equal uri (plist-get current :uri))
                          (equal position (gdev-lsp-hierarchy--position current))))))

(defun gdev-lsp-hierarchy--nodes (result &optional parent field)
  "Crea le voci figlie di PARENT a partire da RESULT.
Quando FIELD è indicato, leggi i dati delle chiamate."
  (cl-loop for entry in (append result nil)
           for item = (if field (plist-get entry field) entry)
           for position = (gdev-lsp-hierarchy--position item)
           when (and (stringp (plist-get item :name))
                     (stringp (plist-get item :uri))
                     (natnump (plist-get position :line))
                     (natnump (plist-get position :character)))
           collect (gdev-lsp-hierarchy--make-node
                    :item item :parent parent
                    :sites (when field (plist-get entry :fromRanges))
                    :cycle (gdev-lsp-hierarchy--ancestors-contain-p item parent))))

(defun gdev-lsp-hierarchy--branch (node)
  "Restituisci lo stato della direzione corrente di NODE, se già consultata."
  (alist-get (car gdev-lsp-hierarchy--direction) (gdev-lsp-hierarchy--node-branches node)))

(defun gdev-lsp-hierarchy--expand (node)
  "Mostra il ramo di NODE nella direzione scelta, richiedendolo al primo accesso."
  (unless (gdev-lsp-hierarchy--node-cycle node)
    (unless (gdev-lsp-hierarchy--origin-current-p gdev-lsp-hierarchy--context)
      (user-error "Il documento è cambiato. Avvia di nuovo la ricerca"))
    (let* ((method (car gdev-lsp-hierarchy--direction))
           (field (nth 2 gdev-lsp-hierarchy--direction))
           (branch (or (gdev-lsp-hierarchy--branch node)
                       (setf (alist-get method (gdev-lsp-hierarchy--node-branches node))
                             (gdev-lsp-hierarchy--make-branch)))))
      (setf (gdev-lsp-hierarchy--branch-open branch) t)
      (when (and (eq (gdev-lsp-hierarchy--branch-children branch) :unfetched)
                 (not (gdev-lsp-hierarchy--branch-pending branch)))
        (let ((token (make-symbol "ramo")))
          (setf (gdev-lsp-hierarchy--branch-pending branch) token
                (gdev-lsp-hierarchy--branch-error branch) nil)
          (gdev-lsp-hierarchy--request
           token method (list :item (gdev-lsp-hierarchy--node-item node))
           (lambda (result failure)
             (setf (gdev-lsp-hierarchy--branch-pending branch) nil
                   (gdev-lsp-hierarchy--branch-error branch) failure)
             (unless failure
               (setf (gdev-lsp-hierarchy--branch-children branch)
                     (gdev-lsp-hierarchy--nodes result node field))))))))))

(defun gdev-lsp-hierarchy-toggle (&optional node)
  "Espandi o comprimi NODE, oppure il ramo al cursore."
  (interactive)
  (let* ((node (or node (get-text-property (point) 'gdev-lsp-hierarchy-node)
                   (user-error "Scegli un simbolo nella gerarchia")))
         (branch (gdev-lsp-hierarchy--branch node)))
    (if (and branch (gdev-lsp-hierarchy--branch-open branch))
        (progn
          (setf (gdev-lsp-hierarchy--branch-open branch) nil)
          (when-let* ((token (gdev-lsp-hierarchy--branch-pending branch)))
            (gdev-lsp-hierarchy--cancel token)
            (setf (gdev-lsp-hierarchy--branch-pending branch) nil)))
      (gdev-lsp-hierarchy--expand node))
    (gdev-lsp-hierarchy--render)))

(defun gdev-lsp-hierarchy--visit (uri position)
  "Apri nel gruppo editor il sorgente URI alla POSITION."
  (let ((context gdev-lsp-hierarchy--context))
    (unless (gdev-lsp-hierarchy--origin-current-p context)
      (user-error "Il documento è cambiato. Avvia di nuovo la ricerca"))
    (let* ((file (with-current-buffer (marker-buffer (gdev-lsp-hierarchy--context-origin context))
                   (eglot-uri-to-path uri)))
           (encoding (gdev-lsp-hierarchy--context-encoding context)))
      (gdev-lsp-visit-location file position encoding))))

(defun gdev-lsp-hierarchy--call-site (node)
  "Apri uno dei siti di chiamata associati a NODE."
  (let* ((from (if (eq (car gdev-lsp-hierarchy--direction) :callHierarchy/outgoingCalls)
                   (gdev-lsp-hierarchy--node-parent node)
                 node))
         (uri (plist-get (gdev-lsp-hierarchy--node-item from) :uri))
         (positions (mapcar (lambda (range) (plist-get range :start))
                            (gdev-lsp-hierarchy--node-sites node)))
         (position
          (if (cdr positions)
              (let* ((choices (mapcar (lambda (position)
                                         (cons (format "Riga %d · colonna %d"
                                                       (1+ (plist-get position :line))
                                                       (1+ (plist-get position :character)))
                                               position))
                                       positions))
                     (choice (completing-read "Punto di chiamata: " choices nil t)))
                (or (cdr (assoc choice choices)) (user-error "Nessun punto di chiamata scelto")))
            (car positions))))
    (gdev-lsp-hierarchy--visit uri position)))

(defun gdev-lsp-hierarchy--button (label action &optional id help face)
  "Inserisci il pulsante LABEL con ACTION, ID, HELP e FACE."
  (insert-text-button label 'type 'gdev-ui-action
                      'gdev-lsp-hierarchy-control id
                      'face (or face 'gdev-ui-action)
                      'help-echo (or help label)
                      'action (lambda (button)
                                (goto-char (button-start button))
                                (funcall action))))

(defun gdev-lsp-hierarchy--hint (text &optional warning)
  "Inserisci il dettaglio TEXT, con WARNING quando richiede attenzione."
  (insert (propertize text 'face (if warning 'gdev-ui-status-warning 'gdev-ui-secondary)) "\n"))

(defun gdev-lsp-hierarchy--row (node depth)
  "Disegna NODE e i discendenti aperti, partendo da DEPTH."
  (let* ((item (gdev-lsp-hierarchy--node-item node))
         (name (replace-regexp-in-string "[\r\n]+" " " (plist-get item :name)))
         (uri (plist-get item :uri))
         (path (decode-coding-string (url-unhex-string uri) 'utf-8-unix))
         (position (gdev-lsp-hierarchy--position item))
         (indent (make-string (* 2 (min depth 8)) ?\s))
         (branch (gdev-lsp-hierarchy--branch node))
         (open (and branch (gdev-lsp-hierarchy--branch-open branch)))
         (start (point)))
    (insert indent)
    (if (gdev-lsp-hierarchy--node-cycle node)
        (insert "↪")
      (gdev-lsp-hierarchy--button (if open "▾" "▸")
                                  (lambda () (gdev-lsp-hierarchy-toggle node))
                                  'disclosure
                                  (format "%s le relazioni di %s" (if open "Comprimi" "Espandi") name)))
    (insert " ")
    (gdev-lsp-hierarchy--button name (lambda () (gdev-lsp-hierarchy--visit uri position))
                                'symbol (format "%s\n%s · riga %d" name path
                                                (1+ (plist-get position :line))))
    (insert "\n" indent "   "
            (propertize (format "%s:%d%s" (file-name-nondirectory path)
                                (1+ (plist-get position :line))
                                (if (gdev-lsp-hierarchy--node-cycle node) " · Ciclo" ""))
                        'face 'gdev-ui-secondary 'help-echo path)
            "\n")
    (when-let* ((sites (gdev-lsp-hierarchy--node-sites node))
                ((not (seq-empty-p sites))))
      (insert indent "   ")
      (gdev-lsp-hierarchy--button
       (if (length= sites 1) "Punto di chiamata" (format "%d punti di chiamata" (length sites)))
       (lambda () (gdev-lsp-hierarchy--call-site node)) 'call-site)
      (insert "\n"))
    (put-text-property start (point) 'gdev-lsp-hierarchy-node node)
    (when open
      (cond
       ((gdev-lsp-hierarchy--branch-pending branch)
        (gdev-lsp-hierarchy--hint (concat indent "   Caricamento…")))
       ((gdev-lsp-hierarchy--branch-error branch)
        (gdev-lsp-hierarchy--hint (concat indent "   " (gdev-lsp-hierarchy--branch-error branch)) t)
        (insert indent "   ")
        (gdev-lsp-hierarchy--button "Riprova" (lambda ()
                                              (gdev-lsp-hierarchy--expand node)
                                              (gdev-lsp-hierarchy--render)))
        (insert "\n"))
       ((gdev-lsp-hierarchy--branch-children branch)
        (dolist (child (gdev-lsp-hierarchy--branch-children branch))
          (gdev-lsp-hierarchy--row child (1+ depth))))
       (t (gdev-lsp-hierarchy--hint (concat indent "   Nessuna relazione.")))))))

(defun gdev-lsp-hierarchy--render ()
  "Ridisegna i rami aperti e conserva la selezione nei risultati ancora presenti."
  (let* ((window (get-buffer-window (current-buffer) 'visible))
         (position (if window (window-point window) (point)))
         (node (get-text-property position 'gdev-lsp-hierarchy-node))
         (control (get-text-property position 'gdev-lsp-hierarchy-control))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (nth 1 gdev-lsp-hierarchy--kind) 'face 'gdev-ui-view-title) "\n\n")
    (dolist (direction (nthcdr 4 gdev-lsp-hierarchy--kind))
      (gdev-lsp-hierarchy--button
       (nth 1 direction)
       (lambda ()
         (setq gdev-lsp-hierarchy--direction direction)
         (gdev-lsp-hierarchy--render))
       (car direction) nil (and (eq direction gdev-lsp-hierarchy--direction) 'gdev-ui-action-primary))
      (insert "  "))
    (insert "\n\n")
    (let ((first (point)))
      (cond
       ((eq gdev-lsp-hierarchy--status 'pending)
        (gdev-lsp-hierarchy--hint "Ricerca del simbolo…"))
       ((stringp gdev-lsp-hierarchy--status)
        (gdev-lsp-hierarchy--hint gdev-lsp-hierarchy--status t))
       (gdev-lsp-hierarchy--roots
        (dolist (root gdev-lsp-hierarchy--roots) (gdev-lsp-hierarchy--row root 0)))
       (t (gdev-lsp-hierarchy--hint "Nessun simbolo disponibile per questa posizione.")))
      (let* ((start (if node (text-property-any first (point-max) 'gdev-lsp-hierarchy-node node)
                      (point-min)))
             (end (and start (if node (next-single-property-change start 'gdev-lsp-hierarchy-node)
                               first)))
             (selected (and control start end
                            (text-property-any start end 'gdev-lsp-hierarchy-control control))))
        (goto-char (or selected (and node start) first))
        (when (window-live-p window) (set-window-point window (point)))))))

;;;###autoload
(defun gdev-lsp-hierarchy-show (kind)
  "Apri la gerarchia KIND, `call' o `type', del simbolo nell'editor."
  (gdev-call-with-editor
   (lambda ()
     (let* ((spec (or (assq kind gdev-lsp-hierarchy--kinds)
                      (error "Gerarchia sconosciuta: %s" kind)))
            (server (or (and (eglot-managed-p) (eglot-current-server))
                        (user-error "Sul documento attivo manca una connessione al server di linguaggio"))))
       (unless (eglot-server-capable (nth 2 spec))
         (user-error "Il server del documento non offre questa gerarchia"))
       (eglot--signal-textDocument/didChange)
       (let* ((parameters (eglot--TextDocumentPositionParams))
              (frame (selected-frame))
              (owner (and gdev-layout-mode (gdev-workspace-state-ensure-id frame)))
              (context (gdev-lsp-hierarchy--make-context
                        :origin (point-marker) :tick (buffer-chars-modified-tick)
                        :server server :encoding eglot-move-to-linepos-function
                        :owner owner :frame frame))
              (buffer (if owner
                          (gdev-activity-buffer 'lsp-hierarchy "*Gerarchia*"
                                                #'gdev-lsp-hierarchy-mode)
                        (get-buffer-create "*Gerarchia*"))))
         (with-current-buffer buffer
           (unless (derived-mode-p 'gdev-lsp-hierarchy-mode) (gdev-lsp-hierarchy-mode))
           (gdev-lsp-hierarchy--cancel-all)
           (setq-local gdev-activity-kind nil
                       gdev-lsp-hierarchy--context context
                       gdev-lsp-hierarchy--kind spec
                       gdev-lsp-hierarchy--direction (nth 4 spec)
                       gdev-lsp-hierarchy--roots nil
                       gdev-lsp-hierarchy--status 'pending)
           (goto-char (point-min))
           (gdev-lsp-hierarchy--render))
         (pop-to-buffer buffer)
         (with-current-buffer buffer
           (gdev-lsp-hierarchy--request
            (make-symbol "simbolo") (nth 3 spec) parameters
            (lambda (result failure)
              (setq gdev-lsp-hierarchy--status failure
                    gdev-lsp-hierarchy--roots (gdev-lsp-hierarchy--nodes result)))))
         buffer)))))

(provide 'gdev-lsp-hierarchy)
;;; gdev-lsp-hierarchy.el ends here
