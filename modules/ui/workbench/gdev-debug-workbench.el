;;; gdev-debug-workbench.el --- Debug, profilazione e risorse dello spazio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; La vista Debug usa lo stesso riquadro delle altre attività. Scorrimento,
;; pagina e processo osservato appartengono allo spazio di lavoro.

;;; Code:

(require 'button)
(require 'gdev-ui)
(require 'gdev-layout)
(require 'gdev-workspace-state)

(declare-function dape--config "dape" (connection))
(declare-function dape--capable-p "dape" (connection capability))
(declare-function dape--state "dape" (connection))
(declare-function dape-select-session "dape" (connection &optional exact))
(declare-function dape-continue "dape" (conn))
(declare-function dape-pause "dape" (conn))
(declare-function dape-restart "dape" (&optional conn skip-compile valid-p))
(declare-function dape-kill "dape" (conn &optional cb with-disconnect))
(declare-function dape-repl "dape" ())
(declare-function dape-breakpoint-toggle "dape" ())
(declare-function dape-breakpoint-log "dape" (message))
(declare-function dape-breakpoint-expression "dape" (expression))
(declare-function dape-breakpoint-hits "dape" (condition))
(declare-function gdev-debug-attach "../../tools/debugger/config" (pid))
(declare-function gdev-debug-breakpoints-show "gdev-debug-breakpoints" ())
(declare-function gdev-debug-inspector-show "gdev-debug-inspector" (&optional connection))
(declare-function gdev-debug-session-command "../../tools/debugger/config" (command &optional connection))
(declare-function gdev-run-project-task "../../tools/build/config" (&optional repeat))
(declare-function gdev-debug-workspace-connection "../../tools/debugger/config"
                  (owner &optional connections))
(declare-function gdev-debug-workspace-connections "../../tools/debugger/config" (owner))
(declare-function gdev-debug-workspace-target "../../tools/debugger/config" (connection))
(declare-function gdev-debug-workspace-result "../../tools/debugger/config" (owner))
(declare-function gdev-debug-select-workspace-session "../../tools/debugger/config" (owner))
(declare-function gdev-project-view--render "gdev-project-view" ())
(declare-function gdev-project-view--run-command "gdev-project-view" (command))
(declare-function gdev-project-view-select-profile "gdev-project-view" ())
(declare-function gdev-debug-exceptions-available-p "../../tools/debugger/config"
                  (&optional connection))
(declare-function gdev-debug-exceptions "../../tools/debugger/config" (&optional connection))
(declare-function gdev-build "../../tools/build/config" (&optional choose-target))
(declare-function gdev-project-view-launch "gdev-project-view" (&optional debug))
(declare-function gdev-system-monitor--sample "../../ui/system-monitor/config" ())
(declare-function gdev-system-monitor-show "../../ui/system-monitor/config" ())

(defface gdev-debug-workbench-title
  '((t :inherit gdev-ui-side-title))
  "Titolo della vista Debug."
  :group 'gdev-layout)

(defface gdev-debug-workbench-accent
  '((t :inherit gdev-ui-action-primary))
  "Azione primaria e pagina selezionata nella vista Debug."
  :group 'gdev-layout)

(defface gdev-debug-workbench-heading
  '((t :inherit gdev-ui-view-heading))
  "Titolo di un gruppo nella vista Debug."
  :group 'gdev-layout)

(defface gdev-debug-workbench-paused
  '((t :inherit gdev-ui-status-warning))
  "Stato di pausa durante il debug."
  :group 'gdev-layout)

(defface gdev-debug-workbench-running
  '((t :inherit gdev-ui-status-success))
  "Stato di esecuzione durante il debug."
  :group 'gdev-layout)

(defconst gdev-debug-workbench--pages '((session . "Sessione") (profile . "Profila") (system . "Sistema")))
(defvar-local gdev-debug-workbench--page 'session)
(defvar-local gdev-debug-workbench--owner nil)
(defvar-local gdev-debug-workbench--snapshot nil)
(defvar-local gdev-debug-workbench--manual-pid nil)
(defvar-local gdev-debug-workbench--target nil)
(defvar-local gdev-debug-workbench--job nil)
(defvar-local gdev-debug-workbench--sample nil)
(defvar-local gdev-debug-workbench--sample-time 0)
(defvar-local gdev-debug-workbench--cpu-history nil)
(defvar-local gdev-debug-workbench--rss-history nil)
(defconst gdev-debug-workbench--sample-limit 12)
(defvar gdev-debug-workbench--timer nil)
(defvar gdev-debug-workbench--drawing-session nil
  "Dati della sessione durante un ridisegno avviato da un evento.")

(defun gdev-debug-workbench-owner ()
  "Restituisci l'identità temporanea dello spazio di lavoro corrente."
  (gdev-workspace-state-ensure-id))

(defun gdev-debug-workbench--connection ()
  "Restituisci la connessione del riquadro, se attiva."
  (when (fboundp 'gdev-debug-workspace-connection)
    (gdev-debug-workspace-connection gdev-debug-workbench--owner)))

(defun gdev-debug-workbench--result ()
  "Restituisci l'ultimo esito del debugger nello spazio del riquadro."
  (when (fboundp 'gdev-debug-workspace-result)
    (gdev-debug-workspace-result gdev-debug-workbench--owner)))

(defun gdev-debug-workbench--session-data ()
  "Raccogli in una lettura sola lo stato e le azioni della sessione."
  (let* ((connections (when (fboundp 'gdev-debug-workspace-connections)
                        (gdev-debug-workspace-connections gdev-debug-workbench--owner)))
         (conn (and connections
                    (gdev-debug-workspace-connection gdev-debug-workbench--owner connections)))
         (state (and conn (dape--state conn)))
         (result (when (or (not conn) (memq state '(exited terminated)))
                   (gdev-debug-workbench--result)))
         (program (or (and conn (plist-get (dape--config conn) :program)) (car result))))
    (list :connection conn :state state :result result :program program
          :multiple (and (cdr connections) t)
          :memory (and (eq state 'stopped) (dape--capable-p conn :supportsReadMemoryRequest))
          :disassemble (and (eq state 'stopped) (dape--capable-p conn :supportsDisassembleRequest))
          :exceptions (and conn (gdev-debug-exceptions-available-p conn) t))))

(defun gdev-debug-workbench--target (connection)
  "Restituisci l'identità del processo osservato o del programma di CONNECTION."
  (if gdev-debug-workbench--manual-pid
      (cons gdev-debug-workbench--manual-pid 'manual)
    (when (fboundp 'gdev-debug-workspace-target)
      (when-let* ((pid (gdev-debug-workspace-target connection)))
        (cons pid connection)))))

(defun gdev-debug-workbench--cancel ()
  "Interrompi la lettura corrente del processo."
  (let ((job gdev-debug-workbench--job))
    (setq gdev-debug-workbench--job nil)
    (when (process-live-p job) (delete-process job))))

(defun gdev-debug-workbench--parse-process (text)
  "Leggi CPU percentuale, RAM in byte e avvio da TEXT di ps."
  (let ((fields (split-string (string-trim text) "[[:blank:]]+" t)))
    (when (and (>= (length fields) 3)
               (string-match-p "^[0-9]+\\(?:\\.[0-9]+\\)?$" (car fields))
               (string-match-p "^[0-9]+$" (cadr fields)))
      (list (string-to-number (car fields)) (* 1024 (string-to-number (cadr fields)))
            (string-join (cddr fields) " ")))))

(defun gdev-debug-workbench--accept-sample (sample)
  "Memorizza SAMPLE solo finché corrisponde allo stesso avvio del PID."
  (setq gdev-debug-workbench--sample
        (if (and sample
                 (or (null gdev-debug-workbench--sample)
                     (and (consp gdev-debug-workbench--sample)
                          (equal (nth 2 sample) (nth 2 gdev-debug-workbench--sample)))))
            sample
          'unavailable))
  (when (consp gdev-debug-workbench--sample)
    (push (car sample) gdev-debug-workbench--cpu-history)
    (push (cadr sample) gdev-debug-workbench--rss-history)
    (setq gdev-debug-workbench--cpu-history
          (seq-take gdev-debug-workbench--cpu-history gdev-debug-workbench--sample-limit)
          gdev-debug-workbench--rss-history
          (seq-take gdev-debug-workbench--rss-history gdev-debug-workbench--sample-limit))))

(defun gdev-debug-workbench--sample-process (target)
  "Aggiorna in background CPU e memoria del TARGET visibile."
  (unless (equal target gdev-debug-workbench--target)
    (gdev-debug-workbench--cancel)
    (setq gdev-debug-workbench--target target
          gdev-debug-workbench--sample nil
          gdev-debug-workbench--cpu-history nil
          gdev-debug-workbench--rss-history nil
          gdev-debug-workbench--sample-time 0))
  (when (and target (not gdev-debug-workbench--job)
             (not (eq gdev-debug-workbench--sample 'unavailable))
             (>= (- (float-time) gdev-debug-workbench--sample-time) 2))
    (setq gdev-debug-workbench--sample-time (float-time))
    (let ((view (current-buffer))
          (output (generate-new-buffer " *gdev debug ps*"))
          (default-directory temporary-file-directory)
          (process-environment (cons "LC_ALL=C" (default-value 'process-environment))))
      (condition-case nil
          (setq gdev-debug-workbench--job
                (make-process
                 :name "gdev-debug-ps" :noquery t :buffer output :connection-type 'pipe
                 :command (list "ps" "-p" (number-to-string (car target))
                                "-o" "%cpu=" "-o" "rss=" "-o" "lstart=")
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal failed))
                     (unwind-protect
                         (when (buffer-live-p view)
                           (with-current-buffer view
                             (when (eq process gdev-debug-workbench--job)
                               (setq gdev-debug-workbench--job nil)
                               (gdev-debug-workbench--accept-sample
                                (and (eq (process-status process) 'exit)
                                     (zerop (process-exit-status process))
                                     (with-current-buffer output
                                       (gdev-debug-workbench--parse-process (buffer-string)))))
                               (gdev-debug-workbench-refresh-visible t))))
                       (kill-buffer output))))))
        (file-error
         (kill-buffer output)
         (gdev-debug-workbench--accept-sample nil))))))

(defun gdev-debug-workbench--visible ()
  "Elenca i riquadri Debug effettivamente visibili."
  (delq nil
        (mapcar (lambda (frame)
                  (when (eq (frame-visible-p frame) t)
                    (when-let* ((window (gdev-layout-left-window frame))
                                ((eq 'run (buffer-local-value 'gdev-activity-kind (window-buffer window)))))
                      window)))
                (frame-list))))

(defun gdev-debug-workbench--refresh-window (window)
  "Aggiorna WINDOW e indica se deve continuare a campionare un processo."
  (with-selected-window window
    (let* ((frame (window-frame window))
           (page gdev-debug-workbench--page)
           (system (eq page 'system))
           (gdev-debug-workbench--drawing-session
            (when (eq page 'session) (gdev-debug-workbench--session-data)))
           (target (and system (gdev-debug-workbench--target (gdev-debug-workbench--connection))))
           (sampling (and system (or (not (display-graphic-p frame))
                                     (frame-focus-state frame)))))
      (when system
        (if sampling
            (gdev-debug-workbench--sample-process target)
          (gdev-debug-workbench--cancel)))
      (let ((snapshot (list (window-body-width window t) (frame-char-width frame)
                            (frame-parameter frame 'background-mode) page
                            gdev-debug-workbench--drawing-session
                            (and system (gdev-debug-workbench--machine))
                            target (and system gdev-debug-workbench--sample)
                            (and system gdev-debug-workbench--cpu-history)
                            (and system gdev-debug-workbench--rss-history))))
        (unless (equal snapshot gdev-debug-workbench--snapshot)
          (setq gdev-debug-workbench--snapshot snapshot)
          (gdev-project-view--render)))
      (and sampling target (not (eq gdev-debug-workbench--sample 'unavailable))))))

(defun gdev-debug-workbench-refresh-visible (&optional system-only)
  "Aggiorna le viste visibili. Con SYSTEM-ONLY aggiorna la pagina Sistema."
  (let (sampling)
    (dolist (window (gdev-debug-workbench--visible))
      (when (and (or (not system-only)
                     (eq 'system (buffer-local-value 'gdev-debug-workbench--page (window-buffer window))))
                 (gdev-debug-workbench--refresh-window window))
        (setq sampling t)))
    (cond (sampling
           (unless gdev-debug-workbench--timer
             (setq gdev-debug-workbench--timer
                   (run-with-timer 1 1 #'gdev-debug-workbench-refresh-visible t))))
          (gdev-debug-workbench--timer
           (cancel-timer gdev-debug-workbench--timer)
           (setq gdev-debug-workbench--timer nil)))))

(add-function :after after-focus-change-function #'gdev-debug-workbench-refresh-visible)
(add-hook 'gdev-ui-after-theme-hook #'gdev-debug-workbench-refresh-visible)

(defun gdev-debug-workbench--refresh-system ()
  "Aggiorna la pagina Sistema dopo un campione della macchina."
  (gdev-debug-workbench-refresh-visible t))

(add-hook 'gdev-system-monitor-after-sample-hook #'gdev-debug-workbench--refresh-system)

(defun gdev-debug-workbench-initialize ()
  "Attiva lo stato temporaneo del riquadro corrente."
  (setq-local gdev-debug-workbench--owner (gdev-debug-workbench-owner)
              left-margin-width 1
              right-margin-width 1
              mode-line-format nil
              cursor-type '(bar . 2))
  (add-hook 'kill-buffer-hook #'gdev-debug-workbench--cancel nil t))

(defun gdev-debug-workbench-page (page)
  "Mostra PAGE mantenendo il riquadro attivo."
  (setq gdev-debug-workbench--page page
        gdev-debug-workbench--snapshot nil)
  (unless (eq page 'system) (gdev-debug-workbench--cancel))
  (gdev-debug-workbench-refresh-visible)
  (goto-char (point-min))
  (let ((button (next-button (point-min) t)))
    (while (and button (not (eq page (button-get button 'gdev-project-view-id))))
      (setq button (next-button (button-end button))))
    (when button (goto-char (button-start button)))))

(defun gdev-debug-workbench--machine ()
  "Restituisci il campione già raccolto del sistema locale."
  (when (fboundp 'gdev-system-monitor--sample) (gdev-system-monitor--sample)))

(defun gdev-debug-workbench--fit (text &optional face)
  "Adatta TEXT al riquadro usando FACE e la larghezza del carattere visualizzato."
  (let* ((window (get-buffer-window (current-buffer) t))
         (label (if face (propertize text 'face face) text)))
    (if (and window (display-graphic-p (window-frame window)))
        (gdev-ui-fit-text label (max 12 (- (window-body-width window t) 4)) #'string-pixel-width)
      (truncate-string-to-width label (if window (window-body-width window) 32) nil nil "…"))))

(defun gdev-debug-workbench--text (text &optional face help)
  "Inserisci una riga TEXT, conservando il testo completo in HELP."
  (insert (propertize (gdev-debug-workbench--fit text face) 'help-echo (or help text)) "\n"))

(defun gdev-debug-workbench--button (label id action &optional face inline help)
  "Inserisci il pulsante LABEL per ACTION con ID, FACE, INLINE e HELP."
  (let ((text (if (eq id 'primary) (concat "   " label "   ") label)))
    (insert-text-button (if inline text (gdev-debug-workbench--fit text face))
                      'type 'gdev-ui-action
                      'face (or face 'gdev-ui-action)
                      'help-echo (or help (string-trim label))
                      'gdev-project-view-id id
                      'action (lambda (_) (funcall action))))
  (unless inline (insert "\n")))

(defun gdev-debug-workbench--command (label command)
  "Esponi il comando disponibile COMMAND con LABEL."
  (when (commandp command)
    (gdev-debug-workbench--button label command
                                 (lambda () (gdev-project-view--run-command command)))))

(defun gdev-debug-workbench--controls (command &optional select)
  "Esegui COMMAND sulla connessione del riquadro, reselezionandola con SELECT."
  (let ((conn (or (gdev-debug-workbench--connection)
                  (user-error "Nessuna sessione attiva in questo spazio"))))
    (if select
        (progn
          (dape-select-session conn t)
          (gdev-project-view--run-command command))
      (gdev-debug-session-command command conn))))

(defun gdev-debug-workbench--session (profile)
  "Disegna lo stato del debugger e le azioni disponibili per PROFILE."
  (let* ((data (or gdev-debug-workbench--drawing-session (gdev-debug-workbench--session-data)))
         (conn (plist-get data :connection))
         (state (plist-get data :state))
         (result (plist-get data :result))
         (program (plist-get data :program)))
    (cond
     ((eq state 'stopped)
      (gdev-debug-workbench--text "●  In pausa" 'gdev-debug-workbench-paused))
     ((memq state '(running started launched attached))
      (gdev-debug-workbench--text "●  In esecuzione" 'gdev-debug-workbench-running))
     (result
      (let ((code (cdr result)))
        (gdev-debug-workbench--text (format "Uscita %d" code)
                                    (if (zerop code) 'gdev-debug-workbench-running
                                      'gdev-debug-workbench-paused)
                                    (format "Uscita con codice %d" code))))
     ((memq state '(exited terminated))
      (gdev-debug-workbench--text "○  Terminato" 'gdev-ui-secondary))
     (conn (gdev-debug-workbench--text "◌  Connessione in corso" 'gdev-ui-secondary))
     (t (gdev-debug-workbench--text "○  Pronto per il debug" 'gdev-ui-secondary)))
    (when (stringp program)
      (gdev-debug-workbench--text (file-name-nondirectory program) 'gdev-ui-secondary program))
    (insert "\n")
    (if conn
        (progn
          (pcase state
            ('stopped
             (gdev-debug-workbench--button "Continua" 'primary
                                          (lambda () (gdev-debug-workbench--controls #'dape-continue))
                                          'gdev-debug-workbench-accent)
             (insert "\n")
             (dolist (entry '(("Passo successivo" . dape-next)
                              ("Entra nella funzione" . dape-step-in)
                              ("Esci dalla funzione" . dape-step-out)))
               (let ((command (cdr entry)))
                 (gdev-debug-workbench--button (car entry) command
                                              (lambda () (gdev-debug-workbench--controls command))))))
            ((or 'running 'started 'launched 'attached)
             (gdev-debug-workbench--button "Pausa" 'primary
                                          (lambda () (gdev-debug-workbench--controls #'dape-pause))
                                          'gdev-debug-workbench-accent)))
          (unless (memq state '(starting initialized))
            (gdev-debug-workbench--button "Riavvia" 'restart
                                         (lambda () (gdev-debug-workbench--controls #'dape-restart))))
          (gdev-debug-workbench--button
           "Termina sessione…" 'terminate
           (lambda ()
             (when (yes-or-no-p "Terminare la sessione di questo spazio? ")
               (gdev-debug-workbench--controls #'dape-kill))))
          (insert "\n")
          (gdev-debug-workbench--text "Ispeziona" 'gdev-debug-workbench-heading)
          (when (commandp 'gdev-debug-inspector-show)
            (gdev-debug-workbench--button "Variabili, pila e thread" 'gdev-debug-inspector-show
                                         (lambda () (gdev-debug-inspector-show conn))))
          (dolist (entry '(("Console di debug" . dape-repl)
                           ("Valuta espressione…" . dape-evaluate-expression)
                           ("Osserva espressione…" . dape-watch-dwim)
                           ("Esegui fino al cursore" . dape-until)
                           ("Leggi memoria…" . dape-memory)
                           ("Disassembla…" . dape-disassemble)))
            (let ((command (cdr entry)))
              (when (and (commandp command)
                         (or (eq state 'stopped) (eq command 'dape-repl))
                         (pcase command
                           ('dape-memory (plist-get data :memory))
                           ('dape-disassemble (plist-get data :disassemble))
                           (_ t)))
                (gdev-debug-workbench--button (car entry) command
                                             (lambda ()
                                               (gdev-debug-workbench--controls
                                                command (not (eq command 'dape-until))))))))
          (when (plist-get data :multiple)
            (gdev-debug-workbench--button
             "Scegli sessione…" 'select-session
             (lambda () (gdev-debug-select-workspace-session gdev-debug-workbench--owner)))))
      (gdev-debug-workbench--button (concat "Profilo · " (or profile "Automatico")) 'launch-profile
                                   #'gdev-project-view-select-profile)
      (when (commandp 'gdev-debug-dwim)
        (gdev-debug-workbench--button "Avvia debug" 'primary
                                     (lambda () (gdev-project-view-launch t))
                                     'gdev-debug-workbench-accent)
        (when result
          (gdev-debug-workbench--command "Console di debug" #'dape-repl))
        (gdev-debug-workbench--command "Collega a un processo…" #'gdev-debug-attach))
      (when (commandp 'gdev-run-dwim)
        (gdev-debug-workbench--button "Esegui" 'run (lambda () (gdev-project-view-launch))))
      (gdev-debug-workbench--command "Compila" #'gdev-build)
      (gdev-debug-workbench--command "Esegui attività…" #'gdev-run-project-task))
    (when (commandp 'gdev-debug-dwim)
      (insert "\n")
      (gdev-debug-workbench--text "Punti di interruzione" 'gdev-debug-workbench-heading)
      (gdev-debug-workbench--command "Gestisci punti di interruzione" #'gdev-debug-breakpoints-show)
      (when (plist-get data :exceptions)
        (gdev-debug-workbench--button
         "Eccezioni…" 'exception-filters
         (lambda () (gdev-debug-workbench--controls #'gdev-debug-exceptions))
         nil nil "Scegli quali eccezioni mettono in pausa questa sessione"))
      (gdev-debug-workbench--command "Attiva o rimuovi alla riga" #'dape-breakpoint-toggle)
      (gdev-debug-workbench--command "Imposta condizione…" #'dape-breakpoint-expression)
      (gdev-debug-workbench--command "Conta i passaggi…" #'dape-breakpoint-hits)
      (gdev-debug-workbench--command "Registra messaggio…" #'dape-breakpoint-log))))

(defconst gdev-debug-workbench--profilers
  '(("Programma"
     ("Profila il codice attivo" . gdev-profile-dwim)
     ("Profilo CPU con samply" . gdev-profile-samply)
     ("Registra con Instruments…" . gdev-profile-instruments)
     ("Grafico a fiamma…" . gdev-profile-flamegraph)
     ("Perdite di memoria…" . gdev-profile-leaks)
     ("Misura i tempi…" . gdev-profile-hyperfine))
    ("Verifiche"
     ("Copertura dei test" . gdev-profile-coverage)
     ("Errori di memoria · ASan" . gdev-profile-asan)
     ("Comportamento indefinito · UBSan" . gdev-profile-ubsan)
     ("Accessi concorrenti · TSan" . gdev-profile-tsan))
    ("Emacs"
     ("Profila CPU e memoria" . gdev-profile-emacs)
     ("Misura l’avvio" . gdev-profile-emacs-startup))))

(defun gdev-debug-workbench--profiling ()
  "Disegna le azioni di profilazione disponibili."
  (if (not (commandp 'gdev-profile-dwim))
      (gdev-debug-workbench--text "Attiva il modulo profiler." 'gdev-ui-secondary)
    (dolist (group gdev-debug-workbench--profilers)
      (gdev-debug-workbench--text (car group) 'gdev-debug-workbench-heading)
      (dolist (action (cdr group))
        (when (or gdev-macos-p (not (memq (cdr action) '(gdev-profile-instruments gdev-profile-leaks))))
          (gdev-debug-workbench--command (car action) (cdr action))))
      (insert "\n"))))

(defun gdev-debug-workbench--choose-process ()
  "Scegli un PID locale senza cambiare il processo del debugger."
  (let ((pid (gdev-read-process "Processo locale da osservare: ")))
    (unless (and (integerp pid) (> pid 0)) (user-error "Indica un PID positivo"))
    (setq gdev-debug-workbench--manual-pid pid
          gdev-debug-workbench--target nil)
    (gdev-debug-workbench-refresh-visible)))

(defun gdev-debug-workbench--inspect-process (network)
  "Mostra i file aperti o, con NETWORK, le connessioni del processo locale."
  (let* ((target (gdev-debug-workbench--target (gdev-debug-workbench--connection)))
         (lsof (executable-find "lsof")))
    (unless (and target (equal target gdev-debug-workbench--target)
                 (consp gdev-debug-workbench--sample))
      (user-error "Scegli prima un processo locale disponibile"))
    (unless lsof (user-error "lsof non disponibile"))
    (gdev-compile (gdev-command-line lsof "-nP" "-a" "-p" (number-to-string (car target))
                                     (when network "-i"))
                  (format "Debug · %s · PID %d" (if network "Connessioni" "File aperti") (car target))
                  temporary-file-directory)))

(defun gdev-debug-workbench--sparkline (history scale)
  "Disegna HISTORY dal campione più vecchio al più recente sulla SCALA."
  (mapconcat (lambda (value)
               (string (aref "·▁▂▃▄▅▆▇█" (min 8 (ceiling (* 8.0 (/ value (float scale))))))))
             (reverse history) ""))

(defun gdev-debug-workbench--metric (label history minimum formatter face)
  "Mostra LABEL, ultimo valore e grafico di HISTORY.
MINIMUM è il minimo della scala massima. FORMATTER mostra le unità e
FACE colora il grafico."
  (when history
    (let* ((peak (apply #'max history))
           (scale (max minimum peak))
           (description (format "%s · picco %s · scala 0–%s"
                                label (funcall formatter peak) (funcall formatter scale))))
      (gdev-debug-workbench--text
       (format "%s  %s" label (funcall formatter (car history)))
       'gdev-debug-workbench-heading description)
      (when (cdr history)
        (gdev-debug-workbench--text
         (gdev-debug-workbench--sparkline history scale) face
         (format "%s. Ultimo campione a destra." description))))))

(defun gdev-debug-workbench--system ()
  "Mostra separatamente il processo osservato e il sistema locale."
  (let* ((target (gdev-debug-workbench--target (gdev-debug-workbench--connection)))
         (sample (and (equal target gdev-debug-workbench--target)
                      gdev-debug-workbench--sample)))
    (gdev-debug-workbench--text "Processo locale" 'gdev-debug-workbench-heading)
    (if target
        (progn
          (gdev-debug-workbench--text (format "PID %d · %s" (car target)
                                            (if (eq (cdr target) 'manual) "Selezionato" "Debugger"))
                                      'gdev-ui-secondary)
          (cond ((consp sample)
                 (gdev-debug-workbench--metric "CPU" gdev-debug-workbench--cpu-history 100
                                               (lambda (cpu) (format "%.1f%%" cpu)) 'gdev-ui-action)
                 (gdev-debug-workbench--metric "RAM" gdev-debug-workbench--rss-history 1
                                               (lambda (rss) (file-size-human-readable rss 'iec " "))
                                               'gdev-debug-workbench-running)
                 (when (cdr gdev-debug-workbench--cpu-history)
                   (gdev-debug-workbench--text
                    (format "Ultimi %d campioni" (length gdev-debug-workbench--cpu-history))
                    'gdev-ui-secondary "CPU: 100% equivale a un core. RAM: memoria residente.")))
                ((eq sample 'unavailable)
                 (gdev-debug-workbench--text "Processo non disponibile" 'gdev-ui-secondary))
                (t (gdev-debug-workbench--text "In attesa del primo campione…" 'gdev-ui-secondary))))
      (gdev-debug-workbench--text "Nessun PID da osservare" 'gdev-ui-secondary))
    (gdev-debug-workbench--button "Osserva un processo…" 'observe #'gdev-debug-workbench--choose-process)
    (when gdev-debug-workbench--manual-pid
      (gdev-debug-workbench--button "Segui il debugger" 'follow
                                   (lambda ()
                                     (setq gdev-debug-workbench--manual-pid nil)
                                     (gdev-debug-workbench-refresh-visible))))
    (when (consp sample)
      (gdev-debug-workbench--button "File aperti" 'files
                                   (lambda () (gdev-debug-workbench--inspect-process nil)))
      (gdev-debug-workbench--button "Connessioni di rete" 'connections
                                   (lambda () (gdev-debug-workbench--inspect-process t))))
    (insert "\n")
    (gdev-debug-workbench--text (if gdev-macos-p "Questo Mac" "Sistema locale") 'gdev-debug-workbench-heading)
    (if-let* ((values (gdev-debug-workbench--machine)))
        (pcase-let ((`(,cpu ,used ,total ,network) values))
          (gdev-debug-workbench--text (format "CPU  %d%%" cpu))
          (gdev-debug-workbench--text (format "RAM  %.1f / %.1f GiB" (/ used 1073741824.0) (/ total 1073741824.0)))
          (when network
            (gdev-debug-workbench--text (format "Scarica  %s/s" (file-size-human-readable (car network) 'iec)))
            (gdev-debug-workbench--text (format "Invia  %s/s" (file-size-human-readable (cadr network) 'iec)))))
      (gdev-debug-workbench--text "Campione di sistema assente" 'gdev-ui-secondary))
    (when (and gdev-macos-p (commandp 'gdev-system-monitor-show))
      (gdev-debug-workbench--command "Dettagli del monitor" #'gdev-system-monitor-show))))

(defun gdev-debug-workbench-render (root profile)
  "Inserisci la pagina Debug attiva per ROOT e PROFILE."
  (gdev-debug-workbench--text "Debug" 'gdev-debug-workbench-title)
  (gdev-debug-workbench--text (file-name-nondirectory (directory-file-name root))
                              'gdev-ui-secondary (abbreviate-file-name root))
  (insert "\n")
  (let* ((labels (mapconcat #'cdr gdev-debug-workbench--pages " "))
         (inline (equal labels (gdev-debug-workbench--fit labels 'gdev-debug-workbench-accent))))
    (dolist (entry gdev-debug-workbench--pages)
      (let ((page (car entry))
            (label (cdr entry)))
        (unless (or (not inline) (eq entry (car gdev-debug-workbench--pages)))
          (insert " "))
        (gdev-debug-workbench--button label page
                                     (lambda () (gdev-debug-workbench-page page))
                                     (if (eq page gdev-debug-workbench--page)
                                         'gdev-debug-workbench-accent 'gdev-ui-secondary) inline)))
    (insert (if inline "\n\n" "\n")))
  (pcase gdev-debug-workbench--page
    ('session (gdev-debug-workbench--session profile))
    ('profile (gdev-debug-workbench--profiling))
    ('system (gdev-debug-workbench--system))))

(provide 'gdev-debug-workbench)
;;; gdev-debug-workbench.el ends here
