;;; gdev-minimap-indicators-test.el --- Verifica i marcatori della minimappa -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Proiezione dei risultati pubblicati, ridisegno e salto nell'editor.

;;; Code:

(require 'ert)
(require 'flymake)
(require 'gdev-minimap)
(require 'gdev-search)

(ert-deftest gdev-test-minimap-ordered-binning-avoids-per-mark-search ()
  "Lotti monotoni in entrambi i versi usano una scansione, senza ricerche singole."
  (let ((gdev-minimap--rows (vconcat (number-sequence 1 8192 32)))
        (marks (cl-loop for position from 0 below 8192 collect (cons position 'search))))
    (cl-letf (((symbol-function 'gdev-minimap--row)
               (lambda (&rest _) (ert-fail "Ricerca binaria ripetuta su dati ordinati"))))
      (let ((ascending (gdev-minimap--buckets marks))
            (descending (gdev-minimap--buckets (reverse marks))))
        (should (equal ascending descending))
        (should (= 8192 (cl-loop for bucket across ascending sum (nth 2 bucket))))
        (should (equal marks (cl-loop for position from 0 below 8192 collect (cons position 'search))))))))

(ert-deftest gdev-test-minimap-binning-preserves-salience-under-permutations ()
  "Ordine e densità non nascondono errori, conteggi o destinazioni esatte."
  (let* ((gdev-minimap--rows [1 100 200])
         (marks '((0 . search) (10 . :error) (27 . :warning) (66 . :note) (87 . :error)
                  (100 . :warning) (199 . :note) (200 . search) (209 . :error) (1000 . :error)))
         (expected [(10 :error 5) (100 :warning 2) (209 :error 3)]))
    (dolist (ordered (list marks (reverse marks)
                          (append (seq-drop marks 4) (seq-take marks 4))
                          (append (cl-loop for mark in marks for index from 0 when (cl-oddp index) collect mark)
                                  (cl-loop for mark in marks for index from 0 when (cl-evenp index) collect mark))))
      (should (equal expected (gdev-minimap--buckets ordered))))))

(ert-deftest gdev-test-minimap-empty-bins-and-boundaries-are-safe ()
  "Senza righe non si indicizza il vettore; estremi e righe vuote restano coerenti."
  (let ((gdev-minimap--rows []))
    (should (equal [] (gdev-minimap--buckets '((1 . search))))))
  (let ((gdev-minimap--rows [1 100 200]))
    (should (equal [nil nil nil] (gdev-minimap--buckets nil)))
    (should (equal [(0 search 1) (100 search 1) (200 search 1)]
                   (gdev-minimap--buckets '((0 . search) (100 . search) (200 . search)))))))

(ert-deftest gdev-test-minimap-mark-contrast-follows-both-appearances ()
  "I marcatori restano leggibili anche nella zona evidenziata."
  (cl-progv '(modus-operandi-palette-overrides modus-vivendi-palette-overrides
              modus-themes-italic-constructs modus-themes-bold-constructs
              modus-themes-mixed-fonts modus-themes-prompts modus-themes-completions
              modus-themes-common-palette-overrides)
      nil
    (gdev-ui--configure-modus)
    (dolist (appearance '(light dark))
      (cl-flet ((color (face attribute)
                  (or (gdev-ui-test--face-color face attribute appearance)
                      (plist-get (cdr (assq t (get face 'face-defface-spec))) attribute))))
        (let* ((palette (if (eq appearance 'light) modus-operandi-palette-overrides
                          modus-vivendi-palette-overrides))
               (surfaces (list (cadr (assq 'bg-main palette)) (color 'gdev-minimap-viewport :background))))
          (dolist (glyph gdev-minimap--glyphs)
            (let ((a (gdev-ui-test--luminance (color (nth 2 glyph) :foreground))))
              (dolist (surface surfaces)
                (let ((b (gdev-ui-test--luminance surface)))
                  (ert-info ((format "%s, %s su %s" appearance (car glyph) surface))
                    (should (>= (/ (+ (max a b) 0.05) (+ (min a b) 0.05)) 4.5))))))))))))

(ert-deftest gdev-test-minimap-groups-indicators-by-section-and-severity ()
  "Ogni corsia conserva la prima posizione utile, con precedenza agli errori."
  (let ((gdev-minimap--rows [1 100 200]))
    (should (equal (gdev-minimap--buckets '((66 . :note) (27 . :warning) (87 . :error)
                                           (10 . :error) (121 . :warning) (209 . :note)))
                   [(10 :error 4) (121 :warning 1) (209 :note 1)]))))

(ert-deftest gdev-test-minimap-redraws-published-marks-without-rereading-on-scroll ()
  "Il clic usa la posizione esatta del marcatore e i dati seguono lo spazio."
  (gdev-test--with-layout
    (let* ((frame (selected-frame))
           (previous (frame-parameter frame 'gdev-minimap-buffer))
           (first (generate-new-buffer " *Sorgente dei marcatori*"))
           (search (generate-new-buffer " *Risultati dei marcatori*"))
           (other (generate-new-buffer " *Altri risultati*"))
           (file "/progetto/dimostrazione.el")
           (hits (list (make-gdev-search-hit :file file :line 2 :ranges '((4 . 8)) :source "abc prova")
                       (make-gdev-search-hit :file file :line 3 :ranges '((0 . 4)) :source "vecchio")))
           (calls 0)
           mirror)
      (unwind-protect
          (progn
            (set-frame-parameter frame 'gdev-minimap-buffer nil)
            (let* ((editor (gdev-layout-editor))
                   (second (with-current-buffer first
                             (insert "prima\nabc prova\nrecente\n")
                             (gdev-layout-mark-document)
                             (setq-local buffer-file-name file flymake-mode t)
                             (set-buffer-modified-p nil)
                             (line-beginning-position -1)))
                   (target (+ second 4))
                   (problem (+ second 1))
                   (diagnostic (flymake-make-diagnostic first problem (1+ problem) :warning "Avviso"))
                   (original (symbol-function 'flymake-diagnostics)))
              (set-window-buffer editor first)
              (with-current-buffer first
                (let ((overlay (make-overlay problem (1+ problem))))
                  (setf (flymake--diag-overlay diagnostic) overlay)
                  (overlay-put overlay 'flymake-diagnostic diagnostic)))
              (gdev-workspace-state-set 'gdev-activity-buffers `((search . ,search)))
              (with-current-buffer search (gdev-search--set-results hits))
              (gdev-workspace-state-set 'gdev-layout-minimap-visible t)
              (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                        ((symbol-function 'flymake-diagnostics)
                         (lambda (&rest args) (cl-incf calls) (apply original args)))
                        ((symbol-function 'make-process)
                         (lambda (&rest _) (ert-fail "La minimappa ha avviato una ricerca"))))
                (gdev-minimap--sync frame)
                (let ((side (window-with-parameter 'gdev-minimap t frame))
                      row)
                  (should (window-live-p side))
                  (setq mirror (window-buffer side))
                  (with-current-buffer mirror
                    (setq row (text-property-any (point-min) (point-max) 'gdev-minimap-target target))
                    (should row)
                    (should (equal (get-text-property row 'display) "+"))
                    (should (equal (get-text-property (+ row 2) 'display) "!"))
                    (should (equal (get-text-property row 'help-echo) "Risultato di ricerca"))
                    (should (equal (get-text-property (+ row 2) 'help-echo) "Avviso"))
                    (should (equal (get-text-property (+ row 2) 'gdev-minimap-target) problem))
                    (should-not (text-property-any (point-min) (point-max) 'gdev-minimap-target
                                                   (+ second (length "abc prova\n")))))
                  (select-window side)
                  (gdev-minimap-jump (list 'mouse-1 (list side row '(0 . 0) 0)))
                  (should (eq (selected-window) editor))
                  (should (eq (current-buffer) first))
                  (should (= (point) target))
                  (gdev-minimap--render side editor)
                  (gdev-minimap--render side editor)
                  (should (= calls 1))
                  (gdev-workspace-state-set 'gdev-activity-buffers `((search . ,other)))
                  (gdev-minimap--render side editor)
                  (with-current-buffer mirror
                    (should-not (text-property-any (point-min) (point-max) 'gdev-minimap-target target))
                    (should (text-property-any (point-min) (point-max) 'gdev-minimap-target problem)))
                  (should (= calls 1))
                  (gdev-workspace-state-set 'gdev-activity-buffers `((search . ,search)))
                  (with-current-buffer first (goto-char (point-min)) (insert "Riga nuova\n"))
                  (gdev-minimap--render side editor)
                  (with-current-buffer mirror
                    (should-not (text-property-any (point-min) (point-max) 'gdev-minimap-target target))
                    (should (text-property-any (point-min) (point-max) 'gdev-minimap-target
                                               (+ problem (length "Riga nuova\n")))))
                  (should (= calls 2))))))
        (when (timerp (frame-parameter frame 'gdev-minimap-update))
          (cancel-timer (frame-parameter frame 'gdev-minimap-update))
          (set-frame-parameter frame 'gdev-minimap-update nil))
        (set-frame-parameter frame 'gdev-minimap-buffer previous)
        (dolist (buffer (list first search other mirror))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(ert-deftest gdev-test-minimap-index-invalidates-only-on-published-search-results ()
  "L'indice è pigro, resta stabile e viene scartato per una nuova ricerca."
  (gdev-test--with-layout
    (let ((search (generate-new-buffer " *Indice di Cerca*"))
          (file "/progetto/documento.el")
          (updates 0))
      (unwind-protect
          (progn
            (gdev-workspace-state-set 'gdev-activity-buffers `((search . ,search)))
            (with-current-buffer search
              (let ((gdev-search-results-change-hook (list (lambda () (cl-incf updates))))
                    (hit (make-gdev-search-hit :file file :line 10)))
                (gdev-search--set-results (list hit))
                (should-not gdev-search--results-by-file)
                (let ((hits (gdev-search-document-hits (selected-frame) "/alias/documento.el" file)))
                  (should (eq (car hits) hit))
                  (should (eq hits (gdev-search-document-hits (selected-frame) file)))
                  (gdev-search--set-results gdev-search--results)
                  (should (= updates 1)))
                (gdev-search--set-results nil)
                (should (= updates 2))
                (should-not gdev-search--results-by-file)
                (should-not (gdev-search-document-hits (selected-frame) file)))))
        (kill-buffer search)))))

(provide 'gdev-minimap-indicators-test)
;;; gdev-minimap-indicators-test.el ends here
