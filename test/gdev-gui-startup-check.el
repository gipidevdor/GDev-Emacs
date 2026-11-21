;;; gdev-gui-startup-check.el --- Riscontro della vera finestra macOS -*- lexical-binding: t; no-byte-compile: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Caricato soltanto da gdev-gui-startup-test.py in una nuova istanza isolata.
;; Non sostituisce le primitive grafiche e non inizializza GDev a mano.
;;; Code:

(defun gdev-test-gui-startup--run ()
  "Registra finestra, avvio e codice nativo, poi termina questa istanza."
  (let* ((directory (getenv "GDEV_STARTUP_CHECK_DIR"))
         (result (gdev-startup-check-inspect t t))
         (native-function 'gdev-core--restore-gc)
         (native (and (fboundp 'subr-native-elisp-p)
                      (fboundp native-function)
                      (subrp (symbol-function native-function))
                      (subr-native-elisp-p (symbol-function native-function))))
         (visible (eq t (frame-visible-p (selected-frame))))
         (reason (cond
                  ((not (eq t (alist-get 'ok result))) (alist-get 'reason result))
                  ((not (eq window-system 'ns)) "La finestra non usa il backend nativo macOS")
                  ((not visible) "La finestra nativa non è visibile")
                  ((not native) "Il nucleo GDev non è stato caricato dal codice nativo preparato")))
         (receipt `((schema_version . 1) (ok . ,(if reason :false t))
                    (pid . ,(emacs-pid)) (token . ,(getenv "GDEV_GUI_TEST_TOKEN"))
                    (graphical . ,(if (display-graphic-p) t :false))
                    (window_system . ,(symbol-name window-system))
                    (visible . ,(if visible t :false))
                    (early_init_file . ,(or (bound-and-true-p early-init-file) :null))
                    (user_init_file . ,(or (bound-and-true-p user-init-file) :null))
                    (state . ,(or (bound-and-true-p gdev-state-directory) :null))
                    (private . ,(or (bound-and-true-p gdev-user-directory) :null))
                    (native . ,(if native t :false))
                    (native_function . ,(symbol-name native-function))
                    (reason . ,(or reason :null))))
         (coding-system-for-write 'utf-8-unix))
    (with-temp-file (expand-file-name "gui-result.tmp" directory)
      (insert (json-serialize receipt :null-object :null :false-object :false) "\n"))
    (rename-file (expand-file-name "gui-result.tmp" directory)
                 (expand-file-name "gui-result.json" directory) t)
    (when-let* ((messages (get-buffer "*Messages*")))
      (with-current-buffer messages
        (write-region (point-min) (point-max) (expand-file-name "messages.log" directory) nil 'silent)))
    (kill-emacs (if reason 1 0))))

(unless (and (getenv "GDEV_GUI_TEST_TOKEN") (getenv "GDEV_STARTUP_CHECK_DIR"))
  (error "Usa test/gdev-gui-startup-test.py per avviare questo verificatore"))

(setq frame-title-format "GDev — verifica GUI isolata")
(add-hook 'emacs-startup-hook
          (lambda () (run-with-timer 0.6 nil #'gdev-test-gui-startup--run)) 101)

;;; gdev-gui-startup-check.el ends here
