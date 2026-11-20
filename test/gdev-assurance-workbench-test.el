;;; gdev-assurance-workbench-test.el --- Integrazione del processo -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'gdev-assurance-workbench)

(defmacro gdev-test-assurance-ui--view (root &rest body)
  "Esegui BODY nella vista isolata del progetto ROOT."
  (declare (indent 1))
  (let ((buffers (make-symbol "buffers")))
    `(let ((,buffers (buffer-list)))
       (gdev-test--with-layout
         (unwind-protect (progn (gdev-assurance-show ,root) ,@body)
           (dolist (buffer (seq-difference (buffer-list) ,buffers))
             (when (and (buffer-live-p buffer)
                        (with-current-buffer buffer (derived-mode-p 'gdev-assurance-mode)))
               (kill-buffer buffer))))))))

(defun gdev-test-assurance-ui--button (identity)
  "Trova il pulsante con IDENTITY nella vista corrente."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'gdev-assurance-focus identity #'equal)))
      (button-at (prop-match-beginning match)))))

(defmacro gdev-test-assurance-ui--worker (&rest body)
  "Esegui BODY prima di consegnare l'uscita del processo simulato."
  (declare (indent 0))
  `(let (sentinel output operation)
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest arguments)
                  (setq sentinel (plist-get arguments :sentinel)
                        output (plist-get arguments :buffer)
                        operation (buffer-local-value 'gdev-workbench-operations--output output))
                  'worker)))
       (unwind-protect
           (progn
             (gdev-assurance--background (gdev-assurance--context) "adopt" '("core") "Adozione")
             ,@body)
         (when (buffer-live-p output) (kill-buffer output))))))

(defun gdev-test-assurance-ui--deliver (sentinel output id)
  "Consegna ID come uscita riuscita di SENTINEL nel buffer OUTPUT."
  (with-current-buffer output (insert id "\n"))
  (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
            ((symbol-function 'process-exit-status) (lambda (_) 0)))
    (funcall sentinel 'worker "finished\n")))

(defun gdev-test-assurance-ui--wait (process operation)
  "Attendi l'uscita di PROCESS e la sua pubblicazione in OPERATION."
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (or (process-live-p process)
                    (memq (gdev-workbench-operation-state (gdev-workbench-operation-current operation))
                          '(running stopping))))
      (accept-process-output process 0.05))
    (should-not (process-live-p process))
    (should (memq (gdev-workbench-operation-state (gdev-workbench-operation-current operation))
                  '(completed failed cancelled)))))

(ert-deftest gdev-test-assurance-ui-model-uses-one-database-snapshot ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance-ui--view root
        (setq gdev-assurance--transaction id)
        (let ((open (symbol-function 'gdev-assurance-db-open)) (calls 0))
          (cl-letf (((symbol-function 'gdev-assurance-db-open)
                     (lambda (&rest arguments) (cl-incf calls) (apply open arguments))))
            (gdev-assurance--read-model))
          (should (= 1 calls)))))))

(ert-deftest gdev-test-assurance-ui-project-reader-refuses-a-write-command ()
  (gdev-test-assurance--with-root root
    (should-error (gdev-assurance-project-data root nil "open") :type 'user-error)
    (should-not (file-exists-p (gdev-assurance-db-file root)))))

(ert-deftest gdev-test-assurance-ui-adoption-keeps-the-history-selected-during-the-job ()
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-adoption--git root)
    (let ((closed (gdev-test-assurance--open db)))
      (gdev-process-advance db closed 'CANCELLED :actor "persona" :actor-kind 'human)
      (gdev-test-assurance-ui--view root
        (gdev-test-assurance-ui--worker
          (gdev-assurance-select closed)
          (let ((id (gdev-adoption-adopt root 'core :actor "persona" :actor-kind 'human)))
            (gdev-test-assurance-ui--deliver sentinel output id))
          (should (equal closed gdev-assurance--transaction))
          (should-not (gdev-workspace-state-get 'gdev-assurance-transaction)))))))

(ert-deftest gdev-test-assurance-ui-cancelled-adoption-never-activates-a-late-success ()
  (gdev-test-assurance--with-root root
    (gdev-test-adoption--git root)
    (gdev-test-assurance-ui--view root
      (gdev-test-assurance-ui--worker
        (gdev-workbench-operation-report operation 'stopping)
        (let ((id (gdev-adoption-adopt root 'core :actor "persona" :actor-kind 'human)))
          (gdev-test-assurance-ui--deliver sentinel output id))
        (should (eq 'cancelled (gdev-workbench-operation-state
                                (car (gdev-workspace-state-get 'gdev-workbench-operations)))))
        (should (string-search "interrotta" gdev-assurance--notice))
        (should-not gdev-assurance--transaction)
        (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))))))

(ert-deftest gdev-test-assurance-ui-adoption-refreshes-its-view-without-taking-the-document-focus ()
  (gdev-test-assurance--with-root root
    (gdev-test-adoption--git root)
    (gdev-test-assurance-ui--view root
      (let ((view (current-buffer)) (document (generate-new-buffer "Documento durante l'adozione")))
        (unwind-protect
            (gdev-test-assurance-ui--worker
              (switch-to-buffer document)
              (let ((id (gdev-adoption-adopt root 'core :actor "persona" :actor-kind 'human)))
                (gdev-test-assurance-ui--deliver sentinel output id)
                (should (equal id (buffer-local-value 'gdev-assurance--transaction view))))
              (should (eq document (window-buffer (selected-window)))))
          (kill-buffer document))))))

(ert-deftest gdev-test-assurance-ui-worker-publishes-its-final-result-once ()
  (gdev-test-assurance--with-root root
    (gdev-test-adoption--git root)
    (gdev-test-assurance-ui--view root
      (gdev-test-assurance-ui--worker
        (let ((id (gdev-adoption-adopt root 'core :actor "persona" :actor-kind 'human))
              (refresh (symbol-function 'gdev-assurance-refresh)) (calls 0))
          (cl-letf (((symbol-function 'gdev-assurance-refresh)
                     (lambda () (cl-incf calls) (funcall refresh))))
            (gdev-test-assurance-ui--deliver sentinel output id)
            (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_) 0)))
              (funcall sentinel 'worker "finished twice\n")))
          (should (= 1 calls))
          (should (equal id (plist-get (gdev-assurance-workspace-active) :id))))))))

(ert-deftest gdev-test-assurance-ui-worker-discards-publication-after-its-space-closes ()
  (gdev-test-assurance--with-root root
    (gdev-test-adoption--git root)
    (gdev-test-assurance-ui--view root
      (let ((origin (gdev-workspace-state-id)))
        (gdev-test-assurance-ui--worker
          (tab-bar-new-tab)
          (gdev-workspace-state-ensure-id)
          (tab-bar-close-tab 1)
          (let ((selected (gdev-workspace-state-id))
                (id (gdev-adoption-adopt root 'core :actor "persona" :actor-kind 'human)))
            (gdev-test-assurance-ui--deliver sentinel output id)
            (should (eq selected (gdev-workspace-state-id))))
          (should-not (gdev-workspace-state-find origin))
          (should-not (gdev-workspace-state-get 'gdev-assurance-transaction)))))))

(ert-deftest gdev-test-assurance-ui-worker-distinguishes-interruption-and-failure ()
  (dolist (case '((exit 130 cancelled) (signal 2 cancelled) (exit 1 failed)))
    (gdev-test-assurance--with-root root
      (gdev-test-assurance-ui--view root
        (gdev-test-assurance-ui--worker
          (with-current-buffer output (insert "Dettagli della prova\n"))
          (cl-letf (((symbol-function 'process-status) (lambda (_) (car case)))
                    ((symbol-function 'process-exit-status) (lambda (_) (cadr case))))
            (funcall sentinel 'worker "exit\n"))
          (should (eq (nth 2 case) (gdev-workbench-operation-state (gdev-workbench-operation-current operation))))
          (should (eq (if (eq (nth 2 case) 'failed) 'gdev-ui-status-error 'gdev-ui-status-warning)
                      gdev-assurance--notice-face))
          (should-not (file-exists-p (gdev-assurance-db-file root))))))))

(ert-deftest gdev-test-assurance-ui-browsing-never-creates-an-archive ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (should (eq gdev-ui-view-profile 'document))
      (should (eq (gdev-layout--role (current-buffer)) 'editor))
      (should (eq (key-binding (kbd "q")) #'gdev-close-document))
      (should (string-search "Nessun archivio" (buffer-string)))
      (should-not (buffer-modified-p))
      (let ((button (gdev-test-assurance-ui--button '(action "Standard"))))
        (should button)
        (button-activate button)
        (should (eq gdev-assurance--section 'standards)))
      (should (string-search "owasp-asvs" (buffer-string)))
      (should-not (file-exists-p (expand-file-name ".gdev" root))))))

(ert-deftest gdev-test-assurance-ui-new-transaction-uses-the-common-writer-and-workspace-state ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Modifica dall'editor"))
                ((symbol-function 'completing-read) (lambda (&rest _) "core")))
        (call-interactively #'gdev-assurance-new))
      (should (equal "GT-0001" gdev-assurance--transaction))
      (should (equal "GT-0001" (plist-get (gdev-assurance-workspace-active) :id)))
      (should (eq 'controls gdev-assurance--section))
      (gdev-assurance-db-with-open (db root)
        (should (equal "Modifica dall'editor" (alist-get 'title (gdev-process-get db "GT-0001"))))))))

(ert-deftest gdev-test-assurance-ui-specific-proof-and-state-change-reuse-the-kernel ()
  (gdev-test-assurance--with-archive (root db)
    (let* ((target "owasp-asvs#V1.2.1") (id (gdev-test-standard--start db root (list target)))
           (report (expand-file-name "report.txt" root)))
      (write-region "Rapporto" nil report nil 'silent)
      (gdev-test-assurance-ui--view root
        (gdev-assurance-select id)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _)
                     (should (equal "REVIEWING" (cdr (assoc "In revisione" choices))))
                     "In revisione")))
          (should-error (gdev-assurance-advance) :type 'gdev-process-refused))
        (should (eq 'VERIFYING (alist-get 'state (gdev-process-get db id))))
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) report))
                  ((symbol-function 'completing-read) (lambda (&rest _) "Positivo")))
          (gdev-assurance-proof target))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "In revisione")))
          (gdev-assurance-advance))
        (should (eq 'REVIEWING (alist-get 'state (gdev-process-get db id))))
        (should (string-search "Soddisfatto" (buffer-string)))
        (should-not (gdev-assurance-verify db))))))

(ert-deftest gdev-test-assurance-ui-cancel-and-changed-workspace-never-write ()
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-assurance-ui--view root
      (let ((before (length (gdev-process-list db))))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (signal 'quit nil))))
          (should (eq 'cancelled (condition-case nil (gdev-assurance-new) (quit 'cancelled)))))
        (should (= before (length (gdev-process-list db))))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (tab-bar-new-tab) "Cambio di spazio"))
                  ((symbol-function 'completing-read) (lambda (&rest _) "core")))
          (should-error (gdev-assurance-new) :type 'user-error))
        (should (= before (length (gdev-process-list db))))
        (tab-bar-select-tab 1)))))

(ert-deftest gdev-test-assurance-ui-confirmation-uses-the-digest-reviewed-in-the-view ()
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assurance--open db))
           (ref (gdev-assurance-request-submit db id "advance" ["CLASSIFIED"])))
      (gdev-test-assurance-ui--view root
        (gdev-assurance-select id)
        (gdev-assurance-section 'requests)
        (let ((button (gdev-test-assurance-ui--button (list 'confirm ref))))
          (should button)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))) (button-activate button))
          (should (eq 'PROPOSED (alist-get 'state (gdev-process-get db id))))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (button-activate button)))
        (should (eq 'CLASSIFIED (alist-get 'state (gdev-process-get db id))))
        (should-not (gdev-test-assurance-ui--button (list 'confirm ref)))
        (should-not (gdev-assurance-verify db))))))

(ert-deftest gdev-test-assurance-ui-redraw-and-filter-use-cached-data-and-preserve-the-target ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (gdev-assurance-catalog "owasp-asvs")
      (gdev-assurance-next)
      (goto-char (point-min))
      (let* ((position (text-property-not-all (point-min) (point-max) 'gdev-assurance-row nil))
             (identity (get-text-property position 'gdev-assurance-row)))
        (goto-char position)
        (cl-letf (((symbol-function 'gdev-assurance-data) (lambda (&rest _) (ert-fail "Un ridisegno non deve rileggere l'archivio"))))
          (gdev-assurance--render)
          (should (equal identity (get-text-property (point) 'gdev-assurance-row)))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "V1.2.1"))) (gdev-assurance-filter)))
        (should (string-search "V1.2.1" (buffer-string)))
        (should-not (string-search "V1.2.2\n" (buffer-string)))))))

(ert-deftest gdev-test-assurance-ui-reader-nests-without-seeing-a-concurrent-commit ()
  (gdev-test-assurance--with-archive (root writer)
    (sqlite-pragma writer "journal_mode = WAL")
    (gdev-test-assurance--open writer)
    (gdev-assurance-call-with-reader
     root (lambda (_)
            (should (= 1 (length (alist-get 'transactions (gdev-assurance-data "list" root)))))
            (gdev-test-assurance--open writer)
            (should (= 1 (length (alist-get 'transactions (gdev-assurance-data "list" root)))))))
    (should (= 2 (length (alist-get 'transactions (gdev-assurance-data "list" root)))))))

(ert-deftest gdev-test-assurance-ui-changing-project-clears-only-an-unrelated-active-transaction ()
  (gdev-test--with-layout
    (gdev-test-assurance--with-archive (root db)
      (gdev-test-assurance--with-root other
        (let ((id (gdev-test-assurance--open db)))
          (gdev-workspace-set-roots (list root))
          (gdev-assurance-workspace-select root id)
          (make-directory (expand-file-name "src" root))
          (gdev-workspace-set-roots (list (expand-file-name "src" root)))
          (should (equal id (plist-get (gdev-assurance-workspace-active) :id)))
          (gdev-workspace-set-roots (list (file-name-directory (directory-file-name root))))
          (should (equal id (plist-get (gdev-assurance-workspace-active) :id)))
          (gdev-workspace-set-roots (list other))
          (should-not (gdev-workspace-state-get 'gdev-assurance-transaction)))))))

(ert-deftest gdev-test-assurance-ui-profile-decisions-work-from-the-row-key-and-cli ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance-ui--view root
        (gdev-assurance-select id)
        (goto-char (point-min))
        (goto-char (prop-match-beginning (text-property-search-forward 'gdev-assurance-row '(control "GES-C03") #'equal)))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Deroga autorizzata"))
                  ((symbol-function 'read-string) (lambda (&rest _) "Eccezione esaminata")))
          (call-interactively (key-binding (kbd "d"))))
        (should (eq 'waiver (alist-get 'kind (car (gdev-decision-list db id)))))
        (should (= 0 (car (gdev-test-assurance--cli root "decision" id "GES-C03" "not-applicable" "Fuori perimetro"))))
        (gdev-assurance-refresh)
        (should (string-search "Non applicabile" (buffer-string)))
        (should-not (gdev-assurance-verify db))))))

(ert-deftest gdev-test-assurance-ui-agent-reads-can-use-the-active-transaction-without-changing-project ()
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-assurance--with-root other
      (gdev-test-assurance-ui--view root
        (let ((id (gdev-test-assurance--open db)))
          (gdev-assurance-select id)
          (should (equal id (alist-get 'id (alist-get 'assurance_transaction (gdev-agent-interface--status)))))
          (should (equal id (alist-get 'id (alist-get 'transaction (gdev-test-assurance--live "show" "" "")))))
          (should-error (gdev-test-assurance--live "show" "" other))
          (gdev-assurance-workspace-clear)
          (should-error (gdev-test-assurance--live "show" "" "")))))))

(ert-deftest gdev-test-assurance-ui-modeline-does-not-read-the-database-and-opens-the-active-root ()
  (load (gdev-module-file :ui 'modeline ".el") nil t t)
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-assurance-ui--view root
      (let ((id (gdev-test-assurance--open db)))
        (gdev-assurance-select id)
        (cl-letf (((symbol-function 'sqlite-select) (lambda (&rest _) (ert-fail "La barra di stato non deve leggere SQLite"))))
          (should (equal id (substring-no-properties (gdev-modeline--assurance)))))
        (gdev-test-assurance--with-root other
          (gdev-assurance-show other)
          (gdev-assurance-show-active)
          (should (file-equal-p root gdev-assurance--root))
          (should (equal id gdev-assurance--transaction)))))))

(ert-deftest gdev-test-assurance-ui-readers-refuse-unsaved-files-and-external-links ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance--with-root other
      (let* ((file (expand-file-name "source.el" root)) (outside (expand-file-name "outside.el" other)))
        (write-region "source" nil file nil 'silent)
        (write-region "outside" nil outside nil 'silent)
        (gdev-test-assurance-ui--view root
          (let ((context (gdev-assurance--context)) (buffer (find-file-noselect file)))
            (unwind-protect
                (progn
                  (with-current-buffer buffer (insert "modifica"))
                  (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) file)))
                    (should-error (gdev-assurance--read-file context "File: ")))
                  (make-symbolic-link outside (expand-file-name "link.el" root))
                  (should-error (gdev-assurance-visit (expand-file-name "link.el" root))))
              (with-current-buffer buffer (set-buffer-modified-p nil))
              (kill-buffer buffer))))))))

(ert-deftest gdev-test-assurance-ui-all-sections-render-and-official-source-is-an-explicit-action ()
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (gdev-test-assurance-ui--view root
        (gdev-assurance-select id)
        (dolist (section gdev-assurance--sections)
          (gdev-assurance-section (car section))
          (should-not gdev-assurance--error)
          (should-not (buffer-modified-p)))
        (gdev-assurance-catalog "ieee-1012")
        (let (url)
          (cl-letf (((symbol-function 'browse-url) (lambda (value &rest _) (setq url value))))
            (button-activate (gdev-test-assurance-ui--button '(catalog source))))
          (should (string-prefix-p "https://standards.ieee.org/" url)))))))

(ert-deftest gdev-test-assurance-ui-adoption-completes-in-its-original-inactive-workspace ()
  (gdev-test-assurance--with-root root
    (gdev-test-adoption--git root)
    (gdev-test-assurance-ui--view root
      (let* ((context (gdev-assurance--context))
             (process (gdev-assurance--background context "adopt" '("core") "Adozione di prova"))
             (output (process-buffer process))
             (operation (buffer-local-value 'gdev-workbench-operations--output output)))
        (unwind-protect
            (progn
              (tab-bar-new-tab)
              (gdev-workspace-state-ensure-id)
              (gdev-test-assurance-ui--wait process operation)
              (should (= 0 (process-exit-status process)))
              (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))
              (let ((tab (gdev-workspace-state-find (plist-get context :space))))
                (should (equal "GT-0001" (plist-get (gdev-workspace-state-read 'gdev-assurance-transaction tab) :id))))
              (gdev-assurance-db-with-open (db root)
                (should (eq 'PROPOSED (alist-get 'state (gdev-process-get db "GT-0001"))))
                (should (eq 'reconstructed (alist-get 'origin (car (gdev-evidence-list db "GT-0001")))))))
          (when (process-live-p process) (delete-process process))
          (when (buffer-live-p output) (kill-buffer output)))))))

(ert-deftest gdev-test-assurance-ui-background-human-writes-cannot-be-launched-by-the-agent-channel ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (let ((gdev-process-origin 'agent))
        (should-error (gdev-assurance--background (gdev-assurance--context) "adopt" '("core") "Adozione") :type 'gdev-process-refused))
      (should-not (file-exists-p (gdev-assurance-db-file root))))))

(ert-deftest gdev-test-assurance-ui-adoption-does-not-activate-in-a-changed-project ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance--with-root other
      (gdev-test-adoption--git root)
      (gdev-test-assurance-ui--view root
        (gdev-workspace-set-roots (list root))
        (let* ((process (gdev-assurance--background (gdev-assurance--context) "adopt" '("core") "Adozione"))
               (output (process-buffer process))
               (operation (buffer-local-value 'gdev-workbench-operations--output output)))
          (unwind-protect
              (progn
                (gdev-workspace-set-roots (list other))
                (gdev-test-assurance-ui--wait process operation)
                (should (= 0 (process-exit-status process)))
                (should-not (gdev-workspace-state-get 'gdev-assurance-transaction))
                (should-not gdev-assurance--transaction)
                (should (string-search "progetto dello spazio è cambiato" gdev-assurance--notice))
                (should (file-exists-p (gdev-assurance-db-file root)))
                (should-not (file-exists-p (gdev-assurance-db-file other))))
            (when (process-live-p process) (delete-process process))
            (when (buffer-live-p output) (kill-buffer output))))))))

(ert-deftest gdev-test-assurance-ui-background-launch-failure-clears-the-pending-notice ()
  (gdev-test-assurance--with-root root
    (gdev-test-assurance-ui--view root
      (let ((before (buffer-list)))
        (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Processo non disponibile"))))
          (should-error (gdev-assurance--background (gdev-assurance--context) "adopt" '("core") "Adozione")))
        (should (eq 'gdev-ui-status-error gdev-assurance--notice-face))
        (should (string-search "non avviata" gdev-assurance--notice))
        (should-not (string-search "in corso" gdev-assurance--notice))
        (should-not (seq-difference (buffer-list) before))
        (should-not (file-exists-p (gdev-assurance-db-file root)))))))

(ert-deftest gdev-test-assurance-ui-lavorazioni-reuse-due-controls-and-require-a-standard-choice ()
  (gdev-test-assurance--with-archive (root db)
    (let* ((target "owasp-asvs#V1.2.1") (id (gdev-test-standard--start db root (list target)))
           (context (make-gdev-lavorazione--contesto :radice root))
           (other (gdev-test-assurance--open db)))
      (should-error (gdev-assurance-lavorazione-standards context other))
      (gdev-test-standard--proof db root id target)
      (gdev-test-assurance--step db id 'REVIEWING)
      (gdev-assurance-lavorazione-assess context id)
      (gdev-assurance-lavorazione-standards context id)
      (write-region "cambiato" nil (expand-file-name "test.txt" root) nil 'silent)
      (should-error (gdev-assurance-lavorazione-standards context id))
      (should-error (gdev-assurance-lavorazione-assess context id)))))

(ert-deftest gdev-test-assurance-ui-adoption-rechecks-the-initial-inventory-after-another-writer-wins ()
  (gdev-test-assurance--with-archive (root db)
    (gdev-test-adoption--git root)
    (let ((transaction (symbol-function 'gdev-assurance-db-transaction))
          (open (symbol-function 'gdev-assurance-db-open)) (first t) ready)
      (cl-letf (((symbol-function 'gdev-assurance-db-open)
                 (lambda (&rest args) (prog1 (apply open args) (setq ready t))))
                ((symbol-function 'gdev-assurance-db-transaction)
                 (lambda (database function)
                   (when (and ready first)
                     (setq first nil)
                     (gdev-adoption-adopt root 'core :actor "seconda persona" :actor-kind 'human))
                   (funcall transaction database function))))
        (should-error (gdev-adoption-adopt root 'core :actor "prima persona" :actor-kind 'human)))
      (should (= 1 (length (gdev-record-list db nil 'baseline))))
      (should (= 1 (length (gdev-process-list db))))
      (should-not (gdev-assurance-verify db)))))

;;; gdev-assurance-workbench-test.el ends here
