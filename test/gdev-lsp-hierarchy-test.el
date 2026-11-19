;;; gdev-lsp-hierarchy-test.el --- Prove delle gerarchie del codice -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)

(defun gdev-test-lsp-hierarchy--item (name file line &optional data)
  "Costruisci il simbolo NAME in FILE e LINE con DATA opaco."
  (list :name name :uri (concat "file:///progetto/" file)
        :selectionRange (list :start (list :line line :character 5))
        :data data))

(defun gdev-test-lsp-hierarchy--press (id)
  "Attiva il primo controllo visibile con l'identità ID."
  (let ((position (text-property-any (point-min) (point-max) 'gdev-lsp-hierarchy-control id)))
    (should position)
    (goto-char position)
    (push-button)))

(defmacro gdev-test-lsp-hierarchy--with-view (&rest body)
  "Esegui BODY con richieste e risposte del server controllate."
  (declare (indent 0) (debug t))
  `(progn
     (let ((load-path (cons (gdev-module-directory :tools 'lsp) load-path)))
       (require 'gdev-lsp-hierarchy))
     (let ((source (generate-new-buffer " *sorgente della gerarchia*"))
           (gdev-layout-mode nil)
           (eglot-move-to-linepos-function #'eglot-move-to-utf-16-linepos)
           (server 'server-di-prova)
           (capable t)
           (id 0)
           requests canceled notifications views)
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) source)
             (with-current-buffer source
               (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
                         ((symbol-function 'eglot-current-server) (lambda () server))
                         ((symbol-function 'eglot-server-capable) (lambda (_) capable))
                         ((symbol-function 'eglot--signal-textDocument/didChange)
                          (lambda () (push 'changed notifications)))
                         ((symbol-function 'eglot--TextDocumentPositionParams)
                          (lambda () '(:textDocument (:uri "file:///progetto/iniziatore.cpp")
                                       :position (:line 1 :character 0))))
                         ((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                         ((symbol-function 'jsonrpc-notify)
                          (lambda (_ method params) (push (cons method params) canceled)))
                         ((symbol-function 'jsonrpc-async-request)
                          (lambda (connection method params &rest callbacks)
                            (should (eq connection server))
                            (push method notifications)
                            (push (list method params callbacks) requests)
                            (list (cl-incf id)))))
                 ,@body)))
         (dolist (view views)
           (when (buffer-live-p view)
             (with-current-buffer view (clrhash gdev-lsp-hierarchy--requests))
             (kill-buffer view)))
         (kill-buffer source)))))

(defun gdev-test-lsp-hierarchy--respond (request result)
  "Consegna RESULT alla continuazione di successo di REQUEST."
  (funcall (plist-get (nth 2 request) :success-fn) result))

(ert-deftest gdev-test-lsp-hierarchy-loads-only-the-requested-branch ()
  "La direzione scelta conserva i rami già letti e l'identità della selezione."
  (gdev-test-lsp-hierarchy--with-view
    (let* ((item (gdev-test-lsp-hierarchy--item "calcola" "iniziatore.cpp" 1 '(dato 3)))
           (child (gdev-test-lsp-hierarchy--item "attiva" "principale.cpp" 7))
           (view (gdev-lsp-hierarchy-show 'call)))
      (push view views)
      (should (equal notifications '(:textDocument/prepareCallHierarchy changed)))
      (gdev-test-lsp-hierarchy--respond (car requests) (vector item))
      (with-current-buffer view
        (should (eq gdev-ui-view-profile 'document))
        (should (eq (gdev-layout--role view) 'auxiliary))
        (should (string-search "iniziatore.cpp:2" (buffer-string)))
        (should (= 1 (length requests)))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (should (equal (seq-take (car requests) 2) (list :callHierarchy/incomingCalls (list :item item))))
        (gdev-test-lsp-hierarchy--respond
         (car requests)
         (vector (list :from child :fromRanges [(:start (:line 8 :character 9))])))
        (should (string-search "Punto di chiamata" (buffer-string)))
        (should (eq (get-text-property (point) 'gdev-lsp-hierarchy-control) 'disclosure))
        (should (string-search "attiva" (buffer-string)))
        (gdev-test-lsp-hierarchy--press :callHierarchy/outgoingCalls)
        (should-not (string-search "attiva" (buffer-string)))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (should (eq (caar requests) :callHierarchy/outgoingCalls))
        (gdev-test-lsp-hierarchy--respond (car requests) [])
        (should (string-search "Nessuna relazione." (buffer-string)))
        (gdev-test-lsp-hierarchy--press :callHierarchy/incomingCalls)
        (should (string-search "attiva" (buffer-string)))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (should-not (string-search "attiva" (buffer-string)))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (should (string-search "attiva" (buffer-string)))
        (should (= 3 (length requests)))))))

(ert-deftest gdev-test-lsp-hierarchy-cancels-collapsed-and-replaced-requests ()
  "Una risposta a un ramo annullato o a una ricerca precedente non torna visibile."
  (gdev-test-lsp-hierarchy--with-view
    (let* ((item (gdev-test-lsp-hierarchy--item "Parte" "parti.hpp" 3))
           (old-item (gdev-test-lsp-hierarchy--item "Superato" "altro.hpp" 4))
           (view (gdev-lsp-hierarchy-show 'type)))
      (push view views)
      (gdev-test-lsp-hierarchy--respond (car requests) (vector item))
      (gdev-test-lsp-hierarchy--press 'disclosure)
      (should (eq (caar requests) :typeHierarchy/supertypes))
      (let ((obsolete (car requests)))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (should (equal canceled '((:$/cancelRequest :id 2))))
        (gdev-test-lsp-hierarchy--press 'disclosure)
        (gdev-test-lsp-hierarchy--respond obsolete (vector old-item))
        (should (string-search "Caricamento…" (buffer-string)))
        (gdev-test-lsp-hierarchy--respond (car requests) (vector item))
        (should (string-search "Ciclo" (buffer-string)))
        (should-not (string-search "Superato" (buffer-string))))
      (with-selected-window (get-buffer-window source)
        (gdev-lsp-hierarchy-show 'type)
        (let ((obsolete (car requests)))
          (with-selected-window (get-buffer-window source)
            (gdev-lsp-hierarchy-show 'call))
          (gdev-test-lsp-hierarchy--respond obsolete (vector old-item))))
      (with-current-buffer view
        (should (string-search "Ricerca del simbolo" (buffer-string)))
        (should-not (string-search "Superato" (buffer-string)))))))

(ert-deftest gdev-test-lsp-hierarchy-call-sites-use-the-caller-document ()
  "Per una chiamata in uscita le posizioni sono nel file del chiamante."
  (gdev-test-lsp-hierarchy--with-view
    (let* ((caller (gdev-test-lsp-hierarchy--item "calcola" "iniziatore.cpp" 1))
           (callee (gdev-test-lsp-hierarchy--item "attiva" "principale.cpp" 7))
           (view (gdev-lsp-hierarchy-show 'call))
           visits)
      (push view views)
      (gdev-test-lsp-hierarchy--respond (car requests) (vector caller))
      (gdev-test-lsp-hierarchy--press :callHierarchy/outgoingCalls)
      (gdev-test-lsp-hierarchy--press 'disclosure)
      (gdev-test-lsp-hierarchy--respond
       (car requests)
       (vector (list :to callee :fromRanges [(:start (:line 1 :character 17))
                                           (:start (:line 5 :character 8))])))
      (cl-letf (((symbol-function 'gdev-lsp-hierarchy--visit)
                 (lambda (uri position) (push (list uri position) visits)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _) (caar (last choices)))))
        (gdev-test-lsp-hierarchy--press 'call-site)
        (should (equal (car visits) '("file:///progetto/iniziatore.cpp" (:line 5 :character 8))))))))

(ert-deftest gdev-test-lsp-hierarchy-rejects-stale-documents-and-closed-workspaces ()
  "Esiti tardivi non modificano la vista dopo un cambio del documento o dello spazio."
  (gdev-test-lsp-hierarchy--with-view
    (let* ((item (gdev-test-lsp-hierarchy--item "Parte" "parti.hpp" 3))
           (view (gdev-lsp-hierarchy-show 'type)))
      (push view views)
      (with-current-buffer source (insert "nuovo testo"))
      (gdev-test-lsp-hierarchy--respond (car requests) (vector item))
      (with-current-buffer view
        (should (string-search "Il documento è cambiato" (buffer-string)))
        (should-not gdev-lsp-hierarchy--roots))
      (with-current-buffer view
        (setq gdev-lsp-hierarchy--context
              (gdev-lsp-hierarchy--make-context
               :server server :owner (make-symbol "chiuso") :frame (selected-frame)))
        (gdev-lsp-hierarchy--request
         'chiuso :textDocument/prepareTypeHierarchy nil
         (lambda (&rest _) (ert-fail "Risposta consegnata allo spazio chiuso")))
        (gdev-test-lsp-hierarchy--respond (car requests) (vector item))
        (should-not gdev-lsp-hierarchy--roots)
        (should (zerop (hash-table-count gdev-lsp-hierarchy--requests)))))))

(ert-deftest gdev-test-lsp-hierarchy-checks-capability-before-sending-request ()
  "Una gerarchia assente non apre la vista e non invia richieste."
  (gdev-test-lsp-hierarchy--with-view
    (setq capable nil)
    (should-error (gdev-lsp-hierarchy-show 'type) :type 'user-error)
    (should-not notifications)
    (should (eq (window-buffer) source))))

(ert-deftest gdev-test-lsp-hierarchy-advertises-only-missing-client-capabilities ()
  "Le capacità già negoziate e la risposta originale di Eglot restano intatte."
  (unless (fboundp 'gdev-lsp--hierarchy-client-capabilities)
    (require 'use-package)
    (load (gdev-config-file "modules/tools/lsp/config.el") nil t t))
  (let* ((source '(:workspace (:configuration t)
                   :textDocument (:callHierarchy (:dynamicRegistration t) :hover t)))
         (snapshot (copy-tree source))
         (gdev-layout-mode t)
         (result (gdev-lsp--hierarchy-client-capabilities source)))
    (should (equal source snapshot))
    (should (equal (plist-get result :workspace) (plist-get source :workspace)))
    (let ((document (plist-get result :textDocument)))
      (should (equal (plist-get document :callHierarchy) '(:dynamicRegistration t)))
      (should (equal (plist-get document :typeHierarchy) '(:dynamicRegistration :json-false)))
      (should (plist-get document :hover)))
    (should (eq result (gdev-lsp--hierarchy-client-capabilities result)))
    (let ((gdev-layout-mode nil))
      (should (eq source (gdev-lsp--hierarchy-client-capabilities source))))))

(provide 'gdev-lsp-hierarchy-test)
;;; gdev-lsp-hierarchy-test.el ends here
