;;; gdev-lsp-navigation-test.el --- Verifiche della navigazione LSP -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)

(ert-deftest gdev-test-lsp-navigation-groups-and-keeps-distinct-columns ()
  "La vista conserva i riferimenti distinti sulla stessa riga."
  (load (gdev-module-file :tools 'lsp ".el") nil t t)
  (require 'gdev-lsp-navigation)
  (let* ((first '(:uri "file:///tmp/a.c" :range (:start (:line 2 :character 3))))
         (second '(:targetUri "file:///tmp/a.c"
                   :targetSelectionRange (:start (:line 2 :character 9))))
         (third '(:uri "file:///tmp/b.c" :range (:start (:line 0 :character 0))))
         (locations (gdev-lsp-navigation--locations (vector third first second first))))
    (should (equal (mapcar #'car locations) '("/tmp/a.c" "/tmp/a.c" "/tmp/b.c")))
    (should (equal (mapcar (lambda (entry) (plist-get (cdr entry) :character)) locations)
                   '(3 9 0)))
    (should (equal (gdev-lsp-navigation--locations first) (list (car locations))))
    (should-not (gdev-lsp-navigation--locations [(:uri "file:///tmp/b.c")]))
    (with-temp-buffer
      (gdev-lsp-navigation-mode)
      (let ((gdev-lsp-navigation--batch-size 1))
        (setq gdev-lsp-navigation--heading "Tutti i riferimenti"
              gdev-lsp-navigation--total 3
              gdev-lsp-navigation--pending locations
              gdev-lsp-navigation--root "/tmp/")
        (gdev-lsp-navigation--render nil)
        (should (string-search "colonna 4" (buffer-string)))
        (should-not (string-search "colonna 10" (buffer-string)))
        (button-activate (next-button (button-end (button-at (point)))))
        (should (string-search "colonna 10" (buffer-string)))
        (should (= (how-many "^a\\.c$" (point-min) (point-max)) 1))
        (should (= (length gdev-lsp-navigation--pending) 1))))))

(ert-deftest gdev-test-lsp-navigation-assigns-responses-to-current-request-and-document ()
  "Il server può rispondere fuori ordine o dopo una modifica dell'origine."
  (load (gdev-module-file :tools 'lsp ".el") nil t t)
  (require 'gdev-lsp-navigation)
  (gdev-test--with-layout
    (let ((document (generate-new-buffer "gdev-lsp-sorgente"))
          response-handlers pane)
      (unwind-protect
          (progn
            (switch-to-buffer document)
            (gdev-layout-mark-document)
            (insert "carica")
            (cl-letf (((symbol-function 'gdev-lsp--check-capability) #'ignore)
                      ((symbol-function 'eglot-current-server) (lambda () 'server))
                      ((symbol-function 'eglot--project) (lambda (_) nil))
                      ((symbol-function 'eglot--TextDocumentPositionParams) (lambda () nil))
                      ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                      ((symbol-function 'eglot-uri-to-path) #'identity)
                      ((symbol-function 'jsonrpc-async-request)
                       (lambda (_server _method _params &rest callbacks)
                         (push (plist-get callbacks :success-fn) response-handlers))))
              (gdev-lsp-navigation-show 'references)
              (setq pane (current-buffer))
              (should (derived-mode-p 'gdev-lsp-navigation-mode))
              (gdev-lsp-navigation-show 'references)
              (funcall (cadr response-handlers) [(:uri "/tmp/vecchia.c" :range (:start (:line 0 :character 0)))])
              (should (string-search "Ricerca in corso" (buffer-string)))
              (should-not (string-search "vecchia.c" (buffer-string)))
              (with-current-buffer document (insert " modifica"))
              (funcall (car response-handlers) [(:uri "/tmp/stale.c" :range (:start (:line 0 :character 0)))])
              (should (string-search "Il documento è cambiato" (buffer-string)))
              (gdev-lsp-navigation-show 'references)
              (funcall (car response-handlers) [(:uri "/tmp/nuova.c" :range (:start (:line 2 :character 4)))])
              (should (string-search "nuova.c" (buffer-string)))
              (should (string-search "Riga 3 · colonna 5" (buffer-string)))))
        (when (buffer-live-p pane) (kill-buffer pane))
        (kill-buffer document)))))

(ert-deftest gdev-test-lsp-navigation-consult-fork-keeps-duplicate-line-text ()
  "Le scelte di Consult mantengono due riferimenti con la stessa anteprima."
  (package-activate-all)
  (require 'consult-xref)
  (let ((first (xref-make "x + x" (xref-make-file-location "/tmp/a.c" 2 0)))
        (second (xref-make "x + x" (xref-make-file-location "/tmp/a.c" 2 4))))
    (let* ((consult-xref--fetcher (lambda () (list first second)))
           (candidates (consult-xref--candidates)))
      (should-not (equal (car candidates) (cadr candidates)))
      (should (string-suffix-p ":2:1:x + x" (car candidates)))
      (should (string-suffix-p ":2:5:x + x" (cadr candidates)))
      (should (eq (get-text-property 0 'consult-xref (cadr candidates)) second)))))

(ert-deftest gdev-test-lsp-navigation-visits-utf16-and-records-return ()
  "Il salto usa le coordinate del server e registra il punto di origine."
  (load (gdev-module-file :tools 'lsp ".el") nil t t)
  (require 'eglot)
  (require 'xref)
  (let ((file (make-temp-file "gdev-posizione-" nil ".txt" "a😀simbolo\n"))
        (origin (generate-new-buffer "gdev lsp origine"))
        target)
    (unwind-protect
        (gdev-test--with-layout
          (switch-to-buffer origin)
          (gdev-layout-mark-document)
          (insert "punto di ritorno")
          (goto-char 6)
          (gdev-lsp-visit-location file '(:line 0 :character 3) #'eglot-move-to-utf-16-linepos)
          (setq target (current-buffer))
          (should (equal buffer-file-name file))
          (should (looking-at "simbolo"))
          (xref-go-back)
          (should (eq (current-buffer) origin))
          (should (= (point) 6)))
      (when (buffer-live-p target) (kill-buffer target))
      (kill-buffer origin)
      (delete-file file))))

(provide 'gdev-lsp-navigation-test)
;;; gdev-lsp-navigation-test.el ends here
