;;; gdev-layout.el --- Disposizione dell'area di modifica, dell'albero e del pannello -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Ogni spazio di lavoro (scheda di tab-bar) ha gruppi di modifica centrali,
;; un albero a sinistra e un pannello degli strumenti in basso.  Le
;; finestre sono lo stato visibile, tab-bar ne salva la disposizione.
;; Nella scheda conserviamo anche gli strumenti già aperti e le
;; preferenze che valgono a pannelli chiusi.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tab-bar)
(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function gdev-dashboard-buffer "../../ui/dashboard/config" ())
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-term-new "../../term/eat/config" ())
(declare-function gdev-term-new-profile "../../term/eat/config" ())
(declare-function gdev-term-split "../../term/eat/config" ())
(declare-function gdev-term-split-available-p "../../term/eat/config" (&optional window))
(declare-function tab-line-select-tab-buffer "tab-line" (buffer &optional window))

(defgroup gdev-layout nil
  "Disposizione dei riquadri di GDev."
  :group 'gdev)

(defcustom gdev-layout-panel-height 0.32
  "Altezza iniziale del pannello degli strumenti, come frazione della finestra."
  :type 'float
  :group 'gdev-layout)

(defcustom gdev-sidebar-width 32
  "Larghezza iniziale della barra laterale, in colonne."
  :type 'integer
  :group 'gdev-layout)

(defcustom gdev-command-sidebar-width 36
  "Larghezza iniziale del riquadro Comandi, in colonne."
  :type 'natnum
  :group 'gdev-layout)

(defcustom gdev-layout-focus-columns 104
  "Larghezza in colonne dell'editor nella modalità concentrazione."
  :type 'natnum
  :group 'gdev-layout)

(defvar gdev-layout-mode)
(defvar tab-line-format)
(defvar tab-line-tabs-function)
(defvar tab-line-close-tab-function)
(defvar tab-line-tab-name-function)
(defvar tab-line-tab-name-format-function)
(defvar tab-line-cache-key-function)
(defvar tab-line-tab-close-map)
(defvar tab-line-close-button)
(defvar tab-line-left-button)
(defvar tab-line-right-button)
(declare-function tab-line-tab-name-format-default "tab-line" (tab tabs))
(declare-function tab-line-cache-key-default "tab-line" (tabs))
(defvar ediff-this-buffer-ediff-sessions)
(declare-function gdev-comparison-control-at-window "gdev-commands" (&optional window))
(declare-function gdev-comparison-close "gdev-commands" (&optional control))
(defvar which-key-buffer-name)
(defvar-local gdev-activity-kind nil)
(declare-function gdev-activity-decorate "gdev-activity")
(declare-function gdev-activity-restore "gdev-activity")
(declare-function gdev-activity-display "gdev-activity")
(declare-function gdev-activity-save-position "gdev-activity")
(declare-function gdev-activity-restore-position "gdev-activity")
(declare-function gdev-command-sidebar-sync "gdev-command-sidebar" (&optional frame))
(declare-function gdev-minimap-requested-p "gdev-minimap" (&optional frame))
(declare-function gdev-workspace-roots "gdev-workspace-roots" (&optional frame))
(defvar gdev-new-document-hook nil
  "Funzioni da eseguire quando un'area di testo viene aperto come nuovo documento.")
(defvar-local gdev-layout-document-p nil
  "Non nil per un'area di testo che si apre esplicitamente come documento.")
(defvar-local gdev-layout-auxiliary-p nil
  "Non nil per una vista ausiliaria che si apre accanto all'editor.")
(defvar-local gdev-layout--panel-tabs-p nil)
(defvar-local gdev-layout--tool-p nil)

(defun gdev-layout-mark-document ()
  "Tratta l'area di testo corrente come documento e attiva la sua scheda."
  (setq gdev-layout-document-p t)
  (run-hooks 'gdev-new-document-hook))

(defun gdev-layout-mark-auxiliary ()
  "Destina la vista corrente alla parte inferiore della colonna di destra."
  (setq gdev-layout-auxiliary-p t))

(defun gdev-layout-document-tab-p (buffer)
  "Restituisce non nil se BUFFER può comparire fra le schede dei documenti."
  (or (buffer-file-name buffer)
      (buffer-local-value 'gdev-layout-document-p buffer)))

(defun gdev-layout--editors (&optional frame)
  "Elenca i gruppi editor di FRAME."
  (seq-remove (lambda (window) (window-parameter window 'window-side))
              (window-list frame 'no-minibuffer)))

(defun gdev-layout-split-p ()
  "Restituisce non nil se l'editor ha più di un gruppo."
  (not (window-live-p (window-main-window))))

(defun gdev-layout-editor (&optional frame)
  "Restituisce il gruppo editor attivo, o l'ultimo usato in FRAME."
  (let* ((frame (or frame (selected-frame)))
         (active (frame-selected-window frame))
         (editors (gdev-layout--editors frame)))
    (or (car (memq active editors))
        (seq-reduce (lambda (best window)
                      (if (or (not best) (> (window-use-time window) (window-use-time best)))
                          window
                        best))
                    editors nil))))

(defun gdev-layout-tab-name ()
  "Restituisce il nome automatico dello spazio: il buffer del gruppo editor attivo.
Il fuoco su Esplora file, Comandi o un pannello non rinomina lo spazio."
  (let ((selected (selected-window)))
    (if-let* ((editor (if (or (window-minibuffer-p selected)
                              (window-parameter selected 'window-side))
                          (gdev-layout-editor)
                        selected)))
        ;; «Appunti» e non «*scratch*»: il nome dello spazio è visibile nella barra delle schede.
        (gdev-ui-buffer-name (window-buffer editor))
      (tab-bar-tab-name-current))))

(defconst gdev-layout-editor-limit 4
  "Numero massimo di gruppi di modifica nello spazio di lavoro.")

(defun gdev-layout-other-editor (source)
  "Restituisce il successivo gruppo di modifica dopo SOURCE."
  (seq-find (lambda (window) (not (window-parameter window 'window-side)))
            (cdr (window-list (window-frame source) 'nomini source))))

(defun gdev-layout-editor-direction (source)
  "Restituisce la direzione della divisione immediata di SOURCE."
  (unless (eq source (window-main-window (window-frame source)))
    (if (window-combined-p source t) 'right 'below)))

(defun gdev-layout--editor-child (window)
  "Restituisce il primo figlio di WINDOW, se è una combinazione."
  (or (window-left-child window) (window-top-child window)))

(defun gdev-layout--editor-axis-used-p (window horizontal)
  "Indica se WINDOW occupa già metà dell'asse HORIZONTAL nell'editor."
  (let ((main (window-main-window (window-frame window)))
        used)
    (while (and (not used) (not (eq window main)) (window-parent window))
      (setq used (window-combined-p window horizontal)
            window (window-parent window)))
    used))

(defun gdev-layout--check-editor-split (window side)
  "Verifica che dividere WINDOW sul lato SIDE rispetti il layout."
  (when (>= (length (gdev-layout--editors (window-frame window))) gdev-layout-editor-limit)
    (user-error "Sono già aperti quattro gruppi di modifica"))
  (when (gdev-layout--editor-axis-used-p window (not (memq side '(nil below above up down))))
    (user-error "%s" (if (memq side '(nil below above up down))
                         "Questo gruppo occupa già una delle due righe"
                       "Questo gruppo occupa già una delle due colonne"))))

(defun gdev-layout-editor-can-split-p (window side)
  "Indica se la disposizione di WINDOW permette una divisione sul lato SIDE."
  (condition-case nil
      (progn (gdev-layout--check-editor-split window side) t)
    (user-error nil)))

(defun gdev-layout--limit-editor-split (split &optional window size side &rest args)
  "Verifica SPLIT nei gruppi di modifica prima di chiamare Emacs."
  (let* ((target (or window (selected-window)))
         (frame (window-frame target)))
    (when (and (not ignore-window-parameters)
               (not (frame-parent frame))
               (not (window-minibuffer-p target))
               (not (window-parameter target 'window-side)))
      (gdev-layout--check-editor-split target side))
    (apply split window size side args)))

(defun gdev-layout--split-editor-window (source side &optional pixels)
  "Crea un gruppo sul lato SIDE di SOURCE, con misura di SOURCE in PIXELS."
  (let ((window-combination-resize nil))
    (condition-case problem
        (split-window source pixels side (and pixels t))
      (user-error (signal (car problem) (cdr problem)))
      (error (user-error "%s" (if (memq side '(left right))
                                  "Allarga la finestra per affiancare i gruppi"
                                "Aumenta l'altezza della finestra per aprire un'altra riga"))))))

(defun gdev-layout--change-editors (source change)
  "Applica CHANGE al gruppo SOURCE, conservando fuoco e stato in caso di errore."
  (let* ((source (or source (gdev-layout-editor)))
         (frame (selected-frame))
         (focus (frame-parameter frame 'gdev-layout-focus))
         (tab-bar-lines (frame-parameter frame 'tab-bar-lines))
         (previous (current-window-configuration frame))
         completed)
    (unless (memq source (gdev-layout--editors frame))
      (user-error "Apri un gruppo di modifica nella finestra attiva"))
    (unwind-protect
        (progn
          (gdev-layout-exit-focus)
          (when focus (setq source (gdev-layout-editor frame)))
          (prog1 (funcall change source)
            (select-window source)
            (gdev-workspace-state-set 'gdev-layout-editor-state nil)
            (setq completed t)))
      (unless completed
        (set-window-configuration previous)
        (when focus
          (set-frame-parameter frame 'gdev-layout-focus focus)
          (set-frame-parameter frame 'tab-bar-lines tab-bar-lines))))))

(defun gdev-layout-split-editor (direction &optional source)
  "Divide il gruppo SOURCE lungo DIRECTION e restituisce il nuovo gruppo."
  (gdev-layout--change-editors source
    (lambda (window) (gdev-layout--split-editor-window window direction))))

(defun gdev-layout-rotate-editor-pair (&optional source)
  "Ruota una coppia di gruppi senza cambiare file, ordine o fuoco."
  (gdev-layout--change-editors
   source
   (lambda (window)
     (unless (= (length (gdev-layout--editors)) 2)
       (user-error "La rotazione richiede esattamente due gruppi"))
     (let* ((peer (gdev-layout-other-editor window))
            (first (eq window (gdev-layout--editor-child (window-parent window))))
            (side (if (eq (gdev-layout-editor-direction window) 'right)
                      (if first 'below 'above)
                    (if first 'right 'left)))
            (state (window-state-get peer))
            (tabs (window-parameter peer 'tab-line-buffers))
            (preview (window-parameter peer 'gdev-editor-preview)))
       (delete-window peer)
       (let ((new (gdev-layout--split-editor-window window side)))
         (gdev-window-state-put state new 'safe)
         (set-window-parameter new 'tab-line-buffers tabs)
         (set-window-parameter new 'gdev-editor-preview preview)
         new)))))

(defun gdev-layout-editor-grid-p ()
  "Restituisce non nil se i gruppi formano una griglia 2×2."
  (let* ((root (window-main-window))
         (horizontal (window-left-child root))
         (first (gdev-layout--editor-child root))
         (second (and first (window-next-sibling first))))
    (and second (not (window-next-sibling second))
         (= (length (gdev-layout--editors)) gdev-layout-editor-limit)
         (window-combination-p first (not horizontal))
         (window-combination-p second (not horizontal)))))

(defun gdev-layout-split-editor-grid (&optional source)
  "Completa una griglia 2×2 a partire da SOURCE."
  (gdev-layout--change-editors
   source
   (lambda (window)
     (unless (gdev-layout--editor-child (window-main-window))
       (gdev-layout--split-editor-window window 'right))
     (let* ((root (window-main-window))
            (direction (if (window-left-child root) 'below 'right))
            (first (gdev-layout--editor-child root))
            (second (window-next-sibling first)))
       (unless (and second (not (window-next-sibling second)))
         (user-error "La disposizione corrente non si può completare come griglia"))
       (let* ((subdivision (or (gdev-layout--editor-child first)
                               (gdev-layout--editor-child second)))
              (size (and subdivision (if (eq direction 'below)
                                         (window-pixel-height subdivision)
                                       (window-pixel-width subdivision)))))
         (dolist (group (list first second))
           (when (window-live-p group)
             (gdev-layout--split-editor-window group direction size))))))))

(defun gdev-layout-limit-restored-editors ()
  "Riduce le vecchie disposizioni a quattro gruppi senza chiudere documenti."
  (let* ((editor (gdev-layout-editor))
         (others (remq editor (gdev-layout--editors)))
         (peer (car others)))
    (dolist (extra (nthcdr (1- gdev-layout-editor-limit) others))
      (let ((buffer (window-buffer extra)))
        (when (and (gdev-layout-document-tab-p buffer)
                   (not (eq buffer (window-buffer peer)))
                   (not (assq buffer (window-prev-buffers peer))))
          (set-window-prev-buffers
           peer (cons (list buffer (window-start extra) (window-point extra))
                      (window-prev-buffers peer)))))
      (delete-window extra))))

(defun gdev-layout--panel ()
  (window-with-parameter 'gdev-layout-panel t))

(defun gdev-layout-panel-companion ()
  "Restituisci il riquadro affiancato, se è visibile."
  (window-with-parameter 'gdev-layout-panel 'companion))

(defun gdev-layout-panel-split-fits-p ()
  "Indica se il pannello inferiore può ospitare due terminali leggibili."
  (when-let* ((panel (gdev-layout--panel)))
    (>= (+ (window-total-width panel)
           (if-let* ((companion (gdev-layout-panel-companion)))
               (window-total-width companion)
             0))
        68)))

(defun gdev-layout--key-hint-p (buffer)
  "Restituisce non nil per la guida temporanea alle scorciatoie."
  (and (boundp 'which-key-buffer-name) (equal (buffer-name buffer) which-key-buffer-name)))

(defun gdev-layout--temporary-p (buffer)
  "Identifica le viste che il pannello non deve ricordare tra gli strumenti."
  (let ((name (buffer-name buffer)))
    (or (gdev-layout--key-hint-p buffer)
        (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'ediff-mode)
        (string-prefix-p " *transient" name)
        (member name '("*Completions*" "*Process List*")))))

(defun gdev-layout--rule (buffer action)
  (seq-find (lambda (rule) (buffer-match-p (car rule) buffer action)) gdev-popup-rules))

(defun gdev-layout--role (buffer &optional rule)
  "Restituisce la destinazione di BUFFER, tenendo conto di RULE."
  (with-current-buffer buffer
    (cond ((derived-mode-p 'gdev-sidebar-mode) 'explorer)
          (gdev-activity-kind 'activity)
          ((derived-mode-p 'gdev-command-sidebar-mode) 'commands)
          ((derived-mode-p 'gdev-minimap-mode) 'minimap)
          ((or gdev-layout-document-p
               (seq-some #'buffer-live-p (bound-and-true-p ediff-this-buffer-ediff-sessions)))
           'editor)
          (gdev-layout-auxiliary-p 'auxiliary)
          ((or rule gdev-layout--tool-p (gdev-layout--rule buffer nil)) 'panel)
          ((or buffer-file-name
               (gdev-ui-scratch-buffer-p)
               (derived-mode-p 'dired-mode 'gdev-dashboard-mode 'gdev-layout-empty-mode
                               'Custom-mode 'eww-mode
                               'org-src-mode 'org-capture-mode))
           'editor)
          ((or (string-match-p "\\`[ *]" (buffer-name))
               (derived-mode-p 'special-mode 'comint-mode 'compilation-mode 'eshell-mode
                               'eat-mode 'dape-info-parent-mode))
           'panel)
          (t 'editor))))

(defun gdev-layout--panel-buffers ()
  "Restituisce gli strumenti aperti nello spazio di lavoro corrente."
  (seq-filter (lambda (buffer)
                (and (buffer-live-p buffer)
                     (memq (gdev-layout--role buffer) '(panel auxiliary))))
              (gdev-workspace-state-get 'gdev-layout-panel-buffers)))

(defun gdev-layout--remember-panel (buffer &optional shown)
  "Registra BUFFER senza riordinare le schede.  SHOWN indica quella attiva."
  (unless (gdev-layout--temporary-p buffer)
    (let* ((buffers (gdev-layout--panel-buffers))
           (changes (unless (memq buffer buffers)
                      (list (cons 'gdev-layout-panel-buffers (append buffers (list buffer)))))))
      (when shown
        (push (cons 'gdev-layout-panel-active buffer) changes))
      (gdev-workspace-state-update changes))))

(defun gdev-layout--panel-label (buffer)
  "Restituisce il nome dello strumento BUFFER, con il suo contesto."
  (with-current-buffer buffer
    (let* ((name (string-trim (buffer-name) "[ *]+" "[ *]+"))
           (label (cond ((derived-mode-p 'eat-mode 'eshell-mode 'shell-mode 'term-mode)
                         (setq name (replace-regexp-in-string
                                     "\\`\\(?:eat\\|eshell\\|shell\\|terminal\\)\\(?:[: ]+\\|\\'\\)"
                                     "" name))
                         "Terminale")
                        ((derived-mode-p 'flymake-project-diagnostics-mode
                                         'flymake-diagnostics-buffer-mode)
                         (setq name (string-remove-suffix "'"
                                                        (string-remove-prefix "Flymake diagnostics for `" name)))
                         "Problemi")
                        ((derived-mode-p 'grep-mode)
                         (setq name (string-remove-prefix "grep" name))
                         "Ricerca")
                        ((derived-mode-p 'compilation-mode)
                         (setq name (string-remove-prefix "gdev-build: " name))
                         (when (equal name "compilation") (setq name ""))
                         "Compilazione")
                        ((derived-mode-p 'dape-info-parent-mode 'dape-repl-mode)
                         (gdev-ui-mode-label))
                        ((derived-mode-p 'help-mode 'helpful-mode 'Info-mode)
                         (when (member name '("Help" "info")) (setq name ""))
                         "Aiuto"))))
      (cond ((or (not label)
                 (string-match-p "\\`\\(?:Hit\\|Terminale\\|Interprete Lisp\\|Compilazione\\|Esecuzione\\|Debug\\|Test\\) · " name))
             name)
            ((string-empty-p name) label)
            (t (concat label " · " name))))))

(defun gdev-layout--display-editor (buffer prohibited placement)
  "Mostra BUFFER in un gruppo editor secondo PROHIBITED e PLACEMENT.
PROHIBITED è la finestra da escludere. PLACEMENT indica l'azione esplicita."
  (let* ((editors (gdev-layout--editors))
         (active (gdev-layout-editor))
         (other-command (memq this-command '(find-file-other-window dired-other-window
                                             switch-to-buffer-other-window consult-buffer-other-window)))
         (separate (or other-command (eq placement 'display-buffer-pop-up-window)
                       (and prohibited (eq active prohibited))))
         (window
          (if (and separate (window-live-p active))
              (or (seq-find (lambda (window)
                              (and (not (eq window active)) (eq (window-buffer window) buffer)))
                            editors)
                  (gdev-layout-other-editor active)
                  (with-selected-window active
                    (if other-command (split-window-right)
                      (ignore-errors (split-window-right)))))
            active)))
    (when (window-live-p window)
      (with-selected-window window
        (or (and (eq (window-buffer) buffer) window)
            (display-buffer-same-window buffer nil))))))

(defun gdev-layout-explorer-preferred-width (window)
  "Restituisce la larghezza dell'albero WINDOW prima dell'adattamento."
  (or (nth 2 (window-parameter window 'gdev-layout-explorer-sizing))
      (window-total-width window)))

(defun gdev-layout--explorer-width (columns preferred)
  "Adatta PREFERRED a COLUMNS, riservando spazio all'editor."
  (min preferred (max 1 (/ columns 2)) (max 20 (- columns 48))))

(declare-function gdev-sidebar--resize "../sidebar/config")

(defun gdev-layout-left-window (&optional frame)
  "Restituisce la vista a sinistra di FRAME."
  (or (window-with-parameter 'gdev-sidebar t frame)
      (window-with-parameter 'gdev-activity t frame)))

(defun gdev-layout-command-sidebar-window (&optional frame)
  "Restituisci il riquadro Comandi di FRAME."
  (window-with-parameter 'gdev-layout-commands t frame))

(defun gdev-layout-auxiliary-window (&optional frame)
  "Restituisci la vista ausiliaria a destra di FRAME."
  (window-with-parameter 'gdev-layout-auxiliary t frame))

(defun gdev-layout--commands-context-p (window frame)
  "Accetta i documenti e gli strumenti stabili di FRAME come contesto."
  (and (window-live-p window) (eq (window-frame window) frame)
       (not (window-minibuffer-p window))
       (not (or (window-parameter window 'gdev-layout-commands)
                (window-parameter window 'gdev-minimap)
                (gdev-layout--temporary-p (window-buffer window))))))

(defun gdev-layout--commands-wanted-p (frame source)
  "Restituisci non nil se Comandi è richiesto in FRAME per SOURCE."
  (let ((visibility (gdev-workspace-state-get 'gdev-layout-commands-visibility frame)))
    (and gdev-layout-mode source (not (eq visibility 'hidden))
         (not (frame-parameter frame 'gdev-layout-focus))
         (not (gdev-minimap-requested-p frame))
         (or (eq visibility 'shown) (gdev-workspace-roots frame)
             (with-current-buffer (window-buffer source)
               (not (or (gdev-ui-scratch-buffer-p)
                        (derived-mode-p 'gdev-dashboard-mode 'gdev-layout-empty-mode))))))))

(defun gdev-layout--sync-commands (frame)
  "Allinea Comandi e caricalo quando FRAME può mostrarlo."
  (when (and (not noninteractive) (fboundp 'gdev-command-sidebar-sync)
             (or (featurep 'gdev-command-sidebar)
                 (let* ((selected (frame-selected-window frame))
                        (source (if (gdev-layout--commands-context-p selected frame)
                                    selected (gdev-layout-editor frame))))
                   (and (gdev-layout--commands-wanted-p frame source)
                        (gdev-layout-commands-fit-p)))))
    (gdev-command-sidebar-sync frame)))

(defconst gdev-layout--commands-min-width 22
  "Larghezza minima del riquadro Comandi in colonne.")

(defun gdev-layout--commands-space (frame)
  "Calcola le colonne di FRAME e quelle già assegnate a sinistra."
  (let ((left (gdev-layout-left-window frame)))
    (cons (window-total-width (frame-root-window frame))
          (if left (window-total-width left) 0))))

(defun gdev-layout--commands-width (space preferred frame)
  "Adatta PREFERRED allo SPACE di FRAME lasciando posto all'editor."
  (let* ((two-columns (seq-some (lambda (window) (gdev-layout--editor-axis-used-p window t))
                               (gdev-layout--editors frame)))
         (editor-min (max (if two-columns 72 48)
                          (window-min-size (window-main-window frame) t 'safe)))
         (available (- (car space) (cdr space) editor-min)))
    (when (>= available gdev-layout--commands-min-width)
      (min available (max gdev-layout--commands-min-width preferred)))))

(defun gdev-layout-commands-fit-p ()
  "Indica se la disposizione normale può ospitare Comandi."
  (let ((space (gdev-layout--commands-space (selected-frame))))
    (when-let* ((focus (frame-parameter nil 'gdev-layout-focus))
                (left-width (plist-get focus :explorer-width)))
      (setcdr space (gdev-layout--explorer-width (car space) left-width)))
    (gdev-layout--commands-width space gdev-command-sidebar-width (selected-frame))))

(defun gdev-layout--fit-explorer (frame)
  "Adatta l'albero visibile di FRAME alla larghezza disponibile."
  (when-let* ((window (gdev-layout-left-window frame)))
    (let* ((columns (window-total-width (frame-root-window frame)))
           (width (window-total-width window))
           (previous (window-parameter window 'gdev-layout-explorer-sizing))
           (same-frame-width (eql columns (car previous))))
      ;; Nella stessa finestra il trascinamento del bordo imposta una preferenza.
      (unless (and same-frame-width (eql width (cadr previous)))
        (let ((preferred (if same-frame-width width
                           (gdev-layout-explorer-preferred-width window))))
          (unless same-frame-width
            (let ((delta (- (gdev-layout--explorer-width columns preferred) width)))
              (when (and (not (zerop delta))
                         (window-resizable-p window delta t window))
                (window-resize window delta t window)
                (window-preserve-size window t t)
                ;; Il hook locale del buffer precede il ridimensionamento del frame.
                (when (and (window-parameter window 'gdev-sidebar)
                           (fboundp 'gdev-sidebar--resize))
                  (with-current-buffer (window-buffer window)
                    (gdev-sidebar--resize window))))))
          (set-window-parameter window 'gdev-layout-explorer-sizing
                                (list columns (window-total-width window) preferred)))))))

(defun gdev-layout--remove-side (window)
  "Rimuovi WINDOW senza cambiare la preferenza di visibilità."
  (with-selected-frame (window-frame window)
    (when (eq (frame-selected-window) window)
      (select-window (gdev-layout-editor)))
    (let ((ignore-window-parameters t))
      (delete-window window))))

(defun gdev-layout--forget-auxiliary (buffer)
  "Annulla il ripristino automatico di BUFFER nello spazio attivo."
  (when (eq buffer (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer))
    (gdev-workspace-state-update
     '((gdev-layout-auxiliary-buffer . nil)
       (gdev-layout-auxiliary-panel-origin . nil)))))

(defun gdev-layout--hide-panel ()
  "Nascondi il pannello intero conservando sessioni, scelta e altezza."
  (when-let* ((panel (gdev-layout--panel)))
    (unless (gdev-layout--temporary-p (window-buffer panel))
      (gdev-layout--forget-auxiliary (window-buffer panel))
      (gdev-workspace-state-update
       `((gdev-layout-panel-height . ,(window-total-height panel))
         (gdev-layout-panel-hidden . t)))))
  (gdev-layout--remove-panel-companion)
  (when-let* ((panel (gdev-layout--panel)))
    (gdev-layout--remove-side panel)))

(defun gdev-layout--delete-side (window)
  "Chiude WINDOW ricordando dimensione e stato nello spazio di lavoro."
  (with-selected-frame (window-frame window)
    (cond ((window-parameter window 'gdev-layout-panel)
           ;; Emacs può eliminare un riquadro quando termina il suo buffer.
           ;; Finché sono visibili entrambi, la sessione superstite resta aperta.
           (when (or (eq this-command 'delete-window) (not (gdev-layout-panel-companion)))
             (gdev-layout--hide-panel)))
          ((or (window-parameter window 'gdev-sidebar)
               (window-parameter window 'gdev-activity))
           (when (fboundp 'gdev-activity-save-position)
             (gdev-activity-save-position window))
           (gdev-workspace-state-update
            `((gdev-layout-explorer-width . ,(gdev-layout-explorer-preferred-width window))
              (gdev-layout-explorer-hidden . t))))
          ((window-parameter window 'gdev-layout-commands)
           (gdev-workspace-state-set 'gdev-layout-commands-visibility 'hidden))
          ((window-parameter window 'gdev-layout-auxiliary)
           (gdev-layout--forget-auxiliary (window-buffer window)))
          ((window-parameter window 'gdev-minimap)
           (gdev-workspace-state-set 'gdev-layout-minimap-visible nil)))
    (when (window-live-p window)
      (gdev-layout--remove-side window))))

(defun gdev-layout--reject-side-split (&rest _)
  "Impedisci di creare gruppi dentro l'albero o il pannello."
  (user-error "Da Finestra puoi dividere un gruppo dell'editor"))

(defconst gdev-layout--fixed-side-parameters
  '((delete-window . gdev-layout--delete-side)
    (split-window . gdev-layout--reject-side-split)
    (no-other-window . t)
    (no-delete-other-windows . t))
  "Regole condivise dai riquadri fissi del Workbench.")

(defconst gdev-layout--auxiliary-min-height 8
  "Righe minime per ciascuna metà della colonna di destra.")

(defun gdev-layout--right-height (rows fraction)
  "Ripartisci ROWS secondo FRACTION garantendo il minimo alle due viste."
  (max gdev-layout--auxiliary-min-height
       (min (- rows gdev-layout--auxiliary-min-height) (round (* rows fraction)))))

(defun gdev-layout--right-slot (buffer slot sibling options)
  "Mostra BUFFER nello SLOT destro, conservando la finestra SIBLING.
OPTIONS contiene dimensioni e parametri della destinazione."
  (if (not sibling)
      (let ((ignore-window-parameters t))
        (display-buffer-in-side-window buffer (append `((side . right) (slot . ,slot)) options)))
    (let ((configuration (current-window-configuration))
          (sibling-buffer (window-buffer sibling))
          window placed)
      (unwind-protect
          (condition-case nil
              (let ((ignore-window-parameters t))
                (setq window (display-buffer-in-side-window
                              buffer (append `((side . right) (slot . ,slot)) options)))
                (when (and (window-live-p window)
                           (eql (window-parameter window 'window-slot) slot)
                           (not (eq window sibling))
                           (window-live-p sibling)
                           (eq (window-buffer sibling) sibling-buffer))
                  (setq placed window)))
            (error nil))
        (unless placed (set-window-configuration configuration))))))

(defun gdev-layout-show-commands (buffer)
  "Mostra BUFFER a destra quando la disposizione lo consente."
  (let ((frame (selected-frame))
        (auxiliary (gdev-layout-auxiliary-window)))
    (unless (or (frame-parameter frame 'gdev-layout-focus)
                (window-with-parameter 'gdev-minimap t frame)
                (and auxiliary
                     (< (window-total-height (frame-root-window frame))
                        (* 2 gdev-layout--auxiliary-min-height))))
      (when-let* ((space (gdev-layout--commands-space frame))
                  (preferred (or (gdev-workspace-state-get 'gdev-layout-commands-width)
                                 gdev-command-sidebar-width))
                  (width (gdev-layout--commands-width space preferred frame))
                  (window
                   (gdev-layout--right-slot
                    buffer 0 auxiliary
                    `((dedicated . t) (window-width . ,width) (preserve-size . (t . nil))
                      ,@(when auxiliary
                          `((window-height . ,(gdev-layout--right-height
                                               (window-total-height auxiliary) 0.55))))
                      (window-parameters . ((gdev-layout-commands . t)
                                            . ,gdev-layout--fixed-side-parameters))))))
        (set-window-parameter window 'gdev-layout-commands-sizing
                              (cons space (window-total-width window)))
        window))))

(defun gdev-layout-fit-commands (window)
  "Adatta WINDOW, ricordando i trascinamenti a larghezza del frame invariata."
  (let* ((frame (window-frame window))
         (space (gdev-layout--commands-space frame))
         (current (window-total-width window))
         (previous (window-parameter window 'gdev-layout-commands-sizing))
         (preferred (or (gdev-workspace-state-get 'gdev-layout-commands-width frame)
                        gdev-command-sidebar-width)))
    (when (and (equal space (car previous)) (/= current (cdr previous)))
      (setq preferred (max gdev-layout--commands-min-width current))
      (gdev-workspace-state-set 'gdev-layout-commands-width preferred
                                (gdev-workspace-state-current frame)))
    (if-let* ((width (gdev-layout--commands-width space preferred frame)))
        (let ((delta (- width current)))
          (when (and (/= delta 0) (window-resizable-p window delta t window))
            (window-resize window delta t window)
            (window-preserve-size window t t))
          (set-window-parameter window 'gdev-layout-commands-sizing
                                (cons space (window-total-width window)))
          window)
      (gdev-layout--remove-side window)
      nil)))

(defun gdev-layout--show-auxiliary (buffer)
  "Mostra BUFFER sotto Comandi se c'è spazio nella colonna destra."
  (unless (or (window-with-parameter 'gdev-minimap t) (gdev-minimap-requested-p))
    (let* ((frame (selected-frame))
           (space (gdev-layout--commands-space frame))
           (top (gdev-layout-command-sidebar-window frame))
           (previous (gdev-layout-auxiliary-window frame))
           (height (window-total-height (frame-root-window frame)))
           (width (gdev-layout--commands-width
                   space (or (gdev-workspace-state-get 'gdev-layout-commands-width)
                             gdev-command-sidebar-width) frame)))
      (when (and width
                 (>= height (* (if top 2 1) gdev-layout--auxiliary-min-height)))
        (when-let* ((window
                     (gdev-layout--right-slot
                      buffer 1 top
                      `((dedicated . t)
                        ,@(unless (or top previous) `((window-width . ,width)))
                        ,@(when (and top (not previous))
                            `((window-height . ,(gdev-layout--right-height
                                                 (window-total-height top) 0.45))))
                        (preserve-size . (t . nil))
                        (window-parameters . ((gdev-layout-auxiliary . t)
                                              (tab-line-format . none)
                                              . ,gdev-layout--fixed-side-parameters))))))
          (set-window-parameter window 'gdev-layout-commands-sizing
                                (cons space (window-total-width window)))
          window)))))

(defun gdev-layout--tool-location (window)
  "Ricorda il buffer, l'inizio visibile e il cursore di WINDOW."
  (with-current-buffer (window-buffer window)
    (list (current-buffer) (copy-marker (window-start window))
          (copy-marker (window-point window)))))

(defun gdev-layout--restore-tool-location (window location)
  "Ripristina LOCATION in WINDOW, se mostra ancora il suo buffer."
  (when (and (consp location) (eq (window-buffer window) (car location)))
    (set-window-start window (nth 1 location) t)
    (set-window-point window (nth 2 location))))

(defun gdev-layout--detach-auxiliary-from-panel (buffer)
  "Rimuovi BUFFER dal pannello e ripristina lo strumento che copriva."
  (let* ((buffers (gdev-layout--panel-buffers))
         (remaining (remq buffer buffers))
         (panel (gdev-layout--panel))
         (active (gdev-workspace-state-get 'gdev-layout-panel-active))
         (origin (when (eq buffer (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer))
                   (gdev-workspace-state-get 'gdev-layout-auxiliary-panel-origin)))
         (closed (memq (car origin) '(absent hidden)))
         (previous (if closed (cadr origin) (car origin)))
         (next (or (car (memq previous remaining))
                   (car (memq active remaining)) (car (last remaining)))))
    (when (memq buffer buffers)
      (gdev-workspace-state-set 'gdev-layout-panel-buffers remaining)
      (when (eq active buffer)
        (gdev-workspace-state-set 'gdev-layout-panel-active next))
      (when (and panel (eq (window-buffer panel) buffer))
        (cond (closed
               (gdev-layout--remove-side panel)
               (gdev-workspace-state-set 'gdev-layout-panel-hidden (eq (car origin) 'hidden)))
              (t (if-let* ((restored (and next (gdev-layout--display-panel next))))
                     (gdev-layout--restore-tool-location restored origin)
                   (gdev-layout--remove-side panel))))))
    (when (eq buffer (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer))
      (gdev-workspace-state-set 'gdev-layout-auxiliary-panel-origin nil))))

(defun gdev-layout--dock-auxiliary (buffer)
  "Sposta BUFFER a destra conservando posizione e fuoco."
  (let* ((previous (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer))
         (panel (gdev-layout--panel))
         (location (when (and panel (eq buffer (window-buffer panel)))
                     (gdev-layout--tool-location panel)))
         (focused (and location (eq panel (selected-window)))))
    (when-let* ((window (gdev-layout--show-auxiliary buffer)))
      (when (and previous (not (eq buffer previous)))
        (gdev-layout--detach-auxiliary-from-panel previous))
      (gdev-layout--detach-auxiliary-from-panel buffer)
      (gdev-workspace-state-set 'gdev-layout-auxiliary-buffer buffer)
      (when location (gdev-layout--restore-tool-location window location))
      (when focused (select-window window))
      window)))

(defun gdev-layout--compact-auxiliary (buffer)
  "Mostra BUFFER nel pannello, ricordando lo strumento che occupava lo spazio."
  (let* ((previous (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer))
         (panel (gdev-layout--panel))
         (origin (cond ((not panel)
                        (list (if (gdev-workspace-state-get 'gdev-layout-panel-hidden) 'hidden 'absent)
                              (gdev-workspace-state-get 'gdev-layout-panel-active)))
                       ((eq (gdev-layout--role (window-buffer panel)) 'panel)
                        (gdev-layout--tool-location panel)))))
    (when-let* ((window (gdev-layout--display-panel buffer)))
      (when (and previous (not (eq buffer previous)))
        (gdev-workspace-state-set 'gdev-layout-panel-buffers
                                  (remq previous (gdev-layout--panel-buffers))))
      (when origin (gdev-workspace-state-set 'gdev-layout-auxiliary-panel-origin origin))
      (gdev-workspace-state-set 'gdev-layout-auxiliary-buffer buffer)
      window)))

(defun gdev-layout--display-auxiliary (buffer &optional prohibited)
  "Mostra BUFFER accanto all'editor o nel pannello, escludendo PROHIBITED."
  (or (unless (and prohibited (eq prohibited (gdev-layout-auxiliary-window)))
        (gdev-layout--display-outside-focus
         (lambda () (gdev-layout--dock-auxiliary buffer))))
      (unless (and prohibited (eq prohibited (gdev-layout--panel)))
        (when-let* ((panel (gdev-layout--compact-auxiliary buffer)))
          (when-let* ((old (gdev-layout-auxiliary-window)))
            (gdev-layout--remove-side old))
          panel))
      (unless prohibited
        (user-error "Allarga la finestra per mostrare la vista ausiliaria"))))

(defun gdev-layout-close-auxiliary (buffer)
  "Chiudi la presentazione di BUFFER nello spazio attivo e conserva la vista."
  (let ((side (gdev-layout-auxiliary-window))
        (focused (when (eq buffer (window-buffer (selected-window))) (selected-window))))
    (if (and side (eq (window-buffer side) buffer))
        (gdev-layout--delete-side side)
      (gdev-layout--detach-auxiliary-from-panel buffer)
      (gdev-layout--forget-auxiliary buffer))
    (when focused
      (select-window (if (window-live-p focused) focused (gdev-layout-editor))))))

(defun gdev-layout--close-panel-tab (buffer)
  "Chiudi BUFFER dallo spazio attivo secondo il tipo di strumento."
  (if (eq (gdev-layout--role buffer) 'auxiliary)
      (gdev-layout-close-auxiliary buffer)
    (let ((focused (and (eq buffer (window-buffer)) (window-parameter nil 'gdev-layout-panel))))
      (when (kill-buffer buffer)
        (gdev-layout--repair-panel-split focused)))))

(defun gdev-layout-click-new-terminal (event)
  "Apri un nuovo terminale nello spazio del pannello del clic EVENT."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (and (window-live-p window) (window-parameter window 'gdev-layout-panel)
               (fboundp 'gdev-term-new))
      (unless (eq (window-frame window) (selected-frame))
        (select-frame-set-input-focus (window-frame window)))
      (gdev-term-new))))

(defvar-keymap gdev-layout--new-terminal-map
  "<tab-line> <mouse-1>" #'gdev-layout-click-new-terminal
  "RET" #'gdev-term-new)

(defconst gdev-layout--new-terminal-button
  (propertize "  +  " 'keymap gdev-layout--new-terminal-map
              'mouse-face 'tab-line-highlight 'help-echo "Nuovo terminale del progetto"))

(defun gdev-layout--terminal-action-at (event command)
  "Esegui COMMAND nel pannello degli strumenti del clic EVENT."
  (when-let* ((window (posn-window (event-start event)))
              ((and (window-live-p window) (window-parameter window 'gdev-layout-panel))))
    (let ((previous (selected-window))
          succeeded)
      (unwind-protect
          (progn
            (unless (eq (window-frame window) (selected-frame))
              (select-frame-set-input-focus (window-frame window)))
            (select-window window)
            (prog1 (call-interactively command)
              (setq succeeded t)))
        (when (and (not succeeded) (window-live-p previous))
          (unless (eq (window-frame previous) (selected-frame))
            (select-frame-set-input-focus (window-frame previous)))
          (select-window previous))))))

(defun gdev-layout-click-terminal-profile (event)
  "Scegli il profilo del nuovo terminale dal clic EVENT."
  (interactive "e")
  (gdev-layout--terminal-action-at event #'gdev-term-new-profile))

(defun gdev-layout-click-split-terminal (event)
  "Affianca un terminale a quello del clic EVENT."
  (interactive "e")
  (gdev-layout--terminal-action-at event #'gdev-term-split))

(defvar-keymap gdev-layout--terminal-profile-map
  "<tab-line> <mouse-1>" #'gdev-layout-click-terminal-profile
  "RET" #'gdev-term-new-profile)

(defvar-keymap gdev-layout--split-terminal-map
  "<tab-line> <mouse-1>" #'gdev-layout-click-split-terminal
  "RET" #'gdev-term-split)

(defconst gdev-layout--terminal-profile-button
  (propertize " ⌄ " 'keymap gdev-layout--terminal-profile-map
              'mouse-face 'tab-line-highlight 'help-echo "Nuovo terminale con profilo…"))

(defconst gdev-layout--split-terminal-button
  (propertize " ◫ " 'keymap gdev-layout--split-terminal-map
              'mouse-face 'tab-line-highlight 'help-echo "Affianca un terminale"))

(defun gdev-layout--panel-tab-name (buffer tabs)
  "Mostra l'etichetta di BUFFER con spazio per la chiusura e per le altre TABS."
  (let* ((name (concat "  " (gdev-layout--panel-label buffer)))
         (cap (if (cdr tabs) 30 50))
         (controls (when (fboundp 'gdev-term-new)
                     (if (eq (window-parameter nil 'gdev-layout-panel) 'companion)
                         gdev-layout--new-terminal-button
                       (concat gdev-layout--new-terminal-button
                               gdev-layout--terminal-profile-button
                               gdev-layout--split-terminal-button)))))
    (if (display-graphic-p)
        (let* ((reserved (concat controls tab-line-left-button tab-line-right-button
                                 tab-line-close-button "    "))
               (width (min (* cap (frame-char-width))
                           (- (window-body-width nil t) (gdev-ui-string-pixel-width reserved)))))
          (gdev-ui-fit-text name width
                            (lambda (text)
                              (gdev-ui-string-pixel-width (propertize text 'face 'tab-line-tab)))))
      (truncate-string-to-width
       name (max 4 (min cap (- (window-body-width) (string-width (or controls "")) 7)))
       nil nil "…"))))

(defun gdev-layout--panel-format-tab (buffer tabs)
  "Mostra il nome completo di BUFFER al passaggio del puntatore sulla scheda."
  (let* ((label (tab-line-tab-name-format-default buffer tabs))
         (close (text-property-any 0 (length label) 'keymap tab-line-tab-close-map label)))
    (put-text-property 0 (or close (length label)) 'help-echo (gdev-layout--panel-label buffer) label)
    (when close (put-text-property close (length label) 'help-echo "Chiudi questo strumento" label))
    label))

(defun gdev-layout--panel-tab-cache-key (tabs)
  "Distingui la resa di TABS nelle diverse larghezze del pannello."
  (append (tab-line-cache-key-default tabs) (list (window-body-width nil t))))

(defun gdev-layout--panel-display-tabs ()
  "Elenca le schede da mostrare nel riquadro del pannello attuale."
  (if (eq (window-parameter nil 'gdev-layout-panel) 'companion)
      (list (current-buffer))
    (let ((buffers (gdev-layout--panel-buffers)))
      (if-let* ((companion (gdev-layout-panel-companion)))
          (remq (window-buffer companion) buffers)
        buffers))))

(defun gdev-layout--panel-prepare-tabs (buffer)
  "Dota BUFFER delle schede e dei comandi del pannello."
  (with-current-buffer buffer
    (unless gdev-layout--panel-tabs-p
      (setq-local tab-line-tabs-function #'gdev-layout--panel-display-tabs
                  tab-line-tab-name-function #'gdev-layout--panel-tab-name
                  tab-line-tab-name-format-function #'gdev-layout--panel-format-tab
                  tab-line-cache-key-function #'gdev-layout--panel-tab-cache-key
                  tab-line-close-tab-function #'gdev-layout--close-panel-tab)
      (tab-line-mode 1)
      (when (fboundp 'gdev-term-new)
        ;; Il più resta in vista quando le schede eccedono la larghezza.
        (setq-local tab-line-format
                    (list gdev-layout--new-terminal-button
                          '(:eval (when (and (fboundp 'gdev-term-new-profile)
                                             (eq (window-parameter nil 'gdev-layout-panel) t))
                                    gdev-layout--terminal-profile-button))
                          '(:eval (when (and (fboundp 'gdev-term-split-available-p)
                                             (eq (window-parameter nil 'gdev-layout-panel) t)
                                             (gdev-term-split-available-p (selected-window)))
                                    gdev-layout--split-terminal-button))
                          '(:eval (tab-line-format)))))
      (setq gdev-layout--panel-tabs-p t))))

(defun gdev-layout--fit-auxiliary (window)
  "Mantieni WINDOW nella colonna o trasferiscila nel pannello con poco spazio."
  (let ((top (gdev-layout-command-sidebar-window)))
    (if (and (not (window-with-parameter 'gdev-minimap t))
             (not (gdev-minimap-requested-p))
             (>= (window-total-height window) gdev-layout--auxiliary-min-height)
             (or (not top) (>= (window-total-height top) gdev-layout--auxiliary-min-height))
             (gdev-layout-commands-fit-p))
        (unless top (gdev-layout-fit-commands window))
      (let ((buffer (window-buffer window))
            (location (gdev-layout--tool-location window))
            (selected (eq window (selected-window))))
        (gdev-layout--remove-side window)
        (gdev-layout--remember-panel buffer)
        (when (or selected (not (gdev-layout--panel)))
          (when-let* ((panel (ignore-errors (gdev-layout--compact-auxiliary buffer))))
            (gdev-layout--restore-tool-location panel location)
            (when selected (select-window panel))))))))

(defun gdev-layout--remove-panel-companion ()
  "Riunisci il pannello senza chiudere la sessione affiancata."
  (when-let* ((companion (gdev-layout-panel-companion)))
    (gdev-layout--remove-side companion)))

(defun gdev-layout--panel-slot (buffer &optional companion)
  "Mostra BUFFER nel pannello inferiore, sul lato destro con COMPANION."
  (let* ((panel (if companion (gdev-layout-panel-companion) (gdev-layout--panel)))
         (marker (if companion 'companion t))
         ;; L'azione nativa deve poter dividere il riquadro già esistente.
         (ignore-window-parameters (or companion ignore-window-parameters)))
    (if (and panel (eq (window-buffer panel) buffer))
        panel
      (display-buffer-in-side-window
       buffer `((side . bottom) (slot . ,(if companion 1 0)) (dedicated . side)
                (window-height . ,(or (and (gdev-layout--panel)
                                         (window-total-height (gdev-layout--panel)))
                                    (gdev-workspace-state-get 'gdev-layout-panel-height)
                                    gdev-layout-panel-height))
                (preserve-size . (nil . t))
                (window-parameters . ((gdev-layout-panel . ,marker)
                                      . ,gdev-layout--fixed-side-parameters)))))))

(defun gdev-layout--show-panel-pair (pair)
  "Mostra PAIR in due riquadri con la stessa altezza."
  (let ((configuration (current-window-configuration))
        right)
    (unwind-protect
        (when-let* ((left (gdev-layout--panel-slot (car pair)))
                    ((gdev-layout-panel-split-fits-p))
                    (candidate (gdev-layout--panel-slot (cadr pair) t))
                    ((not (eq left candidate))))
          (gdev-layout--panel-prepare-tabs (car pair))
          (gdev-layout--panel-prepare-tabs (cadr pair))
          (setq right candidate))
      (unless right (set-window-configuration configuration)))))

(defun gdev-layout-split-panel (source buffer)
  "Affianca BUFFER a SOURCE e pubblica la disposizione riuscita."
  (let* ((pair (list source buffer))
         (buffers (gdev-layout--panel-buffers))
         (window (gdev-layout--show-panel-pair pair)))
    (unless window (user-error "Allarga la finestra per affiancare i terminali"))
    (gdev-workspace-state-update
     `((gdev-layout-panel-split . ,pair)
       (gdev-layout-panel-active . ,buffer)
       (gdev-layout-panel-hidden)
       (gdev-layout-panel-buffers . ,(append buffers (list buffer)))))
    window))

(defun gdev-layout--display-panel (buffer &optional temporary)
  "Mostra BUFFER nel pannello.  TEMPORARY vale per i menu a comparsa."
  (if temporary
      (gdev-layout--panel-slot buffer)
    (gdev-layout--resume-panel-tools)
    (gdev-layout--display-outside-focus
     (lambda ()
       (let* ((pair (gdev-workspace-state-get 'gdev-layout-panel-split))
              (right (and (memq buffer pair) (seq-every-p #'buffer-live-p pair)
                          (gdev-layout--show-panel-pair pair)))
              (window (if right
                          (if (eq buffer (cadr pair)) right (gdev-layout--panel))
                        (gdev-layout--remove-panel-companion)
                        (gdev-layout--panel-slot buffer))))
         (when window
           (gdev-workspace-state-set 'gdev-layout-panel-hidden nil)
           (gdev-layout--remember-panel buffer t)
           (gdev-layout--panel-prepare-tabs buffer)
           window))))))

(defun gdev-layout--repair-panel-split (&optional retain-focus)
  "Allinea i due riquadri dopo chiusura, cambio scheda o ridimensionamento."
  (when-let* ((pair (gdev-workspace-state-get 'gdev-layout-panel-split)))
    (let* ((panel (gdev-layout--panel))
           (companion (gdev-layout-panel-companion))
           (focused (selected-window))
           (panel-focused (or retain-focus (eq focused panel) (eq focused companion)))
           (shown (and panel (window-buffer panel)))
           (right (and companion (window-buffer companion)))
           (active (gdev-workspace-state-get 'gdev-layout-panel-active))
           (live (seq-filter #'buffer-live-p pair)))
      (cond
       ((not (cdr live))
        (let* ((remaining (gdev-layout--panel-buffers))
               (next (or (car (memq active remaining)) (car live) (car (last remaining)))))
          (gdev-workspace-state-update
           `((gdev-layout-panel-split)
             (gdev-layout-panel-buffers . ,remaining)
             (gdev-layout-panel-active . ,next)))
          (gdev-layout--remove-panel-companion)
          (when (and next (or companion (memq shown pair))
                     (not (gdev-workspace-state-get 'gdev-layout-panel-hidden)))
            (when-let* ((window (gdev-layout--display-panel next)))
              (when panel-focused (select-window window))))))
       ((and panel (not (gdev-layout--temporary-p shown)))
        (let* ((fits (gdev-layout-panel-split-fits-p))
               (target (cond ((eq focused companion) right)
                             ((and companion (not panel-focused) (eq right active))
                              right)
                             (t shown))))
          (cond
           ((and fits (eq shown (car pair)) (eq right (cadr pair)))
            (when panel-focused
              (gdev-layout--remember-panel (window-buffer focused) t)))
           ((or companion (and fits (memq shown pair)))
            (when (memq (gdev-layout--role target) '(panel auxiliary))
              (when-let* ((window (gdev-layout--display-panel target)))
                (when panel-focused (select-window window))))))))))))

(defun gdev-layout--select-panel-tab (select buffer &optional window)
  "Applica SELECT alle schede ordinarie e conserva la coppia del pannello."
  (let ((target (or window (selected-window))))
    (if (and (window-parameter target 'gdev-layout-panel)
             (gdev-workspace-state-get 'gdev-layout-panel-split (window-frame target)))
        (progn
          (unless (eq (window-frame target) (selected-frame))
            (select-frame-set-input-focus (window-frame target)))
          (select-window target)
          (when-let* ((shown (gdev-layout--display-panel buffer)))
            (select-window shown)))
      (funcall select buffer window))))

(defun gdev-layout-show-left (buffer marker)
  "Mostra BUFFER nell'unico riquadro a sinistra, con il parametro MARKER."
  (gdev-layout-exit-focus)
  (when (fboundp 'gdev-activity-save-position)
    (gdev-activity-save-position (gdev-layout-left-window)))
  (when-let* ((previous (gdev-layout-left-window))
              (preferred (gdev-layout-explorer-preferred-width previous)))
    (gdev-workspace-state-set 'gdev-layout-explorer-width preferred))
  (when-let* ((preferred (or (gdev-workspace-state-get 'gdev-layout-explorer-width)
                             gdev-sidebar-width))
              (columns (window-total-width (frame-root-window)))
              (window
               (display-buffer-in-side-window
                buffer `((side . left) (slot . 0) (dedicated . t)
                         (window-width . ,(gdev-layout--explorer-width columns preferred))
                         (preserve-size . (t . nil))
                         (window-parameters . ((gdev-sidebar . ,(eq marker 'gdev-sidebar))
                                               (gdev-activity . ,(eq marker 'gdev-activity))
                                               . ,gdev-layout--fixed-side-parameters))))))
    (set-window-parameter window 'gdev-sidebar (eq marker 'gdev-sidebar))
    (set-window-parameter window 'gdev-activity (eq marker 'gdev-activity))
    (set-window-parameter window 'gdev-layout-explorer-sizing
                          (list columns (window-total-width window) preferred))
    (gdev-workspace-state-set 'gdev-layout-explorer-hidden nil)
    (when (fboundp 'gdev-activity-restore-position)
      (gdev-activity-restore-position window))
    window))

(defun gdev-layout-show-explorer (buffer)
  "Mostra BUFFER nella vista Esplora file."
  (when-let* ((window (gdev-layout-show-left buffer 'gdev-sidebar)))
    (gdev-workspace-state-update
     `((gdev-layout-explorer-buffer . ,buffer)
       (gdev-activity-view . nil)))
    (when (fboundp 'gdev-activity-decorate) (gdev-activity-decorate window))
    window))

(defun gdev-layout--display (buffer alist)
  "Applica la destinazione di BUFFER.  Da ALIST prende il contesto del chiamante."
  (let* ((action (cdr (assq 'gdev-layout-action alist)))
         (rule (gdev-layout--rule buffer action))
         (role (gdev-layout--role buffer rule))
         (prohibited (and (alist-get 'inhibit-same-window alist) (selected-window)))
         (placement (alist-get 'gdev-layout-placement alist))
         (window
          (pcase role
            ((or 'explorer 'activity)
             (unless (and prohibited (eq prohibited (gdev-layout-left-window)))
               (if (eq role 'explorer)
                   (gdev-layout-show-explorer buffer)
                 (when (fboundp 'gdev-activity-display)
                   (gdev-activity-display buffer (buffer-local-value 'gdev-activity-kind buffer) t)))))
            ((or 'commands 'minimap)
             (let ((side (if (eq role 'commands)
                             (gdev-layout-command-sidebar-window)
                           (window-with-parameter 'gdev-minimap t))))
               (unless (eq prohibited side) side)))
            ('auxiliary (gdev-layout--display-auxiliary buffer prohibited))
            ('panel (unless (and prohibited (window-parameter prohibited 'gdev-layout-panel))
                      (gdev-layout--display-panel
                       buffer (or (minibuffer-window-active-p (minibuffer-window))
                                  (gdev-layout--temporary-p buffer)))))
            ('editor (if (or (eq placement 'display-buffer-pop-up-frame)
                             (memq this-command '(find-file-other-frame dired-other-frame
                                                  switch-to-buffer-other-frame consult-buffer-other-frame)))
                         (display-buffer-pop-up-frame
                          buffer (seq-filter (lambda (option)
                                               (memq (car option) '(inhibit-switch-frame pop-up-frame-parameters)))
                                             alist))
                       (gdev-layout--display-editor buffer prohibited placement))))))
    (when window
      (when (and rule (eq role 'panel))
        (with-current-buffer buffer
          (setq gdev-layout--tool-p t)))
      (let ((body (alist-get 'body-function alist)))
        (when (functionp body)
          (let ((inhibit-read-only t)
                (inhibit-modification-hooks t))
            (funcall body window))))
      (when (plist-get (cdr rule) :select)
        (select-window window))
      window)))

(defvar gdev-layout--displaying nil
  "Non nil mentre è in corso una transizione di visualizzazione.")

(defun gdev-layout--display-advice (display buffer &optional action frame)
  "Instrada le richieste di DISPLAY nella finestra di lavoro corrente."
  (let* ((candidate (get-buffer buffer))
         (actions (list display-buffer-overriding-action
                        (and candidate
                             (display-buffer-assq-regexp (buffer-name candidate)
                                                         display-buffer-alist
                                                         (and (listp action) action)))
                        (and (consp action) action)))
         (options (apply #'append
                         (append (mapcar #'cdr actions)
                                 (when (and action (not (listp action)))
                                   '(((inhibit-same-window . t))))
                                 (list (cdr display-buffer-base-action)
                                       (cdr display-buffer-fallback-action)))))
         (placement (seq-some (lambda (entry)
                                (let ((functions (car entry)))
                                  (if (functionp functions) functions (car-safe functions))))
                              actions))
         (background (and (alist-get 'allow-no-window options)
                          (seq-some (lambda (entry)
                                      (memq #'display-buffer-no-window (ensure-list (car entry))))
                                    actions))))
    (cond
     ((or (not candidate) (frame-parent) (eq (frame-parameter nil 'minibuffer) 'only))
      (funcall display buffer action frame))
     (background nil)
     (t
      (with-suppressed-warnings ((obsolete special-display-function))
        (let (;; L'azione vale per questa chiamata: `list-processes' può
              ;; richiamare `display-buffer' mentre prepara il contenuto.
              (layout-action
               `(gdev-layout--display (gdev-layout-action . ,action)
                                      (gdev-layout-placement . ,placement)
                                      ,@options))
              (gdev-layout--displaying t)
              (display-buffer-overriding-action nil)
              (display-buffer-alist nil)
              (display-buffer-base-action nil)
              (display-buffer-fallback-action nil)
              (special-display-function nil))
          (funcall display candidate layout-action)))))))

(define-derived-mode gdev-layout-empty-mode special-mode "Spazio di lavoro"
  "Vista iniziale quando il cruscotto è disattivato."
  (gdev-ui-view-setup 'document)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Nessun documento aperto" 'face 'gdev-ui-view-title) "\n\n")
    (insert-text-button "Apri file…" 'type 'gdev-ui-action
                        'action (lambda (_) (call-interactively #'gdev-open-file)))
    (insert "\n")
    (goto-char (point-min))))

(defun gdev-layout-home-buffer ()
  "Restituisci la vista iniziale di un gruppo senza documenti."
  (if (fboundp 'gdev-dashboard-buffer)
      (gdev-dashboard-buffer)
    (let ((buffer (get-buffer-create "*Spazio GDev*")))
      (with-current-buffer buffer
        (unless (derived-mode-p 'gdev-layout-empty-mode) (gdev-layout-empty-mode)))
      buffer)))

(defun gdev-layout--skip-buffer (window buffer _bury-or-kill)
  "Esclude BUFFER dalla cronologia di WINDOW se appartiene a un altro riquadro."
  (let ((role (gdev-layout--role buffer)))
    (cond ((window-parameter window 'gdev-sidebar) (not (eq role 'explorer)))
          ((window-parameter window 'gdev-activity) (not (eq role 'activity)))
          ((window-parameter window 'gdev-layout-commands) (not (eq role 'commands)))
          ((window-parameter window 'gdev-layout-auxiliary) (not (eq role 'auxiliary)))
          ((window-parameter window 'gdev-minimap) (not (eq role 'minimap)))
          ((window-parameter window 'gdev-layout-panel)
           (not (and (memq role '(panel auxiliary))
                     (memq buffer (gdev-workspace-state-get 'gdev-layout-panel-buffers
                                                            (window-frame window))))))
          (t (or (not (eq role 'editor)) (gdev-ui-scratch-buffer-p buffer))))))

(defun gdev-layout--restore-document (window)
  "Ripristina in WINDOW l'ultimo documento del suo gruppo."
  (let* ((displaced (window-buffer window))
         (entry (seq-find (lambda (entry)
                           (and (buffer-live-p (car entry))
                                (not (eq (car entry) displaced))
                                (not (gdev-ui-scratch-buffer-p (car entry)))
                                (eq (gdev-layout--role (car entry)) 'editor)))
                         (window-prev-buffers window)))
         (buffer (or (car entry) (with-selected-window window (gdev-layout-home-buffer)))))
    (set-window-dedicated-p window nil)
    (set-window-buffer-start-and-point window buffer (nth 1 entry) (nth 2 entry))
    (unrecord-window-buffer window displaced)))

(defun gdev-layout--closed-documents ()
  "Restituisce le schede chiuse ancora recuperabili nello spazio corrente."
  (seq-filter (lambda (entry) (buffer-live-p (car entry)))
              (gdev-workspace-state-get 'gdev-layout-closed-documents)))

(defun gdev-layout-close-editor-tab (buffer)
  "Chiude BUFFER nel gruppo selezionato e conserva le modifiche in memoria."
  (let* ((window (selected-window))
         (shown (eq buffer (window-buffer window))))
    (if-let* ((control (and shown (fboundp 'gdev-comparison-control-at-window)
                            (gdev-comparison-control-at-window window))))
        (gdev-comparison-close control)
      (let* ((previous (assq buffer (window-prev-buffers window)))
             (entry
              (with-current-buffer buffer
                (list buffer
                      (when-let* ((start (if shown (window-start window) (nth 1 previous))))
                        (copy-marker start))
                      (copy-marker (or (if shown (window-point window) (nth 2 previous))
                                       (point)))))))
        (if shown (gdev-layout--restore-document window)
          (unrecord-window-buffer window buffer))
        (gdev-workspace-state-set
         'gdev-layout-closed-documents
         (seq-take (cons entry (assq-delete-all buffer (gdev-layout--closed-documents))) 20))
        (force-mode-line-update)))))

(defun gdev-layout-reopen-document ()
  "Riapre l'ultima scheda chiusa dello spazio di lavoro nel gruppo attivo."
  (interactive)
  (let* ((history (gdev-layout--closed-documents))
         (entry (or (car history) (user-error "Nessuna scheda da riaprire in questo spazio")))
         (window (gdev-layout-editor))
         (buffer (car entry)))
    (select-window window)
    (unless (eq buffer (window-buffer window))
      (switch-to-buffer buffer)
      (unless (eq buffer (window-buffer window))
        (user-error "Impossibile riaprire la scheda nel gruppo attivo"))
      (when (nth 1 entry)
        (set-window-start window (nth 1 entry) t))
      (set-window-point window (nth 2 entry)))
    (gdev-workspace-state-set 'gdev-layout-closed-documents (cdr history))))

(defun gdev-layout-document-beside (buffer source)
  "Trova il gruppo creato per affiancare BUFFER al gruppo SOURCE."
  (when-let* ((id (window-parameter source 'gdev-layout-editor-id)))
    (seq-find (lambda (window)
                (and (eq (window-buffer window) buffer)
                     (equal (window-parameter window 'gdev-layout-document-source) id)))
              (gdev-layout--editors (window-frame source)))))

(defun gdev-layout-open-document-beside (buffer source &optional direction toggle)
  "Disponi BUFFER accanto a SOURCE lungo DIRECTION, predefinita a destra.
Con TOGGLE chiude il gruppo già aperto dalla stessa azione per BUFFER."
  (unless (and (window-live-p source) (not (window-parameter source 'window-side))
               (buffer-live-p buffer) (gdev-layout-document-tab-p buffer)
               (not (eq buffer (window-buffer source))))
    (user-error "Scegli un altro documento"))
  (let* ((direction (or direction 'right))
         (neighbor (window-in-direction direction source))
         (target (and neighbor (not (window-parameter neighbor 'window-side)) neighbor)))
    (if (and toggle target (eq target (gdev-layout-document-beside buffer source)))
        (progn (delete-window target) (select-window source))
      (let* ((window (or target (gdev-layout-split-editor direction source)))
             (source (if target source (gdev-layout-editor)))
             (id (or (window-parameter source 'gdev-layout-editor-id)
                     (make-temp-name "editor-"))))
        (set-window-buffer window buffer)
        (select-window source)
        (unless target
          (set-window-prev-buffers window nil)
          (set-window-next-buffers window nil)
          (set-window-parameter source 'gdev-layout-editor-id id)
          (set-window-parameter window 'gdev-layout-document-source id)))))
  (force-mode-line-update t))

(defun gdev-layout-toggle-document-beside (buffer source &optional direction)
  "Apri o chiudi BUFFER sul lato DIRECTION di SOURCE."
  (gdev-layout-open-document-beside buffer source direction t))

(defun gdev-layout--recover-tool (buffer)
  "Raccogli BUFFER nel pannello senza sostituire uno strumento già attivo."
  (pcase (gdev-layout--role buffer)
    ('auxiliary (gdev-layout--display-auxiliary buffer))
    ('panel (gdev-layout--remember-panel buffer)
            (unless (or (gdev-layout--panel) (gdev-workspace-state-get 'gdev-layout-panel-hidden))
              (gdev-layout--display-panel buffer)))))

(defun gdev-layout--restore-auxiliary ()
  "Riporta a destra la vista ancora aperta quando lo spazio torna sufficiente."
  (when-let* ((buffer (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer)))
    (cond ((not (and (buffer-live-p buffer) (eq (gdev-layout--role buffer) 'auxiliary)))
           (gdev-layout--forget-auxiliary buffer))
          ((not (gdev-layout-auxiliary-window))
           (gdev-layout--dock-auxiliary buffer)))))

(defun gdev-layout--reconcile (&optional frame)
  "Riconduce FRAME alla disposizione ammessa dopo un cambiamento nativo."
  (let ((frame (or frame (selected-frame))))
    (unless (or gdev-layout--displaying (active-minibuffer-window) (frame-parent frame)
                (frame-parameter frame 'gdev-layout-focus)
                (eq (frame-parameter frame 'minibuffer) 'only))
      (let ((gdev-layout--displaying t))
        (with-selected-frame frame
          (gdev-layout--repair-panel-split)
          (dolist (window (window-list frame 'no-minibuffer))
            (let* ((buffer (window-buffer window))
                   (role (gdev-layout--role buffer)))
              (pcase (window-parameter window 'window-side)
                ('nil
                 (unless (eq role 'editor)
                   (gdev-layout--restore-document window)
                   (gdev-layout--recover-tool buffer)))
                ('left
                 (unless (and (eq window (gdev-layout-left-window))
                              (or (and (window-parameter window 'gdev-sidebar) (eq role 'explorer))
                                  (and (window-parameter window 'gdev-activity) (eq role 'activity))))
                   (gdev-layout--delete-side window)
                   (gdev-layout--recover-tool buffer)))
                ('right
                 (cond
                  ((window-parameter window 'gdev-layout-auxiliary)
                   (if (and (eq role 'auxiliary)
                            (eq buffer (gdev-workspace-state-get 'gdev-layout-auxiliary-buffer)))
                       (gdev-layout--fit-auxiliary window)
                     (gdev-layout--remove-side window)
                     (unless (eq role 'auxiliary) (gdev-layout--recover-tool buffer))))
                  ((or (and (window-parameter window 'gdev-minimap) (eq role 'minimap))
                       (and (window-parameter window 'gdev-layout-commands) (eq role 'commands))))
                  (t
                   (if (window-parameter window 'gdev-layout-commands)
                       (gdev-layout--remove-side window)
                     (gdev-layout--delete-side window))
                   (gdev-layout--recover-tool buffer))))
                ('bottom
                 (cond
                  ((gdev-layout--key-hint-p buffer))
                  ((eq window (gdev-layout-panel-companion)))
                  ((and (window-parameter window 'gdev-layout-panel) (memq role '(panel auxiliary))
                        (eq window (gdev-layout--panel)))
                   (if (and (eq role 'auxiliary)
                            (not (memq buffer (gdev-workspace-state-get 'gdev-layout-panel-buffers))))
                       (gdev-layout--remove-side window)
                     (unless (gdev-layout-panel-companion)
                       (gdev-layout--remember-panel buffer t))))
                  (t (gdev-layout--delete-side window)
                     (gdev-layout--recover-tool buffer))))
                (_
                 (gdev-layout--delete-side window)
                 (gdev-layout--recover-tool buffer)))))
          (when (and (not noninteractive) (fboundp 'gdev-activity-restore))
            (gdev-activity-restore))
          (when (and (not noninteractive) (fboundp 'gdev-sidebar--sync-frame)
                     (not (window-with-parameter 'gdev-activity t frame)))
            (gdev-sidebar--sync-frame frame))
          (gdev-layout--sync-commands frame)
          (gdev-layout--restore-auxiliary)
          (gdev-layout--schedule-saved-panel frame))))))

(defun gdev-layout-show-panel (&optional buffer)
  "Mostra BUFFER nel pannello in basso, oppure lo strumento attivo dello spazio.
È l'ingresso dei moduli al pannello: aggiorna insieme schede, strumento
attivo e visibilità.  Dopo un riavvio ricrea prima gli strumenti salvati
con la sessione.  Restituisce la finestra, o nil se lo spazio è troppo
stretto o il pannello non ha strumenti."
  (when-let* ((restored (gdev-layout--resume-panel-tools))
              ((not buffer)))
    (setq buffer restored))
  (when-let* ((buffer (or buffer
                          (let ((buffers (gdev-layout--panel-buffers)))
                            (or (car (memq (gdev-workspace-state-get 'gdev-layout-panel-active)
                                           buffers))
                                (car (last buffers)))))))
    (gdev-layout--display-panel buffer)))

(defun gdev-layout-hide-panel ()
  "Nascondi il pannello in basso conservando sessioni, scelta e altezza."
  (gdev-layout--hide-panel))

(defun gdev-layout-panel-window ()
  "Restituisci la finestra del pannello in basso, se è visibile."
  (gdev-layout--panel))

;;;; Strumenti del pannello dopo il riavvio

(defvar-local gdev-layout-restore-function nil
  "Funzione che descrive come ricreare lo strumento dopo un riavvio.
Restituisce (TIPO . PROPRIETÀ) o nil.  TIPO è registrato con
`gdev-layout-register-panel-restorer'; le PROPRIETÀ sono una lista di
proprietà fatta di testi, numeri e liste.")

(defvar gdev-layout--panel-restorers nil
  "Funzioni che ricreano gli strumenti del pannello, per tipo.")

(defun gdev-layout-register-panel-restorer (kind function)
  "Registra FUNCTION per ricreare gli strumenti di tipo KIND.
FUNCTION riceve le proprietà salvate, le convalida e restituisce il
buffer creato senza mostrarlo, oppure nil.  La sessione ricrea solo i tipi
registrati."
  (setf (alist-get kind gdev-layout--panel-restorers) function))

(defun gdev-layout-panel-snapshot (tab &optional pending)
  "Descrivi il pannello di TAB per salvarlo con la sessione.
Restituisce strumenti da ricreare, indice di quello attivo, altezza e
visibilità.  Senza strumenti da ricreare restituisce PENDING, il pannello
salvato che lo spazio non ha ancora mostrato."
  (let* ((current (eq (car tab) 'current-tab))
         (buffers (seq-filter #'buffer-live-p
                              (gdev-workspace-state-read 'gdev-layout-panel-buffers tab)))
         (active (gdev-workspace-state-read 'gdev-layout-panel-active tab))
         tools active-index)
    (dolist (buffer buffers)
      (when-let* ((describe (buffer-local-value 'gdev-layout-restore-function buffer))
                  (tool (with-demoted-errors "Strumento del pannello: %S"
                          (with-current-buffer buffer (funcall describe))))
                  ((assq (car-safe tool) gdev-layout--panel-restorers)))
        (when (eq buffer active) (setq active-index (length tools)))
        (push tool tools)))
    (if (not tools)
        pending
      (let ((window (and current (gdev-layout--panel))))
        (list :tools (nreverse tools)
              :active active-index
              :height (if window
                          (window-total-height window)
                        (gdev-workspace-state-read 'gdev-layout-panel-height tab))
              :visible (if current
                           (and window t)
                         (not (gdev-workspace-state-read 'gdev-layout-panel-hidden tab))))))))

(defun gdev-layout--resume-panel-tools ()
  "Ricrea nello spazio attivo gli strumenti salvati con la sessione.
Avviene la prima volta che lo spazio mostra il pannello, così i processi
partono solo quando servono.  Restituisce lo strumento attivo ricreato."
  (when-let* ((pending (gdev-workspace-state-get 'gdev-layout-panel-session)))
    (gdev-workspace-state-set 'gdev-layout-panel-session nil)
    (let (buffers active)
      (cl-loop for (kind . properties) in (plist-get pending :tools)
               for index from 0
               for restorer = (alist-get kind gdev-layout--panel-restorers)
               for buffer = (and restorer
                                 (with-demoted-errors "Ripristino dello strumento: %S"
                                   (funcall restorer properties)))
               when (buffer-live-p buffer)
               do (push buffer buffers)
               (when (eql index (plist-get pending :active)) (setq active buffer)))
      (when buffers
        (setq buffers (nreverse buffers))
        (gdev-workspace-state-update
         `((gdev-layout-panel-buffers . ,(append buffers (gdev-layout--panel-buffers)))
           (gdev-layout-panel-active . ,(or active (car buffers)))
           ,@(when-let* ((height (plist-get pending :height)))
               `((gdev-layout-panel-height . ,height)))))
        (or active (car buffers))))))

(defun gdev-layout--show-saved-panel (frame id)
  "Mostra il pannello salvato visibile nello spazio ID di FRAME."
  (when (and (frame-live-p frame) gdev-layout-mode
             (eq id (gdev-workspace-state-id frame)))
    (with-selected-frame frame
      (unless (gdev-layout--panel)
        (gdev-layout-show-panel)))))

(defun gdev-layout--schedule-saved-panel (frame)
  "Pianifica la ricomparsa del pannello salvato visibile nello spazio di FRAME."
  (when-let* ((pending (gdev-workspace-state-get 'gdev-layout-panel-session frame))
              ((plist-get pending :visible)))
    (gdev-workspace-state-set 'gdev-layout-panel-session
                              (plist-put (copy-sequence pending) :visible nil)
                              (gdev-workspace-state-current frame))
    (run-at-time 0 nil #'gdev-layout--show-saved-panel
                 frame (gdev-workspace-state-ensure-id frame))))

(defun gdev-layout-restore-configuration (configuration)
  "Ripristina CONFIGURATION e riallinea il pannello allo stato dello spazio.
Una vista temporanea registra le finestre quando si apre.  Quanto
l'utente cambia nel frattempo nel pannello vive nello stato dello spazio,
che prevale sulla fotografia: lo strumento aperto resta visibile e il
pannello chiuso resta chiuso."
  (set-window-configuration configuration)
  (when gdev-layout-mode
    (let ((active (gdev-workspace-state-get 'gdev-layout-panel-active)))
      (cond ((gdev-workspace-state-get 'gdev-layout-panel-hidden)
             (when (gdev-layout--panel) (gdev-layout--hide-panel)))
            ((and (memq active (gdev-layout--panel-buffers))
                  (not (memq (get-buffer-window active)
                             (delq nil (list (gdev-layout--panel)
                                             (gdev-layout-panel-companion))))))
             (gdev-layout-show-panel active))))))

(defun gdev-layout-toggle-panel ()
  "Nasconde o ripristina lo strumento attivo nello spazio di lavoro."
  (interactive)
  (if (gdev-layout--panel)
      (gdev-layout--hide-panel)
    (gdev-layout--resume-panel-tools)
    (if (gdev-layout--panel-buffers)
        (unless (gdev-layout-show-panel)
          (user-error "Allarga la finestra per mostrare il pannello"))
      (if (fboundp 'gdev-term-project)
          (call-interactively #'gdev-term-project)
        (user-error "Apri prima uno strumento")))))

(declare-function gdev-term-project "../../term/eat/config")
(declare-function gdev-sidebar--sync-frame "../sidebar/config")

(defun gdev-layout-open-tools ()
  "Restituisci le viste ausiliarie e gli strumenti dello spazio corrente."
  (let ((buffers (gdev-layout--panel-buffers)))
    (if-let* ((side (gdev-layout-auxiliary-window))
              (buffer (window-buffer side)))
        (cons buffer (remq buffer buffers))
      buffers)))

(defun gdev-layout-choose-panel ()
  "Sceglie uno strumento aperto nello spazio di lavoro e porta il fuoco lì."
  (interactive)
  (let* ((frame (selected-frame))
         (tab (gdev-workspace-state-current frame))
         (tools (gdev-layout-open-tools))
         (focused (window-buffer (selected-window)))
         (active (or (car (memq focused tools))
                     (gdev-workspace-state-read 'gdev-layout-panel-active tab)))
         choices current)
    (dolist (buffer tools)
      (let* ((base (gdev-layout--panel-label buffer))
             (label base)
             (number 1))
        (while (assoc label choices)
          (setq label (format "%s (%d)" base (cl-incf number))))
        (push (cons label buffer) choices)
        (when (eq buffer active) (setq current label))))
    (unless choices (user-error "Nessuno strumento aperto in questo spazio di lavoro"))
    (let* ((choices (nreverse choices))
           (table (gdev-completion-table-with-metadata
                   choices `((display-sort-function . identity)
                             (annotation-function . ,(lambda (label)
                                                      (when (equal label current) "  Attivo"))))))
           (name (completing-read "Strumento del progetto: " table nil t nil nil
                                  (or current (caar choices))))
           (buffer (cdr (assoc name choices))))
      (unless (and (eq frame (selected-frame)) (eq tab (gdev-workspace-state-current frame)))
        (user-error "Lo spazio di lavoro è cambiato. Scegli di nuovo lo strumento"))
      (unless (and (buffer-live-p buffer) (memq buffer (gdev-layout-open-tools)))
        (user-error "Lo strumento non è più aperto in questo spazio di lavoro"))
      (pop-to-buffer buffer))))

(defun gdev-layout-promote-panel ()
  "Trasforma lo strumento attivo in un documento nel gruppo editor."
  (interactive)
  (unless (window-parameter nil 'gdev-layout-panel)
    (user-error "Seleziona il pannello degli strumenti"))
  (let ((buffer (current-buffer))
        (window (selected-window)))
    (when (memq buffer (gdev-workspace-state-get 'gdev-layout-panel-split))
      (gdev-workspace-state-set 'gdev-layout-panel-split nil))
    (setq gdev-layout-document-p t)
    (when gdev-layout--panel-tabs-p
      (when (eq (car-safe tab-line-format) gdev-layout--new-terminal-button)
        (kill-local-variable 'tab-line-format))
      (tab-line-mode -1)
      (kill-local-variable 'tab-line-tabs-function)
      (kill-local-variable 'tab-line-tab-name-function)
      (kill-local-variable 'tab-line-tab-name-format-function)
      (kill-local-variable 'tab-line-cache-key-function)
      (kill-local-variable 'tab-line-close-tab-function)
      (setq gdev-layout--panel-tabs-p nil))
    (run-hooks 'gdev-new-document-hook)
    (gdev-layout--delete-side window)
    (pop-to-buffer buffer)))

(defun gdev-layout-toggle-maximize ()
  "Ingrandisce il gruppo editor e ripristina solo i gruppi editor."
  (let ((editor (gdev-layout-editor))
        (main (window-main-window))
        (state (gdev-workspace-state-get 'gdev-layout-editor-state)))
    (select-window editor)
    (cond
     ((not (eq main editor))
      (gdev-workspace-state-set 'gdev-layout-editor-state (window-state-get main))
      (delete-other-windows editor))
     (state
      (let ((active-state (window-state-get editor)))
        (gdev-window-state-put state editor 'safe)
        (gdev-window-state-put active-state (gdev-layout-editor) 'safe))
      (gdev-workspace-state-set 'gdev-layout-editor-state nil)))))

(defconst gdev-layout--focus-window-parameters
  '(header-line-format tab-line-format mode-line-format))

(defun gdev-layout--center-document (frame)
  "Centra l'editor di FRAME quando è attiva la modalità concentrazione."
  (when (frame-parameter frame 'gdev-layout-focus)
    (when-let* ((editor (gdev-layout-editor frame)))
      (let ((margin (max 0 (/ (- (window-total-width editor)
                                (max 1 gdev-layout-focus-columns)) 2)))
            (margins (window-margins editor)))
        (unless (and (= margin (or (car margins) 0)) (= margin (or (cdr margins) 0)))
          (set-window-margins editor margin margin))))))

(defun gdev-layout-exit-focus (&rest _)
  "Ripristina il layout e mantieni il documento aperto in concentrazione."
  (when-let* ((state (frame-parameter nil 'gdev-layout-focus))
              (editor (gdev-layout-editor)))
    (let ((document (window-buffer editor))
          (start (window-start editor))
          (point (window-point editor))
          (previous (window-prev-buffers editor))
          (next (window-next-buffers editor)))
      (set-frame-parameter nil 'gdev-layout-focus nil)
      (set-frame-parameter nil 'tab-bar-lines (plist-get state :tab-bar-lines))
      (set-window-configuration (plist-get state :configuration))
      (when-let* ((restored (gdev-layout-editor)))
        (select-window restored)
        (dolist (entry (plist-get state :parameters))
          (set-window-parameter restored (car entry) (cdr entry)))
        (let ((margins (plist-get state :margins)))
          (set-window-margins restored (car margins) (cdr margins)))
        (when (buffer-live-p document)
          (switch-to-buffer document)
          (set-window-start restored start)
          (set-window-point restored point)
          (set-window-prev-buffers restored previous)
          (set-window-next-buffers restored next))))))

(defun gdev-layout--display-outside-focus (display)
  "Esegui DISPLAY, ripristinando la concentrazione se manca una finestra."
  (if-let* ((focus (frame-parameter nil 'gdev-layout-focus))
            (editor (gdev-layout-editor)))
      (let ((configuration (current-window-configuration))
            (tab-bar-lines (frame-parameter nil 'tab-bar-lines))
            (parameters (mapcar (lambda (name) (cons name (window-parameter editor name)))
                                gdev-layout--focus-window-parameters))
            window)
        (unwind-protect
            (progn
              (gdev-layout-exit-focus)
              (setq window (funcall display)))
          (unless (window-live-p window)
            (set-frame-parameter nil 'gdev-layout-focus focus)
            (set-frame-parameter nil 'tab-bar-lines tab-bar-lines)
            (set-window-configuration configuration)
            (when-let* ((restored (gdev-layout-editor)))
              (dolist (parameter parameters)
                (set-window-parameter restored (car parameter) (cdr parameter)))))))
    (funcall display)))

(defun gdev-layout-toggle-focus ()
  "Centra il documento in una vista essenziale o ripristina i riquadri."
  (interactive)
  (if (frame-parameter nil 'gdev-layout-focus)
      (gdev-layout-exit-focus)
    (let ((editor (gdev-layout-editor)))
      (unless editor (user-error "Apri una finestra dell'editor"))
      (select-window editor)
      (set-frame-parameter
       nil 'gdev-layout-focus
       (list :configuration (current-window-configuration)
             :editor-state (window-state-get (window-main-window))
             :explorer-width (when-let* ((sidebar (gdev-layout-left-window)))
                               (gdev-layout-explorer-preferred-width sidebar))
             :tab-bar-lines (frame-parameter nil 'tab-bar-lines)
             :margins (window-margins editor)
             :parameters (mapcar (lambda (name) (cons name (window-parameter editor name)))
                                 gdev-layout--focus-window-parameters)))
      (let ((ignore-window-parameters t))
        (delete-other-windows editor))
      (set-frame-parameter nil 'tab-bar-lines 0)
      (dolist (name gdev-layout--focus-window-parameters)
        (set-window-parameter editor name 'none))
      (gdev-layout--center-document (selected-frame)))))

(defun gdev-layout--new-tab (open-tab &rest args)
  "Apri una scheda con OPEN-TAB da un gruppo editor.
Lo spazio duplicato eredita cartelle, preferenze della vista e profili."
  (when-let* ((editor (gdev-layout-editor)))
    (select-window editor))
  (let ((settings (when (eq tab-bar-new-tab-choice 'clone)
                    (gdev-workspace-state-clone-values))))
    (prog1 (apply open-tab args)
      (when settings
        (gdev-workspace-state-update settings)
        (when (fboundp 'gdev-activity-restore)
          (gdev-activity-restore)))
      (when (or (eq tab-bar-new-tab-choice #'gdev-layout-home-buffer)
                (and (equal tab-bar-new-tab-choice "*scratch*")
                     (gdev-ui-scratch-buffer-p (window-buffer (selected-window)))))
        (set-window-prev-buffers nil nil)
        (set-window-next-buffers nil nil)
        (set-window-parameter nil 'gdev-layout-editor-id nil)
        (set-window-parameter nil 'gdev-layout-document-source nil)))))

(defun gdev-layout--check-swap (&optional from to &rest _)
  "Consenti lo scambio fra gruppi editor della stessa finestra."
  (let* ((from (or from (selected-window)))
         (to (or to (next-window from 'nomini 'visible))))
    (when (or (window-parameter from 'window-side)
              (window-parameter to 'window-side)
              (not (eq (window-frame from) (window-frame to))))
      (user-error "Scegli due gruppi editor della stessa finestra"))))

(defconst gdev-layout--options
  '((switch-to-buffer-obey-display-actions . t)
    (window-sides-slots . (1 0 2 2))
    (window-sides-vertical . t)
    (switch-to-prev-buffer-skip . gdev-layout--skip-buffer)
    (tab-bar-tab-name-function . gdev-layout-tab-name)))

(defvar gdev-layout--previous-options nil)

(declare-function gdev-close-document "gdev-commands" ())
(defvar tab-line-close-button-show)

(defun gdev-layout-click-close (event)
  "Chiudi il documento o la vista nella finestra del clic EVENT."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (and (window-live-p window) (not (window-minibuffer-p window)))
      (with-selected-window window
        (gdev-close-document)))))

(defvar-keymap gdev-layout-close-map
  "<header-line> <mouse-1>" #'gdev-layout-click-close)

(defconst gdev-layout--close-button
  (propertize "  ×  " 'face 'variable-pitch 'mouse-face 'gdev-ui-side-hover
              'help-echo "Chiudi questa vista" 'local-map gdev-layout-close-map))

(defun gdev-layout--update-close-buttons (frame &optional remove)
  "Aggiungi la X alle finestre di FRAME. Con REMOVE ripristina le intestazioni."
  ;; I frame figli, come il popup del completamento, non hanno la X.
  (dolist (window (and (not (frame-parent frame)) (window-list frame 'nomini)))
    (with-current-buffer (window-buffer window)
      (let* ((header (window-parameter window 'header-line-format))
             (ours (and (consp header) (eq (car header) gdev-layout--close-button)))
             (original (if ours (nth 1 header) header))
             (tabs (and (bound-and-true-p tab-line-mode)
                        (bound-and-true-p tab-line-format)
                        (bound-and-true-p tab-line-close-button-show)
                        (not (window-parameter window 'tab-line-format))
                        (or gdev-layout--panel-tabs-p
                            (and (gdev-layout-document-tab-p (current-buffer))
                                 (not (window-parameter window 'window-side)))))))
        (cond ((or remove tabs)
               (when ours (set-window-parameter window 'header-line-format original)))
              ((not ours)
               (set-window-parameter
                window 'header-line-format
                (list gdev-layout--close-button original
                      (cond ((eq original 'none) nil)
                            (original nil)
                            (t 'header-line-format))))))))))

(defconst gdev-layout--tab-transitions '(tab-bar-select-tab tab-bar-new-tab-to tab-bar-close-tab)
  "Azioni sulle schede che ripristinano il layout dopo la concentrazione.")

(declare-function gdev-split-editor-right "gdev-commands" (&optional source))
(declare-function gdev-split-editor-below "gdev-commands" (&optional source))
(declare-function gdev-quit-view "gdev-commands" (&optional kill window))

(defvar-keymap gdev-layout-mode-map
  "<remap> <split-window-right>" #'gdev-split-editor-right
  "<remap> <split-window-below>" #'gdev-split-editor-below
  ;; `q' delle viste di Emacs segue la regola di chiusura del Workbench.
  "<remap> <quit-window>" #'gdev-quit-view)

(define-minor-mode gdev-layout-mode
  "Usa riquadri a destinazione fissa per tutta la configurazione."
  :global t
  :group 'gdev-layout
  (if gdev-layout-mode
      (progn
        (unless gdev-layout--previous-options
          (setq gdev-layout--previous-options
                (mapcar (lambda (option) (cons (car option) (default-value (car option))))
                        gdev-layout--options)))
        (dolist (option gdev-layout--options)
          (set-default (car option) (cdr option)))
        (dolist (parameter '(gdev-sidebar gdev-activity gdev-layout-panel gdev-minimap
                              gdev-layout-commands gdev-layout-commands-sizing gdev-layout-auxiliary
                              gdev-layout-explorer-sizing
                              gdev-layout-editor-id gdev-layout-document-source delete-window split-window
                              no-other-window no-delete-other-windows))
          (setf (alist-get parameter window-persistent-parameters) 'writable))
        (advice-add 'display-buffer :around #'gdev-layout--display-advice)
        (advice-add 'tab-line-select-tab-buffer :around #'gdev-layout--select-panel-tab)
        (advice-add 'split-window :around #'gdev-layout--limit-editor-split)
        (advice-add 'tab-bar-new-tab-to :around #'gdev-layout--new-tab)
        (advice-add 'window-swap-states :before #'gdev-layout--check-swap)
        (dolist (command gdev-layout--tab-transitions)
          (advice-add command :before #'gdev-layout-exit-focus))
        (add-hook 'window-size-change-functions #'gdev-layout--center-document)
        (add-hook 'window-size-change-functions #'gdev-layout--fit-explorer)
        (add-hook 'window-state-change-functions #'gdev-layout--reconcile)
        (add-hook 'window-state-change-functions #'gdev-layout--update-close-buttons 90)
        (set-frame-window-state-change nil t))
    (gdev-layout-exit-focus)
    (dolist (option gdev-layout--previous-options)
      (set-default (car option) (cdr option)))
    (setq gdev-layout--previous-options nil)
    (advice-remove 'display-buffer #'gdev-layout--display-advice)
    (advice-remove 'tab-line-select-tab-buffer #'gdev-layout--select-panel-tab)
    (advice-remove 'split-window #'gdev-layout--limit-editor-split)
    (advice-remove 'tab-bar-new-tab-to #'gdev-layout--new-tab)
    (advice-remove 'window-swap-states #'gdev-layout--check-swap)
    (dolist (command gdev-layout--tab-transitions)
      (advice-remove command #'gdev-layout-exit-focus))
    (remove-hook 'window-size-change-functions #'gdev-layout--center-document)
    (remove-hook 'window-size-change-functions #'gdev-layout--fit-explorer)
    (remove-hook 'window-state-change-functions #'gdev-layout--reconcile)
    (remove-hook 'window-state-change-functions #'gdev-layout--update-close-buttons)
    (dolist (frame (frame-list))
      (gdev-layout--update-close-buttons frame t))))

(provide 'gdev-layout)
;;; gdev-layout.el ends here
