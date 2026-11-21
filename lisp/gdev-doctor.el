;;; gdev-doctor.el --- Diagnosi dell'installazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; `gdev doctor' in un terminale, o C-h d d dentro Emacs, è la diagnosi
;; dell'ambiente: controlla ciò su cui contano i moduli attivi, cioè come è
;; compilato Emacs, la configurazione privata, le grammatiche tree-sitter e
;; ogni programma esterno che un modulo ha registrato con
;; `gdev-doctor-executable' o `gdev-doctor-check'.  Ogni problema arriva con
;; il comando che lo risolve.  Niente qui stampa un segreto: i controlli
;; sulle credenziali dicono solo se esistono.

;;; Code:

(require 'seq)
(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-handlers)

(defvar gdev-treesit-languages)         ; tools/tree-sitter
(declare-function gdev-env-saved-p "gdev-env")
(declare-function gdev-state-db-inspect "gdev-state-db-maintenance" (file &optional full))

(declare-function eglot-current-server "eglot" ())
(declare-function eglot-managed-p "eglot" ())
(declare-function gdev-debug-workspace-connections "../modules/tools/debugger/config" (owner))
(declare-function gdev-workspace-state-id "gdev-workspace-state" (&optional frame))
(declare-function gdev-layout-editor "../modules/ui/workbench/gdev-layout" (&optional frame))
(declare-function gdev-workspace-directory "gdev-workspace-roots" (&optional directory frame))

(defun gdev-doctor-last-measures ()
  "Leggi l'ultima misura se l'archivio del profilo è disponibile."
  (when (and (file-readable-p (gdev-state-db-file))
             (not (bound-and-true-p gdev-state-startup-issue)))
    (condition-case nil
        (cdar (gdev-state-db-entries "applicazione" "" "misure_workbench"))
      (error nil))))

(defun gdev-doctor-format-measures (report)
  "Formatta le misure del banco REPORT in millisecondi."
  (if (not (eq (plist-get report :versione) 1))
      "\nPrestazioni · esegui gdev bench flussi per ottenere una misura.\n"
    (concat (format "\nPrestazioni · %s · Emacs %s · %s · %s percorsi\n"
                    (plist-get report :data) (plist-get report :emacs)
                    (plist-get report :ambiente) (plist-get report :percorsi))
            (mapconcat
             (lambda (row)
               (let ((limit (plist-get row :limite_ms)) (ms (plist-get row :mediana_ms)))
                 (format "  %s · %.2f ms%s\n" (plist-get row :nome) ms
                         (if limit (format " · obiettivo < %d ms%s" limit
                                           (if (< ms limit) "" " · superato")) ""))))
             (plist-get report :misure) ""))))

(defun gdev-doctor--session ()
  "Descrivi i servizi osservati nell'editor corrente, senza avviarli."
  (when (and (not noninteractive) (bound-and-true-p gdev-layout-mode))
    (let* ((editor (gdev-layout-editor))
           (owner (gdev-workspace-state-id))
           (debug (and owner (fboundp 'gdev-debug-workspace-connections)
                       (gdev-debug-workspace-connections owner))))
      (format "\nSpazio di lavoro · %s\n  LSP nel documento attivo · %s\n  Connessioni di debug nello spazio · %d\n"
              (or (gdev-workspace-directory) "senza cartella")
              (if (and (window-live-p editor) (featurep 'eglot)
                       (with-current-buffer (window-buffer editor)
                         (and (eglot-managed-p) (eglot-current-server))))
                  "connesso" "inattivo")
              (length debug)))))

(declare-function gdev-workbench-operations-log "gdev-workbench-operations" ())

(defun gdev-doctor-json (results)
  "Rendi RESULTS e le misure del profilo in JSON per il supporto."
  (let* ((live (and (not noninteractive) (bound-and-true-p gdev-layout-mode)))
         (report (copy-tree (gdev-doctor-last-measures) t)))
    (seq-doseq (row (plist-get report :misure))
      (unless (plist-get row :limite_ms) (plist-put row :limite_ms :null)))
    (decode-coding-string
     (json-serialize
      (list :versione 1 :contesto (if live "editor" "terminale")
            :profilo (or gdev-active-profile "predefinito")
            :spazio (or (and live (gdev-workspace-directory)) :null)
            :operazioni (if (and live (fboundp 'gdev-workbench-operations-log))
                            (gdev-workbench-operations-log) :null)
            :controlli (vconcat (mapcar (pcase-lambda (`(,level ,label ,hint))
                                         (list :livello (symbol-name level) :voce label :rimedio hint))
                                       results))
            :prestazioni (or report :null))
      :null-object :null) 'utf-8-unix)))

(defun gdev-doctor--core-checks ()
  "Restituisce i controlli che non dipendono dai moduli."
  (append
   (list
    (list "Emacs 30.1 o successivo" (lambda () (version<= "30.1" emacs-version))
          "installa un Emacs recente: brew install --cask emacs-app" 'warning)
    (list "compilazione nativa" (lambda () (and (fboundp 'native-comp-available-p)
                                                (native-comp-available-p)))
          "usa un Emacs con compilazione nativa (quello installato con brew install --cask)"
          'warning)
    (list "tree-sitter" #'treesit-available-p
          "usa un Emacs con tree-sitter (quello installato con brew install --cask)"
          'warning)
    (list "archivio SQLite del profilo"
          (lambda () (and (sqlite-available-p)
                          (or (and (not (file-exists-p (gdev-state-db-file)))
                                   (not (file-symlink-p (gdev-state-db-file)))
                                   (not (file-directory-p (expand-file-name "copie-stato" gdev-state-directory))))
                              (progn (require 'gdev-state-db-maintenance)
                                     (gdev-state-db-inspect (gdev-state-db-file) t)))))
          "gdev stato verifica, oppure gdev stato copie per il recupero" 'warning)
    (list "configurazione privata" (lambda () (file-exists-p (gdev-user-file "init.el")))
          "gdev install  (crea ~/.config/gdev da templates/)" 'note)
    (list "git" (lambda () (executable-find "git")) "xcode-select --install" 'warning)
    (list "ripgrep" (lambda () (executable-find "rg")) "brew install ripgrep" 'warning))
   (when gdev-macos-p
     (list (list "ambiente della shell salvato" #'gdev-env-saved-p
                 "gdev env  (eseguilo da un terminale)" 'warning)))
   (mapcar (lambda (entry)
             (list (format "modulo facoltativo %s %s" (car entry) (cadr entry)) #'ignore
                   (format "aggiungi %s a %s in %s, poi esegui gdev sync"
                           (cadr entry) (car entry) (abbreviate-file-name (gdev-user-file "init.el")))
                   'note))
           (gdev-modules-missing-from-template))
   (when (and (gdev-module-p :tools 'tree-sitter) (boundp 'gdev-treesit-languages))
     (mapcar (lambda (entry)
               (let ((language (car entry)))
                 (list (format "grammatica tree-sitter: %s" language)
                       (lambda () (treesit-language-available-p language))
                       "gdev sync" 'warning)))
             gdev-treesit-languages))
   (when gdev-modules-private-errors
     (mapcar (lambda (failure)
               (list (format "configurazione privata %s" (abbreviate-file-name (car failure)))
                     #'ignore (format "non si carica: %s" (cdr failure)) 'warning))
             gdev-modules-private-errors))
   (when gdev-failed-modules
     (mapcar (lambda (failure)
               (list (format "modulo %s %s" (nth 0 failure) (nth 1 failure)) #'ignore
                     (format "non si carica: %s" (error-message-string (nth 2 failure)))
                     'warning))
             gdev-failed-modules))))

(defun gdev-doctor-run ()
  "Esegue tutti i controlli.  Restituisce una lista di (STATUS LABEL HINT).
STATUS è `ok', `warning' o `note'."
  (mapcar (pcase-lambda (`(,label ,predicate ,hint ,severity))
            (list (if (ignore-errors (funcall predicate)) 'ok severity) label hint))
          (append (gdev-doctor--core-checks) (reverse gdev-doctor-checks))))

(defun gdev-doctor-format (results)
  "Restituisce come testo i RESULTS di `gdev-doctor-run', prima i problemi."
  (let ((problems (seq-filter (lambda (result) (eq (car result) 'warning)) results))
        (notes (seq-filter (lambda (result) (eq (car result) 'note)) results))
        (fine (seq-filter (lambda (result) (eq (car result) 'ok)) results)))
    (concat
     (format "Diagnosi di GDev-Emacs (doctor): %d problem%s, %d suggeriment%s, %d a posto.\n"
             (length problems) (if (= (length problems) 1) "a" "i")
             (length notes) (if (= (length notes) 1) "o" "i")
             (length fine))
     (when problems
       (concat "\nProblemi:\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,hint)) (format "  ✗ %s\n      %s\n" label hint))
                          problems "")))
     (when notes
       (concat "\nSuggerimenti (facoltativi):\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,hint)) (format "  · %s\n      %s\n" label hint))
                          notes "")))
     (when fine
       (concat "\nA posto:\n"
               (mapconcat (pcase-lambda (`(,_ ,label ,_)) (format "  ✓ %s\n" label)) fine "")))
     (gdev-doctor--session)
     (gdev-doctor-format-measures (gdev-doctor-last-measures)))))

;;;###autoload
(defun gdev-doctor ()
  "Controlla l'installazione e mostra cosa manca, con il rimedio."
  (interactive)
  (let* ((results (gdev-doctor-run))
         (text (gdev-doctor-format results))
         (report (gdev-doctor-json results)))
    (with-current-buffer (get-buffer-create "*gdev-doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text "\n")
        (insert-text-button "Copia rapporto JSON" 'follow-link t
                            'action (lambda (_) (kill-new report) (message "Rapporto copiato"))))
      (special-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

(provide 'gdev-doctor)
;;; gdev-doctor.el ends here
