;;; gdev-workspaces.el --- Salvataggio degli spazi di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Tab Bar conserva i riquadri in memoria.  Su disco salviamo soltanto gli
;; editor, associando i documenti ai percorsi e ricreando Esplora file su richiesta.

;;; Code:

(require 'cl-lib)
(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-workspace-state)
(require 'gdev-drafts)
(require 'gdev-workspace-roots)

(defvar tabspaces-project-tab-map)
(defvar tabspaces-session-file)
(defvar gdev-session--restarting)
(declare-function gdev-sidebar-show "../modules/ui/sidebar/config")
(declare-function gdev-editor-preview-buffer-p "../modules/ui/workbench/gdev-editor-tabs")
(declare-function gdev-session--mark-restore "gdev-commands")
(declare-function files--buffers-needing-to-be-saved "files")

(defvar gdev-workspaces--session-active nil
  "Non nil dopo aver salvato o ripreso la sessione.")

(defconst gdev-workspaces--geometry
  '(last total-width total-height normal-width normal-height combination-limit)
  "Campi che descrivono le proporzioni di un riquadro nello stato nativo.")

(defconst gdev-workspaces--stored-fields
  '((:activity . gdev-activity-view)
    (:explorer-hidden . gdev-layout-explorer-hidden)
    (:commands-visibility . gdev-layout-commands-visibility)
    (:commands-width . gdev-layout-commands-width)
    (:commands-category . gdev-command-sidebar-category)
    (:launch-selections . gdev-launch-selections)
    (:minimap . gdev-layout-minimap-visible)
    (:panel . gdev-layout-panel-session))
  "Corrispondenza fra proprietà della sessione v1 e campi dello spazio vivo.
Si salva e si ripristina solo un campo che `gdev-workspace-state-fields'
dichiara `clone' o `persist'.  Radici, larghezza di Esplora file e
disposizione hanno una forma propria: vedi `gdev-workspaces--context-fields'.")

(defconst gdev-workspaces--context-fields
  '(gdev-workspace-roots gdev-layout-folder gdev-layout-explorer-root
    gdev-layout-explorer-width gdev-workspaces-layout)
  "Campi salvati nella sessione con una forma che dipende dal contesto.")

(defun gdev-workspaces--local-path (value)
  "Restituisce VALUE se è un percorso assoluto locale."
  (and (stringp value) (file-name-absolute-p value) (not (file-remote-p value)) value))

(defun gdev-workspaces--buffer-file (buffer)
  "Restituisce il percorso locale del file visitato da BUFFER."
  (when (buffer-live-p buffer)
    (gdev-workspaces--local-path (buffer-file-name buffer))))

(defun gdev-workspaces--panel-session (value)
  "Convalida VALUE, il pannello salvato di uno spazio.
Conserva gli strumenti nella forma (TIPO . PROPRIETÀ); il modulo che ha
registrato TIPO convalida le proprietà quando ricrea lo strumento."
  (when (plistp value)
    (when-let* ((tools (seq-filter (lambda (tool)
                                     (and (consp tool) (symbolp (car tool)) (car tool)
                                          (plistp (cdr tool))))
                                   (plist-get value :tools))))
      (let ((active (plist-get value :active))
            (height (plist-get value :height)))
        (list :tools tools
              :active (and (natnump active) (< active (length tools)) active)
              :height (and (natnump height) (> height 0) height)
              :visible (and (plist-get value :visible) t))))))

(defun gdev-workspaces--launch-selections (entries)
  "Restituisci le scelte di profilo locali presenti in ENTRIES."
  (cl-loop for entry in entries
           when (and (consp entry) (gdev-workspaces--local-path (car entry))
                     (stringp (cdr entry)))
           collect (cons (file-name-as-directory (car entry)) (cdr entry))))

(defun gdev-workspaces--position (value)
  "Converte il marcatore o la posizione VALUE in un numero salvabile."
  (or (if (markerp value) (marker-position value) value) 1))

(defun gdev-workspaces--map-tree (node resolve &optional home)
  "Trasforma NODE usando RESOLVE per i documenti e HOME per i gruppi vuoti."
  (let* ((entries (cdr node))
         (parameters (alist-get 'parameters entries))
         (geometry (seq-filter (lambda (entry) (memq (car entry) gdev-workspaces--geometry))
                               entries)))
    (pcase (car node)
      ('leaf
       (unless (alist-get 'window-side parameters)
         (let* ((view (alist-get 'buffer entries))
                (file (funcall resolve (car view)))
                (previous (cl-loop for (buffer start point) in (alist-get 'prev-buffers entries)
                                   for ref = (funcall resolve buffer)
                                   when ref collect (list ref (gdev-workspaces--position start)
                                                          (gdev-workspaces--position point)))))
           `(leaf ,@geometry
                  (buffer ,(or file (caar previous) home "*scratch*")
                          (selected . ,(alist-get 'selected (cdr view)))
                          (point . ,(if file (gdev-workspaces--position (alist-get 'point (cdr view)))
                                      (or (caddar previous) 1)))
                          (start . ,(if file (gdev-workspaces--position (alist-get 'start (cdr view)))
                                      (or (cadar previous) 1)))
                          (hscroll . ,(if file (or (alist-get 'hscroll (cdr view)) 0) 0))
                          (fringes nil nil)
                          (vscroll . 0))
                  (prev-buffers . ,previous)
                  (next-buffers . ,(delq nil (mapcar resolve (alist-get 'next-buffers entries))))
                  (parameters
                   (gdev-layout-editor-id . ,(alist-get 'gdev-layout-editor-id parameters))
                   (gdev-layout-document-source . ,(alist-get 'gdev-layout-document-source parameters))
                   (tab-line-buffers . ,(delq nil (mapcar resolve (alist-get 'tab-line-buffers parameters)))))))))
      ((or 'hc 'vc)
       (let ((children (cl-loop for entry in entries
                                for child = (when (memq (car entry) '(leaf hc vc))
                                              (gdev-workspaces--map-tree entry resolve home))
                                when child collect child)))
         (when children
           (let ((last-child (car (last children))))
             (dolist (child children)
               (setf (alist-get 'last (cdr child) nil 'remove) (eq child last-child))))
           (if (cdr children) (append (list (car node)) geometry children) (car children))))))))

(defun gdev-workspaces--replace-focused (node editor)
  "Aggiorna il riquadro selezionato di NODE con il documento di EDITOR."
  (cond
   ((and (eq (car node) 'leaf) (alist-get 'selected (cddr (assq 'buffer (cdr node)))))
    (cons 'leaf
          (append (seq-filter (lambda (entry) (memq (car entry) gdev-workspaces--geometry)) (cdr node))
                  (seq-filter (lambda (entry)
                                (memq (car entry) '(buffer prev-buffers next-buffers parameters)))
                              (cdr editor)))))
   ((memq (car node) '(hc vc))
    (cons (car node) (mapcar (lambda (entry) (gdev-workspaces--replace-focused entry editor)) (cdr node))))
   (t node)))

(defun gdev-workspaces--capture ()
  "Legge la disposizione degli editor e la larghezza di Esplora file."
  (with-selected-window (gdev-layout-editor)
    (let* ((focus (frame-parameter nil 'gdev-layout-focus))
           (normal-state (plist-get focus :editor-state))
           (sidebar (or (window-with-parameter 'gdev-sidebar t)
                        (window-with-parameter 'gdev-activity t)))
           (width (if sidebar (gdev-layout-explorer-preferred-width sidebar)
                    (plist-get focus :explorer-width))))
      (list :windows (if normal-state
                         (cons (car normal-state)
                               (gdev-workspaces--replace-focused
                                (cdr normal-state) (cdr (window-state-get (selected-window)))))
                       (window-state-get (window-main-window)))
            :explorer-visible (and width t)
            :explorer-width (or width (gdev-workspace-state-get 'gdev-layout-explorer-width))))))

(defun gdev-workspaces--remember-layout (make-tab &optional frame)
  "Aggiunge a MAKE-TAB lo stato degli editor prima di lasciare FRAME."
  (let ((tab (funcall make-tab frame)))
    (with-selected-frame (or frame (selected-frame))
      (gdev-workspace-state-set 'gdev-workspaces-layout (gdev-workspaces--capture) tab))
    tab))

(defun gdev-workspaces--index-drafts (drafts test)
  "Indicizza DRAFTS con TEST, conservando la prima voce per ogni chiave."
  (when drafts
    (let ((index (make-hash-table :test test :size (length drafts))))
      (dolist (entry drafts index)
        (unless (gethash (car entry) index)
          (puthash (car entry) (cdr entry) index))))))

(defun gdev-workspaces--record (tab &optional draft-index)
  "Crea il record salvabile per TAB, usando l'indice DRAFT-INDEX per le bozze."
  (let* ((active (eq (car tab) 'current-tab))
         (name (alist-get 'name (cdr tab)))
         (layout (if active (gdev-workspaces--capture)
                   (gdev-workspace-state-read 'gdev-workspaces-layout tab)))
         (buffers (if active
                      (append (frame-parameter nil 'buffer-list) (frame-parameter nil 'buried-buffer-list))
                    (append (alist-get 'wc-bl tab) (alist-get 'wc-bbl tab))))
         (reference (lambda (buffer)
                      (unless (and (fboundp 'gdev-editor-preview-buffer-p)
                                   (gdev-editor-preview-buffer-p buffer))
                        (or (and draft-index (gethash buffer draft-index))
                            (gdev-workspaces--buffer-file buffer)))))
         (files (delq nil (mapcar reference buffers)))
         (state (plist-get layout :windows))
         (tree (gdev-workspaces--map-tree
                (cdr state)
                (lambda (buffer)
                  (when-let* ((path (funcall reference buffer)))
                    (cl-pushnew path files :test #'equal)
                    path)))))
    (append
     (list :name name
           :project (gdev-workspaces--local-path
                     (car (rassoc name (bound-and-true-p tabspaces-project-tab-map))))
           :root (gdev-workspaces--local-path (gdev-workspace-state-read 'gdev-layout-explorer-root tab))
           :folder (gdev-workspaces--local-path (gdev-workspace-state-read 'gdev-layout-folder tab))
           :folders (delq nil (mapcar #'gdev-workspaces--local-path
                                      (gdev-workspace-state-read 'gdev-workspace-roots tab)))
           :explorer-visible (plist-get layout :explorer-visible)
           :explorer-width (plist-get layout :explorer-width))
     (cl-loop for (property . field) in gdev-workspaces--stored-fields
              for value = (gdev-workspace-state-read field tab)
              when (gdev-workspace-state-saved-p field)
              append (list property
                           (pcase property
                             (:launch-selections (gdev-workspaces--launch-selections value))
                             ;; Gli strumenti vivi prevalgono sul pannello non ancora ripreso.
                             (:panel (gdev-workspaces--panel-session
                                      (gdev-layout-panel-snapshot tab value)))
                             (_ value))))
     (list :files (delete-dups files)
           :windows (when tree (cons (car state) tree))))))

(defun gdev-workspaces--referenced-files (records)
  "Indicizza i riferimenti ai documenti raccolti in RECORDS."
  (let ((references (make-hash-table :test #'equal)))
    (dolist (record records references)
      (dolist (file (plist-get record :files))
        (puthash file t references)))))

(defun gdev-workspaces--session (tabs &optional drafts snapshot-entry)
  "Raccoglie lo stato di TABS e i documenti indicati in DRAFTS.
SNAPSHOT-ENTRY, se fornita, costruisce la voce di una bozza dai suoi buffer
e chiave."
  (let* ((active (seq-position tabs 'current-tab (lambda (tab tag) (eq (car tab) tag))))
         (draft-index (gdev-workspaces--index-drafts drafts #'eq))
         (records (mapcar (lambda (tab) (gdev-workspaces--record tab draft-index)) tabs))
         (references (gdev-workspaces--referenced-files records)))
    (list :version 1 :active (or active 0) :tabs records
          :drafts (cl-loop for (buffer . key) in drafts
                           when (gethash key references)
                           collect (if snapshot-entry
                                       (funcall snapshot-entry buffer key)
                                     (cons key (gdev-drafts--snapshot buffer)))))))

(defun gdev-workspaces--drafts ()
  "Raccoglie i riferimenti univoci alle bozze dei buffer aperti."
  (cl-loop for buffer in (buffer-list)
           for key = (gdev-drafts--key buffer)
           when key collect (cons buffer key)))

(defvar gdev-workspaces--checkpoint-signature nil
  "Identità e revisione delle bozze incluse nell'ultimo salvataggio periodico.")

(defvar gdev-workspaces--checkpoint-file nil
  "File dell'ultimo salvataggio periodico completato.")

(defvar gdev-workspaces--checkpoint-cache nil
  "Rappresentazioni Lisp delle bozze riutilizzabili al prossimo salvataggio.")

(defconst gdev-workspaces--checkpoint-cache-limit (* 8 1024 1024)
  "Limite in byte della memoria occupata dalle bozze serializzate.")

(defun gdev-workspaces--draft-revision (buffer key)
  "Identifica testo e metadati da conservare per KEY nel BUFFER."
  (with-current-buffer buffer
    (list key (buffer-chars-modified-tick) (buffer-name) major-mode default-directory
          buffer-file-name (visited-file-modtime) enable-multibyte-characters)))

(defun gdev-workspaces--interrupted-file (file)
  "File in cui si conserva la sessione di FILE non ripresa."
  (concat file ".interrotta"))

(defun gdev-workspaces--keep-unrestored (file)
  "Conserva la sessione di FILE prima di sostituirla, se ha bozze e nessuno
l'ha ripresa.  Dopo un arresto anomalo il checkpoint contiene l'unica copia
delle bozze: la prima modifica di una sessione nuova lo riscriverebbe senza
di esse."
  (when (and (not gdev-workspaces--session-active) (file-regular-p file))
    (let ((session (condition-case nil (gdev-workspaces--read) (error 'unreadable))))
      ;; Un file che non si legge più, per esempio con un formato sconosciuto
      ;; dopo un aggiornamento al contrario, può ancora contenere bozze: si conserva.
      (when (or (eq session 'unreadable) (plist-get session :drafts))
        (copy-file file (gdev-workspaces--interrupted-file file) t)
        (message "Le bozze della sessione precedente sono conservate: riprendile con C-c q L")))))

(defun gdev-workspaces-restore-interrupted ()
  "Riprende la sessione interrotta, conservata prima di essere sostituita."
  (interactive)
  (let ((file (gdev-workspaces--interrupted-file (gdev-state-file "gdev-workspaces.eld"))))
    (unless (file-regular-p file)
      (user-error "Nessuna sessione interrotta da riprendere"))
    (gdev-workspaces-restore file)
    (delete-file file)))

(defun gdev-workspaces--write-checkpoint (file drafts revisions)
  "Salva DRAFTS in FILE e restituisci la cache delle REVISIONI effettivamente
salvate."
  (gdev-workspaces--keep-unrestored file)
  (let ((origin (current-buffer))
        (tabs (tab-bar-tabs))
        (next (make-hash-table :test #'eq))
        (remaining gdev-workspaces--checkpoint-cache-limit))
    (gdev-write-state-file
     file
     (lambda ()
       (let ((session
              (with-current-buffer origin
                (gdev-workspaces--session
                 tabs drafts
                 (lambda (buffer key)
                   (let* ((revision (gethash buffer revisions))
                          (old (and gdev-workspaces--checkpoint-cache
                                    (gethash buffer gdev-workspaces--checkpoint-cache)))
                          (entry (if (equal (car old) revision)
                                     old
                                   (cons revision
                                         (prin1-to-string (cons key (gdev-drafts--snapshot buffer))))))
                          (bytes (string-bytes (cdr entry))))
                     (when (<= bytes remaining)
                       (puthash buffer entry next)
                       (cl-decf remaining bytes))
                     (cdr entry)))))))
         ;; Le bozze sono già serializzate. Il risultato resta la stessa
         ;; lista Lisp letta anche dai salvataggi precedenti.
         (insert "(")
         (cl-loop for (key value) on session by #'cddr do
                  (prin1 key (current-buffer))
                  (insert " ")
                  (if (and (eq key :drafts) value)
                      (progn
                        (insert "(")
                        (dolist (entry value) (insert entry "\n"))
                        (insert ")"))
                    (prin1 value (current-buffer)))
                  (insert " "))
         (insert ")"))))
    next))

(defvar gdev-workspaces--checkpoint-timer nil
  "Salvataggio delle bozze in attesa della prossima pausa nella scrittura.")

(defconst gdev-workspaces--checkpoint-pause 2
  "Secondi di inattività prima di scrivere le bozze dovute.")

(defun gdev-workspaces-schedule-checkpoint ()
  "Rimanda il salvataggio delle bozze alla prossima pausa nella scrittura.
Copiare e scrivere un documento lungo richiede tempo: durante la
digitazione il salvataggio attende, se Emacs è già inattivo parte subito."
  (unless (memq gdev-workspaces--checkpoint-timer timer-idle-list)
    (setq gdev-workspaces--checkpoint-timer
          (run-with-idle-timer gdev-workspaces--checkpoint-pause nil
                               #'gdev-workspaces-checkpoint))))

(defun gdev-workspaces-checkpoint ()
  "Conserva le bozze modificate periodicamente per il recupero."
  (let* ((drafts (when gdev-drafts-hot-exit
                   (sort (gdev-workspaces--drafts)
                         :key (lambda (entry) (buffer-name (car entry)))
                         :lessp #'string-lessp)))
         (file (gdev-state-file "gdev-workspaces.eld"))
         (revisions (make-hash-table :test #'eq))
         (signature (mapcar (pcase-lambda (`(,buffer . ,key))
                              (cons buffer (puthash buffer
                                                    (gdev-workspaces--draft-revision buffer key)
                                                    revisions)))
                            drafts)))
    (when (or (not (equal signature gdev-workspaces--checkpoint-signature))
              (and drafts (not (equal file gdev-workspaces--checkpoint-file))))
      (with-demoted-errors "Salvataggio delle bozze: %S"
        (setq gdev-workspaces--checkpoint-cache
              (gdev-workspaces--write-checkpoint file drafts revisions)
              gdev-workspaces--checkpoint-file file
              gdev-workspaces--checkpoint-signature signature
              gdev-workspaces--session-active t)))))

(defun gdev-workspaces-save (&optional on-exit)
  "Salva gli spazi di lavoro senza cambiare scheda o gruppo editor.
Con ON-EXIT conserva il salvataggio precedente se l'avvio è rimasto vuoto.
Le bozze si includono quando `gdev-drafts-hot-exit' è attivo."
  (let* ((session (gdev-workspaces--session
                   (tab-bar-tabs) (when gdev-drafts-hot-exit
                                    (gdev-workspaces--drafts))))
         (records (plist-get session :tabs)))
    (when (or (not on-exit) gdev-workspaces--session-active (cdr records)
              (plist-get (car records) :files) (plist-get (car records) :root)
              (plist-get (car records) :folder)
              (plist-get (car records) :folders)
              (plist-get (car records) :project))
      (gdev-workspaces--write session))))

(defun gdev-workspaces--write (session)
  "Sostituisce il salvataggio completato con SESSION."
  (gdev-workspaces--keep-unrestored (gdev-state-file "gdev-workspaces.eld"))
  (gdev-write-state-data (gdev-state-file "gdev-workspaces.eld") session)
  (setq gdev-workspaces--session-active t))

(defun gdev-workspaces-quit (restart)
  "Esci conservando le bozze.  Con RESTART riavvia e ripristina."
  (let* ((tabs (tab-bar-tabs))
         (draft-index (gdev-workspaces--index-drafts (gdev-workspaces--drafts) #'eq))
         (records (mapcar (lambda (tab) (gdev-workspaces--record tab draft-index)) tabs))
         (references (gdev-workspaces--referenced-files records))
         (other (lambda ()
                  (not (and draft-index (gethash (gethash (current-buffer) draft-index) references)))))
         (verb (if restart "riavviare" "uscire")))
    (when (or (files--buffers-needing-to-be-saved other)
              (run-hook-with-args-until-success 'save-some-buffers-functions 'query))
      (save-some-buffers nil other))
    (when (run-hook-with-args-until-failure 'kill-emacs-query-functions)
      (let* ((remaining (files--buffers-needing-to-be-saved other))
             (processes (and confirm-kill-processes
                             (seq-filter (lambda (process)
                                           (and (process-live-p process) (process-query-on-exit-flag process)))
                                         (process-list)))))
        (when (cond (remaining
                     (yes-or-no-p (format "Restano %d documenti da salvare%s. Vuoi %s comunque? "
                                          (length remaining)
                                          (if processes " e ci sono processi attivi" "") verb)))
                    (processes
                     (yes-or-no-p (format "Ci sono %d processi attivi. Vuoi interromperli e %s? "
                                          (length processes) verb)))
                    (confirm-kill-emacs (funcall confirm-kill-emacs (format "Vuoi %s da GDev? " verb)))
                    (t t))
          (let* ((gdev-session--restarting t)
                 (session (gdev-workspaces--session (tab-bar-tabs) (gdev-workspaces--drafts))))
            (if (or restart (plist-get session :drafts))
                (progn (gdev-workspaces--write session)
                       (gdev-session--mark-restore))
              (gdev-workspaces-save t))
            (kill-emacs nil restart)))))))

(defun gdev-workspaces-save-on-exit ()
  "Salva la sessione dopo una chiusura confermata."
  (unless (or noninteractive gdev-session--restarting)
    (with-demoted-errors "Salvataggio della sessione: %S"
      (gdev-workspaces-save t))))

(defun gdev-workspaces--legacy-path (name files)
  "Cerca il nome di buffer NAME tra i percorsi FILES di una vecchia sessione."
  (when (stringp name)
    (let ((matches (seq-filter (lambda (file) (string-suffix-p (concat "/" name) file)) files)))
      (if (member name files) name (and (consp matches) (null (cdr matches)) (car matches))))))

(defun gdev-workspaces--read-legacy (file)
  "Legge i dati della sessione Tabspaces FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (tabs projects (read-circle nil))
      (condition-case nil
          (while t
            (pcase (read (current-buffer))
              (`(setq tabspaces--session-list ',value) (setq tabs value))
              (`(setq tabspaces-project-tab-map ',value) (setq projects value))))
        (end-of-file nil))
      (list :active 0
            :tabs (cl-loop for (buffers name state) in tabs
                           for files = (delq nil (mapcar #'gdev-workspaces--local-path buffers))
                           for tree = (gdev-workspaces--map-tree
                                       (cdr state)
                                       (lambda (ref) (gdev-workspaces--legacy-path ref files)))
                           collect (list :name name :files files :project (car (rassoc name projects))
                                         :windows (when tree (cons (car state) tree))))))))

(defun gdev-workspaces--validate-session (session)
  "Verifica i record di SESSION prima di modificare schede o buffer."
  (let ((tabs (plist-get session :tabs))
        (drafts (plist-get session :drafts)))
    (unless (and (proper-list-p tabs)
                 (cl-every (lambda (record)
                             (and (plistp record)
                                  (stringp (plist-get record :name))
                                  (proper-list-p (plist-get record :files))
                                  (proper-list-p (plist-get record :folders))
                                  (proper-list-p (plist-get record :launch-selections))))
                           tabs)
                 (proper-list-p drafts)
                 (cl-every (lambda (entry)
                             (and (consp entry) (gdev-drafts--record-p (cdr entry))))
                           drafts))
      (error "Schede o bozze della sessione non valide")))
  session)

(defun gdev-workspaces--read (&optional only-file)
  "Legge la sessione corrente o, al primo avvio, la precedente sessione Tabspaces.
Con ONLY-FILE legge quel file e nessun altro."
  (let ((file (or only-file (gdev-state-file "gdev-workspaces.eld")))
        (legacy (and (not only-file)
                     (or (bound-and-true-p tabspaces-session-file)
                         (gdev-state-file "workspaces.eld")))))
    (condition-case err
        (cond ((file-exists-p file)
               (with-temp-buffer
                 (insert-file-contents file)
                 (let ((session (let ((read-circle nil)) (read (current-buffer)))))
                   (unless (eql (plist-get session :version) 1)
                     (error "Formato di sessione sconosciuto"))
                   (gdev-workspaces--validate-session session))))
              ((and legacy (file-exists-p legacy))
               (gdev-workspaces--validate-session (gdev-workspaces--read-legacy legacy))))
      (error (user-error "Impossibile leggere la sessione. %s" (error-message-string err))))))

(cl-defstruct gdev-workspaces--restore-transaction existing opened changes)

(defun gdev-workspaces--remember-restore-buffer (transaction buffer)
  "Registra BUFFER se è stato creato durante TRANSACTION."
  (when (and transaction (buffer-live-p buffer)
             (not (memq buffer (gdev-workspaces--restore-transaction-existing transaction))))
    (cl-pushnew buffer (gdev-workspaces--restore-transaction-opened transaction)))
  buffer)

(defun gdev-workspaces--track-restored-buffer (transaction buffer)
  "Registra BUFFER in TRANSACTION. Restituisci t se ne serve l'annullamento."
  (if (memq buffer (gdev-workspaces--restore-transaction-existing transaction))
      (let ((changes (gdev-workspaces--restore-transaction-changes transaction)))
        (unless (assq buffer changes)
          (let ((group (prepare-change-group buffer)))
            (activate-change-group group)
            (setf (gdev-workspaces--restore-transaction-changes transaction)
                  (nconc group changes))))
        t)
    (gdev-workspaces--remember-restore-buffer transaction buffer)
    nil))

(defun gdev-workspaces--visit-restored-file (file transaction)
  "Visita FILE e registra in TRANSACTION un buffer aperto con successo."
  (or (find-buffer-visiting file)
      (gdev-workspaces--remember-restore-buffer
       transaction (gdev-drafts--visit-unopened-file file))))

(defun gdev-workspaces--restore-editor-layout (record buffers home)
  "Ripristina gli editor di RECORD usando BUFFERS e la vista iniziale HOME."
  (let ((state (plist-get record :windows))
        (before (current-window-configuration))
        (fallback (or (cdar buffers) home)))
    (condition-case err
        (if-let* ((tree (gdev-workspaces--map-tree
                         (cdr state)
                         (lambda (path) (cdr (assoc path buffers)))
                         (buffer-name home))))
            (progn
              (let ((ignore-window-parameters t))
                (gdev-window-state-put (cons (car state) tree) (window-main-window) 'safe))
              (gdev-layout-limit-restored-editors))
          (set-window-buffer (gdev-layout-editor) fallback))
      (error
       (set-window-configuration before)
       (set-window-buffer (gdev-layout-editor) fallback)
       (message "Disposizione di %s ridotta a un gruppo. %s"
                (plist-get record :name) (error-message-string err))))))

(defun gdev-workspaces--restore-tab (record draft-index recovered &optional decoded transaction)
  "Ripristina RECORD usando DRAFT-INDEX e riutilizzando i buffer RECOVERED.
DECODED contiene le bozze binarie già convalidate. TRANSACTION registra
i buffer aperti o modificati durante il ripristino."
  (tab-bar-rename-tab (plist-get record :name))
  (when-let* ((project (gdev-workspaces--local-path (plist-get record :project)))
              ((boundp 'tabspaces-project-tab-map)))
    (setf (alist-get project tabspaces-project-tab-map nil nil #'equal) (plist-get record :name)))
  (let* ((root (gdev-workspaces--local-path (plist-get record :root)))
         (folder (gdev-workspaces--local-path (plist-get record :folder)))
         (track-buffer (when transaction
                         (lambda (buffer)
                           (gdev-workspaces--track-restored-buffer transaction buffer))))
         (roots (cl-loop for path in (plist-get record :folders)
                         for local = (gdev-workspaces--local-path path)
                         when (and local (file-directory-p local))
                         collect (file-name-as-directory local)))
         (buffers (cl-loop for path in (plist-get record :files)
                           for draft = (and draft-index (gethash path draft-index))
                           for buffer = (cond (draft
                                              (or (gethash path recovered)
                                                  (puthash path (gdev-drafts--restore
                                                                 draft (and decoded (gethash path decoded))
                                                                 track-buffer)
                                                           recovered)))
                                             ((and (gdev-workspaces--local-path path) (file-regular-p path))
                                              (with-demoted-errors "Documento della sessione: %S"
                                                (gdev-workspaces--visit-restored-file path transaction))))
                           when buffer collect (cons path buffer)))
         (home (gdev-workspaces--remember-restore-buffer transaction (gdev-layout-home-buffer))))
    (set-frame-parameter nil 'buffer-list (mapcar #'cdr buffers))
    (gdev-workspace-state-update
     (append
      (if roots
          (gdev-workspace-root-fields (delete-dups roots))
        (append (when (and root (file-directory-p root))
                  (list (cons 'gdev-layout-explorer-root root)))
                (when (and folder (file-directory-p folder))
                  (list (cons 'gdev-layout-folder folder)))))
      `((gdev-layout-explorer-width . ,(plist-get record :explorer-width)))
      (cl-loop for (property . field) in gdev-workspaces--stored-fields
               for value = (plist-get record property)
               when (gdev-workspace-state-saved-p field)
               collect (cons field
                             (pcase property
                               (:commands-visibility (and (memq value '(shown hidden)) value))
                               (:commands-width (and (natnump value) value))
                               (:launch-selections (gdev-workspaces--launch-selections value))
                               (:panel (gdev-workspaces--panel-session value))
                               (_ value))))))
    (when (and (not (plist-get record :activity))
               (gdev-workspace-state-get 'gdev-layout-explorer-root)
               (plist-get record :explorer-visible)
               (fboundp 'gdev-sidebar-show))
      (unwind-protect
          (with-demoted-errors "Esplora file: %S" (gdev-sidebar-show (or (car roots) root) t))
        (gdev-workspaces--remember-restore-buffer
         transaction (gdev-workspace-state-get 'gdev-layout-explorer-buffer))))
    (gdev-workspaces--restore-editor-layout record buffers home)))

(defun gdev-workspaces--initial-tab-p (tabs)
  "Restituisce non nil se TABS contiene soltanto la schermata d'avvio."
  (and (null (cdr tabs))
       (not (gdev-layout-split-p))
       (with-current-buffer (window-buffer (gdev-layout-editor))
         (or (derived-mode-p 'gdev-dashboard-mode)
             (and (equal (buffer-name) "*scratch*") (not (buffer-modified-p)))))
       (not (plist-get (gdev-workspaces--record (car tabs)) :files))
       (not (gdev-workspace-state-get 'gdev-layout-explorer-root))
       (not (gdev-workspace-state-get 'gdev-layout-folder))
       (seq-every-p (lambda (buffer) (equal (buffer-name buffer) "*Warnings*"))
                    (gdev-layout--panel-buffers))))

(defun gdev-workspaces--apply-session (tabs apply-session)
  "Esegui APPLY-SESSION con un ripristino delle risorse GDev in caso di errore.
TABS è l'elenco delle schede prima dell'operazione."
  (let* ((frame (selected-frame))
         (windows (current-window-configuration frame))
         (parameters (mapcar (lambda (key) (cons key (frame-parameter frame key)))
                             '(buffer-list buried-buffer-list gdev-layout-focus tab-bar-lines)))
         (original-tabs (copy-sequence tabs))
         (tab-entries (mapcar #'gdev-workspace-state-snapshot tabs))
         (projects (when (boundp 'tabspaces-project-tab-map)
                     (cons t (copy-alist tabspaces-project-tab-map))))
         (tabs-visible tab-bar-mode)
         (history-back (gethash frame tab-bar-history-back))
         (history-forward (gethash frame tab-bar-history-forward))
         (history-omit tab-bar-history-omit)
         (transaction (make-gdev-workspaces--restore-transaction :existing (buffer-list)))
         committed)
    (unwind-protect
        (progn
          (funcall apply-session transaction)
          (accept-change-group (gdev-workspaces--restore-transaction-changes transaction))
          (setq committed t))
      (unless committed
        (let ((inhibit-quit t))
          (dolist (change (gdev-workspaces--restore-transaction-changes transaction))
            (when (buffer-live-p (car change))
              (with-demoted-errors "Ripristino di un documento: %S"
                (cancel-change-group (list change))
                (with-current-buffer (car change)
                  (set-buffer-modified-p nil)))))
          (when projects (setq tabspaces-project-tab-map (cdr projects)))
          (when (frame-live-p frame)
            (mapc #'gdev-workspace-state-restore tab-entries)
            (tab-bar-tabs-set original-tabs frame)
            (puthash frame history-back tab-bar-history-back)
            (puthash frame history-forward tab-bar-history-forward)
            (setq tab-bar-history-omit history-omit)
            (with-demoted-errors "Ripristino delle finestre: %S"
              (unless (eq tabs-visible tab-bar-mode)
                (tab-bar-mode (if tabs-visible 1 -1)))
              (set-window-configuration windows)
              (modify-frame-parameters frame parameters)
              (force-mode-line-update t)))
          (dolist (buffer (gdev-workspaces--restore-transaction-opened transaction))
            (when (buffer-live-p buffer)
              (with-demoted-errors "Chiusura di un documento del ripristino: %S"
                (with-current-buffer buffer (set-buffer-modified-p nil))
                (kill-buffer buffer)))))))))

(defun gdev-workspaces--restored-name (record existing draft-index)
  "Nome con cui ripristinare RECORD, dato l'elenco EXISTING degli spazi già
aperti.  Uno spazio aperto con lo stesso nome vale come già ripristinato, ma
solo se la scheda salvata non ha bozze: altrimenti il suo testo non sarebbe
mai letto e il salvataggio successivo lo cancellerebbe.  DRAFT-INDEX associa
i percorsi alle bozze."
  (let ((name (plist-get record :name)))
    (if (and (member name existing)
             draft-index
             (seq-some (lambda (path) (gethash path draft-index)) (plist-get record :files)))
        (concat name " (bozze)")
      name)))

(defun gdev-workspaces-restore (&optional file)
  "Riprende la sessione lasciando intatti gli spazi di lavoro già in uso.
Con FILE legge quel salvataggio al posto di quello corrente."
  (let* ((session (gdev-workspaces--read file))
         (records (or (plist-get session :tabs) (user-error "Nessuna sessione da riprendere")))
         ;; Le viste si riaprono dal loro stato, non dal testo salvato.
         (drafts (seq-remove (lambda (entry) (gdev-drafts--view-p (cdr entry)))
                             (plist-get session :drafts)))
         (draft-index (gdev-workspaces--index-drafts drafts #'equal))
         (decoded (gdev-drafts--decode-binary-records drafts))
         (recovered (make-hash-table :test #'equal))
         (tabs (tab-bar-tabs))
         (reuse (gdev-workspaces--initial-tab-p tabs))
         (existing (and (not reuse) (mapcar (lambda (tab) (alist-get 'name (cdr tab))) tabs)))
         (count (length tabs))
         (active (plist-get session :active))
         (gdev-layout--displaying t)
         (switch-to-buffer-obey-display-actions nil)
         (tab-bar-new-tab-choice #'gdev-layout-home-buffer)
         restored)
    (gdev-workspaces--apply-session
     tabs
     (lambda (transaction)
       (dolist (record records)
         (let* ((name (gdev-workspaces--restored-name record existing draft-index))
                (record (if (equal name (plist-get record :name))
                            record
                          (plist-put (copy-sequence record) :name name)))
                (index (seq-position existing name)))
           (cond (index (setcar (nthcdr index existing) nil))
                 (t
                  (if reuse
                      (progn
                        (setq reuse nil index 0)
                        (let ((ignore-window-parameters t))
                          (delete-other-windows (gdev-layout-editor)))
                        (tab-bar-tabs-set nil))
                    (tab-bar-new-tab-to -1)
                    (setq index count count (1+ count)))
                  (gdev-workspaces--restore-tab record draft-index recovered decoded transaction)))
           (push (1+ index) restored)))
       (setq restored (nreverse restored))
       (tab-bar-select-tab (or (and (natnump active) (nth active restored)) (car restored)))))
    (setq gdev-workspaces--session-active t)
    (message "Sessione ripresa")))

(provide 'gdev-workspaces)
;;; gdev-workspaces.el ends here
