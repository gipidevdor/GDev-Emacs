;;; gdev-test-coverage-providers-test.el --- Prove dei fornitori di copertura -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Il rapporto viene consegnato solo dopo l'esportazione ed è di proprietà
;; dello spazio che lo ha richiesto.

;;; Code:

(require 'ert)

(ert-deftest gdev-test-coverage-python-preserves-test-exit-and-combines-profiles ()
  "Un fallimento pytest produce un rapporto e conserva il codice del test."
  (require 'gdev-test-coverage-providers)
  (let* ((scratch (make-temp-file "gdev coverage " t))
         (runner (expand-file-name "python di prova" scratch))
         (report (expand-file-name "rapporto.lcov" scratch)))
    (unwind-protect
        (progn
          (with-temp-file runner
            (insert "#!/bin/sh\ncase \"$3\" in\n"
                    "  run) printf 'dato' > \"$COVERAGE_FILE.1\"; exit 1 ;;\n"
                    "  combine) mv \"$COVERAGE_FILE.1\" \"$COVERAGE_FILE\" ;;\n"
                    "  lcov) [ -f \"$COVERAGE_FILE\" ] || exit 4\n"
                    "        printf 'SF:prova.py\\nDA:2,1\\nend_of_record\\n' > \"$5\" ;;\n"
                    "esac\n"))
          (set-file-modes runner #o700)
          (with-temp-buffer
            (should (= (process-file "sh" nil t nil "-c"
                                     (gdev-test-coverage--python-command runner scratch)) 1)))
          (should (file-regular-p report))
          (should-not (file-exists-p (concat report ".pending")))
          (should (string-match-p "DA:2,1" (gdev-read-file-contents report))))
      (delete-directory scratch t))))

(ert-deftest gdev-test-coverage-cmake-catalog-can-include-shared-and-module-libraries ()
  "Il catalogo ordinario continua a proporre eseguibili, LLVM vede anche librerie."
  (load (gdev-module-file :tools 'build ".el") nil t t)
  (let* ((root temporary-file-directory)
         (model (cons root '((configurations . (((name . "Debug")
                                                 (targets . (((jsonFile . "eseguibile.json"))
                                                             ((jsonFile . "libreria.json"))
                                                             ((jsonFile . "modulo.json"))
                                                             ((jsonFile . "archivio.json"))))))))))
         (outputs '(("eseguibile.json" "EXECUTABLE" "prova con spazi")
                    ("libreria.json" "SHARED_LIBRARY" "libprova.dylib")
                    ("modulo.json" "MODULE_LIBRARY" "componente.so")
                    ("archivio.json" "STATIC_LIBRARY" "libprova.a"))))
    (cl-letf (((symbol-function 'gdev-cmake--json)
               (lambda (file)
                 (pcase-let ((`(,_ ,kind ,name) (assoc (file-name-nondirectory file) outputs)))
                   `((type . ,kind) (artifacts . (((path . ,name)))))))))
      (should (equal (gdev-cmake--artifact-paths model root "Debug")
                     (list t (expand-file-name "prova con spazi" root))))
      (should (equal (gdev-cmake--artifact-paths
                      model root "Debug" '("EXECUTABLE" "SHARED_LIBRARY" "MODULE_LIBRARY"))
                     (cons t (mapcar (lambda (name) (expand-file-name name root))
                                     '("prova con spazi" "libprova.dylib" "componente.so"))))))))

(ert-deftest gdev-test-coverage-provider-publishes-only-while-workspace-is-open ()
  "Il report sopravvive al cambio di scheda ed è scartato alla chiusura."
  (require 'gdev-test-coverage-providers)
  (gdev-test--with-layout
    (let* ((frame (selected-frame))
           (owner (gdev-workspace-state-ensure-id frame))
           (directory (make-temp-file "gdev-copertura-test-" t))
           shown)
      (unwind-protect
          (cl-labels ((try-report (name)
                        (let* ((scratch (expand-file-name name directory))
                               (report (expand-file-name "rapporto.lcov" scratch))
                               (job (gdev-test-coverage--make-job :root directory :owner owner
                                                                  :frame frame :scratch scratch)))
                          (make-directory scratch)
                          (with-temp-file report (insert "risultato"))
                          (gdev-test-coverage--finish job report)
                          (should-not (file-exists-p scratch)))))
            (cl-letf (((symbol-function 'gdev-test-coverage-publish)
                       (lambda (report root origin window)
                         (should (file-regular-p report))
                         (push (list root origin window) shown)
                         t)))
              (tab-bar-new-tab)
              (let ((active (selected-window)))
                (try-report "aperto")
                (should (eq active (selected-window))))
              (should (equal shown (list (list directory owner frame))))
              (tab-bar-close-tab 1)
              (try-report "chiuso")
              (should (= (length shown) 1))))
        (delete-directory directory t)))))

(ert-deftest gdev-test-coverage-provider-interrupts-the-export-from-compilation ()
  "Interrompi compilazione annulla anche l'esportazione LLVM e ne pulisce i file."
  (require 'gdev-test-coverage-providers)
  (gdev-test--with-layout
    (let* ((scratch (make-temp-file "gdev-copertura-llvm-" t))
           (profdata (expand-file-name "insieme.profdata" scratch))
           (report (expand-file-name "rapporto.lcov" scratch))
           (runner (expand-file-name "llvm-cov" scratch))
           (buffer (generate-new-buffer " *Esportazione LLVM*"))
           (job (gdev-test-coverage--make-job :root scratch :scratch scratch :buffer buffer
                                              :owner (gdev-workspace-state-ensure-id)
                                              :frame (selected-frame)))
           (deadline (+ (float-time) 4)))
      (unwind-protect
          (progn
            (with-temp-file profdata (insert "misura"))
            (with-temp-file runner (insert "#!/bin/sh\nexec sleep 30\n"))
            (set-file-modes runner #o700)
            (cl-letf (((symbol-function 'gdev-cmake--codemodel) (lambda (_) 'catalogo))
                      ((symbol-function 'gdev-cmake--artifact-paths) (lambda (&rest _) (list t runner)))
                      ((symbol-function 'gdev-test-coverage-publish)
                       (lambda (&rest _) (ert-fail "Esportazione interrotta pubblicata"))))
              (with-current-buffer buffer (compilation-mode))
              (gdev-test-coverage--export-llvm job runner scratch profdata report)
              (with-current-buffer buffer
                (should (eq (get-buffer-process buffer) (gdev-test-coverage--job-process job)))
                (kill-compilation))
              (while (and (gdev-test-coverage--job-scratch job) (< (float-time) deadline))
                (accept-process-output nil 0.03))
              (should-not (file-directory-p scratch))))
        (gdev-test-coverage--cleanup job)
        (kill-buffer buffer)))))

(provide 'gdev-test-coverage-providers-test)
;;; gdev-test-coverage-providers-test.el ends here
