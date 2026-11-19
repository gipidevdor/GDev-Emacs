;;; gdev-command-sidebar.el --- Comandi del contesto nel riquadro destro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I comandi vengono dalla vista attiva, dalla sua mappa del linguaggio e
;; dai menu GDev. I moduli possono pubblicare un gruppo con
;; `gdev-set-tool-actions'. Il riquadro e la ricerca usano le stesse azioni.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'hl-line)
(require 'seq)
(require 'gdev-activity)
(require 'gdev-context)
(require 'gdev-layout)
(require 'gdev-menu)
(require 'gdev-minimap)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)

(declare-function gdev-focus-editor "gdev-commands" ())
(declare-function gdev-writing-context-p "gdev-writing" ())

(defconst gdev-command-sidebar--categories
  '((context "Contesto" "code" "V" writing view language gdev-file gdev-edit gdev-selection gdev-code)
    (project "Progetto" "project" "P" gdev-project gdev-hit gdev-hithub direnv)
    (search "Cerca" "search" "C" gdev-search gdev-navigate)
    (terminals "Terminali" "terminal" "T" terminals remote)
    (tools "Strumenti" "settings" "S"))
  "Categorie dei comandi del riquadro.
I gruppi senza categoria esplicita vanno in Strumenti.")

(defface gdev-command-sidebar-group
  '((t :inherit (gdev-ui-view-heading variable-pitch)))
  "Titoli dei gruppi e del contesto."
  :group 'gdev-layout)

(defface gdev-command-sidebar-detail
  '((t :inherit (gdev-ui-secondary variable-pitch)))
  "Contesto secondario e scorciatoie del riquadro Comandi."
  :group 'gdev-layout)

(defconst gdev-command-sidebar--section-icons
  '((gdev-project . "project") (gdev-search . "search")
    (gdev-navigate . "open") (gdev-code . "code") (gdev-hit . "git")
    (gdev-hithub . "git") (gdev-tools . "settings") (gdev-file . "file")
    (gdev-edit . "edit") (gdev-view . "toggle") (gdev-window . "window")
    (gdev-help . "help")))

(defconst gdev-command-sidebar--project-first
  '(gdev-run-dwim gdev-build gdev-test-dwim gdev-run-project-task))
(defconst gdev-command-sidebar--search-first
  '(gdev-search-query consult-ripgrep project-find-regexp devdocs-lookup gdev-lookup-online))
(defconst gdev-command-sidebar--terminal-first
  '(gdev-term-project gdev-term-here gdev-open-repl gdev-eshell-project gdev-eshell-here))
(defconst gdev-command-sidebar--remote-first
  '(gdev-remote-open-folder gdev-remote-terminal gdev-remote-dired))

(cl-defstruct (gdev-command-sidebar--action (:constructor gdev-command-sidebar--make-action))
  label command key sequences path predicate prefix)

(defvar-local gdev-command-sidebar--source nil)
(defvar-local gdev-command-sidebar--stamp nil)
(defvar-local gdev-command-sidebar--groups-by-category nil
  "Descrittori delle sezioni per categoria, nell'ordine di presentazione.")
(defvar-local gdev-command-sidebar--group-stamp nil)
(defvar-local gdev-command-sidebar--resolved nil)
(defvar-local gdev-command-sidebar--disclosures nil)
(defvar-local gdev-command-sidebar--geometry nil)
(defvar-local gdev-command-sidebar--positions nil)
(defvar-local gdev-command-sidebar--rendered-category nil)
(defvar-local gdev-command-sidebar--locations nil)
(defvar-local gdev-command-sidebar--presentation nil
  "Finestra, categoria, intestazione, bersaglio e righe dell'ultimo ridisegno.")
(defvar gdev-command-sidebar--syncing nil)

(defun gdev-command-sidebar--category ()
  "Restituisci la categoria selezionata nello spazio corrente."
  (or (assq (gdev-workspace-state-get 'gdev-command-sidebar-category) gdev-command-sidebar--categories)
      (car gdev-command-sidebar--categories)))

(defun gdev-command-sidebar--group-category (group)
  "Restituisci la categoria che contiene GROUP."
  (or (cl-loop for (id _label _icon _letter . groups) in gdev-command-sidebar--categories
               when (memq (car group) groups) return id)
      'tools))

(defun gdev-command-sidebar--tab-line ()
  "Mostra le categorie di Comandi nella barra comune ai riquadri."
  (gdev-activity-tab-line gdev-command-sidebar--categories (car (gdev-command-sidebar--category))
                          #'gdev-command-sidebar-select))

(defun gdev-command-sidebar--available-p (action)
  "Verifica se ACTION è eseguibile nella vista corrente."
  (and (commandp (gdev-command-sidebar--action-command action))
       (condition-case nil
           (funcall (gdev-command-sidebar--action-predicate action))
         ((void-function void-variable user-error) nil))))

(defun gdev-command-sidebar--view-actions ()
  "Costruisci le azioni del profilo della vista e delle sue estensioni."
  (let (actions)
    (dolist (item (gdev-context-view-items))
      (when-let* ((command (gdev-context-item-command item)))
        (let ((condition (if (> (length item) 2) (aref item 2) t))
              (prefix (and (> (length item) 3) (plist-get (aref item 3) :prefix))))
          (push (gdev-command-sidebar--make-action
                 :label (aref item 0) :command command :prefix prefix
                 :predicate (lambda () (eval condition t)))
                actions))))
    (when (current-local-map)
      (push (gdev-command-sidebar--make-action
             :label "Cerca un comando della vista…" :command #'gdev-context-mode-actions
             :predicate #'current-local-map)
            actions))
    (nreverse actions)))

(defun gdev-command-sidebar--menu-actions (items &optional path gate)
  "Appiattisci ITEMS conservando PATH e l'eventuale condizione GATE."
  (mapcan
   (lambda (item)
     (pcase item
       (`(:when ,condition . ,entries)
        (let ((pending t) available)
          (gdev-command-sidebar--menu-actions
           entries path
           (lambda ()
             (when pending
               (setq available (and (or (null gate) (funcall gate)) (eval condition t))
                     pending nil))
             available))))
       ((and (pred vectorp) (guard (and (> (length item) 1) (stringp (aref item 0)))))
        (let* ((properties (append (seq-drop item 2) nil))
               (keys (plist-get properties :key-sequence)))
          (list (gdev-command-sidebar--make-action
                 :label (aref item 0) :command (aref item 1) :path path
                 :key (plist-get properties :keys) :sequences keys
                 :predicate (lambda ()
                              (and (or (null gate) (funcall gate))
                                   (gdev-menu--available-item-p item)))))))
       (`(,(and label (pred stringp)) . ,children)
        (gdev-command-sidebar--menu-actions children
                                          (if path (concat path " › " label) label) gate))))
   items))

(defun gdev-command-sidebar--submenu-items (entry)
  "Togli il titolo di ENTRY conservando l'eventuale condizione del sottomenu."
  (pcase entry
    (`(:when ,condition ,body)
     (list `(:when ,condition ,@(gdev-command-sidebar--submenu-items body))))
    (`(,(pred stringp) . ,items) items)))

(defun gdev-command-sidebar--menu-group (entry &optional first)
  "Descrivi la sezione ENTRY, con i comandi FIRST in testa quando viene aperta."
  (pcase-let ((`(,id ,label . ,_) entry))
    (list id label (or (alist-get id gdev-command-sidebar--section-icons) "settings")
          (lambda ()
            (gdev-command-sidebar--prioritize
             (gdev-command-sidebar--menu-actions (gdev-menu-section-items id)) first)))))

(defun gdev-command-sidebar--prioritize (actions first)
  "Porta i comandi di FIRST all'inizio di ACTIONS, nell'ordine indicato."
  (if (not first)
      actions
    (cl-stable-sort actions #'<
                    :key (lambda (action)
                           (or (seq-position first (gdev-command-sidebar--action-command action))
                               (length first))))))

(defun gdev-command-sidebar--submenu-label (item)
  "Restituisci il titolo di ITEM prima di risolvere le sue voci."
  (pcase item
    (`(:when ,_ ,entry) (gdev-command-sidebar--submenu-label entry))
    (`(:group ,label . ,_) label)
    ('(:personal) (and gdev-menu-personal-items "Comandi personali"))
    (`(,(and label (pred stringp)) . ,_) label)))

(defun gdev-command-sidebar--tool-groups (entry)
  "Descrivi separatamente i sottomenu di ENTRY senza risolverne le voci."
  (let (direct submenus)
    (dolist (item (cddr entry))
      (unless (member item '((:catalog) (:tool-actions)))
        (if-let* ((label (gdev-command-sidebar--submenu-label item)))
            (push (list (list 'gdev-tools label) label "settings"
                        (lambda ()
                          (gdev-command-sidebar--menu-actions
                           (gdev-command-sidebar--submenu-items (gdev-menu--entry item)))))
                  submenus)
          (push item direct))))
    (setq direct (nreverse direct))
    (cons (list 'gdev-tools (cadr entry) "settings"
                (lambda ()
                  (gdev-command-sidebar--menu-actions (gdev-menu--entries direct))))
          (nreverse submenus))))

(defun gdev-command-sidebar--writing-p ()
  "Indica se il contesto corrente usa il gruppo Scrittura."
  (and (fboundp 'gdev-writing-context-p) (gdev-writing-context-p)))

(defun gdev-command-sidebar--group-sources ()
  "Descrivi i gruppi nella vista corrente e prepara il modo di risolverli."
  (let ((primary '(gdev-project gdev-search)))
    (append
     (mapcar (lambda (section)
               (gdev-command-sidebar--menu-group
                (assq section gdev-menu--sections)
                (if (eq section 'gdev-project) gdev-command-sidebar--project-first
                  gdev-command-sidebar--search-first)))
             primary)
     (list
      (list 'terminals "Terminali" "terminal"
            (lambda ()
              (gdev-command-sidebar--prioritize
               (seq-filter (lambda (action)
                             (memq (gdev-command-sidebar--action-command action)
                                   gdev-command-sidebar--terminal-first))
                           (gdev-command-sidebar--menu-actions
                            (gdev-menu--items gdev-open-map "C-c o")))
               gdev-command-sidebar--terminal-first)))
      (list 'remote "Connessioni SSH" "remote"
            (lambda ()
              (gdev-command-sidebar--prioritize
               (gdev-command-sidebar--menu-actions (gdev-menu--items gdev-remote-map "C-c r"))
               gdev-command-sidebar--remote-first)))
      (if (gdev-command-sidebar--writing-p)
          (list 'writing "Scrittura" "edit" #'gdev-command-sidebar--view-actions)
        (list 'view "Vista corrente" "window" #'gdev-command-sidebar--view-actions)))
     (when (gdev-menu--language-map)
       (list (list 'language "Linguaggio" "code"
                   (lambda ()
                     (when-let* ((map (gdev-menu--language-map)))
                       (gdev-command-sidebar--menu-actions (gdev-menu--items map "C-c l")))))))
     (mapcar (pcase-lambda (`(,id ,label ,icon . ,items))
               (list id label icon
                     (lambda () (gdev-command-sidebar--menu-actions (gdev-menu--entries items)))))
             (reverse gdev-tool-action-groups))
     (mapcan (lambda (entry)
               (let ((id (car entry)))
                 (when (and (not (memq id primary)) (gdev-menu--section-enabled-p id))
                   (if (eq id 'gdev-tools)
                       (gdev-command-sidebar--tool-groups entry)
                     (list (gdev-command-sidebar--menu-group entry))))))
             gdev-menu--sections))))

(defun gdev-command-sidebar--identity (action)
  "Restituisci l'identità di ACTION, compreso il suo argomento prefisso."
  (cons (gdev-command-sidebar--action-command action)
        (gdev-command-sidebar--action-prefix action)))

(defun gdev-command-sidebar--resolve (group &optional seen limit wanted)
  "Valuta GROUP nella vista attiva, ignorando SEEN e fermandoti a LIMIT azioni.
Con WANTED valuta solo il comando con quell'identità."
  (let ((gdev-menu--defer-context t)
        (seen (or seen (make-hash-table :test #'equal)))
        usable)
    (catch 'enough
      (dolist (action (funcall (nth 3 group)))
        (let ((identity (gdev-command-sidebar--identity action)))
          (when (and (or (null wanted) (equal wanted identity))
                     (not (gethash identity seen))
                     (not (memq (car identity) '(gdev-command-sidebar-toggle
                                                gdev-command-sidebar-focus
                                                gdev-command-sidebar-select
                                                gdev-command-sidebar-find)))
                     (gdev-command-sidebar--available-p action))
            (puthash identity t seen)
            (push action usable)
            (when (and limit (zerop (cl-decf limit))) (throw 'enough nil))))))
    (nreverse usable)))

(defun gdev-command-sidebar--collect ()
  "Raccogli in ordine le azioni disponibili nel buffer corrente."
  (let ((seen (make-hash-table :test #'equal)))
    (cl-loop for group in (gdev-command-sidebar--group-sources)
             for (id label icon) = group
             for usable = (gdev-command-sidebar--resolve group seen)
             when usable collect (list id label icon usable))))

;;;; Il contesto resta quello della vista che l'utente stava usando

(defun gdev-command-sidebar--source-window (frame)
  "Trova la vista di FRAME a cui si riferiscono i comandi."
  (let ((selected (frame-selected-window frame))
        (buffer (gdev-workspace-state-get 'gdev-command-sidebar-buffer frame)))
    (or (and (gdev-layout--commands-context-p selected frame) selected)
        (when (buffer-live-p buffer)
          (let ((previous (buffer-local-value 'gdev-command-sidebar--source buffer)))
            (when (gdev-layout--commands-context-p previous frame) previous)))
        (gdev-layout-editor frame))))

(defun gdev-command-sidebar--directory ()
  "Restituisci la cartella visibile della vista attiva senza accedere al disco."
  (let* ((path (gdev-command-file))
         (directory (or (and path (file-name-directory path)) default-directory)))
    (or (gdev-workspace-root-for (or path directory) (gdev-workspace-roots)) directory)))

(defun gdev-command-sidebar--context-stamp (window)
  "Raccogli lo stato di WINDOW che può cambiare le azioni visibili."
  (with-selected-window window
    (list window (current-buffer) major-mode (buffer-name) buffer-file-name default-directory
          (gdev-workspace-roots (window-frame window))
          ;; Le azioni dipendono dalla presenza della selezione, non dai suoi
          ;; estremi: estenderla non ridisegna la vista a ogni movimento.
          (use-region-p)
          (and (or gdev-context-items (derived-mode-p 'special-mode 'dired-mode))
               (point))
          buffer-read-only (buffer-modified-p) (consp buffer-undo-list)
          (bound-and-true-p eglot--managed-mode) gdev-activity-kind
          (when-let* ((process (get-buffer-process (current-buffer)))) (process-status process))
          (gdev-menu--language-map) gdev-context-items gdev-tool-action-groups gdev-menu-personal-items
          gdev-modules (bound-and-true-p gdev-preferences-keybindings))))

(defun gdev-command-sidebar--target (source &optional capture-point)
  "Ricorda vista, spazio e selezione di SOURCE.
Le righe di Comandi ricordano solo se c'è una selezione: il clic agisce su
quella visibile.  Con CAPTURE-POINT, per una scelta che resta aperta,
ricorda anche estremi della selezione, cursore e revisione del documento.
L'output di uno strumento in corso può avanzare durante la scelta."
  (with-selected-window source
    (list source (current-buffer) major-mode (gdev-workspace-state-current) default-directory
          (copy-sequence (gdev-workspace-roots))
          (if capture-point
              (when (use-region-p)
                (list (region-beginning) (region-end) (buffer-chars-modified-tick)))
            (use-region-p))
          (and capture-point
               (if (get-buffer-process (current-buffer))
                   'output
                 (cons (point) (buffer-chars-modified-tick)))))))

(defun gdev-command-sidebar--run (identity target group-id)
  "Richiama il comando (COMANDO . PREFISSO) di IDENTITY per TARGET.
Verifica che il comando sia ancora disponibile in GROUP-ID."
  (pcase-let ((`(,source ,buffer ,_ ,tab ,_ ,_ ,_ ,caret) target))
    (unless (and (window-live-p source) (eq (window-buffer source) buffer)
                 (eq (gdev-workspace-state-current (window-frame source)) tab)
                 (equal target (gdev-command-sidebar--target source caret)))
      (gdev-command-sidebar-refresh)
      (user-error "Il contesto è cambiato. Scegli di nuovo il comando"))
    (unless (with-selected-window source
              (when-let* ((group (assoc group-id (gdev-command-sidebar--group-sources))))
                (gdev-command-sidebar--resolve group nil 1 identity)))
      (gdev-command-sidebar-refresh)
      (user-error "Il comando non è più disponibile in questa vista"))
    (let ((before (selected-window))
          (command (car identity))
          (current-prefix-arg (or (cdr identity) current-prefix-arg))
          (last-input-event nil))
      (select-window source)
      (condition-case err
          (progn (setq this-command command) (call-interactively command))
        ((quit error)
         (when (and (window-live-p before) (eq tab (gdev-workspace-state-current (window-frame before))))
           (select-window before))
         (signal (car err) (cdr err)))))))

(defun gdev-command-sidebar-find ()
  "Cerca in tutte le categorie e richiama il comando scelto."
  (interactive)
  (let* ((source (or (gdev-command-sidebar--source-window (selected-frame))
                     (user-error "Apri una vista dello spazio di lavoro")))
         (target (gdev-command-sidebar--target source t))
         (groups (with-selected-window source (gdev-command-sidebar--collect)))
         (labels (make-hash-table :test #'equal))
         choices)
    (pcase-dolist (`(,id ,group ,_ . (,actions)) groups)
      (dolist (action actions)
        (let* ((base (concat (gdev-command-sidebar--action-label action)
                             " · " group
                             (when-let* ((path (gdev-command-sidebar--action-path action)))
                               (concat " › " path))))
               (label base)
               (index 1))
          (while (gethash label labels)
            (setq label (format "%s (%d)" base (cl-incf index))))
          (puthash label (cons id action) labels)
          (push label choices))))
    (unless choices (user-error "Nessun comando disponibile per questa vista"))
    (when-let* ((label (completing-read "Comando del contesto: " (nreverse choices) nil t))
                (choice (gethash label labels)))
      (gdev-command-sidebar--run (gdev-command-sidebar--identity (cdr choice))
                                 target (car choice)))))

;;;; Righe e comandi della vista

(defvar-keymap gdev-command-sidebar-mode-map
  :parent special-mode-map
  "RET" #'gdev-command-sidebar-activate
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "<down>" #'forward-button
  "<up>" #'backward-button
  "<left>" #'gdev-command-sidebar-previous-category
  "<right>" #'gdev-command-sidebar-next-category
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'gdev-command-sidebar-click
  "<double-mouse-1>" #'ignore
  "/" #'gdev-command-sidebar-find
  "g" #'gdev-command-sidebar-refresh
  "q" #'gdev-focus-editor)

(defvar-keymap gdev-command-sidebar-button-map
  :parent button-map
  "<mouse-1>" #'gdev-command-sidebar-click
  "<double-mouse-1>" #'ignore)

(define-button-type 'gdev-command-sidebar-button
  'keymap gdev-command-sidebar-button-map
  'face 'variable-pitch 'mouse-face 'gdev-ui-side-hover
  'follow-link t)

(define-derived-mode gdev-command-sidebar-mode special-mode "Comandi"
  "Azioni disponibili nello spazio di lavoro."
  (gdev-ui-view-setup 'sidebar)
  (setq-local tab-line-format '(:eval (gdev-command-sidebar--tab-line))
              gdev-command-sidebar--resolved (make-hash-table :test #'equal))
  (when (display-graphic-p)
    (setq-local cursor-type nil))
  (setq-local header-line-format
              '(:eval (propertize (concat "  " (cadr (gdev-command-sidebar--category)))
                                  'face 'gdev-ui-side-title)))
  (hl-line-mode 1))

(defun gdev-command-sidebar-activate ()
  "Attiva l'azione della riga corrente."
  (interactive)
  (if-let* ((button (button-at (point))))
      (button-activate button)
    (user-error "Scegli un comando o un gruppo")))

(defun gdev-command-sidebar-click (event)
  "Attiva la riga indicata da EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (button-at (point)) (gdev-command-sidebar-activate)))

(defun gdev-command-sidebar--measure (text)
  "Misura TEXT con i caratteri della finestra corrente."
  (if (display-graphic-p) (string-pixel-width text) (string-width text)))

(defun gdev-command-sidebar--fit (text face width)
  "Adatta TEXT in FACE alla WIDTH corrente."
  (gdev-ui-fit-text (propertize (replace-regexp-in-string "[\n\r\t]" " " text) 'face face)
                   (max 0 width) #'gdev-command-sidebar--measure))

(defun gdev-command-sidebar--row (id label face lead hint width callback &optional help)
  "Inserisci ID con LABEL in FACE, LEAD e HINT entro WIDTH."
  (let* ((start (point))
         (lead (or lead "  "))
         (hint (when hint (propertize (concat "  " hint) 'face 'gdev-command-sidebar-detail)))
         (budget (- width (gdev-command-sidebar--measure lead)))
         (hint-width (if hint (gdev-command-sidebar--measure hint) 0)))
    ;; La scorciatoia è un'indicazione secondaria. Alla larghezza minima
    ;; lascia prima spazio al nome dell'azione, mantenendo il testo in aiuto.
    (when (and hint (> hint-width (/ budget 3)))
      (setq hint nil hint-width 0))
    (puthash id start gdev-command-sidebar--positions)
    (insert-text-button (concat lead (gdev-command-sidebar--fit label face (- budget hint-width))
                                (when hint
                                  (let ((column (- width hint-width)))
                                    (propertize " " 'display
                                                (list 'space :align-to
                                                      (if (display-graphic-p) (list column) column)))))
                                hint)
                        :type 'gdev-command-sidebar-button
                        'action callback 'help-echo (or help label)
                        'gdev-command-sidebar-id id)
    (insert "\n")))

(defun gdev-command-sidebar--group-actions (group state limit source)
  "Risolvi GROUP per SOURCE una volta per contesto e apertura STATE.
In forma compatta basta verificare l'esistenza di un'azione oltre LIMIT."
  (let* ((id (car group))
         (entry (gethash id gdev-command-sidebar--resolved)))
    (if (eq (car entry) state)
        (cdr entry)
      (let ((actions (with-selected-window source
                       (gdev-command-sidebar--resolve group nil
                                                     (and (eq state 'compact) (1+ limit))))))
        (puthash id (cons state actions) gdev-command-sidebar--resolved)
        actions))))

(defun gdev-command-sidebar--action-content (action)
  "Raccogli identità, etichetta, percorso e scorciatoia effettiva di ACTION."
  (let* ((identity (gdev-command-sidebar--identity action))
         (key (or (gdev-command-sidebar--action-key action)
                  (when-let* ((sequence (gdev-menu-command-key
                                         (car identity)
                                         (gdev-command-sidebar--action-sequences action))))
                    (gdev-menu-key-label sequence)))))
    (list identity (copy-sequence (gdev-command-sidebar--action-label action))
          (copy-sequence (gdev-command-sidebar--action-path action))
          (copy-sequence key))))

(defun gdev-command-sidebar--section-content (group source)
  "Restituisci le righe visibili di GROUP con le scorciatoie attive in SOURCE."
  (pcase-let* ((`(,id ,label ,icon ,_) group)
               (default (cond ((eq id 'writing) 'expanded)
                              ((memq id '(view language gdev-project gdev-search terminals)) 'compact)))
               (state (alist-get id gdev-command-sidebar--disclosures default nil #'equal))
               (limit (pcase id ((or 'view 'gdev-project) 4) ((or 'language 'gdev-search) 2) (_ 1)))
               (actions (and state (gdev-command-sidebar--group-actions group state limit source)))
               (shown (if (eq state 'compact) (seq-take actions limit) actions))
               (rows (when shown
                       (with-selected-window source
                         (mapcar #'gdev-command-sidebar--action-content shown)))))
    (list id label icon state rows (< (length shown) (length actions)))))

(defun gdev-command-sidebar--section (section window width target)
  "Disegna SECTION di TARGET in WINDOW con WIDTH unità disponibili."
  (pcase-let* ((`(,id ,label ,icon ,state ,rows ,more) section)
               (prefix (concat "  " (if state "▾" "▸") " "
                               (gdev-ui-icon icon "·" (window-frame window)
                                            'gdev-command-sidebar-detail)
                               "  ")))
    (gdev-command-sidebar--row
     id label 'gdev-command-sidebar-group prefix nil width
     (lambda (_)
       (setf (alist-get id gdev-command-sidebar--disclosures nil nil #'equal)
             (unless state 'expanded))
       (remhash id gdev-command-sidebar--resolved)
       (gdev-command-sidebar--render window))
     (format "%s il gruppo %s" (if state "Comprimi" "Espandi") label))
    (when state
      (unless rows
        (insert "     " (gdev-command-sidebar--fit "Nessun comando disponibile"
                                                  'gdev-command-sidebar-detail
                                                  (- width (gdev-command-sidebar--measure "     ")))
                "\n"))
      (pcase-dolist (`(,(and identity `(,command . ,prefix-arg)) ,name ,path ,key) rows)
        (let ((action-id (list id command)))
          (gdev-command-sidebar--row
           (if prefix-arg (append action-id (list prefix-arg)) action-id)
           name 'variable-pitch "     " key width
           (lambda (_) (gdev-command-sidebar--run identity target id))
           (string-join (delq nil (list name path key)) " · "))))
      (when more
        (gdev-command-sidebar--row
         (list id 'more) "Altri comandi…" 'gdev-command-sidebar-detail "     " nil width
         (lambda (_)
           (setf (alist-get id gdev-command-sidebar--disclosures nil nil #'equal) 'expanded)
           (gdev-command-sidebar--render window)))))))

(defun gdev-command-sidebar--context (source)
  "Restituisci titolo, percorso e descrizione della vista SOURCE."
  (with-selected-window source
    (let* ((directory (gdev-command-sidebar--directory))
           (title (file-name-nondirectory (directory-file-name directory)))
           (name (gdev-ui-buffer-name))
           (mode (gdev-ui-mode-label)))
      (list (if (string-empty-p title) directory title)
            (abbreviate-file-name directory)
            (if (equal name mode) name (format "%s · %s" name mode))))))

(defun gdev-command-sidebar--render (window &optional compare)
  "Aggiorna WINDOW. Con COMPARE ridisegna solo se cambia la presentazione."
  (with-selected-window window
    (let* ((category (car (gdev-command-sidebar--category)))
           (source gdev-command-sidebar--source)
           (target (gdev-command-sidebar--target source))
           (context (gdev-command-sidebar--context source))
           (sections (mapcar (lambda (group) (gdev-command-sidebar--section-content group source))
                             (alist-get category gdev-command-sidebar--groups-by-category)))
           (presentation (list window category context target sections))
           (previous-target (nth 3 gdev-command-sidebar--presentation)))
      (unless (and compare (eq (nth 3 target) (nth 3 previous-target))
                   (equal-including-properties presentation gdev-command-sidebar--presentation))
        (gdev-command-sidebar--draw window category context target sections)
        (setq gdev-command-sidebar--presentation presentation)))))

(defun gdev-command-sidebar--draw (window category context target sections)
  "Disegna CATEGORY in WINDOW selezionata, con CONTEXT e azioni di TARGET."
  (let* ((inhibit-read-only t)
         (pixels (display-graphic-p))
         (width (- (window-body-width window pixels)
                   (gdev-command-sidebar--measure "  ")))
         (previous gdev-command-sidebar--rendered-category)
         (location (cons (get-text-property (point) 'gdev-command-sidebar-id)
                         (get-text-property (window-start window) 'gdev-command-sidebar-id)))
         (restore (if (eq previous category) location
                    (cdr (assq category gdev-command-sidebar--locations))))
         (project-prefix (concat "  " (gdev-ui-icon "project" "·" (window-frame window)
                                                    'gdev-command-sidebar-detail) "  ")))
    (when (and previous (not (eq previous category)))
      (setf (alist-get previous gdev-command-sidebar--locations) location))
    (setq gdev-command-sidebar--positions (make-hash-table :test #'equal)
          gdev-command-sidebar--rendered-category category)
    (erase-buffer)
    (insert project-prefix
            (propertize (gdev-command-sidebar--fit
                         (car context) 'gdev-command-sidebar-group
                         (- width (gdev-command-sidebar--measure project-prefix)))
                        'help-echo (nth 1 context))
            "\n  "
            (propertize (gdev-command-sidebar--fit (nth 2 context) 'gdev-command-sidebar-detail
                                                   (- width (gdev-command-sidebar--measure "  ")))
                        'help-echo (nth 2 context))
            "\n\n")
    (gdev-command-sidebar--row
     'find "Cerca un comando…" 'gdev-ui-action
     (concat "  " (gdev-ui-icon "search" "·" (window-frame window) 'gdev-command-sidebar-detail) "  ")
     "/" width (lambda (_) (gdev-command-sidebar-find)))
    (insert "\n")
    (if sections
        (dolist (section sections)
          (gdev-command-sidebar--section section window width target))
      (insert "  " (gdev-command-sidebar--fit "Nessun comando disponibile"
                                             'gdev-command-sidebar-detail width) "\n"))
    (let ((selected (car restore))
          (top (cdr restore)))
      (goto-char (or (gethash selected gdev-command-sidebar--positions)
                     (and (consp selected) (gethash (car selected) gdev-command-sidebar--positions))
                     (gethash 'find gdev-command-sidebar--positions)))
      (set-window-start window (or (gethash top gdev-command-sidebar--positions) (point-min)) t))
    (set-window-hscroll window 0)
    (set-buffer-modified-p nil)
    (hl-line-highlight)))

;;;; Disposizione, aggiornamenti e vita del riquadro

(defun gdev-command-sidebar--update (window source &optional force)
  "Aggiorna la vista in WINDOW per SOURCE se cambia il contesto o la geometria."
  (when (window-live-p source)
    (let* ((stamp (gdev-command-sidebar--context-stamp source))
           (geometry (list (window-body-width window t) (frame-char-width (window-frame window)))))
      (with-current-buffer (window-buffer window)
        (let ((changed (or force (not (equal stamp gdev-command-sidebar--stamp))))
              (layout-changed (or (not (eq window (car gdev-command-sidebar--presentation)))
                                  (not (equal geometry gdev-command-sidebar--geometry)))))
          (when changed
            (let ((group-stamp (with-selected-window source
                                 (list gdev-menu--sections gdev-modules gdev-tool-action-groups
                                       (not (null gdev-menu-personal-items))
                                       (not (null (gdev-menu--language-map)))
                                       (gdev-command-sidebar--writing-p)))))
              (when (or force (not (equal group-stamp gdev-command-sidebar--group-stamp)))
                (setq gdev-command-sidebar--groups-by-category
                      (seq-group-by #'gdev-command-sidebar--group-category
                                    (with-selected-window source (gdev-command-sidebar--group-sources)))
                      gdev-command-sidebar--group-stamp group-stamp)))
            (clrhash gdev-command-sidebar--resolved)
            (setq gdev-command-sidebar--source source
                  gdev-command-sidebar--stamp stamp
                  default-directory (buffer-local-value 'default-directory (window-buffer source))))
          (when (or changed layout-changed
                    (not (eq (car (gdev-command-sidebar--category)) gdev-command-sidebar--rendered-category)))
            (setq gdev-command-sidebar--geometry geometry)
            (gdev-command-sidebar--render window (not (or force layout-changed)))))))))

(defun gdev-command-sidebar--buffer ()
  "Recupera il buffer Comandi dello spazio di lavoro attivo."
  (let ((buffer (gdev-workspace-state-get 'gdev-command-sidebar-buffer)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer " *GDev Comandi*"))
      (with-current-buffer buffer (gdev-command-sidebar-mode))
      (gdev-workspace-state-set 'gdev-command-sidebar-buffer buffer))
    buffer))

(defun gdev-command-sidebar-sync (&optional frame)
  "Allinea il riquadro Comandi di FRAME con lo spazio e la vista attivi."
  (let ((frame (or frame (selected-frame))))
    (unless (or gdev-command-sidebar--syncing (active-minibuffer-window)
                (frame-parent frame) (eq (frame-parameter frame 'minibuffer) 'only))
      (let ((gdev-command-sidebar--syncing t))
        (with-selected-frame frame
          (let ((side (gdev-layout-command-sidebar-window frame))
                (source (gdev-command-sidebar--source-window frame)))
            ;; La duplicazione di una scheda copia anche le sue finestre.
            (when (and side (not (eq (window-buffer side)
                                     (gdev-workspace-state-get 'gdev-command-sidebar-buffer frame))))
              (gdev-layout--remove-side side)
              (setq side nil))
            (if (gdev-layout--commands-wanted-p frame source)
                (when-let* ((window (if side (gdev-layout-fit-commands side)
                                       (gdev-layout-show-commands (gdev-command-sidebar--buffer)))))
                  (gdev-command-sidebar--update window source)
                  window)
              (when side (gdev-layout--remove-side side))
              nil)))))))

(defun gdev-command-sidebar--show ()
  "Richiedi Comandi nello spazio attivo e restituisci la sua finestra."
  (when (and gdev-layout-mode (gdev-layout-commands-fit-p))
    (gdev-layout-exit-focus)
    (gdev-workspace-state-update
     '((gdev-layout-commands-visibility . shown)
       (gdev-layout-minimap-visible . nil)))
    (when-let* ((minimap (window-with-parameter 'gdev-minimap t)))
      (gdev-layout--remove-side minimap))
    (gdev-command-sidebar-sync)))

(defun gdev-command-sidebar-toggle ()
  "Mostra o nascondi il riquadro Comandi dello spazio corrente."
  (interactive)
  (if-let* ((side (gdev-layout-command-sidebar-window)))
      (delete-window side)
    (unless (gdev-command-sidebar--show)
      (gdev-command-sidebar-find))))

(defun gdev-command-sidebar-focus ()
  "Passa a Comandi, all'editor o alla ricerca se la finestra è stretta."
  (interactive)
  (if (window-parameter nil 'gdev-layout-commands)
      (gdev-focus-editor)
    (if-let* ((side (or (gdev-layout-command-sidebar-window)
                        (gdev-command-sidebar--show))))
        (select-window side)
      (gdev-command-sidebar-find))))

(defun gdev-command-sidebar-select (&optional category keep-focus)
  "Mostra CATEGORY in Comandi; con KEEP-FOCUS conserva il fuoco.
Restituisci la finestra di Comandi, oppure nil se KEEP-FOCUS e non c'è spazio."
  (interactive
   (list (let ((choices (mapcar (lambda (entry) (cons (cadr entry) (car entry)))
                               gdev-command-sidebar--categories)))
           (cdr (assoc (completing-read "Categoria di Comandi: " choices nil t) choices)))))
  (unless (assq category gdev-command-sidebar--categories)
    (user-error "Scegli una categoria di Comandi"))
  (if-let* ((side (or (gdev-layout-command-sidebar-window) (gdev-command-sidebar--show)))
            (source (gdev-command-sidebar--source-window (selected-frame))))
      (progn
        (gdev-workspace-state-set 'gdev-command-sidebar-category category)
        (gdev-command-sidebar--update side source)
        (unless keep-focus (select-window side))
        (force-mode-line-update)
        side)
    (unless keep-focus
      (user-error "Allarga la finestra per mostrare Comandi. C-c w T apre la ricerca"))))

(defun gdev-command-sidebar--step-category (direction)
  "Passa alla categoria nella DIREZIONE indicata."
  (let* ((current (gdev-command-sidebar--category))
         (index (seq-position gdev-command-sidebar--categories current #'eq)))
    (gdev-command-sidebar-select
     (car (nth (mod (+ index direction) (length gdev-command-sidebar--categories))
               gdev-command-sidebar--categories)))))

(defun gdev-command-sidebar-previous-category ()
  "Passa alla categoria precedente di Comandi."
  (interactive)
  (gdev-command-sidebar--step-category -1))

(defun gdev-command-sidebar-next-category ()
  "Passa alla categoria successiva di Comandi."
  (interactive)
  (gdev-command-sidebar--step-category 1))

(defun gdev-command-sidebar-refresh ()
  "Rileggi le azioni e ridisegna la vista Comandi."
  (interactive)
  (dolist (frame (frame-list))
    (when-let* ((window (gdev-layout-command-sidebar-window frame))
                (source (gdev-command-sidebar--source-window frame)))
      (gdev-command-sidebar--update window source t))))

(defun gdev-command-sidebar--after-command ()
  "Verifica il contesto visibile dopo un comando."
  (when (and gdev-layout-mode (not noninteractive) (not (active-minibuffer-window)))
    (when-let* ((window (gdev-layout-command-sidebar-window))
                (source (gdev-command-sidebar--source-window (selected-frame))))
      (gdev-command-sidebar--update window source))))

(defun gdev-command-sidebar--close-tab (tab last-tab)
  "Rilascia il buffer Comandi di TAB se lo spazio viene chiuso."
  (unless last-tab
    (when-let* ((buffer (gdev-workspace-state-read 'gdev-command-sidebar-buffer tab))
                ((buffer-live-p buffer)))
      (when-let* ((window (get-buffer-window buffer t))
                  ((window-parameter window 'gdev-layout-commands)))
        (gdev-layout--remove-side window))
      (kill-buffer buffer))))

(defun gdev-command-sidebar--discard-frame (frame)
  "Rilascia i buffer Comandi degli spazi di FRAME."
  (dolist (tab (gdev-workspace-state-tabs frame))
    (gdev-command-sidebar--close-tab tab nil)))

(defun gdev-command-sidebar-install ()
  "Collega Comandi a tastiera, tema e spazi di lavoro."
  (add-hook 'post-command-hook #'gdev-command-sidebar--after-command)
  (add-hook 'gdev-ui-after-theme-hook #'gdev-command-sidebar-refresh)
  (add-hook 'gdev-tool-actions-change-hook #'gdev-command-sidebar-refresh)
  (add-hook 'delete-frame-functions #'gdev-command-sidebar--discard-frame)
  (add-hook 'tab-bar-tab-pre-close-functions #'gdev-command-sidebar--close-tab))

(provide 'gdev-command-sidebar)
;;; gdev-command-sidebar.el ends here
