;;; gdev-drafts.el --- Recupero dei documenti in corso -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Conserva il testo dei documenti in corso nello stato privato della
;; sessione.  Se il file è cambiato su disco, recupera le modifiche in una
;; bozza separata.

;;; Code:

(require 'gdev-layout)

(defgroup gdev-drafts nil
  "Recupero dei documenti in corso."
  :group 'gdev)

(defcustom gdev-drafts-hot-exit t
  "Conserva le bozze locali durante il lavoro e quando esci da GDev."
  :type 'boolean
  :group 'gdev-drafts)

(defun gdev-drafts-toggle-hot-exit ()
  "Attiva o disattiva la conservazione automatica delle bozze."
  (interactive)
  (customize-save-variable 'gdev-drafts-hot-exit (not gdev-drafts-hot-exit))
  (message "%s" (if gdev-drafts-hot-exit
                    "Le bozze si conservano durante il lavoro e all’uscita"
                  "All’uscita verrà chiesto di salvare i documenti")))

(defun gdev-drafts--view-p (draft)
  "Indica se DRAFT conserva il testo di una vista invece che di un documento.
Una vista, come le Preferenze, si ridisegna dal suo stato: recuperata come
testo resterebbe senza pulsanti.  Le sessioni salvate prima del
2026-11-17 possono contenerne."
  (let ((mode (plist-get draft :mode)))
    (and (symbolp mode) (provided-mode-derived-p mode 'special-mode))))

(defun gdev-drafts--key (buffer)
  "Identifica BUFFER se il suo testo può essere conservato in sessione.
Le viste derivate da `special-mode' si ridisegnano e non sono bozze."
  (when (and (buffer-live-p buffer) (buffer-modified-p buffer)
             (not (buffer-base-buffer buffer)))
    (with-current-buffer buffer
      (cond
       ((or buffer-save-without-query (file-remote-p default-directory)
            (derived-mode-p 'special-mode))
        nil)
       (buffer-file-name
        (and (not (file-remote-p buffer-file-name))
             (not (find-file-name-handler buffer-file-name 'write-region))
             buffer-file-name))
       (gdev-layout-document-p
        (list 'bozza (buffer-name)))))))

(defun gdev-drafts--snapshot (buffer)
  "Legge il testo e lo stato di BUFFER senza cambiare il documento."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (list :name (buffer-name) :mode major-mode :directory default-directory
              :file buffer-file-name :modtime (visited-file-modtime)
              :modified (buffer-modified-p) :base64 (not enable-multibyte-characters)
              :text (if enable-multibyte-characters text (base64-encode-string text t)))))))

(defun gdev-drafts--record-p (draft)
  "Indica se DRAFT ha i campi richiesti per recuperare una bozza locale."
  (and (plistp draft)
       (let ((file (plist-get draft :file))
             (directory (plist-get draft :directory)))
         (and (stringp (plist-get draft :name))
              (or (not file)
                  (and (stringp file) (file-name-absolute-p file) (not (file-remote-p file))))
              (or (not directory) (stringp directory))
              (stringp (plist-get draft :text))))))

(defun gdev-drafts--decode-text (draft)
  "Restituisci il testo salvato di DRAFT, decodificando le bozze binarie."
  (let ((text (plist-get draft :text)))
    (if (plist-get draft :base64) (base64-decode-string text) text)))

(defun gdev-drafts--decode-binary-records (drafts)
  "Convalida le bozze binarie in DRAFTS e restituisci i testi decodificati."
  (let ((decoded (make-hash-table :test #'equal)))
    (pcase-dolist (`(,key . ,draft) drafts)
      (when (plist-get draft :base64)
        (condition-case nil
            (puthash key (gdev-drafts--decode-text draft) decoded)
          (error (user-error "Bozza della sessione illeggibile: %s" key)))))
    decoded))

(defun gdev-drafts--file-unchanged-p (file modtime)
  "Controlla se FILE corrisponde alla versione MODTIME della bozza."
  (condition-case nil
      (if-let* ((attributes (file-attributes (file-truename file))))
          (and (consp modtime) (eq (file-attribute-type attributes) nil)
               (time-equal-p modtime (file-attribute-modification-time attributes)))
        (eq modtime -1))
    (file-error nil)))

(defun gdev-drafts--replace-text (text)
  "Inserisci TEXT nell'intero documento della bozza, conservando la restrizione."
  (let ((inhibit-read-only t))
    (save-restriction
      (widen)
      (erase-buffer)
      (insert text))))

(defun gdev-drafts--visit-unopened-file (file)
  "Visita FILE, ancora senza buffer, e scarta un'apertura incompleta."
  (let (buffer)
    (unwind-protect
        (setq buffer (find-file-noselect file))
      (unless (buffer-live-p buffer)
        (let ((inhibit-quit t))
          (with-demoted-errors "Apertura incompleta della sessione: %S"
            (when-let* ((partial (find-buffer-visiting file)))
              (kill-buffer partial))))))))

(defun gdev-drafts--restore (draft &optional decoded-text track-buffer)
  "Carica DRAFT in un buffer, preservando le modifiche già aperte e il disco.
Usa DECODED-TEXT se la bozza binaria è stata già convalidata.
TRACK-BUFFER riceve il buffer scelto e indica se registrarne le modifiche
in un gruppo nativo per poterle annullare."
  (let* ((file (plist-get draft :file))
         (directory (plist-get draft :directory))
         (multibyte (not (plist-get draft :base64)))
         (text (or decoded-text (gdev-drafts--decode-text draft)))
         (visiting (and file (find-buffer-visiting file)))
         (use-file (and file (not (file-remote-p file))
                        (not (find-file-name-handler file 'write-region))
                        (or (not visiting)
                            (and (not (buffer-modified-p visiting))
                                 ;; Cambiare codifica cancella la cronologia nativa.
                                 (or (not track-buffer)
                                     (eq multibyte (buffer-local-value
                                                    'enable-multibyte-characters visiting)))))
                        (gdev-drafts--file-unchanged-p file (plist-get draft :modtime))
                        (or visiting (condition-case nil
                                         (gdev-drafts--visit-unopened-file file)
                                       (file-error nil)))))
         (buffer (or use-file
                   (generate-new-buffer (if file (format "Bozza recuperata · %s" (file-name-nondirectory file))
                                          (plist-get draft :name)))))
         (tracked (and track-buffer (funcall track-buffer buffer))))
    (with-current-buffer buffer
      (unless use-file
        (when (and directory (not (file-remote-p directory)) (file-directory-p directory))
          (setq default-directory directory))
        (let ((mode (plist-get draft :mode)))
          (when (and (symbolp mode) (fboundp mode) (provided-mode-derived-p mode '(prog-mode text-mode)))
            (funcall mode)))
        (setq-local buffer-offer-save 'always)
        (gdev-layout-mark-document))
      (unless (eq enable-multibyte-characters multibyte)
        (set-buffer-multibyte multibyte))
      (if tracked
          (gdev-drafts--replace-text text)
        (let ((buffer-undo-list t)) (gdev-drafts--replace-text text)))
      (set-buffer-modified-p (or (and file (not use-file)) (plist-get draft :modified))))
    buffer))

(provide 'gdev-drafts)
;;; gdev-drafts.el ends here
