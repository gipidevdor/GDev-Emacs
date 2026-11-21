;;; gdev-install.el --- Ingresso grafico esplicito alla distribuzione -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il lanciatore conserva il checkout e le opzioni di percorso scelte durante
;; l'installazione. Non dipende dalla precedenza dei file personali di Emacs.
;;; Code:
(require 'gdev-lib)

(defconst gdev-install-launcher-environment
  '("EMACS" "GDEV_PROFILE" "GDEV_USER_DIR" "GDEV_STATE_DIR" "GDEV_TOOLS_DIR"
    "XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_DATA_HOME")
  "Sole opzioni di percorso propagate al lanciatore; nessuna credenziale.")

(defun gdev-install-macos-application (&optional directory)
  "Prepara GDev-Emacs.app in DIRECTORY, normalmente ~/Applications.
GDEV_APPLICATIONS_DIR può scegliere una cartella diversa. Le applicazioni
estranee e i collegamenti simbolici non vengono sovrascritti."
  (let* ((base (expand-file-name (or directory (getenv "GDEV_APPLICATIONS_DIR") "~/Applications/")))
         (app (expand-file-name "GDev-Emacs.app" base))
         (contents (expand-file-name "Contents/" app))
         (marker (expand-file-name "Resources/gdev-launcher" contents))
         (executable (expand-file-name "MacOS/gdev" contents)))
    (dolist (path (list app contents (expand-file-name "Resources" contents)
			(expand-file-name "MacOS" contents) marker))
      (when (file-symlink-p path)
        (user-error "Collegamento esistente conservato: %s" path)))
    (when (or (file-symlink-p app)
              (and (file-exists-p app)
                   (not (and (file-regular-p marker)
                             (equal "GDev-Emacs launcher 1\n" (gdev-read-file-contents marker))))))
      (user-error "Applicazione esistente conservata: %s. Scegli GDEV_APPLICATIONS_DIR" app))
    (make-directory (file-name-directory executable) t)
    (make-directory (file-name-directory marker) t)
    ;; Il marcatore permette di riprendere una preparazione interrotta.
    (gdev-write-state-file marker (lambda () (insert "GDev-Emacs launcher 1")))
    (gdev-write-state-file
     (expand-file-name "Info.plist" contents)
     (lambda ()
       (insert "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	       "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
	       "<plist version=\"1.0\"><dict>\n"
	       "<key>CFBundleIdentifier</key><string>org.gdev.emacs.launcher</string>\n"
	       "<key>CFBundleName</key><string>GDev-Emacs</string>\n"
	       "<key>CFBundleDisplayName</key><string>GDev-Emacs</string>\n"
	       "<key>CFBundleExecutable</key><string>gdev</string>\n"
	       "<key>CFBundlePackageType</key><string>APPL</string>\n"
	       "<key>CFBundleVersion</key><string>1</string>\n"
	       "</dict></plist>")))
    (gdev-write-state-file
     executable
     (lambda ()
       (insert "#!/bin/sh\n# Generato da GDev-Emacs; nessun file personale di Emacs viene modificato.\n")
       (dolist (name gdev-install-launcher-environment)
	 (insert "unset " name "\n")
	 (when-let* ((value (getenv name)))
	   (insert "export " name "=" (shell-quote-argument value) "\n")))
       (insert "export GDEV_STARTUP_REQUIRE_WORKBENCH=1\nexport GDEV_STARTUP_REQUIRE_GRAPHICAL=1\nexec "
	       (gdev-command-line (expand-file-name "bin/gdev" gdev-config-directory) "emacs")
	       " \"$@\"")))
    (set-file-modes executable #o755)
    app))

(provide 'gdev-install)
;;; gdev-install.el ends here
