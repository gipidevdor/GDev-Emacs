;;; gdev-graph-test.el --- Modelli indipendenti dei grafi -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Oracolo matriciale indipendente, catene profonde e integrità degli input.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'gdev-graph)
(require 'gdev-project)

(ert-deftest gdev-test-project-graph-deep-chains-and-cycle-witness ()
  "Ventimila livelli non consumano la pila Lisp; il ciclo restituito è reale."
  (let ((adjacency (make-hash-table :test #'equal)) (max-lisp-eval-depth 100)
        (nodes (number-sequence 0 19999)))
    (dotimes (index 19999) (puthash index (list (1+ index)) adjacency))
    (should-not (gdev-graph-cycle nodes adjacency))
    (should (= 20000 (hash-table-count (gdev-graph-reachable adjacency '(0 0)))))
    (puthash 19999 '(19997) adjacency)
    (should (equal '(19997 19998 19999 19997) (gdev-graph-cycle nodes adjacency)))
    (should (equal '(1) (gethash 0 adjacency)))))

(ert-deftest gdev-test-project-graph-matches-independent-transitive-closure ()
  "La visita coincide con una chiusura matriciale indipendente su 32 grafi."
  (dotimes (case 32)
    (let* ((size 8) (nodes (number-sequence 0 (1- size)))
           (matrix (vconcat (cl-loop repeat size collect (make-vector size nil))))
           (adjacency (make-hash-table :test #'equal)))
      (dotimes (from size)
        (dotimes (to size)
          (when (and (or (cl-oddp case) (< from to))
                     (zerop (mod (+ (* from 17) (* to 13) (* case 7) (* from to)) 5)))
            (aset (aref matrix from) to t)
            (push to (gethash from adjacency)))))
      (dotimes (via size)
        (dotimes (from size)
          (dotimes (to size)
            (when (and (aref (aref matrix from) via) (aref (aref matrix via) to))
              (aset (aref matrix from) to t)))))
      (dolist (seed nodes)
        (let ((actual (gdev-graph-reachable adjacency (list seed seed))))
          (dolist (target nodes)
            (should (eq (and (gethash target actual) t)
                        (and (or (= seed target) (aref (aref matrix seed) target)) t))))))
      (let ((cycle (gdev-graph-cycle nodes adjacency)))
        (should (eq (and cycle t) (cl-some (lambda (node) (aref (aref matrix node) node)) nodes)))
        (when cycle
          (should (equal (car cycle) (car (last cycle))))
          (cl-loop for (from to) on cycle while to
                   do (should (member to (gethash from adjacency)))))))))

(ert-deftest gdev-test-project-graph-empty-duplicate-and-nil-nodes ()
  "Nodi falsi, isolati, ripetuti e componenti distinte restano validi."
  (let ((adjacency (make-hash-table :test #'equal)))
    (should-not (gdev-graph-cycle nil adjacency))
    (should (zerop (hash-table-count (gdev-graph-reachable adjacency nil))))
    (should-not (gdev-graph-cycle '(nil nil isolated) adjacency))
    (puthash nil '(next next) adjacency)
    (puthash 'next '(nil) adjacency)
    (should (equal '(nil next nil) (gdev-graph-cycle '(nil isolated) adjacency)))
    (should (= 2 (hash-table-count (gdev-graph-reachable adjacency '(nil nil)))))))

(ert-deftest gdev-test-project-validates-deep-dependencies-without-recursion ()
  "L'indice del progetto non ricerca ogni dipendenza nell'intera lista."
  (gdev-test-assurance--with-root root
    (let* ((data (gdev-test-project--fixture root))
           (prototype (car (plist-get data :requirements)))
           (count 2000))
      (setf (plist-get data :requirements)
            (cl-loop for number from 1 to count collect
                     (let ((row (copy-tree prototype)))
                       (setf (plist-get row :id) (format "DEEP-%d" number)
                             (plist-get row :depends-on)
                             (when (< number count) (list (format "DEEP-%d" (1+ number)))))
                       row)))
      (let ((max-lisp-eval-depth 100)) (should (eq data (gdev-project-validate data))))
      (setf (plist-get (car (last (plist-get data :requirements))) :depends-on) '("DEEP-1"))
      (should-error (gdev-project-validate data) :type 'gdev-process-refused))))

(ert-deftest gdev-test-project-imported-taxonomy-validates-deep-parent-chains-once ()
  "L'importazione valida la gerarchia con una sola visita dell'indice."
  (gdev-test-assurance--with-root root
    (let* ((gdev-standards-directory root) (count 2000)
           (nodes (vconcat (cl-loop for number from 1 to count collect
                                   `((id . ,(format "N%d" number)) (title . "Nodo")
                                     (kind . "clause") (locator . "Fixture")
                                     (parent . ,(if (< number count) (format "N%d" (1+ number)) :null))))))
           (file (expand-file-name "standard/indici-fonti.json" root))
           (check (symbol-function 'gdev-graph-cycle)) (calls 0))
      (make-directory (file-name-directory file) t)
      (cl-labels ((write-index ()
                    (with-temp-file file
                      (insert (json-serialize `((schema_version . 1)
                                               (taxonomies . [((id . "deep") (nodes . ,nodes) (sources . []))]))
                                              :null-object :null)))))
        (write-index)
        (cl-letf (((symbol-function 'gdev-graph-cycle)
                   (lambda (&rest arguments) (cl-incf calls) (apply check arguments))))
          (let ((max-lisp-eval-depth 100))
            (should (= count (length (alist-get 'nodes (gdev-taxonomy--imported "deep")))))))
        (should (= calls 1))
        (setf (alist-get 'parent (aref nodes (1- count))) "N1")
        (write-index)
        (should-error (gdev-taxonomy--imported "deep") :type 'user-error)
        (setf (alist-get 'parent (aref nodes (1- count))) "missing")
        (write-index)
        (should-error (gdev-taxonomy--imported "deep") :type 'user-error)))))

(ert-deftest gdev-test-project-source-inventory-shares-one-output-index ()
  "Inventario e filtro usano la stessa politica, senza ricostruire le uscite per file."
  (gdev-test-assurance--with-root root
    (let* ((data '(:source-roots ("src") :artifacts ((:path "src/generated.el"))))
           (outputs (symbol-function 'gdev-project-output-paths)) (calls 0))
      (make-directory (expand-file-name "src" root))
      (dolist (path '("src/a.el" "src/b.el" "src/generated.el" "src/a.elc"))
        (write-region "Fixture" nil (expand-file-name path root) nil 'silent))
      (cl-letf (((symbol-function 'gdev-project-output-paths)
                 (lambda (definition) (cl-incf calls) (funcall outputs definition))))
        (should (equal '("src/a.el" "src/b.el")
                       (mapcar (lambda (row) (alist-get 'path row))
                               (append (gdev-project-source-inventory root data) nil)))))
      (should (= 1 calls))
      (let ((select (gdev-project-source-selector data)))
        (dolist (path '("src/a.el" "src/nested/c.txt")) (should (funcall select path)))
        (dolist (path '("src/generated.el" "src/a.elc" "src/__pycache__/x" "elsewhere/a.el"))
          (should-not (funcall select path)))))))

(ert-deftest gdev-test-project-source-collections-do-not-mutate-definition ()
  "Raccolta, deduplicazione e ordinamento non modificano liste del manifesto."
  (let* ((data '(:source-files ("z" "a") :requirements ((:sources ("y" "b")))
                :procedures ((:outputs ("out-z" "out-a")
                              :steps ((:plan "plan" :inputs ("x" "c") :outputs ("step-z" "step-a")))))
                :snippets ((:template "template"))
                :artifacts ((:path "artifact" :sources ("v" "d")))))
         (snapshot (copy-tree data)))
    (cl-letf (((symbol-function 'gdev-project-file-fingerprint)
               (lambda (_ path) `((path . ,path)))))
      (let ((inputs (gdev-project-inputs "/fixture/" data)))
        (should (equal '(".gdev-assurance/project.eld" "a" "b" "c" "d" "plan" "template" "v" "x" "y" "z")
                       (mapcar (lambda (row) (alist-get 'path row)) (append inputs nil))))))
    (should (equal snapshot data))
    (let ((outputs (gdev-project-output-paths data)))
      (should (equal '("artifact" "out-z" "out-a" "step-z" "step-a") outputs))
      (setcar (nthcdr 4 outputs) "changed"))
    (should (equal snapshot data))))

(provide 'gdev-graph-test)
;;; gdev-graph-test.el ends here
