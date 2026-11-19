;;; gdev-lsp-refactor-test.el --- Prove di rinomina ed estrazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Code:

(require 'ert)

(defun gdev-lsp-refactor-test--edit (start end text &optional line)
  "Crea una modifica tra START ed END sulla LINEA LSP con TEXT."
  (list :range (list :start (list :line (or line 0) :character start)
                     :end (list :line (or line 0) :character end))
        :newText text))

(defmacro gdev-lsp-refactor-test--with-files (&rest body)
  "Esegui BODY con `first', `second', `source' e uno spazio di prova."
  (declare (indent 0))
  `(let* ((load-path (cons (gdev-module-directory :tools 'lsp) load-path))
          (_library (require 'gdev-lsp-refactor))
          (root (make-temp-file "gdev-lsp-rinomina-" t))
          (first (expand-file-name "una.go" root))
          (second (expand-file-name "due.go" root))
          (gdev-lsp-auto-start nil)
          source)
     (unwind-protect
         (gdev-test--with-layout
           (write-region "😀acqua\n" nil first nil 'silent)
           (write-region "acqua\n" nil second nil 'silent)
           (setq source (find-file-noselect first))
           (with-current-buffer source
             (cl-letf (((symbol-function 'eglot-current-server)
                        (lambda () (and (eq (current-buffer) source) 'adapter)))
                       ((symbol-function 'eglot-uri-to-path) #'identity))
               ,@body)))
       (dolist (buffer (list (find-buffer-visiting first) (find-buffer-visiting second)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(ert-deftest gdev-test-lsp-refactor-multi-file-undo-and-insertion-order ()
  "Un solo annullamento ripristina entrambi i file e rispetta l'ordine LSP."
  (gdev-lsp-refactor-test--with-files
    (let* ((request (gdev-lsp-refactor--capture))
           (edit (list :changes
                       (list first (vector (gdev-lsp-refactor-test--edit 2 2 "☕")
                                           (gdev-lsp-refactor-test--edit 2 2 " ")
                                           (gdev-lsp-refactor-test--edit 2 7 "caffè"))
                             second (vector (gdev-lsp-refactor-test--edit 0 5 "caffè")))))
           (files (gdev-lsp-refactor--prepare edit request))
           (preview (make-gdev-lsp-refactor--preview :request request :files files :label "Rinomina")))
      (should-not (find-buffer-visiting second))
      (gdev-lsp-refactor--change preview)
      (should (equal (gdev-operation-undo-label) "Rinomina"))
      (should (equal (buffer-string) "😀☕ caffè\n"))
      (should (equal (with-current-buffer (find-buffer-visiting second) (buffer-string)) "caffè\n"))
      (should (buffer-modified-p source))
      (with-temp-buffer
        (insert-file-contents second)
        (should (equal (buffer-string) "acqua\n")))
      (gdev-operation-undo)
      (should (equal (buffer-string) "😀acqua\n"))
      (should (equal (with-current-buffer (find-buffer-visiting second) (buffer-string)) "acqua\n"))
      (gdev-operation-redo)
      (should (equal (buffer-string) "😀☕ caffè\n"))
      (should (equal (with-current-buffer (find-buffer-visiting second) (buffer-string)) "caffè\n")))))

(ert-deftest gdev-test-lsp-refactor-rejects-stale-and-closes-unmodified-new-visits ()
  "Un documento cambiato invalida il gruppo e chiude le nuove visite."
  (gdev-lsp-refactor-test--with-files
    (let* ((request (gdev-lsp-refactor--capture))
           (edit (list :changes (list first (vector (gdev-lsp-refactor-test--edit 2 7 "nuovo"))
                                     second (vector (gdev-lsp-refactor-test--edit 0 5 "nuovo")))))
           (files (gdev-lsp-refactor--prepare edit request))
           (preview (make-gdev-lsp-refactor--preview :request request :files files)))
      (with-current-buffer source (setq buffer-read-only t))
      (should-error (gdev-lsp-refactor--change preview) :type 'user-error)
      (should-not (find-buffer-visiting second))
      (should (equal (buffer-string) "😀acqua\n"))
      (setq buffer-read-only nil)
      (goto-char (point-max))
      (insert "cambiato\n")
      (should-error (gdev-lsp-refactor--change preview) :type 'user-error)
      (should-not (find-buffer-visiting second))
      (should-not (gdev-operation-undo-label)))))

(ert-deftest gdev-test-lsp-refactor-checks-version-range-and-workspace ()
  "Il server deve indirizzare il documento, la versione e l'intervallo corretti."
  (gdev-lsp-refactor-test--with-files
    (let* ((request (gdev-lsp-refactor--capture))
           (edit (gdev-lsp-refactor-test--edit 2 7 "nuovo"))
           (group (lambda (version edits)
                    (list :documentChanges (vector (list :textDocument
                                                         (list :uri first :version version)
                                                         :edits edits))))))
      (cl-letf (((symbol-function 'gdev-lsp-refactor--version) (lambda () 10)))
        (should (gdev-lsp-refactor--prepare (funcall group 10 (vector edit)) request))
        (should-error (gdev-lsp-refactor--prepare (funcall group 9 (vector edit)) request) :type 'user-error)
        (should-error (gdev-lsp-refactor--prepare (funcall group 10 (vector edit edit)) request) :type 'user-error)
        (should-error (gdev-lsp-refactor--prepare
                       (funcall group 10 (vector (gdev-lsp-refactor-test--edit 1 7 "nuovo"))) request)
                      :type 'user-error)
        (should-error (gdev-lsp-refactor--prepare
                       (funcall group 10 (vector (gdev-lsp-refactor-test--edit 0 0 "testo" 12))) request)
                      :type 'user-error))
      (tab-bar-new-tab)
      (should-error (gdev-lsp-refactor--prepare (funcall group 10 (vector edit)) request) :type 'user-error))))

(ert-deftest gdev-test-lsp-refactor-extraction-resolves-and-previews-before-executing ()
  "L'estrazione risolta passa all'anteprima e resta annullabile."
  (gdev-lsp-refactor-test--with-files
    (let* ((action '(:title "Estrai funzione" :kind "refactor.extract.function" :data (:token "1")))
           (edit (list :changes (list first (vector (gdev-lsp-refactor-test--edit 2 7 "nuovo")))))
           (view nil))
      (unwind-protect
          (cl-letf (((symbol-function 'eglot--code-action-bounds) (lambda () '(1 1)))
                    ((symbol-function 'eglot--TextDocumentIdentifier) (lambda () (list :uri first)))
                    ((symbol-function 'eglot-server-capable) (lambda (&rest _) t))
                    ((symbol-function 'eglot--request)
                     (lambda (server method value &rest _)
                       (should (eq server 'adapter))
                       (pcase method
                         (:textDocument/codeAction
                          (should (equal (plist-get (plist-get value :context) :only) ["refactor.extract"]))
                          (vector action '(:title "Ripara" :kind "quickfix")))
                         (:codeAction/resolve
                          (should (equal value action))
                          (append action (list :edit edit)))
                         (_ (ert-fail method))))))
            (gdev-lsp-refactor-extract)
            (setq view (window-buffer))
            (with-current-buffer view
              (should (derived-mode-p 'gdev-lsp-refactor-preview-mode))
              (should (string-search "Applica modifiche" (buffer-string)))
              (should (string-search "− acqua\n+ nuovo" (buffer-string)))
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
                (gdev-lsp-refactor-apply))
              (gdev-lsp-refactor-cancel))
            (should (equal (with-current-buffer source (buffer-string)) "😀acqua\n"))
            (should-not (gdev-operation-undo-label)))
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest gdev-test-lsp-refactor-extraction-with-command-requires-explicit-confirmation ()
  "Un comando opaco richiesto al server richiede la conferma prima dell'esecuzione."
  (gdev-lsp-refactor-test--with-files
    (let ((action '(:title "Estrai funzione" :command "extract.function" :arguments [1]))
          answer executed)
      (cl-letf (((symbol-function 'eglot--code-action-bounds) (lambda () '(1 1)))
                ((symbol-function 'eglot--TextDocumentIdentifier) (lambda () (list :uri first)))
                ((symbol-function 'eglot--request) (lambda (&rest _) (vector action)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) answer))
                ((symbol-function 'eglot-execute)
                 (lambda (server command)
                   (should (eq server 'adapter))
                   (setq executed command))))
        (gdev-lsp-refactor-extract)
        (should-not executed)
        (setq answer t)
        (gdev-lsp-refactor-extract)
        (should (equal executed action))
        (should-not (gdev-operation-undo-label))))))

(ert-deftest gdev-test-lsp-refactor-replacement-retains-existing-history-label ()
  "Le sostituzioni di Cerca conservano l'etichetta predefinita."
  (require 'gdev-operation-history)
  (gdev-test--with-layout
    (with-temp-buffer
      (insert "nuovo")
      (gdev-operation-record-replacement
       (list (cons (current-buffer) '((1 1 7 "prima" "nuovo")))))
      (should (equal (gdev-operation-undo-label) "sostituzione in 1 file")))))

(ert-deftest gdev-test-lsp-refactor-oversized-transaction-leaves-all-buffers-untouched ()
  "Se manca spazio per l'annullamento, il piano non apre i file né scrive."
  (gdev-lsp-refactor-test--with-files
    (let* ((request (gdev-lsp-refactor--capture))
           (edit (list :changes (list first (vector (gdev-lsp-refactor-test--edit 2 7 "nuovo"))
                                     second (vector (gdev-lsp-refactor-test--edit 0 5 "nuovo")))))
           (files (gdev-lsp-refactor--prepare edit request))
           (preview (make-gdev-lsp-refactor--preview :request request :files files))
           (gdev-operation-text-budget 16))
      (should-error (gdev-lsp-refactor--change preview) :type 'user-error)
      (should-not (find-buffer-visiting second))
      (should (equal (buffer-string) "😀acqua\n"))
      (should-not (gdev-operation-undo-label)))))

(provide 'gdev-lsp-refactor-test)
;;; gdev-lsp-refactor-test.el ends here
