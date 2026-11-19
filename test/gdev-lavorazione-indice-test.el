;;; gdev-lavorazione-indice-test.el --- Prove del catalogo dei piani -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Controlla ricerca locale, nomi insoliti e annullamento del catalogo.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ucs-normalize)
(require 'gdev-lavorazione-indice)

(defun gdev-test-lavorazione-indice--attendi (pronto)
  "Attendi fino a quando PRONTO restituisce un valore."
  (let ((scadenza (+ (float-time) 4)))
    (while (and (not (funcall pronto)) (< (float-time) scadenza))
      (accept-process-output nil 0.02))
    (should (funcall pronto))))

(defun gdev-test-lavorazione-indice--esito (radici)
  "Restituisci la risposta del catalogo per RADICI."
  (let* (risposta
         (annulla (gdev-lavorazione-indice-avvia radici
                    (lambda (file stato) (setq risposta (list file stato))))))
    (unwind-protect
        (progn
          (should-not risposta)
          (gdev-test-lavorazione-indice--attendi (lambda () risposta))
          risposta)
      (funcall annulla))))

(ert-deftest gdev-test-lavorazione-indice-file-locali-e-nomi-letterali ()
  (let* ((radice (make-temp-file "gdev-lavorazioni-prova-" t))
         (cartella (expand-file-name "una cartella" radice))
         (primo (expand-file-name "per\nme.lavorazione" cartella))
         (secondo (expand-file-name "è vuoto.lavorazione" radice))
         (executable-find-reale (symbol-function 'executable-find)))
    (unwind-protect
        (progn
          (make-directory cartella)
          (write-region "" nil primo nil 'silent)
          (write-region "" nil secondo nil 'silent)
          (write-region "" nil (expand-file-name "nota.lavorazione.bak" cartella) nil 'silent)
          (write-region "" nil (expand-file-name ".privato.lavorazione" radice) nil 'silent)
          (make-symbolic-link radice (expand-file-name "anello" cartella))
          (dolist (usa-ripgrep '(nil t))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (comando &optional remoto)
                         (when (or usa-ripgrep (not (string-equal comando "rg")))
                           (funcall executable-find-reale comando remoto)))))
              (pcase-let ((`(,file ,stato)
                           (gdev-test-lavorazione-indice--esito
                            (list radice cartella radice "/ssh:esempio.invalid:/progetto/"))))
                (should (eq stato 'ok))
                (should (equal (mapcar #'ucs-normalize-NFC-string file)
                               (list primo secondo)))))))
      (delete-directory radice t))))

(ert-deftest gdev-test-lavorazione-indice-limite-delle-voci ()
  (let ((radice (make-temp-file "gdev-lavorazioni-limite-" t)))
    (unwind-protect
        (progn
          (dotimes (indice (1+ gdev-lavorazione-indice--limite))
            (write-region "" nil
                          (expand-file-name (format "%04d.lavorazione" indice) radice)
                          nil 'silent))
          (pcase-let ((`(,file ,stato) (gdev-test-lavorazione-indice--esito (list radice))))
            (should (eq stato 'limite))
            (should (= (length file) gdev-lavorazione-indice--limite))
            (should (equal (car file) (expand-file-name "0000.lavorazione" radice)))))
      (delete-directory radice t))))

(ert-deftest gdev-test-lavorazione-indice-remoto-non-avvia-processi ()
  (cl-letf (((symbol-function 'gdev-lavorazione-indice--processo)
             (lambda (&rest _) (ert-fail "Processo avviato per una cartella remota"))))
    (should (equal (gdev-test-lavorazione-indice--esito '("/ssh:esempio.invalid:/progetto/"))
                   '(nil ok)))))

(ert-deftest gdev-test-lavorazione-indice-annullamento-idempotente ()
  (let ((radice (list temporary-file-directory)) processo consegna esito)
    (cl-letf (((symbol-function 'gdev-lavorazione-indice--processo)
               (lambda (_radici rispondi)
                 (setq consegna rispondi
                       processo (make-pipe-process :name "gdev-prova-indice" :noquery t)))))
      (let ((annulla (gdev-lavorazione-indice-avvia radice (lambda (&rest _) (setq esito t)))))
        (funcall annulla)
        (accept-process-output nil 0.02)
        (should-not processo)
        (should-not esito))
      (let ((annulla (gdev-lavorazione-indice-avvia radice (lambda (&rest _) (setq esito t)))))
        (unwind-protect
            (progn
              (gdev-test-lavorazione-indice--attendi (lambda () processo))
              (should (process-live-p processo))
              (funcall annulla)
              (funcall annulla)
              (should-not (process-live-p processo))
              (funcall consegna nil 'ok)
              (should-not esito))
          (funcall annulla))))))

(ert-deftest gdev-test-lavorazione-indice-segnala-errore-di-avvio ()
  (cl-letf (((symbol-function 'gdev-lavorazione-indice--processo)
             (lambda (&rest _) (signal 'file-error '("Avvio non riuscito")))))
    (should (equal (gdev-test-lavorazione-indice--esito (list temporary-file-directory))
                   '(nil errore)))))

(ert-deftest gdev-test-lavorazione-indice-conserva-le-radici-valide ()
  (let* ((radice (make-temp-file "gdev-lavorazioni-parziale-" t))
         (piano (expand-file-name "stampa.lavorazione" radice))
         (assente (expand-file-name "assente" radice)))
    (unwind-protect
        (progn
          (write-region "" nil piano nil 'silent)
          (should (equal (gdev-test-lavorazione-indice--esito (list assente radice))
                         (list (list piano) 'errore))))
      (delete-directory radice t))))

(provide 'gdev-lavorazione-indice-test)
;;; gdev-lavorazione-indice-test.el ends here
