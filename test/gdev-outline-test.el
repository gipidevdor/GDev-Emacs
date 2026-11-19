;;; gdev-outline-test.el --- Prove della struttura del documento -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'gdev-outline)

(defmacro gdev-test-outline--with-documents (&rest body)
  "Esegui BODY con due sorgenti e un riquadro in uno spazio isolato."
  (declare (indent 0) (debug t))
  `(gdev-test--with-layout
     (let* ((first (generate-new-buffer "primo-sorgente.el"))
            (second (generate-new-buffer "secondo-sorgente.el"))
            (editor (gdev-layout-editor))
            pane)
       (unwind-protect
           (progn
             (with-current-buffer first
               (emacs-lisp-mode)
               (insert "(defun prima () t)\n(defun seconda () nil)\n"))
             (with-current-buffer second
               (emacs-lisp-mode)
               (insert "(defun calcola () 27)\n"))
             (select-window editor)
             (switch-to-buffer first)
             ,@body)
         (when (buffer-live-p pane) (kill-buffer pane))
         (kill-buffer first)
         (kill-buffer second)))))

(defun gdev-test-outline--row (name)
  "Trova la prima riga con il NAME di un simbolo."
  (gdev-outline--row-position (list (cons name 0))))

(ert-deftest gdev-test-outline-follows-editor-and-opens-symbols ()
  "Il puntatore e Invio raggiungono lo stesso editor, che guida la vista."
  (gdev-test-outline--with-documents
    (gdev-outline-show)
    (setq pane (current-buffer))
    (should (eq gdev-ui-view-profile 'sidebar))
    (should (eq (gdev-layout--role pane) 'auxiliary))
    (should (eq gdev-outline--source first))
    (should (string-search "prima" (buffer-string)))
    (search-forward "seconda")
    (goto-char (1- (point)))
    (call-interactively (key-binding (kbd "RET")))
    (should (eq (selected-window) editor))
    (should (eq (current-buffer) first))
    (should (= 2 (line-number-at-pos)))
    (with-current-buffer pane
      (let ((pos (save-excursion (goto-char (point-min)) (search-forward "prima") (1- (point)))))
        (push-button pos t)))
    (should (eq (selected-window) editor))
    (should (= 1 (line-number-at-pos)))
    (switch-to-buffer second)
    (gdev-outline--sync-frame (selected-frame))
    (gdev-outline--load pane)
    (should (eq (selected-window) editor))
    (with-current-buffer pane
      (should (eq gdev-outline--source second))
      (should (string-search "calcola" (buffer-string)))
      (should-not (string-search "seconda" (buffer-string))))
    (should-not (buffer-local-value 'gdev-outline--subscribers first))))

(ert-deftest gdev-test-outline-preserves-identity-while-narrow-and-refreshed ()
  "La riga selezionata resta la stessa e il nome completo è consultabile."
  (gdev-test-outline--with-documents
    (let ((name "unNomeMoltoLungoPerUnaFunzioneCheDeveRestareConsultabile"))
      (with-current-buffer first
        (setq-local imenu-create-index-function (lambda () (list (cons name 1) '("altra" . 11)))))
      (gdev-outline-show)
      (setq pane (current-buffer))
      (goto-char (gdev-test-outline--row name))
      (cl-letf (((symbol-function 'display-graphic-p) #'ignore)
                ((symbol-function 'window-body-width) (lambda (&rest _) 18)))
        (gdev-outline--render (selected-window))
        (should (equal (gdev-outline--node-name (get-text-property (point) 'gdev-outline-node)) name))
        (should-not (string-search name (buffer-string)))
        (beginning-of-line)
        (should (<= (string-width (buffer-substring (point) (line-end-position))) 18))
        (forward-char 3)
        (should (equal (get-text-property (point) 'help-echo) name)))
      (with-current-buffer first
        (goto-char (point-min))
        (insert " "))
      (gdev-outline--load pane)
      (should (equal (gdev-outline--node-name (get-text-property (point) 'gdev-outline-node)) name)))))

(ert-deftest gdev-test-outline-defers-and-discards-old-symbols ()
  "La risposta del server vale per la revisione e lo spazio ancora visibili."
  (gdev-test-outline--with-documents
    (let (replies)
      (cl-letf (((symbol-function 'gdev-outline--server) (lambda () 'server))
                ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                ((symbol-function 'eglot--TextDocumentIdentifier)
                 (lambda () (list :uri (buffer-name))))
                ((symbol-function 'eglot-range-region) (lambda (range &optional _) range))
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_ method _params &rest options)
                   (should (eq method :textDocument/documentSymbol))
                   (push (plist-get options :success-fn) replies))))
        (gdev-outline-show)
        (setq pane (current-buffer))
        (should (= (length replies) 1))
        (gdev-outline--load pane)
        (should (= (length replies) 1))
        (select-window editor)
        (switch-to-buffer second)
        (gdev-outline--sync-frame (selected-frame))
        (gdev-outline--load pane)
        (funcall (nth 1 replies) [(:name "vecchio" :range (1 . 10))])
        (with-current-buffer pane
          (should-not gdev-outline--nodes))
        (funcall (car replies) [(:name "Classe" :range (1 . 20) :selectionRange (2 . 5)
                                 :children [(:name "metodo" :range (6 . 12) :selectionRange (8 . 10))])])
        (with-selected-window (get-buffer-window pane)
          (should (string-search "metodo" (buffer-string)))
          (let ((parent (gdev-test-outline--row "Classe")))
            (should parent)
            (goto-char parent)
            (gdev-outline-toggle)
            (should-not (string-search "metodo" (buffer-string)))
            (gdev-outline-toggle)
            (should (string-search "metodo" (buffer-string)))
            (goto-char parent)
            (gdev-outline-activate)))
        (should (= (point) 2))
        (gdev-outline-show)
        (gdev-outline-refresh)
        (let ((reply (car replies)))
          (gdev-close-document)
          (funcall reply [(:name "nascosto" :range (1 . 10))])
          (with-current-buffer pane
            (should-not (string-search "nascosto" (buffer-string))))
          (gdev-outline--load pane)
          (should (= (length replies) 3)))))))

(ert-deftest gdev-test-outline-breadcrumb-index-can-be-reused-safely ()
  "Il fork conserva le etichette native e rilegge un indice sostituito."
  (package-activate-all)
  (require 'breadcrumb)
  (with-temp-buffer
    (insert "abcde")
    (let* ((label (copy-sequence "funzione"))
           (entry (cons label (copy-marker 3)))
           (index (list nil imenu--rescan-item (list "Gruppo" entry))))
      (should-not (breadcrumb-ipath index 2))
      (should (equal (breadcrumb-ipath index 5) '("Gruppo" "funzione")))
      (should-not (text-properties-at 0 label))
      (goto-char (point-min))
      (insert "12")
      (should-not (breadcrumb-ipath index 4))
      (should (equal (breadcrumb-ipath index 5) '("Gruppo" "funzione")))
      (should (equal (breadcrumb-ipath '(("altra" . 3)) 5) '("altra")))
      (should-not (breadcrumb-ipath '(nil ("*Rescan*" . -99)) 5)))))

(provide 'gdev-outline-test)
;;; gdev-outline-test.el ends here
