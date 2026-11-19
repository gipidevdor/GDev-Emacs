;;; gdev-lavorazione-agent.el --- Composizione per agenti locali -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; L'agente legge e modifica il sorgente aperto dalla GUI. Il piano resta
;; un documento JSON e passa dallo stesso validatore del riquadro.

;;; Code:

(require 'gdev-agent-interface)
(require 'gdev-lavorazione-composizione)

(defun gdev-lavorazione-agent--catalogo ()
  "Descrivi il registro e lo schema delle azioni attive in questa istanza."
  (vconcat
   (cl-loop for nome in (sort (hash-table-keys gdev-lavorazione--azioni) #'string<)
            for azione = (gethash nome gdev-lavorazione--azioni)
            collect
            `((name . ,nome)
              (description . ,(gdev-lavorazione--azione-descrizione azione))
              (module . ,(gdev-lavorazione--azione-modulo azione))
              (opens_document . ,(if (gdev-lavorazione--azione-apre-documento azione) t :false))
              (requires_document . ,(if (gdev-lavorazione--azione-richiede-documento azione) t :false))
              (arguments . ,(vconcat
                             (cl-loop for (campo . tipo) in (gdev-lavorazione--azione-schema azione)
                                      collect `((name . ,campo) (type . ,(symbol-name tipo))))))))))

(defun gdev-lavorazione-agent--file (path)
  "Risolvi PATH come file locale di lavorazione."
  (unless (and (gdev-agent-interface--absolute-local-p path)
               (string-suffix-p ".lavorazione" path)
               (not (find-file-name-handler path 'insert-file-contents)))
    (user-error "Indica il percorso locale assoluto di un file .lavorazione"))
  (let ((file (file-truename path)))
    (unless (and (string-suffix-p ".lavorazione" file)
                 (file-directory-p (file-name-directory file))
                 (not (find-file-name-handler file 'insert-file-contents))
                 (not (find-file-name-handler file 'write-region))
                 (or (not (file-exists-p file))
                     (and (file-regular-p file) (file-readable-p file))))
      (user-error "Serve un file .lavorazione leggibile in una cartella locale esistente"))
    file))

(defun gdev-lavorazione-agent--documento (path)
  "Leggi il piano JSON da PATH, senza visitarlo come file."
  (unless (and (gdev-agent-interface--absolute-local-p path)
               (not (find-file-name-handler path 'insert-file-contents))
               (file-regular-p path) (file-readable-p path)
               (<= (file-attribute-size (file-attributes path))
                   (* 4 gdev-lavorazione--limite-caratteri)))
    (user-error "Indica un file JSON locale, leggibile e di al massimo 1 MiB"))
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents path))
    (gdev-lavorazione--leggi)))

(defun gdev-lavorazione-agent--revisione ()
  "Identifica il testo corrente, comprese le modifiche fuori dalla regione."
  (save-restriction
    (widen)
    (secure-hash 'sha256 (current-buffer))))

(defun gdev-lavorazione-agent--stato (file)
  "Descrivi il piano e la revisione della lavorazione FILE già aperta."
  (let ((documento :null)
        (errore :null))
    (condition-case err
        (let ((letto (gdev-lavorazione--leggi)))
          (gdev-lavorazione--piano letto)
          (setq documento letto))
      (user-error (setq errore (error-message-string err))))
    `((path . ,file)
      (revision . ,(gdev-lavorazione-agent--revisione))
      (plan . ,documento)
      (validation_error . ,errore)
      (modified . ,(if (buffer-modified-p) t :false)))))

(defun gdev-lavorazione-agent--aggiorna-vista ()
  "Aggiorna il riquadro aperto conservando il fuoco della sessione."
  (when (buffer-live-p gdev-lavorazione--vista)
    (if-let* ((finestra (get-buffer-window gdev-lavorazione--vista)))
        (with-selected-window finestra (gdev-composizione-aggiorna))
      (with-current-buffer gdev-lavorazione--vista (gdev-composizione-aggiorna)))))

(defun gdev-lavorazione-agent-richiesta (action &optional path revisione dati)
  "Esegui ACTION su PATH, con REVISIONE attesa e DATI JSON se richiesti."
  (if (equal action "lavorazione-catalogo")
      (list (cons 'actions (gdev-lavorazione-agent--catalogo)))
    (let* ((file (gdev-lavorazione-agent--file path))
           (apri (equal action "lavorazione-apri"))
           (sorgente (if apri (gdev-lavorazione--apri-sorgente file)
                       (find-buffer-visiting file))))
      (unless (buffer-live-p sorgente)
        (user-error "Apri prima la lavorazione in Composizione"))
      (with-current-buffer sorgente
        (unless (derived-mode-p 'gdev-lavorazione-mode)
          (user-error "Il file deve usare la modalità Lavorazione"))
        (when (member action '("lavorazione-componi" "lavorazione-salva"))
          (unless (equal revisione (gdev-lavorazione-agent--revisione))
            (user-error "Il sorgente è cambiato. Rileggi la lavorazione prima di modificarla"))
          (unless (verify-visited-file-modtime sorgente)
            (user-error "Il file è cambiato su disco. Controllalo nell'editor"))
          (if (equal action "lavorazione-componi")
              (let* ((versione (buffer-chars-modified-tick))
                     (piano (gdev-lavorazione-agent--documento dati)))
                (gdev-lavorazione--scrivi piano versione)
                (gdev-lavorazione-agent--aggiorna-vista))
            (gdev-lavorazione--piano (gdev-lavorazione--leggi))
            (unless (file-writable-p file)
              (user-error "Il file della lavorazione non è scrivibile"))
            (save-buffer)))
        (let ((stato (gdev-lavorazione-agent--stato file)))
          (when (and apri (hash-table-p (alist-get 'plan stato)))
            (gdev-lavorazione-composizione))
          (list (cons 'composition stato)))))))

(provide 'gdev-lavorazione-agent)
;;; gdev-lavorazione-agent.el ends here
