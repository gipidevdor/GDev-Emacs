;;; config.el --- :tools lsp: server di linguaggio tramite Eglot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Eglot (incluso in Emacs) dialoga con i server di linguaggio e porta
;; nell'area di testo completamento, segnalazioni, definizioni e riferimenti
;; (M-. M-?), rinomina (C-c c r), azioni sul codice (C-c c a), suggerimenti
;; in linea (C-c t h) e gerarchie (C-c c h / H).
;;
;; Un modulo di linguaggio dichiara il suo server con
;; `gdev-set-eglot-server'.  Eglot parte da solo in un'area di testo quando il
;; file è locale e il server è installato.  Per i file remoti lo avvii tu
;; con C-c c s, così una connessione lenta non blocca mai l'apertura di un
;; file.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-commands)
(require 'gdev-modules)

(add-to-list 'load-path (gdev-module-directory :tools 'lsp))
(autoload 'gdev-lsp-navigation-show "gdev-lsp-navigation")
(autoload 'gdev-lsp-hierarchy-show "gdev-lsp-hierarchy")
(autoload 'gdev-lsp-refactor-rename "gdev-lsp-refactor" nil t)
(autoload 'gdev-lsp-refactor-extract "gdev-lsp-refactor" nil t)
(declare-function eglot--lsp-position-to-point "eglot" (position &optional marker))
(declare-function xref-push-marker-stack "xref" (&optional marker))
(defvar eglot-move-to-linepos-function)

(defun gdev-lsp-location-marker (file position encoding)
  "Raggiungi POSITION in FILE secondo la funzione di coordinate ENCODING."
  (with-current-buffer (find-file-noselect file)
    (let ((eglot-move-to-linepos-function encoding))
      (eglot--lsp-position-to-point position t))))

(defun gdev-lsp-visit-location (file position encoding)
  "Apri FILE a POSITION nell'editor con ENCODING e registra il ritorno."
  (require 'xref)
  (gdev-call-with-editor
   (lambda ()
     (let ((marker (gdev-lsp-location-marker file position encoding)))
       (xref-push-marker-stack)
       (switch-to-buffer (marker-buffer marker))
       (unless (<= (point-min) marker (point-max)) (widen))
       (goto-char marker)
       (set-marker marker nil)
       (run-hooks 'xref-after-jump-hook)))))

(defun gdev-lsp--show-hierarchy (command)
  "Esegui COMMAND se l'Eglot installato offre la gerarchia."
  (require 'eglot)
  (unless (commandp command)
    (user-error "Questa versione di Eglot non offre la gerarchia richiesta"))
  (call-interactively command))

(defun gdev-lsp-call-hierarchy ()
  "Mostra la gerarchia delle chiamate del simbolo corrente."
  (interactive)
  (if gdev-layout-mode (gdev-lsp-hierarchy-show 'call)
    (gdev-lsp--show-hierarchy 'eglot-show-call-hierarchy)))

(defun gdev-lsp-type-hierarchy ()
  "Mostra la gerarchia dei tipi del simbolo corrente."
  (interactive)
  (if gdev-layout-mode (gdev-lsp-hierarchy-show 'type)
    (gdev-lsp--show-hierarchy 'eglot-show-type-hierarchy)))

(defun gdev-lsp--hierarchy-client-capabilities (capabilities)
  "Completa le CAPABILITIES di Eglot con le gerarchie del Workbench."
  (let ((document (plist-get capabilities :textDocument)))
    (if (and gdev-layout-mode
             (listp document)
             (not (and (plist-member document :callHierarchy)
                       (plist-member document :typeHierarchy))))
        (let ((updated (copy-sequence document)))
          (dolist (capability '(:callHierarchy :typeHierarchy))
            (unless (plist-member updated capability)
              (setq updated (plist-put updated capability '(:dynamicRegistration :json-false)))))
          (plist-put (copy-sequence capabilities) :textDocument updated))
      capabilities)))

;; Eglot in Emacs 30 non annuncia queste capacità durante l'inizializzazione.
(with-eval-after-load 'eglot
  (advice-add 'eglot-client-capabilities :filter-return #'gdev-lsp--hierarchy-client-capabilities))

(defun gdev-lsp--connect-message (function format &rest arguments)
  "Annuncia la connessione e inoltra a FUNCTION gli altri messaggi.
FORMAT e ARGUMENTS sono quelli di `eglot--message'."
  (if (and (stringp format) (string-prefix-p "Connected! Server" format)
           (length> arguments 2))
      (message "Server di linguaggio %s pronto per %s" (nth 0 arguments) (nth 2 arguments))
    (apply function format arguments)))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure eglot-rename eglot-code-actions eglot-reconnect
             eglot-shutdown eglot-inlay-hints-mode eglot-find-implementation
             eglot-find-typeDefinition eglot-find-declaration
             eglot-code-action-organize-imports eglot-code-action-quickfix
             eglot-code-action-extract)
  :custom
  (eglot-autoshutdown t)                ; ferma il server col suo ultimo buffer
  ;; Il registro degli eventi costa tempo e memoria a ogni messaggio.  Alza
  ;; :size per un po' (M-x customize-variable) quando fai il debug di un
  ;; server.
  (eglot-events-buffer-config '(:size 0 :format full))
  (eglot-sync-connect nil)              ; mai bloccare mentre un server parte
  (eglot-connect-timeout 60)
  (eglot-extend-to-xref t)              ; anche i sorgenti delle librerie
  (eglot-report-progress t)
  ;; Formattare mentre scrivi sorprende: formatta su richiesta o al
  ;; salvataggio.  Tree-sitter colora già il codice: i token semantici del
  ;; server (Eglot 1.24) ripercorrono il file dall'inizio a ogni porzione
  ;; ridisegnata e rallentano la scrittura nei file lunghi.
  (eglot-ignored-server-capabilities '(:documentOnTypeFormattingProvider
                                       :semanticTokensProvider))
  ;; Il margine sinistro resta a diagnostica, punti di interruzione e riga in
  ;; esecuzione: le azioni disponibili compaiono nella riga di stato (Eglot 1.19).
  (eglot-code-action-indications '(eldoc-hint mode-line))
  :config
  (advice-add 'eglot--message :around #'gdev-lsp--connect-message))


(defgroup gdev-lsp nil
  "Server di linguaggio (Eglot)."
  :group 'gdev)

(defcustom gdev-lsp-auto-start t
  "Se non nil, avvia Eglot quando c'è il server di linguaggio del file locale."
  :type 'boolean)

(defun gdev-lsp--server-installed-p (contact)
  "Restituisce non nil se il programma del CONTACT di Eglot è nel PATH."
  (let ((program (cl-find-if #'stringp contact)))
    (and program (executable-find program))))

(defvar-local gdev-lsp--starting nil
  "Non nil mentre `gdev-lsp-maybe-start' prepara l'ambiente di questo buffer.")

(defun gdev-lsp-maybe-start ()
  "Avvia qui Eglot se per questa modalità c'è un server dichiarato e usabile."
  ;; Con il risultato di direnv già in cache l'ambiente si applica subito e il
  ;; suo gancio richiama questa funzione dentro la prima chiamata: senza il
  ;; controllo partirebbero due server per lo stesso buffer.
  (unless gdev-lsp--starting
    (when-let* ((gdev-lsp-auto-start)
                (file buffer-file-name)
                ((not (file-remote-p file)))
                (server (gdev-handler :eglot)))
      ;; Valgono anche i server fissati dal progetto: i suoi strumenti vanno
      ;; nel percorso di ricerca.
      (let ((gdev-lsp--starting t))
        (gdev-use-project-tools))
      (when (and (gdev-project-environment-ready-p)
                 (if-let* ((predicate (plist-get server :when)))
                     (funcall predicate)
                   (gdev-lsp--server-installed-p (plist-get server :contact))))
        (eglot-ensure)))))

(defun gdev-lsp-start ()
  "Avvia Eglot nel gruppo editor quando l'ambiente del documento è pronto."
  (interactive)
  (gdev-call-with-editor
   (lambda ()
     (gdev-use-project-tools)
     (gdev-require-project-environment)
     (call-interactively #'eglot))))

(add-hook 'prog-mode-hook #'gdev-lsp-maybe-start)
(add-hook 'yaml-ts-mode-hook #'gdev-lsp-maybe-start)
(add-hook 'gdev-project-environment-ready-hook #'gdev-lsp-maybe-start)

(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot" (&rest feats))

(defun gdev-lsp-capable-p (capability &optional buffer)
  "Restituisce non nil se il server di BUFFER supporta CAPABILITY."
  (with-current-buffer (or buffer (current-buffer))
    (and (featurep 'eglot) (eglot-managed-p) (eglot-server-capable capability))))

(defun gdev-lsp--editor-buffer ()
  "Documento su cui agiscono le azioni del server: quello dell'editor attivo."
  (or (and (fboundp 'gdev-editor-document) (gdev-editor-document)) (current-buffer)))

;; Menu e Comandi offrono un'azione del server solo se il documento attivo
;; ha un server che la supporta.
(pcase-dolist (`(,command . ,capability)
               '((gdev-lsp-code-actions . :codeActionProvider)
                 (gdev-lsp-extract . :codeActionProvider)
                 (gdev-lsp-quick-fix . :codeActionProvider)
                 (gdev-organize-imports . :codeActionProvider)
                 (gdev-lsp-rename . :renameProvider)
                 (gdev-lsp-find-implementation . :implementationProvider)
                 (gdev-lsp-find-type-definition . :typeDefinitionProvider)
                 (gdev-lsp-call-hierarchy . :callHierarchyProvider)
                 (gdev-lsp-type-hierarchy . :typeHierarchyProvider)))
  (put command 'gdev-menu-available
       (lambda () (gdev-lsp-capable-p capability (gdev-lsp--editor-buffer)))))
(dolist (command '(eglot-shutdown eglot-reconnect))
  (put command 'gdev-menu-available
       (lambda () (and (featurep 'eglot)
                       (with-current-buffer (gdev-lsp--editor-buffer) (eglot-managed-p))))))

(defun gdev-lsp--check-capability (capability)
  "Valida CAPABILITY prima di avviare l'azione nel documento corrente."
  (unless (and (featurep 'eglot) (eglot-managed-p))
    (user-error "Sul documento attivo manca una connessione al server di linguaggio"))
  (unless (eglot-server-capable capability)
    (user-error "Il server di linguaggio del documento non offre questa azione")))

(defun gdev-lsp--run (command capability)
  "Esegui COMMAND nell'editor dopo aver verificato CAPABILITY."
  (gdev-call-with-editor
   (lambda ()
     (gdev-lsp--check-capability capability)
     (let ((this-command command))
       (call-interactively command)))))

(defun gdev-lsp-rename ()
  "Prepara la rinomina del simbolo nel documento attivo."
  (interactive)
  (gdev-lsp--run (if gdev-layout-mode #'gdev-lsp-refactor-rename #'eglot-rename)
                 :renameProvider))

(defun gdev-lsp-extract ()
  "Prepara l'estrazione offerta dal server per la selezione attiva."
  (interactive)
  (gdev-lsp--run (if gdev-layout-mode #'gdev-lsp-refactor-extract #'eglot-code-action-extract)
                 :codeActionProvider))

(defun gdev-lsp-find-implementation ()
  "Vai alle implementazioni del simbolo corrente."
  (interactive)
  (if gdev-layout-mode (gdev-lsp-navigation-show 'implementation)
    (gdev-lsp--run #'eglot-find-implementation :implementationProvider)))

(defun gdev-lsp-find-type-definition ()
  "Vai alla definizione del tipo del simbolo corrente."
  (interactive)
  (if gdev-layout-mode (gdev-lsp-navigation-show 'type-definition)
    (gdev-lsp--run #'eglot-find-typeDefinition :typeDefinitionProvider)))

(defun gdev-lsp-code-actions ()
  "Mostra le azioni del server di linguaggio nel documento attivo."
  (interactive)
  (gdev-lsp--run #'eglot-code-actions :codeActionProvider))

(defun gdev-lsp-quick-fix ()
  "Cerca le correzioni rapide nel documento attivo."
  (interactive)
  (gdev-lsp--run #'eglot-code-action-quickfix :codeActionProvider))

(defun gdev-organize-imports ()
  "Riordina le importazioni con lo strumento del linguaggio corrente."
  (interactive)
  (gdev-call-with-editor
   (lambda ()
     (let ((this-command (or (gdev-handler :organize-imports)
                             (progn
                               (gdev-lsp--check-capability :codeActionProvider)
                               #'eglot-code-action-organize-imports))))
       (call-interactively this-command)))))

;;; config.el ends here
