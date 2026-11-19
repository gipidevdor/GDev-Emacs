;;; gdev-debug-inspector-test.el --- Prove del riquadro di ispezione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica i comandi, le richieste differite e le risposte di sessioni inattive.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gdev-debug-inspector)

(defmacro gdev-test-debug-inspector--with-session (&rest body)
  "Esegui BODY con uno spazio e una risposta Dape controllata."
  (declare (indent 0) (debug t))
  `(progn
     (package-activate-all)
     (require 'dape)
     (let* ((owner (make-symbol "spazio"))
            (conn (make-symbol "adattatore"))
            (scope (list :name "Locals" :variablesReference 81))
            (frame (list :id 17 :name "esegui"
                         :source '(:path "/progetto/lungo/programma.py") :line 7
                         :scopes (list scope)))
            (thread (list :id 3 :name "Principale" :status 'stopped
                          :stackFrames (list frame) :totalFrames 1))
            (worker (list :id 7 :name "Secondario" :status 'stopped))
            (active-frame frame)
            (open t)
            (dape--watched nil))
       (cl-letf (((symbol-function 'gdev-debug-workspace-connection)
                  (lambda (requested-owner) (and (eq requested-owner owner) conn)))
                 ((symbol-function 'gdev-debug--workspace-open-p)
                  (lambda (requested-owner) (and open (eq requested-owner owner))))
                 ((symbol-function 'dape--current-thread)
                  (lambda (connection) (and (eq connection conn) thread)))
                 ((symbol-function 'dape--current-stack-frame)
                  (lambda (connection) (and (eq connection conn) active-frame)))
                 ((symbol-function 'dape--threads)
                  (lambda (connection) (and (eq connection conn) (list thread worker))))
                 ((symbol-function 'dape--file-name-local) (lambda (_conn path) path)))
         (with-temp-buffer
           (gdev-debug-inspector-mode)
           (setq gdev-debug-inspector--owner owner)
           (gdev-debug-inspector-refresh)
           ,@body)))))

(defun gdev-test-debug-inspector--position (id)
  "Restituisci la posizione del pulsante di ID nella vista."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'gdev-debug-inspector-id id t)))
      (prop-match-beginning match))))

(defun gdev-test-debug-inspector--click (id)
  "Attiva ID con il comando condiviso da Invio e dal puntatore."
  (let ((position (gdev-test-debug-inspector--position id)))
    (should position)
    (goto-char position)
    (push-button)))

(ert-deftest gdev-test-debug-inspector-frame-and-thread-use-origin ()
  "Pila e thread scelgono la stessa connessione e conservano il fuoco."
  (gdev-test-debug-inspector--with-session
    (let (commands)
      (cl-letf (((symbol-function 'dape-select-stack)
                 (lambda (connection id) (push (list 'frame connection id) commands)))
                ((symbol-function 'dape-select-thread)
                 (lambda (connection id) (push (list 'thread connection id) commands))))
        (should (eq gdev-ui-view-profile 'document))
        (should (eq (key-binding (kbd "q")) #'gdev-close-document))
        (should (string-search "programma.py:7" (buffer-string)))
        (gdev-test-debug-inspector--click '(frame 17))
        (should (equal (get-text-property (point) 'help-echo) "/progetto/lungo/programma.py:7"))
        (gdev-debug-inspector-refresh)
        (should (equal (get-text-property (point) 'gdev-debug-inspector-id) '(frame 17)))
        (gdev-test-debug-inspector--click '(thread 7))
        (should (equal commands (list (list 'thread conn 7) (list 'frame conn 17))))))))

(ert-deftest gdev-test-debug-inspector-loads-stack-on-demand ()
  "Richiede il livello successivo soltanto con l'azione esplicita."
  (gdev-test-debug-inspector--with-session
    (let ((dape-stack-trace-levels 20)
          request callback)
      (cl-letf (((symbol-function 'dape--stack-trace)
                 (lambda (connection selected count reply)
                   (setq request (list connection selected count) callback reply))))
        (setf (plist-get thread :totalFrames) 2)
        (gdev-debug-inspector-refresh)
        (should-not request)
        (gdev-test-debug-inspector--click 'stack-more)
        (should (equal request (list conn thread 21)))
        (should (string-search "Caricamento della pila" (buffer-string)))
        (setf (plist-get thread :stackFrames)
              (list frame '(:id 18 :name "chiamante")))
        (funcall callback nil nil)
        (gdev-debug-inspector-refresh)
        (should (gdev-test-debug-inspector--position '(frame 18)))
        (should-not (gdev-test-debug-inspector--position 'stack-more))))))

(ert-deftest gdev-test-debug-inspector-loads-variables-lazily-and-retries ()
  "L'apertura riusa la richiesta Dape e distingue errore da insieme vuoto."
  (gdev-test-debug-inspector--with-session
    (let (requests callback)
      (cl-letf (((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                ((symbol-function 'dape-request)
                 (lambda (connection method args reply)
                   (push (list connection method args) requests)
                   (setq callback reply))))
        (gdev-test-debug-inspector--click 'locals)
        (should (string-search "Locali" (buffer-string)))
        (should-not requests)
        (gdev-test-debug-inspector--click '(scope 0))
        (gdev-test-debug-inspector--click '(scope 0))
        (gdev-test-debug-inspector--click '(scope 0))
        (should (length= requests 1))
        (should (equal (car requests) (list conn :variables '(:variablesReference 81))))
        (funcall callback nil "Riferimento scaduto")
        (gdev-debug-inspector-refresh)
        (should (string-search "Riferimento scaduto" (buffer-string)))
        (gdev-test-debug-inspector--click '(retry scope 0))
        (funcall callback '(:variables [(:name "totale" :value "3" :variablesReference 0)]) nil)
        (gdev-debug-inspector-refresh)
        (should (string-search "totale  3" (buffer-string)))
        ;; Se il valore va a capo, la continuazione resta rientrata sotto il nodo.
        (should (equal (get-text-property (string-search "totale" (buffer-string)) 'wrap-prefix)
                       "      "))
        (should-not (gdev-test-debug-inspector--position '(retry scope 0)))
        (gdev-test-debug-inspector--click '(scope 0))
        (gdev-test-debug-inspector--click '(scope 0))
        (should (length= requests 2))))))

(ert-deftest gdev-test-debug-inspector-discards-stale-watch-results ()
  "Valuta nello spazio corretto e scarta esiti di livelli o spazi chiusi."
  (gdev-test-debug-inspector--with-session
    (let (requests)
      (cl-letf (((symbol-function 'dape--evaluate-expression)
                 (lambda (connection id name context callback)
                   (push (list connection id name context callback) requests))))
        (setq dape--watched '((:name "totale") (:name "indice")))
        (should-not requests)
        (gdev-test-debug-inspector--click 'watches)
        (should (length= requests 2))
        (should (equal (seq-take (car requests) 4) (list conn 17 "indice" "watch")))
        (funcall (nth 4 (car requests)) '(:result "4") nil)
        (should-not gdev-debug-inspector--watch-results)
        (funcall (nth 4 (cadr requests)) '(:result "10") nil)
        (gdev-debug-inspector-refresh)
        (should (string-search "totale  10" (buffer-string)))
        (setq active-frame '(:id 21 :name "altro"))
        (gdev-debug-inspector-refresh)
        (should (equal (seq-take (car requests) 4) (list conn 21 "indice" "watch")))
        (setq open nil)
        (funcall (nth 4 (car requests)) '(:result "5") nil)
        (funcall (nth 4 (cadr requests)) '(:result "9") nil)
        (should-not gdev-debug-inspector--watch-results)))))

(ert-deftest gdev-test-debug-inspector-does-not-prepare-hidden-watches ()
  "Gli eventi Dape non producono valutazioni da una vista non mostrata."
  (gdev-test-debug-inspector--with-session
    (let (reads)
      (setq gdev-debug-inspector--page 'watches
            dape--watched '((:name "totale")))
      (cl-letf (((symbol-function 'dape--evaluate-expression)
                 (lambda (&rest _) (cl-incf reads)))
                ((symbol-function 'gdev-debug-inspector--read-context)
                 (lambda () (ert-fail "Ispettore non visibile aggiornato"))))
        (gdev-debug-inspector--refresh-visible)
        (should-not reads)))))

(ert-deftest gdev-test-debug-inspector-watch-edits-use-dape-registry ()
  "Conferma, rimozione e annullamento usano il registro condiviso di Dape."
  (gdev-test-debug-inspector--with-session
    (let ((input " tot + 1 "))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input))
                ((symbol-function 'dape--evaluate-expression)
                 (lambda (_conn _id _expression _context callback)
                   (funcall callback '(:result "5") nil))))
        (gdev-debug-inspector--add-watch)
        (should (eq gdev-debug-inspector--page 'watches))
        (should (equal dape--watched '((:name "tot + 1"))))
        (should (string-search "tot + 1  5" (buffer-string)))
        (setq input " ")
        (gdev-test-debug-inspector--click 'add-watch)
        (should (length= dape--watched 1))
        (gdev-test-debug-inspector--click '(remove-watch "tot + 1"))
        (should-not dape--watched)
        (should (string-search "Nessuna espressione osservata" (buffer-string)))))))

(provide 'gdev-debug-inspector-test)
;;; gdev-debug-inspector-test.el ends here
