;;; gdev-agent-cursors.el --- Cursori per agenti nella sessione GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Ogni agente dispone dei propri punti di inserimento nel documento.
;; I marker seguono le modifiche di Emacs e gli overlay li rendono
;; visibili senza cambiare il cursore o la selezione di chi usa l'editor.

;;; Code:

(require 'gdev-agent-interface)
(require 'gdev-ui)

(defface gdev-agent-cursor
  '((t :inherit gdev-ui-action :underline t))
  "Punto di inserimento di un agente."
  :group 'gdev-ui)

(defvar-local gdev-agent-cursors--groups nil)
(defvar-local gdev-agent-cursors--buffer-id nil)
(defvar gdev-agent-cursors--serial 0)
(defvar gdev-agent-cursors--defer-refresh nil)

(defun gdev-agent-cursors--revision ()
  "Identifica il documento aperto e la sua revisione testuale."
  (unless gdev-agent-cursors--buffer-id
    (setq gdev-agent-cursors--buffer-id
          (format "%s-%s-%s" (emacs-pid) (time-convert nil 'integer)
                  (cl-incf gdev-agent-cursors--serial))))
  (format "%s:%s" gdev-agent-cursors--buffer-id (buffer-chars-modified-tick)))

(defun gdev-agent-cursors--refresh (&rest _)
  "Allinea gli indicatori ai marker dopo una modifica del testo."
  (unless gdev-agent-cursors--defer-refresh
    (save-restriction
      (widen)
      (dolist (group gdev-agent-cursors--groups)
        (dolist (cursor (cdr group))
          (let* ((pos (marker-position (overlay-get cursor 'gdev-agent-marker)))
                 (eol (or (= pos (point-max)) (eq (char-after pos) ?\n)))
                 (end (if eol pos (1+ pos))))
            (unless (and (= pos (overlay-start cursor)) (= end (overlay-end cursor)))
              (move-overlay cursor pos end))
            (unless (eq eol (overlay-get cursor 'gdev-agent-eol))
              (overlay-put cursor 'gdev-agent-eol eol)
              (overlay-put cursor 'after-string
                           (and eol (propertize "▏" 'face 'gdev-agent-cursor
                                                'help-echo (overlay-get cursor 'help-echo)))))))))))

(defun gdev-agent-cursors--clear (agent)
  "Rimuovi i cursori di AGENT nel documento corrente."
  (dolist (cursor (cdr (assoc agent gdev-agent-cursors--groups)))
    (set-marker (overlay-get cursor 'gdev-agent-marker) nil)
    (delete-overlay cursor))
  (setq gdev-agent-cursors--groups (assoc-delete-all agent gdev-agent-cursors--groups))
  (unless gdev-agent-cursors--groups
    (remove-hook 'after-change-functions #'gdev-agent-cursors--refresh t)
    (remove-hook 'change-major-mode-hook #'gdev-agent-cursors-clear-buffer t)))

;;;###autoload
(defun gdev-agent-cursors-clear-buffer ()
  "Rimuovi tutti i cursori degli agenti in questo documento."
  (interactive)
  (dolist (group gdev-agent-cursors--groups)
    (gdev-agent-cursors--clear (car group))))

(defun gdev-agent-cursors--place (agent offsets)
  "Metti i cursori di AGENT agli OFFSETS in caratteri."
  (unless (and (vectorp offsets) (<= 1 (length offsets) 32)
               (cl-every (lambda (n) (and (integerp n) (<= 0 n (buffer-size)))) offsets)
               (= (length offsets) (length (delete-dups (append offsets nil)))))
    (user-error "Indica da 1 a 32 posizioni distinte nel documento"))
  (unless (or (assoc agent gdev-agent-cursors--groups)
              (< (length gdev-agent-cursors--groups) 16))
    (user-error "Il documento ha già 16 agenti con cursori"))
  (gdev-agent-cursors--clear agent)
  (push (cons agent
              (cl-loop for offset across offsets
                       for pos = (+ (point-min) offset)
                       collect
                       (let ((cursor (make-overlay pos pos nil t t)))
                         (overlay-put cursor 'face 'gdev-agent-cursor)
                         (overlay-put cursor 'help-echo (format "Cursore · %s" agent))
                         (overlay-put cursor 'gdev-agent-marker (copy-marker pos t))
                         cursor)))
        gdev-agent-cursors--groups)
  (add-hook 'after-change-functions #'gdev-agent-cursors--refresh nil t)
  (add-hook 'change-major-mode-hook #'gdev-agent-cursors-clear-buffer nil t)
  (gdev-agent-cursors--refresh))

(defun gdev-agent-cursors--write (agent text)
  "Inserisci TEXT ai cursori di AGENT come una sola modifica annullabile."
  (let* ((cursors (cdr (assoc agent gdev-agent-cursors--groups)))
         (positions (mapcar (lambda (cursor)
                              (marker-position (overlay-get cursor 'gdev-agent-marker)))
                            cursors)))
    (unless positions (user-error "Posiziona prima i cursori dell'agente"))
    (unless (and (stringp text) (not (string-empty-p text))
                 (<= (* (length positions) (string-bytes text)) (* 256 1024)))
      (user-error "Indica un testo non vuoto, fino a 256 KiB per tutti i cursori"))
    (unless (= (length positions) (length (delete-dups (copy-sequence positions))))
      (user-error "Alcuni cursori coincidono. Riposizionali prima di scrivere"))
    (unless (and (not buffer-read-only) (not (eq buffer-undo-list t))
                 (verify-visited-file-modtime (current-buffer)))
      (user-error "Il documento non è modificabile o è cambiato su disco"))
    (undo-boundary)
    (unwind-protect
        (let ((gdev-agent-cursors--defer-refresh t))
          (save-mark-and-excursion
            (atomic-change-group
              (dolist (pos (sort positions #'>))
                (goto-char pos)
                (insert text)))))
      (gdev-agent-cursors--refresh))
    (undo-boundary)))

(defun gdev-agent-cursors--data (path)
  "Leggi un piccolo valore JSON UTF-8 da PATH."
  (unless (and (gdev-agent-interface--absolute-local-p path)
               (not (find-file-name-handler path 'insert-file-contents))
               (file-regular-p path) (file-readable-p path)
               (<= (file-attribute-size (file-attributes path)) (* 1024 1024)))
    (user-error "Indica un file JSON locale di al massimo 1 MiB"))
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents path))
    (json-parse-string (buffer-string) :array-type 'array)))

(defun gdev-agent-cursors-request (action path agent-or-offset &optional revision data)
  "Smista ACTION su PATH con AGENT-OR-OFFSET, REVISION e DATA."
  (unless (and (gdev-agent-interface--absolute-local-p path) (not (file-directory-p path)))
    (user-error "Indica il percorso locale assoluto di un documento aperto"))
  (let ((buffer (find-buffer-visiting path))
        (read-state (equal action "cursor-state"))
        (agent agent-or-offset))
    (unless (buffer-live-p buffer)
      (user-error "Apri prima il documento in GDev"))
    (unless (or read-state
                (and (stringp agent)
                     (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]\\{0,39\\}\\'" agent)))
      (user-error "Indica un nome agente di 1–40 caratteri, come revisore-1"))
    (with-current-buffer buffer
      (unless enable-multibyte-characters (user-error "Serve un documento di testo"))
      (save-restriction
        (widen)
        (when (member action '("cursor-place" "cursor-write"))
          (when (or (derived-mode-p 'gdev-lavorazione-mode)
                    (string-suffix-p ".lavorazione" buffer-file-name))
            (user-error "Per modificare una lavorazione usa Composizione"))
          (unless (equal revision (gdev-agent-cursors--revision))
            (user-error "Il documento è cambiato. Leggi di nuovo posizioni e revisione")))
        (pcase action
          ("cursor-place" (gdev-agent-cursors--place agent (gdev-agent-cursors--data data)))
          ("cursor-write" (gdev-agent-cursors--write agent (gdev-agent-cursors--data data)))
          ("cursor-clear" (gdev-agent-cursors--clear agent)))
        (list
         (cons 'document
               `((path . ,buffer-file-name)
                 (revision . ,(gdev-agent-cursors--revision))
                 (length . ,(buffer-size))
                 (modified . ,(if (buffer-modified-p) t :false))
                 (cursors . ,(vconcat
                              (cl-loop for (name . cursors) in gdev-agent-cursors--groups
                                       collect `((agent . ,name)
                                                 (offsets . ,(vconcat
                                                              (mapcar (lambda (cursor)
                                                                        (- (overlay-start cursor) (point-min)))
                                                                      cursors)))))))
                 ,@(when read-state
                     (unless (and (stringp agent-or-offset)
                                  (string-match-p "\\`[0-9]+\\'" agent-or-offset)
                                  (<= (string-to-number agent-or-offset) (buffer-size)))
                       (user-error "L'offset richiesto è fuori dal documento"))
                     (let* ((offset (string-to-number agent-or-offset))
                            (start (+ (point-min) offset))
                            (end (min (point-max) (+ start 4096))))
                       `((offset . ,offset)
                         (text . ,(buffer-substring-no-properties start end))))))))))))

(provide 'gdev-agent-cursors)
;;; gdev-agent-cursors.el ends here
