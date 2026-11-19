;;; gdev-lavorazione-composizione.el --- Editor dei passi di una lavorazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Il riquadro modifica il documento JSON aperto. La lista rappresenta
;; l'ultima versione letta; prima di scrivere si controlla che quella
;; versione corrisponda ancora al sorgente.

;;; Code:

(require 'gdev-lavorazione)
(require 'gdev-activity)
(require 'button)
(require 'hl-line)

(declare-function gdev-close-document "gdev-commands" ())

(defvar-local gdev-lavorazione--vista nil)
(defvar-local gdev-composizione--sorgente nil)
(defvar-local gdev-composizione--versione nil)
(defvar-local gdev-composizione--selezione nil)
(defvar-local gdev-composizione--righe nil)
(defvar-local gdev-composizione--pulsanti nil)
(defvar-local gdev-composizione--errore nil)
(defvar-local gdev-composizione--esito-mostrato nil)
(defvar-local gdev-composizione--revisione-osservata nil
  "Revisione del sorgente per la quale c'è almeno un esito corrente.")

(defconst gdev-composizione--gruppi-documento
  '((["Aggiungi passo…" gdev-composizione-aggiungi (not gdev-composizione--errore) (:target view)]
     ["Catalogo" gdev-lavorazione-catalogo t (:target view)])
    (["Verifica" gdev-composizione-verifica t (:target view)]
     ["Esito…" gdev-composizione-esito t (:target view)]
     ["Esegui…" gdev-composizione-esegui gdev-composizione--righe (:target view)])
    (["Salva" gdev-composizione-salva (not gdev-composizione--errore) (:target view)]
     ["Sorgente JSON" gdev-composizione-sorgente t (:target view)]
     ["Aggiorna" gdev-composizione-aggiorna t (:target view)])))

(defconst gdev-composizione--gruppi-passo
  '((["Modifica…" gdev-composizione-modifica (gdev-composizione--indice)]
     ["Rimuovi" gdev-composizione-rimuovi (gdev-composizione--indice)])
    (["Sposta su" gdev-composizione-su
      (when-let* ((indice (gdev-composizione--indice))) (> indice 0))]
     ["Sposta giù" gdev-composizione-giu
      (when-let* ((indice (gdev-composizione--indice)))
        (< (1+ indice) (length gdev-composizione--righe)))])))

(defun gdev-composizione--sorgente ()
  "Restituisci il documento associato al riquadro."
  (unless (and (buffer-live-p gdev-composizione--sorgente)
               (with-current-buffer gdev-composizione--sorgente
                 (derived-mode-p 'gdev-lavorazione-mode)))
    (user-error "Il documento della lavorazione non è più aperto"))
  gdev-composizione--sorgente)

(defun gdev-composizione--sorgente-aggiornato ()
  "Restituisci il sorgente se è ancora quello mostrato nel riquadro."
  (let ((sorgente (gdev-composizione--sorgente)))
    (unless (eql gdev-composizione--versione (buffer-chars-modified-tick sorgente))
      (user-error "Il sorgente è cambiato. Usa Aggiorna per rileggere i passi"))
    sorgente))

(defun gdev-composizione--stato-sorgente ()
  "Mostra lo stato del documento senza rileggere il piano."
  (let ((sorgente gdev-composizione--sorgente))
    (when (buffer-live-p sorgente)
      (cond
       ((not (eql gdev-composizione--versione (buffer-chars-modified-tick sorgente)))
        (propertize "Da rileggere · g" 'face 'gdev-ui-status-warning
                    'help-echo "Il JSON è cambiato. Premi g o scegli Aggiorna."))
       ((buffer-modified-p sorgente)
        (propertize "Modifiche da salvare" 'face 'gdev-ui-secondary))))))

(defun gdev-composizione--esito-aggiornato-p (esito)
  "Indica se ESITO appartiene alla revisione del sorgente."
  (and (buffer-live-p gdev-composizione--sorgente)
       (eql (gdev-lavorazione-esito-revisione esito)
            (buffer-chars-modified-tick gdev-composizione--sorgente))))

(defun gdev-composizione--sintesi (esito)
  "Descrivi ESITO con uno stato breve e una faccia semantica."
  (let* ((stato (gdev-lavorazione-esito-stato esito))
         (passo (gdev-lavorazione-esito-passo esito))
         (totale (gdev-lavorazione-esito-totale esito))
         (testo (pcase stato
                  ('valida (format "Valida · %d %s" totale (if (= totale 1) "passo" "passi")))
                  ('non-valida (if passo (format "Non valida · passo %d" passo) "Non valida"))
                  ('completata (format "Completata · %d/%d"
                                       (gdev-lavorazione-esito-completati esito)
                                       (gdev-lavorazione-esito-totale esito)))
                  ('fallita (if passo (format "Interrotta · passo %d" passo) "Interrotta"))
                  ('annullata "Annullata"))))
    (propertize testo 'face (pcase stato
                            ((or 'valida 'completata) 'gdev-ui-status-success)
                            ((or 'non-valida 'fallita) 'gdev-ui-status-warning)
                            (_ 'gdev-ui-secondary)))))

(defun gdev-composizione--intestazione ()
  "Mostra lo stato del sorgente e l'esito dello spazio della finestra."
  (let* ((sorgente gdev-composizione--sorgente)
         ;; In una forma :eval Emacs seleziona la finestra che sta disegnando.
         (esito (and (buffer-live-p sorgente)
                     (gdev-lavorazione-ultimo-esito sorgente)))
         (stato (gdev-composizione--stato-sorgente))
         (corrente (and esito (gdev-composizione--esito-aggiornato-p esito)))
         (sintesi (when esito
                    (if corrente
                        (gdev-composizione--sintesi esito)
                      (propertize "Esito precedente" 'face 'gdev-ui-secondary))))
         (ordine (if (and corrente (eql gdev-composizione--versione
                                        (gdev-lavorazione-esito-revisione esito)))
                     (list sintesi stato)
                   (list stato sintesi))))
    (when (or stato sintesi)
      (string-join (delq nil ordine) "  ·  "))))

(defun gdev-composizione--indice ()
  "Restituisci la riga attiva o l'ultima selezione."
  (or (get-text-property (line-beginning-position) 'gdev-composizione-indice)
      gdev-composizione--selezione))

(defun gdev-composizione--indice-riletto (piano)
  "Ritrova nel PIANO il passo selezionato prima di rileggere il sorgente."
  (when-let* ((indice (gdev-composizione--indice))
              (inizio (nth indice gdev-composizione--righe))
              (passo (get-text-property inizio 'gdev-composizione-passo)))
    (if (equal passo (nth indice piano))
        indice
      (or (cl-position passo piano :test #'equal) indice))))

(defun gdev-composizione--seleziona (indice)
  "Sposta il punto sulla riga INDICE se è presente."
  (when (and indice gdev-composizione--righe)
    (let* ((index (min (max 0 indice) (1- (length gdev-composizione--righe))))
           (position (nth index gdev-composizione--righe)))
      (setq gdev-composizione--selezione index)
      (goto-char position)
      (gdev-composizione--aggiorna-pulsanti))))

(defun gdev-composizione--ricorda-selezione ()
  "Mantieni la riga attiva quando il fuoco passa a un pulsante."
  (when-let* ((indice (get-text-property (line-beginning-position) 'gdev-composizione-indice)))
    (unless (eql indice gdev-composizione--selezione)
      (setq gdev-composizione--selezione indice)
      (gdev-composizione--aggiorna-pulsanti))))

(defun gdev-composizione--evidenziazione ()
  "Restituisci l'intera riga selezionata, anche col fuoco sui pulsanti."
  (when-let* ((indice (gdev-composizione--indice))
              (inizio (nth indice gdev-composizione--righe)))
    (save-excursion
      (goto-char inizio)
      (cons inizio (line-beginning-position 2)))))

(defun gdev-composizione--aggiorna-pulsanti ()
  "Applica ai pulsanti le condizioni del menu per la riga corrente."
  (with-silent-modifications
    (pcase-dolist (`(,pulsante ,condizione ,faccia) gdev-composizione--pulsanti)
      (let ((abilitato (eval condizione t)))
        (button-put pulsante 'face (if abilitato faccia 'gdev-ui-secondary))
        (button-put pulsante 'mouse-face (if abilitato 'gdev-ui-side-hover 'gdev-ui-secondary))
        (button-put pulsante 'skip (not abilitato))))))

(defun gdev-composizione--barra (voci &optional primario)
  "Inserisci i pulsanti delle VOCI e metti in evidenza PRIMARIO."
  (dolist (voce voci)
    (unless (bolp) (insert "  "))
    (let* ((etichetta (aref voce 0))
           (comando (aref voce 1))
           (condizione (aref voce 2))
           (faccia (if (eq comando primario) 'gdev-ui-action-primary 'gdev-ui-action))
           (pulsante
            (insert-text-button etichetta 'type 'gdev-ui-action 'face faccia 'help-echo etichetta
                                'gdev-composizione-comando comando
                                'action (lambda (_)
                                          (when (eval condizione t)
                                            (call-interactively comando))))))
      (unless (eq condizione t)
        (push (list pulsante condizione faccia) gdev-composizione--pulsanti))))
  (insert "\n"))

(defun gdev-composizione--valore (valore)
  "Mostra una sintesi su una sola riga di VALORE."
  (let ((print-escape-newlines t) (print-escape-control-characters t))
    (if (and (stringp valore) (> (length valore) 42))
        (concat (prin1-to-string (substring valore 0 42)) "…")
      (prin1-to-string valore))))

(defun gdev-composizione--nome-sorgente ()
  "Prepara il nome del sorgente, con il percorso completo nel suggerimento."
  (let* ((nome (buffer-name gdev-composizione--sorgente))
         (finestra (or (get-buffer-window (current-buffer))
                       (gdev-layout-auxiliary-window)))
         (colonne (if finestra (window-body-width finestra) gdev-layout--commands-min-width)))
    (propertize
     (if (display-graphic-p)
         (gdev-ui-fit-file-name
          nome (max 1 (- (if finestra (window-body-width finestra t)
                           (* colonne (frame-char-width))) 6))
          #'gdev-ui-string-pixel-width)
       (truncate-string-to-width nome colonne nil nil "…"))
     'face 'gdev-ui-secondary
     'help-echo (or (buffer-file-name gdev-composizione--sorgente) nome))))

(defun gdev-composizione--dettaglio (esito)
  "Inserisci il passo e il messaggio disponibili in ESITO."
  (when-let* ((passo (gdev-lavorazione-esito-passo esito)))
    (insert (propertize (format "Passo %d" passo) 'face 'gdev-ui-view-heading))
    (when-let* ((azione (gdev-lavorazione-esito-azione esito)))
      (insert " · " azione))
    (insert "\n"))
  (when-let* ((messaggio (gdev-lavorazione-esito-messaggio esito)))
    (insert messaggio "\n")))

(defun gdev-composizione--render (piano versione indice &optional errore)
  "Disegna PIANO alla VERSIONE letta e seleziona INDICE.
Con ERRORE mostra il problema di validazione e le azioni di recupero."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq gdev-composizione--righe nil
          gdev-composizione--selezione nil
          gdev-composizione--pulsanti nil
          gdev-composizione--errore errore
          gdev-composizione--versione versione)
    (insert (propertize "Composizione" 'face 'gdev-ui-view-title) "\n"
            (gdev-composizione--nome-sorgente) "\n\n")
    (dolist (gruppo gdev-composizione--gruppi-documento)
      (gdev-composizione--barra
       (if piano gruppo
         (seq-remove (lambda (voce) (eq (aref voce 1) 'gdev-composizione-esegui)) gruppo))
       (if piano 'gdev-composizione-esegui 'gdev-composizione-aggiungi)))
    (insert "\n")
    (cond
     (errore
      (insert (propertize "Piano da correggere" 'face 'gdev-ui-status-warning) "\n")
      (gdev-composizione--dettaglio errore)
      (insert (propertize "Correggi il sorgente JSON e aggiorna." 'face 'gdev-ui-secondary) "\n"))
     ((not piano)
      (insert (propertize "Nessun passo. Scegli un'azione dal catalogo."
                          'face 'gdev-ui-secondary) "\n"))
     (t
      (insert (propertize (format "Passi · %d" (length piano)) 'face 'gdev-ui-view-heading) "\n")
      (dolist (gruppo gdev-composizione--gruppi-passo)
        (gdev-composizione--barra gruppo))
      (insert "\n")
      (cl-loop for (azione . valori) in piano
               for index from 0
               do
               (let ((inizio (point)) (riga index))
                 (push inizio gdev-composizione--righe)
                 (insert (format "%d. %s" (1+ index) (gdev-lavorazione--azione-nome azione)))
                 (let ((titolo-fine (point)))
                   (cl-loop for (campo . _) in (gdev-lavorazione--azione-schema azione)
                            for valore in valori
                            do (insert "   " (propertize
                                              (format "%s %s" campo (gdev-composizione--valore valore))
                                              'face 'gdev-ui-secondary
                                              'help-echo (prin1-to-string valore))))
                   (make-text-button inizio (point) 'type 'gdev-ui-action
                                     'action (lambda (_) (gdev-composizione--seleziona riga)))
                   (put-text-property inizio titolo-fine 'help-echo
                                      (gdev-lavorazione--azione-descrizione azione)))
                 (insert "\n")
                 (put-text-property inizio (1+ inizio) 'gdev-composizione-passo
                                    (cons azione valori))
                 (put-text-property inizio (point) 'gdev-composizione-indice index)))
      (setq gdev-composizione--righe (nreverse gdev-composizione--righe))))
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (when gdev-composizione--righe (setq gdev-composizione--selezione 0))
    (if (and indice gdev-composizione--righe)
        (gdev-composizione--seleziona indice)
      (gdev-composizione--aggiorna-pulsanti)
      (when-let* ((pulsante (next-button (point)))) (goto-char (button-start pulsante))))))

(defun gdev-composizione-aggiorna ()
  "Rileggi il JSON, mostra il piano o il problema e indica se è valido."
  (interactive)
  (pcase-let* ((`(,piano . ,esito) (gdev-lavorazione-analizza (gdev-composizione--sorgente)))
               (valido (eq (gdev-lavorazione-esito-stato esito) 'valida)))
    (gdev-composizione--render piano (gdev-lavorazione-esito-revisione esito)
                               (gdev-composizione--indice-riletto piano)
                               (unless valido esito))
    valido))

(defun gdev-composizione--cambia (azione)
  "Applica AZIONE alla riga selezionata e valida l'intero risultato."
  (let* ((sorgente (gdev-composizione--sorgente-aggiornato))
         (versione gdev-composizione--versione)
         (indice (gdev-composizione--indice))
         (documento (with-current-buffer sorgente (gdev-lavorazione--leggi)))
         (passi (gethash "passi" documento))
         (numero (length passi))
         (piano (gdev-lavorazione--piano documento))
         (nuovo-indice indice))
    (unless (or (eq azione 'aggiungi) (and indice (< indice numero)))
      (user-error "Seleziona un passo"))
    (pcase azione
      ('aggiungi
       (when (>= numero 128) (user-error "La lavorazione ha già 128 passi"))
       (setq passi (vconcat passi (vector (gdev-lavorazione--leggi-passo piano)))
             nuovo-indice numero))
      ('modifica
       (aset passi indice (gdev-lavorazione--leggi-passo
                           (seq-take piano indice) (aref passi indice))))
      ('rimuovi
       (setq passi (vconcat (seq-subseq passi 0 indice) (seq-subseq passi (1+ indice)))))
      ((or 'su 'giu)
       (setq nuovo-indice (+ indice (if (eq azione 'su) -1 1)))
       (unless (<= 0 nuovo-indice (1- numero)) (user-error "Il passo è già al limite"))
       (cl-rotatef (aref passi indice) (aref passi nuovo-indice))))
    (puthash "passi" passi documento)
    (unless (buffer-live-p sorgente) (user-error "Il sorgente è stato chiuso"))
    (let ((risultato
           (with-current-buffer sorgente
             (let ((nuovo-piano (gdev-lavorazione--scrivi documento versione)))
               (cons (buffer-chars-modified-tick) nuovo-piano)))))
      (gdev-composizione--render (cdr risultato) (car risultato) nuovo-indice))))

(defun gdev-composizione-aggiungi () "Aggiungi un passo." (interactive) (gdev-composizione--cambia 'aggiungi))
(defun gdev-composizione-modifica () "Modifica il passo." (interactive) (gdev-composizione--cambia 'modifica))
(defun gdev-composizione-rimuovi () "Rimuovi il passo." (interactive) (gdev-composizione--cambia 'rimuovi))
(defun gdev-composizione-su () "Sposta il passo prima." (interactive) (gdev-composizione--cambia 'su))
(defun gdev-composizione-giu () "Sposta il passo dopo." (interactive) (gdev-composizione--cambia 'giu))

(defun gdev-composizione-successivo ()
  "Seleziona il passo successivo."
  (interactive)
  (gdev-composizione--seleziona (1+ (or (gdev-composizione--indice) -1))))

(defun gdev-composizione-precedente ()
  "Seleziona il passo precedente."
  (interactive)
  (gdev-composizione--seleziona (1- (or (gdev-composizione--indice) 1))))

(defun gdev-composizione-salva ()
  "Valida e salva il sorgente della lavorazione."
  (interactive)
  (unless (gdev-composizione-aggiorna)
    (user-error "Correggi il piano prima di salvarlo dalla composizione"))
  (with-current-buffer (gdev-composizione--sorgente) (save-buffer)))

(defun gdev-composizione-sorgente ()
  "Mostra il documento JSON della lavorazione."
  (interactive)
  (let* ((sorgente (gdev-composizione--sorgente))
         (finestra (get-buffer-window sorgente (selected-frame))))
    (if (and (window-live-p finestra) (not (window-parameter finestra 'window-side)))
        (select-window finestra)
      (pop-to-buffer sorgente))))

(defun gdev-composizione-esegui ()
  "Esegui i passi mostrati dopo aver confermato la cartella di lavoro."
  (interactive)
  (unless gdev-composizione--righe (user-error "Aggiungi almeno un passo"))
  (with-current-buffer (gdev-composizione--sorgente-aggiornato)
    (gdev-lavorazione-esegui)))

(defun gdev-composizione-verifica ()
  "Controlla il piano mostrato senza eseguirlo."
  (interactive)
  (with-current-buffer (gdev-composizione--sorgente-aggiornato)
    (gdev-lavorazione-verifica)))

(defun gdev-composizione--puo-raggiungere-passo ()
  "Indica se si può mostrare il passo indicato nell'esito."
  (let ((esito gdev-composizione--esito-mostrato))
    (and esito
         (memq (gdev-lavorazione-esito-stato esito) '(fallita annullata))
         (gdev-lavorazione-esito-passo esito)
         (gdev-composizione--esito-aggiornato-p esito))))

(defun gdev-composizione-riprendi ()
  "Torna dall'esito alla composizione della stessa lavorazione."
  (interactive)
  (gdev-lavorazione-composizione (gdev-composizione--sorgente)))

(defun gdev-composizione-vai-al-passo ()
  "Seleziona il passo indicato nell'esito della revisione corrente."
  (interactive)
  (unless (gdev-composizione--puo-raggiungere-passo)
    (user-error "Nessun passo da raggiungere nella revisione corrente"))
  (let ((indice (1- (gdev-lavorazione-esito-passo gdev-composizione--esito-mostrato))))
    (gdev-composizione-riprendi)
    (gdev-composizione--seleziona indice)))

(defconst gdev-composizione--azioni-esito
  '(["Composizione" gdev-composizione-riprendi
     (buffer-live-p gdev-composizione--sorgente) (:target view)]
    ["Sorgente JSON" gdev-composizione-sorgente
     (buffer-live-p gdev-composizione--sorgente) (:target view)]
    ["Vai al passo" gdev-composizione-vai-al-passo
     (gdev-composizione--puo-raggiungere-passo) (:target view)]))

(defvar-keymap gdev-composizione-esito-mode-map
  "b" #'gdev-composizione-riprendi
  "C-c C-e" #'gdev-composizione-sorgente
  "p" #'gdev-composizione-vai-al-passo
  "q" #'gdev-close-document)

(define-derived-mode gdev-composizione-esito-mode special-mode "Esito"
  "Consulta l'esito della lavorazione nello spazio attivo."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local gdev-context-items gdev-composizione--azioni-esito)
  (add-hook 'window-buffer-change-functions #'gdev-composizione--riprendi-esito nil t))

(defun gdev-composizione--render-esito (sorgente esito &optional conserva)
  "Mostra ESITO per SORGENTE. Con CONSERVA mantieni il punto nel rapporto."
  (let* ((inhibit-read-only t)
         (punto (if conserva (point) (point-min)))
         (comando (and conserva (get-text-property punto 'gdev-composizione-comando))))
    (erase-buffer)
    (setq gdev-composizione--sorgente sorgente
          gdev-composizione--esito-mostrato esito
          gdev-composizione--pulsanti nil
          default-directory (buffer-local-value 'default-directory sorgente))
    (insert (propertize "Esito della lavorazione" 'face 'gdev-ui-view-title) "\n"
            (gdev-composizione--nome-sorgente) "\n\n")
    (gdev-composizione--barra (butlast gdev-composizione--azioni-esito))
    (when (gdev-composizione--puo-raggiungere-passo)
      (gdev-composizione--barra (last gdev-composizione--azioni-esito)))
    (insert "\n")
    (cond
     ((null esito)
      (insert (propertize "Nessuna verifica o esecuzione in questo spazio."
                          'face 'gdev-ui-secondary) "\n"))
     (t
      (insert (gdev-composizione--sintesi esito) "\n")
      (if (gdev-composizione--esito-aggiornato-p esito)
          (with-current-buffer sorgente
            (setq gdev-composizione--revisione-osservata (buffer-chars-modified-tick))
            (add-hook 'after-change-functions #'gdev-composizione--invalida-esiti nil t))
        (insert (propertize "L’esito riguarda una revisione precedente."
                            'face 'gdev-ui-status-warning) "\n"))
      (when-let* ((radice (gdev-lavorazione-esito-radice esito)))
        (insert (propertize "Cartella di lavoro" 'face 'gdev-ui-view-heading)
                "\n" (abbreviate-file-name radice) "\n"))
      (when-let* ((completati (gdev-lavorazione-esito-completati esito)))
        (insert (propertize (format "Passi completati · %d di %d"
                                   completati (gdev-lavorazione-esito-totale esito))
                            'face 'gdev-ui-secondary) "\n"))
      (gdev-composizione--dettaglio esito)))
    (set-buffer-modified-p nil)
    (goto-char (if comando
                   (or (text-property-any (point-min) (point-max) 'gdev-composizione-comando comando)
                       (point-min))
                 (min punto (point-max))))
    (gdev-composizione--aggiorna-pulsanti)))

(defun gdev-composizione--per-esito (funzione &optional tutte)
  "Applica FUNZIONE alle viste del sorgente corrente con la loro cornice.
Con TUTTE includi anche le schede inattive."
  (let ((sorgente (current-buffer)))
    (dolist (cornice (frame-list))
      (dolist (tab (if tutte (gdev-workspace-state-tabs cornice)
                     (list (gdev-workspace-state-current cornice))))
        (when-let* ((vista (alist-get 'lavorazione-esito
                                     (gdev-workspace-state-read 'gdev-activity-buffers tab)))
                    ((buffer-live-p vista))
                    ((eq sorgente (buffer-local-value 'gdev-composizione--sorgente vista))))
          (with-current-buffer vista
            (funcall funzione cornice)))))))

(defun gdev-composizione--sincronizza-esito (cornice)
  "Allinea l'esito mostrato alla scheda attiva in CORNICE."
  (when (buffer-live-p gdev-composizione--sorgente)
    (let ((esito (gdev-lavorazione-ultimo-esito gdev-composizione--sorgente cornice)))
      (unless (eq esito gdev-composizione--esito-mostrato)
        (gdev-composizione--render-esito gdev-composizione--sorgente esito t)))))

(defun gdev-composizione--riprendi-esito (finestra)
  "Aggiorna il rapporto quando torna visibile in FINESTRA."
  (when (eq (window-buffer finestra) (current-buffer))
    (gdev-composizione--sincronizza-esito (window-frame finestra))))

(defun gdev-composizione--invalida-esiti (&rest _)
  "Al primo cambiamento del sorgente, contrassegna i suoi esiti precedenti."
  (let ((revisione gdev-composizione--revisione-osservata))
    (unless (eql revisione (buffer-chars-modified-tick))
      (setq gdev-composizione--revisione-osservata nil)
      (remove-hook 'after-change-functions #'gdev-composizione--invalida-esiti t)
      (gdev-composizione--per-esito
       (lambda (_)
         (when (and gdev-composizione--esito-mostrato
                    (eql revisione (gdev-lavorazione-esito-revisione gdev-composizione--esito-mostrato)))
           (gdev-composizione--render-esito gdev-composizione--sorgente
                                           gdev-composizione--esito-mostrato t)))
       t))))

(defun gdev-composizione-esito ()
  "Mostra l'ultima verifica o esecuzione della lavorazione nello spazio attivo."
  (interactive)
  (let* ((sorgente (gdev-composizione--sorgente))
         (esito (gdev-lavorazione-ultimo-esito sorgente))
         (vista (gdev-activity-buffer 'lavorazione-esito "*Esito della lavorazione*"
                                    #'gdev-composizione-esito-mode)))
    (with-current-buffer vista
      ;; Il registro delle viste resta responsabile del ciclo di vita.
      ;; L'esito occupa lo slot ausiliario della composizione.
      (setq-local gdev-activity-kind nil)
      (gdev-composizione--render-esito sorgente esito))
    (pop-to-buffer vista)))

(defvar-keymap gdev-composizione-mode-map
  "a" #'gdev-composizione-aggiungi
  "e" #'gdev-composizione-modifica
  "d" #'gdev-composizione-rimuovi
  "n" #'gdev-composizione-successivo
  "p" #'gdev-composizione-precedente
  "<down>" #'gdev-composizione-successivo
  "<up>" #'gdev-composizione-precedente
  "M-<up>" #'gdev-composizione-su
  "M-<down>" #'gdev-composizione-giu
  "g" #'gdev-composizione-aggiorna
  "c" #'gdev-lavorazione-catalogo
  "v" #'gdev-composizione-verifica
  "?" #'gdev-composizione-esito
  "C-c C-v" #'gdev-composizione-verifica
  "C-c C-c" #'gdev-composizione-esegui
  "C-c C-e" #'gdev-composizione-sorgente
  "C-x C-s" #'gdev-composizione-salva
  "s-s" #'gdev-composizione-salva
  "q" #'gdev-close-document)

(define-derived-mode gdev-composizione-mode special-mode "Composizione"
  "Editor dei passi della lavorazione corrente."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1)
  (setq-local hl-line-face 'gdev-ui-side-selection
              hl-line-range-function #'gdev-composizione--evidenziazione
              header-line-format '(:eval (gdev-composizione--intestazione))
              gdev-context-items (apply #'append (append gdev-composizione--gruppi-documento
                                                        gdev-composizione--gruppi-passo))
              cursor-type nil)
  (add-hook 'post-command-hook #'gdev-composizione--ricorda-selezione nil t)
  (hl-line-mode 1))

(defun gdev-composizione--chiudi-buffer-ausiliario (vista)
  "Rilascia VISTA e chiudi le sue finestre ausiliarie."
  (dolist (finestra (get-buffer-window-list vista nil t))
    (when (or (window-parameter finestra 'gdev-layout-auxiliary)
              (window-parameter finestra 'gdev-layout-panel))
      (with-selected-window finestra
        (gdev-layout-close-auxiliary vista))))
  (kill-buffer vista))

(defun gdev-composizione--chiudi-vista ()
  "Rilascia la composizione e gli esiti quando si chiude il sorgente."
  (when (buffer-live-p gdev-lavorazione--vista)
    (gdev-composizione--chiudi-buffer-ausiliario gdev-lavorazione--vista))
  (gdev-composizione--per-esito
   (lambda (_) (gdev-composizione--chiudi-buffer-ausiliario (current-buffer)))
   t))

(defun gdev-composizione--aggiorna-esiti ()
  "Aggiorna il riepilogo e i rapporti quando il motore pubblica un esito."
  (when (buffer-live-p gdev-lavorazione--vista)
    (force-mode-line-update t))
  (gdev-composizione--per-esito #'gdev-composizione--sincronizza-esito))

(defun gdev-lavorazione-composizione (&optional sorgente)
  "Apri l'editor visivo di SORGENTE o della lavorazione corrente."
  (interactive)
  (let ((sorgente (or sorgente (current-buffer))) vista)
    (unless (buffer-live-p sorgente) (user-error "Apri un file .lavorazione"))
    (with-current-buffer sorgente
      (unless (derived-mode-p 'gdev-lavorazione-mode)
        (user-error "Apri un file .lavorazione"))
      (unless (buffer-live-p gdev-lavorazione--vista)
        (let ((cartella default-directory))
          (setq gdev-lavorazione--vista (generate-new-buffer
                                        (format "*Composizione · %s*" (buffer-name))))
          (add-hook 'kill-buffer-hook #'gdev-composizione--chiudi-vista nil t)
          (add-hook 'gdev-lavorazione-esito-hook #'gdev-composizione--aggiorna-esiti nil t)
          (with-current-buffer gdev-lavorazione--vista
            (gdev-composizione-mode)
            (setq gdev-composizione--sorgente sorgente
                  default-directory cartella))))
      (setq vista gdev-lavorazione--vista))
    (with-current-buffer vista (gdev-composizione-aggiorna))
    (pop-to-buffer vista)))

(provide 'gdev-lavorazione-composizione)
;;; gdev-lavorazione-composizione.el ends here
