;;; config.el --- :lang common-lisp: SLY e l'immagine Lisp viva -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Common Lisp si sviluppa dentro un'immagine Lisp in esecuzione, tramite
;; SLY: il codice si compila e si prova senza mai riavviare il programma.
;;
;;   C-c o r        avvia o mostra SBCL e il suo interprete interattivo
;;   C-c C-c        compila la forma di primo livello sotto il cursore
;;   C-c C-k        compila e carica il file
;;   C-c c k        voce della HyperSpec per il simbolo; in locale se installata
;;   C-c l m        espande la macro sotto il cursore, un passo alla volta
;;   C-c l p / P    profilazione statistica di CPU / allocazioni della forma
;;                  prima del cursore (sb-sprof); C-c P P fa lo stesso
;;   C-c l t        misura il tempo della forma prima del cursore
;;   C-c l l / q    carica un sistema ASDF / una libreria con Quicklisp
;;
;; Gli errori aprono il sistema di diagnosi di SLY: riavvii, livelli della
;; pila, variabili locali, ispezione, ritorno da qualunque
;; livello.  Gli adesivi (C-c C-s C-s) registrano i valori che
;; attraversano un'espressione senza modificare il codice.  La modifica
;; strutturale del codice è in editor/paredit.

;;; Code:

(require 'cl-lib)
(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)

(declare-function sly-symbol-completion-mode "sly-completion" (&optional arg))

;;;; Implementazioni

(defun gdev-cl-implementations ()
  "Restituisce `sly-lisp-implementations' per i Lisp installati qui."
  (cl-loop for (name program . arguments)
           in '((sbcl "sbcl" "--dynamic-space-size" "4096")
                (ccl "ccl64")
                (ecl "ecl"))
           when (executable-find program)
           collect (list name (cons program arguments) :coding-system 'utf-8-unix)))

(gdev-doctor-executable "sbcl" "brew install sbcl")

;;;; SLY

(use-package sly
  :ensure t
  :commands (sly sly-connected-p sly-eval-region sly-hyperspec-lookup)
  :custom
  (sly-default-lisp 'sbcl)
  (sly-net-coding-system 'utf-8-unix)
  (sly-kill-without-query-p t)
  (sly-mrepl-history-file-name (gdev-state-file "sly-mrepl-history"))
  (sly-complete-symbol-function #'sly-flex-completions)
  :config
  (setq sly-lisp-implementations (gdev-cl-implementations))
  ;; Completamento con corfu come in ogni altro buffer, non con il menu a
  ;; comparsa (popup) di SLY.
  (sly-symbol-completion-mode -1)
  ;; HyperSpec locale (offline) quando è installato il sistema "clhs" di
  ;; Quicklisp, che lo script di preparazione (bootstrap) aggiunge; si legge
  ;; dentro Emacs con eww.
  (when-let* ((root (car (file-expand-wildcards
                          (expand-file-name "~/quicklisp/dists/quicklisp/software/clhs-*/HyperSpec-*/HyperSpec/")))))
    (setq common-lisp-hyperspec-root (concat "file://" root))
    (require 'browse-url)
    (add-to-list 'browse-url-handlers '("/HyperSpec/" . eww-browse-url))))
(defvar sly-lisp-implementations)
(defvar common-lisp-hyperspec-root)

;; I moduli aggiuntivi (contrib) si registrano da soli in SLY, una volta
;; installati.
(use-package sly-asdf :ensure t)        ; carica e testa i sistemi ASDF
(use-package sly-quicklisp :ensure t)   ; carica librerie con Quicklisp dal REPL
(use-package sly-macrostep :ensure t)   ; macrostep per Common Lisp

(use-package macrostep
  :ensure t
  :commands macrostep-expand)

;;;; Gestori (handler)

(declare-function sly-connected-p "sly")
(declare-function sly-mrepl "sly-mrepl")
(declare-function sly-last-expression "sly")
(declare-function sly-interactive-eval "sly")

(defun gdev-cl-repl ()
  "Restituisce il REPL del Lisp in esecuzione; avvia SBCL se non ce n'è uno."
  (require 'sly)
  (if (sly-connected-p)
      (sly-mrepl #'ignore)
    ;; L'avvio è asincrono: SLY mostra il REPL appena si connette.
    (sly)
    nil))

(defun gdev-cl-documentation ()
  "Apre la voce della HyperSpec per il simbolo sotto il cursore."
  (call-interactively #'sly-hyperspec-lookup))

(defun gdev-cl--eval-wrapped (template)
  "Valuta la forma prima del cursore dentro TEMPLATE (stringa di formato)."
  (require 'sly)
  (sly-interactive-eval (format template (sly-last-expression))))

(defun gdev-cl-profile-cpu ()
  "Profila in modo statistico la CPU della forma prima del cursore.
Il rapporto appare nel REPL."
  (interactive)
  (gdev-cl--eval-wrapped
   "(progn (require :sb-sprof) (sb-sprof:with-profiling (:max-samples 100000 :mode :cpu :report :flat) %s))"))

(defun gdev-cl-profile-alloc ()
  "Profila le allocazioni di memoria della forma prima del cursore.
Il rapporto appare nel REPL."
  (interactive)
  (gdev-cl--eval-wrapped
   "(progn (require :sb-sprof) (sb-sprof:with-profiling (:max-samples 100000 :mode :alloc :report :flat) %s))"))

(defun gdev-cl-time ()
  "Esegue la forma prima del cursore sotto `time'.
Riporta il tempo di esecuzione, quello della raccolta della memoria
\(garbage collection) e i byte allocati (consed)."
  (interactive)
  (gdev-cl--eval-wrapped "(time %s)"))

(gdev-set-repl 'lisp-mode #'gdev-cl-repl)
(gdev-set-eval 'lisp-mode #'sly-eval-region)
(gdev-set-documentation 'lisp-mode #'gdev-cl-documentation)
(gdev-set-profiler 'lisp-mode #'gdev-cl-profile-cpu)

(gdev-set-popup-rule "\\`\\*sly-\\(mrepl\\|db\\|inspector\\)"
                     :select t)
(gdev-set-popup-rule "\\`\\*sly-\\(description\\|compilation\\)")

;;;; Tasti del linguaggio (localleader)

(gdev-localleader lisp-mode lisp-mode-map
  "m" "espandi macro" #'macrostep-expand
  "p" "profila la CPU" #'gdev-cl-profile-cpu
  "P" "profila allocazioni" #'gdev-cl-profile-alloc
  "t" "misura il tempo" #'gdev-cl-time
  "l" "carica sistema ASDF" 'sly-asdf-load-system
  "q" "carica una libreria con Quicklisp" 'sly-quickload
  "h" "cerca nella HyperSpec" #'sly-hyperspec-lookup
  "i" "ispeziona" 'sly-inspect)

;;; config.el ends here
