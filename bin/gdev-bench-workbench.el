;;; gdev-bench-workbench.el --- Misure del Workbench in un profilo isolato -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Avviato da gdev bench flussi. I tempi batch comprendono il comando e il
;; modello della vista. Il disegno di AppKit richiede una verifica distinta.
;;; Code:
(require 'cl-lib)
(require 'gdev-activity)
(require 'gdev-search)
(require 'gdev-workbench-operations)

(defun gdev-bench--wait (predicate)
  "Attendi PREDICATE fino a 30 secondi elaborando l'output dei processi."
  (let ((deadline (time-add (current-time) 30)))
    (while (and (not (funcall predicate)) (time-less-p (current-time) deadline))
      (accept-process-output nil 0.01))
    (unless (funcall predicate) (error "Tempo scaduto durante la misura"))))

(defun gdev-bench--quick-open ()
  "Esercita il comando fino alla disponibilità del percorso nella tabella."
  (cl-letf (((symbol-function 'gdev-quick-open--read)
             (lambda (_initial table &rest _)
               ;; In batch manca il ciclo interattivo del minibuffer. Solo
               ;; l'input è sostituito; indice, processo e candidati sono reali.
               (let ((noninteractive nil))
                 (cl-letf (((symbol-function 'active-minibuffer-window) #'minibuffer-window))
                   (gdev-bench--wait (lambda () (test-completion "299/099.txt" table)))))
               "")))
    (gdev-quick-open)))

(defun gdev-bench--measure (name budget function &optional prepare)
  "Misura cinque invocazioni di FUNCTION dopo un riscaldamento."
  (when prepare (funcall prepare))
  (funcall function)
  (let (samples)
    (dotimes (_ 5)
      (when prepare (funcall prepare))
      (let ((start (current-time)))
        (funcall function)
        (push (* 1000.0 (float-time (time-subtract (current-time) start))) samples)))
    (let ((median (nth 2 (sort (copy-sequence samples) #'<))))
      (list :nome name :mediana_ms median :limite_ms budget :campioni_ms (vconcat (nreverse samples))))))

(defun gdev-bench--activity (view)
  (gdev-activity-select view)
  (unless (eq (window-buffer (selected-window)) (window-buffer (gdev-layout-left-window)))
    (error "Il fuoco della vista %s non è nel riquadro sinistro" view)))

(defun gdev-bench--run (root)
  (unless (and (executable-find "git") (executable-find "make") (executable-find "rg"))
    (error "Installa Git, Make e ripgrep per misurare i flussi"))
  (let ((default-directory root)
        (gdev-trusted-projects (list root))
        (target (expand-file-name "299/099.txt" root))
        build-process build-start metrics)
    (unless (zerop (process-file "git" nil nil nil "init" "-q"))
      (error "Impossibile preparare il repository di misura"))
    (dotimes (i 300)
      (let ((dir (format "%03d/" i)))
        (make-directory dir)
        (dotimes (j 100) (write-region "" nil (format "%s%03d.txt" dir j) nil 'silent))))
    (with-temp-file target (insert "ago-workbench\n"))
    (with-temp-file "Makefile" (insert "all:\n\t@echo compilato > prodotto\n"))
    (with-temp-file ".gdev-project.eld"
      (prin1 '(:version 1 :default "Misura" :profiles (("Misura" :build ("make")))) (current-buffer)))
    (gdev-layout-mode 1)
    (gdev-open-folder root)
    (select-window (gdev-layout-editor))
    (push (gdev-bench--measure "Tavolozza a caldo" 50 #'gdev-bench--quick-open) metrics)
    (dolist (view (gdev-activity--available))
      (let ((id (car view)))
        (push (gdev-bench--measure (nth 1 view) 100
                                   (lambda ()
                                     (gdev-bench--activity id))
                                   (lambda () (gdev-bench--activity (if (eq id 'search) 'test 'search))))
              metrics)))
    (push (gdev-bench--measure
           "Ricerca fino al risultato" nil
           (lambda ()
             (let ((buffer (gdev-search-show "ago-workbench")))
               (gdev-bench--wait
                (lambda () (with-current-buffer buffer
                             (and (null gdev-search--process) (= 1 (length gdev-search--results)))))))))
          metrics)
    (select-window (gdev-layout-editor))
    (gdev-open-file target)
    (push (gdev-bench--measure "Inserimento nel documento di testo" nil
                               (lambda ()
                                 (let ((last-command-event ?x))
                                   (call-interactively #'self-insert-command))))
          metrics)
    (set-buffer-modified-p nil)
    (let ((compilation-start-hook
           (cons (lambda (process) (setq build-process process)) compilation-start-hook)))
      (dotimes (_ 6)
        (when (file-exists-p (expand-file-name "prodotto" root)) (delete-file (expand-file-name "prodotto" root)))
        (select-window (gdev-layout-editor))
        (let ((start (current-time)))
          (setq build-process nil)
          (gdev-build)
          (push (* 1000.0 (float-time (time-subtract (current-time) start))) build-start))
        (unless (processp build-process) (error "Il comando di compilazione non ha avviato il processo"))
        (gdev-bench--wait (lambda () (not (process-live-p build-process))))
        (unless (and (zerop (process-exit-status build-process)) (file-exists-p (expand-file-name "prodotto" root)))
          (error "La compilazione di misura non ha prodotto l'uscita attesa"))))
    (setq build-start (butlast build-start))
    (push (list :nome "Avvio della compilazione" :mediana_ms (nth 2 (sort (copy-sequence build-start) #'<))
                :limite_ms nil :campioni_ms (vconcat (nreverse build-start))) metrics)
    (list :versione 1 :data (format-time-string "%FT%T%z") :emacs emacs-version
          :ambiente "batch" :percorsi 30000 :misure (vconcat (nreverse metrics)))))

(defun gdev-bench-workbench ()
  "Scrivi il rapporto nella cartella temporanea predisposta dalla CLI."
  (let* ((output (getenv "GDEV_BENCH_OUTPUT"))
         (root (file-name-as-directory (file-truename (make-temp-file "gdev-bench-progetto-" t)))))
    (unwind-protect
        (let ((result (gdev-bench--run root)))
          (with-temp-file output (prin1 result (current-buffer))))
      (delete-directory root t))))

;;; gdev-bench-workbench.el ends here
