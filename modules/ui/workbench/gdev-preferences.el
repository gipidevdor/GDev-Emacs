;;; gdev-preferences.el --- Preferenze e scorciatoie del Workbench -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Raccoglie le opzioni frequenti e usa Customize per salvare le preferenze
;; personali. Le opzioni dei documenti si applicano per progetto o sessione.

;;; Code:

(require 'button)
(require 'gdev-scoped-options)
(require 'wid-edit)
(require 'gdev-layout)
(require 'gdev-menu)
(require 'gdev-lib)
(require 'gdev-workspace-state)

(declare-function gdev-modules-edit-selection "gdev-modules")
(declare-function gdev-workspace-directory "gdev-workspace-roots")
(declare-function gdev-open-private-config "gdev-commands" ())

(defconst gdev-preferences--options
  '((fill-column "Colonna di margine" integer)
    (tab-width "Larghezza della tabulazione" integer)
    (indent-tabs-mode "Rientra con tabulazioni" boolean)
    (gdev-sidebar-width "Larghezza della vista laterale")
    (gdev-layout-focus-columns "Larghezza in modalità concentrazione")
    (gdev-launch-profiles "Profili di esecuzione, compilazione e debug")))

(defcustom gdev-preferences-keybindings nil
  "Scorciatoie globali personali, da descrizione del tasto a comando."
  :type '(alist :key-type string :value-type function)
  :group 'gdev)

(defvar gdev-preferences--base-bindings (make-hash-table :test #'equal))
(defvar-local gdev-preferences--source nil)
(defvar-local gdev-preferences--project nil)
(defvar-local gdev-preferences--filter "")
(defvar-local gdev-preferences--scope 'personal)

(define-derived-mode gdev-preferences-mode special-mode "Preferenze"
  "Preferenze personali, di progetto e scorciatoie del Workbench."
  (gdev-ui-view-setup 'document)
  (visual-line-mode 1)
  (gdev-layout-mark-document))

(defun gdev-preferences--button (label command &optional id)
  (insert-text-button label 'type 'gdev-ui-action 'action (lambda (_) (funcall command))
                      'gdev-preferences-entry (or id label)))

(defun gdev-preferences--root ()
  (if-let* ((file (or buffer-file-truename buffer-file-name)))
      (or (and (fboundp 'gdev-workspace-roots)
               (gdev-workspace-root-for file (gdev-workspace-roots)))
          (gdev-project-root (file-name-directory file)))
    (or (and (fboundp 'gdev-workspace-directory) (gdev-workspace-directory))
        (gdev-project-root))))

(defun gdev-preferences-open (&optional scope)
  "Apri le preferenze nel gruppo editor attivo, eventualmente in SCOPE."
  (interactive)
  (let* ((editor (gdev-layout-editor))
         (source (window-buffer editor))
         (buffer (gdev-workspace-state-get 'gdev-preferences-buffer))
         (root (unless (eq source buffer)
                 (with-current-buffer source (gdev-preferences--root)))))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer "*Preferenze GDev*"))
      (gdev-workspace-state-set 'gdev-preferences-buffer buffer))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-preferences-mode) (gdev-preferences-mode))
      (when root
        (setq gdev-preferences--project root gdev-preferences--source source
              default-directory root))
      (when scope (setq gdev-preferences--scope scope))
      (gdev-preferences--render))
    (select-window editor)
    (switch-to-buffer buffer)))

(defun gdev-preferences-open-shortcuts ()
  "Apri il catalogo delle scorciatoie nel gruppo editor attivo."
  (interactive)
  (gdev-preferences-open 'keys))

(defun gdev-preferences-open-appearance ()
  "Apri le scelte di aspetto dalle Preferenze o dal cruscotto."
  (interactive)
  (gdev-preferences-open 'appearance))

(defun gdev-preferences--appearance ()
  "Mostra le scelte di tema e le impostazioni tipografiche."
  (insert (propertize "Tema" 'face 'gdev-ui-view-heading) "\n")
  (let ((choice (if (and gdev-macos-p gdev-follow-system-appearance) 'system gdev-ui--appearance)))
    (dolist (entry '((system . "Come il sistema") (light . "Chiaro") (dark . "Scuro")))
      (let ((value (car entry)))
        (when (or gdev-macos-p (not (eq value 'system)))
          (insert-text-button (cdr entry) 'type 'gdev-ui-action
                              'face (if (eq value choice) 'gdev-ui-action-primary 'gdev-ui-action)
                              'gdev-preferences-entry value
                              'action (lambda (_)
                                        (gdev-ui-set-appearance value t)
                                        (gdev-preferences--render)))
          (insert "   ")))))
  (insert "\n\n" (propertize "Caratteri" 'face 'gdev-ui-view-heading) "\n")
  (dolist (option '((gdev-font-height . "Dimensione del testo nell’editor")
                    (gdev-font-families . "Caratteri dell’editor")))
    (let ((symbol (car option)))
      (gdev-preferences--button (cdr option) (lambda () (customize-option symbol)) symbol)
      (insert "\n"))))

(defun gdev-preferences-filter ()
  "Filtra le opzioni o le scorciatoie mostrate."
  (interactive)
  (unless (derived-mode-p 'gdev-preferences-mode) (user-error "Apri prima le Preferenze"))
  (setq gdev-preferences--filter (read-string "Filtra: " gdev-preferences--filter))
  (gdev-preferences--render))

(defun gdev-preferences--matching-p (&rest fields)
  (let ((case-fold-search t)
        (text (string-join (delq nil fields) " ")))
    (seq-every-p (lambda (word) (string-match-p (regexp-quote word) text))
                 (split-string gdev-preferences--filter nil t))))

(defun gdev-preferences--commands (source)
  "Restituisci il catalogo dei menu nel contesto del documento SOURCE."
  (with-current-buffer (if (buffer-live-p source) source (current-buffer))
    (seq-filter (lambda (entry) (symbolp (cdr entry))) (gdev-menu-command-items t))))

(defun gdev-preferences--command-label (command catalog)
  (or (car (rassq command catalog))
      (when (and command (symbolp command))
        (when-let* ((definition (indirect-function command)))
          (car (seq-find (lambda (entry) (eq (indirect-function (cdr entry)) definition)) catalog))))
      (if (and command (symbolp command)) (gdev-menu--command-label command) "Comando della vista")))

(defun gdev-preferences--render-keys ()
  "Mostra i comandi e i tasti effettivi nel documento di origine."
  (let* ((source gdev-preferences--source)
         (catalog (gdev-preferences--commands source))
         (personal (seq-group-by #'cdr gdev-preferences-keybindings))
         (entries (append catalog
                          (cl-loop for (command . _) in personal
                                   unless (rassq command catalog)
                                   collect (cons (gdev-preferences--command-label command catalog) command))))
         found)
    (gdev-preferences--button "Assegna scorciatoia…" #'gdev-preferences-edit-shortcut)
    (insert "\n\n")
    (dolist (entry entries)
      (let* ((command (cdr entry))
             (label (car entry))
             (overrides (mapcar #'car (alist-get command personal)))
             (override-labels (mapcar (lambda (sequence)
                                        (if (and (stringp sequence) (key-valid-p sequence))
                                            (gdev-menu-key-label (kbd sequence)) (format "%s" sequence)))
                                      overrides))
             (key (unless overrides
                    (with-current-buffer (if (buffer-live-p source) source (current-buffer))
                      (when-let* (((commandp command))
                                  (binding (where-is-internal command nil t))
                                  ((eq (key-binding binding) command)))
                        binding))))
             (key-label (and key (gdev-menu-key-label key))))
        (when (apply #'gdev-preferences--matching-p label (and (symbolp command) (symbol-name command))
                     key-label (and key (key-description key))
                     (append override-labels (seq-filter #'stringp overrides)))
          (setq found t)
          (if (commandp command)
              (gdev-preferences--button label (lambda () (gdev-preferences-edit-shortcut command)) command)
            (insert label))
          (when key-label (insert "  " (propertize key-label 'face 'gdev-ui-secondary)))
          (cl-loop for sequence in overrides for key-name in override-labels
                   do (insert "  " (propertize key-name 'face 'gdev-ui-secondary) " ")
                   do (let ((shortcut sequence))
                        (gdev-preferences--button "Ripristina" (lambda () (gdev-preferences-reset-shortcut shortcut))
                                                  (cons 'reset shortcut))))
          (insert "\n"))))
    (unless found (insert (propertize "Nessuna scorciatoia corrispondente" 'face 'gdev-ui-secondary) "\n"))))

(defun gdev-preferences--render ()
  (let ((inhibit-read-only t)
        (position (point))
        (selected (get-text-property (point) 'gdev-preferences-entry)))
    (erase-buffer)
    (insert (propertize "Preferenze" 'face 'gdev-ui-view-title) "\n\n")
    (dolist (entry '((personal . "Personali") (appearance . "Aspetto")
                     (project . "Progetto") (project-type . "Tipo di progetto")
                     (session . "Sessione") (keys . "Scorciatoie")))
      (if (eq (car entry) gdev-preferences--scope)
          (insert (propertize (cdr entry) 'face 'gdev-ui-action-primary))
        (gdev-preferences--button
         (cdr entry) (lambda () (setq gdev-preferences--scope (car entry))
                       (gdev-preferences--render))))
      (insert "   "))
    (insert "\n")
    (unless (eq gdev-preferences--scope 'appearance)
      (gdev-preferences--button "Cerca…" #'gdev-preferences-filter)
      (unless (string-empty-p gdev-preferences--filter)
        (insert "  " (propertize gdev-preferences--filter 'face 'gdev-ui-secondary)))
      (insert "\n"))
    (insert "\n")
    (pcase gdev-preferences--scope
      ('appearance (gdev-preferences--appearance))
      ('keys (gdev-preferences--render-keys))
      (_
       (when (eq gdev-preferences--scope 'project)
         (insert (propertize (abbreviate-file-name gdev-preferences--project) 'face 'gdev-ui-secondary) "\n\n"))
       (let* ((personal (eq gdev-preferences--scope 'personal))
              (kind (and (eq gdev-preferences--scope 'project-type)
                         (gdev-scoped-options-project-type gdev-preferences--project)))
              (saved (pcase gdev-preferences--scope
                       ('project (gdev-state-db-entries "preferenze_progetto" (gdev-scoped-options-project-ref gdev-preferences--project)))
                       ('project-type (gdev-state-db-entries "preferenze_tipo_progetto" kind))
                       ('session (gdev-scoped-options-session))))
              (options (append gdev-preferences--options
                               (cl-loop for (name . _) in saved for var = (intern name)
                                        unless (assq var gdev-preferences--options)
                                        collect (list var name)))))
         (when kind
           (insert (propertize (pcase kind ("gdev-article" "Articolo") ("gdev-latex" "LaTeX")
                                      (_ (capitalize kind))) 'face 'gdev-ui-secondary) "\n\n"))
         (gdev-preferences--button
          "Scegli impostazione…"
          (lambda ()
            (let ((option (gdev-scoped-options-choose personal)))
              (if personal (customize-option option)
                (gdev-preferences--edit-project option nil)))))
         (insert "\n")
         (dolist (option options)
           (pcase-let ((`(,symbol ,label . ,type) option))
             (when (and (boundp symbol) (or personal (gdev-scoped-options-local-p symbol))
                        (gdev-preferences--matching-p label (symbol-name symbol)))
               (gdev-preferences--button
                label (lambda () (if personal (customize-option symbol)
                                   (gdev-preferences--edit-project symbol (car type)))) symbol)
               (when-let* ((entry (assoc (symbol-name symbol) saved)))
                 (insert "  " (propertize (format "%S" (cdr entry)) 'face 'gdev-ui-secondary) "  ")
                 (gdev-preferences--button
                  "Ripristina" (lambda ()
                                 (gdev-scoped-options-set gdev-preferences--scope gdev-preferences--project symbol nil t)
                                 (gdev-preferences--render)) (cons 'reset symbol)))
               (insert "\n")))))
       (when (eq gdev-preferences--scope 'personal)
         (insert "\n")
         (gdev-preferences--button "Tutte le opzioni di Emacs…" #'customize-browse)
         (insert "\n")
         (gdev-preferences--button "Moduli del profilo…" #'gdev-modules-edit-selection)
         (insert "\n")
         (gdev-preferences--button "Apri configurazione privata…" #'gdev-open-private-config))))
    (let ((button (and selected (next-button (point-min) t))))
      (while (and button (not (equal selected (button-get button 'gdev-preferences-entry))))
        (setq button (next-button (button-end button))))
      (goto-char (if button (button-start button) (min position (point-max)))))
    ;; Il testo ridisegnato non è una modifica da salvare: la scheda non
    ;; mostra modifiche e la sessione non lo conserva come bozza.
    (set-buffer-modified-p nil)))

(defun gdev-preferences--edit-project (symbol type)
  (let* ((source (if (buffer-live-p gdev-preferences--source) gdev-preferences--source (current-buffer)))
         (current (buffer-local-value symbol source))
         (value (pcase type
                  ('boolean (equal (completing-read "Valore: " '("Sì" "No") nil t) "Sì"))
                  ('integer (read-number "Valore: " current))
                  (_ (read--expression "Valore Lisp: " (gdev-state-db--print current))))))
    (when (and (eq type 'integer) (not (and (integerp value) (> value 0))))
      (user-error "Inserisci un numero intero positivo"))
    (gdev-scoped-options-set gdev-preferences--scope gdev-preferences--project symbol value)
    (when (buffer-live-p gdev-preferences--source)
      (with-current-buffer source
        (gdev-scoped-options-apply (unless buffer-file-name default-directory))))
    (gdev-preferences--render)))

(defun gdev-preferences--global-entry (sequence)
  "Leggi l'associazione originale del tasto SEQUENCE, compresa l'eventuale
etichetta."
  (let* ((keys (kbd sequence))
         (last (1- (length keys)))
         (global (current-global-map))
         (owner (if (zerop last) global (lookup-key global (substring keys 0 last))))
         (event (aref keys last)))
    (when (keymapp owner)
      (catch 'binding
        (map-keymap (lambda (key binding) (when (equal event key) (throw 'binding binding))) owner)
        (lookup-key global keys)))))

(defun gdev-preferences-apply-shortcuts ()
  "Applica le scorciatoie personali dopo aver caricato le impostazioni."
  (dolist (binding gdev-preferences-keybindings)
    (let ((sequence (car binding))
          (command (cdr binding)))
      (when (commandp command)
        (condition-case problem
            (let* ((saved (gethash sequence gdev-preferences--base-bindings))
                   (original (if (and saved (eq (cadr saved) (keymap-lookup (current-global-map) sequence nil t)))
                                 (car saved) (gdev-preferences--global-entry sequence))))
              (keymap-global-set sequence command)
              (puthash sequence (list original command) gdev-preferences--base-bindings))
          (error (display-warning 'gdev (error-message-string problem))))))))

(defun gdev-preferences-edit-shortcut (&optional command)
  "Assegna una scorciatoia globale a COMMAND, chiedendo conferma sui conflitti."
  (interactive)
  (let* ((source (if (derived-mode-p 'gdev-preferences-mode) gdev-preferences--source (current-buffer)))
         (catalog (gdev-preferences--commands source))
         (command (or command
                      (let ((choice (completing-read "Comando: " catalog nil nil)))
                        (or (cdr (assoc choice catalog)) (intern-soft choice)))))
         (key (if (commandp command) (read-key-sequence-vector "Premi la scorciatoia: ")
                (user-error "Scegli un comando disponibile")))
         (sequence (key-description key))
         (global (lookup-key (current-global-map) key))
         (local (and (buffer-live-p source) (with-current-buffer source (key-binding key)))))
    (when (or (equal sequence "") (equal sequence "C-g")
              (seq-some (lambda (event) (consp event)) key)
              (numberp global) (keymapp global))
      (user-error "Scegli una sequenza di tasti che non modifica un prefisso"))
    (unless (or (null global) (eq global command)
                (yes-or-no-p (format "%s è assegnata a «%s». Sostituire? "
                                     (gdev-menu-key-label key) (gdev-preferences--command-label global catalog))))
      (user-error "Scorciatoia conservata"))
    (unless (or (null local) (memq local (list global command))
                (yes-or-no-p (format "%s richiama «%s» nella vista di origine. Salvare il tasto globale? "
                                     (gdev-menu-key-label key) (gdev-preferences--command-label local catalog))))
      (user-error "Scorciatoia conservata"))
    (customize-save-variable 'gdev-preferences-keybindings
                             (cons (cons sequence command) (assoc-delete-all sequence gdev-preferences-keybindings)))
    (gdev-preferences-apply-shortcuts)
    (when (derived-mode-p 'gdev-preferences-mode) (gdev-preferences--render))))

(defun gdev-preferences-reset-shortcut (sequence)
  "Rimuovi l'assegnazione personale di SEQUENCE."
  (customize-save-variable 'gdev-preferences-keybindings
                           (assoc-delete-all sequence gdev-preferences-keybindings))
  (when-let* ((base (gethash sequence gdev-preferences--base-bindings)))
    (when (eq (keymap-lookup (current-global-map) sequence nil t) (cadr base))
      (keymap-global-set sequence (car base)))
    (remhash sequence gdev-preferences--base-bindings))
  (gdev-preferences--render))

(keymap-set gdev-preferences-mode-map "s" #'gdev-preferences-filter)
(keymap-set gdev-preferences-mode-map "k" #'gdev-preferences-edit-shortcut)
(keymap-set gdev-preferences-mode-map "TAB" #'forward-button)
(keymap-set gdev-preferences-mode-map "<backtab>" #'backward-button)

(provide 'gdev-preferences)
;;; gdev-preferences.el ends here
