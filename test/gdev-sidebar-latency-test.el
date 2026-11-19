;;; gdev-sidebar-latency-test.el --- Regressioni di Esplora file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la misura delle etichette e le letture differite delle cartelle.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-modules)

(ert-deftest gdev-sidebar-latency-test-measures-fitting-file-once ()
  "Un nome che entra per intero richiede una sola misura."
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (let (measured)
    (let ((label (gdev-sidebar--fit-label
                  "documento.txt" 'gdev-sidebar-filename 22 t
                  (lambda (text) (push text measured) (string-width text)))))
      (should (equal label "documento.txt"))
      (should (eq (get-text-property 0 'face label) 'gdev-sidebar-filename))
      (should (equal measured '("documento.txt"))))))

(ert-deftest gdev-sidebar-latency-test-checks-directory-metadata-in-batches ()
  "Una verifica sostitutiva scarta la chiamata vecchia e mantiene il ridisegno."
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (with-temp-buffer
    (gdev-sidebar-mode)
    (setq gdev-sidebar--root "/progetto/")
    (dotimes (i 150)
      (puthash (format "/progetto/cartella-%d/" i) '(nil nil) gdev-sidebar--directory-cache))
    (let ((checks 0) (redraws 0) callbacks cancels)
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100.0))
                ((symbol-function 'file-attributes) (lambda (&rest _) (cl-incf checks) nil))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat callback) (push callback callbacks) callback))
                ((symbol-function 'cancel-timer) (lambda (callback) (push callback cancels)))
                ((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
                ((symbol-function 'gdev-sidebar--render) (lambda (&rest _) (cl-incf redraws))))
        (gdev-sidebar--refresh-git-tree t)
        (should (= checks 128))
        (should (= redraws 0))
        (let ((previous (car callbacks)))
          (gdev-sidebar--refresh-git-tree nil)
          (should (equal cancels (list previous)))
          (should (= checks 256))
          (funcall previous)
          (should (= checks 256)))
        (funcall (car callbacks))
        (should (= checks (+ 128 150)))
        (should (= redraws 1))
        (should-not gdev-sidebar--directory-check-timer)))))

(ert-deftest gdev-sidebar-latency-test-refreshes-directories-with-unchanged-git ()
  "Una risposta Git identica conserva le righe e rileva le nuove voci ignorate."
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (with-temp-buffer
    (gdev-sidebar-mode)
    (let* ((directory (make-temp-file "gdev-sidebar-latency-" t))
           (root (file-name-as-directory directory))
           (ignored (expand-file-name "cache/" root))
           (git-status "!! cache/\0")
           refreshes)
      (unwind-protect
          (progn
            (setq gdev-sidebar--root root
                  gdev-sidebar--repo root
                  gdev-sidebar--last-output git-status)
            (make-directory ignored)
            (gdev-sidebar--read-directory ignored)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) (selected-window)))
                      ((symbol-function 'gdev-sidebar--render)
                       (lambda (&rest _) (ert-fail "Ridisegno senza cambiamenti")))
                      ((symbol-function 'gdev-sidebar--refresh-directories)
                       (lambda (directories) (setq refreshes directories))))
              (gdev-sidebar--apply-git-status git-status)
              (should-not refreshes)
              (with-temp-file (expand-file-name "nuovo.txt" ignored))
              ;; Rende il confronto deterministico anche sui volumi con risoluzione al secondo.
              (puthash ignored 0 gdev-sidebar--directory-times)
              (gdev-sidebar--apply-git-status git-status)
              (should (equal refreshes (list ignored)))))
        (delete-directory directory t)))))

(ert-deftest gdev-sidebar-latency-test-loads-large-folders-and-reveals-document ()
  "La lettura a freddo restituisce subito il riquadro e poi rivela il documento."
  (skip-unless (executable-find "perl"))
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (save-window-excursion
    (let* ((root (file-name-as-directory
                  (file-truename (make-temp-file "gdev-sidebar-cold-" t))))
           (folder (expand-file-name "sorgenti" root))
           (document (expand-file-name "documento-lungo.txt" folder))
           (hidden (expand-file-name ".impostazioni" folder))
           (with-newline (expand-file-name "file\nspeciale.txt" folder))
           (added (expand-file-name "nuovo-in-corsa" root))
           (old-buffer (frame-parameter nil 'gdev-sidebar-buffer))
           (editor (selected-window))
           (gdev-layout-mode nil)
           (gdev-sidebar--directory-read-limit 3)
           (gdev-sidebar--timer 'disabled)
           (noninteractive nil)
           sidebar buffer)
      (unwind-protect
          (progn
            (make-directory folder)
            (make-directory (expand-file-name ".git" folder))
            (dolist (file (list hidden with-newline document (expand-file-name ".DS_Store" folder)
                                (expand-file-name "uno" root) (expand-file-name "due" root)
                                (expand-file-name "tre" root) (expand-file-name "quattro" root)))
              (with-temp-file file))
            (cl-letf (((symbol-function 'gdev-sidebar--editor-file) (lambda (&rest _) document)))
              (setq sidebar (gdev-sidebar-show root t)
                    buffer (window-buffer sidebar)))
            (should (eq editor (selected-window)))
            (with-current-buffer buffer
              (should (processp gdev-sidebar--directory-process))
              (should-not (gdev-sidebar--path-position document))
              (should (string-match-p "Lettura" (buffer-string)))
              (let ((deadline (+ (float-time) 5))
                    (cache (symbol-function 'gdev-sidebar--cache-scanned-directories))
                    first-delivery)
                (cl-letf (((symbol-function 'gdev-sidebar--cache-scanned-directories)
                           (lambda (records)
                             (unless first-delivery
                               (setq first-delivery t)
                               (with-temp-file added)
                               (set-file-times root (time-add (current-time) 4)))
                             (funcall cache records))))
                  (while (and gdev-sidebar--directory-process (< (float-time) deadline))
                    (accept-process-output nil 0.03))))
              (should-not gdev-sidebar--directory-process)
              (should-not (string-match-p "Lettura" (buffer-string)))
              (should (gdev-sidebar--path-position hidden))
              (should (gdev-sidebar--path-position with-newline))
              (should (gdev-sidebar--path-position added))
              (should-not (gdev-sidebar--path-position (expand-file-name ".git" folder)))
              (should-not (gdev-sidebar--path-position (expand-file-name ".DS_Store" folder)))
              (should (equal (window-point sidebar) (gdev-sidebar--path-position document)))
              (should (equal (overlay-get gdev-sidebar--current-marker 'display) "▏")))
            (should (eq editor (selected-window))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-frame-parameter nil 'gdev-sidebar-buffer old-buffer)
        (delete-directory root t)))))

(ert-deftest gdev-sidebar-latency-test-discards-cold-scan-on-root-change ()
  "Un risultato obsoleto non ripristina il ramo della radice precedente."
  (skip-unless (executable-find "perl"))
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (save-window-excursion
    (let* ((directory (file-truename (make-temp-file "gdev-sidebar-root-switch-" t)))
           (root (expand-file-name "prima/" directory))
           (other-root (expand-file-name "seconda/" directory))
           (old-path (expand-file-name "vecchio" root))
           (new-path (expand-file-name "nuovo" other-root))
           (old-buffer (frame-parameter nil 'gdev-sidebar-buffer))
           (gdev-layout-mode nil)
           (gdev-sidebar--directory-read-limit 1)
           (gdev-sidebar--timer 'disabled)
           (noninteractive nil)
           buffer old-process)
      (unwind-protect
          (progn
            (make-directory root)
            (make-directory other-root)
            (dolist (file (list old-path (expand-file-name "altro" root) new-path))
              (with-temp-file file))
            (cl-letf (((symbol-function 'gdev-sidebar--editor-file) #'ignore))
              (setq buffer (window-buffer (gdev-sidebar-show root t))
                    old-process (buffer-local-value 'gdev-sidebar--directory-process buffer))
              (should (processp old-process))
              (should (eq buffer (window-buffer (gdev-sidebar-show other-root t)))))
            (gdev-sidebar--apply-directory-scan old-process buffer)
            (with-current-buffer buffer
              (should-not gdev-sidebar--directory-process)
              (should-not gdev-sidebar--directory-paths)
              (should-not (gdev-sidebar--path-position old-path))
              (should (gdev-sidebar--path-position new-path))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-frame-parameter nil 'gdev-sidebar-buffer old-buffer)
        (delete-directory directory t)))))

(ert-deftest gdev-sidebar-latency-test-recovers-if-creating-cold-worker-fails ()
  "Se il sottoprocesso non parte la vista mostra comunque i file reali."
  (skip-unless (executable-find "perl"))
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (save-window-excursion
    (let* ((root (file-name-as-directory
                  (file-truename (make-temp-file "gdev-sidebar-fallback-" t))))
           (first (expand-file-name "primo" root))
           (second (expand-file-name "secondo" root))
           (old-buffer (frame-parameter nil 'gdev-sidebar-buffer))
           (gdev-layout-mode nil)
           (gdev-sidebar--directory-read-limit 1)
           (gdev-sidebar--timer 'disabled)
           (noninteractive nil)
           buffer)
      (unwind-protect
          (progn
            (with-temp-file first)
            (with-temp-file second)
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) (signal 'file-error '("Non disponibile"))))
                      ((symbol-function 'gdev-sidebar--editor-file) (lambda (&rest _) second)))
              (setq buffer (window-buffer (gdev-sidebar-show root t))))
            (with-current-buffer buffer
              (should-not gdev-sidebar--directory-process)
              (should-not gdev-sidebar--directory-paths)
              (should (gdev-sidebar--path-position first))
              (should (gdev-sidebar--path-position second))
              (should-not (string-match-p "Lettura" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-frame-parameter nil 'gdev-sidebar-buffer old-buffer)
        (delete-directory root t)))))

(ert-deftest gdev-sidebar-latency-test-merges-git-deletions-in-directory-order ()
  "Le voci eliminate restano uniche, ordinate e separate dalla cache reale."
  (load (gdev-module-file :ui 'sidebar ".el") nil t t)
  (with-temp-buffer
    (gdev-sidebar-mode)
    (let* ((root "/prova/")
           (folder (concat root "200-reale"))
           (deleted-folder (concat root "100-assente"))
           (paths (mapcar (lambda (index) (format "file-%02d.txt" index)) (number-sequence 0 39)))
           (recreated (concat root (nth 4 paths)))
           (keep (concat root "sano.txt"))
           (cached (list (list folder) (list recreated keep)))
           (porcelain (mapconcat #'identity
                                (append (mapcar (lambda (name) (concat " D " name)) (reverse paths))
                                        '(" D 100-assente/b" " D 100-assente/a" "R  nuovo" "100-assente/a"))
                                "\0"))
           (gdev-sidebar--removed (cdr (gdev-sidebar--git-index porcelain root root))))
      (puthash root cached gdev-sidebar--directory-cache)
      (puthash (file-name-as-directory deleted-folder) (list nil nil) gdev-sidebar--directory-cache)
      (should (equal (gdev-sidebar--children root)
                     (list (list deleted-folder folder)
                           (append (mapcar (lambda (name) (concat root name)) paths) (list keep)))))
      (should (equal (gdev-sidebar--children (file-name-as-directory deleted-folder))
                     (list nil (list (concat deleted-folder "/a") (concat deleted-folder "/b")))))
      (should (eq (gethash root gdev-sidebar--directory-cache) cached))
      (should (equal cached (list (list folder) (list recreated keep)))))))

(provide 'gdev-sidebar-latency-test)
;;; gdev-sidebar-latency-test.el ends here
