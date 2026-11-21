;;; gdev-project-operations.el --- Contratto delle operazioni di progetto -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Un modello osservabile di contesto, prerequisiti, preparazione ed esito.
;; I motori restano responsabili delle regole dei rispettivi progetti.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'gdev-project-types)

(defconst gdev-project-operation-phases
  '((configure . :configure) (build . :build) (test . :test)
    (run . :run) (clean . :clean) (debug . :debug)))

(defconst gdev-project-operation-contracts
  '((declared "Operazioni dichiarate dal progetto" nil (configure build test run clean debug) project)
    (cmake "CMake" "cmake" (configure build test clean) metadata)
    (meson "Meson" "meson" (configure build test clean) metadata)
    (make "Make" "make" (configure build test clean) engine)
    (ninja "Ninja" "ninja" (configure build test clean) engine)
    (xcode "Xcode" "xcodebuild" (configure build test run clean debug) metadata)
    (node "Node" "npm" (build test) manifest)
    (deno "Deno" "deno" (build test) manifest)
    (perl-make "Perl MakeMaker" "perl" (configure build test clean) manifest)
    (perl-build "Perl Module::Build" "perl" (configure build test clean) manifest)
    (perl-prove "Perl" "prove" (build test) manifest)
    (asdf "Common Lisp / ASDF" "sbcl" (build test) manifest)
    (python "Python" "python3" (configure build test) language)
    (go "Go" "go" (configure build test run clean) language)
    (rust "Rust" "cargo" (configure build test run clean) language)
    (swift "Swift" "swift" (configure build test run clean) language)
    (zig "Zig" "zig" (configure build test run clean) language)
    (java "Java" nil (configure build test run clean) language)
    (csharp ".NET" "dotnet" (configure build test run clean) language))
  "Contratti tematici: tipo, nome, strumento, fasi e autorità delle regole.
Il controllo verifica che ogni tipo riconosciuto abbia un contratto.
Le fasi sono capacità del fornitore, da risolvere sul progetto concreto.")

(defun gdev-project-operation-decision (known environment available configured running &optional fresh)
  "Classifica i fatti del progetto in uno stato operativo finito.
KNOWN, AVAILABLE, CONFIGURED e RUNNING sono osservazioni, non preferenze.
FRESH nil scarta una risposta asincrona di un contesto superato."
  (cond ((not fresh) 'obsolete)
        (running 'running)
        ((not known) 'unrecognized)
        ((eq environment 'pending) 'preparing)
        ((eq environment 'failed) 'blocked)
        ((not available) 'missing-tool)
        ((not configured) 'needs-configuration)
        (t 'ready)))

(defun gdev-project-operation-result (status code stopping)
  "Classifica l'esito reale STATUS e CODE, includendo STOPPING."
  (cond ((or stopping (and (eq status 'exit) (= code 130))
             (and (eq status 'signal) (= code 2))) 'cancelled)
        ((and (eq status 'exit) (= code 0)) 'completed)
        (t 'failed)))

(defun gdev-project-operations-read (root validator)
  "Leggi i profili dichiarati in ROOT, verificandoli con VALIDATOR.
Il file è letto come dati. Una configurazione non valida non produce un
profilo parziale e non viene sostituita da deduzioni silenziose."
  (let ((file (expand-file-name gdev-project-operations-file root)))
    (when (file-exists-p file)
      (when (> (file-attribute-size (file-attributes file)) (* 128 1024))
        (user-error "Configurazione del progetto troppo grande: %s" file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let* ((read-circle nil)
               (data (condition-case failure (read (current-buffer))
                       (error (user-error "Configurazione non leggibile in %s: %s"
                                          file (error-message-string failure))))))
          (unless (and (proper-list-p data) (cl-evenp (length data)))
            (user-error "Usa una lista di proprietà in %s" file))
          (while (progn (skip-chars-forward " \t\r\n") (eq (char-after) ?\;))
            (forward-line 1))
          (let ((profiles (plist-get data :profiles)) (default (plist-get data :default)) names
                (keys (cl-loop for (key _) on data by #'cddr collect key)))
            (unless (and (eobp) (proper-list-p data) (cl-evenp (length data))
                         (equal (plist-get data :version) 1)
                         (proper-list-p profiles) profiles
                         (= (length keys) (length (delete-dups (copy-sequence keys))))
                         (cl-every (lambda (key) (memq key '(:version :default :profiles)))
                                   keys))
              (user-error "Formato delle operazioni non valido in %s" file))
            (dolist (profile profiles)
              (unless (and (proper-list-p profile) (stringp (car profile))
                           (not (string-empty-p (car profile)))
                           (not (member (car profile) names)))
                (user-error "Nome del profilo non valido o ripetuto in %s" file))
              (push (car profile) names)
              (funcall validator profile root))
            (unless (or (null default) (member default names))
              (user-error "Profilo predefinito inesistente in %s" file))
            (list :profiles profiles :default (or default (and (= (length profiles) 1) (caar profiles)))
                  :file file)))))))

(defun gdev-project-operation-model-check ()
  "Verifica esaustivamente gli invarianti dei predicati usati dalle operazioni."
  (let ((cases 0) failures)
    (dolist (environment '(nil ready pending failed))
      (dotimes (bits 32)
        (let* ((known (/= 0 (logand bits 1))) (available (/= 0 (logand bits 2)))
               (configured (/= 0 (logand bits 4))) (running (/= 0 (logand bits 8)))
               (fresh (/= 0 (logand bits 16)))
               (state (gdev-project-operation-decision known environment available configured running fresh)))
          (cl-incf cases)
          (when (and (eq state 'ready)
                     (not (and fresh known available configured (not running)
                               (not (memq environment '(pending failed))))))
            (push `((property . "unready-execution") (environment . ,(format "%s" environment)) (facts . ,bits)) failures))
          (when (and (not fresh) (not (eq state 'obsolete)))
            (push `((property . "stale-context") (environment . ,(format "%s" environment)) (facts . ,bits)) failures))
          (when (and fresh known available configured (not running)
                     (not (memq environment '(pending failed))) (not (eq state 'ready)))
            (push `((property . "ready-not-reachable") (environment . ,(format "%s" environment)) (facts . ,bits)) failures)))))
    (dolist (status '(exit signal failed))
      (dolist (code '(0 1 2 127 130))
        (dolist (stopping '(nil t))
          (cl-incf cases)
          (let ((state (gdev-project-operation-result status code stopping)))
            (when (and stopping (not (eq state 'cancelled)))
              (push `((property . "late-success-after-stop") (status . ,(symbol-name status))
                      (code . ,code)) failures))
            (when (and (eq state 'completed) (not (and (eq status 'exit) (= code 0))))
              (push `((property . "false-success") (status . ,(symbol-name status))
                      (code . ,code) (stopping . ,(if stopping t :false))) failures))))))
    (let* ((types (delete-dups (append (mapcar #'car gdev-project-build-file-markers)
                                       (mapcar #'car gdev-project-language-markers)
                                       '(declared xcode asdf perl-prove))))
           (missing (seq-remove (lambda (type) (assq type gdev-project-operation-contracts)) types)))
      (when missing
        (push `((property . "unclassified-provider") (providers . ,(vconcat (mapcar #'symbol-name missing)))) failures)))
    `((method . "exhaustive-finite-model") (cases . ,cases)
      (ok . ,(if failures :false t)) (counterexamples . ,(vconcat failures))
      (scope . "Osservazioni finite di contesto, prerequisiti ed esiti; copertura dei fornitori registrati")
      (limitations . ["Non dimostra le ricette arbitrarie di Make o la correttezza dei compilatori."
                      "Gli adattatori devono fornire fatti corretti; li verificano i test di integrazione."]))))

(provide 'gdev-project-operations)
;;; gdev-project-operations.el ends here
