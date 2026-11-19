;;; config.el --- :ui breadcrumb: dove ti trovi nel codice -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La riga sopra il codice mostra il percorso del file e il simbolo al
;; cursore. Le cartelle aprono la scelta dei file, il nome del file apre
;; Struttura e il simbolo apre la scelta delle definizioni del documento.

;;; Code:

(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-workspace-roots)

(declare-function gdev-quick-open--symbols "gdev-commands" (buffer))
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-ui-fit-text "../workbench/gdev-ui" (text width measure))
(declare-function gdev-ui-fit-file-name "../workbench/gdev-ui" (text width measure))
(declare-function gdev-outline-show "../workbench/gdev-outline" ())
(declare-function gdev-outline-symbol-path "../workbench/gdev-outline" (editor))
(declare-function breadcrumb-imenu-path "breadcrumb" (&optional position))
(declare-function breadcrumb-file-components "breadcrumb" (file root))
(declare-function eglot-imenu "eglot" ())
(declare-function imenu "imenu" (index-item))
(declare-function project-root "project" (project))
(defvar gdev-quick-open-map)
(defvar gdev-layout--close-button)
(defvar imenu-create-index-function)
(defvar breadcrumb-imenu-index-function)

(defun gdev-breadcrumb-symbols (&optional window)
  "Scegli un simbolo del documento mostrato in WINDOW."
  (interactive)
  (let ((source (or window (gdev-layout-editor)))
        visited)
    (unless (memq source (gdev-layout--editors))
      (user-error "Apri un documento nel gruppo di modifica"))
    (with-selected-window source
      (let* ((index (gdev-quick-open--symbols (current-buffer)))
             (names (sort (hash-table-keys index) #'string-lessp)))
        (unless names (user-error "Nessun simbolo indicizzato in questo documento"))
        (when-let* ((name
                     (minibuffer-with-setup-hook
                         (lambda ()
                           (use-local-map (make-composed-keymap gdev-quick-open-map (current-local-map))))
                       (completing-read
                        "Simbolo nel documento: "
                        (lambda (input predicate action)
                          (if (eq action 'metadata)
                              '(metadata (category . imenu))
                            (complete-with-action action names input predicate)))
                        nil t)))
                    (target (gethash name index)))
          (imenu target)
          (setq visited t))))
    (when visited (select-window source))))

(defvar-keymap gdev-breadcrumb--symbol-map
  "<header-line> <down-mouse-1>" #'ignore
  "<header-line> <mouse-1>"
  (lambda (event)
    (interactive "e")
    (gdev-breadcrumb-symbols (posn-window (event-start event)))))

(defconst gdev-breadcrumb--symbol-button
  (propertize "Simboli ▾" 'face '(:inherit (gdev-ui-action header-line) :weight semi-bold)
              'mouse-face 'gdev-ui-side-hover 'pointer 'hand
              'help-echo "Cerca classi, metodi e funzioni nel documento"
              'local-map gdev-breadcrumb--symbol-map))

(defconst gdev-breadcrumb--separator (propertize " › " 'face 'gdev-ui-secondary))
(defvar-local gdev-breadcrumb--locations nil)
(defvar-local gdev-breadcrumb--rendered nil)
(defvar gdev-breadcrumb--theme-revision 0)

(defun gdev-breadcrumb--theme-changed ()
  "Invalida le misure memorizzate quando cambia il tema."
  (cl-incf gdev-breadcrumb--theme-revision))

(defun gdev-breadcrumb--local-index ()
  "Indicizza il documento con la modalità, anche quando Eglot è attivo."
  (save-excursion
    (save-restriction
      (widen)
      (let ((imenu-create-index-function imenu-create-index-function))
        (remove-function imenu-create-index-function #'eglot-imenu)
        (funcall imenu-create-index-function)))))

(defun gdev-breadcrumb--enable ()
  "Attiva Breadcrumb GDev e imposta l'indice locale nei documenti del Workbench."
  (when (derived-mode-p 'prog-mode 'text-mode 'conf-mode)
    (when (and gdev-layout-mode (display-graphic-p))
      (setq-local breadcrumb-imenu-index-function #'gdev-breadcrumb--local-index))
    (breadcrumb-local-mode 1)))

(defun gdev-breadcrumb--use-window (window action)
  "Esegui ACTION in WINDOW, ripristinando il fuoco in caso di annullamento."
  (unless (and (window-live-p window) (memq window (gdev-layout--editors (window-frame window))))
    (user-error "Apri un documento nel gruppo di modifica"))
  (let ((previous (selected-window)) done)
    (unwind-protect
        (progn (select-window window) (funcall action) (setq done t))
      (unless done (when (window-live-p previous) (select-window previous))))))

(defun gdev-breadcrumb--structure (window)
  "Apri Struttura per il documento di WINDOW."
  (if (fboundp 'gdev-outline-show)
      (gdev-breadcrumb--use-window window #'gdev-outline-show)
    (gdev-breadcrumb-symbols window)))

(defun gdev-breadcrumb--open-in-folder (window directory)
  "Scegli un file di DIRECTORY e aprilo in WINDOW."
  (gdev-breadcrumb--use-window
   window
   (lambda ()
     (let ((default-directory directory))
       (apply #'gdev-open-file
              (find-file-read-args "Apri file: " (confirm-nonexistent-file-or-buffer)))))))

(defun gdev-breadcrumb--choose-folder (window folders)
  "Scegli una delle cartelle FOLDERS del percorso di WINDOW."
  (gdev-breadcrumb--use-window
   window
   (lambda ()
     (when-let* ((directory (completing-read "Cartella del percorso: " folders nil t))
                 ((not (string-empty-p directory))))
       (gdev-breadcrumb--open-in-folder window directory)))))

(defun gdev-breadcrumb--action-map (command &rest args)
  "Associa il clic in intestazione a COMMAND con la finestra e ARGS."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1]
      (lambda (event) (interactive "e")
        (apply command (posn-window (event-start event)) args)))
    map))

(defun gdev-breadcrumb--label (text tooltip map)
  "Decora TEXT come azione con TOOLTIP e MAP."
  (propertize text 'face '(:inherit (gdev-ui-action header-line))
              'mouse-face 'gdev-ui-side-hover 'pointer 'hand
              'help-echo tooltip 'local-map map))

(defun gdev-breadcrumb--file-locations (window)
  "Restituisci i segmenti del file mostrato in WINDOW.
Calcola il percorso a partire dalle cartelle dello spazio."
  (let* ((roots (gdev-workspace-roots (window-frame window)))
         (key (list buffer-file-name buffer-file-truename default-directory roots)))
    (unless (equal (car gdev-breadcrumb--locations) key)
      (let* ((file buffer-file-name)
             (root (gdev-workspace-root-for file roots)))
        (when (and (not root) buffer-file-truename)
          (setq root (gdev-workspace-root-for buffer-file-truename roots))
          (when root (setq file buffer-file-truename)))
        (unless root
          (setq root (or (and file (not (file-remote-p file))
                              (when-let* ((project (project-current nil (file-name-directory file))))
                                (project-root project)))
                         (and file (file-name-directory file)))))
        (setq gdev-breadcrumb--locations
              (cons key (and file (breadcrumb-file-components file root))))))
    (cdr gdev-breadcrumb--locations)))

(defun gdev-breadcrumb--file-labels (locations)
  "Trasforma LOCATIONS in controlli per le cartelle e il file."
  (let ((structure-map (gdev-breadcrumb--action-map #'gdev-breadcrumb--structure)))
    (or (cl-loop for ((name . path) . remaining) on locations
                 collect (if remaining
                             (gdev-breadcrumb--label
                              name (format "Apri un file in %s" path)
                              (gdev-breadcrumb--action-map #'gdev-breadcrumb--open-in-folder path))
                           (gdev-breadcrumb--label name (format "Struttura di %s" path) structure-map)))
        (list (gdev-breadcrumb--label (buffer-name) "Apri Struttura" structure-map)))))

(defun gdev-breadcrumb--measure (text)
  "Misura TEXT nel carattere effettivo dell'intestazione."
  (gdev-ui-string-pixel-width (propertize text 'face 'header-line)))

(defun gdev-breadcrumb--fit-label (label width &optional file)
  "Adatta LABEL alla WIDTH mantenendo azione, aiuto e l'eventuale estensione FILE."
  (let* ((fit (if file #'gdev-ui-fit-file-name #'gdev-ui-fit-text))
         (text (funcall fit (substring-no-properties label) width #'gdev-breadcrumb--measure)))
    (apply #'propertize text (text-properties-at 0 label))))

(defun gdev-breadcrumb--compact (file symbol overflow width)
  "Stringi FILE e SYMBOL in WIDTH mantenendo OVERFLOW quando entra."
  (let* ((sep gdev-breadcrumb--separator)
         (separator-width (gdev-breadcrumb--measure sep))
         (minimum (gdev-breadcrumb--measure " … "))
         (overflow-width (if overflow (+ separator-width (gdev-breadcrumb--measure overflow)) 0)))
    (when (< width (+ overflow-width separator-width (* 2 minimum)))
      (setq overflow nil overflow-width 0))
    (if (and symbol (>= width (+ overflow-width separator-width (* 2 minimum))))
        (let* ((remaining (- width overflow-width separator-width))
               (file-width (min (gdev-breadcrumb--measure file)
                                (max (- remaining (gdev-breadcrumb--measure symbol))
                                     (/ (* remaining 55) 100)))))
          (string-join (delq nil (list overflow
                                       (gdev-breadcrumb--fit-label file file-width t)
                                       (gdev-breadcrumb--fit-label symbol (- remaining file-width)))) sep))
      (gdev-breadcrumb--fit-label file width t))))

(defun gdev-breadcrumb--render (locations symbols width)
  "Mostra LOCATIONS e SYMBOLS entro WIDTH, con i segmenti completi disponibili."
  (let* ((sep gdev-breadcrumb--separator)
         (file-labels (gdev-breadcrumb--file-labels locations))
         (file (car (last file-labels)))
         (full-symbol (when symbols
                        (let ((path (string-join symbols " › ")))
                          (gdev-breadcrumb--label
                           path (format "Scegli un simbolo · %s" path) gdev-breadcrumb--symbol-map))))
         (symbol (if full-symbol
                     (apply #'propertize (car (last symbols)) (text-properties-at 0 full-symbol))
                   gdev-breadcrumb--symbol-button))
         (full (string-join (append file-labels (list (or full-symbol symbol))) sep)))
    (if (<= (gdev-breadcrumb--measure full) width) full
      (let* ((folders (mapcar #'cdr (butlast locations)))
             (overflow (when folders
                         (gdev-breadcrumb--label
                          "…" (string-join folders " › ")
                          (gdev-breadcrumb--action-map #'gdev-breadcrumb--choose-folder folders))))
             (compact (string-join (if (cdr folders)
                                        (list (car file-labels) overflow file symbol)
                                      (append file-labels (list symbol))) sep)))
        (if (<= (gdev-breadcrumb--measure compact) width) compact
          (gdev-breadcrumb--compact file symbol overflow width))))))

(defun gdev-breadcrumb--width (window)
  "Misura lo spazio utile in WINDOW, riservando il pulsante di chiusura."
  (let ((header (window-parameter window 'header-line-format)))
    (max 0 (- (window-body-width window t) (* 2 (frame-char-width (window-frame window)))
              (if (and (consp header) (eq (car header) gdev-layout--close-button))
                  (gdev-ui-string-pixel-width gdev-layout--close-button) 0)))))

(defun gdev-breadcrumb--header (original)
  "Mostra file e simbolo nell'intestazione del gruppo in corso di ridisegno."
  (let ((window (selected-window)))
    (if (and gdev-layout-mode (display-graphic-p (window-frame window))
             (derived-mode-p 'prog-mode 'text-mode 'conf-mode)
             (not (window-parameter window 'window-side)))
        (let* ((locations (gdev-breadcrumb--file-locations window))
               (outline (and (fboundp 'gdev-outline-symbol-path) (gdev-outline-symbol-path window)))
               (symbols (if outline (cdr outline)
                          (mapcar #'substring-no-properties (breadcrumb-imenu-path (window-point window)))))
               (width (gdev-breadcrumb--width window))
               (key (list locations symbols width gdev-breadcrumb--theme-revision (buffer-name))))
          (unless gdev-breadcrumb--rendered
            (setq gdev-breadcrumb--rendered (make-hash-table :test #'eq :weakness 'key)))
          (let ((cached (gethash window gdev-breadcrumb--rendered)))
            (if (equal (car cached) key) (cdr cached)
              (let ((label (gdev-breadcrumb--render locations symbols width)))
                (puthash window (cons key label) gdev-breadcrumb--rendered)
                label))))
      (funcall original))))

(use-package breadcrumb
  :ensure t
  :commands breadcrumb-local-mode
  :hook ((prog-mode . gdev-breadcrumb--enable)
         (find-file . gdev-breadcrumb--enable))
  :config
  (advice-add 'breadcrumb--header-line :around #'gdev-breadcrumb--header))

(add-hook 'gdev-ui-after-theme-hook #'gdev-breadcrumb--theme-changed)

;;; config.el ends here
