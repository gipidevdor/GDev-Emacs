;;; gdev-timeline.el --- Cronologia del file e copie locali -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Registra copie private dei salvataggi e interroga Git quando si apre
;; la cronologia del file. Il ripristino modifica il documento nell'editor.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'hl-line)
(require 'seq)
(require 'text-property-search)
(require 'gdev-context)
(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-compare-buffer-with-file "gdev-commands" (document file &optional label whole))
(declare-function gdev-comparison--start "gdev-commands" (function))
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(defvar ediff-quit-hook)

(defcustom gdev-timeline-local-history t
  "Conserva copie locali dei file salvati in GDev."
  :type 'boolean :group 'gdev)
(defcustom gdev-timeline-local-size-limit (* 256 1024)
  "Dimensione massima in byte di un file acquisito."
  :type 'natnum :group 'gdev)
(defcustom gdev-timeline-local-entry-limit 30
  "Numero massimo di salvataggi conservati per ogni file."
  :type 'natnum :group 'gdev)
(defcustom gdev-timeline-local-exclude gdev-sensitive-file-regexps
  "Espressioni regolari per i percorsi da escludere dalle copie locali.
Per impostazione predefinita sono quelle dei file con segreti."
  :type '(repeat regexp) :group 'gdev)

(defconst gdev-timeline--git-count 50)
(defconst gdev-timeline--git-bytes (* 8 1024 1024))
(defconst gdev-timeline--snapshot-name "^[0-9]\\{20\\}-[[:alnum:]]+\\'")

(cl-defstruct (gdev-timeline--entry (:constructor gdev-timeline--entry-create))
  source time title detail revision path)

(defvar-local gdev-timeline--file nil)
(defvar-local gdev-timeline--origin nil)
(defvar-local gdev-timeline--root nil)
(defvar-local gdev-timeline--filter 'all)
(defvar-local gdev-timeline--git-entries nil)
(defvar-local gdev-timeline--git-status nil)
(defvar-local gdev-timeline--log-job nil)
(defvar-local gdev-timeline--action-job nil)

(defun gdev-timeline--directory (file)
  "Risolvi la directory privata di FILE."
  (expand-file-name (secure-hash 'sha256 file) (gdev-state-file "cronologia/")))

(defun gdev-timeline--snapshots (directory)
  "Elenca le copie in DIRECTORY, dalla più recente."
  (when (file-directory-p directory)
    (nreverse (directory-files directory nil gdev-timeline--snapshot-name))))

(defun gdev-timeline--record (file source)
  "Acquisisci i byte di SOURCE per la cronologia di FILE."
  (when-let* ((attributes (file-attributes source))
              ((<= (file-attribute-size attributes) gdev-timeline-local-size-limit)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally source nil 0 (1+ gdev-timeline-local-size-limit))
      (when (<= (buffer-size) gdev-timeline-local-size-limit)
        (let* ((directory (gdev-timeline--directory file))
               (time (car (time-convert nil 1000000))))
          (with-file-modes #o700 (make-directory directory t))
          (let* ((temporary (make-temp-file (expand-file-name "in-corso-" directory)))
                 (suffix (substring (file-name-nondirectory temporary) (length "in-corso-")))
                 (snapshot (expand-file-name (format "%020d-%s" time suffix) directory))
                 (coding-system-for-write 'no-conversion))
            (unwind-protect
                (progn
                  (write-region (point-min) (point-max) temporary nil 'silent)
                  (rename-file temporary snapshot))
              (when (file-exists-p temporary) (delete-file temporary))))
          (dolist (old (nthcdr gdev-timeline-local-entry-limit
                               (gdev-timeline--snapshots directory)))
            (ignore-error file-missing (delete-file (expand-file-name old directory))))
          t)))))

(defun gdev-timeline--excluded-p (file)
  "Indica se FILE deve restare escluso dalle copie locali."
  (or (file-remote-p file)
      (find-file-name-handler file 'insert-file-contents)
      (seq-some (lambda (pattern) (string-match-p pattern file))
                gdev-timeline-local-exclude)))

(defun gdev-timeline-record ()
  "Registra l'ultimo salvataggio del buffer corrente, se consentito."
  (when (and gdev-timeline-local-history buffer-file-name
             (> gdev-timeline-local-entry-limit 0)
             (not (gdev-timeline--excluded-p buffer-file-name)))
    (condition-case err
        (let* ((file buffer-file-name)
               (source (file-truename file)))
          (when (and (or (equal source file) (not (gdev-timeline--excluded-p source)))
                     (file-regular-p source)
                     (gdev-timeline--record file source))
            (let ((view (gdev-workspace-state-get 'gdev-timeline-buffer)))
              (when (buffer-live-p view)
                (with-current-buffer view
                  (when (equal file gdev-timeline--file) (gdev-timeline--render)))))))
      (file-error (message "Cronologia locale: %s" (error-message-string err))))))

(defun gdev-timeline--local-entries ()
  "Leggi le date delle copie del file mostrato."
  (let ((directory (gdev-timeline--directory gdev-timeline--file)))
    (mapcar (lambda (name)
              (gdev-timeline--entry-create
               :source 'local :time (cons (string-to-number name) 1000000)
               :title "Salvataggio locale" :path (expand-file-name name directory)))
            (gdev-timeline--snapshots directory))))

(defun gdev-timeline--git-parse (text)
  "Interpreta i record NUL di Git in TEXT, comprese le rinomine."
  (let ((fields (split-string text "\0")) entries)
    (while fields
      (let ((revision (pop fields)))
        (unless (string-empty-p revision)
          (let* ((time (string-to-number (pop fields)))
                 (title (pop fields))
                 (author (pop fields))
                 (status (string-trim-left (or (pop fields) "")))
                 (path (pop fields))
                 (deleted (string-prefix-p "D" status)))
            (when (string-match-p "^[RC]" status) (setq path (pop fields)))
            (when (and path (string-match-p "^[0-9a-f]\\{40,64\\}\\'" revision))
              (push (gdev-timeline--entry-create
                     :source 'git :time time :title (if (string-empty-p title) "Registrazione Git" title)
                     :detail (format "%s · %s%s" (substring revision 0 8)
                                     author (if deleted " · prima dell’eliminazione" ""))
                     :revision (if deleted (concat revision "^") revision) :path path)
                    entries))))))
    (nreverse entries)))

(defun gdev-timeline--tab ()
  "Ritrova la scheda proprietaria della vista, anche dopo un trasferimento."
  (let ((view (current-buffer)))
    (cl-loop for frame in (frame-list)
             for tab = (gdev-workspace-state-find gdev-timeline--origin frame)
             when (eq view (gdev-workspace-state-read 'gdev-timeline-buffer tab))
             return tab)))

(defun gdev-timeline--cancel (slot)
  "Invalida e interrompi il processo in SLOT."
  (let ((process (symbol-value slot)))
    (set slot nil)
    (when (process-live-p process) (delete-process process))))

(defun gdev-timeline--run (slot arguments coding receive)
  "Esegui Git con ARGUMENTS in SLOT e consegna l'uscita a RECEIVE.
CODING indica come decodificare i byte in uscita."
  (gdev-timeline--cancel slot)
  (let* ((view (current-buffer))
         (default-directory gdev-timeline--root)
         (command (append (list (or (executable-find "git") (user-error "Git non è disponibile"))
                                "--no-pager" "--literal-pathspecs") arguments))
         (output (generate-new-buffer " *GDev cronologia Git*"))
         (errors (generate-new-buffer " *GDev cronologia errori*"))
         (bytes 0)
         process)
    (unwind-protect
        (progn
          (with-current-buffer output (set-buffer-multibyte (not (eq coding 'no-conversion))))
          (setq process
                (make-process
                 :name "gdev-cronologia-git" :command command
                 :connection-type 'pipe :buffer output :stderr errors :coding coding :noquery t
                 :filter (lambda (job chunk)
                           (cl-incf bytes (string-bytes chunk))
                           (if (> bytes gdev-timeline--git-bytes)
                               (progn (process-put job 'gdev-timeline-limit t)
                                      (delete-process job))
                             (with-current-buffer output
                               (goto-char (point-max))
                               (insert chunk))))
                 :sentinel
                 (lambda (job _event)
                   (when (memq (process-status job) '(exit signal failed))
                     (unwind-protect
                         (when (buffer-live-p view)
                           (with-current-buffer view
                             (when (eq job (symbol-value slot))
                               (set slot nil)
                               (when (gdev-timeline--tab)
                                 (let* ((limit (process-get job 'gdev-timeline-limit))
                                        (success (and (not limit) (zerop (process-exit-status job)))))
                                   (condition-case err
                                       (funcall receive (and success (with-current-buffer output (buffer-string))) limit)
                                     (error (message "Cronologia: %s" (error-message-string err)))))))))
                       (when (buffer-live-p output) (kill-buffer output))
                       (when (buffer-live-p errors) (kill-buffer errors)))))))
          (set slot process))
      (unless process
        (kill-buffer output)
        (kill-buffer errors)))))

(defun gdev-timeline--entry-at-point ()
  "Restituisci l'evento della riga corrente."
  (get-text-property (point) 'gdev-timeline-entry))

(defun gdev-timeline--entry ()
  "Restituisci l'evento al cursore o chiedi di sceglierne uno."
  (or (gdev-timeline--entry-at-point) (user-error "Seleziona una versione nella cronologia")))

(defconst gdev-timeline--filters '((all . "Tutte") (local . "Salvataggi") (git . "Git")))

(defun gdev-timeline--apply-filter (filter)
  "Mostra le versioni ammesse da FILTER."
  (setq gdev-timeline--filter filter)
  (gdev-timeline--render))

(defun gdev-timeline-filter ()
  "Scegli le origini da mostrare nella cronologia."
  (interactive)
  (let ((label (completing-read "Origine delle versioni: " (mapcar #'cdr gdev-timeline--filters)
                                nil t nil nil (alist-get gdev-timeline--filter gdev-timeline--filters))))
    (gdev-timeline--apply-filter (car (rassoc label gdev-timeline--filters)))))

(defun gdev-timeline--entries (filter)
  "Elenca le versioni ammesse da FILTER, a partire dalla più recente."
  (sort (append (unless (eq filter 'git) (gdev-timeline--local-entries))
                (unless (eq filter 'local) (copy-sequence gdev-timeline--git-entries)))
        (lambda (a b) (time-less-p (gdev-timeline--entry-time b)
                                   (gdev-timeline--entry-time a)))))

(defun gdev-timeline--render ()
  "Ridisegna la vista mantenendo l'evento selezionato."
  (let* ((selection (gdev-timeline--entry-at-point))
         (filter gdev-timeline--filter)
         (entries (gdev-timeline--entries filter))
         (status (unless (eq filter 'local) gdev-timeline--git-status))
         (inhibit-read-only t)
         (starts (gdev-ui-window-starts))
         first selected)
    (erase-buffer)
    (insert (propertize "Cronologia del file" 'face 'gdev-ui-view-title) "\n"
            (propertize (file-name-nondirectory gdev-timeline--file)
                        'face 'gdev-ui-secondary 'help-echo gdev-timeline--file)
            "\n\n")
    (dolist (choice gdev-timeline--filters)
      (let ((filter-choice (car choice)))
        (unless (eq filter-choice 'all) (insert "   "))
        (insert-text-button
         (cdr choice) 'type 'gdev-ui-action
         'face (if (eq filter filter-choice) 'gdev-ui-action-primary 'gdev-ui-action)
         'action (lambda (_) (gdev-timeline--apply-filter filter-choice)))))
    (insert "\n\n")
    (when status (insert (propertize status 'face 'gdev-ui-secondary) "\n\n"))
    (dolist (entry entries)
      (let* ((start (point))
             (title (replace-regexp-in-string "[[:cntrl:]]" " " (gdev-timeline--entry-title entry)))
             (detail (format "%s%s" (format-time-string "%d/%m/%Y %H:%M:%S" (gdev-timeline--entry-time entry))
                             (if-let* ((text (gdev-timeline--entry-detail entry)))
                                 (concat " · Git · " (replace-regexp-in-string "[[:cntrl:]]" " " text)) ""))))
        (unless first (setq first start))
        (when (equal selection entry) (setq selected start))
        (insert-text-button title 'type 'gdev-ui-action
                            'help-echo (concat title "\n" detail)
                            'action (lambda (_) (gdev-timeline--compare entry)))
        (insert "\n" (propertize detail 'face 'gdev-ui-secondary) "\n")
        (put-text-property start (point) 'gdev-timeline-entry entry)
        (insert "\n")))
    (unless (or entries status)
      (insert (propertize "Nessuna versione disponibile." 'face 'gdev-ui-secondary) "\n"))
    (goto-char (or selected first (point-min)))
    (gdev-ui-restore-windows starts)))

(defun gdev-timeline-refresh ()
  "Rileggi le copie locali e avvia in background la cronologia Git."
  (interactive)
  (gdev-timeline--cancel 'gdev-timeline--log-job)
  (let* ((file gdev-timeline--file)
         (git (executable-find "git"))
         (root (locate-dominating-file (file-name-directory file) ".git")))
    (setq gdev-timeline--root root
          gdev-timeline--git-status
          (cond ((not root) "Il file è fuori da un repository Git.")
                ((not git) "Git non è disponibile.")
                (t "Lettura della cronologia Git…")))
    (gdev-timeline--render)
    (when (and root git)
      (gdev-timeline--run
       'gdev-timeline--log-job
       (list "log" "-n" (number-to-string gdev-timeline--git-count)
             "--follow" "--no-show-signature" "--no-color"
             "--name-status" "-z" "--format=%x00%H%x00%ct%x00%s%x00%an"
             "--" (file-relative-name file root))
       'utf-8-unix
       (lambda (output limit)
         (setq gdev-timeline--git-entries (and output (gdev-timeline--git-parse output))
               gdev-timeline--git-status
               (cond (limit "La cronologia Git supera il limite di lettura.")
                     ((not output) "Impossibile leggere la cronologia Git.")
                     ((not gdev-timeline--git-entries) "Nessuna registrazione Git per il file.")))
         (gdev-timeline--render))))))

(defun gdev-timeline--with-version (entry action)
  "Passa ad ACTION il file della versione ENTRY."
  (if (eq (gdev-timeline--entry-source entry) 'local)
      (let ((path (gdev-timeline--entry-path entry)))
        (unless (file-readable-p path) (user-error "La copia locale è scaduta. Aggiorna la cronologia"))
        (funcall action path))
    (unless gdev-timeline--root (user-error "Il repository Git non è disponibile"))
    (let ((view (current-buffer))
          (window (selected-window)))
      (gdev-timeline--run
       'gdev-timeline--action-job
       (list "show" "--no-textconv" "--no-color"
             (concat (gdev-timeline--entry-revision entry) ":" (gdev-timeline--entry-path entry)))
       'no-conversion
       (lambda (output limit)
         (when (and (eq window (selected-window)) (eq view (window-buffer window)))
           (unless output
             (user-error (if limit "La versione Git supera il limite di 8 MiB"
                           "Non è possibile leggere questa versione Git")))
           (let ((file (make-temp-file "gdev-cronologia-"))
                 (coding-system-for-write 'no-conversion))
             (unwind-protect
                 (progn
                   (write-region output nil file nil 'silent)
                   (funcall action file))
               (delete-file file)))))))))

(defun gdev-timeline--compare (entry)
  "Confronta ENTRY con il documento associato, incluse le modifiche in corso."
  (let ((file gdev-timeline--file))
    (gdev-timeline--with-version
     entry
     (lambda (snapshot)
       (unless (or (find-buffer-visiting file) (file-exists-p file))
         (user-error "Il file è assente. Apri o ripristina la versione selezionata"))
       (gdev-compare-buffer-with-file
        (find-file-noselect file) snapshot
        (format-time-string "Versione del %d/%m/%Y %H:%M:%S" (gdev-timeline--entry-time entry)) t)))))

(defun gdev-timeline-compare ()
  "Confronta la versione selezionata con il documento corrente."
  (interactive)
  (gdev-timeline--compare (gdev-timeline--entry)))

(define-derived-mode gdev-timeline-revision-mode fundamental-mode "Versione del file"
  "Mostra il contenuto storico del documento in sola lettura."
  (gdev-ui-view-setup 'native)
  (setq buffer-read-only t))

(defun gdev-timeline--revision-buffer (file entry insert-content)
  "Prepara una vista di ENTRY di FILE riempita da INSERT-CONTENT."
  (let ((view (generate-new-buffer (format "%s · %s" (file-name-nondirectory file)
                                          (format-time-string "%d/%m %H:%M:%S"
                                                              (gdev-timeline--entry-time entry))))))
    (condition-case err
        (progn
          (with-current-buffer view
            (funcall insert-content)
            (gdev-timeline-revision-mode)
            (gdev-layout-mark-document)
            (set-buffer-modified-p nil))
          view)
      ((error quit) (kill-buffer view) (signal (car err) (cdr err))))))

(defun gdev-timeline-visit ()
  "Apri la versione selezionata in sola lettura."
  (interactive)
  (let ((entry (gdev-timeline--entry)) (file gdev-timeline--file))
    (gdev-timeline--with-version
     entry
     (lambda (snapshot)
       (let ((view (gdev-timeline--revision-buffer file entry
                                                  (lambda () (insert-file-contents snapshot)))))
         (condition-case err
             (pop-to-buffer view)
           ((error quit) (kill-buffer view) (signal (car err) (cdr err)))))))))

(defun gdev-timeline--compare-pair (file left text right snapshot)
  "Confronta TEXT di LEFT con lo SNAPSHOT di RIGHT per FILE."
  (let (a b control)
    (cl-labels ((release ()
                  (dolist (buffer (list a b))
                    (when (and (buffer-live-p buffer) (not (buffer-modified-p buffer)))
                      (kill-buffer buffer)))))
      (unwind-protect
          (progn
            (setq a (gdev-timeline--revision-buffer file left (lambda () (insert text)))
                  b (gdev-timeline--revision-buffer file right (lambda () (insert-file-contents snapshot)))
                  control
                  (gdev-comparison--start
                   (lambda (setup)
                     (ediff-buffers a b
                                    (list setup
                                          (lambda ()
                                            (add-hook 'ediff-quit-hook #'release 'append t))))))))
        (unless control (release))))))

(defun gdev-timeline-compare-versions ()
  "Confronta la versione indicata con un'altra voce della cronologia."
  (interactive)
  (let* ((view (current-buffer))
         (window (selected-window))
         (origin (gdev-workspace-state-id))
         (file gdev-timeline--file)
         (left (gdev-timeline--entry))
         (entries (remove left (gdev-timeline--entries 'all)))
         (choices
          (cl-loop for entry in entries for index from 1
                   collect
                   (cons (format "%s · %s · %d"
                                 (format-time-string "%d/%m/%Y %H:%M:%S"
                                                     (gdev-timeline--entry-time entry))
                                 (replace-regexp-in-string "[[:cntrl:]]" " "
                                                           (gdev-timeline--entry-title entry))
                                 index)
                         entry))))
    (unless choices (user-error "Serve un'altra versione da confrontare"))
    (let ((right (cdr (assoc (completing-read "Versione da mettere a destra: " choices nil t)
                            choices))))
      (unless (and right (eq window (selected-window)) (eq view (window-buffer window))
                   (eq origin (gdev-workspace-state-id))
                   (with-current-buffer view
                     (and (equal file gdev-timeline--file)
                          (equal left (gdev-timeline--entry-at-point)))))
        (user-error "La cronologia o la selezione è cambiata. Riapri il confronto"))
      (gdev-timeline--with-version
       left
       (lambda (snapshot)
         (let ((text (with-temp-buffer (insert-file-contents snapshot) (buffer-string))))
           (gdev-timeline--with-version
            right (lambda (other) (gdev-timeline--compare-pair file left text right other)))))))))

(defun gdev-timeline--restore-target (file)
  "Identifica il documento di FILE e la sua revisione in memoria e su disco."
  (let ((document (find-buffer-visiting file))
        (attributes (file-attributes (file-truename file) 'integer)))
    (list document (and document (buffer-chars-modified-tick document))
          (when attributes
            (list (file-attribute-file-identifier attributes)
                  (file-attribute-modification-time attributes)
                  (file-attribute-size attributes))))))

(defun gdev-timeline-restore ()
  "Riporta la versione selezionata nell'editor, con un annullamento unico."
  (interactive)
  (let ((file gdev-timeline--file)
        (view (current-buffer))
        (frame (selected-frame))
        (origin gdev-timeline--origin))
    (gdev-timeline--with-version
     (gdev-timeline--entry)
     (lambda (snapshot)
       (let ((target (gdev-timeline--restore-target file)))
         (when (yes-or-no-p (format "Ripristinare «%s» nell’editor?" (file-name-nondirectory file)))
           (unless (and (eq frame (selected-frame))
                        (eq origin (gdev-workspace-state-id frame))
                        (eq view (gdev-workspace-state-get 'gdev-timeline-buffer frame))
                        (buffer-live-p view)
                        (equal file (buffer-local-value 'gdev-timeline--file view)))
             (user-error "La vista o lo spazio di lavoro è cambiato. Riapri la cronologia"))
           (unless (equal target (gdev-timeline--restore-target file))
             (user-error "Il documento è cambiato. Scegli di nuovo la versione da ripristinare"))
           (let ((document (or (car target) (find-file-noselect file))))
             (with-temp-buffer
               (insert-file-contents snapshot)
               (let ((source (current-buffer)))
                 (with-current-buffer document
                   (barf-if-buffer-read-only)
                   (save-restriction
                     (widen)
                     (undo-boundary)
                     ;; Questa firma è disponibile anche in Emacs 30.
                     (with-suppressed-warnings ((obsolete replace-buffer-contents))
                       (atomic-change-group (replace-buffer-contents source 0.05)))
                     (unless (file-exists-p file) (set-buffer-modified-p t))
                     (undo-boundary)))))
             (gdev-open-file file))))))))

(defun gdev-timeline-move (step)
  "Vai alla versione successiva o precedente secondo il segno di STEP."
  (let* ((entry (gdev-timeline--entry-at-point))
         (target (save-excursion
                   (if (> step 0)
                       (progn
                         (when entry
                           (goto-char (next-single-property-change (point) 'gdev-timeline-entry)))
                         (text-property-search-forward 'gdev-timeline-entry))
                     (when entry
                       (goto-char (previous-single-property-change (1+ (point)) 'gdev-timeline-entry)))
                     (text-property-search-backward 'gdev-timeline-entry)))))
    (when target (goto-char (prop-match-beginning target)))))

(defvar-keymap gdev-timeline-mode-map
  :parent special-mode-map
  "RET" #'gdev-timeline-compare
  "c" #'gdev-timeline-compare-versions
  "v" #'gdev-timeline-visit
  "r" #'gdev-timeline-restore
  "f" #'gdev-timeline-filter
  "n" (lambda () (interactive) (gdev-timeline-move 1))
  "p" (lambda () (interactive) (gdev-timeline-move -1))
  "g" #'gdev-timeline-refresh)

(define-derived-mode gdev-timeline-mode special-mode "Cronologia"
  "Esplora i salvataggi e le registrazioni Git del file."
  (gdev-ui-view-setup 'document)
  (setq-local truncate-lines t
              hl-line-face 'gdev-ui-side-selection)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (gdev-timeline--cancel 'gdev-timeline--log-job)
              (gdev-timeline--cancel 'gdev-timeline--action-job)) nil t))

(gdev-set-popup-rule '(derived-mode . gdev-timeline-mode))

(defun gdev-timeline-open (&optional file)
  "Mostra la cronologia di FILE o del documento indicato."
  (interactive (list (when current-prefix-arg (read-file-name "Cronologia del file: "))))
  (let* ((file (expand-file-name
                (or file (gdev-context--timeline-target) (user-error "Indica un file locale"))))
         (origin (gdev-workspace-state-ensure-id))
         (view (gdev-workspace-state-get 'gdev-timeline-buffer)))
    (when (or (file-remote-p file) (file-directory-p file)) (user-error "Indica un file locale"))
    (unless (buffer-live-p view)
      (setq view (generate-new-buffer "*Cronologia del file*"))
      (gdev-workspace-state-set 'gdev-timeline-buffer view))
    (with-current-buffer view
      (unless (derived-mode-p 'gdev-timeline-mode) (gdev-timeline-mode))
      (unless (equal gdev-timeline--file file)
        (gdev-timeline--cancel 'gdev-timeline--action-job)
        (setq gdev-timeline--file file gdev-timeline--git-entries nil
              default-directory (file-name-directory file)))
      (setq gdev-timeline--origin origin)
      (gdev-timeline-refresh))
    (pop-to-buffer view)))

(provide 'gdev-timeline)
;;; gdev-timeline.el ends here
