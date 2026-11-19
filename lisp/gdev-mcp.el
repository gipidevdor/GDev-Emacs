;;; gdev-mcp.el --- Server MCP di GDev per agenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; `bin/gdev-mcp' carica questo file in un Emacs batch che resta attivo
;; per tutta la sessione del client.  Il trasporto è MCP su stdio:
;; JSON-RPC 2.0, un messaggio per riga, UTF-8 in entrambe le direzioni.
;; Su stdout escono solo le risposte; la diagnostica va su stderr.
;;
;; Modalità dal vivo.  Il ponte si collega al socket Unix privato che
;; `gdev-mcp-server' apre nell'istanza GDev e vi inoltra le chiamate agli
;; strumenti dell'editor.  Lì la sessione JSON-RPC esegue ogni strumento
;; come chiamata di funzione, senza avviare altri processi.  Con --socket
;; indichi il socket del server Emacs copiato con `gdev-agent-copy-socket':
;; il ponte vi chiede una volta di aprire il socket MCP.  Senza --socket
;; cerca l'istanza dello stesso checkout e della stessa cartella di stato.
;;
;; Modalità senza editor.  Il ponte serve da sé `gdev_discover' leggendo
;; i sorgenti del checkout, nello stesso processo.
;;
;; `gdev-mcp-handle-line' gestisce una riga per una sessione: la usano sia
;; il ponte sia le connessioni aperte nell'editor.

;;; Code:

(require 'cl-lib)
(require 'gdev-agent-interface)
(require 'gdev-assurance-api)
(require 'rx)
(require 'subr-x)

(defvar gdev-config-directory)
(defvar gdev-state-directory)
(declare-function server-quote-arg "server" (arg))
(declare-function server-unquote-arg "server" (arg))
(declare-function gdev-assurance-request-parse "gdev-assurance-requests" (proposal))
(declare-function gdev-assurance-request--arguments "gdev-assurance-requests" (operation arguments))

(defconst gdev-mcp-protocols '("2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05")
  "Versioni del protocollo MCP accettate, dalla più recente.")

(defconst gdev-mcp-payload-limit (* 1024 1024)
  "Dimensione massima, in byte, dei dati JSON passati a un'azione.")

(defconst gdev-mcp-call-timeout 30
  "Secondi di attesa massima per uno strumento dell'editor dal vivo.")

(defconst gdev-mcp-timeout-message
  "Tempo scaduto. Controlla lo stato di GDev prima di riprovare."
  "Errore restituito quando l'editor non risponde in tempo.")

(defconst gdev-mcp--raw-byte (rx (any (#x3fff80 . #x3fffff)))
  "Caratteri che rappresentano byte non validi in UTF-8.")

;;;; Catalogo degli strumenti

(defconst gdev-mcp--path-schema '((type . "string") (pattern . "^/")))
(defconst gdev-mcp--plan-path-schema '((type . "string") (pattern . "^/.*\\.lavorazione$")))
(defconst gdev-mcp--agent-schema
  '((type . "string") (pattern . "^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$")))
(defconst gdev-mcp--cursor-revision-schema
  '((type . "string") (pattern . "^[0-9]+-[0-9]+-[0-9]+:[0-9]+$")))
(defconst gdev-mcp--plan-revision-schema '((type . "string") (pattern . "^[0-9a-f]{64}$")))
(defconst gdev-mcp--timeout-schema
  '((type . "integer") (minimum . 1) (maximum . 300) (default . 10)
    (description . "Secondi di attesa massima prima di interrompere l'esecuzione.")))
(defconst gdev-mcp--force-schema
  '((type . "boolean") (default . :false)
    (description . "Esegui anche se il minibuffer o una modifica ricorsiva attendono l'utente.")))

(defconst gdev-mcp--plan-schema
  '((type . "object")
    (properties
     . ((versione . ((type . "integer") (enum . [1])))
        (passi . ((type . "array")
                  (maxItems . 128)
                  (items . ((type . "object")
                            (properties . ((azione . ((type . "string")))
                                           (argomenti . ((type . "object")))))
                            (required . ["azione" "argomenti"])
                            (additionalProperties . :false)))))))
    (required . ["versione" "passi"])
    (additionalProperties . :false)))

(defconst gdev-mcp--discover-tool
  '((name . "gdev_discover")
    (description . "Leggi il catalogo GDev dal checkout corrente.")
    (inputSchema
     . ((type . "object")
        (properties
         . ((mode . ((type . "string") (enum . ["develop" "use"])))
            (prefix . ((type . "string")
                       (minLength . 1)
                       (pattern . "^(?!--)")
                       (description . "Prefisso dei simboli Lisp, disponibile con develop.")))))
        (required . ["mode"])
        (additionalProperties . :false)))
    (annotations . ((readOnlyHint . t) (openWorldHint . :false))))
  "Descrizione MCP della scoperta, disponibile anche senza editor.")

(defconst gdev-mcp--live-tools
  `(("status" read "Leggi lo stato della finestra e dell'editor di GDev.")
    ("commands" read "Scopri i comandi disponibili nel contesto corrente di GDev.")
    ("shortcuts" read
     "Leggi i tasti effettivi di un comando o il comando associato a un tasto nella vista corrente."
     ("query" query ((type . "string") (minLength . 1) (maxLength . 128)
                     (description . "Nome Lisp del comando o tasto in notazione Emacs, per esempio s-z."))))
    ("open-file" write "Apri un file esistente nella sessione GDev selezionata."
     ("path" file ,gdev-mcp--path-schema))
    ("open-folder" write "Apri una cartella esistente nello spazio di lavoro GDev."
     ("path" folder ,gdev-mcp--path-schema))
    ("lavorazione-catalogo" read "Leggi azioni e tipi disponibili nella sessione GDev.")
    ("lavorazione-apri" write
     "Apri o crea un file .lavorazione in Composizione e leggi piano e revisione."
     ("path" plan-path ,gdev-mcp--plan-path-schema))
    ("lavorazione-leggi" read "Leggi piano, revisione e validazione di una lavorazione aperta."
     ("path" plan-path ,gdev-mcp--plan-path-schema))
    ("lavorazione-componi" destructive
     "Valida e applica un piano completo alla revisione letta, aggiornando Composizione."
     ("path" plan-path ,gdev-mcp--plan-path-schema)
     ("revision" plan-revision ,gdev-mcp--plan-revision-schema)
     ("plan" plan ,gdev-mcp--plan-schema))
    ("lavorazione-salva" destructive "Salva su disco una lavorazione aperta alla revisione letta."
     ("path" plan-path ,gdev-mcp--plan-path-schema)
     ("revision" plan-revision ,gdev-mcp--plan-revision-schema))
    ("cursor-state" read "Leggi la bozza aperta, la sua revisione e i cursori degli agenti."
     ("path" path ,gdev-mcp--path-schema)
     ("offset" offset ((type . "integer") (minimum . 0) (default . 0)
                       (description . "Offset in caratteri da cui leggere fino a 4096 caratteri."))))
    ("cursor-place" write
     "Posiziona uno o più cursori appartenenti allo stesso agente, usando la revisione letta."
     ("path" path ,gdev-mcp--path-schema)
     ("agent" agent ,gdev-mcp--agent-schema)
     ("revision" cursor-revision ,gdev-mcp--cursor-revision-schema)
     ("offsets" offsets ((type . "array") (minItems . 1) (maxItems . 32) (uniqueItems . t)
                         (items . ((type . "integer") (minimum . 0))))))
    ("cursor-write" destructive
     "Inserisci lo stesso testo a tutti i cursori dell'agente, in un solo gruppo di annullamento."
     ("path" path ,gdev-mcp--path-schema)
     ("agent" agent ,gdev-mcp--agent-schema)
     ("revision" cursor-revision ,gdev-mcp--cursor-revision-schema)
     ("text" text ((type . "string") (minLength . 1))))
    ("cursor-clear" write "Rimuovi i cursori dell'agente dal documento."
     ("path" path ,gdev-mcp--path-schema)
     ("agent" agent ,gdev-mcp--agent-schema))
    ("eval" destructive
     "Valuta Emacs Lisp nell'editor GDev e leggi il valore stampato e i messaggi."
     ("form" form ((type . "string") (minLength . 1) (maxLength . 65536)
                   (description . "Una o più forme; il risultato è il valore dell'ultima.")))
     ("timeout" timeout ,gdev-mcp--timeout-schema)
     ("force" force ,gdev-mcp--force-schema))
    ("command" destructive
     "Esegui un comando interattivo nella finestra selezionata, come da tastiera."
     ("command" command ((type . "string") (minLength . 1) (maxLength . 256)
                         (description . "Nome Lisp del comando, per esempio gdev-open-file.")))
     ("prefix" prefix ((type . "string") (pattern . "^(|-|-?[0-9]{1,9}|C-u( C-u){0,3})$")
                       (default . "")
                       (description . "Argomento prefisso: vuoto, un intero, - oppure C-u ripetuto.")))
     ("timeout" timeout ,gdev-mcp--timeout-schema)
     ("force" force ,gdev-mcp--force-schema))
    ("keys" destructive
     "Premi una sequenza di tasti nella finestra selezionata, comprese le risposte ai prompt."
     ("keys" keys ((type . "string") (minLength . 1) (maxLength . 1024)
                   (description . "Tasti in notazione Emacs, per esempio C-x b *scratch* RET.")))
     ("timeout" timeout ,gdev-mcp--timeout-schema)
     ("force" force ,gdev-mcp--force-schema))
    ("open-location" write "Apri un file esistente e porta il cursore alla riga e alla colonna indicate."
     ("path" path ,gdev-mcp--path-schema)
     ("line" line ((type . "integer") (minimum . 1) (default . 1)
                   (description . "Riga, a partire da 1.")))
     ("column" column ((type . "integer") (minimum . 1) (default . 1)
                       (description . "Colonna in caratteri, a partire da 1."))))
    ("buffer-read" read
     "Leggi testo, modalità, file, modifiche, punto e regione di un buffer dell'editor."
     ("buffer" buffer ((type . "string") (maxLength . 256) (default . "")
                       (description . "Nome del buffer; vuoto per quello della finestra selezionata.")))
     ("offset" offset ((type . "integer") (minimum . 0) (default . 0)
                       (description . "Offset in caratteri da cui leggere.")))
     ("length" length ((type . "integer") (minimum . 1) (maximum . 65536) (default . 4096)
                       (description . "Numero massimo di caratteri da leggere."))))
    ("buffers" read "Elenca i buffer aperti con file, modalità e modifiche.")
    ("layout" read "Leggi finestre, ruoli nel Workbench, spazi di lavoro e stato dello spazio corrente.")
    ("messages" read "Leggi le ultime righe di *Messages*."
     ("lines" lines ((type . "integer") (minimum . 1) (maximum . 1000) (default . 50)
                     (description . "Numero di righe da leggere."))))
    ("assurance-request" write
     "Registra una proposta senza eseguirla. Una persona legge dati e digest e conferma dalla CLI o dal Workbench; nessuna approvazione è offerta all'agente."
     ("transaction" assurance-transaction ((type . "string") (pattern . "^GT-[0-9]{4,18}$") (maxLength . 64)))
     ("proposal" assurance-proposal ((type . "string") (maxLength . 32768)
                                    (description . "JSON con operation e arguments: advance, evidence, assess, artifact, link o standard-proof.")))
     ("root" folder ((type . "string") (pattern . "^/") (maxLength . 4096))))
    ("assurance" read
     "Leggi, senza modificarlo, l'archivio di assicurazione ingegneristica del progetto: stato, transazioni, una transazione con eventi e prove, verifica dell'integrità, valutazione dei controlli di una transazione."
     ("command" assurance-command
      ((type . "string") (enum . ,(vconcat (gdev-assurance-read-commands)))
       (description . "Comando di lettura del catalogo di assicurazione.")))
     ("argument" assurance-argument
      ((type . "string") (maxLength . 4096) (default . "")
       (description . "Stato con list; ID con show, work e assess; standard con taxonomy o suggest, con cursore ID@200 se next_argument è presente. Vuoto usa la transazione attiva quando previsto.")))
     ("root" assurance-root
      ((type . "string") (maxLength . 4096) (default . "")
       (description . "Cartella assoluta del progetto; vuota per cercare l'archivio dalla finestra selezionata.")))))
  "Strumenti dell'editor dal vivo: (AZIONE EFFETTO DESCRIZIONE PROPRIETÀ...).
Ogni proprietà è (NOME CONTROLLO SCHEMA); l'ordine delle proprietà è quello
degli argomenti di `gdev agent live'.")

(defun gdev-mcp--tool-name (action)
  "Restituisci il nome MCP dell'azione dal vivo ACTION."
  (concat "gdev_" (string-replace "-" "_" action)))

(defun gdev-mcp--tool-json (spec)
  "Costruisci la descrizione MCP dello strumento SPEC."
  (pcase-let ((`(,action ,effect ,description . ,properties) spec))
    `((name . ,(gdev-mcp--tool-name action))
      (description . ,description)
      (inputSchema
       . ((type . "object")
          (properties . ,(mapcar (lambda (property) (cons (intern (car property)) (nth 2 property)))
                                 properties))
          (required . ,(vconcat (cl-loop for (field _ schema) in properties
                                         unless (assq 'default schema) collect field)))
          (additionalProperties . :false)))
      (annotations . ((readOnlyHint . ,(if (eq effect 'read) t :false))
                      (destructiveHint . ,(if (eq effect 'destructive) t :false))
                      (openWorldHint . :false))))))

(defconst gdev-mcp--tools
  (cons (cons "gdev_discover" gdev-mcp--discover-tool)
        (mapcar (lambda (spec) (cons (gdev-mcp--tool-name (car spec)) (gdev-mcp--tool-json spec)))
                gdev-mcp--live-tools))
  "Descrizioni MCP per nome, nell'ordine di `tools/list'.")

(defconst gdev-mcp-all-tools (mapcar #'car gdev-mcp--tools)
  "Nomi di tutti gli strumenti, quando l'editor dal vivo è raggiungibile.")

(defun gdev-mcp--live-spec (name)
  "Restituisci la definizione dello strumento dal vivo chiamato NAME."
  (cl-find name gdev-mcp--live-tools
           :key (lambda (spec) (gdev-mcp--tool-name (car spec))) :test #'equal))

;;;; Validazione degli argomenti

(defun gdev-mcp--invalid (message)
  "Rifiuta gli argomenti con MESSAGE."
  (user-error "%s" message))

(defun gdev-mcp--match-p (regexp value)
  "Indica se la stringa VALUE corrisponde per intero a REGEXP."
  (and (stringp value)
       (let ((case-fold-search nil))
         (string-match-p regexp value))))

(defun gdev-mcp--local-path-p (value)
  "Controlla la sintassi del percorso VALUE senza risolvere collegamenti."
  (and (stringp value) (string-prefix-p "/" value) (not (string-search "\0" value))))

(defun gdev-mcp--integer-p (value minimum &optional maximum)
  "Indica se VALUE è un intero tra MINIMUM e MAXIMUM."
  (and (integerp value) (<= minimum value) (or (null maximum) (<= value maximum))))

(defun gdev-mcp--operand (check value)
  "Valida VALUE secondo CHECK e restituisci l'argomento testuale dell'azione."
  (pcase check
    ('query
     (unless (and (stringp value) (<= 1 (length value) 128) (not (string-search "\0" value)))
       (gdev-mcp--invalid "Indica il nome del comando o un tasto in notazione Emacs."))
     value)
    ((or 'path 'plan-path 'file 'folder)
     (unless (gdev-mcp--local-path-p value)
       (gdev-mcp--invalid "Indica path come percorso locale assoluto."))
     (when (and (eq check 'plan-path) (not (string-suffix-p ".lavorazione" value)))
       (gdev-mcp--invalid "Indica il percorso di un file .lavorazione."))
     (let ((file-name-handler-alist nil))
       (when (or (and (eq check 'file) (not (file-regular-p value)))
                 (and (eq check 'folder) (not (file-directory-p value))))
         (gdev-mcp--invalid "Il file o la cartella indicata non esiste.")))
     value)
    ('offset
     (unless (gdev-mcp--integer-p value 0)
       (gdev-mcp--invalid "offset deve essere un intero non negativo."))
     (number-to-string value))
    ('agent
     (unless (gdev-mcp--match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]\\{0,39\\}\\'" value)
       (gdev-mcp--invalid "Indica un identificatore agente di 1–40 caratteri."))
     value)
    ((or 'cursor-revision 'plan-revision)
     (unless (gdev-mcp--match-p (if (eq check 'plan-revision)
                                    "\\`[0-9a-f]\\{64\\}\\'"
                                  "\\`[0-9]+-[0-9]+-[0-9]+:[0-9]+\\'")
                                value)
       (gdev-mcp--invalid "Indica la revisione restituita dalla lettura."))
     value)
    ('form
     (unless (and (stringp value) (<= 1 (length value) 65536))
       (gdev-mcp--invalid "Indica in form da 1 a 65536 caratteri di Emacs Lisp."))
     value)
    ('timeout
     (unless (gdev-mcp--integer-p value 1 300)
       (gdev-mcp--invalid "timeout deve essere un intero da 1 a 300 secondi."))
     (number-to-string value))
    ('force
     (unless (memq value '(t :false))
       (gdev-mcp--invalid "force deve essere un valore booleano."))
     (if (eq value t) "true" "false"))
    ('command
     (unless (and (stringp value) (<= 1 (length value) 256))
       (gdev-mcp--invalid "Indica il nome Lisp di un comando interattivo."))
     value)
    ('prefix
     (unless (gdev-mcp--match-p "\\`\\(-\\|-?[0-9]\\{1,9\\}\\|C-u\\( C-u\\)\\{0,3\\}\\)?\\'" value)
       (gdev-mcp--invalid "prefix deve essere vuoto, un intero, - oppure C-u ripetuto."))
     value)
    ('keys
     (unless (and (stringp value) (<= 1 (length value) 1024))
       (gdev-mcp--invalid "Indica i tasti in notazione Emacs, per esempio C-x b."))
     value)
    ((or 'line 'column)
     (unless (gdev-mcp--integer-p value 1)
       (gdev-mcp--invalid (format "%s deve essere un intero positivo." check)))
     (number-to-string value))
    ('buffer
     (unless (and (stringp value) (<= (length value) 256))
       (gdev-mcp--invalid "buffer deve essere il nome di un buffer o una stringa vuota."))
     value)
    ('length
     (unless (gdev-mcp--integer-p value 1 65536)
       (gdev-mcp--invalid "length deve essere un intero da 1 a 65536."))
     (number-to-string value))
    ('lines
     (unless (gdev-mcp--integer-p value 1 1000)
       (gdev-mcp--invalid "lines deve essere un intero da 1 a 1000."))
     (number-to-string value))
    ('assurance-command
     (unless (gdev-assurance-read-command-p value)
       (gdev-mcp--invalid (format "command deve essere uno fra %s."
                                 (mapconcat #'identity (gdev-assurance-read-commands) ", "))))
     value)
    ('assurance-transaction
     (unless (gdev-mcp--match-p "\\`GT-[0-9]\\{4,18\\}\\'" value)
       (gdev-mcp--invalid "Indica la transazione GT-0001 o il suo identificativo effettivo."))
     value)
    ('assurance-proposal
     (unless (and (stringp value) (<= (string-bytes value) 32768))
       (gdev-mcp--invalid "Proposta troppo grande o non testuale."))
     (condition-case nil
         (progn
          (require 'gdev-assurance-requests)
          (let ((data (gdev-assurance-request-parse value)))
           (gdev-assurance-request--arguments (alist-get 'operation data) (alist-get 'arguments data))))
       (error (gdev-mcp--invalid "Proposta di assicurazione non valida.")))
     value)
    ('assurance-argument
     (unless (and (stringp value) (<= (length value) 4096) (not (string-search "\0" value)))
       (gdev-mcp--invalid "argument deve essere un testo di al più 4096 caratteri."))
     value)
    ('assurance-root
     (unless (or (equal value "")
                 (and (gdev-mcp--local-path-p value) (<= (length value) 4096)
                      (let ((file-name-handler-alist nil)) (file-directory-p value))))
       (gdev-mcp--invalid "root deve essere vuoto o una cartella locale assoluta esistente."))
     value)
    (_ (error "Controllo sconosciuto: %S" check))))

(defun gdev-mcp--separators (value)
  "Conta i separatori di VALUE che json.dumps scrive con uno spazio in più."
  (cond ((hash-table-p value)
         (let ((count (max 0 (1- (* 2 (hash-table-count value))))))
           (maphash (lambda (_key item) (setq count (+ count (gdev-mcp--separators item)))) value)
           count))
        ((vectorp value)
         (+ (max 0 (1- (length value)))
            (cl-loop for item across value sum (gdev-mcp--separators item))))
        (t 0)))

(defun gdev-mcp--payload (check value field)
  "Valida il dato JSON VALUE di FIELD secondo CHECK e restituiscine i byte."
  (unless (pcase check
            ('plan (hash-table-p value))
            ('offsets (vectorp value))
            ('text (stringp value)))
    (gdev-mcp--invalid (format "Il valore di %s deve rispettare lo schema dello strumento." field)))
  (let ((bytes (if (stringp value)
                   ;; Un testo isolato passa da un vettore: vale anche dove
                   ;; json-serialize accetta solo oggetti e vettori.
                   (substring (gdev-mcp--encode (vector value)) 1 -1)
                 (gdev-mcp--encode value))))
    ;; Il limite resta quello misurato sul formato di json.dumps.
    (when (> (+ (length bytes) (gdev-mcp--separators value)) gdev-mcp-payload-limit)
      (gdev-mcp--invalid "I dati JSON superano 1 MiB."))
    bytes))

(defun gdev-mcp--operands (spec arguments)
  "Valida ARGUMENTS per SPEC e restituisci (ARGOMENTI . DATI-JSON)."
  (let ((properties (nthcdr 3 spec))
        operands payload)
    (when (or (cl-some (lambda (key) (not (assoc key properties))) (hash-table-keys arguments))
              (cl-some (pcase-lambda (`(,field ,_ ,schema))
                         (and (not (assq 'default schema))
                              (eq (gethash field arguments 'gdev-mcp--absent) 'gdev-mcp--absent)))
                       properties))
      (gdev-mcp--invalid "Gli argomenti devono corrispondere allo schema dello strumento."))
    (pcase-dolist (`(,field ,check ,schema) properties)
      (let ((value (gethash field arguments (alist-get 'default schema))))
        (if (memq check '(plan offsets text))
            (setq payload (gdev-mcp--payload check value field))
          (push (gdev-mcp--operand check value) operands))))
    (cons (nreverse operands) payload)))

;;;; Esecuzione nello stesso processo

(defun gdev-mcp--discover (arguments)
  "Restituisci l'inventario di `gdev agent' per ARGUMENTS."
  (let ((mode (gethash "mode" arguments))
        (prefix (gethash "prefix" arguments 'gdev-mcp--absent)))
    (unless (and (member mode '("develop" "use"))
                 (cl-every (lambda (key) (member key '("mode" "prefix"))) (hash-table-keys arguments)))
      (gdev-mcp--invalid "Specifica mode (develop o use) e, se serve, prefix."))
    (unless (or (eq prefix 'gdev-mcp--absent)
                (and (equal mode "develop") (stringp prefix) (not (string-empty-p prefix))
                     (not (string-prefix-p "--" prefix)) (not (string-search "\0" prefix))))
      (gdev-mcp--invalid "prefix deve essere una stringa non vuota e richiede mode develop."))
    (condition-case err
        (gdev-agent-interface-inventory mode (unless (eq prefix 'gdev-mcp--absent) prefix))
      (error (gdev-agent-interface--error (error-message-string err))))))

(defun gdev-mcp--decode-payload (json)
  "Leggi l'oggetto JSON restituito da un'azione."
  (json-parse-string (decode-coding-string json 'utf-8-unix) :object-type 'alist :array-type 'array
                     :null-object :null :false-object :false))

(defun gdev-mcp-call-in-process (_session name arguments &optional _line)
  "Esegui lo strumento NAME con ARGUMENTS in questo Emacs.
Le azioni dal vivo passano da `gdev-agent-interface-request', come dalla CLI."
  (if (equal name "gdev_discover")
      (gdev-mcp--discover arguments)
    (pcase-let* ((spec (gdev-mcp--live-spec name))
                 (`(,operands . ,payload) (gdev-mcp--operands spec arguments)))
      (if (not payload)
          (gdev-mcp--decode-payload
           (apply #'gdev-agent-interface-request gdev-agent-interface--root (car spec) operands))
        (let* ((directory (make-temp-file "gdev-piano-" t))
               (file (expand-file-name "piano.json" directory)))
          (unwind-protect
              (progn
                (let ((coding-system-for-write 'binary))
                  (write-region payload nil file nil 0))
                (gdev-mcp--decode-payload
                 (apply #'gdev-agent-interface-request gdev-agent-interface--root (car spec)
                        (append operands (list file)))))
            (delete-directory directory t)))))))

;;;; Sessioni JSON-RPC

(cl-defstruct (gdev-mcp-session (:constructor gdev-mcp-session-create) (:copier nil))
  "Stato di una sessione MCP."
  (protocol nil :documentation "Versione negoziata, o nil prima di initialize.")
  (ready nil :documentation "Non nil dopo notifications/initialized.")
  (tools nil :documentation "Funzione della sessione che restituisce i nomi disponibili.")
  (call nil :documentation "Funzione (SESSIONE NOME ARGOMENTI RIGA) che esegue uno strumento.
Restituisce l'esito come dati JSON oppure una risposta JSON-RPC già pronta."))

(defun gdev-mcp--encode (object)
  "Serializza OBJECT in JSON compatto, come byte UTF-8."
  (let ((json (json-serialize object)))
    (if (multibyte-string-p json) (encode-coding-string json 'utf-8-unix) json)))

(defun gdev-mcp--bytes (line)
  "Restituisci i byte di LINE, letta da stdin o da un socket."
  (if (multibyte-string-p line) (encode-coding-string line 'utf-8-unix) line))

(defun gdev-mcp--parse (line)
  "Leggi la richiesta JSON in LINE, o restituisci il simbolo `invalid'."
  (let ((text (decode-coding-string (gdev-mcp--bytes line) 'utf-8-unix t)))
    (if (string-match-p gdev-mcp--raw-byte text)
        'invalid
      (condition-case nil
          (json-parse-string text :object-type 'hash-table :array-type 'array
                             :null-object :null :false-object :false)
        (error 'invalid)))))

(defun gdev-mcp--rpc-error (id code message)
  "Costruisci l'errore JSON-RPC CODE con MESSAGE per ID."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun gdev-mcp--rpc-result (id result)
  "Costruisci la risposta JSON-RPC RESULT per ID."
  `((jsonrpc . "2.0") (id . ,id) (result . ,result)))

(defun gdev-mcp--tool-result (payload protocol)
  "Presenta l'esito PAYLOAD di uno strumento secondo PROTOCOL."
  `((content . [((type . "text")
                 (text . ,(decode-coding-string (gdev-mcp--encode payload) 'utf-8-unix)))])
    (isError . ,(if (assq 'error payload) t :false))
    ,@(unless (string< protocol "2025-06-18")
        `((structuredContent . ,payload)))))

(defun gdev-mcp--tools-list (session)
  "Descrivi gli strumenti disponibili in SESSION."
  (let ((legacy (equal (gdev-mcp-session-protocol session) "2024-11-05")))
    (vconcat (mapcar (lambda (name)
                       (let ((tool (cdr (assoc name gdev-mcp--tools))))
                         (if legacy (seq-remove (lambda (entry) (eq (car entry) 'annotations)) tool) tool)))
                     (funcall (gdev-mcp-session-tools session) session)))))

(defun gdev-mcp--call (session id params line)
  "Esegui la chiamata tools/call con ID e PARAMS ricevuta in LINE."
  (let ((name (gethash "name" params))
        (arguments (gethash "arguments" params 'gdev-mcp--absent)))
    (when (eq arguments 'gdev-mcp--absent)
      (setq arguments (make-hash-table :test #'equal)))
    (cond ((not (and (stringp name) (hash-table-p arguments)))
           (gdev-mcp--rpc-error id -32602 "Specifica name e un oggetto arguments."))
          ((not (member name (funcall (gdev-mcp-session-tools session) session)))
           (gdev-mcp--rpc-error id -32602 "Strumento MCP non disponibile."))
          (t
           (let ((outcome (condition-case err
                              (funcall (gdev-mcp-session-call session) session name arguments line)
                            (error `((error . ,(error-message-string err)))))))
             (if (stringp outcome)
                 outcome
               (gdev-mcp--rpc-result
                id (gdev-mcp--tool-result outcome (gdev-mcp-session-protocol session)))))))))

(defun gdev-mcp--method (session id method params line)
  "Rispondi alla richiesta METHOD con ID e PARAMS di SESSION."
  (pcase method
    ("initialize"
     (let ((version (gethash "protocolVersion" params)))
       (if (or (gdev-mcp-session-protocol session) (not (stringp version)))
           (gdev-mcp--rpc-error id -32602 "Inizializzazione MCP non valida.")
         (let ((protocol (if (member version gdev-mcp-protocols) version (car gdev-mcp-protocols))))
           (setf (gdev-mcp-session-protocol session) protocol)
           (gdev-mcp--rpc-result
            id `((protocolVersion . ,protocol)
                 (capabilities . ((tools . ,(make-hash-table))))
                 (serverInfo . ((name . "gdev-mcp") (version . "1.0.0")))))))))
    ("ping" (gdev-mcp--rpc-result id (make-hash-table)))
    ((guard (not (gdev-mcp-session-ready session)))
     (gdev-mcp--rpc-error id -32002 "Inizializza la sessione MCP."))
    ("tools/list"
     (if (not (eq (gethash "cursor" params 'gdev-mcp--absent) 'gdev-mcp--absent))
         (gdev-mcp--rpc-error id -32602 "Cursore di paginazione sconosciuto.")
       (gdev-mcp--rpc-result id `((tools . ,(gdev-mcp--tools-list session))))))
    ("tools/call" (gdev-mcp--call session id params line))
    (_ (gdev-mcp--rpc-error id -32601 "Metodo MCP non disponibile."))))

(defun gdev-mcp--handle (session request line)
  "Rispondi a REQUEST, ricevuta in LINE, nel contesto di SESSION."
  (if (not (and (hash-table-p request) (equal (gethash "jsonrpc" request) "2.0")))
      (gdev-mcp--rpc-error :null -32600 "Richiesta JSON-RPC non valida.")
    (let ((method (gethash "method" request))
          (id (gethash "id" request 'gdev-mcp--absent)))
      (cond
       ((not (stringp method))
        (gdev-mcp--rpc-error :null -32600 "Metodo JSON-RPC mancante."))
       ((eq id 'gdev-mcp--absent)
        (when (and (equal method "notifications/initialized") (gdev-mcp-session-protocol session))
          (setf (gdev-mcp-session-ready session) t))
        nil)
       ((not (or (integerp id) (stringp id)))
        (gdev-mcp--rpc-error :null -32600 "Identificatore JSON-RPC non valido."))
       (t
        (let ((params (gethash "params" request 'gdev-mcp--absent)))
          (when (eq params 'gdev-mcp--absent)
            (setq params (make-hash-table :test #'equal)))
          (if (hash-table-p params)
              (gdev-mcp--method session id method params line)
            (gdev-mcp--rpc-error id -32602 "params deve essere un oggetto."))))))))

(defun gdev-mcp-request-id (request)
  "Restituisci l'identificatore valido di REQUEST, o :null."
  (let ((id (and (hash-table-p request) (gethash "id" request))))
    (if (or (integerp id) (stringp id)) id :null)))

(defun gdev-mcp-handle-line (session line)
  "Gestisci la riga JSON-RPC LINE in SESSION.
Restituisci la risposta come byte UTF-8 senza a capo, o nil per una notifica."
  (let ((request (gdev-mcp--parse line)))
    (if (eq request 'invalid)
        (gdev-mcp--encode (gdev-mcp--rpc-error :null -32700 "JSON non valido."))
      (let ((response
             (condition-case err
                 (gdev-mcp--handle session request line)
               (error (gdev-mcp--rpc-error (gdev-mcp-request-id request) -32603
                                           (concat "Errore interno di GDev: " (error-message-string err)))))))
        (if (stringp response) response (and response (gdev-mcp--encode response)))))))

;;;; Socket privato dell'editor dal vivo

(defun gdev-mcp-runtime-directory ()
  "Cartella dei socket MCP: privata dell'utente, come quella di `server-start'."
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (file-name-as-directory
     (if (and runtime (file-name-absolute-p runtime))
         (expand-file-name "gdev" runtime)
       (expand-file-name (format "gdev%d" (user-uid)) (or (getenv "TMPDIR") "/tmp"))))))

(defun gdev-mcp-socket-file (&optional root state)
  "Socket MCP dell'istanza con checkout ROOT e cartella di stato STATE."
  (expand-file-name
   (concat "mcp-" (substring (secure-hash 'sha256 (concat (or root gdev-config-directory) "\0"
                                                          (or state gdev-state-directory)))
                             0 16))
   (gdev-mcp-runtime-directory)))

(defun gdev-mcp-private-directory-p (directory)
  "Indica se DIRECTORY appartiene all'utente ed è accessibile solo a lui."
  ;; Con la barra finale lstat segue un collegamento simbolico e il tipo
  ;; non lo rivelerebbe: si legge il nome della cartella senza barra.
  (let ((attributes (let ((file-name-handler-alist nil))
                      (file-attributes (directory-file-name directory) 'integer))))
    (and (eq (file-attribute-type attributes) t)
         (eql (file-attribute-user-id attributes) (user-uid))
         (string-suffix-p "------" (file-attribute-modes attributes)))))

(defun gdev-mcp-private-socket-p (file)
  "Indica se FILE è un socket dell'utente in una cartella privata."
  (let ((attributes (let ((file-name-handler-alist nil))
                      (file-attributes file 'integer))))
    (and attributes
         (string-prefix-p "s" (file-attribute-modes attributes))
         (eql (file-attribute-user-id attributes) (user-uid))
         (gdev-mcp-private-directory-p (file-name-directory file)))))

;;;; Controllo di flusso sul socket

;; Un socket Unix su macOS contiene 8 KiB.  Quando è pieno,
;; `process-send-string' sospende Emacs per 20-30 ms prima di riprovare,
;; anche se il lettore lo ha già svuotato: ogni 8 KiB di risposta costava
;; quasi 30 ms.  Per evitarlo i due capi si confermano i byte letti.  Chi
;; riceve invia una riga vuota ogni `gdev-mcp-ack-unit' byte, solo tra un
;; messaggio e l'altro che invia a sua volta, e chi invia
;; non lascia in transito più di `gdev-mcp-window' byte non confermati,
;; così il socket non si riempie mai.  Il ponte apre la connessione con una
;; riga vuota e l'editor risponde allo stesso modo: solo dopo questo saluto
;; i capi si confermano i byte.  Un client che non saluta riceve soltanto
;; righe JSON-RPC.  Il protocollo ignora le righe vuote.

(defconst gdev-mcp-ack-unit 4096
  "Byte ricevuti confermati da ogni riga vuota.")

(defconst gdev-mcp-window 8192
  "Byte non ancora confermati che un capo lascia in transito.")

(defconst gdev-mcp-ack-wait 2
  "Secondi di attesa di una conferma prima di chiudere la connessione.")

(defun gdev-mcp--write (process string)
  "Invia STRING a PROCESS e conta i byte inviati."
  (process-put process 'gdev-mcp-sent
               (+ (string-bytes string) (or (process-get process 'gdev-mcp-sent) 0)))
  (process-send-string process string))

(defun gdev-mcp-greet (process)
  "Saluta PROCESS con una riga vuota: d'ora in poi conferma i byte ricevuti."
  (unless (process-get process 'gdev-mcp-greeted)
    (process-put process 'gdev-mcp-greeted t)
    (gdev-mcp--write process "\n")))

(defun gdev-mcp-note-input (process output)
  "Registra OUTPUT ricevuto da PROCESS: conta le conferme e conferma i byte letti."
  (let* ((before (or (process-get process 'gdev-mcp-received) 0))
         (received (+ before (length output)))
         (start 0)
         (empty 0)
         newline)
    (process-put process 'gdev-mcp-received received)
    ;; Una riga vuota è un \n all'inizio di una riga.
    (while (setq newline (string-search "\n" output start))
      (when (if (= newline 0)
                (not (process-get process 'gdev-mcp-mid-line))
              (eq (aref output (1- newline)) ?\n))
        (setq empty (1+ empty)))
      (setq start (1+ newline)))
    (unless (string-empty-p output)
      (process-put process 'gdev-mcp-mid-line
                   (not (eq (aref output (1- (length output))) ?\n))))
    (when (and (= before 0) (> empty 0) (eq (aref output 0) ?\n))
      ;; La prima riga vuota del flusso è il saluto, non una conferma.
      (setq empty (1- empty))
      (process-put process 'gdev-mcp-paced t)
      (gdev-mcp-greet process))
    (when (> empty 0)
      (process-put process 'gdev-mcp-acks (+ empty (or (process-get process 'gdev-mcp-acks) 0))))
    (gdev-mcp--flush-acks process)))

(defun gdev-mcp--flush-acks (process)
  "Conferma a PROCESS i byte ricevuti e non ancora confermati.
Una riga vuota nel mezzo di un messaggio ne sarebbe la fine: finché questo
capo sta inviando un messaggio, le conferme restano in sospeso e partono
quando `gdev-mcp-send' lo ha concluso."
  (when (and (process-get process 'gdev-mcp-paced)
             (not (process-get process 'gdev-mcp-sending))
             (process-live-p process))
    (let* ((sent (or (process-get process 'gdev-mcp-acks-sent) 0))
           (due (- (/ (or (process-get process 'gdev-mcp-received) 0) gdev-mcp-ack-unit)
                   sent)))
      (when (> due 0)
        (process-put process 'gdev-mcp-acks-sent (+ sent due))
        (gdev-mcp--write process (make-string due ?\n))))))

(defun gdev-mcp--await-ack (process)
  "Attendi da PROCESS una nuova conferma, o chiudi la connessione."
  (let ((acks (process-get process 'gdev-mcp-acks))
        (deadline (+ (float-time) gdev-mcp-ack-wait)))
    (while (and (eql acks (process-get process 'gdev-mcp-acks))
                (process-live-p process)
                (< (float-time) deadline))
      (accept-process-output process 0.05))
    ;; Un capo che non legge più bloccherebbe questo Emacs: meglio perdere
    ;; la risposta, il ponte si ricollega alla chiamata successiva.
    (when (eql acks (process-get process 'gdev-mcp-acks))
      (delete-process process))))

(defun gdev-mcp-send (process string)
  "Invia STRING a PROCESS senza riempire il socket."
  (let ((start 0)
        (end (length string)))
    (process-put process 'gdev-mcp-sending t)
    (unwind-protect
        (while (and (< start end) (process-live-p process))
          (let ((room (if (process-get process 'gdev-mcp-paced)
                          (- gdev-mcp-window
                             (- (or (process-get process 'gdev-mcp-sent) 0)
                                (* gdev-mcp-ack-unit (or (process-get process 'gdev-mcp-acks) 0))))
                        end)))
            (if (<= room 0)
                (gdev-mcp--await-ack process)
              (let ((stop (min end (+ start room))))
                (gdev-mcp--write process (if (and (= start 0) (= stop end))
                                             string
                                           (substring string start stop)))
                (setq start stop)))))
      (process-put process 'gdev-mcp-sending nil)
      ;; Le conferme arrivate durante l'invio partono a messaggio concluso.
      (gdev-mcp--flush-acks process))))

;;;; Ponte stdio

(defvar gdev-mcp--server-socket nil
  "Socket del server Emacs indicato con --socket, o nil per la ricerca.")

(defvar gdev-mcp--link nil
  "Connessione al socket MCP dell'editor dal vivo.")

(defvar gdev-mcp--link-output ""
  "Byte ricevuti dall'editor dal vivo e non ancora letti.")

(defvar gdev-mcp--live-listed nil
  "Non nil dopo aver offerto gli strumenti dell'editor in questa sessione.")

(defvar gdev-mcp--agent-interface-stamp
  (file-attribute-modification-time
   (file-attributes (expand-file-name "lisp/gdev-agent-interface.el" gdev-agent-interface--root)))
  "Data del sorgente di `gdev-agent-interface' caricato.")

(defun gdev-mcp--refresh-agent-interface ()
  "Ricarica `gdev-agent-interface' se il sorgente è cambiato.
Il ponte resta attivo per tutta la sessione: la scoperta descrive comunque
il codice corrente del checkout."
  (let* ((source (expand-file-name "lisp/gdev-agent-interface.el" gdev-agent-interface--root))
         (stamp (file-attribute-modification-time (file-attributes source))))
    (unless (equal stamp gdev-mcp--agent-interface-stamp)
      (setq gdev-mcp--agent-interface-stamp stamp)
      (load (file-name-sans-extension source) nil t))))

(defun gdev-mcp--link-filter (process output)
  "Accumula OUTPUT ricevuto dall'editor dal vivo su PROCESS."
  (gdev-mcp-note-input process output)
  (setq gdev-mcp--link-output (concat gdev-mcp--link-output output)))

(defun gdev-mcp--link-read (process seconds)
  "Leggi da PROCESS una riga non vuota entro SECONDS, o restituisci nil."
  (let ((deadline (+ (float-time) seconds))
        (searched 0)
        (waiting t)
        line)
    (while (and waiting (not line))
      (let ((newline (string-search "\n" gdev-mcp--link-output searched)))
        (cond (newline
               ;; Le righe vuote sono saluti e conferme del controllo di flusso.
               (unless (= newline 0)
                 (setq line (substring gdev-mcp--link-output 0 newline)))
               (setq gdev-mcp--link-output (substring gdev-mcp--link-output (1+ newline))
                     searched 0))
              ((and (process-live-p process) (< (float-time) deadline))
               (setq searched (length gdev-mcp--link-output))
               (accept-process-output process (min 0.5 (max 0.001 (- deadline (float-time))))))
              (t (setq waiting nil)))))
    line))

(defun gdev-mcp--server-reply (output)
  "Leggi il valore restituito dal server Emacs in OUTPUT."
  (let (parts failure)
    (dolist (line (split-string output "\n" t))
      (pcase (split-string line " ")
        (`("-print" ,text) (push (server-unquote-arg text) parts))
        (`("-print-nonl" ,text) (push (server-unquote-arg text) parts))
        (`("-error" ,text) (setq failure (server-unquote-arg text)))))
    (cond (failure
           (user-error "%s: %s" gdev-agent-interface-no-reply
                       (decode-coding-string failure 'utf-8-unix)))
          ((null parts) (user-error "%s" gdev-agent-interface-no-reply))
          (t (car (read-from-string
                   (decode-coding-string (apply #'concat (nreverse parts)) 'utf-8-unix)))))))

(defun gdev-mcp--bootstrap (server-socket)
  "Chiedi al server Emacs SERVER-SOCKET di aprire il socket MCP e restituiscilo."
  (require 'server)
  (gdev-agent-interface-check-socket server-socket)
  (let* ((output "")
         (root gdev-agent-interface--root)
         (form (let ((print-escape-nonascii t)
                     (print-escape-multibyte t)
                     (print-escape-newlines t))
                 (prin1-to-string
                  `(if (and (boundp 'gdev-config-directory) (equal gdev-config-directory ,root))
                       (progn (require 'gdev-mcp-server) (gdev-mcp-server-start))
                     :gdev-checkout-diverso))))
         (process (condition-case nil
                      (make-network-process
                       :name "gdev-mcp-avvio" :family 'local :service server-socket
                       :coding 'binary :noquery t :sentinel #'ignore
                       :filter (lambda (_process text) (setq output (concat output text))))
                    (file-error (user-error "%s" gdev-agent-interface-no-reply))))
         (deadline (+ (float-time) 10)))
    (unwind-protect
        (progn
          ;; Il protocollo di server.el chiude ogni argomento con uno spazio.
          (process-send-string process (concat "-eval " (server-quote-arg form) " \n"))
          (while (and (process-live-p process)
                      (< (float-time) deadline)
                      (not (string-match-p "^-error .*\n" output)))
            (accept-process-output process 0.1)))
      (delete-process process))
    (let ((value (gdev-mcp--server-reply output)))
      (cond ((stringp value) value)
            ((eq value :gdev-checkout-diverso)
             (user-error "Il socket non appartiene a questo checkout di GDev"))
            (t (user-error "%s" gdev-agent-interface-no-reply))))))

(defun gdev-mcp--discovered-socket ()
  "Restituisci il socket MCP dell'istanza con lo stesso checkout e stato."
  (when (boundp 'gdev-state-directory)
    (let ((file (gdev-mcp-socket-file)))
      (and (gdev-mcp-private-socket-p file) file))))

(defun gdev-mcp--link-open (socket protocol)
  "Collegati al socket MCP SOCKET e apri una sessione con PROTOCOL."
  (let ((process (condition-case nil
                     ;; Senza lettura adattiva le risposte brevi non attendono.
                     (let ((process-adaptive-read-buffering nil))
                       (make-network-process
                        :name "gdev-mcp-editor" :family 'local :service socket
                        :coding 'binary :noquery t :sentinel #'ignore
                        :filter #'gdev-mcp--link-filter))
                   (file-error (user-error "%s" gdev-agent-interface-no-reply)))))
    (setq gdev-mcp--link-output "")
    (gdev-mcp-greet process)
    (gdev-mcp-send
     process
     (concat (gdev-mcp--encode `((jsonrpc . "2.0") (id . 0) (method . "initialize")
                                 (params . ((protocolVersion . ,protocol)
                                            (capabilities . ,(make-hash-table))
                                            (clientInfo . ((name . "gdev-mcp") (version . "1.0.0")))))))
             "\n"))
    (let ((reply (gdev-mcp--link-read process 10)))
      (unless (and reply (string-search "\"result\"" reply))
        (delete-process process)
        (user-error "%s" gdev-agent-interface-no-reply)))
    (gdev-mcp-send process "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
    process))

(defun gdev-mcp--ensure-link (session)
  "Restituisci la connessione all'editor dal vivo per SESSION, aprendola se serve."
  ;; Il ponte attende l'agente in una lettura bloccante e non vede l'altro capo
  ;; chiudersi.  Emacs in batch non ignora SIGPIPE: scrivere su un socket
  ;; chiuso, per esempio dopo il riavvio dell'editor, terminerebbe il ponte
  ;; (stato 141) e il client vedrebbe cadere il server.  Un ascolto senza
  ;; attesa registra la chiusura prima della scrittura.
  (when (process-live-p gdev-mcp--link)
    (accept-process-output gdev-mcp--link 0))
  (unless (process-live-p gdev-mcp--link)
    (setq gdev-mcp--link nil)
    (let ((socket (if gdev-mcp--server-socket
                      (gdev-mcp--bootstrap gdev-mcp--server-socket)
                    (or (gdev-mcp--discovered-socket)
                        (user-error "Nessuna istanza GDev di questo checkout è raggiungibile")))))
      (setq gdev-mcp--link (gdev-mcp--link-open socket (gdev-mcp-session-protocol session)))))
  gdev-mcp--link)

(defun gdev-mcp--bridge-tools (session)
  "Nomi degli strumenti offerti dal ponte in SESSION."
  (if (or gdev-mcp--server-socket
          gdev-mcp--live-listed
          (and (gdev-mcp-session-protocol session)
               (gdev-mcp--discovered-socket)
               (ignore-errors (gdev-mcp--ensure-link session))))
      (progn (setq gdev-mcp--live-listed t) gdev-mcp-all-tools)
    '("gdev_discover")))

(defun gdev-mcp--deadline (arguments)
  "Secondi di attesa per una chiamata dal vivo con ARGUMENTS."
  (let ((timeout (gethash "timeout" arguments)))
    (if (integerp timeout)
        (max gdev-mcp-call-timeout (+ (min timeout 300) 5))
      gdev-mcp-call-timeout)))

(defun gdev-mcp--bridge-call (session name arguments line)
  "Esegui lo strumento NAME: la scoperta qui, il resto nell'editor dal vivo."
  (if (equal name "gdev_discover")
      (progn (gdev-mcp--refresh-agent-interface)
             (gdev-mcp--discover arguments))
    ;; Gli errori di validazione non richiedono l'editor.
    (gdev-mcp--operands (gdev-mcp--live-spec name) arguments)
    (condition-case err
        (let* ((link (gdev-mcp--ensure-link session))
               (reply (progn (gdev-mcp-send link (concat (gdev-mcp--bytes line) "\n"))
                             (gdev-mcp--link-read link (gdev-mcp--deadline arguments)))))
          (cond (reply reply)
                ((process-live-p link)
                 (delete-process link)
                 `((error . ,gdev-mcp-timeout-message)))
                (t (gdev-agent-interface--error gdev-agent-interface-no-reply))))
      (error (gdev-agent-interface--error (error-message-string err))))))

(defun gdev-mcp--usage-error (message)
  "Scrivi MESSAGE su stderr con l'uso del comando ed esci con stato 2."
  (message "uso: gdev-mcp [-h] [--socket SOCKET]\ngdev-mcp: errore: %s" message)
  (kill-emacs 2))

(defun gdev-mcp--arguments (arguments)
  "Leggi le opzioni di `bin/gdev-mcp' da ARGUMENTS e restituisci il socket."
  (let (socket)
    (while arguments
      (let ((argument (pop arguments)))
        (cond ((member argument '("-h" "--help"))
               (princ (concat "uso: gdev-mcp [-h] [--socket SOCKET]\n\n"
                              "Espone l'interfaccia per agenti di GDev via MCP su stdin e stdout.\n\n"
                              "opzioni:\n"
                              "  -h, --help         mostra questo aiuto ed esci\n"
                              "  --socket SOCKET    percorso assoluto del socket Unix di Emacs da usare\n"))
               (kill-emacs 0))
              ((equal argument "--socket")
               (unless arguments
                 (gdev-mcp--usage-error "l'argomento --socket richiede un valore"))
               (setq socket (pop arguments)))
              ((string-prefix-p "--socket=" argument)
               (setq socket (substring argument (length "--socket="))))
              (t (gdev-mcp--usage-error (format "argomento non riconosciuto: %s" argument))))))
    (when (and socket (not (gdev-mcp--local-path-p socket)))
      (gdev-mcp--usage-error "--socket richiede un percorso locale assoluto."))
    socket))

(defun gdev-mcp-serve (session)
  "Servi SESSION leggendo righe da stdin fino alla fine del flusso."
  (catch 'gdev-mcp--end
    (while t
      (let ((line (condition-case nil
                      (read-from-minibuffer "")
                    (end-of-file (throw 'gdev-mcp--end nil)))))
        ;; In batch anche \r chiude una riga: CRLF lascia una riga vuota.
        (unless (string-empty-p line)
          (when-let* ((response (gdev-mcp-handle-line session line)))
            (send-string-to-terminal (concat response "\n"))))))))

(defun gdev-mcp-main ()
  "Punto di ingresso di `bin/gdev-mcp' in un Emacs batch."
  (setq gdev-mcp--server-socket (gdev-mcp--arguments command-line-args-left)
        command-line-args-left nil
        ;; early-init.el sospende la raccolta della memoria fino all'avvio.
        gc-cons-threshold (* 32 1024 1024)
        gc-cons-percentage 0.2)
  (gdev-mcp-serve (gdev-mcp-session-create :tools #'gdev-mcp--bridge-tools
                                           :call #'gdev-mcp--bridge-call))
  (kill-emacs 0))

(provide 'gdev-mcp)
;;; gdev-mcp.el ends here
