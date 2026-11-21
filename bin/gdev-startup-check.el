;;; gdev-startup-check.el --- Riscontro dell'avvio ordinario -*- lexical-binding: t; no-byte-compile: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Caricato dall'ingresso esplicito dopo init.el. Il bootstrap attende il
;; riscontro della vera istanza, senza dedurre il successo dall'installazione.
;;; Code:
(defconst gdev-startup-check--root
  (file-name-directory (directory-file-name (file-name-directory (file-truename load-file-name)))))

(defun gdev-startup-check-inspect (&optional require-workbench require-graphical)
  "Osserva l'avvio; REQUIRE-WORKBENCH e REQUIRE-GRAPHICAL richiedono la GUI."
  (let* ((root (bound-and-true-p gdev-config-directory))
         (private (bound-and-true-p gdev-user-directory))
         (workbench (bound-and-true-p gdev-layout-mode))
         (graphical (display-graphic-p))
         (reason (cond
                  ((or (null root) (not (file-equal-p root gdev-startup-check--root)))
                   "Emacs non ha caricato il checkout GDev richiesto")
                  ((bound-and-true-p init-file-had-error) "Errore durante il caricamento della configurazione")
                  ((bound-and-true-p gdev-state-startup-issue) "Il profilo GDev è sospeso: verifica l'archivio di stato")
                  ((bound-and-true-p gdev-modules-private-errors) "La configurazione privata contiene errori")
                  ((bound-and-true-p gdev-failed-modules) "Uno o più moduli GDev non si sono caricati")
                  ((not (featurep 'gdev-core)) "Il nucleo GDev non è attivo")
                  ((and require-workbench (not workbench))
                   "L'interfaccia GDev non è attiva: controlla :ui workbench nel tuo init.el privato")
                  ((and require-graphical (not graphical)) "Non è stata aperta una finestra grafica"))))
    `((schema_version . 1) (ok . ,(if reason :false t)) (pid . ,(emacs-pid))
      (root . ,(or root :null)) (private . ,(or private :null))
      (workbench . ,(if workbench t :false)) (graphical . ,(if graphical t :false))
      (reason . ,(or reason :null)))))

(defun gdev-startup-check-run ()
  "Verifica l'istanza aperta e pubblica il riscontro del bootstrap, se richiesto."
  (let* ((result (gdev-startup-check-inspect
                  (equal "1" (getenv "GDEV_STARTUP_REQUIRE_WORKBENCH"))
                  (equal "1" (getenv "GDEV_STARTUP_REQUIRE_GRAPHICAL"))))
         (json (json-serialize result :null-object :null :false-object :false))
         (directory (getenv "GDEV_STARTUP_CHECK_DIR"))
         (coding-system-for-write 'utf-8-unix))
    (when (and directory (file-directory-p directory))
      (with-temp-file (expand-file-name "result.json" directory) (insert json "\n"))
      ;; Lo stato viene pubblicato soltanto dopo il riscontro completo.
      (with-temp-file (expand-file-name "status.tmp" directory)
        (insert (if (eq t (alist-get 'ok result)) "ready\n" "failed\n")))
      (rename-file (expand-file-name "status.tmp" directory) (expand-file-name "status" directory) t))
    (unless (eq t (alist-get 'ok result))
      (display-warning 'gdev
                       (format "%s.\nCheckout: %s\nConfigurazione privata: %s\nUsa gdev doctor e controlla *Warnings*."
                               (alist-get 'reason result) (alist-get 'root result) (alist-get 'private result)) :error))
    result))

(unless (or noninteractive (daemonp))
  (add-hook 'emacs-startup-hook (lambda () (run-with-timer 0.2 nil #'gdev-startup-check-run)) 100))

(provide 'gdev-startup-check)
;;; gdev-startup-check.el ends here
