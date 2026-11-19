;;; gdev-standards.el --- Registro degli standard e indice delle clausole -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Legge il registro dei riferimenti normativi, `registro.eld' in
;; docs/assicurazione/standard, e controlla che un riferimento a una clausola
;; sia vero: lo standard è nel registro, è corrente, l'edizione è quella
;; indicata e la clausola esiste nei dati locali.
;;
;; Il registro contiene identificativi, edizioni, stati e licenze, mai testo
;; normativo.  Una clausola si verifica solo se i dati dello standard sono
;; locali: ASVS, SSDF, SLSA e indici parziali ECSS. Senza un indice si accetta
;; soltanto un riferimento bibliografico esplicito, mai un numero di clausola.
;; I controlli di attuazione sono originali GDev e non riproducono le norme.
;;
;; I file `.eld' sono dati: si leggono con `read' e `read-eval' spento, e non si
;; valutano.  Carica da solo, senza la configurazione di GDev.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'lisp-mode)
(require 'gdev-assurance-db)

;; In Emacs 30 `read-eval' esiste e vale t: con nil `read' rifiuta `#.'.  In
;; Emacs 31 la variabile non c'è più e `#.' non si legge mai: legarla non fa danni.
(defvar read-eval)
(defvar gdev-standards--cache nil "Cache limitata a una singola operazione di lettura.")

(defun gdev-standards-with-cache (function)
  "Esegui FUNCTION condividendo i dati solo per la durata dell'operazione."
  (let ((gdev-standards--cache (or gdev-standards--cache (make-hash-table :test #'equal))))
    (funcall function)))

(define-error 'gdev-standards-error "Dati degli standard non validi" 'gdev-assurance-error)

(defvar gdev-standards-directory
  (expand-file-name
   "docs/assicurazione/"
   (file-name-directory
    (directory-file-name
     (file-name-directory
      (file-truename (or load-file-name (locate-library "gdev-standards") buffer-file-name))))))
  "Cartella dei dati di assicurazione: contiene `standard/' e `profili/'.")

(defconst gdev-standards--statuses '(corrente bozza ritirata da-verificare)
  "Stati ammessi per uno standard del registro.")

(defconst gdev-standards--classes '(aperto pubblico-da-verificare solo-riferimento)
  "Classi di riuso ammesse.")

(defconst gdev-standards--required-keys
  '(:id :titolo :ente :edizione :stato :verificato :fonte :licenza :classe-riuso
    :formati-ufficiali :note)
  "Chiavi che ogni voce del registro deve avere.")

(defun gdev-standards--read (file)
  "Leggi il file di dati FILE senza valutare nulla e restituisci il suo contenuto."
  (unless (file-regular-p file)
    (signal 'gdev-standards-error (list (format "File mancante: %s" file))))
  (condition-case err
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents file))
        (let ((read-eval nil) (read-circle nil))
          (set-syntax-table emacs-lisp-mode-syntax-table)
          (let ((value (read (current-buffer))))
            (forward-comment (buffer-size))
            (unless (eobp) (error "Il file deve contenere un solo dato completo"))
            value)))
    (error (signal 'gdev-standards-error
                   (list (format "%s non si legge come dati: %s"
                                 (file-name-nondirectory file) (error-message-string err)))))))

(defun gdev-standards-read (file)
  "Leggi FILE come dati, una volta sola se una cache di richiesta è attiva."
  (let ((key (expand-file-name file)))
    (if (and gdev-standards--cache (gethash key gdev-standards--cache))
        (car (gethash key gdev-standards--cache))
      (let ((data (gdev-standards--read file)))
        (when gdev-standards--cache (puthash key (list data) gdev-standards--cache))
        data))))

(defun gdev-standards--registry-file ()
  "Restituisci il file del registro."
  (expand-file-name "standard/registro.eld" gdev-standards-directory))

(defun gdev-standards-problems (entries)
  "Restituisci i problemi delle voci ENTRIES del registro: nil se sono valide."
  (let (problems ids)
    (if (not (and (proper-list-p entries) (cl-every #'plistp entries)))
        (push "Il registro non è un elenco di voci" problems)
      (dolist (entry entries)
        (let ((id (plist-get entry :id)))
          (dolist (key gdev-standards--required-keys)
            (unless (plist-member entry key)
              (push (format "%s: manca %s" (or id "voce senza :id") key) problems)))
          (when (and id (member id ids))
            (push (format "%s: identificativo duplicato" id) problems))
          (push id ids)
          (unless (and (stringp id) (not (string-empty-p id)))
            (push "Il registro richiede identificativi testuali non vuoti" problems))
          (unless (memq (plist-get entry :stato) gdev-standards--statuses)
            (push (format "%s: stato non valido" id) problems))
          (unless (memq (plist-get entry :classe-riuso) gdev-standards--classes)
            (push (format "%s: classe di riuso non valida" id) problems)))))
    (nreverse problems)))

(defun gdev-standards-all ()
  "Restituisci le voci del registro, dopo averle controllate."
  (let* ((entries (gdev-standards-read (gdev-standards--registry-file)))
         (problems (gdev-standards-problems entries)))
    (when problems
      (signal 'gdev-standards-error (list (mapconcat #'identity problems "; "))))
    entries))

(defun gdev-standards-get (id)
  "Restituisci la voce del registro con identificativo ID, o nil."
  (cl-find id (gdev-standards-all) :key (lambda (entry) (plist-get entry :id)) :test #'equal))

(defun gdev-standards--sheet-ids (sheets)
  "Restituisci gli identificativi di pratiche e compiti della prima di SHEETS."
  (let (ids)
    (dolist (row (plist-get (car sheets) :righe))
      (dolist (cell (seq-take row 2))
        (let ((start 0))
          (while (string-match "\\([A-Z][A-Z]\\.[0-9]+\\(?:\\.[0-9]+\\)?\\)[):]" (or cell "") start)
            (push (match-string 1 cell) ids)
            (setq start (match-end 0))))))
    (delete-dups ids)))

(defun gdev-standards-data (id)
  "Leggi la materializzazione di ID, se presente e interna al registro."
  (when-let* ((entry (gdev-standards-get id))
              (file (plist-get entry :formato-gdev))
              (directory (expand-file-name "standard/" gdev-standards-directory))
              (path (expand-file-name file directory))
              (safe (or (file-in-directory-p (file-truename path) (file-truename directory))
                         (signal 'gdev-standards-error '("I dati dello standard escono dal registro"))))
              (data (gdev-standards-read path))) data))

(defun gdev-standards-clauses (id)
  "Restituisci i riferimenti di ID presenti nell'indice locale, o nil."
  (when-let* ((data (gdev-standards-data id)))
    (cond ((and (consp data) (plist-member (car data) :foglio)) (gdev-standards--sheet-ids data))
          ((and (consp data) (plist-member (car data) :id))
           (mapcar (lambda (row) (plist-get row :id)) data)))))

(defun gdev-standards-check-reference (reference)
  "Controlla REFERENCE: restituisci un motivo se falso, altrimenti nil.
REFERENCE è (:standard ID :edizione E :clausola C), oppure un riferimento
bibliografico con :ambito standard e senza :clausola."
  (if (not (and (plistp reference) (or (null (plist-get reference :standard))
                                     (stringp (plist-get reference :standard)))
                (stringp (plist-get reference :edizione))
                (or (and (stringp (plist-get reference :clausola))
                         (not (eq (plist-get reference :ambito) 'standard)))
                    (and (eq (plist-get reference :ambito) 'standard)
                         (not (plist-member reference :clausola))))))
      "Il riferimento richiede standard, edizione e clausola testuali"
  (let* ((id (plist-get reference :standard))
         (entry (and (stringp id) (gdev-standards-get id))))
    (cond
     ((null entry) (format "Lo standard %s non è nel registro" id))
     ((not (eq (plist-get entry :stato) 'corrente))
      (format "Lo standard %s non è corrente (%s)" id (plist-get entry :stato)))
     ((not (equal (plist-get entry :edizione) (plist-get reference :edizione)))
      (format "Lo standard %s è all'edizione %s, non %s" id (plist-get entry :edizione)
              (plist-get reference :edizione)))
     ((eq (plist-get reference :ambito) 'standard) nil)
     (t
      (let ((clauses (gdev-standards-clauses id)))
        (cond ((null clauses)
               (format "Lo standard %s non ha dati locali: la clausola %s non si verifica"
                       id (plist-get reference :clausola)))
              ((not (member (plist-get reference :clausola) clauses))
               (format "La clausola %s non esiste in %s %s" (plist-get reference :clausola)
                       id (plist-get entry :edizione))))))))))

(provide 'gdev-standards)
;;; gdev-standards.el ends here
