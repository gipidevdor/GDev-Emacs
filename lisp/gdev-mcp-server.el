;;; gdev-mcp-server.el --- Socket MCP dell'editor dal vivo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Apre nell'istanza GDev un socket Unix su cui il ponte `bin/gdev-mcp'
;; parla MCP: JSON-RPC 2.0, un messaggio per riga.  Ogni connessione ha
;; la propria sessione, gestita da `gdev-mcp-handle-line', e ogni
;; strumento è una chiamata di funzione in questo Emacs.
;;
;; Il socket sta in una cartella dell'utente con permessi 0700, come
;; quello di `server-start': solo i processi dello stesso utente possono
;; collegarsi.  Non esiste una variante TCP.  Il nome dipende dal checkout
;; e dalla cartella di stato, così il ponte trova l'istanza giusta anche
;; senza --socket.  Il modulo :tools agent lo apre subito dopo l'avvio;
;; altrimenti usa M-x gdev-mcp-server-start, oppure avvia il ponte con
;; --socket.  Le connessioni seguono il controllo di flusso descritto in
;; `gdev-mcp'.

;;; Code:

(require 'gdev-mcp)

(defcustom gdev-agent-mcp-autostart t
  "Se non nil, il modulo :tools agent apre all'avvio il socket MCP.
Gli agenti collegati con bin/gdev-mcp pilotano questa istanza attraverso
il socket.  Con nil il server MCP offre solo la scoperta del checkout,
finché non usi \[gdev-mcp-server-start]."
  :type 'boolean
  :group 'gdev)

(defvar gdev-mcp-server--process nil
  "Processo in ascolto sul socket MCP.")

(defvar gdev-mcp-server--file nil
  "Percorso del socket MCP aperto da questa istanza.")

(defvar gdev-mcp-server--timer nil
  "Timer che riapre il socket se il suo file viene rimosso.")

(defun gdev-mcp-server--prepare-directory (directory)
  "Crea DIRECTORY accessibile solo all'utente, o segnala perché non è sicura."
  (let ((file-name-handler-alist nil))
    (with-file-modes #o700
      (make-directory directory t))
    ;; Senza la barra finale: con essa lstat segue un collegamento simbolico.
    (let ((attributes (file-attributes (directory-file-name directory) 'integer)))
      (unless (and (eq (file-attribute-type attributes) t)
                   (eql (file-attribute-user-id attributes) (user-uid)))
        (user-error "La cartella %s non appartiene all'utente" directory))
      (unless (gdev-mcp-private-directory-p directory)
        (set-file-modes directory #o700)))))

(defun gdev-mcp-server--answers-p (file)
  "Indica se un altro processo risponde sul socket FILE."
  (condition-case nil
      (progn (delete-process (make-network-process :name "gdev-mcp-prova" :family 'local
                                                   :service file :noquery t))
             t)
    (error nil)))

(defun gdev-mcp-server--free (file)
  "Restituisci FILE se è libero, dopo aver rimosso un socket orfano."
  (let ((file-name-handler-alist nil))
    (cond ((not (file-exists-p file)) file)
          ((not (gdev-mcp-private-socket-p file)) nil)
          ((gdev-mcp-server--answers-p file) nil)
          (t (delete-file file) file))))

(defun gdev-mcp-server--session ()
  "Crea la sessione MCP di una nuova connessione."
  (gdev-mcp-session-create :tools (lambda (_session) gdev-mcp-all-tools)
                           :call #'gdev-mcp-call-in-process))

(defun gdev-mcp-server--send (connection response)
  "Invia RESPONSE su CONNECTION, se è ancora aperta."
  (when (process-live-p connection)
    ;; Un client che chiude la connessione non riguarda l'editor.
    (condition-case nil
        (gdev-mcp-send connection (concat response "\n"))
      (error (delete-process connection)))))

(defun gdev-mcp-server--answer (connection line)
  "Rispondi alla riga LINE ricevuta su CONNECTION."
  (let ((session (or (process-get connection 'gdev-mcp-session)
                     (let ((session (gdev-mcp-server--session)))
                       (process-put connection 'gdev-mcp-session session)
                       session)))
        done)
    (unwind-protect
        (let ((response (gdev-mcp-handle-line session line)))
          (setq done t)
          (when response
            (gdev-mcp-server--send connection response)))
      ;; Un tasto come RET in un minibuffer aperto prima della richiesta può
      ;; uscire con un salto non locale: il client riceve comunque l'esito.
      (unless done
        (gdev-mcp-server--send
         connection
         (gdev-mcp--encode
          (gdev-mcp--rpc-result
           (gdev-mcp-request-id (gdev-mcp--parse line))
           `((content . [((type . "text")
                          (text . "L'esecuzione ha chiuso il minibuffer o la modifica ricorsiva in attesa."))])
             (isError . :false)))))))))

(defconst gdev-mcp-server-line-limit (* 8 1024 1024)
  "Byte massimi di una riga in ingresso: oltre, la connessione è chiusa.
Ogni richiesta è una riga JSON; i dati degli strumenti sono già limitati a
1 MiB, quindi una riga più lunga non è una richiesta ma un flusso senza fine.")

(defun gdev-mcp-server--filter (connection output)
  "Accumula OUTPUT di CONNECTION e rispondi a ogni riga completa."
  (gdev-mcp-note-input connection output)
  (process-put connection 'gdev-mcp-input
               (concat (process-get connection 'gdev-mcp-input) output))
  (when (and (> (length (process-get connection 'gdev-mcp-input)) gdev-mcp-server-line-limit)
             (not (string-search "\n" (process-get connection 'gdev-mcp-input))))
    (delete-process connection))
  ;; Uno strumento che attende processi può far rientrare il filtro: le
  ;; righe successive aspettano la fine di quella in corso.
  (unless (process-get connection 'gdev-mcp-busy)
    (process-put connection 'gdev-mcp-busy t)
    (unwind-protect
        (let (newline)
          (while (and (process-live-p connection)
                      (setq newline (string-search "\n" (process-get connection 'gdev-mcp-input))))
            (let ((input (process-get connection 'gdev-mcp-input)))
              (process-put connection 'gdev-mcp-input (substring input (1+ newline)))
              ;; Le righe vuote servono al controllo di flusso.
              (unless (= newline 0)
                (gdev-mcp-server--answer connection (substring input 0 newline))))))
      (process-put connection 'gdev-mcp-busy nil))))

(defun gdev-mcp-server--sentinel (process _event)
  "Rimuovi il socket quando il processo in ascolto PROCESS termina."
  (when (and (eq process gdev-mcp-server--process)
             (not (process-live-p process))
             gdev-mcp-server--file)
    (ignore-errors (delete-file gdev-mcp-server--file))))

(defun gdev-mcp-server--socket-lost-p ()
  "Indica se il processo ascolta ancora ma il file del suo socket è sparito.
Su macOS la pulizia periodica di `$TMPDIR' può rimuoverlo: senza file il
ponte non trova più l'editor."
  (and (process-live-p gdev-mcp-server--process)
       gdev-mcp-server--file
       (not (let ((file-name-handler-alist nil))
              (file-exists-p gdev-mcp-server--file)))))

(defun gdev-mcp-server--repair ()
  "Riapre il socket se il suo file è stato rimosso mentre l'editor ascoltava."
  (when (gdev-mcp-server--socket-lost-p)
    (condition-case err
        (gdev-mcp-server-start)
      (error (display-warning 'gdev-mcp
                              (format "Socket MCP non ripristinato: %s" (error-message-string err))
                              :warning)))))

;;;###autoload
(defun gdev-mcp-server-start ()
  "Apri il socket privato con cui il server MCP di GDev pilota questa istanza.
Restituisci il percorso del socket."
  (interactive)
  (when (gdev-mcp-server--socket-lost-p)
    (gdev-mcp-server-stop))
  (unless (process-live-p gdev-mcp-server--process)
    (let* ((preferred (gdev-mcp-socket-file))
           (_ (gdev-mcp-server--prepare-directory (file-name-directory preferred)))
           (file (or (gdev-mcp-server--free preferred)
                     ;; Un'altra istanza con lo stesso stato usa già il nome.
                     (gdev-mcp-server--free (format "%s-%d" preferred (emacs-pid)))
                     (user-error "Il socket MCP %s è occupato" preferred))))
      (setq gdev-mcp-server--file file
            gdev-mcp-server--process
            ;; Senza lettura adattiva una richiesta breve non attende.
            (let ((process-adaptive-read-buffering nil))
              (make-network-process :name "gdev-mcp" :server t :family 'local :service file
                                    :coding 'binary :noquery t
                                    :filter #'gdev-mcp-server--filter
                                    :sentinel #'gdev-mcp-server--sentinel)))
      (set-file-modes file #o600)
      (unless (timerp gdev-mcp-server--timer)
        ;; Un solo file-exists-p ogni cinque minuti.
        (setq gdev-mcp-server--timer
              (run-with-timer 300 300 #'gdev-mcp-server--repair)))
      (add-hook 'kill-emacs-hook #'gdev-mcp-server-stop)))
  (when (called-interactively-p 'interactive)
    (message "Server MCP di GDev in ascolto su %s" gdev-mcp-server--file))
  gdev-mcp-server--file)

(defun gdev-mcp-server-stop ()
  "Chiudi il socket MCP e le connessioni degli agenti."
  (interactive)
  (dolist (process (process-list))
    (when (eq (process-filter process) #'gdev-mcp-server--filter)
      (delete-process process)))
  (setq gdev-mcp-server--process nil)
  (when (timerp gdev-mcp-server--timer)
    (cancel-timer gdev-mcp-server--timer)
    (setq gdev-mcp-server--timer nil))
  (when gdev-mcp-server--file
    (ignore-errors (delete-file gdev-mcp-server--file))
    (setq gdev-mcp-server--file nil)))

;;;###autoload
(defun gdev-mcp-server-autostart ()
  "Apri il socket MCP all'avvio se `gdev-agent-mcp-autostart' lo chiede.
Un problema diventa un avviso e non interrompe l'avvio."
  (when gdev-agent-mcp-autostart
    (condition-case err
        (gdev-mcp-server-start)
      (error (display-warning 'gdev-mcp
                              (format "Server MCP non avviato: %s" (error-message-string err))
                              :warning)))))

(provide 'gdev-mcp-server)
;;; gdev-mcp-server.el ends here
