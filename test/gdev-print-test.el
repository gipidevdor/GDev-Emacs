;;; gdev-print-test.el --- Prove della stampa a colori -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La stampa conserva colori e stili delle facce del testo, li adatta alla
;; carta bianca e lascia fuori gli evidenziatori temporanei.

;;; Code:

(require 'ert)
(require 'gdev-print)

(defmacro gdev-test-print--with-text (&rest body)
  "Esegui BODY in un buffer con testo colorato da facce anonime."
  (declare (indent 0))
  `(with-temp-buffer
     (insert "uno "
             (propertize "rosso" 'face '(:foreground "#ff0000" :weight bold))
             " due "
             (propertize "scuro" 'face '(:foreground "#f0f0f0" :background "#202020"))
             " "
             (propertize "tre" 'face '((:slant italic) (:underline t) (:foreground "#00aa00")))
             "\n")
     ,@body))

(ert-deftest gdev-test-print-runs-keep-colors-and-styles ()
  "I tratti coprono tutto il testo e ne conservano colori e stili."
  (gdev-test-print--with-text
    (let ((runs (gdev-print-runs)))
      (should (equal (apply #'concat (mapcar #'car runs)) (buffer-string)))
      (should (equal (mapcar #'car runs) '("uno " "rosso" " due " "scuro" " " "tre" "\n")))
      ;; Il testo senza faccia usa l'inchiostro e la carta.
      (should (equal (cdr (nth 0 runs)) '(nil nil 0)))
      (pcase-let ((`(,_ ,red ,background ,style) (nth 1 runs)))
        (should (string-prefix-p "#" red))
        (should-not background)
        (should (= style 1)))
      ;; Corsivo e sottolineatura da facce diverse della stessa lista.
      (should (= (nth 3 (nth 5 runs)) (+ 2 4))))))

(ert-deftest gdev-test-print-colors-are-readable-on-paper ()
  "I colori dello schermo diventano leggibili sulla carta bianca."
  (gdev-test-print--with-text
    (dolist (run (gdev-print-runs))
      (pcase-let ((`(,_ ,foreground ,background ,_) run))
        (when foreground
          (should (>= (gdev-print--contrast
                       (gdev-print--rgb foreground)
                       (if background (gdev-print--rgb background) gdev-print--paper))
                      gdev-print-minimum-contrast)))
        ;; Lo sfondo scuro del tema scuro diventa una tinta chiara.
        (when background
          (should (>= (gdev-print--luminance (gdev-print--rgb background)) 0.3)))))
    ;; Il rosso puro scurisce senza cambiare tinta.
    (let ((red (gdev-print--rgb (nth 1 (nth 1 (gdev-print-runs))))))
      (should (> (nth 0 red) (* 3 (nth 1 red))))
      (should (< (nth 0 red) 1.0)))
    ;; Un colore già leggibile resta quello dell'editor.
    (should (equal (gdev-print--hex (gdev-print--ink (gdev-print--rgb "#1c00cf") gdev-print--paper))
                   "#1c00cf"))))

(ert-deftest gdev-test-print-ignores-highlights ()
  "Riga corrente, selezione e altri overlay non finiscono sulla carta."
  (gdev-test-print--with-text
    (let ((before (gdev-print-runs))
          (overlay (make-overlay (point-min) (point-max))))
      (overlay-put overlay 'face '(:background "#ffff00"))
      (should (equal (gdev-print-runs) before)))))

(ert-deftest gdev-test-print-payload-carries-the-runs ()
  "Il dialogo riceve testo, carattere, tabulazioni e colori in JSON."
  (gdev-test-print--with-text
    (setq-local tab-width 4)
    (let ((document (json-parse-string (decode-coding-string (gdev-print--payload) 'utf-8)
                                       :object-type 'alist :null-object nil)))
      (should (= (alist-get 'tab document) 4))
      (should (equal (apply #'concat (mapcar (lambda (run) (aref run 0)) (alist-get 'runs document)))
                     (buffer-string)))
      (should (equal (aref (alist-get 'runs document) 0) ["uno " nil nil 0]))))
  (with-temp-buffer
    (set-buffer-multibyte t)
    (insert "testo " (string #x3fff80))
    (should-error (gdev-print--payload) :type 'user-error)))

(ert-deftest gdev-test-print-document-uses-the-native-dialog ()
  "Su macOS il menu Stampa passa per il dialogo con i colori."
  (let ((system-type 'darwin)
        printed)
    (with-temp-buffer
      (insert "testo")
      (narrow-to-region 1 2)
      (cl-letf (((symbol-function 'gdev-editor-document) (lambda () (current-buffer)))
                ((symbol-function 'gdev-print-macos)
                 (lambda () (setq printed (buffer-substring-no-properties (point-min) (point-max))))))
        (gdev-print-document)))
    ;; Il documento si stampa intero anche se è ristretto a una parte.
    (should (equal printed "testo"))))

(ert-deftest gdev-test-print-macos-hands-the-document-over-in-a-file ()
  "Il documento arriva a Swift in un file privato e non nella pipe del processo."
  (let (command)
    (gdev-test-print--with-text
      (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 0))
                ((symbol-function 'make-process)
                 (lambda (&rest arguments)
                   (setq command (plist-get arguments :command))
                   ;; Senza processo, `process-send-string' darebbe errore.
                   nil)))
        (gdev-print-macos)))
    (let ((file (nth 4 command)))
      (unwind-protect
          (progn
            (should (file-regular-p file))
            (should (equal (file-modes file) #o600))
            (let ((text (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally file)
                          (buffer-string))))
              (should (string-search "\"runs\"" text))
              (should (string-search "rosso" text))))
        (ignore-errors (delete-file file))))))

(ert-deftest gdev-test-print-leaves-out-hidden-text ()
  "Il testo nascosto da proprietà o da overlay non esce sulla carta."
  (with-temp-buffer
    (insert "visibile " (propertize "[[nascosto]]" 'invisible t) " ancora "
            "piegato" " fine")
    ;; Un blocco ripiegato con un overlay, come fanno outline e hideshow.
    (let ((overlay (make-overlay (- (point-max) 10) (- (point-max) 5))))
      (overlay-put overlay 'invisible t))
    (let ((text (apply #'concat (mapcar #'car (gdev-print-runs)))))
      (should-not (string-search "nascosto" text))
      (should (string-search "visibile " text))
      (should (string-search " fine" text))
      (should-not (string-search "[[" text))))
  ;; Gli stati visibili con lo stesso stile restano un solo tratto.
  (with-temp-buffer
    (insert "uno " (propertize "due" 'invisible t) "tre")
    (should (equal (mapcar #'car (gdev-print-runs)) '("uno tre")))))

;;; gdev-print-test.el ends here
