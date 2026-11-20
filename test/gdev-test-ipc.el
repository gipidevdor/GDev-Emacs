;;; gdev-test-ipc.el --- Prerequisiti dei servizi locali nelle prove -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; In CI anche un permesso mancante per avviare il servizio è un fallimento.

;;; Code:

(require 'ert)

(defun gdev-test-ipc-denied (reason)
  "Segnala il permesso mancante descritto da REASON."
  (if (equal (getenv "GDEV_TEST_REQUIRE_IPC") "1")
      (ert-fail reason)
    (message "Prova saltata: %s" reason)
    (ert-skip reason)))

(defun gdev-test-ipc-listen (family &rest arguments)
  "Apri un listener di prova di famiglia FAMILY con ARGUMENTS."
  (let ((system-messages-locale "C"))
    (condition-case err
        (apply #'make-network-process :server t :family family :noquery t arguments)
      (file-error
       (if (and (equal (nth 1 err) "Cannot bind server socket")
                (member (nth 2 err) '("Operation not permitted" "Permission denied")))
           (gdev-test-ipc-denied
            (format "Il sistema nega l'apertura di un socket %s: %s"
                    (if (eq family 'local) "Unix" family) (nth 2 err)))
         (signal (car err) (cdr err)))))))

(defun gdev-test-ipc-require-unix (directory)
  "Verifica che Emacs possa aprire un socket Unix nella DIRECTORY temporanea."
  (let ((path (expand-file-name "probe.sock" directory)))
    (delete-process (gdev-test-ipc-listen 'local :name "gdev-prova-unix" :service path))
    (when (file-exists-p path)
      (delete-file path))))

(provide 'gdev-test-ipc)
;;; gdev-test-ipc.el ends here
