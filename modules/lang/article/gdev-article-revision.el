;;; gdev-article-revision.el --- Revisione del manoscritto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Controlla la struttura del manoscritto e le verifiche aperte. La vista
;; legge il testo corrente quando viene aperta o aggiornata con `g`.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'org-element)
(require 'ox)
(require 'seq)
(require 'subr-x)

(declare-function gdev-article--document-title "config" (file &optional buffer))
(declare-function gdev-article--manuscript-buffer "config" (&optional root))
(declare-function gdev-article--project-root "config" ())
(defvar gdev-article--manuscript)

(defvar-local gdev-article-review--file nil
  "Percorso del manoscritto che alimenta la vista.")

(defvar-local gdev-article-review--tick nil
  "Revisione del contenuto del manoscritto rappresentata nella vista.")

(defconst gdev-article-review--groups
  '((empty . "Testo da completare")
    (todo . "Attività aperte")
    (checkbox . "Verifiche aperte"))
  "Ordine e intestazioni dei controlli.")

(defconst gdev-article-review--metadata
  '(clock comment comment-block drawer keyword node-property planning property-drawer)
  "Elementi di servizio esclusi dai controlli sul corpo del testo.")

(defvar-keymap gdev-article-review-mode-map
  :parent special-mode-map
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-article-review-mode special-mode "Revisione articolo"
  "Consulta i punti da rivedere nel manoscritto."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-document)
  (visual-line-mode 1)
  (setq-local left-margin-width 2
              right-margin-width 2
              revert-buffer-function #'gdev-article-review--render))

(defun gdev-article-review--keyword-values (tree key)
  "Restituisci i valori KEY dichiarati localmente in TREE."
  (org-element-map tree 'keyword
    (lambda (node)
      (when (equal key (org-element-property :key node))
        (org-element-property :value node)))))

(defun gdev-article-review--public-p (node excluded)
  "Indica se NODE è una sezione rivedibile con i tag EXCLUDED."
  (and (not (org-element-property :commentedp node))
       (not (org-element-property :archivedp node))
       (not (seq-intersection excluded (org-element-property :tags node)))))

(defun gdev-article-review--has-body-p (node excluded)
  "Indica se NODE ha testo o una sottosezione visibile con i tag EXCLUDED."
  (seq-some (lambda (child)
              (pcase (org-element-type child)
                ('headline (gdev-article-review--public-p child excluded))
                ('section
                 (seq-some (lambda (element)
                             (not (memq (org-element-type element)
                                        gdev-article-review--metadata)))
                           (org-element-contents child)))))
            (org-element-contents node)))

(defun gdev-article-review--checkbox-title (node)
  "Restituisci la prima riga di testo della casella Org NODE."
  (when-let* ((start (org-element-property :contents-begin node)))
    (save-excursion
      (goto-char start)
      (string-trim (buffer-substring-no-properties start (line-end-position))))))

(defun gdev-article-review--findings ()
  "Raccogli i punti da rivedere nel manoscritto Org corrente."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((tree (org-element-parse-buffer 'element))
             (excluded (append '("noexport") org-export-exclude-tags
                               (split-string
                                (string-join
                                 (gdev-article-review--keyword-values tree "EXCLUDE_TAGS") " "))))
             (filetags (split-string
                        (string-join (gdev-article-review--keyword-values tree "FILETAGS") ":")
                        "[: \t]+" t))
             findings)
        (cl-labels
            ((add (kind node title)
               (push (list kind (org-element-property :begin node) title) findings))
             (visit (node)
               (let ((type (org-element-type node)))
                 (cond
                  ((memq type gdev-article-review--metadata))
                  ((memq type '(headline inlinetask))
                   (when (gdev-article-review--public-p node excluded)
                     (let ((title (string-trim (or (org-element-property :raw-value node) ""))))
                       (cond
                        ((eq (org-element-property :todo-type node) 'todo)
                         (add 'todo node (if (string-empty-p title) "Attività senza titolo" title)))
                        ((and (eq type 'headline)
                              (not (gdev-article-review--has-body-p node excluded)))
                         (add 'empty node (if (string-empty-p title) "Sezione senza titolo" title)))))
                     (mapc #'visit (org-element-contents node))))
                  (t
                   (when (and (eq type 'item)
                              (memq (org-element-property :checkbox node) '(off trans)))
                     (add 'checkbox node (or (gdev-article-review--checkbox-title node)
                                             "Verifica senza testo")))
                   (mapc #'visit (org-element-contents node)))))))
          (unless (seq-intersection excluded filetags)
            (if (gdev-article-review--has-body-p tree excluded)
                (mapc #'visit (org-element-contents tree))
              (push (list 'empty (point-max) "Aggiungi il testo dell’articolo") findings))))
        (nreverse findings)))))

(defun gdev-article-review--source ()
  "Restituisci il buffer Org che visita il manoscritto della vista."
  (let ((buffer (gdev-article--manuscript-buffer default-directory)))
    (unless (provided-mode-derived-p (buffer-local-value 'major-mode buffer) 'org-mode)
      (user-error "Apri il manoscritto in modalità Org"))
    buffer))

(defun gdev-article-review--jump (button)
  "Raggiungi nel manoscritto il punto ancora aperto associato a BUTTON."
  (let ((marker (button-get button 'gdev-article-review-position))
        (tick gdev-article-review--tick)
        (source (gdev-article-review--source)))
    (unless (and (eq (marker-buffer marker) source)
                 (or (= tick (buffer-chars-modified-tick source))
                     (member (list (button-get button 'gdev-article-review-kind)
                                   (marker-position marker) (button-label button))
                             (with-current-buffer source (gdev-article-review--findings)))))
      (user-error "Aggiorna la revisione con g per ricalcolare i punti"))
    (pop-to-buffer-same-window source)
    (unless (<= (point-min) marker (point-max))
      (widen))
    (goto-char marker)
    (org-fold-show-context 'agenda)))

(defun gdev-article-review--render (&optional _ignore-auto _noconfirm)
  "Aggiorna i controlli e ripristina, se presente, il punto selezionato."
  (let* ((source (gdev-article-review--source))
         (findings (with-current-buffer source (gdev-article-review--findings)))
         (kind (get-text-property (point) 'gdev-article-review-kind))
         (selected (get-text-property (point) 'gdev-article-review-position))
         (inhibit-read-only t)
         position)
    (erase-buffer)
    (insert (propertize "Revisione del manoscritto" 'face 'gdev-ui-view-title) "\n"
            (propertize (gdev-article--document-title gdev-article-review--file source)
                        'face 'gdev-ui-secondary) "\n\n")
    (if findings
        (dolist (group gdev-article-review--groups)
          (when-let* ((rows (seq-filter (lambda (row) (eq (car row) (car group))) findings)))
            (insert (propertize (cdr group) 'face 'gdev-ui-view-heading) "\n")
            (pcase-dolist (`(,type ,at ,title) rows)
              (when (and (eq kind type) (markerp selected)
                         (eq (marker-buffer selected) source) (equal (marker-position selected) at))
                (setq position (point)))
              (insert-text-button title 'type 'gdev-ui-action 'help-echo title
                                  'action #'gdev-article-review--jump
                                  'gdev-article-review-kind type
                                  'gdev-article-review-position (with-current-buffer source
                                                                 (copy-marker at t)))
              (insert "\n"))
            (insert "\n")))
      (insert (propertize "Nessun punto aperto nei controlli di revisione"
                          'face 'gdev-ui-status-success) "\n"))
    (goto-char (or position (point-min)))
    (setq gdev-article-review--tick (buffer-chars-modified-tick source))
    (set-buffer-modified-p nil)))

;;;###autoload
(defun gdev-article-review (&optional root)
  "Apri i controlli di revisione per il manoscritto del progetto ROOT."
  (interactive)
  (let* ((directory (file-name-as-directory (expand-file-name (or root (gdev-article--project-root)))))
         (file (expand-file-name gdev-article--manuscript directory))
         (window (or (gdev-layout-editor) (selected-window)))
         (view (seq-find (lambda (buffer)
                           (equal file (buffer-local-value 'gdev-article-review--file buffer)))
                         (buffer-list))))
    (unless (file-regular-p file)
      (user-error "Il manoscritto %s non è disponibile" (file-name-nondirectory file)))
    (unless view
      (setq view (generate-new-buffer (format "*Revisione · %s*" (file-name-nondirectory
                                                                 (directory-file-name directory)))))
      (with-current-buffer view
        (gdev-article-review-mode)
        (setq default-directory directory
              gdev-article-review--file file)))
    (with-current-buffer view
      (gdev-article-review--render))
    (select-window window)
    (pop-to-buffer-same-window view)))

(provide 'gdev-article-revision)
;;; gdev-article-revision.el ends here
