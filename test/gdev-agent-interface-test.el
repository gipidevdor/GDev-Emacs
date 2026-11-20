;;; gdev-agent-interface-test.el --- Prove dell'interfaccia per agenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Controlla la scoperta dal checkout e i vincoli delle azioni dal vivo.

;;; Code:

(require 'ert)
(require 'gdev-agent-interface)

(ert-deftest gdev-agent-interface-inventory-follows-checkout ()
  "L'inventario riflette i cambiamenti delle dichiarazioni senza valutarle."
  (let* ((gdev-agent-interface--root (file-name-as-directory (make-temp-file "gdev-agent-" t)))
         (root gdev-agent-interface--root)
         (cli (expand-file-name "lisp/gdev-cli.el" root))
         (template (expand-file-name "templates/init.el" root))
         (module (expand-file-name "modules/ui/prova/config.el" root)))
    (unwind-protect
        (progn
          (dolist (file (list cli template module))
            (make-directory (file-name-directory file) t))
          (with-temp-file cli
            (insert "(error \"non leggere come programma\")\n"
                    "(defconst gdev-cli-commands '((\"prova\" . gdev-cli-prova)))\n"))
          (with-temp-file template (insert "(gdev! :ui (prova +flag))"))
          (with-temp-file module (insert "(defun gdev-prova () (interactive))\n"))
          (let ((inventory (gdev-agent-interface-inventory "develop" "gdev-prova")))
            (should (member "prova" (append (alist-get 'cli_commands inventory) nil)))
            (should (equal (alist-get 'flags (aref (alist-get 'default_modules inventory) 0)) ["+flag"]))
            (let ((symbol (aref (alist-get 'symbols inventory) 0)))
              (should (equal (alist-get 'file symbol) "modules/ui/prova/config.el"))
              (should (eq (alist-get 'interactive symbol) t))))
          (with-temp-file module (insert "\n(defun gdev-prova-nuova ())\n"))
          (let ((symbol (aref (alist-get 'symbols (gdev-agent-interface-inventory "develop" "gdev-prova")) 0)))
            (should (equal (alist-get 'name symbol) "gdev-prova-nuova"))
            (should (equal (alist-get 'line symbol) 2))))
      (delete-directory root t))))

(defvar gdev-agent-fixture-noninteractive-mode-map)

(ert-deftest gdev-agent-interface-reads-mode-options-without-evaluating-them ()
  "Riconosci le modalità interattive anche con opzioni esplicite e storiche."
  (require 'gdev-audit)
  (let* ((gdev-agent-interface--root (file-name-as-directory (make-temp-file "gdev-agent-mode-" t)))
         (root gdev-agent-interface--root)
         (source (expand-file-name "lisp/modalita.el" root))
         (prefix "gdev-agent-fixture-"))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source))
          (with-temp-file source
            (insert "(error \"Non valutare il sorgente\")\n"
                    "(define-derived-mode gdev-agent-fixture-default-mode special-mode \"Prova\")\n"
                    "(define-derived-mode gdev-agent-fixture-noninteractive-mode special-mode \"Prova\"\n"
                    "  :interactive nil)\n"
                    "(define-derived-mode gdev-agent-fixture-nildoc-mode special-mode \"Prova\" nil\n"
                    "  :group 'gdev :interactive nil)\n"
                    "(define-derived-mode gdev-agent-fixture-overridden-mode special-mode \"Prova\" \"Guida\"\n"
                    "  :interactive nil :interactive t)\n"
                    "(define-derived-mode gdev-agent-fixture-body-mode special-mode \"Prova\"\n"
                    "  (ignore) :interactive nil)\n"
                    "(define-minor-mode gdev-agent-fixture-internal-mode nil :interactive nil)\n"
                    "(define-minor-mode gdev-agent-fixture-legacy-mode nil nil \" P\" nil :interactive nil)\n"
                    "(define-minor-mode gdev-agent-fixture-restricted-mode nil :interactive (text-mode))\n"
                    "(define-globalized-minor-mode gdev-agent-fixture-global-mode\n"
                    "  gdev-agent-fixture-internal-mode ignore :interactive nil)\n"
                    "(defalias 'gdev-agent-fixture-alias 'forward-char)\n"))
          (let* ((entries (append (gdev-agent-interface--symbols prefix) nil))
                 (original (copy-tree entries))
                 (gdev-agent-fixture-noninteractive-mode-map (make-sparse-keymap)))
            (should (equal (mapcar (lambda (entry)
                                    (cons (string-remove-prefix prefix (alist-get 'name entry))
                                          (alist-get 'interactive entry)))
                                  entries)
                           '(("default-mode" . t)
                             ("noninteractive-mode" . :false)
                             ("nildoc-mode" . :false)
                             ("overridden-mode" . t)
                             ("body-mode" . t)
                             ("internal-mode" . :false)
                             ("legacy-mode" . :false)
                             ("restricted-mode" . t)
                             ("global-mode" . :false)
                             ("alias" . :false))))
            (should-not (fboundp 'gdev-agent-fixture-default-mode))
            (should-not (fboundp 'gdev-agent-fixture-alias))
            (cl-letf (((symbol-function 'gdev-agent-fixture-alias) #'forward-char))
              (should (equal (mapcar (lambda (entry)
                                       (should (eq (alist-get 'interactive entry) t))
                                       (string-remove-prefix prefix (alist-get 'name entry)))
                                     (gdev-audit--definitions entries))
                             '("default-mode" "overridden-mode" "body-mode" "restricted-mode" "alias"))))
            (keymap-set gdev-agent-fixture-noninteractive-mode-map "a" #'forward-char)
            (let ((routes (gdev-audit--mode-routes entries)))
              (should (= (length routes) 1))
              (should (equal (alist-get 'scope (car routes)) (concat prefix "noninteractive-mode")))
              (should (equal (alist-get 'effective (car routes)) "forward-char")))
            (should (equal entries original))))
      (delete-directory root t))))

(ert-deftest gdev-agent-interface-rejects-wrong-targets ()
  "Un checkout diverso, un percorso remoto o un'azione sconosciuta restano senza effetti."
  (require 'gdev-commands)
  (let ((calls 0))
    (cl-letf (((symbol-function 'gdev-open-file) (lambda (&rest _) (cl-incf calls))))
      (dolist (request (list (list "/checkout-diverso/" "status")
                             (list gdev-config-directory "open-file" "file-relativo")
                             (list gdev-config-directory "open-file" "/ssh:host:/tmp/file")
                             (list gdev-config-directory "eval" "(message \"ciao\")")))
        (let ((response (json-parse-string (apply #'gdev-agent-interface-request request)
                                           :object-type 'alist)))
          (should (eq (alist-get 'ok response) :false))
          (should (stringp (alist-get 'error response)))))
      (should (zerop calls)))))

(ert-deftest gdev-test-lavorazione-agent-condivide-il-sorgente ()
  "Le richieste usano la stessa bozza e lo stesso riquadro della GUI."
  (require 'gdev-lavorazione-agent)
  (gdev-test--with-layout
    (let* ((dir (make-temp-file "gdev-agent-composizione-" t))
           (file (expand-file-name "Bozza.lavorazione" dir))
           (dati (expand-file-name "piano.json" dir))
           (auto-mode-alist (cons '("\\.lavorazione\\'" . gdev-lavorazione-mode)
                                  auto-mode-alist))
           sorgente vista revisione)
      (unwind-protect
          (cl-labels ((call (action &rest args)
                        (json-parse-string
                         (apply #'gdev-agent-interface-request gdev-config-directory
                                (concat "lavorazione-" action) args)
                         :object-type 'alist)))
            (let* ((esito (call "catalogo"))
                   (azioni (alist-get 'actions esito)))
              (should (eq t (alist-get 'ok esito)))
              (should (seq-find (lambda (voce)
                                  (and (equal "apri-file" (alist-get 'name voce))
                                       (eq t (alist-get 'opens_document voce))))
                                azioni)))
            (let ((esito (call "apri" file)))
              (should (eq t (alist-get 'ok esito)))
              (setq revisione (alist-get 'revision (alist-get 'composition esito))
                    sorgente (find-buffer-visiting file)
                    vista (buffer-local-value 'gdev-lavorazione--vista sorgente))
              (should (window-live-p (get-buffer-window vista)))
              (should-not (file-exists-p file)))
            (with-temp-file dati
              (insert "{\"versione\":1,\"passi\":[{\"azione\":\"salva\",\"argomenti\":{}}]}"))
            (should (alist-get 'error (call "componi" file revisione dati)))
            (should (equal revisione (alist-get 'revision (alist-get 'composition (call "leggi" file)))))
            (with-temp-file dati
              (insert "{\"versione\":1,\"passi\":[{\"azione\":\"apri-file\",\"argomenti\":{\"file\":\"note è.txt\"}}]}"))
            (let ((esito (call "componi" file revisione dati)))
              (should (eq t (alist-get 'ok esito)))
              (should-not (file-exists-p file))
              (with-current-buffer vista
                (should (string-search "note è.txt" (buffer-string))))
              (setq revisione (alist-get 'revision (alist-get 'composition esito))))
            (with-current-buffer sorgente
              (goto-char (point-max))
              (insert "\n"))
            (should (alist-get 'error (call "componi" file revisione dati)))
            (should (alist-get 'error (call "salva" file revisione)))
            (setq revisione (alist-get 'revision (alist-get 'composition (call "leggi" file))))
            (should (eq t (alist-get 'ok (call "salva" file revisione))))
            (should (file-regular-p file))
            (with-temp-file file (insert "modifica esterna"))
            (should (alist-get 'error (call "componi" file revisione dati))))
        (when (buffer-live-p sorgente) (kill-buffer sorgente))
        (delete-directory dir t)))))

(ert-deftest gdev-agent-interface-shortcuts-follow-active-keymaps ()
  "La lettura dei tasti rispetta le scorciatoie locali e quelle oscurate."
  (require 'gdev-commands)
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (keymap-local-set "C-c q" #'gdev-undo)
    (keymap-local-set "C-c b" #'gdev-redo)
    (let* ((shortcut (alist-get 'shortcut (gdev-agent-interface--shortcuts "C-c q")))
           (bindings (alist-get 'keys (alist-get 'shortcut
                                                (gdev-agent-interface--shortcuts "gdev-redo")))))
      (should (equal (alist-get 'command shortcut) "gdev-undo"))
      (should (member "C-c b" (mapcar (lambda (key) (alist-get 'key key)) bindings)))
      (should-not (member "C-c q" (mapcar (lambda (key) (alist-get 'key key)) bindings))))
    (save-window-excursion
      (set-window-buffer (selected-window) (current-buffer))
      (with-temp-buffer
        (let* ((reply (json-parse-string
                       (gdev-agent-interface-request gdev-config-directory "shortcuts" "C-c q")
                       :object-type 'alist))
               (shortcut (alist-get 'shortcut reply)))
          (should (equal (alist-get 'command shortcut) "gdev-undo")))))))

(ert-deftest gdev-test-agent-cursors-group-edits-and-track-other-agents ()
  "Le scritture sono atomiche, annullabili e rispettano la revisione letta."
  (require 'gdev-agent-cursors)
  (let* ((dir (make-temp-file "gdev-agent-cursors-" t))
         (file (expand-file-name "note.txt" dir))
         (data (expand-file-name "dati.json" dir))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "alfa\nbeta\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (cl-labels ((call (action &rest args)
                          (json-parse-string
                           (apply #'gdev-agent-interface-request gdev-config-directory
                                  (concat "cursor-" action) file args)
                           :object-type 'alist)))
              (let* ((state (alist-get 'document (call "state" "0")))
                     (revision (alist-get 'revision state)))
                (should (equal (alist-get 'text state) "alfa\nbeta\n"))
                (with-temp-file data (insert "[0,5]"))
                (should (eq t (alist-get 'ok (call "place" "alfa" revision data))))
                (with-temp-file data (insert "[8]"))
                (should (eq t (alist-get 'ok (call "place" "beta" revision data))))
                (with-temp-file data (insert "\"Ω \""))
                (let ((reject (lambda (start _) (when (< start 3) (user-error "Zona protetta")))))
                  (unwind-protect
                      (progn
                        (add-hook 'before-change-functions reject nil t)
                        (should (alist-get 'error (call "write" "alfa" revision data)))
                        (should (equal (buffer-string) "alfa\nbeta\n")))
                    (remove-hook 'before-change-functions reject t)))
                (setq revision (alist-get 'revision (alist-get 'document (call "state" "0"))))
                (goto-char 4)
                (set-mark 2)
                (let* ((result (call "write" "alfa" revision data))
                       (groups (alist-get 'cursors (alist-get 'document result))))
                  (should (eq t (alist-get 'ok result)))
                  (should (equal (buffer-string) "Ω alfa\nΩ beta\n"))
                  (should (= (point) 6))
                  (should (= (mark) 4))
                  (should (seq-some (lambda (group)
                                      (and (equal (alist-get 'agent group) "beta")
                                           (equal (alist-get 'offsets group) [12])))
                                    groups)))
                (should (alist-get 'error (call "write" "beta" revision data)))
                (let ((last-command nil)) (undo-only 1))
                (should (equal (buffer-string) "alfa\nbeta\n"))
                (should (eq t (alist-get 'ok (call "clear" "alfa"))))
                (should (assoc "beta" gdev-agent-cursors--groups))
                (fundamental-mode)
                (should-not (overlays-in (point-min) (point-max)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest gdev-agent-interface-formal-discovery-does-not-evaluate-manifest ()
  "La scoperta segnala il manifesto e indica come consultarne lo stato reale."
  (let* ((gdev-agent-interface--root (file-name-as-directory (make-temp-file "gdev-agent-formal-" t)))
         (root gdev-agent-interface--root))
    (unwind-protect
        (progn
          (dolist (directory '("lisp" "templates" "modules" ".gdev-assurance"))
            (make-directory (expand-file-name directory root) t))
          (with-temp-file (expand-file-name "lisp/gdev-cli.el" root)
            (insert "(defconst gdev-cli-commands '((\"prova\" . ignore)))"))
          (with-temp-file (expand-file-name "templates/init.el" root)
            (insert "(gdev! :ui prova)"))
          (should (eq :false (alist-get 'manifest_present
                                        (alist-get 'development (gdev-agent-interface-inventory "develop")))))
          (with-temp-file (expand-file-name ".gdev-assurance/project.eld" root)
            (insert "(error \"Il manifesto non è un programma\")"))
          (let ((data (alist-get 'development (gdev-agent-interface-inventory "develop"))))
            (should (eq t (alist-get 'manifest_present data)))
            (should (equal "agent" (alist-get 'identity data)))
            (should (string-match-p "gdev agente assicurazione" (alist-get 'agent_entry data))))
          (should-not (file-exists-p (expand-file-name ".gdev" root))))
      (delete-directory root t))))

(ert-deftest gdev-agent-interface-headless-assurance-preserves-identity ()
  "Il nome della persona non promuove il canale agente e i rifiuti restano in audit."
  (require 'gdev-assurance-actions)
  (let ((root (make-temp-file "gdev-agent-process-" t)))
    (unwind-protect
        (let ((id (gdev-assurance-agent-run root "apri" '("Prova formale" "quality") "persona")))
          (gdev-assurance-agent-run root "avanza" (list id "classificata") "persona")
          (gdev-assurance-agent-run root "avanza" (list id "in-analisi") "persona")
          (should-error (gdev-assurance-agent-run root "avanza" (list id "autorizzata") "persona")
                        :type 'gdev-process-refused)
          (let* ((data (gdev-assurance-data "show" root id))
                 (events (append (alist-get 'events data) nil))
                 (refusal (car (last events))))
            (should (equal "ANALYZED" (alist-get 'state (alist-get 'transaction data))))
            (should (cl-every (lambda (event) (equal "agent" (alist-get 'actor_kind event))) events))
            (should (equal "persona" (alist-get 'actor refusal)))
            (should (equal "refusal" (alist-get 'kind refusal)))
            (should (string-match-p "Autorizzata" (alist-get 'note refusal))))
          (should (eq t (alist-get 'ok (gdev-assurance-data "verify" root)))))
      (delete-directory root t))))

(ert-deftest gdev-agent-interface-headless-assurance-rejects-unsupported-actions ()
  "Un'operazione esclusa non crea un archivio né viene eseguita come persona."
  (require 'gdev-assurance-actions)
  (let ((root (make-temp-file "gdev-agent-denied-" t)))
    (unwind-protect
        (progn
          (dolist (invalid-root (list nil "relativa" "/ssh:gdev-invalid:/tmp"
                                     (expand-file-name "inesistente" root)))
            (should-error (gdev-assurance-agent-run invalid-root "stato" nil)
                          :type 'user-error))
          (dolist (command '("confirm" "sign" "decision" "recover" "inesistente"))
            (should-error (gdev-assurance-agent-run root command nil) :type 'user-error))
          (should-error (gdev-assurance-agent-run root "stato" '("argomento inatteso"))
                        :type 'user-error)
          (should-error (gdev-assurance-action-run root "open" '("Prova" "quality") "x" 'robot)
                        :type 'gdev-process-refused)
          (should-not (file-exists-p (expand-file-name ".gdev" root)))
          (let ((result (gdev-agent-interface--assurance-headless (list root "stato"))))
            (should (eq t (alist-get 'ok result)))
            (should (equal "agent" (alist-get 'actor_kind result)))
            (should (eq :false (alist-get 'archive (alist-get 'data result)))))
          (should-not (file-exists-p (expand-file-name ".gdev" root))))
      (delete-directory root t))))

(ert-deftest gdev-agent-interface-headless-procedure-failure-is-an-error ()
  "Una procedura fallita o interrotta restituisce errore e conserva i dati."
  (require 'gdev-assurance-actions)
  (dolist (status '("FAILED" "CANCELLED"))
    (cl-letf (((symbol-function 'gdev-assurance-agent-run)
               (lambda (&rest _) (list (cons 'status status)))))
      (let ((data (gdev-agent-interface--assurance-headless (list temporary-file-directory "esegui-procedura"))))
        (should (eq :false (alist-get 'ok data)))
        (should (equal status (alist-get 'status (alist-get 'data data))))
        (should (stringp (alist-get 'error data)))))))

(ert-deftest gdev-agent-interface-process-labels-are-italian-and-codes-stable ()
  "Gli stati usano nomi italiani senza cambiare i codici persistiti."
  (require 'gdev-assurance)
  (dolist (state gdev-process-states)
    (let ((label (gdev-assurance-label 'state state)))
      (should-not (equal (symbol-name state) label))
      (should (eq state (gdev-assurance-state-code label)))
      (should (eq state (gdev-assurance-state-code (symbol-name state))))))
  (should (equal "Consolidata" (gdev-assurance-label 'state 'BASELINED)))
  (should (eq 'IMPLEMENTING (gdev-assurance-state-code "in-lavorazione")))
  (should-error (gdev-assurance-state-code "stato inventato") :type 'user-error)
  (let* ((data '((state . :null) (transactions . [((id . "GT-0001") (state . "IMPLEMENTING")
                                                 (profile . "quality") (title . "Prova"))])))
         (text (with-output-to-string (gdev-assurance--render-list data))))
    (should (string-match-p "In lavorazione" text))
    (should (string-match-p "Qualità" text))
    (should-not (string-match-p "IMPLEMENTING" text))
    (should (equal "IMPLEMENTING" (alist-get 'state (aref (alist-get 'transactions data) 0))))))

(provide 'gdev-agent-interface-test)
;;; gdev-agent-interface-test.el ends here
