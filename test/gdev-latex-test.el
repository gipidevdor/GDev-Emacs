;;; gdev-latex-test.el --- Prove del progetto e degli strumenti LaTeX -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica i sorgenti del modello, il fork locale e le azioni di compilazione.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gdev-modules)

(defvar latex-mode-hook)

(defun gdev-test--load-latex ()
  "Prepara le capacità anche dopo un'attivazione temporanea."
  (let ((gdev-modules (cons '(:lang latex) gdev-modules)))
    (load (gdev-module-file :lang 'latex ".el") nil t t)))

(ert-deftest gdev-test-latex-project-template-and-fork ()
  "Il progetto visita il documento, usa il fork e protegge i file esistenti."
  (gdev-test--load-latex)
  (let* ((container (make-temp-file "gdev-latex-test-" t))
         (folder (expand-file-name "Prova accentata" container))
         (file (expand-file-name "main.tex" folder))
         hook-ran
         (latex-mode-hook (list (lambda () (setq hook-ran t))))
         buffer)
    (unwind-protect
        (progn
          (gdev-latex--initialize folder "Titolo & società\n100%")
          (should (equal (expand-file-name folder)
                         (directory-file-name (project-root (project-current nil folder)))))
          (should (file-regular-p (expand-file-name "bibliografia.bib" folder)))
          (should (file-equal-p
                   (file-name-directory (locate-library "gdev-tex-mode"))
                   (gdev-bundled-package-directory 'gdev-tex-mode)))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (should (eq major-mode 'gdev-latex-mode))
            (should hook-ran)
            (should (derived-mode-p 'latex-mode 'tex-mode))
            (should (eq gdev-ui-view-profile 'native))
            (should (eq indent-line-function #'latex-indent))
            (should (eq (key-binding (kbd "C-c C-s")) #'latex-split-block))
            (should (eq (key-binding (kbd "C-c C-v")) #'gdev-latex-open-pdf))
            (should (eq (lookup-key (current-local-map) [menu-bar tex]) #'undefined))
            (let ((menu (lookup-key (current-local-map) [menu-bar gdev-latex]))
                  commands)
              (map-keymap (lambda (_ binding)
                            (when (eq (car-safe binding) 'menu-item)
                              (push (nth 2 binding) commands)))
                          menu)
              (should (memq 'gdev-latex-open-pdf commands))
              (should-not (memq 'tex-view commands)))
            (should (string-search "\\title{Titolo \\& società 100\\%}" (buffer-string)))
            (should (seq-some (lambda (item) (eq (aref item 1) 'gdev-latex-compile))
                              gdev-context-items)))
          (should-error (gdev-latex--initialize folder "Nuovo titolo") :type 'user-error))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory container t))))

(ert-deftest gdev-test-latex-text-actions-preserve-selection-content ()
  "Le azioni testuali inseriscono sintassi LaTeX e lasciano pronto il cursore."
  (gdev-test--load-latex)
  (with-temp-buffer
    (gdev-latex-mode)
    (let ((transient-mark-mode t))
      (insert "Parole")
      (set-mark (point-min))
      (setq mark-active t)
      (gdev-latex-bold)
      (should (equal (buffer-string) "\\textbf{Parole}")))
    (goto-char (point-max))
    (gdev-latex-insert-section "section" "Scienza & cultura")
    (should (string-suffix-p "\n\\section{Scienza \\& cultura}\n\n" (buffer-string)))
    (gdev-latex-inline-math)
    (insert "x^2")
    (should (string-suffix-p "\\(x^2\\)" (buffer-string)))))

(ert-deftest gdev-test-latex-standalone-keeps-plain-tex ()
  "I sorgenti autonomi preferiscono la modalità corretta dal contenuto."
  (gdev-test--load-latex)
  (dolist (entry '(("\\documentclass{article}\n" . gdev-latex-mode)
                   ("\\hbox{Plain TeX}\n\\bye\n" . plain-tex-mode)))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "prova.tex" temporary-file-directory))
      (insert (car entry))
      (set-auto-mode)
      (should (eq major-mode (cdr entry))))))

(ert-deftest gdev-test-latex-compiles-the-main-source-of-an-included-file ()
  "Il comando usa il sorgente principale dalla cartella che lo contiene."
  (gdev-test--load-latex)
  (let* ((folder (make-temp-file "gdev-latex-test-" t))
         (main (expand-file-name "main.tex" folder))
         (fragment (expand-file-name "sezioni/Con accento è.tex" folder))
         invocation)
    (unwind-protect
        (progn
          (gdev-latex--initialize folder "Prova")
          (make-directory (file-name-directory fragment))
          (write-region "Testo\n" nil fragment nil 'silent)
          (with-temp-buffer
            (setq default-directory (file-name-directory fragment)
                  buffer-file-name fragment)
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (name &optional _) (when (equal name "pdflatex") "/te x/pdflatex")))
                      ((symbol-function 'save-some-buffers) #'ignore)
                      ((symbol-function 'gdev-compile)
                       (lambda (command _name directory)
                         (setq invocation (cons command directory)))))
              (gdev-latex-compile)
              (should (equal invocation
                             (cons (gdev-command-line "/te x/pdflatex" "-no-shell-escape"
                                                      "-interaction=nonstopmode" "-file-line-error"
                                                      "-halt-on-error" main)
                                   (file-name-as-directory folder)))))))
      (delete-directory folder t))))

(ert-deftest gdev-test-latex-build-uses-the-compilation-buffer ()
  "Un motore di prova riceve il sorgente e scrive nel buffer di compilazione."
  (gdev-test--load-latex)
  (let* ((folder (make-temp-file "gdev LaTeX-" t))
         (program (expand-file-name "pdflatex" folder))
         (main (expand-file-name "main.tex" folder))
         source output)
    (unwind-protect
        (save-window-excursion
          (gdev-latex--initialize folder "Prova")
          (write-region "#!/bin/sh\nfor arg do printf 'Argomento=<%s>\\n' \"$arg\"; done\n"
                        nil program nil 'silent)
          (set-file-modes program #o700)
          (setq source (find-file-noselect main))
          (with-current-buffer source
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (name &optional _) (and (equal name "pdflatex") program))))
              (setq output (gdev-latex-compile))))
          (let ((process (get-buffer-process output))
                (deadline (+ (float-time) 5)))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1)))
          (with-current-buffer output
            (should (derived-mode-p 'compilation-mode))
            (should (string-search "Argomento=<-no-shell-escape>" (buffer-string)))
            (should (string-search (format "Argomento=<%s>" main) (buffer-string)))))
      (dolist (buffer (list source output))
        (when (buffer-live-p buffer)
          (when-let* ((process (get-buffer-process buffer)))
            (delete-process process))
          (kill-buffer buffer)))
      (delete-directory folder t))))

;;; gdev-latex-test.el ends here
