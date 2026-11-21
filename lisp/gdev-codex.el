;;; gdev-codex.el --- Codex nel progetto corrente -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Eat possiede il processo e il suo ciclo di vita. La radice canonica
;; identifica la sessione; il server MCP è quello della distribuzione GDev,
;; indipendentemente dalla cartella del progetto aperto.
;;; Code:
(require 'cl-lib)
(require 'project)
(require 'json)
(autoload 'gdev-launch-profile-root "gdev-launch")
(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function gdev-ui-view-setup "gdev-ui" (profile))
(declare-function vc-root-diff "vc" (&optional verbose))
(defvar gdev-config-directory)
(defvar-local gdev-codex-root nil)

(defcustom gdev-codex-executable "codex"
  "Eseguibile Codex già installato."
  :type 'string :group 'gdev)

(defun gdev-codex--root ()
  "Ricava il progetto dal medesimo contesto delle operazioni di sviluppo."
  (let ((root (or gdev-codex-root (gdev-launch-profile-root)
                  (when-let* ((project (project-current nil))) (project-root project))
                  default-directory)))
    (when (file-remote-p root) (user-error "Codex richiede un progetto locale"))
    (file-name-as-directory (file-truename root))))

(defun gdev-codex--name (root)
  "Identifica ROOT senza collisioni tra cartelle omonime."
  (format "Codex · %s · %s" (file-name-nondirectory (directory-file-name root))
          (substring (secure-hash 'sha256 root) 0 12)))

(defun gdev-codex--arguments (root &optional resume)
  "Prepara argv per ROOT; con RESUME apri il selettore nativo delle sessioni."
  (let ((server (expand-file-name "bin/gdev-mcp" gdev-config-directory)))
    (unless (file-executable-p server) (user-error "Server MCP GDev assente: %s" server))
    (append (list "--cd" root "--no-alt-screen"
                  "-c" (concat "mcp_servers.gdev.command=" (json-serialize server))
                  "-c" "mcp_servers.gdev.args=[]")
            (when resume '("resume")))))

(defun gdev-codex--buffer (root)
  "Trova il terminale di ROOT senza riusare buffer di un altro proprietario."
  (let ((buffer (get-buffer (concat "*" (gdev-codex--name root) "*"))))
    (when (and buffer (not (equal root (buffer-local-value 'gdev-codex-root buffer))))
      (user-error "Il nome del terminale Codex è occupato da un altro buffer; rinominalo prima di riprovare"))
    buffer))

;;;###autoload
(defun gdev-codex (&optional resume)
  "Apri Codex per il progetto. Con prefisso, riprendi una sessione salvata."
  (interactive "P")
  (let* ((root (gdev-codex--root)) (default-directory root)
         (program (or (executable-find gdev-codex-executable)
                      (user-error "Codex non trovato; installa la CLI o configura gdev-codex-executable")))
         (name (gdev-codex--name root))
         (existing (gdev-codex--buffer root)))
    (when (and resume existing (process-live-p (get-buffer-process existing)))
      (user-error "La sessione di questo progetto è già attiva; interrompila prima di riprenderne un'altra"))
    (require 'eat)
    (let ((buffer (apply #'eat-make name program nil (gdev-codex--arguments root resume))))
      (with-current-buffer buffer
        (setq-local gdev-codex-root root)
        (gdev-ui-view-setup 'native))
      (pop-to-buffer buffer))))

;;;###autoload
(defun gdev-codex-resume ()
  "Riprendi una sessione Codex tramite il selettore nativo del progetto."
  (interactive) (gdev-codex t))

;;;###autoload
(defun gdev-codex-stop ()
  "Ferma il processo Codex del progetto corrente conservando il terminale."
  (interactive)
  (let* ((root (gdev-codex--root))
         (buffer (gdev-codex--buffer root))
         (process (and buffer (get-buffer-process buffer))))
    (unless (process-live-p process) (user-error "Nessuna sessione Codex attiva per questo progetto"))
    (delete-process process)))

;;;###autoload
(defun gdev-codex-diff ()
  "Rivedi le modifiche del progetto con il confronto Git comune di Emacs."
  (interactive)
  (require 'vc)
  (let ((default-directory (gdev-codex--root))) (vc-root-diff)))

(provide 'gdev-codex)
;;; gdev-codex.el ends here
