;;; gdev-lavorazione-test.el --- Prove delle lavorazioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Copre il contratto dei piani e l'esecuzione su file temporanei.

;;; Code:

(require 'ert)
(require 'gdev-commands)
(require 'gdev-lavorazione)
(require 'gdev-lavorazione-composizione)

(defvar gdev-test-lavorazione--snippet-valutato nil)

(defun gdev-test-lavorazione--piano (testo)
  "Compila il piano JSON descritto da TESTO."
  (with-temp-buffer
    (insert testo)
    (gdev-lavorazione--piano (gdev-lavorazione--leggi))))

(ert-deftest gdev-test-lavorazione-documento-locale ()
  "Apri, modifica e salva un documento con il normale comando dell'editor."
  (let* ((radice (file-name-as-directory (make-temp-file "gdev-lavorazione-" t)))
         (file (expand-file-name "prova.txt" radice)))
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "titolo\nprima\n"))
          (let ((piano (gdev-test-lavorazione--piano
                        "{\"versione\":1,\"passi\":[
                           {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"prova.txt\"}},
                           {\"azione\":\"vai-riga\",\"argomenti\":{\"riga\":2}},
                           {\"azione\":\"inserisci\",\"argomenti\":{\"testo\":\"nota: \"}},
                           {\"azione\":\"sostituisci\",\"argomenti\":{\"prima\":\"prima\",\"dopo\":\"dopo\"}},
                           {\"azione\":\"salva\",\"argomenti\":{}}]}")))
            (should (= 5 (gdev-lavorazione--esegui piano radice))))
          (with-temp-buffer
            (insert-file-contents file)
            (should (equal (buffer-string) "titolo\nnota: dopo\n"))))
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))
      (delete-directory radice t))))

(ert-deftest gdev-test-lavorazione-catalogo-dinamico-e-verifica ()
  "Le azioni nuove sono subito risolvibili e un passo errato blocca il piano."
  (let ((gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni)) chiamate)
    (gdev-lavorazione-registra "prova" "Registra un risultato locale."
                              '(("dato" . testo))
                              (lambda (_contesto dato) (push dato chiamate)))
    (let ((piano (gdev-test-lavorazione--piano
                  "{\"versione\":1,\"passi\":[{\"azione\":\"prova\",\"argomenti\":{\"dato\":\"ok\"}}]}")))
      (should-not chiamate)
      (should (= 1 (gdev-lavorazione--esegui piano default-directory)))
      (should (equal chiamate '("ok"))))
    (dolist (testo '("{\"versione\":2,\"passi\":[]}"
                     "{\"versione\":1,\"passi\":[{\"azione\":\"prova\",\"argomenti\":{\"dato\":3}}]}"
                     "{\"versione\":1,\"passi\":[{\"azione\":\"salva\",\"argomenti\":{}},
                                                   {\"azione\":\"inesistente\",\"argomenti\":{}}]}"
                     "{\"versione\":1,\"passi\":[{\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"../fuori\"}}]}"
                     "{\"versione\":1,\"passi\":[]} altro"))
      (should-error (gdev-test-lavorazione--piano testo) :type 'user-error))))

(ert-deftest gdev-test-lavorazione-impedisce-uscita-dalla-radice ()
  "Il resolver rifiuta un collegamento che punta fuori dalla cartella scelta."
  (let* ((base (make-temp-file "gdev-lavorazione-" t))
         (radice (expand-file-name "dentro/" base))
         (fuori (expand-file-name "fuori.txt" base)))
    (unwind-protect
        (progn
          (make-directory radice)
          (with-temp-file fuori (insert "testo"))
          (make-symbolic-link fuori (expand-file-name "alias.txt" radice))
          (should-error (gdev-lavorazione--percorso radice "alias.txt") :type 'user-error))
      (delete-directory base t))))

(ert-deftest gdev-test-lavorazione-aggiunge-passo-da-catalogo ()
  "L'autore guidato genera un passo tipizzato che il motore sa rileggere."
  (with-temp-buffer
    (gdev-lavorazione-mode)
    (insert "{\"versione\":1,\"passi\":[
             {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"note.txt\"}}]}")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "vai-riga"))
              ((symbol-function 'read-number) (lambda (&rest _) 4)))
      (gdev-lavorazione-aggiungi-passo))
    (let ((piano (gdev-lavorazione--piano (gdev-lavorazione--leggi))))
      (should (= 2 (length piano)))
      (should (equal (gdev-lavorazione--azione-nome (caadr piano)) "vai-riga"))
      (should (equal (cdadr piano) '(4))))))

(ert-deftest gdev-test-lavorazione-composizione-valida-le-modifiche ()
  "Il riquadro modifica il sorgente solo dopo la verifica di tutti i passi."
  (with-temp-buffer
    (gdev-lavorazione-mode)
    (insert "{\"versione\":1,\"passi\":[]}")
    (let ((sorgente (current-buffer)))
      (with-temp-buffer
        (gdev-composizione-mode)
        (setq gdev-composizione--sorgente sorgente)
        (gdev-composizione-aggiorna)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt nomi &rest _)
                     (should (member "apri-file" nomi))
                     (should-not (member "salva" nomi))
                     "apri-file"))
                  ((symbol-function 'read-string) (lambda (&rest _) "note.txt")))
          (gdev-composizione-aggiungi))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt nomi &rest _)
                     (should (member "vai-riga" nomi))
                     "vai-riga"))
                  ((symbol-function 'read-number) (lambda (&rest _) 2)))
          (gdev-composizione-aggiungi))
        (cl-letf (((symbol-function 'read-number)
                   (lambda (_prompt iniziale &rest _)
                     (should (= iniziale 2))
                     3)))
          (gdev-composizione-modifica))
        (let ((prima (with-current-buffer sorgente (buffer-string))))
          (should-error (gdev-composizione-su) :type 'user-error)
          (gdev-composizione-precedente)
          (should-error (gdev-composizione-rimuovi) :type 'user-error)
          (should (equal prima (with-current-buffer sorgente (buffer-string))))
          (with-current-buffer sorgente (goto-char (point-max)) (insert "\n"))
          (should-error (gdev-composizione-giu) :type 'user-error))
        (gdev-composizione-aggiorna)
        (gdev-composizione-successivo)
        (gdev-composizione-rimuovi)
        (should (= 1 (with-current-buffer sorgente
                       (length (gdev-lavorazione--piano (gdev-lavorazione--leggi))))))))))

(ert-deftest gdev-test-lavorazione-composizione-azioni-della-vista ()
  "Pulsanti e menu usano il piano visibile e la riga a cui si riferiscono."
  (with-temp-buffer
    (gdev-lavorazione-mode)
    (should (memq 'gdev-lavorazione-composizione
                  (mapcar #'gdev-context-item-command (gdev-context-view-items))))
    (insert "{\"versione\":1,\"passi\":[]}")
    (let ((sorgente (current-buffer)))
      (save-window-excursion
        (with-temp-buffer
          (gdev-composizione-mode)
          (setq gdev-composizione--sorgente sorgente)
          (set-window-buffer (selected-window) (current-buffer))
          (gdev-composizione-aggiorna)
          (should-not (gdev-composizione--evidenziazione))
          (should-not (string-search "Esegui…" (buffer-string)))
          (with-current-buffer sorgente
            (erase-buffer)
            (insert "{\"versione\":1,\"passi\":[
                     {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"note.txt\"}},
                     {\"azione\":\"vai-riga\",\"argomenti\":{\"riga\":1}},
                     {\"azione\":\"salva\",\"argomenti\":{}}]}"))
          (gdev-composizione-aggiorna)
          (let ((sposta-su (save-excursion
                             (goto-char (point-min))
                             (search-forward "Sposta su")
                             (button-at (1- (point))))))
            (should (button-get sposta-su 'skip))
            (button-activate sposta-su)
            (should (= (gdev-composizione--indice) 0))
            (gdev-composizione-successivo)
            (should-not (button-get sposta-su 'skip)))
          (let ((intervallo (gdev-composizione--evidenziazione))
                (target (gdev-context--target-create
                         :window (selected-window) :buffer (current-buffer)
                         :mode major-mode :tick (buffer-chars-modified-tick)
                         :position (car gdev-composizione--righe)))
                (menu (make-sparse-keymap)))
            (gdev-context--add-items menu (gdev-context-view-items) target)
            (should (assq 'gdev-composizione-esegui (cdr menu)))
            (should (assq 'gdev-composizione-giu (cdr menu)))
            (should-not (assq 'gdev-composizione-su (cdr menu)))
            (goto-char (point-min))
            (search-forward "Esegui…")
            (let ((pulsante (button-at (1- (point))))
                  (chiamate 0))
              (should (equal intervallo (gdev-composizione--evidenziazione)))
              (cl-letf (((symbol-function 'gdev-lavorazione-esegui)
                         (lambda () (should (eq (current-buffer) sorgente))
                           (cl-incf chiamate))))
                (button-activate pulsante)
                (call-interactively (key-binding (kbd "C-c C-c")))
                (should (= chiamate 2))
                (with-current-buffer sorgente
                  (goto-char (point-min))
                  (search-forward "{\"azione\":\"vai-riga\"")
                  (goto-char (match-beginning 0))
                  (insert "{\"azione\":\"inserisci\",\"argomenti\":{\"testo\":\"prima\"}},"))
                (should-error (button-activate pulsante) :type 'user-error)
                (should (= chiamate 2))
                (gdev-composizione-aggiorna)
                (should (= (gdev-composizione--indice) 2))))))))))

(ert-deftest gdev-test-lavorazione-composizione-distingue-selezione-e-modifica ()
  "L'intera riga seleziona il passo e la modifica richiede un'azione esplicita."
  (with-temp-buffer
    (gdev-lavorazione-mode)
    (insert "{\"versione\":1,\"passi\":[
               {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"note.txt\"}},
               {\"azione\":\"vai-riga\",\"argomenti\":{\"riga\":7}}]}")
    (set-buffer-modified-p nil)
    (let ((sorgente (current-buffer))
          (prima (buffer-string))
          (richieste 0))
      (with-temp-buffer
        (gdev-composizione-mode)
        (setq gdev-composizione--sorgente sorgente)
        (gdev-composizione-aggiorna)
        (should-not (gdev-composizione--stato-sorgente))
        (cl-letf (((symbol-function 'read-number)
                   (lambda (&rest _)
                     (cl-incf richieste)
                     (signal 'quit nil))))
          (let* ((valore (1- (save-excursion
                               (goto-char (cadr gdev-composizione--righe))
                               (search-forward "riga 7"))))
                 (pulsante (button-at valore)))
            (should pulsante)
            (should (equal (get-text-property valore 'help-echo) "7"))
            (button-activate pulsante)
            (should (= (gdev-composizione--indice) 1))
            (call-interactively (key-binding (kbd "<up>")))
            (should (= (gdev-composizione--indice) 0))
            (goto-char valore)
            (call-interactively (key-binding (kbd "RET")))
            (should (= (gdev-composizione--indice) 1))
            (should (= richieste 0)))
          (should (eq (condition-case nil
                          (call-interactively (key-binding (kbd "e")))
                        (quit 'annullata))
                      'annullata))
          (should (= richieste 1)))
        (with-current-buffer sorgente
          (should (equal (buffer-string) prima))
          (should-not (buffer-modified-p))
          (goto-char (point-max))
          (insert "\n"))
        (should (equal (substring-no-properties (gdev-composizione--stato-sorgente))
                       "Da rileggere · g"))
        (gdev-composizione-aggiorna)
        (should (= (gdev-composizione--indice) 1))
        (should (equal (substring-no-properties (gdev-composizione--stato-sorgente))
                       "Modifiche da salvare"))))))

(ert-deftest gdev-test-lavorazione-vista-ausiliaria-e-sorgente ()
  "La composizione e il catalogo riusano il riquadro senza alterare il JSON."
  (require 'gdev-command-sidebar)
  (gdev-test--with-layout
    (let* ((originale "{\"versione\":1,\"passi\":[]}")
           (file (make-temp-file "gdev-piano-prova-" nil ".lavorazione" originale))
           (editor (gdev-layout-editor))
           (gdev-command-sidebar-width 24)
           (gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni))
           (auto-mode-alist (cons '("\\.lavorazione\\'" . gdev-lavorazione-mode) auto-mode-alist))
           sorgente composizione catalogo comandi controllo)
      (unwind-protect
          (progn
            (gdev-open-file file)
            (setq sorgente (current-buffer))
            (goto-char (point-max))
            (insert "\n")
            (goto-char 8)
            (setq controllo (buffer-string))
            (gdev-command-sidebar-toggle)
            (setq comandi (window-buffer (gdev-layout-command-sidebar-window)))
            (call-interactively (key-binding (kbd "C-c C-e")))
            (setq composizione (current-buffer))
            (should (derived-mode-p 'gdev-composizione-mode))
            (should (eq (selected-window) (gdev-layout-auxiliary-window)))
            (should (eq (window-buffer editor) sorgente))
            (call-interactively (key-binding (kbd "C-c C-e")))
            (should (eq (selected-window) editor))
            (should (= (point) 8))
            (should (equal (buffer-string) controllo))
            (gdev-lavorazione-catalogo)
            (setq catalogo (current-buffer))
            (should (derived-mode-p 'gdev-lavorazione-catalogo-mode))
            (should (eq (selected-window) (gdev-layout-auxiliary-window)))
            (goto-char (point-min))
            (search-forward "vai-riga")
            (should (equal (get-text-property (point) 'gdev-lavorazione-voce) "vai-riga"))
            (gdev-lavorazione-registra "azione-prova" "Una nuova voce." nil #'ignore)
            (call-interactively (key-binding (kbd "g")))
            (should (string-search "azione-prova" (buffer-string)))
            (should (equal (get-text-property (point) 'gdev-lavorazione-voce) "vai-riga"))
            (call-interactively (key-binding (kbd "q")))
            (should (eq (selected-window) editor))
            (should (eq (current-buffer) sorgente))
            (should (buffer-live-p catalogo))
            (should (buffer-modified-p sorgente))
            (with-temp-buffer
              (insert-file-contents file)
              (should (equal (buffer-string) originale)))
            (call-interactively (key-binding (kbd "C-c C-e")))
            (should (eq (current-buffer) composizione)))
        (when (buffer-live-p sorgente)
          (with-current-buffer sorgente (set-buffer-modified-p nil)))
        (dolist (buffer (list sorgente composizione catalogo comandi))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-file file)))))

(ert-deftest gdev-test-lavorazione-si-ferma-al-primo-errore ()
  "Un passo fallito indica la propria posizione e impedisce quelli successivi."
  (let ((gdev-lavorazione--azioni (copy-hash-table gdev-lavorazione--azioni))
        chiamate)
    (gdev-lavorazione-registra "prova" "Azione di prova." '(("dato" . testo))
                              (lambda (_contesto dato)
                                (when (equal dato "errore") (user-error "Precondizione"))
                                (push dato chiamate)))
    (let* ((piano (gdev-test-lavorazione--piano
                   "{\"versione\":1,\"passi\":[
                     {\"azione\":\"prova\",\"argomenti\":{\"dato\":\"prima\"}},
                     {\"azione\":\"prova\",\"argomenti\":{\"dato\":\"errore\"}},
                     {\"azione\":\"prova\",\"argomenti\":{\"dato\":\"dopo\"}}]}"))
           (err (should-error (gdev-lavorazione--esegui piano default-directory) :type 'user-error)))
      (should (string-match-p "Passo 2" (error-message-string err)))
      (should (equal chiamate '("prima"))))))

(ert-deftest gdev-test-lavorazione-frammenti-e-azioni-dei-moduli ()
  "I moduli distribuiti contribuiscono azioni e YAS espande solo frammenti statici."
  (skip-unless (getenv "GDEV_TEST_SMOKE"))
  (require 'package)
  (package-activate-all)
  (dolist (integrazione '((snippets . "inserisci-snippet")
                          (fold . "piega-blocchi")
                          (format . "formatta-documento")))
    (unless (gethash (cdr integrazione) gdev-lavorazione--azioni)
      (gdev-modules--load :editor (car integrazione))))
  (require 'yasnippet)
  (dolist (voce '(("inserisci-snippet" . "Frammenti")
                  ("piega-blocchi" . "Piegatura")
                  ("espandi-blocchi" . "Piegatura")
                  ("formatta-documento" . "Formattazione")))
    (should (equal (gdev-lavorazione--azione-modulo (gethash (car voce) gdev-lavorazione--azioni))
                   (cdr voce))))
  (let* ((radice (make-temp-file "gdev-lavorazione-frammenti-" t))
         (file (expand-file-name "prova.el" radice))
         (gdev-test-lavorazione--snippet-valutato nil))
    (unwind-protect
        (save-window-excursion
          (let* ((default-directory (file-name-as-directory radice))
                 (piano (gdev-test-lavorazione--piano
                         "{\"versione\":1,\"passi\":[
                           {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"prova.el\"}}]}")))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt opzioni &rest _)
                         (if (hash-table-p opzioni)
                             (progn (should (gethash "dp-observer" opzioni)) "dp-observer")
                           "inserisci-snippet"))))
              (let ((passo (gdev-lavorazione--leggi-passo piano)))
                (should (equal (gethash "chiave" (gethash "argomenti" passo)) "dp-observer"))))
            (should-not (get-file-buffer file))
            (should-not (file-exists-p file)))
          (with-temp-file file)
          (gdev-lavorazione--esegui
           (gdev-test-lavorazione--piano
            "{\"versione\":1,\"passi\":[
              {\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"prova.el\"}},
              {\"azione\":\"inserisci-snippet\",\"argomenti\":{\"chiave\":\"dp-observer\"}},
              {\"azione\":\"salva\",\"argomenti\":{}}]}")
           radice)
          (set-buffer (get-file-buffer file))
          (let ((contesto (make-gdev-lavorazione--contesto :radice radice :documento (current-buffer))))
            (goto-char (point-min))
            (should (search-forward "(run-hooks 'example-updated-hook)" nil t))
            (should (string-match-p "example-updated-hook" (gdev-read-file-contents file)))
            (should-not (yas-active-snippets 'all))
            (yas-define-snippets
             'emacs-lisp-mode
             '(("gdev-prova-trasformazione" "`(setq gdev-test-lavorazione--snippet-valutato t)`")
               ("gdev-prova-condizione" "test" "Condizione" (setq gdev-test-lavorazione--snippet-valutato t))))
            (let ((testo (buffer-string)))
              (should-error (gdev-snippets--inserisci-in-lavorazione contesto "gdev-prova-trasformazione")
                            :type 'user-error)
              (should-error (gdev-snippets--inserisci-in-lavorazione contesto "gdev-prova-condizione")
                            :type 'user-error)
              (should-not gdev-test-lavorazione--snippet-valutato)
              (should (equal testo (buffer-string))))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory radice t))))

;;; gdev-lavorazione-test.el ends here
