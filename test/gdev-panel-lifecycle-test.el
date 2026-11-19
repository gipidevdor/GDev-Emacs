;;; gdev-panel-lifecycle-test.el --- Chiusura e ripresa delle viste -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; `q', la × e `C-x k' seguono una sola regola per riquadro.  Il pannello
;; salvato torna dopo il riavvio solo con gli strumenti registrati.

;;; Code:

(require 'ert)
(require 'gdev-commands)
(require 'gdev-workspaces)

(defun gdev-test-panel-lifecycle--tool (name)
  "Crea uno strumento di Emacs chiamato NAME, con `q' di `special-mode'."
  (with-current-buffer (generate-new-buffer name)
    (special-mode)
    (current-buffer)))

(ert-deftest gdev-test-panel-q-closes-a-tool-like-its-close-button ()
  "Nel pannello `q' di uno strumento di Emacs chiude la vista come la sua ×."
  (gdev-test--with-layout
    (let ((first (gdev-test-panel-lifecycle--tool "*Prima uscita di prova*"))
          (second (gdev-test-panel-lifecycle--tool "*Seconda uscita di prova*")))
      (unwind-protect
          (progn
            (should (gdev-layout-show-panel first))
            (should (gdev-layout-show-panel second))
            (select-window (gdev-layout-panel-window))
            (should (eq (key-binding (kbd "q")) #'gdev-quit-view))
            (call-interactively (key-binding (kbd "q")))
            (should-not (buffer-live-p second))
            (should (equal (gdev-layout--panel-buffers) (list first)))
            ;; La × sulla stessa vista porta allo stesso stato.
            (select-window (gdev-layout-panel-window))
            (should (eq (window-buffer) first))
            (gdev-close-document)
            (should-not (buffer-live-p first))
            (should-not (gdev-layout--panel-buffers)))
        (dolist (buffer (list first second))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-panel-q-in-a-fixed-column-returns-to-the-editor ()
  "Nelle colonne fisse `q' riporta all'editor e lascia aperta la colonna."
  (gdev-test--with-layout
    (let ((view (gdev-test-panel-lifecycle--tool "*Attività di prova*"))
          (editor (gdev-layout-editor)))
      (unwind-protect
          (let ((window (gdev-layout-show-left view 'gdev-sidebar)))
            (select-window window)
            (call-interactively (key-binding (kbd "q")))
            (should (eq (selected-window) editor))
            (should (window-live-p window))
            (should (buffer-live-p view)))
        (kill-buffer view)))))

(ert-deftest gdev-test-panel-kill-buffer-on-comparison-controls-ends-it ()
  "`C-x k' sui controlli del confronto lo termina e ripristina le finestre."
  (require 'ediff)
  (gdev-test--with-layout
    (let* ((first (make-temp-file "gdev-confronto-" nil ".txt" "uno\n"))
           (second (make-temp-file "gdev-confronto-" nil ".txt" "due\n"))
           (editors (length (gdev-layout--editors)))
           control)
      (unwind-protect
          (progn
            (setq control (gdev-compare-files first second))
            (should (> (length (gdev-layout--editors)) editors))
            (select-window (get-buffer-window control))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (call-interactively (key-binding (kbd "C-x k"))))
            (should-not (buffer-live-p control))
            (should-not (gdev-workspace-state-get 'gdev-comparison-control))
            (should (= (length (gdev-layout--editors)) editors)))
        (when (buffer-live-p control)
          (with-current-buffer control (ediff-really-quit nil)))
        (dolist (file (list first second))
          (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer))
          (delete-file file))))))

(ert-deftest gdev-test-panel-session-keeps-only-registered-tools ()
  "Il pannello salvato ricrea solo i tipi registrati e torna quando serve."
  (gdev-test--with-layout
    (let* ((gdev-layout--panel-restorers nil)
           (created nil)
           (tool (gdev-test-panel-lifecycle--tool "*Strumento ricreabile*")))
      (unwind-protect
          (progn
            (gdev-layout-register-panel-restorer
             'gdev-prova
             (lambda (properties)
               (let ((buffer (gdev-test-panel-lifecycle--tool (plist-get properties :name))))
                 (push buffer created)
                 buffer)))
            (with-current-buffer tool
              (setq-local gdev-layout-restore-function
                          (lambda () (list 'gdev-prova :name "*Strumento ricreato*"))))
            (should (gdev-layout-show-panel tool))
            (let ((saved (plist-get (gdev-workspaces--record (gdev-workspace-state-current))
                                    :panel)))
              (should (equal (plist-get saved :tools)
                             '((gdev-prova :name "*Strumento ricreato*"))))
              (should (eql (plist-get saved :active) 0))
              (should (plist-get saved :visible))
              (should (natnump (plist-get saved :height)))
              ;; Un riavvio: lo spazio non ha strumenti vivi.
              (kill-buffer tool)
              (gdev-layout-hide-panel)
              (gdev-workspace-state-update
               `((gdev-layout-panel-buffers) (gdev-layout-panel-active)
                 (gdev-layout-panel-session
                  . ,(gdev-workspaces--panel-session
                      (plist-put (copy-sequence saved) :tools
                                 (cons '(sconosciuto :programma "/bin/sh")
                                       (plist-get saved :tools))))))))
            ;; Lo spazio non ancora mostrato conserva il pannello salvato.
            (should (equal (plist-get (plist-get (gdev-workspaces--record
                                                  (gdev-workspace-state-current))
                                                 :panel)
                                      :tools)
                           '((sconosciuto :programma "/bin/sh")
                             (gdev-prova :name "*Strumento ricreato*"))))
            (should-not created)
            (let (scheduled)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (_time _repeat function &rest arguments)
                           (setq scheduled (cons function arguments)))))
                (gdev-layout--schedule-saved-panel (selected-frame))
                (gdev-layout--schedule-saved-panel (selected-frame)))
              (should scheduled)
              (should-not created)
              (apply (car scheduled) (cdr scheduled)))
            (should (= (length created) 1))
            (should (eq (window-buffer (gdev-layout-panel-window)) (car created)))
            (should (equal (gdev-layout--panel-buffers) created))
            (should-not (gdev-workspace-state-get 'gdev-layout-panel-session)))
        (dolist (buffer (cons tool created))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-panel-session-rejects-malformed-records ()
  "La convalida scarta un pannello salvato non conforme."
  (should-not (gdev-workspaces--panel-session nil))
  (should-not (gdev-workspaces--panel-session '(:tools (1 "testo" (nil :a 1)))))
  (should-not (gdev-workspaces--panel-session '(:tools ((prova . "non è una lista")))))
  (should (equal (gdev-workspaces--panel-session
                  '(:tools ((prova :a 1)) :active 4 :height -2 :visible si))
                 '(:tools ((prova :a 1)) :active nil :height nil :visible t))))

;;; gdev-panel-lifecycle-test.el ends here
