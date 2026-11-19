;;; gdev-lsp-navigation.el --- Risultati di navigazione del codice -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Riferimenti, implementazioni e definizioni del tipo condividono una vista
;; per spazio. Le richieste sono asincrone e il sorgente si apre al salto.

;;; Code:

(require 'button)
(require 'eglot)
(require 'gdev-activity)
(require 'gdev-commands)
(require 'gdev-ui)
(require 'jsonrpc)

(declare-function gdev-lsp--check-capability "config" (capability))
(declare-function gdev-lsp-visit-location "config" (file position encoding))

(defconst gdev-lsp-navigation--kinds
  '((references "Tutti i riferimenti" :textDocument/references :referencesProvider
                :context (:includeDeclaration t))
    (implementation "Implementazioni" :textDocument/implementation :implementationProvider)
    (type-definition "Definizioni del tipo" :textDocument/typeDefinition :typeDefinitionProvider)))

(defconst gdev-lsp-navigation--batch-size 100)
(defvar-local gdev-lsp-navigation--request nil)
(defvar-local gdev-lsp-navigation--pending nil)
(defvar-local gdev-lsp-navigation--heading nil)
(defvar-local gdev-lsp-navigation--total 0)
(defvar-local gdev-lsp-navigation--root nil)
(defvar-local gdev-lsp-navigation--encoding nil)
(defvar-local gdev-lsp-navigation--last-file nil)

(defvar-keymap gdev-lsp-navigation-mode-map
  "n" #'forward-button
  "p" #'backward-button
  "q" #'gdev-close-document)

(define-derived-mode gdev-lsp-navigation-mode special-mode "Navigazione del codice"
  "Consulta i risultati del server di linguaggio."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local hl-line-face 'gdev-ui-side-selection)
  (hl-line-mode 1))

(defun gdev-lsp-navigation--locations (response)
  "Raggruppa le posizioni distinte di RESPONSE per file, senza aprirli."
  (let ((by-uri (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        locations)
    (mapc
     (lambda (item)
       (let* ((uri (or (plist-get item :targetUri) (plist-get item :uri)))
              (range (or (plist-get item :targetSelectionRange) (plist-get item :range)))
              (position (plist-get range :start)))
         (when (and (stringp uri) (natnump (plist-get position :line))
                    (natnump (plist-get position :character)))
           (let* ((file (or (gethash uri by-uri)
                            (puthash uri (eglot-uri-to-path uri) by-uri)))
                  (entry (cons file position)))
             (unless (gethash entry seen)
               (puthash entry t seen)
               (push entry locations))))))
     (if (vectorp response) response (and response (list response))))
    (sort locations (lambda (a b)
                      (cond ((not (equal (car a) (car b))) (string-lessp (car a) (car b)))
                            ((/= (plist-get (cdr a) :line) (plist-get (cdr b) :line))
                             (< (plist-get (cdr a) :line) (plist-get (cdr b) :line)))
                            (t (< (plist-get (cdr a) :character)
                                  (plist-get (cdr b) :character))))))))

(defun gdev-lsp-navigation--visit (location encoding)
  "Apri LOCATION nell'editor con ENCODING e conserva il percorso di ritorno."
  (gdev-lsp-visit-location (car location) (cdr location) encoding))

(defun gdev-lsp-navigation--row (location)
  "Inserisci LOCATION come azione, con un'intestazione per ogni file."
  (let* ((file (car location))
         (encoding gdev-lsp-navigation--encoding)
         (line (1+ (plist-get (cdr location) :line)))
         (column (1+ (plist-get (cdr location) :character))))
    (unless (equal file gdev-lsp-navigation--last-file)
      (setq gdev-lsp-navigation--last-file file)
      (let ((name (if (and gdev-lsp-navigation--root
                           (string-prefix-p gdev-lsp-navigation--root file))
                      (substring file (length gdev-lsp-navigation--root)) file)))
        (insert "\n" (propertize name 'face 'gdev-ui-view-heading 'help-echo file) "\n")))
    (insert-text-button (format "Riga %d · colonna %d" line column)
                        'type 'gdev-ui-action 'help-echo (format "%s:%d:%d" file line column)
                        'action (lambda (_) (gdev-lsp-navigation--visit location encoding)))
    (insert "\n")))

(defun gdev-lsp-navigation--append ()
  "Mostra il prossimo gruppo di risultati già ricevuti."
  (let ((inhibit-read-only t)
        (start (point)))
    (goto-char (point-max))
    (cl-loop repeat gdev-lsp-navigation--batch-size
             while gdev-lsp-navigation--pending
             do (gdev-lsp-navigation--row (pop gdev-lsp-navigation--pending)))
    (when gdev-lsp-navigation--pending
      (insert "\n")
      (insert-text-button "Mostra altri risultati" 'type 'gdev-ui-action
                          'action (lambda (button)
                                    (let ((inhibit-read-only t))
                                      (goto-char (button-start button))
                                      (delete-region (1- (point)) (point-max))
                                      (gdev-lsp-navigation--append))))
      (insert "\n"))
    (goto-char start)))

(defun gdev-lsp-navigation--render (message)
  "Mostra MESSAGE oppure l'elenco delle posizioni ricevute."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize gdev-lsp-navigation--heading 'face 'gdev-ui-view-title) "\n\n")
    (insert (propertize (or message (format "Posizioni trovate · %d" gdev-lsp-navigation--total))
                        'face 'gdev-ui-secondary) "\n")
    (unless message (gdev-lsp-navigation--append))
    (goto-char (point-min))
    (when-let* ((button (next-button (point)))) (goto-char (button-start button)))))

(defun gdev-lsp-navigation-show (kind)
  "Mostra le posizioni di KIND nello spazio corrente, mentre il server risponde."
  (gdev-call-with-editor
   (lambda ()
     (pcase-let ((`(,_ ,title ,method ,capability . ,extra)
                  (assq kind gdev-lsp-navigation--kinds)))
       (gdev-lsp--check-capability capability)
       (let* ((origin (current-buffer))
              (tick (buffer-chars-modified-tick))
              (symbol (thing-at-point 'symbol t))
              (server (eglot-current-server))
              (encoding eglot-move-to-linepos-function)
              (root (and (eglot--project server) (project-root (eglot--project server))))
              (parameters (append (eglot--TextDocumentPositionParams) extra))
              (owner (gdev-workspace-state-ensure-id))
              (frame (selected-frame))
              (request (list kind))
              (pane (gdev-activity-buffer 'lsp-navigation "*Navigazione del codice*"
                                          #'gdev-lsp-navigation-mode)))
         (with-current-buffer pane
           (setq-local gdev-activity-kind nil
                       gdev-lsp-navigation--request request
                       gdev-lsp-navigation--heading (if symbol (concat title " · " symbol) title)
                       gdev-lsp-navigation--encoding encoding
                       gdev-lsp-navigation--root root
                       gdev-lsp-navigation--pending nil
                       gdev-lsp-navigation--last-file nil)
           (gdev-lsp-navigation--render "Ricerca in corso…"))
         (pop-to-buffer pane)
         (cl-labels
             ((complete (response failure)
                (when (and (buffer-live-p pane) (frame-live-p frame)
                           (gdev-workspace-state-find owner frame)
                           (eq request (buffer-local-value 'gdev-lsp-navigation--request pane)))
                  (let ((positions
                         (when (and (not failure) (buffer-live-p origin))
                           (with-current-buffer origin
                             (when (and (= tick (buffer-chars-modified-tick))
                                        (eq server (eglot-current-server)))
                               (cons t (gdev-lsp-navigation--locations response)))))))
                    (with-current-buffer pane
                      (setq gdev-lsp-navigation--pending (cdr positions)
                            gdev-lsp-navigation--total (length (cdr positions)))
                      (gdev-lsp-navigation--render
                       (cond (failure failure)
                             ((not positions) "Il documento è cambiato. Ripeti la ricerca.")
                             ((not (cdr positions)) "Nessuna posizione trovata."))))
                    (when (and (not (eq kind 'references)) (length= (cdr positions) 1)
                               (eq pane (window-buffer (selected-window))))
                      (condition-case err
                          (gdev-lsp-navigation--visit (cadr positions) encoding)
                        (error (message "%s" (error-message-string err)))))))))
           (with-current-buffer origin
             (eglot--signal-textDocument/didChange)
             (jsonrpc-async-request server method parameters
                                    :success-fn (lambda (response) (complete response nil))
                                    :error-fn (lambda (err)
                                                (complete nil (or (plist-get err :message)
                                                                  "Ricerca non riuscita.")))
                                    :timeout-fn (lambda () (complete nil "Il server non ha risposto."))
                                    :timeout 15))))))))

(provide 'gdev-lsp-navigation)
;;; gdev-lsp-navigation.el ends here
