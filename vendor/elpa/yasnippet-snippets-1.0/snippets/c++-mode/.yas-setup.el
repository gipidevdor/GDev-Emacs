;;; .yas-setup.el --- Supporto dei frammenti C++ -*- lexical-binding: nil; -*-

;; Modificato da GDev-Emacs il 2026-11-15: descrizione del file di supporto in italiano.

(require 'yasnippet)

(defun yas-c++-class-name (str)
  "Search for a class name like `DerivedClass' in STR
(which may look like `DerivedClass : ParentClass1, ParentClass2, ...')

If found, the class name is returned, otherwise STR is returned"
  (yas-substr str "[^: ]*"))

(defun yas-c++-class-method-declare-choice ()
  "Choose and return the end of a C++11 class method declaration"
  (yas-choose-value '(";" " = default;" " = delete;")))
