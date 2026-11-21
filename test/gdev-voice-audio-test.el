;;; gdev-voice-audio-test.el --- Risposte vocali e ciclo delle richieste -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Le risposte simulate verificano consegna, annullamento e completamento
;; immediato senza microfono, rete o installazione di modelli.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'gdev-voice-audio)

;; Le prove a monte restano nel corpus ordinario, con gli stessi contratti.
(gdev-voice--fork)
(load (gdev-config-file "vendor/elpa/earwig-0.2.0/test/earwig-test.el") nil t t)

;; Il corpus usa la selezione attiva e due casi attivano il modo globale.
;; Ogni corpo ERT riceve lo stesso stato iniziale e ripristina quello del
;; chiamante. Le fonti a monte restano intatte e verificabili dall'impronta.
(dolist (test (ert-select-tests "^earwig-test-" t))
  (let ((body (ert-test-body test)))
    (setf (ert-test-body test)
          (lambda ()
            (let ((transient-mark-mode t)
                  (earwig-speech-server-base-url (or (getenv "GDEV_TEST_VOICE_SERVER") "http://127.0.0.1:0")))
              (funcall body))))))

(ert-deftest gdev-test-voice-upstream-selection-preserves-transient-mark-mode ()
  "Le selezioni del corpus ripristinano il modo globale in entrambi gli stati."
  (dolist (initial '(nil t))
    (let ((transient-mark-mode initial))
      (dolist (name '(earwig-test-part-range earwig-test-go-back))
        (funcall (ert-test-body (ert-get-test name)))
        (should (eq transient-mark-mode initial))))))

(defmacro gdev-voice-test--session (kind &rest body)
  "Isola una sessione KIND ed esegui BODY nel documento della prova."
  (declare (indent 1))
  `(let ((gdev-voice--session nil)
         (gdev-voice-backend-process nil)
         (post-command-hook (copy-sequence post-command-hook))
         (global-mode-string (copy-tree global-mode-string)))
     (unwind-protect
         (progn
           (gdev-voice--attach
            (gdev-voice-session-create :kind ,kind :phase 'listening :context (gdev-voice-context)))
           ,@body)
       (gdev-voice-stop))))

(ert-deftest gdev-test-voice-disabled-does-not-install-start-or-download ()
  (gdev-voice-test--document "testo"
    (let ((gdev-voice--session nil) (gdev-voice-recognizer nil) opened)
      (cl-letf (((symbol-function 'gdev-voice-open) (lambda () (setq opened t)))
                ((symbol-function 'gdev-voice-backend-prepare) (lambda (&rest _) (ert-fail "Preparazione implicita")))
                ((symbol-function 'gdev-voice-backend-ensure) (lambda (&rest _) (ert-fail "Motore implicito"))))
        (gdev-voice-start-dictation)
        (should opened)
        (should-not gdev-voice--session)
        (should (equal (buffer-string) "testo"))))))

(ert-deftest gdev-test-voice-canceled-preparation-can-be-started-again ()
  (gdev-voice-test--document "documento"
    (let* ((root (make-temp-file "gdev-voice-prepare-test-" t))
           (gdev-tools-directory root)
           (gdev-voice--session nil)
           (gdev-voice-recognizer nil)
           (gdev-voice-backend--preparation nil)
           (real-compile (symbol-function 'gdev-compile)) outputs)
      (unwind-protect
          (cl-letf (((symbol-function 'gdev-compile)
                     (lambda (_command _name directory &rest _)
                       (let ((buffer (funcall real-compile "sleep 30" (make-temp-name "Preparazione voce test ") directory)))
                         (push buffer outputs) buffer))))
            (dotimes (_ 2)
              (gdev-voice-prepare)
              (should (gdev-voice--preparing-p))
              (should-not gdev-voice--session)
              (should gdev-voice--active)
              (goto-char (point-max)) (insert " modifica umana")
              (gdev-voice--watch-context)
              (should (gdev-voice--preparing-p))
              (let ((real-make-process (symbol-function 'make-process)) (system-type 'darwin))
                (cl-letf (((symbol-function 'gdev-voice-voices) (lambda () '("it")))
                          ((symbol-function 'make-process)
                           (lambda (&rest options)
                             (apply real-make-process
                                    (plist-put options :command '("sh" "-c" "sleep 30"))))))
                  (goto-char (point-min))
                  (gdev-voice-read)
                  (should (eq 'read (gdev-voice-session-kind gdev-voice--session)))
                  (should (gdev-voice--preparing-p))
                  (gdev-voice-stop t)
                  (should (gdev-voice--preparing-p))))
              (gdev-voice-stop)
              (let ((deadline (+ (float-time) 2)))
                (while (and gdev-voice-backend--preparation (< (float-time) deadline))
                  (accept-process-output nil 0.02)))
              (should-not gdev-voice--session)
              (should-not gdev-voice-backend--preparation)
              (should-not gdev-voice-recognizer)))
        (gdev-voice-stop)
        (dolist (buffer outputs)
          (when (buffer-live-p buffer)
            (when-let* ((process (get-buffer-process buffer))) (delete-process process))
            (kill-buffer buffer)))
        (delete-directory root t)))))

(ert-deftest gdev-test-voice-preparation-completion-does-not-stop-reading-or-enable-after-cancel ()
  (gdev-voice-test--document "documento"
    (gdev-voice-test--session 'read
      (let ((original gdev-voice--session) reply enabled
            (gdev-voice-backend--generation 0))
        (cl-letf (((symbol-function 'gdev-voice-backend-prepare)
                   (lambda (callback &rest _) (setq reply callback)))
                  ((symbol-function 'customize-save-variable)
                   (lambda (variable value &rest _) (should (eq variable 'gdev-voice-recognizer)) (setq enabled value))))
          (gdev-voice-prepare)
          (should (eq original gdev-voice--session))
          (funcall reply t 'ready)
          (should (eq enabled 'whisper))
          (should (eq original gdev-voice--session))
          (setq enabled nil)
          (gdev-voice-prepare)
          (gdev-voice-backend-stop)
          (funcall reply t 'late)
          (should-not enabled)
          (should (eq original gdev-voice--session)))))))

(ert-deftest gdev-test-voice-context-and-human-edit-invalidate-pending-text ()
  (gdev-voice-test--document "uno"
    (gdev-voice-test--session 'command
      (let (reply delivered)
        (cl-letf (((symbol-function 'earwig-server-transcribe-default)
                   (lambda (_file callback) (setq reply callback) nil)))
          (gdev-voice--transcribe "non-letto.wav" (lambda (&rest _) (setq delivered t)))
          (put-text-property (point-min) (point-max) 'face 'bold)
          (should (gdev-voice--valid-p gdev-voice--session))
          (goto-char (point-max)) (insert " umano")
          (should-not (gdev-voice--valid-p gdev-voice--session))
          (funcall reply t "non deve entrare")
          (should-not delivered)
          (should (equal (buffer-substring-no-properties (point-min) (point-max)) "uno umano")))))))

(ert-deftest gdev-test-voice-late-result-cannot-affect-a-new-session ()
  (gdev-voice-test--document "uno"
    (gdev-voice-test--session 'command
      (let (reply delivered)
        (cl-letf (((symbol-function 'earwig-server-transcribe-default)
                   (lambda (_file callback) (setq reply callback) nil)))
          (gdev-voice--transcribe "non-letto.wav" (lambda (&rest _) (setq delivered t)))
          (gdev-voice-stop)
          (let ((new (gdev-voice-session-create :kind 'read :phase 'reading :context (gdev-voice-context))))
            (gdev-voice--attach new)
            (funcall reply t "risposta vecchia")
            (should (eq new gdev-voice--session))
            (should (eq 'reading (gdev-voice-session-phase new)))
            (should-not delivered)))))))

(ert-deftest gdev-test-voice-cancel-releases-recorders-requests-files-and-hooks ()
  (gdev-voice-test--document "testo già presente"
    (let* ((earwig--record-process (make-process :name "gdev-voice-test-record" :command '("sh" "-c" "sleep 30") :noquery t))
           (earwig--record-request nil)
           (earwig--preview-request (make-process :name "gdev-voice-test-request" :command '("sh" "-c" "sleep 30") :noquery t))
           (earwig--record-file (make-temp-file "gdev-voice-test-" nil ".wav"))
           (earwig--preview-file (make-temp-file "gdev-voice-test-preview-" nil ".wav"))
           (earwig--record-target (copy-marker (point)))
           (earwig--stream-dir nil) (earwig--stream-process nil) (earwig--stream-curl nil)
           (earwig--phase 'recording)
           (recorder earwig--record-process) (request earwig--preview-request)
           (file earwig--record-file) (preview earwig--preview-file) late)
      (set-process-sentinel recorder (lambda (&rest _) (setq late t)))
      (set-process-sentinel request (lambda (&rest _) (setq late t)))
      (gdev-voice-test--session 'command
        (gdev-voice-stop)
        (accept-process-output nil 0.01)
        (should-not late)
        (should-not (process-live-p recorder))
        (should-not (process-live-p request))
        (should-not (file-exists-p file))
        (should-not (file-exists-p preview))
        (should-not (memq #'gdev-voice--after-change after-change-functions))
        (should-not (memq #'gdev-voice--watch-context post-command-hook))
        (should-not gdev-voice--session)
        (should (equal "testo già presente" (buffer-string)))))))

(ert-deftest gdev-test-voice-italian-dictation-keeps-punctuation-and-literal-words ()
  (gdev-voice-test--document ""
    (gdev-voice-test--session 'dictate
      (should (equal (gdev-voice--process-text "Ciao virgola mondo punto" document (point)) "Ciao, mondo."))
      (should (equal (gdev-voice--process-text "letterale virgola" document (point)) "virgola"))
      (should-not (gdev-voice--process-text "comando, frase inesistente" document (point))))))

(ert-deftest gdev-test-voice-corrections-apply-once-and-do-not-rewrite-typed-commands ()
  (gdev-voice-test--document ""
    (gdev-voice-test--session 'dictate
      (let ((gdev-voice-corrections '(("alfa" . "beta") ("beta" . "gamma"))))
        (should (equal (gdev-voice--process-text "alfa" document (point)) "beta"))
        (should (equal (gdev-voice-italian-parse "cerca alfa" nil) '((:kind search :text "alfa"))))))))

(ert-deftest gdev-test-voice-cancel-preserves-the-minibuffer-quit-command ()
  (cl-letf (((symbol-function 'minibufferp) (lambda (&rest _) t)))
    (should-not (gdev-voice--cancel-key #'gdev-voice-stop)))
  (cl-letf (((symbol-function 'minibufferp) (lambda (&rest _) nil)))
    (should (eq #'gdev-voice-stop (gdev-voice--cancel-key #'gdev-voice-stop)))))

(ert-deftest gdev-test-voice-canceled-readiness-cannot-start-a-late-engine ()
  (let ((gdev-voice-backend-process nil) (gdev-voice-backend--installation nil)
        (gdev-voice-backend--waiting nil) (gdev-voice-backend--generation 0)
        reply delivered started)
    (cl-letf (((symbol-function 'gdev-voice-backend-prepare)
               (lambda (callback check) (should check) (setq reply callback)))
              ((symbol-function 'gdev-voice-backend--start) (lambda (&rest _) (setq started t))))
      (gdev-voice-backend-ensure '("GDev") (lambda (ok _detail) (setq delivered (list ok))))
      (gdev-voice-backend-stop)
      (funcall reply t 'installation)
      (should-not started)
      (should (equal delivered '(nil)))
      (should-not gdev-voice-backend--waiting))))

(ert-deftest gdev-test-voice-readiness-requires-a-real-health-response ()
  (let* ((engine (make-process :name "gdev-test-voice-engine" :command '("sh" "-c" "sleep 10") :noquery t))
         (body "{\"status\":\"loading model\"}") delivered
         (server (make-network-process
                  :name "gdev-test-voice-health-server" :server t :host "127.0.0.1" :service t :noquery t
                  :filter (lambda (client _request)
                            (process-send-string client (format "HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n%s" (string-bytes body) body))
                            (delete-process client))))
         (gdev-voice-backend-process engine)
         (gdev-voice-backend--timer nil)
         (gdev-voice-backend--installation nil)
         (gdev-voice-backend-url nil)
         (gdev-voice-backend--port (process-contact server :service))
         (gdev-voice-backend--waiting (list (lambda (ok _detail) (setq delivered ok)))))
    (unwind-protect
        (progn
          (gdev-voice-backend--poll engine (+ (float-time) 5))
          (let ((end (+ (float-time) 0.3)))
            (while (< (float-time) end) (accept-process-output nil 0.02)))
          (should-not delivered)
          (should-not gdev-voice-backend-url)
          (setq body "{\"status\":\"ok\"}")
          (let ((end (+ (float-time) 3)))
            (while (and (not delivered) (< (float-time) end)) (accept-process-output nil 0.02)))
          (should delivered)
          (should (string-prefix-p "http://127.0.0.1:" gdev-voice-backend-url)))
      (gdev-voice-backend-stop)
      (delete-process server))))

(ert-deftest gdev-test-voice-reading-uses-stdin-selection-and-native-controls ()
  (gdev-voice-test--document "prima testo scelto dopo"
    (let ((gdev-voice--session nil) (gdev-voice-reading-voice nil) (system-type 'darwin)
          arguments output sent eof signals)
      (goto-char 7) (push-mark 19 t t)
      (cl-letf (((symbol-function 'gdev-voice-voices) (lambda () '("Voce italiana")))
                ((symbol-function 'make-process)
                 (lambda (&rest options) (setq arguments (plist-get options :command)
                                              output (plist-get options :buffer)) 'reader))
                ((symbol-function 'process-send-string) (lambda (_process text) (setq sent text)))
                ((symbol-function 'process-send-eof) (lambda (_) (setq eof t)))
                ((symbol-function 'process-live-p) (lambda (process) (eq process 'reader)))
                ((symbol-function 'signal-process) (lambda (_process signal) (push signal signals)))
                ((symbol-function 'continue-process) (lambda (_) (push 'continue signals))))
        (unwind-protect
            (progn
              (gdev-voice-read)
              (should (equal "testo scelto" sent))
              (should eof)
              (should (equal (cl-subseq arguments 0 3) '("/usr/bin/say" "-v" "Voce italiana")))
              (should-not (member sent arguments))
              (gdev-voice-pause)
              (should (eq 'paused (gdev-voice-session-phase gdev-voice--session)))
              (gdev-voice-pause)
              (should (equal signals '(continue SIGSTOP))))
          (when gdev-voice--session (gdev-voice--finish gdev-voice--session))
          (when (buffer-live-p output) (kill-buffer output)))))))

(ert-deftest gdev-test-voice-view-opens-without-audio-and-preserves-document ()
  (gdev-voice-test--document "documento"
    (require 'gdev-voice-view)
    (cl-letf (((symbol-function 'gdev-voice-backend-prepare) (lambda (&rest _) (ert-fail "Download dalla vista")))
              ((symbol-function 'gdev-voice-backend-ensure) (lambda (&rest _) (ert-fail "Motore dalla vista"))))
      (unwind-protect
          (progn
            (gdev-voice-open)
            (should (eq document (gdev-editor-document)))
            (with-current-buffer "*Voce GDev*"
              (should (derived-mode-p 'gdev-voice-view-mode))
              (goto-char (text-property-any (point-min) (point-max) 'gdev-voice-action #'gdev-voice-read))
              (gdev-voice-view-render)
              (should (eq #'gdev-voice-read (get-text-property (point) 'gdev-voice-action)))))
        (when (get-buffer "*Voce GDev*") (kill-buffer "*Voce GDev*"))))))

(ert-deftest gdev-test-voice-transcription-immediate-result-does-not-retain-request ()
  (gdev-voice-test--document "uno"
    (let* ((session (gdev-voice-session-create :context (gdev-voice-context)))
           (gdev-voice--session session)
           (process-environment (append '("no_proxy=example.test" "NO_PROXY=example.test") process-environment))
           delivered)
      (cl-letf (((symbol-function 'earwig-server-transcribe-default)
                 (lambda (_file callback)
                   (should (equal "*" (getenv "no_proxy")))
                   (should (equal "*" (getenv "NO_PROXY")))
                   (funcall callback t "due")
                   'completed-request)))
        (should (eq 'completed-request
                    (gdev-voice--transcribe "audio.wav"
                                           (lambda (ok text) (setq delivered (list ok text))))))
        (should (equal delivered '(t "due")))
        (should (equal "example.test" (getenv "no_proxy")))
        (should-not (gdev-voice-session-requests session))))))

(ert-deftest gdev-test-voice-transcription-releases-request-and-tracks-applied-text ()
  (gdev-voice-test--document "uno"
    (let* ((session (gdev-voice-session-create :context (gdev-voice-context)))
           (gdev-voice--session session)
           reply applying)
      (cl-letf (((symbol-function 'earwig-server-transcribe-default)
                 (lambda (_file callback) (setq reply callback) 'pending-request)))
        (gdev-voice--transcribe "audio.wav"
                               (lambda (ok text)
                                 (should ok)
                                 (setq applying gdev-voice--applying)
                                 (goto-char (point-max)) (insert text)))
        (should (equal (gdev-voice-session-requests session) '(pending-request)))
        (funcall reply t " due")
        (should applying)
        (should (equal (buffer-string) "uno due"))
        (should-not (gdev-voice-session-requests session))
        (should (= (gdev-voice-session-tick session) (buffer-chars-modified-tick)))))))

(ert-deftest gdev-test-voice-transcription-after-cancel-does-not-deliver ()
  (gdev-voice-test--document "uno"
    (let* ((session (gdev-voice-session-create :context (gdev-voice-context)))
           (gdev-voice--session session)
           reply delivered)
      (cl-letf (((symbol-function 'earwig-server-transcribe-default)
                 (lambda (_file callback) (setq reply callback) 'pending-request)))
        (gdev-voice--transcribe "audio.wav" (lambda (&rest _) (setq delivered t)))
        (setq gdev-voice--session nil)
        (funcall reply t "risposta superata")
        (should-not delivered)
        (should-not (gdev-voice-session-requests session))
        (should (equal (buffer-string) "uno"))))))

(ert-deftest gdev-test-voice-view-model-size-follows-the-selected-catalog-entry ()
  "La dimensione mostrata segue i pesi selezionati senza avviare il motore."
  (gdev-voice-test--document "documento"
    (require 'gdev-voice-view)
    (let ((gdev-voice-recognizer nil)
          (gdev-voice--session nil)
          (gdev-voice-model "small")
          (gdev-voice-backend--model-catalog
           '((models . ((small . ((size . 10000000))) (tiny . ((size . 2000000))))))))
      (unwind-protect
          (progn
            (gdev-voice-open)
            (with-current-buffer "*Voce GDev*"
              (should (string-search "Pesi del modello: 10 MB" (buffer-string)))
              (setq gdev-voice-model "tiny")
              (gdev-voice-view-render)
              (should (string-search "Pesi del modello: 2 MB" (buffer-string)))))
        (when (get-buffer "*Voce GDev*") (kill-buffer "*Voce GDev*"))))))

(provide 'gdev-voice-audio-test)
;;; gdev-voice-audio-test.el ends here
