;;; gdev-voice-test.el --- Grammatica e sessioni della voce italiana -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Si provano le entrate effettive e i limiti tra testo letterale e azione.
;; Le prove di riconoscimento su file e con microfono restano distinte.
;;; Code:
(require 'ert)
(require 'gdev-voice-italian)
(require 'gdev-voice)

(ert-deftest gdev-test-voice-upstream-contracts-have-verified-provenance ()
  (let* ((directory (gdev-bundled-package-directory 'earwig))
         (manifest (with-temp-buffer
                     (insert-file-contents (expand-file-name "upstream-tests.json" directory))
                     (json-parse-buffer :object-type 'alist)))
         (registered (assq 'earwig gdev-bundled-packages)))
    (should (equal (alist-get 'revision manifest) (nth 4 registered)))
    (should (equal (alist-get 'license manifest) (nth 2 registered)))
    (dolist (entry (alist-get 'files manifest))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally (expand-file-name (symbol-name (car entry)) directory))
        (should (equal (cdr entry) (secure-hash 'sha256 (current-buffer))))))))

(ert-deftest gdev-test-voice-loads-the-local-fork-before-an-elpa-namesake ()
  (let ((directory (make-temp-file "gdev-voice-elpa-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "earwig-edit.el" directory)
            (insert "(error \"Copia ELPA non autorizzata\")\n"))
          (with-temp-buffer
            (should
             (zerop
              (call-process
               (expand-file-name invocation-name invocation-directory) nil (current-buffer) nil
               "--batch" "-Q" "-l" (gdev-config-file "early-init.el")
               "-L" (gdev-config-file "lisp/")
               "-L" (gdev-config-file "modules/ui/workbench/")
               "--eval"
               (prin1-to-string
                `(progn
                   (require 'gdev-voice)
                   (push ,directory load-path)
                   (gdev-voice--fork 'earwig-edit)
                   (unless (file-in-directory-p (symbol-file 'earwig-part-range 'defun)
                                                (gdev-bundled-package-directory 'earwig))
                     (error "Il simbolo non appartiene al fork locale")))))))))
      (delete-directory directory t))))

(defmacro gdev-voice-test--document (text &rest body)
  "Esegui BODY nel documento TEXT di una finestra normale."
  (declare (indent 1))
  `(let ((document (generate-new-buffer "Documento vocale"))
         (windows (current-window-configuration))
         (transient-mark-mode t)
         (gdev-layout-mode nil))
     (unwind-protect
         (progn
           (set-window-buffer (selected-window) document)
           (with-current-buffer document
             (gdev-layout-mark-document)
             (buffer-enable-undo)
             (insert ,text)
             (setq buffer-undo-list nil)
             ,@body))
       (set-window-configuration windows)
       (when (buffer-live-p document) (kill-buffer document)))))

(ert-deftest gdev-test-voice-italian-numbers-and-incomplete-input ()
  (dolist (example '(("0" . 0) ("due" . 2) ("diciassette" . 17) ("ventuno" . 21)
                     ("ventitré" . 23) ("ventotto" . 28) ("trentadue" . 32)
                     ("cento" . 100) ("centottanta" . 180) ("duecento quarantadue" . 242)
                     ("mille" . 1000) ("duemila ventisei" . 2026) ("novantanovemilanovecentonovantanove" . 99999)))
    (ert-info ((car example)) (should (equal (cdr example) (gdev-voice-italian-number (car example))))))
  (dolist (example '("-1" "due parole" "ventiuno" "cinque e mezzo" "1000000" ""))
    (should-not (gdev-voice-italian-number example))))

(ert-deftest gdev-test-voice-italian-targets-preserve-literals ()
  (should (equal (gdev-voice-italian-target "tutto") '(:kind structural :spec "everything")))
  (should (equal (gdev-voice-italian-target "\"tutto\"") '(:kind literal :text "tutto")))
  (should (equal (gdev-voice-italian-target "le ultime due parole") '(:kind structural :spec "last 2 words")))
  (should (equal (gdev-voice-italian-target "questa riga") '(:kind structural :spec "this 1 line")))
  (should (equal (gdev-voice-italian-target "prossime tre frasi") '(:kind structural :spec "next 3 sentences")))
  (should (equal (gdev-voice-italian-target "\"C++::Tipo<T>\"") '(:kind literal :text "C++::Tipo<T>")))
  (should-not (gdev-voice-italian-target "le ultime due")))

(ert-deftest gdev-test-voice-italian-chains-are-validated-before-effects ()
  (let ((catalog '(("Salva · File" . save-buffer) ("Compila · Progetto" . gdev-build))))
    (should (equal (gdev-voice-italian-parse "salva E POI compila." catalog)
                   '((:kind command :command save-buffer) (:kind command :command gdev-build))))
    (should-not (gdev-voice-italian-parse "salva e poi qualcosa di ignoto" catalog))
    (should-not (gdev-voice-italian-parse "vai alla riga" catalog))
    (should-not (gdev-voice-italian-parse "vai alla riga zero" catalog))
    (should-not (gdev-voice-italian-parse "cerca \"virgolette aperte" catalog))
    (should (equal (gdev-voice-italian-parse "salva e poi non importa" catalog) '((:kind cancel))))))

(ert-deftest gdev-test-voice-italian-keeps-code-case-punctuation-and-quoted-chains ()
  (should (equal (gdev-voice-italian-parse "sostituisci «A con B» con «C++ e poi D»" nil)
                 '((:kind replace :from "A con B" :to "C++ e poi D" :all nil))))
  (should (equal (gdev-voice-italian-parse "sostituisci Alfa con Beta ovunque" nil)
                 '((:kind replace :from "Alfa" :to "Beta" :all t))))
  (should (equal (gdev-voice-italian-parse "apri file \"Cartella è/Classe.cpp\"" nil)
                 '((:kind file :text "Cartella è/Classe.cpp"))))
  (should (equal (gdev-voice-italian-parse "cerca \"A && B || C\"" nil)
                 '((:kind search :text "A && B || C")))))

(ert-deftest gdev-test-voice-italian-catalog-does-not-guess-an-ambiguous-command ()
  (let ((catalog '(("Apri… · File" . find-file) ("Apri… · Progetto" . project-switch-project))))
    (should-not (gdev-voice-italian-parse "apri" catalog))
    (should (equal (gdev-voice-italian-parse "apri · progetto" catalog)
                   '((:kind command :command project-switch-project))))))

(ert-deftest gdev-test-voice-command-edits-the-real-document-and-can-undo ()
  (gdev-voice-test--document "uno due tre"
    (goto-char (point-max))
    (gdev-voice-execute "seleziona le ultime due parole")
    (should (equal "due tre" (buffer-substring-no-properties (region-beginning) (region-end))))
    (gdev-voice-execute "maiuscolo la selezione")
    (should (equal "uno DUE TRE" (buffer-string)))
    (undo-only 1)
    (should (equal "uno due tre" (buffer-string)))))

(ert-deftest gdev-test-voice-command-keeps-literals-and-validates-the-whole-chain ()
  (gdev-voice-test--document "tutto non tutto"
    (goto-char (point-max))
    (gdev-voice-execute "elimina \"tutto\"")
    (should (equal "tutto non " (buffer-string)))
    (let ((before (buffer-string)) (position (point)))
      (should-error (gdev-voice-execute "maiuscolo tutto e poi comando inesistente") :type 'user-error)
      (should (equal before (buffer-string)))
      (should (= position (point))))))

(ert-deftest gdev-test-voice-command-replacement-preserves-code-and-read-only-documents ()
  (gdev-voice-test--document "TipoA e TipoA"
    (gdev-voice-execute "sostituisci TipoA con \"C++::Tipo<T>\" ovunque")
    (should (equal "C++::Tipo<T> e C++::Tipo<T>" (buffer-string)))
    (let ((buffer-read-only t))
      (should-error (gdev-voice-execute "elimina tutto") :type 'buffer-read-only)
      (should (equal "C++::Tipo<T> e C++::Tipo<T>" (buffer-string))))))

(ert-deftest gdev-test-voice-context-rejects-a-replaced-or-closed-document ()
  (gdev-voice-test--document "prima"
    (let ((context (gdev-voice-context)) (other (generate-new-buffer "Altro documento")))
      (unwind-protect
          (progn
            (should (gdev-voice-context-current-p context))
            (set-window-buffer (selected-window) other)
            (should-not (gdev-voice-context-current-p context))
            (set-window-buffer (selected-window) document)
            (should (gdev-voice-context-current-p context))
            (kill-buffer document)
            (should-not (gdev-voice-context-current-p context)))
        (kill-buffer other)))))

(provide 'gdev-voice-test)
;;; gdev-voice-test.el ends here
