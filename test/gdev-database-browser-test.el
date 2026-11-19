;;; gdev-database-browser-test.el --- Prove dell'esploratore Database SQL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le prove attraversano la vista con adattatori controllati e lo stato
;; effettivo di Tab Bar. Le interrogazioni reali vivono nei test dei motori.

;;; Code:

(require 'ert)
(require 'gdev-lib)
(require 'gdev-database-browser
         (gdev-config-file "modules/lang/postgresql/gdev-database-browser"))

(defmacro gdev-test-database--with-workspaces (&rest body)
  "Esegui BODY con spazi distinti dal resto della suite."
  (declare (indent 0) (debug t))
  (let ((frame (make-symbol "frame"))
        (tabs (make-symbol "tabs")))
    `(let ((,frame (selected-frame))
           (,tabs (frame-parameter nil 'tabs))
           (tab-bar-closed-tabs nil))
       (unwind-protect
           (save-window-excursion
             (set-frame-parameter ,frame 'tabs nil)
             ,@body)
         (set-frame-parameter ,frame 'tabs ,tabs)))))

(ert-deftest gdev-test-database-browser-keeps-object-and-connection ()
  "Apertura, ridimensionamento e anteprima conservano l'oggetto del catalogo."
  (let ((name "fatture 進行 \"2026\"\narchivio")
        (connection '(sviluppo . servizio))
        requests view)
    (gdev-test-database--with-workspaces
      (unwind-protect
          (progn
            (setq view
                  (gdev-database-browser-display
                   'prova connection "Prova" default-directory
                   (lambda (target path reply)
                     (should (equal target connection))
                     (push (cons path reply) requests)
                     #'ignore)))
            (should (eq (window-buffer) view))
            (with-current-buffer view
              (should (derived-mode-p 'gdev-database-browser-mode))
              (should (eq gdev-ui-view-profile 'table))
              (funcall (cdar requests) '("vendite") nil)
              (call-interactively (keymap-lookup (current-local-map) "RET"))
              (should (equal (caar requests) '("vendite")))
              (funcall (cdar requests) (list (list name "m") '("altro" "v")) nil)
              (gdev-database-browser--select name)
              (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 37)))
                (gdev-database-browser--resize (selected-window)))
              (should (equal (tabulated-list-get-id) name))
              (should-not (string-search name (buffer-string)))
              (should (text-property-search-forward 'help-echo name t))
              (call-interactively (keymap-lookup (current-local-map) "RET"))
              (should (equal (caar requests) (list "vendite" name)))
              (funcall (cdar requests) '(("numero" "integer" t)) nil)
              (call-interactively (keymap-lookup (current-local-map) "v"))
              (should (equal (caar requests) (list "vendite" name 'anteprima)))
              (funcall (cdar requests) '((("Riga" nil) ("numero" "42"))) nil)
              (should (string-match-p "NULL.*42" (buffer-string)))
              (should (= (length tabulated-list-format) 3))
              (should (equal (mapcar #'car (append tabulated-list-format nil))
                             '("Riga" "Riga (2)" "numero")))
              (call-interactively (keymap-lookup (current-local-map) "^"))
              (funcall (cdar requests) '(("numero" "integer" t)) nil)
              (call-interactively (keymap-lookup (current-local-map) "^"))
              (funcall (cdar requests) (list (list name "m") '("altro" "v")) nil)
              (should (equal (tabulated-list-get-id) name))))
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest gdev-test-database-browser-discards-obsolete-responses ()
  "Le risposte superate e annullate non cambiano il livello visibile."
  (let (requests cancelled view)
    (gdev-test-database--with-workspaces
      (unwind-protect
          (progn
            (setq view
                  (gdev-database-browser-display
                   'prova 'prova "Prova" default-directory
                   (lambda (_ path reply)
                     (push reply requests)
                     (lambda () (push path cancelled)))))
            (with-current-buffer view
              (let ((original (car requests)))
                (gdev-database-browser-refresh)
                (should (equal cancelled '(nil)))
                (funcall original '("superata") nil)
                (should-not (string-search "superata" (buffer-string)))
                (funcall (car requests) '("vendite") nil))
              (gdev-database-browser-open)
              (let ((pending (car requests)))
                (gdev-database-browser-cancel)
                (should (equal cancelled '(("vendite") nil)))
                (funcall pending '(("ordini" "r")) nil))
              (should-not gdev-database-browser--path)
              (should (equal (tabulated-list-get-id) "vendite"))
              (should (string-search "annullato" (apply #'concat mode-line-process)))
              (gdev-database-browser-open)
              (funcall (car requests) nil "Connessione chiusa")
              (should-not gdev-database-browser--path)
              (should (equal (tabulated-list-get-id) "vendite"))))
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest gdev-test-database-browser-isolates-workspaces ()
  "Una connessione ha viste distinte e chiudere uno spazio annulla la sua richiesta."
  (let (requests cancelled first second)
    (gdev-test-database--with-workspaces
      (unwind-protect
          (let ((request (lambda (_ _ reply)
                           (let ((view (current-buffer)))
                             (push reply requests)
                             (lambda () (push view cancelled))))))
            (setq first (gdev-database-browser-display 'prova 'stessa "Stessa" default-directory request))
            (tab-bar-new-tab)
            (setq second (gdev-database-browser-display 'prova 'stessa "Stessa" default-directory request))
            (should-not (eq first second))
            (should (eq second (gdev-database-browser-display
                                'prova 'stessa "Stessa" default-directory request)))
            (should (= 2 (length requests)))
            (tab-bar-close-tab 1)
            (should-not (buffer-live-p first))
            (should (equal cancelled (list first)))
            (funcall (cadr requests) '("chiusa") nil)
            (funcall (car requests) '("attiva") nil)
            (with-current-buffer second
              (should (equal (tabulated-list-get-id) "attiva")))
            (should (equal (gdev-workspace-state-get 'gdev-database-browser-buffers) (list second))))
        (dolist (view (list second first))
          (when (buffer-live-p view) (kill-buffer view)))))))

(provide 'gdev-database-browser-test)
;;; gdev-database-browser-test.el ends here
