;;; gdev-behavior-support.el --- Adattatori dei corpus di comportamento -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Legge dati a monte senza eseguire JavaScript, TypeScript o Lisp importati.
;; Gli oracoli restano nei file originali; le traduzioni delle interazioni
;; sono descritte nel catalogo locale. Non viene caricato dall'editor.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)

(defconst gdev-behavior-directory
  (expand-file-name "behavior/" (file-name-directory (or load-file-name buffer-file-name))))

(defun gdev-behavior-read (relative)
  "Leggi RELATIVE, relativo al corpus, conservando i caratteri Unicode."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative gdev-behavior-directory))
    (buffer-string)))

(defun gdev-behavior-json (relative)
  "Leggi i dati JSON di RELATIVE senza valutare codice."
  (json-parse-string (gdev-behavior-read relative) :object-type 'plist
                     :array-type 'list :null-object nil :false-object nil))

(defun gdev-behavior-prerequisite (available description)
  "Richiedi AVAILABLE per DESCRIPTION; in CI un'assenza è un errore."
  (unless available
    (let ((reason (format "Prerequisito del corpus assente: %s" description)))
      (if (equal (getenv "GDEV_TEST_REQUIRE_BEHAVIORS") "1")
          (ert-fail reason)
        (ert-skip reason)))))

(defun gdev-behavior-grammar (language)
  "Richiedi la grammatica LANGUAGE già installata da gdev sync."
  (require 'treesit)
  (gdev-behavior-prerequisite
   (and (treesit-available-p) (treesit-language-available-p language))
   (format "Tree-sitter %s (gdev sync)" language)))

(defun gdev-behavior-corpus (text)
  "Leggi i casi Tree-sitter da TEXT, inclusi i casi marcati :error.
Rifiuta intestazioni sconosciute e oracoli mancanti, senza saltare casi."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (cases)
      (while (re-search-forward "^=\\{3,\\}[ \t]*$" nil t)
        (let* ((header-start (progn (forward-line 1) (point)))
               (header-end (progn
                             (unless (re-search-forward "^=\\{3,\\}[ \t]*$" nil t)
                               (error "Intestazione Tree-sitter incompleta"))
                             (match-beginning 0)))
               (header (split-string (string-trim
                                      (buffer-substring-no-properties header-start header-end)) "\n" t))
               (name (pop header))
               (input-start (progn (forward-line 1) (point)))
               (next (save-excursion
                       (if (re-search-forward "^=\\{3,\\}[ \t]*$" nil t)
                           (match-beginning 0) (point-max))))
               (separator (progn
                            (unless (re-search-forward "^-\\{3,\\}[ \t]*$" next t)
                              (error "Oracolo Tree-sitter mancante: %s" name))
                            (match-beginning 0)))
               (input (string-trim
                       (buffer-substring-no-properties input-start separator) "\n+" "\n+"))
               (expected (string-trim (buffer-substring-no-properties
                                      (progn (forward-line 1) (point)) next))))
          (unless (and name (cl-every (lambda (flag) (equal flag ":error")) header))
            (error "Intestazione Tree-sitter non supportata: %S" (cons name header)))
          (let* ((read-circle nil)
                 (tree (read-from-string expected)))
            (unless (and (consp (car tree))
                         (string-empty-p (string-trim (substring expected (cdr tree)))))
              (error "Oracolo Tree-sitter non valido: %s" name))
            (push (list :name name :input input :tree (car tree)
                        :error (and (member ":error" header) t)) cases))
          (goto-char next)))
      (unless cases (error "Corpus Tree-sitter vuoto"))
      (nreverse cases))))

(defun gdev-behavior-node (node &optional expected)
  "Traduci NODE nel formato corpus, verificando i campi dichiarati in EXPECTED."
  (if (treesit-node-check node 'missing)
      (list 'MISSING (treesit-node-type node))
    (let ((fields (cl-some (lambda (entry) (and (symbolp entry)
                                              (string-suffix-p ":" (symbol-name entry))))
                           (cdr expected)))
          (children (cl-remove-if-not #'consp (cdr expected)))
          result)
      (dotimes (index (treesit-node-child-count node))
        (let ((child (treesit-node-child node index)))
          (when (or (treesit-node-check child 'named) (treesit-node-check child 'missing))
            (when-let* ((field (and fields (treesit-node-field-name-for-child node index))))
              (push (intern (concat field ":")) result))
            (push (gdev-behavior-node child (pop children)) result))))
      (cons (intern (treesit-node-type node)) (nreverse result)))))

(defun gdev-behavior-parse (language case)
  "Confronta CASE con il parser LANGUAGE, anche dopo una modifica incrementale."
  (gdev-behavior-grammar language)
  (with-temp-buffer
    (insert (plist-get case :input))
    (treesit-parser-create language)
    (let ((tree (treesit-buffer-root-node language)))
      (should (equal (gdev-behavior-node tree (plist-get case :tree)) (plist-get case :tree)))
      (when (plist-get case :error)
        (should (treesit-node-check tree 'has-error))))
    ;; La modifica attraversa il parser già esistente. Il confronto finale
    ;; coglie anche invalidazioni mancate, senza generare un nuovo oracolo.
    (goto-char (point-min))
    (insert " ")
    (treesit-buffer-root-node language)
    (delete-region (point-min) (1+ (point-min)))
    (should (equal (gdev-behavior-node (treesit-buffer-root-node language) (plist-get case :tree))
                   (plist-get case :tree)))))

(defun gdev-behavior-markers (text)
  "Leggi i marcatori CodeMirror |, < e > in TEXT.
Restituisci (TESTO CURSORI REGIONI), con posizioni Emacs da uno."
  (let ((position 1) characters cursors ranges opening)
    (dolist (character (string-to-list text))
      (pcase character
        (?| (push position cursors))
        (?< (when opening (error "Selezione annidata nel corpus")) (setq opening position))
        (?> (unless opening (error "Fine selezione senza inizio"))
            (push (cons opening position) ranges) (setq opening nil))
        (_ (push character characters) (cl-incf position))))
    (when opening (error "Selezione non terminata nel corpus"))
    (unless (or cursors ranges) (error "Posizione del cursore mancante"))
    (list (apply #'string (nreverse characters)) (nreverse cursors) (nreverse ranges))))

(defun gdev-behavior-codemirror (section name)
  "Estrai input e oracolo del test NAME nella SECTION di CodeMirror."
  (with-temp-buffer
    (insert (gdev-behavior-read "upstream/codemirror/test/test-commands.ts"))
    (goto-char (point-min))
    (search-forward (format "describe(\"%s\"" section))
    (let ((end (save-excursion
                 (if (search-forward "  describe(" nil t) (match-beginning 0) (point-max)))))
      (unless (search-forward (format "it(\"%s\"" name) end t)
        (error "Caso CodeMirror sconosciuto: %s / %s" section name))
      (search-forward "test(" end)
      (let ((regexp "\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"") values)
        (dotimes (_ 2)
          (unless (re-search-forward regexp end t) (error "Stringa CodeMirror incompleta"))
          (push (json-parse-string (match-string 0)) values))
        (nreverse values)))))

(defun gdev-behavior-fourslash (text)
  "Leggi codice e marcatori di un file Fourslash TEXT con un solo documento."
  (let ((lines (split-string text "\n")) code (position 1) markers)
    (dolist (line lines)
      (when (string-prefix-p "////" line)
        (push (string-remove-suffix "\r" (substring line 4)) code)))
    (unless code (error "Nessun documento Fourslash"))
    (with-temp-buffer
      (insert (mapconcat #'identity (nreverse code) "\n"))
      (goto-char (point-min))
      (while (re-search-forward "/\\*\\([[:alnum:]_]*\\)\\*/\\|\\[|\\||]" nil t)
        (when (match-beginning 1)
          (let ((name (match-string 1)))
            (when (assoc name markers) (error "Marcatore Fourslash duplicato: %s" name))
            (push (cons name (match-beginning 0)) markers)))
        (replace-match "" t t))
      (setq position (point-max))
      (unless (and markers (> position 1)) (error "Marcatori Fourslash mancanti"))
      (list (buffer-string) (nreverse markers)))))

(defun gdev-behavior-register (name documentation body &rest tags)
  "Registra un test ERT NAME con DOCUMENTATION, BODY e TAGS."
  (ert-set-test name (make-ert-test :name name :documentation documentation
                                  :body (lambda ()
                                          ;; In Emacs 30 alcuni modi Tree-sitter
                                          ;; registrano le estensioni all'entrata.
                                          ;; Non cambiare la scelta dei file per
                                          ;; i test eseguiti dopo questo corpus.
                                          (let ((auto-mode-alist (copy-tree auto-mode-alist))
                                                (interpreter-mode-alist (copy-tree interpreter-mode-alist)))
                                            (funcall body)))
                                  :tags (cons 'behavior tags))))

(provide 'gdev-behavior-support)
;;; gdev-behavior-support.el ends here
