;;; config.el --- :tools terraform: HCL, validazione e piani -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; M-x gdev-terraform-validate controlla la configurazione.
;; M-x gdev-terraform-plan apre il piano nel pannello, senza applicarlo.
;; C-c c f formatta il file e terraform-ls fornisce i riferimenti.

;;; Code:

(require 'gdev-handlers)

(use-package terraform-mode
  :ensure t
  :mode "\\.tf\\(?:vars\\)?\\'")

(let ((rule '("\\.tftest\\.hcl\\'" . terraform-mode)))
  (add-to-list 'auto-mode-alist rule)
  (with-eval-after-load 'hcl-mode
    ;; hcl-mode antepone la regola generica quando viene caricato.
    (setq auto-mode-alist (cons rule (delete rule auto-mode-alist)))))

(defun gdev-terraform--root ()
  "Restituisci la cartella del modulo Terraform aperto."
  (or (locate-dominating-file default-directory
                              (lambda (dir) (directory-files dir nil "\\.tf\\'" t 1)))
      (user-error "Apri un modulo con almeno un file Terraform .tf")))

(defun gdev-terraform-validate ()
  "Mostra la validazione del modulo Terraform."
  (interactive)
  (gdev-compile "terraform validate -no-color" "Terraform · Validazione" (gdev-terraform--root)))

(defun gdev-terraform-plan ()
  "Genera e mostra il piano del modulo Terraform."
  (interactive)
  (gdev-compile "terraform plan -no-color -input=false" "Terraform · Piano" (gdev-terraform--root)))

(declare-function gdev-format-with-program "../../editor/format/config")
(defun gdev-terraform-format ()
  "Formatta il documento con terraform fmt."
  (gdev-format-with-program "terraform" "fmt" "-"))

(gdev-set-tool-actions 'terraform "Terraform" "build"
  ["Valida il modulo" gdev-terraform-validate]
  ["Mostra il piano" gdev-terraform-plan])

(gdev-set-formatter 'terraform-mode #'gdev-terraform-format)
(gdev-set-eglot-server 'terraform-mode '("terraform-ls" "serve"))
(gdev-doctor-executable "terraform" "Installa Terraform" 'note)
(gdev-doctor-executable "terraform-ls" "Installa Terraform Language Server" 'note)

;;; config.el ends here
