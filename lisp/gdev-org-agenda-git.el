;;; gdev-org-agenda-git.el --- Attività Git nel calendario Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Legge in background la cronologia e il reflog del repository aperto.
;; Il calendario conserva il risultato dell'intervallo visibile fino a g.

;;; Code:

(require 'button)
(require 'calendar)
(require 'gdev-ui)
(require 'seq)
(require 'subr-x)

(declare-function gdev-org-calendar-redraw "gdev-org-calendar")
(declare-function magit-show-commit "magit-diff" (rev &optional args files module))
(declare-function magit-status "magit-status" (&optional directory cache))
(declare-function vc-dir "vc-dir" (directory &optional backend))
(defvar gdev-org-calendar-context-root)

(defconst gdev-org-agenda-git--read-limit 40
  "Numero massimo di record letti per ciascun flusso nell'intervallo.")
(defconst gdev-org-agenda-git--display-limit 8
  "Numero massimo di righe Git da mostrare nel calendario.")

(defvar-local gdev-org-agenda-git--process nil)
(defvar-local gdev-org-agenda-git--query nil)
(defvar-local gdev-org-agenda-git--callback nil)
(defvar-local gdev-org-agenda-git--data nil)

(defun gdev-org-agenda-git--cancel ()
  "Annulla la lettura in corso nel calendario corrente."
  (let ((process gdev-org-agenda-git--process))
    (setq gdev-org-agenda-git--process nil)
    (when (process-live-p process) (delete-process process))))

(defun gdev-org-agenda-git--run (git directory arguments continuation)
  "Esegui GIT con ARGUMENTS in DIRECTORY e passa l'uscita a CONTINUATION."
  (let ((owner (current-buffer))
        (output (generate-new-buffer " *gdev agenda git*"))
        (errors (generate-new-buffer " *gdev agenda git errori*"))
        (default-directory directory)
        (process-environment (copy-sequence process-environment)))
    (dolist (variable '("GIT_DIR" "GIT_WORK_TREE" "GIT_COMMON_DIR")) (setenv variable nil))
    (setenv "GIT_OPTIONAL_LOCKS" "0")
    (setenv "GIT_NO_LAZY_FETCH" "1")
    (condition-case nil
        (setq gdev-org-agenda-git--process
              (make-process
               :name "gdev-agenda-git" :buffer output :stderr errors
               :command (cons git arguments) :connection-type 'pipe
               :coding 'utf-8-unix :noquery t
               :sentinel
               (lambda (process _event)
                 (when (memq (process-status process) '(exit signal failed))
                   (unwind-protect
                       (when (buffer-live-p owner)
                         (with-current-buffer owner
                           (when (eq process gdev-org-agenda-git--process)
                             (setq gdev-org-agenda-git--process nil)
                             (funcall continuation (process-exit-status process)
                                      (if (buffer-live-p output)
                                          (with-current-buffer output (buffer-string)) "")))))
                     (dolist (buffer (list output errors))
                       (when (buffer-live-p buffer) (kill-buffer buffer))))))))
      (file-error
       (kill-buffer output)
       (kill-buffer errors)
       (funcall continuation nil "")))))

(defun gdev-org-agenda-git--record-text (text)
  "Rendi TEXT di Git leggibile su una sola riga."
  (replace-regexp-in-string "[[:cntrl:]]" " " text))

(defun gdev-org-agenda-git--records (text kind start end)
  "Leggi da TEXT i record di tipo KIND, tra START incluso ed END escluso."
  (let ((fields (split-string text "\0")) results)
    (while (and (cdr fields) (cddr fields) (cdddr fields))
      (let* ((hash (pop fields)) (date (pop fields))
             (subject (pop fields)) (author (pop fields))
             (seconds (if (eq kind 'commit) date
                        (and (string-match "@{\\([0-9]+\\)}\\'" date) (match-string 1 date))))
             (time (and seconds (string-to-number seconds))))
        (when (and time (<= start time) (< time end)
                   (string-match-p "\\`[[:xdigit:]]+\\'" hash))
          (push (list :kind kind :hash hash :time time
                      :subject (gdev-org-agenda-git--record-text subject)
                      :author (gdev-org-agenda-git--record-text author)) results))))
    (nreverse results)))

(defun gdev-org-agenda-git--operation (directory)
  "Descrivi l'operazione in corso nella directory dei dati Git DIRECTORY."
  (seq-some (pcase-lambda (`(,marker . ,label))
              (and (file-exists-p (expand-file-name marker directory)) label))
            '(("rebase-apply/applying" . "Applicazione patch in corso")
              ("rebase-apply" . "Rebase in corso")
              ("rebase-merge" . "Rebase in corso")
              ("MERGE_HEAD" . "Unione in corso")
              ("CHERRY_PICK_HEAD" . "Applicazione di commit in corso")
              ("REVERT_HEAD" . "Annullamento di commit in corso")
              ("sequencer/todo" . "Sequenza Git in corso")
              ("BISECT_START" . "Bisect in corso"))))

(defun gdev-org-agenda-git--finish (data)
  "Memorizza DATA e informa il calendario in attesa."
  (let ((callback gdev-org-agenda-git--callback))
    (setq gdev-org-agenda-git--data data
          gdev-org-agenda-git--callback nil)
    (when callback (funcall callback data))))

(defun gdev-org-agenda-git--read-history (git root git-directory branch start end)
  "Leggi la cronologia con GIT in ROOT tra START ed END.
GIT-DIRECTORY e BRANCH identificano il repository selezionato."
  (let ((limit (format "--max-count=%d" gdev-org-agenda-git--read-limit)))
    (gdev-org-agenda-git--run
     git root
     (list "log" "-z" "--no-show-signature" "--encoding=UTF-8"
           "--format=%H%x00%ct%x00%s%x00%an" limit
           (format "--since=@%d" start) (format "--until=@%d" end) "HEAD" "--")
     (lambda (status output)
       (let ((commits (and (eq status 0) (gdev-org-agenda-git--records output 'commit start end))))
         (gdev-org-agenda-git--run
          git root
          (list "log" "-g" "-z" "--no-show-signature" "--encoding=UTF-8" "--date=unix"
                "--format=%H%x00%gd%x00%gs%x00%gn" limit
                (format-time-string "HEAD@{%Y-%m-%d %H:%M:%S %z}" (seconds-to-time (1- end))) "--")
          (lambda (status output)
            (gdev-org-agenda-git--finish
             (list :root root :branch branch :operation (gdev-org-agenda-git--operation git-directory)
                   :commits commits
                   :actions (and (eq status 0) (gdev-org-agenda-git--records output 'action start end)))))))))))

(defun gdev-org-agenda-git--timestamp (date)
  "Restituisci i secondi Unix della mezzanotte locale del giorno assoluto DATE."
  (pcase-let ((`(,month ,day ,year) (calendar-gregorian-from-absolute date)))
    (time-convert (encode-time 0 0 0 day month year) 'integer)))

(defun gdev-org-agenda-git-request (directory start end callback &optional force)
  "Leggi Git per DIRECTORY tra i giorni assoluti START ed END escluso.
Chiama CALLBACK nel buffer corrente con i risultati. FORCE rilegge Git."
  (let ((query (list directory start end)))
    (if (and (not force) (equal gdev-org-agenda-git--query query))
        (if gdev-org-agenda-git--process
            (setq gdev-org-agenda-git--callback callback)
          (funcall callback gdev-org-agenda-git--data))
      (gdev-org-agenda-git--cancel)
      (unless (equal gdev-org-agenda-git--query query) (setq gdev-org-agenda-git--data nil))
      (setq gdev-org-agenda-git--query query
            gdev-org-agenda-git--callback callback)
      (if-let* (((and directory (not (file-remote-p directory)) (file-directory-p directory)))
                (git (executable-find "git")))
          (progn
            (add-hook 'kill-buffer-hook #'gdev-org-agenda-git--cancel nil t)
            (gdev-org-agenda-git--run
             git (file-name-as-directory directory)
             '("rev-parse" "--show-toplevel" "--absolute-git-dir" "--abbrev-ref" "HEAD" "--")
             (lambda (_status output)
               (pcase-let ((`(,root ,git-directory ,branch . ,_) (split-string output "\n" t)))
                 (if (and root git-directory (file-name-absolute-p root) (file-name-absolute-p git-directory))
                     (let* ((root (file-name-as-directory root))
                            (lower (gdev-org-agenda-git--timestamp start))
                            (upper (gdev-org-agenda-git--timestamp end))
                            (history (lambda (branch)
                                       (gdev-org-agenda-git--read-history git root git-directory branch lower upper))))
                       (if (and branch (not (equal branch "HEAD")))
                           (funcall history branch)
                         (gdev-org-agenda-git--run
                          git root '("symbolic-ref" "--quiet" "--short" "HEAD")
                          (lambda (status output)
                            (funcall history (if (eq status 0) (string-trim-right output) "HEAD separata"))))))
                   (gdev-org-agenda-git--finish nil))))))
        (gdev-org-agenda-git--finish nil)))))

(defun gdev-org-agenda-git-open-status (root)
  "Apri lo stato Git di ROOT con Hit, se disponibile."
  (if (fboundp 'magit-status) (magit-status root) (vc-dir root 'Git)))

(defun gdev-org-agenda-git-open-commit (root hash)
  "Apri il commit HASH di ROOT in Hit."
  (let ((default-directory root))
    (if (fboundp 'magit-show-commit)
        (magit-show-commit hash)
      (gdev-org-agenda-git-open-status root))))

(defun gdev-org-agenda-git--entries (data)
  "Combina e ordina gli elementi Git di DATA evitando le doppie registrazioni."
  (let* ((commits (plist-get data :commits))
         (hashes (mapcar (lambda (entry) (plist-get entry :hash)) commits))
         (actions (seq-remove (lambda (entry)
                                (and (member (plist-get entry :hash) hashes)
                                     (string-match-p "\\`commit\\(?: (initial)\\)?:"
                                                     (plist-get entry :subject))))
                              (plist-get data :actions))))
    (sort (append commits actions nil)
          (lambda (a b) (> (plist-get a :time) (plist-get b :time))))))

(defun gdev-org-agenda-git--measure (text)
  "Misura TEXT con il carattere del calendario."
  (if (display-graphic-p) (string-pixel-width text) (string-width text)))

(defun gdev-org-agenda-git--fit (text face width)
  "Mostra TEXT con FACE entro WIDTH e conserva il testo completo nell'aiuto."
  (propertize (gdev-ui-fit-text (propertize text 'face face) width
                               #'gdev-org-agenda-git--measure)
              'help-echo text))

(defun gdev-org-agenda-git--button (label width id action help)
  "Inserisci LABEL entro WIDTH con identità ID, ACTION e HELP."
  (let ((face '(gdev-ui-action variable-pitch)))
    (insert-text-button (gdev-org-agenda-git--fit label face width)
                        'type 'gdev-ui-action 'face face 'help-echo help
                        'gdev-org-calendar-item id 'action action)))

(defun gdev-org-agenda-git--goto-section (_button)
  "Porta il fuoco al comando Hit nella sezione Git dell'Agenda."
  (let ((target (save-excursion
                  (goto-char (point-min))
                  (text-property-search-forward 'gdev-org-calendar-item '(git status) #'equal))))
    (when target
      (goto-char (prop-match-beginning target))
      (when (eq (window-buffer (selected-window)) (current-buffer))
        (recenter 1)))))

(defun gdev-org-agenda-git-insert-summary (width start end)
  "Mostra il collegamento alla cronologia Git già letta fra START ed END.
WIDTH è la larghezza disponibile in pixel o, in un terminale, in colonne."
  (when (and (plist-get gdev-org-agenda-git--data :root)
             (equal gdev-org-agenda-git--query (list gdev-org-calendar-context-root start end)))
    (let* ((label (concat (gdev-ui-icon "git-history" "↶" nil 'gdev-ui-action)
                          " Attività Git"))
           (operation (plist-get gdev-org-agenda-git--data :operation))
           (action-width (gdev-org-agenda-git--measure
                          (propertize label 'face '(gdev-ui-action variable-pitch)))))
      (gdev-org-agenda-git--button label width '(git summary) #'gdev-org-agenda-git--goto-section
                                  "Vai alle attività Git del progetto")
      (when operation
        (let* ((separator "  ·  ")
               (space (- width action-width (gdev-org-agenda-git--measure separator)))
               (face '(gdev-ui-status-warning variable-pitch))
               (inline (<= (gdev-org-agenda-git--measure (propertize operation 'face face)) space)))
          (insert (if inline separator "\n")
                  (gdev-org-agenda-git--fit operation face (if inline space width)))))
      (insert "\n\n"))))

(defun gdev-org-agenda-git--action-title (subject)
  "Traduci le azioni comuni del reflog contenute in SUBJECT."
  (cond ((string-match "\\`checkout: moving from .* to \\(.*\\)\\'" subject)
         (concat "Cambio ramo · " (match-string 1 subject)))
        ((string-match "\\`reset: moving to \\(.*\\)\\'" subject)
         (concat "Ripristino a " (match-string 1 subject)))
        ((string-prefix-p "commit (amend): " subject)
         (concat "Commit modificato · " (substring subject (length "commit (amend): "))))
        ((string-match "\\`\\(pull\\|merge\\|rebase\\|reset\\|revert\\|cherry-pick\\)\\>" subject)
         (let ((label (cdr (assoc (match-string 1 subject)
                                 '(("pull" . "Aggiornamento") ("merge" . "Unione")
                                   ("rebase" . "Rebase") ("reset" . "Ripristino")
                                   ("revert" . "Annullamento commit")
                                   ("cherry-pick" . "Applicazione commit"))))))
           (concat label (substring subject (match-end 1)))))
        (t subject)))

(defun gdev-org-agenda-git--insert-entry (entry root width)
  "Mostra ENTRY di ROOT entro WIDTH con l'azione che apre il commit."
  (let* ((hash (plist-get entry :hash))
         (kind (plist-get entry :kind))
         (time (plist-get entry :time))
         (subject (plist-get entry :subject))
         (title (if (eq kind 'commit) subject (gdev-org-agenda-git--action-title subject)))
         (author (plist-get entry :author))
         (label (if (string-empty-p title) (substring hash 0 (min 8 (length hash))) title))
         (stamp (format-time-string "%d/%m · %H:%M" (seconds-to-time time)))
         (stamp-face '(gdev-ui-secondary fixed-pitch))
         (separator "   ")
         (available (- width (gdev-org-agenda-git--measure
                              (concat (propertize stamp 'face stamp-face) separator))))
         (inline (>= available (gdev-org-agenda-git--measure "wwww"))))
    (insert (gdev-org-agenda-git--fit stamp stamp-face width) (if inline separator "\n"))
    (gdev-org-agenda-git--button label (if inline available width) (list 'git kind hash time subject)
                                (lambda (_) (gdev-org-agenda-git-open-commit root hash))
                                (string-join (delq nil (list stamp label
                                                             (unless (string-empty-p author) author)))
                                             " · "))
    (insert "\n")))

(defun gdev-org-agenda-git--request-view (start end &optional force)
  "Aggiorna i dati Git della vista tra START ed END e, con FORCE, rileggili."
  (let ((starting t))
    (gdev-org-agenda-git-request
     gdev-org-calendar-context-root start end
     (lambda (_data) (unless starting (gdev-org-calendar-redraw))) force)
    (setq starting nil)))

(defun gdev-org-agenda-git-insert (start end)
  "Inserisci le attività Git per i giorni assoluti da START ad END escluso."
  (unless (equal gdev-org-agenda-git--query (list gdev-org-calendar-context-root start end))
    (gdev-org-agenda-git--request-view start end))
  (when-let* ((data gdev-org-agenda-git--data) (root (plist-get data :root)))
    (let* ((window (or (get-buffer-window (current-buffer)) (selected-window)))
           (width (max 1 (- (window-body-width window (display-graphic-p (window-frame window))) 2)))
           (heading (gdev-org-agenda-git--fit "Git del progetto" '(gdev-ui-view-heading variable-pitch) width))
           (label "Apri Hit")
           (separator "  ")
           (available (- width (gdev-org-agenda-git--measure (concat heading separator))))
           (inline (>= available (gdev-org-agenda-git--measure
                                   (propertize label 'face '(gdev-ui-action variable-pitch)))))
           (entries (gdev-org-agenda-git--entries data)))
      (insert "\n" heading (if inline separator "\n"))
      (gdev-org-agenda-git--button label (if inline available width) '(git status)
                                  (lambda (_) (gdev-org-agenda-git-open-status root))
                                  (concat "Apri Hit · " root))
      (insert "\n")
      (when-let* ((branch (plist-get data :branch)))
        (let ((text (concat "Ramo · " (gdev-org-agenda-git--record-text branch) "  ·  "
                            (gdev-org-agenda-git--record-text
                             (file-name-nondirectory (directory-file-name root))))))
          (insert (propertize (gdev-org-agenda-git--fit text '(gdev-ui-secondary variable-pitch) width)
                              'help-echo (concat text "\n" root)) "\n")))
      (when-let* ((operation (plist-get data :operation)))
        (insert (gdev-org-agenda-git--fit operation '(gdev-ui-status-warning variable-pitch) width) "\n"))
      (if entries
          (dolist (entry (seq-take entries gdev-org-agenda-git--display-limit))
            (gdev-org-agenda-git--insert-entry entry root width))
        (insert (gdev-org-agenda-git--fit "Nessuna attività Git nel periodo"
                                         '(gdev-ui-secondary variable-pitch) width) "\n"))
      (when (length> entries gdev-org-agenda-git--display-limit)
        (insert (gdev-org-agenda-git--fit "Altre attività in Hit"
                                         '(gdev-ui-secondary variable-pitch) width) "\n")))))

(defun gdev-org-agenda-git-refresh (start end)
  "Rileggi Git per i giorni assoluti da START ad END escluso."
  (gdev-org-agenda-git--request-view start end t))

(provide 'gdev-org-agenda-git)
;;; gdev-org-agenda-git.el ends here
