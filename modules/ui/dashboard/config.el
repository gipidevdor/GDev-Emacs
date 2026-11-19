;;; config.el --- :ui dashboard: la schermata iniziale -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il cruscotto è la prima schermata quando Emacs parte senza
;; file: il logo, le azioni da cui di solito comincia il lavoro e i progetti
;; recenti.
;;
;; Ogni voce si apre col clic, con Invio o con la sua lettera; a destra c'è
;; la scorciatoia globale che fa la stessa cosa ovunque.  Le voci sono
;; legate proprio a quelle scorciatoie: se un modulo è disattivato, la sua
;; voce sparisce.  C-c o h riporta il cruscotto; g lo ridisegna, q lo chiude.
;;
;; Le icone sono in icons/, disegnate per GDev-Emacs; prendono il colore
;; del cursore del tema.  In un terminale restano solo le scritte.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-menu)
(require 'gdev-ui)
(require 'text-property-search)

(defvar project--list)
(declare-function gdev-open-folder "gdev-commands")
(declare-function project--ensure-read-project-list "project")
(defvar gdev-dashboard-mode-map)        ; definita più sotto, con la modalità

(defgroup gdev-dashboard nil
  "Il cruscotto (dashboard) iniziale."
  :group 'gdev)

(defcustom gdev-dashboard-menu
  '(("f" "file"     "Apri file…"               "s-o" "C-x C-f")
    ("o" "open"     "Apri cartella…"           "s-O")
    ("p" "project"  "Apri progetto…"           "C-c w p" "C-c p p")
    ("r" "recent"   "Apri file recente…"       "C-c f r")
    ("s" "session"  "Riprendi ultima sessione" "C-c q l")
    ("v" "git"      "Apri stato Git"          "C-c g g")
    ("t" "terminal" "Apri terminale del progetto" "C-c o t")
    ("a" "calendar" "Apri agenda"              "C-c n a")
    ("k" "keyboard" "Mostra scorciatoie"        "C-h d k")
    ("d" "doctor"   "Esegui diagnosi"           "C-h d d")
    ("," "settings" "Apri preferenze…"          "s-," "C-h d c")
    ("A" "settings" "Aspetto…"                  "C-c t A"))
  "Voci del cruscotto: LETTERA, ICONA, ETICHETTA, poi una o più scorciatoie.
La voce esegue il comando della prima scorciatoia definita.  ICONA è il nome
di un file in icons/, senza estensione."
  :type '(repeat (list string string string (repeat :inline t string))))

(defvar gdev-dashboard--half-width 22
  "Metà della larghezza del menu durante il disegno, in colonne.")

(defvar-local gdev-dashboard--selection-overlay nil)

;;;; Facce (faces)

(defface gdev-dashboard-title '((t :inherit gdev-ui-view-title))
  "Titolo del cruscotto.")

(defface gdev-dashboard-letter '((t :inherit gdev-ui-secondary :weight semi-bold))
  "Lettera che apre una voce.")

(defface gdev-dashboard-heading '((t :inherit gdev-ui-view-heading))
  "Titoli delle sezioni del cruscotto.")

(defface gdev-dashboard-selection
  '((t :inherit gdev-ui-side-selection :extend nil))
  "Riga selezionata nel cruscotto.")

(define-button-type 'gdev-dashboard-action
  'face nil 'follow-link t 'mouse-face 'gdev-ui-side-hover)

;;;; Immagini

(defun gdev-dashboard--images-p ()
  "Restituisce non nil se la finestra può mostrare le icone SVG."
  (and (display-graphic-p) (image-type-available-p 'svg)))

(defun gdev-dashboard--accent ()
  "Restituisce il colore d'accento: quello del cursore del tema."
  (face-background 'cursor nil t))

(defun gdev-dashboard--icon (name)
  "Restituisce l'icona NAME (un file di icons/) come immagine, o nil."
  (when (gdev-dashboard--images-p)
    (let ((file (gdev-config-file (format "icons/%s.svg" name))))
      (when (file-exists-p file)
        (create-image file 'svg nil
                      :ascent 'center
                      :height (round (* 1.15 (frame-char-height)))
                      :foreground (gdev-dashboard--accent))))))

(defun gdev-dashboard--align (columns)
  "Restituisce uno spazio che porta alla colonna CENTRO + COLUMNS."
  (propertize " " 'display `(space :align-to (+ center ,columns))))

(defun gdev-dashboard--text-width (text)
  "Misura TEXT in unità della larghezza del carattere di base."
  (if (display-graphic-p)
      (let ((sample (copy-sequence text)))
        (add-face-text-property 0 (length sample) (alist-get 'default face-remapping-alist) t sample)
        (/ (float (string-pixel-width sample)) (frame-char-width)))
    (string-width text)))

;;;; Disegno

(defun gdev-dashboard--insert-logo ()
  "Inserisce il logo centrato, o la sua versione testuale."
  (let* ((size (* (if (< (window-body-height) 28) 3 5) (frame-char-height)))
         (logo (and (gdev-dashboard--images-p)
                    (create-image (gdev-config-file gdev-application-icon) 'svg nil
                                  :height size :ascent 'center))))
    (if logo
        (insert (propertize " " 'display `(space :align-to (- center (,(/ size 2)))))
                (propertize "logo" 'display logo) "\n\n")
      (insert (gdev-dashboard--align -1) (propertize "›_" 'face 'gdev-dashboard-letter) "\n\n"))))

(defun gdev-dashboard--insert-centered (text face)
  "Inserisce TEXT centrato, con FACE, e un a capo."
  (let ((label (gdev-ui-fit-text (propertize text 'face face)
                                (max 1 (- (window-body-width) 2))
                                #'gdev-dashboard--text-width)))
    (insert (gdev-dashboard--align (- (/ (gdev-dashboard--text-width label) 2))) label "\n")))

(defun gdev-dashboard--command (keys)
  "Restituisce (TASTO . COMANDO) per la prima delle KEYS che ha un comando."
  (cl-some (lambda (key)
             (let ((command (keymap-lookup global-map key)))
               (and (commandp command) (cons key command))))
           keys))

(defun gdev-dashboard--insert-row (contents id action help)
  "Inserisce CONTENTS come voce ID, con azione ACTION e suggerimento HELP."
  (insert (gdev-dashboard--align (- (1+ gdev-dashboard--half-width))))
  (let ((start (point)))
    (insert (gdev-dashboard--align (- gdev-dashboard--half-width))
            contents (gdev-dashboard--align (1+ gdev-dashboard--half-width)))
    (make-text-button start (point) :type 'gdev-dashboard-action
                      'gdev-dashboard-id id 'action action 'help-echo help))
  (insert "\n"))

(defun gdev-dashboard--insert-entry (letter icon label key command)
  "Inserisce la riga di una voce: ICON, LETTER, LABEL, KEY; esegue COMMAND."
  (let* ((compact (< gdev-dashboard--half-width 10))
         (image (and (not compact) (gdev-dashboard--icon icon)))
         (shortcut (propertize (gdev-menu-key-label (kbd key)) 'face 'gdev-ui-secondary))
         (shortcut-start (- gdev-dashboard--half-width (gdev-dashboard--text-width shortcut)))
         (label-start (- (if compact 2 6) gdev-dashboard--half-width))
         (show-shortcut (and (not compact)
                             (<= (+ label-start (gdev-dashboard--text-width label) 2)
                                 shortcut-start))))
    (gdev-dashboard--insert-row
     (concat (unless compact
               (concat (if image (propertize "*" 'display image) " ")
                       (gdev-dashboard--align (- 3 gdev-dashboard--half-width))))
             (propertize letter 'face 'gdev-dashboard-letter)
             (gdev-dashboard--align label-start)
             (gdev-ui-fit-text label (- gdev-dashboard--half-width label-start) #'gdev-dashboard--text-width)
             (when show-shortcut (concat (gdev-dashboard--align shortcut-start) shortcut)))
     letter (lambda (_) (call-interactively command))
     (format "%s · %s qui · %s ovunque" label letter shortcut))
    (keymap-local-set letter command)))

(defun gdev-dashboard--insert-projects ()
  "Inserisce i progetti recenti, se ce ne sono."
  (require 'project)
  (project--ensure-read-project-list)
  (when-let* ((projects (seq-take
                         (seq-remove (lambda (root)
                                       (string-prefix-p gdev-state-directory
                                                        (file-name-as-directory (expand-file-name root))))
                                     (mapcar #'car project--list))
                         5)))
    (insert "\n" (gdev-dashboard--align (- gdev-dashboard--half-width))
            (propertize "Progetti recenti" 'face 'gdev-dashboard-heading) "\n")
    (dolist (root projects)
      (let* ((compact (< gdev-dashboard--half-width 10))
             (indent (if compact 2 6))
             (image (and (not compact) (gdev-dashboard--icon "project")))
             (path (abbreviate-file-name root))
             (directory (directory-file-name path))
             (name (file-name-nondirectory directory))
             (parent (file-name-directory directory))
             (label (cond ((string-empty-p name) path)
                          (parent (concat name "  " (propertize parent 'face 'gdev-ui-secondary)))
                          (t name))))
        (gdev-dashboard--insert-row
         (concat (when image (propertize "*" 'display image))
                 (gdev-dashboard--align (- indent gdev-dashboard--half-width))
                 (gdev-ui-fit-text label (- (* 2 gdev-dashboard--half-width) indent)
                                   #'gdev-dashboard--text-width))
         root (lambda (_) (gdev-open-folder root)) (concat "Apri " path))))))

(defun gdev-dashboard--update-selection ()
  "Evidenzia solo il pulsante alla posizione corrente."
  (if-let* ((button (button-at (point))))
      (progn
        (unless gdev-dashboard--selection-overlay
          (setq gdev-dashboard--selection-overlay (make-overlay (point) (point)))
          (overlay-put gdev-dashboard--selection-overlay 'face 'gdev-dashboard-selection))
        (move-overlay gdev-dashboard--selection-overlay (button-start button) (button-end button)
                      (current-buffer)))
    (when gdev-dashboard--selection-overlay (delete-overlay gdev-dashboard--selection-overlay))))

(defun gdev-dashboard--render ()
  "Riempie l'area di testo del cruscotto per la larghezza della finestra."
  (let* ((width (window-body-width))
         (gdev-dashboard--half-width (max 2 (min 22 (/ (- width 4) 2))))
         (selected (when-let* ((button (button-at (point))))
                     (button-get button 'gdev-dashboard-id)))
         (inhibit-read-only t))
    (erase-buffer)
    (use-local-map (copy-keymap gdev-dashboard-mode-map))
    (insert (make-string (max 1 (/ (- (window-body-height) 30) 3)) ?\n))
    (gdev-dashboard--insert-logo)
    (gdev-dashboard--insert-centered "GDev-Emacs" 'gdev-dashboard-title)
    (insert "\n")
    (pcase-dolist (`(,letter ,icon ,label . ,keys) gdev-dashboard-menu)
      (when-let* ((found (gdev-dashboard--command keys)))
        (gdev-dashboard--insert-entry letter icon label (car found) (cdr found))))
    (gdev-dashboard--insert-projects)
    (insert "\n")
    (gdev-dashboard--insert-centered (if (< width 38) "↑ ↓  Seleziona · Invio  Apri"
                                       "↑ ↓  Seleziona    Invio  Apri    q  Chiudi")
                                     'gdev-ui-secondary)
    (goto-char (point-min))
    (if-let* ((match (and selected (text-property-search-forward 'gdev-dashboard-id selected t))))
        (goto-char (prop-match-beginning match))
      (when-let* ((first (next-button (point-min))))
        (goto-char (button-start first))))
    (gdev-dashboard--update-selection)
    ;; Il ridisegno non è una modifica dell'utente: schede e agenti
    ;; non devono vedere il cruscotto come un documento da salvare.
    (set-buffer-modified-p nil)))

;;;; Modalità

(defvar-keymap gdev-dashboard-mode-map
  :parent button-map
  "n" #'forward-button
  "p" #'backward-button
  "<down>" #'forward-button
  "<up>" #'backward-button
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "g" #'gdev-dashboard-refresh
  "q" #'quit-window)

(define-derived-mode gdev-dashboard-mode special-mode "Cruscotto"
  "Modalità principale della schermata iniziale di GDev-Emacs."
  (gdev-ui-view-setup 'document)
  (setq-local cursor-type nil
              buffer-read-only t
              mode-line-format nil
              truncate-lines t
              bidi-paragraph-direction 'left-to-right)
  (add-hook 'post-command-hook #'gdev-dashboard--update-selection nil t)
  (add-hook 'window-size-change-functions #'gdev-dashboard--on-resize nil t))

(defun gdev-dashboard--on-resize (window)
  "Ricentra il cruscotto quando WINDOW cambia dimensione."
  (with-selected-window window (gdev-dashboard--render)))

(defun gdev-dashboard-refresh ()
  "Ridisegna il cruscotto."
  (interactive)
  (when-let* ((buffer (get-buffer "*gdev*"))
              (window (get-buffer-window buffer t)))
    (gdev-dashboard--on-resize window)))

(defun gdev-dashboard-buffer ()
  "Prepara il cruscotto per la finestra corrente e restituisci il suo buffer."
  (let ((buffer (get-buffer-create "*gdev*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-dashboard-mode) (gdev-dashboard-mode))
      (gdev-dashboard--render))
    buffer))

(defun gdev-dashboard ()
  "Mostra il cruscotto e ne restituisce l'area di testo."
  (interactive)
  (let ((buffer (gdev-dashboard-buffer)))
    (switch-to-buffer buffer)
    buffer))

;; Le icone prendono il colore del tema: si ridisegnano quando cambia.
(add-hook 'gdev-ui-after-theme-hook #'gdev-dashboard-refresh)

;; Compare quando Emacs parte senza file da aprire.
(setq initial-buffer-choice #'gdev-dashboard-buffer)

;;; config.el ends here
