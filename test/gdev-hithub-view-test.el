;;; gdev-hithub-view-test.el --- Prove della panoramica di HitHub e dello stato di Hit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La panoramica disegna stati leggibili, conserva la voce selezionata,
;; ignora le risposte superate e collega pulsanti, tasti e azioni agli
;; stessi comandi.  L'intestazione di Hit riassume lo stato con una sola
;; chiamata a git.

;;; Code:

(require 'ert)
(require 'gdev-ui)

(defvar gdev-github-after-change-functions)
(defvar gdev-menu-personal-items)
(defvar gdevprova-variable)

(defun gdev-test-hithub--load ()
  "Carica HitHub e le sue viste."
  (load (gdev-module-file :tools 'hithub ".el") nil t t)
  (load (expand-file-name "gdev-hithub-view" (file-name-directory (gdev-module-file :tools 'hithub ".el")))
        nil t))

(defconst gdev-test-hithub--pulls
  "[{\"number\":214,\"title\":\"Aggiunge l'anteprima web\",\"state\":\"OPEN\",\"isDraft\":false,
     \"headRefName\":\"anteprima\",\"baseRefName\":\"main\",\"author\":{\"login\":\"giacomo\"},
     \"updatedAt\":\"2026-11-17T09:00:00Z\",\"reviewDecision\":\"APPROVED\",
     \"statusCheckRollup\":[{\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},
                            {\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]},
    {\"number\":213,\"title\":\"Corregge il pannello\",\"state\":\"OPEN\",\"isDraft\":true,
     \"headRefName\":\"pannello\",\"baseRefName\":\"main\",\"author\":{\"login\":\"lucia\"},
     \"updatedAt\":\"2026-11-16T09:00:00Z\",\"reviewDecision\":\"\",
     \"statusCheckRollup\":[{\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"},
                            {\"status\":\"IN_PROGRESS\",\"conclusion\":\"\"}]},
    {\"number\":205,\"title\":\"Aggiorna Magit\",\"state\":\"MERGED\",\"isDraft\":false,
     \"headRefName\":\"magit\",\"baseRefName\":\"main\",\"author\":{\"login\":\"giacomo\"},
     \"updatedAt\":\"2026-11-10T09:00:00Z\",\"reviewDecision\":null,\"statusCheckRollup\":[]}]"
  "Tre richieste: aperta e approvata, bozza con un controllo fallito, unita.")

(defmacro gdev-test-hithub--with-view (&rest body)
  "Esegue BODY con una panoramica le cui richieste a gh restano in attesa.
Le risposte si consegnano con `reply'; `requests' elenca gli argomenti."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "gdev-hithub-" t)))
          (callbacks nil)
          (requests nil)
          (gdev-github-after-change-functions nil))
     (cl-letf (((symbol-function 'gdev-github--request)
                (lambda (_directory callback &rest arguments)
                  (push arguments requests)
                  (push (cons arguments callback) callbacks)
                  t)))
       (cl-flet ((reply (prefix text &optional failure)
                   ;; Risponde alla richiesta più recente che inizia con PREFIX.
                   (let ((entry (seq-find (lambda (entry) (equal (seq-take (car entry) (length prefix)) prefix))
                                          callbacks)))
                     (setq callbacks (delq entry callbacks))
                     (funcall (cdr entry) text failure))))
         (let ((buffer (save-window-excursion (gdev-github-overview root))))
           (unwind-protect
               (with-current-buffer buffer ,@body)
             (kill-buffer buffer)
             (delete-directory root t)))))))

(ert-deftest gdev-test-hithub-overview-shows-readable-states ()
  "Ogni voce mostra icona, parola di stato, dettagli, controlli e revisione."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (should (member '("repo" "view" "--json" "nameWithOwner,description,url") requests))
    (should (seq-find (lambda (arguments) (equal (seq-take arguments 2) '("pr" "list"))) requests))
    (should (string-match-p "Caricamento da GitHub" (buffer-string)))
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (let ((text (buffer-string)))
      (dolist (expected '("Aperte" "Aperta · #214 · anteprima → main · @giacomo"
                          "2 controlli riusciti" "Approvata"
                          "Bozza · #213" "1 controllo non riuscito"
                          "Unita · #205" "Richieste  3"))
        (should (string-match-p (regexp-quote expected) text))))
    ;; Il colore accompagna la parola: la faccia sta sul testo dello stato.
    (goto-char (point-min))
    (search-forward "Unita")
    (should (eq (get-text-property (1- (point)) 'face) 'gdev-ui-status-accent))
    (goto-char (point-min))
    (search-forward "1 controllo non riuscito")
    (should (eq (get-text-property (1- (point)) 'face) 'gdev-ui-status-error))))

(ert-deftest gdev-test-hithub-overview-keeps-the-selected-item ()
  "Dopo un aggiornamento resta selezionata la stessa voce, anche se si sposta."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (goto-char (point-min))
    (gdev-github-view-next)
    (gdev-github-view-next)
    (should (equal (get-text-property (point) 'gdev-github-item) "213"))
    ;; L'overlay copre entrambe le righe della voce.
    (should (string-match-p "Corregge il pannello"
                            (buffer-substring (overlay-start gdev-github-view--selection)
                                              (overlay-end gdev-github-view--selection))))
    (should (string-match-p "#213"
                            (buffer-substring (overlay-start gdev-github-view--selection)
                                              (overlay-end gdev-github-view--selection))))
    (gdev-github-view-refresh)
    (let ((reordered (json-encode (reverse (json-parse-string gdev-test-hithub--pulls
                                                              :object-type 'alist :array-type 'list
                                                              :null-object nil :false-object :json-false)))))
      (reply '("pr" "list") reordered))
    (should (equal (get-text-property (point) 'gdev-github-item) "213"))
    (gdev-github-view-previous)
    (should (equal (get-text-property (point) 'gdev-github-item) "205"))
    (gdev-github-view-previous)
    (should (equal (get-text-property (point) 'gdev-github-item) "205"))))

(ert-deftest gdev-test-hithub-overview-ignores-a-superseded-reply ()
  "Una risposta arrivata dopo una richiesta più recente non cambia la vista."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (let ((first (cdr (seq-find (lambda (entry) (equal (seq-take (car entry) 2) '("pr" "list"))) callbacks))))
      (gdev-github-view-toggle-filter)
      (should (member "all" (car requests)))
      (reply '("pr" "list" "--limit" "50" "--json"
               "number,title,state,isDraft,headRefName,baseRefName,author,updatedAt,reviewDecision,statusCheckRollup"
               "--state")
             gdev-test-hithub--pulls)
      (funcall first "[]" nil)
      (should (string-match-p "Tutte" (buffer-string)))
      (should (string-match-p "#214" (buffer-string))))))

(ert-deftest gdev-test-hithub-overview-states-and-sections ()
  "Stato vuoto con azione, errore con «Riprova» e accesso, cambio di sezione."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (reply '("pr" "list") "[]")
    (should (string-match-p "Nessuna richiesta aperta" (buffer-string)))
    (should (text-property-search-forward 'help-echo "Crea una voce nella sezione · c" t))
    (goto-char (point-min))
    (should (search-forward "Nuova richiesta" nil t))
    (should (button-at (1- (point))))
    (gdev-github-view-show-section 'runs)
    (should (equal (seq-take (car requests) 2) '("run" "list")))
    (reply '("run" "list") nil "Accedi a GitHub con gh auth login")
    (let ((text (buffer-string)))
      (should (string-match-p "GitHub non ha risposto" text))
      (should (string-match-p "Riprova" text))
      (should (string-match-p "Accedi a GitHub" text)))
    ;; Tornando alle richieste valgono i dati ancora recenti.
    (let ((count (length requests)))
      (gdev-github-view-show-section 'pulls)
      (should (= (length requests) count)))
    ;; Il tasto 3 e la scelta per nome da M-x portano alla sezione indicata.
    (let ((last-command-event ?3))
      (call-interactively #'gdev-github-view-show-section))
    (should (eq gdev-github-view--current 'runs))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Versioni")))
      (let ((last-command-event ?\r))
        (call-interactively #'gdev-github-view-show-section)))
    (should (eq gdev-github-view--current 'releases))))

(ert-deftest gdev-test-hithub-overview-actions-share-the-commands ()
  "Invio, `a', il menu contestuale e le modifiche riuscite usano le stesse azioni."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (goto-char (point-min))
    (gdev-github-view-next)
    (let (calls)
      (cl-letf (((symbol-function 'gdev-github--pull-request-act)
                 (lambda (directory number action) (push (list directory number action) calls)))
                ((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?u))))
        (call-interactively (keymap-lookup gdev-github-view-mode-map "RET"))
        (call-interactively (keymap-lookup gdev-github-view-mode-map "a"))
        (should (equal (reverse calls) (list (list root "214" ?i) (list root "214" ?u))))))
    ;; Il titolo è un pulsante che apre la stessa voce.
    (let (opened)
      (cl-letf (((symbol-function 'gdev-github-view-open) (lambda () (interactive) (setq opened t))))
        (goto-char (point-min))
        (search-forward "Corregge il pannello")
        (push-button (1- (point)))
        (should opened)))
    ;; Una modifica riuscita su GitHub aggiorna la panoramica dello stesso archivio.
    (let ((count (length requests)))
      (run-hook-with-args 'gdev-github-after-change-functions root)
      (should (> (length requests) count)))))

(ert-deftest gdev-test-hithub-topic-renders-the-conversation ()
  "La conversazione mostra stato, campi, descrizione e interventi in ordine."
  (gdev-test-hithub--load)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-hithub-topic-" t)))
         (gdev-github-after-change-functions nil)
         callback buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-github--request)
                   (lambda (_directory function &rest arguments)
                     (should (equal (seq-take arguments 3) '("pr" "view" "214")))
                     (setq callback function))))
          (setq buffer (save-window-excursion (gdev-github-topic root 'pull 214)))
          (with-current-buffer buffer
            (should (string-match-p "Caricamento da GitHub" (buffer-string)))
            (funcall callback
                     (concat "{\"number\":214,\"title\":\"Aggiunge l'anteprima\",\"state\":\"OPEN\","
                             "\"isDraft\":false,\"author\":{\"login\":\"giacomo\"},\"url\":\"https://example.invalid\","
                             "\"body\":\"Descrive il cambiamento.\",\"labels\":[{\"name\":\"ui\"}],"
                             "\"assignees\":[{\"login\":\"lucia\"}],\"baseRefName\":\"main\",\"headRefName\":\"anteprima\","
                             "\"reviewDecision\":\"CHANGES_REQUESTED\",\"statusCheckRollup\":[],"
                             "\"additions\":12,\"deletions\":3,\"changedFiles\":2,\"updatedAt\":\"2026-11-17T09:00:00Z\","
                             "\"comments\":[{\"author\":{\"login\":\"lucia\"},\"body\":\"Secondo\",\"createdAt\":\"2026-11-17T08:00:00Z\"}],"
                             "\"reviews\":[{\"author\":{\"login\":\"marco\"},\"body\":\"Primo\",\"state\":\"CHANGES_REQUESTED\","
                             "\"submittedAt\":\"2026-11-17T07:00:00Z\"}]}")
                     nil)
            (let ((text (buffer-string)))
              (dolist (expected '("Aggiunge l'anteprima" "Aperta · #214 · @giacomo" "Revisiona"
                                  "anteprima → main" "Modifiche richieste" "+12 −3 · 2 file"
                                  "ui" "@lucia" "Descrive il cambiamento." "Conversazione · 2"))
                (should (string-match-p (regexp-quote expected) text)))
              (should (< (string-match "Primo" text) (string-match "Secondo" text))))
            ;; Il cambio di tema ridisegna dai dati ricevuti.
            (let ((inhibit-read-only t)) (erase-buffer))
            (gdev-github-view--redraw-all)
            (should (string-match-p "Descrive il cambiamento\\." (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gdev-test-hithub-overview-narrow-keeps-the-full-text ()
  "In una finestra stretta la riga si accorcia e il testo completo resta nel suggerimento."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (cl-letf (((symbol-function 'gdev-github-view--width)
               (lambda () (+ gdev-github-view--indent 12
                             (gdev-ui-string-pixel-width "Aperta · #214 · ante")))))
      (reply '("pr" "list") gdev-test-hithub--pulls)
      (should-not (string-match-p "anteprima → main · @giacomo" (buffer-string)))
      (goto-char (point-min))
      (let ((match (text-property-search-forward
                    'help-echo "Aperta · #214 · anteprima → main · @giacomo"
                    (lambda (expected actual) (and (stringp actual) (string-prefix-p expected actual))))))
        (should match)
        (should (string-match-p "…" (buffer-substring (prop-match-beginning match)
                                                      (prop-match-end match))))))))

(ert-deftest gdev-test-hithub-views-follow-the-theme ()
  "Un cambio di tema ridisegna panoramica e conversazione senza chiedere di nuovo i dati."
  (gdev-test-hithub--load)
  (should (memq #'gdev-github-view--redraw-all gdev-ui-after-theme-hook))
  (gdev-test-hithub--with-view
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (let ((count (length requests))
          (inhibit-read-only t))
      (erase-buffer)
      (gdev-github-view--redraw-all)
      (should (string-match-p "#214" (buffer-string)))
      (should (= (length requests) count)))))

(ert-deftest gdev-test-hithub-relative-age ()
  "Il tempo trascorso si legge in italiano."
  (gdev-test-hithub--load)
  (let ((now (parse-iso8601-time-string "2026-11-17T12:00:00Z")))
    (should (equal (gdev-github-view--age "2026-11-17T11:59:30Z" now) "adesso"))
    (should (equal (gdev-github-view--age "2026-11-17T11:15:00Z" now) "45 min fa"))
    (should (equal (gdev-github-view--age "2026-11-17T10:30:00Z" now) "1 ora fa"))
    (should (equal (gdev-github-view--age "2026-11-17T09:00:00Z" now) "3 ore fa"))
    (should (equal (gdev-github-view--age "2026-11-16T09:00:00Z" now) "ieri"))
    (should (equal (gdev-github-view--age "2026-11-13T09:00:00Z" now) "4 giorni fa"))
    (should (equal (gdev-github-view--age "2026-10-01T09:00:00Z" now) "01/10/2026"))
    (should-not (gdev-github-view--age "" now))))

(ert-deftest gdev-test-ui-actions-wrap-and-share-the-command ()
  "La barra delle azioni va a capo quando manca spazio e usa il comando dato."
  (with-temp-buffer
    (let (pressed)
      (gdev-ui-insert-actions
       (list (list "git-commit" "●" "Registra" (lambda () (setq pressed 'registra)) :primary t)
             (list "push" "↑" "Invia" (lambda () (setq pressed 'invia)) :help "Invia · P"))
       10000)
      (should (= (count-lines (point-min) (point-max)) 1))
      (goto-char (point-min))
      (search-forward "Registra")
      (should (eq (get-text-property (1- (point)) 'face) 'gdev-ui-action-primary))
      (push-button (1- (point)))
      (should (eq pressed 'registra))
      (search-forward "Invia")
      (should (equal (get-text-property (1- (point)) 'help-echo) "Invia · P"))
      (erase-buffer)
      (gdev-ui-insert-actions
       (list (list "git-commit" "●" "Registra" #'ignore) (list "push" "↑" "Invia" #'ignore))
       (gdev-ui-string-pixel-width " ● Registra "))
      (should (= (count-lines (point-min) (point-max)) 2)))))

(ert-deftest gdev-test-hit-header-summarises-one-status-call ()
  "Lo stato di Hit riassume ramo, conteggi e azione principale da git status."
  (load (gdev-module-file :tools 'git ".el") nil t t)
  (let ((summary (gdev-git--summary
                  '("# branch.oid 0123" "# branch.head main" "# branch.upstream origin/main"
                    "# branch.ab +2 -1" "1 M. N... 100644 100644 100644 a b file.el"
                    "1 .M N... 100644 100644 100644 a b altro.el" "1 MM N... 100644 100644 100644 a b doppio.el"
                    "u UU N... 1 2 3 4 a b c conflitto.el" "? nuovo.txt" "! ignorato.o"))))
    (should (equal (plist-get summary :branch) "main"))
    (should (equal (plist-get summary :upstream) "origin/main"))
    (should (equal (mapcar (lambda (key) (plist-get summary key))
                           '(:ahead :behind :staged :unstaged :untracked :conflicts))
                   '(2 1 2 2 1 1)))
    (should (equal (mapcar #'caddr (gdev-git--badges summary))
                   '("1 conflitto" "2 nell'indice" "2 da preparare" "1 non tracciato"
                     "2 da inviare" "1 da scaricare")))
    ;; Una sola azione principale: con modifiche nell'indice è «Registra».
    (let ((primary (seq-filter (lambda (action) (plist-get (nthcdr 4 action) :primary))
                               (gdev-git--actions summary))))
      (should (equal (mapcar #'caddr primary) '("Registra"))))
    (let ((clean (gdev-git--summary '("# branch.head main" "# branch.ab +1 -0"))))
      (should (equal (mapcar #'caddr (gdev-git--badges clean)) '("1 da inviare")))
      (should (equal (mapcar #'caddr (seq-filter (lambda (action) (plist-get (nthcdr 4 action) :primary))
                                                 (gdev-git--actions clean)))
                     '("Invia"))))
    (should (equal (mapcar #'caddr (gdev-git--badges (gdev-git--summary '("# branch.head main"))))
                   '("Albero di lavoro pulito")))
    (should-not (plist-get (gdev-git--summary '("# branch.head (detached)")) :branch))))

(ert-deftest gdev-test-hit-header-follows-the-narrowest-window ()
  "L'intestazione si ridispone senza rieseguire git e lascia al loro posto le sezioni."
  (load (gdev-module-file :tools 'git ".el") nil t t)
  (let ((calls 0)
        (width 10000))
    (cl-letf (((symbol-function 'magit-git-lines)
               (lambda (&rest _) (cl-incf calls)
                 '("# branch.head main" "# branch.upstream origin/main" "# branch.ab +1 -0"
                   "1 M. N... 100644 100644 100644 a b a.el" "? nuovo.txt")))
              ((symbol-function 'gdev-ui-buffer-pixel-width) (lambda (&rest _) width)))
      (with-temp-buffer
        (gdev-git--insert-header)
        (let ((section (point-marker))
              (lines (count-lines (point-min) (point))))
          (insert "Ramo: main\n")
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (setq width (gdev-ui-string-pixel-width " ● Registra "))
            (gdev-git--rewrap-header (selected-window))
            (should (> (count-lines (point-min) section) lines))
            (should (equal (buffer-substring section (+ section 5)) "Ramo:"))
            (should (= (text-property-any (point-min) (point-max) 'gdev-git-header t) (point-min)))
            (should-not (get-text-property section 'gdev-git-header))
            (setq width 10000)
            (gdev-git--rewrap-header (selected-window))
            (should (= (count-lines (point-min) section) lines))
            (should (equal (buffer-substring section (+ section 5)) "Ramo:"))
            (should (= calls 1))
            ;; In una finestra minima il ramo lungo si accorcia e resta intero nel suggerimento.
            (setq width (gdev-ui-string-pixel-width "• main → orig"))
            (gdev-git--rewrap-header (selected-window))
            (goto-char (point-min))
            (let ((match (text-property-search-forward 'help-echo "main → origin/main" t)))
              (should match)
              (should (string-suffix-p "…" (buffer-substring-no-properties
                                            (prop-match-beginning match) (prop-match-end match)))))
            (should (= calls 1))))))))

(ert-deftest gdev-test-hit-commands-never-show-the-fork-name ()
  "which-key e i menu mostrano le etichette di Hit al posto dei nomi magit-."
  (require 'package)
  (package-activate-all)
  (load (gdev-module-file :tools 'git ".el") nil t t)
  (require 'which-key)
  (require 'gdev-menu)
  (let ((which-key-allow-multiple-replacements nil))
    (should (equal (cdr (which-key--maybe-replace (cons "C-x M-g" "magit-dispatch")))
                   "Comandi di Hit"))
    ;; Un comando senza etichetta propria prende comunque il nome GDev.
    (should (equal (cdr (which-key--maybe-replace (cons "C-c x" "magit-unknown-thing")))
                   "Hit · unknown thing"))
    ;; Le altre sostituzioni restano attive.
    (should (equal (cdr (which-key--maybe-replace (cons "C-c x" "gdev-rename-thing")))
                   "rename-thing")))
  (should (equal (gdev-menu--command-label 'magit-edit-thing) "Modifica l'elemento"))
  (should (equal (gdev-menu--command-label 'magit-log-buffer-file) "Hit · log buffer file"))
  (should (equal (gdev-menu--command-label 'gdev-git-status) "Git status")))

;;;; Nomi GDev in M-x

(require 'gdev-keys)
(defvar which-key-replacement-alist)

(defconst gdev-test-hithub--fake-commands
  '("gdevprova-run" "gdevprova-text" "gdevprova-hidden" "gdevprova-old" "gdevprova-taken"
    "gdevprova-clash" "gdevprova-helper" "gdevprova-variable" "gdevprova-late"
    "gdevalias-run" "gdevalias-text"
    "gdevalias-hidden" "gdevalias-old" "gdevalias-taken" "gdevalias-clash" "gdevalias-helper"
    "gdevalias-late")
  "Nomi del fork finto usato per provare gli alias di M-x.")

(ert-deftest gdev-test-fork-commands-take-the-gdev-name-in-mx ()
  "M-x e M-X offrono il nome GDev dei comandi di un fork al posto dell'originale."
  (require 'which-key)
  (let ((gdev-keys--command-labels (make-hash-table :test #'eq))
        (gdev-keys--command-prefixes nil)
        (gdev-keys--command-aliases nil)
        (gdev-keys--aliases-stale nil)
        (which-key-replacement-alist (copy-sequence which-key-replacement-alist)))
    (unwind-protect
        (progn
          (defalias 'gdevprova-run
            (lambda ()
              "Avvia un comando Gdevprova, non Gdevprovafoo: `gdevprova-taken' o \\[gdevprova-run]."
              (interactive)
              'run))
          (defalias 'gdevprova-text (lambda () (interactive nil text-mode) 'text))
          (defalias 'gdevprova-hidden (lambda () (interactive) 'hidden))
          (put 'gdevprova-hidden 'completion-predicate #'ignore)
          (defalias 'gdevprova-old #'gdevprova-run)
          (make-obsolete 'gdevprova-old #'gdevprova-run "Gdevprova 1.0")
          (defalias 'gdevprova-taken (lambda () (interactive) 'taken))
          (defalias 'gdevalias-taken (lambda () (interactive) 'other))
          (defalias 'gdevprova-clash (lambda () (interactive) 'clash))
          (defalias 'gdevalias-clash (lambda () 'function))
          (defalias 'gdevprova-helper (lambda () 'helper))
          (gdev-keys-register-commands "gdevprova-" "Prova" :alias "gdevalias-")
          (should gdev-keys--aliases-stale)
          (gdev-keys-refresh-aliases)
          (should-not gdev-keys--aliases-stale)
          (with-temp-buffer
            (let* ((buffer (current-buffer))
                   (offered (lambda (symbol) (command-completion-default-include-p symbol buffer))))
              ;; Un comando comune: l'alias lancia l'originale, che esce da M-x.
              (should (eq (symbol-function 'gdevalias-run) 'gdevprova-run))
              (should (eq (call-interactively 'gdevalias-run) 'run))
              (should (funcall offered 'gdevalias-run))
              (should-not (funcall offered 'gdevprova-run))
              ;; L'alias segue le modalità dichiarate dall'originale.
              (should-not (funcall offered 'gdevalias-text))
              (let ((major-mode 'text-mode))
                (should (funcall offered 'gdevalias-text))
                (should-not (funcall offered 'gdevprova-text)))
              ;; Un predicato già presente vale anche per l'alias.
              (should (fboundp 'gdevalias-hidden))
              (should-not (funcall offered 'gdevalias-hidden))
              (should-not (funcall offered 'gdevprova-hidden))
              ;; Un nome obsoleto esce da M-x senza un alias proprio.
              (should-not (fboundp 'gdevalias-old))
              (should-not (funcall offered 'gdevprova-old))
              ;; Un comando GDev con lo stesso nome resta com'è e prende il
              ;; posto dell'originale, come hit-status.
              (should (eq (call-interactively 'gdevalias-taken) 'other))
              (should (funcall offered 'gdevalias-taken))
              (should-not (funcall offered 'gdevprova-taken))
              ;; Se il nome GDev non è un comando, l'originale resta visibile.
              (should (eq (funcall 'gdevalias-clash) 'function))
              (should (funcall offered 'gdevprova-clash))
              ;; Le funzioni che non sono comandi non ricevono alias.
              (should-not (fboundp 'gdevalias-helper))
              ;; La descrizione cambia il nome intero del fork e i comandi
              ;; citati, non quelli che servono a trovare i tasti.
              (should (equal (documentation 'gdevalias-run t)
                             (concat "Avvia un comando Prova, non Gdevprovafoo: "
                                     "`gdevalias-taken' o \\[gdevprova-run].")))
              ;; M-X cerca nelle mappe della vista, dove compare l'originale.
              (use-local-map (define-keymap "C-c r" #'gdevprova-run))
              (should (command-completion-using-modes-and-keymaps-p 'gdevalias-run buffer))
              (should-not (command-completion-using-modes-and-keymaps-p 'gdevprova-run buffer))
              (let ((for-buffer (command-completion--command-for-this-buffer-function)))
                (should (funcall for-buffer 'gdevalias-run buffer))
                (should-not (funcall for-buffer 'gdevprova-run buffer))
                (let ((major-mode 'text-mode))
                  (should (funcall for-buffer 'gdevalias-text buffer))
                  (should-not (funcall for-buffer 'gdevprova-text buffer))))))
          ;; Solo i file del fork segnalano nuovi comandi da rinominare.
          (gdev-keys--note-load "/tmp/other.el")
          (should-not gdev-keys--aliases-stale)
          (defalias 'gdevprova-late (lambda () (interactive) 'late))
          (gdev-keys--note-load "/tmp/fork/gdevprova-extra.el")
          (should gdev-keys--aliases-stale)
          (gdev-keys-refresh-aliases)
          (should (eq (symbol-function 'gdevalias-late) 'gdevprova-late))
          ;; Una nuova sincronizzazione non tocca i comandi già rinominati.
          (gdev-keys--define-aliases)
          (should (eq (get 'gdevprova-hidden 'gdev-keys-previous-predicate) #'ignore))
          (should-not (get 'gdevprova-run 'gdev-keys-previous-predicate))
          (should (eq (call-interactively 'gdevalias-taken) 'other)))
      (dolist (name gdev-test-hithub--fake-commands)
        (when-let* ((symbol (intern-soft name)))
          (fmakunbound symbol)
          (setplist symbol nil)
          (makunbound symbol))))))

(ert-deftest gdev-test-hit-commands-take-the-hit-name-in-mx ()
  "In M-x i comandi di Hit si chiamano hit-… e lanciano i comandi del fork."
  (require 'package)
  (package-activate-all)
  (require 'gdev-commands)
  (load (gdev-module-file :tools 'git ".el") nil t t)
  (require 'magit)
  (gdev-keys--define-aliases)
  (should (eq (symbol-function 'hit-commit) 'magit-commit))
  ;; Il comando di stato di GDev conserva il nome hit-status.
  (should (eq (symbol-function 'hit-status) 'gdev-git-status))
  (with-temp-buffer
    (should (command-completion-default-include-p 'hit-commit (current-buffer)))
    (should (command-completion-default-include-p 'hit-status (current-buffer)))
    (should-not (command-completion-default-include-p 'magit-commit (current-buffer)))
    (should-not (command-completion-default-include-p 'magit-status (current-buffer))))
  (let ((doc (documentation 'hit-file-dispatch))
        (case-fold-search t))
    (should (string-match-p "\\_<Hit\\_>" doc))
    (should (string-search "hit-dispatch" doc))
    (should-not (string-match-p "magit" doc))))

(ert-deftest gdev-test-fork-aliases-show-the-original-keys-in-mx ()
  "Accanto a un alias M-x mostra i tasti dell'originale e mai il nome del fork."
  (require 'which-key)
  (let ((gdev-keys--command-labels (make-hash-table :test #'eq))
        (gdev-keys--command-prefixes nil)
        (gdev-keys--command-aliases nil)
        (gdev-keys--aliases-stale nil)
        (which-key-replacement-alist (copy-sequence which-key-replacement-alist)))
    (unwind-protect
        (progn
          (defalias 'gdevprova-run (lambda () (interactive) 'run))
          (defalias 'gdevprova-text (lambda () (interactive) 'text))
          (gdev-keys-register-commands "gdevprova-" "Prova" :alias "gdevalias-")
          (gdev-keys-refresh-aliases)
          ;; L'annotatore legge le mappe del buffer mostrato nella finestra selezionata.
          (save-window-excursion
            (let ((buffer (generate-new-buffer " *gdev-prova*")))
              (unwind-protect
                  (progn
                    (set-window-buffer (selected-window) buffer)
                    (with-current-buffer buffer
                      (use-local-map (define-keymap "C-c r" #'gdevprova-run))
                      (let ((entries (read-extended-command--affixation
                                      '("gdevalias-run" "gdevalias-text" "gdevprova-run"))))
                        ;; Con un tasto: il tasto. Senza: niente, e non «(gdevprova-text)».
                        (should (equal (substring-no-properties (nth 2 (nth 0 entries))) " (C-c r)"))
                        (should (equal (substring-no-properties (nth 2 (nth 1 entries))) ""))
                        ;; Un comando non rinominato resta com'è.
                        (should (equal (substring-no-properties (nth 2 (nth 2 entries))) " (C-c r)")))
                      ;; Marginalia cerca i tasti con il nome dell'originale.
                      (when (require 'marginalia nil t)
                        (should (equal (substring-no-properties (marginalia-annotate-binding "gdevalias-run"))
                                       " (C-c r)")))))
                (kill-buffer buffer)))))
      (dolist (name gdev-test-hithub--fake-commands)
        (when-let* ((symbol (intern-soft name)))
          (fmakunbound symbol)
          (setplist symbol nil)
          (makunbound symbol))))))

(ert-deftest gdev-test-command-palette-follows-renamed-commands ()
  "La tavolozza elenca per etichetta il comando reale e per nome solo quello GDev."
  (require 'which-key)
  (require 'gdev-commands)
  (let ((gdev-modules '((:ui workbench) (:tools git)))
        (gdev-menu-personal-items '(["Azione rinominata" gdevprova-run]))
        (read-extended-command-predicate #'command-completion-default-include-p)
        (gdev-keys--command-labels (make-hash-table :test #'eq))
        (gdev-keys--command-prefixes nil)
        (gdev-keys--command-aliases nil)
        (gdev-keys--aliases-stale nil)
        (which-key-replacement-alist (copy-sequence which-key-replacement-alist))
        ran)
    (unwind-protect
        (progn
          (defalias 'gdevprova-run (lambda () (interactive) (setq ran t)))
          (defalias 'gdevprova-helper (lambda () 'helper))
          (set 'gdevprova-variable 1)
          (gdev-keys-register-commands "gdevprova-" "Prova" :alias "gdevalias-")
          ;; Nessuno ha ancora aperto M-x: gli alias non esistono.
          (should-not (fboundp 'gdevalias-run))
          (cl-letf (((symbol-function 'gdev-quick-open--read)
                     (lambda (_initial table &rest _)
                       ;; Per nome la tavolozza prepara gli alias, offre solo il nome GDev
                       ;; e solo comandi: né funzioni né variabili.
                       (should (equal (all-completions ">gdevalias-r" table) '("gdevalias-run")))
                       (should-not (all-completions ">gdevprova-" table))
                       ;; Per etichetta il catalogo usa il comando reale del menu.
                       (let ((choices (all-completions ">Azione rin" table)))
                         (should (equal choices '("Azione rinominata · Strumenti › Comandi personali")))
                         (concat ">" (car choices))))))
            (gdev-command-palette)
            (should ran)))
      (dolist (name gdev-test-hithub--fake-commands)
        (when-let* ((symbol (intern-soft name)))
          (fmakunbound symbol)
          (setplist symbol nil)
          (makunbound symbol))))))

(defconst gdev-test-hithub--topic-json
  (concat "{\"number\":214,\"title\":\"Aggiunge l'anteprima\",\"state\":\"OPEN\","
          "\"isDraft\":false,\"author\":{\"login\":\"giacomo\"},\"url\":\"https://example.invalid\","
          "\"body\":\"Prima riga.\\r\\nSeconda riga.\\r\\n\",\"labels\":[],\"assignees\":[],"
          "\"baseRefName\":\"main\",\"headRefName\":\"anteprima\",\"reviewDecision\":\"\","
          "\"statusCheckRollup\":[],\"additions\":1,\"deletions\":0,\"changedFiles\":1,"
          "\"updatedAt\":\"2026-11-17T09:00:00Z\","
          "\"comments\":[{\"author\":{\"login\":\"lucia\"},\"body\":\"Commento.\\r\\nSu due righe.\","
          "\"createdAt\":\"2026-11-17T08:00:00Z\"}],\"reviews\":[]}")
  "Conversazione di prova con i ritorni a capo CRLF dei testi scritti sul web.")

(ert-deftest gdev-test-hithub-topic-text-has-no-carriage-returns ()
  "I testi di GitHub con CRLF non mostrano ^M e restano su righe separate."
  (gdev-test-hithub--load)
  (should (equal (gdev-github-view--text "uno\r\ndue\r\n") "uno\ndue"))
  (let* ((root (file-name-as-directory (make-temp-file "gdev-hithub-topic-" t)))
         (gdev-github-after-change-functions nil)
         callback buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-github--request)
                   (lambda (_directory function &rest _) (setq callback function))))
          (setq buffer (save-window-excursion (gdev-github-topic root 'pull 214)))
          (with-current-buffer buffer
            (funcall callback gdev-test-hithub--topic-json nil)
            (should-not (string-search "\r" (buffer-string)))
            (should (string-search "Prima riga.\nSeconda riga." (buffer-string)))
            (should (string-search "Commento.\nSu due righe." (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gdev-test-hithub-topic-refresh-keeps-the-reading-place ()
  "Aggiornare una conversazione già mostrata non la riporta a «Caricamento»."
  (gdev-test-hithub--load)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-hithub-topic-" t)))
         (gdev-github-after-change-functions nil)
         callback buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-github--request)
                   (lambda (_directory function &rest _) (setq callback function))))
          (setq buffer (save-window-excursion (gdev-github-topic root 'pull 214)))
          (with-current-buffer buffer
            (funcall callback gdev-test-hithub--topic-json nil)
            (goto-char (search-forward "Su due righe"))
            (let ((place (point)))
              (gdev-github-topic-refresh)
              (should (string-search "Su due righe" (buffer-string)))
              (should-not (string-search "Caricamento da GitHub" (buffer-string)))
              (should (= (point) place))
              (funcall callback gdev-test-hithub--topic-json nil)
              (should (= (point) place)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gdev-test-hithub-topic-without-gh-shows-the-error ()
  "Se gh manca la conversazione mostra l'errore e «Riprova», senza segnalare."
  (gdev-test-hithub--load)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-hithub-topic-" t)))
         (gdev-github-after-change-functions nil)
         buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'gdev-github--request)
                   (lambda (&rest _) (user-error "gh non è installato"))))
          (setq buffer (save-window-excursion (gdev-github-topic root 'issue 7)))
          (with-current-buffer buffer
            (should (string-search "gh non è installato" (buffer-string)))
            (should (string-search "Riprova" (buffer-string)))
            (should-not gdev-github-topic--request)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest gdev-test-hithub-empty-states-keep-a-placeholder-for-the-icon ()
  "L'icona degli stati vuoti ha un segnaposto: `propertize' su \"\" non porta immagini."
  (gdev-test-hithub--load)
  (let (fallbacks)
    (cl-letf (((symbol-function 'gdev-ui-icon)
               (lambda (_name fallback &rest _) (push fallback fallbacks) fallback)))
      (gdev-test-hithub--with-view
        (reply '("pr" "list") "[]")
        (should (string-search "Nessuna" (buffer-string)))))
    (should fallbacks)
    (should-not (member "" fallbacks))))

(ert-deftest gdev-test-hithub-gh-errors-name-the-real-cause ()
  "Un archivio senza remoto GitHub non si presenta come un problema di accesso."
  (gdev-test-hithub--load)
  (should (equal (gdev-github--error
                  (concat "none of the git remotes configured for this repository point to a known "
                          "GitHub host. To tell gh about a new GitHub host, please use `gh auth login`"))
                 "Questo archivio non ha un remoto su GitHub"))
  (should (equal (gdev-github--error "To get started with GitHub CLI, please run:  gh auth login")
                 "Accedi a GitHub con gh auth login"))
  (should (equal (gdev-github--error "You are not logged into any GitHub hosts. Run gh auth login")
                 "Accedi a GitHub con gh auth login"))
  (should (string-prefix-p "HitHub · Operazione non riuscita"
                           (gdev-github--error "HTTP 500: Server Error"))))

(ert-deftest gdev-test-hithub-overview-ignores-answers-for-other-filters ()
  "Una risposta chiesta con un filtro non si applica quando i filtri sono cambiati."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (gdev-github-view-search "foo")
    ;; Si cambia sezione e si torna: i dati recenti senza filtro bastano.
    (gdev-github-view-show-section 'issues)
    (gdev-github-view-show-section 'pulls)
    (reply '("pr" "list")
           "[{\"number\":9,\"title\":\"Solo per foo\",\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"x\",\"baseRefName\":\"main\",\"author\":{\"login\":\"a\"},\"updatedAt\":\"2026-11-17T09:00:00Z\",\"reviewDecision\":null,\"statusCheckRollup\":[]}]")
    (should-not (string-search "Solo per foo" (buffer-string)))
    (should (string-search "Aggiunge l'anteprima web" (buffer-string)))))

(ert-deftest gdev-test-hithub-changes-refresh-every-section ()
  "Dopo una modifica le altre sezioni non restano «fresche» con i dati di prima."
  (gdev-test-hithub--load)
  (gdev-test-hithub--with-view
    (reply '("pr" "list") gdev-test-hithub--pulls)
    (gdev-github-view-show-section 'issues)
    (should (plist-get (alist-get 'pulls gdev-github-view--data) :time))
    (run-hook-with-args 'gdev-github-after-change-functions root)
    (should-not (plist-get (alist-get 'pulls gdev-github-view--data) :time))))

(ert-deftest gdev-test-hithub-theme-redraw-survives-a-failing-view ()
  "Un errore nel ridisegno di una vista non ferma il cambio di tema."
  (gdev-test-hithub--load)
  (with-temp-buffer
    (let ((target (current-buffer))
          (original (symbol-function 'gdev-github-view--redraw)))
      (cl-letf (((symbol-function 'gdev-github-view--redraw)
                 (lambda () (if (eq (current-buffer) target) (error "Rotta") (funcall original)))))
        (should-not (condition-case nil
                        (progn (gdev-github-view--redraw-all) nil)
                      (error t)))))))

(ert-deftest gdev-test-hithub-github-values-appear-in-italian ()
  "Gli eventi e i motivi noti si traducono; i nuovi non mostrano trattini bassi."
  (gdev-test-hithub--load)
  (should (equal (gdev-github-view--translate "dynamic" gdev-github-view--events) "automatico"))
  (should (equal (gdev-github-view--translate "approval_requested" gdev-github-view--reasons)
                 "approvazione richiesta"))
  (should (equal (gdev-github-view--translate "RepositoryInvitation" gdev-github-view--subjects)
                 "Invito"))
  (should (equal (gdev-github-view--translate "evento_nuovo" gdev-github-view--events) "evento nuovo"))
  (should-not (gdev-github-view--translate nil gdev-github-view--events)))

(ert-deftest gdev-test-hit-hidden-status-follows-the-theme-when-shown ()
  "Uno stato di Hit non visibile si ridisegna con il tema nuovo quando torna visibile."
  (require 'package)
  (package-activate-all)
  (load (gdev-module-file :tools 'git ".el") nil t t)
  (require 'magit)
  (let ((refreshed 0))
    (cl-letf (((symbol-function 'magit-refresh-buffer) (lambda (&rest _) (cl-incf refreshed))))
      (with-temp-buffer
        ;; Un buffer con la modalità di Hit, non mostrato in alcuna finestra.
        (setq major-mode 'magit-status-mode)
        (gdev-git--refresh-after-theme)
        (should (= refreshed 0))
        (should gdev-git--theme-stale)
        ;; Tornando visibile si ridisegna una volta sola.
        (gdev-git--refresh-stale (current-buffer))
        (should (= refreshed 1))
        (should-not gdev-git--theme-stale)
        (gdev-git--refresh-stale (current-buffer))
        (should (= refreshed 1))))))

;;; gdev-hithub-view-test.el ends here
