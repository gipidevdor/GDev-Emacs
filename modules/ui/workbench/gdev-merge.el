;;; gdev-merge.el --- Anteprima dell'unione a tre vie -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Git produce un risultato testuale a tre vie.  SMerge lo naviga e lo
;; modifica in una scheda indipendente, usando le primitive di Emacs.
;; I file e l'indice di Git restano intatti durante l'anteprima.

;;; Code:

(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'smerge-mode)

(declare-function gdev-call-with-editor "gdev-commands" (function))
(declare-function gdev-editor-document "gdev-commands" ())
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))

(defvar-local gdev-merge--owner nil)
(defvar-local gdev-merge--source nil)
(defvar-local gdev-merge--source-tick nil)
(defvar-local gdev-merge--source-file nil)
(defvar-local gdev-merge--state nil)
(defvar-local gdev-merge--process nil)
(defvar-local gdev-merge--conflicts-cache nil)
(defvar-local gdev-merge--header-cache nil)
(defvar gdev-merge--discarding nil)

(defun gdev-merge--conflicts ()
  "Restituisci il numero di marcatori iniziali del documento intero."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eql tick (car gdev-merge--conflicts-cache))
      (setq gdev-merge--conflicts-cache
            (cons tick (save-restriction
                         (widen)
                         (save-excursion
                           (goto-char (point-min))
                           (how-many smerge-begin-re (point-min) (point-max)))))))
    (cdr gdev-merge--conflicts-cache)))

(defun gdev-merge-conflict-available-p ()
  "Indica che il documento dell'editor contiene conflitti testuali."
  (when-let* ((document (gdev-editor-document)))
    (with-current-buffer document
      (and buffer-file-name (not (derived-mode-p 'gdev-merge-preview-mode))
           (> (gdev-merge--conflicts) 0)))))

(defun gdev-merge-preview-available-p ()
  "Indica che nello spazio corrente esiste un'anteprima dell'unione."
  (buffer-live-p (gdev-workspace-state-get 'gdev-merge-preview)))

(defun gdev-merge--attached-p (buffer)
  "Verifica che BUFFER appartenga ancora al suo spazio originario."
  (when (buffer-live-p buffer)
    (let ((owner (buffer-local-value 'gdev-merge--owner buffer)))
      (seq-some (lambda (frame)
                  (when-let* ((tab (gdev-workspace-state-find owner frame)))
                    (eq buffer (gdev-workspace-state-read 'gdev-merge-preview tab))))
                (frame-list)))))

(defun gdev-merge--discard ()
  "Chiedi conferma prima di scartare le modifiche dell'anteprima."
  (or gdev-merge--discarding (not (buffer-modified-p))
      (yes-or-no-p "Scartare le modifiche all’anteprima dell’unione? ")))

(defun gdev-merge--cleanup-process ()
  "Ferma il calcolo in corso quando si elimina l'anteprima."
  (when (process-live-p gdev-merge--process)
    (setq gdev-merge--state 'cancelled)
    (delete-process gdev-merge--process)))

(defun gdev-merge--close-workspace (tab _last-tab)
  "Chiudi l'anteprima di TAB, conservando il lavoro se annulli."
  (unless gdev-workspace-state--moving-tab
    (when-let* ((buffer (gdev-workspace-state-read 'gdev-merge-preview tab))
                ((buffer-live-p buffer)))
      (unless (kill-buffer buffer)
        (user-error "L’anteprima dell’unione è ancora aperta")))))

(defun gdev-merge--quit-check ()
  "Conferma l'uscita se ci sono anteprime modificate ancora aperte."
  (or (not (seq-some (lambda (buffer)
                      (with-current-buffer buffer
                        (and (derived-mode-p 'gdev-merge-preview-mode) (buffer-modified-p))))
                    (buffer-list)))
      (yes-or-no-p "Uscire e scartare le modifiche alle anteprime dell’unione? ")))

(defun gdev-merge--navigate (direction)
  "Vai al conflitto seguente nella DIRECTION indicata (1 o -1)."
  (unless (eq gdev-merge--state 'ready) (user-error "L’anteprima non è pronta"))
  (let ((origin (point)))
    (unless (save-excursion
              (beginning-of-line)
              (when (> direction 0) (forward-line 1))
              (when (if (> direction 0)
                        (re-search-forward smerge-begin-re nil t)
                      (re-search-backward smerge-begin-re nil t))
                (setq origin (match-beginning 0))))
      (user-error (if (> direction 0) "Nessun conflitto successivo" "Nessun conflitto precedente")))
    (goto-char origin)))

(defun gdev-merge-next ()
  "Vai al conflitto successivo dell'anteprima."
  (interactive)
  (gdev-merge--navigate 1))

(defun gdev-merge-previous ()
  "Vai al conflitto precedente dell'anteprima."
  (interactive)
  (gdev-merge--navigate -1))

(defun gdev-merge--variants ()
  "Restituisci le versioni selezionabili per il conflitto al cursore."
  (save-match-data
    (when (and (eq gdev-merge--state 'ready) (ignore-errors (smerge-match-conflict)))
      (append '(("Tieni la versione superiore" . smerge-keep-upper))
              (when (match-beginning 2) '(("Tieni la base comune" . smerge-keep-base)))
              '(("Tieni la versione inferiore" . smerge-keep-lower)
                ("Confronta le due versioni" . smerge-diff-upper-lower)
                ("Evidenzia le parole cambiate" . smerge-refine))))))

(defun gdev-merge-choose (&optional event)
  "Scegli come trattare il conflitto al cursore, da tastiera o da EVENT."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (let* ((choices (or (gdev-merge--variants)
                      (user-error "Porta il cursore in un conflitto")))
         (action (if (and event (display-graphic-p))
                     (x-popup-menu event (list "Risolvi conflitto" (cons "Risolvi conflitto" choices)))
                   (cdr (assoc (completing-read "Risolvi conflitto: " choices nil t) choices)))))
    (when action
      (atomic-change-group (funcall action))
      (force-mode-line-update))))

(defun gdev-merge--validate-source ()
  "Controlla che il documento di origine sia ancora modificabile e attuale."
  (let ((source gdev-merge--source)
        (tick gdev-merge--source-tick)
        (file gdev-merge--source-file))
    (unless (and (buffer-live-p source)
                 (with-current-buffer source
                   (and (not buffer-read-only)
                        (equal buffer-file-name file)
                        (eql (buffer-chars-modified-tick) tick)
                        (verify-visited-file-modtime source))))
      (user-error "Il documento di origine è cambiato o non è più modificabile"))
    source))

(defun gdev-merge--complete (buffer)
  "Rilascia BUFFER dopo la consegna del risultato."
  (when (eq buffer (gdev-workspace-state-get 'gdev-merge-preview))
    (gdev-workspace-state-set 'gdev-merge-preview nil))
  (let ((gdev-merge--discarding t))
    (kill-buffer buffer)))

(defun gdev-merge--validate-preview (preview tick)
  "Assicurati che il dialogo non abbia reso obsoleti PREVIEW e TICK."
  (unless (and (eq preview (current-buffer))
               (eq preview (gdev-workspace-state-get 'gdev-merge-preview))
               (eql tick (buffer-chars-modified-tick)))
    (user-error "Lo spazio o l’anteprima sono cambiati")))

(defun gdev-merge-finish ()
  "Applica l'anteprima al documento oppure esportala in un nuovo file."
  (interactive)
  (unless (and (eq gdev-merge--state 'ready)
               (eq (current-buffer) (gdev-workspace-state-get 'gdev-merge-preview)))
    (user-error "Apri l’anteprima dell’unione di questo spazio"))
  (when (> (gdev-merge--conflicts) 0)
    (user-error "Risolvi i conflitti prima di consegnare il risultato"))
  (let ((preview (current-buffer)) (tick (buffer-chars-modified-tick)))
    (cond
     (gdev-merge--source
      (let ((source (gdev-merge--validate-source)))
        (when (yes-or-no-p (format "Applicare il risultato al documento «%s»? " (buffer-name source)))
          (gdev-merge--validate-preview preview tick)
          (gdev-merge--validate-source)
          (save-restriction
            (widen)
            (with-current-buffer source
              (save-restriction
                (widen)
                (undo-boundary)
                (with-suppressed-warnings ((obsolete replace-buffer-contents))
                  (atomic-change-group (replace-buffer-contents preview 0.25)))
                (undo-boundary))))
          (switch-to-buffer source)
          (gdev-merge--complete preview))))
     (t
      (let ((file (read-file-name "Esporta il risultato in un nuovo file: " default-directory)))
        (gdev-merge--validate-preview preview tick)
        (when (file-remote-p file) (user-error "Scegli un nuovo file locale"))
        (let ((coding-system-for-write 'utf-8-unix))
          (save-restriction
            (widen)
            (write-region (point-min) (point-max) file nil 'silent nil 'excl)))
        (gdev-open-file file)
        (gdev-merge--complete preview))))))

(defun gdev-merge--header-action (label help command)
  "Crea un controllo per COMMAND con LABEL e suggerimento HELP."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1]
                (lambda (event)
                  (interactive "e")
                  (select-window (posn-window (event-start event)))
                  (call-interactively command)))
    (propertize label 'face 'gdev-ui-action 'mouse-face 'gdev-ui-side-hover
                'keymap map 'help-echo help 'pointer 'hand 'gdev-merge-command command)))

(defun gdev-merge--header-actions (finish compact)
  "Formatta le operazioni, con FINISH come etichetta dell'azione finale."
  (mapconcat #'identity
             (list
              (gdev-merge--header-action (if compact "‹" "‹ Precedente")
                                         "Conflitto precedente" #'gdev-merge-previous)
              (gdev-merge--header-action (if compact "›" "Successivo ›")
                                         "Conflitto successivo" #'gdev-merge-next)
              (gdev-merge--header-action "Scelte…" "Scegli la versione del conflitto"
                                         #'gdev-merge-choose)
              (gdev-merge--header-action finish "Consegna il risultato dell’unione"
                                         #'gdev-merge-finish))
             "   "))

(defun gdev-merge--header ()
  "Disegna la riga di controllo dell'anteprima nella finestra corrente."
  (let* ((graphic (display-graphic-p))
         (width (window-body-width nil graphic))
         (measure (if graphic #'gdev-ui-string-pixel-width #'string-width))
         (count (if (eq gdev-merge--state 'ready) (gdev-merge--conflicts) 0))
         (stamp (list width graphic gdev-merge--state count (window-frame)
                      (frame-parameter nil 'background-mode)
                      (face-attribute 'variable-pitch :family nil t)
                      (face-attribute 'variable-pitch :height nil t))))
    (unless (equal stamp (car gdev-merge--header-cache))
      (let* ((status (propertize
                      (pcase gdev-merge--state
                        ('pending "Calcolo dell’unione…")
                        ('failed "Unione non riuscita")
                        (_ (if (= count 1) "1 conflitto" (format "%d conflitti" count))))
                      'face 'gdev-ui-secondary))
             (controls (when (eq gdev-merge--state 'ready)
                         (let* ((finish (if gdev-merge--source "Applica…" "Esporta…"))
                                (full (concat status "   " (gdev-merge--header-actions finish nil)))
                                (short (concat status "   " (gdev-merge--header-actions finish t))))
                           (cond ((<= (funcall measure full) width) full)
                                 ((<= (funcall measure short) width) short)
                                 (t (gdev-merge--header-actions finish t)))))))
        (setq gdev-merge--header-cache (cons stamp (list (or controls status))))))
    (cdr gdev-merge--header-cache)))

(defvar-keymap gdev-merge-preview-mode-map
  "C-c C-n" #'gdev-merge-next
  "C-c C-p" #'gdev-merge-previous
  "C-c C-e" #'gdev-merge-choose
  "C-c C-s" #'gdev-merge-finish)

(define-derived-mode gdev-merge-preview-mode text-mode "Anteprima unione"
  "Modifica e controlla un'unione prima di consegnare il risultato."
  (gdev-ui-view-setup 'native)
  (gdev-layout-mark-document)
  (setq-local header-line-format '(:eval (gdev-merge--header))
              smerge-auto-leave nil)
  (add-hook 'kill-buffer-query-functions #'gdev-merge--discard nil t)
  (add-hook 'kill-buffer-hook #'gdev-merge--cleanup-process nil t))

(defun gdev-merge-resume ()
  "Mostra l'anteprima dell'unione dello spazio corrente."
  (interactive)
  (let ((buffer (gdev-workspace-state-get 'gdev-merge-preview)))
    (unless (buffer-live-p buffer) (user-error "Nessuna anteprima in questo spazio"))
    (gdev-call-with-editor (lambda () (switch-to-buffer buffer)))))

(defun gdev-merge--new-preview ()
  "Prepara un'anteprima indipendente per lo spazio attivo."
  (unless gdev-layout-mode (user-error "Attiva il banco di lavoro"))
  (when-let* ((previous (gdev-workspace-state-get 'gdev-merge-preview))
              ((buffer-live-p previous)))
    (unless (kill-buffer previous)
      (user-error "L’anteprima precedente è ancora aperta")))
  (let ((buffer (generate-new-buffer "*Anteprima unione*"))
        (owner (gdev-workspace-state-ensure-id)))
    (with-current-buffer buffer
      (gdev-merge-preview-mode)
      (setq gdev-merge--owner owner
            gdev-merge--state 'pending
            buffer-read-only t))
    (gdev-workspace-state-set 'gdev-merge-preview buffer)
    (add-hook 'tab-bar-tab-pre-close-functions #'gdev-merge--close-workspace)
    (add-hook 'kill-emacs-query-functions #'gdev-merge--quit-check)
    buffer))

(defun gdev-merge--load (preview text)
  "Carica TEXT, il risultato iniziale, in PREVIEW."
  (with-current-buffer preview
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
      (erase-buffer)
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward smerge-begin-re nil t)
        (goto-char (match-beginning 0)))
      (setq gdev-merge--state 'ready buffer-read-only nil)
      (smerge-mode 1)
      (set-buffer-modified-p nil)
      (force-mode-line-update))))

(defun gdev-merge--conflict-document (source)
  "Copia il documento con conflitti SOURCE senza applicare modifiche."
  (let ((text (with-current-buffer source
                (unless (and buffer-file-name (> (gdev-merge--conflicts) 0))
                  (user-error "Il documento non contiene marcatori di conflitto"))
                (save-restriction
                  (widen)
                  (buffer-substring-no-properties (point-min) (point-max)))))
        (preview (gdev-merge--new-preview)))
    (with-current-buffer preview
      (setq gdev-merge--source source
            gdev-merge--source-file (buffer-file-name source)
            gdev-merge--source-tick (buffer-chars-modified-tick source)
            default-directory (buffer-local-value 'default-directory source)))
    (gdev-merge--load preview text)
    (gdev-merge-resume)
    preview))

(defun gdev-merge-conflict ()
  "Apri un'anteprima indipendente dei conflitti nel documento dell'editor."
  (interactive)
  (gdev-merge--conflict-document
   (or (gdev-editor-document) (user-error "Apri un documento con conflitti"))))

(defun gdev-merge-conflict-file (file)
  "Apri i conflitti testuali di FILE, anche partendo dallo stato di Hit."
  (unless (and (file-regular-p file) (file-readable-p file))
    (user-error "Il file selezionato non è leggibile"))
  (gdev-merge--conflict-document (find-file-noselect file)))

(defun gdev-merge--read-input (file)
  "Copia il testo di FILE da Emacs o dal disco."
  (if-let* ((live (find-buffer-visiting file)))
      (with-current-buffer live
        (save-restriction
          (widen)
          (buffer-substring-no-properties (point-min) (point-max))))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun gdev-merge--terminate-job (child preview directory stderr)
  "Ricevi il risultato di CHILD e rilascia DIRECTORY e i suoi buffer."
  (when (memq (process-status child) '(exit signal failed))
    (let ((output (process-buffer child)))
      (unwind-protect
          (when (and (gdev-merge--attached-p preview)
                     (eq 'pending (buffer-local-value 'gdev-merge--state preview)))
            (if (and (eq (process-status child) 'exit)
                     (<= 0 (process-exit-status child) 127)
                     ;; Un codice positivo senza conflitti indica un errore.
                     (or (= (process-exit-status child) 0)
                         (with-current-buffer output
                           (save-excursion
                             (goto-char (point-min))
                             (re-search-forward smerge-begin-re nil t)))))
                (gdev-merge--load preview (with-current-buffer output (buffer-string)))
              (with-current-buffer preview
                (let ((inhibit-read-only t))
                  (insert (propertize "Git non ha prodotto un risultato.\n" 'face 'gdev-ui-secondary))
                  (when (buffer-live-p stderr)
                    (insert (with-current-buffer stderr (buffer-string))))
                  (setq gdev-merge--state 'failed)
                  (force-mode-line-update)))))
        (dolist (buffer (list output stderr))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (remove-hook 'kill-emacs-hook (process-get child 'gdev-merge-cleanup))
        (delete-directory directory t)))))

(defun gdev-merge--start-job (git inputs preview)
  "Esegui GIT sui tre testi di INPUTS e pubblica in PREVIEW."
  (let ((directory (make-temp-file "gdev-unione-" t))
        (output (generate-new-buffer " *gdev-esito-unione*"))
        (stderr (generate-new-buffer " *gdev-errore-unione*"))
        child)
    (unwind-protect
        (let ((paths (mapcar (lambda (name)
                               (expand-file-name name directory))
                             '("superiore" "base" "inferiore")))
              (default-directory (file-name-as-directory directory))
              (coding-system-for-write 'utf-8-unix))
          (cl-mapc (lambda (text file) (write-region text nil file nil 'silent)) inputs paths)
          (setq child
                (make-process
                 :name "gdev-unione" :buffer output :stderr stderr :coding 'utf-8-unix
                 :command (append (list git "merge-file" "-p" "--diff3" "--marker-size=7"
                                        "-L" "Versione superiore" "-L" "Base comune"
                                        "-L" "Versione inferiore" "--") paths)
                 :connection-type 'pipe :noquery t
                 :sentinel (lambda (process _event)
                             (gdev-merge--terminate-job process preview directory stderr))))
          (let ((cleanup (lambda ()
                           (when (process-live-p child)
                             (delete-process child)))))
            (process-put child 'gdev-merge-cleanup cleanup)
            (add-hook 'kill-emacs-hook cleanup))
          (with-current-buffer preview (setq gdev-merge--process child)))
      (unless child
        (kill-buffer output)
        (kill-buffer stderr)
        (delete-directory directory t)))))

(defun gdev-merge-files (upper base lower)
  "Prepara l'unione di UPPER e LOWER a partire dalla BASE comune."
  (interactive
   (list (read-file-name "Versione superiore: " nil buffer-file-name t)
         (read-file-name "Base comune: " nil nil t)
         (read-file-name "Versione inferiore: " nil nil t)))
  (let* ((files (mapcar #'expand-file-name (list upper base lower)))
         (git (or (executable-find "git") (user-error "Git serve per unire tre file"))))
    (dolist (file files)
      (unless (and (not (file-remote-p file)) (file-regular-p file) (file-readable-p file))
        (user-error "Scegli un file locale leggibile: %s" file)))
    (let ((inputs (mapcar #'gdev-merge--read-input files))
          (directory (file-name-directory (car files))))
      (when (seq-some (lambda (text) (string-search "\0" text)) inputs)
        (user-error "L’unione è disponibile per i file di testo"))
      (let ((preview (gdev-merge--new-preview))
            started)
        (unwind-protect
            (progn
              (with-current-buffer preview (setq default-directory directory))
              (gdev-merge--start-job git inputs preview)
              (setq started t)
              (gdev-merge-resume)
              preview)
          (unless started (gdev-merge--complete preview)))))))

(provide 'gdev-merge)
;;; gdev-merge.el ends here
