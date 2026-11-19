;;; gdev-lavorazione-composizione-gui-test.el --- Pannello delle lavorazioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Verifica accesso dalla vista, recupero da un piano invalido e
;; consultazione dell'esito senza cambiare il sorgente.

;;; Code:

(require 'ert)
(require 'gdev-lavorazione-composizione)

(defun gdev-test-composizione--pulsante (etichetta)
  "Raggiungi e restituisci il pulsante di ETICHETTA."
  (goto-char (point-min))
  (search-forward etichetta)
  (button-at (1- (point))))

(ert-deftest gdev-test-lavorazione-composizione-apre-anche-un-piano-invalido ()
  "Il riquadro spiega il problema e il recupero senza scrivere il JSON."
  (gdev-test--with-layout
    (let ((sorgente (generate-new-buffer "diagnosi.lavorazione"))
          (editor (selected-window))
          (documento (generate-new-buffer "Documento attivo"))
          (lavorazioni (generate-new-buffer "Lavorazioni"))
          sinistra esito)
      (unwind-protect
          (progn
            (switch-to-buffer documento)
            (setq sinistra (gdev-activity-display lavorazioni 'lavorazioni t))
            (should (window-live-p sinistra))
            (with-current-buffer sorgente
              (gdev-lavorazione-mode)
              (insert "{\"versione\":1,\"passi\":[{\"azione\":\"salva\",\"argomenti\":{}}]}"))
            (gdev-lavorazione-composizione sorgente)
            (should (derived-mode-p 'gdev-composizione-mode))
            (should (eq (window-buffer editor) documento))
            (should (string-search "Piano da correggere" (buffer-string)))
            (should (string-search "Passo 1 · salva" (buffer-string)))
            (should-not (string-search "Esegui…" (buffer-string)))
            (should (button-get (gdev-test-composizione--pulsante "Aggiungi passo…") 'skip))
            (should-error (gdev-composizione-salva) :type 'user-error)
            (with-current-buffer sorgente
              (erase-buffer)
              (insert "{\"versione\":1,\"passi\":[]}"))
            (should (string-search "Da rileggere" (gdev-composizione--intestazione)))
            (call-interactively (key-binding (kbd "g")))
            (should (string-search "Nessun passo" (buffer-string)))
            (should-not (button-get (gdev-test-composizione--pulsante "Aggiungi passo…") 'skip))
            (button-activate (gdev-test-composizione--pulsante "Verifica"))
            (should (string-search "Valida · 0 passi" (gdev-composizione--intestazione)))
            (call-interactively (key-binding (kbd "?")))
            (setq esito (current-buffer))
            (should (derived-mode-p 'gdev-composizione-esito-mode))
            (should (eq (window-buffer sinistra) lavorazioni))
            (should (or (window-parameter nil 'gdev-layout-auxiliary)
                        (window-parameter nil 'gdev-layout-panel)))
            (should (string-search "Valida · 0 passi" (buffer-string)))
            (button-activate (gdev-test-composizione--pulsante "Composizione"))
            (should (derived-mode-p 'gdev-composizione-mode))
            (should (eq (window-buffer editor) documento)))
        (dolist (buffer (list esito sorgente documento lavorazioni))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-lavorazione-composizione-esito-porta-al-passo-interrotto ()
  "Esito e azione sul passo seguono il piano e lo spazio che lo ha eseguito."
  (gdev-test--with-layout
    (let* ((cartella (make-temp-file "gdev-composizione-esito-" t))
           (sorgente (generate-new-buffer "esecuzione.lavorazione"))
           (bersaglio (expand-file-name "nota.txt" cartella))
           esito)
      (unwind-protect
          (progn
            (write-region "Nota\n" nil bersaglio nil 'silent)
            (with-current-buffer sorgente
              (gdev-lavorazione-mode)
              (insert "{\"versione\":1,\"passi\":[
                {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"nota.txt\"}},
                {\"azione\":\"vai-riga\",\"argomenti\":{\"riga\":999}}]}"))
            (gdev-lavorazione-composizione sorgente)
            (cl-letf (((symbol-function 'read-directory-name) (lambda (&rest _) cartella))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (should-error (gdev-composizione-esegui) :type 'user-error))
            (should (string-search "Interrotta · passo 2" (gdev-composizione--intestazione)))
            (gdev-composizione-esito)
            (setq esito (current-buffer))
            (should (string-search "Passi completati · 1 di 2" (buffer-string)))
            (should (string-search "Passo 2 · vai-riga" (buffer-string)))
            (button-activate (gdev-test-composizione--pulsante "Vai al passo"))
            (should (derived-mode-p 'gdev-composizione-mode))
            (should (= (gdev-composizione--indice) 1))
            (with-current-buffer sorgente
              (goto-char (point-max))
              (insert "\n"))
            (should (string-search "Esito precedente" (gdev-composizione--intestazione)))
            (with-current-buffer esito
              (should (string-search "revisione precedente" (buffer-string)))
              (should-not (string-search "Vai al passo" (buffer-string)))
              (should-error (gdev-composizione-vai-al-passo) :type 'user-error))
            (gdev-composizione-esito)
            (should (string-search "revisione precedente" (buffer-string)))
            (should-not (string-search "Vai al passo" (buffer-string))))
        (when-let* ((buffer (find-buffer-visiting bersaglio))) (kill-buffer buffer))
        (dolist (buffer (list esito sorgente))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory cartella t)))))

(ert-deftest gdev-test-lavorazione-esito-segue-il-sorgente-aperto ()
  "Una verifica aggiorna il rapporto aperto senza spostare il fuoco."
  (gdev-test--with-layout
    (let ((sorgente (generate-new-buffer "Rapporto .lavorazione"))
          (editor (selected-window))
          esito composizione)
      (unwind-protect
          (progn
            (with-current-buffer sorgente
              (gdev-lavorazione-mode)
              (insert "{\"versione\":1,\"passi\":[]}"))
            (gdev-lavorazione-composizione sorgente)
            (setq composizione (current-buffer))
            (gdev-composizione-esito)
            (setq esito (current-buffer))
            (should (string-search "Nessuna verifica" (buffer-string)))
            (select-window editor)
            (with-current-buffer sorgente (gdev-lavorazione-verifica))
            (should (eq editor (selected-window)))
            (with-current-buffer esito
              (should (string-search "Valida · 0 passi" (buffer-string))))
            (with-current-buffer sorgente
              (goto-char (point-max))
              (insert "\n"))
            (let ((tick (buffer-chars-modified-tick esito)))
              (with-current-buffer sorgente (insert " "))
              (should (= tick (buffer-chars-modified-tick esito))))
            (kill-buffer sorgente)
            (should-not (buffer-live-p esito))
            (should-not (buffer-live-p composizione))
            (should (eq editor (selected-window))))
        (dolist (buffer (list esito composizione sorgente))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest gdev-test-lavorazione-esiti-visivi-restano-nello-spazio-di-origine ()
  "Una verifica aggiorna solo l'esito dello spazio che la esegue."
  (gdev-test--with-layout
    (let ((sorgente (generate-new-buffer "Rapporto condiviso .lavorazione"))
          prima seconda)
      (unwind-protect
          (progn
            (with-current-buffer sorgente
              (gdev-lavorazione-mode)
              (insert "{\"versione\":1,\"passi\":[]}")
              (gdev-lavorazione-verifica))
            (gdev-lavorazione-composizione sorgente)
            (gdev-composizione-esito)
            (setq prima (current-buffer))
            (tab-bar-new-tab)
            (gdev-lavorazione-composizione sorgente)
            (gdev-composizione-esito)
            (setq seconda (current-buffer))
            (should-not (eq prima seconda))
            (should (string-search "Nessuna verifica" (buffer-string)))
            (with-current-buffer sorgente
              (goto-char (point-max))
              (insert "\n")
              (gdev-lavorazione-verifica))
            (with-current-buffer prima
              (should (string-search "revisione precedente" (buffer-string))))
            (with-current-buffer seconda
              (should (string-search "Valida · 0 passi" (buffer-string)))
              (should-not (string-search "revisione precedente" (buffer-string))))
            (kill-buffer sorgente)
            (should-not (buffer-live-p prima))
            (should-not (buffer-live-p seconda)))
        (dolist (buffer (list prima seconda sorgente))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'gdev-lavorazione-composizione-gui-test)
;;; gdev-lavorazione-composizione-gui-test.el ends here
