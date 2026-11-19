;;; gdev-terminal-split-test.el --- Profili e terminali affiancati -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica i profili di avvio e la disposizione del pannello inferiore.

;;; Code:

(require 'ert)

(defmacro gdev-test--with-profile-terminals (&rest body)
  "Esegui BODY con terminali Eat di prova, senza processi."
  (declare (indent 0))
  `(progn
     (require 'package)
     (package-activate-all)
     (load (gdev-module-file :term 'eat ".el") nil t t)
     (require 'eat)
     (gdev-test--with-layout
       (let* ((root (file-name-as-directory (make-temp-file "gdev-term-test-" t)))
              (subdir (file-name-as-directory (expand-file-name "sotto" root)))
              (profile '("Bash di prova" "/bin/bash" "--noprofile"))
              (gdev-term-profiles (list profile))
              (editor (selected-window))
              (tool (generate-new-buffer "*Compilazione di prova*"))
              sessions)
         (unwind-protect
             (progn
               (make-directory subdir)
               (gdev-workspace-set-roots (list root))
               (cl-letf (((symbol-function 'gdev-term--make-profile-session)
                          (lambda (name settings)
                            (let ((buffer (generate-new-buffer (concat "*" name "*"))))
                              (push (list buffer default-directory settings) sessions)
                              (with-current-buffer buffer
                                (setq major-mode 'eat-mode))
                              buffer))))
                 ,@body))
           (mapc (lambda (session) (kill-buffer (car session))) sessions)
           (kill-buffer tool)
           (delete-directory root t))))))

(ert-deftest gdev-test-terminal-split-inherits-profile-and-directory ()
  "Profilo, posizione, fuoco e sessioni seguono i comandi del pannello."
  (gdev-test--with-profile-terminals
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (car profile))))
      (gdev-term-new-profile))
    (let* ((first (caar sessions))
           (panel (gdev-layout--panel))
           (format (buffer-local-value 'tab-line-format first)))
      (should (equal (cdar sessions) (list root profile)))
      (should (eq (selected-window) panel))
      (should (eq (keymap-lookup gdev-layout--terminal-profile-map "RET") 'gdev-term-new-profile))
      (should (eq (keymap-lookup gdev-layout--split-terminal-map "RET") 'gdev-term-split))
      (should (eq (car format) gdev-layout--new-terminal-button))
      (setq-local default-directory subdir)
      (select-window editor)
      (gdev-layout-click-split-terminal (list 'mouse-1 (list panel 'tab-line '(0 . 0) 0)))
      (let* ((second (caar sessions))
             (right (gdev-layout-panel-companion)))
        (should (equal (cdar sessions) (list subdir profile)))
        (should (eq (selected-window) right))
        (should (eq (window-buffer right) second))
        (should (eq (window-buffer panel) first))
        (should (equal (gdev-workspace-state-get 'gdev-layout-panel-split) (list first second)))
        (should (equal (gdev-layout--panel-buffers) (list first second)))
        (should-error (gdev-term-split) :type 'user-error)
        (gdev-term-focus-other)
        (should (eq (selected-window) panel))
        (gdev-term-focus-other)
        (should (eq (selected-window) right))
        (gdev-layout--reconcile)
        (should (eq (gdev-workspace-state-get 'gdev-layout-panel-active) second))
        (gdev-layout-toggle-panel)
        (should-not (gdev-layout--panel))
        (should-not (gdev-layout-panel-companion))
        (should (and (buffer-live-p first) (buffer-live-p second)))
        (gdev-layout-toggle-panel)
        (should (eq (window-buffer (gdev-layout-panel-companion)) second))
        (should (eq (gdev-workspace-state-get 'gdev-layout-panel-active) second))
        (select-window (gdev-layout-panel-companion))
        (gdev-close-document)
        (should-not (buffer-live-p second))
        (should-not (gdev-layout-panel-companion))
        (should-not (gdev-workspace-state-get 'gdev-layout-panel-split))
        (should (eq (window-buffer (gdev-layout--panel)) first))))))

(ert-deftest gdev-test-terminal-split-survives-tools-resize-and-workspace-switch ()
  "Gli strumenti temporaneamente in primo piano non sostituiscono le sessioni."
  (gdev-test--with-profile-terminals
    (let ((first (gdev-term--open-project root profile))
          second)
      (setq second (gdev-term-split))
      (tab-line-select-tab-buffer tool (gdev-layout--panel))
      (should (eq (window-buffer (gdev-layout--panel)) tool))
      (should-not (gdev-layout-panel-companion))
      (gdev-term-project)
      (should (gdev-layout-panel-companion))
      (tab-bar-new-tab)
      (should-not (gdev-workspace-state-get 'gdev-layout-panel-split))
      (should-not (gdev-layout-panel-companion))
      (tab-bar-select-tab 1)
      (should (equal (gdev-workspace-state-get 'gdev-layout-panel-split) (list first second)))
      (let ((companion (gdev-layout-panel-companion)))
        (select-window companion)
        (cl-letf (((symbol-function 'gdev-layout-panel-split-fits-p) #'ignore))
          (gdev-layout--reconcile)
          (should-not (gdev-layout-panel-companion))
          (should (eq (window-buffer (gdev-layout--panel)) second)))
        (gdev-layout--reconcile)
        (should (eq (window-buffer (gdev-layout-panel-companion)) second))))))

(ert-deftest gdev-test-terminal-sessions-return-after-restart ()
  "I terminali tornano con cartella e profilo quando lo spazio mostra il pannello."
  (require 'gdev-workspaces)
  (gdev-test--with-profile-terminals
    (let* ((first (gdev-term--open-project root profile))
           (saved (progn
                    (with-current-buffer first (setq default-directory subdir))
                    (plist-get (gdev-workspaces--record (gdev-workspace-state-current)) :panel)))
           scheduled)
      (should (equal (plist-get saved :tools)
                     (list (list 'terminal :root root :directory subdir :profile profile))))
      (should (plist-get saved :visible))
      ;; Un riavvio: nessuna sessione viva, il pannello salvato nello spazio.
      (gdev-layout-hide-panel)
      (kill-buffer first)
      (gdev-workspace-state-update
       `((gdev-layout-panel-buffers) (gdev-layout-panel-active)
         (gdev-layout-panel-session . ,(gdev-workspaces--panel-session saved))))
      (setq sessions nil)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest arguments)
                   (setq scheduled (cons function arguments)))))
        (gdev-layout--schedule-saved-panel (selected-frame)))
      (should-not sessions)
      (apply (car scheduled) (cdr scheduled))
      (let ((restored (caar sessions)))
        (should (equal (cdar sessions) (list subdir profile)))
        (should (eq (window-buffer (gdev-layout-panel-window)) restored))
        (should (equal (buffer-local-value 'gdev-term--project-root restored) root)))
      ;; Solo cartelle locali e profili ancora configurati.
      (should-not (gdev-term--restore (list :root root :profile '("Altro" "/bin/sh"))))
      (should-not (gdev-term--restore (list :root "/ssh:host:/tmp/")))
      (should-not (gdev-term--restore (list :root (expand-file-name "manca" root))))
      (should (= (length sessions) 1)))))

(ert-deftest gdev-test-terminal-exit-preserves-companion ()
  "La fine della shell di sinistra lascia la seconda sessione nel pannello."
  (gdev-test--with-profile-terminals
    (let* ((first (gdev-term--open-project root profile))
           (second (gdev-term-split)))
      (kill-buffer first)
      (gdev-layout--reconcile)
      (should-not (gdev-layout-panel-companion))
      (should (eq (window-buffer (gdev-layout--panel)) second))
      (should (equal (gdev-layout--panel-buffers) (list second)))
      (should (eq (gdev-workspace-state-get 'gdev-layout-panel-active) second))
      (should-not (gdev-workspace-state-get 'gdev-layout-panel-split)))))

(ert-deftest gdev-test-terminal-profile-cancel-and-split-failure-keep-state ()
  "L'annullamento e una divisione fallita lasciano invariato lo spazio."
  (gdev-test--with-profile-terminals
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
      (should (eq (condition-case nil (gdev-term-new-profile) (quit 'annullato)) 'annullato)))
    (should-not sessions)
    (should-not (gdev-layout--panel))
    (let* ((first (gdev-term--open-project root profile))
           (panel (gdev-layout--panel))
           (slot (symbol-function 'gdev-layout--panel-slot)))
      (select-window editor)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
        (let ((event (list 'mouse-1 (list panel 'tab-line '(0 . 0) 0))))
          (should (eq (condition-case nil (gdev-layout-click-terminal-profile event)
                        (quit 'annullato))
                      'annullato))))
      (should (eq (selected-window) editor))
      (select-window panel)
      (cl-letf (((symbol-function 'gdev-layout--panel-slot)
                 (lambda (buffer &optional companion)
                   (unless companion (funcall slot buffer)))))
        (should-error (gdev-term-split) :type 'user-error))
      (should (= (length sessions) 2))
      (should-not (buffer-live-p (caar sessions)))
      (should (equal (gdev-layout--panel-buffers) (list first)))
      (should (eq (gdev-workspace-state-get 'gdev-layout-panel-active) first))
      (should-not (gdev-workspace-state-get 'gdev-layout-panel-split))
      (should-not (gdev-layout-panel-companion))
      (should (eq (selected-window) panel)))))

;;; gdev-terminal-split-test.el ends here
