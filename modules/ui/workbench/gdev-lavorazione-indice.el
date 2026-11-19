;;; gdev-lavorazione-indice.el --- Cerca le lavorazioni dello spazio -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Elenca i nomi dei piani locali a richiesta, in un processo separato.
;; Le radici remote rimangono disponibili per l'apertura esplicita.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst gdev-lavorazione-indice--limite 500
  "Numero massimo di lavorazioni mostrate per spazio.")

(defconst gdev-lavorazione-indice--visita
  '(lambda (radici codifica)
     ;; Questa funzione gira soltanto nell'Emacs separato.
     (set-terminal-coding-system codifica)
     (let ((da-visitare (reverse radici)) errore)
       (while da-visitare
         (let ((file (pop da-visitare)))
           (condition-case nil
               (unless (and (file-symlink-p file) (not (member file radici)))
                 (cond
                  ((file-directory-p file)
                   (dolist (figlio (reverse (directory-files file t "^[^.]")))
                     (push figlio da-visitare)))
                  ((member file radici) (setq errore t))
                  ((and (string-suffix-p ".lavorazione" file) (file-regular-p file))
                   (princ file)
                   (princ (string 0)))))
             (file-error (setq errore t)))))
       (when errore (kill-emacs 2))))
  "Enumeratore locale usato quando ripgrep non è disponibile.")

(defun gdev-lavorazione-indice--comando (radici codifica)
  "Prepara la ricerca delle RADICI con nomi nella CODIFICA locale."
  (if-let* ((ripgrep (executable-find "rg")))
      (append (list ripgrep "--no-config" "--files" "--null" "--sort" "path"
                    "--type-add" "lavorazione:*.lavorazione" "--type" "lavorazione"
                    "--glob" "!**/.*" "--")
              radici)
    (list (expand-file-name invocation-name invocation-directory)
          "--batch" "-Q" "--eval"
          (prin1-to-string
           `(funcall ,gdev-lavorazione-indice--visita ',radici ',codifica)))))

(defun gdev-lavorazione-indice--processo (radici rispondi)
  "Avvia la ricerca di RADICI e consegna l'esito a RISPONDI."
  (let* ((default-directory (or invocation-directory temporary-file-directory))
         (codifica (coding-system-change-eol-conversion
                    (or file-name-coding-system default-file-name-coding-system 'utf-8) 'unix))
         (comando (gdev-lavorazione-indice--comando radici codifica))
         (errori (make-pipe-process :name "gdev-lavorazioni-errori" :noquery t :filter #'ignore))
         (noti (make-hash-table :test 'equal))
         (residuo "")
         (limite gdev-lavorazione-indice--limite)
         file incompleto processo)
    (unwind-protect
        (setq processo
              (make-process
               :name "gdev-lavorazioni" :command comando :stderr errori
               :connection-type 'pipe :coding codifica :noquery t
               :filter
               (lambda (lettore blocco)
                 (let ((voci (nreverse (split-string (concat residuo blocco) "\0"))))
                   (setq residuo (pop voci))
                   (dolist (voce (nreverse voci))
                     (unless (or incompleto (string-empty-p voce) (gethash voce noti))
                       (if (< (hash-table-count noti) limite)
                           (progn (puthash voce t noti) (push voce file))
                         (setq incompleto t)
                         (delete-process lettore))))))
               :sentinel
               (lambda (lettore _evento)
                 (when (memq (process-status lettore) '(exit signal failed))
                   (delete-process errori)
                   (let ((stato (cond (incompleto 'limite)
                                      ((and (eq (process-status lettore) 'exit)
                                            (memq (process-exit-status lettore) '(0 1))) 'ok)
                                      (t 'errore))))
                     (funcall rispondi (sort file #'string<) stato))))))
      (unless processo (delete-process errori)))
    processo))

(defun gdev-lavorazione-indice-avvia (radici rispondi)
  "Cerca i file di lavorazione sotto le RADICI locali.
RISPONDI riceve in seguito i percorsi assoluti ordinati e uno stato
tra `ok', `limite' ed `errore'. La funzione restituita annulla la ricerca
quando viene chiamata senza argomenti. L'annullamento sopprime la risposta."
  (let ((radici (delete-dups (mapcar (lambda (radice)
                                      (directory-file-name (expand-file-name radice)))
                                    (seq-remove #'file-remote-p radici))))
        tempo processo)
    (setq tempo
          (run-at-time
           0 nil
           (lambda ()
             (setq tempo nil)
             (let ((consegna (lambda (file stato)
                               (when rispondi
                                 (let ((callback rispondi))
                                   (setq rispondi nil)
                                   (funcall callback file stato))))))
               (if (not radici)
                   (funcall consegna nil 'ok)
                 (setq processo
                       (condition-case nil
                           (gdev-lavorazione-indice--processo radici consegna)
                         (file-error nil)))
                 (unless processo (funcall consegna nil 'errore)))))))
    (lambda ()
      (setq rispondi nil)
      (when tempo (cancel-timer tempo))
      (when (process-live-p processo) (delete-process processo)))))

(provide 'gdev-lavorazione-indice)
;;; gdev-lavorazione-indice.el ends here
