;;; config.el --- :tools remote: macchine remote e amministrazione di sistema -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; TRAMP rende i file remoti file normali:
;; /ssh:nome-macchina:/etc/nginx/nginx.conf si apre, si salva, si cerca e si
;; confronta come un file locale; Esplora file, l'interprete Lisp, Hit e la compilazione
;; funzionano anche nelle cartelle remote. Le macchine remote vengono da
;; ~/.ssh/config: alias, macchine intermediarie e chiavi non richiedono altra
;; configurazione qui.
;;
;;   C-c r r    apri una macchina remota in Dired
;;   C-c r o    apri una cartella via SSH nell'esplora file
;;   C-c r t    terminale su una macchina remota
;;   C-c r s    apri una macchina remota come root (sudo)
;;   C-c r x    esegui un comando su una macchina remota
;;   C-c r l    segui il registro di sistema (journal) di una macchina remota
;;   C-c r u    servizi di sistema (systemctl) su una macchina remota
;;   C-c r p    processi (locali o remoti)
;;   C-c r h    modifica ~/.ssh/config
;;   C-c r n    raggiungibilità di una macchina remota (ping)
;;   C-c r d    interrogazione DNS (dig)
;;   C-c r c    chiudi le connessioni
;;   C-c f U    riapri il file corrente come root (locale o remoto)
;;
;; I file di configurazione di sistema hanno le loro modalità principali:
;; nginx, Apache, unità systemd, configurazione SSH, certificati X.509 e file
;; di registro con i livelli evidenziati.
;;
;; Dei file remoti non si fanno mai copie di riserva locali, e su di essi
;; non parte da solo nessun server di linguaggio né
;; controllo di versione: l'apertura resta veloce.

;;; Code:

(require 'gdev-lib)

(declare-function gdev-open-folder "gdev-commands")
(declare-function tramp-hlo-setup "tramp-hlo" ())
(declare-function eat-other-window "eat" (&optional program arg))
(defvar eat-buffer-name)
(defvar tramp-default-method)
(defvar tramp-verbose)
(defvar tramp-histfile-override)
(defvar tramp-remote-path)
(defvar tramp-file-name-regexp)
(defvar tramp-use-connection-share)
(defvar tramp-copy-size-limit)
(defvar proced-show-remote-processes)
(autoload 'tramp-cleanup-all-connections "tramp-cmds" nil t)

;;;; Prestazioni di TRAMP

(setq tramp-default-method "ssh"
      tramp-verbose 1                   ; solo errori
      ;; Una sola connessione SSH (ControlMaster) per tutte le operazioni.
      tramp-use-connection-share t
      ;; Gli attributi dei file in memoria valgono per un minuto.
      remote-file-name-inhibit-cache 60
      ;; Niente file di blocco né di salvataggio automatico sugli host remoti.
      remote-file-name-inhibit-locks t
      remote-file-name-inhibit-auto-save-visited t
      ;; I file oltre 1 MB si copiano con scp, non con la codifica in linea.
      tramp-copy-size-limit (* 1024 1024)
      ;; Le shell remote non scrivono la cronologia dei comandi di TRAMP.
      tramp-histfile-override t
      ;; Le password digitate per sudo restano in memoria per dieci minuti.
      password-cache-expiry 600
      proced-show-remote-processes t)

(with-eval-after-load 'tramp
  ;; Usa il PATH definito dalla shell di login remota (~/.local/bin, /opt...).
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)
  ;; I processi asincroni (compilazione, ricerca, Hit) parlano direttamente
  ;; con ssh invece che con la shell di TRAMP: molto più veloci.
  (connection-local-set-profile-variables
   'gdev-remote-direct-async '((tramp-direct-async-process . t)))
  (connection-local-set-profiles '(:application tramp :protocol "ssh")
                                 'gdev-remote-direct-async)
  ;; Il controllo di versione resta spento nelle cartelle remote: ogni
  ;; verifica è un viaggio di andata e ritorno. Hit funziona comunque
  ;; quando lo chiami.
  (setq vc-ignore-dir-regexp
        (format "\\(%s\\)\\|\\(%s\\)" vc-ignore-dir-regexp tramp-file-name-regexp)))

;; Versioni più veloci delle operazioni sui file che TRAMP esegue spesso.
(use-package tramp-hlo
  :ensure t
  :after tramp
  :demand t
  :config (tramp-hlo-setup))

;;;; Host

(defun gdev-remote-hosts (&optional directory)
  "Restituisci gli host di config e dei file inclusi da DIRECTORY.
DIRECTORY indica la cartella di configurazione SSH e vale ~/.ssh per default."
  (let* ((base (or directory (expand-file-name "~/.ssh/")))
         (files (list (expand-file-name "config" base)))
         (visited (make-hash-table :test #'equal))
         (case-fold-search t)
         pending hosts)
    (while files
      (when-let* ((file (pop files))
                  ((not (file-remote-p file)))
                  (identity (condition-case nil (file-truename file) (file-error nil)))
                  ((not (gethash identity visited)))
                  ((and (file-regular-p identity) (file-readable-p identity))))
        (puthash identity t visited)
        (with-temp-buffer
          (insert-file-contents identity)
          (goto-char (point-min))
          (while (re-search-forward "^[ \t]*\\(Host\\|Include\\)[ \t]+\\(.+\\)$" nil t)
            (let ((directive (match-string-no-properties 1))
                  (values (split-string (match-string-no-properties 2))))
              (if (string-equal-ignore-case directive "include")
                  (dolist (pattern values)
                    (let ((path (expand-file-name pattern base)))
                      (unless (file-remote-p path)
                        (dolist (included (file-expand-wildcards path))
                          (push included pending)))))
                (dolist (host values)
                  (unless (string-match-p "[*?!]" host)
                    (push host hosts))))))))
      (unless files
        (setq files (nreverse pending) pending nil)))
    (delete-dups (nreverse hosts))))

(defvar gdev-remote-host-history nil "Host scelti nei comandi remoti di GDev.")

(defun gdev-remote--read-host (prompt)
  "Legge il nome di un host con PROMPT, proponendo gli host di ~/.ssh/config."
  (let ((host (string-trim (completing-read prompt (gdev-remote-hosts) nil nil nil
                                           'gdev-remote-host-history))))
    (if (string-empty-p host) (user-error "Indica una macchina SSH") host)))

(defun gdev-remote-dired (host)
  "Apre in Dired la cartella personale (home) di HOST."
  (interactive (list (gdev-remote--read-host "Host: ")))
  (dired (format "/ssh:%s:~/" host)))

(defun gdev-remote-open-folder (host)
  "Scegli e apri una cartella su HOST via SSH."
  (interactive (list (gdev-remote--read-host "Apri cartella su host: ")))
  (gdev-open-folder (read-directory-name "Cartella remota: "
                                        (format "/ssh:%s:~/" host) nil t)))

(defun gdev-remote-sudo-dired (host)
  "Apre in Dired, come root, la cartella radice di HOST."
  (interactive (list (gdev-remote--read-host "Host (come root): ")))
  (dired (format "/ssh:%s|sudo:root@%s:/" host host)))

(defun gdev-remote-terminal (host)
  "Apre in un terminale una sessione SSH verso HOST."
  (interactive (list (gdev-remote--read-host "Terminale sull'host: ")))
  (if (fboundp 'eat-other-window)
      (let ((default-directory temporary-file-directory)
            (eat-buffer-name (format "*Terminale · %s*" host)))
        (eat-other-window (gdev-command-line "ssh" "--" host) t))
    (let ((default-directory (format "/ssh:%s:~/" host)))
      (shell (format "*Terminale · %s*" host)))))

(defun gdev-remote-shell-command (host command)
  "Esegue il comando dell'interprete dei comandi COMMAND su HOST.
Ciò che stampa va in un'area di testo che resta aperto e attivo."
  (interactive
   (let ((host (gdev-remote--read-host "Host: ")))
     (list host (read-shell-command (format "Comando su %s: " host)))))
  (gdev-compile (gdev-command-line "ssh" "--" host command)
                (format "Comando remoto · %s" host) default-directory t))

(defun gdev-remote-journal (host unit)
  "Segue il registro di sistema (journal) di HOST, per UNIT se non è vuota."
  (interactive
   (let ((host (gdev-remote--read-host "Registro di sistema dell'host: ")))
     (list host (read-string "Unità (vuota: tutte): "))))
  (gdev-compile (gdev-command-line
                 "ssh" "-t" "--" host
                 (gdev-command-line "journalctl" "-f" "-n" "200" "--no-pager"
                                    (unless (string-empty-p unit) (list "-u" unit))))
                (format "Registro di sistema · %s" host) default-directory t))

(defconst gdev-remote--service-actions
  '(("Stato" "status")
    ("Riavvia" "restart")
    ("Rileggi configurazione" "reload")
    ("Avvia" "start")
    ("Ferma" "stop")
    ("Abilita all'avvio" "enable")
    ("Disabilita all'avvio" "disable")
    ("Unità in errore" "list-units" "--failed"))
  "Etichette e argomenti dei comandi per le unità di sistema.")

(defun gdev-remote-systemctl (host action unit)
  "Esegue systemctl ACTION sull'unità UNIT di HOST.
Le azioni che cambiano lo stato passano da sudo."
  (interactive
   (let* ((host (gdev-remote--read-host "Host: "))
          (label (completing-read "Servizio di sistema: " gdev-remote--service-actions nil t nil nil "Stato"))
          (action (string-join (cdr (assoc label gdev-remote--service-actions)) " ")))
     (list host action (if (string-prefix-p "list-units" action) "" (read-string "Unità: ")))))
  (let* ((arguments (seq-find (lambda (entry) (equal (string-join entry " ") action))
                              (mapcar #'cdr gdev-remote--service-actions)))
         (unit (unless (string-empty-p unit) (list "--" unit)))
         (command (if (member (car arguments) '("status" "list-units"))
                      (gdev-command-line "systemctl" arguments unit)
                    (gdev-command-line "sudo" "systemctl" arguments unit))))
    (unless arguments (user-error "Azione non disponibile per un servizio di sistema"))
    (gdev-compile (gdev-command-line "ssh" "-t" "--" host command)
                  (format "Servizi di sistema · %s" host) default-directory t)))

(defun gdev-remote-ssh-config ()
  "Modifica ~/.ssh/config."
  (interactive)
  (find-file (expand-file-name "~/.ssh/config")))

;;;; Modalità per i file di configurazione dei server

(use-package ssh-config-mode :ensure t)  ; ~/.ssh/config, known_hosts
(use-package nginx-mode :ensure t)
(use-package apache-mode :ensure t)
(use-package systemd :ensure t)          ; file di unità: completamento e aiuto
(use-package x509-mode :ensure t)        ; certificati e chiavi, decodificati
(use-package logview                      ; livelli del registro (log), filtri, orari
  :ensure t
  :custom (logview-cache-filename (gdev-state-file "logview-cache.extmap")))

;;; config.el ends here
