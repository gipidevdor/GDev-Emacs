;;; gdev-architecture-test.el --- Confini fra nucleo e adattatori -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Legge le forme senza valutarle. I require differiti non sono archi
;; dell'avvio: restano verificati dai flussi e dalla compilazione a freddo.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'gdev-agent-interface)

(defun gdev-test-architecture--requires (form)
  "Trova i require letterali eseguiti durante il caricamento di FORM."
  (when (consp form)
    (pcase (car form)
      ('require (when (and (eq (car-safe (cadr form)) 'quote) (symbolp (cadadr form)))
                  (list (cadadr form))))
      ((or 'quote 'function 'lambda 'defun 'cl-defun 'defmacro 'cl-defmacro
           'define-derived-mode 'define-minor-mode 'with-eval-after-load 'eval-after-load
           'eval-when-compile) nil)
      (_ (nconc (gdev-test-architecture--requires (car form))
                (gdev-test-architecture--requires (cdr form)))))))

(defun gdev-test-architecture--graph ()
  "Leggi proprietari delle feature e dipendenze dei sorgenti distribuiti."
  (let* ((files (append (directory-files (gdev-config-file "lisp") t "\\.el\\'")
                        (directory-files-recursively (gdev-config-file "modules") "\\.el\\'")))
         (owners (make-hash-table :test #'eq))
         (edges (make-hash-table :test #'equal)) dependencies duplicates)
    (dolist (file files)
      (let (requires)
        (gdev-agent-interface--read
         file (lambda (form _line)
                (when (and (eq (car-safe form) 'provide) (eq (car-safe (cadr form)) 'quote))
                  (let* ((feature (cadadr form)) (prior (gethash feature owners)))
                    (when (and prior (not (equal prior file))) (push (list feature prior file) duplicates))
                    (puthash feature file owners)))
                (setq requires (append requires (gdev-test-architecture--requires form)))))
        (push (cons file requires) dependencies)))
    (dolist (entry dependencies)
      (puthash (car entry) (delete-dups (delq nil (mapcar (lambda (feature) (gethash feature owners)) (cdr entry)))) edges))
    (list :files files :owners owners :edges edges :duplicates duplicates)))

(defun gdev-test-architecture--cycle (edges)
  "Restituisci un ciclo di EDGES, oppure nil se il grafo è aciclico."
  (let ((colors (make-hash-table :test #'equal)))
    (catch 'cycle
      (cl-labels ((visit (node path)
                    (pcase (gethash node colors)
                      ('visiting (throw 'cycle (reverse (cons node path))))
                      ('done nil)
                      (_ (puthash node 'visiting colors)
                         (dolist (next (gethash node edges)) (visit next (cons node path)))
                         (puthash node 'done colors)))))
        (maphash (lambda (node _) (visit node nil)) edges))
      nil)))

(ert-deftest gdev-test-architecture-features-have-one-owner ()
  (should-not (plist-get (gdev-test-architecture--graph) :duplicates)))

(ert-deftest gdev-test-architecture-static-action-icons-are-included ()
  (let (references)
    (cl-labels ((inspect (form file line)
                  (when (consp form)
                    (pcase (car form)
                      ('gdev-ui-icon (when (stringp (cadr form)) (push (list (cadr form) file line) references)))
                      ('gdev-set-tool-actions (when (stringp (nth 3 form)) (push (list (nth 3 form) file line) references)))
                      ((or 'gdev-ui-insert-actions 'gdev-assurance--actions)
                       (when (eq (car-safe (cadr form)) 'quote)
                         (dolist (action (cadadr form))
                           (when (stringp (car-safe action)) (push (list (car action) file line) references))))))
                    (inspect (car form) file line) (inspect (cdr form) file line))))
      (dolist (file (plist-get (gdev-test-architecture--graph) :files))
        (gdev-agent-interface--read file (lambda (form line) (inspect form file line)))))
    (should references)
    (dolist (entry references)
      (ert-info ((format "%s:%s · icona %s" (nth 1 entry) (nth 2 entry) (car entry)))
        (should (file-readable-p (gdev-config-file (format "icons/%s.svg" (car entry)))))))))

(ert-deftest gdev-test-architecture-load-dependencies-have-no-cycles ()
  (let ((cycle (gdev-test-architecture--cycle (plist-get (gdev-test-architecture--graph) :edges))))
    (ert-info ((format "Ciclo di caricamento: %S" cycle)) (should-not cycle))))

(ert-deftest gdev-test-architecture-check-distinguishes-load-and-deferred-dependencies ()
  (should (equal '(immediate conditional)
                 (gdev-test-architecture--requires
                  '(progn (require 'immediate) (when enabled (require 'conditional))
                          (defun later () (require 'later))
                          (with-eval-after-load 'package (require 'after))
                          (funcall (lambda () (require 'callback)))))))
  (let ((edges (make-hash-table :test #'equal)))
    (puthash "first" '("second") edges)
    (should-not (gdev-test-architecture--cycle edges))
    (puthash "second" '("first") edges)
    (should (gdev-test-architecture--cycle edges))))

(ert-deftest gdev-test-architecture-assurance-domain-does-not-load-the-editor ()
  (let* ((graph (gdev-test-architecture--graph)) (edges (plist-get graph :edges))
         (directory (gdev-config-file "lisp/")))
    (dolist (root (plist-get graph :files))
      (when (and (string-prefix-p directory root)
                 (string-match-p "/gdev-\\(?:assurance\\|assessment\\|process\\|evidence\\|policy\\|gates\\|controls\\|standards?\\|decisions\\|records\\|capability\\|trace\\|adoption\\|documents\\)\\(?:-[^/]+\\)?\\.el\\'" root)
                 (not (string-suffix-p "/gdev-assurance-workspace.el" root)))
        (let ((seen (make-hash-table :test #'equal)))
          (cl-labels ((visit (file)
                        (unless (gethash file seen)
                          (puthash file t seen)
                          (ert-info ((format "Il dominio %s dipende da %s" root file))
                            (should (string-prefix-p directory file))
                            (should-not (member (file-name-base file)
                                                '("gdev-workspace-state" "gdev-modules" "gdev-commands" "gdev-cli" "gdev-agent-interface"))))
                          (mapc #'visit (gethash file edges)))))
            (visit root)))))))

(ert-deftest gdev-test-architecture-assurance-views-do-not-handle-sql-connections ()
  (dolist (relative '("modules/ui/workbench/gdev-assurance-workbench.el"
                      "modules/ui/workbench/gdev-assurance-interactive.el"))
    (gdev-agent-interface--read
     (gdev-config-file relative)
     (lambda (form line)
       (cl-labels ((inspect (value)
                     (cond ((consp value) (inspect (car value)) (inspect (cdr value)))
                           ((vectorp value) (mapc #'inspect value))
                           ((symbolp value)
                            (ert-info ((format "%s:%s · %s" relative line value))
                              (should-not (string-match-p
                                           "\\`\\(?:sqlite-\\|gdev-assurance-db-\\(?:open\\|with-open\\|select\\|read-transaction\\)\\|gdev-assurance-call-with-reader\\|gdev-standard-selection\\|gdev-record-data\\)"
                                           (symbol-name value))))))))
         (inspect form))))))

;;; gdev-architecture-test.el ends here
