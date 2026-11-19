;;; gdev-tab-reorder-test.el --- Riordino delle schede nei gruppi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica che tastiera, menu e trascinamento agiscano sull'ordine del
;; gruppo e conservino documento, posizione e modifiche.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun gdev-test-tabs--load ()
  "Carica il modulo delle schede e la riga nativa di Emacs."
  (unless (fboundp 'gdev-workspaces-move-document-left)
    (require 'package)
    (unless (memq 'tabspaces package-activated-list)
      (package-activate-all))
    (load (gdev-module-file :ui 'workspaces ".el") nil t t))
  (require 'tab-line))

(defmacro gdev-test-tabs--with-documents (&rest body)
  "Esegui BODY con EDITOR e tre documenti aperti da FIRST a LAST."
  (declare (indent 0) (debug t))
  `(progn
     (gdev-test-tabs--load)
     (gdev-test--with-layout
       (let* ((editor (gdev-layout-editor))
              (first (generate-new-buffer "Primo documento"))
              (middle (generate-new-buffer "Secondo documento"))
              (last (generate-new-buffer "Terzo documento"))
              (original (list first middle last)))
         (unwind-protect
             (with-selected-window editor
               (switch-to-buffer first)
               (set-window-prev-buffers editor nil)
               (set-window-next-buffers editor nil)
               (dolist (buffer original)
                 (switch-to-buffer buffer)
                 (gdev-layout-mark-document))
               (switch-to-buffer first)
               (set-window-parameter editor 'tab-line-buffers (copy-sequence original))
               ,@body)
           (mapc #'kill-buffer original))))))

(defun gdev-test-tabs--position (editor buffer &optional x)
  "Rappresenta BUFFER nella riga delle schede di EDITOR alla coordinata X."
  (list editor 'tab-line (cons (or x 30) 12) 0
        (cons (propertize "  Documento  " 'tab buffer) 2) nil nil '(0 . 0) nil '(10 . 16)))

(ert-deftest gdev-test-tabs-keyboard-reorder-keeps-view-and-persisted-order ()
  "Lo spostamento da tastiera vale nel solo gruppo e conserva la vista."
  (gdev-test-tabs--with-documents
    (gdev-operation-install)
    (insert "Modifiche del documento")
    (goto-char 8)
    (let ((other (gdev-layout-split-editor 'right editor)))
      (with-selected-window other
        (switch-to-buffer last)
        (gdev-workspaces--document-tabs))
      (let ((other-order (window-parameter other 'tab-line-buffers)))
        (should (gdev-workspaces-document-move-available-p 1))
        (set-window-parameter editor 'tab-line-hscroll 2)
        (let ((native (tab-line-cache-key-default original)))
          (should (equal (seq-take (gdev-workspaces--document-tab-cache-key original) (length native))
                         native)))
        (gdev-workspaces-move-document-right)
        (should-not (window-parameter editor 'tab-line-hscroll))
        (should (equal (gdev-workspaces--document-tabs) (list middle first last)))
        (should (equal (window-parameter other 'tab-line-buffers) other-order))
        (should (eq (selected-window) editor))
        (should (eq (window-buffer editor) first))
        (should (= (window-point editor) 8))
        (should (buffer-modified-p first))
        (gdev-operation-undo)
        (should (equal (gdev-workspaces--document-tabs) original))
        (gdev-operation-redo)
        (should (equal (gdev-workspaces--document-tabs) (list middle first last)))
        (delete-window other)
        (let* ((tree (cdr (plist-get (gdev-workspaces--capture) :windows)))
               (saved (gdev-workspaces--map-tree
                       tree (lambda (buffer) (and (bufferp buffer) (buffer-name buffer)))))
               (resolved (gdev-workspaces--map-tree saved #'get-buffer)))
          (should (equal (alist-get 'tab-line-buffers (alist-get 'parameters (cdr resolved)))
                         (list middle first last))))
        (gdev-workspaces-move-document-left)
        (should (equal (gdev-workspaces--document-tabs) original))
        (should-not (gdev-workspaces-document-move-available-p -1))
        (should-error (gdev-workspaces-move-document-left) :type 'user-error)
        (should (equal (gdev-workspaces--document-tabs) original))))))

(ert-deftest gdev-test-tabs-drag-shows-drop-and-selects-inactive-document ()
  "Il rilascio riordina una scheda inattiva e le assegna il fuoco."
  (gdev-test-tabs--with-documents
    (let* ((from (gdev-test-tabs--position editor middle))
           (to (gdev-test-tabs--position editor last 150))
           (drag (list 'drag-mouse-1 from to))
           (events (list (list 'mouse-movement to) drag)))
      (should (eq (lookup-key gdev-workspaces--document-tab-map [tab-line down-mouse-1])
                  #'gdev-workspaces--tab-press))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _)
                   (when (eq (car events) drag)
                     (should (eq (window-buffer editor) first))
                     (should (eq (window-parameter editor 'gdev-workspaces-tab-drop) last))
                     (should (equal (get-text-property 0 'mouse-face
                                                       (gdev-workspaces--format-tab last original))
                                    '(gdev-ui-side-selection (:underline t)))))
                   (pop events))))
        (gdev-workspaces--tab-press (list 'down-mouse-1 from)))
      (should-not (window-parameter editor 'gdev-workspaces-tab-drop))
      (should (eq (window-buffer editor) middle))
      (should (equal (gdev-workspaces--document-tabs) (list first last middle))))))

(ert-deftest gdev-test-tabs-cancel-drag-and-plain-click ()
  "Annullamento, rilascio fuori gruppo e clic hanno esiti distinti."
  (gdev-test-tabs--with-documents
    (let* ((other (gdev-layout-split-editor 'right editor))
           (from (gdev-test-tabs--position editor middle))
           (over (gdev-test-tabs--position editor last 150))
           (outside (list other 'vertical-scroll-bar '(1 . 0) 0)))
      (dolist (cancel (list 27 (list 'drag-mouse-1 from outside)))
        (let ((events (list (list 'mouse-movement over) cancel)))
          (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (pop events))))
            (gdev-workspaces--tab-press (list 'down-mouse-1 from))))
        (should-not (window-parameter editor 'gdev-workspaces-tab-drop))
        (should (eq (window-buffer editor) first))
        (should (equal (gdev-workspaces--document-tabs) original)))
      (cl-letf (((symbol-function 'read-event) (lambda (&rest _) (list 'mouse-1 from))))
        (gdev-workspaces--tab-press (list 'down-mouse-1 from)))
      (should (eq (window-buffer editor) middle))
      (should (equal (gdev-workspaces--document-tabs) original)))))

(ert-deftest gdev-test-tabs-context-reorders-indicated-tab ()
  "Il menu contestuale sposta il bersaglio, anche se la scheda è inattiva."
  (gdev-test-tabs--with-documents
    (let ((position (gdev-test-tabs--position editor middle)) menu)
      (cl-letf (((symbol-function 'popup-menu) (lambda (map &rest _) (setq menu map))))
        (gdev-context-tab (list 'down-mouse-3 position)))
      (call-interactively (lookup-key menu [gdev-workspaces-move-document-left]))
      (should (eq (selected-window) editor))
      (should (eq (window-buffer editor) middle))
      (should (equal (gdev-workspaces--document-tabs) (list middle first last))))))

(ert-deftest gdev-test-tabs-scrolls-during-drag-and-restores-on-cancel ()
  "Sostando sulla freccia si vedono le altre schede. Annulla ripristina la vista."
  (gdev-test-tabs--with-documents
    (let* ((from (gdev-test-tabs--position editor first))
           (arrow (copy-sequence (gdev-test-tabs--position editor nil 256)))
           (events (list (list 'mouse-movement arrow) nil 27)))
      (setcar (nthcdr 4 arrow) (cons (propertize " › " 'keymap tab-line-right-map) 1))
      (set-window-parameter editor 'tab-line-hscroll 0)
      (cl-letf (((symbol-function 'read-event)
                 (lambda (_prompt _input-method timeout)
                   (pcase (length events)
                     (3 (should-not timeout))
                     (2 (should (numberp timeout)))
                     (1 (should (= (window-parameter editor 'tab-line-hscroll) 1))))
                   (pop events))))
        (gdev-workspaces--tab-press (list 'down-mouse-1 from)))
      (should (= (window-parameter editor 'tab-line-hscroll) 0))
      (should (equal (gdev-workspaces--document-tabs) original)))))

(ert-deftest gdev-test-tabs-transfer-inactive-dirty-document-and-undo ()
  "La scheda trascinata mantiene il contenuto e le posizioni dei due gruppi."
  (require 'gdev-editor-tabs)
  (gdev-test-tabs--with-documents
    (with-current-buffer middle (insert "prima\nseconda\nterza\n"))
    (switch-to-buffer middle)
    (goto-char 9)
    (switch-to-buffer first)
    (let* ((target (gdev-layout-split-editor 'right editor))
           (fourth (generate-new-buffer "Quarto documento")))
      (unwind-protect
          (progn
            (with-current-buffer fourth (gdev-layout-mark-document))
            (set-window-buffer target fourth)
            (set-window-prev-buffers target (list (with-current-buffer last (list last (copy-marker 1) (copy-marker 1)))))
            (set-window-next-buffers target nil)
            (set-window-parameter target 'tab-line-buffers (list last fourth))
            (let* ((from (gdev-test-tabs--position editor middle))
                   (to (gdev-test-tabs--position target fourth 150))
                   (drag (list 'drag-mouse-1 from to))
                   (events (list (list 'mouse-movement to) drag)))
              (gdev-operation-install)
              (cl-letf (((symbol-function 'read-event)
                         (lambda (&rest _)
                           (when (eq (car events) drag)
                             (should (eq (window-parameter target 'gdev-workspaces-tab-drop) fourth))
                             (should (eq (selected-window) editor)))
                           (pop events))))
                (gdev-workspaces--tab-press (list 'down-mouse-1 from))))
            (should (eq (selected-window) target))
            (should (eq (window-buffer target) middle))
            (should (= (window-point target) 9))
            (should (buffer-modified-p middle))
            (should (eq (window-buffer editor) first))
            (should-not (window-parameter target 'gdev-workspaces-tab-drop))
            (should (equal (gdev-workspaces--document-tabs) (list last middle fourth)))
            (should (equal (with-selected-window editor (gdev-workspaces--document-tabs)) (list first last)))
            (should (gdev-operation-undo-label))
            (gdev-operation-undo)
            (should (eq (window-buffer target) fourth))
            (should (equal (with-selected-window target (gdev-workspaces--document-tabs)) (list last fourth)))
            (should (equal (gdev-workspaces--document-tabs) original))
            (gdev-operation-redo)
            (should (eq (window-buffer target) middle))
            (should (= (window-point target) 9))
            (should (equal (gdev-workspaces--document-tabs) (list last middle fourth))))
        (kill-buffer fourth)))))

(ert-deftest gdev-test-tabs-transfer-duplicate-keeps-target-view-and-appends-only-new-tabs ()
  "Un gruppo con la stessa scheda mantiene la sua vista e l'ordine."
  (require 'gdev-editor-tabs)
  (gdev-test-tabs--with-documents
    (insert "Riga uno\nRiga due\nRiga tre\n")
    (goto-char 4)
    (let ((target (gdev-layout-split-editor 'right editor)))
      (set-window-buffer-start-and-point target first 1 12)
      (set-window-prev-buffers target (list (with-current-buffer last (list last (copy-marker 1) (copy-marker 1)))))
      (set-window-parameter target 'tab-line-buffers (list first last))
      (gdev-editor-move-to-group target editor)
      (should (eq (selected-window) target))
      (should (= (window-point target) 12))
      (should (equal (gdev-workspaces--document-tabs) (list first last)))
      (should (equal (with-selected-window editor (gdev-workspaces--document-tabs)) (list middle last)))
      (should-not (assq first (window-prev-buffers editor))))))

(ert-deftest gdev-test-tabs-drop-blank-group-clears-preview-and-preserves-groups ()
  "Il corpo del gruppo vuoto accetta la scheda senza cambiare geometria."
  (require 'gdev-editor-tabs)
  (gdev-test-tabs--with-documents
    (let* ((target (gdev-layout-split-editor 'right editor))
           (home (gdev-layout-home-buffer))
           (from (gdev-test-tabs--position editor middle))
           (body (list target 1 '(10 . 40) 0))
           (drag (list 'drag-mouse-1 from body))
           (events (list (list 'mouse-movement body) drag)))
      (set-window-buffer target home)
      (set-window-prev-buffers target nil)
      (set-window-next-buffers target nil)
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _)
                   (when (eq (car events) drag)
                     (should (eq (window-parameter target 'gdev-workspaces-tab-drop) 'end))
                     (should (overlayp (window-parameter target 'gdev-workspaces-tab-drop-overlay))))
                   (pop events))))
        (gdev-workspaces--tab-press (list 'down-mouse-1 from)))
      (should (eq (window-buffer target) middle))
      (should (eq (window-buffer editor) first))
      (should-not (window-parameter target 'gdev-workspaces-tab-drop-overlay))
      (should (= (length (gdev-layout--editors)) 2)))))

(ert-deftest gdev-test-tabs-transfer-rolls-back-after-target-change ()
  "Se il ripristino dell'origine fallisce ritorna tutta la disposizione."
  (require 'gdev-editor-tabs)
  (gdev-test-tabs--with-documents
    (let ((target (gdev-layout-split-editor 'right editor)))
      (set-window-buffer target last)
      (set-window-parameter target 'tab-line-buffers (list last))
      (let ((source-state (gdev-operation-window-tab-state editor))
            (target-state (gdev-operation-window-tab-state target)))
        (cl-letf (((symbol-function 'gdev-layout--restore-document)
                   (lambda (window)
                     (set-window-buffer window middle)
                     (error "Errore simulato"))))
          (should-error (gdev-editor-move-to-group target editor)))
        (should (eq (selected-window) editor))
        (should (eq (window-buffer editor) first))
        (should (eq (window-buffer target) last))
        (should (equal (gdev-operation-window-tab-state editor) source-state))
        (should (equal (gdev-operation-window-tab-state target) target-state))))))

;;; gdev-tab-reorder-test.el ends here
