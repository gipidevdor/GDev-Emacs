;;; gdev-profile-report.el --- Risultati delle misurazioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Apre i risultati di hyperfine come documento del progetto.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'seq)
(require 'subr-x)

(defvar-local gdev-profile-report--bars nil
  "Posizioni delle barre e durate relative del rapporto corrente.")

(defvar-local gdev-profile-report--bar-style nil
  "Ultima larghezza e ultimo carattere usati per disegnare le barre.")

(defvar-keymap gdev-profile-report-mode-map
  :parent special-mode-map
  "TAB" #'forward-button
  "<tab>" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-profile-report-mode special-mode "Prestazioni"
  "Mostra i risultati delle misurazioni del progetto."
  (gdev-ui-view-setup 'document)
  (visual-line-mode 1)
  (gdev-layout-mark-document)
  (add-hook 'window-size-change-functions #'gdev-profile-report--resize nil t)
  (add-hook 'window-buffer-change-functions #'gdev-profile-report--resize nil t))

(defun gdev-profile-report--results (data)
  "Estrai e ordina per durata media le misurazioni decodificate da DATA."
  (let (results)
    (dolist (result (alist-get 'results data))
      (let* ((metrics (alist-get 'time_wall_clock (alist-get 'summary result)))
             (row (if metrics (cons (assq 'command result) metrics) result))
             (mean (alist-get 'mean row)))
        (when (and (numberp mean) (<= 0 mean) (stringp (alist-get 'command row)))
          (push row results))))
    (cl-stable-sort (nreverse results) #'< :key (lambda (row) (alist-get 'mean row)))))

(defun gdev-profile-report--duration (seconds)
  "Formatta SECONDS nell'unità adatta e conserva il valore originale."
  (pcase-let ((`(,factor . ,unit)
               (cond ((or (= seconds 0) (>= seconds 1)) '(1 . "s"))
                     ((>= seconds 1e-3) '(1e3 . "ms"))
                     ((>= seconds 1e-6) '(1e6 . "µs"))
                     (t '(1e9 . "ns")))))
    (propertize (format "%.6g %s" (* seconds factor) unit)
                'help-echo (format "%S s" seconds))))

(defun gdev-profile-report--insert-result (result slowest)
  "Inserisci RESULT con una barra proporzionale alla durata SLOWEST."
  (let* ((command (alist-get 'command result))
         (mean (alist-get 'mean result))
         (stddev (alist-get 'stddev result))
         (count (or (alist-get 'count result) (length (alist-get 'times result))))
         details)
    (insert (propertize (replace-regexp-in-string
                         "[[:cntrl:]]"
                         (lambda (control) (text-char-description (aref control 0)))
                         command t t)
                        'face '(gdev-ui-view-heading fixed-pitch) 'help-echo command)
            "\nMedia " (gdev-profile-report--duration mean))
    (when (numberp stddev)
      (insert "  ± " (gdev-profile-report--duration stddev)))
    (insert "\n")
    (push (cons (point) (if (> slowest 0) (/ (float mean) slowest) 0))
          gdev-profile-report--bars)
    (insert "#\n")
    (dolist (field '((median . "Mediana") (min . "Min") (max . "Max")))
      (let ((value (alist-get (car field) result)))
        (when (numberp value)
          (push (concat (cdr field) " " (gdev-profile-report--duration value)) details))))
    (when (> count 0)
      (push (if (= count 1) "1 esecuzione" (format "%d esecuzioni" count)) details))
    (when details
      (insert (propertize (string-join (nreverse details) "  ·  ") 'face 'gdev-ui-secondary)
              "\n"))
    (insert "\n")))

(defun gdev-profile-report--bar-width (window glyph)
  "Misura quante ripetizioni di GLYPH usare nella parte testuale di WINDOW."
  (with-selected-window window
    (if (display-graphic-p)
        (/ (* 3 (window-body-width window t))
           (* 4 (max 1 (string-pixel-width (propertize glyph 'face 'fixed-pitch)))))
      (/ (* 3 (window-body-width window)) 4))))

(defun gdev-profile-report--resize (window)
  "Adegua le barre quando cambia la larghezza di WINDOW."
  (with-current-buffer (window-buffer window)
    (when gdev-profile-report--bars
      (let* ((windows (get-buffer-window-list (current-buffer) nil t))
             (glyph (if (seq-every-p (lambda (visible)
                                       (with-selected-window visible
                                         (and (display-graphic-p) (char-displayable-p ?█))))
                                     windows)
                        "█" "#"))
             (width (max 1 (seq-reduce (lambda (limit visible)
                                         (min limit (gdev-profile-report--bar-width visible glyph)))
                                       windows 48)))
             (style (cons width glyph)))
        (unless (equal style gdev-profile-report--bar-style)
          (setq gdev-profile-report--bar-style style)
          (with-silent-modifications
            (dolist (bar gdev-profile-report--bars)
              (let* ((ratio (cdr bar))
                     (length (if (> ratio 0) (max 1 (round (* ratio width))) 0))
                     (text (if (zerop length) "-" (make-string length (aref glyph 0)))))
                (put-text-property (car bar) (1+ (car bar)) 'display
                                   (propertize text 'face '(gdev-ui-action fixed-pitch)))))))))))

(defun gdev-profile-report--output (button)
  "Apri il riepilogo testuale associato a BUTTON."
  (let ((buffer (button-get button 'gdev-profile-output)))
    (if (buffer-live-p buffer)
        (pop-to-buffer buffer)
      (user-error "L’output della misurazione è stato chiuso"))))

(defun gdev-profile-report-benchmarks (data root &optional output)
  "Apri il rapporto delle misurazioni DATA del progetto ROOT.
DATA è il JSON di hyperfine decodificato con oggetti alist e array list.
OUTPUT è il buffer facoltativo con l'uscita originale del comando."
  (let* ((project (file-name-nondirectory (directory-file-name root)))
         (project (if (string-empty-p project) root project))
         (buffer (generate-new-buffer (format "*Prestazioni · %s*" project)))
         (results (gdev-profile-report--results data))
         (slowest (alist-get 'mean (car (last results)))))
    (with-current-buffer buffer
      (setq default-directory (file-name-as-directory root))
      (gdev-profile-report-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "Prestazioni" 'face 'gdev-ui-view-title) "\n"
                (propertize (abbreviate-file-name root) 'face 'gdev-ui-secondary) "\n")
        (when (buffer-live-p output)
          (insert-text-button "Apri output" 'type 'gdev-ui-action
                              'action #'gdev-profile-report--output 'gdev-profile-output output)
          (insert "\n"))
        (insert "\n")
        (if results
            (progn
              (insert (propertize "Durata media" 'face 'gdev-ui-view-heading) "\n"
                      (propertize "Dal comando più rapido al più lento" 'face 'gdev-ui-secondary)
                      "\n\n")
              (dolist (result results)
                (gdev-profile-report--insert-result result slowest)))
          (insert (propertize "Nessuna misurazione disponibile" 'face 'gdev-ui-secondary) "\n"))
        (goto-char (point-min))
        (set-buffer-modified-p nil)))
    (pop-to-buffer buffer)
    (gdev-profile-report--resize (selected-window))
    buffer))

(provide 'gdev-profile-report)
;;; gdev-profile-report.el ends here
