;;; gdev-ui.el --- Aspetto delle aree di testo e delle finestre di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; L'aspetto di GDev-Emacs: essenziale e chiaro come un'app di macOS,
;; asciutto come un terminale.
;;
;;   - tema chiaro e tema scuro con i colori di sistema di macOS, scelti
;;     secondo l'aspetto del sistema (i temi Modus sono inclusi in Emacs e
;;     pensati per la leggibilità; qui ne cambia solo la tavolozza);
;;   - SF Mono per il codice, caratteri di sistema per le etichette;
;;   - niente bordi né riquadri: separatori sottili, margini, interlinea;
;;   - nelle aree di testo di codice numeri di riga, riga corrente
;;     e margine destro, tutti discreti.
;;
;; Tema e caratteri si applicano dopo il config.el privato: impostare lì
;; `gdev-theme-dark' o `gdev-font-height' basta.

;;; Code:

(declare-function set-fontset-font "fontset.c" (name target font-spec &optional frame add))

(require 'gdev-lib)
(require 'button)
(require 'face-remap)

(defvar gdev-ui--icons (make-hash-table :test #'equal)
  "Icone già preparate per nome, dimensione e colore.")

(defun gdev-ui-icon (name fallback &optional frame face height)
  "Restituisci l'icona NAME per FRAME con il colore di FACE, o FALLBACK.
Con HEIGHT usa esattamente quell'altezza in pixel."
  (if (and (display-graphic-p frame) (image-type-available-p 'svg))
      (let* ((pixels (or height (frame-char-height frame)))
             (scale (if height 1 'default))
             (color (face-foreground (or face 'default) frame t))
             (key (list name fallback pixels scale color)))
        (or (gethash key gdev-ui--icons)
            (puthash key
                     (let ((file (gdev-config-file (format "icons/%s.svg" name))))
                       (if (not (file-readable-p file)) fallback
                         (condition-case nil
                             (propertize fallback 'display
                                         (create-image file 'svg nil :height pixels :scale scale
                                                       :ascent 'center :foreground color))
                           (error fallback))))
                     gdev-ui--icons)))
    fallback))

(defconst gdev-ui--module-icon-groups
  '(("git" git hithub vc vc-gutter)
    ("terminal" eat sh)
    ("debug" debugger)
    ("build" build profiler)
    ("check" syntax spell hl-todo)
    ("notes" org markdown)
    ("remote" remote)
    ("agent" agent llm)
    ("search" lookup window-select)
    ("session" workspaces undo)
    ("file" dired sidebar ibuffer)
    ("settings" macos default))
  "Icone specifiche dei moduli, prima delle icone di categoria.")

(defun gdev-ui-module-icon (category module)
  "Restituisce l'icona di MODULE oppure quella della sua CATEGORY."
  (let ((name (or (car (seq-find (lambda (group) (memq module (cdr group)))
                               gdev-ui--module-icon-groups))
                  (alist-get category '((:completion . "search") (:ui . "window")
                                        (:editor . "edit") (:emacs . "file")
                                        (:term . "terminal") (:checkers . "check")
                                        (:tools . "build") (:os . "settings")
                                        (:lang . "code") (:config . "settings")))
                  "settings")))
    (gdev-ui-icon name "·")))

(defun gdev-ui-string-pixel-width (text)
  "Misura TEXT in pixel con le facce del buffer corrente."
  (static-if (>= emacs-major-version 31)
      (string-pixel-width text (current-buffer))
    ;; Emacs 30 non accetta il buffer come secondo argomento.
    (let ((faces face-remapping-alist))
      (with-current-buffer (get-buffer-create " *gdev-ui-measure*")
        (setq-local face-remapping-alist faces
                    display-line-numbers nil)
        (erase-buffer)
        (insert text)
        (car (buffer-text-pixel-size nil nil t))))))

(defun gdev-ui-window-starts (&optional buffer)
  "Righe d'inizio delle finestre di BUFFER, da riportare con
`gdev-ui-restore-windows'.  Da chiamare prima di ridisegnare con
`erase-buffer'."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar (lambda (window) (cons window (count-lines (point-min) (window-start window))))
            (get-buffer-window-list nil nil t))))

(defun gdev-ui-restore-windows (starts)
  "Riporta le finestre di STARTS al punto corrente e alla riga d'inizio salvata.
`erase-buffer' porta a 1 il punto e l'inizio delle finestre non selezionate:
una vista che si ridisegna da un gancio, mentre l'utente lavora altrove,
perderebbe selezione e scorrimento.  STARTS viene da `gdev-ui-window-starts'."
  (dolist (entry starts)
    (let ((window (car entry)))
      (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
        (unless (eq window (selected-window))
          (set-window-point window (point)))
        (set-window-start window (save-excursion
                                   (goto-char (point-min))
                                   (forward-line (cdr entry))
                                   (point))
                          t)))))

(defun gdev-ui-buffer-pixel-width (&optional buffer)
  "Larghezza in pixel della finestra più stretta che mostra BUFFER, o nil.
Una vista disposta su questa larghezza resta entro il bordo in ogni
finestra che la mostra, anche dopo `split-window'."
  (when-let* ((windows (get-buffer-window-list (or buffer (current-buffer)) 'nomini t)))
    (apply #'min (mapcar (lambda (window) (window-body-width window t)) windows))))

(defun gdev-ui-fit-text (text width measure)
  "Accorcia TEXT a WIDTH usando MEASURE come funzione di misura.
Conserva le proprietà del testo e accorcia tra un glifo e l'altro."
  (if (<= (funcall measure text) width) text
    (let ((ellipsis (propertize "…" 'face (get-text-property 0 'face text))))
      (if (> (funcall measure ellipsis) width) ""
        (let ((ends (make-vector (1+ (length text)) 0))
              (position 0)
              (low 0)
              (high 0))
          (while (< position (length text))
            (let* ((next (1+ position))
                   (composition (find-composition position next text)))
              ;; Alcuni terminali restituiscono anche la composizione precedente.
              (setq position
                    (if (and composition (car (cddr composition))
                             (<= (car composition) position)
                             (< position (cadr composition)))
                        (min (length text) (cadr composition))
                      next))
              (aset ends (cl-incf high) position)))
          (while (< (1+ low) high)
            (let* ((mid (/ (+ low high) 2))
                   (candidate (concat (substring text 0 (aref ends mid)) ellipsis)))
              (if (<= (funcall measure candidate) width)
                  (setq low mid)
                (setq high mid))))
          (concat (substring text 0 (aref ends low)) ellipsis))))))

(defun gdev-ui-fit-file-name (name width measure)
  "Accorcia NAME entro WIDTH, conservando l'estensione quando c'è spazio."
  (if (<= (funcall measure name) width) name
    (if-let* ((extension (file-name-extension name t))
              ((> (length extension) 1))
              (end (- (length name) (length extension)))
              (suffix (substring name end))
              (stem (gdev-ui-fit-text (substring name 0 end) width
                                     (lambda (text) (funcall measure (concat text suffix)))))
              ((> (length stem) 1)))
        (concat stem suffix)
      (gdev-ui-fit-text name width measure))))

;;;; Tema e aspetto del sistema

(defgroup gdev-ui nil
  "Aspetto: temi, caratteri, finestre."
  :group 'gdev)

(defcustom gdev-theme-light 'modus-operandi
  "Tema usato quando l'aspetto del sistema è chiaro."
  :type 'symbol)

(defcustom gdev-theme-dark 'modus-vivendi
  "Tema usato quando l'aspetto del sistema è scuro."
  :type 'symbol)

(defcustom gdev-follow-system-appearance gdev-macos-p
  "Se non nil, il tema segue il passaggio chiaro/scuro di macOS.
Il controllo avviene quando una finestra di Emacs torna in primo piano,
al massimo ogni 30 secondi, in un processo separato: Emacs non attende."
  :type 'boolean)

(defvar modus-themes-italic-constructs)
(defvar modus-themes-bold-constructs)
(defvar modus-themes-mixed-fonts)
(defvar modus-themes-prompts)
(defvar modus-themes-completions)
(defvar modus-themes-common-palette-overrides)
(defvar modus-operandi-palette-overrides)
(defvar modus-vivendi-palette-overrides)

(defun gdev-ui--configure-modus ()
  "Imposta colori e facce usati dai temi di GDev."
  ;; Niente corsivi e grassetti sparsi nel codice.
  (setq modus-themes-italic-constructs nil
        modus-themes-bold-constructs nil
        modus-themes-mixed-fonts t
        modus-themes-prompts '(semibold)
        modus-themes-completions '((selection . (semibold)))
        ;; Bordi invisibili: margini, numeri di riga e barra di stato hanno lo
        ;; stesso fondo di ciò che li circonda.
        modus-themes-common-palette-overrides
        '((fringe unspecified)
          (bg-line-number-active unspecified)
          (bg-line-number-inactive unspecified)
          (border-mode-line-active bg-mode-line-active)
          (border-mode-line-inactive bg-mode-line-inactive)))

  ;; I colori di sistema di macOS, nella variante chiara e scura.
  (setq modus-operandi-palette-overrides
        '((bg-main "#ffffff") (fg-main "#1d1d1f")
        (bg-dim "#f5f5f7") (fg-dim "#595960")
          (border "#e5e5ea") (cursor "#007aff")
          (bg-hl-line "#f5f5f7") (bg-region "#b3d7ff") (bg-paren-match "#d1d1d6")
        (fg-prompt "#194777") (bg-completion "#dceaff")
        (fg-completion-match-0 "#194777") (fg-completion-match-1 "#77277c")
        (fg-completion-match-2 "#005b63") (fg-completion-match-3 "#a22531")
          (bg-mode-line-active "#f5f5f7") (fg-mode-line-active "#1d1d1f")
          (bg-mode-line-inactive "#ffffff") (fg-mode-line-inactive "#595960")
        (fg-line-number-inactive "#676772") (fg-line-number-active "#1d1d1f")
          (bg-tab-bar "#f5f5f7") (bg-tab-current "#ffffff") (bg-tab-other "#f5f5f7")
          (keyword "#9b2393") (builtin "#6c36a9") (preprocessor "#643820")
          (string "#c41a16") (docstring "#5d6c79") (comment "#5d6c79")
          (number "#1c00cf") (constant "#1c00cf")
          (type "#0b4f79") (fnname "#326d74") (variable "#0f68a0")))

  (setq modus-vivendi-palette-overrides
        '((bg-main "#1e1e20") (fg-main "#e5e5e7")
        (bg-dim "#2c2c2e") (fg-dim "#b9bac2")
          (border "#38383a") (cursor "#32d74b")
          (bg-hl-line "#262629") (bg-region "#3f638b") (bg-paren-match "#48484a")
        (fg-prompt "#a8ceff") (bg-completion "#294563")
        (fg-completion-match-0 "#a8ceff") (fg-completion-match-1 "#f0b5f5")
        (fg-completion-match-2 "#83dedc") (fg-completion-match-3 "#ffb5ac")
          (bg-mode-line-active "#2c2c2e") (fg-mode-line-active "#e5e5e7")
          (bg-mode-line-inactive "#1e1e20") (fg-mode-line-inactive "#8e8e93")
        (fg-line-number-inactive "#93939e") (fg-line-number-active "#e5e5e7")
          (bg-tab-bar "#2c2c2e") (bg-tab-current "#1e1e20") (bg-tab-other "#2c2c2e")
          (keyword "#fc5fa3") (builtin "#d0a8ff") (preprocessor "#fd8f3f")
        (string "#fc6a5d") (docstring "#a0aab5") (comment "#a0aab5")
          (number "#d0bf69") (constant "#d0bf69")
          (type "#5dd8ff") (fnname "#67b7a4") (variable "#41a1c0"))))

(defvar gdev-ui--appearance nil "Aspetto mostrato ora: `light' (chiaro) o `dark' (scuro).")
(defvar gdev-ui--appearance-checked-at 0 "Quando è stato letto l'ultima volta l'aspetto del sistema.")
(defvar gdev-ui--appearance-request nil "Identità della lettura di sistema ancora valida.")

(defun gdev-ui--appearance-cache () (gdev-state-file "appearance"))

(defvar gdev-ui-after-theme-hook nil
  "Funzioni eseguite dopo ogni cambio di tema, per ritoccare le facce (faces).")

(defface gdev-ui-secondary
  '((((background light)) :foreground "#595960")
    (((background dark)) :foreground "#b9bac2"))
  "Testo secondario leggibile sui fondi dell'interfaccia.")

(defface gdev-ui-side-surface
  '((((background light)) :background "#f4f5f7")
    (((background dark)) :background "#25262a"))
  "Superficie dei riquadri laterali."
  :group 'gdev-ui)

(defface gdev-ui-side-selection
  '((((background light)) :background "#d5e5fd" :extend t)
    (((background dark)) :background "#31466a" :extend t))
  "Riga selezionata nel riquadro laterale attivo."
  :group 'gdev-ui)

(defface gdev-ui-side-hover
  '((((background light)) :background "#e7ebf3")
    (((background dark)) :background "#353842"))
  "Riga sotto il puntatore in un riquadro laterale."
  :group 'gdev-ui)

(defface gdev-ui-side-title
  '((t :inherit variable-pitch :height 1.12 :weight semi-bold))
  "Intestazione di un riquadro laterale."
  :group 'gdev-ui)

(defface gdev-ui-view-title
  '((t :inherit variable-pitch :height 1.30 :weight semi-bold))
  "Titolo di una pagina dell'interfaccia."
  :group 'gdev-ui)

(defface gdev-ui-view-heading
  '((t :weight semi-bold))
  "Titolo di sezione alla dimensione del corpo."
  :group 'gdev-ui)

(defface gdev-ui-action
  '((((background light)) :foreground "#164781")
    (((background dark)) :foreground "#b9d7ff"))
  "Testo di un'azione sulle superfici dell'interfaccia."
  :group 'gdev-ui)

(defface gdev-ui-action-primary
  '((t :inherit (gdev-ui-action gdev-ui-side-selection) :extend nil :weight semi-bold))
  "Azione primaria o controllo selezionato."
  :group 'gdev-ui)

(defface gdev-ui-side-current
  '((((background light)) :background "#e3ebf9" :extend t)
    (((background dark)) :background "#2e394c" :extend t))
  "Elemento aperto nel riquadro, distinto dal fuoco della tastiera."
  :group 'gdev-ui)

(defface gdev-ui-status-warning
  '((((background light)) :foreground "#694400" :weight semi-bold)
    (((background dark)) :foreground "#ffcc77" :weight semi-bold))
  "Testo di uno stato che richiede attenzione."
  :group 'gdev-ui)

(defface gdev-ui-status-success
  '((((background light)) :foreground "#1c5433" :weight semi-bold)
    (((background dark)) :foreground "#a0e8b4" :weight semi-bold))
  "Testo di uno stato positivo."
  :group 'gdev-ui)

(defface gdev-ui-status-error
  '((((background light)) :foreground "#a3262a" :weight semi-bold)
    (((background dark)) :foreground "#ffb3ad" :weight semi-bold))
  "Testo di un esito non riuscito o di un elemento chiuso senza esito."
  :group 'gdev-ui)

(defface gdev-ui-status-accent
  '((((background light)) :foreground "#6a3fb0" :weight semi-bold)
    (((background dark)) :foreground "#d9c2ff" :weight semi-bold))
  "Testo di uno stato concluso da distinguere dal successo, come un'unione."
  :group 'gdev-ui)

(defun gdev-ui-badge (icon fallback face label &optional help)
  "Restituisci l'icona ICON con l'etichetta LABEL nella faccia FACE.
FALLBACK sostituisce l'icona in un terminale.  HELP diventa il suggerimento
mostrato dal puntatore.  Il colore accompagna sempre un testo leggibile."
  (let ((badge (concat (gdev-ui-icon icon fallback nil face) " "
                       (propertize label 'face face))))
    (if help (propertize badge 'help-echo help) badge)))

(defun gdev-ui-insert-actions (actions &optional width)
  "Inserisci ACTIONS come pulsanti su righe larghe al più WIDTH pixel.
Ogni azione è (ICONA RISERVA ETICHETTA COMANDO . PROPRIETÀ).  COMANDO è
un comando o una funzione senza argomenti.  PROPRIETÀ accetta :primary
per l'azione principale e :help per il suggerimento.  Una riga va a capo
prima del pulsante che non ci sta; WIDTH predefinita è la finestra."
  (let ((limit (or width (window-body-width nil t)))
        (gap (gdev-ui-string-pixel-width "   "))
        (used 0))
    (dolist (action actions)
      (pcase-let* ((`(,icon ,fallback ,label ,command . ,properties) action)
                   (face (if (plist-get properties :primary) 'gdev-ui-action-primary 'gdev-ui-action))
                   (text (concat " " (gdev-ui-icon icon fallback nil face) " "
                                 (propertize label 'face face) " "))
                   (size (gdev-ui-string-pixel-width text)))
        (cond ((zerop used))
              ((> (+ used gap size) limit) (insert "\n") (setq used 0))
              (t (insert "   ") (setq used (+ used gap))))
        (insert-text-button text :type 'gdev-ui-action 'face face
                            'help-echo (or (plist-get properties :help) label)
                            'action (lambda (_)
                                      (if (commandp command)
                                          (call-interactively command)
                                        (funcall command))))
        (setq used (+ used size))))
    (insert "\n")))

(defun gdev-ui-align-right (text &optional margin)
  "Restituisci TEXT preceduto dallo spazio che lo allinea al margine destro.
MARGIN aggiunge pixel di respiro dal bordo della finestra."
  (concat (propertize " " 'display
                      `(space :align-to (- right (,(+ (or margin 12)
                                                     (gdev-ui-string-pixel-width text))))))
          text))

(defvar-keymap gdev-ui-action-map
  :parent button-map
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'push-button)

(define-button-type 'gdev-ui-action
  'follow-link t 'keymap gdev-ui-action-map
  'face 'gdev-ui-action 'mouse-face 'gdev-ui-side-hover)

(defvar-local gdev-ui-view-profile nil
  "Profilo grafico applicato alla modalità corrente.")

(defun gdev-ui-view-setup (profile)
  "Applica PROFILE alla vista corrente.
Document e sidebar usano il carattere d'interfaccia. Table mantiene
allineate le colonne. Native segue la modalità di Emacs. Preview
identifica viste non testuali come la minimappa."
  (unless (eq profile gdev-ui-view-profile)
    (pcase profile
      ((or 'document 'sidebar)
       (variable-pitch-mode 1)
       (setq-local display-line-numbers nil
                   line-spacing 0.22)
       (when (eq profile 'sidebar)
         (setq-local truncate-lines t
                     mode-line-format nil
                     hl-line-face 'gdev-ui-side-selection
                     hl-line-sticky-flag nil)
         (face-remap-add-relative 'default 'gdev-ui-side-surface)
         (face-remap-add-relative 'fringe 'gdev-ui-side-surface)
         (face-remap-add-relative 'header-line
                                  '(:box nil :underline nil) 'gdev-ui-side-surface)))
      ('table
       (buffer-face-set 'fixed-pitch)
       (setq-local tabulated-list-padding 2
                   hl-line-face 'gdev-ui-side-selection
                   hl-line-sticky-flag nil))
      ((or 'native 'preview))
      (_ (error "Profilo grafico sconosciuto: %s" profile)))
    (setq-local gdev-ui-view-profile profile)))

(defun gdev-ui-scratch-buffer-p (&optional buffer)
  "Restituisci non nil per l'area Appunti di Emacs."
  (equal (buffer-name buffer) "*scratch*"))

(defun gdev-ui-buffer-name (&optional buffer)
  "Restituisci il nome di BUFFER da mostrare nell'interfaccia."
  (if (gdev-ui-scratch-buffer-p buffer) "Appunti" (buffer-name buffer)))

(defun gdev-ui-buffer-unsaved-p (&optional buffer)
  "Indica che BUFFER contiene modifiche dell'utente non ancora salvate.
Contano i file, i nuovi documenti e il testo modificabile. Le viste in
sola lettura che ridisegnano il proprio contenuto non hanno nulla da salvare."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-modified-p buffer)
         (with-current-buffer buffer
           (or buffer-file-name buffer-offer-save
               (not (or buffer-read-only (derived-mode-p 'special-mode)))))
         t)))

(defun gdev-ui-setup-scratch ()
  "Applica ad Appunti l'intestazione di GDev e conserva la modalità di modifica."
  (when (gdev-ui-scratch-buffer-p)
    (gdev-ui-view-setup 'native)
    (setq-local header-line-format
                (list "  " (propertize "Appunti" 'face 'gdev-ui-side-title)
                      "  " (propertize (format-mode-line mode-name) 'face 'gdev-ui-secondary)))))

(defconst gdev-ui--mode-labels
  '((fundamental-mode . "Testo semplice")
    (dired-mode . "Gestore file") (wdired-mode . "Rinomina file")
    (ibuffer-mode . "Documenti e strumenti") (Buffer-menu-mode . "Documenti e strumenti")
    (help-mode . "Aiuto") (helpful-mode . "Aiuto") (Info-mode . "Manuale")
    (Custom-mode . "Preferenze") (messages-buffer-mode . "Messaggi")
    (compilation-mode . "Compilazione") (grep-mode . "Risultati di ricerca")
    (diff-mode . "Differenze") (flymake-project-diagnostics-mode . "Problemi")
    (flymake-diagnostics-buffer-mode . "Problemi")
    (eat-mode . "Terminale") (term-mode . "Terminale") (shell-mode . "Terminale")
    (eshell-mode . "Interprete Lisp") (vundo-mode . "Cronologia annullamenti")
    (dape-info-parent-mode . "Esecuzione passo passo") (dape-repl-mode . "Console di debug")))

(defun gdev-ui-mode-label (&optional buffer)
  "Restituisci il nome della vista o del linguaggio di BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (or (and (gdev-ui-scratch-buffer-p) "Appunti")
        (cl-loop for mode = major-mode then (get mode 'derived-mode-parent)
                 while mode
                 thereis (alist-get mode gdev-ui--mode-labels))
        (let ((label (string-trim (if (stringp mode-name) mode-name (format-mode-line mode-name)))))
          ;; CC Mode accoda a mode-name gli indicatori di stile, come «C++//l».
          (when (and (bound-and-true-p c-buffer-is-cc-mode)
                     (string-match "\\`[^/]+" label))
            (setq label (string-trim (match-string 0 label))))
          (if (string-empty-p label) "Documento" (substring-no-properties label))))))

(defun gdev-ui--refine-faces ()
  "Imposta la tipografia comune di intestazioni e barre di stato."
  (set-face-attribute 'minibuffer-prompt nil :family 'unspecified :inherit 'variable-pitch)
  (dolist (face '(mode-line mode-line-active mode-line-inactive))
    (when (facep face)
      (set-face-attribute face nil
                          :box `(:line-width (1 . 6) :color ,(face-background face nil t))
                          :family 'unspecified :height 1.0 :inherit 'variable-pitch
                          :overline nil :underline nil)))
  (dolist (face '(header-line header-line-inactive))
    (when (facep face)
      (set-face-attribute face nil
                          :box `(:line-width (1 . 3) :color ,(face-background face nil t))
                          :family 'unspecified :height 1.0 :weight 'semi-bold
                          :inherit 'variable-pitch)))
  (run-hooks 'gdev-ui-after-theme-hook))

(defun gdev-ui--tabular-header ()
  "Allinea le intestazioni delle tabelle alle colonne a spaziatura fissa."
  (face-remap-add-relative 'header-line 'fixed-pitch)
  (when (facep 'header-line-inactive)
    (face-remap-add-relative 'header-line-inactive 'fixed-pitch)))

(defun gdev-ui-apply-appearance (appearance &optional force)
  "Carica il tema per APPEARANCE (`light' o `dark').
Non fa nulla se è già quello mostrato, salvo con FORCE."
  (when (or force (not (eq appearance gdev-ui--appearance)))
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme (if (eq appearance 'dark) gdev-theme-dark gdev-theme-light) t)
    (setq gdev-ui--appearance appearance)
    ;; Le finestre create dopo questo punto partono da `default-frame-alist': con i
    ;; valori di avvio avrebbero lo sfondo e la barra del titolo del tema precedente.
    (setf (alist-get 'background-color default-frame-alist)
          (if (eq appearance 'dark) "#1e1e20" "#ffffff"))
    (when gdev-macos-p
      (setf (alist-get 'ns-appearance default-frame-alist) appearance))
    (gdev-ui--refine-faces)
    ;; Su macOS la barra del titolo segue il tema.
    (when gdev-macos-p
      (dolist (frame (frame-list))
        (set-frame-parameter frame 'ns-appearance appearance)))
    ;; early-init.el lo legge per colorare la prima finestra del prossimo avvio.
    (ignore-errors
      (with-temp-file (gdev-ui--appearance-cache)
        (insert (symbol-name appearance))))))

(defun gdev-ui--sync-appearance ()
  "Leggi l'aspetto di macOS se il tema segue ancora il sistema."
  (when (and gdev-macos-p gdev-follow-system-appearance)
    (let ((request (make-symbol "aspetto"))
          (buffer (generate-new-buffer " *gdev-appearance*"))
          ;; La cartella del buffer corrente può non esistere più.
          (default-directory temporary-file-directory))
      (setq gdev-ui--appearance-checked-at (float-time)
            gdev-ui--appearance-request request)
      (condition-case err
          (make-process
           :name "gdev-appearance" :buffer buffer :noquery t
           :command '("defaults" "read" "-g" "AppleInterfaceStyle")
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (let ((appearance
                      (when (and (buffer-live-p buffer) (eq (process-status process) 'exit))
                        (pcase (process-exit-status process)
                          (0 (with-current-buffer buffer
                               (if (string-search "Dark" (buffer-string)) 'dark 'light)))
                          ;; In modalità chiara la chiave AppleInterfaceStyle può mancare.
                          (1 'light)))))
                 (when (buffer-live-p buffer)
                   (kill-buffer buffer))
                 (when (eq gdev-ui--appearance-request request)
                   (setq gdev-ui--appearance-request nil)
                   (when (and gdev-follow-system-appearance appearance)
                     (gdev-ui-apply-appearance appearance)))))))
        (error
         (kill-buffer buffer)
         (setq gdev-ui--appearance-request nil)
         (signal (car err) (cdr err)))))))

(defun gdev-ui-sync-appearance (&optional save)
  "Segui l'aspetto di macOS e chiedi subito quello corrente.
Con SAVE, sempre da menu e tastiera, la scelta vale anche al prossimo
avvio, come in Preferenze."
  (interactive (list t))
  (gdev-ui-set-appearance 'system save))

(defun gdev-ui--on-focus-change ()
  "Ricontrolla l'aspetto del sistema quando una finestra torna in primo piano."
  (when (and gdev-follow-system-appearance
             (frame-focus-state (selected-frame))
             (> (- (float-time) gdev-ui--appearance-checked-at) 30))
    (gdev-ui--sync-appearance)))

(defun gdev-ui-toggle-theme ()
  "Alterna tema chiaro e scuro e smette di seguire l'aspetto del sistema.
La scelta vale anche al prossimo avvio, come in Preferenze."
  (interactive)
  (gdev-ui-set-appearance (if (eq gdev-ui--appearance 'dark) 'light 'dark) t))

(defun gdev-ui-set-appearance (appearance &optional save)
  "Applica APPEARANCE, `light', `dark' o `system', e con SAVE ricorda la scelta."
  (pcase appearance
    ('system
     (unless gdev-macos-p (user-error "L'aspetto del sistema è disponibile su macOS"))
     (setq gdev-follow-system-appearance t)
     (gdev-ui--sync-appearance))
    ((or 'light 'dark)
     (setq gdev-follow-system-appearance nil
           gdev-ui--appearance-request nil)
     (gdev-ui-apply-appearance appearance))
    (_ (user-error "Scegli l'aspetto chiaro, scuro o di sistema")))
  (when save (customize-save-variable 'gdev-follow-system-appearance (eq appearance 'system))))

(defun gdev-ui-init-theme ()
  "Mostra subito l'aspetto salvato, poi lo conferma in modo asincrono."
  (unless noninteractive
    (gdev-ui-apply-appearance
     (if (string-prefix-p "dark" (or (gdev-read-file-contents (gdev-ui--appearance-cache)) ""))
         'dark 'light)
     'force)
    (when gdev-macos-p
      (add-hook 'emacs-startup-hook #'gdev-ui--sync-appearance)
      (add-function :after after-focus-change-function #'gdev-ui--on-focus-change))))

;;;; Caratteri

(defcustom gdev-font-families
  '("SF Mono" "Menlo" "Source Code Pro" "Consolas" "DejaVu Sans Mono")
  "Famiglie a spaziatura fissa da provare, in ordine: vince la prima installata.
SF Mono è dentro Terminale di macOS; il programma di preparazione (bootstrap)
lo rende disponibile."
  :type '(repeat string))

(defcustom gdev-variable-pitch-families
  '(".AppleSystemUIFont" "SF Pro Text" "SF Pro" "Helvetica Neue" "Segoe UI" "DejaVu Sans")
  "Famiglie proporzionali (testo in prosa, per esempio nelle note Org), in ordine."
  :type '(repeat string))

(defcustom gdev-font-height (if gdev-macos-p 130 110)
  "Altezza del carattere predefinito, in decimi di punto."
  :type 'integer)

(defcustom gdev-ui-control-scale 1.08
  "Ingrandimento delle richieste e dei menu temporanei."
  :type 'float)

(defvar-local gdev-ui--control-remap nil)

(defun gdev-ui-scale-controls ()
  "Ingrandisci il testo dell'area di testo corrente, conservandone il carattere."
  (when gdev-ui--control-remap
    (face-remap-remove-relative gdev-ui--control-remap))
  (setq gdev-ui--control-remap
        (face-remap-add-relative 'default :height gdev-ui-control-scale)))

(defcustom gdev-line-spacing 0.12
  "Spazio aggiunto fra le righe, in frazioni dell'altezza del carattere."
  :type 'number)

(defun gdev-ui--first-font (families &optional frame)
  "Restituisce la prima delle FAMILIES disponibile in FRAME."
  (cl-find-if (lambda (name) (find-font (font-spec :family name) frame)) families))

(defun gdev-ui-apply-fonts (&optional frame)
  "Imposta i caratteri di FRAME (di tutte le finestre se nil)."
  (when (display-graphic-p frame)
    (set-face-attribute 'default frame :height gdev-font-height)
    (when-let* ((family (gdev-ui--first-font gdev-font-families frame)))
      (set-face-attribute 'default frame :family family)
      (set-face-attribute 'fixed-pitch frame :family family))
    (when-let* ((family (gdev-ui--first-font gdev-variable-pitch-families frame)))
      (set-face-attribute 'variable-pitch frame :family family))
    ;; Il carattere degli emoji è indicato per nome: cercarlo fra tutti i
    ;; caratteri è lento e si ripeterebbe a ogni ridisegno.
    (when gdev-macos-p
      (set-fontset-font t 'emoji (font-spec :family "Apple Color Emoji") nil 'prepend))))

(defun gdev-ui-init-fonts ()
  "Applica i caratteri ora, o alla prima finestra grafica del demone (daemon)."
  (setq-default line-spacing gdev-line-spacing)
  (if (daemonp)
      (add-hook 'server-after-make-frame-hook #'gdev-ui-apply-fonts)
    (gdev-ui-apply-fonts)))

;; Presentazioni e programmazione in coppia: tutto più grande, ovunque.
(define-minor-mode gdev-big-font-mode
  "Mostra ogni finestra con un carattere più grande."
  :global t
  (set-face-attribute 'default nil :height (if gdev-big-font-mode
                                               (round (* gdev-font-height 1.4))
                                             gdev-font-height)))

;;;; Buffer di codice

(defun gdev-ui-code-buffer-setup ()
  "Aiuti visivi nelle aree di testo di codice e di configurazione."
  (setq-local display-line-numbers-width 3)
  (display-line-numbers-mode 1)
  (hl-line-mode 1)
  (display-fill-column-indicator-mode 1))

(defun gdev-ui-toggle-relative-line-numbers ()
  "Alterna numeri di riga assoluti e relativi."
  (interactive)
  (setq-local display-line-numbers
              (if (eq display-line-numbers 'relative) t 'relative)))

(defun gdev-ui-install ()
  "Applica l'aspetto di GDev a tema, caratteri, finestre e aree di testo."
  (gdev-ui--configure-modus)
  (add-hook 'gdev-after-init-hook #'gdev-ui-init-theme)
  (add-hook 'gdev-after-init-hook #'gdev-ui-init-fonts)
  (add-hook 'after-change-major-mode-hook #'gdev-ui-setup-scratch)
  (when-let* ((scratch (get-buffer "*scratch*")))
    (with-current-buffer scratch (gdev-ui-setup-scratch)))
  (add-hook 'tabulated-list-mode-hook #'gdev-ui--tabular-header)
  (dolist (hook '(minibuffer-setup-hook which-key-init-buffer-hook transient-setup-buffer-hook))
    (add-hook hook #'gdev-ui-scale-controls))
  (dolist (hook '(prog-mode-hook conf-mode-hook yaml-ts-mode-hook toml-ts-mode-hook))
    (add-hook hook #'gdev-ui-code-buffer-setup))
  ;; La barra di Emacs resta disponibile anche senza :ui modeline.
  (setq mode-line-compact 'long
        project-mode-line t)
  (when (boundp 'mode-line-collapse-minor-modes)
    (setq mode-line-collapse-minor-modes t))
  (add-hook 'emacs-startup-hook #'column-number-mode)
  ;; Il separatore resta sottile nelle due disposizioni.
  (setq window-combination-resize t
        split-width-threshold 160
        split-height-threshold nil
        window-divider-default-places t
        window-divider-default-right-width 1
        window-divider-default-bottom-width 1)
  (add-hook 'emacs-startup-hook #'window-divider-mode))

(provide 'gdev-ui)
;;; gdev-ui.el ends here
