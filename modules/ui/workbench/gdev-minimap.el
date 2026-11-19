;;; gdev-minimap.el --- Minimap del documento attivo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La vista a destra segue il gruppo attivo e appartiene allo spazio di
;; lavoro. Il suo contenuto si ridimensiona in funzione dell'altezza.
;; Le corsie mostrano i risultati pubblicati da Cerca e Flymake.

;;; Code:

(require 'gdev-layout)
(require 'gdev-workspace-state)
(require 'face-remap)

(declare-function gdev-search-document-hits "gdev-search" (frame file &optional alias))
(declare-function gdev-search-hit-line "gdev-search" (hit))
(declare-function gdev-search-hit-source "gdev-search" (hit))
(declare-function gdev-search-hit-ranges "gdev-search" (hit))
(declare-function flymake-diagnostics "flymake" (&optional begin end))
(declare-function flymake-diagnostic-type "flymake" (diagnostic))
(declare-function flymake--diag-overlay "flymake" (diagnostic))

(defface gdev-minimap-viewport
  '((((background dark)) :background "#374253" :extend t)
    (t :background "#e1e9f6" :extend t))
  "Zona del documento visibile nell'editor."
  :group 'gdev-layout)

(defface gdev-minimap-ink
  '((((background dark)) :foreground "#adbbd0")
    (t :foreground "#4f5e71"))
  "Testo in miniatura sullo sfondo normale e sul riquadro evidenziato."
  :group 'gdev-layout)

(defface gdev-minimap-error
  '((((background dark)) :inherit error :foreground "#ffb5ac")
    (((background light)) :inherit error :foreground "#a22531"))
  "Errore leggibile anche sopra la zona evidenziata della minimappa."
  :group 'gdev-layout)

(defconst gdev-minimap--width 18
  "Larghezza della minimappa in colonne della finestra principale.")

(defvar-local gdev-minimap--editor nil)
(defvar-local gdev-minimap--rows nil)
(defvar-local gdev-minimap--content-key nil)
(defvar-local gdev-minimap--viewport nil)
(defvar-local gdev-minimap--search-cache nil)
(defvar-local gdev-minimap--diagnostics-cache nil)
(defvar-local gdev-minimap--marks-key nil)

(defconst gdev-minimap--jump-help "Vai a un punto del documento con un clic o trascinando")
(defconst gdev-minimap--glyphs
  '((search "+" gdev-ui-action "Risultato di ricerca" 0)
    (:error "X" gdev-minimap-error "Errore" 3)
    (:warning "!" gdev-ui-status-warning "Avviso" 2)
    (:note "i" gdev-minimap-ink "Nota" 1))
  "Carattere, faccia, descrizione e precedenza di ogni indicatore.")

(defvar-keymap gdev-minimap-mode-map
  :parent special-mode-map
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'gdev-minimap-jump
  "<drag-mouse-1>" #'gdev-minimap-jump
  "q" #'gdev-minimap-toggle)

(define-derived-mode gdev-minimap-mode special-mode "Minimappa"
  "Vista d'insieme del documento attivo."
  (gdev-ui-view-setup 'preview)
  (setq-local mode-line-format nil header-line-format nil tab-line-format nil
              display-line-numbers nil cursor-type nil truncate-lines t
              line-spacing 0)
  (face-remap-add-relative 'default 'gdev-minimap-ink '(:height 0.30)))

(defun gdev-minimap--snapshot (buffer rows)
  "Leggi al massimo ROWS righe rappresentative di BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let* ((size (- (point-max) (point-min)))
             (stride (unless (> size 1000000)
                       (max 1 (ceiling (count-lines (point-min) (point-max)) rows))))
             samples)
        (dotimes (row rows)
          (when (or (zerop row) (< (point) (point-max)))
            (unless stride (goto-char (+ (point-min) (floor (* row size) rows))))
            (let* ((start (point))
                   (limit (min (point-max) (+ start 90)))
                   (end (save-excursion (if (search-forward "\n" limit t) (1- (point)) limit))))
              (push (cons start (buffer-substring-no-properties start end)) samples))
            (when stride (forward-line stride))))
        (nreverse samples)))))

(defun gdev-minimap--row (position)
  "Restituisci l'indice della riga della minimappa per POSITION."
  (let ((low 0) (high (length gdev-minimap--rows)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (<= (aref gdev-minimap--rows middle) position)
            (setq low (1+ middle))
          (setq high middle))))
    (max 0 (1- low))))

(defun gdev-minimap--search-positions (hits)
  "Trova le posizioni di HITS che corrispondono al testo corrente."
  (let ((first (point-min)) (last (point-max)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((line 1) positions)
          (dolist (hit hits)
            (when (zerop (forward-line (- (gdev-search-hit-line hit) line)))
              (setq line (gdev-search-hit-line hit))
              (let* ((text (gdev-search-hit-source hit))
                     (end (line-end-position))
                     (target (+ (point) (or (caar (gdev-search-hit-ranges hit)) 0))))
                (when (and (<= first target) (< target last) (<= target end)
                           (= (length text) (- end (point)))
                           (equal text (buffer-substring-no-properties (point) end)))
                  (push (cons target 'search) positions)))))
          positions)))))

(defun gdev-minimap--search-marks (source frame)
  "Restituisci i risultati di Cerca già pubblicati per SOURCE in FRAME."
  (let* ((hits (with-current-buffer source
                 (when (and buffer-file-name (not (buffer-modified-p))
                            (fboundp 'gdev-search-document-hits))
                   (gdev-search-document-hits frame buffer-file-name buffer-file-truename))))
         (key (and hits (cons (seq-take gdev-minimap--content-key 4) hits))))
    (unless (equal key (car gdev-minimap--search-cache))
      (setq gdev-minimap--search-cache
            (and key (cons key (with-current-buffer source (gdev-minimap--search-positions hits))))))
    (cdr gdev-minimap--search-cache)))

(defun gdev-minimap--diagnostic-marks (source)
  "Leggi le segnalazioni già mostrate da Flymake in SOURCE."
  (let ((key (and (with-current-buffer source (bound-and-true-p flymake-mode))
                  (seq-take gdev-minimap--content-key 4))))
    (unless (equal key (car gdev-minimap--diagnostics-cache))
      (setq gdev-minimap--diagnostics-cache
            (and key
                 (cons key
                       (with-current-buffer source
                         (delq nil
                               (mapcar
                                (lambda (diagnostic)
                                  (when-let* ((overlay (flymake--diag-overlay diagnostic))
                                              (start (overlay-start overlay))
                                              ((<= (point-min) start)) ((< start (point-max))))
                                    (let ((type (flymake-diagnostic-type diagnostic)))
                                      (cons start (if (memq type '(:error :warning)) type :note)))))
                                (flymake-diagnostics (point-min) (point-max)))))))))
    (cdr gdev-minimap--diagnostics-cache)))

(defun gdev-minimap--mark-order (marks)
  "Riconosci l'ordine monotono di MARKS in un passaggio, senza modificarli."
  (let ((ascending t) (descending t))
    (while (and (cdr marks) (or ascending descending))
      (let ((first (caar marks)) (next (caadr marks)))
        (when (> first next) (setq ascending nil))
        (when (< first next) (setq descending nil)))
      (setq marks (cdr marks)))
    (cond (ascending 'ascending) (descending 'descending))))

(defun gdev-minimap--buckets (marks)
  "Raggruppa MARKS conservando la prima posizione del livello più grave.
Con M marcatori ordinati e R righe usa una scansione O(M + R), in entrambi
i versi. Per posizioni disordinate conserva la ricerca O(M log R + R)."
  (let ((rows (make-vector (length gdev-minimap--rows) nil)))
    (when (> (length rows) 0)
      (let* ((order (gdev-minimap--mark-order marks))
             (index (if (eq order 'descending) (1- (length rows)) 0)))
	(dolist (mark marks)
	  (let* ((position (car mark))
		 (row (if (not order) (gdev-minimap--row position)
			(if (eq order 'ascending)
                            (while (and (< index (1- (length rows)))
					(<= (aref gdev-minimap--rows (1+ index)) position))
                              (cl-incf index))
			  (while (and (> index 0) (> (aref gdev-minimap--rows index) position))
                            (cl-decf index)))
			index))
		 (previous (aref rows row))
		 (rank (nth 4 (assq (cdr mark) gdev-minimap--glyphs)))
		 (old-rank (and previous (nth 4 (assq (nth 1 previous) gdev-minimap--glyphs))))
		 (count (if previous (1+ (nth 2 previous)) 1)))
            (if (or (not previous) (> rank old-rank)
                    (and (= rank old-rank) (< (car mark) (car previous))))
		(aset rows row (list (car mark) (cdr mark) count))
              (setcar (cddr previous) count))))))
    rows))

(defun gdev-minimap--paint-mark (point mark)
  "Mostra MARK nella corsia di due caratteri che inizia a POINT."
  (when mark
    (pcase-let* ((`(,target ,kind ,count) mark)
                 (`(,_ ,glyph ,face ,label ,_) (assq kind gdev-minimap--glyphs))
                 (help (cond ((= count 1) label)
                             ((eq kind 'search) (format "%d righe con risultati di ricerca" count))
                             (t (format "%s · %d segnalazioni in questa sezione" label count)))))
      (put-text-property point (1+ point) 'display (propertize glyph 'face (list face 'bold)))
      (add-text-properties point (+ point 2) `(help-echo ,help gdev-minimap-target ,target)))))

(defun gdev-minimap--paint-marks (source frame)
  "Ridisponi le corsie solo quando cambiano risultati o campioni."
  (let* ((search (gdev-minimap--search-marks source frame))
         (diagnostics (gdev-minimap--diagnostic-marks source))
         (key (list gdev-minimap--content-key search diagnostics)))
    (unless (equal key gdev-minimap--marks-key)
      (let ((search (gdev-minimap--buckets search))
            (diagnostics (gdev-minimap--buckets diagnostics))
            (inhibit-read-only t))
        (with-silent-modifications
          (remove-list-of-text-properties (point-min) (point-max) '(display gdev-minimap-target))
          (put-text-property (point-min) (point-max) 'help-echo gdev-minimap--jump-help)
          (save-excursion
            (goto-char (point-min))
            (dotimes (row (length gdev-minimap--rows))
              (gdev-minimap--paint-mark (point) (aref search row))
              (gdev-minimap--paint-mark (+ (point) 2) (aref diagnostics row))
              (forward-line 1)))))
      (setq gdev-minimap--marks-key key))))

(defun gdev-minimap--render (side editor)
  "Aggiorna il contenuto e l'area evidenziata in SIDE per EDITOR."
  (let* ((source (window-buffer editor))
         (frame (window-frame side))
         (row-height (max 4 (ceiling (* 0.36 (frame-char-height frame)))))
         (rows (max 1 (min 500 (/ (window-body-height side t) row-height))))
         (key (with-current-buffer source (list source (buffer-chars-modified-tick) (point-min) (point-max) rows)))
         (first (window-start editor))
         (last (max first (1- (or (window-end editor) first)))))
    (with-current-buffer (window-buffer side)
      (setq gdev-minimap--editor editor)
      (unless (equal key gdev-minimap--content-key)
        (let ((inhibit-read-only t)
              (samples (gdev-minimap--snapshot source rows)))
          (erase-buffer)
          (dolist (sample samples) (insert "    " (cdr sample) "\n"))
          (setq gdev-minimap--content-key key
                gdev-minimap--rows (vconcat (mapcar #'car samples)))
          (set-window-start side (point-min))))
      (gdev-minimap--paint-marks source frame)
      (save-excursion
        (goto-char (point-min))
        (forward-line (gdev-minimap--row first))
        (let ((start (point)))
          (forward-line (1+ (- (gdev-minimap--row last) (gdev-minimap--row first))))
          (unless (overlayp gdev-minimap--viewport)
            (setq gdev-minimap--viewport (make-overlay start (point)))
            (overlay-put gdev-minimap--viewport 'face 'gdev-minimap-viewport))
          (move-overlay gdev-minimap--viewport start (point)))))))

(defun gdev-minimap--open ()
  "Mostra l'area di testo della minimappa nel posto assegnato a destra."
  (let ((main (window-main-window)))
    (when (>= (window-total-width main) (+ (window-min-size main t) gdev-minimap--width))
      (let ((buffer (frame-parameter nil 'gdev-minimap-buffer)))
        (unless (buffer-live-p buffer)
          (setq buffer (generate-new-buffer " *GDev minimappa*"))
          (set-frame-parameter nil 'gdev-minimap-buffer buffer)
          (with-current-buffer buffer (gdev-minimap-mode)))
        (with-current-buffer buffer (setq gdev-minimap--diagnostics-cache nil))
        (display-buffer-in-side-window
         buffer `((side . right) (slot . 0) (window-width . ,gdev-minimap--width)
                  (preserve-size . (t . nil)) (dedicated . t)
                  (window-parameters . ((gdev-minimap . t)
                                        (delete-window . gdev-layout--delete-side)
                                        (split-window . gdev-layout--reject-side-split)
                                        (no-other-window . t)
                                        (no-delete-other-windows . t)))))))))

(defun gdev-minimap--sync (frame)
  "Allinea la minimappa di FRAME con il documento del gruppo attivo."
  (when (frame-live-p frame)
    (set-frame-parameter frame 'gdev-minimap-update nil)
    (unless (active-minibuffer-window)
      (with-selected-frame frame
        (let ((side (window-with-parameter 'gdev-minimap t))
              (editor (gdev-layout-editor)))
          (if (gdev-minimap-requested-p frame)
              (progn
                (when-let* ((auxiliary (gdev-layout-auxiliary-window frame)))
                  (gdev-layout--fit-auxiliary auxiliary))
                (when-let* ((commands (gdev-layout-command-sidebar-window frame)))
                  (gdev-layout--remove-side commands))
                (when-let* ((side (or side (gdev-minimap--open))))
                  (gdev-minimap--render side editor)))
            (when side
              (let ((ignore-window-parameters t)) (delete-window side)))))))))

(defun gdev-minimap-requested-p (&optional frame)
  "Restituisci non nil se nello spazio di FRAME la minimappa può aprirsi."
  (and gdev-layout-mode (display-graphic-p frame)
       (gdev-workspace-state-get 'gdev-layout-minimap-visible frame)
       (not (frame-parameter frame 'gdev-layout-focus))
       (when-let* ((editor (gdev-layout-editor frame)))
         (gdev-layout-document-tab-p (window-buffer editor)))))

(defun gdev-minimap--schedule (frame)
  "Aggiorna dopo il ridisegno, accorpando gli eventi di FRAME."
  (when (and (display-graphic-p frame) (not (frame-parent frame))
             (not (frame-parameter frame 'gdev-minimap-update))
             (or (window-with-parameter 'gdev-minimap t frame)
                 (gdev-workspace-state-get 'gdev-layout-minimap-visible frame)))
    (set-frame-parameter frame 'gdev-minimap-update (run-at-time 0.06 nil #'gdev-minimap--sync frame))))

(defun gdev-minimap--after-command ()
  "Programma l'aggiornamento della finestra corrente."
  (gdev-minimap--schedule (selected-frame)))

(defun gdev-minimap--after-scroll (window _start)
  "Programma l'aggiornamento dopo lo scorrimento di WINDOW."
  (unless (window-parameter window 'window-side)
    (gdev-minimap--schedule (window-frame window))))

(defun gdev-minimap--search-changed ()
  "Pianifica il ridisegno delle minimappe dello spazio della ricerca."
  (let ((view (current-buffer)))
    (dolist (frame (visible-frame-list))
      (when (and (window-with-parameter 'gdev-minimap t frame)
                 (eq view (alist-get 'search (gdev-workspace-state-get 'gdev-activity-buffers frame))))
        (gdev-minimap--schedule frame)))))

(defun gdev-minimap--diagnostics-changed (&rest _)
  "Invalida le mappe visibili dopo un rapporto accettato da Flymake.
Il rapporto può anche aggiornare le segnalazioni di un altro buffer."
  (dolist (frame (visible-frame-list))
    (when-let* ((side (window-with-parameter 'gdev-minimap t frame)))
      (with-current-buffer (window-buffer side)
        (setq gdev-minimap--diagnostics-cache nil))
      (gdev-minimap--schedule frame))))

(defun gdev-minimap--discard-frame (frame)
  "Libera l'area di testo riservato alla minimappa di FRAME."
  (when-let* ((timer (frame-parameter frame 'gdev-minimap-update)))
    (cancel-timer timer))
  (when-let* ((buffer (frame-parameter frame 'gdev-minimap-buffer))
              ((buffer-live-p buffer)))
    (kill-buffer buffer)))

(defun gdev-minimap-toggle ()
  "Mostra o nascondi la minimappa nello spazio di lavoro corrente."
  (interactive)
  (unless (and gdev-layout-mode (display-graphic-p))
    (user-error "La minimappa è disponibile nella finestra grafica di GDev"))
  (when (and (frame-parameter nil 'gdev-layout-focus)
             (not (gdev-workspace-state-get 'gdev-layout-minimap-visible)))
    (gdev-layout-exit-focus))
  (gdev-workspace-state-set 'gdev-layout-minimap-visible
                            (not (gdev-workspace-state-get 'gdev-layout-minimap-visible)))
  (gdev-minimap--sync (selected-frame)))

(defun gdev-minimap-jump (event)
  "Porta l'editor al marcatore o alla riga indicati da EVENT nella minimappa."
  (interactive "e")
  (let* ((position (event-end event))
         (side (posn-window position))
         (point (posn-point position)))
    (when (and (window-live-p side) (integer-or-marker-p point))
      (let* ((mirror (window-buffer side))
             (editor (buffer-local-value 'gdev-minimap--editor mirror))
             (document (seq-take (buffer-local-value 'gdev-minimap--content-key mirror) 4)))
        (when (and (window-live-p editor) (eq editor (gdev-layout-editor (window-frame side)))
                   (with-current-buffer (window-buffer editor)
                     (equal document (list (current-buffer) (buffer-chars-modified-tick) (point-min) (point-max)))))
          (when-let* ((target (with-current-buffer mirror
                               (when (> (length gdev-minimap--rows) 0)
                                 (or (and (not (memq 'drag (event-modifiers event)))
                                          (get-text-property point 'gdev-minimap-target))
                                     (aref gdev-minimap--rows (min (1- (length gdev-minimap--rows))
                                                                 (1- (line-number-at-pos point)))))))))
            (select-window editor)
            (goto-char target)
            (recenter)))))))

(defun gdev-minimap-install ()
  "Collega la minimappa alle transizioni della finestra."
  (add-hook 'window-state-change-functions #'gdev-minimap--schedule)
  (add-hook 'post-command-hook #'gdev-minimap--after-command)
  (add-hook 'window-scroll-functions #'gdev-minimap--after-scroll)
  (add-hook 'delete-frame-functions #'gdev-minimap--discard-frame)
  (add-hook 'gdev-search-results-change-hook #'gdev-minimap--search-changed)
  (add-hook 'flymake-mode-hook #'gdev-minimap--diagnostics-changed)
  (with-eval-after-load 'flymake
    (advice-add 'flymake--publish-diagnostics :after #'gdev-minimap--diagnostics-changed)))

(provide 'gdev-minimap)
;;; gdev-minimap.el ends here
