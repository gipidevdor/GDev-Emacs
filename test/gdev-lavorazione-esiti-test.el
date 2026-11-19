;;; gdev-lavorazione-esiti-test.el --- Esiti delle lavorazioni nella GUI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica la pubblicazione degli esiti, la revisione e lo spazio di origine.

;;; Code:

(require 'ert)
(require 'gdev-lavorazione)

(defconst gdev-test-lavorazione--esiti-piano
  "{\"versione\":1,\"passi\":[{\"azione\":\"simula-passo\",\"argomenti\":{\"testo\":\"uno\"}},{\"azione\":\"simula-passo\",\"argomenti\":{\"testo\":\"due\"}},{\"azione\":\"simula-passo\",\"argomenti\":{\"testo\":\"tre\"}}]}")

(ert-deftest gdev-test-lavorazione-esiti-analisi-strutturata-senza-pubblicazione ()
  "L'analisi distingue il JSON non valido, il passo errato e il piano vuoto."
  (with-temp-buffer
    (gdev-lavorazione-mode)
    (insert "{")
    (pcase-let ((`(,piano . ,esito) (gdev-lavorazione-analizza)))
      (should-not piano)
      (should (eq (gdev-lavorazione-esito-stato esito) 'non-valida))
      (should-not (gdev-lavorazione-esito-passo esito))
      (should (string-prefix-p "JSON non valido" (gdev-lavorazione-esito-messaggio esito))))
    (erase-buffer)
    (insert "{\"versione\":1,\"passi\":[{\"azione\":\"salva\",\"argomenti\":{}}]}")
    (pcase-let ((`(,piano . ,esito) (gdev-lavorazione-analizza)))
      (should-not piano)
      (should (eq (gdev-lavorazione-esito-stato esito) 'non-valida))
      (should (= (gdev-lavorazione-esito-totale esito) 1))
      (should (= (gdev-lavorazione-esito-passo esito) 1))
      (should (equal (gdev-lavorazione-esito-azione esito) "salva"))
      (should (string-prefix-p "Passo 1 · " (gdev-lavorazione-esito-messaggio esito))))
    (erase-buffer)
    (insert "{\"versione\":1,\"passi\":[]}")
    (pcase-let ((`(,piano . ,esito) (gdev-lavorazione-analizza)))
      (should-not piano)
      (should (eq (gdev-lavorazione-esito-stato esito) 'valida))
      (should (= (gdev-lavorazione-esito-totale esito) 0)))
    (should-not (gdev-lavorazione-ultimo-esito))))

(ert-deftest gdev-test-lavorazione-esiti-verifica-pubblica-la-revisione ()
  "La verifica pubblica nel sorgente e conserva il messaggio di errore."
  (gdev-test--with-layout
    (with-temp-buffer
      (gdev-lavorazione-mode)
      (insert "{\"versione\":1,\"passi\":[]}")
      (let ((sorgente (current-buffer)) osservato)
        (add-hook 'gdev-lavorazione-esito-hook
                  (lambda ()
                    (should (eq (current-buffer) sorgente))
                    (setq osservato (gdev-lavorazione-ultimo-esito)))
                  nil t)
        (call-interactively #'gdev-lavorazione-verifica)
        (should (eq (gdev-lavorazione-esito-stato osservato) 'valida))
        (should (= (gdev-lavorazione-esito-revisione osservato) (buffer-chars-modified-tick)))
        (insert " testo inatteso")
        (should-not (= (gdev-lavorazione-esito-revisione osservato) (buffer-chars-modified-tick)))
        (let ((errore (should-error (call-interactively #'gdev-lavorazione-verifica)
                                    :type 'user-error)))
          (should (eq (gdev-lavorazione-esito-stato osservato) 'non-valida))
          (should (equal (gdev-lavorazione-esito-messaggio osservato)
                         (error-message-string errore))))))))

(ert-deftest gdev-test-lavorazione-esiti-annulla-e-segnala-il-passo-fallito ()
  "Nessun passo parte senza conferma e l'errore conserva il progresso parziale."
  (gdev-test--with-layout
    (with-temp-buffer
      (gdev-lavorazione-mode)
      (insert gdev-test-lavorazione--esiti-piano)
      (let ((gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni))
            (radice default-directory)
            errore chiamate)
        (gdev-lavorazione-registra "simula-passo" "Simula un passo." '(("testo" . testo))
                                  (lambda (_contesto testo)
                                    (when (and errore (equal testo "due")) (user-error "Precondizione"))
                                    (push testo chiamate)))
        (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) radice))
                  ((symbol-function 'yes-or-no-p) #'ignore))
          (call-interactively #'gdev-lavorazione-esegui))
        (let ((esito (gdev-lavorazione-ultimo-esito)))
          (should (eq (gdev-lavorazione-esito-stato esito) 'annullata))
          (should (= (gdev-lavorazione-esito-completati esito) 0))
          (should-not chiamate))
        (setq errore t)
        (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) radice))
                  ((symbol-function 'yes-or-no-p) #'always))
          (let* ((segnale (should-error (call-interactively #'gdev-lavorazione-esegui)
                                        :type 'user-error))
                 (esito (gdev-lavorazione-ultimo-esito)))
            (should (eq (gdev-lavorazione-esito-stato esito) 'fallita))
            (should (= (gdev-lavorazione-esito-totale esito) 3))
            (should (= (gdev-lavorazione-esito-completati esito) 1))
            (should (= (gdev-lavorazione-esito-passo esito) 2))
            (should (equal (gdev-lavorazione-esito-azione esito) "simula-passo"))
            (should (equal (gdev-lavorazione-esito-messaggio esito) (error-message-string segnale)))
            (should (equal (gdev-lavorazione-esito-radice esito)
                           (file-name-as-directory (file-truename radice))))
            (should (equal chiamate '("uno"))))
          (setq errore nil chiamate nil)
          (call-interactively #'gdev-lavorazione-esegui)
          (let ((esito (gdev-lavorazione-ultimo-esito)))
            (should (eq (gdev-lavorazione-esito-stato esito) 'completata))
            (should (= (gdev-lavorazione-esito-completati esito) 3))
            (should-not (gdev-lavorazione-esito-passo esito))
            (should (equal chiamate '("tre" "due" "uno")))))))))

(ert-deftest gdev-test-lavorazione-esiti-spazio-cambiato-durante-la-conferma ()
  "Il cambio di spazio invalida la conferma e l'esito resta nello spazio di origine."
  (gdev-test--with-layout
    (with-temp-buffer
      (gdev-lavorazione-mode)
      (insert gdev-test-lavorazione--esiti-piano)
      (let ((gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni))
            (radice default-directory)
            (sorgente (current-buffer))
            (origine (gdev-workspace-state-ensure-id))
            chiamate)
        (gdev-lavorazione-registra "simula-passo" "Simula un passo." '(("testo" . testo))
                                  (lambda (&rest _) (push t chiamate)))
        (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) radice))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) (tab-bar-new-tab) t)))
          (should-error (call-interactively #'gdev-lavorazione-esegui) :type 'user-error))
        (should-not chiamate)
        (should-not (eq origine (gdev-workspace-state-id)))
        (should-not (gdev-lavorazione-ultimo-esito sorgente))
        (tab-bar-select-tab 1)
        (should (eq origine (gdev-workspace-state-id)))
        (let ((esito (gdev-lavorazione-ultimo-esito sorgente)))
          (should (eq (gdev-lavorazione-esito-stato esito) 'fallita))
          (should (= (gdev-lavorazione-esito-completati esito) 0))
          (should (string-prefix-p "Lo spazio di lavoro è cambiato"
                                   (gdev-lavorazione-esito-messaggio esito))))))))

(ert-deftest gdev-test-lavorazione-esiti-interruzione-della-scelta ()
  "Un annullamento da tastiera pubblica l'esito senza intercettare il segnale."
  (gdev-test--with-layout
    (with-temp-buffer
      (gdev-lavorazione-mode)
      (insert "{\"versione\":1,\"passi\":[{\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"prova.txt\"}}]}")
      (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) (signal 'quit nil))))
        (should (condition-case nil (progn (gdev-lavorazione-esegui) nil) (quit t))))
      (let ((esito (gdev-lavorazione-ultimo-esito)))
        (should (eq (gdev-lavorazione-esito-stato esito) 'annullata))
        (should (= (gdev-lavorazione-esito-completati esito) 0))))))

(ert-deftest gdev-test-lavorazione-esiti-sorgente-cambiato-durante-la-conferma ()
  "Una conferma per una revisione precedente non avvia la lavorazione."
  (gdev-test--with-layout
    (with-temp-buffer
      (gdev-lavorazione-mode)
      (insert gdev-test-lavorazione--esiti-piano)
      (let ((gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni))
            (radice default-directory)
            (sorgente (current-buffer))
            (revisione (buffer-chars-modified-tick))
            chiamate)
        (gdev-lavorazione-registra "simula-passo" "Simula un passo." '(("testo" . testo))
                                  (lambda (&rest _) (push t chiamate)))
        (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) radice))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (with-current-buffer sorgente (insert " ")) t)))
          (should-error (call-interactively #'gdev-lavorazione-esegui) :type 'user-error))
        (let ((esito (gdev-lavorazione-ultimo-esito)))
          (should (eq (gdev-lavorazione-esito-stato esito) 'fallita))
          (should-not chiamate)
          (should (= revisione (gdev-lavorazione-esito-revisione esito)))
          (should (/= revisione (buffer-chars-modified-tick))))))))

(ert-deftest gdev-test-lavorazione-esiti-sorgente-dopo-il-salvataggio ()
  "Il comando dal sorgente pubblica anche quando l'editor apre un altro file."
  (gdev-test--with-layout
    (let* ((radice (file-name-as-directory (make-temp-file "gdev-lavorazione-esito-" t)))
           (piano (expand-file-name "prova.lavorazione" radice))
           (documento (expand-file-name "nota.txt" radice))
           (auto-mode-alist (cons '("\\.lavorazione\\'" . gdev-lavorazione-mode) auto-mode-alist))
           sorgente)
      (unwind-protect
          (progn
            (with-temp-file piano
              (insert "{\"versione\":1,\"passi\":[
                       {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"nota.txt\"}},
                       {\"azione\":\"inserisci\",\"argomenti\":{\"testo\":\"Nota locale\\n\"}},
                       {\"azione\":\"salva\",\"argomenti\":{}}]}"))
            (gdev-open-file piano)
            (setq sorgente (current-buffer))
            (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) radice))
                      ((symbol-function 'yes-or-no-p) #'always))
              (call-interactively (key-binding (kbd "C-c C-c"))))
            (should (eq (window-buffer (gdev-layout-editor)) (find-buffer-visiting documento)))
            (let ((esito (gdev-lavorazione-ultimo-esito sorgente)))
              (should (eq (gdev-lavorazione-esito-stato esito) 'completata))
              (should (= (gdev-lavorazione-esito-completati esito) 3))
              (should (= (gdev-lavorazione-esito-revisione esito) (buffer-chars-modified-tick sorgente))))
            (with-temp-buffer
              (insert-file-contents documento)
              (should (equal (buffer-string) "Nota locale\n"))))
        (dolist (buffer (list sorgente (find-buffer-visiting documento)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory radice t)))))

(provide 'gdev-lavorazione-esiti-test)
;;; gdev-lavorazione-esiti-test.el ends here
