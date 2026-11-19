;;; config.el --- :emacs ibuffer: il gestore delle aree di testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; C-x C-b (C-c b i) elenca le aree di testo raggruppate per
;; progetto: marcane molte e agisci su tutte insieme (salva, chiudi, cerca,
;; sostituisci). Per i progetti omonimi, il titolo include la parte
;; del percorso che li distingue.
;; C-o mostra tutte le operazioni.

;;; Code:

(require 'gdev-lib)
(require 'gdev-ui)                      ; misura in pixel con il carattere della vista

(defvar ibuffer-filter-groups)
(defvar ibuffer-inline-columns)
(declare-function project-root "project" (project))

(keymap-global-set "C-x C-b" #'ibuffer)

(defun gdev-ibuffer--project-path (root)
  "Normalizza ROOT senza chiedere il percorso reale a un server remoto."
  (file-name-as-directory (if (file-remote-p root) (expand-file-name root)
                            (file-truename root))))

(defun gdev-ibuffer--project-label (root roots)
  "Distingui ROOT dalle altre ROOTS con la parte finale del percorso."
  (let* ((other (remove root roots))
         (parts (reverse (split-string (directory-file-name root) "/" t))))
    (cl-loop with label = (or (pop parts) root)
             while (seq-some (lambda (candidate) (string-suffix-p (concat "/" label "/") candidate)) other)
             if parts do (setq label (concat (pop parts) "/" label))
             else return (abbreviate-file-name (directory-file-name root))
             finally return label)))

(defun gdev-ibuffer--in-project-p (roots)
  "Verifica se il documento o lo strumento corrente appartiene a ROOTS."
  (let ((path (expand-file-name (or buffer-file-truename default-directory))))
    (seq-some (lambda (root)
                (or (and path (string-prefix-p root (file-name-as-directory path)))
                    (and buffer-file-name (string-prefix-p root buffer-file-name))))
              roots)))

(defun gdev-ibuffer-group-by-project ()
  "Raggruppa per percorso di progetto l'elenco di Ibuffer."
  (interactive)
  (require 'ibuf-ext)
  (let* ((paths (cl-loop for buffer in (buffer-list)
                         for project = (with-current-buffer buffer
                                         (and (or buffer-file-name (derived-mode-p 'dired-mode))
                                              (project-current nil)))
                         when project collect (file-name-as-directory (project-root project))))
         (projects (seq-group-by #'gdev-ibuffer--project-path (delete-dups paths)))
         (roots (mapcar #'car projects)))
    ;; Ibuffer assegna un documento al primo gruppo che lo comprende.
    (setq projects (sort projects (lambda (left right)
                                    (let ((a (car left)) (b (car right)))
                                      (cond ((string-prefix-p a b) nil)
                                            ((string-prefix-p b a) t)
                                            (t (string< a b)))))))
    (setq ibuffer-filter-groups
          (append (mapcar (lambda (project)
                            (cons (gdev-ibuffer--project-label (car project) roots)
                                  `((predicate . (gdev-ibuffer--in-project-p ',project)))))
                          projects)
                  '(("Fuori progetto")))))
  (ibuffer-update nil t))
(declare-function ibuffer-update "ibuffer")
(declare-function ibuffer-redisplay "ibuffer")
(declare-function ibuffer-expand-format-entry "ibuffer")
(defvar ibuffer-filter-groups)
(defvar-local gdev-ibuffer--pixel-width nil)

(defun gdev-ibuffer--view-width ()
  "Restituisci la larghezza più stretta tra le finestre grafiche della vista."
  (when-let* ((widths (cl-loop for window in (get-buffer-window-list nil nil 'visible)
                              when (display-graphic-p (window-frame window))
                              collect (window-body-width window t))))
    (apply #'min widths)))

(defun gdev-ibuffer--fit-group-header (args)
  "Adatta il titolo nei parametri ARGS, tenendo l'identità del gruppo."
  (pcase (cadr (assoc (car args) ibuffer-filter-groups))
    (`(predicate gdev-ibuffer--in-project-p ',roots)
     (setf (nth 2 args) (car roots))
     (when-let* ((width (gdev-ibuffer--view-width)))
       (let* ((face (or (bound-and-true-p ibuffer-filter-group-name-face) 'bold))
              (suffix (if (equal (car args) (cadr args)) "" " ..."))
              (padding (gdev-ui-string-pixel-width (propertize (concat "[  ]" suffix) 'face face)))
              (label (gdev-ui-fit-text (propertize (car args) 'face face) (- width padding)
                                      #'gdev-ui-string-pixel-width)))
         (setf (nth 1 args) (concat (substring-no-properties label) suffix))))))
  args)

(defun gdev-ibuffer--resize (_window)
  "Adatta i titoli alla nuova larghezza conservando righe e contrassegni."
  (let ((width (gdev-ibuffer--view-width)))
    (unless (equal width gdev-ibuffer--pixel-width)
      (setq gdev-ibuffer--pixel-width width)
      (ibuffer-redisplay t))))

(defun gdev-ibuffer--display-name (args)
  "Usa un nome italiano di Ibuffer salvo quello esplicito in ARGS."
  (if (cadr args) args
    (cons (car args) (cons "*Documenti e strumenti*" (cddr args)))))

(defun gdev-ibuffer--mode-label ()
  "Imposta l'etichetta della modalità anche nella barra di stato nativa."
  (setq mode-name "Documenti e strumenti"
        gdev-ibuffer--pixel-width (gdev-ibuffer--view-width))
  (add-hook 'window-size-change-functions #'gdev-ibuffer--resize nil t))

(declare-function casual-ibuffer-tmenu "casual-ibuffer")

(use-package ibuffer
  :ensure nil
  :hook ((ibuffer . gdev-ibuffer-group-by-project)
         (ibuffer-mode . gdev-ibuffer--mode-label))
  :custom
  (ibuffer-show-empty-filter-groups nil)
  (ibuffer-expert t)                    ; chiude senza conferma i buffer non modificati
  :config
  (advice-add 'ibuffer :filter-args #'gdev-ibuffer--display-name)
  (advice-add 'ibuffer-insert-filter-group :filter-args #'gdev-ibuffer--fit-group-header)
  (keymap-set ibuffer-mode-map "C-o" #'casual-ibuffer-tmenu)
  (dolist (column '((name . "Nome") (size . "Dim.") (mode . "Modalità")
                    (recency . "Ultimo accesso") (process . "Processo")
                    (filename . "Percorso") (filename-and-process . "Percorso o processo")))
    (let ((function (intern (format "ibuffer-make-column-%s" (car column)))))
      (when (or (fboundp function) (assq function ibuffer-inline-columns))
        (put function 'ibuffer-column-name (cdr column))))))

(use-package casual
  :ensure t
  :defer t)

;;; config.el ends here
