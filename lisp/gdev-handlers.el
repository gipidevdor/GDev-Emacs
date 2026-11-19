;;; gdev-handlers.el --- Gestori (handler) per linguaggio, registrati dai moduli -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; I comandi generici funzionano in ogni linguaggio: formatta, esegui,
;; test, interprete interattivo (REPL), valuta, documentazione, profila,
;; correzione errori (debug).  Ciascun modulo di linguaggio dice che cosa
;; significano per le sue modalità principali:
;;
;;   (gdev-set-formatter 'cperl-mode #'gdev-perl-perltidy)
;;   (gdev-set-runner 'cperl-mode :run #'gdev-perl-run-file
;;                                :test #'gdev-perl-test-file)
;;   (gdev-set-repl 'cperl-mode #'gdev-perl-repl)
;;
;; I moduli condividono le voci dei registri che non modificano.
;; Il comando generico cerca il gestore alla sua esecuzione.
;; Un gestore registrato per una modalità serve anche le modalità derivate.

;;; Code:

(require 'gdev-lib)

(defvar gdev--staging-registrations nil)
(defvar gdev--registration-effects nil)

(defun gdev-register-after-module (function)
  "Esegui FUNCTION dopo che il modulo in caricamento ha registrato le capacità.
Fuori dal caricamento dei moduli eseguila subito."
  (if gdev--staging-registrations
      (push function gdev--registration-effects)
    (funcall function)))

(defvar gdev--handlers (make-hash-table :test #'eq)
  "Tipo di gestore (parola chiave) -> alist di (MAJOR-MODE . HANDLER).")

(defvar gdev--shared-handler-table nil
  "Tabella pubblicata da copiare alla prima scrittura del modulo.")

(defun gdev--registration-put (key value entries &optional test)
  "Associa KEY a VALUE senza modificare ENTRIES.
Una sostituzione preserva posizione e chiave originali. TEST, se dato,
confronta le chiavi al posto di `eq'."
  (let ((previous (if test (assoc key entries test) (assq key entries))))
    (if previous
        (mapcar (lambda (entry)
                  (if (eq entry previous) (cons (car entry) value) entry))
                entries)
      (cons (cons key value) entries))))

(defun gdev--mode-symbols (modes)
  "Restituisce i simboli delle modalità in MODES.
MODES può usare la forma (MODE :key v) di Eglot."
  (mapcar (lambda (mode) (if (consp mode) (car mode) mode)) (ensure-list modes)))

(defun gdev-set-handler (kind modes handler)
  "Registra HANDLER come gestore KIND per MODES (una modalità o una lista)."
  (when-let* ((mode-list (gdev--mode-symbols modes)))
    (let ((entries (gethash kind gdev--handlers)))
      (dolist (mode mode-list)
        (setq entries (gdev--registration-put mode handler entries)))
      (when (eq gdev--handlers gdev--shared-handler-table)
        (setq gdev--handlers (copy-hash-table gdev--handlers)))
      (puthash kind entries gdev--handlers))
    nil))

(defun gdev-handler (kind &optional mode)
  "Restituisce il gestore KIND per MODE, o per la modalità principale attuale.
Vince il gestore della modalità antenata più vicina."
  (let ((table (gethash kind gdev--handlers)))
    (cl-some (lambda (ancestor) (alist-get ancestor table))
             (derived-mode-all-parents (or mode major-mode)))))

;;;; I tipi di gestore

(defun gdev-set-formatter (modes function)
  "FUNCTION (senza argomenti) formatta il buffer nei MODES.
Vedi editor/format."
  (gdev-set-handler :format modes function))

(cl-defun gdev-set-runner (modes &key run test)
  "Nei MODES, RUN esegue il file visitato e TEST i suoi test.
Vedi tools/build.  RUN riceve un argomento: non nil per chiedere di nuovo
gli argomenti del programma."
  (when run (gdev-set-handler :run modes run))
  (when test (gdev-set-handler :test modes test)))

(defvar gdev-project-languages nil
  "Progetti riconosciuti dai moduli di linguaggio, indicizzati per nome.")

(defun gdev-set-project-language (name modes marker command)
  "Registra NAME per MODES, con MARKER e COMMAND.
MARKER riconosce la radice. COMMAND riceve l'azione e la radice e
restituisce una lista con eseguibile e argomenti."
  (setq gdev-project-languages
        (gdev--registration-put name (cons marker command) gdev-project-languages))
  (gdev-set-handler :project-language modes name)
  (gdev-set-handler :build-root modes #'gdev-language-root)
  (gdev-set-runner modes :run #'gdev-language-run :test #'gdev-language-test))

(defun gdev-language-root ()
  "Trova il progetto del linguaggio corrente, anche dentro un repository."
  (if-let* ((name (gdev-handler :project-language))
            (marker (car (alist-get name gdev-project-languages)))
            (root (locate-dominating-file default-directory marker)))
      (file-name-as-directory (expand-file-name root))
    (gdev-project-root)))

(defun gdev-language-command (action root &optional only-current-mode)
  "Restituisci eseguibile e argomenti per ACTION in ROOT.
ONLY-CURRENT-MODE limita il riconoscimento al linguaggio del documento."
  (let* ((current (assq (gdev-handler :project-language) gdev-project-languages))
         (entry (or (and current (funcall (cadr current) root) current)
                    (unless only-current-mode
                      (cl-find-if (lambda (candidate) (funcall (cadr candidate) root))
                                  gdev-project-languages)))))
    (when entry (funcall (cddr entry) action root))))

(defun gdev-language-run (&optional ask-arguments)
  "Esegui il progetto attivo. Con ASK-ARGUMENTS, chiedi gli argomenti."
  (let* ((root (gdev-language-root))
         (command (gdev-language-command 'run root t))
         (arguments (when ask-arguments (read-shell-command "Argomenti del programma: "))))
    (unless command (user-error "Nessun programma configurato per questo progetto"))
    (save-buffer)
    (gdev-compile (concat (gdev-command-line (car command) (cdr command))
                          (when arguments (concat " " arguments)))
                  (format "Esecuzione · %s" (abbreviate-file-name root)) root t)))

(defun gdev-language-test ()
  "Esegui i test del progetto del linguaggio corrente."
  (let* ((root (gdev-language-root))
         (command (gdev-language-command 'test root t)))
    (unless command (user-error "Nessun comando di test configurato per questo progetto"))
    (save-buffer)
    (gdev-compile (gdev-command-line (car command) (cdr command))
                  (format "Test · %s" (abbreviate-file-name root)) root)))

(defun gdev-set-repl (modes function)
  "FUNCTION (senza argomenti) apre un REPL per MODES e ne restituisce il buffer.
Vedi tools/eval."
  (gdev-set-handler :repl modes function))

(defun gdev-set-eval (modes function)
  "FUNCTION valuta la selezione tra i suoi argomenti BEG ed END, nei MODES."
  (gdev-set-handler :eval modes function))

(defun gdev-set-documentation (modes function)
  "FUNCTION (senza argomenti) mostra la documentazione di ciò che è al cursore."
  (gdev-set-handler :documentation modes function))

(defun gdev-set-docsets (modes &rest docsets)
  "Registra la documentazione locale (offline) per MODES.
DOCSETS sono identificativi (slug) di devdocs.  Vedi tools/lookup."
  (gdev-set-handler :docsets modes docsets))

(defun gdev-set-profiler (modes function)
  "FUNCTION (senza argomenti) profila il codice corrente, nei MODES.
Vedi tools/profiler."
  (gdev-set-handler :profile modes function))

(defun gdev-set-debugger (modes function)
  "FUNCTION (senza argomenti) avvia il debugger sul codice corrente, nei MODES.
Vedi tools/debugger."
  (gdev-set-handler :debug modes function))

(defun gdev-set-coverage (modes function)
  "FUNCTION (senza argomenti) misura la copertura (coverage) dei test.
La misura riguarda l'intero progetto.  Vedi tools/profiler."
  (gdev-set-handler :coverage modes function))

(defun gdev-set-other-file (modes function)
  "FUNCTION (senza argomenti) apre il file compagno di quello visitato.
Vale nei MODES.  Il compagno è per esempio l'intestazione (header) di un
sorgente o il test di un modulo."
  (gdev-set-handler :other-file modes function))

(cl-defun gdev-set-eglot-server (modes contact &key when)
  "Usa CONTACT come server di linguaggio (language server) per MODES.
CONTACT segue la sintassi di Eglot.  WHEN, una funzione senza argomenti,
deve restituire non nil perché il server parta da solo; senza WHEN basta
che il programma in CONTACT esista.  Vedi tools/lsp."
  (gdev-set-handler :eglot modes (list :contact contact :when when))
  (gdev-register-after-module
   (lambda ()
     (with-eval-after-load 'eglot
       (defvar eglot-server-programs)
       (add-to-list 'eglot-server-programs (cons (ensure-list modes) contact))))))

;;;; Verifiche dell'ambiente (gdev doctor)

(defvar gdev-doctor-checks nil
  "Verifiche registrate dai moduli: (LABEL PREDICATE HINT SEVERITY).")

(defun gdev-doctor-check (label predicate hint &optional severity)
  "Registra una verifica per `gdev doctor'.
PREDICATE (senza argomenti) restituisce non nil se LABEL è a posto; HINT
spiega come rimediare.  SEVERITY è `warning' (predefinito: manca una
funzionalità) o `note' (un extra facoltativo).  Una seconda verifica con
la stessa LABEL (due moduli che richiedono lo stesso programma) sostituisce
la prima."
  (let ((check (list predicate hint (or severity 'warning))))
    (setq gdev-doctor-checks
          (gdev--registration-put label check gdev-doctor-checks #'equal))
    check))

(defun gdev-doctor-executable (program hint &optional severity)
  "Registra una verifica di `gdev doctor': PROGRAM deve essere installato.
HINT e SEVERITY valgono come in `gdev-doctor-check'."
  (gdev-doctor-check program (lambda () (executable-find program)) hint severity))

;;;; Posizione delle finestre per i buffer degli strumenti

(defvar gdev-popup-rules nil
  "Regole registrate con `gdev-set-popup-rule', dalla più recente.")

(defun gdev-set-popup-rule (condition &rest properties)
  "Assegna al pannello degli strumenti i buffer che soddisfano CONDITION.
CONDITION ha il formato di una condizione di `buffer-match-p'.
PROPERTIES accetta :select per portare il fuoco nello strumento.
La geometria è condivisa da tutti gli strumenti dello spazio di lavoro."
  (push (cons condition properties) gdev-popup-rules))

;;;; Azioni dei moduli nei menu e nel riquadro Comandi

(defvar gdev-tool-action-groups nil
  "Gruppi registrati dai moduli, ciascuno (ID ETICHETTA ICONA . VOCI).")

(defvar gdev-tool-actions-change-hook nil
  "Funzioni chiamate dopo la registrazione delle azioni di un modulo.")

(defun gdev-set-tool-actions (id label icon &rest items)
  "Registra ITEMS come gruppo ID con LABEL e ICON.
Le voci usano il formato easy-menu [ETICHETTA COMANDO PROPRIETÀ…].
Le condizioni :visible e :active si valutano nella vista attiva.
Devono essere rapide e prive di effetti collaterali."
  (setq gdev-tool-action-groups
        (gdev--registration-put id (cons label (cons icon items)) gdev-tool-action-groups))
  (unless gdev--staging-registrations
    (run-hooks 'gdev-tool-actions-change-hook)))

(defun gdev-load-module-registrations (load-module &optional on-commit)
  "Valuta LOAD-MODULE e pubblica i registri delle capacità se riesce.
La funzione facoltativa ON-COMMIT pubblica l'esito dell'attivazione
prima degli effetti registrati e dell'aggiornamento del riquadro Comandi."
  (let* ((previous-groups gdev-tool-action-groups)
         (staged
          (let ((gdev--shared-handler-table gdev--handlers)
                (gdev--handlers gdev--handlers)
                (gdev-project-languages gdev-project-languages)
                (gdev-doctor-checks gdev-doctor-checks)
                (gdev-popup-rules gdev-popup-rules)
                (gdev-tool-action-groups previous-groups)
                (gdev--registration-effects nil)
                (gdev--staging-registrations t))
            (funcall load-module)
            (list gdev--handlers gdev-project-languages gdev-doctor-checks
                  gdev-popup-rules gdev-tool-action-groups
                  (nreverse gdev--registration-effects))))
         effects)
    (let ((inhibit-quit t))
      (pcase-setq `(,gdev--handlers ,gdev-project-languages ,gdev-doctor-checks
                    ,gdev-popup-rules ,gdev-tool-action-groups ,effects) staged)
      (when on-commit (funcall on-commit)))
    (dolist (effect effects)
      (with-demoted-errors "Registrazione successiva all'attivazione: %S"
        (funcall effect)))
    (unless (equal previous-groups gdev-tool-action-groups)
      (with-demoted-errors "Aggiornamento riquadro Comandi: %S"
        (run-hooks 'gdev-tool-actions-change-hook)))))

(provide 'gdev-handlers)
;;; gdev-handlers.el ends here
