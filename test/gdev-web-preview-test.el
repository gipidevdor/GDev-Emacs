;;; gdev-web-preview-test.el --- Verifiche dell'anteprima web -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica le destinazioni accettate, l'aggiornamento dal documento
;; aperto, la richiesta a un servizio locale e le risposte superate.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'gdev-web-preview)

(defmacro gdev-test-web-preview--with-project (&rest body)
  "Esegui BODY in un progetto temporaneo; `root' indica la sua radice."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev-prova-web-" t)))
          (buffers (buffer-list)))
     (unwind-protect
         (progn
           (call-process "git" nil nil nil "init" "-q" root)
           (gdev-test--with-layout ,@body))
       (dolist (buffer (buffer-list))
         (unless (memq buffer buffers)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun gdev-test-web-preview--text (view)
  "Restituisci il testo visibile di VIEW, con gli a capo di SHR come spazi."
  (with-current-buffer view
    (string-clean-whitespace (buffer-substring-no-properties (point-min) (point-max)))))

(ert-deftest gdev-test-web-preview-accepts-local-pages-only ()
  "L'anteprima apre file HTML e servizi di loopback, senza credenziali."
  (let ((directory (file-name-as-directory (make-temp-file "gdev-prova-web-" t))))
    (unwind-protect
        (progn
          (write-region "<p>ciao</p>" nil (expand-file-name "pagina.html" directory) nil 'silent)
          (write-region "testo" nil (expand-file-name "note.txt" directory) nil 'silent)
          (should (equal (gdev-web-preview--input " pagina.html " directory)
                         (cons 'file (expand-file-name "pagina.html" directory))))
          (should (equal (gdev-web-preview--input "http://localhost:8000/" directory)
                         '(http . "http://localhost:8000/")))
          (should (equal (car (gdev-web-preview--input "https://[::1]:8443/a" directory)) 'http))
          (dolist (target '("https://example.com/" "http://utente:segreto@localhost/"
                            "file:///etc/hosts" "note.txt" "assente.html"))
            (should-error (gdev-web-preview--input target directory) :type 'user-error)))
      (delete-directory directory t))))

(ert-deftest gdev-test-web-preview-follows-unsaved-edits ()
  "Il documento HTML aperto aggiorna l'anteprima senza salvare."
  (skip-unless (and (executable-find "git") (libxml-available-p)))
  (gdev-test-web-preview--with-project
    (let ((file (expand-file-name "indice.html" root)))
      (write-region "<html><body><h1>Titolo iniziale</h1></body></html>" nil file nil 'silent)
      (find-file file)
      (let* ((source (current-buffer))
             (view (gdev-web-preview)))
        (should (eq (current-buffer) source))
        (should (get-buffer-window view))
        (gdev-test-launch--wait
         (lambda () (string-search "Titolo iniziale" (gdev-test-web-preview--text view))))
        (goto-char (point-min))
        (search-forward "iniziale")
        (replace-match "aggiornato" t t)
        (gdev-test-launch--wait
         (lambda () (string-search "Titolo aggiornato" (gdev-test-web-preview--text view))))
        (should (buffer-modified-p source))
        (should (memq view (buffer-local-value 'gdev-web-preview--source-views source)))
        (kill-buffer view)
        (should-not (memq #'gdev-web-preview--source-changed
                          (buffer-local-value 'after-change-functions source)))))))

(ert-deftest gdev-test-web-preview-loads-a-local-service-and-reloads-on-save ()
  "Un servizio su 127.0.0.1 riceve una richiesta asincrona e una dopo il salvataggio."
  (skip-unless (and (executable-find "git") (libxml-available-p)))
  (gdev-test-web-preview--with-project
    (let* ((requests 0)
           (server
            (make-network-process
             :name "gdev-prova-web" :server t :host "127.0.0.1" :service t
             :family 'ipv4 :noquery t :coding 'binary
             :filter (lambda (process _text)
                       (unless (process-get process 'risposto)
                         (process-put process 'risposto t)
                         (cl-incf requests)
                         (let ((body (format "<h1>Risposta %d</h1>" requests)))
                           (process-send-string
                            process
                            (format "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                                    (string-bytes body) body))
                           (process-send-eof process))))))
           (address (format "http://127.0.0.1:%d/" (process-contact server :service))))
      (unwind-protect
          (let ((file (expand-file-name "stile.css" root)))
            (find-file file)
            (let ((view (gdev-web-preview address)))
              (gdev-test-launch--wait
               (lambda () (string-search "Risposta 1" (gdev-test-web-preview--text view))))
              (insert "body { color: black; }")
              (save-buffer)
              (gdev-test-launch--wait
               (lambda () (string-search "Risposta 2" (gdev-test-web-preview--text view))))
              (should (= requests 2))))
        (delete-process server)))))

(ert-deftest gdev-test-web-preview-ignores-superseded-responses ()
  "Una risposta arrivata dopo un nuovo aggiornamento non sostituisce la pagina."
  (skip-unless (and (executable-find "git") (libxml-available-p)))
  (gdev-test-web-preview--with-project
    (let ((file (expand-file-name "indice.html" root)))
      (write-region "<p>Pagina corrente</p>" nil file nil 'silent)
      (find-file file)
      (let* ((view (gdev-web-preview))
             (response (generate-new-buffer " *risposta superata*"))
             (generation (buffer-local-value 'gdev-web-preview--generation view)))
        (gdev-test-launch--wait
         (lambda () (string-search "Pagina corrente" (gdev-test-web-preview--text view))))
        (with-current-buffer view (gdev-web-preview--invalidate))
        (with-current-buffer response
          (gdev-web-preview--receive nil view generation))
        (should-not (buffer-live-p response))
        (should (string-search "Pagina corrente" (gdev-test-web-preview--text view)))))))

(provide 'gdev-web-preview-test)
;;; gdev-web-preview-test.el ends here
