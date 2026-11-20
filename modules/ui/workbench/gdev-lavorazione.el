;;; gdev-lavorazione.el --- Lavorazioni dichiarative del banco di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Una lavorazione è un file JSON. I moduli dichiarano azioni e argomenti
;; con gdev-lavorazione-registra. Il file contiene solo dati e non viene
;; mai interpretato come codice Lisp o come comando della shell.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'js)
(require 'subr-x)
;; Il motore delle procedure serve anche senza editor. Le viste e lo stato
;; dello spazio si caricano quando viene usato un comando interattivo.
(autoload 'gdev-ui-view-setup "gdev-ui")
(autoload 'gdev-layout-mark-auxiliary "gdev-layout")
(autoload 'gdev-workspace-state-id "gdev-workspace-state")
(autoload 'gdev-workspace-state-find "gdev-workspace-state")
(autoload 'gdev-workspace-state-ensure-id "gdev-workspace-state")
(autoload 'gdev-workspace-directory "gdev-workspaces")
(defvar gdev-context-items)

(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-close-document "gdev-commands" ())

(cl-defstruct gdev-lavorazione--azione
  nome descrizione schema funzione richiede-documento apre-documento modulo lettore)
(cl-defstruct gdev-lavorazione--contesto radice documento visitati)
(cl-defstruct gdev-lavorazione-esito
  "Risultato di verifica o esecuzione riferito a una revisione del sorgente."
  stato revisione totale completati passo azione messaggio radice)

(defvar-local gdev-lavorazione--esiti nil
  "Ultimi esiti del sorgente, indicizzati per identità dello spazio.")

(defvar gdev-lavorazione-esito-hook nil
  "Funzioni di notifica eseguite nel sorgente dopo la pubblicazione di un esito.")

(defvar gdev-lavorazione--azioni (make-hash-table :test #'equal))
(defvar gdev-lavorazione--in-corso nil)
(defconst gdev-lavorazione--limite-caratteri (* 256 1024))

(cl-defun gdev-lavorazione-registra (nome descrizione schema funzione
                                         &key richiede-documento apre-documento
                                         (modulo "Lavorazioni") lettore)
  "Registra NOME, DESCRIZIONE, SCHEMA e FUNZIONE per le lavorazioni.
SCHEMA è una lista di (NOME-ARGOMENTO . TIPO). I tipi sono `testo',
`testo-non-vuoto', `intero-positivo' e `percorso'. Gli argomenti sono
obbligatori. FUNZIONE riceve il contesto e i valori nell'ordine di SCHEMA.
Il modulo deve fornire un'azione locale sincrona, senza richieste di
input, e segnalare le precondizioni fallite prima di modificare lo stato.
RICHIEDE-DOCUMENTO indica che serve un passo precedente con APRE-DOCUMENTO.
MODULO è l'etichetta del componente che fornisce l'azione. LETTORE, se
presente, legge un argomento nella composizione. Riceve nome, tipo,
valore iniziale e prefisso del piano. Lo schema verifica il valore restituito."
  (unless (and (stringp nome) (string-match-p "\\`[a-z][a-z0-9-]*\\'" nome)
               (stringp descrizione) (functionp funzione)
               (stringp modulo) (not (string-empty-p modulo))
               (or (null lettore) (functionp lettore))
               (proper-list-p schema)
               (cl-every (lambda (campo)
                           (and (consp campo) (stringp (car campo))
                                (memq (cdr campo) '(testo testo-non-vuoto intero-positivo percorso))))
                         schema)
               (= (length schema) (length (delete-dups (mapcar #'car schema)))))
    (error "Contratto dell'azione non valido: %S" nome))
  (when-let* ((precedente (gethash nome gdev-lavorazione--azioni)))
    (unless (equal modulo (gdev-lavorazione--azione-modulo precedente))
      (error "L'azione %s appartiene già a %s" nome
             (gdev-lavorazione--azione-modulo precedente))))
  (puthash nome (make-gdev-lavorazione--azione
                 :nome nome :descrizione descrizione :schema schema :funzione funzione
                 :richiede-documento richiede-documento :apre-documento apre-documento
                 :modulo modulo :lettore lettore)
           gdev-lavorazione--azioni))

(defun gdev-lavorazione--oggetto (oggetto campi)
  "Verifica che OGGETTO contenga esattamente CAMPI."
  (unless (and (hash-table-p oggetto)
               (= (hash-table-count oggetto) (length campi))
               (cl-every (lambda (campo) (not (eq :manca (gethash campo oggetto :manca)))) campi))
    (user-error "Atteso un oggetto con i campi: %s" (string-join campi ", "))))

(defun gdev-lavorazione--argomento-p (valore tipo)
  "Restituisci non nil se VALORE è del TIPO dichiarato."
  (pcase tipo
    ('testo (stringp valore))
    ('testo-non-vuoto (and (stringp valore) (not (string-empty-p valore))))
    ('intero-positivo (and (integerp valore) (> valore 0)))
    ('percorso (and (stringp valore) (not (string-empty-p valore))
                    (not (file-name-absolute-p valore))
                    (not (string-match-p "\0" valore))
                    (not (member ".." (split-string valore "/" t)))))))

(defun gdev-lavorazione--leggi ()
  "Leggi il documento corrente e restituisci l'oggetto JSON."
  (save-excursion
    (save-restriction
      (widen)
      (when (> (buffer-size) gdev-lavorazione--limite-caratteri)
        (user-error "La lavorazione supera il limite di 256 Ki caratteri"))
      (goto-char (point-min))
      (let ((documento (condition-case err
                            (json-parse-buffer :object-type 'hash-table :array-type 'array)
                          (json-error (user-error "JSON non valido: %s" (error-message-string err))))))
        (skip-chars-forward " \t\n\r")
        (unless (eobp) (user-error "Testo dopo la fine della lavorazione"))
        (gdev-lavorazione--oggetto documento '("versione" "passi"))
        (unless (eql 1 (gethash "versione" documento))
          (user-error "Versione della lavorazione non supportata"))
        (unless (and (vectorp (gethash "passi" documento))
                     (<= (length (gethash "passi" documento)) 128))
          (user-error "I passi devono essere un elenco di al massimo 128 elementi"))
        documento))))

(defun gdev-lavorazione--piano (documento &optional al-fallimento)
  "Risolvi e valida tutti i passi di DOCUMENTO prima dell'esecuzione.
AL-FALLIMENTO riceve il numero del passo e il nome dell'azione, se noto."
  (cl-loop with documento-aperto = nil
           for passo across (gethash "passi" documento)
           for numero from 1
           collect
           (condition-case err
               (progn
                 (gdev-lavorazione--oggetto passo '("azione" "argomenti"))
                 (let* ((nome (gethash "azione" passo))
                        (azione (gethash nome gdev-lavorazione--azioni))
                        (argomenti (gethash "argomenti" passo)))
                   (unless azione (user-error "Azione non disponibile: %S" nome))
                   (when (and (gdev-lavorazione--azione-richiede-documento azione)
                              (not documento-aperto))
                     (user-error "Prima di %s serve un passo che apre un documento" nome))
                   (when (gdev-lavorazione--azione-apre-documento azione)
                     (setq documento-aperto t))
                   (let ((schema (gdev-lavorazione--azione-schema azione)))
                     (gdev-lavorazione--oggetto argomenti (mapcar #'car schema))
                     (cons azione
                           (cl-loop for (campo . tipo) in schema
                                    for valore = (gethash campo argomenti)
                                    collect
                                    (progn
                                      (unless (gdev-lavorazione--argomento-p valore tipo)
                                        (user-error "%s richiede il tipo %s" campo tipo))
                                      valore))))))
             (user-error
              (when al-fallimento
                (let ((nome (and (hash-table-p passo) (gethash "azione" passo))))
                  (funcall al-fallimento numero (and (stringp nome) nome))))
              (user-error "Passo %d · %s" numero (error-message-string err))))))

(defun gdev-lavorazione--percorso (radice relativo)
  "Risolvi RELATIVO sotto RADICE, controllando anche i collegamenti simbolici."
  (let ((file (expand-file-name relativo radice)))
    (unless (and (not (file-remote-p file))
                 (not (find-file-name-handler file 'write-region))
                 (file-in-directory-p file radice)
                 (file-directory-p (file-name-directory file))
                 (or (not (file-exists-p file)) (file-regular-p file)))
      (user-error "Serve un file locale nella cartella di lavoro: %s" relativo))
    file))

(defun gdev-lavorazione-radice (contesto)
  "Restituisci la cartella locale scelta per CONTESTO."
  (gdev-lavorazione--contesto-radice contesto))

(defun gdev-lavorazione-file-previsto (piano)
  "Restituisci il percorso relativo dell'ultimo apri-file in PIANO.
Se l'ultimo passo che apre un documento è di altro tipo, restituisci nil."
  (let ((passo (cl-find-if (lambda (voce)
                           (gdev-lavorazione--azione-apre-documento (car voce)))
                         piano :from-end t)))
    (when (and passo (equal (gdev-lavorazione--azione-nome (car passo)) "apri-file"))
      (cadr passo))))

(defun gdev-lavorazione-documento (contesto)
  "Restituisci il documento attivo di CONTESTO dopo averne verificato il percorso."
  (let* ((buffer (gdev-lavorazione--contesto-documento contesto))
         (radice (gdev-lavorazione--contesto-radice contesto))
         (file (and (buffer-live-p buffer) (buffer-file-name buffer))))
    (unless file (user-error "Apri un file con il passo apri-file"))
    (gdev-lavorazione--percorso radice (file-relative-name file radice))
    buffer))

(defun gdev-lavorazione--apri (contesto relativo)
  "Apri RELATIVO nel progetto di CONTESTO e selezionalo per i passi successivi."
  (let* ((radice (gdev-lavorazione--contesto-radice contesto))
         (file (gdev-lavorazione--percorso radice relativo))
         (aperto (find-buffer-visiting file))
         (enable-local-variables :safe)
         (enable-local-eval nil))
    (when (and aperto
               (or (not (verify-visited-file-modtime aperto))
                   (and (buffer-modified-p aperto)
                        (not (memq aperto (gdev-lavorazione--contesto-visitati contesto))))))
      (user-error "Controlla le modifiche già presenti in %s" relativo))
    (let ((buffer (gdev-open-file file)))
      (unless (and (buffer-live-p buffer) (buffer-file-name buffer))
        (user-error "Impossibile aprire %s" relativo))
      (setf (gdev-lavorazione--contesto-documento contesto) buffer)
      (cl-pushnew buffer (gdev-lavorazione--contesto-visitati contesto)))))

(defun gdev-lavorazione--vai (contesto riga)
  "Porta il cursore a RIGA nel documento di CONTESTO."
  (with-current-buffer (gdev-lavorazione-documento contesto)
    (save-restriction
      (widen)
      (let ((posizione (save-excursion
                        (goto-char (point-min))
                        (unless (zerop (forward-line (1- riga)))
                          (user-error "La riga %d non esiste" riga))
                        (point))))
        (goto-char posizione)))))

(defun gdev-lavorazione--inserisci (contesto testo)
  "Inserisci TESTO al cursore nel documento di CONTESTO."
  (with-current-buffer (gdev-lavorazione-documento contesto)
    (atomic-change-group (insert testo))))

(defun gdev-lavorazione--sostituisci (contesto prima dopo)
  "Sostituisci l'unica occorrenza letterale di PRIMA con DOPO in CONTESTO."
  (with-current-buffer (gdev-lavorazione-documento contesto)
    (save-restriction
      (widen)
      (let ((case-fold-search nil)
            (inizio nil))
        (save-excursion
          (goto-char (point-min))
          (unless (search-forward prima nil t)
            (user-error "Il testo da sostituire non è presente"))
          (setq inizio (- (point) (length prima)))
          (goto-char (1+ inizio))
          (when (search-forward prima nil t)
            (user-error "Il testo da sostituire ha più occorrenze")))
        (atomic-change-group
          (goto-char inizio)
          (delete-region inizio (+ inizio (length prima)))
          (insert dopo))))))

(defun gdev-lavorazione--salva (contesto)
  "Salva il documento di CONTESTO se il disco è ancora allineato al buffer."
  (let ((buffer (gdev-lavorazione-documento contesto)))
    (unless (verify-visited-file-modtime buffer)
      (user-error "Il documento è cambiato su disco"))
    (with-current-buffer buffer (save-buffer))))

(gdev-lavorazione-registra "apri-file" "Apri o crea un documento nella cartella di lavoro."
                          '(("file" . percorso)) #'gdev-lavorazione--apri :apre-documento t)
(gdev-lavorazione-registra "vai-riga" "Sposta il cursore alla riga indicata."
                          '(("riga" . intero-positivo)) #'gdev-lavorazione--vai :richiede-documento t)
(gdev-lavorazione-registra "inserisci" "Inserisci testo alla posizione del cursore."
                          '(("testo" . testo)) #'gdev-lavorazione--inserisci :richiede-documento t)
(gdev-lavorazione-registra "sostituisci" "Sostituisci un'occorrenza letterale univoca."
                          '(("prima" . testo-non-vuoto) ("dopo" . testo))
                          #'gdev-lavorazione--sostituisci :richiede-documento t)
(gdev-lavorazione-registra "salva" "Scrivi il documento corrente sul disco."
                          nil #'gdev-lavorazione--salva :richiede-documento t)

(defun gdev-lavorazione--esegui (piano radice &optional al-passo)
  "Esegui PIANO in RADICE, fermandoti al primo passo non riuscito.
AL-PASSO riceve il numero e il nome di ogni azione prima di eseguirla."
  (when gdev-lavorazione--in-corso (user-error "Una lavorazione è già in corso"))
  (let ((gdev-lavorazione--in-corso t)
        (contesto (make-gdev-lavorazione--contesto :radice radice)))
    (cl-loop for (azione . argomenti) in piano
             for numero from 1
             when al-passo do (funcall al-passo numero (gdev-lavorazione--azione-nome azione))
             do (condition-case err
                    (apply (gdev-lavorazione--azione-funzione azione) contesto argomenti)
                  (error (user-error "Passo %d (%s) · %s"
                                     numero (gdev-lavorazione--azione-nome azione)
                                     (error-message-string err)))))
    (length piano)))

(defun gdev-lavorazione-run-file (file root &optional check)
  "Valida ed esegui FILE nella radice ROOT con il motore ordinario.
Con CHECK risolvi l'intero piano senza eseguire passi. Non visita FILE e
non pubblica stato dello spazio: è l'entrata sincrona delle procedure."
  (let ((root (file-name-as-directory (file-truename root))))
    (unless (and (file-regular-p file) (file-in-directory-p (file-truename file) root))
      (user-error "Il piano deve essere un file interno al progetto"))
    (gdev-lavorazione-run-text
     (with-temp-buffer (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file)) (buffer-string)) root check)))

(defun gdev-lavorazione-run-text (text root &optional check)
  "Esegui il piano TEXT fissato dal chiamante in ROOT, oppure validalo con CHECK."
  (with-temp-buffer
    (insert text)
    (let ((plan (gdev-lavorazione--piano (gdev-lavorazione--leggi))))
      (unless plan (user-error "Una procedura richiede un piano non vuoto"))
      (if check (length plan) (gdev-lavorazione--esegui plan root)))))

(defun gdev-lavorazione-analizza (&optional sorgente)
  "Leggi SORGENTE e restituisci una coppia (PIANO . ESITO) senza pubblicarla.
Senza SORGENTE usa il buffer corrente. Un piano vuoto ha esito valido."
  (with-current-buffer (or sorgente (current-buffer))
    (let ((esito (make-gdev-lavorazione-esito
                  :stato 'valida :revisione (buffer-chars-modified-tick)))
          piano)
      (condition-case err
          (let ((documento (gdev-lavorazione--leggi)))
            (setf (gdev-lavorazione-esito-totale esito) (length (gethash "passi" documento)))
            (setq piano (gdev-lavorazione--piano
                         documento
                         (lambda (passo azione)
                           (setf (gdev-lavorazione-esito-passo esito) passo
                                 (gdev-lavorazione-esito-azione esito) azione)))))
        (user-error
         (setf (gdev-lavorazione-esito-stato esito) 'non-valida
               (gdev-lavorazione-esito-messaggio esito) (error-message-string err))))
      (cons piano esito))))

(defun gdev-lavorazione-ultimo-esito (&optional sorgente cornice)
  "Restituisci l'ultimo esito di SORGENTE nello spazio corrente di CORNICE.
La revisione dell'esito permette di riconoscere un sorgente cambiato."
  (with-current-buffer (or sorgente (current-buffer))
    (when gdev-lavorazione--esiti
      (gethash (gdev-workspace-state-id cornice) gdev-lavorazione--esiti))))

(defun gdev-lavorazione--pubblica-esito (sorgente spazio esito)
  "Pubblica ESITO per SORGENTE se lo SPAZIO di origine è ancora aperto."
  (when (and (buffer-live-p sorgente)
             (cl-loop for cornice in (frame-list)
                      thereis (gdev-workspace-state-find spazio cornice)))
    (with-current-buffer sorgente
      (unless gdev-lavorazione--esiti
        (setq gdev-lavorazione--esiti (make-hash-table :test #'eq :weakness 'key)))
      (puthash spazio esito gdev-lavorazione--esiti)
      (with-demoted-errors "Aggiornamento dell'esito: %S"
        (run-hooks 'gdev-lavorazione-esito-hook)))))

(defun gdev-lavorazione-verifica ()
  "Controlla tutti i passi della lavorazione corrente senza eseguirli."
  (interactive)
  (let* ((esito (cdr (gdev-lavorazione-analizza)))
         (spazio (gdev-workspace-state-ensure-id)))
    (gdev-lavorazione--pubblica-esito (current-buffer) spazio esito)
    (when (eq (gdev-lavorazione-esito-stato esito) 'non-valida)
      (user-error "%s" (gdev-lavorazione-esito-messaggio esito)))
    (message "Lavorazione valida · %d passi" (gdev-lavorazione-esito-totale esito))))

(defun gdev-lavorazione--controlla-origine (sorgente spazio revisione)
  "Verifica SPAZIO e REVISIONE di SORGENTE dopo una richiesta di input."
  (unless (eq spazio (gdev-workspace-state-id))
    (user-error "Lo spazio di lavoro è cambiato. Avvia di nuovo la lavorazione"))
  (unless (and (buffer-live-p sorgente) (= revisione (buffer-chars-modified-tick sorgente)))
    (user-error "La lavorazione è cambiata. Rileggila prima di eseguirla")))

(declare-function gdev-workbench-operation-start "gdev-workbench-operations" (label buffer &optional interruptible))
(declare-function gdev-workbench-operation-report "gdev-workbench-operations" (operation state &optional detail))

(defun gdev-lavorazione-esegui ()
  "Esegui il contenuto della lavorazione corrente dopo conferma."
  (interactive)
  (unless (derived-mode-p 'gdev-lavorazione-mode)
    (user-error "Apri un file .lavorazione"))
  (let* ((origine (current-buffer))
         (spazio (gdev-workspace-state-ensure-id))
         (analisi (gdev-lavorazione-analizza))
         (piano (car analisi))
         (esito (cdr analisi))
         (revisione (gdev-lavorazione-esito-revisione esito))
         (totale (length piano))
         passo azione operazione)
    (when (eq (gdev-lavorazione-esito-stato esito) 'non-valida)
      (gdev-lavorazione--pubblica-esito origine spazio esito)
      (user-error "%s" (gdev-lavorazione-esito-messaggio esito)))
    (unwind-protect
        (condition-case err
            (progn
              (unless piano (user-error "La lavorazione è vuota"))
              (let ((radice (read-directory-name "Cartella di lavoro: "
                                                (or (gdev-workspace-directory) default-directory)
                                                nil t)))
                (gdev-lavorazione--controlla-origine origine spazio revisione)
                (when (file-remote-p radice) (user-error "Scegli una cartella locale"))
                (setf (gdev-lavorazione-esito-radice esito) radice)
                (if (yes-or-no-p (format "Eseguire %d passi in %s? "
                                        totale (abbreviate-file-name radice)))
                    (progn
                      (gdev-lavorazione--controlla-origine origine spazio revisione)
                      (setq radice (file-name-as-directory (file-truename radice)))
                      (setf (gdev-lavorazione-esito-radice esito) radice)
                      (when (fboundp 'gdev-workbench-operation-start)
                        (setq operazione (gdev-workbench-operation-start
                                          (format "Lavorazione · %s" (buffer-name origine)) origine)))
                      (let ((completati
                             (save-current-buffer
                               (gdev-lavorazione--esegui piano radice
                                                        (lambda (n nome)
                                                          (setq passo n azione nome)
                                                          (when operazione
                                                            (gdev-workbench-operation-report
                                                             operazione 'running
                                                             (format "Passo %d di %d · %s" n totale nome))))))))
                        (setf (gdev-lavorazione-esito-completati esito) completati
                              (gdev-lavorazione-esito-stato esito) 'completata)
                        (message "Lavorazione completata · %d passi" completati)))
                  (setf (gdev-lavorazione-esito-stato esito) 'annullata
                        (gdev-lavorazione-esito-completati esito) 0)
                  nil)))
          ((error quit)
           (setf (gdev-lavorazione-esito-stato esito)
                 (if (eq (car err) 'quit) 'annullata 'fallita)
                 (gdev-lavorazione-esito-completati esito) (if passo (1- passo) 0)
                 (gdev-lavorazione-esito-passo esito) passo
                 (gdev-lavorazione-esito-azione esito) azione
                 (gdev-lavorazione-esito-messaggio esito) (error-message-string err))
           (signal (car err) (cdr err))))
      (gdev-lavorazione--pubblica-esito origine spazio esito)
      (when operazione
        (gdev-workbench-operation-report
         operazione (pcase (gdev-lavorazione-esito-stato esito)
                      ('completata 'completed) ('annullata 'cancelled) (_ 'failed))
         (or (gdev-lavorazione-esito-messaggio esito)
             (format "%d di %d passi completati" (gdev-lavorazione-esito-completati esito) totale)))))))

(defvar-keymap gdev-lavorazione-catalogo-mode-map
  "g" #'gdev-lavorazione-catalogo
  "q" #'gdev-close-document)

(define-derived-mode gdev-lavorazione-catalogo-mode special-mode "Catalogo azioni"
  "Consulta le azioni registrate per le lavorazioni."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local gdev-context-items
              '(["Aggiorna catalogo" gdev-lavorazione-catalogo t (:target view)])))

(defun gdev-lavorazione--disegna-catalogo ()
  "Presenta le azioni e conserva quella vicina al punto."
  (let ((azione-corrente (get-text-property (point) 'gdev-lavorazione-voce))
        (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Azioni disponibili" 'face 'gdev-ui-view-title) "\n\n")
    (dolist (nome (sort (hash-table-keys gdev-lavorazione--azioni) #'string<))
      (let ((azione (gethash nome gdev-lavorazione--azioni)) (inizio (point)))
        (insert (propertize nome 'face 'gdev-ui-view-heading) "\n"
                (propertize (gdev-lavorazione--azione-modulo azione) 'face 'gdev-ui-secondary) "\n"
                (gdev-lavorazione--azione-descrizione azione) "\n")
        (pcase-dolist (`(,campo . ,tipo) (gdev-lavorazione--azione-schema azione))
          (insert (propertize (format "%s (%s)" campo tipo) 'face 'gdev-ui-secondary) "\n"))
        (insert "\n")
        (put-text-property inizio (point) 'gdev-lavorazione-voce nome)))
    (goto-char (point-min))
    (when-let* ((azione-corrente)
                (voce (text-property-search-forward 'gdev-lavorazione-voce azione-corrente t)))
      (goto-char (prop-match-beginning voce)))
    (set-buffer-modified-p nil)))

(defun gdev-lavorazione-catalogo ()
  "Mostra le azioni attualmente disponibili e i loro argomenti."
  (interactive)
  (let ((buffer (get-buffer-create "*Azioni delle lavorazioni*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-lavorazione-catalogo-mode)
        (gdev-lavorazione-catalogo-mode))
      (gdev-lavorazione--disegna-catalogo))
    (pop-to-buffer buffer)))

(defun gdev-lavorazione--leggi-passo (piano &optional precedente)
  "Compila un passo valido dopo PIANO o modifica gli argomenti di PRECEDENTE."
  (let* ((documento-aperto (seq-some (lambda (passo)
                                       (gdev-lavorazione--azione-apre-documento (car passo)))
                                     piano))
         (nomi (cl-loop for nome being the hash-keys of gdev-lavorazione--azioni
                        using (hash-values azione)
                        when (or documento-aperto
                                 (not (gdev-lavorazione--azione-richiede-documento azione)))
                        collect nome))
         (nome (if precedente (gethash "azione" precedente)
                 (minibuffer-with-setup-hook
                     (lambda ()
                       (setq-local completion-extra-properties
                                   (list :annotation-function
                                         (lambda (nome)
                                           (when-let* ((voce (gethash nome gdev-lavorazione--azioni)))
                                             (concat "  " (gdev-lavorazione--azione-modulo voce)))))))
                   (completing-read "Azione: " nomi nil t))))
         (azione (gethash nome gdev-lavorazione--azioni))
         (argomenti (make-hash-table :test #'equal))
         (passo (make-hash-table :test #'equal)))
    (unless (and azione (member nome nomi))
      (user-error "Scegli un'azione disponibile a questo punto della lavorazione"))
    (pcase-dolist (`(,campo . ,tipo) (gdev-lavorazione--azione-schema azione))
      (let* ((prompt (format "%s (%s): " campo tipo))
             (iniziale (and precedente (gethash campo (gethash "argomenti" precedente))))
             (lettore (gdev-lavorazione--azione-lettore azione))
             (valore (cond (lettore (funcall lettore campo tipo iniziale piano))
                           ((eq tipo 'intero-positivo) (read-number prompt iniziale))
                           (t (read-string prompt iniziale)))))
        (unless (gdev-lavorazione--argomento-p valore tipo)
          (user-error "%s richiede il tipo %s" campo tipo))
        (puthash campo valore argomenti)))
    (puthash "azione" nome passo)
    (puthash "argomenti" argomenti passo)
    passo))

(defun gdev-lavorazione--scrivi (documento versione)
  "Scrivi DOCUMENTO alla VERSIONE attesa e restituisci il piano verificato."
  (unless (= versione (buffer-chars-modified-tick))
    (user-error "Il sorgente è cambiato. Aggiorna la composizione prima di continuare"))
  (when (> (length (gethash "passi" documento)) 128)
    (user-error "La lavorazione ha già 128 passi"))
  (let ((piano (gdev-lavorazione--piano documento))
        (sorgente (current-buffer)))
    (with-temp-buffer
      (insert (gdev-json-text documento))
      (json-pretty-print-buffer)
      (insert "\n")
      (when (> (buffer-size) gdev-lavorazione--limite-caratteri)
        (user-error "La lavorazione è troppo lunga"))
      (let ((testo (current-buffer)))
        (with-current-buffer sorgente
          (save-restriction
            (widen)
            (undo-boundary)
            (atomic-change-group
              (with-suppressed-warnings ((obsolete replace-buffer-contents))
                (replace-buffer-contents testo 0.2)))
            (undo-boundary)))))
    piano))

(defun gdev-lavorazione-aggiungi-passo ()
  "Aggiungi un passo scegliendolo dal catalogo e compilando i suoi argomenti."
  (interactive)
  (unless (derived-mode-p 'gdev-lavorazione-mode)
    (user-error "Apri un file .lavorazione"))
  (let* ((documento (gdev-lavorazione--leggi))
         (passi (gethash "passi" documento))
         (versione (buffer-chars-modified-tick))
         (piano (gdev-lavorazione--piano documento)))
    (when (>= (length passi) 128) (user-error "La lavorazione ha già 128 passi"))
    (puthash "passi" (vconcat passi (vector (gdev-lavorazione--leggi-passo piano))) documento)
    (gdev-lavorazione--scrivi documento versione)))

(autoload 'gdev-lavorazione-composizione "gdev-lavorazione-composizione" nil t)

(defun gdev-lavorazione--apri-sorgente (file)
  "Apri FILE nell'editor e prepara il modello per una nuova lavorazione."
  (let ((esiste (file-exists-p file))
        (enable-local-eval nil)
        (enable-local-variables :safe))
    (gdev-open-file file)
    (unless (derived-mode-p 'gdev-lavorazione-mode)
      (user-error "Il file deve usare la modalità Lavorazione"))
    (unless (or esiste (not (zerop (buffer-size))))
      (insert "{\n  \"versione\": 1,\n  \"passi\": []\n}\n"))
    (current-buffer)))

(defun gdev-lavorazione-nuova (file)
  "Apri FILE e prepara un modello se il documento è nuovo."
  (interactive "FFile della lavorazione: ")
  (unless (string-suffix-p ".lavorazione" file)
    (setq file (concat file ".lavorazione")))
  (gdev-lavorazione--apri-sorgente file)
  (gdev-lavorazione-composizione))

(defvar-keymap gdev-lavorazione-mode-map
  "C-c C-c" #'gdev-lavorazione-esegui
  "C-c C-v" #'gdev-lavorazione-verifica
  "C-c C-a" #'gdev-lavorazione-aggiungi-passo
  "C-c C-e" #'gdev-lavorazione-composizione)

(define-derived-mode gdev-lavorazione-mode js-json-mode "Lavorazione"
  "Modifica un piano JSON eseguibile da GDev."
  (gdev-ui-view-setup 'native)
  (setq-local enable-local-eval nil
              enable-local-variables :safe
              gdev-context-items
              '(["Apri composizione" gdev-lavorazione-composizione t (:target view)]
                ["Aggiungi un passo…" gdev-lavorazione-aggiungi-passo t (:target view)]
                ["Verifica la lavorazione" gdev-lavorazione-verifica t (:target view)]
                ["Esegui la lavorazione…" gdev-lavorazione-esegui t (:target view)])))

(provide 'gdev-lavorazione)
(require 'gdev-assurance-lavorazione)
;;; gdev-lavorazione.el ends here
