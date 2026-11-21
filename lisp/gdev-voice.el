;;; gdev-voice.el --- Voce GDev: azioni comuni e contesto del documento -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il testo scritto e quello riconosciuto attraversano la stessa grammatica.
;; Le operazioni dell'IDE restano nei loro moduli; qui si risolvono soltanto
;; intenti, testo letterale e identità del documento e dello spazio d'origine.
;;; Code:
(require 'gdev-lib)
(require 'gdev-command-context)
(require 'gdev-workspace-state)
(require 'gdev-voice-italian)

(declare-function gdev-layout-editor "../modules/ui/workbench/gdev-layout" (&optional frame))
(declare-function gdev-editor-document "gdev-commands" ())
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-open-folder "gdev-commands" (directory))
(declare-function gdev-menu-command-items "../modules/ui/workbench/gdev-menu" (&optional include-disabled))
(declare-function earwig-part-range "earwig-edit" (spec))
(declare-function gdev-bundled-package-directory "../early-init" (name))
(autoload 'consult-line "consult" nil t)

(defgroup gdev-voice nil
  "Comandi, dettatura e lettura in italiano."
  :group 'gdev)

(defcustom gdev-voice-vocabulary '("GDev" "Emacs" "Elisp" "Makefile" "CMake" "Python" "Perl" "C++")
  "Lessico tecnico suggerito al riconoscitore locale.
Puoi aggiungere nomi del tuo progetto. Il riconoscitore usa sempre l'italiano."
  :type '(repeat string) :group 'gdev-voice)

(defcustom gdev-voice-corrections nil
  "Correzioni personali del riconoscimento, come coppie testo errato e corretto.
Si applicano a parole intere, anche composte, senza alterare i comandi scritti."
  :type '(alist :key-type string :value-type string) :group 'gdev-voice)

(defun gdev-voice-learn-correction (wrong right)
  "Memorizza la correzione vocale di WRONG in RIGHT nelle preferenze GDev."
  (interactive
   (let* ((document (gdev-editor-document))
          (selected (and document (with-current-buffer document
                                   (when (use-region-p)
                                     (buffer-substring-no-properties (region-beginning) (region-end))))))
          (wrong (read-string "Testo riconosciuto da correggere: " selected)))
     (list wrong (read-string (format "Correzione di «%s»: " wrong)))))
  (when (string-empty-p (string-trim wrong)) (user-error "Indica il testo riconosciuto da correggere"))
  (let ((corrections (copy-tree gdev-voice-corrections)))
    (setf (alist-get wrong corrections nil nil #'string-equal-ignore-case) right)
    (customize-save-variable 'gdev-voice-corrections corrections))
  (message "Correzione vocale memorizzata"))

(defcustom gdev-voice-command-aliases
  '(("salva il file" . "salva") ("salva documento" . "salva")
    ("compila il progetto" . "compila") ("compila progetto" . "compila")
    ("annulla ultima modifica" . "annulla") ("leggi" . "leggi testo")
    ("ferma lettura" . "interrompi voce") ("smetti di ascoltare" . "interrompi voce"))
  "Sinonimi italiani di etichette del catalogo, senza duplicare le azioni."
  :type '(alist :key-type string :value-type string) :group 'gdev-voice)

(cl-defstruct (gdev-voice-context (:constructor gdev-voice-context-create))
  frame owner window buffer)

(cl-defstruct (gdev-voice-session (:constructor gdev-voice-session-create))
  kind phase context process requests paused pending-command started error profile tick timer)

(defvar gdev-voice--session nil "Sessione applicativa corrente; una sola sorgente audio o lettura.")
(defvar gdev-voice--applying nil "Non nil durante modifiche prodotte dalla sessione vocale.")
(defvar gdev-voice-state-change-hook nil "Notifica dei cambiamenti della sessione applicativa.")
(defvar gdev-voice-command-history nil "Cronologia dei soli comandi digitati esplicitamente.")

(defun gdev-voice-context ()
  "Cattura il contesto attraverso i servizi dell'editor e dello spazio."
  (let ((window (gdev-layout-editor)))
    (gdev-voice-context-create
     :frame (selected-frame)
     :owner (and (bound-and-true-p gdev-layout-mode) (gdev-workspace-state-ensure-id))
     :window window :buffer (gdev-editor-document))))

(defun gdev-voice-context-current-p (context)
  "Verifica che CONTEXT appartenga ancora allo spazio e documento originali."
  (and context (frame-live-p (gdev-voice-context-frame context))
       (eq (selected-frame) (gdev-voice-context-frame context))
       (let ((owner (gdev-voice-context-owner context))
             (window (gdev-voice-context-window context))
             (buffer (gdev-voice-context-buffer context)))
         (and (or (null owner)
                  (equal owner (gdev-workspace-state-id (gdev-voice-context-frame context))))
              (or (null buffer)
                  (and (buffer-live-p buffer) (window-live-p window)
                       (eq (gdev-layout-editor (gdev-voice-context-frame context)) window)
                       (eq (window-buffer window) buffer)))))))

(defun gdev-voice--fork (&optional feature)
  "Carica FEATURE della copia locale di Voce GDev (originale Earwig)."
  (let ((directory (gdev-bundled-package-directory 'earwig)))
    (unless directory (user-error "Il fork Voce GDev non è nel registro dei pacchetti"))
    (setq load-path (cons directory (delete directory load-path)))
    (dolist (symbol '(earwig-part-range earwig-mode))
      ;; Un autoload è una promessa, non codice già caricato. In Emacs 30
      ;; `symbol-file' può restituirne il nome di libreria non assoluto.
      (when-let* ((file (and (fboundp symbol)
                            (not (autoloadp (symbol-function symbol)))
                            (symbol-file symbol 'defun))))
        (unless (file-in-directory-p file directory)
          (user-error "È già caricata un'altra copia di Earwig: riavvia GDev per usare il fork incluso"))))
    (let ((feature (or feature 'earwig)))
      (require feature (expand-file-name (symbol-name feature) directory)))))

(defun gdev-voice-catalog ()
  "Leggi le azioni disponibili e i loro sinonimi dal catalogo comune."
  (require 'gdev-menu)
  ;; Il primo passo di una sequenza può abilitare il successivo. La
  ;; disponibilità effettiva viene verificata di nuovo prima di eseguirlo.
  (let ((catalog (gdev-menu-command-items t)))
    (dolist (alias gdev-voice-command-aliases)
      (when-let* ((intent (gdev-voice-italian--catalog (cdr alias) catalog)))
        (push (cons (car alias) (plist-get intent :command)) catalog)))
    catalog))

(defun gdev-voice-parse (text)
  "Interpreta TEXT italiano con le azioni disponibili nel contesto reale."
  (gdev-voice-italian-parse text (gdev-voice-catalog)))

(defun gdev-voice--literal-range (text)
  "Trova l'occorrenza letterale di TEXT più vicina al punto."
  (let ((origin (point)) (case-fold-search t) before after)
    (save-excursion
      (when (search-forward text nil t) (setq after (cons (- (point) (length text)) (point))))
      (goto-char origin)
      (when (search-backward text nil t) (setq before (cons (point) (+ (point) (length text))))))
    (or (cond ((null before) after) ((null after) before)
              ((<= (- origin (cdr before)) (- (car after) origin)) before) (t after))
        (user-error "Testo non trovato nel documento: %s" text))))

(defun gdev-voice-target-range (target)
  "Risolvi TARGET nel documento, senza cambiare testo, selezione o punto."
  (pcase (plist-get target :kind)
    ('literal (gdev-voice--literal-range (plist-get target :text)))
    ('structural
     (gdev-voice--fork 'earwig-edit)
     (condition-case nil
         (or (earwig-part-range (plist-get target :spec))
             (user-error "Parte del documento non disponibile"))
       (user-error (user-error "La parte richiesta non è disponibile nel documento"))))
    (_ (user-error "Bersaglio del comando non valido"))))

(defun gdev-voice--edit (intent)
  "Applica l'intento di modifica INTENT con le primitive dell'editor."
  (let* ((range (gdev-voice-target-range (plist-get intent :target)))
         (beg (car range)) (end (cdr range)) (verb (plist-get intent :verb)))
    (pcase verb
      ("seleziona" (goto-char end) (push-mark beg t t))
      ("copia" (copy-region-as-kill beg end))
      (_
       (barf-if-buffer-read-only)
       (atomic-change-group
         (pcase verb
           ((or "cancella" "elimina") (delete-region beg end))
           ("taglia" (kill-region beg end))
           ("maiuscolo" (upcase-region beg end))
           ("minuscolo" (downcase-region beg end))
           ("iniziale maiuscola" (capitalize-region beg end))))))))

(defun gdev-voice--replace (intent)
  "Sostituisci il testo letterale dichiarato da INTENT, in un passo annullabile."
  (barf-if-buffer-read-only)
  (let ((from (plist-get intent :from)) (to (plist-get intent :to)))
    (if (plist-get intent :all)
        (save-restriction
          (widen)
          (save-excursion
            (goto-char (point-min))
            (unless (search-forward from nil t) (user-error "Testo non trovato: %s" from))
            (goto-char (point-min))
            (atomic-change-group
              (while (search-forward from nil t) (replace-match to t t)))))
      (pcase-let ((`(,beg . ,end) (gdev-voice--literal-range from)))
        (atomic-change-group (delete-region beg end) (goto-char beg) (insert to))))))

(defun gdev-voice-execute-intent (intent)
  "Esegui INTENT usando la stessa azione offerta dall'interfaccia di GDev."
  (let ((gdev-voice--applying t))
    (pcase (plist-get intent :kind)
      ('cancel (message "Comando annullato"))
      ('command
       (let ((command (plist-get intent :command)))
         (unless (memq command (mapcar #'cdr (gdev-menu-command-items)))
           (user-error "Il comando non è disponibile nel contesto attuale"))
         (call-interactively command)))
      ((or 'edit 'replace 'line 'search)
       (let ((document (or (gdev-editor-document) (user-error "Apri un documento per questo comando"))))
         (with-current-buffer document
           (pcase (plist-get intent :kind)
             ('edit (gdev-voice--edit intent))
             ('replace (gdev-voice--replace intent))
             ('line
              (let* ((line (plist-get intent :number))
                     (position (save-excursion
                                 (goto-char (point-min))
                                 (when (> (forward-line (1- line)) 0) (user-error "Il documento non contiene la riga %d" line))
                                 (point))))
                (push-mark) (goto-char position)))
             ('search (consult-line (plist-get intent :text)))))))
      ('file (gdev-open-file (expand-file-name (plist-get intent :text) (gdev-command-directory))))
      ('folder (gdev-open-folder (expand-file-name (plist-get intent :text) (gdev-command-directory))))
      (_ (user-error "Intento vocale non disponibile")))))

(defun gdev-voice-execute (text)
  "Esegui TEXT come comando italiano, scritto o riconosciuto.
La sequenza viene interpretata integralmente prima della prima modifica."
  (interactive (list nil))
  (let* ((context (gdev-voice-context))
         (text (or text (completing-read "Comando in italiano: "
                                         (mapcar #'car (gdev-voice-catalog))
                                         nil nil nil 'gdev-voice-command-history)))
         (intents (or (gdev-voice-parse text)
                      (user-error "Comando non riconosciuto o incompleto: %s" text))))
    (unless (gdev-voice-context-current-p context)
      (user-error "Il documento o lo spazio è cambiato: ripeti il comando"))
    (when (window-live-p (gdev-voice-context-window context))
      (select-window (gdev-voice-context-window context)))
    (dolist (intent intents)
      (gdev-voice-execute-intent intent)
      (undo-boundary))))

(autoload 'gdev-voice-start-dictation "gdev-voice-audio" nil t)
(autoload 'gdev-voice-start-command "gdev-voice-audio" nil t)
(autoload 'gdev-voice-read "gdev-voice-audio" nil t)
(autoload 'gdev-voice-pause "gdev-voice-audio" nil t)
(autoload 'gdev-voice-stop "gdev-voice-audio" nil t)
(autoload 'gdev-voice-select-voice "gdev-voice-audio" nil t)
(autoload 'gdev-voice-prepare "gdev-voice-audio" nil t)
(autoload 'gdev-voice-disable "gdev-voice-audio" nil t)
(autoload 'gdev-voice-open "gdev-voice-view" nil t)

(provide 'gdev-voice)
;;; gdev-voice.el ends here
