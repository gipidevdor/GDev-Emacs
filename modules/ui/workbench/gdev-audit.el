;;; gdev-audit.el --- Inventario riproducibile delle entrate di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; L'inventario accosta dichiarazioni Lisp, menu, scorciatoie e profili
;; contestuali della configurazione distribuita. Non invoca le azioni.

;;; Code:

(require 'cl-lib)
(require 'gdev-agent-interface)
(require 'gdev-command-sidebar)
(require 'gdev-context)
(require 'gdev-menu)
(require 'gdev-keys)
(require 'subr-x)
(require 'gdev-project-operations)

(defun gdev-audit--definitions (declarations)
  "Elenca i comandi interattivi fra le DECLARATIONS di GDev."
  (cl-loop for entry in declarations
           for kind = (alist-get 'kind entry)
           for interactive = (eq (alist-get 'interactive entry) t)
           when (or interactive
                    (and (equal kind "defalias")
                         (commandp (intern-soft (alist-get 'name entry)))))
           collect (if interactive entry
                     (cons '(interactive . t) (remq (assq 'interactive entry) entry)))))

(defun gdev-audit--menu-routes ()
  "Elenca i percorsi di menu anche quando il loro stato è condizionale."
  (let ((gdev-menu--defer-context t))
    (cl-loop for (id label . _) in gdev-menu--sections
             for actions = (gdev-command-sidebar--menu-actions
                            (gdev-menu-section-items id '((:catalog) :catalog)) label)
             append
             (cl-loop for action in actions
                      for command = (gdev-command-sidebar--action-command action)
                      when (and command (symbolp command))
                      collect `((path . ,(gdev-command-sidebar--action-path action))
                                (label . ,(gdev-command-sidebar--action-label action))
                                (command . ,(symbol-name command))
                                (key_hints . ,(vconcat
                                               (ensure-list
                                                (gdev-command-sidebar--action-sequences action)))))))))

(defun gdev-audit--binding (scope keys binding)
  "Descrivi BINDING di KEYS in SCOPE e la risoluzione effettiva."
  (let ((expected (if (and (consp binding) (stringp (car binding))) (cdr binding) binding)))
    (when (and (symbolp expected) expected (not (eq expected 'undefined)))
      (let ((actual (key-binding keys)))
        `((scope . ,scope)
          (key . ,(key-description keys))
          (command . ,(symbol-name expected))
          (effective . ,(if (and actual (symbolp actual)) (symbol-name actual) :null)))))))

(defun gdev-audit--keymap (map prefix scope)
  "Restituisci le scorciatoie di MAP dopo PREFIX in SCOPE."
  (let (rows)
    (dolist (entry (accessible-keymaps map))
      (map-keymap
       (lambda (event binding)
         (let ((keys (vconcat prefix (car entry) (vector event))))
           (when-let* (((not (seq-some #'mouse-event-p keys)))
                       ((not (seq-intersection keys [menu-bar tool-bar tab-bar tab-line
                                                    header-line mode-line remap])))
                       (row (gdev-audit--binding scope keys binding)))
             (push row rows))))
       (cdr entry)))
    (delete-dups (nreverse rows))))

(defun gdev-audit--key-routes (mode-specs)
  "Leggi i prefissi GDev, i tasti globali e i comandi dei linguaggi in MODE-SPECS."
  (let (direct)
    (map-keymap
     (lambda (event binding)
       (when (and (symbolp binding) binding
                  (or (string-prefix-p "gdev-" (symbol-name binding))
                      (and (symbolp event)
                           (or (memq 'super (event-modifiers event))
                               (string-match-p (rx (or bos "-") "f" (+ digit) eos)
                                               (symbol-name event))))))
         (push (gdev-audit--binding "globale" (vector event) binding) direct)))
     (current-global-map))
    (append
     (delq nil (nreverse direct))
     (cl-loop for (key map . _) in gdev-leader-groups
              append (gdev-audit--keymap (symbol-value map) (kbd (concat "C-c " key)) "globale"))
     (gdev-audit--keymap gdev-help-map (kbd "C-h d") "globale")
     (cl-loop for (library map _) in mode-specs
              when (and (require library nil t) (boundp map))
              when (gethash (symbol-value map) gdev--localleader-maps)
              append (with-temp-buffer
                       (use-local-map (symbol-value map))
                       (gdev-audit--keymap (gethash (symbol-value map) gdev--localleader-maps)
                                          (kbd "C-c l") (symbol-name map)))))))

(defun gdev-audit--mode-routes (declarations)
  "Leggi le scorciatoie delle modalità caricate fra le DECLARATIONS."
  (cl-loop for entry in declarations
           for name = (alist-get 'name entry)
           for map = (and (equal (alist-get 'kind entry) "define-derived-mode")
                          (intern-soft (concat name "-map")))
           when (and map (boundp map) (keymapp (symbol-value map)))
           append
           (with-temp-buffer
             (let* ((original (symbol-value map))
                    (local (copy-keymap original)))
               (set-keymap-parent local nil)
               (use-local-map original)
               (gdev-audit--keymap local [] name)))))

(defun gdev-audit--view-routes ()
  "Leggi i comandi dichiarati per i profili comuni delle viste."
  (cl-loop for (modes . items) in gdev-context--profiles
           append
           (cl-loop for item in items
                    for definition = (aref item 1)
                    for command = (or (gdev-context-item-command item)
                                      (and (symbolp definition) definition))
                    when (and command (symbolp command))
                    collect `((modes . ,(vconcat (mapcar #'symbol-name modes)))
                              (label . ,(aref item 0))
                              (command . ,(symbol-name command))))))

(defun gdev-audit-inventory (mode-specs)
  "Raccogli l'inventario della configurazione caricata e dei MODE-SPECS."
  (let ((declarations (cl-loop for entry across (gdev-agent-interface--symbols "")
                               unless (string-prefix-p "test/" (alist-get 'file entry))
                               collect entry)))
    `((schema_version . 1)
      (modules . ,(gdev-agent-interface--modules))
      (default_modules . ,(gdev-agent-interface--default-modules))
      (cli_commands . ,(gdev-agent-interface--checkout-commands))
      (live_actions . ,(vconcat (mapcar #'car gdev-agent-interface--live-actions)))
      (project_operation_model . ,(gdev-project-operation-model-check))
      (project_operation_contracts .
       ,(vconcat (mapcar (pcase-lambda (`(,id ,name ,tool ,phases ,authority))
                          `((id . ,(symbol-name id)) (name . ,name) (tool . ,(or tool :null))
                            (phases . ,(vconcat (mapcar #'symbol-name phases)))
                            (authority . ,(symbol-name authority))))
                        gdev-project-operation-contracts)))
      (definitions . ,(vconcat (gdev-audit--definitions declarations)))
      (menu_routes . ,(vconcat (gdev-audit--menu-routes)))
      (key_routes . ,(vconcat (gdev-audit--key-routes mode-specs)
                             (gdev-audit--mode-routes declarations)))
      (view_routes . ,(vconcat (gdev-audit--view-routes))))))

(provide 'gdev-audit)
;;; gdev-audit.el ends here
