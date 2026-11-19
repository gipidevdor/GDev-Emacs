;;; gdev-org-calendar.el --- Calendario visivo di Org GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Presenta le voci dell'Agenda di Org in una griglia oraria. Conserva
;; le sorgenti, le impostazioni dell'Agenda e l'accesso al selettore Org.

;;; Code:

(require 'button)
(require 'calendar)
(require 'cl-lib)
(require 'gdev-layout)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-workspace-roots)
(require 'org-agenda)
(require 'project)
(require 'seq)

(declare-function gdev-org-agenda-git-insert "gdev-org-agenda-git" (start end))
(declare-function gdev-org-agenda-git-insert-summary "gdev-org-agenda-git" (width start end))
(declare-function gdev-org-agenda-git-refresh "gdev-org-agenda-git" (start end))

(defvar gdev-org-calendar-extra-functions nil
  "Funzioni che aggiungono contenuto alla fine dell'Agenda.
Ricevono due date assolute. La data finale è esclusa.")

(defvar gdev-org-calendar-refresh-functions nil
  "Funzioni che rileggono i dati esterni su richiesta esplicita.
Ricevono due date assolute. La data finale è esclusa.")

(defvar-local gdev-org-calendar-context-root nil
  "Cartella del progetto dal quale è stata aperta la vista.")

(defvar-local gdev-org-calendar--date nil)
(defvar-local gdev-org-calendar--view 'week)
(defvar-local gdev-org-calendar--entries nil)
(defvar-local gdev-org-calendar--loaded-range nil)
(defvar-local gdev-org-calendar--loaded-entries nil)
(defvar-local gdev-org-calendar--width nil)
(defvar-local gdev-org-calendar--rendering nil)

(defconst gdev-org-calendar--days
  ["Domenica" "Lunedì" "Martedì" "Mercoledì" "Giovedì" "Venerdì" "Sabato"])

(defconst gdev-org-calendar--months
  ["gennaio" "febbraio" "marzo" "aprile" "maggio" "giugno"
   "luglio" "agosto" "settembre" "ottobre" "novembre" "dicembre"])

(defface gdev-org-calendar-divider
  '((((background light)) :background "#d8dde6")
    (((background dark)) :background "#383d48"))
  "Separatore decorativo della griglia dell'Agenda."
  :group 'gdev-ui)

(defface gdev-org-calendar-all-day
  '((t :inherit gdev-ui-side-surface :extend t))
  "Superficie della fascia per gli impegni senza orario."
  :group 'gdev-ui)

(defvar-keymap gdev-org-calendar-mode-map
  :parent special-mode-map
  "<left>" #'gdev-org-calendar-previous
  "<right>" #'gdev-org-calendar-next
  "t" #'gdev-org-calendar-today
  "j" #'gdev-org-calendar-jump
  "g" #'gdev-org-calendar-refresh
  "r" #'gdev-org-calendar-refresh
  "v d" #'gdev-org-calendar-day
  "v w" #'gdev-org-calendar-week
  "v l" #'gdev-org-calendar-workweek
  "TAB" #'forward-button
  "<tab>" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-org-calendar-mode special-mode "Agenda GDev"
  "Calendario giornaliero o settimanale basato sulle voci dell'Agenda Org."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-document)
  (setq-local truncate-lines t)
  (require 'gdev-org-agenda-git)
  (add-hook 'gdev-org-calendar-extra-functions #'gdev-org-agenda-git-insert nil t)
  (add-hook 'gdev-org-calendar-refresh-functions #'gdev-org-agenda-git-refresh nil t)
  (add-hook 'window-size-change-functions #'gdev-org-calendar--resize nil t)
  (add-hook 'window-buffer-change-functions #'gdev-org-calendar--resize nil t))

(defun gdev-org-calendar-visible-range ()
  "Restituisci il periodo mostrato come due date assolute.
La seconda data è esclusa."
  (let* ((date (or gdev-org-calendar--date (org-today)))
         (weekday (calendar-day-of-week (calendar-gregorian-from-absolute date)))
         (monday (- date (mod (1- weekday) 7))))
    (pcase gdev-org-calendar--view
      ('day (cons date (1+ date)))
      ('workweek (cons monday (+ monday 5)))
      (_ (cons monday (+ monday 7))))))

(defun gdev-org-calendar--visible-date ()
  "Restituisci la data attiva più vicina nel periodo mostrato."
  (min gdev-org-calendar--date (1- (cdr (gdev-org-calendar-visible-range)))))

(defun gdev-org-calendar--date-label (date &optional year)
  "Mostra DATE con il mese italiano e, se YEAR, anche l'anno."
  (pcase-let ((`(,month ,day ,number) (calendar-gregorian-from-absolute date)))
    (concat (format "%d %s" day (aref gdev-org-calendar--months (1- month)))
            (when year (format " %d" number)))))

(defun gdev-org-calendar--weekday (date)
  "Restituisci il nome italiano del giorno DATE."
  (aref gdev-org-calendar--days
        (calendar-day-of-week (calendar-gregorian-from-absolute date))))

(defun gdev-org-calendar--title (start end)
  "Formatta il titolo del periodo da START a END, escluso."
  (if (= start (1- end))
      (format "%s %s" (gdev-org-calendar--weekday start)
              (gdev-org-calendar--date-label start t))
    (pcase-let ((`(,first-month ,first-day ,first-year)
                 (calendar-gregorian-from-absolute start))
                (`(,last-month ,_last-day ,last-year)
                 (calendar-gregorian-from-absolute (1- end))))
      (if (and (= first-year last-year) (= first-month last-month))
          (format "%d–%s" first-day (gdev-org-calendar--date-label (1- end) t))
        (format "%s – %s" (gdev-org-calendar--date-label start (/= first-year last-year))
                (gdev-org-calendar--date-label (1- end) t))))))

(defun gdev-org-calendar--entry (entry date)
  "Converti la voce Org ENTRY in una scheda della data DATE."
  (let* ((marker (or (get-text-property 0 'org-hd-marker entry)
                     (get-text-property 0 'org-marker entry)))
         (buffer (and (markerp marker) (marker-buffer marker)))
         (kind (get-text-property 0 'type entry))
         (time (get-text-property 0 'time-of-day entry))
         (duration (get-text-property 0 'duration entry))
         (title (if buffer
                    (org-with-point-at marker (org-get-heading t t t t))
                  (string-trim (substring-no-properties entry)))))
    (unless (string-empty-p title)
      (list :title (substring-no-properties title) :marker marker
            :start (when (and (integerp time) (<= 0 time 2359))
                     (+ (* 60 (/ time 100)) (% time 100)))
            :duration (and (numberp duration) duration)
            :kind kind
            :id (list 'org date (or marker title) kind time)))))

(defun gdev-org-calendar--collect (range)
  "Raccogli le voci Org del RANGE attraverso le primitive dell'Agenda."
  (let* ((files (org-agenda-files nil 'ifmode))
         (types (if org-agenda-include-deadlines
                    org-agenda-entry-types
                  (remq :deadline (remq :deadline* org-agenda-entry-types))))
         (org-agenda-buffer nil)
         (org-agenda-markers nil)
         (org-prefix-format-compiled nil)
         (org-agenda-current-date nil)
         (org-starting-day (car range)))
    (org-compile-prefix-format 'agenda)
    (cl-loop for day from (car range) below (cdr range)
             for date = (calendar-gregorian-from-absolute day)
             collect
             (cons day
                   (seq-sort-by
                    (lambda (entry) (or (plist-get entry :start) -1)) #'<
                    (delq nil
                          (mapcar (lambda (entry) (gdev-org-calendar--entry entry day))
                                  (append
                                   (when types
                                     (cl-loop for file in files
                                              append
                                              (catch 'nextfile
                                                (org-check-agenda-file file)
                                                (apply #'org-agenda-get-day-entries file date types))))
                                   (when org-agenda-include-diary
                                     (require 'diary-lib)
                                     (org-get-entries-from-diary date))))))))))

(defun gdev-org-calendar--read (&optional force)
  "Rileggi il periodo visibile, oppure fallo comunque con FORCE."
  (let ((range (gdev-org-calendar-visible-range)))
    (unless (and (not force) gdev-org-calendar--loaded-range
                 (<= (car gdev-org-calendar--loaded-range) (car range))
                 (<= (cdr range) (cdr gdev-org-calendar--loaded-range)))
      (setq gdev-org-calendar--loaded-entries (gdev-org-calendar--collect range)
            gdev-org-calendar--loaded-range range))
    (setq gdev-org-calendar--entries
          (seq-filter (lambda (day) (and (<= (car range) (car day)) (< (car day) (cdr range))))
                      gdev-org-calendar--loaded-entries))))

(defun gdev-org-calendar--open (button)
  "Apri la voce di Org associata a BUTTON."
  (let* ((marker (button-get button 'gdev-org-calendar-marker))
         (buffer (marker-buffer marker))
         (position (marker-position marker)))
    (unless buffer (user-error "La voce non è più disponibile. Aggiorna l'Agenda"))
    (pop-to-buffer-same-window buffer)
    (unless (<= (point-min) position (point-max)) (widen))
    (goto-char position)
    (when (derived-mode-p 'org-mode)
      (org-fold-show-context 'agenda)
      (run-hooks 'org-agenda-after-show-hook))))

(defun gdev-org-calendar--button (label command id description &optional face)
  "Inserisci LABEL per COMMAND, con identità ID e aiuto DESCRIPTION.
FACE sostituisce la faccia dell'azione se fornita."
  (insert-text-button label 'type 'gdev-ui-action 'action (lambda (_) (funcall command))
                      'face (gdev-org-calendar--text-face (or face 'gdev-ui-action))
                      'help-echo description
                      'gdev-org-calendar-item id))

(defun gdev-org-calendar--select (view &optional date)
  "Mostra VIEW usando DATE se fornita e aggiorna il contenuto."
  (setq gdev-org-calendar--view view
        gdev-org-calendar--date (or date gdev-org-calendar--date (org-today)))
  (gdev-org-calendar--read)
  (gdev-org-calendar-redraw))

(defun gdev-org-calendar-day ()
  "Mostra il giorno selezionato."
  (interactive)
  (gdev-org-calendar--select 'day))

(defun gdev-org-calendar-week ()
  "Mostra la settimana corrente dell'Agenda."
  (interactive)
  (gdev-org-calendar--select 'week))

(defun gdev-org-calendar-workweek ()
  "Mostra i giorni da lunedì a venerdì."
  (interactive)
  (gdev-org-calendar--select 'workweek))

(defun gdev-org-calendar--move (direction)
  "Sposta il periodo in DIRECTION."
  (gdev-org-calendar--select gdev-org-calendar--view
                            (+ gdev-org-calendar--date
                               (* direction (if (eq gdev-org-calendar--view 'day) 1 7)))))

(defun gdev-org-calendar-previous ()
  "Vai al periodo precedente."
  (interactive)
  (gdev-org-calendar--move -1))

(defun gdev-org-calendar-next ()
  "Vai al periodo successivo."
  (interactive)
  (gdev-org-calendar--move 1))

(defun gdev-org-calendar-today ()
  "Torna al periodo che contiene oggi."
  (interactive)
  (gdev-org-calendar--select gdev-org-calendar--view (org-today)))

(defun gdev-org-calendar-jump ()
  "Visualizza la data selezionata."
  (interactive)
  (gdev-org-calendar--select gdev-org-calendar--view
                            (time-to-days
                             (org-read-date nil t nil "Vai alla data"
                                            (org-time-from-absolute
                                             (calendar-gregorian-from-absolute
                                              gdev-org-calendar--date))))))

(defun gdev-org-calendar-refresh ()
  "Aggiorna le voci del periodo corrente."
  (interactive)
  (gdev-org-calendar--read t)
  (pcase-let ((`(,start . ,end) (gdev-org-calendar-visible-range)))
    (run-hook-with-args 'gdev-org-calendar-refresh-functions start end))
  (gdev-org-calendar-redraw))

(defconst gdev-org-calendar--scopes '(day workweek week))

(defun gdev-org-calendar--toolbar-row (width actions)
  "Mostra ACTIONS entro WIDTH con segmenti uguali per le viste."
  (let* ((regular-gap (gdev-org-calendar--measure "   "))
         (segment-width
          (+ (gdev-org-calendar--measure "  ")
             (or (cl-loop for (id label) in actions
                          when (memq id gdev-org-calendar--scopes)
                          maximize (gdev-org-calendar--measure
                                    (propertize label 'face
                                                (gdev-org-calendar--text-face 'gdev-ui-action-primary))))
                 0)))
         (used 0)
         previous-segment)
    (pcase-dolist (`(,id ,label ,command ,help) actions)
      (let* ((segment (memq id gdev-org-calendar--scopes))
             (selected (eq id gdev-org-calendar--view))
             (face (cond (selected 'gdev-ui-action-primary)
                         (segment '(gdev-ui-action gdev-ui-side-surface))
                         (t 'gdev-ui-action)))
             (gap (if (and previous-segment segment) 1 regular-gap))
             (button (gdev-org-calendar--padded-label label width face (and segment segment-width)))
             (length (gdev-org-calendar--measure button)))
        (when (and (> used 0) (> (+ used gap length) width))
          (insert "\n")
          (setq used 0))
        (when (> used 0)
          (gdev-org-calendar--padding gap)
          (cl-incf used gap))
        (gdev-org-calendar--button button command id
                                   (if selected (concat help " · selezionata") help) face)
        (cl-incf used length)
        (setq previous-segment segment))))
  (insert "\n"))

(defun gdev-org-calendar--toolbar (width)
  "Mostra navigazione e cambio vista su righe distinte entro WIDTH."
  (gdev-org-calendar--toolbar-row
   width '((previous "‹ Precedente" gdev-org-calendar-previous "Periodo precedente")
           (today "Oggi" gdev-org-calendar-today "Torna al giorno corrente")
           (next "Successivo ›" gdev-org-calendar-next "Periodo successivo")
           (date "Vai alla data…" gdev-org-calendar-jump "Scegli una data")))
  (gdev-org-calendar--toolbar-row
   width '((day "Giorno" gdev-org-calendar-day "Vista giorno")
           (workweek "Lun–ven" gdev-org-calendar-workweek "Settimana lavorativa")
           (week "Settimana" gdev-org-calendar-week "Vista settimana")
           (classic "Elenco Org" org-agenda "Apri il selettore di Org")))
  (insert "\n"))

(defun gdev-org-calendar--measure (text)
  "Misura TEXT nella finestra corrente."
  (if (display-graphic-p) (gdev-ui-string-pixel-width text) (string-width text)))

(defun gdev-org-calendar--space (amount &optional face)
  "Prepara uno spazio di AMOUNT unità, eventualmente con FACE."
  (cond ((<= amount 0) "")
        ((display-graphic-p)
         (propertize " " 'display `(space :width (,amount)) 'face face))
        (t (propertize (make-string amount ?\s) 'face face))))

(defun gdev-org-calendar--padding (amount &optional face)
  "Inserisci uno spazio di AMOUNT unità, eventualmente con FACE."
  (insert (gdev-org-calendar--space amount face)))

(defun gdev-org-calendar--text-face (face)
  "Usa il carattere della vista anche quando il testo usa FACE."
  (append (ensure-list face) '(variable-pitch)))

(defun gdev-org-calendar--fit (text width face)
  "Accorcia TEXT alla WIDTH disponibile usando FACE."
  (gdev-ui-fit-text (propertize text 'face (gdev-org-calendar--text-face face))
                   width #'gdev-org-calendar--measure))

(defun gdev-org-calendar--padded-label (text width face &optional minimum)
  "Adatta TEXT a WIDTH con FACE, includendo il margine nell'area cliccabile.
MINIMUM riserva una larghezza uniforme per un gruppo di controlli."
  (let* ((margin (min (gdev-org-calendar--measure " ") (/ width 4)))
         (label (gdev-org-calendar--fit text (- width (* 2 margin)) face))
         (length (gdev-org-calendar--measure label))
         (extra (max 0 (- (min width (or minimum 0)) (* 2 margin) length)))
         (leading (+ margin (/ extra 2))))
    (concat (gdev-org-calendar--space leading)
            label
            (gdev-org-calendar--space (- (+ (* 2 margin) extra) leading)))))

(defun gdev-org-calendar--time (minutes)
  "Mostra MINUTES dal principio del giorno."
  (format "%02d:%02d" (/ minutes 60) (% minutes 60)))

(defun gdev-org-calendar--duration (entry)
  "Mostra l'ora o l'intervallo della scheda ENTRY."
  (when-let* ((start (plist-get entry :start)))
    (let ((duration (plist-get entry :duration)))
      (concat (gdev-org-calendar--time start)
              (when (and duration (> duration 0))
                (concat "–" (gdev-org-calendar--time (round (+ start duration)))))))))

(defun gdev-org-calendar--kind (entry)
  "Restituisci una descrizione del tipo di ENTRY."
  (let ((kind (plist-get entry :kind)))
    (cond ((member kind '("deadline" "upcoming-deadline")) "Scadenza")
          ((member kind '("scheduled" "past-scheduled")) "Pianificato")
          (t "Impegno"))))

(defun gdev-org-calendar--insert-event (entry width compact)
  "Inserisci ENTRY nelle unità WIDTH, con etichetta COMPACT in griglia."
  (let* ((title (plist-get entry :title))
         (duration (gdev-org-calendar--duration entry))
         (start (plist-get entry :start))
         (marker (plist-get entry :marker))
         (source (and (markerp marker) (marker-buffer marker)))
         (kind (gdev-org-calendar--kind entry))
         (deadline (equal kind "Scadenza"))
         (face (if deadline 'gdev-ui-status-warning 'gdev-ui-action))
         (face (if compact (list face 'gdev-ui-side-current) face))
         (time-column
          (when (and (not compact) duration)
            (let ((column (gdev-org-calendar--measure
                           (propertize "00:00–00:00   " 'face
                                       (gdev-org-calendar--text-face 'gdev-ui-secondary)))))
              (when (>= width (+ column (gdev-org-calendar--measure " Incontro lungo ")))
                column))))
         (text (concat (when deadline (if compact "Scad. " "Scadenza · "))
                       (cond ((and compact start) (concat (gdev-org-calendar--time start) " "))
                             ((and duration (not time-column)) (concat duration "  "))
                             (t ""))
                       title))
         (fitted (if compact (gdev-org-calendar--padded-label text width face)
                   (gdev-org-calendar--fit text (if time-column (- width time-column) width) face))))
    (when time-column
      (let ((stamp (propertize duration 'face (gdev-org-calendar--text-face 'gdev-ui-secondary))))
        (insert stamp)
        (gdev-org-calendar--padding (- time-column (gdev-org-calendar--measure stamp)))))
    (if source
        (insert-text-button fitted 'type 'gdev-ui-action 'face (gdev-org-calendar--text-face face)
                            'action #'gdev-org-calendar--open
                            'gdev-org-calendar-marker marker
                            'gdev-org-calendar-item (plist-get entry :id)
                            'help-echo (string-join
                                        (delq nil (list title kind duration (buffer-name source))) " · "))
      (insert fitted))
    (gdev-org-calendar--measure fitted)))

(defun gdev-org-calendar--date-button (day width compact)
  "Disegna una data DAY come azione per la vista Giorno entro WIDTH."
  (let* ((name (gdev-org-calendar--weekday day))
         (label (if compact
                    (format "%s %d" (substring name 0 3)
                            (nth 1 (calendar-gregorian-from-absolute day)))
                  (concat name " " (gdev-org-calendar--date-label day))))
         (active (= day (gdev-org-calendar--visible-date)))
         (today (= day (org-today)))
         (face (cond (active 'gdev-ui-action-primary)
                     (today 'gdev-ui-action)
                     (t 'gdev-ui-view-heading)))
         (label (gdev-org-calendar--fit (if today (concat label " · Oggi") label) width face)))
    (gdev-org-calendar--button label (lambda () (gdev-org-calendar--select 'day day)) (cons 'date day)
                               (concat name " " (gdev-org-calendar--date-label day t)) face)
    (gdev-org-calendar--measure label)))

(defun gdev-org-calendar--group-days (entries)
  "Raggruppa ENTRIES per giorno e per ora."
  (mapcar
   (lambda (day)
     (let ((groups (make-vector 25 nil)))
       (dolist (entry (reverse (cdr day)))
         (let* ((minute (plist-get entry :start))
                (slot (if minute (1+ (/ minute 60)) 0)))
           (push entry (aref groups slot))))
       (dotimes (slot (length groups))
         (aset groups slot (vconcat (aref groups slot))))
       (cons (car day) groups)))
   entries))

(defun gdev-org-calendar--grid-line (axis days axis-width column-width gap cell)
  "Inserisci AXIS e le celle DAY con CELL alle larghezze indicate.
AXIS-WIDTH regola la scala, COLUMN-WIDTH le celle e GAP il margine."
  (let ((text (gdev-org-calendar--fit axis (- axis-width gap) 'gdev-ui-secondary))
        (graphic (display-graphic-p)))
    (insert text)
    (unless graphic
      (gdev-org-calendar--padding (- axis-width (gdev-org-calendar--measure text))))
    (cl-loop for day in days
             for left from axis-width by (1+ column-width) do
             (if graphic
                 (progn
                   (insert (propertize " " 'display `(space :align-to (,left))))
                   (gdev-org-calendar--padding 1 'gdev-org-calendar-divider))
               (insert (propertize "│" 'face 'gdev-ui-secondary)))
             (gdev-org-calendar--padding gap)
             (let* ((available (- column-width (* 2 gap)))
                    (occupied (funcall cell day available)))
               (unless graphic
                 (gdev-org-calendar--padding (- column-width gap (or occupied 0)))))))
  (insert "\n"))

(defun gdev-org-calendar--grid (entries width)
  "Disegna la griglia settimanale delle ENTRIES entro WIDTH."
  (let* ((groups (gdev-org-calendar--group-days entries))
         (gap (gdev-org-calendar--measure "  "))
         (axis (+ (gdev-org-calendar--measure
                   (propertize "Tutto il giorno  " 'face 'variable-pitch)) gap))
         (column (max 1 (- (/ (- width axis gap) (length groups))
                            (if (display-graphic-p) 1 (string-width "│")))))
         (first 9)
         (last 19))
    (dolist (day groups)
      (dotimes (slot 24)
        (when (> (length (aref (cdr day) (1+ slot))) 0)
          (setq first (min first (1+ slot))
                last (max last (1+ slot))))))
    (gdev-org-calendar--grid-line "" groups axis column gap
                                 (lambda (day available)
                                   (gdev-org-calendar--date-button (car day) available t)))
    (when (seq-some #'cdr entries)
      (cl-loop for slot in (cons 0 (number-sequence first last)) do
               (let ((count (apply #'max
                                   (mapcar (lambda (day) (length (aref (cdr day) slot))) groups))))
                 (dotimes (row (max 1 count))
                   (let ((line (point)))
                     (gdev-org-calendar--grid-line
                      (if (> row 0) "" (if (= slot 0) "Tutto il giorno"
                                         (gdev-org-calendar--time (* 60 (1- slot)))))
                      groups axis column gap
                      (lambda (day available)
                        (let ((events (aref (cdr day) slot)))
                          (when (< row (length events))
                            (gdev-org-calendar--insert-event (aref events row) available t)))))
                     (when (= slot 0)
                       (add-face-text-property line (point) 'gdev-org-calendar-all-day t)))))))))

(defun gdev-org-calendar--list (entries width)
  "Disegna ENTRIES per giorno, con titoli leggibili entro WIDTH."
  (dolist (day entries)
    (when (or (cdr day) (= (car day) (gdev-org-calendar--visible-date)))
      (unless (eq gdev-org-calendar--view 'day)
        (gdev-org-calendar--date-button (car day) width nil)
        (insert "\n"))
      (if (cdr day)
          (let ((previous-group nil))
            (dolist (entry (cdr day))
              (let ((group (if (plist-get entry :start) 'timed 'all-day)))
                (unless (eq previous-group group)
                  (insert (propertize (if (eq group 'timed) "Orari" "Tutto il giorno")
                                      'face 'gdev-ui-secondary) "\n")
                  (setq previous-group group))
                (gdev-org-calendar--insert-event entry width nil)
                (insert "\n"))))
        (insert (propertize "Nessun impegno" 'face 'gdev-ui-secondary) "\n"))
      (insert "\n"))))

(defun gdev-org-calendar--width ()
  "Restituisci la larghezza disponibile nella finestra mostrata."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window (display-graphic-p (window-frame window)))
    (if (display-graphic-p) (frame-inner-width) (frame-width))))

(defun gdev-org-calendar--resize (window)
  "Adegua la griglia alla larghezza di WINDOW."
  (with-current-buffer (window-buffer window)
    (when (and gdev-org-calendar--loaded-range
               (not (equal gdev-org-calendar--width (gdev-org-calendar--width))))
      (gdev-org-calendar-redraw))))

(defun gdev-org-calendar-redraw ()
  "Ridisegna i dati già raccolti conservando l'azione selezionata."
  (unless gdev-org-calendar--rendering
    (let* ((gdev-org-calendar--rendering t)
           (inhibit-read-only t)
           (old-pos (point))
           (old-id (get-text-property (point) 'gdev-org-calendar-item))
           (width (gdev-org-calendar--width))
           (views (length gdev-org-calendar--entries))
           (wide (and (> views 1)
                      (>= width (+ (gdev-org-calendar--measure "Tutto il giorno  ")
                                   (* views (gdev-org-calendar--measure "   09:15 Incontro   ")))))))
      (setq gdev-org-calendar--width width)
      (erase-buffer)
      (pcase-let ((`(,start . ,end) (gdev-org-calendar-visible-range)))
        (let ((title (gdev-org-calendar--title start end)))
          (insert (propertize (gdev-org-calendar--fit
                               (concat (gdev-ui-icon "calendar" "▦" nil 'gdev-ui-action) " " title)
                               width 'gdev-ui-view-title)
                              'help-echo title) "\n\n"))
        (gdev-org-calendar--toolbar width)
        (gdev-org-agenda-git-insert-summary width start end)
        (cond (wide (gdev-org-calendar--grid gdev-org-calendar--entries width)
                    (unless (seq-some #'cdr gdev-org-calendar--entries)
                      (insert (propertize "Nessun impegno nel periodo" 'face 'gdev-ui-secondary) "\n")))
              ((or (= views 1) (seq-some #'cdr gdev-org-calendar--entries))
               (gdev-org-calendar--list gdev-org-calendar--entries width))
              (t (insert (propertize "Nessun impegno nel periodo" 'face 'gdev-ui-secondary) "\n")))
        (run-hook-with-args 'gdev-org-calendar-extra-functions start end))
      (goto-char (point-min))
      (goto-char (or (and old-id
                         (when-let* ((match (text-property-search-forward
                                             'gdev-org-calendar-item old-id #'equal)))
                           (prop-match-beginning match)))
                     (min old-pos (point-max))))
      (set-buffer-modified-p nil))))

(defun gdev-org-calendar ()
  "Apri l'Agenda Org nel gruppo editor attivo."
  (interactive)
  (require 'org)
  (let* ((window (or (and gdev-layout-mode (gdev-layout-editor)) (selected-window)))
         (directory (buffer-local-value 'default-directory (window-buffer window)))
         (project (project-current nil directory))
         (root (if project (file-name-as-directory (project-root project))
                 (gdev-project-root (or (gdev-workspace-directory directory) directory))))
         (buffer (or (seq-find
                      (lambda (candidate)
                        (with-current-buffer candidate
                          (and (derived-mode-p 'gdev-org-calendar-mode)
                               (equal gdev-org-calendar-context-root root))))
                      (buffer-list))
                     (generate-new-buffer "*Agenda GDev*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-org-calendar-mode)
        (gdev-org-calendar-mode)
        (setq gdev-org-calendar-context-root root
              default-directory root
              gdev-org-calendar--date (org-today))))
    (select-window window)
    (pop-to-buffer-same-window buffer)
    (gdev-org-calendar--read)
    (gdev-org-calendar-redraw)))

(provide 'gdev-org-calendar)
;;; gdev-org-calendar.el ends here
