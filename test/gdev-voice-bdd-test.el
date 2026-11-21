;;; gdev-voice-bdd-test.el --- Comportamenti italiani collegati a ERT -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'gdev-bdd (gdev-config-file "test/gdev-bdd"))
(require 'gdev-voice)

(defun gdev-voice-bdd--setup ()
  "Prepara un documento effettivo e conserva la disposizione precedente."
  (list (generate-new-buffer "Documento BDD voce") (current-window-configuration) (make-hash-table)
        transient-mark-mode))

(defun gdev-voice-bdd--cleanup (context)
  "Ripristina finestre e rimuovi il solo documento creato dalla prova."
  (set-window-configuration (nth 1 context))
  (transient-mark-mode (if (nth 3 context) 1 -1))
  (when (buffer-live-p (car context)) (kill-buffer (car context))))

(defun gdev-voice-bdd--text (context text)
  "Inserisci TEXT nel documento di CONTEXT."
  (switch-to-buffer (car context))
  (gdev-layout-mark-document)
  (buffer-enable-undo)
  (insert (replace-regexp-in-string "\\\\n" "\n" text t t))
  (setq buffer-undo-list nil)
  (transient-mark-mode 1))

(defun gdev-voice-bdd--command (context text)
  "Esegui TEXT e registra l'eventuale rifiuto in CONTEXT."
  (let ((gdev-layout-mode nil))
    (puthash 'error nil (nth 2 context))
    (condition-case error (gdev-voice-execute text)
      ((user-error buffer-read-only) (puthash 'error error (nth 2 context))))))

(gdev-bdd-register-feature
 (gdev-config-file "test/behavior/voice.feature") "gdev-test-behavior-voice-"
 `(("un documento vocale con testo \"\\([^\"]*\\)\"" . ,#'gdev-voice-bdd--text)
   ("impartisco il comando italiano \"\\([^\"]+\\)\"" . ,#'gdev-voice-bdd--command)
   ("il documento vocale contiene \"\\([^\"]*\\)\"" .
    ,(lambda (context expected)
       (with-current-buffer (car context) (should (equal expected (buffer-string))))))
   ("la selezione vocale contiene \"\\([^\"]+\\)\"" .
    ,(lambda (_context expected)
       (should (use-region-p))
       (should (equal expected (buffer-substring-no-properties (region-beginning) (region-end))))))
   ("annullo la modifica vocale" . ,(lambda (_context) (undo-only 1)))
   ("il comando vocale viene rifiutato" . ,(lambda (context) (should (gethash 'error (nth 2 context)))))
   ("il comando vocale termina regolarmente" . ,(lambda (context) (should-not (gethash 'error (nth 2 context)))))
   ("il documento vocale è in sola lettura" . ,(lambda (_context) (setq buffer-read-only t)))
   ("il cursore vocale è alla riga \\([0-9]+\\)" .
    ,(lambda (_context line) (should (= (string-to-number line) (line-number-at-pos))))))
 #'gdev-voice-bdd--setup #'gdev-voice-bdd--cleanup)

(provide 'gdev-voice-bdd-test)
;;; gdev-voice-bdd-test.el ends here
