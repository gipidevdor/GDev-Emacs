;;; gdev-breadcrumb-path-test.el --- Percorso del documento e del simbolo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verifiche del percorso corrente e dei comandi associati ai segmenti.

;;; Code:

(require 'ert)
(require 'gdev-outline)

(defun gdev-test-breadcrumb--load ()
  "Carica il fork e il suo modulo dal checkout in prova."
  (require 'package)
  (package-activate-all)
  (load (gdev-module-file :ui 'breadcrumb ".el") nil t t)
  (require 'breadcrumb))

(ert-deftest gdev-test-breadcrumb-fork-exposes-paths-and-rich-leaves ()
  "I nomi delle cartelle conservano i punti e le foglie ricche si navigano."
  (gdev-test-breadcrumb--load)
  (should (equal (breadcrumb-file-components "/tmp/Progetto.v2/api/codice.el" "/tmp/Progetto.v2/")
                 '(("Progetto.v2" . "/tmp/Progetto.v2/")
                   ("api" . "/tmp/Progetto.v2/api/")
                   ("codice.el" . "/tmp/Progetto.v2/api/codice.el"))))
  (with-temp-buffer
    (let ((index (list imenu--rescan-item
                       (list (propertize "Classe" 'breadcrumb-region '(1 . 80))
                             (cons (propertize "Metodo" 'breadcrumb-region '(10 . 50)) 10)))))
      (should (equal (breadcrumb-ipath index 30) '("Classe" "Metodo")))
      (should (equal (breadcrumb-ipath index 70) '("Classe")))
      (should-not (breadcrumb-ipath index 90)))))

(ert-deftest gdev-test-breadcrumb-narrow-keeps-file-symbol-and-full-help ()
  "Il percorso rientra nel budget a ogni dimensione con aiuto e clic."
  (gdev-test-breadcrumb--load)
  (let* ((file "/progetto/sorgenti/documento-dal-nome-molto-lungo.el")
         (directories (breadcrumb-file-components file "/progetto/"))
         (symbols '("Controlli" "generatore-molto-lungo")))
    (cl-letf (((symbol-function 'gdev-breadcrumb--measure) #'string-width))
      (dotimes (width 130)
        (should (<= (string-width (gdev-breadcrumb--render directories symbols width)) width)))
      (let* ((label (gdev-breadcrumb--render directories symbols 39))
             (file-help (format "Struttura di %s" file))
             (symbol-help "Scegli un simbolo · Controlli › generatore-molto-lungo"))
        (should (string-search ".el" label))
        (should (text-property-any 0 (length label) 'pointer 'hand label))
        (should (seq-some (lambda (index) (equal file-help (get-text-property index 'help-echo label)))
                          (number-sequence 0 (1- (length label)))))
        (should (seq-some (lambda (index) (equal symbol-help (get-text-property index 'help-echo label)))
                          (number-sequence 0 (1- (length label)))))))))

(ert-deftest gdev-test-breadcrumb-shares-outline-path-at-each-window-point ()
  "Lo stesso documento mostra il simbolo di ciascun gruppo e riusa Struttura."
  (gdev-test-breadcrumb--load)
  (gdev-test--with-layout
    (let* ((editor (gdev-layout-editor))
           (peer (gdev-split-editor-right))
           (source (generate-new-buffer "percorso-simboli.el"))
           pane)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacs-lisp-mode)
              (insert "(defun uno () t)\n(defun due () nil)\n"))
            (set-window-buffer editor source)
            (set-window-buffer peer source)
            (set-window-point editor 2)
            (set-window-point peer 26)
            (select-window editor)
            (gdev-outline-show)
            (setq pane (current-buffer))
            (should (equal (gdev-outline-symbol-path editor) '(t "uno")))
            (should (equal (gdev-outline-symbol-path peer) '(t "due")))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                      ((symbol-function 'gdev-breadcrumb--width) (lambda (_) 500))
                      ((symbol-function 'gdev-breadcrumb--measure) #'string-width)
                      ((symbol-function 'breadcrumb-imenu-path)
                       (lambda (&rest _) (ert-fail "Indice di Struttura già disponibile"))))
              (dolist (pair (list (cons editor "uno") (cons peer "due")))
                (with-selected-window (car pair)
                  (let ((label (gdev-breadcrumb--header #'ignore)))
                    (should (string-search (cdr pair) label))
                    (should (eq label (gdev-breadcrumb--header #'ignore))))))))
        (when (buffer-live-p pane) (kill-buffer pane))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest gdev-test-breadcrumb-click-targets-window-and-restores-on-quit ()
  "Cartella e file usano il gruppo del clic e conservano il fuoco al rifiuto."
  (gdev-test-breadcrumb--load)
  (gdev-test--with-layout
    (let* ((source (selected-window))
           (peer (gdev-split-editor-right))
           (path "/tmp/Progetto/api/")
           (event (list 'mouse-1 (list peer 'header-line '(1 . 1) 0)))
           (location (concat path "prova.el"))
           (labels (gdev-breadcrumb--file-labels (breadcrumb-file-components location "/tmp/Progetto/")))
           (folder (lookup-key (get-text-property 0 'local-map (nth 1 labels)) '[header-line mouse-1]))
           (file (lookup-key (get-text-property 0 'local-map (nth 2 labels)) '[header-line mouse-1]))
           opened)
      (cl-letf (((symbol-function 'find-file-read-args)
                 (lambda (&rest _)
                   (should (eq (selected-window) peer))
                   (should (equal default-directory path))
                   (signal 'quit nil))))
        (condition-case nil (funcall folder event) (quit nil))
        (should (eq (selected-window) source)))
      (cl-letf (((symbol-function 'find-file-read-args) (lambda (&rest _) (list location nil)))
                ((symbol-function 'gdev-open-file)
                 (lambda (file _) (setq opened (cons (selected-window) file)))))
        (funcall folder event))
      (should (equal opened (cons peer location)))
      (select-window source)
      (cl-letf (((symbol-function 'gdev-outline-show) (lambda () (setq opened (selected-window)))))
        (funcall file event))
      (should (eq opened peer)))))

(provide 'gdev-breadcrumb-path-test)
;;; gdev-breadcrumb-path-test.el ends here
