;;; gdev-activity.el --- Viste laterali dello spazio di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Le attività condividono il riquadro sinistro. Ogni spazio conserva il
;; buffer, il cursore e lo scorrimento di ciascuna vista.

;;; Code:

(declare-function image-size "image.c" (spec &optional pixels frame))

(require 'gdev-modules)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'button)
(require 'cl-lib)
(require 'tab-line)

(defconst gdev-activity-views
  '((explorer "Esplora file" "file" "E" :ui sidebar gdev-sidebar-focus)
    (search "Cerca" "search" "C" :ui workbench gdev-search-show)
    (git "Hit" "git" "H" :tools git gdev-project-view-git)
    (run "Debug dello spazio" "debug" "D" :ui workbench gdev-project-view-run)
    (test "Test" "test" "T" :tools build gdev-project-view-tests)
    (lavorazioni "Lavorazioni" "code" "L" :ui workbench gdev-lavorazioni-pannello)))

(defun gdev-activity--available ()
  "Elenca le viste dei moduli attivi."
  (seq-filter (lambda (entry) (gdev-module-p (nth 4 entry) (nth 5 entry)))
              gdev-activity-views))

(defun gdev-activity--space (width graphical)
  "Restituisci uno spazio di WIDTH pixel con GRAPHICAL, altrimenti colonne."
  (if graphical
      (if (zerop width) "" (propertize " " 'display `(space :width (,width))))
    (make-string width ?\s)))

(defun gdev-activity--buttons (views active select frame width height)
  "Distribuisci VIEWS di FRAME su WIDTH, evidenziando ACTIVE.
SELECT riceve la vista scelta dopo aver selezionato il suo riquadro.
HEIGHT è l'altezza del carattere in pixel, o nil in un terminale."
  (let* ((count (length views))
         (size (and height (> count 0)
                    (min (round (* height 1.2)) (max 1 (- (/ width count) 2)))))
         (index 0)
         (start 0))
    (mapcar
     (pcase-lambda (`(,view ,label ,icon ,letter . ,_))
       (let* ((face (if (eq view active) 'tab-line-tab-current 'tab-line-tab-inactive))
              ;; Il bordo sopra e sotto riserva spazio verticale alle icone.
              (style (if height
                         (list `(:box (:line-width (0 . 6) :color ,(face-background face frame t))) face)
                       face))
              (picture (gdev-ui-icon icon letter frame face size))
              (image (get-text-property 0 'display picture))
              (glyph-width (cond (image (car (image-size image t frame)))
                                 (height (string-pixel-width (propertize picture 'face style)))
                                 (t (string-width picture))))
              (end (/ (* (cl-incf index) width) count))
              (padding (max 0 (- end start glyph-width)))
              (leading (/ padding 2))
              (keymap (make-sparse-keymap)))
         (setq start end)
         (define-key keymap [tab-line down-mouse-1] #'ignore)
         (define-key keymap [tab-line mouse-1]
                     (lambda (event)
                       (interactive "e")
                       (select-window (posn-window (event-start event)))
                       (funcall select view)))
         (propertize (concat (gdev-activity--space leading height) picture
                             (gdev-activity--space (- padding leading) height))
                     'keymap keymap 'help-echo label 'face style
                     'mouse-face (unless (eq view active) 'gdev-ui-side-hover))))
     views)))

(defun gdev-activity-tab-line (views active select)
  "Rendi VIEWS, con ACTIVE selezionata e comando SELECT.
VIEWS è una lista o una funzione che ricava le viste dai moduli attivi."
  (let* ((window (selected-window))
         (frame (window-frame window))
         (height (and (display-graphic-p frame) (frame-char-height frame)))
         ;; A differenza del testo, la barra passa anche sopra i margini e i bordi interni.
         (width (if height
                    (- (window-pixel-width window) (window-right-divider-width window))
                  (window-body-width window)))
         (stamp (list views active select width height (frame-parameter frame 'background-mode)
                      (and (functionp views) gdev-modules)))
         (cache (window-parameter window 'gdev-activity-tab-line-cache)))
    (if (equal stamp (car cache))
        (cdr cache)
      (let* ((entries (if (functionp views) (funcall views) views))
             (line (cons "" (gdev-activity--buttons entries active select frame width height))))
        (set-window-parameter window 'gdev-activity-tab-line-cache (cons stamp line))
        line))))

(defun gdev-activity--tab-line ()
  "Rendi la barra delle attività nella finestra di redisplay."
  (gdev-activity-tab-line #'gdev-activity--available
                          (or (gdev-workspace-state-get 'gdev-activity-view) 'explorer)
                          #'gdev-activity-select))

(defun gdev-activity-decorate (window)
  "Mostra in WINDOW i pulsanti delle viste laterali."
  (set-window-parameter window 'gdev-activity-tab-line-cache nil)
  (set-window-parameter window 'tab-line-format '(:eval (gdev-activity--tab-line)))
  (force-mode-line-update t))

(defun gdev-activity-refresh-chrome ()
  "Aggiorna le icone dei riquadri visibili al cambio di aspetto."
  (dolist (frame (frame-list))
    (dolist (window (list (gdev-layout-left-window frame) (gdev-layout-command-sidebar-window frame)))
      (when window
        (set-window-parameter window 'gdev-activity-tab-line-cache nil))))
  (force-mode-line-update t))

(defun gdev-activity-close-tab (tab last-tab)
  "Rilascia le viste temporanee di TAB quando rimangono altri spazi."
  (unless last-tab
    (unless gdev-workspace-state--moving-tab
      (dolist (entry (gdev-workspace-state-read 'gdev-activity-buffers tab))
        (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry)))))
    (dolist (field (if gdev-workspace-state--moving-tab
                       '(gdev-preferences-buffer)
                     '(gdev-preferences-buffer gdev-timeline-buffer)))
      (let ((view (gdev-workspace-state-read field tab)))
        (when (buffer-live-p view) (kill-buffer view))))))

(defun gdev-activity-buffer (view name mode)
  "Restituisce il buffer di VIEW nello spazio corrente, con NAME e MODE."
  (let* ((buffers (gdev-workspace-state-get 'gdev-activity-buffers))
         (buffer (alist-get view buffers)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer name))
      (with-current-buffer buffer
        (funcall mode)
        (setq-local gdev-activity-kind view))
      (gdev-workspace-state-set 'gdev-activity-buffers
                                (cons (cons view buffer)
                                      (assq-delete-all view (copy-sequence buffers)))))
    buffer))

(defun gdev-activity-save-position (window)
  "Salva cursore e scorrimento di WINDOW nello spazio della sua finestra."
  (when (window-live-p window)
    (let ((tab (gdev-workspace-state-current (window-frame window))))
      (with-current-buffer (window-buffer window)
        (gdev-workspace-state-set
         'gdev-activity-positions
         (cons (list (current-buffer) (copy-marker (window-point window))
                     (copy-marker (window-start window)))
               (assq-delete-all (current-buffer)
                                (copy-sequence
                                 (gdev-workspace-state-read 'gdev-activity-positions tab))))
         tab)))))

(defun gdev-activity-restore-position (window)
  "Ripristina cursore e scorrimento del buffer di WINDOW."
  (when-let* ((position (assq (window-buffer window)
                             (gdev-workspace-state-get 'gdev-activity-positions (window-frame window)))))
    (set-window-start window (nth 2 position) t)
    (set-window-point window (nth 1 position))))

(defun gdev-activity-display (buffer view &optional keep-focus)
  "Mostra BUFFER nella vista VIEW. Con KEEP-FOCUS conserva il fuoco."
  (with-current-buffer buffer (setq-local gdev-activity-kind view))
  (when-let* ((window (gdev-layout-show-left buffer 'gdev-activity)))
    (gdev-workspace-state-set 'gdev-activity-view view)
    (gdev-activity-decorate window)
    (unless keep-focus (select-window window))
    window))

(defun gdev-activity-select (&optional view)
  "Passa alla vista laterale VIEW nello spazio corrente."
  (interactive)
  (let* ((available (gdev-activity--available))
         (labels (mapcar (lambda (entry) (cons (nth 1 entry) (car entry))) available))
         (view (or view (cdr (assoc (completing-read "Vista laterale: " labels nil t) labels))))
         (command (nth 6 (assq view available))))
    (unless (commandp command) (user-error "Vista laterale non disponibile"))
    (call-interactively command)))

(defun gdev-activity-restore ()
  "Riprendi la vista richiesta senza selezionarla o avviare strumenti."
  (let ((view (gdev-workspace-state-get 'gdev-activity-view))
        (window (gdev-layout-left-window)))
    (cond ((and window (window-parameter window 'gdev-activity)
                (eq (window-buffer window) (alist-get view (gdev-workspace-state-get 'gdev-activity-buffers))))
           (when (and (memq view '(git run test)) (fboundp 'gdev-project-view-sync))
             (gdev-project-view-sync (window-buffer window))))
          ((and (or (not window) (window-parameter window 'gdev-activity))
                view (assq view (gdev-activity--available))
                (not (gdev-workspace-state-get 'gdev-layout-explorer-hidden))
                (not (frame-parameter nil 'gdev-layout-focus)))
           (when-let* ((buffer (pcase view
                                 ('search (and (fboundp 'gdev-search-buffer) (gdev-search-buffer)))
                                 ('lavorazioni (and (fboundp 'gdev-lavorazioni-buffer)
                                                     (gdev-lavorazioni-buffer)))
                                 (_ (and (fboundp 'gdev-project-view-buffer)
                                         (gdev-project-view-buffer view))))))
             (gdev-activity-display buffer view t))))
    (when (and (or (eq view 'run) (bound-and-true-p gdev-debug-workbench--timer))
               (fboundp 'gdev-debug-workbench-refresh-visible))
      (gdev-debug-workbench-refresh-visible))))

(declare-function gdev-debug-workbench-refresh-visible "gdev-debug-workbench"
                  (&optional system-only))

(defun gdev-activity-toggle ()
  "Nascondi o riprendi l'ultima vista laterale."
  (interactive)
  (if-let* ((window (gdev-layout-left-window)))
      (delete-window window)
    (let ((view (gdev-workspace-state-get 'gdev-activity-view))
          (available (gdev-activity--available)))
      (gdev-activity-select (or (car (assq view available)) (caar available))))))

(declare-function gdev-search-buffer "gdev-search")
(declare-function gdev-lavorazioni-buffer "gdev-lavorazioni" ())
(declare-function gdev-project-view-buffer "gdev-project-view")
(declare-function gdev-project-view-sync "gdev-project-view")

(provide 'gdev-activity)
;;; gdev-activity.el ends here
