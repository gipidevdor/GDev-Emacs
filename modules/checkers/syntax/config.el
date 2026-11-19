;;; config.el --- :checkers syntax: segnalazioni mentre scrivi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Flymake, incluso in Emacs, mostra i problemi trovati dal server di
;; linguaggio o dai controlli locali: ShellCheck,
;; perl -c, Perl::Critic, il compilatore in codice intermedio.
;;
;;   C-c ! n / p    problema successivo / precedente (poi n, p ripetono)
;;   C-c ! l        tutti i problemi dell'area di testo, filtrabili
;;   C-c ! P / ⇧⌘M  pannello dei problemi del progetto
;;   C-c t d        attiva/disattiva le segnalazioni a fine riga

;;; Code:

(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-commands)

(defvar-local gdev-checkers--elisp-run nil
  "Identità della compilazione Lisp da cui Flymake attende risposte.")

(defun gdev-checkers--trusted-elisp-compile (backend report-fn &rest args)
  "Esegui BACKEND sui contenuti autorizzati o segnala un esito vuoto a REPORT-FN."
  ;; Una compilazione precedente può terminare dopo questo controllo.
  (setq gdev-checkers--elisp-run nil)
  (if (trusted-content-p)
      (let ((source (current-buffer))
            (run (make-symbol "compilazione-lisp")))
        (setq gdev-checkers--elisp-run run)
        (apply backend
               (lambda (&rest result)
                 (when (and (buffer-live-p source)
                            (eq run (buffer-local-value 'gdev-checkers--elisp-run source)))
                   (apply report-fn result)))
               args))
    (funcall report-fn nil)))

(with-eval-after-load 'elisp-mode
  (advice-add 'elisp-flymake-byte-compile :around #'gdev-checkers--trusted-elisp-compile)
  ;; Flymake recente verifica la fiducia prima di invocare il backend.
  ;; Checkdoc legge il testo; il compilatore è protetto dalla guardia sopra.
  (put 'elisp-flymake-checkdoc 'flymake-always-safe t)
  (put 'elisp-flymake-byte-compile 'flymake-always-safe t))

(use-package flymake
  :ensure nil
  :hook ((emacs-lisp-mode sh-base-mode) . flymake-mode)
  :custom
  (flymake-no-changes-timeout 0.4)
  ;; Problemi alla fine della riga interessata, solo la prima riga del testo.
  (flymake-show-diagnostics-at-end-of-line 'short)
  (flymake-mode-line-lighter "!"))

(defvar-keymap gdev-checkers-repeat-map
  :doc "Dopo C-c ! n o C-c ! p, continua a premere n e p."
  :repeat t
  "n" #'gdev-checkers-next
  "p" #'gdev-checkers-previous)

(defun gdev-checkers-toggle-inline ()
  "Mostra o nasconde le segnalazioni alla fine delle loro righe."
  (interactive)
  (setq flymake-show-diagnostics-at-end-of-line
        (if flymake-show-diagnostics-at-end-of-line nil 'short))
  (when (bound-and-true-p flymake-mode) (flymake-start))
  (message "Segnalazioni a fine riga %s"
           (if flymake-show-diagnostics-at-end-of-line "attivate" "disattivate")))
(defvar flymake-show-diagnostics-at-end-of-line)
(declare-function flymake-start "flymake")

(gdev-set-popup-rule
 '(derived-mode . (flymake-diagnostics-buffer-mode flymake-project-diagnostics-mode))
 :select t)

(declare-function flymake-show-buffer-diagnostics "flymake")
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake--diagnostics-buffer-name "flymake" ())
(declare-function flymake-diagnostics-buffer-mode "flymake" ())
(defvar flymake--diagnostics-buffer-source)
(declare-function flymake-show-project-diagnostics "flymake")
(declare-function flymake-goto-next-error "flymake")
(declare-function flymake-goto-prev-error "flymake")
(declare-function flymake-diagnostic-type "flymake" (diagnostic))
(declare-function flymake-diagnostic-text "flymake" (diagnostic &optional part))
(declare-function flymake--lookup-type-property "flymake" (type property &optional default))
(defvar flymake-indicator-type)
(defvar flymake-fringe-indicator-position)
(declare-function tabulated-list-init-header "tabulated-list")
(declare-function tabulated-list-get-id "tabulated-list")
(defvar tabulated-list-format)
(defvar tabulated-list-entries)
(defvar tabulated-list-sort-key)
(declare-function warning-numeric-level "warnings" (level))

(defvar-local gdev-checkers-errors-only nil
  "Quando non nil, in questa vista Problemi compaiono solo gli errori.")
(put 'gdev-checkers-errors-only 'permanent-local t)
(defvar-local gdev-checkers--entries-function nil
  "Fornitore delle righe nelle versioni di Flymake con raccolta differita.")

(defconst gdev-checkers--columns
  '(("Line" . "Riga") ("Col" . "Col.") ("Type" . "Tipo") ("Backend" . "Origine")
    ("Origin" . "Origine") ("Code" . "Codice") ("Message" . "Segnalazione"))
  "Etichette delle colonne native di Flymake.")

(defun gdev-checkers--document-panel-name ()
  "Restituisci il nome italiano del pannello per il documento corrente."
  (format "*Problemi del documento · %s*" (buffer-name)))

(defun gdev-checkers--project-panel-buffer (root)
  "Restituisci il pannello Problemi del progetto ROOT."
  (get-buffer-create (format "*Problemi del progetto · %s*" (abbreviate-file-name root))))

(defun gdev-checkers--panel-columns ()
  "Aggiorna filtro, etichette e stato vuoto dopo la raccolta delle segnalazioni."
  (when (functionp tabulated-list-entries)
    (setq gdev-checkers--entries-function tabulated-list-entries))
  (when gdev-checkers--entries-function
    (setq tabulated-list-entries (funcall gdev-checkers--entries-function)))
  (when gdev-checkers-errors-only
    (let ((minimum (warning-numeric-level :error)))
      (setq tabulated-list-entries
            (seq-filter (lambda (row) (>= (plist-get (car row) :severity) minimum))
                        tabulated-list-entries))))
  (setq mode-name (if gdev-checkers-errors-only "Problemi · Errori" "Problemi"))
  (if (null tabulated-list-entries)
      (setq header-line-format (if gdev-checkers-errors-only
                                   "  Nessun errore disponibile"
                                 "  Nessuna segnalazione disponibile"))
    (setq tabulated-list-format
          (vconcat
           (mapcar (lambda (column)
                     (let ((name (alist-get (car column) gdev-checkers--columns nil nil #'equal)))
                       (if name
                           (cons name (cons (max (string-width name) (cadr column)) (cddr column)))
                         column)))
                   tabulated-list-format)))
    (when-let* ((sort (car tabulated-list-sort-key))
                (name (alist-get sort gdev-checkers--columns nil nil #'equal)))
      (setq tabulated-list-sort-key (cons name (cdr tabulated-list-sort-key))))
    (tabulated-list-init-header)))

(defun gdev-checkers--panel-mode ()
  "Collega il pannello nativo di Flymake al workbench."
  (setq mode-name "Problemi")
  (add-hook 'tabulated-list-revert-hook #'gdev-checkers--panel-columns nil t))

(add-hook 'flymake-diagnostics-buffer-mode-hook #'gdev-checkers--panel-mode)
(add-hook 'flymake-project-diagnostics-mode-hook #'gdev-checkers--panel-mode)

(defun gdev-checkers--margin-tooltip (display tooltip)
  "Aggiungi TOOLTIP alla stringa del margine in DISPLAY."
  (pcase display
    (`((margin ,_) ,(and glyph (pred stringp)))
     (let ((help (pcase (get-text-property 0 'help-echo glyph)
                   ('nil tooltip)
                   ("Open Flymake diagnostics"
                    (concat (truncate-string-to-width tooltip 60 nil nil "…")
                            "\nApri Problemi")))))
       (if help (list (car display) (propertize glyph 'help-echo help)) display)))
    ;; In modalità auto Flymake sceglie la rappresentazione durante il ridisegno.
    (`(when ,condition . ,spec)
     `(when ,condition . ,(gdev-checkers--margin-tooltip spec tooltip)))
    ((and (pred proper-list-p) (guard (consp (car display))))
     (mapcar (lambda (spec) (gdev-checkers--margin-tooltip spec tooltip)) display))
    (_ display)))

(defun gdev-checkers--indicator-tooltip (overlay)
  "Accompagna l'indicatore di OVERLAY con il livello e il messaggio."
  (when-let* (((overlayp overlay))
              (diagnostic (overlay-get overlay 'flymake-diagnostic))
              (indicator (overlay-get overlay 'before-string))
              ((stringp indicator))
              (display (get-text-property 0 'display indicator)))
    (let* ((type (or (flymake-diagnostic-type diagnostic) :error))
           (label (flymake--lookup-type-property type 'flymake-type-name "Segnalazione"))
           (text (string-trim-left (flymake-diagnostic-text diagnostic)))
           (line (string-trim-right (substring text 0 (string-search "\n" text))))
           (tooltip (substring-no-properties
                     (truncate-string-to-width (concat label " · " line) 75 nil nil "…"))))
      (when (memq flymake-indicator-type '(auto fringes))
        (when-let* ((property (pcase flymake-fringe-indicator-position
                               ('left-fringe 'left-fringe-help)
                               ('right-fringe 'right-fringe-help)))
                    ((not (overlay-get overlay property))))
          (overlay-put overlay property tooltip)))
      (when (memq flymake-indicator-type '(auto margins))
        (overlay-put overlay 'before-string
                     (propertize indicator 'display
                                 (gdev-checkers--margin-tooltip display tooltip))))))
  overlay)

(with-eval-after-load 'flymake
  (advice-add 'flymake--diagnostics-buffer-name :override #'gdev-checkers--document-panel-name)
  (advice-add 'flymake--project-diagnostics-buffer :override #'gdev-checkers--project-panel-buffer)
  (dolist (type '((flymake-error . "Errore") (flymake-warning . "Avviso") (flymake-note . "Nota")))
    (put (car type) 'flymake-type-name (cdr type)))
  (advice-add 'flymake--highlight-line :filter-return #'gdev-checkers--indicator-tooltip)
  (keymap-set flymake-diagnostics-buffer-mode-map "RET"
              (if (fboundp 'flymake-goto-diagnostic) 'flymake-goto-diagnostic 'flymake-show-diagnostic))
  (keymap-set flymake-diagnostics-buffer-mode-map "e" #'gdev-checkers-toggle-errors)
  (keymap-set flymake-diagnostics-buffer-mode-map "n" #'gdev-checkers-next)
  (keymap-set flymake-diagnostics-buffer-mode-map "p" #'gdev-checkers-previous))

(defun gdev-checkers-panel-p (&optional window)
  "Restituisce non nil se WINDOW mostra un elenco Flymake."
  (with-current-buffer (window-buffer window)
    (derived-mode-p 'flymake-diagnostics-buffer-mode 'flymake-project-diagnostics-mode)))

(defun gdev-checkers-toggle-errors ()
  "Alterna tutti i livelli e i soli errori nel pannello corrente."
  (interactive)
  (unless (gdev-checkers-panel-p)
    (user-error "Apri il pannello Problemi per filtrare le segnalazioni"))
  (setq gdev-checkers-errors-only (not gdev-checkers-errors-only))
  (revert-buffer)
  (message "%s" (if gdev-checkers-errors-only "Mostro solo gli errori" "Mostro tutte le segnalazioni")))

(defun gdev-checkers--document-problems ()
  "Mostra l'elenco nativo anche quando non rimangono segnalazioni."
  (if (flymake-diagnostics)
      (flymake-show-buffer-diagnostics)
    ;; Le versioni recenti rifiutano una lista vuota. Il Workbench conserva
    ;; la stessa vista nativa per mostrare che il documento non ha problemi.
    (let ((source (current-buffer))
          (buffer (get-buffer-create (flymake--diagnostics-buffer-name))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'flymake-diagnostics-buffer-mode)
          (flymake-diagnostics-buffer-mode))
        (setq-local flymake--diagnostics-buffer-source source)
        (revert-buffer))
      (display-buffer buffer
                      '((display-buffer-reuse-window display-buffer-below-selected)
                        (window-height . (lambda (window) (fit-window-to-buffer window 10))))))))

(defun gdev-checkers-problems (&optional scope)
  "Mostra le segnalazioni del documento attivo o del suo progetto.
SCOPE può essere `document' o `project'.  Per impostazione predefinita
mostra le segnalazioni del progetto, quando presente."
  (interactive)
  (require 'flymake)
  (gdev-call-with-editor
   (lambda ()
     (if (and (not (eq scope 'document)) (project-current))
         (flymake-show-project-diagnostics)
       (when (eq scope 'project)
         (user-error "Il documento attivo è fuori da un progetto"))
       (unless (bound-and-true-p flymake-mode)
         (user-error "Il controllo sintattico è disattivato nel documento attivo"))
       (gdev-checkers--document-problems)))))

(defun gdev-checkers-document-problems ()
  "Apri il pannello Problemi per il documento attivo."
  (interactive)
  (gdev-checkers-problems 'document))

(defun gdev-checkers-project-problems ()
  "Apri il pannello Problemi per il progetto del documento attivo."
  (interactive)
  (gdev-checkers-problems 'project))

(defun gdev-checkers-toggle-problems ()
  "Mostra o nascondi il pannello Problemi nello spazio di lavoro."
  (interactive)
  (if-let* ((panel (gdev-layout--panel))
            ((gdev-checkers-panel-p panel)))
      (delete-window panel)
    (gdev-checkers-problems)))

(defun gdev-checkers--move (command direction prefix)
  "Naviga nel pannello in DIRECTION, o usa COMMAND con PREFIX nell'editor."
  (if (gdev-checkers-panel-p)
      (let ((origin (point)))
        (forward-line (* direction (prefix-numeric-value prefix)))
        (unless (tabulated-list-get-id)
          (goto-char origin)
          (user-error "Nessun'altra segnalazione in questa direzione")))
    (require 'flymake)
    (gdev-call-with-editor
     (lambda ()
       (unless (bound-and-true-p flymake-mode)
         (user-error "Il controllo sintattico è disattivato nel documento attivo"))
       (let ((current-prefix-arg prefix))
         (call-interactively command))))))

(defun gdev-checkers-next (&optional prefix)
  "Vai alla segnalazione successiva, con il PREFIX di Flymake nell'editor."
  (interactive "P")
  (gdev-checkers--move #'flymake-goto-next-error 1 prefix))

(defun gdev-checkers-previous (&optional prefix)
  "Vai alla segnalazione precedente, con il PREFIX di Flymake nell'editor."
  (interactive "P")
  (gdev-checkers--move #'flymake-goto-prev-error -1 prefix))

(dolist (command '(gdev-checkers-next gdev-checkers-previous))
  (put command 'repeat-map 'gdev-checkers-repeat-map))

;;; config.el ends here
