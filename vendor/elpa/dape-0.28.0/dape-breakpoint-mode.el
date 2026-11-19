;;; dape-breakpoint-mode.el --- Clickable breakpoint margins -*- lexical-binding: t; -*-

;; Copyright (C) 2023-2026 Free Software Foundation, Inc.
;; Author: Daniel Pettersson <daniel@dpettersson.net>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Modificato per GDev-Emacs il 2026-11-15: controlli del margine separati
;; da dape.el per caricare il client al primo utilizzo.

;;; Commentary:

;; The margin and its key bindings are available before the DAP client
;; is loaded.  Activating a breakpoint loads the existing Dape command.

;;; Code:

(require 'easy-mmode)

;; Keep Customize discoverable before the client is loaded.
(custom-autoload 'dape "dape" t)
(custom-add-to-group 'applications 'dape 'custom-group)

(autoload 'dape-breakpoint-toggle "dape" nil t)
(autoload 'dape-breakpoint-log "dape" nil t)
(autoload 'dape-breakpoint-expression "dape" nil t)
(autoload 'dape-breakpoint-hits "dape" nil t)

(defcustom dape-default-breakpoints-file
  (locate-user-emacs-file "dape-breakpoints")
  "Default file for loading and saving breakpoints.
See `dape-breakpoint-load' and `dape-breakpoint-save'."
  :type 'file
  :group 'dape)

(defun dape--read-breakpoint-file (filename)
  "Read the saved breakpoint records in FILENAME."
  (with-temp-buffer
    (insert-file-contents filename)
    (goto-char (point-min))
    (read (current-buffer))))

(defmacro dape--mouse-command (name doc command)
  "Create mouse command with NAME, DOC which call COMMAND."
  (declare (indent 1))
  `(defun ,name (event)
     ,doc
     (interactive "e")
     (save-selected-window
       (let ((start (event-start event)))
         (select-window (posn-window start))
         (save-excursion
           (goto-char (posn-point start))
           (call-interactively ',command))))))

(dape--mouse-command dape-mouse-breakpoint-toggle
  "Toggle breakpoint at current line."
  dape-breakpoint-toggle)

(dape--mouse-command dape-mouse-breakpoint-log
  "Add log breakpoint at current line."
  dape-breakpoint-log)

(dape--mouse-command dape-mouse-breakpoint-expression
  "Add expression breakpoint at current line."
  dape-breakpoint-expression)

(dape--mouse-command dape-mouse-breakpoint-hits
  "Add hits breakpoint at current line."
  dape-breakpoint-hits)

(defvar dape-breakpoint-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-fringe mouse-1] #'dape-mouse-breakpoint-toggle)
    (define-key map [left-margin mouse-1] #'dape-mouse-breakpoint-toggle)
    ;; TODO Would be nice if mouse-2 would open an menu for any
    ;; breakpoint type (expression, log and hit).
    (define-key map [left-fringe mouse-2] #'dape-mouse-breakpoint-expression)
    (define-key map [left-margin mouse-2] #'dape-mouse-breakpoint-expression)
    (define-key map [left-fringe mouse-3] #'dape-mouse-breakpoint-log)
    (define-key map [left-margin mouse-3] #'dape-mouse-breakpoint-log)
    map)
  "Keymap for `dape-breakpoint-mode'.")

(define-minor-mode dape-breakpoint-mode
  "Toggle clickable breakpoint controls in fringe or margins."
  :lighter nil)

(defun turn-on-dape-breakpoint-mode ()
  "Turn on `dape-breakpoint-mode' if derived from `prog-mode'."
  (when (derived-mode-p 'prog-mode)
    (dape-breakpoint-mode 1)))

;;;###autoload
(define-globalized-minor-mode dape-breakpoint-global-mode dape-breakpoint-mode
  turn-on-dape-breakpoint-mode
  :group 'dape)

(provide 'dape-breakpoint-mode)
;;; dape-breakpoint-mode.el ends here
