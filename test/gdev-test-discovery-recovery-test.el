;;; gdev-test-discovery-recovery-test.el --- Diagnosi e motori dei test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Processi reali verificano conservazione del registro, recupero e richieste
;; superate. Il comando del documento e il catalogo condividono il runtime.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-project-view)
(require 'gdev-project-types)

(defmacro gdev-test-discovery--with-view (&rest body)
  "Esegui BODY in una vista con cartella e ciclo di vita isolati."
  (declare (indent 0))
  `(let ((root (file-name-as-directory (make-temp-file "gdev-discovery-" t)))
         (view (generate-new-buffer " *gdev-discovery-view*")))
     (unwind-protect
         (with-current-buffer view
           (gdev-project-view-mode)
           (setq-local default-directory root
                       gdev-activity-kind 'test
                       gdev-project-view--root root
                       gdev-project-view--results (make-hash-table :test #'equal))
           ,@body)
       (when (buffer-live-p view) (kill-buffer view))
       (delete-directory root t))))

(defun gdev-test-discovery--await ()
  "Attendi la pubblicazione dell'esito, non solo la fine del figlio."
  (let ((deadline (+ (float-time) 5)))
    (while (and (or gdev-project-view--request gdev-project-view--process)
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should-not gdev-project-view--request)
    (should-not gdev-project-view--process)))

(defun gdev-test-discovery--button (id)
  "Trova il pulsante della vista con identità ID."
  (let ((button (next-button (point-min) t)))
    (while (and button (not (equal id (button-get button 'gdev-project-view-id))))
      (setq button (next-button (button-end button))))
    button))

(ert-deftest gdev-test-discovery-retains-stderr-and-opens-the-log ()
  "L'uscita 2 conserva stderr e offre la stessa apertura da clic e Invio."
  (gdev-test-discovery--with-view
    (let (called shown)
      (gdev-project-view--start
       '("sh" "-c" "printf 'ModuleNotFoundError: missing_dependency\n' >&2; exit 2")
       root (lambda (_) (setq called t)))
      (gdev-test-discovery--await)
      (should-not called)
      (should (string-match-p "uscita 2" gdev-project-view--status))
      (should (string-match-p "missing_dependency" gdev-project-view--status))
      (should (buffer-live-p gdev-project-view--discovery-log))
      (with-current-buffer gdev-project-view--discovery-log
        (should (derived-mode-p 'compilation-mode))
        (should (eq gdev-ui-view-profile 'native))
        (should buffer-read-only)
        (should-not (buffer-modified-p))
        (should (string-search "ModuleNotFoundError: missing_dependency" (buffer-string))))
      (should (equal (button-label (gdev-test-discovery--button 'discover)) "Riprova"))
      (cl-letf (((symbol-function 'gdev-layout-show-panel) (lambda (buffer) (setq shown buffer))))
        (button-activate (gdev-test-discovery--button 'discovery-log))
        (should (eq shown gdev-project-view--discovery-log))
        (setq shown nil)
        (gdev-project-view-discovery-log)
        (should (eq shown gdev-project-view--discovery-log))))))

(ert-deftest gdev-test-discovery-retry-replaces-the-failed-request ()
  "Riprova usa il comando comune e un successo rilascia il registro fallito."
  (gdev-test-discovery--with-view
    (gdev-project-view--start '("sh" "-c" "printf 'prima diagnosi\n' >&2; exit 2") root #'ignore)
    (gdev-test-discovery--await)
    (let ((failed-log gdev-project-view--discovery-log) result)
      (cl-letf (((symbol-function 'gdev-project-view-sync) #'ignore)
                ((symbol-function 'gdev-project-view--test-refresh)
                 (lambda (&rest _)
                   (gdev-project-view--start
                    '("sh" "-c" "printf 'test_esempio.py::test_ok\n'") root
                    (lambda (output) (setq result output gdev-project-view--status "1 test · pytest"))))))
        (button-activate (gdev-test-discovery--button 'discover))
        (gdev-test-discovery--await))
      (should (equal result "test_esempio.py::test_ok\n"))
      (should-not (buffer-live-p failed-log))
      (should-not gdev-project-view--discovery-log)
      (should (equal gdev-project-view--status "1 test · pytest"))
      (should (equal (button-label (gdev-test-discovery--button 'discover)) "Rileva test")))))

(ert-deftest gdev-test-discovery-cancel-discards-a-late-notification ()
  "L'annullamento invalida anche una seconda consegna tardiva della sentinella."
  (gdev-test-discovery--with-view
    (let* ((process (gdev-project-view--start '("sh" "-c" "read linea; exit 2") root #'ignore))
           (sentinel (process-sentinel process))
           (output (process-buffer process)))
      (gdev-project-view-cancel-discovery)
      (funcall sentinel process "notifica tardiva")
      (should (equal gdev-project-view--status "Rilevamento interrotto"))
      (should-not gdev-project-view--discovery-log)
      (should-not (buffer-live-p output))
      (should-not (process-live-p process))
      (should-not (funcall (get 'gdev-project-view-cancel-discovery 'gdev-menu-available)))
      (should-error (gdev-project-view-cancel-discovery) :type 'user-error)
      (should (equal gdev-project-view--status "Rilevamento interrotto")))))

(ert-deftest gdev-test-discovery-replacement-rejects-an-old-result ()
  "Una richiesta superata non cambia il nuovo esito né il suo registro."
  (gdev-test-discovery--with-view
    (let* ((old (gdev-project-view--start '("sh" "-c" "read linea; exit 2") root #'ignore))
           (sentinel (process-sentinel old))
           (output (process-buffer old)))
      (gdev-project-view--start '("sh" "-c" "printf 'diagnosi corrente\n' >&2; exit 2") root #'ignore)
      (gdev-test-discovery--await)
      (let ((current-log gdev-project-view--discovery-log)
            (current-status gdev-project-view--status))
        (funcall sentinel old "notifica superata")
        (should (eq current-log gdev-project-view--discovery-log))
        (should (equal current-status gdev-project-view--status))
        (should (string-match-p "diagnosi corrente" current-status))
        (should-not (buffer-live-p output))))))

(ert-deftest gdev-test-discovery-log-is-released-when-the-view-closes ()
  "La vista possiede il registro fino alla chiusura effettiva del buffer."
  (gdev-test-discovery--with-view
    (gdev-project-view--start '("sh" "-c" "printf 'errore\n' >&2; exit 2") root #'ignore)
    (gdev-test-discovery--await)
    (let ((log gdev-project-view--discovery-log))
      (should (kill-buffer view))
      (should-not (buffer-live-p log)))))

(ert-deftest gdev-test-discovery-changing-project-releases-the-old-log ()
  "Il registro del primo progetto non viene proposto nel progetto successivo."
  (gdev-test-discovery--with-view
    (gdev-project-view--start '("sh" "-c" "printf 'primo progetto\n' >&2; exit 2") root #'ignore)
    (gdev-test-discovery--await)
    (let ((log gdev-project-view--discovery-log)
          (source (generate-new-buffer " *gdev-discovery-source*"))
          (next (file-name-as-directory (expand-file-name "secondo" root))))
      (unwind-protect
          (progn
            (make-directory next)
            (with-current-buffer source (setq default-directory next))
            (save-window-excursion
              (set-window-buffer (selected-window) source)
              (cl-letf (((symbol-function 'gdev-layout-editor) (lambda (&rest _) (selected-window)))
                        ((symbol-function 'gdev-workspace-directory) #'identity)
                        ((symbol-function 'gdev-project-root) #'identity))
                (should (gdev-project-view-sync view))))
            (should (equal gdev-project-view--root next))
            (should-not gdev-project-view--discovery-log)
            (should-not (buffer-live-p log)))
        (kill-buffer source)))))

(ert-deftest gdev-test-discovery-immediate-completion-keeps-the-result ()
  "Una sentinella consegnata prima del ritorno non lascia una richiesta attiva."
  (gdev-test-discovery--with-view
    (let ((original (symbol-function 'make-process)) result)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest arguments)
                   (let ((process (apply original arguments)))
                     (gdev-test-discovery--await)
                     process))))
        (gdev-project-view--start '("sh" "-c" "printf 'concluso\n'") root
                                  (lambda (output) (setq result output))))
      (should (equal result "concluso\n"))
      (should-not gdev-project-view--request)
      (should-not gdev-project-view--process))))

(ert-deftest gdev-test-discovery-javascript-runtime-follows-the-same-manifests ()
  "File JS/TS e catalogo scelgono lo stesso runtime, anche se non installato."
  (require 'typescript-ts-mode)
  (require 'js)
  (load (gdev-module-file :lang 'javascript ".el") nil t t)
  (let ((root (file-name-as-directory (make-temp-file "gdev-test-runtime-" t))))
    (unwind-protect
        (dolist (case '((nil deno) (("package.json") node)
                        (("package.json" "deno.json") deno) (("deno.jsonc") deno)))
          (dolist (name '("package.json" "deno.json" "deno.jsonc"))
            (let ((path (expand-file-name name root)))
              (when (file-exists-p path) (delete-file path))))
          (dolist (name (car case)) (with-temp-file (expand-file-name name root) (insert "{}\n")))
          (dolist (mode '(js-mode typescript-ts-mode tsx-ts-mode))
            (with-temp-buffer
              (let ((major-mode mode)
                    (default-directory root)
                    (buffer-file-name (expand-file-name "esempio.test.ts" root)) command)
                (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) root))
                          ((symbol-function 'save-buffer) #'ignore)
                          ((symbol-function 'executable-find) #'ignore)
                          ((symbol-function 'gdev-compile) (lambda (value &rest _) (setq command value))))
                  (funcall (gdev-handler :test))
                  (should (eq (gdev-test-catalog-provider mode root nil) (cadr case)))
                  (should (string-prefix-p (concat (symbol-name (cadr case)) " ") command)))))))
      (delete-directory root t))))

(ert-deftest gdev-test-discovery-javascript-document-and-catalog-follow-the-nested-package ()
  "Nel monorepo il test del documento e il catalogo usano il pacchetto vicino."
  (require 'typescript-ts-mode)
  (load (gdev-module-file :lang 'javascript ".el") nil t t)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-test-runtime-nested-" t)))
         (package (file-name-as-directory (expand-file-name "pacchetto" root)))
         (directory (file-name-as-directory (expand-file-name "src" package))))
    (unwind-protect
        (progn
          (make-directory directory t)
          (dolist (case '(("deno.json" "package.json" node) ("package.json" "deno.jsonc" deno)))
            (dolist (parent (list root package))
              (dolist (name '("package.json" "deno.json" "deno.jsonc"))
                (let ((path (expand-file-name name parent)))
                  (when (file-exists-p path) (delete-file path)))))
            (with-temp-file (expand-file-name (car case) root) (insert "{}\n"))
            (with-temp-file (expand-file-name (cadr case) package) (insert "{}\n"))
            (with-temp-buffer
              (let ((major-mode 'typescript-ts-mode)
                    (default-directory directory)
                    (buffer-file-name (expand-file-name "esempio.test.ts" directory))
                    command cwd)
                (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) root))
                          ((symbol-function 'save-buffer) #'ignore)
                          ((symbol-function 'gdev-compile)
                           (lambda (value _name location &rest _) (setq command value cwd location))))
                  (funcall (gdev-handler :test))
                  (let ((catalog-root (gdev-project-view--test-root 'javascript root directory)))
                    (should (equal catalog-root package))
                    (should (equal cwd catalog-root))
                    (should (eq (gdev-test-catalog-provider major-mode catalog-root nil) (nth 2 case)))
                    (should (string-prefix-p (concat (symbol-name (nth 2 case)) " ") command))))))))
      (delete-directory root t))))

(ert-deftest gdev-test-discovery-javascript-repl-does-not-substitute-a-missing-runtime ()
  "La console segnala il motore mancante invece di avviarne uno diverso."
  (load (gdev-module-file :lang 'javascript ".el") nil t t)
  (let ((root (file-name-as-directory (make-temp-file "gdev-test-runtime-repl-" t))) started)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) root))
                    ((symbol-function 'executable-find)
                     (lambda (program &rest _) (when (equal program "node") "/bin/true")))
                    ((symbol-function 'gdev-executable-in) (lambda (&rest _) nil))
                    ((symbol-function 'make-comint) (lambda (&rest arguments) (setq started arguments))))
            (should-error (gdev-js-repl) :type 'user-error)
            (should-not started))
          (with-temp-file (expand-file-name "package.json" root) (insert "{}\n"))
          (cl-letf (((symbol-function 'gdev-project-root) (lambda (&rest _) root))
                    ((symbol-function 'gdev-executable-in)
                     (lambda (program location)
                       (should (equal program "node"))
                       (should (equal location root))
                       "/bin/true"))
                    ((symbol-function 'make-comint) (lambda (&rest arguments) (setq started arguments))))
            (gdev-js-repl)
            (should (equal (nth 1 started) "node"))
            (should (equal (nth 3 started) "--interactive"))))
      (delete-directory root t))))

(provide 'gdev-test-discovery-recovery-test)
;;; gdev-test-discovery-recovery-test.el ends here
