;;; gdev-org-test.el --- Verifiche dell'Agenda di Org GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Apre l'Agenda usando i comandi di Org e un documento temporaneo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'button)

(ert-deftest gdev-test-org-agenda-renders-in-italian-from-the-local-fork ()
  "Selettore, settimana ed elenco attività usano il fork e le etichette italiane."
  (require 'package)
  (package-activate-all)
  (require 'org-agenda)
  (let* ((directory (make-temp-file "gdev-agenda-" t))
         (file (expand-file-name "attivita.org" directory))
         (org-agenda-files (list file))
         (org-agenda-window-setup 'current-window)
         (org-agenda-sticky nil)
         (org-agenda-start-day "2026-11-16")
         (org-agenda-start-on-weekday 1)
         (org-agenda-span 'week)
         (org-agenda-format-date #'org-agenda-format-date-aligned)
         (org-todo-keywords '((sequence "TODO" "NEXT" "|" "DONE")))
         (org-agenda-buffer-name "*Agenda GDev di prova*")
         (system-time-locale "C"))
    (unwind-protect
        (save-window-excursion
          (should (file-in-directory-p (symbol-file 'org-agenda 'defun)
                                       (gdev-bundled-package-directory 'org)))
          (with-temp-file file
            (insert "* TODO Preparare il verbale\n  SCHEDULED: <2026-11-16 Mon>\n"
                    "* NEXT Chiudere il fascicolo\n  DEADLINE: <2026-11-16 Mon>\n"))
          (cl-letf (((symbol-function 'read-char-exclusive)
                     (lambda (&rest _)
                       (should (string-match-p "Scegli un comando dell’Agenda" (buffer-string)))
                       (should (string-match-p "Cerca nei file dell’Agenda" (buffer-string)))
                       (should (string-match-p "Agenda e tutte le attività" (buffer-string)))
                       ?a)))
            (org-agenda))
          (should (derived-mode-p 'org-agenda-mode))
          (should (string-match-p "Agenda · settimana" (buffer-string)))
          (should (string-match-p "lunedì +16 novembre" (buffer-string)))
          (should (string-match-p "Pianificata:" (buffer-string)))
          (should (string-match-p "Scadenza:" (buffer-string)))
          (goto-char (point-min))
          (search-forward "TODO Preparare il verbale")
          (should (equal (get-text-property (match-beginning 0) 'display) "Da fare"))
          (let ((marker (org-agenda-get-any-marker)))
            (with-current-buffer (marker-buffer marker)
              (goto-char marker)
              (should (equal (org-get-todo-state) "TODO"))
              (should-not (buffer-modified-p))))
          (org-todo-list)
          (should (string-match-p "Elenco delle attività per stato" (buffer-string)))
          (should (string-match-p "Premi .N r. per filtrare per stato" (buffer-string)))
          (should-not (string-search "Global list" (buffer-string)))
          (should-not (string-search "Press " (buffer-string))))
      (dolist (buffer (list (get-file-buffer file) (get-buffer org-agenda-buffer-name)
                            (get-buffer " *Comandi dell’Agenda*")))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest gdev-test-org-agenda-keeps-file-order-across-views ()
  "Le voci mantengono l'ordine dei file anche quando qualcuno è vuoto."
  (require 'package)
  (package-activate-all)
  (require 'org-agenda)
  (let* ((directory (make-temp-file "gdev-agenda-ordine-" t))
         (files (mapcar (lambda (name) (expand-file-name name directory))
                        '("prima.org" "vuoto.org" "ultima.org" "fine.org")))
         (org-agenda-files files)
         (org-agenda-window-setup 'current-window)
         (org-agenda-sticky nil)
         (org-agenda-start-on-weekday nil)
         (org-agenda-use-time-grid nil)
         (org-agenda-sorting-strategy '((agenda) (todo) (search) (tags)))
         (org-agenda-buffer-name "*Agenda GDev ordine*"))
    (unwind-protect
        (save-window-excursion
          (cl-mapc (lambda (file text)
                     (with-temp-file file
                       (insert text)))
                   files
                   '("* TODO Prova uno :prova:\n  SCHEDULED: <2026-11-16 Mon>\n* TODO Prova due :prova:\n  SCHEDULED: <2026-11-16 Mon>\n"
                     ""
                     "* TODO Prova tre :prova:\n  SCHEDULED: <2026-11-16 Mon>\n"
                     ""))
          (dolist (view '((org-agenda-list nil "2026-11-16" day)
                          (org-todo-list)
                          (org-search-view nil "Prova")
                          (org-tags-view nil "+prova")))
            (apply (car view) (cdr view))
            (let ((text (buffer-string)))
              (should (= (how-many "Prova " (point-min) (point-max)) 3))
              (should (< (string-search "Prova uno" text)
                         (string-search "Prova due" text)
                         (string-search "Prova tre" text))))))
      (dolist (buffer (cons (get-buffer org-agenda-buffer-name)
                           (mapcar #'get-file-buffer files)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest gdev-test-org-calendar-opens-a-real-entry-after-redraw ()
  "L'Agenda preserva la voce selezionata e la apre nel documento Org."
  (package-activate-all)
  (require 'org-agenda)
  (unless (fboundp 'gdev-org-calendar)
    (load (gdev-module-file :lang 'org ".el") nil t))
  (let* ((directory (file-name-as-directory (make-temp-file "gdev-calendario-" t)))
         (file (expand-file-name "agenda.org" directory))
         (date (format-time-string "%Y-%m-%d" (org-time-from-absolute (org-today))))
         (org-agenda-files (list file))
         (gdev-layout-mode nil)
         view)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert "* TODO Riesame del progetto\n  SCHEDULED: <" date " 10:00-11:00>\n"
                    "* TODO Pubblicare il verbale\n  DEADLINE: <" date ">\n"))
          (let ((default-directory directory)) (call-interactively #'gdev-org-calendar))
          (setq view (current-buffer))
          (should (derived-mode-p 'gdev-org-calendar-mode))
          (should (eq gdev-ui-view-profile 'document))
          (let ((segments
                 (mapcar (lambda (id)
                           (goto-char (point-min))
                           (button-at (prop-match-beginning
                                       (text-property-search-forward 'gdev-org-calendar-item id #'eq))))
                         '(day workweek week))))
            (should (apply #'= (mapcar (lambda (button) (- (button-end button) (button-start button)))
                                       segments)))
            (should (memq 'gdev-ui-action-primary (button-get (car (last segments)) 'face))))
          (execute-kbd-macro (kbd "v l"))
          (let ((range (gdev-org-calendar-visible-range)))
            (should (= 5 (- (cdr range) (car range)))))
          (execute-kbd-macro (kbd "v d"))
          (execute-kbd-macro (kbd "t"))
          (should (string-search "Tutto il giorno" (buffer-string)))
          (should (string-search "10:00–11:00" (buffer-string)))
          (should (= 1 (how-many (regexp-quote (gdev-org-calendar--title
                                               (org-today) (1+ (org-today))))
                                 (point-min) (point-max))))
          (goto-char (point-min))
          (should (search-forward "Riesame del progetto" nil t))
          (goto-char (match-beginning 0))
          (let ((item (button-get (button-at (point)) 'gdev-org-calendar-item)))
            (should item)
            (gdev-org-calendar-redraw)
            (should (equal item (button-get (button-at (point)) 'gdev-org-calendar-item)))
            (gdev-org-calendar-refresh)
            (should (equal item (button-get (button-at (point)) 'gdev-org-calendar-item))))
          (execute-kbd-macro (kbd "RET"))
          (should (equal buffer-file-name file))
          (should (string-search "Riesame del progetto" (thing-at-point 'line t))))
      (dolist (buffer (list view (get-file-buffer file)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory directory t))))

;;; gdev-org-test.el ends here
