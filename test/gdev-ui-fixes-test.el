;;; gdev-ui-fixes-test.el --- Prove di tema, finestre figlie, Struttura e barra laterale -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Le finestre nuove seguono il tema attuale, i popup a finestra figlia non
;; ricevono il pulsante ×, la Struttura sopravvive a un cambio di modalità e
;; l'albero dei file si aggiorna anche fuori da un repository Git.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-ui)
(require 'gdev-layout)
(require 'gdev-search)
(require 'gdev-preferences)
(require 'gdev-lavorazioni)
(require 'gdev-project-dependencies)

(defvar gdev-outline--subscribers)
(defvar gdev-sidebar--root)
(defvar gdev-sidebar--repo)

(ert-deftest gdev-test-new-frames-follow-the-current-theme ()
  "Dopo un cambio di tema `default-frame-alist' non conserva lo sfondo di avvio."
  (let ((default-frame-alist (list '(background-color . "#ffffff") '(ns-appearance . light)))
        (gdev-ui--appearance nil))
    (cl-letf (((symbol-function 'load-theme) #'ignore)
              ((symbol-function 'disable-theme) #'ignore)
              ((symbol-function 'gdev-ui--refine-faces) #'ignore)
              ((symbol-function 'gdev-ui--appearance-cache)
               (lambda () (make-temp-file "gdev-aspetto-"))))
      (gdev-ui-apply-appearance 'dark)
      (should (equal (alist-get 'background-color default-frame-alist) "#1e1e20"))
      (when gdev-macos-p
        (should (eq (alist-get 'ns-appearance default-frame-alist) 'dark)))
      (gdev-ui-apply-appearance 'light)
      (should (equal (alist-get 'background-color default-frame-alist) "#ffffff"))
      (should (= 1 (seq-count (lambda (entry) (eq (car entry) 'background-color))
                              default-frame-alist))))))

(ert-deftest gdev-test-child-frames-get-no-close-button ()
  "Un popup a finestra figlia, come quello del completamento, non riceve la ×."
  (cl-letf (((symbol-function 'frame-parent) (lambda (_frame) 'principale))
            ((symbol-function 'window-list)
             (lambda (&rest _) (ert-fail "Le finestre di un frame figlio non si toccano"))))
    (gdev-layout--update-close-buttons (selected-frame))))

(ert-deftest gdev-test-outline-keeps-following-after-a-mode-change ()
  "La Struttura continua a seguire il documento dopo `kill-all-local-variables'."
  (require 'gdev-outline)
  (with-temp-buffer
    (add-hook 'after-change-functions #'gdev-outline--source-changed nil t)
    (add-hook 'post-command-hook #'gdev-outline--source-command nil t)
    (setq-local gdev-outline--subscribers (list (current-buffer)))
    (kill-all-local-variables)
    (should (memq #'gdev-outline--source-changed after-change-functions))
    (should (memq #'gdev-outline--source-command post-command-hook))
    (should (equal gdev-outline--subscribers (list (current-buffer))))))

(ert-deftest gdev-test-sidebar-refreshes-folders-outside-a-repository ()
  "Senza un repository Git l'albero controlla comunque le cartelle cambiate."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :ui 'sidebar ".el") nil t t))
  (let ((directory (make-temp-file "gdev-sidebar-" t))
        (buffer (generate-new-buffer " *gdev-sidebar-prova*"))
        checked)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local gdev-sidebar--root (file-name-as-directory directory)
                        gdev-sidebar--repo nil))
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (cl-letf (((symbol-function 'gdev-sidebar--refresh-git-tree)
                       (lambda (_redraw) (setq checked t)))
                      ((symbol-function 'gdev-sidebar--read-git) #'ignore))
              (gdev-sidebar--refresh-visible)))
          (should checked))
      (kill-buffer buffer)
      (delete-directory directory t))))

(ert-deftest gdev-test-lavorazioni-q-returns-to-the-editor ()
  "In Lavorazioni `q' riporta all'editor come le altre attività, senza chiudere la colonna."
  (should (eq (keymap-lookup gdev-lavorazioni-mode-map "q") 'gdev-quit-view)))

(ert-deftest gdev-test-dependency-edits-keep-non-ascii-text ()
  "La dichiarazione JSON modificata conserva i caratteri non ASCII."
  (should (equal (gdev-json-text "caffè") "\"caffè\""))
  (should (multibyte-string-p (gdev-json-text "caffè"))))

(ert-deftest gdev-test-search-filters-split-on-commas-outside-braces ()
  "Ogni virgola separa i filtri, tranne quelle dentro le graffe di un'alternativa."
  (should (equal (gdev-search--split-globs "node_modules,dist") '("node_modules" "dist")))
  (should (equal (gdev-search--split-globs "*.{c,h}, build") '("*.{c,h}" "build")))
  (should (equal (gdev-search--split-globs " , ") nil))
  (should (equal (gdev-search--globs "a,b" t) '("--glob" "!a" "--glob" "!b"))))

(ert-deftest gdev-test-workspace-name-uses-the-interface-name-of-scratch ()
  "Lo spazio con gli Appunti si chiama «Appunti», non «*scratch*»."
  (save-window-excursion
    (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
    (should (equal (gdev-layout-tab-name) (gdev-ui-buffer-name (get-buffer "*scratch*"))))
    (should-not (string-prefix-p "*" (gdev-layout-tab-name)))))

(ert-deftest gdev-test-views-keep-unselected-windows-after-a-redraw ()
  "Una vista ridisegnata da un gancio non riporta in cima le finestre non selezionate."
  (let ((buffer (generate-new-buffer " *gdev-ridisegno*"))
        (text (mapconcat #'number-to-string (number-sequence 1 100) "\n")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((other (split-window)))
            (with-current-buffer buffer (insert text))
            (set-window-buffer other buffer)
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 24)
              (let ((place (point)))
                (set-window-point other place)
                (set-window-start other (save-excursion
                                          (goto-char (point-min))
                                          (forward-line 19)
                                          (point))
                                  t)
                (let ((starts (gdev-ui-window-starts))
                      (inhibit-read-only t))
                  (erase-buffer)
                  (insert text)
                  (goto-char place)
                  (gdev-ui-restore-windows starts)
                  (should (= (window-point other) place))
                  (should (= (line-number-at-pos (window-start other)) 20)))))))
      (kill-buffer buffer))))

(ert-deftest gdev-test-sidebar-limits-the-rows-of-huge-folders ()
  "Una cartella enorme mostra un numero limitato di voci e dichiara quante restano fuori."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :ui 'sidebar ".el") nil t t))
  (let ((shown 0)
        (files (cl-loop for index from 1 to (+ gdev-sidebar--render-limit 5)
                        collect (format "/tmp/enorme/file-%d.txt" index))))
    (with-temp-buffer
      (setq-local gdev-sidebar--roots nil)
      (cl-letf (((symbol-function 'gdev-sidebar--children) (lambda (_directory) (list nil files)))
                ((symbol-function 'gdev-sidebar--insert-entry)
                 (lambda (&rest _) (cl-incf shown) (insert "voce\n"))))
        (gdev-sidebar--insert-children "/tmp/enorme/" 0 40 nil nil))
      (should (= shown gdev-sidebar--render-limit))
      (should (string-search "… altre 5 voci non mostrate" (buffer-string))))
    ;; Sotto il limite non compare alcuna nota.
    (setq shown 0)
    (with-temp-buffer
      (setq-local gdev-sidebar--roots nil)
      (cl-letf (((symbol-function 'gdev-sidebar--children)
                 (lambda (_directory) (list nil '("/tmp/a" "/tmp/b"))))
                ((symbol-function 'gdev-sidebar--insert-entry)
                 (lambda (&rest _) (cl-incf shown) (insert "voce\n"))))
        (gdev-sidebar--insert-children "/tmp/" 0 40 nil nil))
      (should (= shown 2))
      (should-not (string-search "non mostrate" (buffer-string))))))

(ert-deftest gdev-test-sidebar-fits-file-names-without-an-extension ()
  "Un nome senza estensione che non entra si accorcia, non diventa una riga vuota."
  (let ((use-package-ensure-function #'ignore))
    (load (gdev-module-file :ui 'sidebar ".el") nil t t))
  (dolist (name '("LICENSEFILE-MOLTO-LUNGO" ".gitignore-molto-lungo" "Makefile.in.molto.lungo.txt"))
    (let ((label (gdev-sidebar--fit-label name 'default 8 t #'string-width)))
      (should (> (length label) 1))
      (should (<= (string-width label) 8))
      (should (string-search "…" label))))
  ;; Un nome che entra resta com'è.
  (should (equal (substring-no-properties (gdev-sidebar--fit-label "README" 'default 20 t #'string-width))
                 "README")))

;;; gdev-ui-fixes-test.el ends here
