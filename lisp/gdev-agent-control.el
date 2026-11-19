;;; gdev-agent-control.el --- Pilotaggio dell'editor per agenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le azioni dal vivo `eval', `command', `keys', `open-location',
;; `buffer-read', `buffers', `layout' e `messages' permettono a un agente
;; di valutare Emacs Lisp, eseguire comandi e tasti e leggere buffer,
;; finestre e spazio di lavoro dell'istanza GDev.  `gdev-agent-interface'
;; le smista sia dalla CLI sia dal server MCP: gli argomenti arrivano
;; sempre come testo, come dalla riga di comando.
;;
;; Valutazione, comandi e tasti seguono tre regole.  Non partono mentre il
;; minibuffer o una modifica ricorsiva attendono l'utente, salvo FORCE.
;; Si interrompono dopo il tempo indicato.  Una richiesta di input durante
;; `eval' e `command' diventa un errore restituito all'agente, così
;; l'editor non resta in attesa.  Il debugger resta spento e C-g
;; nell'editor interrompe l'esecuzione.  Ogni esito riporta i messaggi
;; comparsi in *Messages* nel frattempo.

;;; Code:

(require 'cl-lib)
(require 'gdev-agent-interface)
(require 'lisp-mode)
(require 'rx)
(require 'subr-x)

(defvar gdev-workspace-state-fields)
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-layout-editor "gdev-layout" (&optional frame))
(declare-function gdev-layout-panel-window "gdev-layout" ())
(declare-function gdev-layout-left-window "gdev-layout" (&optional frame))
(declare-function gdev-layout-command-sidebar-window "gdev-layout" (&optional frame))
(declare-function gdev-layout-auxiliary-window "gdev-layout" (&optional frame))
(declare-function gdev-workspace-roots "gdev-workspace-roots" (&optional frame))
(declare-function gdev-workspace-state-get "gdev-workspace-state" (key &optional frame))
(declare-function gdev-workspace-state-tabs "gdev-workspace-state" (&optional frame))

(define-error 'gdev-agent-control-timeout "Tempo scaduto")

(defconst gdev-agent-control--value-limit 65536
  "Numero massimo di caratteri del valore stampato da `eval'.")

(defconst gdev-agent-control--message-limit 200
  "Numero massimo di righe di *Messages* riportate da un'esecuzione.")

(defconst gdev-agent-control--line-limit 2000
  "Numero massimo di caratteri di una riga di *Messages* riportata.")

(defconst gdev-agent-control--raw-byte (rx (any (#x3fff80 . #x3fffff)))
  "Caratteri che rappresentano byte non decodificati.")

;;;; Argomenti testuali

(defun gdev-agent-control--integer (text minimum maximum message)
  "Leggi da TEXT un intero tra MINIMUM e MAXIMUM, o segnala MESSAGE.
Con MAXIMUM nil l'intervallo non ha limite superiore."
  (let ((value (and (stringp text)
                    (string-match-p "\\`-?[0-9]\\{1,15\\}\\'" text)
                    (string-to-number text))))
    (unless (and (integerp value) (<= minimum value) (or (null maximum) (<= value maximum)))
      (user-error "%s" message))
    value))

(defun gdev-agent-control--seconds (text)
  "Leggi da TEXT l'attesa massima in secondi."
  (gdev-agent-control--integer text 1 300 "timeout deve essere un intero da 1 a 300 secondi"))

(defun gdev-agent-control--force (text)
  "Leggi da TEXT il valore booleano di force."
  (pcase text
    ("true" t)
    ("false" nil)
    (_ (user-error "force deve essere true o false"))))

(defun gdev-agent-control--prefix (text)
  "Converti TEXT nell'argomento prefisso grezzo di un comando."
  (cond ((equal text "") nil)
        ((equal text "-") '-)
        ((and (stringp text) (string-match-p "\\`C-u\\( C-u\\)\\{0,3\\}\\'" text))
         (list (expt 4 (/ (1+ (length text)) 4))))
        ((and (stringp text) (string-match-p "\\`-?[0-9]\\{1,9\\}\\'" text))
         (string-to-number text))
        (t (user-error "prefix deve essere vuoto, un intero, - oppure C-u ripetuto"))))

(defun gdev-agent-control--read-forms (text)
  "Leggi le forme Emacs Lisp di TEXT senza valutarle."
  (unless (and (stringp text) (not (string-blank-p text)))
    (user-error "Indica una forma Emacs Lisp"))
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (forms)
      (condition-case err
          (with-syntax-table emacs-lisp-mode-syntax-table
            (while (progn (forward-comment (point-max)) (not (eobp)))
              (push (read (current-buffer)) forms)))
        (error (user-error "La forma non è leggibile: %s" (error-message-string err))))
      (nreverse forms))))

;;;; Esecuzione protetta

(defun gdev-agent-control--user-waiting-p ()
  "Indica se il minibuffer o una modifica ricorsiva attendono l'utente."
  (or (active-minibuffer-window) (> (minibuffer-depth) 0) (> (recursion-depth) 0)))

(defun gdev-agent-control--check-idle (force)
  "Segnala un errore se l'editor attende l'utente, salvo FORCE."
  (when (and (not force) (gdev-agent-control--user-waiting-p))
    ;; Il testo resta uguale con ogni `text-quoting-style'.
    (user-error "%s" "L'editor attende una risposta nel minibuffer o in una modifica ricorsiva. Completala oppure riprova con force")))

(defun gdev-agent-control--message-lines (text count)
  "Ultime COUNT righe di TEXT, ognuna accorciata e senza byte grezzi.
Un `(message \"%S\" (buffer-string))' darebbe altrimenti una risposta di molti
megabyte, duplicata nei campi del risultato."
  (vconcat
   (mapcar (lambda (line)
             (let ((line (gdev-agent-control--text line)))
               (if (> (length line) gdev-agent-control--line-limit)
                   (concat (substring line 0 gdev-agent-control--line-limit) "…")
                 line)))
           (last (split-string text "\n" t) count))))

(defun gdev-agent-control--messages-since (marker)
  "Restituisci le righe aggiunte a *Messages* dopo MARKER e rilascialo."
  (prog1 (if-let* ((buffer (marker-buffer marker)))
             (with-current-buffer buffer
               (gdev-agent-control--message-lines
                (buffer-substring-no-properties marker (point-max))
                gdev-agent-control--message-limit))
           [])
    (set-marker marker nil)))

(defun gdev-agent-control--refuse-input (&rest _)
  "Rifiuta una lettura dalla tastiera durante un'esecuzione non interattiva."
  (signal 'inhibited-interaction nil))

;; Il nucleo dell'assicurazione (`gdev-process') legge questa variabile: ciò che un
;; agente esegue da qui conta come azione di un agente, qualunque tipo
;; d'attore dichiari.  Ferma le chiamate ingenue, non un agente che la riassegna.
(defvar gdev-process-origin)

(defun gdev-agent-control--run (seconds interactive function)
  "Chiama FUNCTION nel buffer della finestra selezionata entro SECONDS.
Senza INTERACTIVE ogni richiesta di input diventa un errore.  Restituisci
\(VALORE . MESSAGGI); in caso di errore segnala
`gdev-agent-interface-failure' con i messaggi raccolti."
  (let ((start (with-current-buffer (messages-buffer) (copy-marker (point-max))))
        (window (selected-window))
        value failure)
    (condition-case err
        (let ((gdev-process-origin 'agent)
              (debug-on-error nil)
              (debug-on-quit nil)
              (debug-on-signal nil)
              (inhibit-debugger t)
              ;; I filtri dei processi impediscono C-g: qui l'utente può
              ;; interrompere un'esecuzione troppo lunga.
              (inhibit-quit nil)
              (inhibit-interaction (not interactive)))
          (cl-letf (((symbol-function 'read-key)
                     (if interactive (symbol-function 'read-key) #'gdev-agent-control--refuse-input)))
            (setq value (with-timeout (seconds (signal 'gdev-agent-control-timeout nil))
                          (with-current-buffer (window-buffer window)
                            (funcall function))))))
      (gdev-agent-control-timeout
       (setq failure (format "Tempo scaduto dopo %d s. Rileggi lo stato dell'editor prima di riprovare"
                             seconds)))
      (inhibited-interaction
       (setq failure "L'esecuzione ha chiesto un input all'utente. Passa i valori nella forma o usa keys"))
      (quit (setq failure "Esecuzione interrotta nell'editor"))
      (error (setq failure (error-message-string err))))
    (let ((messages (gdev-agent-control--messages-since start)))
      (if failure
          (signal 'gdev-agent-interface-failure (list failure (cons 'messages messages)))
        (cons value messages)))))

(defun gdev-agent-control--print (value)
  "Stampa VALUE in forma leggibile e restituisci (TESTO . TRONCATO)."
  (let* ((print-length 200)
         (print-level 12)
         (print-circle t)
         (text (prin1-to-string value)))
    (if (> (length text) gdev-agent-control--value-limit)
        (cons (substring text 0 gdev-agent-control--value-limit) t)
      (cons text nil))))

(defun gdev-agent-control--eval (form timeout force)
  "Valuta le forme in FORM entro TIMEOUT secondi, rispettando FORCE."
  (let* ((seconds (gdev-agent-control--seconds timeout))
         (force (gdev-agent-control--force force))
         (forms (gdev-agent-control--read-forms form)))
    (gdev-agent-control--check-idle force)
    (pcase-let* ((`(,value . ,messages)
                  (gdev-agent-control--run seconds nil (lambda () (eval (macroexp-progn forms) t))))
                 (`(,text . ,truncated) (gdev-agent-control--print value)))
      `((value . ,(gdev-agent-control--text text))
        (truncated . ,(if truncated t :false))
        (messages . ,messages)))))

(defun gdev-agent-control--execute (keys &optional command prefix)
  "Esegui KEYS come una macro di tastiera, con il ciclo dei comandi.
Il tasto fittizio [gdev-agent-command] esegue COMMAND; [gdev-agent-prefix]
gli passa PREFIX come farebbe C-u."
  (let* ((map (make-sparse-keymap))
         (emulation-mode-map-alists (cons `((t . ,map)) emulation-mode-map-alists)))
    (when command
      (define-key map [gdev-agent-command] command))
    (define-key map [gdev-agent-prefix]
                (lambda ()
                  (interactive)
                  (prefix-command-preserve-state)
                  (setq prefix-arg prefix)))
    (execute-kbd-macro keys)))

(defun gdev-agent-control--command (name prefix timeout force)
  "Esegui il comando NAME con PREFIX entro TIMEOUT secondi, rispettando FORCE."
  (let* ((command (and (stringp name) (intern-soft name)))
         (prefix (gdev-agent-control--prefix prefix))
         (seconds (gdev-agent-control--seconds timeout))
         (force (gdev-agent-control--force force)))
    (unless (and command (commandp command))
      (user-error "Nessun comando interattivo chiamato %s" name))
    (gdev-agent-control--check-idle force)
    (let ((outcome (gdev-agent-control--run
                    seconds nil
                    (lambda ()
                      (gdev-agent-control--execute
                       (if prefix [gdev-agent-prefix gdev-agent-command] [gdev-agent-command])
                       command prefix)))))
      `((command . ,(symbol-name command))
        (messages . ,(cdr outcome))))))

(defun gdev-agent-control--keys (keys timeout force)
  "Premi KEYS nella finestra selezionata entro TIMEOUT secondi, rispettando FORCE."
  (let ((sequence (and (stringp keys) (not (string-blank-p keys))
                       (ignore-errors (kbd keys))))
        (seconds (gdev-agent-control--seconds timeout))
        (force (gdev-agent-control--force force)))
    (unless (and sequence (> (length sequence) 0))
      (user-error "Indica i tasti in notazione Emacs, per esempio C-x b"))
    (gdev-agent-control--check-idle force)
    ;; La macro fornisce anche le risposte ai prompt che apre: qui l'input
    ;; resta ammesso e il tempo massimo evita l'attesa oltre la macro.
    (let ((outcome (gdev-agent-control--run
                    seconds t (lambda () (gdev-agent-control--execute sequence)))))
      `((keys . ,(key-description sequence))
        (messages . ,(cdr outcome))))))

;;;; Lettura dell'editor

(defun gdev-agent-control--text (text)
  "Restituisci TEXT senza proprietà, con U+FFFD al posto dei byte grezzi."
  (let ((text (substring-no-properties text)))
    (if (string-match-p gdev-agent-control--raw-byte text)
        (replace-regexp-in-string gdev-agent-control--raw-byte "�" text t t)
      text)))

(defun gdev-agent-control--buffer (buffer &optional detail)
  "Descrivi BUFFER; con DETAIL aggiungi punto, riga, colonna e regione."
  (with-current-buffer buffer
    (let ((window (get-buffer-window buffer 'visible)))
      `((name . ,(gdev-agent-control--text (buffer-name)))
        (file . ,(or buffer-file-name :null))
        (mode . ,(symbol-name major-mode))
        (modified . ,(if (buffer-modified-p) t :false))
        (read_only . ,(if buffer-read-only t :false))
        (size . ,(buffer-size))
        (visible . ,(if window t :false))
        ,@(when detail
            (save-restriction
              (widen)
              (let ((point (if window (window-point window) (point))))
                `((point . ,(1- point))
                  (line . ,(line-number-at-pos point))
                  (column . ,(save-excursion (goto-char point) (current-column)))
                  (region . ,(if (region-active-p)
                                 `((start . ,(1- (region-beginning))) (end . ,(1- (region-end))))
                               :null))))))))))

(defun gdev-agent-control--buffer-read (name offset length)
  "Leggi LENGTH caratteri di NAME da OFFSET, con i dati del buffer."
  (let ((buffer (cond ((equal name "") (window-buffer (selected-window)))
                      ((stringp name) (get-buffer name))))
        (offset (gdev-agent-control--integer offset 0 nil "offset deve essere un intero non negativo"))
        (length (gdev-agent-control--integer length 1 65536 "length deve essere un intero da 1 a 65536")))
    (unless (buffer-live-p buffer)
      (user-error "Nessun buffer chiamato %s" name))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (when (> offset (buffer-size))
          (user-error "%s" "L'offset richiesto è fuori dal buffer"))
        (let* ((start (+ (point-min) offset))
               (end (min (point-max) (+ start length))))
          `((buffer . ,(gdev-agent-control--buffer buffer t))
            (offset . ,offset)
            (text . ,(gdev-agent-control--text (buffer-substring-no-properties start end)))
            (next_offset . ,(if (< end (point-max)) (- end (point-min)) :null))))))))

(defun gdev-agent-control--buffers ()
  "Elenca i buffer visibili all'utente, dal più recente."
  `((buffers . ,(vconcat
                 (cl-loop for buffer in (buffer-list)
                          for count from 0 below 1000
                          unless (string-prefix-p " " (buffer-name buffer))
                          collect (gdev-agent-control--buffer buffer))))))

(defun gdev-agent-control--json (value depth)
  "Converti VALUE in dati JSON, esplorando fino a DEPTH livelli."
  (cond ((null value) :null)
        ((eq value t) t)
        ((stringp value)
         (let ((text (gdev-agent-control--text value)))
           (if (> (length text) 500) (concat (substring text 0 500) "…") text)))
        ((integerp value) value)
        ((floatp value) (if (or (isnan value) (= (abs value) 1.0e+INF)) (format "%S" value) value))
        ((keywordp value) (substring (symbol-name value) 1))
        ((symbolp value) (symbol-name value))
        ((bufferp value) (if (buffer-live-p value) (buffer-name value) "buffer chiuso"))
        ((and (> depth 0) (or (vectorp value) (proper-list-p value)))
         (vconcat (mapcar (lambda (item) (gdev-agent-control--json item (1- depth)))
                          (take 50 (append value nil)))))
        ((and (> depth 0) (consp value))
         (vector (gdev-agent-control--json (car value) (1- depth))
                 (gdev-agent-control--json (cdr value) (1- depth))))
        (t (let ((text (gdev-agent-control--text (format "%S" value))))
             (if (> (length text) 200) (concat (substring text 0 200) "…") text)))))

(defun gdev-agent-control--layout ()
  "Descrivi finestre, spazi di lavoro e stato dello spazio corrente."
  (let* ((roles (cl-loop for (role . function) in '(("panel" . gdev-layout-panel-window)
                                                    ("left" . gdev-layout-left-window)
                                                    ("commands" . gdev-layout-command-sidebar-window)
                                                    ("auxiliary" . gdev-layout-auxiliary-window))
                         for window = (and (fboundp function) (funcall function))
                         when window collect (cons window role)))
         (editor (and (fboundp 'gdev-layout-editor) (gdev-layout-editor)))
         (tabs (if (fboundp 'gdev-workspace-state-tabs)
                   (gdev-workspace-state-tabs)
                 (funcall tab-bar-tabs-function))))
    `((windows
       . ,(vconcat
           (mapcar (lambda (window)
                     (let ((buffer (window-buffer window)))
                       `((buffer . ,(gdev-agent-control--text (buffer-name buffer)))
                         (file . ,(or (buffer-file-name buffer) :null))
                         (mode . ,(symbol-name (buffer-local-value 'major-mode buffer)))
                         (role . ,(or (cdr (assq window roles))
                                      (if (window-parameter window 'window-side) "side" "editor")))
                         (selected . ,(if (eq window (selected-window)) t :false))
                         (active_editor . ,(if (eq window editor) t :false))
                         (dedicated . ,(if (window-dedicated-p window) t :false))
                         (point . ,(1- (window-point window)))
                         (width . ,(window-total-width window))
                         (height . ,(window-total-height window)))))
                   (window-list nil 'no-minibuf))))
      (workspaces
       . ,(vconcat (mapcar (lambda (tab)
                             `((name . ,(gdev-agent-control--json (alist-get 'name (cdr tab)) 0))
                               (current . ,(if (eq (car tab) 'current-tab) t :false))))
                           tabs)))
      (workspace
       . ((roots . ,(vconcat (and (fboundp 'gdev-workspace-roots) (gdev-workspace-roots))))
          (fields . ,(when (featurep 'gdev-workspace-state)
                       (cl-loop for (key . _rule) in gdev-workspace-state-fields
                                for value = (gdev-workspace-state-get key)
                                when value
                                collect (cons key (gdev-agent-control--json value 3))))))))))

(defun gdev-agent-control--messages (lines)
  "Restituisci le ultime LINES righe di *Messages*."
  (let ((count (gdev-agent-control--integer lines 1 1000 "lines deve essere un intero da 1 a 1000")))
    (with-current-buffer (messages-buffer)
      (save-excursion
        (goto-char (point-max))
        (forward-line (- (1+ count)))
        `((messages . ,(gdev-agent-control--message-lines
                        (buffer-substring-no-properties (point) (point-max)) count)))))))

(defconst gdev-agent-control--open-timeout 25
  "Secondi concessi all'apertura di un file: meno dell'attesa del ponte.")

(defun gdev-agent-control--open-location (path line column)
  "Apri PATH e porta il punto a LINE e COLUMN, contate da 1."
  (let ((line (gdev-agent-control--integer line 1 nil "line deve essere un intero positivo"))
        (column (gdev-agent-control--integer column 1 nil "column deve essere un intero positivo")))
    (unless (and (gdev-agent-interface--absolute-local-p path)
                 (file-regular-p path)
                 (file-readable-p path))
      (user-error "Indica un percorso locale assoluto, esistente e leggibile, del tipo richiesto"))
    ;; Un file con variabili locali non sicure, sotto controllo di versione
    ;; o cifrato apre un prompt nel minibuffer dell'utente: senza input
    ;; ammesso diventa un errore, e il tempo massimo vale come per le altre azioni.
    (car (gdev-agent-control--run
          gdev-agent-control--open-timeout nil
          (lambda ()
            (gdev-open-file path)
            (let ((window (selected-window)))
              (with-current-buffer (window-buffer window)
                (goto-char (point-min))
                (forward-line (1- line))
                (goto-char (min (+ (point) (1- column)) (line-end-position)))
                (set-window-point window (point))
                `((location . ((line . ,(line-number-at-pos))
                               (column . ,(1+ (- (point) (line-beginning-position))))))))))))))

;;;###autoload
(defun gdev-agent-control-request (action &rest arguments)
  "Esegui l'azione di pilotaggio ACTION con ARGUMENTS testuali.
Restituisci i campi da aggiungere alla risposta JSON."
  (pcase action
    ("eval" (apply #'gdev-agent-control--eval arguments))
    ("command" (apply #'gdev-agent-control--command arguments))
    ("keys" (apply #'gdev-agent-control--keys arguments))
    ("open-location" (apply #'gdev-agent-control--open-location arguments))
    ("buffer-read" (apply #'gdev-agent-control--buffer-read arguments))
    ("buffers" (gdev-agent-control--buffers))
    ("layout" (gdev-agent-control--layout))
    ("messages" (apply #'gdev-agent-control--messages arguments))
    (_ (user-error "Azione di pilotaggio sconosciuta: %s" action))))

(provide 'gdev-agent-control)
;;; gdev-agent-control.el ends here
