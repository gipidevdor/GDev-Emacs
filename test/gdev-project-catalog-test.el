;;; gdev-project-catalog-test.el --- Regressioni dei cataloghi esterni -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'gdev-project)
(require 'gdev-evidence)

(defmacro gdev-test-project-catalog--fixture (&rest body)
  "Esegui BODY in una sorgente e vista isolate."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev-catalog-" t)))
          (descriptor '(:id "EXTERNAL" :path "catalog.json" :directories ("authority")))
          (source (expand-file-name "authority/gates.yaml" root))
          (target (expand-file-name "catalog.json" root))
          (record '((id . "GATE-1") (kind . "gate") (state . "IMPLEMENTATA")
                    (path . "authority/gates.yaml") (data . ((requisiti . ["REQ-1"]))))))
     (unwind-protect
         (progn
           (make-directory (file-name-directory source) t)
           (write-region "gate: not yet proven\n" nil source nil 'silent)
           (cl-labels ((publish (&optional records)
                         (with-temp-file target
                           (insert (json-serialize
                                    `((schema_version . 1) (id . "EXTERNAL")
                                      (inputs . ,(gdev-project-catalog-inputs root descriptor))
                                      (records . ,(or records (vector record)))))))))
             (publish)
             ,@body))
       (delete-directory root t))))

(ert-deftest gdev-test-project-catalog-preserves-source-status-and-no-approval ()
  (gdev-test-project-catalog--fixture
    (gdev-project-catalog-validate (list descriptor))
    (let* ((view (gdev-project-catalog-data root descriptor))
           (row (aref (alist-get 'records (alist-get 'catalog view)) 0)))
      (should (equal "CURRENT" (alist-get 'status view)))
      (should (equal "IMPLEMENTATA" (alist-get 'state row)))
      (should (equal ["REQ-1"] (alist-get 'requisiti (alist-get 'data row))))
      (should (eq :false (alist-get 'certification view)))
      (should (equal "NOT_VERIFIED" (alist-get 'human_approval view))))))

(ert-deftest gdev-test-project-catalog-invalidates-change-add-delete-and-snapshot ()
  (gdev-test-project-catalog--fixture
    (let* ((data (list :catalogs (list descriptor)))
           (before (gdev-project-inputs root data))
           (extra (expand-file-name "authority/new.yaml" root)))
      (write-region "new content" nil source nil 'silent)
      (should (equal "INVALID" (alist-get 'status (gdev-project-catalog-data root descriptor))))
      (should-not (equal before (gdev-project-inputs root data)))
      (publish)
      (write-region "new gate" nil extra nil 'silent)
      (should-error (gdev-project-catalog-read root descriptor))
      (publish)
      (delete-file extra)
      (should-error (gdev-project-catalog-read root descriptor))
      (publish)
      (delete-file source)
      (should-error (gdev-project-catalog-read root descriptor)))))

(ert-deftest gdev-test-project-catalog-rejects-duplicate-ids-paths-and-escaping-symlinks ()
  (gdev-test-project-catalog--fixture
    (publish (vector record record))
    (should-error (gdev-project-catalog-read root descriptor))
    (should-error (gdev-project-catalog-validate (list descriptor descriptor)))
    (should-error (gdev-project-catalog-validate '((:id "X" :path "../outside" :files ("a")))))
    (delete-file source)
    (make-symbolic-link "/etc/hosts" source)
    (should-error (gdev-project-catalog-inputs root descriptor))))

(ert-deftest gdev-test-project-catalog-malformed-missing-and-future-versions-fail-closed ()
  (gdev-test-project-catalog--fixture
    (dolist (text '("{" "{\"schema_version\":2}" "[]"))
      (write-region text nil target nil 'silent)
      (should (equal "INVALID" (alist-get 'status (gdev-project-catalog-data root descriptor)))))
    (delete-file target)
    (should-error (gdev-project-catalog-read root descriptor))))

(ert-deftest gdev-test-project-catalog-json-order-and-agent-query-are-stable ()
  (gdev-test-project-catalog--fixture
    (require 'gdev-assurance-actions)
    (with-temp-file target
      (insert (json-serialize `((schema_version . 1) (id . "EXTERNAL")
                               (inputs . ,(vconcat (mapcar #'reverse (append (gdev-project-catalog-inputs root descriptor) nil))))
                               (records . ,(vector record))))))
    (should (gdev-project-catalog-read root descriptor))
    (cl-letf (((symbol-function 'gdev-project-read) (lambda (_) (list :catalogs (list descriptor)))))
      (let ((page (gdev-assurance-agent-run root "catalogo" '("GATE-1"))))
        (should (= 1 (alist-get 'total page)))
        (should (equal "EXTERNAL" (alist-get 'catalog_id (aref (alist-get 'items page) 0))))
        (should (eq :false (alist-get 'certification page))))
      (should (= 0 (alist-get 'total (gdev-assurance-data "catalog" root "UNKNOWN"))))
      (should-error (gdev-assurance-data "catalog" root "GATE@bad")))))

(ert-deftest gdev-test-project-catalog-workbench-keeps-source-identity-and-opening ()
  (gdev-test-project-catalog--fixture
    (require 'gdev-assurance-workbench)
    (let ((gdev-assurance--root root)
          (gdev-assurance--filter "GATE-1")
          (gdev-assurance--page 0)
          (gdev-assurance--model
           `((detail . ((project . ((id . "DEMO") (name . "External project") (purpose . "Test") (profile . "quality") (requirements . [])))
                        (catalogs . ,(vector (gdev-project-catalog-data root descriptor)))))))
          opened)
      (with-temp-buffer
        (gdev-assurance--project)
        (goto-char (point-min))
        (should (search-forward "IMPLEMENTATA" nil t))
        (should (search-forward "authority/gates.yaml" nil t))
        (goto-char (point-min))
        (let (found)
          (while-let ((button (next-button (point))))
            (goto-char (button-end button))
            (when (equal '("EXTERNAL" "GATE-1") (button-get button 'gdev-assurance-focus))
              (setq found t)
              (cl-letf (((symbol-function 'gdev-assurance-visit) (lambda (file) (setq opened file))))
                (button-activate button))))
          (should found)))
      (should (file-equal-p opened source)))))

(ert-deftest gdev-test-project-catalog-work-procedure-refusal-names-the-contract ()
  (require 'gdev-work)
  (let ((work '(:version 1 :title "Task" :type feature :objective "Exercise contract" :scope "Fixture"
                :owner "Tests" :priority must :requirements ("REQ") :acceptance ("Checked")
                :procedure (:id "VERIFY" :version 1)))
        (project '(:requirements ((:id "REQ")) :procedures ((:id "VERIFY" :version 1 :types nil)))))
    (let ((error (should-error (gdev-work-validate work project) :type 'gdev-process-refused)))
      (should (string-match-p "VERIFY" (error-message-string error)))
      (should (string-match-p ":types" (error-message-string error))))
    (setf (plist-get (car (plist-get project :procedures)) :types) '("feature"))
    (should (eq work (gdev-work-validate work project)))))

(provide 'gdev-project-catalog-test)
