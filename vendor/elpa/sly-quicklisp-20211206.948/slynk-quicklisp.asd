;;; -*- lisp -*-
;;; Modificato da GDev il 15 novembre 2026 per caricare Quicklisp alla richiesta.
(in-package :asdf)

(defsystem :slynk-quicklisp
    :author "João Távora <https://github.com/capitaomorte>"
    :depends-on (#:slynk)
  :description "Basic QUICKLISP support for Slynk"
  :components ((:file "slynk-quicklisp")))

;; Local Variables:
;; coding: utf-8
;; End:
