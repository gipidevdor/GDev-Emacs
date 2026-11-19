;;; config.el --- :tools jupyter: notebook e console di kernel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; M-x gdev-jupyter-console apre una console collegata al kernel.
;; M-x gdev-jupyter-execute-notebook esegue un notebook .ipynb e scrive
;; i risultati in un'altra copia.

;;; Code:

(require 'gdev-handlers)
(require 'comint)

(defun gdev-jupyter-console (kernel)
  "Apri una console Jupyter per KERNEL nella cartella del progetto."
  (interactive (list (read-string "Kernel: " nil nil "python3")))
  (unless (executable-find "jupyter") (user-error "Jupyter non è disponibile"))
  (let ((default-directory (gdev-project-root)))
    (pop-to-buffer (make-comint (format "Jupyter · %s · %s" kernel (gdev-project-name))
                                "jupyter" nil "console" (concat "--kernel=" kernel)))))

(defun gdev-jupyter-execute-notebook (file output)
  "Esegui il notebook FILE e salva il risultato in OUTPUT."
  (interactive
   (let ((file (read-file-name "Notebook: " nil nil t nil
                               (lambda (candidate)
                                 (or (file-directory-p candidate)
                                     (string-suffix-p ".ipynb" candidate))))))
     (list file (read-file-name "Copia con i risultati: " (file-name-directory file) nil nil
                                (concat (file-name-base file) ".eseguito.ipynb")))))
  (let ((source (expand-file-name file))
        (target (expand-file-name output)))
    (unless (and (executable-find "jupyter") (file-regular-p source)
                 (string-suffix-p ".ipynb" target) (file-directory-p (file-name-directory target)))
      (user-error "Servono Jupyter, un notebook leggibile e una destinazione .ipynb"))
    (when (or (equal source target) (file-equal-p source target))
      (user-error "Scegli una destinazione diversa dal notebook originale"))
    (when (and (file-exists-p target) (not (yes-or-no-p "Sostituire la copia precedente? ")))
      (user-error "Esecuzione annullata"))
    (gdev-compile (gdev-command-line "jupyter" "nbconvert" "--to" "notebook" "--execute"
                                    "--output-dir" (file-name-directory target)
                                    "--output" (file-name-nondirectory target) source)
                  "Jupyter · Notebook" (file-name-directory source))))

(gdev-set-tool-actions 'jupyter "Jupyter" "terminal"
  ["Apri console del kernel…" gdev-jupyter-console]
  ["Esegui notebook in una copia…" gdev-jupyter-execute-notebook])

(gdev-doctor-executable "jupyter" "Installa Jupyter nel tuo ambiente Python" 'note)

;;; config.el ends here
