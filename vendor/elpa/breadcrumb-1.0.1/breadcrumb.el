;;; breadcrumb.el --- project and imenu-based breadcrumb paths   -*- lexical-binding: t; -*-

;; Modificato per GDev-Emacs il 2026-11-17: indicizzazione lineare dei
;; percorsi Imenu senza modificare le etichette del fornitore, accesso ai
;; segmenti grezzi e supporto per indici con regioni e voce di aggiornamento.
;; Dopo l'indicizzazione aggiorna solo le righe del documento indicizzato.

;; Copyright (C) 2023  Free Software Foundation, Inc.

;; Author: João Távora <joaotavora@gmail.com>
;; Package-Requires: ((emacs "28.1") (project "0.9.8"))
;; Version: 1.0.1
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;;;; Usage:
;;
;; Breadcrumbs are sequences of short strings indicating where you
;; are in some big tree-like maze.
;;
;; To craft these strings, this library uses the maps provided by
;; project.el and Imenu, respectively.  Project breadcrumbs shows you
;; the current buffer's path in a large project.  Imenu breadcrumbs
;; show the current position of point in the buffer's nested
;; structure of programming constructs (for example, a specific
;; functions within multiple C++ nested namespaces).
;;
;; To use this library:
;;
;; * `M-x breadcrumb-mode` is a global mode.  Will try to turn itself
;;   on conservatively and only if there's a project.
;;
;; * `M-x breadcrumb-local-mode` is a buffer-local minor mode, if you
;;    don't want the default heuristics for turning it on everywhere.
;;
;; * Manually put the mode-line constructs
;;
;;     (:eval (breadcrumb-imenu-crumbs))
;;
;;   and
;;
;;     (:eval (breadcrumb-project-crumbs))
;;
;;  in your settings of the `mode-line-format' or
;;  `header-line-format' variables.
;;
;; The shape and size of each breadcrumb groups may be tweaked via
;; `breadcrumb-imenu-max-length', `breadcrumb-project-max-length',
;; `breadcrumb-imenu-crumb-separator', and
;; `breadcrumb-project-crumb-separator'.
;;
;; The structure each the breadcrumbs varies depending on whether
;; either project.el and imenu.el (or both) can do useful things for
;; your buffer.
;;
;; For Project breadcrumbs, this depends on whether project.el's
;; `project-current' can guess what project the current buffer
;; belongs to.
;;
;; For Imenu breadcrumbs, this varies.  Depending on the major-mode
;; author's taste, the Imenu tree (in variable `imenu--index-alist')
;; may have different structure.  Sometimes, minor mode also tweak
;; the Imenu tree in useful ways.  For example, with recent Eglot (I
;; think Eglot 1.14+), managed buffers get extra region info added to
;; it, which makes Breadcrumb show "richer" paths.
;;
;;;; Implementation notes:
;;
;; This _should_ be faster than which-func.el due some caching
;; strategies.  One of these strategies occurs in `bc--ipath-alist',
;; which takes care not to over-call `imenu--make-index-alist', which
;; could be slow (in fact very slow if an external process needs to
;; be contacted).  The variable `breadcrumb-idle-delay' controls
;; that.  Another cache occurs in `bc--ipath-plain-cache' second is
;; just a simple "space-for-speed" cache.
;;
;; Breadcrumb uses the double-dashed Imenu symbols
;; `imenu--index-alist' and `imenu--make-index-alist'.  There's
;; really no official API here.  It's arguable that, despite the
;; name, these aren't really internal symbols (the much older
;; which-func.el library makes liberal use of them, for example).
;;
;;;; Todo:
;;
;; Make more clicky buttons in the headerline to do whatever
;;

;;; Code:
(require 'cl-lib)
(require 'imenu)
(require 'project)


;;;; Customization options
;;

(defgroup breadcrumb nil
  "One-liner indication of where you are in the maze."
  :prefix "breadcrumb-"
  :group 'convenience)

(defcustom bc-project-max-length 0.3
  "Soft cutoff for `breadcrumb-project-crumbs'.
If a fixnum, it's a absolute number of characters.  If a float, a
percentage of `window-width'."
  :type '(choice (natnum :tag "Number of characters")
                 (float  :tag "Percent of window's width")))

(defcustom bc-project-crumb-separator "/"
  "Separator for `breadcrumb-project-crumbs'." :type 'string)

(defcustom bc-imenu-max-length 0.3
  "Soft cutoff for `breadcrumb-imenu-crumbs'.
If a fixnum, it's a absolute number of characters.  If a float, a
percentage of `window-width'."
  :type '(choice (natnum :tag "Number of characters")
                 (float  :tag "Percent of window's width")))

(defcustom bc-imenu-crumb-separator " > "
  "Separator for `breadcrumb-project-crumbs'." :type 'string)

(defface bc-face '((t (:inherit shadow)))
  "Base face for all breadcrumb things.")

(defface bc-imenu-crumbs-face '((t (:inherit bc-face)))
  "Face for imenu crumbs in the breadcrumb imenu path.")

(defface bc-imenu-leaf-face '((t (:inherit (font-lock-function-name-face
                                            bc-imenu-crumbs-face))))
  "Face for imenu leaf crumbs in the breadcrumb imenu path.")

(defface bc-project-crumbs-face '((t (:inherit bc-face)))
  "Face for project crumbs in the breadcrumb project path.")

(defface bc-project-base-face '((t (:inherit bc-project-crumbs-face)))
  "Face for project base in the breadcrumb project path.")

(defface bc-project-leaf-face '((t (:inherit (mode-line-buffer-id))))
  "Face for the project leaf crumb in breadcrumb project path.")


;;;; "ipath" management logic and imenu interoperation
;;
(cl-defun bc--bisect (a x &key (from 0) (to (length a)) key from-end)
  "Compute index to insert X in sequence A, keeping it sorted.
If X already in A, the resulting index is the leftmost such
index, unless FROM-END is t.  KEY is as usual in other CL land."
  (cl-macrolet ((search (from-end key)
                  `(cl-loop while (< from to)
                            for mid = (/ (+ from to) 2)
                            for p1 = (elt a mid)
                            for p2 = ,(if key `(funcall key p1) `p1)
                            if (,(if from-end '< '<=) x p2)
                            do (setq to mid) else do (setq from (1+ mid))
                            finally return from)))
    (if from-end (if key (search t key) (search t nil))
      (if key (search nil key) (search nil nil)))))

(defun bc--ipath-rich (index-alist pos)
  "Compute ipath for rich `imenu--index-alist' structures.
These structures have a `breadcrumb-region' property on every
node."
  (cl-labels
      ((search (nodes &optional ipath)
         (cl-loop
          for n in nodes
          for reg = (and (consp n) (stringp (car n))
                         (get-text-property 0 'breadcrumb-region (car n)))
          when (and reg (<= (car reg) pos (cdr reg)))
          return (search (and (imenu--subalist-p n) (cdr n))
                         (cons (propertize (car n)
                                           'breadcrumb-siblings nodes
                                           'breadcrumb-parent (car ipath))
                               ipath))
          finally (cl-return ipath))))
    (nreverse (search index-alist))))

(defvar-local bc--ipath-plain-cache nil
  "Cons of the source Imenu index and its sorted breadcrumb positions.")

(defun bc--ipath-plain (index-alist pos)
  "Compute ipath for plain `imenu--index-alist' structures.
These structures don't have a `breadcrumb-region' property on."
  (unless (eq index-alist (car bc--ipath-plain-cache))
    (let (positions)
      (cl-labels ((collect (nodes path)
                    (dolist (node nodes)
                      (when (and (consp node) (stringp (car node)))
                        (if (imenu--subalist-p node)
                            (collect (cdr node) (cons (car node) path))
                          (let ((position (if (consp (cdr node)) (cadr node) (cdr node))))
                            (when (and (number-or-marker-p position)
                                       (or (not (markerp position)) (marker-position position))
                                       (> position 0))
                              (push (cons position (cons (propertize (car node)
                                                                   'breadcrumb-siblings (cdr nodes))
                                                        path))
                                    positions))))))))
        (collect index-alist nil))
      (setq bc--ipath-plain-cache
            (cons index-alist (vconcat (cl-stable-sort (nreverse positions) #'< :key #'car))))))
  (when-let* ((positions (cdr bc--ipath-plain-cache))
              (index (bc--bisect positions pos :key #'car :from-end t))
              ((> index 0)))
    (reverse (cdr (aref positions (1- index))))))

(defun bc-ipath (index-alist pos)
  "Get breadcrumb for position POS given INDEX-ALIST."
  (let ((first (cl-find-if (lambda (node)
                             (and (consp node) (stringp (car node))
                                  (not (eq node imenu--rescan-item))))
                           index-alist)))
    (if (and first (get-text-property 0 'breadcrumb-region (car first)))
        (bc--ipath-rich index-alist pos)
      (bc--ipath-plain index-alist pos))))

(defvar bc-idle-time 1
  "Control idle time before requesting new breadcrumbs.")

(defvar-local bc--idle-timer nil
  "Timer used by `breadcrumb--ipath-alist'.")

(defvar-local bc--last-update-tick 0
  "Last time `breadcrumb--ipath-alist' asked for an update.")

(defvar-local bc-imenu-index-function nil
  "Optional function to build Breadcrumb's Imenu index while idle.
The function must return an Imenu index and can choose a local provider.
Nil leaves index creation and reuse to Imenu.")

(defvar-local bc--owned-index nil
  "Index created by `breadcrumb-imenu-index-function', when set.")

(defun bc--ipath-alist ()
  "Return `imenu--index-alist', maybe arrange for its update."
  (let ((nochangep (eql (buffer-chars-modified-tick) bc--last-update-tick))
        (buf (current-buffer)))
    (unless nochangep
      (setq bc--last-update-tick (buffer-chars-modified-tick))
      (when bc--idle-timer (cancel-timer bc--idle-timer))
      (setq bc--idle-timer
            (run-with-idle-timer
             bc-idle-time nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq bc--idle-timer nil)
                   (let ((visible (get-buffer-window buf 'visible)))
                     (if (and bc-imenu-index-function (not visible))
                         (setq bc--last-update-tick nil)
                       (setq bc--last-update-tick (buffer-chars-modified-tick))
                       (let ((non-essential t)
                             (imenu-auto-rescan t))
                         (if bc-imenu-index-function
                             (setq bc--owned-index (ignore-errors (funcall bc-imenu-index-function)))
                           (ignore-errors (imenu--make-index-alist t))))
                       (setq bc--ipath-plain-cache nil)
                       (when visible (force-mode-line-update))))))))))
    (if bc-imenu-index-function bc--owned-index imenu--index-alist)))

(defun bc-imenu-path (&optional position)
  "Return the cached Imenu path at POSITION, or point if omitted."
  (when-let* ((index (bc--ipath-alist)))
    (bc-ipath index (or position (point)))))


;;;; Higher-level functions
;;

;; FIXME: Why do I need to put these key definitiosn in special
;; variables?
(defvar bc--header-line-key [header-line mouse-1])
(defvar bc--mode-line-key [mode-line mouse-1])

(defun bc--length (len)
  "Interpret LEN using `window-width' and return a number."
  (cond ((floatp len) (* (window-width) len))
        (t len)))

(defun bc--format-ipath-node (p more)
  (let* ((l (lambda (&rest _event)
              (interactive)
              ;; TODO: This is a bit inadequate if the user is
              ;; clicking the mode or header lines, but 'event' seems
              ;; to be missing in these cases.  We would to
              ;; conveniently visit places near the node `p' via the
              ;; mouse
              (breadcrumb-jump))))
    (propertize
     p 'mouse-face 'header-line-highlight
     'face (if more 'bc-imenu-crumbs-face 'bc-imenu-leaf-face)
     'bc-dont-shorten (null more)
     'help-echo (format "mouse-1: Go places near %s" p)
     'keymap
     (let ((m (make-sparse-keymap)))
       (define-key m bc--header-line-key l)
       (define-key m bc--mode-line-key l)
       m))))

;;;###autoload
(defun breadcrumb-imenu-crumbs ()
  "Describe point inside the Imenu tree of current file."
  (when-let* ((path (bc-imenu-path)))
    (bc--summarize
     (cl-loop for (p . more) on path collect (bc--format-ipath-node p more))
     (bc--length bc-imenu-max-length)
     (propertize bc-imenu-crumb-separator 'face 'bc-face))))

(defun bc--summarize (crumbs cutoff separator)
  "Return a string that summarizes CRUMBS, a list of strings.
\"Summarization\" consists of truncating some CRUMBS to 1
character.  Rightmost members of CRUMBS are summarized last.
Members with a `breadcrumb-dont-shorten' are never truncated.
Aim for a return string that is at most CUTOFF characters long.
Join the crumbs with SEPARATOR."
  (let ((rcrumbs
         (cl-loop
          for available = (- cutoff used)
          for (c . more) on (reverse crumbs)
          for seplen = (if more (length separator) 0)
          for shorten-p = (unless (get-text-property 0 'bc-dont-shorten c)
                            (> (+ (length c) seplen) available))
          for toadd = (if shorten-p (substring c 0 1) c)
          sum (+ (length toadd) seplen) into used
          collect toadd)))
    (string-join (reverse rcrumbs) separator)))

(defun bc--format-project-node (p more path)
  "Helper for `bc--project-crumbs-1'.
Format path crumb P given optional MORE nodes and its absolute PATH."
  (let ((l (lambda (&rest _event)
             (interactive)
             ;; TODO: See similar TODO in `bc--format-ipath-node'.
             (find-file (file-name-directory path)))))
    (propertize p 'face
                (if more 'bc-project-crumbs-face 'bc-project-leaf-face)
                'bc-dont-shorten (null more)
                'mouse-face 'header-line-highlight
                'help-echo (format "mouse-1: Go places near %s" path)
                'keymap
                (let ((m (make-sparse-keymap)))
                  (define-key m bc--header-line-key l)
                  (define-key m bc--mode-line-key l)
                  m))))

(defun bc-file-components (file root)
  "Return the (NAME . PATH) pairs from ROOT to FILE.
The PATH of each directory ends with a slash."
  (let* ((base (file-name-as-directory (expand-file-name root)))
         (name (file-name-nondirectory (directory-file-name base)))
         (parts (split-string (file-relative-name file base) "/" t))
         (path base)
         (result (list (cons (if (string-empty-p name) base name) base))))
    (while parts
      (let ((part (pop parts)))
        (unless (equal part ".")
          (setq path (expand-file-name part path))
          (when (or parts (directory-name-p file)) (setq path (file-name-as-directory path)))
          (push (cons part path) result))))
    (nreverse result)))

(defun bc--project-crumbs-1 (bfn)
  "Return propertized project crumbs for BFN."
  (let* ((project (project-current))
         (root (if project (project-root project) default-directory))
         (components (bc-file-components (or bfn default-directory) root)))
    (cons (propertize (caar components) 'bc-dont-shorten t 'face 'bc-project-base-face)
          (cl-loop for (component . more) on (cdr components)
                   collect (bc--format-project-node (car component) more (cdr component))))))

;;;###autoload
(cl-defun breadcrumb-project-crumbs ()
  "Describing the current file inside project."
  (bc--summarize
   (if buffer-file-name (bc--project-crumbs-1 buffer-file-name)
     (list (propertize (buffer-name) 'face 'bc-project-leaf-face)))
   (bc--length bc-project-max-length)
   (propertize bc-project-crumb-separator
               'face 'bc-project-crumbs-face)))

(defun bc--header-line ()
  "Helper for `breadcrumb-headerline-mode'."
  (let ((x (cl-remove-if
            #'seq-empty-p (mapcar #'funcall
                                  '(bc-project-crumbs bc-imenu-crumbs)))))
    (mapconcat #'identity x (propertize " : " 'face 'bc-face))))

;;;###autoload
(define-minor-mode breadcrumb-local-mode
  "Header lines with breadcrumbs."
  :init-value nil
  (if bc-local-mode (add-to-list 'header-line-format '(:eval (bc--header-line)))
    (setq header-line-format (delete '(:eval (bc--header-line)) header-line-format))))

(defun bc--turn-on-local-mode-on-behalf-of-global-mode ()
  (unless (or (minibufferp)
              (not (buffer-file-name))
              (null (bc-project-crumbs)))
    (bc-local-mode 1)))

;;;###autoload
(define-globalized-minor-mode breadcrumb-mode bc-local-mode
  bc--turn-on-local-mode-on-behalf-of-global-mode)

(require 'pulse)
(defun bc--goto (window pos)
  "Helper for `breadcrumb-jump'."
  (with-selected-window window
    (with-current-buffer (window-buffer)
      (push-mark)
      (goto-char pos)
      (let ((pulse-delay 0.05) (pulse-flag t))
        (pulse-momentary-highlight-region (line-beginning-position) (line-end-position))))))

;;;###autoload
(defun breadcrumb-jump ()
  "Like \\[execute-extended-command] `imenu', but breadcrumb-powered."
  (interactive)
  (let (cands choice)
    (cl-labels
        ((fmt (strs)
           (mapconcat #'identity strs " > "))
         (dfs (nodes &optional ipath)
           (cl-loop
            for n in nodes
            for newpath = (cons (car n) ipath)
            for pos = (or (car (get-text-property 0 'breadcrumb-region (car n)))
                          (and (number-or-marker-p (cdr n)) (cdr n)))
            when pos do (push (cons (fmt (reverse newpath)) pos)
                              cands)
            do (dfs (cdr n) newpath))))
      (imenu--make-index-alist)
      (dfs imenu--index-alist)
      (unless cands (user-error "Sorry, no breadcrumb items to jump to"))
      (setq choice (cdr (assoc (completing-read "Index item? " cands nil t)
                               cands #'string=)))
      (push-mark)
      (bc--goto (selected-window) choice))))

(provide 'breadcrumb)
;;; breadcrumb.el ends here

;; Local Variables:
;; read-symbol-shorthands: (("bc-" . "breadcrumb-"))
;; End:
