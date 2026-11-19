;;; gdev-command-context.el --- File, cartella e progetto di un comando -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un solo punto risponde alla domanda «su quale file, cartella e progetto
;; agisce questo comando?».  Tastiera, barra dei menu, menu contestuale e
;; Comandi usano le stesse funzioni, così un comando dà lo stesso esito da
;; ogni ingresso.  Una vista che mostra file o cartelle dichiara come
;; leggere la riga corrente con `gdev-command-file-function'.

;;; Code:

(require 'gdev-lib)
(require 'gdev-workspace-roots)

(declare-function dired-get-filename "dired")

(defvar-local gdev-command-file-function nil
  "Funzione senza argomenti che restituisce il file della riga corrente.
Una vista che mostra file o cartelle la imposta nella propria modalità.")

(defun gdev-command-file (&optional window)
  "Restituisci il file o la cartella su cui agisce un comando.
È la voce della riga corrente in una vista che mostra file, la voce di
Dired o il documento visitato.  Con WINDOW legge quella finestra."
  (if window
      (with-selected-window window (gdev-command-file))
    (cond (gdev-command-file-function (funcall gdev-command-file-function))
          ((derived-mode-p 'dired-mode) (dired-get-filename nil t))
          (t buffer-file-name))))

(defun gdev-command--directory-of (file)
  "Restituisci FILE se è una cartella locale, altrimenti la sua cartella."
  (if (and (not (file-remote-p file)) (file-directory-p file))
      (file-name-as-directory file)
    (file-name-directory file)))

(defun gdev-command-directory (&optional window)
  "Restituisci la cartella su cui agisce un comando.
Mentre è in corso un comando di «Cambia progetto» è la cartella scelta.
Altrimenti è la cartella del file del contesto o quella della vista.
Con WINDOW legge quella finestra."
  (let ((file (and (not (bound-and-true-p project-current-directory-override))
                   (gdev-command-file window))))
    (file-name-as-directory
     (expand-file-name
      (cond (file (gdev-command--directory-of file))
            (window (with-selected-window window (gdev-default-directory)))
            (t (gdev-default-directory)))))))

(defun gdev-command-project (&optional window)
  "Restituisci la radice del progetto su cui agisce un comando.
Con WINDOW legge quella finestra."
  (gdev-project-root (gdev-command-directory window)))

(defun gdev-command-relative-name (file &optional roots)
  "Restituisci FILE relativo alla cartella più specifica fra ROOTS.
ROOTS vale per difetto le cartelle dello spazio attivo.  Fuori da
quelle cartelle il nome è relativo al progetto di FILE.  Esplora file,
il menu File e il menu contestuale usano la stessa regola."
  (file-relative-name
   file (or (gdev-workspace-root-for file (or roots (gdev-workspace-roots)))
            (gdev-project-root (gdev-command--directory-of file)))))

(provide 'gdev-command-context)
;;; gdev-command-context.el ends here
