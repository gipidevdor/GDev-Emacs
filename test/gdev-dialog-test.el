;;; gdev-dialog-test.el --- Prove delle conferme localizzate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'ert)
(require 'gdev-dialog)

(ert-deftest gdev-test-dialog-localizes-messages-with-file-names ()
  "La traduzione conserva nomi, spazi finali e messaggi già localizzati."
  (dolist (quote '("‘" "`" "'"))
    (let ((end (if (equal quote "‘") "’" "'")))
      (should (equal (gdev-dialog--text (format "File %sprova %%s %s exists; overwrite? " quote end))
                     "«prova %s » esiste già. Sostituirlo? "))))
  (should (equal (gdev-dialog--text "File relazione.ods changed on disk.  Discard your edits?")
                 "«relazione.ods» è cambiato sul disco. Scartare le modifiche locali?"))
  (should (equal (gdev-dialog--text "Save file /tmp/Résumé.txt (buffer Note)? ")
                 "Salvare «/tmp/Résumé.txt» dal documento «Note»? "))
  (let ((prompt (propertize "Salvare già?" 'help-echo "Prova")))
    (should (eq prompt (gdev-dialog--text prompt))))
  (should (equal (gdev-dialog--prompt-args '("Write file: " nil t "nome"))
                 '("Salva con nome: " nil t "nome"))))

(ert-deftest gdev-test-dialog-preserves-button-values-and-separators ()
  "Cambia il testo del popup mantenendo i valori del chiamante."
  (let* ((value (vector 'callback))
         (contents (list "Unsaved Buffers" (cons "Save All" value) nil '("Cancel" . cancel)))
         (translated (gdev-dialog--popup-args (list t contents t))))
    (should (equal translated
                   (list t (list "Documenti con modifiche da salvare" (cons "Salva tutto" value)
                                 nil '("Annulla" . cancel)) t)))
    (should (eq (cdr (nth 1 (cadr translated))) value))
    (should (equal (nth 1 contents) (cons "Save All" value)))))

(ert-deftest gdev-test-dialog-keeps-yes-no-and-cancellation-distinct ()
  "Pulsanti italiani nel ramo grafico e risposta originale al terminale."
  (let ((noninteractive nil)
        (ask (lambda (_) (ert-fail "Era attesa una conferma grafica"))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'use-dialog-box-p) #'always)
              ((symbol-function 'x-popup-dialog)
               (lambda (_ contents &rest _)
                 (should (equal contents '("Uscire da GDev-Emacs? " ("Sì" . t) ("No"))))
                 (cdadr contents))))
      (should (gdev-dialog--yes-or-no ask "Really exit Emacs? ")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'use-dialog-box-p) #'always)
              ((symbol-function 'x-popup-dialog) (lambda (&rest _) nil)))
      (should-not (gdev-dialog--yes-or-no ask "Really exit Emacs? ")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'use-dialog-box-p) #'always)
              ((symbol-function 'x-popup-dialog) (lambda (&rest _) (signal 'quit nil))))
      (should (eq (condition-case nil (gdev-dialog--yes-or-no ask "Really exit Emacs? ")
                    (quit 'annullato))
                  'annullato))))
  (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
    (should (equal (gdev-dialog--yes-or-no #'identity "Really restart Emacs? ")
                   "Riavviare GDev-Emacs? "))))

;;; gdev-dialog-test.el ends here
