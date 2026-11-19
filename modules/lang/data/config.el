;;; config.el --- :lang data: YAML, TOML, JSON, file di configurazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I formati che accompagnano il codice e i servizi in rete, tutti
;; con modalità integrate in Emacs: YAML, TOML, JSON, .ini/.conf, .env,
;; Makefile.
;;
;;   C-c c f    formatta: JSON con rientro leggibile (deno fmt se
;;              installato), YAML con deno fmt, TOML con taplo
;;
;; Lo YAML viene controllato con yamllint, se installato; il TOML usa il
;; server di linguaggio taplo, con completamento e
;; validazione dagli schemi.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-language-modes)

(add-to-list 'auto-mode-alist '("\\.ya?ml\\'" . yaml-ts-mode))
(add-to-list 'auto-mode-alist '("\\.toml\\'" . conf-toml-mode))
(add-to-list 'auto-mode-alist '("\\.jsonc?\\'" . js-json-mode))
(gdev-language-register-tree-sitter 'conf-toml-mode 'toml-ts-mode 'toml)
(gdev-language-register-tree-sitter 'js-json-mode 'json-ts-mode 'json)
(add-to-list 'auto-mode-alist '("\\.\\(ini\\|cfg\\|conf\\|cnf\\)\\'" . conf-mode))
(add-to-list 'auto-mode-alist '("\\.env\\(\\..*\\)?\\'" . conf-unix-mode))
(add-to-list 'auto-mode-alist '("\\.\\(mk\\|make\\)\\'" . makefile-gmake-mode))

(declare-function gdev-format-with-program "../../editor/format/config")

(defun gdev-data-format-json ()
  "Formatta il JSON con deno fmt; senza Deno usa il formattatore di Emacs."
  (if (executable-find "deno")
      (gdev-format-with-program "deno" "fmt" "--quiet" "--ext=json" "-")
    (json-pretty-print-buffer)))

(defun gdev-data-format-yaml ()
  "Formatta lo YAML con deno fmt."
  (unless (executable-find "deno") (user-error "deno non è installato (brew install deno)"))
  (gdev-format-with-program "deno" "fmt" "--quiet" "--ext=yaml" "-"))

(defun gdev-data-format-toml ()
  "Formatta il TOML con taplo."
  (unless (executable-find "taplo") (user-error "taplo non è installato (brew install taplo)"))
  (gdev-format-with-program "taplo" "format" "-"))

(gdev-set-formatter '(json-ts-mode js-json-mode) #'gdev-data-format-json)
(gdev-set-formatter 'yaml-ts-mode #'gdev-data-format-yaml)
(gdev-set-formatter '(toml-ts-mode conf-toml-mode) #'gdev-data-format-toml)
(gdev-set-eglot-server '((toml-ts-mode :language-id "toml")
                         (conf-toml-mode :language-id "toml"))
                       '("taplo" "lsp" "stdio"))
(gdev-set-docsets 'makefile-mode "gnu_make")

;; TOML non è una modalità di programmazione: il suo server di linguaggio
;; si avvia qui.
(declare-function gdev-lsp-maybe-start "../../tools/lsp/config")
(defun gdev-data-maybe-start-lsp ()
  "Avvia taplo in quest'area di testo se tools/lsp è attivo e taplo è installato."
  (when (fboundp 'gdev-lsp-maybe-start)
    (gdev-lsp-maybe-start)))
(gdev-module-add-hook 'toml-ts-mode-hook #'gdev-data-maybe-start-lsp)
(gdev-module-add-hook 'conf-toml-mode-hook #'gdev-data-maybe-start-lsp)

;;;; yamllint tramite Flymake

(defvar-local gdev-data--yamllint-process nil
  "Il controllo yamllint in corso, se c'è.")

(defun gdev-data-flymake-yamllint (report-fn &rest _)
  "Fonte Flymake: esegue yamllint sull'area di testo e chiama REPORT-FN.
Vale la configurazione .yamllint del progetto."
  (when (process-live-p gdev-data--yamllint-process)
    (kill-process gdev-data--yamllint-process))
  (let ((source (current-buffer)))
    (save-restriction
      (widen)
      (setq gdev-data--yamllint-process
            (make-process
             :name "gdev-yamllint" :noquery t :connection-type 'pipe
             :buffer (generate-new-buffer " *gdev-yamllint*")
             :command '("yamllint" "--format" "parsable" "-")
             :sentinel
             (lambda (process _event)
               (when (memq (process-status process) '(exit signal))
                 (unwind-protect
                     (when (and (buffer-live-p source)
                                (eq process (buffer-local-value 'gdev-data--yamllint-process source)))
                       (with-current-buffer (process-buffer process)
                         (goto-char (point-min))
                         (let (diagnostics)
                           (while (re-search-forward
                                   "^[^:]*:\\([0-9]+\\):\\([0-9]+\\): \\[\\(error\\|warning\\)\\] \\(.*\\)$"
                                   nil t)
                             (let ((region (flymake-diag-region
                                            source
                                            (string-to-number (match-string 1))
                                            (string-to-number (match-string 2)))))
                               (push (flymake-make-diagnostic
                                      source (car region) (cdr region)
                                      (if (equal (match-string 3) "error") :error :warning)
                                      (match-string 4))
                                     diagnostics)))
                           (funcall report-fn diagnostics))))
                   (kill-buffer (process-buffer process)))))))
      (process-send-region gdev-data--yamllint-process (point-min) (point-max))
      (process-send-eof gdev-data--yamllint-process))))

(defun gdev-data-enable-yamllint ()
  "Controlla quest'area di testo YAML con yamllint, se installato."
  (when (and (not (file-remote-p default-directory)) (executable-find "yamllint"))
    (add-hook 'flymake-diagnostic-functions #'gdev-data-flymake-yamllint nil t)
    (flymake-mode 1)))

(gdev-module-add-hook 'yaml-ts-mode-hook #'gdev-data-enable-yamllint)

(gdev-doctor-executable "yamllint" "brew install yamllint" 'note)
(gdev-doctor-executable "taplo" "brew install taplo" 'note)

;;; config.el ends here
