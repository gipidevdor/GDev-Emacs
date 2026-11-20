;;; gdev-workspace-state-test.el --- Contratto dello stato degli spazi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la destinazione degli aggiornamenti e il confine con Tab Bar.

;;; Code:

(require 'ert)
(require 'gdev-workspace-state)

(defvar tabspaces-project-tab-map)
(defvar tabspaces-session-file)

(ert-deftest gdev-test-workspace-state-updates-the-inactive-space ()
  "Un aggiornamento esplicito appartiene alla sua scheda anche se è inattiva."
  (gdev-test--with-layout
    (should-not (gdev-workspace-state-id))
    (let* ((frame (selected-frame))
           (first (gdev-workspace-state-ensure-id frame)))
      (should (eq first (gdev-workspace-state-id frame)))
      (gdev-workspace-state-set 'gdev-activity-view 'search)
      (tab-bar-new-tab)
      (let ((second (gdev-workspace-state-ensure-id frame))
            (target (gdev-workspace-state-find first frame)))
        (should (and second (not (eq first second))))
        (should (memq target (gdev-workspace-state-tabs frame)))
        (should-not (eq target (gdev-workspace-state-current frame)))
        (should (eq (gdev-workspace-state-read 'gdev-activity-view target) 'search))
        (gdev-workspace-state-set 'gdev-activity-view 'explorer)
        (gdev-workspace-state-update '((gdev-activity-view . run)
                                      (gdev-layout-explorer-width . 30))
                                    target)
        (should (eq (gdev-workspace-state-id frame) second))
        (should (eq (gdev-workspace-state-get 'gdev-activity-view frame) 'explorer))
        (should (eq (gdev-workspace-state-read 'gdev-activity-view target) 'run))
        (tab-bar-select-tab 1)
        (should (eq (gdev-workspace-state-id frame) first))
        (should (eq (gdev-workspace-state-get 'gdev-activity-view frame) 'run))
        (should (= (gdev-workspace-state-get 'gdev-layout-explorer-width frame) 30))))))

(ert-deftest gdev-test-workspace-state-update-rejects-all-fields-on-error ()
  "Un campo sconosciuto rifiuta l'intero aggiornamento."
  (gdev-test--with-layout
    (gdev-workspace-state-set 'gdev-activity-view 'search)
    (let* ((tab (gdev-workspace-state-current))
           (width (gdev-workspace-state-read 'gdev-layout-explorer-width tab)))
      (should-error
       (gdev-workspace-state-update '((gdev-activity-view . run)
                                     (gdev-layout-explorer-width . 36)
                                     (gdev-state-field-not-registered . t))
                                   tab))
      (should (eq (gdev-workspace-state-read 'gdev-activity-view tab) 'search))
      (should (equal (gdev-workspace-state-read 'gdev-layout-explorer-width tab) width)))))

(ert-deftest gdev-test-workspace-state-keeps-legacy-private-fields ()
  "Le configurazioni precedenti possono ancora aggiornare e rimuovere una chiave privata."
  (gdev-test--with-layout
    (let* ((tab (gdev-layout--tab))
           (owner (gdev-layout-workspace-id))
           (key 'gdev-personal-private-preference))
      (should (eq (gdev-layout-set-tab-value key 'preferito) 'preferito))
      (should (eq (gdev-layout-tab-value key) 'preferito))
      (should-error (gdev-workspace-state-set key 'altro))
      (let ((snapshot (gdev-workspace-state-snapshot tab)))
        (should-not (gdev-layout-set-tab-value key nil))
        (should-not (gdev-layout-tab-value key))
        (gdev-workspace-state-restore snapshot)
        (should (eq (gdev-layout--tab) tab))
        (should (eq (gdev-layout-workspace-id) owner))
        (should (eq (gdev-layout-tab-value key) 'preferito))))))

(ert-deftest gdev-test-workspace-state-releases-resources-of-closed-tab ()
  "La chiusura elimina identità e viste dello spazio indicato, anche se inattivo."
  (require 'gdev-activity)
  (require 'gdev-command-sidebar)
  (gdev-test--with-layout
    (let ((tools (generate-new-buffer " *Comandi dello spazio chiuso*"))
          (preferences (generate-new-buffer " *Preferenze dello spazio chiuso*"))
          (activity (generate-new-buffer " *Attività dello spazio chiuso*"))
          (tab-bar-tab-pre-close-functions
           '(gdev-command-sidebar--close-tab gdev-activity-close-tab)))
      (unwind-protect
          (let ((owner (gdev-workspace-state-ensure-id)))
            (gdev-workspace-state-update
             `((gdev-command-sidebar-buffer . ,tools)
               (gdev-preferences-buffer . ,preferences)
               (gdev-activity-buffers (search . ,activity))))
            (gdev-command-sidebar--close-tab (gdev-workspace-state-current) t)
            (gdev-activity-close-tab (gdev-workspace-state-current) t)
            (should (seq-every-p #'buffer-live-p (list tools preferences activity)))
            (tab-bar-new-tab-to -1)
            (let ((remaining (gdev-workspace-state-ensure-id)))
              (gdev-workspace-state-set 'gdev-activity-view 'git)
              (tab-bar-close-tab 1)
              (should-not (gdev-workspace-state-find owner))
              (should-not (seq-some #'buffer-live-p (list tools preferences activity)))
              (should (eq (gdev-workspace-state-id) remaining))
              (should (eq (gdev-workspace-state-get 'gdev-activity-view) 'git))))
        (dolist (buffer (list tools preferences activity))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-workspace-state-fields-have-one-lifecycle-policy ()
  "Ogni campo è registrato una volta e ha un ciclo di vita valido."
  (let ((keys (mapcar #'car gdev-workspace-state-fields)))
    (should (equal keys (delete-dups (copy-sequence keys)))))
  (dolist (field gdev-workspace-state-fields)
    (should (memq (cdr field) '(clone persist transient until-close)))))

(ert-deftest gdev-test-workspace-state-saved-fields-follow-the-rules ()
  "La sessione salva i campi `clone' e `persist', e soltanto quelli."
  (should (gdev-workspace-state-saved-p 'gdev-layout-folder))
  (should (gdev-workspace-state-saved-p 'gdev-layout-minimap-visible))
  (should-not (gdev-workspace-state-saved-p 'gdev-layout-panel-height))
  (should-not (gdev-workspace-state-saved-p 'gdev-launch-pending))
  (should-not (gdev-workspace-state-saved-p 'gdev-campo-sconosciuto))
  (require 'gdev-workspaces)
  (let ((saved (append (mapcar #'cdr gdev-workspaces--stored-fields)
                       gdev-workspaces--context-fields)))
    (should (equal saved (delete-dups (copy-sequence saved))))
    (dolist (field gdev-workspace-state-fields)
      (should (eq (and (memq (car field) saved) t)
                  (and (gdev-workspace-state-saved-p (car field)) t))))))

(ert-deftest gdev-test-workspaces-record-skips-fields-kept-in-memory ()
  "Un campo dichiarato temporaneo non entra nel salvataggio della sessione."
  (require 'gdev-workspaces)
  (gdev-test--with-layout
    (gdev-workspace-state-set 'gdev-layout-minimap-visible t)
    (should (eq (plist-get (gdev-workspaces--record (gdev-workspace-state-current)) :minimap) t))
    (let ((gdev-workspace-state-fields
           (cons '(gdev-layout-minimap-visible . transient) gdev-workspace-state-fields)))
      (should-not (plist-member (gdev-workspaces--record (gdev-workspace-state-current))
                                :minimap)))))

(ert-deftest gdev-test-workspace-state-reopens-without-the-previous-identity ()
  "La riapertura ripristina le preferenze, mentre le operazioni sospese scadono."
  (gdev-test--with-layout
    (let ((tab-bar-closed-tabs nil)
          (tab-bar-tab-pre-close-functions nil)
          (tab-bar-tab-prevent-close-functions nil)
          (first (gdev-workspace-state-ensure-id)))
      (tab-bar-rename-tab "Primo spazio")
      (gdev-workspace-state-update
       '((gdev-layout-folder . "/prova/")
         (gdev-command-sidebar-category . tools)
         (gdev-launch-pending ignore)))
      (tab-bar-new-tab-to -1)
      (let ((second (gdev-workspace-state-ensure-id)))
        (tab-bar-select-tab 1)
        (tab-bar-close-tab)
        (let ((closed (alist-get 'tab (car tab-bar-closed-tabs))))
          (should-not (gdev-workspace-state-read 'gdev-debug-workspace-id closed))
          (should-not (gdev-workspace-state-read 'gdev-launch-pending closed)))
        (should (eq (gdev-workspace-state-id) second))
        (tab-bar-undo-close-tab)
        (should (equal (gdev-workspace-state-get 'name) "Primo spazio"))
        (should (equal (gdev-workspace-state-get 'gdev-layout-folder) "/prova/"))
        (should (eq (gdev-workspace-state-get 'gdev-command-sidebar-category) 'tools))
        (should-not (gdev-workspace-state-find first))
        (should (gdev-workspace-state-ensure-id))
        (should-not (eq (gdev-workspace-state-id) first))))))

(ert-deftest gdev-test-workspace-state-closes-only-confirmed-tabs ()
  "Chiudi le altre schede senza perdere il riferimento a uno spazio tuttora aperto."
  (gdev-test--with-layout
    (let ((tab-bar-closed-tabs nil)
          (tab-bar-tab-pre-close-functions nil)
          (tab-bar-tab-prevent-close-functions nil)
          (first (gdev-workspace-state-ensure-id)))
      (tab-bar-new-tab-to -1)
      (let ((second (gdev-workspace-state-ensure-id))
            (tab-bar-tab-pre-close-functions (list (lambda (&rest _) (signal 'quit nil)))))
        (should (eq (condition-case nil (tab-bar-close-other-tabs) (quit 'annullato)) 'annullato))
        (should (gdev-workspace-state-find first))
        (should (eq (gdev-workspace-state-id) second)))
      (setq tab-bar-closed-tabs nil)
      (tab-bar-close-other-tabs)
      (should-not (gdev-workspace-state-find first))
      (should-not (gdev-workspace-state-read 'gdev-debug-workspace-id
                                             (alist-get 'tab (car tab-bar-closed-tabs)))))))

(ert-deftest gdev-test-workspace-state-keeps-an-identity-during-transfer ()
  "La chiusura interna al trasferimento mantiene i dati della scheda viva."
  (gdev-test--with-layout
    (let ((tab-bar-closed-tabs nil)
          (tab-bar-tab-pre-close-functions nil)
          (tab-bar-tab-prevent-close-functions nil)
          (owner (gdev-workspace-state-ensure-id)))
      (gdev-workspace-state-set 'gdev-launch-pending (list #'ignore))
      (tab-bar-new-tab-to -1)
      ;; La rimozione dalla finestra di partenza è una chiusura nativa.
      (let ((transferred (gdev-workspace-state--move-tab
                          (lambda (index)
                            (tab-bar-close-tab index)
                            (alist-get 'tab (car tab-bar-closed-tabs)))
                          1)))
        (should (eq (gdev-workspace-state-read 'gdev-debug-workspace-id transferred) owner))
        (should (equal (gdev-workspace-state-read 'gdev-launch-pending transferred) '(ignore)))))))

(ert-deftest gdev-test-workspace-state-clone-copies-only-inherited-values ()
  "La scheda duplicata eredita una lista indipendente dei profili."
  (gdev-test--with-layout
    (let* ((profiles (list (cons "/prova/" "Profilo iniziale")))
           (first (gdev-workspace-state-ensure-id))
           (frame (selected-frame)))
      (gdev-workspace-state-update
       `((gdev-launch-selections . ,profiles)
         (gdev-layout-commands-width . 40)
         (gdev-launch-pending . (ignore))))
      (tab-bar-duplicate-tab)
      (should-not (eq (gdev-workspace-state-id frame) first))
      (should-not (gdev-workspace-state-get 'gdev-layout-commands-width frame))
      (should-not (gdev-workspace-state-get 'gdev-launch-pending frame))
      (let ((cloned (gdev-workspace-state-get 'gdev-launch-selections frame)))
        (should (equal cloned profiles))
        (setcdr (car cloned) "Profilo duplicato"))
      (let ((original (gdev-workspace-state-find first frame)))
        (should (equal (gdev-workspace-state-read 'gdev-launch-selections original)
                       '(("/prova/" . "Profilo iniziale"))))
        (should (= (gdev-workspace-state-read 'gdev-layout-commands-width original) 40))
        (should (equal (gdev-workspace-state-read 'gdev-launch-pending original)
                       '(ignore)))))))

(defun gdev-test-workspace-state--check-form (form)
  "Verifica che FORM usi gli accessori pubblici dei campi dello spazio."
  (cond
   ((memq form '(gdev-layout--tab gdev-layout-tab-value
                                  gdev-layout-set-tab-value gdev-layout-workspace-id))
    (ert-fail (list "Accessore dello spazio obsoleto" form)))
   ((consp form)
    (when (memq (car form) '(alist-get assq))
      (pcase (cadr form)
        (`(quote ,field)
         (when (assq field gdev-workspace-state-fields)
           (ert-fail (list "Accesso diretto a un campo dello spazio" form))))))
    (while (consp form)
      (gdev-test-workspace-state--check-form (pop form)))
    (gdev-test-workspace-state--check-form form))
   ((vectorp form)
    (mapc #'gdev-test-workspace-state--check-form form))))

(ert-deftest gdev-test-workspace-state-access-goes-through-the-contract ()
  "Nucleo e moduli usano gli accessori dello stato dello spazio."
  (dolist (file (gdev-test--elisp-sources))
    (let ((relative (file-relative-name file gdev-config-directory)))
      (when (and (string-match-p "\\`\\(?:lisp\\|modules\\)/" relative)
                 (not (equal relative "lisp/gdev-workspace-state.el")))
        (ert-info (relative)
          (with-temp-buffer
            (insert-file-contents file)
            (condition-case nil
                (while t (gdev-test-workspace-state--check-form (read (current-buffer))))
              (end-of-file nil))))))))

(ert-deftest gdev-test-workspace-state-validates-drafts-before-restoring-tabs ()
  "Una bozza corrotta lascia intatto lo spazio, una valida conserva i byte."
  (require 'gdev-workspaces)
  (let ((gdev-state-directory (make-temp-file "gdev-session-state-" t))
        (name "Bozza binaria di prova"))
    (unwind-protect
        (gdev-test--with-layout
          (tab-bar-rename-tab "Spazio aperto")
          (gdev-workspace-state-set 'gdev-activity-view 'search)
          (let* ((tab (gdev-workspace-state-current))
                 (owner (gdev-workspace-state-ensure-id))
                 (draft (list :name name :base64 t :modified t :text "%%%"))
                 (key (list 'bozza name))
                 (file (gdev-state-file "gdev-workspaces.eld"))
                 (session `(:version 1 :active 1
                            :tabs ((:name "Prima scheda")
                                   (:name "Seconda scheda" :files (,key)))
                            :drafts ((,key . ,draft))))
                 (bytes (unibyte-string 0 255)))
            (gdev-write-state-data file session)
            (should-error (gdev-workspaces-restore) :type 'user-error)
            (should (equal (gdev-workspace-state-tabs) (list tab)))
            (should (eq (gdev-workspace-state-id) owner))
            (should (equal (gdev-workspace-state-get 'name) "Spazio aperto"))
            (should (eq (gdev-workspace-state-get 'gdev-activity-view) 'search))
            (setf (plist-get draft :text) (base64-encode-string bytes t))
            (gdev-write-state-data file session)
            (gdev-workspaces-restore)
            (should (equal (gdev-workspace-state-get 'name) "Seconda scheda"))
            (with-current-buffer (get-buffer name)
              (should-not enable-multibyte-characters)
              (should (equal (buffer-string) bytes)))))
      (when-let* ((buffer (get-buffer name)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-rolls-back-runtime-restore-errors ()
  "Un errore durante il ripristino recupera scheda, documento e cronologia iniziali."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (make-temp-file "gdev-session-rollback-" t))
         (gdev-workspaces--session-active nil)
         (file (expand-file-name "documento.txt" gdev-state-directory))
         (other (expand-file-name "da-aprire.txt" gdev-state-directory))
         (name "Bozza provvisoria")
         (draft-key (list 'bozza name))
         (project (file-name-as-directory gdev-state-directory))
         (tabspaces-project-tab-map (list (cons project "Originale")))
         (restore-tab (symbol-function 'gdev-workspaces--restore-tab))
         buffer)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-file file (insert "testo sul disco"))
          (with-temp-file other (insert "secondo documento"))
          (setq buffer (find-file-noselect file))
          (set-window-buffer (selected-window) buffer)
          (tab-bar-rename-tab "Originale")
          (let* ((window (selected-window))
                 (tab (gdev-workspace-state-current))
                 (owner (gdev-workspace-state-ensure-id))
                 (undo (buffer-local-value 'buffer-undo-list buffer))
                 (draft (with-current-buffer buffer (gdev-drafts--snapshot buffer)))
                 (session `(:version 1 :active 1
                            :tabs ((:name "Prima" :project ,project :files (,file))
                                   (:name "Seconda" :files (,draft-key ,other)))
                            :drafts ((,file . ,draft)
                                     (,draft-key :name ,name :text "bozza" :modified t)))))
            (setf (plist-get draft :text) "testo della bozza"
                  (plist-get draft :modified) t)
            (gdev-write-state-data (gdev-state-file "gdev-workspaces.eld") session)
            ;; Le osservazioni dello stub si registrano e si asseriscono dopo: un `should'
            ;; fallito dentro `should-error' sarebbe preso per l'errore atteso.
            (let (observed)
              (cl-letf (((symbol-function 'gdev-workspaces--restore-tab)
                         (lambda (record &rest args)
                           (apply restore-tab record args)
                           (when (equal (plist-get record :name) "Seconda")
                             (setq observed
                                   (list (cdr (assoc project tabspaces-project-tab-map))
                                         (with-current-buffer buffer (buffer-string))
                                         (buffer-live-p (get-buffer name))
                                         (buffer-live-p (find-buffer-visiting other))))
                             (error "Ripristino interrotto")))))
                (let ((failure (should-error (gdev-workspaces-restore) :type 'error)))
                  (should (equal (cadr failure) "Ripristino interrotto"))))
              (should (equal observed (list "Prima" "testo della bozza" t t))))
            (should (eq (gdev-workspace-state-current) tab))
            (should (eq (gdev-workspace-state-id) owner))
            (should (= (length (gdev-workspace-state-tabs)) 1))
            (should (equal (gdev-workspace-state-get 'name) "Originale"))
            (should (equal (assoc project tabspaces-project-tab-map) (cons project "Originale")))
            (should (eq (selected-window) window))
            (should (eq (window-buffer window) buffer))
            (should-not gdev-workspaces--session-active)
            (should-not (get-buffer name))
            (should-not (find-buffer-visiting other))
            (with-current-buffer buffer
              (should (equal (buffer-string) "testo sul disco"))
              (should-not (buffer-modified-p))
              (should (eq buffer-undo-list undo)))))
      (dolist (candidate (list buffer (get-buffer name) (find-buffer-visiting other)))
        (when (buffer-live-p candidate)
          (with-current-buffer candidate (set-buffer-modified-p nil))
          (kill-buffer candidate)))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-cancelled-restore-keeps-selected-tab ()
  "Annullare tra due schede ripristina la selezione e la concentrazione originali."
  (require 'gdev-workspaces)
  (let ((gdev-state-directory (make-temp-file "gdev-session-annullata-" t))
        (gdev-workspaces--session-active nil))
    (unwind-protect
        (gdev-test--with-layout
          (tab-bar-rename-tab "Spazio a sinistra")
          (let ((first (gdev-workspace-state-ensure-id)))
            (tab-bar-new-tab-to -1)
            (tab-bar-rename-tab "Spazio selezionato")
            (gdev-layout-toggle-focus)
            (unwind-protect
                (let* ((second (gdev-workspace-state-ensure-id))
                       (focus (frame-parameter nil 'gdev-layout-focus))
                       (before (copy-sequence (gdev-workspace-state-tabs)))
                       (window (selected-window))
                       (opened 0)
                       (tab-bar-tab-post-open-functions
                        (list (lambda (_)
                                (when (= (cl-incf opened) 2) (signal 'quit nil))))))
                  (gdev-write-state-data
                   (gdev-state-file "gdev-workspaces.eld")
                   '(:version 1 :active 0 :tabs ((:name "Ripristina uno") (:name "Ripristina due"))))
                  (should (eq (condition-case nil
                                  (progn (gdev-workspaces-restore) 'riuscito)
                                (quit 'annullato))
                              'annullato))
                  (should (= opened 2))
                  (should (equal (gdev-workspace-state-tabs) before))
                  (should (gdev-workspace-state-find first))
                  (should (eq (gdev-workspace-state-id) second))
                  (should (eq (selected-window) window))
                  (should (eq (frame-parameter nil 'gdev-layout-focus) focus))
                  (should-not gdev-workspaces--session-active))
              (gdev-layout-exit-focus))))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-reads-legacy-tabspaces-session ()
  "Una vecchia sessione conserva nome, progetto, percorso e posizione del documento."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (file-name-as-directory (make-temp-file "gdev-tabspaces-" t)))
         (file (expand-file-name "istruzioni.txt" gdev-state-directory))
         (tabspaces-session-file (gdev-state-file "workspaces.eld"))
         (tabspaces-project-tab-map nil)
         (gdev-workspaces--session-active nil)
         buffer)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-file file (insert "Prima riga\nSeconda riga\n"))
          (setq buffer (find-file-noselect file))
          (set-window-buffer (selected-window) buffer)
          (set-window-point (selected-window) 6)
          (let* ((state (window-state-get (window-main-window) 'writable))
                 (records (list (list (list file) "Archivio precedente" state)))
                 (projects (list (cons gdev-state-directory "Archivio precedente"))))
            (with-temp-file tabspaces-session-file
              (prin1 `(setq tabspaces--session-list ',records) (current-buffer))
              (terpri (current-buffer))
              (prin1 `(setq tabspaces-project-tab-map ',projects) (current-buffer))))
          (tab-bar-rename-tab "In uso")
          (gdev-workspaces-restore)
          (should (equal (gdev-workspace-state-get 'name) "Archivio precedente"))
          (should (equal (cdr (assoc gdev-state-directory tabspaces-project-tab-map)) "Archivio precedente"))
          (should (eq (window-buffer (gdev-layout-editor)) buffer))
          (should (= (window-point (gdev-layout-editor)) 6))
          (let ((tab (gdev-workspace-state-current)))
            (gdev-write-state-data (gdev-state-file "gdev-workspaces.eld") '(:version 2))
            (should (gdev-session-db-exists-p))
            (should-error (gdev-workspaces-restore (gdev-state-file "gdev-workspaces.eld")) :type 'user-error)
            (should (eq (gdev-workspace-state-current) tab))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-restores-document-if-geometry-fails ()
  "Una geometria rifiutata recupera il documento e lascia intatti gli altri editor."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (make-temp-file "gdev-session-geometria-" t))
         (file (expand-file-name "editor.txt" gdev-state-directory))
         (gdev-workspaces--session-active nil)
         buffer)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-file file (insert "Documento da riprendere"))
          (setq buffer (find-file-noselect file))
          (set-window-buffer (selected-window) buffer)
          (split-window-right)
          (tab-bar-rename-tab "Da riprendere")
          (gdev-workspaces-save)
          (tab-bar-rename-tab "In uso")
          (let (attempted)
            (cl-letf (((symbol-function 'window-state-put)
                       (lambda (&rest _)
                         (setq attempted t)
                         (split-window-right)
                         (error "Geometria rifiutata"))))
              (gdev-workspaces-restore))
            (should attempted))
          (should (equal (gdev-workspace-state-get 'name) "Da riprendere"))
          (should (one-window-p))
          (should (eq (window-buffer (gdev-layout-editor)) buffer))
          (tab-bar-select-tab 1)
          (should (equal (gdev-workspace-state-get 'name) "In uso"))
          (should (= (length (gdev-layout--editors)) 2)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-cancel-exit-keeps-unowned-document ()
  "Un documento fuori dalla sessione richiede conferma e resta aperto all'annullamento."
  (require 'gdev-workspaces)
  (let ((document (generate-new-buffer "Documento fuori sessione"))
        (confirm-kill-processes nil)
        (kill-emacs-query-functions nil)
        (save-some-buffers-functions nil)
        offered prompt)
    (unwind-protect
        (gdev-test--with-layout
          (with-current-buffer document
            (insert "Da salvare")
            (setq-local buffer-offer-save 'always))
          (cl-letf (((symbol-function 'save-some-buffers)
                     (lambda (_ predicate)
                       (setq offered (with-current-buffer document (funcall predicate)))))
                    ((symbol-function 'yes-or-no-p)
                     (lambda (question) (setq prompt question) nil))
                    ((symbol-function 'kill-emacs)
                     (lambda (&rest _) (ert-fail "L'uscita è stata annullata"))))
            (gdev-workspaces-quit nil))
          (should offered)
          (should (string-match-p "Restano [0-9]+ documenti da salvare" prompt))
          (should (buffer-modified-p document))
          (should (equal (with-current-buffer document (buffer-string)) "Da salvare")))
      (kill-buffer document))))

(ert-deftest gdev-test-workspace-state-saves-only-on-ordinary-exit ()
  "Il salvataggio d'uscita salta il riavvio e conserva lo spazio durante una normale chiusura."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (make-temp-file "gdev-session-uscita-" t))
         (gdev-workspaces--session-active t))
    (unwind-protect
        (gdev-test--with-layout
          (tab-bar-rename-tab "Spazio da conservare")
          (let ((noninteractive nil)
                (gdev-session--restarting t))
            (gdev-workspaces-save-on-exit))
          (should-not (gdev-session-db-exists-p))
          (let ((noninteractive nil)
                (gdev-session--restarting nil))
            (gdev-workspaces-save-on-exit))
          (let ((record (car (plist-get (gdev-workspaces--read) :tabs))))
            (should (equal (plist-get record :name) "Spazio da conservare"))))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-toggles-draft-persistence ()
  "Il comando richiede il salvataggio di entrambe le scelte di conservazione."
  (require 'gdev-drafts)
  (let ((gdev-drafts-hot-exit t)
        choices)
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (variable value &optional _comment)
                 (should (eq variable 'gdev-drafts-hot-exit))
                 (push value choices)
                 (set variable value))))
      (call-interactively #'gdev-drafts-toggle-hot-exit)
      (should-not gdev-drafts-hot-exit)
      (call-interactively #'gdev-drafts-toggle-hot-exit)
      (should gdev-drafts-hot-exit)
      (should (equal choices '(t nil))))))

(ert-deftest gdev-test-workspace-state-restores-first-v1-draft-for-a-shared-key ()
  "Due schede con la stessa chiave ricostruiscono la prima bozza e usano lo stesso buffer."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (make-temp-file "gdev-session-bozza-condivisa-" t))
         (gdev-workspaces--session-active nil)
         (name (generate-new-buffer-name "Bozza condivisa"))
         (key (list 'bozza name))
         restored)
    (unwind-protect
        (gdev-test--with-layout
          (gdev-write-state-data
           (gdev-state-file "gdev-workspaces.eld")
           `(:version 1 :active 1
             :tabs ((:name "Primo spazio" :files (,(copy-tree key)))
                    (:name "Secondo spazio" :files (,(copy-tree key))))
             :drafts ((,key :name ,name :text "prima voce" :modified t)
                      (,(copy-tree key) :name ,name :text "seconda voce" :modified t))))
          (gdev-workspaces-restore)
          (setq restored (get-buffer name))
          (should (buffer-live-p restored))
          (should (equal (with-current-buffer restored (buffer-string)) "prima voce"))
          (should (equal (gdev-workspace-state-get 'name) "Secondo spazio"))
          (should (eq (window-buffer (gdev-layout-editor)) restored))
          (let* ((names (mapcar (lambda (tab) (gdev-workspace-state-read 'name tab))
                                (gdev-workspace-state-tabs)))
                 (first (seq-position names "Primo spazio" #'equal)))
            (tab-bar-select-tab (1+ first))
            (should (eq (window-buffer (gdev-layout-editor)) restored))))
      (when (buffer-live-p restored)
        (with-current-buffer restored (set-buffer-modified-p nil))
        (kill-buffer restored))
      (delete-directory gdev-state-directory t))))

;; Un clic su una voce delle Preferenze riprese dalla sessione non faceva
;; nulla: la vista era stata salvata come bozza e tornava testo semplice.
(ert-deftest gdev-test-workspace-state-views-are-not-drafts ()
  "Le viste non si salvano come bozze e una vista salvata prima non si ripristina."
  (require 'gdev-workspaces)
  (with-temp-buffer
    (special-mode)
    (setq-local gdev-layout-document-p t)
    (let ((inhibit-read-only t)) (insert "Preferenze"))
    (should (buffer-modified-p))
    (should-not (gdev-drafts--key (current-buffer))))
  (should (gdev-drafts--view-p '(:mode special-mode)))
  (should-not (gdev-drafts--view-p '(:mode text-mode)))
  (should-not (gdev-drafts--view-p '(:mode nil)))
  (let* ((gdev-state-directory (make-temp-file "gdev-session-vista-" t))
         (gdev-workspaces--session-active nil)
         (view (generate-new-buffer-name "Vista salvata"))
         (draft (generate-new-buffer-name "Bozza salvata"))
         restored)
    (unwind-protect
        (gdev-test--with-layout
          (gdev-write-state-data
           (gdev-state-file "gdev-workspaces.eld")
           `(:version 1 :active 0
             :tabs ((:name "Spazio" :files ((bozza ,view) (bozza ,draft))))
             :drafts (((bozza ,view) :name ,view :mode special-mode :text "Preferenze" :modified t)
                      ((bozza ,draft) :name ,draft :mode text-mode :text "Appunti" :modified t))))
          (gdev-workspaces-restore)
          (setq restored (get-buffer draft))
          (should (equal (with-current-buffer restored (buffer-string)) "Appunti"))
          (should-not (get-buffer view)))
      (when (buffer-live-p restored)
        (with-current-buffer restored (set-buffer-modified-p nil))
        (kill-buffer restored))
      (delete-directory gdev-state-directory t))))

(ert-deftest gdev-test-workspace-state-draft-scan-skips-clean-documents ()
  "Il checkpoint consulta un percorso solo per un documento modificato."
  (require 'gdev-drafts)
  (with-temp-buffer
    (setq-local gdev-layout-document-p t)
    (let ((buffer (current-buffer))
          (paths 0))
      (cl-letf (((symbol-function 'file-remote-p)
                 (lambda (&rest _) (cl-incf paths) nil)))
        (should-not (gdev-drafts--key buffer))
        (should (zerop paths))
        (insert "Bozza")
        (should (equal (gdev-drafts--key buffer) (list 'bozza (buffer-name buffer))))
        (should (= paths 1))))))

(ert-deftest gdev-test-workspace-state-discards-partial-file-visits ()
  "Il ripristino isola le aperture incomplete e conserva bozza e documenti precedenti."
  (require 'gdev-workspaces)
  (let* ((gdev-state-directory (make-temp-file "gdev-session-visite-incomplete-" t))
         (gdev-workspaces--session-active nil)
         (draft (expand-file-name "bozza.txt" gdev-state-directory))
         (ordinary (expand-file-name "ordinario.txt" gdev-state-directory))
         (previous (expand-file-name "preesistente.txt" gdev-state-directory))
         (failure 'quit)
         (find-file-hook
          (list (lambda ()
                  (when (member (file-name-nondirectory buffer-file-name) '("bozza.txt" "ordinario.txt"))
                    (insert "Modifica dell'apertura incompleta")
                    (signal failure '("Errore di apertura simulato"))))))
         existing recovered)
    (unwind-protect
        (gdev-test--with-layout
          (dolist (file (list draft ordinary previous))
            (with-temp-file file (insert "testo sul disco")))
          (setq existing (find-file-noselect previous))
          (with-current-buffer existing
            (erase-buffer)
            (insert "modifica in corso"))
          (gdev-write-state-data
           (gdev-state-file "gdev-workspaces.eld")
           `(:version 1 :active 0
             :tabs ((:name "Sessione di prova" :files (,draft ,ordinary ,previous)))
             :drafts ((,draft :name "bozza.txt" :file ,draft :modified t
                        :modtime ,(file-attribute-modification-time (file-attributes draft))
                        :text "testo della bozza"))))
          (let ((workspace (gdev-workspace-state-current)))
            (should (eq (condition-case nil (gdev-workspaces-restore) (quit 'annullato)) 'annullato))
            (should (eq (gdev-workspace-state-current) workspace))
            (should-not gdev-workspaces--session-active)
            (should-not (find-buffer-visiting draft)))
          (setq failure 'file-error)
          (gdev-workspaces-restore)
          (setq recovered (window-buffer (gdev-layout-editor)))
          (should (equal (with-current-buffer recovered (buffer-string)) "testo della bozza"))
          (should-not (buffer-file-name recovered))
          (should-not (find-buffer-visiting draft))
          (should-not (find-buffer-visiting ordinary))
          (should (eq (find-buffer-visiting previous) existing))
          (should (equal (with-current-buffer existing (buffer-string)) "modifica in corso"))
          (should (buffer-modified-p existing))
          (dolist (file (list draft ordinary))
            (with-temp-buffer
              (insert-file-contents file)
              (should (equal (buffer-string) "testo sul disco")))))
      (dolist (buffer (list recovered existing (find-buffer-visiting draft)
                            (find-buffer-visiting ordinary)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory gdev-state-directory t))))

(provide 'gdev-workspace-state-test)
;;; gdev-workspace-state-test.el ends here
