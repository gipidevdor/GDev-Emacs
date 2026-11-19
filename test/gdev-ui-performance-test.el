;;; gdev-ui-performance-test.el --- Regressioni nei percorsi frequenti dell'interfaccia -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica l'identità delle righe dopo un ridisegno dell'albero e il
;; riutilizzo delle mappe dei pulsanti nella barra di stato.

;;; Code:

(require 'ert)
(require 'gdev-modules)

(ert-deftest gdev-ui-perf-test-sidebar-rebuilds-position-index ()
  "L'indice segue le righe visibili, anche dopo un riordino o una modifica."
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (with-temp-buffer
    (gdev-sidebar-mode)
    (let* ((root "/progetto/")
           (first "/progetto/a.el")
           (middle "/progetto/b.el")
           (last "/progetto/c.el"))
      (setq gdev-sidebar--root root)
      (puthash root (list nil (list middle last)) gdev-sidebar--directory-cache)
      (gdev-sidebar--render middle)
      (let ((original (point)))
        (should (= original (gdev-sidebar--path-position middle)))
        (puthash root (list nil (list first middle)) gdev-sidebar--directory-cache)
        (gdev-sidebar--render)
        (should (= (point) (gdev-sidebar--path-position middle)))
        (should (> (point) original))
        (should-not (gdev-sidebar--path-position last)))
      (let ((inhibit-read-only t))
        (put-text-property (point) (1+ (point)) 'gdev-sidebar-path last))
      (should (= (point) (gdev-sidebar--path-position last))))))

(ert-deftest gdev-ui-perf-test-modeline-reuses-only-mouse-binding ()
  "La mappa si riusa senza conservare il testo o il suo suggerimento."
  (load (gdev-module-file :ui 'modeline ".el") nil t t)
  (let* ((first (gdev-modeline--clickable "prima" "suggerimento iniziale" #'ignore))
         (second (gdev-modeline--clickable "dopo" "suggerimento successivo" #'ignore))
         (other (gdev-modeline--clickable "altro" "altra azione" #'forward-char)))
    (should (equal second "dopo"))
    (should (equal (get-text-property 0 'help-echo second) "suggerimento successivo"))
    (should (eq (get-text-property 0 'keymap first) (get-text-property 0 'keymap second)))
    (should-not (eq (get-text-property 0 'keymap first) (get-text-property 0 'keymap other)))))

(ert-deftest gdev-ui-perf-test-debug-samples-only-a-visible-focused-target ()
  "Le pagine statiche e la pagina Sistema senza PID non creano un timer."
  (require 'gdev-debug-workbench)
  (let ((gdev-debug-workbench--timer nil)
        (visible t) (focused t) (sampled 0) (redrawn 0))
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (let ((window (selected-window)))
              (set-window-buffer window (current-buffer))
              (cl-letf (((symbol-function 'gdev-debug-workbench--visible)
                         (lambda () (and visible (list window))))
                        ((symbol-function 'gdev-debug-workbench--connection) #'ignore)
                        ((symbol-function 'gdev-debug-workbench--sample-process)
                         (lambda (target) (when target (cl-incf sampled))))
                        ((symbol-function 'gdev-project-view--render)
                         (lambda () (cl-incf redrawn)))
                        ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                        ((symbol-function 'frame-focus-state) (lambda (&rest _) focused)))
                (dolist (page '(session profile system))
                  (setq gdev-debug-workbench--page page)
                  (gdev-debug-workbench-refresh-visible)
                  (should-not gdev-debug-workbench--timer))
                (gdev-debug-workbench-refresh-visible)
                (should (= redrawn 3))
                (setq gdev-debug-workbench--manual-pid (emacs-pid))
                (gdev-debug-workbench-refresh-visible)
                (should (timerp gdev-debug-workbench--timer))
                (should (= sampled 1))
                (setq focused nil)
                (gdev-debug-workbench-refresh-visible)
                (should-not gdev-debug-workbench--timer)
                (should (= sampled 1))
                (setq focused t)
                (gdev-debug-workbench-refresh-visible)
                (should (timerp gdev-debug-workbench--timer))
                (setq visible nil)
                (gdev-debug-workbench-refresh-visible)
                (should-not gdev-debug-workbench--timer)))))
      (when gdev-debug-workbench--timer (cancel-timer gdev-debug-workbench--timer)))))

;;; gdev-ui-performance-test.el ends here
