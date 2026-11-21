;;; gdev-voice-backend.el --- Preparazione e riconoscitore locale della voce -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il motore appartiene all'applicazione e rimane caldo tra due richieste.
;; Avvio, download e verifica avvengono soltanto su richiesta esplicita.
;; I callback del chiamante conservano separatamente l'identità del documento.
;;; Code:
(require 'gdev-voice)
(require 'gdev-compilation)
(require 'json)

(defcustom gdev-voice-model "small"
  "Modello multilingue del catalogo verificato, usato con lingua italiana."
  :type 'string :group 'gdev-voice)

(defvar gdev-voice-backend-process nil "Processo del riconoscitore locale posseduto da GDev.")
(defvar gdev-voice-backend-url nil "Indirizzo locale del solo motore pronto.")
(defvar gdev-voice-backend--installation nil)
(defvar gdev-voice-backend--preparation nil)
(defvar gdev-voice-backend--waiting nil)
(defvar gdev-voice-backend--timer nil)
(defvar gdev-voice-backend--prompt nil)
(defvar gdev-voice-backend--port nil)
(defvar gdev-voice-backend--model-catalog nil
  "Catalogo locale dei pesi, letto una sola volta senza preparare strumenti.")

(defun gdev-voice-backend-model-size ()
  "Restituisci i byte dei pesi selezionati dal catalogo locale, oppure nil."
  (condition-case nil
      (let* ((catalog (or gdev-voice-backend--model-catalog
                          (setq gdev-voice-backend--model-catalog
                                (with-temp-buffer
                                  (insert-file-contents (gdev-config-file "bin/gdev-voice-models.json"))
                                  (json-parse-buffer :object-type 'alist)))))
             (model (alist-get (intern gdev-voice-model) (alist-get 'models catalog)))
             (size (alist-get 'size model)))
        (and (integerp size) (> size 0) size))
    (error nil)))
(defvar gdev-voice-backend--generation 0)

(defun gdev-voice-backend-model-directory ()
  "Restituisci la cartella gestita del modello, fuori dal checkout."
  (gdev-tools-file "voce/"))

(defun gdev-voice-backend--deliver (ok detail)
  "Consegna OK e DETAIL una sola volta ai chiamanti in attesa."
  (let ((callbacks (prog1 gdev-voice-backend--waiting (setq gdev-voice-backend--waiting nil))))
    (dolist (callback (nreverse callbacks))
      (condition-case error
          (funcall callback ok detail)
        (error (message "Voce: %s" (error-message-string error)))))))

(defun gdev-voice-backend-prepare (callback &optional check)
  "Prepara strumenti e modello senza bloccare; consegna l'esito a CALLBACK."
  (if (buffer-live-p gdev-voice-backend--preparation)
      (user-error "La preparazione della voce è già in corso")
    (let* ((python (or (executable-find "python3") (user-error "Installa Python 3 per preparare la voce")))
           (directory (gdev-voice-backend-model-directory))
           (command (apply #'gdev-command-line python (gdev-config-file "bin/gdev-voice-prepare.py")
                           (append (list "--directory" directory "--model" gdev-voice-model)
                                   (when check '("--check")))))
           starts
           (compilation-start-hook
            (cons (lambda (process) (push (cons (process-buffer process) process) starts)) compilation-start-hook)))
      (make-directory directory t)
      (setq gdev-voice-backend--preparation (gdev-compile command "Preparazione voce" directory))
      (let ((child (cdr (assq gdev-voice-backend--preparation (nreverse starts)))))
        (gdev-compilation-on-finish
         gdev-voice-backend--preparation
         (lambda (buffer)
         (when (eq buffer gdev-voice-backend--preparation)
           (setq gdev-voice-backend--preparation nil))
         (if (not (and child (gdev-compilation-succeeded-p child)))
             (funcall callback nil "Preparazione non completata: consulta il pannello Preparazione voce")
           (let ((result (condition-case error
               (let* ((receipt (expand-file-name "installazione.json" directory))
                      (data (with-temp-buffer
                              (insert-file-contents receipt)
                              (json-parse-buffer :object-type 'alist :null-object nil :false-object nil))))
                 (unless (and (eq t (alist-get 'ok data))
                              (file-readable-p (alist-get 'model data))
                              (file-executable-p (alist-get 'recognizer data)))
                   (error "Riscontro di installazione non valido"))
                 (setq gdev-voice-backend--installation data)
                 (cons t data))
             (error (cons nil (error-message-string error))))))
             (funcall callback (car result) (cdr result)))))))
      gdev-voice-backend--preparation)))

(defun gdev-voice-backend--log (process output)
  "Conserva una diagnosi limitata di PROCESS in memoria.
Non scrive file di trascrizioni."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t))
        (goto-char (point-max)) (insert output)
        (when (> (buffer-size) 16000) (delete-region (point-min) (- (point-max) 12000)))))))

(defun gdev-voice-diagnostics ()
  "Mostra la diagnosi del motore locale senza avviarlo."
  (interactive)
  (let ((buffer (or (get-buffer " *gdev-voce-motore*")
                    (user-error "Nessuna diagnosi: il motore vocale non è stato avviato"))))
    (require 'gdev-ui)
    (with-current-buffer buffer
      (special-mode)
      (gdev-ui-view-setup 'document)
      (gdev-layout-mark-auxiliary))
    (if (bound-and-true-p gdev-layout-mode) (pop-to-buffer buffer)
      (select-window (display-buffer-in-side-window buffer '((side . bottom) (window-height . 0.4)))))))

(defun gdev-voice-backend--poll (process deadline)
  "Verifica la disponibilità di PROCESS fino a DEADLINE, senza leggere audio."
  (when (eq process gdev-voice-backend-process)
    (cond
     ((not (process-live-p process))
      (gdev-voice-backend--deliver nil "Il motore vocale non si è avviato; consulta la diagnosi Voce"))
     ((> (float-time) deadline)
      (gdev-voice-backend-stop "Il motore vocale non è diventato pronto entro il tempo previsto"))
     (t
      (let* ((url (format "http://127.0.0.1:%d" gdev-voice-backend--port))
             (buffer (generate-new-buffer " *gdev-voice-health*"))
             (probe
              (make-process
               :name "gdev-voice-health" :buffer buffer :connection-type 'pipe :noquery t :coding 'utf-8-unix
               :command (list (or (alist-get 'transport gdev-voice-backend--installation) "curl")
                              "--silent" "--fail" "--noproxy" "*" "--max-time" "1" (concat url "/health"))
               :sentinel
               (lambda (child _event)
                 (when (memq (process-status child) '(exit signal))
                   (let ((ready
                          (and (zerop (process-exit-status child))
                               (buffer-live-p buffer)
                               (condition-case nil
                                   (with-current-buffer buffer
                                     (goto-char (point-min))
                                     (equal "ok" (alist-get 'status (json-parse-buffer :object-type 'alist))))
                                 (error nil)))))
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (when (eq process gdev-voice-backend-process)
                       (if ready
                           (progn (setq gdev-voice-backend-url url) (gdev-voice-backend--deliver t url))
                         (setq gdev-voice-backend--timer
                               (run-with-timer 0.2 nil #'gdev-voice-backend--poll process deadline))))))))))
        (process-put process 'gdev-voice-health probe))))))

(defun gdev-voice-backend--start (prompt)
  "Avvia il motore preparato con PROMPT, scegliendo una porta locale libera."
  (let ((reservation (make-network-process :name "gdev-voice-port" :server t :host "127.0.0.1"
                                          :service t :noquery t)))
    (setq gdev-voice-backend--port (process-contact reservation :service))
    (delete-process reservation))
  (let* ((data gdev-voice-backend--installation)
         (arguments (list (alist-get 'recognizer data) "-m" (alist-get 'model data)
                          "-l" "it" "--host" "127.0.0.1" "--port" (number-to-string gdev-voice-backend--port)
                          "--inference-path" "/v1/audio/transcriptions" "--prompt" prompt))
         (buffer (get-buffer-create " *gdev-voce-motore*")))
    (with-current-buffer buffer (let ((inhibit-read-only t)) (erase-buffer)))
    (setq gdev-voice-backend--prompt prompt
          gdev-voice-backend-process
          (make-process :name "gdev-voice-recognizer" :command arguments :buffer buffer
                        :coding 'utf-8-unix :connection-type 'pipe :noquery t
                        :filter #'gdev-voice-backend--log))
    (gdev-voice-backend--poll gdev-voice-backend-process (+ (float-time) 60))))

(defun gdev-voice-backend-ensure (vocabulary callback)
  "Rendi pronto il motore con VOCABULARY e consegna l'esito a CALLBACK."
  (let ((prompt (concat "Trascrizione in italiano. " (string-join vocabulary ", ") ".")))
    (cond
     ((and (process-live-p gdev-voice-backend-process) gdev-voice-backend-url
           (equal prompt gdev-voice-backend--prompt))
      (funcall callback t gdev-voice-backend-url))
     ((process-live-p gdev-voice-backend-process)
      (if (equal prompt gdev-voice-backend--prompt)
          (push callback gdev-voice-backend--waiting)
        (gdev-voice-backend-stop)
        (push callback gdev-voice-backend--waiting)
        (gdev-voice-backend--start prompt)))
     (t
      (push callback gdev-voice-backend--waiting)
      (if gdev-voice-backend--installation
          (gdev-voice-backend--start prompt)
        (let ((generation gdev-voice-backend--generation))
          (gdev-voice-backend-prepare
           (lambda (ok detail)
             (when (= generation gdev-voice-backend--generation)
               (if ok (gdev-voice-backend--start prompt)
                 (gdev-voice-backend--deliver nil detail)))) t)))))))

(defun gdev-voice-backend-stop (&optional reason)
  "Arresta il solo motore posseduto da GDev e invalida i seguiti con REASON."
  (cl-incf gdev-voice-backend--generation)
  (let ((preparation gdev-voice-backend--preparation))
    (setq gdev-voice-backend--preparation nil)
    (when-let* ((child (and (buffer-live-p preparation) (get-buffer-process preparation))))
      (when (process-live-p child) (delete-process child))))
  (when (timerp gdev-voice-backend--timer) (cancel-timer gdev-voice-backend--timer))
  (let ((process gdev-voice-backend-process))
    (setq gdev-voice-backend-process nil gdev-voice-backend-url nil gdev-voice-backend--timer nil)
    (when-let* ((probe (and (processp process) (process-get process 'gdev-voice-health))))
      (when (process-live-p probe) (delete-process probe)))
    (when (process-live-p process) (delete-process process)))
  (gdev-voice-backend--deliver nil (or reason "Avvio del motore vocale interrotto")))

(add-hook 'kill-emacs-hook #'gdev-voice-backend-stop)

(provide 'gdev-voice-backend)
;;; gdev-voice-backend.el ends here
