;;; gdev-test-catalog.el --- Cataloghi e identificatori dei test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Rileva il catalogo di test del progetto e legge i risultati di pytest,
;; Deno e Node per la vista Test.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xml)
(require 'gdev-lib)

(declare-function gdev-python--interpreter "../../lang/python/config" (root))
(declare-function libxml-parse-region "xml")
(declare-function python-info-current-defun "python" ())
(declare-function url-filename "url-parse" (url))
(declare-function url-generic-parse-url "url-parse" (url))
(declare-function url-unhex-string "url-util" (string &optional allow-newlines))

(defun gdev-test-catalog-language (mode)
  "Restituisci la famiglia di test direttamente associata a MODE."
  (cond ((and (fboundp 'gdev-python--interpreter)
              (provided-mode-derived-p mode 'python-base-mode)) 'python)
        ((provided-mode-derived-p mode '(js-mode js-base-mode typescript-ts-base-mode)) 'javascript)))

(defun gdev-test-catalog-provider (mode root ctest-directory)
  "Scegli il catalogo per MODE e ROOT, usando CTEST-DIRECTORY se disponibile."
  (let ((language (gdev-test-catalog-language mode)))
    (cond ((eq language 'python) 'pytest)
          ((eq language 'javascript)
           (if (gdev-project-file-exists-p root "deno.json" "deno.jsonc") 'deno
             (if (gdev-project-file-exists-p root "package.json") 'node 'deno)))
          (ctest-directory 'ctest)
          ((gdev-project-file-exists-p root "deno.json" "deno.jsonc") 'deno)
          ((gdev-project-file-exists-p root "package.json") 'node)
          ((and (fboundp 'gdev-python--interpreter)
                (gdev-project-file-exists-p root "pyproject.toml" "pytest.ini" "setup.cfg")) 'pytest))))

(defun gdev-test-catalog-title (provider)
  "Restituisci il nome dello strumento di prova PROVIDER."
  (pcase provider ('pytest "pytest") ('deno "Deno") ('node "Node") (_ "CTest")))

(defun gdev-test-catalog-pytest-command (root &rest arguments)
  "Esegui pytest con l'interprete di ROOT e gli ARGUMENTS indicati."
  (append (list (gdev-python--interpreter root) "-m" "pytest" "--color=no") arguments))

(defun gdev-test-catalog-command (provider directory ids &optional jobs)
  "Prepara gli argomenti per PROVIDER in DIRECTORY e gli identificatori IDS.
JOBS seleziona il parallelismo di Node e abilita quello di Deno da due in su.
Per limitare Deno imposta anche DENO_JOBS nell'ambiente del processo."
  (pcase provider
    ('pytest (apply #'gdev-test-catalog-pytest-command directory "-v" "--" ids))
    ('deno (append '("deno" "test" "--reporter=junit")
                   (when (and jobs (> jobs 1)) '("--parallel"))
                   (mapcar (lambda (id) (concat "./" id)) ids)))
    ('node (append '("node" "--test" "--test-reporter=junit")
                   (when jobs (list (format "--test-concurrency=%d" jobs)))
                   (mapcar (lambda (id) (concat "./" id)) ids)))))

(defun gdev-test-catalog--entry (name location)
  "Crea una voce del catalogo per NAME e LOCATION."
  (list (cons 'name name) (cons 'gdev-location location)))

(defun gdev-test-catalog-pytest (output root)
  "Leggi gli identificatori dei test pytest raccolti in OUTPUT per ROOT."
  (let ((files (make-hash-table :test #'equal)))
    (cl-loop for line in (split-string output "\n" t)
             for name = (when (string-match "^\\(.+?\\.py\\)::[^[:space:]]" line)
                          (match-string 1 line))
             for path = (when name
                          (let ((known (gethash name files 'unknown)))
                            (if (eq known 'unknown)
                                (let ((file (expand-file-name name root)))
                                  (puthash name (and (file-regular-p file) file) files))
                              known)))
             when path collect (gdev-test-catalog--entry line (cons path 1)))))

(defconst gdev-test-catalog-deno-files
  '("rg" "--files" "--null"
    "-g" "*_test.{ts,tsx,mts,js,mjs,jsx}"
    "-g" "*.test.{ts,tsx,mts,js,mjs,jsx}"
    "-g" "test.{ts,tsx,mts,js,mjs,jsx}"
    "-g" "**/__tests__/**/*.{ts,tsx,mts,js,mjs,jsx}")
  "Elenca le convenzioni Deno per nome di file senza eseguire i test.")

(defconst gdev-test-catalog-node-files
  '("rg" "--files" "--null"
    "-g" "*_test.{js,cjs,mjs,ts,cts,mts}"
    "-g" "*-test.{js,cjs,mjs,ts,cts,mts}"
    "-g" "*.test.{js,cjs,mjs,ts,cts,mts}"
    "-g" "test-*.{js,cjs,mjs,ts,cts,mts}"
    "-g" "test.{js,cjs,mjs,ts,cts,mts}"
    "-g" "**/test/**/*.{js,cjs,mjs,ts,cts,mts}"
    "-g" "!**/node_modules/**")
  "Elenca i possibili file di test di Node.")

(defun gdev-test-catalog-files (output root)
  "Leggi i percorsi NUL di OUTPUT come file di test in ROOT."
  (mapcar (lambda (file) (gdev-test-catalog--entry file (cons (expand-file-name file root) 1)))
          (sort (split-string output "\0" t) #'string<)))

(defun gdev-test-catalog--pytest-at-point (entries root)
  "Trova in ENTRIES il test Python al cursore, relativo a ROOT."
  (require 'python)
  (when-let* ((function (python-info-current-defun))
              (name (concat (file-relative-name buffer-file-name root) "::"
                            (string-replace "." "::" function)))
              (parameter-prefix (concat name "[")))
    (cl-loop for entry in entries
             for id = (alist-get 'name entry)
             when (or (equal name id) (string-prefix-p parameter-prefix id)) collect id)))

(defun gdev-test-catalog-at-point (provider entries root)
  "Restituisci gli identificatori di PROVIDER in ENTRIES al cursore.
ROOT è la radice del catalogo. CTest usa la registrazione e Deno e
Node usano il file di test. pytest include le varianti raccolte."
  (when buffer-file-name
    (pcase provider
      ('pytest (gdev-test-catalog--pytest-at-point entries root))
      ((or 'deno 'node)
       (let ((relative (file-relative-name buffer-file-name root)))
         (when (cl-find relative entries :key (lambda (entry) (alist-get 'name entry))
                        :test #'equal)
           (list relative))))
      ('ctest
       (let ((line (line-number-at-pos nil t))
             (opening (when-let* ((start (nth 1 (syntax-ppss))))
                        (line-number-at-pos start t))))
         (cl-loop for entry in entries
                  for location = (alist-get 'gdev-location entry)
                  when (and location (memq (cdr location) (list line opening))
                            (or (member (car location) (list buffer-file-name buffer-file-truename))
                                (file-equal-p (car location) buffer-file-name)))
                  collect (alist-get 'name entry)))))))

(defconst gdev-test-catalog--pytest-result-pattern
  (let ((state (regexp-opt '("PASSED" "FAILED" "ERROR" "SKIPPED" "XFAIL" "XPASS") t))
        (id "\\(.+?\\.py::.+\\)"))
    (concat "^\\(?:" id " " state "\\(?:[[:blank:]]\\|$\\)"
            "\\|\\[[[:alnum:]_.-]+\\][[:blank:]]+\\(?:\\[[^]\n]+\\][[:blank:]]+\\)?"
            state " " id "$\\)"))
  "Riga degli esiti di pytest, anche con i worker paralleli di xdist.")

(defun gdev-test-catalog-pytest-results (&optional start end results)
  "Leggi gli esiti pytest verbosi tra START ed END nel buffer corrente.
Aggiorna RESULTS se già fornito per una lettura incrementale."
  (let ((results (or results (make-hash-table :test #'equal)))
        (case-fold-search nil))
    (save-excursion
      (goto-char (or start (point-min)))
      (while (re-search-forward gdev-test-catalog--pytest-result-pattern end t)
        (let ((id (string-trim-right (or (match-string-no-properties 1) (match-string-no-properties 4))))
              (state (or (match-string-no-properties 2) (match-string-no-properties 3))))
          (puthash id
                   (pcase state
                     ((or "PASSED" "XPASS") "Passato")
                     ((or "SKIPPED" "XFAIL") "Saltato")
                     (_ "Fallito"))
                   results))))
    results))

(defun gdev-test-catalog--junit ()
  "Leggi il documento JUnit dal buffer di compilazione."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((tag (re-search-forward "^[[:blank:]]*<\\(testsuites?\\)\\b" nil t))
                (name (match-string-no-properties 1))
                (start (match-beginning 0))
                (end (search-forward (concat "</" name ">") nil t)))
      (condition-case nil
          (if (fboundp 'libxml-parse-region)
              (libxml-parse-region start end)
            (car (xml-parse-region start end)))
        (error nil)))))

(defun gdev-test-catalog--report-id (path root)
  "Traduci PATH del rapporto in un identificatore relativo a ROOT."
  (if (not root)
      (string-remove-prefix "./" path)
    (when (string-prefix-p "file://" path)
      (require 'url-parse)
      (require 'url-util)
      (setq path (decode-coding-string
                  (url-unhex-string (url-filename (url-generic-parse-url path))) 'utf-8-unix)))
    (file-relative-name (if (file-name-absolute-p path) (file-truename path)
                          (expand-file-name path root)) root)))

(defun gdev-test-catalog--merge-result (results id result)
  "Conserva in RESULTS l'esito più rilevante per ID tra quelli già letti e RESULT."
  (let ((previous (gethash id results)))
    (puthash id (cond ((or (equal previous "Fallito") (equal result "Fallito")) "Fallito")
                      ((or (equal previous "Passato") (equal result "Passato")) "Passato")
                      (t "Saltato"))
             results)))

(defun gdev-test-catalog-deno-results (&optional root)
  "Leggi gli esiti del resoconto JUnit di Deno, con percorsi relativi a ROOT."
  (let* ((results (make-hash-table :test #'equal))
         (base (and root (file-truename root)))
         (document (gdev-test-catalog--junit))
         (suites (if (eq (car-safe document) 'testsuite) (list document)
                   (xml-get-children document 'testsuite))))
    (dolist (suite suites)
      (when-let* ((name (xml-get-attribute-or-nil suite 'name)))
        (gdev-test-catalog--merge-result
         results (gdev-test-catalog--report-id name base)
         (cond ((or (> (string-to-number (xml-get-attribute suite 'failures)) 0)
                    (> (string-to-number (xml-get-attribute suite 'errors)) 0)) "Fallito")
               ((= (string-to-number (xml-get-attribute suite 'tests))
                   (string-to-number (xml-get-attribute suite 'disabled))) "Saltato")
               (t "Passato")))))
    results))

(defun gdev-test-catalog-node-results (root)
  "Raggruppa per file gli esiti JUnit di Node rispetto a ROOT."
  (let* ((document (gdev-test-catalog--junit))
         (cases (append (xml-get-children document 'testcase)
                        (cl-mapcan (lambda (suite) (xml-get-children suite 'testcase))
                                   (xml-get-children document 'testsuite))))
         (base (file-truename root))
         (sources (make-hash-table :test #'equal))
         (results (make-hash-table :test #'equal)))
    (dolist (test cases)
      (when-let* ((file (xml-get-attribute-or-nil test 'file))
                  (id (with-memoization (gethash file sources)
                        (gdev-test-catalog--report-id file base))))
        (gdev-test-catalog--merge-result
         results id
         (cond ((or (xml-get-children test 'failure) (xml-get-children test 'error)) "Fallito")
               ((or (xml-get-attribute-or-nil test 'skipped) (xml-get-children test 'skipped)) "Saltato")
               (t "Passato")))))
    results))

(defun gdev-test-catalog-results (provider root &optional start end results)
  "Leggi gli esiti di PROVIDER relativo a ROOT nel buffer corrente.
Per pytest usa START, END e RESULTS per leggere solo l'output nuovo.
Per i rapporti JUnit attendi il documento completo prima di chiamare."
  (pcase provider
    ('pytest (gdev-test-catalog-pytest-results start end results))
    ('deno (gdev-test-catalog-deno-results root))
    ('node (gdev-test-catalog-node-results root))))

(provide 'gdev-test-catalog)
;;; gdev-test-catalog.el ends here
