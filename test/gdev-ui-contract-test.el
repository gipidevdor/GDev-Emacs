;;; gdev-ui-contract-test.el --- Verifiche dei profili grafici di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Contratto grafico per le modalità dei moduli, le superfici condivise
;; e la destinazione del riquadro quando termina la cronologia.

;;; Code:

(require 'ert)
(require 'gdev-ui)

(defvar gdev-workspaces--tab-title-width)

(ert-deftest gdev-test-ui-contract-missing-icon-uses-and-caches-the-readable-fallback ()
  (let ((gdev-ui--icons (make-hash-table :test #'equal))
        (readable (symbol-function 'file-readable-p))
        (image (symbol-function 'create-image))
        (target (gdev-config-file "icons/gdev-nonexistent-test-icon.svg")) (reads 0) (images 0))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'image-type-available-p) (lambda (_) t))
              ((symbol-function 'file-readable-p)
               (lambda (file) (when (equal file target) (cl-incf reads)) (funcall readable file)))
              ((symbol-function 'create-image)
               (lambda (&rest arguments)
                 (when (equal (car arguments) target) (cl-incf images))
                 (apply image arguments))))
      (should (equal "+" (gdev-ui-icon "gdev-nonexistent-test-icon" "+")))
      (should (equal "+" (gdev-ui-icon "gdev-nonexistent-test-icon" "+")))
      (should (= 1 reads))
      (should (= 0 images)))))

(ert-deftest gdev-test-ui-contract-icon-constructor-failure-keeps-the-label-readable ()
  (let ((gdev-ui--icons (make-hash-table :test #'equal))
        (image (symbol-function 'create-image)) (calls 0))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'image-type-available-p) (lambda (_) t))
              ((symbol-function 'create-image)
               (lambda (file &optional type data &rest properties)
                 (if (= 997 (or (plist-get properties :height) 0))
                     (progn (cl-incf calls) (error "Formato non disponibile"))
                   (apply image file type data properties)))))
      (should (equal "✓" (gdev-ui-icon "test" "✓" nil nil 997)))
      (should (equal "✓" (gdev-ui-icon "test" "✓" nil nil 997)))
      (should (= 1 calls)))))

(defun gdev-ui-test--check-modes (form)
  "Controlla le dichiarazioni di modalità contenute in FORM."
  (pcase form
    (`(define-derived-mode ,name ,parent . ,body)
     (ert-info ((format "Modalità %s da %s" name parent))
       (let* ((calls (seq-filter (lambda (item) (eq (car-safe item) 'gdev-ui-view-setup))
                                 body))
              (profile (cadr (cadar calls)))
              (allowed (pcase parent
                         ('tabulated-list-mode '(table))
                         ('special-mode '(document sidebar preview))
                         (_ '(native document sidebar table preview)))))
         (should (= (length calls) 1))
         (should (equal (car calls) (list 'gdev-ui-view-setup (list 'quote profile))))
         (should (memq profile allowed)))))
    ((or `(quote . ,_) (pred atom)) nil)
    (_ (let ((rest form))
         (while (consp rest)
           (gdev-ui-test--check-modes (pop rest)))))))

(ert-deftest gdev-test-ui-contract-module-profiles ()
  "Ogni modalità distribuita dichiara un profilo coerente con il suo tipo."
  (let ((files (directory-files-recursively (gdev-config-file "modules") "\\.el\\'")))
    ;; Una cartella spostata renderebbe la scansione vuota e il controllo verde.
    (should (>= (length files) 90))
    (dolist (file files)
      (ert-info ((file-relative-name file gdev-config-directory))
        (with-temp-buffer
          (insert-file-contents file)
          (condition-case nil
              (while t (gdev-ui-test--check-modes (read (current-buffer))))
            (end-of-file nil)))))))

(defun gdev-ui-test--luminance (hex)
  "Calcola la luminanza relativa sRGB del colore HEX."
  (cl-loop for offset in '(1 3 5)
           for weight in '(0.2126 0.7152 0.0722)
           for component = (/ (string-to-number (substring hex offset (+ offset 2)) 16) 255.0)
           sum (* weight
                  (if (<= component 0.04045) (/ component 12.92)
                    (expt (/ (+ component 0.055) 1.055) 2.4)))))

(defun gdev-ui-test--face-color (face attribute appearance)
  "Leggi ATTRIBUTE per FACE nell'aspetto APPEARANCE."
  (let ((spec (get face 'face-defface-spec)))
    (plist-get (cdr (assoc (list (list 'background appearance)) spec)) attribute)))

(ert-deftest gdev-test-ui-contract-shared-contrast ()
  "Corpo, dettagli, azioni e stati superano 4,5:1 sulle superfici comuni."
  (cl-progv '(modus-operandi-palette-overrides modus-vivendi-palette-overrides
              modus-themes-italic-constructs modus-themes-bold-constructs
              modus-themes-mixed-fonts modus-themes-prompts modus-themes-completions
              modus-themes-common-palette-overrides)
      nil
    (gdev-ui--configure-modus)
    (dolist (appearance '(light dark))
      (let* ((palette (if (eq appearance 'light) modus-operandi-palette-overrides
                        modus-vivendi-palette-overrides))
             (foregrounds
              (cons (cadr (assq 'fg-main palette))
                    (mapcar (lambda (face)
                              (gdev-ui-test--face-color face :foreground appearance))
                            '(gdev-ui-secondary gdev-ui-action
                              gdev-ui-status-warning gdev-ui-status-success
                              gdev-ui-status-error gdev-ui-status-accent))))
             (backgrounds
              (cons (cadr (assq 'bg-main palette))
                    (mapcar (lambda (face)
                              (gdev-ui-test--face-color face :background appearance))
                            '(gdev-ui-side-surface gdev-ui-side-selection
                              gdev-ui-side-hover gdev-ui-side-current)))))
        (dolist (foreground foregrounds)
          (dolist (background backgrounds)
            (ert-info ((format "%s: %s su %s" appearance foreground background))
              (let ((a (gdev-ui-test--luminance foreground))
                    (b (gdev-ui-test--luminance background)))
                (should (>= (/ (+ (max a b) 0.05) (+ (min a b) 0.05)) 4.5))))))))))

(ert-deftest gdev-test-ui-contract-profiles-and-actions ()
  "Pagine e tabelle usano la famiglia prevista e i pulsanti condividono l'azione."
  (with-temp-buffer
    (gdev-ui-view-setup 'sidebar)
    (should (eq gdev-ui-view-profile 'sidebar))
    (should (eq buffer-face-mode-face 'variable-pitch))
    (should (eq hl-line-face 'gdev-ui-side-selection))
    (let (activated)
      (let ((button (insert-text-button "Apri" 'type 'gdev-ui-action
                                        'action (lambda (_) (setq activated t)))))
        (should (eq (keymap-lookup (button-get button 'keymap) "<mouse-1>") #'push-button))
        (button-activate button)
        (should activated))))
  (with-temp-buffer
    (tabulated-list-mode)
    (gdev-ui-view-setup 'table)
    (should (eq gdev-ui-view-profile 'table))
    (should (eq buffer-face-mode-face 'fixed-pitch))
    (should (= tabulated-list-padding 2))))

(ert-deftest gdev-test-ui-contract-filename-preserves-extension-and-glyphs ()
  "Le abbreviazioni mantengono l'estensione, il glifo e le loro proprietà."
  (let* ((accent (concat "Cafe" (string #x301)))
         (name (concat (propertize (concat accent "-documento") 'face 'bold)
                       (propertize ".el" 'face 'italic)))
         (displayed (gdev-ui-fit-file-name name 8 #'string-width)))
    (should (equal (gdev-ui-fit-text name 5 #'string-width) (concat accent "…")))
    (should (equal displayed (concat accent "….el")))
    (should (eq (get-text-property 0 'face displayed) 'bold))
    (should (eq (get-text-property (1- (length displayed)) 'face displayed) 'italic))
    (should (equal (gdev-ui-fit-file-name name 4 #'string-width) "Caf…"))
    (should (eq name (gdev-ui-fit-file-name name 100 #'string-width)))
    (should (equal (gdev-ui-fit-file-name ".gitignore" 5 #'string-width) ".git…"))))

(ert-deftest gdev-test-ui-contract-scratch-and-editor-fallback ()
  "Appunti conserva il contenuto e il gruppo vuoto apre la vista iniziale."
  (require 'gdev-commands)
  (let ((scratch (generate-new-buffer " *gdev-prova-appunti*"))
        (document (generate-new-buffer " *gdev-prova-documento*"))
        (home (generate-new-buffer " *gdev-prova-vista-iniziale*")))
    (unwind-protect
        (cl-letf (((symbol-function 'get-scratch-buffer-create) (lambda () scratch))
                  ((symbol-function 'gdev-ui-scratch-buffer-p)
                   (lambda (&optional buffer) (eq (or buffer (current-buffer)) scratch)))
                  ((symbol-function 'gdev-layout-home-buffer) (lambda () home)))
          (with-current-buffer scratch
            (lisp-interaction-mode)
            (insert "(+ 1 2)"))
          (gdev-test--with-layout
            (gdev-scratch)
            (should (eq (current-buffer) scratch))
            (should (eq major-mode 'lisp-interaction-mode))
            (should (equal (buffer-string) "(+ 1 2)"))
            (should (member "Appunti" header-line-format))
            (should (gdev-layout-document-tab-p scratch))
            (let ((editor (gdev-layout-editor)))
              (set-window-buffer editor document)
              (set-window-prev-buffers editor (list (with-current-buffer scratch (list scratch (copy-marker 1) (copy-marker 1)))))
              (should (gdev-layout--skip-buffer editor scratch nil))
              (gdev-layout--restore-document editor)
              (should (eq (window-buffer editor) home)))))
      (mapc #'kill-buffer (list scratch document home)))))

(ert-deftest gdev-test-ui-contract-display-respects-the-excluded-window ()
  "Una richiesta esplicita non sostituisce il documento nella finestra esclusa."
  (let ((first (generate-new-buffer "Documento di origine"))
        (second (generate-new-buffer "Documento di destinazione"))
        (this-command nil))
    (unwind-protect
        (gdev-test--with-layout
          (let ((origin (selected-window)))
            (set-window-buffer origin first)
            (let ((destination (display-buffer second
                                               '(display-buffer-pop-up-window
                                                 (inhibit-same-window . t)))))
              (should (window-live-p destination))
              (should-not (eq origin destination))
              (should (eq (window-buffer origin) first))
              (should (eq (window-buffer destination) second))
              (should (eq (selected-window) origin))
              (should (eq (display-buffer second t) destination)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest gdev-test-ui-contract-explorer-preview-survives-in-other-workspace ()
  "Sostituire l'anteprima rispetta l'altro spazio e rilascia l'ultimo riferimento."
  (require 'gdev-editor-tabs)
  (require 'gdev-workspaces)
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (let* ((root (make-temp-file "gdev-preview-spazi-" t))
         (first-file (expand-file-name "prima.txt" root))
         (later-file (expand-file-name "dopo.txt" root))
         (files (list first-file later-file))
         (first-tree (generate-new-buffer " *Albero del primo spazio*"))
         (other-tree (generate-new-buffer " *Albero dell'altro spazio*"))
         (already-hooked
          (advice-member-p #'gdev-workspaces--remember-layout 'tab-bar--tab)))
    (unwind-protect
        (gdev-test--with-layout
          (unless already-hooked
            (advice-add 'tab-bar--tab :around #'gdev-workspaces--remember-layout))
          (dolist (file files)
            (with-temp-file file (insert "Testo di anteprima\n")))
          (dolist (tree (list first-tree other-tree))
            (with-current-buffer tree
              (gdev-sidebar-mode)
              (let ((inhibit-read-only t))
                (dolist (file files)
                  (insert-text-button (file-name-nondirectory file)
                                      :type 'gdev-sidebar-entry
                                      'gdev-sidebar-path file 'action #'gdev-sidebar--activate)
                  (insert "\n")))))
          (tab-bar-new-tab-to -1)
          (tab-bar-select-tab 1)
          (let* ((first-side (gdev-layout-show-explorer first-tree))
                 (position (with-current-buffer first-tree (gdev-sidebar--path-position first-file)))
                 (first-editor (gdev-layout-editor)))
            (gdev-sidebar-click (list 'mouse-1 (list first-side position '(0 . 0) 0)))
            (let ((preview (window-buffer first-editor)))
              (should (gdev-editor-preview-p preview first-editor))
              (should (eq (selected-window) first-side))
              (set-window-point first-editor 4)
              (tab-bar-select-tab 2)
              (select-window (gdev-layout-show-explorer other-tree))
              (goto-char (gdev-sidebar--path-position first-file))
              (call-interactively (key-binding (kbd "SPC")))
              (should (eq (window-buffer (gdev-layout-editor)) preview))
              (goto-char (gdev-sidebar--path-position later-file))
              (call-interactively (key-binding (kbd "SPC")))
              (should (buffer-live-p preview))
              (tab-bar-select-tab 1)
              (should (eq (selected-window) first-side))
              (should (equal (gdev-sidebar--path-at-point) first-file))
              (should (eq (window-buffer first-editor) preview))
              (should (= (window-point first-editor) 4))
              (should (gdev-editor-preview-p preview first-editor))
              (goto-char (gdev-sidebar--path-position later-file))
              (call-interactively (key-binding (kbd "SPC")))
              (should-not (buffer-live-p preview)))))
      (unless already-hooked
        (advice-remove 'tab-bar--tab #'gdev-workspaces--remember-layout))
      (dolist (file files)
        (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer)))
      (mapc #'kill-buffer (list first-tree other-tree))
      (delete-directory root t))))

(ert-deftest gdev-test-ui-contract-document-tab-shows-unsaved-changes-until-saved ()
  "La scheda inattiva mostra le modifiche anche dopo il salvataggio automatico."
  (unless (fboundp 'gdev-workspaces--tab-name)
    (load (gdev-module-file :ui 'workspaces ".el") nil t t))
  (let* ((root (make-temp-file "gdev-tab-dirty-" t))
         (file (expand-file-name "documento-lungo.txt" root))
         document)
    (unwind-protect
        (gdev-test--with-layout
          (with-temp-file file (insert "Contenuto su disco\n"))
          (setq document (find-file-noselect file))
          (with-temp-buffer
            (gdev-layout-mark-document)
            (gdev-workspaces--enable-document-tabs)
            (set-window-buffer (gdev-layout-editor) (current-buffer))
            (let ((tab-line-tabs-function (lambda () (list (current-buffer) document)))
                  (pattern (rx "documento-lungo.txt" (* blank) "*")))
              (cl-labels ((dirty-title-p () (string-match-p pattern (apply #'concat (tab-line-format)))))
                (should-not (dirty-title-p))
                (with-current-buffer document
                  (goto-char (point-max))
                  (insert "Aggiornamento\n")
                  (let ((buffer-auto-save-file-name (expand-file-name "bozza" root)))
                    (do-auto-save t t)))
                (should (dirty-title-p))
                (let ((gdev-workspaces--tab-title-width 4))
                  (cl-letf (((symbol-function 'string-pixel-width) #'length))
                    (let ((title (gdev-workspaces--tab-name document nil)))
                      (should (<= (length title) 4))
                      (should (string-suffix-p "*" title)))))
                (with-current-buffer document (save-buffer))
                (should-not (dirty-title-p))
                (with-temp-buffer
                  (insert-file-contents file)
                  (should (search-forward "Aggiornamento" nil t)))))))
      (when (buffer-live-p document) (kill-buffer document))
      (delete-directory root t))))

(ert-deftest gdev-test-ui-contract-redrawn-views-are-not-unsaved-documents ()
  "Asterisco e × di avviso valgono per documenti e testo nuovo, non per le viste."
  (unless (fboundp 'gdev-workspaces--tab-name)
    (load (gdev-module-file :ui 'workspaces ".el") nil t t))
  (require 'tab-line)
  (let ((view (generate-new-buffer "Vista ridisegnata"))
        (draft (generate-new-buffer "senza titolo"))
        (notes (generate-new-buffer "Note")))
    (unwind-protect
        (progn
          (with-current-buffer view
            (special-mode)
            (let ((inhibit-read-only t)) (insert "Contenuto disegnato")))
          (with-current-buffer draft
            (setq-local buffer-offer-save 'always)
            (setq buffer-read-only t)
            (let ((inhibit-read-only t)) (insert "Bozza")))
          (with-current-buffer notes (text-mode) (insert "Appunto"))
          (should (buffer-modified-p view))
          (should-not (gdev-ui-buffer-unsaved-p view))
          (should-not (string-suffix-p "*" (gdev-workspaces--tab-name view nil)))
          (should-not (gdev-workspaces--tab-modified-p view t))
          (dolist (buffer (list draft notes))
            (should (gdev-ui-buffer-unsaved-p buffer))
            (should (string-suffix-p "*" (gdev-workspaces--tab-name buffer nil)))
            (should (gdev-workspaces--tab-modified-p buffer t)))
          (should (gdev-workspaces--tab-modified-p (list (cons 'buffer notes)) nil))
          (with-current-buffer notes (set-buffer-modified-p nil))
          (should-not (gdev-ui-buffer-unsaved-p notes)))
      (dolist (buffer (list view draft notes))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest gdev-test-ui-contract-document-navigation-keeps-group-and-focus ()
  "Le frecce seguono l'ordine delle schede, l'elenco individua il gruppo scelto."
  (require 'package)
  (package-activate-all)
  (unless (fboundp 'gdev-workspaces--tab-name)
    (load (gdev-module-file :ui 'workspaces ".el") nil t t))
  (require 'tab-line)
  (let ((first (generate-new-buffer "Primo documento"))
        (second (generate-new-buffer "Secondo documento"))
        (third (generate-new-buffer "Terzo documento"))
        (sidebar (generate-new-buffer "Elenco laterale")))
    (unwind-protect
        (gdev-test--with-layout
          (let ((editor (gdev-layout-editor)))
            (dolist (buffer (list first second third))
              (with-current-buffer buffer (gdev-layout-mark-document)))
            (select-window editor)
            (switch-to-buffer second)
            (switch-to-buffer first)
            (set-window-parameter editor 'tab-line-buffers (list first second))
            (let ((side (gdev-layout-show-left sidebar 'gdev-sidebar)))
              (select-window side)
              (gdev-workspaces-next-document)
              (should (eq (selected-window) editor))
              (should (eq (window-buffer editor) second))
              (gdev-workspaces-next-document)
              (should (eq (window-buffer editor) first))
              (gdev-workspaces-previous-document)
              (should (eq (window-buffer editor) second))
              (delete-window side))
            (let ((other (gdev-layout-split-editor 'right editor)))
              (set-window-buffer other third)
              (select-window editor)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt candidates &rest _)
                           (caar (seq-filter (lambda (entry) (eq (cddr entry) third)) candidates)))))
                (gdev-workspaces-switch-document))
              (should (eq (selected-window) other))
              (should (eq (window-buffer other) third))
              (should (eq (window-buffer editor) second)))))
      (mapc #'kill-buffer (list first second third sidebar)))))

(ert-deftest gdev-test-ui-contract-save-all-saves-named-documents ()
  "Salva tutti scrive i file aperti e conserva il documento senza nome."
  (require 'gdev-commands)
  (let ((root (make-temp-file "gdev-save-all-" t))
        (draft (generate-new-buffer "Bozza da nominare"))
        files)
    (unwind-protect
        (progn
          (dolist (name '("uno.txt" "due.txt"))
            (let ((file (expand-file-name name root)))
              (with-temp-file file (insert "Originale\n"))
              (let ((buffer (find-file-noselect file)))
                (push buffer files)
                (with-current-buffer buffer
                  (goto-char (point-max))
                  (insert "Modifica\n")))))
          (with-current-buffer draft
            (gdev-layout-mark-document)
            (insert "Da salvare con nome."))
          (gdev-save-all-documents)
          (should (buffer-modified-p draft))
          (should-not (buffer-file-name draft))
          (dolist (buffer files)
            (should-not (buffer-modified-p buffer))
            (with-temp-buffer
              (insert-file-contents (buffer-file-name buffer))
              (should (equal (buffer-string) "Originale\nModifica\n")))))
      (mapc #'kill-buffer (cons draft files))
      (delete-directory root t))))

(ert-deftest gdev-test-ui-contract-minimap-closes-like-a-view ()
  "Chiudi vista e la X nascondono la minimappa anche al prossimo aggiornamento."
  (require 'gdev-commands)
  (require 'gdev-minimap)
  (gdev-test--with-layout
    (let* ((frame (selected-frame))
           (editor (gdev-layout-editor))
           (document (generate-new-buffer "Documento con minimappa"))
           (previous (frame-parameter frame 'gdev-minimap-buffer)))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'gdev-minimap-buffer nil)
            (with-current-buffer document
              (insert "Prima riga\nSeconda riga\n")
              (gdev-layout-mark-document))
            (set-window-buffer editor document)
            (dolist (input '(command click))
              (ert-info ((format "Chiusura via %s" input))
                (gdev-workspace-state-set 'gdev-layout-minimap-visible t)
                (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
                  (gdev-minimap--sync frame))
                (let* ((side (window-with-parameter 'gdev-minimap t frame))
                       (mirror (window-buffer side)))
                  (should (window-live-p side))
                  (pcase input
                    ('command
                     (select-window side)
                     (call-interactively #'gdev-close-document))
                    ('click
                     (gdev-layout--update-close-buttons frame)
                     (let* ((header (window-parameter side 'header-line-format))
                            (map (get-text-property 0 'local-map (car header)))
                            (close (lookup-key map [header-line mouse-1])))
                       (funcall close (list 'mouse-1 (list side 'header-line '(1 . 1) 0))))))
                  (should-not (gdev-workspace-state-get 'gdev-layout-minimap-visible frame))
                  (should (buffer-live-p mirror))
                  (should (eq (frame-parameter frame 'gdev-minimap-buffer) mirror))
                  (should (eq (selected-window) editor))
                  (should (eq (window-buffer editor) document))
                  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
                    (gdev-minimap--sync frame))
                  (should-not (window-with-parameter 'gdev-minimap t frame))))))
        (let ((mirror (frame-parameter frame 'gdev-minimap-buffer)))
          (when (buffer-live-p mirror) (kill-buffer mirror)))
        (set-frame-parameter frame 'gdev-minimap-buffer previous)
        (kill-buffer document)))))

(ert-deftest gdev-test-ui-contract-fixed-panel-keeps-the-excluded-window ()
  "Se il pannello è escluso, una richiesta incompatibile lascia intatta la vista."
  (let ((first (generate-new-buffer "*Pannello di origine*"))
        (second (generate-new-buffer "*Pannello di destinazione*")))
    (unwind-protect
        (gdev-test--with-layout
          (let ((panel (display-buffer first)))
            (should (eq panel (gdev-layout--panel)))
            (with-selected-window panel
              (should-not (display-buffer second '(nil (inhibit-same-window . t))))
              (should (eq (window-buffer panel) first)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest gdev-test-ui-contract-display-respects-background-and-precedence ()
  "Il divieto in primo piano e la precedenza delle opzioni seguono il chiamante."
  (let ((first (generate-new-buffer "Documento in primo piano"))
        (second (generate-new-buffer "Documento richiesto"))
        (this-command nil))
    (unwind-protect
        (gdev-test--with-layout
          (let ((origin (selected-window)))
            (set-window-buffer origin first)
            (should-not (display-buffer
                         second '(display-buffer-no-window (allow-no-window . t))))
            (should (eq (window-buffer origin) first))
            (should (one-window-p))
            (cl-letf (((symbol-function 'split-window-right)
                       (lambda (&rest _) (user-error "Spazio insufficiente"))))
              (should-not (display-buffer second '(nil (inhibit-same-window . t))))
              (should (eq (window-buffer origin) first)))
            (let ((display-buffer-overriding-action '(nil (inhibit-same-window . nil))))
              (should (eq (display-buffer second '(nil (inhibit-same-window . t))) origin))
              (should (eq (window-buffer origin) second)))))
      (mapc #'kill-buffer (list first second)))))

(ert-deftest gdev-test-ui-contract-auxiliary-fallback-keeps-excluded-panel ()
  "La vista ausiliaria usa il pannello solo quando la richiesta lo permette."
  (let ((tool (generate-new-buffer "*Strumento in primo piano*"))
        (auxiliary (generate-new-buffer "*Ausiliario richiesto*"))
        (this-command nil))
    (unwind-protect
        (gdev-test--with-layout
          (with-current-buffer auxiliary (gdev-layout-mark-auxiliary))
          (let ((editor (selected-window))
                (panel (display-buffer tool))
                (action '(nil (inhibit-same-window . t))))
            (cl-letf (((symbol-function 'gdev-layout--show-auxiliary) #'ignore))
              (with-selected-window panel
                (should-not (display-buffer auxiliary action))
                (should (eq (window-buffer panel) tool))
                (should-not (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer)))
              (should (eq (display-buffer auxiliary action) panel))
              (should (eq (window-buffer panel) auxiliary))
              (should (eq (selected-window) editor)))))
      (mapc #'kill-buffer (list auxiliary tool)))))

(ert-deftest gdev-test-ui-contract-display-keeps-explicit-frame-options ()
  "L'azione esplicita per un frame mantiene parametri e scelta di fuoco."
  (let ((document (generate-new-buffer "Documento in un frame"))
        options body-window)
    (unwind-protect
        (gdev-test--with-layout
          (let ((window (selected-window)))
            (cl-letf (((symbol-function 'display-buffer-pop-up-frame)
                       (lambda (_buffer alist) (setq options alist) window)))
              (should
               (eq (display-buffer
                    document `(display-buffer-pop-up-frame
                               (inhibit-switch-frame . t)
                               (pop-up-frame-parameters (name . "Documento"))
                               (body-function . ,(lambda (destination)
                                                   (should-not body-window)
                                                   (setq body-window destination)))))
                   window))
              (should (equal options '((inhibit-switch-frame . t)
                                       (pop-up-frame-parameters (name . "Documento")))))
              (should (eq body-window window)))))
      (kill-buffer document))))

(ert-deftest gdev-test-ui-contract-late-system-appearance-keeps-manual-theme ()
  "La scelta manuale invalida la risposta precedente e può tornare al sistema.
Da tastiera e menu la scelta resta per il prossimo avvio, come in Preferenze."
  (let ((gdev-macos-p t)
        (gdev-follow-system-appearance t)
        (gdev-ui--appearance 'light)
        (gdev-ui--appearance-request nil)
        (gdev-ui--appearance-checked-at 0)
        requests saved)
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (symbol value &rest _) (push (cons symbol value) saved)))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (push (cons (plist-get args :buffer) (plist-get args :sentinel)) requests)))
              ((symbol-function 'process-live-p) #'ignore)
              ((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'gdev-ui-apply-appearance)
               (lambda (appearance &optional _force) (setq gdev-ui--appearance appearance))))
      (unwind-protect
          (progn
            (gdev-ui--sync-appearance)
            (call-interactively #'gdev-ui-toggle-theme)
            (funcall (cdar requests) 'finished "finito")
            (should (eq gdev-ui--appearance 'dark))
            (should-not gdev-follow-system-appearance)
            (should (equal saved '((gdev-follow-system-appearance))))
            (should-not (buffer-live-p (caar requests)))
            (call-interactively #'gdev-ui-sync-appearance)
            (gdev-ui--sync-appearance)
            (with-current-buffer (caadr requests) (insert "Dark"))
            (funcall (cdar requests) 'finished "finito")
            (funcall (cdadr requests) 'finished "finito")
            (should gdev-follow-system-appearance)
            (should (equal (car saved) '(gdev-follow-system-appearance . t)))
            (should (eq gdev-ui--appearance 'light))
            (should-not gdev-ui--appearance-request))
        (dolist (request requests)
          (when (buffer-live-p (car request)) (kill-buffer (car request))))))))

(ert-deftest gdev-test-ui-contract-failed-appearance-process-keeps-theme ()
  "Una lettura abortita libera i suoi dati, una chiave assente vale come chiaro."
  (let ((gdev-macos-p t)
        (gdev-follow-system-appearance t)
        (gdev-ui--appearance 'dark)
        (gdev-ui--appearance-request nil)
        (gdev-ui--appearance-checked-at 0)
        status code output sentinel)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq output (plist-get args :buffer)
                       sentinel (plist-get args :sentinel))))
              ((symbol-function 'process-live-p) #'ignore)
              ((symbol-function 'process-status) (lambda (_) status))
              ((symbol-function 'process-exit-status) (lambda (_) code))
              ((symbol-function 'gdev-ui-apply-appearance)
               (lambda (appearance &optional _force) (setq gdev-ui--appearance appearance))))
      (unwind-protect
          (dolist (result '((signal 15 dark) (exit 127 dark) (exit 1 light)))
            (pcase-let ((`(,result-status ,result-code ,appearance) result))
              (setq status result-status code result-code)
              (gdev-ui-sync-appearance)
              (funcall sentinel 'finished "finito")
              (should-not (buffer-live-p output))
              (should-not gdev-ui--appearance-request)
              (should (eq gdev-ui--appearance appearance))))
        (when (buffer-live-p output) (kill-buffer output))))))

(ert-deftest gdev-test-ui-contract-appearance-launch-error-cleans-up ()
  "Un errore di avvio lascia il tema corrente e rilascia il buffer di lettura."
  (let ((gdev-macos-p t)
        (gdev-follow-system-appearance t)
        (gdev-ui--appearance 'dark)
        (gdev-ui--appearance-request nil)
        (gdev-ui--appearance-checked-at 0)
        output)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq output (plist-get args :buffer))
                 (signal 'file-error '("Processo indisponibile")))))
      (unwind-protect
          (progn
            (should-error (gdev-ui-sync-appearance) :type 'file-error)
            (should (bufferp output))
            (should-not (buffer-live-p output))
            (should-not gdev-ui--appearance-request)
            (should (eq gdev-ui--appearance 'dark)))
        (when (buffer-live-p output) (kill-buffer output))))))

;;; gdev-ui-contract-test.el ends here
