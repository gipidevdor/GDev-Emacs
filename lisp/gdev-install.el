;;; gdev-install.el --- Ingressi grafici alla distribuzione -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il lanciatore dedicato e l'ingresso Emacs ordinario conservano il checkout
;; e le opzioni di percorso scelte. I file personali oscuranti sono salvati
;; prima della pubblicazione dell'ingresso ordinario.
;;; Code:
(require 'gdev-lib)

(defconst gdev-install-launcher-environment
  '("EMACS" "GDEV_PROFILE" "GDEV_USER_DIR" "GDEV_STATE_DIR" "GDEV_TOOLS_DIR"
    "XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_DATA_HOME")
  "Sole opzioni di percorso propagate al lanciatore; nessuna credenziale.")

(defconst gdev-install-standard-entry-marker "GDev-Emacs default entry 1\n"
  "Marcatore dell'ingresso gestito per l'icona Emacs ordinaria.")

(defun gdev-install--standard-entry-files ()
  "Restituisci i file dell'ingresso, con i percorsi scelti nell'installazione."
  (let ((header ";; Generato da GDev-Emacs; configurazioni originali nel backup.\n;; SPDX-License-Identifier: GPL-3.0-or-later\n")
        (print-escape-newlines t))
    `(("gdev-entry" . ,gdev-install-standard-entry-marker)
      ("early-init.el" .
       ,(concat ";;; -*- lexical-binding: t; no-byte-compile: t; -*-\n" header
                (mapconcat (lambda (name)
                             (format "(setenv %S %S)" name (getenv name)))
                           gdev-install-launcher-environment "\n")
                "\n" (format "(load %S nil t t)\n" (gdev-config-file "early-init.el"))))
      ("init.el" .
       ,(concat ";;; -*- lexical-binding: t; no-byte-compile: t; -*-\n" header
                (format "(load %S nil t t)\n" (gdev-config-file "init.el"))
                (format "(load %S nil t t)\n" (gdev-config-file "bin/gdev-startup-check.el")))))))

(defun gdev-install-standard-entry (&optional home-directory)
  "Collega l'icona Emacs ordinaria a GDev nella HOME-DIRECTORY.
Prepara prima l'ingresso ~/.emacs.d in una cartella privata. Sposta i file
.emacs, .emacs.el, .emacs.elc e l'eventuale vecchia .emacs.d in un backup
privato con manifest di ripristino. Non cancella configurazioni né segue
i loro collegamenti. Un errore ripristina i percorsi già spostati.
Restituisce :entry e l'eventuale :backup. Un ingresso identico è riusato."
  (let* ((directory (file-name-as-directory (expand-file-name (or home-directory "~"))))
         (entry (expand-file-name ".emacs.d" directory))
         (files (gdev-install--standard-entry-files))
         (current (and (not (file-symlink-p entry)) (file-directory-p entry)
                       (cl-notany (lambda (name)
                                    (let ((file (expand-file-name name entry)))
                                      (or (file-exists-p file) (file-symlink-p file))))
                                  '("early-init.elc" "init.elc"))
                       (cl-every
                        (lambda (spec)
                          (let ((file (expand-file-name (car spec) entry)))
                            (and (not (file-symlink-p file)) (file-regular-p file)
                                 (equal (cdr spec) (gdev-read-file-contents file))))) files)))
         (originals (cl-loop for name in (append '(".emacs" ".emacs.el" ".emacs.elc")
                                                 (unless current '(".emacs.d")))
                             for path = (expand-file-name name directory)
                             when (or (file-exists-p path) (file-symlink-p path)) collect path))
         staging backup moves moved completed)
    (unwind-protect
        (progn
          (unless current
            (with-file-modes #o700
              (setq staging (make-temp-file (expand-file-name ".gdev-emacs-entry-" directory) t)))
            (dolist (spec files)
              (with-file-modes #o600
                (with-temp-file (expand-file-name (car spec) staging)
                  (insert (cdr spec))))))
          (when originals
            (let ((base (expand-file-name ".gdev-emacs-backups/" directory)))
              (when (file-symlink-p (directory-file-name base))
                (user-error "Cartella di backup collegata conservata: %s" base))
              (gdev-make-private-directory base)
              (with-file-modes #o700
                (setq backup (make-temp-file (expand-file-name "installazione-" base) t)))
              (setq moves (mapcar (lambda (path)
                                    (cons path (expand-file-name (file-name-nondirectory path) backup))) originals))
              ;; Il piano completo precede gli spostamenti: anche un arresto
              ;; improvviso lascia i nomi necessari a recuperare i file.
              (gdev-write-state-data
               (expand-file-name "ripristino.eld" backup)
               (list :version 1 :checkout gdev-config-directory :entry entry :moves moves)
               "File originali: ogni coppia associa percorso originale e copia salvata.")
              (with-temp-file (expand-file-name "LEGGIMI.txt" backup)
                (insert "Configurazioni Emacs conservate, senza cancellazioni.\n"
                        "Per ripristinare: chiudi Emacs, conserva altrove l'ingresso gestito ~/.emacs.d,\n"
                        "poi rinomina ciascun file salvato nel percorso originale indicato da ripristino.eld.\n"
                        "Ripristina soltanto le coppie la cui copia salvata esiste, senza sovrascrivere nuovi file.\n"))
              (dolist (move moves)
                (rename-file (car move) (cdr move))
                (push move moved))))
          (unless current
            (rename-file staging entry)
            (setq staging nil))
          (setq completed t)
          (list :entry entry :backup backup))
      (unless completed
        (dolist (move moved)
          (condition-case error
              (rename-file (cdr move) (car move))
            (error (display-warning 'gdev (format "Ripristino da completare da %s: %s"
                                                 backup (error-message-string error)) :error)))))
      (when (and staging (file-directory-p staging)) (delete-directory staging t)))))

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
