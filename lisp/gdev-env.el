;;; gdev-env.el --- Ambiente della shell salvato in un file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un Emacs avviato dal Dock (o come servizio) non passa dall'interprete dei
;; comandi (shell), quindi non vede PATH, perlbrew, mise e simili.  Avviare
;; una shell di login a ogni avvio costa centinaia di millisecondi.  Invece:
;;
;;   gdev env                    (in un terminale) salva le variabili di
;;                               `gdev-env-variables' nella cartella di stato;
;;   ogni avvio                  legge quel file: microsecondi;
;;   M-x gdev-env-refresh        lo ricostruisce da Emacs, con una shell di
;;                               login.
;;
;; Si salvano solo le variabili dell'elenco, e l'elenco non contiene segreti:
;; il file è testo in chiaro.  Le credenziali arrivano da auth-source, cioè
;; dal Portachiavi (Keychain) di macOS: vedi os/macos.

;;; Code:

(require 'gdev-lib)
(require 'gdev-state-db)

(defgroup gdev-env nil
  "Ambiente dei processi: PATH e variabili degli strumenti."
  :group 'gdev)

(defcustom gdev-env-variables
  '("PATH" "MANPATH" "INFOPATH" "LANG" "LC_ALL" "LC_CTYPE"
    "HOMEBREW_PREFIX" "PKG_CONFIG_PATH"
    "PERLBREW_ROOT" "PERLBREW_HOME" "PERLBREW_PERL" "PERLBREW_PATH" "PERLBREW_MANPATH"
    "PERL5LIB" "PERL_LOCAL_LIB_ROOT" "PERL_MB_OPT" "PERL_MM_OPT"
    "SBCL_HOME" "XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME")
  "Variabili della shell copiate in Emacs quando non parte da una shell.
I segreti (chiavi API, token) mancano di proposito: il file salvato è in
chiaro.  Le credenziali arrivano invece da auth-source."
  :type '(repeat string))

(defconst gdev-env--shell-timeout 5
  "Secondi massimi concessi alla shell per leggere l'ambiente.")

(defvar gdev-env--refresh-process nil
  "Lettura asincrona dell'ambiente ancora in corso.")

(defvar gdev-env--refresh-request nil
  "Identità della richiesta corrente, pubblicata prima di avviare la shell.")

(defvar gdev-env-after-refresh-hook nil
  "Funzioni che aggiornano gli strumenti dopo una nuova lettura dell'ambiente.")

(defun gdev-env-file ()
  "Restituisce il file in cui è salvato l'ambiente."
  (gdev-state-db-file))

(defun gdev-env--apply (pairs)
  "Imposta ogni (NAME . VALUE) di PAIRS e ricostruisce `exec-path' da PATH."
  (pcase-dolist (`(,name . ,value) pairs)
    (when (and (member name gdev-env-variables)
               (not (equal name "SSH_AUTH_SOCK")))
      (setenv name value)))
  (setq exec-path (append (parse-colon-path (getenv "PATH"))
                          (list exec-directory)))
  (gdev-env--add-tool-directories))

(defun gdev-env--add-tool-directories ()
  "Mette la cartella bin degli strumenti GDev davanti a tutte le altre."
  (let ((bin (gdev-tools-file "bin")))
    (when (file-directory-p bin)
      (add-to-list 'exec-path bin)
      ;; `parse-colon-path' restituisce le cartelle con la barra finale.
      (unless (member (file-name-as-directory bin) (parse-colon-path (getenv "PATH")))
        (setenv "PATH" (concat bin path-separator (getenv "PATH")))))))

(defun gdev-env--write (pairs)
  "Scrive PAIRS nel file dell'ambiente salvato."
  (gdev-state-db-with (db t)
    (gdev-state-db--replace db (gdev-state-db--scope db "ambiente" "" t)
                            (assoc-delete-all "SSH_AUTH_SOCK" (copy-sequence pairs)))))

(defun gdev-env-saved-p ()
  (or (gdev-state-db-with (db) (gdev-state-db--scope db "ambiente" ""))
      (file-readable-p (gdev-state-db--legacy "environment.eld"))))

(defun gdev-env-save-current ()
  "Salva i valori attuali di `gdev-env-variables' nel file dell'ambiente.
`gdev env' la chiama da un terminale, dove i valori sono completi."
  (interactive)
  (gdev-env--write (mapcar (lambda (name) (cons name (getenv name))) gdev-env-variables))
  (message "Salvate %d variabili in %s" (length gdev-env-variables) (gdev-env-file)))

(defun gdev-env--finish-reader (process pairs failure)
  "Termina PROCESS una sola volta e consegna PAIRS oppure FAILURE."
  (unless (process-get process 'gdev-env-finished)
    (process-put process 'gdev-env-finished t)
    (when-let* ((timer (process-get process 'gdev-env-timer)))
      (cancel-timer timer)
      (process-put process 'gdev-env-timer nil))
    (set-process-sentinel process #'ignore)
    (when (process-live-p process) (delete-process process))
    (dolist (buffer (list (process-buffer process) (process-get process 'gdev-env-errors)))
      (when (buffer-live-p buffer)
        (when-let* ((child (get-buffer-process buffer)))
          (set-process-query-on-exit-flag child nil)
          (delete-process child))
        (kill-buffer buffer)))
    (funcall (process-get process 'gdev-env-callback) pairs failure)))

(defun gdev-env--reader-sentinel (process _event)
  "Convalida l'uscita della shell PROCESS prima di consegnare i valori."
  (when (memq (process-status process) '(exit signal))
    (condition-case err
        (progn
          (unless (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
            (error "La shell non ha completato la lettura dell'ambiente"))
          (let* ((variables (process-get process 'gdev-env-variables))
                 (values (with-current-buffer (process-buffer process)
                           (cdr (member "__GDEV_ENV__" (split-string (buffer-string) "\0"))))))
            ;; Ogni valore, anche vuoto, deve avere il proprio NUL finale.
            (unless (> (length values) (length variables))
              (error "La shell ha restituito un ambiente incompleto"))
            (gdev-env--finish-reader
             process (cl-mapcar (lambda (name value) (cons name (unless (string-empty-p value) value)))
                                variables values) nil)))
      (error (gdev-env--finish-reader process nil err)))))

(defun gdev-env--read-login-shell (callback)
  "Leggi l'ambiente in un processo e consegna a CALLBACK valori ed errore.
La shell interattiva di login ha un tempo limitato. Il processo possiede
timer, buffer e variabili della richiesta, anche se la configurazione cambia."
  (let* ((shell (or (getenv "SHELL") "/bin/zsh"))
         (variables (copy-sequence gdev-env-variables))
         (script (concat "printf '\\0__GDEV_ENV__\\0'; "
                         (mapconcat (lambda (name) (format "printf '%%s\\0' \"${%s-}\"" name))
                                    variables "; ")))
         (default-directory temporary-file-directory)
         (process-environment (default-value 'process-environment))
         (exec-path (default-value 'exec-path))
         (output (generate-new-buffer " *gdev-env-output*"))
         (errors (generate-new-buffer " *gdev-env-errors*"))
         process)
    (condition-case err
        (progn
          (setq process (make-process :name "gdev-env" :noquery t :connection-type 'pipe
                                      :buffer output :stderr errors :coding 'utf-8-unix
                                      :command (list shell "-l" "-i" "-c" script) :sentinel #'ignore))
          (process-put process 'gdev-env-callback callback)
          (process-put process 'gdev-env-errors errors)
          (process-put process 'gdev-env-variables variables)
          (process-put process 'gdev-env-timer
                       (run-at-time (max 0.01 gdev-env--shell-timeout) nil
                                    #'gdev-env--finish-reader process nil
                                    '(error "Tempo scaduto durante la lettura dell'ambiente")))
          (set-process-sentinel process #'gdev-env--reader-sentinel)
          ;; Un processo molto rapido può essere terminato mentre il
          ;; sentinel era ancora `ignore'. La notifica non viene ripetuta
          ;; quando lo sostituiamo: consegniamo anche questo esito già noto.
          (when (memq (process-status process) '(exit signal))
            (gdev-env--reader-sentinel process "finished\n"))
          process)
      (error
       (when (processp process) (delete-process process))
       (kill-buffer output)
       (kill-buffer errors)
       (signal (car err) (cdr err))))))

(defun gdev-env--from-login-shell ()
  "Restituisci l'ambiente della shell entro `gdev-env--shell-timeout'.
La chiamata Lisp resta sincrona, lasciando eseguire timer e annullamento."
  (let (done pairs failure process)
    (unwind-protect
        (progn
          (setq process (gdev-env--read-login-shell
                         (lambda (values error) (setq done t pairs values failure error))))
          ;; Attendi anche gli altri canali: stdout può essere già chiuso
          ;; mentre stderr o la notifica di uscita devono ancora arrivare.
          (while (not done) (accept-process-output nil 0.05))
          (if failure (signal (car failure) (cdr failure)) pairs))
      (when (and process (not done))
        (gdev-env--finish-reader process nil '(quit))))))

(defun gdev-env-refresh-cancel ()
  "Annulla la lettura dell'ambiente conservando i valori precedenti."
  (interactive)
  (let ((process gdev-env--refresh-process))
    (setq gdev-env--refresh-request nil gdev-env--refresh-process nil)
    (when process
      (gdev-env--finish-reader process nil '(quit))
      (when (called-interactively-p 'interactive) (message "Aggiornamento dell'ambiente annullato")))))

(defun gdev-env--publish (pairs)
  "Salva PAIRS prima di applicarlo all'applicazione, fuori dai buffer di progetto."
  (with-temp-buffer
    (gdev-env--write pairs)
    (gdev-env--apply pairs)
    (with-demoted-errors "Aggiornamento degli strumenti: %S"
      (run-hooks 'gdev-env-after-refresh-hook))))

(defun gdev-env--complete-refresh (request file pairs failure)
  "Pubblica PAIRS di REQUEST soltanto nel profilo FILE ancora corrente.
FAILURE viene segnalato solo per la richiesta ancora valida."
  (when (eq request gdev-env--refresh-request)
    (setq gdev-env--refresh-request nil gdev-env--refresh-process nil)
    (when failure (signal (car failure) (cdr failure)))
    (unless (equal file (gdev-env-file))
      (error "Il profilo è cambiato durante la lettura dell'ambiente"))
    (gdev-env--publish pairs)
    (message "Ambiente aggiornato dalla shell")))

(defun gdev-env-refresh (&optional asynchronous)
  "Leggi l'ambiente della shell, salvalo e applicalo soltanto se completo.
Con ASYNCHRONOUS, e nell'uso interattivo, lascia libero l'editor durante
la lettura. Una nuova richiesta annulla quella precedente."
  (interactive (list t))
  (gdev-env-refresh-cancel)
  (let ((file (gdev-env-file)) (request (list t)) process)
    (setq gdev-env--refresh-request request)
    (if (not asynchronous)
        (unwind-protect
            (gdev-env--complete-refresh request file (gdev-env--from-login-shell) nil)
          (when (eq request gdev-env--refresh-request)
            (setq gdev-env--refresh-request nil)))
      (condition-case err
          (setq process
                (gdev-env--read-login-shell
                 (lambda (pairs failure)
                   (condition-case err
                       (gdev-env--complete-refresh request file pairs failure)
                     (error (display-warning 'gdev (format "%s. Conservo l'ambiente precedente."
                                                          (error-message-string err))))))))
        (error
         (when (eq request gdev-env--refresh-request) (setq gdev-env--refresh-request nil))
         (signal (car err) (cdr err))))
      ;; Il sentinel o un hook possono aver completato o sostituito la
      ;; richiesta già durante l'avvio. Non sovrascrivere quella successiva.
      (when (eq request gdev-env--refresh-request) (setq gdev-env--refresh-process process))
      process)))

(defun gdev-env-load ()
  "Applica l'ambiente salvato se è leggibile e valido."
  (condition-case nil
      (when (gdev-env-saved-p)
        (unless (gdev-state-db-with (db) (gdev-state-db--scope db "ambiente" ""))
          (with-temp-buffer
            (insert-file-contents (gdev-state-db--legacy "environment.eld"))
            (let* ((read-circle nil) (pairs (read (current-buffer))))
              (unless (and (proper-list-p pairs)
                           (cl-every (lambda (pair)
                                       (and (consp pair) (stringp (car pair))
                                            (or (null (cdr pair)) (stringp (cdr pair))))) pairs))
                (error "Formato dell'ambiente non valido"))
              (gdev-state-db-with (db t)
                (unless (gdev-state-db--scope db "ambiente" "")
                  (gdev-env--write pairs))))))
        (gdev-env--apply (gdev-state-db-entries "ambiente" ""))
        t)
    (error
     (display-warning 'gdev "Ambiente salvato illeggibile. Rigeneralo con gdev env.")
     nil)))

;; Su macOS un Emacs grafico o demone (daemon) non ha ereditato l'ambiente
;; di una shell.  Uno avviato da un terminale sì, come le esecuzioni in
;; modalità non interattiva (batch), `gdev' compreso: a lui basta aggiungere
;; gli strumenti GDev.
(defun gdev-env--from-shell-p ()
  "Indica se questo Emacs è partito da una shell e ne ha ereditato l'ambiente.
Da Dock o Finder la variabile SHLVL manca: lì serve l'ambiente salvato."
  (and (getenv "SHLVL") t))

(if (and gdev-macos-p (not noninteractive)
         (or (memq initial-window-system '(ns mac)) (daemonp))
         (not (gdev-env--from-shell-p)))
    (or (gdev-env-load)
        (condition-case nil
            (progn (gdev-env--add-tool-directories) (gdev-env-refresh t) t)
          (error
           (display-warning 'gdev "Uso l’ambiente di avvio. Per aggiornarlo esegui gdev env dal terminale.")
           (gdev-env--add-tool-directories))))
  (gdev-env--add-tool-directories))

(provide 'gdev-env)
;;; gdev-env.el ends here
