;;; gdev-voice-audio.el --- Sessioni di ascolto e lettura contestuali -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il riconoscimento locale è facoltativo. La lettura usa il servizio di
;; sistema; nessun modello viene installato dall'avvio o dall'osservazione.
;; Ogni risposta asincrona conserva sessione, documento e spazio originali.
;;; Code:
(require 'gdev-voice)
(require 'gdev-voice-backend)

(declare-function earwig-server-transcribe-default "earwig-server" (file callback))
(declare-function earwig--toggle-recording "earwig" (mode))
(declare-function earwig-cancel-all-recordings "earwig" ())
(declare-function earwig--record-done "earwig" ())
(declare-function earwig--stop-recorder "earwig-platform" (process))
(declare-function earwig-stream-recording-p "earwig-stream" ())
(declare-function earwig--stream-finish "earwig-stream" ())
(declare-function earwig--stream-accept-group "earwig-stream" ())
(declare-function earwig--stream-break "earwig-stream" ())
(declare-function earwig--stream-after-command "earwig-stream" ())
(declare-function earwig--process-text-1 "earwig" (text target pos &optional cleaned))
(declare-function earwig-clean "earwig-cleanup" (text))
(defvar earwig-filler-words)
(defvar earwig-spoken-format)
(defvar earwig-literal-word)
(defvar earwig-keep-capitalized)
(defvar earwig-wake-word-commands)
(defvar earwig-corrections)
(defvar earwig--phase)
(defvar earwig--mode)
(defvar earwig--audio-flowing)
(defvar earwig--stream-read)
(defvar earwig--stream-dir)
(defvar earwig--stream-process)
(defvar earwig--record-process)

(defun gdev-voice--speech-message (format-string &rest arguments)
  "Mostra un riscontro di trascrizione senza conservarlo nel registro."
  (let ((message-log-max nil)) (apply #'message format-string arguments)))

(defcustom gdev-voice-recognizer nil
  "Riconoscitore facoltativo: nil non installa né avvia modelli.
L'attivazione esplicita prepara il modello locale e conserva la licenza."
  :type '(choice (const :tag "Disattivato" nil) (const :tag "Whisper locale" whisper))
  :group 'gdev-voice)
(defcustom gdev-voice-reading-voice nil
  "Voce italiana scelta dal catalogo di sistema; nil sceglie la prima disponibile."
  :type '(choice (const :tag "Automatica" nil) string) :group 'gdev-voice)
(defcustom gdev-voice-reading-rate 180
  "Velocità di lettura, in parole al minuto."
  :type 'natnum :group 'gdev-voice)
(defvar gdev-voice--voices nil)

(defconst gdev-voice--mode-line '(:eval (gdev-voice-status-string)))
(defvar gdev-voice--active nil "Indicatore derivato per il tasto di interruzione e la barra di stato.")
(defun gdev-voice--preparing-p ()
  "Indica se il processo applicativo di preparazione è ancora attivo."
  (and (buffer-live-p gdev-voice-backend--preparation)
       (process-live-p (get-buffer-process gdev-voice-backend--preparation))))
(defun gdev-voice--cancel-key (command)
  "Mantieni il normale annullamento del minibuffer; altrove usa COMMAND."
  (unless (minibufferp) command))
(defvar gdev-voice--emulation-map
  `((gdev-voice--active . ,(let ((map (make-sparse-keymap)))
                            (define-key map (kbd "C-g")
                                        '(menu-item "" gdev-voice-stop :filter gdev-voice--cancel-key)) map))))
(add-to-list 'emulation-mode-map-alists 'gdev-voice--emulation-map)

(defun gdev-voice-status-string ()
  "Descrivi la sessione con il dato applicativo autorevole."
  (when (or gdev-voice--session (gdev-voice--preparing-p))
    (propertize
     (concat " Voce: "
             (pcase (if gdev-voice--session (gdev-voice-session-phase gdev-voice--session) 'preparing)
               ('preparing "preparazione") ('starting "avvio motore") ('opening "avvio microfono")
               ('listening (if (eq 'command (gdev-voice-session-kind gdev-voice--session)) "ascolto · comando" "ascolto · dettatura"))
               ('transcribing "trascrizione") ('reading "lettura") ('paused "in pausa")
               ('changed "documento cambiato") (_ "in corso")) " ")
     'face 'mode-line-emphasis 'help-echo "C-g interrompe la voce")))

(defun gdev-voice--notify ()
  "Pubblica insieme il riscontro della sessione e l'indicatore."
  (setq gdev-voice--active (and (or gdev-voice--session (gdev-voice--preparing-p)) t))
  (if gdev-voice--active
      (unless (member gdev-voice--mode-line global-mode-string)
        (setq global-mode-string (cons gdev-voice--mode-line
                                      (if (listp global-mode-string) global-mode-string (list global-mode-string)))))
    (when (listp global-mode-string)
      (setq global-mode-string (delete gdev-voice--mode-line global-mode-string))))
  (force-mode-line-update t)
  (run-hooks 'gdev-voice-state-change-hook))

(defun gdev-voice--valid-p (session)
  "Ammetti una risposta soltanto per SESSION ancora corrente e coerente."
  (and (eq session gdev-voice--session)
       (not (eq 'changed (gdev-voice-session-phase session)))
       (gdev-voice-context-current-p (gdev-voice-session-context session))
       (not (and (eq 'dictate (gdev-voice-session-kind session))
                 (let ((buffer (gdev-voice-context-buffer (gdev-voice-session-context session))))
                   (and buffer (buffer-local-value 'buffer-read-only buffer)))))))

(defun gdev-voice--watch-context ()
  "Interrompi prima dei ganci di Earwig quando cambia il contesto dell'editor."
  (when (and gdev-voice--session (not (gdev-voice--valid-p gdev-voice--session)))
    (gdev-voice-stop t)
    (message "Voce interrotta: documento o spazio cambiato")))

(defun gdev-voice--source-killed ()
  "La chiusura del documento invalida anche le risposte già in viaggio."
  (when (and gdev-voice--session
             (eq (current-buffer) (gdev-voice-context-buffer (gdev-voice-session-context gdev-voice--session))))
    (gdev-voice-stop t)))

(defun gdev-voice--before-change (&rest _)
  "Separa l'annullamento del testo dettato dalle modifiche della persona."
  (when (and gdev-voice--session (not gdev-voice--applying)
             (memq (gdev-voice-session-kind gdev-voice--session) '(dictate command))
             (bound-and-true-p earwig--stream-dir))
    (earwig--stream-accept-group)))

(defun gdev-voice--after-change (&rest _)
  "Rifiuta risultati antecedenti a modifiche del testo; ignora le sole proprietà."
  (when-let* ((session gdev-voice--session)
              ((not gdev-voice--applying))
              ((not (equal (gdev-voice-session-tick session) (buffer-chars-modified-tick)))))
    (setf (gdev-voice-session-phase session) 'changed)
    (run-with-timer 0 nil (lambda () (when (eq session gdev-voice--session) (gdev-voice-stop t))))))

(defun gdev-voice--attach (session)
  "Collega SESSION al ciclo di vita del proprio documento."
  (setq gdev-voice--session session)
  (when-let* ((buffer (gdev-voice-context-buffer (gdev-voice-session-context session))))
    (with-current-buffer buffer
      (setf (gdev-voice-session-tick session) (buffer-chars-modified-tick))
      (add-hook 'before-change-functions #'gdev-voice--before-change nil t)
      (add-hook 'after-change-functions #'gdev-voice--after-change nil t)
      (add-hook 'kill-buffer-hook #'gdev-voice--source-killed nil t)))
  (add-hook 'post-command-hook #'gdev-voice--watch-context -100)
  (gdev-voice--notify))

(defun gdev-voice--finish (session)
  "Rilascia soltanto i collegamenti e le impostazioni posseduti da SESSION."
  (when (eq session gdev-voice--session) (setq gdev-voice--session nil))
  (when (timerp (gdev-voice-session-timer session)) (cancel-timer (gdev-voice-session-timer session)))
  (when-let* ((buffer (gdev-voice-context-buffer (gdev-voice-session-context session)))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (remove-hook 'before-change-functions #'gdev-voice--before-change t)
      (remove-hook 'after-change-functions #'gdev-voice--after-change t)
      (remove-hook 'kill-buffer-hook #'gdev-voice--source-killed t)))
  (dolist (entry (gdev-voice-session-profile session)) (set (car entry) (cdr entry)))
  (setf (gdev-voice-session-profile session) nil)
  (unless gdev-voice--session (remove-hook 'post-command-hook #'gdev-voice--watch-context))
  (gdev-voice--notify))

(defun gdev-voice-stop (&optional keep-preparation)
  "Interrompi la voce conservando il testo.
I seguiti del documento usano KEEP-PREPARATION per lasciare attiva la
preparazione applicativa. L'interruzione esplicita ferma anche quella."
  (interactive)
  (unless keep-preparation
    (when (gdev-voice--preparing-p) (gdev-voice-backend-stop)))
  (when-let* ((session gdev-voice--session))
    ;; Prima dei segnali: nessuna sentinella può applicare risultati annullati.
    (setq gdev-voice--session nil)
    (when (eq 'starting (gdev-voice-session-phase session))
      (gdev-voice-backend-stop))
    (when (memq (gdev-voice-session-kind session) '(dictate command))
      (when (featurep 'earwig) (earwig-cancel-all-recordings)))
    (dolist (process (cons (gdev-voice-session-process session) (gdev-voice-session-requests session)))
      (when (processp process)
        (set-process-sentinel process #'ignore)
        (when (process-live-p process) (delete-process process))
        (when (and (or (eq 'read (gdev-voice-session-kind session))
                       (memq process (gdev-voice-session-requests session)))
                   (buffer-live-p (process-buffer process)))
          (kill-buffer (process-buffer process)))))
    (gdev-voice--finish session)
    (message "Voce interrotta"))
  (gdev-voice--notify))

(defun gdev-voice-prepare ()
  "Attiva il riconoscimento facoltativo preparando esplicitamente il modello."
  (interactive)
  (let ((generation gdev-voice-backend--generation))
    (condition-case error
        (progn
          (gdev-voice-backend-prepare
           (lambda (ok detail)
             (when (= generation gdev-voice-backend--generation)
               (if ok
                   (progn (customize-save-variable 'gdev-voice-recognizer 'whisper)
                          (message "Riconoscimento locale pronto. Avvia Dettatura o Comando vocale"))
                 (message "Preparazione voce: %s" detail)))
             (gdev-voice--notify)))
          (gdev-voice--notify))
      (error (gdev-voice--notify) (signal (car error) (cdr error))))))

(defun gdev-voice--transcribe (file callback)
  "Trascrivi FILE e consegna a CALLBACK soltanto risposte ancora attuali."
  (let ((session gdev-voice--session) process completed
        ;; L'audio resta sul collegamento locale anche con un proxy della shell.
        (process-environment (append '("no_proxy=*" "NO_PROXY=*") process-environment)))
    (if (not (and session (gdev-voice--valid-p session)))
        (progn (when (eq session gdev-voice--session) (gdev-voice-stop t)) nil)
      (setq process
            (earwig-server-transcribe-default
             file
             (lambda (ok text)
               (setq completed t)
               (setf (gdev-voice-session-requests session)
                     (delq process (gdev-voice-session-requests session)))
               (let ((gdev-voice--applying t))
                 (if (not (gdev-voice--valid-p session))
                     (when (eq session gdev-voice--session) (gdev-voice-stop t))
                   (funcall callback ok text)
                   (when-let* ((buffer (gdev-voice-context-buffer (gdev-voice-session-context session)))
                               ((buffer-live-p buffer)))
                     (setf (gdev-voice-session-tick session)
                           (with-current-buffer buffer (buffer-chars-modified-tick)))))))))
      (unless completed
        (push process (gdev-voice-session-requests session)))
      process)))

(defun gdev-voice--command-steps (text)
  "Offri al riscontro di Earwig la stessa grammatica dell'entrata scritta."
  (when-let* ((intents (gdev-voice-parse text)))
    (list (list text #'gdev-voice--run-command text intents))))

(defun gdev-voice--run-command (text &optional intents)
  "Esegui TEXT e INTENTS soltanto nel contesto che ha registrato il comando."
  (when-let* ((session gdev-voice--session) ((gdev-voice--valid-p session)))
    (let ((gdev-voice--applying t) (single (eq 'command (gdev-voice-session-kind session))))
      (unwind-protect
          (progn
            (when (bound-and-true-p earwig--stream-dir) (earwig--stream-break))
            (select-window (gdev-voice-context-window (gdev-voice-session-context session)))
            (dolist (intent (or intents (gdev-voice-parse text)))
              (gdev-voice-execute-intent intent) (undo-boundary)))
        (setf (gdev-voice-session-pending-command session) nil)
        (when (eq session gdev-voice--session)
          (cond (single (gdev-voice--finish session))
                ((bound-and-true-p earwig--stream-dir) (earwig--stream-after-command))
                ((not (earwig-stream-recording-p)) (gdev-voice--finish session))))))))

(defun gdev-voice--process-text (text target pos)
  "Adatta TEXT in italiano, conservando TARGET e POS della sessione."
  (when-let* ((session gdev-voice--session) ((gdev-voice--valid-p session))
              ((eq target (gdev-voice-context-buffer (gdev-voice-session-context session)))))
    (let* ((earwig-corrections (append gdev-voice-corrections earwig-corrections))
           (clean (let ((earwig-filler-words '("ehm" "uhm" "mmm")))
                    (earwig-clean text)))
           (single (eq 'command (gdev-voice-session-kind session)))
           (case-fold-search t)
           (prefix (string-match "\\`\\(?:comando\\|gdev\\)[, :]+\\(.+\\)" clean))
           (command (if prefix (match-string 1 clean) clean))
           (intents (and (or single prefix) (gdev-voice-parse command))))
      (cond
       (intents
        (setf (gdev-voice-session-pending-command session) t)
        (run-with-timer 0 nil
                        (lambda ()
                          (when (gdev-voice--valid-p session)
                            (condition-case error
                                (gdev-voice--run-command command intents)
                              (error (gdev-voice--speech-message "Comando vocale: %s" (error-message-string error)))))))
        nil)
       ((or single prefix) (gdev-voice--speech-message "Comando non riconosciuto o incompleto: %s" command) nil)
       (t
        (let ((earwig-spoken-format gdev-voice-italian-punctuation)
              (earwig-literal-word "letterale") (earwig-keep-capitalized gdev-voice-vocabulary)
              (earwig-wake-word-commands nil) (earwig--mode 'dictate))
          (earwig--process-text-1 clean target pos t)))))))

(defun gdev-voice--phase (phase)
  "Aggiorna il solo stato della sessione che possiede Earwig."
  (when-let* ((session gdev-voice--session)
              ((memq (gdev-voice-session-kind session) '(dictate command))))
    (pcase phase
      ('recording (setf (gdev-voice-session-phase session) 'opening))
      ('transcribing (setf (gdev-voice-session-phase session) 'transcribing))
      ('nil
       (unless (gdev-voice-session-pending-command session)
         (run-with-timer 0 nil (lambda () (when (eq session gdev-voice--session) (gdev-voice--finish session)))))))
    (gdev-voice--notify)))

(defun gdev-voice--microphone-ready (session)
  "Mostra l'ascolto solo dopo l'arrivo effettivo di campioni audio."
  (when (gdev-voice--valid-p session)
    (cond
     ((or earwig--audio-flowing (> (or earwig--stream-read 0) 0))
      (setf (gdev-voice-session-phase session) 'listening) (gdev-voice--notify))
     ((and (eq 'opening (gdev-voice-session-phase session))
           (> (- (float-time) (gdev-voice-session-started session)) 15))
      (gdev-voice-stop t)
      (message "Nessun audio ricevuto. Controlla il microfono e il permesso nelle impostazioni Privacy di sistema"))
     ((eq 'opening (gdev-voice-session-phase session))
      (setf (gdev-voice-session-timer session)
            (run-with-timer 0.1 nil #'gdev-voice--microphone-ready session))))))

(defun gdev-voice--begin (session url)
  "Avvia SESSION sul motore pronto URL senza usare le scorciatoie originali."
  (gdev-voice--fork)
  (let ((settings `((earwig-client-transcribe-function . gdev-voice--transcribe)
                    (earwig-client-process-text-function . gdev-voice--process-text)
                    (earwig-client-command-parser . gdev-voice--command-steps)
                    (earwig-client-command-runner . gdev-voice--run-command)
                    (earwig-show-mode-line . nil) (earwig-log-transcriptions . nil)
                    (earwig-log-commands . nil)
                    (earwig-speech-server-base-url . ,url)
                    (earwig-speech-server-model . "whisper-small-it")
                    (earwig-wake-words . ("comando" "gdev"))
                    (earwig-chain-words . ("e poi" "quindi"))
                    (earwig-cancel-words . ("annulla comando" "non importa" "lascia perdere"))
                    (earwig-phase-change-hook . (gdev-voice--phase)))))
    (setf (gdev-voice-session-profile session)
          (mapcar (lambda (entry) (cons (car entry) (symbol-value (car entry)))) settings))
    (dolist (entry settings) (set (car entry) (cdr entry)))
    (setq earwig--audio-flowing nil)
    (setf (gdev-voice-session-started session) (float-time))
    (select-window (gdev-voice-context-window (gdev-voice-session-context session)))
    (earwig--toggle-recording (gdev-voice-session-kind session))
    (gdev-voice--microphone-ready session)))

(defun gdev-voice--start (kind)
  "Avvia o termina la cattura di KIND rispettando il riconoscimento facoltativo."
  (cond
   ((and gdev-voice--session (eq kind (gdev-voice-session-kind gdev-voice--session)))
    (if (eq 'listening (gdev-voice-session-phase gdev-voice--session))
        (earwig--toggle-recording kind)
      (gdev-voice-stop t)))
   ((not (eq 'whisper gdev-voice-recognizer))
    (gdev-voice-open)
    (message "Il riconoscimento è facoltativo: scegli Attiva riconoscimento locale nel pannello Voce"))
   (t
    (gdev-voice-stop t)
    (let* ((context (gdev-voice-context)) (buffer (gdev-voice-context-buffer context)))
      (unless buffer (user-error "Apri un documento per la dettatura o il comando vocale"))
      (with-current-buffer buffer
        (when (and (eq kind 'dictate)
                   (or buffer-read-only (derived-mode-p 'term-mode 'comint-mode 'eat-mode)))
          (user-error "La dettatura richiede un documento modificabile")))
      (when (bound-and-true-p earwig--phase) (user-error "Attendi l'arresto della registrazione precedente"))
      (let ((session (gdev-voice-session-create :kind kind :phase 'starting :context context :started (float-time))))
        (gdev-voice--attach session)
        (condition-case error
            (gdev-voice-backend-ensure
             gdev-voice-vocabulary
             (lambda (ok detail)
               (when (eq session gdev-voice--session)
                 (if (and ok (gdev-voice--valid-p session))
                     (condition-case error (gdev-voice--begin session detail)
                       (error (gdev-voice-stop t) (message "Avvio voce: %s" (error-message-string error))))
                   (gdev-voice--finish session) (message "Voce non avviata: %s" detail)))))
          (error (gdev-voice--finish session) (signal (car error) (cdr error)))))))))

(defun gdev-voice-start-dictation ()
  "Avvia la dettatura italiana; ripeti per terminare e trascrivere, C-g annulla."
  (interactive) (gdev-voice--start 'dictate))
(defun gdev-voice-start-command ()
  "Registra un comando italiano; ripeti per eseguirlo, C-g annulla."
  (interactive) (gdev-voice--start 'command))

(defun gdev-voice-disable ()
  "Disattiva il riconoscimento facoltativo e rilascia il motore dalla memoria."
  (interactive)
  (gdev-voice-stop)
  (gdev-voice-backend-stop)
  (customize-save-variable 'gdev-voice-recognizer nil)
  (gdev-voice--notify)
  (message "Riconoscimento disattivato; il modello resta nella cache condivisa"))

(defun gdev-voice-voices ()
  "Elenca le voci italiane già disponibili, soltanto su richiesta."
  (or gdev-voice--voices
      (setq gdev-voice--voices
            (with-temp-buffer
              (if (eq system-type 'darwin)
                  (progn
                    (unless (and (file-executable-p "/usr/bin/say") (zerop (call-process "/usr/bin/say" nil t nil "-v" "?")))
                      (user-error "Il lettore vocale di sistema non è disponibile"))
                    (goto-char (point-min))
                    (let (voices)
                      (while (re-search-forward "^\\(.+?\\)[ \t]+it[_-]IT[ \t]+#" nil t)
                        (push (string-trim (match-string 1)) voices))
                      (delete-dups (nreverse voices))))
                (let ((program (or (executable-find "espeak-ng") (executable-find "espeak")
                                   (user-error "Installa facoltativamente espeak-ng per la lettura italiana"))))
                  (unless (zerop (call-process program nil t nil "--voices=it")) (user-error "Catalogo delle voci non disponibile"))
                  (list "it")))))))

(defun gdev-voice-select-voice ()
  "Scegli una voce italiana dal catalogo di sistema."
  (interactive)
  (setq gdev-voice--voices nil)
  (let ((voices (or (gdev-voice-voices) (user-error "Aggiungi una voce italiana nelle impostazioni vocali di sistema"))))
    (customize-save-variable 'gdev-voice-reading-voice
                            (completing-read "Voce italiana: " voices nil t nil nil
                                             (if (member gdev-voice-reading-voice voices)
                                                 gdev-voice-reading-voice (car voices))))))

(defun gdev-voice-read (&optional whole)
  "Leggi la selezione o il testo dal punto alla fine. Con WHOLE leggi tutto."
  (interactive "P")
  (let* ((context (gdev-voice-context))
         (buffer (or (gdev-voice-context-buffer context) (user-error "Apri un documento da leggere")))
         (text (with-current-buffer buffer
                 (save-restriction
                   (when whole (widen))
                   (buffer-substring-no-properties
                    (cond (whole (point-min)) ((use-region-p) (region-beginning)) (t (point)))
                    (if (and (not whole) (use-region-p)) (region-end) (point-max))))))
         (voices (or (gdev-voice-voices) (user-error "Nessuna voce italiana installata")))
         (voice (or gdev-voice-reading-voice (car voices)))
         (arguments (if (eq system-type 'darwin)
                        (list "/usr/bin/say" "-v" voice "-r" (number-to-string gdev-voice-reading-rate))
                      (list (or (executable-find "espeak-ng") (executable-find "espeak"))
                            "-v" voice "-s" (number-to-string gdev-voice-reading-rate) "--stdin"))))
    (when (string-empty-p (string-trim text)) (user-error "Non c'è testo da leggere"))
    (unless (member voice voices) (user-error "La voce scelta non è disponibile; usa Scegli voce italiana"))
    (gdev-voice-stop t)
    (let ((session (gdev-voice-session-create :kind 'read :phase 'reading :context context))
          (output (generate-new-buffer " *gdev-voice-reading*")))
      (gdev-voice--attach session)
      (condition-case error
          (let ((process (make-process :name "gdev-voice-reading" :command arguments :buffer output
                                       :coding 'utf-8-unix :connection-type 'pipe :noquery t
                                       :sentinel (lambda (child _)
                                                   (when (memq (process-status child) '(exit signal))
                                                     (when (eq session gdev-voice--session)
                                                       (unless (zerop (process-exit-status child))
                                                         (message "Lettura non riuscita (codice %d)" (process-exit-status child)))
                                                       (gdev-voice--finish session))
                                                     (when (buffer-live-p output) (kill-buffer output)))))))
            (setf (gdev-voice-session-process session) process)
            (process-send-string process text) (process-send-eof process))
        (error (when (buffer-live-p output) (kill-buffer output))
               (gdev-voice--finish session) (signal (car error) (cdr error)))))))

(defun gdev-voice-pause ()
  "Metti in pausa o riprendi la lettura corrente."
  (interactive)
  (let* ((session gdev-voice--session) (process (and session (gdev-voice-session-process session))))
    (unless (and session (eq 'read (gdev-voice-session-kind session)) (process-live-p process))
      (user-error "Non c'è una lettura in corso"))
    (if (gdev-voice-session-paused session) (continue-process process)
      (signal-process process 'SIGSTOP))
    (setf (gdev-voice-session-paused session) (not (gdev-voice-session-paused session))
          (gdev-voice-session-phase session) (if (gdev-voice-session-paused session) 'paused 'reading))
    (gdev-voice--notify)))

(add-hook 'kill-emacs-hook #'gdev-voice-stop)
(provide 'gdev-voice-audio)
;;; gdev-voice-audio.el ends here
