;;; config.el --- :ui workspaces: una scheda per progetto, aree di testo separate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Uno spazio di lavoro è una scheda della barra delle schede di Emacs con il
;; proprio elenco di aree di testo, gestito dal pacchetto tabspaces. Aprire
;; un progetto con C-c w p crea il suo spazio di lavoro; da lì C-x b propone
;; solo le aree di testo di quello spazio (scrivi b e spazio nella richiesta
;; per vederli tutti). Gli spazi di lavoro si salvano all'uscita da Emacs e
;; si ripristinano all'avvio, dal cruscotto o con C-c q l.
;;
;; I documenti aperti compaiono in schede sopra ogni riquadro dell'area di
;; modifica. Trascina il titolo per riordinare o spostarlo in un altro
;; gruppo. C-c b <sinistra> e C-c b <destra> riordinano la scheda corrente.

;;; Code:

(require 'gdev-lib)
(require 'gdev-keys)
(require 'gdev-layout)
(require 'gdev-workspaces)

(defvar tab-line-tab-close-map)
(defvar tab-line-tab-map)
(defvar tab-line-auto-hscroll-buffer)
(defvar tab-line-left-button)
(defvar tab-line-right-button)
(defvar tab-line-left-map)
(defvar tab-line-right-map)
(defvar tab-line-close-button)
(defvar tab-line-close-modified-button)
(defvar tab-line-cache-key-function)
(defvar gdev-ui-after-theme-hook)
(defvar consult-buffer-sources)
(declare-function tab-line-format "tab-line" ())
(declare-function tab-line-force-update "tab-line" (all))
(declare-function tab-line-cache-key-default "tab-line" (tabs))
(declare-function tab-line-tab-name-format-default "tab-line")
(declare-function tab-line--get-tab-property "tab-line")
(declare-function tab-line-event-start "tab-line")
(declare-function tab-line-select-tab-buffer "tab-line" (buffer &optional window))
(declare-function tab-line-hscroll "tab-line" (&optional arg window))
(declare-function gdev-editor-preview-p "../workbench/gdev-editor-tabs")
(declare-function gdev-editor-transfer-group-p "../workbench/gdev-editor-tabs" (window))
(declare-function gdev-editor-move-to-group "../workbench/gdev-editor-tabs"
                  (target &optional source document before))
(autoload 'gdev-editor-transfer-group-p "gdev-editor-tabs")
(autoload 'gdev-editor-move-to-group "gdev-editor-tabs" nil t)
(declare-function gdev-ui-fit-text "../workbench/gdev-ui" (text width measure))
(declare-function gdev-ui-buffer-unsaved-p "../workbench/gdev-ui" (&optional buffer))
(declare-function gdev-split-editor-right "gdev-commands" (&optional source))
(declare-function gdev-split-editor-below "gdev-commands" (&optional source))
(declare-function gdev-split-editor-grid "gdev-commands" (&optional source))
(declare-function gdev-rotate-editor-pair "gdev-commands" (&optional source))
(declare-function gdev-close-editor-group "gdev-commands" (&optional source))
(defvar gdev-session-save-function)
(defvar gdev-session-load-function)
(defvar gdev-session-hot-exit-function)

(defface gdev-workspaces-tab-close-hover
  '((((background dark)) :background "#45454a" :foreground "#ffffff")
    (t :background "#dcdce1" :foreground "#1d1d1f"))
  "Evidenzia il pulsante di chiusura al passaggio del mouse."
  :group 'gdev-layout)

(define-key global-map [tab-line s-mouse-1] #'gdev-workspaces-click-beside)

(unless gdev-macos-p
  (define-key global-map [tab-line C-mouse-1] #'gdev-workspaces-click-beside))

(defun gdev-workspaces-click-beside (event)
  "Affianca il documento della scheda indicata da EVENT."
  (interactive "e")
  (let* ((position (tab-line-event-start event))
         (tab (tab-line--get-tab-property 'tab (car (posn-string position)))))
    (when (and gdev-layout-mode (buffer-live-p tab) (gdev-layout-document-tab-p tab))
      (gdev-layout-toggle-document-beside tab (posn-window position)))))

(defun gdev-workspaces--open-document (direction)
  "Scegli un documento da aprire in DIRECTION rispetto al gruppo attivo."
  (let* ((editor (gdev-layout-editor))
         (tabs (with-selected-window editor (gdev-workspaces--document-tabs)))
         (visible (seq-filter #'gdev-layout-document-tab-p
                              (mapcar #'window-buffer (gdev-layout--editors))))
         (other (remq (window-buffer editor)
                      (seq-uniq (append tabs visible)))))
    (unless other (user-error "Apri un altro documento nello spazio di lavoro"))
    (let ((name (completing-read (if (eq direction 'right) "Documento a destra: " "Documento in basso: ")
                                 (mapcar #'buffer-name other) nil t)))
      (gdev-layout-open-document-beside (get-buffer name) editor direction))))

(defun gdev-workspaces-open-beside ()
  "Scegli un documento da aprire a destra del gruppo editor attivo."
  (interactive)
  (gdev-workspaces--open-document 'right))

(defun gdev-workspaces-open-below ()
  "Scegli un documento da aprire sotto il gruppo editor attivo."
  (interactive)
  (gdev-workspaces--open-document 'below))

(defun gdev-workspaces-split-menu (event)
  "Mostra le disposizioni disponibili nel gruppo indicato da EVENT."
  (interactive "e")
  (let ((source (posn-window (event-start event))))
    (when (and gdev-layout-mode (window-live-p source)
               (not (window-parameter source 'window-side))
               (gdev-layout-document-tab-p (window-buffer source)))
      (let ((menu (make-sparse-keymap (propertize "Dividi" 'hide t)))
            (groups (length (gdev-layout--editors))))
        (define-key-after menu [right]
          `(menu-item "Dividi a destra" ,(lambda () (interactive) (gdev-split-editor-right source))
                      :enable ,(gdev-layout-editor-can-split-p source 'right)))
        (define-key-after menu [below]
          `(menu-item "Dividi in basso" ,(lambda () (interactive) (gdev-split-editor-below source))
                      :enable ,(gdev-layout-editor-can-split-p source 'below)))
        (define-key-after menu [grid]
          `(menu-item "Griglia 2×2" ,(lambda () (interactive) (gdev-split-editor-grid source))
                      :button (:toggle . ,(gdev-layout-editor-grid-p))))
        (when (= groups 2)
          (define-key-after menu [rotate]
            `(menu-item "Ruota i due gruppi" ,(lambda () (interactive) (gdev-rotate-editor-pair source)))))
        (when (> groups 1)
          (define-key-after menu [separator] '(menu-item "--"))
          (define-key-after menu [close]
            `(menu-item "Chiudi questo gruppo"
                        ,(lambda () (interactive) (gdev-close-editor-group source)))))
        (popup-menu menu event)))))

(defvar-keymap gdev-workspaces--split-map
  "<tab-line> <down-mouse-1>" #'ignore
  "<tab-line> <mouse-1>" #'gdev-workspaces-split-menu)

(defconst gdev-workspaces--split-button
  (propertize "  Dividi ▾  " 'face '(:inherit tab-line :weight semi-bold)
              'mouse-face 'gdev-ui-side-hover 'pointer 'hand
              'help-echo "Dividi questo gruppo o completa una griglia 2×2"
              'local-map gdev-workspaces--split-map))

(defconst gdev-workspaces--drop-label
  (propertize " Sposta " 'face 'gdev-ui-action-primary 'help-echo "Sposta la scheda alla fine di questo gruppo"))

(defvar gdev-workspaces--tab-title-width nil
  "Spazio in pixel per il titolo quando la riga contiene Dividi.")

(defvar gdev-workspaces--document-tab-map nil
  "Mappa dei titoli dei documenti, costruita al caricamento di `tab-line'.")

(defun gdev-workspaces--document-tab-line ()
  "Mostra il controllo Dividi prima delle schede del gruppo grafico."
  (if (and gdev-layout-mode (display-graphic-p)
           (not (window-parameter nil 'window-side)))
      (let ((width (- (window-pixel-width) (window-right-divider-width)))
            (document (current-buffer)))
        (unless (eql width (window-parameter nil 'gdev-workspaces-tab-width))
          (set-window-parameter nil 'gdev-workspaces-tab-width width)
          (set-window-parameter nil 'tab-line-cache nil))
        (let* ((control (if (eq (window-parameter nil 'gdev-workspaces-tab-drop) 'end)
                            gdev-workspaces--drop-label gdev-workspaces--split-button))
               (gdev-workspaces--tab-title-width
               (- width (string-pixel-width (concat gdev-workspaces--split-button
                                                    tab-line-left-button tab-line-right-button
                                                    tab-line-close-button))
                  (* 3 (frame-char-width)))))
          ;; Lo scorrimento nativo misura le schede in un buffer di prova.
          (with-current-buffer tab-line-auto-hscroll-buffer
            (let ((line-prefix gdev-workspaces--split-button))
              (with-current-buffer document
                (cons control (tab-line-format)))))))
    (tab-line-format)))

(defun gdev-workspaces--format-tab (tab tabs)
  "Formatta TAB, con evidenziazione distinta per il pulsante di chiusura."
  (let* ((label (tab-line-tab-name-format-default tab tabs))
         (close (text-property-any 0 (length label) 'keymap tab-line-tab-close-map label))
         (end (or close (length label))))
    (when (and gdev-layout-mode (buffer-live-p tab) (gdev-layout-document-tab-p tab))
      (put-text-property 0 end 'keymap gdev-workspaces--document-tab-map label)
      (let ((preview (and (fboundp 'gdev-editor-preview-p) (gdev-editor-preview-p tab))))
        (when preview
          (add-face-text-property 0 end 'italic nil label))
        (put-text-property 0 end 'help-echo
                           (concat (buffer-name tab)
                                   (if preview
                                       " · Anteprima\nDoppio clic sul file per conservare la scheda"
                                     (concat (when (gdev-ui-buffer-unsaved-p tab) " · Modifiche da salvare")
                                             (if gdev-macos-p "\n⌘ + clic per affiancare"
                                               "\nCtrl + clic per affiancare")))
                                   "\nTrascina per riordinare o spostare in un altro gruppo")
                           label))
      (when (gdev-layout-document-beside tab (selected-window))
        (add-face-text-property 0 end 'tab-line-tab-current nil label))
      (when (eq tab (window-parameter nil 'gdev-workspaces-tab-drop))
        (let ((face '(gdev-ui-side-selection (:underline t))))
          (add-face-text-property 0 end face nil label)
          (put-text-property 0 end 'mouse-face face label))))
    (when close
      (put-text-property close (length label) 'mouse-face
                         'gdev-workspaces-tab-close-hover label))
    label))

(defun gdev-workspaces--style-tabs ()
  "Applica la tipografia di sistema alle schede e conserva l'area di chiusura."
  (let* ((dark (eq (frame-parameter nil 'background-mode) 'dark))
         (strip (if dark "#202023" "#f0f0f3"))
         (active (if dark "#343947" "#dfe8fa"))
         (ink (if dark "#f0f2f8" "#202936"))
         (muted (if dark "#b9bac2" "#565660")))
    (dolist (face '(tab-line tab-line-tab tab-line-tab-inactive tab-line-tab-current))
      (when (facep face)
        (let* ((selected (memq face '(tab-line-tab tab-line-tab-current)))
               (background (if selected active strip)))
          (set-face-attribute face nil :height 1.0 :inherit 'variable-pitch
                              :weight (if selected 'medium 'normal) :slant 'normal
                              :foreground (if selected ink muted)
                              :background background
                              :box `(:line-width (1 . 3) :color ,background))))))
  (dolist (face '(tab-bar tab-bar-tab tab-bar-tab-inactive))
    (when (facep face)
      (set-face-attribute face nil :height 1.0 :inherit 'variable-pitch :slant 'normal
                          :weight (if (eq face 'tab-bar-tab) 'medium 'normal))))
  (setq tab-line-close-button
        (propertize "  ×  " 'keymap tab-line-tab-close-map
                    'help-echo "Chiudi scheda")
        tab-line-close-modified-button
        (propertize "  ×  " 'keymap tab-line-tab-close-map
                    'face 'warning
                    'help-echo "Chiudi scheda con modifiche"))
  (tab-line-force-update t))

(defun gdev-workspaces--tab-name (buffer _buffers)
  "Mostra il nome di BUFFER e l'asterisco quando contiene modifiche."
  (let ((name (concat "  " (gdev-ui-buffer-name buffer)))
        (modified (gdev-ui-buffer-unsaved-p buffer))
        (width gdev-workspaces--tab-title-width)
        (measure (lambda (text)
                   (string-pixel-width (propertize text 'face 'tab-line-tab-current)))))
    (cond ((not width) (if modified (concat name " *") name))
          ((not modified) (gdev-ui-fit-text name width measure))
          ((< width (funcall measure " *")) (gdev-ui-fit-text "*" width measure))
          (t (concat (gdev-ui-fit-text
                       name width (lambda (text) (funcall measure (concat text " *"))))
                      " *")))))

(defun gdev-workspaces--tab-modified-p (tab buffer-p)
  "Usa per la × di TAB la stessa regola dell'asterisco nel titolo.
BUFFER-P indica se TAB è un buffer o una lista con la chiave `buffer'."
  (when-let* ((buffer (if buffer-p tab (cdr (assq 'buffer tab)))))
    (gdev-ui-buffer-unsaved-p buffer)))

(defun gdev-workspaces--document-tab-cache-key (tabs)
  "Invalida la riga quando cambiano le modifiche o la destinazione tra TABS."
  (nconc (tab-line-cache-key-default tabs)
         (mapcar (lambda (tab) (and (bufferp tab) (gdev-ui-buffer-unsaved-p tab))) tabs)
         (when-let* ((target (window-parameter nil 'gdev-workspaces-tab-drop)))
           (list target))))

(defun gdev-workspaces--document-tabs ()
  "Restituisce i documenti aperti nel riquadro, in ordine stabile."
  (seq-filter #'gdev-layout-document-tab-p
              (tab-line-tabs-fixed-window-buffers)))

(defun gdev-workspaces--select-document (editor buffer)
  "Attiva la scheda di BUFFER nel gruppo EDITOR."
  (select-window editor)
  (tab-line-select-tab-buffer buffer editor))

(defun gdev-workspaces--document-tab-group-p (window)
  "Indica se WINDOW è un gruppo editor che può riordinare i propri documenti."
  (and (window-live-p window) (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side)) (not (window-dedicated-p window))))

(defun gdev-workspaces-document-move-available-p (step &optional buffer editor)
  "Indica se BUFFER può avanzare di STEP schede in EDITOR.
Senza BUFFER o EDITOR usa il documento o il gruppo attivo."
  (let ((editor (or editor (gdev-layout-editor))))
    (when (gdev-workspaces--document-tab-group-p editor)
      (let* ((tabs (window-parameter editor 'tab-line-buffers))
             (documents (seq-filter (lambda (tab) (and (buffer-live-p tab) (gdev-layout-document-tab-p tab)))
                                    tabs))
             (index (seq-position documents (or buffer (window-buffer editor)) #'eq)))
        (and index (<= 0 (+ index step)) (< (+ index step) (length documents)))))))

(defun gdev-workspaces--reorder-document (editor buffer tabs index)
  "Sposta BUFFER in EDITOR all'indice INDEX fra le schede TABS."
  (let ((remaining (remq buffer tabs)))
    (set-window-parameter editor 'tab-line-buffers
                          (append (seq-take remaining index) (list buffer)
                                  (seq-drop remaining index))))
  (set-window-parameter editor 'tab-line-hscroll nil)
  (set-window-parameter editor 'tab-line-cache nil)
  (gdev-workspaces--select-document editor buffer)
  (force-mode-line-update))

(defun gdev-workspaces--move-document (step buffer editor)
  "Sposta BUFFER di STEP schede nel gruppo EDITOR."
  (let ((editor (or editor (gdev-layout-editor))))
    (unless (gdev-workspaces--document-tab-group-p editor)
      (user-error "Scegli un gruppo editor"))
    (let* ((buffer (or buffer (window-buffer editor)))
           (tabs (with-selected-window editor (gdev-workspaces--document-tabs)))
           (index (seq-position tabs buffer #'eq)))
      (unless index (user-error "Scegli una scheda di documento"))
      (let ((destination (+ index step)))
        (unless (<= 0 destination (1- (length tabs)))
          (user-error "La scheda è già al bordo del gruppo"))
        (gdev-workspaces--reorder-document editor buffer tabs destination)))))

(defun gdev-workspaces-move-document-left (&optional buffer editor)
  "Sposta BUFFER a sinistra nel gruppo EDITOR.
Senza BUFFER o EDITOR usa il documento o il gruppo attivo."
  (interactive)
  (gdev-workspaces--move-document -1 buffer editor))

(defun gdev-workspaces-move-document-right (&optional buffer editor)
  "Sposta BUFFER a destra nel gruppo EDITOR.
Senza BUFFER o EDITOR usa il documento o il gruppo attivo."
  (interactive)
  (gdev-workspaces--move-document 1 buffer editor))

(defun gdev-workspaces--tab-string-at (position editor)
  "Restituisci il testo e l'indice della riga di EDITOR a POSITION."
  (when (and (eq (posn-window position) editor) (eq (posn-area position) 'tab-line))
    (posn-string position)))

(defun gdev-workspaces--document-tab-at (position editor)
  "Restituisci il documento indicato da POSITION nella riga di EDITOR."
  (when-let* ((string (car (gdev-workspaces--tab-string-at position editor)))
              (tab (tab-line--get-tab-property 'tab string)))
    (when (and (buffer-live-p tab) (gdev-layout-document-tab-p tab)) tab)))

(defun gdev-workspaces--tab-scroll-at (position editor)
  "Restituisci la direzione della freccia di EDITOR indicata da POSITION."
  (when-let* ((text (gdev-workspaces--tab-string-at position editor))
              (map (get-text-property (cdr text) 'keymap (car text))))
    (cond ((eq map tab-line-left-map) -1)
          ((eq map tab-line-right-map) 1))))

(defun gdev-workspaces--show-tab-drop (editor destination)
  "Evidenzia DESTINATION in EDITOR finché il trascinamento la indica."
  (when (and (window-live-p editor)
             (not (eq destination (window-parameter editor 'gdev-workspaces-tab-drop))))
    (set-window-parameter editor 'gdev-workspaces-tab-drop destination)
    (when-let* ((overlay (window-parameter editor 'gdev-workspaces-tab-drop-overlay)))
      (delete-overlay overlay)
      (set-window-parameter editor 'gdev-workspaces-tab-drop-overlay nil))
    (with-current-buffer (window-buffer editor)
      (when (and (eq destination 'end) (not (bound-and-true-p tab-line-mode)))
        (let* ((start (window-start editor))
               (overlay (make-overlay start start)))
          (overlay-put overlay 'window editor)
          (overlay-put overlay 'before-string (concat gdev-workspaces--drop-label "\n"))
          (set-window-parameter editor 'gdev-workspaces-tab-drop-overlay overlay)))
      (force-mode-line-update))))

(defun gdev-workspaces--tab-drop-at (position editor source)
  "Ricava gruppo e punto di inserimento di SOURCE da POSITION."
  (let ((target (posn-window position)))
    (when (and (gdev-workspaces--document-tab-group-p target)
               (eq (window-frame editor) (window-frame target)))
      (let ((tab (gdev-workspaces--document-tab-at position target)))
        (if (eq target editor)
            (when (and tab (not (eq tab source))) (cons target tab))
          (when (and (or tab (and (memq (posn-area position) '(nil tab-line header-line))
                                  (not (gdev-workspaces--tab-scroll-at position target))))
                     (gdev-editor-transfer-group-p target))
            (cons target (or tab 'end))))))))

(defun gdev-workspaces--track-tab (editor source owner scrolls)
  "Segui SOURCE in EDITOR e restituisci il rilascio nello spazio OWNER.
SCROLLS conserva gli scorrimenti prima del trascinamento."
  (let ((frame (window-frame editor)) hover scroll scrolling release)
    (unwind-protect
        (progn
          (track-mouse
            (while (and (window-live-p editor)
                        (progn (setq release (read-event nil nil (and scroll 0.35)))
                               (or (null release) (mouse-movement-p release)))
                        (window-live-p editor) (eq owner (gdev-workspace-state-id frame)))
              (if release
                  (let* ((position (event-end release))
                         (target (posn-window position))
                         (drop (gdev-workspaces--tab-drop-at position editor source)))
                    (unless (equal drop hover)
                      (when hover (gdev-workspaces--show-tab-drop (car hover) nil))
                      (when drop (gdev-workspaces--show-tab-drop (car drop) (cdr drop)))
                      (setq hover drop))
                    (setq scroll (and (gdev-workspaces--document-tab-group-p target)
                                      (eq frame (window-frame target))
                                      (gdev-workspaces--tab-scroll-at position target))
                          scrolling target))
                (when (window-live-p scrolling)
                  (let ((previous (window-parameter scrolling 'tab-line-hscroll)))
                    (unless (gethash scrolling scrolls)
                      (puthash scrolling (list previous) scrolls))
                    (tab-line-hscroll scroll scrolling)
                    (when (eql previous (window-parameter scrolling 'tab-line-hscroll))
                      (setq scroll nil)))))))
          release)
      (when hover (gdev-workspaces--show-tab-drop (car hover) nil)))))

(defun gdev-workspaces--restore-drag-scrolls (frame owner scrolls)
  "Ripristina SCROLLS nei gruppi ancora appartenenti a OWNER di FRAME."
  (when (and (frame-live-p frame) (eq owner (gdev-workspace-state-id frame)))
    (maphash (lambda (window initial)
               (when (window-live-p window)
                 (set-window-parameter window 'tab-line-hscroll (car initial))
                 (with-current-buffer (window-buffer window) (force-mode-line-update))))
             scrolls))
  (clrhash scrolls))

(defun gdev-workspaces--tab-press (event)
  "Apri, riordina o trasferisci la scheda indicata da EVENT."
  (interactive "e")
  (let* ((start (event-start event))
         (editor (posn-window start))
         (source (gdev-workspaces--document-tab-at start editor)))
    (when (and source (gdev-workspaces--document-tab-group-p editor))
      (let* ((frame (window-frame editor))
             (owner (gdev-workspace-state-ensure-id frame))
             (scrolls (make-hash-table :test #'eq)))
        (unwind-protect
            (let ((release (gdev-workspaces--track-tab editor source owner scrolls)))
              (gdev-workspaces--restore-drag-scrolls frame owner scrolls)
              (when (and (mouse-event-p release) (eq (event-basic-type release) 'mouse-1)
                         (window-live-p editor) (eq frame (selected-frame))
                         (eq owner (gdev-workspace-state-id frame)))
                (let* ((position (event-end release))
                       (tabs (with-selected-window editor (gdev-workspaces--document-tabs))))
                  (when (memq source tabs)
                    (if (memq 'drag (event-modifiers release))
                        (when-let* ((drop (gdev-workspaces--tab-drop-at position editor source)))
                          (let ((target (car drop)) (before (cdr drop)))
                            (if (eq editor target)
                                (when-let* ((index (seq-position tabs before #'eq)))
                                  (gdev-workspaces--reorder-document editor source tabs index))
                              (gdev-editor-move-to-group target editor source (unless (eq before 'end) before)))))
                      (when (eq source (gdev-workspaces--document-tab-at position editor))
                        (gdev-workspaces--select-document editor source)))))))
          (gdev-workspaces--restore-drag-scrolls frame owner scrolls))))))

(defun gdev-workspaces--step-document (step)
  "Vai alla scheda distante STEP posizioni nel gruppo editor attivo."
  (if-let* ((editor (gdev-layout-editor))
            (tabs (with-selected-window editor (gdev-workspaces--document-tabs))))
      (let ((index (seq-position tabs (window-buffer editor))))
        (gdev-workspaces--select-document
         editor (nth (if index (mod (+ index step) (length tabs)) 0) tabs)))
    (user-error "Apri un documento nel gruppo attivo")))

(defun gdev-workspaces-next-document ()
  "Vai alla scheda di documento successiva nel gruppo attivo."
  (interactive)
  (gdev-workspaces--step-document 1))

(defun gdev-workspaces-previous-document ()
  "Vai alla scheda di documento precedente nel gruppo attivo."
  (interactive)
  (gdev-workspaces--step-document -1))

(defun gdev-workspaces-switch-document ()
  "Scegli un documento aperto in uno dei gruppi dello spazio attivo."
  (interactive)
  (let* ((frame (selected-frame))
         (owner (gdev-workspace-state-ensure-id frame))
         (groups (gdev-layout--editors frame))
         (multiple (cdr groups))
         (candidates
          (cl-loop for editor in groups
                   for index from 1
                   append
                   (with-selected-window editor
                     (mapcar (lambda (buffer)
                               (cons (if multiple (format "Gruppo %d · %s" index (buffer-name buffer))
                                       (buffer-name buffer))
                                     (cons editor buffer)))
                             (gdev-workspaces--document-tabs))))))
    (unless candidates (user-error "Nessun documento aperto in questo spazio"))
    (pcase-let* ((name (completing-read "Documento aperto: " candidates nil t))
                 (`(,editor . ,buffer) (alist-get name candidates nil nil #'equal)))
      (unless (and (eq frame (selected-frame)) (eq owner (gdev-workspace-state-id frame))
                   (window-live-p editor)
                   (with-selected-window editor (memq buffer (gdev-workspaces--document-tabs))))
        (user-error "Lo spazio o la scheda sono cambiati. Riapri l'elenco"))
      (gdev-workspaces--select-document editor buffer))))

(defun gdev-workspaces--enable-document-tabs ()
  "Mostra la scheda del file o del documento corrente."
  (when (gdev-layout-document-tab-p (current-buffer))
    (setq-local tab-line-close-tab-function #'gdev-layout-close-editor-tab
                tab-line-cache-key-function #'gdev-workspaces--document-tab-cache-key)
    (unless (bound-and-true-p tab-line-mode)
      (tab-line-mode 1))
    (setq-local tab-line-format '(:eval (gdev-workspaces--document-tab-line)))))

(use-package tab-line
  :ensure nil
  :commands (tab-line-mode tab-line-tabs-fixed-window-buffers)
  :hook ((find-file gdev-new-document) . gdev-workspaces--enable-document-tabs)
  :custom
  (tab-line-tabs-function #'gdev-workspaces--document-tabs)
  (tab-line-tab-name-function #'gdev-workspaces--tab-name)
  (tab-line-tab-name-format-function #'gdev-workspaces--format-tab)
  (tab-line-new-button-show nil)
  (tab-line-close-button-show t)
  :config
  (when (fboundp 'tab-line-tab-modified-p)
    (advice-add 'tab-line-tab-modified-p :override #'gdev-workspaces--tab-modified-p))
  (setq gdev-workspaces--document-tab-map (make-sparse-keymap))
  (set-keymap-parent gdev-workspaces--document-tab-map tab-line-tab-map)
  (keymap-set gdev-workspaces--document-tab-map "<tab-line> <down-mouse-1>"
              #'gdev-workspaces--tab-press)
  (gdev-workspaces--style-tabs)
  (add-hook 'gdev-ui-after-theme-hook #'gdev-workspaces--style-tabs))

(setq tab-bar-show 1                    ; la barra compare da due schede in su
      tab-bar-close-button-show nil
      tab-bar-format '(tab-bar-format-tabs tab-bar-separator) ; senza pulsanti
      tab-bar-tab-hints t               ; numeri: C-c w 1..9
      tab-bar-new-tab-choice #'gdev-layout-home-buffer)
(add-hook 'emacs-startup-hook #'tab-bar-history-mode)

(use-package tabspaces
  :ensure t
  :hook (emacs-startup . tabspaces-mode)
  :commands (tabspaces-switch-or-create-workspace
             tabspaces-open-or-create-project-and-workspace
             tabspaces-close-workspace tabspaces-kill-buffers-close-workspace
             tabspaces-remove-current-buffer)
  :custom
  (tabspaces-default-tab "Principale")
  (tabspaces-remove-to-default t)
  (tabspaces-include-buffers '("*scratch*" "*Messages*" "*gdev*"))
  (tabspaces-initialize-project-with-todo nil)
  (tabspaces-session nil)               ; GDev salva il layout degli editor
  (tabspaces-session-auto-restore nil)
  (tabspaces-session-file (gdev-state-file "workspaces.eld"))
  :config
  ;; C-x b elenca i buffer dello spazio; con "b SPC" nella richiesta, tutti.
  (with-eval-after-load 'consult
    ;; Le versioni recenti di consult rinominano la fonte di tutti i buffer.
    (let ((all-buffers (if (boundp 'consult-source-buffer)
                           'consult-source-buffer
                         'consult--source-buffer)))
      (set all-buffers (thread-first (copy-sequence (symbol-value all-buffers))
                                     (plist-put :hidden t)
                                     (plist-put :default nil))))
    (defvar gdev-workspaces--consult-source
      (list :name "Aree di testo dello spazio di lavoro"
            :narrow ?w
            :history 'buffer-name-history
            :category 'buffer
            :state #'consult--buffer-state
            :default t
            :items (lambda () (consult--buffer-query :predicate #'tabspaces--local-buffer-p
                                                     :sort 'visibility
                                                     :as #'buffer-name)))
      "Fonte di consult-buffer limitata allo spazio di lavoro corrente.")
    (add-to-list 'consult-buffer-sources 'gdev-workspaces--consult-source)))

(setq gdev-session-save-function #'gdev-workspaces-save
      gdev-session-load-function #'gdev-workspaces-restore
      gdev-session-hot-exit-function #'gdev-workspaces-quit)
(advice-add 'tab-bar--tab :around #'gdev-workspaces--remember-layout)
(gdev-bind gdev-quit-map "L" "riprendi la sessione interrotta" #'gdev-workspaces-restore-interrupted)
(add-hook 'kill-emacs-hook #'gdev-workspaces-save-on-exit)

(defcustom gdev-workspaces-restore-at-startup nil
  "Non nil per riprendere la sessione all'avvio senza documenti.
Il cruscotto offre anche il comando «Riprendi ultima sessione»."
  :type 'boolean
  :group 'gdev)

(defun gdev-workspaces-start ()
  "Riprendi la sessione all'avvio e pianifica il salvataggio delle bozze."
  (unless noninteractive
    (when (and gdev-workspaces-restore-at-startup
               (not gdev-workspaces--session-active)
               (gdev-workspaces--initial-tab-p (tab-bar-tabs))
               (or (gdev-session-db-exists-p)
                   (file-exists-p (gdev-state-file "gdev-workspaces.eld"))
                   (file-exists-p tabspaces-session-file)))
      (with-demoted-errors "Ripristino della sessione: %S"
        (gdev-workspaces-restore)))
    (run-with-timer 30 30 #'gdev-workspaces-schedule-checkpoint)))

(add-hook 'window-setup-hook #'gdev-workspaces-start 90)

(declare-function consult--buffer-state "consult")
(declare-function consult--buffer-query "consult")
(declare-function tabspaces--local-buffer-p "tabspaces")

;;; config.el ends here
