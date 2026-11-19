;;; gdev-mise-test.el --- Prove dell'ambiente di progetto mise -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica con processi isolati lettura, condivisione e aggiornamento
;; dell'ambiente nei documenti in attesa.

;;; Code:

(require 'ert)
(require 'gdev-lib)

(defvar gdev-mise--requests)

(defun gdev-test--load-mise ()
  "Carica il fornitore di ambiente per le prove dirette."
  (require 'gdev-mise (gdev-config-file "modules/tools/build/gdev-mise")))

(defun gdev-test--wait-mise (request)
  "Attendi REQUEST nella prova, con un limite per gli errori."
  (let ((deadline (+ (float-time) 5)))
    (while (and (eq (gdev-mise--request-status request) 'pending)
                (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (should-not (eq (gdev-mise--request-status request) 'pending)))

(ert-deftest gdev-test-mise-rejects-an-invalidated-environment-after-failure ()
  "Una nuova configurazione che fallisce non riusa le versioni precedenti."
  (gdev-test--load-mise)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-mise-invalid-" t)))
         (default-directory root)
         (tool (expand-file-name "mise" root))
         (exec-path (cons root exec-path))
         (gdev-mise--requests (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file tool
            (insert "#!/bin/sh\ntest ! -f errore || exit 1\n"
                    "if test -f incompleta; then printf '{'; exit 0; fi\n"
                    "printf '{\"VERSIONE\":\"nuova\"}\\n'\n"))
          (set-file-modes tool #o700)
          (puthash root (make-gdev-mise--request :stamp (gdev-mise--stamp root)
                                               :status 'ready :environment '((VERSIONE . "vecchia")))
                   gdev-mise--requests)
          (with-temp-file "mise.toml" (insert "[tools]\n"))
          (with-temp-file "errore")
          (should-not (gdev-mise-environment root))
          (let ((request (gethash root gdev-mise--requests)))
            (gdev-test--wait-mise request)
            (should (eq (gdev-mise--request-status request) 'failed))
            (should-not (gdev-mise--request-environment request)))
          (delete-file "errore")
          (with-temp-file "incompleta")
          (let ((request (gdev-mise--start root (gdev-mise--stamp root))))
            (gdev-test--wait-mise request)
            (should (eq (gdev-mise--request-status request) 'failed))
            (should-not (gdev-mise--request-process request)))
          (delete-file "incompleta")
          (gdev-mise--start root (gdev-mise--stamp root))
          (gdev-test--wait-mise (gethash root gdev-mise--requests))
          (should (equal (gdev-mise-environment root) '((VERSIONE . "nuova")))))
      (delete-directory root t))))

(ert-deftest gdev-test-mise-reuses-the-pending-environment ()
  "L'apertura anticipata e la lettura del file condividono la richiesta."
  (gdev-test--load-mise)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-mise-test-" t)))
         (default-directory root)
         (tool (expand-file-name "mise" root))
         (exec-path (cons root exec-path))
         (gdev-mise--requests (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file "mise.toml" (insert "[tools]\n"))
          (with-temp-file tool
            (insert "#!/bin/sh\necho invocazione >> chiamate\n"
                    "echo diagnostica >&2\nsleep 0.1\n"
                    "printf '{\"GDEV_MISE_TEST\":\"attivo\"}\\n'\n"))
          (set-file-modes tool #o700)
          (let* ((stamp (gdev-mise--stamp root))
                 (request (gdev-mise--start root stamp)))
            (should (eq request (gdev-mise--start root stamp)))
            (gdev-test--wait-mise request)
            (should (equal (gdev-mise-environment root) '((GDEV_MISE_TEST . "attivo"))))
            (should (equal (gdev-mise-environment root) '((GDEV_MISE_TEST . "attivo"))))
            (should (equal (gdev-read-file-contents "chiamate") "invocazione\n"))
            (should-not (gdev-mise--request-process request))))
      (when-let* ((request (gethash root gdev-mise--requests))
                  (process (gdev-mise--request-process request))
                  ((process-live-p process)))
        (delete-process process))
      (delete-directory root t))))

(ert-deftest gdev-test-mise-updates-an-already-open-document-without-waiting ()
  "L'apertura termina prima di mise. La risposta sveglia il documento corretto."
  (gdev-test--load-mise)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-mise-late-" t)))
         (default-directory root)
         (tool (expand-file-name "mise" root))
         (exec-path (cons root exec-path))
         (gdev-mise--requests (make-hash-table :test #'equal))
         (gdev-project-environment-functions '(gdev-mise-apply))
         (gdev-trusted-projects (list (file-truename root)))
         (buffer (generate-new-buffer " *gdev mise documento*"))
         (nested-buffer (generate-new-buffer " *gdev mise sottocartella*"))
         (nested (file-name-as-directory (expand-file-name "sotto" root)))
         observed)
    (unwind-protect
        (progn
          (make-directory nested)
          (push (file-truename nested) gdev-trusted-projects)
          (with-temp-file "mise.toml")
          (with-temp-file tool
            (insert "#!/bin/sh\ncase \"$PWD\" in\n"
                    "  */sotto) printf '{\"GDEV_MISE_TARDIVO\":\"sotto\"}\\n' ;;\n"
                    "  *) while test ! -f sblocco; do sleep 0.05; done\n"
                    "     printf '{\"GDEV_MISE_TARDIVO\":\"pronto\"}\\n' ;;\nesac\n"))
          (set-file-modes tool #o700)
          (dolist (document (list buffer nested-buffer))
            (with-current-buffer document
              (setq default-directory (if (eq document buffer) root nested)
                    buffer-file-name (expand-file-name "documento.txt" default-directory))
              (add-hook 'gdev-project-environment-ready-hook
                        (lambda () (push (cons (current-buffer) (getenv "GDEV_MISE_TARDIVO")) observed))
                        nil t)
              (cl-letf (((symbol-function 'accept-process-output)
                         (lambda (&rest _) (ert-fail "L'apertura ha aspettato il processo"))))
                (gdev-use-project-tools))
              (should (eq gdev-project-environment-status 'pending))
              (should-error (gdev-require-project-environment) :type 'user-error)
              (should-not (getenv "GDEV_MISE_TARDIVO"))))
          (with-temp-file (expand-file-name "mise.toml" nested))
          (with-temp-file "sblocco")
          (gdev-test--wait-mise (gethash root gdev-mise--requests))
          (gdev-test--wait-mise (gethash nested gdev-mise--requests))
          (should (equal (alist-get buffer observed) "pronto"))
          (should (equal (alist-get nested-buffer observed) "sotto"))
          (with-current-buffer buffer
            (should (gdev-project-environment-ready-p))
            (should (equal (getenv "GDEV_MISE_TARDIVO") "pronto"))))
      (maphash (lambda (_ request)
                 (when-let* ((process (gdev-mise--request-process request))
                             ((process-live-p process)))
                   (delete-process process)))
               gdev-mise--requests)
      (kill-buffer buffer)
      (kill-buffer nested-buffer)
      (delete-directory root t))))

(ert-deftest gdev-test-mise-result-requires-an-environment-object ()
  "Distingue un ambiente vuoto da JSON malformato o da valori non testuali."
  (gdev-test--load-mise)
  (with-temp-buffer
    (pcase-dolist (`(,json . ,expected)
                   '(("{}" t)
                     ("{\"VERSIONE\":\"locale\"}" t (VERSIONE . "locale"))
                     ("{\"VERSIONE\":false}")
                     ("[]")
                     ("{} {}")
                     ("{")
                     ("")))
      (erase-buffer)
      (insert json)
      (should (equal (gdev-mise--result (current-buffer)) expected)))))

(ert-deftest gdev-test-mise-failed-process-start-releases-resources ()
  "Un eseguibile mancante termina la richiesta e libera entrambe le aree d'uscita."
  (gdev-test--load-mise)
  (let ((gdev-mise--requests (make-hash-table :test #'equal))
        outputs)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest options)
                 (setq outputs (list (plist-get options :buffer) (plist-get options :stderr)))
                 (signal 'file-error '("Avvio non riuscito")))))
      (let ((request (gdev-mise--start default-directory '(prova))))
        (should (eq (gdev-mise--request-status request) 'failed))
        (should-not (gdev-mise--request-process request))
        (should (equal (mapcar #'buffer-live-p outputs) '(nil nil)))))))

(ert-deftest gdev-test-mise-rechecks-project-authorization-on-completion ()
  "Un documento revocato durante l'attesa non riceve il nuovo ambiente."
  (gdev-test--load-mise)
  (let ((gdev-project-environment-ready-hook '(ignore))
        (gdev-trusted-projects nil))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "documento.txt"))
      (let ((request (make-gdev-mise--request :buffers (list (current-buffer)))))
        (setq-local gdev-mise--buffer-request request
                    gdev-project-environment-status 'pending)
        (gdev-mise--publish default-directory request 'ready '((GDEV_MISE_REVOKED . "valore")))
        (should-not (getenv "GDEV_MISE_REVOKED"))
        (should-not gdev-mise--buffer-request)
        (should-not gdev-project-environment-status)
        (should-not (gdev-mise--request-buffers request))))))

(provide 'gdev-mise-test)
;;; gdev-mise-test.el ends here
