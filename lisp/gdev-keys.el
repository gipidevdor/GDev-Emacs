;;; gdev-keys.el --- Tasti guida e mappe del linguaggio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una regola rende la mappa dei tasti facile da imparare: C-c e
;; una lettera aprono un gruppo con quel nome.  Emacs riserva proprio questi
;; tasti all'utente, quindi nessun pacchetto li occupa.
;;
;;   C-c a  agenti                       C-c o  apri
;;   C-c b  aree di testo                C-c p  progetto
;;   C-c c  codice                       C-c P  profilazione
;;   C-c d  esecuzione passo passo       C-c q  esci e sessioni
;;   C-c f  file                         C-c r  macchine remote
;;   C-c g  Hit e HitHub                 C-c s  cerca
;;   C-c i  inserisci                    C-c t  attiva/disattiva
;;   C-c l  linguaggio                   C-c w  finestre e spazi di lavoro
;;   C-c n  note e procedure             C-c !  segnalazioni
;;
;;   C-c l    comandi del linguaggio attivo
;;   C-h d    aiuto GDev: mappa dei tasti, moduli, tempi, diagnosi
;;
;; Dopo un prefisso basta una pausa e which-key elenca i tasti che seguono.
;;
;; Il menu e il clic destro riusano i gruppi e le mappe C-c l
;; nel modulo :ui workbench. Il modulo :config default riempie i gruppi,
;; mentre i moduli dei linguaggi usano `gdev-localleader'.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'cl-lib)
(require 'seq)

;;;; Gruppi

(defvar-keymap gdev-agent-map :doc "C-c a: modelli linguistici e agenti di programmazione.")
(defvar-keymap gdev-buffer-map :doc "C-c b: aree di testo.")
(defvar-keymap gdev-code-map :doc "C-c c: azioni sul codice che conoscono il linguaggio.")
(defvar-keymap gdev-debug-map :doc "C-c d: esecuzione passo passo.")
(defvar-keymap gdev-file-map :doc "C-c f: file.")
(defvar-keymap gdev-git-map :doc "C-c g: Hit e HitHub.")
(defvar-keymap gdev-insert-map :doc "C-c i: inserisci.")
(defvar-keymap gdev-notes-map :doc "C-c n: note e procedure operative.")
(defvar-keymap gdev-open-map :doc "C-c o: apri strumenti.")
(defvar-keymap gdev-project-map :doc "C-c p: progetto: compila, esegui, prova.")
(defvar-keymap gdev-profile-map :doc "C-c P: profilazione e analisi.")
(defvar-keymap gdev-quit-map :doc "C-c q: esci, riavvia, sessioni.")
(defvar-keymap gdev-remote-map :doc "C-c r: macchine remote e amministrazione di sistema.")
(defvar-keymap gdev-search-map :doc "C-c s: cerca.")
(defvar-keymap gdev-toggle-map :doc "C-c t: attiva/disattiva.")
(defvar-keymap gdev-voice-map :doc "C-c v: comandi italiani, dettatura e lettura.")
(defvar-keymap gdev-workspace-map :doc "C-c w: finestre e spazi di lavoro.")
(defvar-keymap gdev-checkers-map :doc "C-c !: segnalazioni e ortografia.")
(defvar-keymap gdev-help-map :doc "C-h d: aiuto GDev.")

(defconst gdev-leader-groups
  '(("a" gdev-agent-map     "agenti")
    ("b" gdev-buffer-map    "aree di testo")
    ("c" gdev-code-map      "codice")
    ("d" gdev-debug-map     "esecuzione passo passo")
    ("f" gdev-file-map      "file")
    ("g" gdev-git-map       "Hit e HitHub")
    ("i" gdev-insert-map    "inserisci")
    ("n" gdev-notes-map     "note e procedure")
    ("o" gdev-open-map      "apri")
    ("p" gdev-project-map   "progetto")
    ("P" gdev-profile-map   "profilazione")
    ("q" gdev-quit-map      "esci e sessioni")
    ("r" gdev-remote-map    "macchine remote")
    ("s" gdev-search-map    "cerca")
    ("t" gdev-toggle-map    "attiva/disattiva")
    ("v" gdev-voice-map     "voce")
    ("w" gdev-workspace-map "finestre e spazi di lavoro")
    ("!" gdev-checkers-map  "segnalazioni"))
  "C-c TASTO, variabile della mappa, etichetta per which-key e per il menu.")

;; Una scorciatoia della forma ("etichetta" . mappa) è un prefisso con nome:
;; which-key mostra l'etichetta senza caricare nulla.
(pcase-dolist (`(,key ,map ,label) gdev-leader-groups)
  (keymap-global-set (concat "C-c " key) (cons label (symbol-value map))))
(keymap-set help-map "d" (cons "aiuto GDev" gdev-help-map))

;;;; Funzioni per le scorciatoie

(defun gdev-bind (keymap &rest bindings)
  "Definisce BINDINGS in KEYMAP.  BINDINGS sono terne TASTO DESCRIZIONE COMANDO.
DESCRIZIONE è ciò che mostrano which-key e i menu; nil mostra il nome del
comando."
  (while bindings
    (let ((key (pop bindings))
          (description (pop bindings))
          (command (pop bindings)))
      (keymap-set keymap key (if description (cons description command) command)))))

(defvar gdev--localleader-maps (make-hash-table :test #'eq :weakness 'key)
  "Mappa di una modalità -> la sua mappa C-c l.")

(defun gdev-localleader-map (keymap)
  "Restituisce la mappa C-c l della mappa di modalità KEYMAP (creata se serve).
La mappa di una modalità eredita da quella della modalità padre; la sua mappa
C-c l eredita a sua volta quella del padre, così le scorciatoie non risalgono
mai verso l'alto."
  (or (gethash keymap gdev--localleader-maps)
      (let ((map (make-sparse-keymap))
            (inherited (keymap-lookup keymap "C-c l")))
        (when (keymapp inherited)
          (set-keymap-parent map inherited))
        (keymap-set keymap "C-c l" (cons "linguaggio" map))
        (puthash keymap map gdev--localleader-maps))))

(defmacro gdev-localleader (feature keymap &rest bindings)
  "Quando FEATURE è caricata, definisce BINDINGS sotto C-c l in KEYMAP.
KEYMAP è una variabile che contiene la mappa di una modalità; BINDINGS sono
terne TASTO DESCRIZIONE COMANDO, come per `gdev-bind'."
  (declare (indent 2))
  (cl-loop for (key) on bindings by #'cdddr
           when (and (stringp key) (not (key-valid-p key)))
           do (error "Scorciatoia non valida: %s" key))
  `(gdev-register-after-module
    (lambda ()
      (with-eval-after-load ',feature
        (gdev-bind (gdev-localleader-map ,keymap) ,@bindings)))))

;;;; Nomi leggibili dei comandi

(defvar which-key-replacement-alist)

(defvar gdev-keys--command-labels (make-hash-table :test #'eq)
  "Comando -> etichetta registrata da un modulo per which-key e per i menu.")

(defvar gdev-keys--command-prefixes nil
  "Alist (PREFISSO . NOME): i comandi di un fork appaiono col nome GDev.")

(defvar gdev-keys--command-aliases nil
  "Alist (PREFISSO . PREFISSO-GDEV): in M-x i comandi prendono il nome GDev.")

(defvar gdev-keys--aliases-stale nil
  "Non nil quando nuovi comandi da rinominare possono essere stati definiti.")

(defvar gdev-keys--offering-alias nil
  "Non nil mentre M-x decide se offrire l'alias di un comando rinominato.")

(cl-defun gdev-keys-register-commands (prefix name &key labels alias)
  "Mostra con il nome GDev NAME i comandi il cui nome inizia con PREFIX.
LABELS è un alist (COMANDO . ETICHETTA) per i comandi che compaiono senza
una descrizione, per esempio dopo un prefisso in which-key.  Un comando
senza etichetta appare come «NAME · resto del nome», mai con il nome
originale del fork.

Con ALIAS, in M-x ogni comando PREFIX-RESTO si chiama ALIAS-RESTO e il
nome originale esce dai candidati.  Il nome originale resta valido per
tasti, configurazione Lisp e integrazioni.  Le descrizioni degli alias
sostituiscono il nome del fork, ricavato da PREFIX, con NAME."
  (pcase-dolist (`(,command . ,label) labels)
    (puthash command label gdev-keys--command-labels))
  (setf (alist-get prefix gdev-keys--command-prefixes nil nil #'equal) name)
  (when alias
    (setf (alist-get prefix gdev-keys--command-aliases nil nil #'equal) alias)
    ;; Gli alias nascono alla prima apertura di M-x: l'avvio non paga nulla.
    (setq gdev-keys--aliases-stale t))
  (with-eval-after-load 'which-key
    (add-to-list 'which-key-replacement-alist
                 (cons (cons nil (concat "\\`" (regexp-quote prefix)))
                       #'gdev-keys--which-key-label))))

(defun gdev-keys--original-include-p (symbol buffer)
  "Nasconde da M-x il nome originale SYMBOL.
Mentre M-x valuta il suo alias, decide come avrebbe deciso per SYMBOL in
BUFFER prima della rinomina."
  (and gdev-keys--offering-alias
       (if-let* ((previous (get symbol 'gdev-keys-previous-predicate)))
           (funcall previous symbol buffer)
         (or (null (command-modes symbol))
             (command-completion-using-modes-p symbol buffer)))))

(defun gdev-keys--alias-include-p (symbol buffer)
  "Offre l'alias SYMBOL in M-x se l'originale sarebbe offerto in BUFFER."
  (let ((gdev-keys--offering-alias t))
    (gdev-keys--original-include-p (get symbol 'gdev-keys-original) buffer)))

(defun gdev-keys--keymap-include-p (function symbol buffer)
  "Con M-X valuta l'alias SYMBOL attraverso i tasti del comando originale.
FUNCTION è il predicato di M-X che decide per BUFFER: cerca i comandi
nelle mappe della vista, dove compare solo il nome originale.  Un nome
rinominato non è mai offerto, nemmeno se dichiara le modalità di BUFFER."
  (cond ((get symbol 'gdev-keys-original)
         (let ((gdev-keys--offering-alias t))
           (funcall function (get symbol 'gdev-keys-original) buffer)))
        ((get symbol 'gdev-keys-alias) nil)
        (t (funcall function symbol buffer))))

(defun gdev-keys--buffer-predicate (predicate)
  "Rende PREDICATE, il filtro di M-X, consapevole degli alias."
  (lambda (symbol buffer)
    (gdev-keys--keymap-include-p predicate symbol buffer)))

(defun gdev-keys--alias-documentation (original)
  "Documentazione di ORIGINAL con i nomi GDev al posto di quelli del fork.
Il nome del fork, ricavato dal prefisso, diventa il nome GDev e i comandi
citati prendono il proprio alias.  Un comando tra \\=\\[ e ] resta com'è:
serve a trovare i suoi tasti, legati al nome originale."
  (when-let* ((text (ignore-errors (documentation original t)))
              (entry (seq-find (lambda (entry) (string-prefix-p (car entry) (symbol-name original)))
                               gdev-keys--command-prefixes)))
    (let ((case-fold-search nil)
          (fork (capitalize (string-remove-suffix "-" (car entry)))))
      ;; Ogni parola è intera: «Magit's» cambia, «Magit-Section» no.
      (replace-regexp-in-string
       "\\(\\\\\\[\\)?\\([-[:alnum:]/+*]+\\)"
       (lambda (match)
         (let* ((word (match-string 2 match))
                (alias (get (intern-soft word) 'gdev-keys-alias)))
           (cond ((match-beginning 1) match)
                 ((equal word fork) (cdr entry))
                 ((and alias (not (eq alias t))) (symbol-name alias))
                 (t match))))
       text t t))))

(defun gdev-keys--define-aliases ()
  "Dà il nome GDev in M-x ai comandi dei prefissi registrati."
  (setq gdev-keys--aliases-stale nil)
  (pcase-dolist (`(,prefix . ,alias) gdev-keys--command-aliases)
    ;; `all-completions' scorre i simboli in C: pochi millisecondi anche
    ;; con l'intero obarray.
    (dolist (name (all-completions prefix obarray
                                   (lambda (symbol)
                                     (and (not (get symbol 'gdev-keys-alias))
                                          (commandp symbol)))))
      (let* ((symbol (intern name))
             ;; Un nome obsoleto non riceve un alias: il suo nome attuale
             ;; ha già il proprio.  M-x lo mostrerebbe comunque, perché
             ;; non sa leggere versioni come «Magit 4.3.2».
             (target (unless (get symbol 'byte-obsolete-info)
                       (intern (concat alias (substring name (length prefix)))))))
        (when (and target (not (fboundp target)))
          (defalias target symbol)
          (put target 'gdev-keys-original symbol)
          (put target 'completion-predicate #'gdev-keys--alias-include-p)
          (put target 'function-documentation `(gdev-keys--alias-documentation ',symbol)))
        ;; Il nome originale esce da M-x solo se c'è un nome GDev da usare.
        (when (or (null target) (commandp target))
          (put symbol 'gdev-keys-alias (or target t))
          (put symbol 'gdev-keys-previous-predicate (get symbol 'completion-predicate))
          (put symbol 'completion-predicate #'gdev-keys--original-include-p))))))

(defun gdev-keys-refresh-aliases (&rest _)
  "Completa gli alias prima che M-x, o un elenco di comandi per nome, li mostri."
  (when gdev-keys--aliases-stale
    (gdev-keys--define-aliases)))

(defun gdev-keys-command-applicable-p (symbol buffer)
  "Indica se il comando SYMBOL è applicabile in BUFFER secondo M-x.
Un comando rinominato conta con il suo nome originale: la tavolozza e i
menu elencano i comandi per etichetta e ne usano il simbolo reale, quindi
la rinomina non deve nasconderli.  Chi elenca i comandi per nome usa
direttamente `read-extended-command-predicate', come M-x."
  (and (commandp symbol)
       (or (not (symbolp symbol)) (not read-extended-command-predicate)
           (let ((gdev-keys--offering-alias t))
             (funcall read-extended-command-predicate symbol buffer)))))

(defun gdev-keys--alias-affixation (entries)
  "Accanto agli alias in M-x mostra i tasti dell'originale, non il suo nome.
ENTRIES sono le voci (CANDIDATO PREFISSO SUFFISSO) dell'annotatore integrato,
che per un alias scriverebbe «(nome-del-fork)»."
  (with-selected-window (or (minibuffer-selected-window) (selected-window))
    (mapcar (lambda (entry)
              (let* ((symbol (and (stringp (car-safe entry)) (intern-soft (car entry))))
                     (original (and symbol (get symbol 'gdev-keys-original))))
                (if (not original)
                    entry
                  (let* ((binding (where-is-internal original overriding-local-map t))
                         (suffix (if (and binding (not (stringp binding)))
                                     (format " (%s)" (key-description binding))
                                   "")))
                    (put-text-property 0 (length suffix) 'face 'completions-annotations suffix)
                    (list (car entry) "" suffix)))))
            entries)))

(defun gdev-keys--annotate-original-binding (function candidate)
  "Con Marginalia cerca i tasti dell'originale quando CANDIDATE è un alias.
FUNCTION è `marginalia-annotate-binding'."
  (let* ((symbol (and (stringp candidate) (intern-soft candidate)))
         (original (and symbol (get symbol 'gdev-keys-original))))
    (funcall function (if original (symbol-name original) candidate))))

(defun gdev-keys--note-load (file)
  "Segnala nuovi comandi da rinominare quando FILE appartiene a un fork registrato."
  (when (and gdev-keys--command-aliases (not gdev-keys--aliases-stale))
    (let ((base (file-name-base file)))
      (when (seq-some (lambda (entry) (string-prefix-p (string-remove-suffix "-" (car entry)) base))
                      gdev-keys--command-aliases)
        (setq gdev-keys--aliases-stale t)))))

(add-hook 'after-load-functions #'gdev-keys--note-load)
(advice-add 'read-extended-command :before #'gdev-keys-refresh-aliases)
(advice-add 'command-completion-using-modes-and-keymaps-p :around #'gdev-keys--keymap-include-p)
(advice-add 'read-extended-command--affixation :filter-return #'gdev-keys--alias-affixation)
(with-eval-after-load 'marginalia
  (advice-add 'marginalia-annotate-binding :around #'gdev-keys--annotate-original-binding))
;; M-X costruisce il proprio filtro senza passare dalla funzione precedente.
(advice-add 'command-completion--command-for-this-buffer-function :filter-return
            #'gdev-keys--buffer-predicate)

(defun gdev-keys-command-label (command &optional generic)
  "Etichetta registrata per COMMAND, un simbolo o il suo nome, o nil.
Con GENERIC, un comando di un prefisso registrato senza etichetta propria
riceve «NOME · resto del nome»."
  (let ((name (if (symbolp command) (symbol-name command) command)))
    (or (gethash (intern-soft name) gdev-keys--command-labels)
        (and generic
             (when-let* ((entry (seq-find (lambda (entry) (string-prefix-p (car entry) name))
                                          gdev-keys--command-prefixes)))
               (concat (cdr entry) " · "
                       (string-replace "-" " " (substring name (length (car entry))))))))))

(defun gdev-keys--which-key-label (key-binding)
  "Sostituisce in KEY-BINDING il nome del comando con la sua etichetta."
  (cons (car key-binding)
        (or (gdev-keys-command-label (cdr key-binding) t)
            (cdr key-binding))))

;;;; which-key (incluso in Emacs dalla versione 30)

(declare-function which-key-key-order-alpha "which-key")
(defvar which-key-idle-delay)
(defvar which-key-idle-secondary-delay)
(defvar which-key-sort-order)
(defvar which-key-show-prefix)
(defvar which-key-max-description-length)
(defvar which-key-add-column-padding)

(setq which-key-idle-delay 0.4
      which-key-idle-secondary-delay 0.05
      which-key-sort-order #'which-key-key-order-alpha
      which-key-show-prefix 'top
      which-key-max-description-length 36
      which-key-add-column-padding 1)
(with-eval-after-load 'which-key
  ;; Nel riquadro compare "rename-thing" invece di "gdev-rename-thing".
  (add-to-list 'which-key-replacement-alist '((nil . "\\`gdev-") . (nil . ""))))
(add-hook 'emacs-startup-hook #'which-key-mode)

(provide 'gdev-keys)
;;; gdev-keys.el ends here
