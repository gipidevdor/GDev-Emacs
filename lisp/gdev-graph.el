;;; gdev-graph.el --- Visite iterative dei grafi di progetto -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Primitive senza editor, filesystem o SQL. I nodi usano uguaglianza `equal';
;; le liste di adiacenza sono lette senza modificarle. Le visite sono lineari
;; nei nodi, negli archi raggiunti e negli elementi iniziali, anche ripetuti.
;;; Code:
(defun gdev-graph-reachable (adjacency seeds)
  "Restituisci la tabella dei nodi raggiungibili da SEEDS in ADJACENCY.
La visita registra i nodi prima di accodarli: con S semi costa O(S + V + E)
atteso e occupa O(V), anche con cicli e archi ripetuti."
  (let ((seen (make-hash-table :test #'equal)) stack)
    (dolist (node seeds)
      (unless (gethash node seen)
        (puthash node t seen)
        (push node stack)))
    (while stack
      (dolist (next (gethash (pop stack) adjacency))
        (unless (gethash next seen)
          (puthash next t seen)
          (push next stack))))
    seen))

(defun gdev-graph-cycle (nodes adjacency)
  "Restituisci un ciclo chiuso fra NODES in ADJACENCY, oppure nil.
Rispetta l'ordine dei nodi e dei vicini. Una visita a tre colori usa una
pila esplicita, senza dipendere dalla profondità di valutazione Lisp."
  (let ((colors (make-hash-table :test #'equal)))
    (catch 'cycle
      (dolist (root nodes)
        (unless (gethash root colors)
          (puthash root 'active colors)
          (let ((stack (list (cons root (gethash root adjacency)))))
            (while stack
              (let* ((frame (car stack)) (neighbors (cdr frame)))
                (if (not neighbors)
                    (progn (puthash (car frame) 'done colors) (pop stack))
                  (setcdr frame (cdr neighbors))
                  (let* ((next (car neighbors)) (color (gethash next colors)))
                    (cond
                     ((eq color 'active)
                      (throw 'cycle
                             (let ((path (list next)))
                               (catch 'closed
                                 (dolist (ancestor stack)
                                   (push (car ancestor) path)
                                   (when (equal (car ancestor) next) (throw 'closed path)))))))
                     ((not color)
                      (puthash next 'active colors)
                      (push (cons next (gethash next adjacency)) stack))))))))))
      nil)))

(provide 'gdev-graph)
;;; gdev-graph.el ends here
