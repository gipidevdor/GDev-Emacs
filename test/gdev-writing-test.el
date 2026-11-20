;;; gdev-writing-test.el --- Verifiche per gli strumenti di scrittura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la destinazione del riquadro e il conteggio nella selezione.

;;; Code:

(require 'ert)
(require 'gdev-writing)
(require 'gdev-command-sidebar)

(ert-deftest gdev-test-writing-templates-open-from-a-cold-workbench ()
  "Un profilo senza moduli di scrittura crea i due progetti dal menu reale."
  (let* ((root (make-temp-file "gdev-modelli-" t))
         (process-environment (copy-sequence process-environment))
         (default-directory gdev-config-directory))
    (unwind-protect
        (progn
          (setenv "GDEV_PROFILE" nil)
          (setenv "GDEV_USER_DIR" root)
          (setenv "GDEV_STATE_DIR" (expand-file-name "stato" root))
          (with-temp-file (expand-file-name "init.el" root)
            (insert "(gdev! :ui workbench dashboard :config default)"))
          (with-temp-buffer
            (let ((status
                   (call-process
                    (expand-file-name invocation-name invocation-directory) nil t nil
                    "--batch" "-Q" "-l" "early-init.el"
                    "--eval" "(progn (require 'package) (package-activate-all))"
                    "-l" "init.el" "--eval"
                    (prin1-to-string
                     '(progn
                        (cl-assert (autoloadp (symbol-function 'gdev-article-new-project)))
                        (cl-assert (autoloadp (symbol-function 'gdev-latex-new-project)))
                        (dolist (row '(("Articolo…" "articolo.org" gdev-article-mode)
                                       ("LaTeX…" "main.tex" gdev-latex-mode)))
                          (let* ((type (car row))
                                 (dest (expand-file-name type gdev-user-directory))
                                 (menu (vector 'menu-bar 'gdev-project (intern "Nuovo progetto") (intern type))))
                            (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) dest))
                                      ((symbol-function 'read-string) (lambda (&rest _) "Titolo di prova")))
                              (call-interactively (lookup-key global-map menu)))
                            (cl-assert (file-equal-p dest (car (gdev-workspace-roots))))
                            (cl-assert (file-equal-p buffer-file-name (expand-file-name (cadr row) dest)))
                            (cl-assert (eq major-mode (nth 2 row))))))))))
              (ert-info ((buffer-string)) (should (zerop status))))))
      (delete-directory root t))))

(ert-deftest gdev-test-writing-counts-the-selection ()
  "Il comando usa la selezione quando è attiva."
  (with-temp-buffer
    (insert "una due tre")
    (should (= 3 (call-interactively #'gdev-writing-count-words)))
    (let ((transient-mark-mode t))
      (goto-char 8)
      (set-mark (point-min))
      (activate-mark)
      (should (= 2 (call-interactively #'gdev-writing-count-words))))))

(ert-deftest gdev-test-writing-uses-the-editor-and-keeps-focus ()
  "Il riquadro Comandi usa la finestra del testo anche se un altro strumento ha il fuoco."
  (let ((text (generate-new-buffer " *scrittura-test*"))
        (tool (generate-new-buffer " *strumento-scrittura-test*"))
        calls)
    (unwind-protect
        (save-window-excursion
          (let* ((editor (selected-window))
                 (other (split-window-below)))
            (set-window-buffer editor text)
            (set-window-buffer other tool)
            (with-current-buffer text (setq major-mode 'gdev-article-mode))
            (select-window other)
            (cl-letf (((symbol-function 'gdev-layout-editor) (lambda (&optional _) editor))
                      ((symbol-function 'gdev-command-sidebar-select)
                       (lambda (category keep-focus)
                         (push (list (selected-window) category keep-focus) calls)
                         nil))
                      ((symbol-function 'gdev-command-sidebar-find)
                       (lambda () (push (selected-window) calls))))
              (gdev-writing-open)
              (should (equal calls (list (list editor 'context t))))
              (call-interactively #'gdev-writing-open)
              (should (equal calls (list editor (list editor 'context t) (list editor 'context t))))
              (should (eq (selected-window) other)))))
      (kill-buffer text)
      (kill-buffer tool))))

(ert-deftest gdev-test-writing-replaces-the-group-when-the-language-map-stays-present ()
  "Il riquadro aggiorna il gruppo anche se entrambe le viste hanno una mappa."
  (let ((text (generate-new-buffer " *scrittura-test*"))
        (commands (generate-new-buffer " *comandi-scrittura-test*"))
        (map (make-sparse-keymap)))
    (unwind-protect
        (save-window-excursion
          (let* ((editor (selected-window))
                 (side (split-window-below)))
            (set-window-buffer editor text)
            (set-window-buffer side commands)
            (with-current-buffer commands (gdev-command-sidebar-mode))
            (cl-letf (((symbol-function 'gdev-menu--language-map) (lambda () map))
                      ((symbol-function 'gdev-command-sidebar--render) #'ignore))
              (gdev-command-sidebar--update side editor)
              (with-current-buffer commands
                (should (assq 'view (alist-get 'context gdev-command-sidebar--groups-by-category))))
              (with-current-buffer text (setq major-mode 'gdev-article-mode))
              (gdev-command-sidebar--update side editor)
              (with-current-buffer commands
                (let ((groups (alist-get 'context gdev-command-sidebar--groups-by-category)))
                  (should (assq 'writing groups))
                  (should-not (assq 'view groups)))))))
      (kill-buffer text)
      (kill-buffer commands))))

(provide 'gdev-writing-test)
;;; gdev-writing-test.el ends here
