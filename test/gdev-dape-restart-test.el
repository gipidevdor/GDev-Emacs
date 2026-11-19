;;; gdev-dape-restart-test.el --- Prove del riavvio di GDev Debug -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'ordine delle risposte DAP, la riconnessione di un processo e
;; la riga di stato della sessione.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar dape--connections)
(defvar dape--connection-selected)
(defvar dape--breakpoints)
(defvar dape--mode-line-format)
(defvar dape--inlay-hint-overlays)

(defmacro gdev-test-dape-restart--with-connection (binding &rest body)
  "Esegui BODY con la connessione temporanea descritta da BINDING.
BINDING ha la forma (CONNESSIONE CONFIGURAZIONE CAPACITÀ)."
  (declare (indent 1) (debug ((symbolp form form) body)))
  (let ((process (make-symbol "process"))
        (conn (car binding)))
    `(progn
       (package-activate-all)
       (require 'dape)
       (let* ((,process (make-pipe-process :name "gdev-test-dape-restart" :noquery t))
              (,conn (make-instance 'dape-connection :name (process-name ,process)
                                    :process ,process :parent nil :config ,(nth 1 binding)))
              (dape--breakpoints nil)
              (dape--connections (list ,conn))
              (dape--connection-selected ,conn))
         (unwind-protect
             (progn
               (setf (dape--capabilities ,conn) ,(nth 2 binding))
               ,@body)
           (delete-process ,process)
           (jsonrpc-shutdown ,conn t)
           (kill-buffer (jsonrpc-events-buffer ,conn)))))))

(ert-deftest gdev-test-dape-restart-rejection-retains-stopped-session ()
  "Un riavvio rifiutato conserva il contesto e consente un nuovo tentativo."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch" :program "programma" gdev-workspace spazio)
            '(:supportsRestartRequest t))
    (let (requests reply warning cleared)
      (setf (dape--state conn) 'stopped
            (dape--thread-id conn) 15
            (dape--threads conn) '((:id 15 :status stopped))
            (dape--stack-id conn) 22
            (dape--modules conn) '(modulo)
            (dape--sources conn) '(sorgente))
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (connection command args callback)
                   (should (eq connection conn))
                   (push (list command args) requests)
                   (setq reply callback)))
                ((symbol-function 'dape--warn)
                 (lambda (format &rest args) (setq warning (apply #'format format args))))
                ((symbol-function 'dape--stack-frame-cleanup) (lambda () (setq cleared t))))
        (dape-restart conn)
        (dape-restart conn)
        (should (equal requests '((:restart (:arguments (:request "launch" :program "programma"))))))
        (should-not cleared)
        (funcall reply nil "richiesta rifiutata")
        (should (string-match-p "richiesta rifiutata" warning))
        (should-not (dape--restart-in-progress-p conn))
        (should (eq (dape--state conn) 'stopped))
        (should (equal (dape--threads conn) '((:id 15 :status stopped))))
        (should (= (dape--thread-id conn) 15))
        (should (= (dape--stack-id conn) 22))
        (should (equal (dape--modules conn) '(modulo)))
        (should (equal (dape--sources conn) '(sorgente)))
        (should (eq dape--connection-selected conn))
        (should-not cleared)
        (dape-restart conn)
        (should (= (length requests) 2))))))

(ert-deftest gdev-test-dape-restart-native-clears-only-confirmed-context ()
  "La conferma pulisce il contesto cessato e mantiene la sessione scelta."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch") '(:supportsRestartRequest t))
    (let ((dape--connection-selected 'another-session)
          (dape-state-change-hook nil)
          (dape-update-ui-hook nil)
          (dape-ui-debounce-time 0)
          reply)
      (setf (dape--state conn) 'stopped
            (dape--thread-id conn) 15
            (dape--stack-id conn) 22
            (dape--exception-description conn) "eccezione precedente")
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection _command _args callback) (setq reply callback)))
                ((symbol-function 'dape--stack-frame-cleanup)
                 (lambda () (ert-fail "Contesto dell'altra sessione rimosso")))
                ((symbol-function 'dape--mode-line-format) #'ignore))
        (dape-restart conn)
        (should (eq (dape--state conn) 'stopped))
        (funcall reply nil nil)
        (should (eq (dape--state conn) 'starting))
        (should-not (dape--thread-id conn))
        (should-not (dape--stack-id conn))
        (should-not (dape--exception-description conn))
        (should (eq dape--connection-selected 'another-session))))))

(ert-deftest gdev-test-dape-restart-native-removes-previous-inline-values ()
  "La conferma del riavvio toglie i valori in linea del processo cessato."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch") '(:supportsRestartRequest t))
    (let ((dape-state-change-hook nil)
          (dape-update-ui-hook nil)
          (dape-ui-debounce-time 0)
          reply)
      (setf (dape--state conn) 'stopped
            (dape--thread-id conn) 15)
      (with-temp-buffer
        (insert "int current = 0;\nreturn current;\n")
        (let* ((current (make-overlay 1 2))
               (previous (make-overlay 18 19))
               (dape--inlay-hint-overlays (list current previous)))
          (cl-letf (((symbol-function 'dape-request)
                     (lambda (_connection _command _args callback) (setq reply callback)))
                    ((symbol-function 'dape--mode-line-format) #'ignore))
            (dape-restart conn)
            ;; Finché l'adattatore non conferma, la pausa resta quella mostrata.
            (should (overlay-buffer current))
            (funcall reply nil nil)
            (should (eq (dape--state conn) 'starting))
            (should-not (overlay-buffer current))
            (should-not (overlay-buffer previous))
            (should-not dape--inlay-hint-overlays)))))))

(ert-deftest gdev-test-dape-restart-keeps-a-stop-before-the-acknowledgement ()
  "Una pausa del nuovo processo ricevuta in anticipo resta visibile."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch") '(:supportsRestartRequest t))
    (let ((dape-state-change-hook nil)
          (dape-stopped-hook nil)
          (dape-update-ui-hook nil)
          (dape-ui-debounce-time 0)
          reply)
      (setf (dape--state conn) 'stopped
            (dape--thread-id conn) 15
            (dape--threads conn) '((:id 15 :status stopped)))
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection _command _args callback) (setq reply callback)))
                ((symbol-function 'dape--update-threads) #'ignore)
                ((symbol-function 'dape--stack-frame-cleanup) #'ignore)
                ((symbol-function 'dape--mode-line-format) #'ignore))
        (dape-restart conn)
        (dape-handle-event conn 'stopped '(:threadId 37 :reason "entry"))
        (funcall reply nil nil)
        (should (eq (dape--state conn) 'stopped))
        (should (equal (dape--state-reason conn) "entry"))
        (should (= (dape--thread-id conn) 37))
        (should (equal (mapcar (lambda (thread) (plist-get thread :id))
                               (dape--threads conn))
                       '(37)))))))

(ert-deftest gdev-test-dape-restart-reconnect-preserves-attach-process ()
  "La riconnessione riusa PID e spazio della configurazione già valutata."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "attach" :pid 715 gdev-workspace spazio)
            '(:supportsTerminateRequest t :supportTerminateDebuggee t))
    (let ((dape-state-change-hook nil)
          (dape-ui-debounce-time 0)
          reply actions)
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (connection command args callback)
                   (should (eq connection conn))
                   (push (list command args) actions)
                   (setq reply callback)))
                ((symbol-function 'dape--shutdown) (lambda (_) (push 'shutdown actions)))
                ((symbol-function 'dape--start-with-config)
                 (lambda (config) (push (list 'start config) actions)))
                ((symbol-function 'dape--mode-line-format) #'ignore))
        (dape-restart conn)
        (dape-restart conn)
        (dape-handle-event conn 'terminated nil)
        (should (equal actions '((:disconnect (:restart t :terminateDebuggee :json-false)))))
        (funcall reply nil nil)
        (should (equal (nreverse actions)
                       '((:disconnect (:restart t :terminateDebuggee :json-false))
                         shutdown
                         (start (:request "attach" :pid 715 gdev-workspace spazio)))))
        (should-not (dape--restart-in-progress-p conn))))))

(ert-deftest gdev-test-dape-restart-reconnect-checks-owner-after-disconnect ()
  "La chiusura dello spazio durante la disconnessione impedisce la riapertura."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch") '(:supportTerminateDebuggee t))
    (let ((dape-state-change-hook nil)
          (dape-ui-debounce-time 0)
          (valid t)
          reply disconnected)
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection command args callback)
                   (should (eq command :disconnect))
                   (should (equal args '(:restart t :terminateDebuggee t)))
                   (setq reply callback)))
                ((symbol-function 'dape--shutdown) (lambda (_) (setq disconnected t)))
                ((symbol-function 'dape--start-with-config)
                 (lambda (_) (ert-fail "Spazio chiuso riaperto")))
                ((symbol-function 'dape--mode-line-format) #'ignore))
        (dape-restart conn nil (lambda () valid))
        (should-not disconnected)
        (setq valid nil)
        (funcall reply nil nil)
        (should disconnected)
        (should (eq (dape--state conn) 'terminated))))))

(ert-deftest gdev-test-dape-restart-build-precedes-disconnect ()
  "La compilazione precede la disconnessione e verifica ancora lo spazio."
  (gdev-test-dape-restart--with-connection (conn '(compile "make") nil)
    (let ((valid t) after disconnected)
      (cl-letf (((symbol-function 'dape--compile)
                 (lambda (config callback)
                   (should (equal config '(compile "make")))
                   (setq after callback)))
                ((symbol-function 'dape-request)
                 (lambda (_connection command args _callback)
                   (should (eq command :disconnect))
                   (should (equal args '(:restart t)))
                   (setq disconnected t))))
        (dape-restart conn nil (lambda () valid))
        (should-not disconnected)
        (setq valid nil)
        (funcall after)
        (should-not disconnected)
        (setq valid t)
        (dape-restart conn nil (lambda () valid))
        (funcall after)
        (should disconnected)))))

(defun gdev-test-dape--mode-line-text (format)
  "Restituisci il testo della riga di stato FORMAT senza disegnarla.
Segue le regole di `mode-line-format' per stringhe, simboli, condizionali
e :propertize; in batch `format-mode-line' non produce testo."
  (cond ((stringp format) format)
        ((eq (car-safe format) :propertize) (gdev-test-dape--mode-line-text (cadr format)))
        ((and (consp format) (symbolp (car format)) (car format))
         ;; (SIMBOLO ALLORA ALTRIMENTI)
         (gdev-test-dape--mode-line-text
          (if (and (boundp (car format)) (symbol-value (car format)))
              (nth 1 format)
            (nth 2 format))))
        ((consp format) (mapconcat #'gdev-test-dape--mode-line-text format ""))
        ((and format (symbolp format) (boundp format))
         (gdev-test-dape--mode-line-text (symbol-value format)))
        (t "")))

(ert-deftest gdev-test-dape-mode-line-follows-thread-names ()
  "La riga di stato usa il nome definitivo del thread e il motivo in italiano."
  (gdev-test-dape-restart--with-connection
      (conn '(:request "launch" :program "programma") nil)
    (let (reply continued)
      (setf (dape--state conn) 'stopped
            (dape--state-reason conn) "breakpoint"
            (dape--thread-id conn) 15
            (dape--threads conn) (list (list :id 15 :name "thread-15" :status 'stopped)))
      (dape--mode-line-format)
      (let ((line (gdev-test-dape--mode-line-text dape--mode-line-format)))
        (should (equal line "Debug: in pausa (punto di interruzione)")))
      ;; Come gli altri indicatori, la sessione compare senza parentesi quadre.
      (let ((dape-active-mode t))
        (should (equal (gdev-test-dape--mode-line-text
                        (assq 'dape-active-mode global-mode-string))
                       "Debug: in pausa (punto di interruzione) ")))
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection command _arguments callback)
                   (should (eq command :threads))
                   (setq reply callback))))
        (dape--update-threads conn (lambda (&rest _) (setq continued t))))
      (funcall reply '(:threads [(:id 15 :name "Thread 1 Queue: com.apple.main-thread (serial)")
                                 (:id 16 :name "Thread 2")])
               nil)
      (should continued)
      (let ((line (gdev-test-dape--mode-line-text dape--mode-line-format)))
        (should (string-search "Debug: Thread 1 Queue: com.app… · in pausa" line))
        (should-not (string-search "thread-15" line)))
      (should (equal (dape--stop-reason-label "motivo nuovo") "motivo nuovo")))))

;;; gdev-dape-restart-test.el ends here
