;;; gdev-pdf-test.el --- Verifiche del lettore PDF di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Copre l'attivazione locale, la navigazione per finestra, la ricerca
;; paginata, la cache e l'invalidazione dei risultati asincroni.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gdev-modules)

(defun gdev-test--load-pdf ()
  "Carica il modulo PDF e il relativo fork quando serve al test."
  (unless (fboundp 'gdev-pdf-visit)
    (load (gdev-module-file :tools 'pdf ".el") nil t t))
  (require 'gdev-pdf (expand-file-name "gdev-pdf" (gdev-module-directory :tools 'pdf))))

(ert-deftest gdev-test-pdf-local-fork-and-paginated-search ()
  (gdev-test--load-pdf)
  (should (file-equal-p (file-name-directory (locate-library "gdev-doc-view"))
                        (gdev-bundled-package-directory 'gdev-doc-view)))
  (with-temp-buffer
    (insert "Intro\fUn Richiamo\nUn RICHIAMO\f\frichiamo")
    (let ((before (point)))
      (should (equal (gdev-doc-view-search-pages "richiamo" (current-buffer)) '(2 4)))
      (should (equal (gdev-doc-view-search-pages "\\`\\'" (current-buffer)) '(3)))
      (should-not (gdev-doc-view-search-pages "INTRO.*Un Richiamo" (current-buffer)))
      (should (= (point) before)))))

(ert-deftest gdev-test-pdf-page-selection-follows-the-window ()
  (gdev-test--load-pdf)
  (save-window-excursion
    (with-temp-buffer
      (insert "%PDF-1.7\n")
      (gdev-doc-view-mode)
      (let* ((first (selected-window))
             (second (split-window-below)))
        (set-window-buffer first (current-buffer))
        (set-window-buffer second (current-buffer))
        (setq gdev-doc-view-page-count 7)
        (gdev-doc-view-goto-page 3)
        (should-error (gdev-doc-view-goto-page 3.2) :type 'user-error)
        (with-selected-window second
          (gdev-doc-view-goto-page 200)
          (should (= (gdev-doc-view-current-page) 7))
          (gdev-doc-view-goto-page 0)
          (should (= (gdev-doc-view-current-page) 1)))
        (should (= (gdev-doc-view-current-page first) 3))
        (should (equal (buffer-string) "%PDF-1.7\n"))
        (should buffer-read-only)))))

(ert-deftest gdev-test-pdf-rejects-an-old-process-result ()
  (gdev-test--load-pdf)
  (with-temp-buffer
    (let* ((output (generate-new-buffer " *gdev-test-pdf-output*"))
           (errors (generate-new-buffer " *gdev-test-pdf-errors*"))
           (active (list nil))
           (old (list nil))
           (callback (lambda (&rest _) (ert-fail "Risultato superato consegnato"))))
      (setq-local gdev-pdf--render-job active)
      (gdev-pdf--complete (current-buffer) 'gdev-pdf--render-job old 0 output errors
                          callback callback)
      (should (eq gdev-pdf--render-job active))
      (should-not (buffer-live-p output))
      (should-not (buffer-live-p errors)))))

(ert-deftest gdev-test-pdf-cache-retains-visible-pages ()
  (gdev-test--load-pdf)
  (with-temp-buffer
    (let ((directory (make-temp-file "gdev-test-pdf-" t))
          (window (selected-window)))
      (unwind-protect
          (let ((gdev-pdf--directory directory)
                (gdev-pdf--cache-limit 2)
                (gdev-pdf--pages
                 (mapcar (lambda (page)
                           (cons page (make-temp-file (expand-file-name "pagina-" directory))))
                         '(5 4 3 2 1))))
            (cl-letf (((symbol-function 'gdev-pdf--windows) (lambda () (list window)))
                      ((symbol-function 'gdev-doc-view-current-page) (lambda (&optional _) 2)))
              (let ((evicted (alist-get 3 gdev-pdf--pages)))
                (gdev-pdf--trim-cache)
                (should (equal (mapcar #'car gdev-pdf--pages) '(5 4 2)))
                (should-not (file-exists-p evicted)))
              (gdev-pdf--release)
              (should-not (file-exists-p directory))))
        (when (file-directory-p directory) (delete-directory directory t))))))

(provide 'gdev-pdf-test)
;;; gdev-pdf-test.el ends here
