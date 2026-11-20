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

(defun gdev-env--from-login-shell ()
  "Restituisce i valori di `gdev-env-variables' in una shell di login.
La shell è interattiva, come quella di un terminale.  I valori arrivano
separati da NUL, quindi un a capo dentro un valore non crea problemi."
  (let* ((shell (or (getenv "SHELL") "/bin/zsh"))
         (marker "__GDEV_ENV__")
         ;; Il marcatore separa i valori da qualunque messaggio stampi la shell.
         (script (concat (format "printf '\\0%s\\0'; " marker)
                         (mapconcat (lambda (name) (format "printf '%%s\\0' \"${%s-}\"" name))
                                    gdev-env-variables "; ")))
         (output (with-temp-buffer
                   (call-process shell nil '(t nil) nil "-l" "-i" "-c" script)
                   (buffer-string)))
         (values (cdr (member marker (split-string output "\0")))))
    (unless (>= (length values) (length gdev-env-variables))
      (error "Impossibile leggere l'ambiente da %s" shell))
    (cl-mapcar (lambda (name value) (cons name (unless (string-empty-p value) value)))
               gdev-env-variables values)))

(defun gdev-env-refresh ()
  "Leggi l'ambiente da una shell di login, salvalo e applicalo."
  (interactive)
  (let ((pairs (gdev-env--from-login-shell)))
    (gdev-env--write pairs)
    (gdev-env--apply pairs)
    (message "Ambiente aggiornato da %s" (getenv "SHELL"))))

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
            (progn (gdev-env-refresh) t)
          (error
           (display-warning 'gdev "Uso l’ambiente di avvio. Per aggiornarlo esegui gdev env dal terminale.")
           (gdev-env--add-tool-directories))))
  (gdev-env--add-tool-directories))

(provide 'gdev-env)
;;; gdev-env.el ends here
