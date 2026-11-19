;;; gdev-dialog.el --- Dialoghi di Emacs in italiano -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Localizza i testi nelle conferme, negli avvisi e nei selettori di file.
;; Le etichette sono indipendenti dai valori restituiti ai comandi.

;;; Code:

(require 'subr-x)

(defconst gdev-dialog--labels
  '(("Yes" . "Sì") ("No" . "No") ("Cancel" . "Annulla")
    ("Abort" . "Annulla") ("Continue" . "Continua") ("Retry" . "Riprova")
    ("Close" . "Chiudi") ("Quit" . "Esci")
    ("Save" . "Salva") ("Save All" . "Salva tutto")
    ("Save All Files" . "Salva tutti i file") ("Save All Buffers" . "Salva tutti i documenti")
    ("Save This But No More" . "Salva solo questo")
    ("Do This But No More" . "Solo questo") ("Do All" . "Applica a tutti")
    ("No For All" . "Salta tutti") ("Close Without Saving" . "Chiudi senza salvare")
    ("View This Buffer" . "Mostra questo documento") ("View Changes" . "Mostra le modifiche")
    ("Unsaved Buffers" . "Documenti con modifiche da salvare")
    ("Really exit Emacs?" . "Uscire da GDev-Emacs?")
    ("Really restart Emacs?" . "Riavviare GDev-Emacs?")
    ("Modified buffers exist; exit anyway?" . "Ci sono modifiche non salvate. Uscire comunque?")
    ("Active processes exist; kill them and exit anyway?" . "Ci sono processi attivi. Interromperli e uscire?")
    ("File has changed on disk; really edit the buffer?" . "Il file è cambiato sul disco. Modificare comunque il documento?")
    ("Buffer has been auto-saved recently.  Revert from auto-save file?" . "È disponibile un salvataggio automatico recente. Ripristinarlo?")
    ("Find file:" . "Apri file:") ("Find file in other window:" . "Apri file nell'altro gruppo:")
    ("Find file in other frame:" . "Apri file in un'altra finestra:")
    ("Find alternate file:" . "Apri un file al posto di questo:")
    ("Find file literally:" . "Apri file senza conversioni:")
    ("Open File" . "Apri file") ("Select File to Load" . "Scegli il file da caricare")
    ("Find directory:" . "Apri cartella:") ("Select directory:" . "Scegli cartella:")
    ("Dired (directory):" . "Apri cartella:") ("Open Directory" . "Apri cartella")
    ("Write file:" . "Salva con nome:") ("Save As" . "Salva con nome")
    ("File to save in:" . "Salva nel file:") ("Load file:" . "Carica file:")
    ("Insert file:" . "Inserisci file:") ("Create empty file:" . "Crea file vuoto:")
    ("Make directory:" . "Crea cartella:") ("Delete file:" . "Elimina file:")
    ("Move file to trash:" . "Sposta nel Cestino:")
    ("Rename visited file to:" . "Rinomina file in:") ("Set visited file name:" . "Assegna un nome al file:")))

(defconst gdev-dialog--patterns
  '(("File [‘\x60']\\(.+\\)['’] exists; overwrite\\?" . "«\\1» esiste già. Sostituirlo?")
    ("Directory [‘\x60']\\(.+\\)['’] does not exist; create\\?" . "La cartella «\\1» manca. Crearla?")
    ("Kill and replace buffer [‘\x60']\\(.+\\)['’] without saving it\\?" . "Chiudere e sostituire «\\1» senza salvare?")
    ("Save file \\(.+\\) (buffer \\(.+\\))\\?" . "Salvare «\\1» dal documento «\\2»?")
    ("Save file \\(.+\\)\\?" . "Salvare il file «\\1»?")
    ("Save buffer \\(.+\\)\\?" . "Salvare il documento «\\1»?")
    ("\\(.+\\) has changed since visited or saved\\. +Save anyway\\?" . "«\\1» è cambiato sul disco. Salvare comunque?")
    ("File \\(.+\\) changed on disk\\. +Discard your edits\\?" . "«\\1» è cambiato sul disco. Scartare le modifiche locali?")
    ("File \\(.+\\) changed on disk\\. +Discard your edits in \\(.+\\)\\?" . "«\\1» è cambiato sul disco. Scartare le modifiche a «\\2»?")
    ("File \\(.+\\) changed on disk\\. +Reread from disk\\?" . "«\\1» è cambiato sul disco. Ricaricarlo?")
    ("File \\(.+\\) changed on disk\\. +Reread from disk into \\(.+\\)\\?" . "«\\1» è cambiato sul disco. Ricaricarlo in «\\2»?")
    ("\\(.+\\) changed on disk; really edit the buffer\\?" . "«\\1» è cambiato sul disco. Modificare comunque il documento?")
    ("Discard edits and reread from \\(.+\\)\\?" . "Scartare le modifiche e ricaricare «\\1» dal disco?")
    ("Revert buffer from file \\(.+\\)\\?" . "Ricaricare il documento da «\\1»?")
    ("Recover auto save file \\(.+\\)\\?" . "Ripristinare il salvataggio automatico di «\\1»?")
    ("Recover \\(.+\\)\\?" . "Recuperare «\\1»?")
    ("File \\(.+\\) is write-protected; try to save anyway\\?" . "«\\1» è protetto da scrittura. Tentare comunque il salvataggio?")
    ("Buffer \\(.+\\) does not end in newline\\. +Add one\\?" . "«\\1» termina senza un ritorno a capo. Aggiungerlo?")
    ("A buffer is visiting \\(.+\\); proceed\\?" . "«\\1» è già aperto. Continuare?")
    ("Really want to delete \\(.+\\)\\?" . "Eliminare «\\1»?")
    ("Kill buffer of \\(.+\\), too\\?" . "Chiudere anche il documento di «\\1»?")))

(defun gdev-dialog--text (text)
  "Traduci TEXT quando è un messaggio noto del dialogo."
  (if (not (stringp text)) text
    (let* ((prompt (string-trim-right text))
           (case-fold-search nil)
           (translation
            (or (cdr (assoc prompt gdev-dialog--labels))
                (save-match-data
                  (catch 'translated
                    (dolist (entry gdev-dialog--patterns)
                      (when (string-match (concat "\\`" (car entry) "\\'") prompt)
                        (throw 'translated (replace-match (cdr entry) t nil prompt)))))))))
      (if translation (concat translation (substring text (length prompt))) text))))

(defun gdev-dialog--prompt-args (arguments)
  "Traduci il testo iniziale di ARGUMENTS, conservando gli altri dati."
  (cons (gdev-dialog--text (car arguments)) (cdr arguments)))

(defun gdev-dialog--item (item)
  "Traduci l'etichetta di ITEM conservando il valore e i separatori."
  (if (consp item)
      (cons (gdev-dialog--text (car item)) (cdr item))
    (gdev-dialog--text item)))

(defun gdev-dialog--popup-args (arguments)
  "Traduci i testi passati a `x-popup-dialog' in ARGUMENTS."
  (let ((contents (cadr arguments)))
    (if (consp contents)
        (cons (car arguments) (cons (mapcar #'gdev-dialog--item contents) (cddr arguments)))
      arguments)))

(defun gdev-dialog--yes-or-no (ask prompt)
  "Usa il dialogo italiano se opportuno e altrimenti delega ad ASK."
  (let ((prompt (gdev-dialog--text prompt)))
    ;; Il ramo grafico della primitiva C non passa per il simbolo Lisp
    ;; `x-popup-dialog'. Qui lo invochiamo con gli stessi valori di risposta.
    (if (and (not noninteractive) (display-graphic-p) (use-dialog-box-p))
        (x-popup-dialog t (list prompt '("Sì" . t) '("No" . nil)))
      (funcall ask prompt))))

(dolist (function '(y-or-n-p message-box message-or-box x-file-dialog))
  (advice-add function :filter-args #'gdev-dialog--prompt-args))
(when (fboundp 'ns-read-file-name)
  (advice-add 'ns-read-file-name :filter-args #'gdev-dialog--prompt-args))
(advice-add 'x-popup-dialog :filter-args #'gdev-dialog--popup-args)
(advice-add 'yes-or-no-p :around #'gdev-dialog--yes-or-no)

(provide 'gdev-dialog)
;;; gdev-dialog.el ends here
