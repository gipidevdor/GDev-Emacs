;;; config.el --- :editor snippets: frammenti di testo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Scrivi un'abbreviazione e premi TAB: diventa un frammento i cui
;; campi si compilano uno alla volta.  I frammenti vengono da
;; ~/.config/gdev/snippets/ (privati; C-c i S ne crea uno lì), da snippets/
;; nella cartella di GDev-Emacs e dalla raccolta yasnippet-snippets.
;; C-c i s apre la ricerca per abbreviazione, nome e categoria.  I pattern
;; di progettazione iniziano con dp-, le ricette del progetto con g-.
;; Eglot usa lo stesso motore per i frammenti dei server di linguaggio.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)
(require 'subr-x)

(declare-function yas--template-p "yasnippet")
(declare-function yas--template-key "yasnippet")
(declare-function yas--template-name "yasnippet")
(declare-function yas--template-group "yasnippet")
(declare-function yas-activate-extra-mode "yasnippet")
(declare-function yas-completing-prompt "yasnippet")
(declare-function yas-reload-all "yasnippet")
(declare-function yas--get-snippet-tables "yasnippet" (&optional mode))
(declare-function yas--fetch "yasnippet" (table key))
(declare-function yas--table-templates "yasnippet" (table))
(declare-function yas--load-pending-jits "yasnippet" ())
(declare-function yas--template-condition "yasnippet" (template))
(declare-function yas--template-content "yasnippet" (template))
(declare-function yas-active-snippets "yasnippet" (&optional beg end))
(declare-function yas-expand-snippet "yasnippet" (snippet &optional start end expand-env))
(declare-function yas-exit-all-snippets "yasnippet" ())
(declare-function gdev-lavorazione-documento "gdev-lavorazione" (contesto))
(declare-function gdev-lavorazione-file-previsto "gdev-lavorazione" (piano))
(declare-function gdev-workspace-directory "gdev-workspace-roots" (&optional directory frame))
(declare-function gdev-lavorazione-registra "gdev-lavorazione"
                  (nome descrizione schema funzione &rest proprieta))
(defvar yas-buffer-local-condition)
(defvar yas-wrap-around-region)
(defvar yas-selected-text)
(defvar yas-indent-line)
(defvar yas-good-grace)
(defvar yasnippet-snippets-dir)

(defun gdev-snippets--completing-prompt (prompt choices &optional _display)
  "Cerca CHOICES per abbreviazione, nome e gruppo nel minibuffer.
Lascia i PROMPT per modalità e abbreviazioni al completamento di YASnippet."
  (when (yas--template-p (car choices))
    (let ((labels (make-hash-table :test #'equal))
          (completion-styles (append completion-styles '(substring))))
      (yas-completing-prompt
       (if (equal prompt "Choose a snippet: ") "Frammento: " prompt)
       choices
       (lambda (template)
         (let* ((group (yas--template-group template))
                (base (string-join
                       (delq nil (list (yas--template-key template)
                                       (yas--template-name template)
                                       (when group (string-join group " / "))))
                       "  "))
                (label base)
                (index 1))
           (while (gethash label labels)
             (setq index (1+ index)
                   label (format "%s (%d)" base index)))
           (puthash label t labels)
           label))))))

(defun gdev-snippets--typescript-javascript ()
  "Attiva la raccolta JavaScript nella modalità TypeScript classica."
  ;; Le modalità tree-sitter dichiarano js-mode fra i propri genitori YAS.
  ;; Un passaggio attraverso typescript-mode confligge con l'ordine degli
  ;; antenati di typescript-ts-mode in Emacs 31.
  (yas-activate-extra-mode 'js-mode))

(use-package yasnippet
  :ensure t
  :hook (((prog-mode conf-mode text-mode) . yas-minor-mode)
         (typescript-mode . gdev-snippets--typescript-javascript))
  :commands (yas-insert-snippet yas-new-snippet yas-visit-snippet-file)
  :init
  (setq yas-snippet-dirs (list (gdev-user-file "snippets/")
                               (gdev-config-file "snippets/")))
  :custom
  (yas-verbosity 1)
  (yas-triggers-in-field t)
  (yas-prompt-functions '(gdev-snippets--completing-prompt yas-completing-prompt)))

;; Una grande raccolta già pronta, caricata per modalità al primo utilizzo.
(use-package yasnippet-snippets
  :ensure t
  :after yasnippet
  :demand t
  :config
  (add-to-list 'yas-snippet-dirs 'yasnippet-snippets-dir t)
  (yas-reload-all))

(defun gdev-snippets--testo-statico (modello)
  "Restituisci il testo di MODELLO se può essere espanso senza Lisp."
  (let ((contenuto (yas--template-content modello)))
    (when (and (stringp contenuto)
               (not (yas--template-condition modello))
               (not (string-match-p "`\\|[$]+[ \t\r\n]*(" contenuto)))
      contenuto)))

(defun gdev-snippets--contenuto-lavorazione (chiave)
  "Restituisci il frammento univoco CHIAVE senza valutare condizioni o Lisp."
  (let* ((yas-buffer-local-condition 'always)
         (modelli (seq-uniq
                   (cl-mapcan (lambda (tabella) (mapcar #'cdr (yas--fetch tabella chiave)))
                              (yas--get-snippet-tables))
                   #'eq))
         (modello (car modelli)))
    (unless modello (user-error "Nessun frammento %s per %s" chiave major-mode))
    (when (cdr modelli) (user-error "La chiave del frammento %s è ambigua" chiave))
    (or (gdev-snippets--testo-statico modello)
        (user-error "Il frammento %s richiede l'espansione interattiva" chiave))))

(defun gdev-snippets--scelte-lavorazione ()
  "Restituisci le chiavi univoche con nome nel linguaggio corrente."
  (let ((yas-buffer-local-condition 'always)
        (visti (make-hash-table :test #'eq))
        (per-chiave (make-hash-table :test #'equal))
        (scelte (make-hash-table :test #'equal)))
    (dolist (tabella (yas--get-snippet-tables))
      (dolist (coppia (yas--table-templates tabella))
        (let* ((modello (cdr coppia))
               (chiave (yas--template-key modello)))
          (when (and (stringp chiave) (not (gethash modello visti)))
            (puthash modello t visti)
            (push modello (gethash chiave per-chiave))))))
    (maphash (lambda (chiave modelli)
               (when (and (not (cdr modelli)) (gdev-snippets--testo-statico (car modelli)))
                 (puthash chiave (yas--template-name (car modelli)) scelte)))
             per-chiave)
    scelte))

(defun gdev-snippets--linguaggio-previsto (relativo)
  "Ricava una modalità dal nome RELATIVO senza visitare il file."
  (let ((case-fold-search nil)
        (modo (assoc-default relativo auto-mode-alist #'string-match-p)))
    (when (and modo (symbolp modo))
      (alist-get modo major-mode-remap-alist modo))))

(defun gdev-snippets--leggi-chiave (_campo _tipo iniziale piano)
  "Proponi gli snippet per il documento previsto da PIANO."
  (require 'yasnippet)
  (let* ((relativo (gdev-lavorazione-file-previsto piano))
         (radice (or (gdev-workspace-directory) default-directory))
         (aperto (and relativo (not (file-remote-p radice))
                      (get-file-buffer (expand-file-name relativo radice))))
         (modo (if aperto (buffer-local-value 'major-mode aperto)
                 (and relativo (gdev-snippets--linguaggio-previsto relativo))))
         (scelte (cond (aperto
                         (with-current-buffer aperto
                           (yas--load-pending-jits)
                           (gdev-snippets--scelte-lavorazione)))
                       (modo
                        (with-temp-buffer
                          (setq-local major-mode modo
                                      default-directory gdev-config-directory)
                          (yas--load-pending-jits)
                          (gdev-snippets--scelte-lavorazione))))))
    (if (and scelte (> (hash-table-count scelte) 0))
        (let ((completion-extra-properties
               (list :annotation-function
                     (lambda (chiave)
                       (when-let* ((nome (gethash chiave scelte))) (concat "  " nome))))))
          (completing-read (format "Frammento (%s): " modo) scelte nil t iniziale))
      (read-string "Chiave del frammento (verificata all'esecuzione): " iniziale))))

(defun gdev-snippets--inserisci-in-lavorazione (contesto chiave)
  "Espandi CHIAVE nel documento di CONTESTO e conferma i campi predefiniti."
  (require 'yasnippet)
  (with-current-buffer (gdev-lavorazione-documento contesto)
    (when (yas-active-snippets 'all)
      (user-error "Completa il frammento già aperto nel documento"))
    (unless (bound-and-true-p yas-minor-mode) (yas-minor-mode 1))
    (let ((contenuto (gdev-snippets--contenuto-lavorazione chiave))
          (yas-wrap-around-region nil)
          (yas-selected-text nil)
          (yas-indent-line 'fixed)
          (yas-good-grace nil))
      (atomic-change-group
        ;; Passa il testo statico: condizioni ed expand-env appartengono
        ;; all'espansione interattiva del modello e non entrano nel piano.
        (yas-expand-snippet contenuto (point) (point))
        (yas-exit-all-snippets)))))

(with-eval-after-load 'gdev-lavorazione
  (gdev-lavorazione-registra
   "inserisci-snippet" "Espandi un frammento del linguaggio con i valori predefiniti."
   '(("chiave" . testo-non-vuoto)) #'gdev-snippets--inserisci-in-lavorazione
   :modulo "Frammenti" :richiede-documento t :lettore #'gdev-snippets--leggi-chiave))

;;; config.el ends here
