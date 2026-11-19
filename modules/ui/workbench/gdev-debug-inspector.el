;;; gdev-debug-inspector.el --- Ispezione del programma in pausa -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Dape possiede sessioni, thread, livelli e variabili. La vista conserva
;; soltanto le sezioni aperte e gli esiti delle espressioni che presenta.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'subr-x)
(require 'text-property-search)

(declare-function dape--current-stack-frame "dape" (conn))
(declare-function dape--current-thread "dape" (conn))
(declare-function dape--evaluate-expression "dape" (conn frame-id expression context cb))
(declare-function dape--file-name-local "dape" (conn filename))
(declare-function dape--info-scope-label "dape" (scope))
(declare-function dape--stack-trace "dape" (conn thread nof cb))
(declare-function dape--threads "dape" (conn))
(declare-function dape--variables "dape" (conn object cb))
(declare-function dape-select-session "dape" (conn &optional exact))
(declare-function dape-select-stack "dape" (conn stack-id))
(declare-function dape-select-thread "dape" (conn thread-id))
(declare-function dape-watch-dwim "dape" (expression &optional remove-only-p add-only-p display-p))
(declare-function gdev-close-document "gdev-commands" ())
(declare-function gdev-debug--workspace-open-p "modules/tools/debugger/config" (owner))
(declare-function gdev-debug-workspace-connection "modules/tools/debugger/config" (owner &optional connections))
(declare-function gdev-debug-workspace-connections "modules/tools/debugger/config" (owner))
(declare-function gdev-project-view-run "gdev-project-view" ())

(defvar dape--watched)
(defvar dape-stack-trace-levels)
(defvar gdev-context-items)
(defvar-local gdev-debug-inspector--owner nil)
(defvar-local gdev-debug-inspector--page 'stack)
(defvar-local gdev-debug-inspector--context nil)
(defvar-local gdev-debug-inspector--expanded nil)
(defvar-local gdev-debug-inspector--requests nil)
(defvar-local gdev-debug-inspector--watch-names nil)
(defvar-local gdev-debug-inspector--watch-results nil)

(defvar-keymap gdev-debug-inspector-mode-map
  "q" #'gdev-close-document
  "g" #'gdev-debug-inspector-refresh
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "c" #'gdev-debug-inspector-copy)

(define-derived-mode gdev-debug-inspector-mode special-mode "Ispezione"
  "Consulta pila, variabili ed espressioni della sessione dello spazio."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local truncate-lines nil
              gdev-context-items
              '(["Copia valore o percorso" gdev-debug-inspector-copy
                 (get-text-property (point) 'gdev-debug-inspector-value) (:target view)]
                ["Aggiungi espressione…" gdev-debug-inspector--add-watch t (:target view)]
                ["Aggiorna" gdev-debug-inspector-refresh t (:target view)]))
  (add-hook 'window-buffer-change-functions #'gdev-debug-inspector--refresh-window nil t))

(defun gdev-debug-inspector--read-context ()
  "Rileggi connessione, thread, livello e ambiti della vista dal debug."
  (when-let* ((gdev-debug-inspector--owner)
              ((fboundp 'gdev-debug-workspace-connection))
              (conn (gdev-debug-workspace-connection gdev-debug-inspector--owner)))
    (let* ((thread (dape--current-thread conn))
           (frame (and (eq (plist-get thread :status) 'stopped)
                       (dape--current-stack-frame conn))))
      (list conn thread frame (plist-get frame :scopes)))))

(defun gdev-debug-inspector--same-context-p (left right)
  "Verifica che LEFT e RIGHT indichino gli stessi dati del debug."
  (and (eq (null left) (null right)) (cl-every #'eq left right)))

(defun gdev-debug-inspector--request (start finish)
  "Esegui START con una funzione di risposta che richiama FINISH.
Scarta risposte destinate a un livello o a un buffer che è cambiato."
  (let ((buffer (current-buffer))
        (context gdev-debug-inspector--context))
    (funcall start
             (lambda (body error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (eq context gdev-debug-inspector--context)
                              (gdev-debug--workspace-open-p gdev-debug-inspector--owner)
                              (gdev-debug-inspector--same-context-p
                               context (gdev-debug-inspector--read-context)))
                     (funcall finish body error))))))))

(defun gdev-debug-inspector--live-context ()
  "Restituisci il contesto mostrato se corrisponde ancora al debugger."
  (let ((context (gdev-debug-inspector--read-context)))
    (unless (gdev-debug-inspector--same-context-p context gdev-debug-inspector--context)
      (gdev-debug-inspector-refresh)
      (user-error "La sessione è cambiata. Scegli un elemento aggiornato"))
    context))

(defun gdev-debug-inspector--button (label id action &optional help face)
  "Inserisci LABEL con identità ID, ACTION, guida HELP e aspetto FACE."
  (insert-text-button label 'type 'gdev-ui-action 'gdev-debug-inspector-id id
                      'face (or face 'gdev-ui-action)
                      'help-echo (or help label)
                      'action (lambda (_) (funcall action))))

(defun gdev-debug-inspector--hint (label)
  "Mostra LABEL come testo secondario."
  (insert (propertize label 'face 'gdev-ui-secondary) "\n"))

(defun gdev-debug-inspector--heading (label)
  "Mostra LABEL come titolo di sezione."
  (insert (propertize label 'face 'gdev-ui-view-heading) "\n"))

(defun gdev-debug-inspector--draw-visible ()
  "Ridisegna soltanto se il riquadro è ancora visibile."
  (when-let* ((window (get-buffer-window (current-buffer) 'visible))
              ((eq gdev-debug-inspector--owner (gdev-workspace-state-id (window-frame window)))))
    (with-selected-window window (gdev-debug-inspector--draw))))

(defun gdev-debug-inspector--choose-thread (thread)
  "Seleziona il THREAD mostrato nella sessione corrente."
  (let ((conn (car (gdev-debug-inspector--live-context))))
    (unless (and conn (memq thread (dape--threads conn))
                 (eq (plist-get thread :status) 'stopped))
      (user-error "Il thread non è più in pausa"))
    (dape-select-thread conn (plist-get thread :id))))

(defun gdev-debug-inspector--choose-frame (frame)
  "Seleziona FRAME nel debug e aprine il sorgente nell'editor."
  (let* ((context (gdev-debug-inspector--live-context))
         (thread (nth 1 context)))
    (unless (and (nth 2 context) (memq frame (plist-get thread :stackFrames)))
      (user-error "Il livello non è più disponibile"))
    (dape-select-stack (car context) (plist-get frame :id))))

(defun gdev-debug-inspector--load-stack ()
  "Richiedi altri livelli della pila del debug una volta per clic."
  (let* ((context (gdev-debug-inspector--live-context))
         (thread (nth 1 context))
         (count (length (plist-get thread :stackFrames)))
         (levels (+ count dape-stack-trace-levels)))
    (when (and (nth 2 context) (not (eq (alist-get 'stack gdev-debug-inspector--requests) 'pending)))
      (setf (alist-get 'stack gdev-debug-inspector--requests) 'pending)
      (gdev-debug-inspector--request
       (lambda (callback)
         (dape--stack-trace (car context) thread levels callback))
       (lambda (_ error)
         (let ((loaded (length (plist-get thread :stackFrames)))
               (total (plist-get thread :totalFrames)))
           (setf (alist-get 'stack gdev-debug-inspector--requests)
                 (or error (if (and (> loaded count)
                                    (if (numberp total) (< loaded total) (>= loaded levels)))
                               'more 'done))))
         (gdev-debug-inspector--draw-visible)))
      (gdev-debug-inspector--draw))))

(defun gdev-debug-inspector--threads (conn current)
  "Mostra i thread della connessione CONN ed evidenzia CURRENT."
  (gdev-debug-inspector--heading "Thread")
  (if-let* ((threads (dape--threads conn)))
      (dolist (thread threads)
        (let ((name (or (plist-get thread :name) "Thread senza nome"))
              (id (plist-get thread :id)))
          (if (eq (plist-get thread :status) 'stopped)
              (progn
                (gdev-debug-inspector--button
                 name (list 'thread id) (lambda () (gdev-debug-inspector--choose-thread thread))
                 (format "Seleziona il thread %s in pausa" name)
                 (and (eq thread current) 'gdev-ui-action-primary))
                (gdev-debug-inspector--hint (if (eq thread current) "  ·  In pausa, attivo" "  ·  In pausa")))
            (gdev-debug-inspector--hint
             (format "%s  ·  %s" name
                     (pcase (plist-get thread :status)
                       ((or 'running 'started) "In esecuzione")
                       ('exited "Terminato")
                       (_ "In attesa")))))))
    (gdev-debug-inspector--hint "Nessun thread disponibile.")))

(defun gdev-debug-inspector--stack (conn thread current)
  "Mostra la pila di THREAD per CONN con CURRENT selezionato."
  (gdev-debug-inspector--heading "Pila delle chiamate")
  (if (not current)
      (gdev-debug-inspector--hint "Metti in pausa il programma per consultare la pila.")
    (dolist (frame (plist-get thread :stackFrames))
      (let* ((source (plist-get frame :source))
             (path (if-let* ((file (plist-get source :path)))
                       (dape--file-name-local conn file)
                     (plist-get source :name)))
             (line (plist-get frame :line))
             (location (and path (if (and line (> line 0)) (format "%s:%d" path line) path)))
             (name (or (plist-get frame :name) "Livello senza nome"))
             (start (point)))
        (gdev-debug-inspector--button
         name (list 'frame (plist-get frame :id)) (lambda () (gdev-debug-inspector--choose-frame frame))
         location (and (eq frame current) 'gdev-ui-action-primary))
        (insert "\n")
        (when location
          (gdev-debug-inspector--hint
           (propertize (concat "   " (file-name-nondirectory location)
                               (when (eq frame current) "  ·  Attivo"))
                       'help-echo location))
          (put-text-property start (1- (point)) 'gdev-debug-inspector-value location))))
    (let ((total (plist-get thread :totalFrames))
          (status (alist-get 'stack gdev-debug-inspector--requests)))
      (cond
       ((eq status 'pending) (gdev-debug-inspector--hint "Caricamento della pila…"))
       ((or (stringp status) (eq status 'more)
            (and (null status) (or (not (numberp total)) (< (length (plist-get thread :stackFrames)) total))))
        (when (stringp status)
          (gdev-debug-inspector--hint (format "Pila non disponibile. %s" status)))
        (gdev-debug-inspector--button "Carica altri livelli" 'stack-more #'gdev-debug-inspector--load-stack)
        (insert "\n"))))))

(defun gdev-debug-inspector--toggle (object)
  "Apri o chiudi OBJECT. Carica i contenuti alla prima apertura."
  (let ((conn (car (gdev-debug-inspector--live-context))))
    (if (memq object gdev-debug-inspector--expanded)
        (setq gdev-debug-inspector--expanded (delq object gdev-debug-inspector--expanded))
      (push object gdev-debug-inspector--expanded)
      (unless (assq object gdev-debug-inspector--requests)
        (setf (alist-get object gdev-debug-inspector--requests nil nil #'eq) 'pending)
        (gdev-debug-inspector--request
         (lambda (callback) (dape--variables conn object callback))
         (lambda (_ error)
           (setf (alist-get object gdev-debug-inspector--requests nil nil #'eq) (or error 'done))
           (gdev-debug-inspector--draw-visible)))))
    (gdev-debug-inspector--draw)))

(defun gdev-debug-inspector-copy ()
  "Copia il valore o il percorso completo dell'elemento al cursore."
  (interactive)
  (if-let* ((value (get-text-property (point) 'gdev-debug-inspector-value)))
      (progn (kill-new value) (message "Valore copiato"))
    (user-error "Nessun valore o percorso al cursore")))

(defun gdev-debug-inspector--object (object id depth &optional label)
  "Mostra OBJECT con identità ID, rientrato a DEPTH ed etichettato LABEL."
  (let* ((reference (plist-get object :variablesReference))
         (expandable (and (integerp reference) (> reference 0)))
         (open (memq object gdev-debug-inspector--expanded))
         (value (or (plist-get object :value) (plist-get object :result)))
         (name (or label (plist-get object :name) "Valore"))
         (indent (make-string (* 2 (min depth 8)) ?\s))
         (line (point)))
    (insert indent)
    (let ((start (point)))
      (if expandable
          (gdev-debug-inspector--button
           (concat (if open "▾ " "▸ ") name) id (lambda () (gdev-debug-inspector--toggle object))
           (format "%s %s" (if open "Chiudi" "Espandi") name))
        (insert name))
      (when (stringp value)
        (let ((preview (replace-regexp-in-string "[\n\r]+" " " (string-limit value 144))))
          (insert "  "
                  (propertize (if (> (length value) 144) (concat preview "…") preview)
                              'face 'gdev-ui-secondary 'help-echo value)))
        (put-text-property start (point) 'gdev-debug-inspector-value value))
      (insert "\n"))
    ;; Un valore lungo continua sotto il nome, dentro il rientro del nodo.
    (put-text-property line (point) 'wrap-prefix (concat indent "    "))
    (when open
      (let ((status (alist-get object gdev-debug-inspector--requests nil nil #'eq)))
        (cond
         ((eq status 'pending) (gdev-debug-inspector--hint "   Caricamento…"))
         ((stringp status)
          (gdev-debug-inspector--hint (format "   Variabili non disponibili. %s" status))
          (gdev-debug-inspector--button
           "Riprova" (cons 'retry id)
           (lambda ()
             (setq gdev-debug-inspector--expanded (delq object gdev-debug-inspector--expanded)
                   gdev-debug-inspector--requests (assq-delete-all object gdev-debug-inspector--requests))
             (gdev-debug-inspector--toggle object)))
          (insert "\n"))
         ((plist-get object :variables)
          (cl-loop for child in (plist-get object :variables)
                   for index from 0
                   do (gdev-debug-inspector--object child (cons index id) (1+ depth))))
         (t (gdev-debug-inspector--hint "   Nessuna variabile.")))))))

(defun gdev-debug-inspector--locals (frame scopes)
  "Mostra gli ambiti SCOPES di FRAME."
  (gdev-debug-inspector--heading "Variabili e ambiti")
  (cond
   ((not frame)
    (gdev-debug-inspector--hint "Metti in pausa il programma per consultare le variabili."))
   ((not scopes)
    (gdev-debug-inspector--hint "Il livello non espone ambiti di variabili."))
   (t
    (cl-loop for scope in scopes for index from 0
             do (gdev-debug-inspector--object scope (list 'scope index) 0
                                              (dape--info-scope-label scope))))))

(defun gdev-debug-inspector--add-watch ()
  "Aggiungi un'espressione al registro del debug."
  (interactive)
  (let ((expression (string-trim (read-string "Espressione da osservare: "))))
    (unless (string-empty-p expression)
      (require 'dape)
      (setq gdev-debug-inspector--page 'watches)
      (dape-watch-dwim expression nil t)
      (gdev-debug-inspector-refresh))))

(defun gdev-debug-inspector--evaluate-watches (conn frame names)
  "Valuta NAMES con CONN e FRAME, ridisegnando dopo l'ultima risposta."
  (setq gdev-debug-inspector--watch-names names
        gdev-debug-inspector--watch-results nil)
  (when (and frame names)
    (let ((remaining (length names))
          results)
      (dolist (name names)
        (gdev-debug-inspector--request
         (lambda (callback)
           (dape--evaluate-expression conn (plist-get frame :id) name "watch" callback))
         (lambda (body error)
           (when (eq names gdev-debug-inspector--watch-names)
             (push (cons name (or error (plist-put body :name name))) results)
             (when (zerop (cl-decf remaining))
               (setq gdev-debug-inspector--watch-results results)
               (gdev-debug-inspector--draw-visible)))))))))

(defun gdev-debug-inspector--watches (frame)
  "Mostra le espressioni del debug ed eventuali risultati per FRAME."
  (gdev-debug-inspector--heading "Espressioni osservate")
  (gdev-debug-inspector--button "Aggiungi espressione…" 'add-watch #'gdev-debug-inspector--add-watch)
  (insert "\n\n")
  (if gdev-debug-inspector--watch-names
      (dolist (name gdev-debug-inspector--watch-names)
        (let ((result (alist-get name gdev-debug-inspector--watch-results nil nil #'equal)))
          (if (consp result)
              (gdev-debug-inspector--object result (list 'watch name) 0)
            (insert name "\n")
            (gdev-debug-inspector--hint
             (cond ((stringp result) (format "Valutazione non riuscita. %s" result))
                   (frame "Valutazione in corso…")
                   (t "Disponibile quando il programma è in pausa."))))
          (gdev-debug-inspector--button
           "Rimuovi" (list 'remove-watch name)
           (lambda ()
             (dape-watch-dwim name t)
             (gdev-debug-inspector-refresh))
           (format "Smetti di osservare %s" name))
          (insert "\n\n")))
    (gdev-debug-inspector--hint "Nessuna espressione osservata.")))

(defun gdev-debug-inspector--draw ()
  "Ridisegna il riquadro conservando l'identità del pulsante al cursore."
  (let ((inhibit-read-only t)
        (id (get-text-property (point) 'gdev-debug-inspector-id))
        (old-point (point))
        (conn (nth 0 gdev-debug-inspector--context))
        (thread (nth 1 gdev-debug-inspector--context))
        (frame (nth 2 gdev-debug-inspector--context))
        (scopes (nth 3 gdev-debug-inspector--context)))
    (erase-buffer)
    (insert (propertize "Ispezione del debug" 'face 'gdev-ui-view-title) "\n\n")
    (dolist (entry '((stack . "Pila e thread") (locals . "Variabili") (watches . "Osservate")))
      (let ((page (car entry)))
        (gdev-debug-inspector--button
         (cdr entry) page
         (lambda ()
           (setq gdev-debug-inspector--page page)
           (gdev-debug-inspector-refresh))
         nil (and (eq page gdev-debug-inspector--page) 'gdev-ui-action-primary))
        (insert "  ")))
    (insert "\n\n")
    (pcase gdev-debug-inspector--page
      ('watches (gdev-debug-inspector--watches frame))
      (_
       (if (not conn)
           (progn
             (gdev-debug-inspector--hint "Nessuna sessione di debug in questo spazio.")
             (gdev-debug-inspector--button "Apri Debug" 'debug #'gdev-project-view-run)
             (insert "\n"))
         (if (eq gdev-debug-inspector--page 'locals)
             (gdev-debug-inspector--locals frame scopes)
           (gdev-debug-inspector--threads conn thread)
           (insert "\n")
           (gdev-debug-inspector--stack conn thread frame)))))
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (if-let* ((id)
              (match (text-property-search-forward 'gdev-debug-inspector-id id t)))
        (goto-char (prop-match-beginning match))
      (goto-char (min old-point (point-max))))))

(defun gdev-debug-inspector-refresh (&optional reevaluate)
  "Aggiorna la vista dal debug. Con REEVALUATE rivaluta le espressioni."
  (interactive (list t))
  (let ((context (gdev-debug-inspector--read-context)))
    (unless (gdev-debug-inspector--same-context-p context gdev-debug-inspector--context)
      (setq gdev-debug-inspector--context context
            gdev-debug-inspector--expanded nil
            gdev-debug-inspector--requests nil
            gdev-debug-inspector--watch-names nil
            gdev-debug-inspector--watch-results nil))
    (when (eq gdev-debug-inspector--page 'watches)
      (let ((names (mapcar (lambda (watch) (plist-get watch :name))
                           (bound-and-true-p dape--watched))))
        (when (or reevaluate (not (equal names gdev-debug-inspector--watch-names)))
          (gdev-debug-inspector--evaluate-watches (car context) (nth 2 context) names))))
    (gdev-debug-inspector--draw)))

(defun gdev-debug-inspector--refresh-window (window)
  "Aggiorna WINDOW quando mostra l'ispettore dello spazio a cui appartiene."
  (with-current-buffer (window-buffer window)
    (when (and (derived-mode-p 'gdev-debug-inspector-mode)
               (eq gdev-debug-inspector--owner (gdev-workspace-state-id (window-frame window))))
      (with-selected-window window (gdev-debug-inspector-refresh)))))

(defun gdev-debug-inspector--refresh-visible ()
  "Aggiorna i soli ispettori visibili dopo un evento del debugger."
  (walk-windows #'gdev-debug-inspector--refresh-window 'no-minibuffer 'visible))

(with-eval-after-load 'dape
  (add-hook 'dape-update-ui-hook #'gdev-debug-inspector--refresh-visible))

;;;###autoload
(defun gdev-debug-inspector-show (&optional connection)
  "Apri il riquadro di ispezione nello spazio corrente.
CONNECTION, se indicata, diventa la sessione attiva dello spazio."
  (interactive)
  (let* ((owner (gdev-workspace-state-ensure-id))
         (buffer (gdev-activity-buffer 'debug-inspector "*Ispezione del debug*"
                                       #'gdev-debug-inspector-mode)))
    (when (and connection
               (memq connection (gdev-debug-workspace-connections owner))
               (not (eq connection (gdev-debug-workspace-connection owner))))
      (dape-select-session connection t))
    (with-current-buffer buffer
      (setq-local gdev-activity-kind nil
                  gdev-debug-inspector--owner owner)
      (gdev-debug-inspector-refresh))
    (pop-to-buffer buffer)))

(provide 'gdev-debug-inspector)
;;; gdev-debug-inspector.el ends here
