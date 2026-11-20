;;; gdev-behavior-test.el --- Corpus di comportamenti reali dell'IDE -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Fa parte della suite ordinaria test/gdev-test.el. I casi a monte vengono
;; registrati singolarmente in ERT, con nome e provenienza nel risultato.
;; GDEV_TEST_REQUIRE_BEHAVIORS=1 rende obbligatorie grammatiche e Deno.
;; test/behavior/README.md descrive adattamenti, limiti e aggiornamenti.

;;; Code:

(load (expand-file-name "gdev-behavior-support.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t t)

(ert-deftest gdev-test-behavior-provenance ()
  "Le copie originali coincidono con il registro fissato per revisione."
  (let ((manifest (gdev-behavior-json "sources.json")) ids files)
    (should (= 1 (plist-get manifest :schema_version)))
    (dolist (source (plist-get manifest :sources))
      (let* ((id (plist-get source :id))
             (base (concat "upstream/" id "/")))
        (should-not (member id ids))
        (push id ids)
        (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (plist-get source :revision)))
        (should (member (plist-get source :license) '("MIT" "Apache-2.0" "GPL-3.0-or-later")))
        (should (file-regular-p (expand-file-name
                                (concat base (plist-get source :license_file))
                                gdev-behavior-directory)))
        (dolist (entry (plist-get source :files))
          (let ((relative (concat base (plist-get entry :path))))
            (push (expand-file-name relative gdev-behavior-directory) files)
            (ert-info ((format "%s @ %s" relative (plist-get source :revision)))
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally (car files))
                (should (equal (secure-hash 'sha256 (current-buffer))
                               (plist-get entry :sha256)))))))))
    (should (equal (sort files #'string<)
                   (sort (directory-files-recursively
                          (expand-file-name "upstream/" gdev-behavior-directory) ".") #'string<)))))

(ert-deftest gdev-test-behavior-adapters-reject-incomplete-oracles ()
  "Un corpus troncato o un marcatore errato non produce un successo vuoto."
  (dolist (text '("" "===\nNome\n===\ncodice\n"
                  "===\nNome\n:skip\n===\nx\n---\n(program)"
                  "===\nNome\n===\nx\n---\n(program) residuo"))
    (should-error (gdev-behavior-corpus text)))
  (dolist (text '("testo" "<testo" "testo>" "<<testo>>"))
    (should-error (gdev-behavior-markers text)))
  (should (equal (gdev-behavior-markers "😀|caffè<é>")
                 '("😀caffèé" (2) ((7 . 8)))))
  (should-error (gdev-behavior-fourslash "////x/*a*/ + /*a*/y"))
  (should (equal (gdev-behavior-fourslash "////const /*a*/x = '😀';\r\n////x./**/")
                 '("const x = '😀';\nx." (("a" . 7) ("" . 18))))))

(ert-deftest gdev-test-behavior-fork-x509-cold-load-under-a-compiling-caller ()
  "Il caricamento a freddo legge i dati X509, anche compilando un altro modulo."
  (let* ((file (expand-file-name "x509-mode.el" (gdev-bundled-package-directory 'x509-mode)))
         (form `(progn
                  (require 'package)
                  (package-activate-all)
                  (let ((byte-compile-current-file
                         ,(gdev-config-file "modules/tools/remote/config.el")))
                    (load ,file nil t t))
                  (unless (and (featurep 'x509-mode) (fboundp 'x509-mode))
                    (error "X509 non caricato")))))
    (with-temp-buffer
      (should (zerop (call-process (expand-file-name invocation-name invocation-directory)
                                   nil (current-buffer) nil "--batch" "-Q"
                                   "-l" (gdev-config-file "early-init.el")
                                   "--eval" (prin1-to-string form)))))))

;;;; Parsing e aggiornamenti incrementali: ogni sezione originale è un test.

(dolist (language '(javascript python json))
  (let ((directory (expand-file-name (format "upstream/%s/test/corpus/" language)
                                     gdev-behavior-directory)))
    (dolist (file (directory-files directory t "\\.txt\\'"))
      (cl-loop for case in (gdev-behavior-corpus
                           (with-temp-buffer (insert-file-contents file) (buffer-string)))
               for index from 1
               do (let ((case case))
                    (gdev-behavior-register
                     (intern (format "gdev-test-behavior-parse-%s-%s-%03d"
                                     language (file-name-base file) index))
                     (format "%s: %s (%s)." language (plist-get case :name)
                             (file-relative-name file gdev-behavior-directory))
                     (lambda () (gdev-behavior-parse language case)) 'parsing))))))

;;;; Evidenziazione: oracoli TextMate tradotti nelle facce semantiche Emacs.

(defun gdev-behavior-textmate-tokens ()
  "Leggi gli intervalli del primo baseline TextMate di Comments.ts."
  (with-temp-buffer
    (insert (gdev-behavior-read "upstream/textmate/tests/baselines/Comments.baseline.txt"))
    (goto-char (point-min))
    (search-forward "Grammar: TypeScript.tmLanguage")
    (forward-line 2)
    (let ((line 0) tokens)
      (while (not (eobp))
        (cond
         ((looking-at "Grammar:") (goto-char (point-max)))
         ((looking-at ">") (cl-incf line) (forward-line 1))
         ((looking-at "\\( +\\)\\(\\^+\\)$")
          (let ((column (1- (length (match-string 1))))
                (length (length (match-string 2))))
            (forward-line 1)
            (let* ((scope (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
                   (kind (cond ((string-match-p "comment\\.block\\.ts" scope) 'comment)
                               ((string-match-p "string\\.quoted\\.double\\.ts" scope) 'string)
                               ((string-match-p "storage\\.type\\.ts" scope) 'keyword))))
              (when kind (push (list line column length kind) tokens)))
            (forward-line 1)))
         (t (forward-line 1))))
      (unless tokens (error "Baseline TextMate privo di token"))
      (nreverse tokens))))

(defun gdev-behavior-face-p (position kind)
  "Verifica la faccia semantica KIND alla POSITION, inclusi i delimitatori."
  (let ((allowed (pcase kind
                   ('comment '(font-lock-comment-face font-lock-comment-delimiter-face font-lock-doc-face))
                   ('string '(font-lock-string-face))
                   ('keyword '(font-lock-keyword-face))))
        (faces (ensure-list (get-text-property position 'face))))
    (cl-intersection allowed faces)))

(ert-deftest gdev-test-behavior-textmate-comments-and-strings ()
  "Commenti intercalati al codice, stringhe e parole chiave seguono il baseline."
  (gdev-behavior-grammar 'typescript)
  (require 'typescript-ts-mode)
  (with-temp-buffer
    (insert (gdev-behavior-read "upstream/textmate/tests/cases/Comments.ts"))
    (typescript-ts-mode)
    (font-lock-ensure)
    (let ((tokens (gdev-behavior-textmate-tokens)))
      (should (> (length tokens) 100))
      (pcase-dolist (`(,line ,column ,length ,kind) tokens)
        (goto-char (point-min))
        (forward-line (1- line))
        (forward-char column)
        (ert-info ((format "TextMate, riga %d, colonna %d, %s" line column kind))
          (dotimes (offset length)
            (when (< (+ (point) offset) (line-end-position))
              (should (gdev-behavior-face-p (+ (point) offset) kind)))))))))

(dolist (language '(javascript python))
  (gdev-behavior-register
   (intern (format "gdev-test-behavior-highlight-%s-keywords" language))
   (format "Le parole chiave del fixture Tree-sitter %s hanno facce Emacs." language)
   (lambda ()
     (gdev-behavior-grammar language)
     (when (eq language 'javascript) (gdev-behavior-grammar 'jsdoc))
     (require (if (eq language 'javascript) 'js 'python))
     (with-temp-buffer
       (insert (gdev-behavior-read (format "upstream/%s/test/highlight/keywords.%s"
                                          language (if (eq language 'javascript) "js" "py"))))
       (funcall (if (eq language 'javascript) #'js-ts-mode #'python-ts-mode))
       (font-lock-ensure)
       (goto-char (point-min))
       (let (code-start)
         (while (not (eobp))
           (if (looking-at "\\([ \t]*\\)\\(?://\\|#\\).*?\\(<-\\|\\^+\\) keyword$")
               (let ((position (if (equal (match-string 2) "<-")
                                   (+ code-start (length (match-string 1)))
                                 (+ code-start (match-beginning 2) (- (line-beginning-position))))))
                 (should (gdev-behavior-face-p position 'keyword)))
             (unless (looking-at "[ \t]*\\(?://\\|#\\)")
               (setq code-start (line-beginning-position))))
           (forward-line 1))))) 'highlight))

;;;; Editing: input/oracolo originali, comandi distribuiti da GDev.

(defconst gdev-behavior-edit-cases
  '(("indentSelection" "auto-indents the current line" indent-for-tab-command)
    ("indentSelection" "moves the cursor ahead of the indentation" indent-for-tab-command)
    ("indentSelection" "indents blocks of lines" indent-for-tab-command)
    ("indentSelection" "includes previous indentation changes in relative indentation" indent-for-tab-command)
    ("insertNewlineKeepIndent" "keeps indentation" newline-and-indent)
    ("insertNewlineKeepIndent" "keeps zero indentation" newline-and-indent)
    ("insertNewlineAndIndent" "isn't confused by text after the cursor" newline-and-indent)
    ("moveLineUp" "can move a line up" gdev-sposta-testo-su)
    ("moveLineDown" "can move a line own" gdev-sposta-testo-giu))
  "Traduzioni dichiarate delle azioni CodeMirror in comandi GDev/Emacs.")

(defun gdev-behavior-edit (case)
  "Esegui il CASE di editing e confronta testo, cursore e selezione."
  (require 'js)
  (require 'gdev-sposta-testo)
  (gdev-behavior-grammar 'javascript)
  (gdev-behavior-grammar 'jsdoc)
  (pcase-let* ((`(,section ,name ,command) case)
               (`(,before ,after) (gdev-behavior-codemirror section name))
               (`(,text ,cursors ,ranges) (gdev-behavior-markers before))
               (`(,expected ,expected-cursors ,expected-ranges) (gdev-behavior-markers after)))
    (with-temp-buffer
      (if (equal section "insertNewlineKeepIndent") (text-mode) (js-ts-mode))
      (setq-local js-indent-level 2 indent-tabs-mode nil)
      (insert text)
      (let ((transient-mark-mode t))
        (if ranges
            (progn (goto-char (caar ranges)) (push-mark (cdar ranges) t t))
          (goto-char (car cursors)))
        ;; I marcatori Emacs sul bordo iniziale restano prima degli spazi
        ;; inseriti. CodeMirror li sposta dopo il nuovo rientro.
        (when (and ranges (equal section "indentSelection") (bolp))
          (setcar (car expected-ranges)
                  (with-temp-buffer
                    (insert expected)
                    (goto-char (caar expected-ranges))
                    (line-beginning-position))))
        (call-interactively command)
        (should (equal (buffer-string) expected))
        (if expected-ranges
            (should (equal (cons (region-beginning) (region-end)) (car expected-ranges)))
          (should (equal (list (point)) expected-cursors)))))))

(cl-loop for case in gdev-behavior-edit-cases for index from 1
         do (let ((case case))
              (gdev-behavior-register
               (intern (format "gdev-test-behavior-edit-codemirror-%02d" index))
               (format "CodeMirror %s / %s → %s." (nth 0 case) (nth 1 case) (nth 2 case))
               (lambda () (gdev-behavior-edit case)) 'editing)))

(ert-deftest gdev-test-behavior-monaco-tab-columns ()
  "Le colonne visibili degli spazi e dei TAB coincidono con i casi Monaco."
  (with-temp-buffer
    (insert (gdev-behavior-read
             "upstream/monaco/src/vs/editor/test/common/controller/cursorAtomicMoveOperations.test.ts"))
    (goto-char (point-min))
    (let ((end (save-excursion (search-forward "test('Test atomicPosition'") (match-beginning 0)))
          (count 0))
      (while (re-search-forward "lineContent: '\\([^'\n]*\\)'" end t)
        (let ((text (replace-regexp-in-string "\\\\t" "\t" (match-string 1) t t)))
          (re-search-forward "tabSize: \\([0-9]+\\)" end)
          (let ((width (string-to-number (match-string 1))))
            (re-search-forward "expectedVisibleColumn: \\(\\[[^]]+\\]\\)" end)
            (let ((expected (json-parse-string (match-string 1) :array-type 'list)))
              (with-temp-buffer
                (setq-local tab-width width)
                (insert text)
                (cl-loop for column in expected for offset from 0
                         when (>= column 0)
                         do (goto-char (1+ offset))
                         and do (should (= (current-column) column)))))))
        (cl-incf count))
      (should (= count 8)))))

(load (gdev-config-file "test/gdev-behavior-bdd-test.el") nil t t)
(load (gdev-config-file "test/gdev-behavior-emacs-test.el") nil t t)
(load (gdev-config-file "test/gdev-behavior-lsp-test.el") nil t t)

(provide 'gdev-behavior-test)
;;; gdev-behavior-test.el ends here
