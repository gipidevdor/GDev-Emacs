(defpackage #:slynk-quicklisp
  (:use :cl #:slynk-api)
  (:export
   #:available-p
   #:quickload
   #:available-system-names))
(in-package #:slynk-quicklisp)

;; GDev-Emacs, 2026-11-15: the REPL starts without Quicklisp. Load it
;; only when the user invokes the integration.
(defslyfun available-p ()
  (not (null (or (find-package "QL") (asdf:find-system "quicklisp" nil)))))

(defun ensure-quicklisp ()
  (unless (find-package "QL")
    (asdf:load-system "quicklisp")))

(defslyfun quickload (system-name)
  "Basically the same as QL:QUICKLOAD"
  (ensure-quicklisp)
  (uiop:symbol-call "QL" "QUICKLOAD" system-name)
  (mapcar (lambda (dist) (uiop:symbol-call "QL-DIST" "VERSION" dist))
          (uiop:symbol-call "QL-DIST" "ENABLED-DISTS")))

(defslyfun available-system-names ()
  (ensure-quicklisp)
  (mapcar (lambda (system) (uiop:symbol-call "QL-DIST" "NAME" system))
          (uiop:symbol-call "QL" "SYSTEM-LIST")))

(provide 'slynk-quicklisp)
