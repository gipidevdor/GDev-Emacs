;;; gdev-test-coverage.el --- Rapporto e margine di copertura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il rapporto LCOV e il margine leggono lo stesso indice dello spazio.
;; Le finestre dipingono soltanto le righe visibili del documento corrente.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'gdev-activity)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)

(declare-function gdev-close-document "gdev-commands" ())
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))

(cl-defstruct gdev-test-coverage--report root files names covered total time)
(cl-defstruct gdev-test-coverage--file lines covered)
(cl-defstruct gdev-test-coverage--paint buffer file tick start anchor line end height overlays margin original)

(defconst gdev-test-coverage--page-size 100)
(defvar gdev-test-coverage--painted (make-hash-table :test #'eq))
(defvar-local gdev-test-coverage--root nil)
(defvar-local gdev-test-coverage--selected-file nil)
(defvar-local gdev-test-coverage--limit nil)
(defvar-local gdev-test-coverage--geometry nil)
(defvar-local gdev-test-coverage--rendered nil)

(defun gdev-test-coverage--directory (path)
  "Normalizza la radice PATH come quella dello spazio di lavoro."
  (file-name-as-directory (if (file-remote-p path) (expand-file-name path) (file-truename path))))

(defvar gdev-test-coverage--report-limit (* 32 1024 1024)
  "Dimensione massima, in byte, di un rapporto LCOV letto dall'interfaccia.
L'analisi gira nel thread principale: un rapporto di centinaia di MB
bloccherebbe l'editor per molti secondi.")

(defun gdev-test-coverage--read (path root)
  "Indicizza le righe di PATH relative a ROOT, unendo le sezioni ripetute."
  (when-let* ((size (file-attribute-size (file-attributes path)))
              ((> size gdev-test-coverage--report-limit)))
    (user-error "Il rapporto %s pesa %d MiB: oltre %d MiB non si legge nell'editor"
                (file-name-nondirectory path) (/ size 1024 1024)
                (/ gdev-test-coverage--report-limit 1024 1024)))
  (let ((records (make-hash-table :test #'equal))
        (files (make-hash-table :test #'equal))
        (time (file-attribute-modification-time (file-attributes path)))
        current names (covered 0) (total 0))
    (with-temp-buffer
      (insert-file-contents path)
      (let ((case-fold-search nil))
        (while (re-search-forward
                "^\\(?:SF:\\([^\r\n]+\\)\\|DA:\\([0-9]+\\),\\([0-9]+\\)\\(?:,[^\r\n]*\\)?\\|end_of_record\\)\r?$"
                nil t)
          (cond ((match-beginning 1)
                 (let ((file (expand-file-name (match-string 1) root)))
                   (setq current (or (gethash file records)
                                     (puthash file (make-hash-table :test #'eql) records)))))
                ((match-beginning 2)
                 (let ((line (string-to-number (match-string 2)))
                       (hits (string-to-number (match-string 3))))
                   (when (and current (fixnump line) (> line 0))
                     (puthash line (or (> hits 0) (gethash line current)) current))))
                (t (setq current nil))))))
    (when (zerop (hash-table-count records))
      (user-error "Il rapporto non contiene sezioni LCOV"))
    (maphash
     (lambda (file lines)
       (unless (zerop (hash-table-count lines))
         (let ((count 0) entries)
           (maphash (lambda (line hit)
                      (when hit (cl-incf count))
                      (push (cons line hit) entries))
                    lines)
           (push file names)
           (cl-incf covered count)
           (cl-incf total (length entries))
           (puthash file (make-gdev-test-coverage--file
                          :covered count :lines (vconcat (cl-sort entries #'< :key #'car)))
                    files))))
     records)
    (make-gdev-test-coverage--report :root root :files files :names (sort names #'string-lessp)
                                    :covered covered :total total :time time)))

(defun gdev-test-coverage--workspace (owner frame)
  "Ritrova la scheda OWNER, anche se trasferita a un altro frame."
  (seq-some (lambda (candidate)
              (when-let* (((frame-live-p candidate))
                          (tab (gdev-workspace-state-find owner candidate)))
                (cons candidate tab)))
            (cons frame (delq frame (frame-list)))))

(defun gdev-test-coverage-publish (path root owner frame)
  "Pubblica il rapporto LCOV di PATH per ROOT nella scheda OWNER di FRAME.
Restituisci non nil se lo spazio esiste ancora. Non cambiare il fuoco."
  (when (gdev-test-coverage--workspace owner frame)
    (let* ((root (gdev-test-coverage--directory root))
           (report (gdev-test-coverage--read path root)))
      (pcase (gdev-test-coverage--workspace owner frame)
        (`(,target . ,tab)
         (gdev-workspace-state-set
          'gdev-test-coverage-reports
          (cons (cons root report)
                (assoc-delete-all root (copy-sequence
                                        (gdev-workspace-state-read 'gdev-test-coverage-reports tab))))
          tab)
         (when (eq tab (gdev-workspace-state-current target))
           (gdev-test-coverage--sync-frame target))
         t)))))

(defun gdev-test-coverage--file-data (report path)
  "Restituisci i dati di PATH in REPORT."
  (gethash path (gdev-test-coverage--report-files report)))

(defun gdev-test-coverage--current-report (frame)
  "Trova il rapporto associato al sorgente corrente in FRAME."
  (when buffer-file-name
    (seq-some (lambda (entry)
                (let* ((report (cdr entry))
                       (data (or (gdev-test-coverage--file-data report buffer-file-name)
                                 (and buffer-file-truename
                                      (gdev-test-coverage--file-data report buffer-file-truename)))))
                  (and data (cons report data))))
              (gdev-workspace-state-get 'gdev-test-coverage-reports frame))))

(defun gdev-test-coverage--fresh-p (report)
  "Indica se il sorgente corrente ha ancora la revisione di REPORT."
  (and (not (buffer-modified-p))
       (not (time-less-p (gdev-test-coverage--report-time report) (visited-file-modtime)))))

(defun gdev-test-coverage--lower-bound (lines line)
  "Trova il primo indice di LINES con numero di riga almeno LINE."
  (let ((low 0) (high (length lines)))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (< (car (aref lines middle)) line) (setq low (1+ middle))
          (setq high middle))))
    low))

(defconst gdev-test-coverage--indicators
  (mapcar (lambda (entry)
            (pcase-let ((`(,glyph ,face ,help) entry))
              (propertize " " 'display `((margin right-margin)
                                         ,(propertize glyph 'face face 'help-echo help))
                          'help-echo help)))
          '(("+" gdev-ui-status-success "Riga eseguita dai test")
            ("!" gdev-ui-status-warning "Riga misurata e mai eseguita"))))

(defun gdev-test-coverage--clear-window (window)
  "Rilascia gli indicatori e il margine di WINDOW."
  (when-let* ((paint (gethash window gdev-test-coverage--painted)))
    (remhash window gdev-test-coverage--painted)
    (mapc #'delete-overlay (gdev-test-coverage--paint-overlays paint))
    (when (and (window-live-p window)
               (eq (window-buffer window) (gdev-test-coverage--paint-buffer paint)))
      (let ((margins (window-margins window)))
        (when (equal (cdr margins) (gdev-test-coverage--paint-margin paint))
          (set-window-margins window (car margins) (gdev-test-coverage--paint-original paint)))))))

(defun gdev-test-coverage--before-edit ()
  "Rimuovi la copertura appena inizia una modifica al sorgente."
  (dolist (window (get-buffer-window-list (current-buffer) 'not-minibuffer t))
    (gdev-test-coverage--clear-window window)))

(defun gdev-test-coverage--after-save ()
  "Verifica nuovamente la revisione del sorgente corrente."
  (mapc #'gdev-test-coverage--paint-window
        (get-buffer-window-list (current-buffer) 'not-minibuffer t)))

(defun gdev-test-coverage--paint-lines (window data start line end)
  "Mostra le righe di DATA visibili in WINDOW da START, LINE fino a END."
  (let* ((lines (gdev-test-coverage--file-lines data))
         (index (gdev-test-coverage--lower-bound lines line))
         overlays)
    (goto-char start)
    (while (and (< index (length lines)) (<= (point) end))
      (pcase-let ((`(,number . ,hit) (aref lines index)))
        (if (and (zerop (forward-line (- number line))) (<= (point) end))
            (let ((overlay (make-overlay (point) (min (1+ (point)) (point-max)))))
              (overlay-put overlay 'window window)
              (overlay-put overlay 'before-string (if hit (car gdev-test-coverage--indicators)
                                                    (cadr gdev-test-coverage--indicators)))
              (push overlay overlays)
              (setq line number))
          (goto-char (point-max))
          (setq index (length lines))))
      (cl-incf index))
    overlays))

(defun gdev-test-coverage--paint-window (window &optional display-start)
  "Aggiorna il margine di WINDOW da DISPLAY-START durante lo scorrimento."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let ((entry (and gdev-layout-mode (eq (frame-visible-p (window-frame window)) t)
                        (not (window-parameter window 'window-side))
                        (gdev-test-coverage--current-report (window-frame window))))
            (old (gethash window gdev-test-coverage--painted)))
        (if (not (and entry (gdev-test-coverage--fresh-p (car entry))))
            (when old (gdev-test-coverage--clear-window window))
          (let* ((data (cdr entry))
                 (tick (buffer-chars-modified-tick))
                 (height (window-body-height window))
                 (start (or display-start (window-start window)))
                 (end (unless display-start (window-end window)))
                 (margins (window-margins window))
                 (same-buffer (and old (eq (current-buffer) (gdev-test-coverage--paint-buffer old))))
                 (same (and same-buffer (= tick (gdev-test-coverage--paint-tick old))))
                 (owned (and same-buffer (equal (cdr margins) (gdev-test-coverage--paint-margin old)))))
            (unless (and owned same (eq data (gdev-test-coverage--paint-file old))
                         (= start (gdev-test-coverage--paint-start old))
                         (= height (gdev-test-coverage--paint-height old))
                         (or (null end) (equal end (gdev-test-coverage--paint-end old))))
              (gdev-test-coverage--redraw-lines window data start end old))))))))

(defun gdev-test-coverage--redraw-lines (window data start end old)
  "Mostra DATA nel tratto START–END di WINDOW, riusando la geometria OLD."
  (let* ((height (window-body-height window))
         (tick (buffer-chars-modified-tick))
         (margins (window-margins window))
         (same-buffer (and old (eq (current-buffer) (gdev-test-coverage--paint-buffer old))))
         (owned (and same-buffer (equal (cdr margins) (gdev-test-coverage--paint-margin old))))
         (original (if owned (gdev-test-coverage--paint-original old) (cdr margins)))
         (width (max 2 (1+ (or original 0))))
         (anchor (save-excursion (save-restriction (widen) (goto-char start) (line-beginning-position))))
         (last (save-excursion (goto-char start) (vertical-motion (1+ height) window) (point)))
         (line (save-restriction
                 (widen)
                 (let ((previous (and same-buffer (= tick (gdev-test-coverage--paint-tick old))
                                      (gdev-test-coverage--paint-anchor old))))
                   (if (and previous (< (abs (- anchor previous)) (- anchor (point-min))))
                       (+ (gdev-test-coverage--paint-line old)
                          (if (< anchor previous) (- (count-lines anchor previous))
                            (count-lines previous anchor)))
                     (line-number-at-pos anchor t)))))
         overlays)
    (when old (mapc #'delete-overlay (gdev-test-coverage--paint-overlays old)))
    (unless (equal (cdr margins) width) (set-window-margins window (car margins) width))
    (save-excursion
      (save-restriction
        (widen)
        (setq overlays (gdev-test-coverage--paint-lines window data anchor line last))))
    (puthash window (make-gdev-test-coverage--paint
                     :buffer (current-buffer) :file data :tick tick :start start :anchor anchor :line line
                     :end end :height height :overlays overlays :margin width :original original)
             gdev-test-coverage--painted)
    (add-hook 'first-change-hook #'gdev-test-coverage--before-edit nil t)
    (add-hook 'after-save-hook #'gdev-test-coverage--after-save nil t)
    (add-hook 'after-revert-hook #'gdev-test-coverage--after-save nil t)))

(defvar-keymap gdev-test-coverage-mode-map
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "q" #'gdev-close-document)

(define-derived-mode gdev-test-coverage-mode special-mode "Copertura"
  "Consulta la copertura dei test del progetto."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local hl-line-face 'gdev-ui-side-selection)
  (hl-line-mode 1))

(defun gdev-test-coverage--fit (window text)
  "Adatta TEXT al carattere del riquadro WINDOW."
  (let ((graphical (display-graphic-p (window-frame window))))
    (gdev-ui-fit-text text (max 0 (- (window-body-width window graphical) 4))
                      (if graphical (lambda (value)
                                      (string-pixel-width (propertize value 'face 'variable-pitch)))
                        #'string-width))))

(defun gdev-test-coverage--button (label identity command &optional help)
  "Inserisci LABEL con IDENTITY e azione COMMAND. HELP mostra il testo completo."
  (insert-text-button label 'type 'gdev-ui-action 'help-echo (or help label)
                      'gdev-test-coverage-id identity
                      'action (lambda (_) (funcall command)))
  (insert "\n"))

(defun gdev-test-coverage--summary (covered total)
  "Descrivi le righe COVERED su TOTAL."
  (if (zerop total) "Nessuna riga misurata"
    (format "%d di %d righe · %d%%" covered total (round (* 100.0 (/ covered (float total)))))))

(defun gdev-test-coverage--visit (report path &optional line)
  "Apri PATH nel gruppo editor e raggiungi LINE della revisione di REPORT."
  (unless (file-readable-p path) (user-error "Il sorgente non è disponibile"))
  (let ((buffer (or (find-buffer-visiting path) (find-file-noselect path))))
    (when line
      (unless (with-current-buffer buffer (gdev-test-coverage--fresh-p report))
        (user-error "Il sorgente è cambiato. Rigenera la copertura")))
    (gdev-open-file path)
    (when line
      (when (buffer-narrowed-p) (widen))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun gdev-test-coverage--select (file)
  "Passa al dettaglio di FILE, oppure al rapporto se FILE è nil."
  (setq gdev-test-coverage--selected-file file gdev-test-coverage--limit nil)
  (gdev-test-coverage--render (selected-window) t (or file 'files)))

(defun gdev-test-coverage--more ()
  "Mostra altre righe o altri file della pagina corrente."
  (setq gdev-test-coverage--limit (+ (or gdev-test-coverage--limit gdev-test-coverage--page-size)
                                    gdev-test-coverage--page-size))
  (gdev-test-coverage--render (selected-window) t))

(defun gdev-test-coverage--files (report window)
  "Disegna i file del REPORT nel riquadro WINDOW."
  (let ((root (gdev-test-coverage--report-root report)))
    (cl-loop for tail on (gdev-test-coverage--report-names report)
             for file = (car tail)
             for i from 0
             when (= i (or gdev-test-coverage--limit gdev-test-coverage--page-size))
             do (gdev-test-coverage--button "Mostra altri file" 'more #'gdev-test-coverage--more)
             and return nil
             do (let* ((path file)
                       (data (gdev-test-coverage--file-data report path)))
                  (gdev-test-coverage--button
                   (gdev-test-coverage--fit window (file-relative-name path root)) path
                   (lambda () (gdev-test-coverage--select path)) path)
                  (insert (propertize (gdev-test-coverage--summary
                                       (gdev-test-coverage--file-covered data)
                                       (length (gdev-test-coverage--file-lines data)))
                                      'face 'gdev-ui-secondary) "\n\n")))))

(defun gdev-test-coverage--detail (report file data window)
  "Disegna le righe del FILE in REPORT secondo DATA e WINDOW."
  (let ((lines (gdev-test-coverage--file-lines data)))
    (gdev-test-coverage--button "‹ Tutti i file" 'files (lambda () (gdev-test-coverage--select nil)))
    (insert (propertize (gdev-test-coverage--fit window (file-relative-name file gdev-test-coverage--root))
                        'face 'gdev-ui-view-heading 'help-echo file) "\n")
    (insert (propertize (gdev-test-coverage--summary (gdev-test-coverage--file-covered data)
                                                    (length lines)) 'face 'gdev-ui-secondary) "\n")
    (gdev-test-coverage--button "Apri sorgente" file (lambda () (gdev-test-coverage--visit report file)))
    (insert "\n")
    (cl-loop for i from 0 below (length lines)
             for (line . hit) = (aref lines i)
             when (= i (or gdev-test-coverage--limit gdev-test-coverage--page-size))
             do (gdev-test-coverage--button "Mostra altre righe" 'more #'gdev-test-coverage--more)
             and return nil
             do (let ((number line))
                  (gdev-test-coverage--button (format "%s Riga %d · %s" (if hit "+" "!") number
                                                     (if hit "eseguita" "mai eseguita"))
                                             number (lambda () (gdev-test-coverage--visit report file number)))))))

(defun gdev-test-coverage--render (window &optional force identity)
  "Aggiorna WINDOW se il rapporto cambia oppure con FORCE.
Se IDENTITY è presente, mantieni la selezione di tale elemento."
  (let* ((reports (gdev-workspace-state-get 'gdev-test-coverage-reports (window-frame window)))
         (report (cdr (assoc gdev-test-coverage--root reports)))
         (geometry (window-body-width window (display-graphic-p (window-frame window))))
         (old (or identity (when-let* ((button (button-at (window-point window))))
                             (button-get button 'gdev-test-coverage-id))))
         (file gdev-test-coverage--selected-file)
         (data (and report file (gdev-test-coverage--file-data report file))))
    (unless (and (not force) (eq report gdev-test-coverage--rendered)
                 (equal geometry gdev-test-coverage--geometry))
      (setq gdev-test-coverage--rendered report gdev-test-coverage--geometry geometry
            gdev-test-coverage--selected-file (and data file))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Copertura dei test" 'face 'gdev-ui-view-title) "\n\n")
        (cond (data (gdev-test-coverage--detail report file data window))
              (report
               (insert (propertize (gdev-test-coverage--summary (gdev-test-coverage--report-covered report)
                                                              (gdev-test-coverage--report-total report))
                                   'face 'gdev-ui-secondary) "\n\n")
               (gdev-test-coverage--files report window))
              (t (insert (propertize "Nessun rapporto per questo progetto" 'face 'gdev-ui-secondary) "\n")))
        (goto-char (point-min))
        (when old
          (let ((button (next-button (point-min) t)))
            (while (and button (not (equal old (button-get button 'gdev-test-coverage-id))))
              (setq button (next-button (button-end button))))
            (when button (goto-char (button-start button)))))
        (set-window-point window (point))))))

(defun gdev-test-coverage--render-frame (frame &optional force)
  "Aggiorna il rapporto visibile di FRAME, rileggendo il formato con FORCE."
  (when-let* (((eq (frame-visible-p frame) t))
              (buffer (alist-get 'coverage (gdev-workspace-state-get 'gdev-activity-buffers frame)))
              ((buffer-live-p buffer))
              (window (get-buffer-window buffer frame)))
    (with-current-buffer buffer (gdev-test-coverage--render window force))))

(defun gdev-test-coverage--sync-frame (frame)
  "Sincronizza i margini e il rapporto visibile di FRAME."
  (when (frame-live-p frame)
    (maphash (lambda (window _paint)
               (when (or (not (window-live-p window))
                         (not (eq (frame-visible-p (window-frame window)) t)))
                 (gdev-test-coverage--clear-window window)))
             gdev-test-coverage--painted)
    (when (and (eq (frame-visible-p frame) t)
               (or (gdev-workspace-state-get 'gdev-test-coverage-reports frame)
                   (> (hash-table-count gdev-test-coverage--painted) 0)))
      (mapc #'gdev-test-coverage--paint-window (window-list frame 'not-minibuffer)))
    (gdev-test-coverage--render-frame frame)))

(defun gdev-test-coverage--change-workspace (&rest _)
  "Sincronizza il margine al cambio di spazio o disposizione."
  (gdev-test-coverage--sync-frame (selected-frame)))

(defun gdev-test-coverage--change-theme ()
  "Ricalcola la misura dei nomi nei rapporti visibili."
  (dolist (frame (frame-list)) (gdev-test-coverage--render-frame frame t)))

(defun gdev-test-coverage-show (&optional root)
  "Mostra la copertura dello spazio attivo per ROOT o per il documento."
  (interactive)
  (unless gdev-layout-mode (user-error "Attiva il Workbench per visualizzare la copertura"))
  (let* ((editor (gdev-layout-editor))
         (frame (window-frame editor))
         (root (gdev-test-coverage--directory
                (or root (with-current-buffer (window-buffer editor)
                           (or (when-let* ((entry (gdev-test-coverage--current-report frame)))
                                 (gdev-test-coverage--report-root (car entry)))
                               (car (seq-find (lambda (entry) (string-prefix-p (car entry) default-directory))
                                              (gdev-workspace-state-get 'gdev-test-coverage-reports frame)))
                               (gdev-workspace-directory default-directory frame)
                               (gdev-project-root))))))
         (buffer (gdev-activity-buffer 'coverage "*Copertura dei test*" #'gdev-test-coverage-mode)))
    (with-current-buffer buffer
      (setq-local gdev-activity-kind nil)
      (unless (equal gdev-test-coverage--root root)
        (setq gdev-test-coverage--root root gdev-test-coverage--selected-file nil gdev-test-coverage--limit nil)))
    (pop-to-buffer buffer)
    (gdev-test-coverage--render (selected-window) t)))

(add-hook 'window-scroll-functions #'gdev-test-coverage--paint-window)
(add-hook 'window-state-change-functions #'gdev-test-coverage--sync-frame)
(add-hook 'tab-bar-tab-post-select-functions #'gdev-test-coverage--change-workspace)
(add-hook 'gdev-layout-mode-hook #'gdev-test-coverage--change-workspace)
(add-hook 'gdev-ui-after-theme-hook #'gdev-test-coverage--change-theme)

(provide 'gdev-test-coverage)
;;; gdev-test-coverage.el ends here
