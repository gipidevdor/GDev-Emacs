;;; gdev-mcp-test.el --- Prove del server MCP di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Controlla il server MCP su tre livelli.  Il protocollo JSON-RPC e la
;; validazione degli argomenti girano in questo Emacs, senza socket.  Gli
;; strumenti di pilotaggio valutano, eseguono e leggono l'editor in cui
;; girano le prove.  Il socket privato collega il ponte al server nello
;; stesso Emacs, con il controllo di flusso.  Con GDEV_TEST_SMOKE=1
;; `bin/gdev-mcp' parla con un secondo Emacs batch che fa da editor dal
;; vivo, sia per ricerca automatica sia con --socket.  Senza editor, offre
;; solo la scoperta.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-mcp)
(require 'gdev-mcp-server)
(require 'gdev-agent-control)

(defvar gdev-config-directory)

;;;; Strumenti delle prove

(defun gdev-mcp-test--read (line)
  "Leggi la risposta JSON in LINE come alist."
  (json-parse-string (decode-coding-string line 'utf-8-unix)
                     :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))

(defun gdev-mcp-test--reply (session message)
  "Passa MESSAGE a SESSION e restituisci la risposta letta, o nil."
  (when-let* ((response (gdev-mcp-handle-line
                         session (if (stringp message) message (gdev-mcp--encode message)))))
    (gdev-mcp-test--read response)))

(defun gdev-mcp-test--arguments (&rest pairs)
  "Costruisci gli argomenti JSON di uno strumento da PAIRS."
  (let ((table (make-hash-table :test #'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) table))
    table))

(defun gdev-mcp-test--request (id method &optional params)
  "Costruisci la richiesta JSON-RPC METHOD con ID e PARAMS."
  `((jsonrpc . "2.0") (id . ,id) (method . ,method)
    ,@(when params `((params . ,params)))))

(defun gdev-mcp-test--call (id name &rest arguments)
  "Costruisci la chiamata allo strumento NAME con ID e ARGUMENTS."
  (gdev-mcp-test--request id "tools/call"
                          `((name . ,name) (arguments . ,(apply #'gdev-mcp-test--arguments arguments)))))

(defun gdev-mcp-test--open (session &optional protocol)
  "Inizializza SESSION con PROTOCOL e restituisci la versione negoziata."
  (prog1 (alist-get 'protocolVersion
                    (alist-get 'result
                               (gdev-mcp-test--reply
                                session (gdev-mcp-test--request
                                         0 "initialize"
                                         `((protocolVersion . ,(or protocol "2025-11-25")))))))
    (should-not (gdev-mcp-test--reply session "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))))

(defun gdev-mcp-test--code (reply)
  "Codice dell'errore JSON-RPC in REPLY."
  (alist-get 'code (alist-get 'error reply)))

(defun gdev-mcp-test--structured (reply)
  "Esito strutturato della chiamata in REPLY."
  (alist-get 'structuredContent (alist-get 'result reply)))

(defun gdev-mcp-test--failure (function &rest arguments)
  "Chiama FUNCTION con ARGUMENTS e restituisci il messaggio dell'errore atteso."
  (condition-case err
      (progn (apply function arguments)
             (ert-fail "Era atteso un errore"))
    (gdev-agent-interface-failure (cadr err))
    (user-error (cadr err))))

(defvar gdev-mcp-test--seen 'non-chiamato
  "Argomento ricevuto da `gdev-mcp-test--command'.")

(defun gdev-mcp-test--command (argument)
  "Registra il prefisso grezzo ARGUMENT."
  (interactive "P")
  (setq gdev-mcp-test--seen argument))

(defmacro gdev-mcp-test--with-runtime (directory &rest body)
  "Esegui BODY con i socket MCP in una cartella temporanea DIRECTORY."
  (declare (indent 1))
  `(progn
     ;; Dentro un'istanza GDev con il socket già aperto la prova non parte.
     (skip-unless (not (process-live-p gdev-mcp-server--process)))
     (let* ((,directory (make-temp-file "gdev-mcp-" t))
            (process-environment (cons (concat "XDG_RUNTIME_DIR=" ,directory) process-environment))
            (hooked (memq #'gdev-mcp-server-stop kill-emacs-hook))
            (gdev-mcp--server-socket nil)
            (gdev-mcp--link nil)
            (gdev-mcp--link-output "")
            (gdev-mcp--live-listed nil))
       (unwind-protect
           (progn ,@body)
         (when (process-live-p gdev-mcp--link)
           (delete-process gdev-mcp--link))
         (gdev-mcp-server-stop)
         (unless hooked
           (remove-hook 'kill-emacs-hook #'gdev-mcp-server-stop))
         (delete-directory ,directory t)))))

;;;; Protocollo nello stesso processo

(ert-deftest gdev-mcp-rpc-errors-leave-the-session-usable ()
  "Ogni errore JSON-RPC ha il suo codice e la sessione continua a rispondere."
  (let ((session (gdev-mcp-session-create
                  :tools (lambda (_session) gdev-mcp-all-tools)
                  :call (lambda (_session name _arguments _line)
                          (if (equal name "gdev_status") '((ok . t)) '((error . "Rifiutato")))))))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session "{non json")) -32700))
    (should (eq (alist-get 'id (gdev-mcp-test--reply session "{non json")) :null))
    ;; Un byte che non è UTF-8 valido rende la riga illeggibile.
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"x\":\"\377\"}"))
               -32700))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session "[1]")) -32600))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session "{\"jsonrpc\":\"2.0\",\"id\":1}")) -32600))
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}"))
               -32600))
    (should (assq 'result (gdev-mcp-test--reply session (gdev-mcp-test--request 1 "ping"))))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session (gdev-mcp-test--request 2 "tools/list")))
               -32002))
    (should (equal (gdev-mcp-test--open session "2099-01-01") (car gdev-mcp-protocols)))
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session (gdev-mcp-test--request
                                               3 "initialize" '((protocolVersion . "2025-11-25")))))
               -32602))
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\",\"params\":[]}"))
               -32602))
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session (gdev-mcp-test--request 5 "tools/list" '((cursor . "x")))))
               -32602))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session (gdev-mcp-test--request 6 "resources/list")))
               -32601))
    (should (= (gdev-mcp-test--code (gdev-mcp-test--reply session (gdev-mcp-test--call 7 "gdev_inesistente")))
               -32602))
    (should (= (gdev-mcp-test--code
                (gdev-mcp-test--reply session (gdev-mcp-test--request
                                               8 "tools/call" '((name . "gdev_status") (arguments . [])))))
               -32602))
    (let ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call "nove" "gdev_status"))))
      (should (equal (alist-get 'id reply) "nove"))
      (should (eq (alist-get 'isError (alist-get 'result reply)) :false))
      (should (equal (gdev-mcp-test--structured reply) '((ok . t)))))))

(ert-deftest gdev-mcp-protocol-versions-shape-tools-and-results ()
  "Annotazioni ed esito strutturato seguono la versione negoziata."
  (dolist (protocol gdev-mcp-protocols)
    (let ((session (gdev-mcp-session-create
                    :tools (lambda (_session) gdev-mcp-all-tools)
                    :call (lambda (_session name _arguments _line)
                            (if (equal name "gdev_status") '((ok . t) (testo . "è")) '((error . "Rifiutato")))))))
      (should (equal (gdev-mcp-test--open session protocol) protocol))
      (let ((tools (alist-get 'tools (alist-get 'result (gdev-mcp-test--reply
                                                         session (gdev-mcp-test--request 1 "tools/list"))))))
        (should (equal (mapcar (lambda (tool) (alist-get 'name tool)) tools) gdev-mcp-all-tools))
        (should (eq (and (assq 'annotations (car tools)) t) (not (equal protocol "2024-11-05")))))
      (let* ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call 2 "gdev_status")))
             (result (alist-get 'result reply))
             (text (alist-get 'text (car (alist-get 'content result)))))
        (should (equal (gdev-mcp-test--read (encode-coding-string text 'utf-8)) '((ok . t) (testo . "è"))))
        (should (eq (and (assq 'structuredContent result) t) (not (string< protocol "2025-06-18")))))
      (should (eq (alist-get 'isError (alist-get 'result (gdev-mcp-test--reply
                                                          session (gdev-mcp-test--call 3 "gdev_buffers"))))
                  t)))))

(ert-deftest gdev-mcp-catalog-matches-the-live-actions ()
  "Ogni strumento dal vivo corrisponde a un'azione con la stessa arità."
  (should (= (length gdev-mcp-all-tools) (1+ (length gdev-mcp--live-tools))))
  (dolist (spec gdev-mcp--live-tools)
    (let* ((properties (nthcdr 3 spec))
           (payload (cl-count-if (lambda (property) (memq (nth 1 property) '(plan offsets text))) properties)))
      (should (eql (cdr (assoc (car spec) gdev-agent-interface--live-actions))
                   (+ (- (length properties) payload) (min payload 1))))))
  (let ((tools (mapcar #'cdr gdev-mcp--tools)))
    (cl-flet ((tool (name) (cl-find name tools :key (lambda (tool) (alist-get 'name tool)) :test #'equal)))
      (should (equal (alist-get 'required (alist-get 'inputSchema (tool "gdev_eval"))) ["form"]))
      (should (equal (alist-get 'required (alist-get 'inputSchema (tool "gdev_command"))) ["command"]))
      (should (equal (alist-get 'required (alist-get 'inputSchema (tool "gdev_open_location"))) ["path"]))
      (should (equal (alist-get 'required (alist-get 'inputSchema (tool "gdev_layout"))) []))
      (should (eq (alist-get 'destructiveHint (alist-get 'annotations (tool "gdev_eval"))) t))
      (should (eq (alist-get 'readOnlyHint (alist-get 'annotations (tool "gdev_buffer_read"))) t))
      (should (eq (alist-get 'readOnlyHint (alist-get 'annotations (tool "gdev_open_location"))) :false))
      (should (eq (alist-get 'destructiveHint (alist-get 'annotations (tool "gdev_open_location"))) :false)))))

(ert-deftest gdev-mcp-validates-arguments-before-the-editor ()
  "Gli argomenti sbagliati sono respinti con il messaggio dello schema."
  (cl-flet ((operands (name &rest arguments)
              (gdev-mcp--operands (gdev-mcp--live-spec name) (apply #'gdev-mcp-test--arguments arguments)))
            (refusal (name &rest arguments)
              (condition-case err
                  (progn (gdev-mcp--operands (gdev-mcp--live-spec name)
                                             (apply #'gdev-mcp-test--arguments arguments))
                         nil)
                (user-error (cadr err)))))
    (should (equal (operands "gdev_eval" "form" "1") '(("1" "10" "false"))))
    (should (equal (operands "gdev_eval" "form" "1" "timeout" 300 "force" t) '(("1" "300" "true"))))
    (should (equal (operands "gdev_command" "command" "save-buffer" "prefix" "C-u C-u")
                   '(("save-buffer" "C-u C-u" "10" "false"))))
    (should (equal (operands "gdev_open_location" "path" "/tmp/x") '(("/tmp/x" "1" "1"))))
    (should (equal (operands "gdev_buffer_read") '(("" "0" "4096"))))
    (let ((schema "Gli argomenti devono corrispondere allo schema dello strumento."))
      (should (equal (refusal "gdev_eval") schema))
      (should (equal (refusal "gdev_eval" "form" "1" "altro" 1) schema)))
    (should (equal (refusal "gdev_eval" "form" "1" "timeout" 0)
                   "timeout deve essere un intero da 1 a 300 secondi."))
    (should (equal (refusal "gdev_eval" "form" "1" "timeout" "5")
                   "timeout deve essere un intero da 1 a 300 secondi."))
    (should (equal (refusal "gdev_keys" "keys" "a" "force" "sì") "force deve essere un valore booleano."))
    (should (equal (refusal "gdev_command" "command" "x" "prefix" "C-x")
                   "prefix deve essere vuoto, un intero, - oppure C-u ripetuto."))
    (should (equal (refusal "gdev_open_location" "path" "relativo")
                   "Indica path come percorso locale assoluto."))
    (should (equal (refusal "gdev_open_location" "path" "/tmp/x" "line" 0) "line deve essere un intero positivo."))
    (should (equal (refusal "gdev_buffer_read" "length" 70000) "length deve essere un intero da 1 a 65536."))
    (should (equal (refusal "gdev_messages" "lines" 0) "lines deve essere un intero da 1 a 1000."))
    ;; Il limite di 1 MiB si misura sul JSON con i separatori di json.dumps.
    (let ((path "/tmp/x") (agent "a") (revision "1-1-1:1"))
      (should (operands "gdev_cursor_write" "path" path "agent" agent "revision" revision
                        "text" (make-string (- gdev-mcp-payload-limit 2) ?a)))
      (should (equal (refusal "gdev_cursor_write" "path" path "agent" agent "revision" revision
                              "text" (make-string (1- gdev-mcp-payload-limit) ?a))
                     "I dati JSON superano 1 MiB."))
      (should (operands "gdev_cursor_write" "path" path "agent" agent "revision" revision
                        "text" (make-string (/ (- gdev-mcp-payload-limit 2) 2) ?è)))
      (should (equal (refusal "gdev_cursor_write" "path" path "agent" agent "revision" revision "text" 3)
                     "Il valore di text deve rispettare lo schema dello strumento.")))
    (should (= (gdev-mcp--separators (json-parse-string "{\"a\":[1,2],\"b\":{\"c\":3}}")) 5))))

;;;; Pilotaggio dell'editor

(ert-deftest gdev-mcp-eval-returns-value-and-messages ()
  "La valutazione restituisce il valore stampato e i messaggi comparsi."
  (let* ((text (format "gdev-mcp-prova-%d" (random 1000000)))
         (outcome (gdev-agent-control-request "eval" (format "(message %S) ; commento\n(+ 1 2)" text)
                                              "5" "false")))
    (should (equal (alist-get 'value outcome) "3"))
    (should (eq (alist-get 'truncated outcome) :false))
    (should (seq-contains-p (alist-get 'messages outcome) text)))
  (let ((outcome (gdev-agent-control-request "eval" "(make-string 70000 ?x)" "5" "false")))
    (should (= (length (alist-get 'value outcome)) gdev-agent-control--value-limit))
    (should (eq (alist-get 'truncated outcome) t)))
  (should (string-prefix-p "La forma non è leggibile"
                           (gdev-mcp-test--failure #'gdev-agent-control-request "eval" "(+ 1" "5" "false")))
  (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request "eval" "(error \"Rotto\")" "5" "false")
                 "Rotto")))

(ert-deftest gdev-mcp-eval-stops-at-timeout-and-refuses-prompts ()
  "Il tempo massimo interrompe l'esecuzione e un prompt diventa un errore."
  (let ((start (float-time)))
    (should (string-prefix-p "Tempo scaduto dopo 1 s"
                             (gdev-mcp-test--failure #'gdev-agent-control-request
                                                     "eval" "(sleep-for 10)" "1" "false")))
    (should (< (- (float-time) start) 5)))
  (let ((prompt "L'esecuzione ha chiesto un input all'utente. Passa i valori nella forma o usa keys"))
    (dolist (form '("(read-string \"Nome: \")" "(read-key)" "(y-or-n-p \"Procedo? \")"))
      (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request "eval" form "5" "false") prompt)))
    (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request "command" "find-file" "" "5" "false")
                   prompt)))
  (should (= (recursion-depth) 0)))

(ert-deftest gdev-mcp-waiting-editor-requires-force ()
  "Con il minibuffer in attesa servono force per agire; le letture restano libere."
  (cl-letf (((symbol-function 'gdev-agent-control--user-waiting-p) (lambda () t)))
    (let ((refusal "L'editor attende una risposta nel minibuffer o in una modifica ricorsiva. Completala oppure riprova con force"))
      (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request "eval" "1" "5" "false") refusal))
      (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request "keys" "a" "5" "false") refusal))
      (should (equal (gdev-mcp-test--failure #'gdev-agent-control-request
                                             "command" "gdev-mcp-test--command" "" "5" "false")
                     refusal)))
    (should (equal (alist-get 'value (gdev-agent-control-request "eval" "1" "5" "true")) "1"))
    (should (vectorp (alist-get 'buffers (gdev-agent-control-request "buffers"))))))

(ert-deftest gdev-mcp-command-receives-prefix-and-keys-reach-the-buffer ()
  "Il comando riceve il prefisso indicato e i tasti agiscono sulla finestra selezionata."
  (dolist (case '(("" . nil) ("-" . -) ("3" . 3) ("-12" . -12) ("C-u" . (4)) ("C-u C-u" . (16))))
    (setq gdev-mcp-test--seen 'non-chiamato)
    (should (equal (alist-get 'command (gdev-agent-control-request
                                        "command" "gdev-mcp-test--command" (car case) "5" "false"))
                   "gdev-mcp-test--command"))
    (should (equal gdev-mcp-test--seen (cdr case))))
  (should (string-prefix-p "Nessun comando interattivo"
                           (gdev-mcp-test--failure #'gdev-agent-control-request
                                                   "command" "gdev-mcp-test--non-esiste" "" "5" "false")))
  (let ((buffer (generate-new-buffer "*gdev-mcp-tasti*"))
        (previous (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (should (equal (alist-get 'keys (gdev-agent-control-request "keys" "a b c" "5" "false")) "a b c"))
          (should (equal (with-current-buffer buffer (buffer-string)) "abc"))
          ;; I tasti rispondono anche ai prompt che aprono.
          (setq gdev-mcp-test--seen 'non-chiamato)
          (gdev-agent-control-request "keys" "M-x gdev-mcp-test--command RET" "5" "false")
          (should (null gdev-mcp-test--seen)))
      (set-window-buffer (selected-window) previous)
      (kill-buffer buffer))))

(ert-deftest gdev-mcp-reads-buffers-layout-and-messages ()
  "Le letture descrivono buffer, finestre e messaggi senza modificarli."
  (let ((buffer (generate-new-buffer "*gdev-mcp-lettura*"))
        (hidden (generate-new-buffer " *gdev-mcp-nascosto*"))
        (previous (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "alfa\nbeta\n")
            (narrow-to-region 6 10))
          (set-window-buffer (selected-window) buffer)
          (set-window-point (selected-window) 7)
          (let ((outcome (gdev-agent-control-request "buffer-read" "" "2" "3")))
            (should (equal (alist-get 'text outcome) "fa\n"))
            (should (= (alist-get 'next_offset outcome) 5))
            (should (equal (alist-get 'name (alist-get 'buffer outcome)) (buffer-name buffer)))
            (should (= (alist-get 'line (alist-get 'buffer outcome)) 2))
            (should (= (alist-get 'column (alist-get 'buffer outcome)) 1)))
          (should (eq (alist-get 'next_offset (gdev-agent-control-request "buffer-read" (buffer-name buffer) "5" "100"))
                      :null))
          (should (string-prefix-p "L'offset"
                                   (gdev-mcp-test--failure #'gdev-agent-control-request
                                                           "buffer-read" (buffer-name buffer) "11" "1")))
          (should (string-prefix-p "Nessun buffer"
                                   (gdev-mcp-test--failure #'gdev-agent-control-request
                                                           "buffer-read" "*gdev-mcp-assente*" "0" "1")))
          (let ((names (mapcar (lambda (entry) (alist-get 'name entry))
                               (alist-get 'buffers (gdev-agent-control-request "buffers")))))
            (should (member (buffer-name buffer) names))
            (should-not (member (buffer-name hidden) names)))
          (let ((windows (append (alist-get 'windows (gdev-agent-control-request "layout")) nil)))
            (should (= (cl-count t windows :key (lambda (window) (alist-get 'selected window))) 1))
            (should (equal (alist-get 'buffer (cl-find t windows :key (lambda (window) (alist-get 'selected window))))
                           (buffer-name buffer))))
          (let ((text (format "gdev-mcp-ultimo-%d" (random 1000000))))
            (message "%s" text)
            (let ((lines (alist-get 'messages (gdev-agent-control-request "messages" "3"))))
              (should (<= (length lines) 3))
              (should (equal (aref lines (1- (length lines))) text)))))
      (set-window-buffer (selected-window) previous)
      (kill-buffer buffer)
      (kill-buffer hidden))))

(ert-deftest gdev-mcp-message-lines-are-short-and-clean ()
  "Le righe di *Messages* riportate sono accorciate e senza byte grezzi."
  (let ((lines (gdev-agent-control--message-lines
                (concat (make-string 5000 ?x) "\nbreve\n" (string #x3fff80) "fine\n") 5)))
    (should (= (length lines) 3))
    (should (= (length (aref lines 0)) (1+ gdev-agent-control--line-limit)))
    (should (string-suffix-p "…" (aref lines 0)))
    (should (equal (aref lines 1) "breve"))
    (should (equal (aref lines 2) "�fine")))
  ;; Il conteggio resta quello richiesto.
  (should (equal (gdev-agent-control--message-lines "a\nb\nc\n" 2) ["b" "c"])))

(ert-deftest gdev-mcp-server-drops-an-endless-line ()
  "Un flusso senza fine riga oltre il limite chiude la connessione."
  (let ((process (make-pipe-process :name "gdev-mcp-prova" :noquery t)))
    (unwind-protect
        (progn
          (gdev-mcp-server--filter process (make-string 1000 ?x))
          (should (process-live-p process))
          (gdev-mcp-server--filter process (make-string gdev-mcp-server-line-limit ?x))
          (should-not (process-live-p process)))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest gdev-mcp-open-location-refuses-prompts ()
  "Un file che apre un prompt nel minibuffer dell'utente dà un errore, non un'attesa."
  (let ((file (make-temp-file "gdev-mcp-prompt" nil ".txt" "uno\n")))
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-open-file)
                   (lambda (_path) (read-string "Variabili locali non sicure: "))))
          (should-error (gdev-agent-control-request "open-location" file "1" "1")
                        :type 'gdev-agent-interface-failure))
      (delete-file file))))

(ert-deftest gdev-mcp-open-location-moves-point ()
  "Aprire una posizione porta il punto alla riga e alla colonna richieste."
  (require 'gdev-commands)
  (let ((file (make-temp-file "gdev-mcp-posizione" nil ".txt" "uno\ndue righe\ntre\n"))
        (previous (window-buffer (selected-window))))
    (unwind-protect
        (let ((location (alist-get 'location (gdev-agent-control-request "open-location" file "2" "5"))))
          (should (equal location '((line . 2) (column . 5))))
          (should (equal (buffer-file-name (window-buffer (selected-window))) file))
          (should (= (window-point (selected-window)) 9))
          ;; Una colonna oltre la riga si ferma alla fine della riga.
          (should (equal (alist-get 'location (gdev-agent-control-request "open-location" file "3" "40"))
                         '((line . 3) (column . 4)))))
      (set-window-buffer (selected-window) previous)
      (when-let* ((buffer (get-file-buffer file)))
        (kill-buffer buffer))
      (delete-file file))))

;;;; Socket privato e controllo di flusso

(ert-deftest gdev-mcp-autostart-follows-the-option ()
  "`gdev-agent-mcp-autostart' decide se il modulo apre il socket all'avvio."
  (let (started)
    (cl-letf (((symbol-function 'gdev-mcp-server-start) (lambda () (setq started t))))
      (let ((gdev-agent-mcp-autostart nil))
        (gdev-mcp-server-autostart))
      (should-not started)
      (let ((gdev-agent-mcp-autostart t))
        (gdev-mcp-server-autostart))
      (should started))))

(ert-deftest gdev-mcp-socket-serves-the-bridge-with-flow-control ()
  "Il ponte trova il socket privato, inoltra le chiamate e conferma i byte."
  (require 'gdev-commands)
  (gdev-mcp-test--with-runtime directory
    (let ((socket (gdev-mcp-server-start))
          (session (gdev-mcp-session-create :tools #'gdev-mcp--bridge-tools
                                            :call #'gdev-mcp--bridge-call)))
      (should (string-prefix-p (expand-file-name "gdev/" directory) socket))
      (should (gdev-mcp-private-socket-p socket))
      (should (equal (file-attribute-modes (file-attributes (file-name-directory socket))) "drwx------"))
      (should (equal (file-attribute-modes (file-attributes socket)) "srw-------"))
      (should (equal (gdev-mcp-server-start) socket))
      (gdev-mcp-test--open session)
      (should (equal (mapcar (lambda (tool) (alist-get 'name tool))
                             (alist-get 'tools (alist-get 'result (gdev-mcp-test--reply
                                                                   session (gdev-mcp-test--request 1 "tools/list")))))
                     gdev-mcp-all-tools))
      (should (process-get gdev-mcp--link 'gdev-mcp-paced))
      (let ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call 2 "gdev_eval" "form" "(emacs-pid)"))))
        (should (equal (alist-get 'id reply) 2))
        (should (equal (alist-get 'value (gdev-mcp-test--structured reply)) (number-to-string (emacs-pid)))))
      ;; Una risposta e una richiesta più grandi del socket passano intere.
      (let ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call 3 "gdev_eval" "form" "(make-string 60000 ?x)"))))
        (should (equal (alist-get 'id reply) 3))
        (should (= (length (alist-get 'value (gdev-mcp-test--structured reply))) 60002)))
      (should (>= (process-get gdev-mcp--link 'gdev-mcp-acks-sent) 24))
      (let ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call
                                                  4 "gdev_eval" "form"
                                                  (format "(length %S)" (make-string 50000 ?a))))))
        (should (equal (alist-get 'value (gdev-mcp-test--structured reply)) "50000")))
      (should (>= (process-get gdev-mcp--link 'gdev-mcp-acks) 12))
      ;; Gli errori di validazione non raggiungono l'editor.
      (should (equal (alist-get 'error (gdev-mcp-test--structured
                                        (gdev-mcp-test--reply session (gdev-mcp-test--call 5 "gdev_eval"))))
                     "Gli argomenti devono corrispondere allo schema dello strumento."))
      (let ((reply (gdev-mcp-test--reply session (gdev-mcp-test--call 6 "gdev_eval" "form" "(read-string \"x\")"))))
        (should (eq (alist-get 'isError (alist-get 'result reply)) t)))
      (should (equal (alist-get 'value (gdev-mcp-test--structured
                                        (gdev-mcp-test--reply session (gdev-mcp-test--call 7 "gdev_eval" "form" "7"))))
                     "7")))))

(ert-deftest gdev-mcp-acks-wait-for-the-end-of-an-outgoing-message ()
  "Una conferma maturata durante un invio non spezza il messaggio in corso."
  (let ((process (make-pipe-process :name "gdev-mcp-prova" :noquery t))
        (message (concat (make-string 40000 ?x) "\n"))
        writes)
    (unwind-protect
        (progn
          (process-put process 'gdev-mcp-paced t)
          ;; Il capo ha già inviato 4090 byte: le conferme del suo ultimo
          ;; invio portano il totale oltre 4096 mentre questo messaggio è a metà.
          (process-put process 'gdev-mcp-received 4090)
          (cl-letf (((symbol-function 'gdev-mcp--write)
                     (lambda (target string)
                       (process-put target 'gdev-mcp-sent
                                    (+ (string-bytes string) (or (process-get target 'gdev-mcp-sent) 0)))
                       (push string writes)))
                    ((symbol-function 'accept-process-output)
                     (lambda (&rest _)
                       (gdev-mcp-note-input process "\n\n\n\n\n\n\n\n"))))
            (gdev-mcp-send process message))
          (let ((sent (apply #'concat (nreverse writes))))
            ;; Il messaggio esce intero, con un solo fine riga, e la conferma dopo.
            (should (string-prefix-p message sent))
            (should (equal (substring sent (length message)) "\n"))
            (should-not (process-get process 'gdev-mcp-sending))))
      (delete-process process))))

(ert-deftest gdev-mcp-server-reopens-a-socket-whose-file-vanished ()
  "Se la pulizia di TMPDIR rimuove il socket, l'editor lo riapre da solo."
  (gdev-mcp-test--with-runtime directory
    (let ((socket (gdev-mcp-server-start)))
      (delete-file socket)
      (should (gdev-mcp-server--socket-lost-p))
      ;; Un nuovo avvio ripara invece di restituire un percorso senza file.
      (should (equal (gdev-mcp-server-start) socket))
      (should (gdev-mcp-private-socket-p socket))
      (should-not (gdev-mcp-server--socket-lost-p))
      ;; Lo stesso fa il controllo periodico.
      (delete-file socket)
      (gdev-mcp-server--repair)
      (should (gdev-mcp-private-socket-p socket))
      (should (timerp gdev-mcp-server--timer))
      (gdev-mcp-server-stop)
      (should-not gdev-mcp-server--timer))))

(ert-deftest gdev-mcp-rejects-a-symlinked-socket-directory ()
  "Un collegamento simbolico al posto della cartella dei socket non è accettato."
  (let* ((root (make-temp-file "gdev-mcp-" t))
         (target (expand-file-name "bersaglio" root))
         (link (file-name-as-directory (expand-file-name "gdev" root))))
    (unwind-protect
        (progn
          (make-directory target)
          (set-file-modes target #o700)
          (make-symbolic-link target (directory-file-name link))
          ;; Con la barra finale lstat segue il collegamento e il tipo non si vede.
          (should-not (gdev-mcp-private-directory-p link))
          (should-error (gdev-mcp-server--prepare-directory link) :type 'user-error))
      (delete-directory root t))))

(ert-deftest gdev-mcp-bridge-reconnects-after-the-editor-restarts ()
  "Dopo il riavvio dell'editor la prima chiamata riapre il collegamento e riesce."
  (require 'gdev-commands)
  (gdev-mcp-test--with-runtime directory
    (gdev-mcp-server-start)
    (let ((session (gdev-mcp-session-create :tools #'gdev-mcp--bridge-tools
                                            :call #'gdev-mcp--bridge-call)))
      (gdev-mcp-test--open session)
      (should (equal (alist-get 'value (gdev-mcp-test--structured
                                        (gdev-mcp-test--reply
                                         session (gdev-mcp-test--call 2 "gdev_eval" "form" "7"))))
                     "7"))
      (let ((old gdev-mcp--link))
        ;; L'editor si riavvia: l'altro capo del vecchio collegamento è chiuso.
        (gdev-mcp-server-stop)
        (gdev-mcp-server-start)
        (should (equal (alist-get 'value (gdev-mcp-test--structured
                                          (gdev-mcp-test--reply
                                           session (gdev-mcp-test--call 3 "gdev_eval" "form" "8"))))
                       "8"))
        (should-not (eq old gdev-mcp--link))))))

(ert-deftest gdev-mcp-bridge-reports-a-silent-editor ()
  "Un editor che non risponde produce l'errore di tempo scaduto e chiude il collegamento."
  (gdev-mcp-test--with-runtime directory
    (let* ((file (expand-file-name "muto" directory))
           (listener (make-network-process
                      :name "gdev-mcp-muto" :server t :family 'local :service file
                      :coding 'binary :noquery t
                      :filter (lambda (connection output)
                                (when (string-search "\"initialize\"" output)
                                  (process-send-string connection "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}\n")))))
           (gdev-mcp-call-timeout 1)
           (session (gdev-mcp-session-create :protocol "2025-11-25" :ready t
                                             :tools #'gdev-mcp--bridge-tools
                                             :call #'gdev-mcp--bridge-call)))
      (unwind-protect
          (progn
            (setq gdev-mcp--link (gdev-mcp--link-open file "2025-11-25"))
            (should-not (process-get gdev-mcp--link 'gdev-mcp-paced))
            (should (equal (gdev-mcp--bridge-call session "gdev_status" (gdev-mcp-test--arguments)
                                                  (gdev-mcp--encode (gdev-mcp-test--call 1 "gdev_status")))
                           `((error . ,gdev-mcp-timeout-message))))
            (should-not (process-live-p gdev-mcp--link)))
        (delete-process listener)))))

;;;; Processi separati

(defun gdev-mcp-test--environment (directory runtime)
  "Ambiente dei processi di prova in DIRECTORY, con i socket in RUNTIME."
  (append (list (concat "XDG_RUNTIME_DIR=" runtime)
                (concat "GDEV_STATE_DIR=" (expand-file-name "stato" directory))
                (concat "GDEV_USER_DIR=" (expand-file-name "utente" directory))
                (concat "EMACS=" (expand-file-name invocation-name invocation-directory)))
          process-environment))

(defun gdev-mcp-test--spawn (name environment command)
  "Avvia COMMAND come NAME con ENVIRONMENT, raccogliendo stdout."
  (let* ((process-environment environment)
         (default-directory gdev-config-directory)
         (errors (generate-new-buffer (format " *%s*" name)))
         (process (make-process
                   :name name :command command :connection-type 'pipe :coding 'binary :noquery t
                   :stderr errors
                   :filter (lambda (process output)
                             (process-put process 'output (concat (process-get process 'output) output))))))
    (process-put process 'errors errors)
    process))

(defun gdev-mcp-test--line (process seconds)
  "Leggi una riga dallo stdout di PROCESS entro SECONDS."
  (let ((deadline (+ (float-time) seconds))
        newline)
    (while (and (not (setq newline (string-search "\n" (or (process-get process 'output) ""))))
                (process-live-p process)
                (< (float-time) deadline))
      (accept-process-output process 0.1))
    (when (or newline (setq newline (string-search "\n" (or (process-get process 'output) ""))))
      (let ((output (process-get process 'output)))
        (process-put process 'output (substring output (1+ newline)))
        (substring output 0 newline)))))

(defun gdev-mcp-test--ask (bridge message)
  "Invia MESSAGE al ponte BRIDGE e leggi la risposta, se MESSAGE ne attende una."
  (process-send-string bridge (concat (gdev-mcp--encode message) "\n"))
  (when (assq 'id message)
    (let ((line (gdev-mcp-test--line bridge 60)))
      (should line)
      (gdev-mcp-test--read line))))

(defun gdev-mcp-test--bridge (environment &rest arguments)
  "Avvia `bin/gdev-mcp' con ENVIRONMENT e ARGUMENTS e inizializza la sessione."
  (let ((bridge (gdev-mcp-test--spawn "gdev-mcp-ponte" environment
                                      (cons (expand-file-name "bin/gdev-mcp" gdev-config-directory)
                                            arguments))))
    (should (equal (alist-get 'protocolVersion
                              (alist-get 'result (gdev-mcp-test--ask
                                                  bridge (gdev-mcp-test--request
                                                          0 "initialize" '((protocolVersion . "2025-06-18"))))))
                   "2025-06-18"))
    (gdev-mcp-test--ask bridge '((jsonrpc . "2.0") (method . "notifications/initialized")))
    bridge))

(defun gdev-mcp-test--tool-names (bridge)
  "Nomi degli strumenti elencati da BRIDGE."
  (mapcar (lambda (tool) (alist-get 'name tool))
          (alist-get 'tools (alist-get 'result (gdev-mcp-test--ask bridge (gdev-mcp-test--request 1 "tools/list"))))))

(defun gdev-mcp-test--close (process)
  "Chiudi PROCESS e il suo buffer di stderr."
  (when (process-live-p process)
    (delete-process process))
  (when-let* ((buffer (process-get process 'errors))
              ((buffer-live-p buffer)))
    (when-let* ((errors (get-buffer-process buffer)))
      (delete-process errors))
    (kill-buffer buffer)))

(ert-deftest gdev-mcp-bridge-drives-a-separate-live-editor ()
  "`bin/gdev-mcp' pilota un altro Emacs dal vivo e, senza editor, offre la scoperta."
  (skip-unless (getenv "GDEV_TEST_SMOKE"))
  (let* ((directory (file-name-as-directory (make-temp-file "gdev-mcp-" t)))
         (runtime (expand-file-name "r" directory))
         (environment (gdev-mcp-test--environment directory runtime))
         (server-socket (expand-file-name "s/prova" directory))
         live bridges)
    (unwind-protect
        (progn
          (make-directory runtime)
          (setq live (gdev-mcp-test--spawn
                      "gdev-mcp-editor" environment
                      (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                            "-l" (expand-file-name "early-init.el" gdev-config-directory)
                            "-L" (expand-file-name "lisp" gdev-config-directory)
                            "--eval"
                            (format "(progn (require 'gdev-commands) (require 'gdev-mcp-server) (require 'server)
                                       (setq server-socket-dir %S server-name \"prova\") (server-start)
                                       (send-string-to-terminal (concat (gdev-mcp-server-start) \"\\n\"))
                                       (while t (accept-process-output nil 0.1)))"
                                    (file-name-directory server-socket)))))
          ;; Un prompt sfuggito leggerebbe da stdin: la fine del flusso lo chiude.
          (process-send-eof live)
          (should (string-prefix-p runtime (or (gdev-mcp-test--line live 60) "")))
          ;; Ricerca automatica: stesso checkout e stessa cartella di stato.
          (let ((bridge (gdev-mcp-test--bridge environment)))
            (push bridge bridges)
            (should (equal (gdev-mcp-test--tool-names bridge) gdev-mcp-all-tools))
            (let ((reply (gdev-mcp-test--ask bridge (gdev-mcp-test--call 2 "gdev_eval" "form" "(emacs-pid)"))))
              (should (equal (alist-get 'value (gdev-mcp-test--structured reply))
                             (number-to-string (process-id live)))))
            (let ((reply (gdev-mcp-test--ask bridge (gdev-mcp-test--call 3 "gdev_eval" "form" "(sleep-for 10)"
                                                                         "timeout" 1))))
              (should (eq (alist-get 'isError (alist-get 'result reply)) t))
              (should (string-prefix-p "Tempo scaduto dopo 1 s"
                                       (alist-get 'error (gdev-mcp-test--structured reply)))))
            (let ((reply (gdev-mcp-test--ask bridge (gdev-mcp-test--call 4 "gdev_eval" "form"
                                                                         "(read-string \"Nome: \")"))))
              (should (string-prefix-p "L'esecuzione ha chiesto un input"
                                       (alist-get 'error (gdev-mcp-test--structured reply)))))
            (let ((reply (gdev-mcp-test--ask bridge (gdev-mcp-test--call 5 "gdev_eval" "form"
                                                                         "(make-string 30000 ?é)"))))
              (should (equal (alist-get 'value (gdev-mcp-test--structured reply))
                             (concat "\"" (make-string 30000 ?é) "\""))))
            (should (process-live-p live))
            (process-send-eof bridge)
            (should-not (gdev-mcp-test--line bridge 30))
            (should (eql (process-exit-status bridge) 0)))
          ;; --socket: il ponte chiede al server Emacs di aprire il socket MCP.
          (let ((bridge (gdev-mcp-test--bridge environment "--socket" server-socket)))
            (push bridge bridges)
            (should (equal (gdev-mcp-test--tool-names bridge) gdev-mcp-all-tools))
            (should (equal (alist-get 'value (gdev-mcp-test--structured
                                              (gdev-mcp-test--ask bridge (gdev-mcp-test--call
                                                                          2 "gdev_eval" "form" "(emacs-pid)"))))
                           (number-to-string (process-id live)))))
          ;; Senza editor raggiungibile resta la scoperta.
          (let ((bridge (gdev-mcp-test--bridge (gdev-mcp-test--environment
                                                directory (expand-file-name "vuota" directory)))))
            (push bridge bridges)
            (should (equal (gdev-mcp-test--tool-names bridge) '("gdev_discover")))
            (should (eq (alist-get 'isError (alist-get 'result (gdev-mcp-test--ask
                                                                bridge (gdev-mcp-test--call
                                                                        2 "gdev_discover" "mode" "use"))))
                        :false))
            (should (= (gdev-mcp-test--code (gdev-mcp-test--ask bridge (gdev-mcp-test--call 3 "gdev_status")))
                       -32602))))
      (mapc #'gdev-mcp-test--close bridges)
      (when live (gdev-mcp-test--close live))
      (delete-directory directory t))))

(provide 'gdev-mcp-test)
;;; gdev-mcp-test.el ends here
