;;; gdev-search.el --- Ricerca persistente nei file del progetto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La vista conserva risultati, filtri e selezione nello spazio di lavoro.
;; Ripgrep aggiorna i risultati su disco in sottofondo mentre la vista è aperta.
;; Le sostituzioni passano per un'anteprima del testo e modificano i documenti
;; aperti nell'editor, dove rimangono annullabili.

;;; Code:

(require 'gdev-activity)
(require 'gdev-commands)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)
(require 'gdev-operation-history)
(require 'button)
(require 'diff-mode)
(require 'json)

(cl-defstruct gdev-search-hit file line ranges source marked)
(cl-defstruct gdev-search-plan file paths tick attributes lines)

(defcustom gdev-search-max-results 2000
  "Numero massimo di righe mostrate in Cerca."
  :type 'natnum
  :group 'gdev)

(defconst gdev-search--max-record-length (* 64 1024)
  "Limite per un record JSON di ripgrep, in caratteri.")

(defconst gdev-search--batch-records 128
  "Numero massimo di record esaminati in un turno.")

(defconst gdev-search--batch-time 0.004
  "Secondi destinati a un turno di lettura dei risultati.")

(defcustom gdev-search-refresh-interval 3
  "Secondi tra le ricerche automatiche mentre Cerca è visibile.
Un valore zero disattiva l'aggiornamento automatico."
  :type 'natnum
  :group 'gdev)

(defvar-local gdev-search--query "")
(defvar-local gdev-search--roots nil)
(defvar-local gdev-search--include "")
(defvar-local gdev-search--exclude "")
(defvar-local gdev-search--regexp nil)
(defvar-local gdev-search--case-sensitive nil)
(defvar-local gdev-search--whole-word nil)
(defvar-local gdev-search--include-ignored nil)
(defvar-local gdev-search--process nil)
(defvar-local gdev-search--refresh-timer nil)
(defvar-local gdev-search--awaiting-save nil)
(defvar-local gdev-search--ordered nil)
(defvar-local gdev-search--results nil)
(defvar-local gdev-search--results-by-file nil)
(defvar gdev-search-results-change-hook nil
  "Hook eseguito nella vista dopo la pubblicazione dei risultati di Cerca.")
(defvar-local gdev-search--status nil)
(defvar-local gdev-search--replacement "")
(defvar-local gdev-search--preview nil)
(defvar-local gdev-search--plan nil)
(defvar-local gdev-search--render-geometry nil)

(defvar-keymap gdev-search--query-map
  "<escape>" #'abort-recursive-edit)

(defvar-keymap gdev-search-mode-map
  :parent special-mode-map
  "s" #'gdev-search-query
  "f" #'gdev-search-filters
  "r" #'gdev-search-toggle-regexp
  "c" #'gdev-search-toggle-case
  "w" #'gdev-search-toggle-word
  "i" #'gdev-search-toggle-ignored
  "SPC" #'gdev-search-toggle-hit
  "m" #'gdev-search-toggle-all
  "RET" #'gdev-search-visit
  "v" #'gdev-search-preview
  "a" #'gdev-search-apply
  "n" #'gdev-search-next-hit
  "p" #'gdev-search-previous-hit
  "<down>" #'gdev-search-next-hit
  "<up>" #'gdev-search-previous-hit
  "g" #'gdev-search-repeat
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-search-mode special-mode "Cerca"
  "Vista di ricerca e sostituzione nei file del progetto."
  (gdev-ui-view-setup 'sidebar)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook #'gdev-search--kill nil t)
  (add-hook 'change-major-mode-hook #'gdev-search--kill nil t)
  (add-hook 'window-buffer-change-functions #'gdev-search--window-changed nil t)
  (add-hook 'pre-redisplay-functions #'gdev-search--resize nil t)
  (gdev-search--reset (gdev-search--scope))
  (gdev-search--render))

(defun gdev-search--root ()
  "Restituisce la radice del progetto del documento attivo, se esiste."
  (when-let* ((editor (gdev-layout-editor)))
    (with-current-buffer (window-buffer editor)
      (when-let* ((project (project-current nil)))
        (file-name-as-directory (expand-file-name (project-root project)))))))

(defun gdev-search--scope ()
  "Restituisce le cartelle da cercare nello spazio di lavoro attivo."
  (or (gdev-workspace-roots)
      (when-let* ((root (gdev-search--root))) (list root))))

(defun gdev-search--host (roots)
  "Verifica che ROOTS siano sulla stessa macchina e restituisce l'host remoto."
  (let ((host (file-remote-p (car roots))))
    (unless (seq-every-p (lambda (directory) (equal (file-remote-p directory) host)) roots)
      (user-error "Cerca nelle cartelle di una sola macchina alla volta"))
    host))

(defun gdev-search-buffer ()
  "Restituisce la vista Cerca dello spazio corrente."
  (let ((buffer (gdev-activity-buffer 'search "*Cerca nel progetto*" #'gdev-search-mode)))
    (with-current-buffer buffer
      (let ((roots (gdev-search--scope)))
        (unless (equal gdev-search--roots roots)
          (gdev-search--reset roots)
          (setq gdev-search--status (unless (string-empty-p gdev-search--query) "Cartelle aggiornate."))
          (gdev-search--render))))
    buffer))

(defun gdev-search-show (&optional query)
  "Apre Cerca e, se fornita, avvia QUERY."
  (interactive)
  (let ((buffer (gdev-search-buffer)))
    (gdev-activity-display buffer 'search)
    (with-current-buffer buffer
      (if query
          (gdev-search--start query)
        (gdev-search--schedule-refresh 0.2)))
    buffer))

(defun gdev-search-document-hits (frame file &optional alias)
  "Leggi le righe già pubblicate per FILE o ALIAS nello spazio di FRAME.
La lista restituita è ordinata per riga e va trattata come sola lettura."
  (when-let* ((view (alist-get 'search (gdev-workspace-state-get 'gdev-activity-buffers frame)))
              ((buffer-live-p view)))
    (with-current-buffer view
      (when gdev-search--results
        (unless (eq (car gdev-search--results-by-file) gdev-search--results)
          (let ((files (make-hash-table :test #'equal)))
            (dolist (hit gdev-search--results)
              (push hit (gethash (gdev-search-hit-file hit) files)))
            (maphash (lambda (path hits) (puthash path (nreverse hits) files)) files)
            (setq gdev-search--results-by-file (cons gdev-search--results files))))
        (let ((files (cdr gdev-search--results-by-file)))
          (or (gethash file files) (and alias (gethash alias files))))))))

(defun gdev-search--set-results (hits)
  "Pubblica HITS e invalida l'indice di consultazione della vista."
  (unless (eq hits gdev-search--results)
    (setq gdev-search--results hits gdev-search--results-by-file nil)
    (run-hooks 'gdev-search-results-change-hook)))

(defun gdev-search--kill ()
  "Chiude il processo, il timer e l'anteprima di questa vista."
  (gdev-search--cancel-refresh)
  (gdev-search--stop-process)
  (let ((preview gdev-search--preview))
    (setq gdev-search--preview nil)
    (when (buffer-live-p preview) (kill-buffer preview))))

(defun gdev-search--stop-process ()
  "Libera il processo corrente senza pubblicarne l'uscita."
  (let ((process gdev-search--process))
    (setq gdev-search--process nil)
    (when process
      (when (process-live-p process) (delete-process process))
      (gdev-search--release-process process))))

(defun gdev-search--release-process (process)
  "Elimina i timer e i buffer temporanei di PROCESS."
  (dolist (property '(drain-timer preview-timer))
    (when-let* ((timer (process-get process property)))
      (cancel-timer timer)
      (process-put process property nil)))
  (dolist (buffer (list (process-buffer process) (process-get process 'errors)))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun gdev-search--cancel-refresh ()
  "Ferma il timer di aggiornamento della vista corrente."
  (when gdev-search--refresh-timer
    (cancel-timer gdev-search--refresh-timer)
    (setq gdev-search--refresh-timer nil)))

(defun gdev-search--schedule-refresh (&optional delay)
  "Aggiorna una ricerca visibile dopo DELAY secondi o l'intervallo configurato."
  (when (and (> gdev-search-refresh-interval 0)
             gdev-search--roots
             (not gdev-search--refresh-timer)
             (not gdev-search--process)
             (not (string-empty-p gdev-search--query))
             (get-buffer-window (current-buffer) 'visible))
    (setq gdev-search--refresh-timer
          (run-at-time (or delay gdev-search-refresh-interval) nil
                       #'gdev-search--refresh (current-buffer)))))

(defun gdev-search--window-changed (window)
  "Sospende gli aggiornamenti quando la vista scompare e li riprende al ritorno."
  (if-let* ((visible (or (and (window-live-p window) (eq (window-buffer window) (current-buffer)) window)
                         (get-buffer-window (current-buffer) 'visible))))
      (progn
        (gdev-search--resize visible)
        (gdev-search--schedule-refresh 0.2))
    (gdev-search--cancel-refresh)
    (when (and gdev-search--process (process-get gdev-search--process 'refresh))
      (gdev-search--stop-process))))

(defun gdev-search--refresh (buffer)
  "Aggiorna in sottofondo la ricerca visibile di BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq gdev-search--refresh-timer nil)
      (when-let* ((window (get-buffer-window buffer 'visible))
                  ((> gdev-search-refresh-interval 0))
                  ((not (string-empty-p gdev-search--query))))
        (let ((roots (or (gdev-workspace-roots (window-frame window)) gdev-search--roots)))
          (condition-case err
              (cond ((null roots) nil)
                    ;; Con Emacs in secondo piano nessun processo parte: si riprova più tardi.
                    ((and (display-graphic-p (window-frame window))
                          (not (eq (frame-focus-state (window-frame window)) t)))
                     (gdev-search--schedule-refresh))
                    ((not (equal roots gdev-search--roots))
                     (gdev-search--start gdev-search--query roots))
                    ((not gdev-search--process)
                     (setq gdev-search--awaiting-save
                           (seq-filter (lambda (document)
                                         (and (buffer-live-p (car document))
                                              (buffer-modified-p (car document))))
                                       gdev-search--awaiting-save))
                     (gdev-search--launch t)))
            (error
             (unless (equal roots gdev-search--roots) (gdev-search--reset roots))
             (gdev-search--set-status (error-message-string err)))))
        (gdev-search--schedule-refresh)))))

(defun gdev-search--measure (text)
  "Misura TEXT con il carattere della vista, in pixel o in colonne."
  (if (display-graphic-p) (gdev-ui-string-pixel-width text) (string-width text)))

(defun gdev-search--fit (text width)
  "Adatta TEXT a WIDTH conservando le facce."
  (gdev-ui-fit-text text (max 0 width) #'gdev-search--measure))

(defun gdev-search--one-line (text)
  "Appiattisci TEXT conservando l'indice dei suoi caratteri."
  (if (string-match-p "[[:cntrl:]]" text)
      (replace-regexp-in-string "[[:cntrl:]]" " " text t t)
    text))

(defun gdev-search--line (label face width &optional help file-name)
  "Inserisci LABEL in FACE entro WIDTH, mantenendo HELP.
Con FILE-NAME mantieni visibile l'estensione quando entra.
Restituisci il testo visibile con la sua faccia."
  (let* ((text (propertize (gdev-search--one-line label) 'face face))
         (visible (if file-name
                      (gdev-ui-fit-file-name text width #'gdev-search--measure)
                    (gdev-search--fit text width))))
    (insert "  " (propertize visible 'help-echo (or help label)) "\n")
    visible))

(defun gdev-search--actions (actions width)
  "Disponi ACTIONS su righe che rientrano in WIDTH."
  (let* ((gap "   ")
         (gap-width (gdev-search--measure gap))
         (remaining width)
         placed)
    (insert "  ")
    (pcase-dolist (`(,label ,command ,help ,primary) actions)
      (let* ((face (if primary 'gdev-ui-action-primary 'gdev-ui-action))
             (text (gdev-search--fit (propertize label 'face face) width))
             (size (gdev-search--measure text)))
        (when placed
          (if (<= (+ gap-width size) remaining)
              (progn (insert gap) (cl-decf remaining gap-width))
            (insert "\n  ")
            (setq remaining width)))
        (insert-text-button text 'type 'gdev-ui-action 'face face 'help-echo help
                            'gdev-search-action command
                            'action (lambda (_) (call-interactively command)))
        (cl-decf remaining size)
        (setq placed t))))
  (insert "\n"))

(defun gdev-search--fit-code (text width cell ellipsis left ascii)
  "Adatta TEXT a WIDTH con CELL, ELLIPSIS e un taglio LEFT facoltativo.
Con ASCII misura il codice con la sua colonna a spaziatura fissa."
  (let ((leading (if left (car ellipsis) "")))
    (if (not ascii)
          (gdev-search--fit (if left (concat leading text) text) width)
      (let* ((marker-width (cdr ellipsis))
             (budget (- width (if left marker-width 0))))
        (cond ((< budget 0) "")
              ((<= (* cell (length text)) budget) (if left (concat leading text) text))
              ((< budget marker-width) leading)
              (t (concat leading (substring text 0 (/ (- budget marker-width) cell))
                         (car ellipsis))))))))

(defun gdev-search--snippet (hit width cell ellipsis)
  "Mostra il testo di HIT entro WIDTH, centrato sulla prima occorrenza.
CELL è la larghezza di una cifra a spaziatura fissa.
ELLIPSIS è la coppia del glifo di sospensione con la sua larghezza."
  (let* ((source (gdev-search-hit-source hit))
         (indent (or (string-match "[^[:blank:]]" source) 0))
         (ranges (gdev-search-hit-ranges hit))
         (cols (/ (max 0 width) cell))
         (first (caar ranges))
         ;; Conserva il prefisso quando lascia spazio alla prima occorrenza.
         (start (if (and first (>= (- first indent) (/ (* 2 cols) 3)))
                    (max 0 (- first (/ cols 5)))
                  (min indent (or first indent))))
         (stop (min (length source) (+ start (max 64 (* 4 cols)))))
         (text (propertize (gdev-search--one-line (substring source start stop)) 'face 'fixed-pitch)))
    (pcase-dolist (`(,beg . ,end) ranges)
      (let ((from (- (max beg start) start))
            (to (- (min end stop) start)))
        (when (< from to)
          (put-text-property from to 'face '(gdev-ui-action fixed-pitch) text))))
    (let* ((left (> start indent))
           (ascii (string-match-p "\\`[ -~]*\\'" text))
           (leading (if left (length (car ellipsis)) 0))
           (fitted (gdev-search--fit-code text width cell ellipsis left ascii))
           (match-end (and first (- (min stop (cdar ranges)) start))))
      (if (or (not match-end)
              (and (<= (+ leading match-end) (length fitted))
                   (eq t (compare-strings text 0 match-end fitted leading (+ leading match-end)))))
          fitted
        (let* ((match-start (max 0 (- first start)))
               (match (substring text match-start match-end))
               (from-match (gdev-search--fit-code (substring text match-start)
                                                width cell ellipsis nil ascii)))
          ;; Conserva tutta l'occorrenza se entra solo senza contesto o ellissi.
          (if (or (string-prefix-p match from-match)
                  (> (if ascii (* cell (length match)) (gdev-search--measure match)) width))
              from-match
            match))))))

(defun gdev-search--marks ()
  "Prepara le due forme del selettore, di pari larghezza."
  (let* ((checked (propertize "  ✓ " 'face '(gdev-ui-action fixed-pitch)))
         (unchecked (propertize "  ○ " 'face '(gdev-ui-secondary fixed-pitch)))
         (size-checked (gdev-search--measure checked))
         (size-unchecked (gdev-search--measure unchecked))
         (gap (abs (- size-checked size-unchecked)))
         (padding (when (> gap 0) (gdev-activity--space gap (display-graphic-p)))))
    (if (> size-checked size-unchecked)
        (list size-checked checked (concat unchecked padding))
      (list size-unchecked (concat checked padding) unchecked))))

(defun gdev-search--selection-button (hit marks)
  "Inserisci il selettore di HIT usando le forme allineate MARKS."
  (let ((marked (gdev-search-hit-marked hit)))
    (insert-text-button (if marked (nth 1 marks) (nth 2 marks)) 'type 'gdev-ui-action
                        'help-echo (if marked "Deseleziona per la sostituzione · Spazio"
                                     "Seleziona per la sostituzione · Spazio")
                        'gdev-search-hit hit 'button-data hit
                        'action #'gdev-search--toggle)))

(defun gdev-search--row (hit width cell line-format marks ellipsis)
  "Inserisci HIT con MARKS, LINE-FORMAT e WIDTH unità per lo spezzone.
CELL e ELLIPSIS descrivono i caratteri a spaziatura fissa."
  (let* ((prefix (propertize (format line-format (gdev-search-hit-line hit))
                            'face '(gdev-ui-secondary fixed-pitch)))
         (snippet (gdev-search--snippet hit width cell ellipsis)))
    (gdev-search--selection-button hit marks)
    (insert-text-button (concat prefix snippet) 'type 'gdev-ui-action
                        'help-echo (gdev-search-hit-source hit)
                        'gdev-search-hit hit 'button-data hit
                        'action #'gdev-search--open-hit)
    (insert "\n")))

(defun gdev-search--controls (width)
  "Disegna il campo della ricerca e le sue opzioni entro WIDTH."
  (gdev-search--line "Cerca nei file" 'gdev-ui-side-title width)
  (if-let* ((roots gdev-search--roots))
      (let* ((root (directory-file-name (car roots)))
             (scope (if (cdr roots)
                        (format "%d cartelle" (length roots))
                      (file-name-nondirectory root))))
        (gdev-search--line (if (string-empty-p scope) root scope)
                           'gdev-ui-secondary width (string-join roots "\n"))
        (insert "\n")
        (gdev-search--options width))
    (gdev-search--line "Nessuna cartella" 'gdev-ui-secondary width)
    (insert "\n")
    (gdev-search--actions
     '(("Apri cartella…" gdev-open-folder "Scegli la cartella in cui cercare" t)) width)))

(defun gdev-search--options (width)
  "Disegna query, criteri e filtri dei percorsi entro WIDTH."
  (let* ((query gdev-search--query)
         (field (if (string-empty-p query) "Cerca un testo…" (gdev-search--one-line query)))
         (filtered (gdev-search-path-filters-p)))
    (gdev-search--actions (list (list field #'gdev-search-query (if (string-empty-p query) field query) t))
                          width)
    (gdev-search--actions
     (list (list "Filtri…" #'gdev-search-filters "Limita la ricerca a determinati percorsi" filtered)
           (list (if gdev-search--case-sensitive "✓ Aa" "Aa")
                 #'gdev-search-toggle-case "Distingui maiuscole e minuscole" gdev-search--case-sensitive)
           (list (if gdev-search--regexp "✓ Regexp" "Regexp")
                 #'gdev-search-toggle-regexp "Usa un'espressione regolare" gdev-search--regexp)
           (list (if gdev-search--whole-word "✓ Parola" "Parola")
                 #'gdev-search-toggle-word "Cerca solo parole intere" gdev-search--whole-word)
           (list (if gdev-search--include-ignored "✓ Ignorati" "Ignorati")
                 #'gdev-search-toggle-ignored "Includi i file ignorati" gdev-search--include-ignored))
     width)
    (when filtered
      (insert "\n")
      (unless (string-blank-p gdev-search--include)
        (gdev-search--line (concat "Includi " gdev-search--include) 'gdev-ui-secondary width))
      (unless (string-blank-p gdev-search--exclude)
        (gdev-search--line (concat "Escludi " gdev-search--exclude) 'gdev-ui-secondary width))
      (gdev-search--actions '(("Azzera filtri" gdev-search-clear-filters "Cerca in tutti i percorsi"))
                            width))))

(defun gdev-search--group-results (hits)
  "Raggruppa HITS per file e raccogli conteggi e numero di riga massimo."
  (let ((by-file (make-hash-table :test #'equal))
        (total 0) (marked 0) (last-line 0)
        groups)
    (dolist (hit (reverse hits))
      (let* ((file (gdev-search-hit-file hit))
             (group (gethash file by-file)))
        (if group
            (push hit (cdr group))
          (push (puthash file (list file hit) by-file) groups)))
      (cl-incf total)
      (when (gdev-search-hit-marked hit) (cl-incf marked))
      (setq last-line (max last-line (gdev-search-hit-line hit))))
    (list groups total marked last-line)))

(defun gdev-search--selection-summary (width total marked)
  "Inserisci conteggio e azioni per MARKED righe scelte fra TOTAL, entro WIDTH."
  (let ((start (point)))
    (when (> marked 0)
      (gdev-search--line (format "%d %s" marked (if (= marked 1) "selezionato" "selezionati"))
                         'gdev-ui-secondary width))
    (gdev-search--actions
     (delq nil
           (list (list (if (= marked total) "Deseleziona tutte" "Seleziona tutte")
                       #'gdev-search-toggle-all "Seleziona le righe per la sostituzione")
                 (when (> marked 0) (list "Anteprima…" #'gdev-search-preview "Confronta le sostituzioni"))
                 (when gdev-search--plan (list "Applica…" #'gdev-search-apply "Conferma le sostituzioni" t))))
     width)
    (put-text-property start (point) 'gdev-search-selection-summary t)
    (put-text-property (1- (point)) (point) 'rear-nonsticky t)))

(defun gdev-search--results-view (width)
  "Disegna risultati e azioni di sostituzione entro WIDTH."
  (when gdev-search--status
    (insert "\n")
    (gdev-search--line gdev-search--status 'gdev-ui-secondary width))
  (when gdev-search--results
    (pcase-let* ((`(,groups ,total ,marked ,last-line)
                  (gdev-search--group-results gdev-search--results))
                (files (length groups))
                (digits (length (number-to-string last-line)))
                (line-format (format "%%%dd  " digits))
                (cell (max 1 (gdev-search--measure (propertize "0" 'face 'fixed-pitch))))
                (ellipsis (propertize "…" 'face 'fixed-pitch))
                (ellipsis (cons ellipsis (gdev-search--measure ellipsis)))
                (marks (gdev-search--marks))
                (snippet-width (- (+ width (gdev-search--measure "  ")) (car marks) (* cell (+ digits 2))))
                (previous-directory nil)
                (previous-label nil))
      (insert "\n")
      (gdev-search--line (format "%d %s in %d file" total (if (= total 1) "risultato" "risultati") files)
                         'gdev-ui-secondary width)
      (gdev-search--selection-summary width total marked)
      (dolist (group groups)
        (let* ((file (car group))
               (directory (file-name-directory (file-relative-name file default-directory))))
          (insert "\n")
          (gdev-search--line (file-name-nondirectory file) 'gdev-ui-view-heading width file t)
          (when (and directory (not (equal directory "./")))
            (if (equal directory previous-directory)
                (insert "  " (propertize previous-label 'help-echo file) "\n")
              (setq previous-directory directory
                    previous-label (gdev-search--line (directory-file-name directory)
                                                      'gdev-ui-secondary width file))))
          ;; Il margine sinistro è incluso nel pulsante di selezione.
          (dolist (hit (cdr group))
            (gdev-search--row hit snippet-width cell line-format marks ellipsis)))))))

(defun gdev-search--geometry (window)
  "Rileva cambi di larghezza o carattere in WINDOW senza misurare testo."
  (let* ((frame (window-frame window))
         (graphical (display-graphic-p frame))
         (width (window-body-width window graphical)))
    (if graphical
        (list width (frame-char-width frame) (frame-char-height frame)
              (face-attribute 'default :height frame)
              (and text-scale-mode text-scale-mode-amount))
      (list width))))

(defun gdev-search--resize (window)
  "Riadatta il testo dopo i cambi di larghezza o carattere di WINDOW."
  (unless (equal gdev-search--render-geometry (gdev-search--geometry window))
    (gdev-search--render window)))

(defun gdev-search--update-selection (hit width)
  "Aggiorna selettore di HIT e riepilogo entro WIDTH, se ancora presenti.
Restituisci non-nil quando non è necessario ricostruire tutti i risultati."
  (when-let* ((position (text-property-any (point-min) (point-max) 'gdev-search-hit hit))
              (button (button-at position))
              ((eq (button-get button 'action) #'gdev-search--toggle))
              (start (text-property-any (point-min) (point-max) 'gdev-search-selection-summary t))
              (end (next-single-property-change start 'gdev-search-selection-summary)))
    (goto-char (button-start button))
    (delete-region (point) (button-end button))
    (gdev-search--selection-button hit (gdev-search--marks))
    ;; Il riepilogo precede i risultati: la modifica del selettore non ne
    ;; cambia i limiti. I conteggi derivano sempre dai dati della vista.
    (goto-char start)
    (delete-region start end)
    (gdev-search--selection-summary width (length gdev-search--results)
                                    (cl-count-if #'gdev-search-hit-marked gdev-search--results))
    t))

(defun gdev-search--render (&optional window selection)
  "Aggiorna la vista per WINDOW conservando il risultato selezionato.
Con SELECTION aggiorna solo il selettore di quel risultato e il riepilogo,
se la geometria non è cambiata."
  (gdev-search--check-mode)
  (let* ((buffer (current-buffer))
         (anchor (gdev-search--anchor (point)))
         (windows (mapcar (lambda (view)
                            (list view (gdev-search--anchor (window-point view))
                                  (gdev-search--anchor (window-start view))))
                          (get-buffer-window-list buffer nil 'visible)))
         (window (or window (caar windows) (selected-window))))
    (with-selected-frame (window-frame window)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (geometry (gdev-search--geometry window)))
          (let ((width (max 1 (- (car geometry) (gdev-search--measure "    ")))))
            (unless (and selection (equal geometry gdev-search--render-geometry)
                         (gdev-search--update-selection selection width))
              (erase-buffer)
              (gdev-search--controls width)
              (when gdev-search--roots (gdev-search--results-view width))))
          (setq gdev-search--render-geometry geometry)
          (goto-char (gdev-search--anchor-position anchor))
          (pcase-dolist (`(,view ,cursor ,start) windows)
            (set-window-point view (gdev-search--anchor-position cursor))
            (set-window-start view (gdev-search--anchor-position start) t)))))))

(defun gdev-search--anchor (position)
  "Identifica il risultato o il pulsante a POSITION prima del ridisegno."
  (save-excursion
    (goto-char position)
    (let* ((hit (gdev-search--hit-at-point))
           (button (button-at position))
           (action (or (get-text-property position 'gdev-search-action)
                       (and hit button (button-get button 'action)))))
      (list hit action
            (- (point) (if action (button-start (button-at position)) (line-beginning-position)))
            position))))

(defun gdev-search--anchor-position (anchor)
  "Restituisce la posizione di ANCHOR tra i risultati appena disegnati."
  (pcase-let ((`(,hit ,action ,column ,old-position) anchor))
    (if-let* ((position (cond (hit
                              (when-let* ((start (text-property-any (point-min) (point-max) 'gdev-search-hit hit)))
                                (if (not action) start
                                  (text-property-any start
                                                     (next-single-property-change start 'gdev-search-hit nil (point-max))
                                                     'action action))))
                             (action (text-property-any (point-min) (point-max) 'gdev-search-action action)))))
        (save-excursion
          (goto-char position)
          (min (if action (1- (button-end (button-at position))) (line-end-position))
               (+ position column)))
      (min old-position (point-max)))))

(defun gdev-search--hit-at-point ()
  "Restituisce il risultato sulla riga corrente."
  (get-text-property (line-beginning-position) 'gdev-search-hit))

(defun gdev-search--open-hit (hit)
  "Apre HIT nel gruppo editor attivo."
  (let ((file (gdev-search-hit-file hit)))
    (unless (file-readable-p file) (user-error "File non disponibile: %s" file))
    (gdev-open-file file))
  (widen)
  (goto-char (point-min))
  (forward-line (1- (gdev-search-hit-line hit)))
  (goto-char (min (line-end-position)
                  (+ (line-beginning-position) (or (caar (gdev-search-hit-ranges hit)) 0)))))

(defun gdev-search-visit ()
  "Apre il risultato corrente oppure esegue l'azione sotto il cursore."
  (interactive)
  (let ((hit (gdev-search--hit-at-point)))
    (cond ((button-at (point)) (push-button))
          (hit (gdev-search--open-hit hit))
          ((null gdev-search--roots) (call-interactively #'gdev-open-folder))
          (t (call-interactively #'gdev-search-query)))))

(defun gdev-search--toggle (hit)
  "Alterna la selezione di HIT e invalida l'anteprima."
  (setf (gdev-search-hit-marked hit) (not (gdev-search-hit-marked hit)))
  (gdev-search--invalidate-preview)
  (gdev-search--render nil hit))

(defun gdev-search-toggle-hit ()
  "Seleziona o deseleziona la riga corrente per la sostituzione."
  (interactive)
  (if-let* ((hit (gdev-search--hit-at-point)))
      (gdev-search--toggle hit)
    (user-error "Scegli un risultato")))

(defun gdev-search-toggle-all ()
  "Seleziona tutte le righe, o azzera la selezione completa."
  (interactive)
  (when gdev-search--results
    (let ((mark (not (seq-every-p #'gdev-search-hit-marked gdev-search--results))))
      (dolist (hit gdev-search--results)
        (setf (gdev-search-hit-marked hit) mark))
      (gdev-search--invalidate-preview)
      (gdev-search--render))))

(defun gdev-search--move (direction)
  "Si sposta di un risultato nella DIRECTION indicata."
  (let ((start (point))
        (step (if (> direction 0) #'next-single-property-change #'previous-single-property-change)))
    (goto-char (line-beginning-position))
    (catch 'found
      (while (let ((new (funcall step (point) 'gdev-search-hit)))
               (when new (goto-char new) t))
        (when (and (< direction 0) (> (point) (point-min))
                   (not (get-text-property (point) 'gdev-search-hit))
                   (get-text-property (1- (point)) 'gdev-search-hit))
          (backward-char))
        (when (get-text-property (point) 'gdev-search-hit)
          (beginning-of-line)
          (goto-char (button-start (next-button (point))))
          (throw 'found t)))
      (goto-char start))))

(defun gdev-search-next-hit ()
  "Va al risultato successivo."
  (interactive)
  (gdev-search--move 1))

(defun gdev-search-previous-hit ()
  "Va al risultato precedente."
  (interactive)
  (gdev-search--move -1))

(defun gdev-search-query (query)
  "Cerca QUERY nelle cartelle dello spazio attivo.
Senza cartelle, il comando interattivo apre la vista Cerca."
  (interactive
   (list (when (gdev-search--scope)
           (minibuffer-with-setup-hook
               (lambda ()
                 (use-local-map (make-composed-keymap gdev-search--query-map (current-local-map))))
             (read-string "Cerca nei file: " (gdev-search--query-seed))))))
  (if (and query (derived-mode-p 'gdev-search-mode))
      (gdev-search--start query)
    (gdev-search-show query)))

(defun gdev-search--query-seed ()
  "Propone la selezione su una riga o l'ultima ricerca dello spazio."
  (if (derived-mode-p 'gdev-search-mode)
      gdev-search--query
    (let* ((search (alist-get 'search (gdev-workspace-state-get 'gdev-activity-buffers)))
           (selection (when (use-region-p)
                        (buffer-substring-no-properties (region-beginning) (region-end)))))
      (if (and selection (not (string-blank-p selection)) (not (string-match-p "[\r\n]" selection)))
          (if (and (buffer-live-p search) (buffer-local-value 'gdev-search--regexp search))
              (replace-regexp-in-string (rx (any "\\.^$*+?()[]{}|"))
                                        (lambda (character) (concat "\\" character)) selection t t)
            selection)
        (if (buffer-live-p search) (buffer-local-value 'gdev-search--query search) "")))))

(defun gdev-search--check-mode ()
  "Richiede il fuoco nella vista Cerca."
  (unless (derived-mode-p 'gdev-search-mode)
    (user-error "Apri la vista Cerca nel progetto")))

(defun gdev-search-path-filters-p ()
  "Restituisci non nil se la vista Cerca ha filtri di percorso attivi."
  (and (derived-mode-p 'gdev-search-mode)
       gdev-search--roots
       (or (not (string-blank-p gdev-search--include))
           (not (string-blank-p gdev-search--exclude)))))

(defun gdev-search-filters (include exclude)
  "Limita Cerca ai percorsi conformi a INCLUDE e fuori da EXCLUDE."
  (interactive (list (read-string "Includi (per esempio *.swift, *.h): " gdev-search--include)
                     (read-string "Escludi (separa i filtri con virgole): " gdev-search--exclude)))
  (gdev-search--check-mode)
  (setq gdev-search--include include gdev-search--exclude exclude)
  (gdev-search-repeat))

(defun gdev-search-clear-filters ()
  "Azzera i filtri dei percorsi e ripete la ricerca corrente."
  (interactive)
  (gdev-search-filters "" "")
  (when-let* ((position (text-property-any (point-min) (point-max)
                                          'gdev-search-action #'gdev-search-filters)))
    (goto-char position)))

(defun gdev-search-toggle-regexp ()
  "Alterna testo letterale ed espressione regolare."
  (interactive)
  (gdev-search--check-mode)
  (setq gdev-search--regexp (not gdev-search--regexp))
  (gdev-search-repeat))

(defun gdev-search-toggle-case ()
  "Alterna la distinzione tra maiuscole e minuscole."
  (interactive)
  (gdev-search--check-mode)
  (setq gdev-search--case-sensitive (not gdev-search--case-sensitive))
  (gdev-search-repeat))

(defun gdev-search-toggle-word ()
  "Alterna la ricerca per parola intera."
  (interactive)
  (gdev-search--check-mode)
  (setq gdev-search--whole-word (not gdev-search--whole-word))
  (gdev-search-repeat))

(defun gdev-search-toggle-ignored ()
  "Includi o escludi i file ignorati da Git e ripgrep."
  (interactive)
  (gdev-search--check-mode)
  (setq gdev-search--include-ignored (not gdev-search--include-ignored))
  (gdev-search-repeat))

(defun gdev-search--split-globs (input)
  "Divide INPUT sulle virgole che non stanno dentro graffe.
«node_modules,dist» sono due filtri, «*.{c,h}» uno solo."
  (let ((depth 0) (start 0) parts)
    (dotimes (index (length input))
      (pcase (aref input index)
        (?{ (cl-incf depth))
        (?} (setq depth (max 0 (1- depth))))
        (?, (when (zerop depth)
              (push (substring input start index) parts)
              (setq start (1+ index))))))
    (push (substring input start) parts)
    (seq-remove #'string-empty-p (mapcar #'string-trim (nreverse parts)))))

(defun gdev-search--globs (input &optional exclude)
  "Converte INPUT in argomenti glob; con EXCLUDE li nega."
  (cl-loop for glob in (gdev-search--split-globs input)
           append (list "--glob" (if exclude (concat "!" glob) glob))))

(defun gdev-search--match-arguments ()
  "Restituisce gli argomenti ripgrep che determinano le corrispondenze."
  (append (list (if gdev-search--case-sensitive "--case-sensitive" "--ignore-case"))
          (when gdev-search--whole-word (list "--word-regexp"))
          (unless gdev-search--regexp (list "--fixed-strings"))))

(defun gdev-search-repeat ()
  "Ripete l'ultima ricerca con i filtri correnti."
  (interactive)
  (if (string-empty-p gdev-search--query)
      (gdev-search--render)
    (gdev-search--start gdev-search--query)))

(defun gdev-search--json-text (object &optional coding)
  "Legge il testo di OBJECT, decodificando i byte con CODING."
  (or (alist-get 'text object)
      (when-let* ((bytes (alist-get 'bytes object)))
        (decode-coding-string (base64-decode-string bytes) (or coding 'utf-8)))))

(defun gdev-search--character-ranges (source matches)
  "Converte gli offset UTF-8 di MATCHES in posizioni nel testo decodificato SOURCE."
  (let* ((ascii (= (string-bytes source) (length source)))
         (bytes (if ascii source (encode-coding-string source 'utf-8-unix)))
         (size (length bytes))
         (previous-byte 0) (previous-end 0) ranges)
    (catch 'invalid-offset
      (dolist (match matches)
        (let* ((start (alist-get 'start match))
               (end (alist-get 'end match)))
          (unless (and (<= previous-byte start end size)
                       (not (alist-get 'bytes (alist-get 'match match)))
                       (or ascii
                           (and (or (= start size) (not (<= #x80 (aref bytes start) #xbf)))
                                (or (= end size) (not (<= #x80 (aref bytes end) #xbf))))))
            (throw 'invalid-offset nil))
          (if ascii
              (push (cons start end) ranges)
            (let* ((first (+ previous-end (length (decode-coding-string
                                                   (substring bytes previous-byte start) 'utf-8))))
                   (last (+ first (length (decode-coding-string (substring bytes start end) 'utf-8)))))
              (push (cons first last) ranges)
              (setq previous-end last)))
          (setq previous-byte end)))
      (nreverse ranges))))

(defun gdev-search--parse (line host root)
  "Legge un risultato JSON LINE di ripgrep sotto HOST e ROOT."
  (let* ((message (json-parse-string line :object-type 'alist :array-type 'list))
         (data (alist-get 'data message)))
    (when (equal (alist-get 'type message) "match")
      (let* ((path (gdev-search--json-text (alist-get 'path data) file-name-coding-system))
             (file (and path (if (and host (file-name-absolute-p path))
                                (concat host path)
                              (expand-file-name path root))))
             (source (when-let* ((text (gdev-search--json-text (alist-get 'lines data))))
                       (string-trim-right text "\r?\n"))))
        (when (and file source)
          (make-gdev-search-hit
           :file file :line (alist-get 'line_number data)
           :source source
           :ranges (gdev-search--character-ranges source (alist-get 'submatches data))))))))

(defun gdev-search--filter (process chunk buffer host root)
  "Accoda CHUNK e pianifica la lettura per BUFFER sotto HOST e ROOT."
  (when (and (buffer-live-p buffer)
             (eq process (buffer-local-value 'gdev-search--process buffer)))
    (save-current-buffer (internal-default-process-filter process chunk))
    (gdev-search--schedule-drain process buffer host root)))

(defun gdev-search--schedule-drain (process buffer host root)
  "Pianifica un solo turno di lettura per PROCESS."
  (unless (process-get process 'drain-timer)
    (process-put process 'drain-timer
                 (run-at-time 0.001 nil #'gdev-search--drain process buffer host root))))

(defun gdev-search--read-batch (process host root)
  "Decodifica un lotto da PROCESS e indica se rimane del testo da leggere."
  (let ((count (or (process-get process 'count) 0))
        (limit (max 1 gdev-search-max-results))
        (hits (process-get process 'hits))
        (pending-saves (process-get process 'pending-saves))
        (skip (process-get process 'skip-tail))
        (deadline (+ (float-time) gdev-search--batch-time))
        (records 0)
        partial pending)
    (with-current-buffer (process-buffer process)
      (goto-char (point-min))
      (while (and (not partial) (not (eobp)) (< count limit)
                  (< records gdev-search--batch-records)
                  (or (zerop records) (< (float-time) deadline)))
        (let* ((start (point))
               (boundary (min (point-max) (+ start gdev-search--max-record-length 1))))
          (cond
           ((search-forward "\n" boundary t)
            (unless skip
              (when-let* ((hit (gdev-search--parse
                                (buffer-substring-no-properties start (1- (point))) host root)))
                (unless (and pending-saves (gethash (gdev-search-hit-file hit) pending-saves))
                  (push hit hits)
                  (cl-incf count))))
            (setq skip nil))
           ((or skip (> (- (point-max) start) gdev-search--max-record-length))
            (process-put process 'long-record t)
            (setq skip t)
            (goto-char boundary))
           (t (setq partial t))))
        (cl-incf records))
      (setq pending (and (not partial) (not (eobp))))
      (delete-region (point-min) (point)))
    (process-put process 'hits hits)
    (process-put process 'count count)
    (process-put process 'skip-tail skip)
    (when (>= count limit) (process-put process 'limit t))
    pending))

(defun gdev-search--preview-results (process buffer)
  "Mostra i risultati parziali di PROCESS se la ricerca continua."
  (process-put process 'preview-timer nil)
  (when (and (buffer-live-p buffer)
             (eq process (buffer-local-value 'gdev-search--process buffer))
             (not (process-get process 'finished)))
    (with-current-buffer buffer
      (let ((hits (process-get process 'hits)))
        (unless (eq hits (process-get process 'preview-hits))
          (process-put process 'preview-hits hits)
          (gdev-search--set-results
           (gdev-search--reuse-hits (sort (copy-sequence hits) #'gdev-search--hit<)))
          (gdev-search--render))))))

(defun gdev-search--drain (process buffer host root)
  "Leggi un lotto e restituisci il controllo prima del successivo."
  (process-put process 'drain-timer nil)
  (when (and (buffer-live-p buffer)
             (eq process (buffer-local-value 'gdev-search--process buffer)))
    (with-current-buffer buffer
      (condition-case err
          (let ((pending (gdev-search--read-batch process host root)))
            (cond
             ((process-get process 'limit)
              (when (process-live-p process) (delete-process process))
              (gdev-search--complete process))
             (pending (gdev-search--schedule-drain process buffer host root))
             ((process-get process 'finished) (gdev-search--complete process)))
            (when (and (eq process gdev-search--process)
                       (not (process-get process 'finished))
                       (not (process-get process 'refresh))
                       (not (process-get process 'preview-timer))
                       (not (eq (process-get process 'hits) (process-get process 'preview-hits))))
              (process-put process 'preview-timer
                           (run-at-time 0.2 nil #'gdev-search--preview-results process buffer))))
        (error
         (gdev-search--stop-process)
         (gdev-search--set-status (error-message-string err))
         (gdev-search--schedule-refresh))))))

(defun gdev-search--hit< (a b)
  "Ordina A e B per percorso e riga, indipendentemente dall'uscita di ripgrep."
  (let ((file-a (gdev-search-hit-file a)) (file-b (gdev-search-hit-file b)))
    (if (equal file-a file-b)
        (< (gdev-search-hit-line a) (gdev-search-hit-line b))
      (string< file-a file-b))))

(defun gdev-search--hit-key (hit)
  "Identifica HIT escludendo il suo stato di selezione."
  (list (gdev-search-hit-file hit) (gdev-search-hit-line hit)
        (gdev-search-hit-source hit) (gdev-search-hit-ranges hit)))

(defun gdev-search--reuse-hits (hits)
  "Mantiene selezione e identità delle righe rimaste uguali in HITS."
  (let ((previous (make-hash-table :test 'equal))
        (marked 0))
    (dolist (hit gdev-search--results)
      (puthash (gdev-search--hit-key hit) hit previous)
      (when (gdev-search-hit-marked hit) (cl-incf marked)))
    (let ((reused (mapcar (lambda (hit)
                            (let ((same (gethash (gdev-search--hit-key hit) previous hit)))
                              (when (gdev-search-hit-marked same) (cl-decf marked))
                              same))
                          hits)))
      (when (and gdev-search--plan (> marked 0))
        (gdev-search--invalidate-preview))
      reused)))

(defun gdev-search--set-status (status)
  "Mostra STATUS se è cambiato."
  (unless (equal status gdev-search--status)
    (setq gdev-search--status status)
    (gdev-search--render)))

(defun gdev-search--publish (process errors)
  "Pubblica il risultato di PROCESS o l'eventuale diagnosi in ERRORS."
  (let* ((limit (process-get process 'limit))
         (refresh (process-get process 'refresh))
         (failed (not (or limit (memq (process-exit-status process) '(0 1)))))
         (hits (if (and refresh failed)
                   gdev-search--results
                 (sort (delete-dups (process-get process 'hits)) #'gdev-search--hit<)))
         (status (cond (failed (with-current-buffer errors
                                 (concat "Errore di ricerca. " (string-trim (buffer-string)))))
                       (limit "Limite raggiunto. Restringi la ricerca.")
                       ((null hits) "Nessun risultato"))))
    (when (not failed)
      (setq hits (gdev-search--reuse-hits hits)))
    (when (process-get process 'long-record)
      (setq status (string-join (delq nil (list status "Righe troppo lunghe omesse.")) " ")))
    (when gdev-search--awaiting-save
      (setq status (string-join (delq nil (list "Sostituzioni applicate. Salva i documenti modificati."
                                               status)) " ")))
    (unless (and (equal hits gdev-search--results) (equal status gdev-search--status))
      (setq gdev-search--status status)
      (gdev-search--set-results hits)
      (gdev-search--render))))

(defun gdev-search--finished (process buffer host root)
  "Segna la fine di PROCESS dopo la consegna del suo ultimo blocco."
  (when (memq (process-status process) '(exit signal failed))
    (if (and (buffer-live-p buffer)
             (eq process (buffer-local-value 'gdev-search--process buffer)))
        (progn
          (process-put process 'finished t)
          (unless (process-get process 'limit)
            (gdev-search--schedule-drain process buffer host root)))
      (gdev-search--release-process process))))

(defun gdev-search--complete (process)
  "Pubblica PROCESS dopo averne letto tutti i risultati utilizzabili."
  (setq gdev-search--process nil)
  (unwind-protect
      (if (and (process-get process 'limit) (not gdev-search--ordered))
          ;; Il limite deve scegliere le stesse righe a parità di file.
          (progn
            (setq gdev-search--ordered t)
            (condition-case err
                (gdev-search--launch (process-get process 'refresh))
              (error (gdev-search--set-status (error-message-string err)))))
        (gdev-search--publish process (process-get process 'errors)))
    (gdev-search--release-process process))
  ;; Le scansioni più lunghe lasciano più tempo tra un passaggio e l'altro.
  (gdev-search--schedule-refresh
   (max gdev-search-refresh-interval
        (min 30 (* 8 (- (float-time) (process-get process 'started)))))))

(defun gdev-search--reset (roots)
  "Dimentica i risultati precedenti e imposta il contesto di ROOTS."
  (gdev-search--kill)
  (setq gdev-search--roots roots
        gdev-search--awaiting-save nil
        gdev-search--ordered nil
        gdev-search--plan nil)
  (gdev-search--set-results nil)
  (when roots
    (setq default-directory (file-name-as-directory (car roots)))))

(defun gdev-search--start (query &optional roots)
  "Avvia una nuova ricerca di QUERY nelle ROOTS correnti."
  (gdev-search--check-mode)
  (let ((roots (or roots (gdev-search--scope))))
    (unless roots
      (user-error "Apri una cartella o un progetto prima di cercare"))
    (unless (or (gdev-search--host roots) (executable-find "rg"))
      (user-error "Installa ripgrep per cercare nei file del progetto"))
    (gdev-search--reset roots)
    (setq gdev-search--query query
          gdev-search--status (unless (string-empty-p query) "Ricerca in corso…"))
    (unless (string-empty-p query)
      (condition-case err
          (gdev-search--launch)
        (error (setq gdev-search--status (error-message-string err)))))
    (gdev-search--render)
    (gdev-search--schedule-refresh)))

(defun gdev-search--launch (&optional refresh)
  "Avvia ripgrep con i filtri correnti; REFRESH conserva la vista fino all'esito."
  (let ((root default-directory)
        (host (gdev-search--host gdev-search--roots))
        (buffer (current-buffer))
        (started (float-time))
        (errors (generate-new-buffer " *gdev-search-errors*"))
        (output (generate-new-buffer " *gdev-search-json*")))
    (buffer-disable-undo output)
    (condition-case err
        (let ((process
               (make-process
                :name "gdev-search" :noquery t :file-handler t :buffer output :stderr errors
                :coding 'utf-8-unix :connection-type 'pipe
                :command (append (list "rg" "--no-config" "--json" "--crlf")
                                 (gdev-search--match-arguments)
                                 (cond (gdev-search--ordered (list "--sort" "path"))
                                       (refresh (list "--threads" "2")))
                                 (when gdev-search--include-ignored (list "--no-ignore" "--hidden" "--glob" "!.git"))
                                 (gdev-search--globs gdev-search--include)
                                 (gdev-search--globs gdev-search--exclude t)
                                 (list "--" gdev-search--query)
                                 (mapcar #'file-local-name gdev-search--roots))
                :sentinel #'ignore)))
          (process-put process 'errors errors)
          (process-put process 'refresh refresh)
          (process-put process 'started started)
          (when gdev-search--awaiting-save
            (let ((pending-saves (make-hash-table :test 'equal)))
              (dolist (document gdev-search--awaiting-save)
                (dolist (path (cdr document)) (puthash path t pending-saves)))
              (process-put process 'pending-saves pending-saves)))
          (setq gdev-search--process process)
          (set-process-filter process (lambda (child chunk) (gdev-search--filter child chunk buffer host root)))
          (set-process-sentinel process (lambda (child _event) (gdev-search--finished child buffer host root)))
          (gdev-search--finished process buffer host root)
          (unless (zerop (buffer-size output))
            (gdev-search--schedule-drain process buffer host root)))
      (error
       (kill-buffer output)
       (kill-buffer errors)
       (signal (car err) (cdr err))))))

(defun gdev-search--changed-line (source matches replacement)
  "Sostituisce MATCHES in SOURCE con REPLACEMENT come testo letterale."
  (let ((end (length source)) parts)
    (dolist (match (reverse matches))
      (push (substring source (cdr match) end) parts)
      (push replacement parts)
      (setq end (car match)))
    (push (substring source 0 end) parts)
    (apply #'concat parts)))

(defun gdev-search--regexp-replacements (hits replacement)
  "Espandi REPLACEMENT per HITS con la sintassi di ripgrep."
  (let ((arguments (gdev-search--match-arguments))
        (query gdev-search--query)
        (result (make-hash-table :test #'eq)))
    (when (string-search "\0" replacement)
      (user-error "La sostituzione non può contenere il carattere NUL"))
    (with-temp-buffer
      (setq default-directory temporary-file-directory)
      (dolist (hit hits)
        (insert (gdev-search-hit-source hit) "\0"))
      (let* ((coding-system-for-read 'utf-8-unix)
             (coding-system-for-write 'utf-8-unix)
             (status (apply #'call-process-region (point-min) (point-max) "rg" t t nil
                            (append (list "--no-config" "--text" "--null-data" "--passthru"
                                          "--color" "never" "--no-line-number" "--no-filename"
                                          "--replace" replacement)
                                    arguments (list "--" query "-"))))
             (output
              (when (and (eql status 0) (eq (char-before (point-max)) 0))
                (split-string (buffer-substring-no-properties (point-min) (1- (point-max))) "\0"))))
        (unless (= (length output) (length hits))
          (user-error "Ripgrep non ha potuto espandere la sostituzione"))
        (cl-mapc (lambda (hit text) (puthash hit text result)) hits output)))
    result))

(defun gdev-search--plan-lines (file hits replacement &optional expansions)
  "Prepara le modifiche di HITS nel buffer corrente per FILE e REPLACEMENT."
  (let ((hits (seq-uniq hits (lambda (a b) (= (gdev-search-hit-line a) (gdev-search-hit-line b)))))
        (line 1) changes)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (hit (sort hits (lambda (a b) (< (gdev-search-hit-line a) (gdev-search-hit-line b)))))
          (when (/= 0 (forward-line (- (gdev-search-hit-line hit) line)))
            (user-error "Il file è cambiato. Ripeti la ricerca: %s" file))
          (setq line (gdev-search-hit-line hit))
          (let* ((beg (line-beginning-position))
                 (end (line-end-position))
                 (source (buffer-substring-no-properties beg end)))
            (unless (equal source (gdev-search-hit-source hit))
              (user-error "Il testo è cambiato. Ripeti la ricerca: %s:%d" file line))
            (unless (gdev-search-hit-ranges hit)
              (user-error "L'espressione individua byte non sostituibili: %s:%d" file line))
            (let ((after (if expansions (gethash hit expansions)
                           (gdev-search--changed-line source (gdev-search-hit-ranges hit) replacement))))
              (unless (equal source after)
                (push (list line beg end source after) changes)))))))
    changes))

(defun gdev-search--file-version (file)
  "Restituisce dimensione e data di modifica di FILE."
  (when-let* ((attributes (file-attributes file)))
    (cons (file-attribute-size attributes) (file-attribute-modification-time attributes))))

(defun gdev-search--plan-file (file hits replacement &optional expansions)
  "Verifica HITS per FILE e prepara le modifiche REPLACEMENT."
  (let* ((buffer (find-buffer-visiting file))
         (attributes (gdev-search--file-version file))
         tick lines)
    (unless (and attributes (file-writable-p file))
      (user-error "Il file manca o è in sola lettura: %s" file))
    (if buffer
        (with-current-buffer buffer
          (when (or buffer-read-only (not (verify-visited-file-modtime buffer)))
            (user-error "File cambiato su disco o in sola lettura: %s" file))
          (setq tick (cons buffer (buffer-chars-modified-tick))
                lines (gdev-search--plan-lines file hits replacement expansions)))
      (with-temp-buffer
        (insert-file-contents file)
        (setq lines (gdev-search--plan-lines file hits replacement expansions))))
    (when lines
      (make-gdev-search-plan :file file :paths (delete-dups (mapcar #'gdev-search-hit-file hits))
                             :tick tick :attributes attributes :lines lines))))

(defun gdev-search--invalidate-preview ()
  "Svuota l'anteprima quando cambia la selezione o il testo sostitutivo."
  (setq gdev-search--plan nil)
  (when (buffer-live-p gdev-search--preview)
    (with-current-buffer gdev-search--preview
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Ricrea l'anteprima delle sostituzioni dalla vista Cerca.\n")
        (set-buffer-modified-p nil)))))

(defun gdev-search-preview (replacement)
  "Mostra una differenza delle righe selezionate con REPLACEMENT."
  (interactive (list (read-string (if gdev-search--regexp "Sostituisci con (gruppi $1, $2…): "
                                    "Sostituisci con: ")
                                  gdev-search--replacement)))
  (gdev-search--check-mode)
  (let ((selected (seq-filter #'gdev-search-hit-marked gdev-search--results))
        (owner (current-buffer))
        (root default-directory))
    (unless selected (user-error "Seleziona le righe da sostituire con SPC"))
    (gdev-search--invalidate-preview)
    (let* ((expansions (when gdev-search--regexp
                         (gdev-search--regexp-replacements selected replacement)))
           (groups (seq-group-by (lambda (hit) (file-truename (gdev-search-hit-file hit))) selected))
           (plan (delq nil (mapcar (lambda (group)
                                    (gdev-search--plan-file (car group) (cdr group) replacement expansions))
                                  groups))))
      (unless plan (user-error "La sostituzione lascia invariato il testo selezionato"))
      (unless (buffer-live-p gdev-search--preview)
        (setq gdev-search--preview (generate-new-buffer "*Anteprima sostituzioni*")))
      (with-current-buffer gdev-search--preview
        (diff-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Anteprima · %d righe in %d file\n\n"
                          (seq-reduce (lambda (total entry) (+ total (length (gdev-search-plan-lines entry)))) plan 0)
                          (length plan)))
          (insert-text-button "Applica sostituzioni" 'follow-link t
                              'action (lambda (_)
                                        (when (buffer-live-p owner)
                                          (with-current-buffer owner (gdev-search-apply)))))
          (insert "\n")
          (dolist (entry plan)
            (let ((name (file-relative-name (gdev-search-plan-file entry) root))
                  (delta 0))
              (insert "\n--- " name "\n+++ " name "\n")
              (pcase-dolist (`(,line ,_beg ,_end ,before ,after)
                             (reverse (gdev-search-plan-lines entry)))
                (let ((extra (cl-count ?\n after)))
                  (insert (format "@@ -%d,1 +%d,%d @@\n" line (+ line delta) (1+ extra))
                          "-" before "\n+" (string-replace "\n" "\n+" after) "\n")
                  (cl-incf delta extra)))))
          (goto-char (point-min))
          (set-buffer-modified-p nil)
          (setq buffer-read-only t)))
      (setq gdev-search--replacement replacement
            gdev-search--plan plan)
      (gdev-search--render)
      (display-buffer gdev-search--preview))))

(defun gdev-search--check-plan (entry buffer)
  "Verifica le righe di ENTRY nel documento BUFFER prima di modificarlo."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (unless (and (not buffer-read-only)
                   (verify-visited-file-modtime buffer)
                   (let ((tick (gdev-search-plan-tick entry)))
                     (or (not tick) (and (eq (car tick) buffer)
                                         (= (cdr tick) (buffer-chars-modified-tick)))))
                   (save-excursion
                     (goto-char (point-min))
                     (let ((previous 1))
                       (seq-every-p (pcase-lambda (`(,line ,beg ,end ,before ,_after))
                                      (and (= (forward-line (- line previous)) 0)
                                           (setq previous line)
                                           (= beg (line-beginning-position))
                                           (= end (line-end-position))
                                           (equal before (buffer-substring-no-properties beg end))))
                                    (reverse (gdev-search-plan-lines entry))))))
        (user-error "Il documento %s è cambiato. Ricrea l'anteprima" (buffer-name buffer))))))

(defun gdev-search--change (plan &optional validate)
  "Applica PLAN come un solo gruppo di modifiche.
Chiama VALIDATE dopo l'apertura dei file e prima di confermare le modifiche.
Restituisci i buffer con i percorsi corrispondenti."
  (let ((previous-ticks (make-hash-table :test #'eq))
        buffers opened change-group accepted)
    (unwind-protect
        (progn
          (dolist (entry plan)
            (let* ((file (gdev-search-plan-file entry))
                   (existing (find-buffer-visiting file)))
              (unless (equal (gdev-search-plan-attributes entry) (gdev-search--file-version file))
                (user-error "Il file %s è cambiato. Ricrea l'anteprima" file))
              (let ((buffer (or existing (find-file-noselect file))))
                (unless existing (push buffer opened))
                (gdev-search--check-plan entry buffer)
                (push (cons buffer entry) buffers))))
          (when validate (funcall validate))
          (setq change-group (apply #'nconc (mapcar (lambda (pair)
                                                    (with-current-buffer (car pair)
                                                      (puthash (car pair) (buffer-chars-modified-tick)
                                                               previous-ticks)
                                                      (undo-boundary)
                                                      (prepare-change-group)))
                                                  buffers)))
          (activate-change-group change-group)
          (dolist (pair buffers)
            (with-current-buffer (car pair)
              (save-excursion
                (save-restriction
                  (widen)
                  (pcase-dolist (`(,_line ,beg ,end ,_before ,after) (gdev-search-plan-lines (cdr pair)))
                    (goto-char beg)
                    (delete-region beg end)
                    (insert after))))))
          (when validate (funcall validate))
          (accept-change-group change-group)
          (setq accepted t)
          (dolist (pair buffers)
            (with-current-buffer (car pair) (undo-boundary)))
          (gdev-operation-record-replacement
           (mapcar (lambda (pair) (cons (car pair) (gdev-search-plan-lines (cdr pair))))
                   buffers)
           previous-ticks)
          (mapcar (lambda (pair) (cons (car pair) (gdev-search-plan-paths (cdr pair)))) buffers))
      (unless accepted
        (when change-group (cancel-change-group change-group))
        (dolist (buffer opened)
          (unless (buffer-modified-p buffer) (kill-buffer buffer)))))))

(defun gdev-search-apply ()
  "Applica l'anteprima dopo conferma, lasciando i documenti da salvare."
  (interactive)
  (gdev-search--check-mode)
  (when (and (eq gdev-activity-kind 'search)
             (not (eq (current-buffer)
                      (alist-get 'search (gdev-workspace-state-get 'gdev-activity-buffers)))))
    (user-error "Torna allo spazio di origine della vista Cerca"))
  (unless (equal gdev-search--roots (gdev-search--scope))
    (user-error "Le cartelle dello spazio sono cambiate. Ripeti la ricerca"))
  (let ((plan gdev-search--plan)
        (buffer (current-buffer))
        (frame (selected-frame)))
    (unless plan (user-error "Mostra prima l'anteprima delle sostituzioni"))
    (let ((workspace (gdev-workspace-state-ensure-id frame)))
      (cl-labels ((validate ()
                    (unless (and (buffer-live-p buffer) (eq frame (selected-frame))
                                 (eq workspace (gdev-workspace-state-id frame)))
                      (user-error "Lo spazio di origine di Cerca non è più attivo"))
                    (with-current-buffer buffer
                      (unless (and (eq plan gdev-search--plan)
                                   (equal gdev-search--roots (gdev-search--scope)))
                        (user-error "L'anteprima è cambiata. Ricrea l'anteprima delle sostituzioni")))))
        (when (yes-or-no-p (format "Applica le sostituzioni a %d file? " (length plan)))
          (validate)
          (with-current-buffer buffer
            (setq gdev-search--awaiting-save (delete-dups (append (gdev-search--change plan #'validate)
                                                                 gdev-search--awaiting-save))
                  gdev-search--plan nil
                  gdev-search--status "Sostituzioni applicate. Salva i documenti modificati.")
            (gdev-search--set-results nil)
            (gdev-search--kill)
            (gdev-search--render)
            (gdev-search--schedule-refresh)))))))

(provide 'gdev-search)
;;; gdev-search.el ends here
