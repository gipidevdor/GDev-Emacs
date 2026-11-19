;;; config.el --- :lang article: progetti e scrittura di articoli -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Nuovo progetto Articolo apre un manoscritto Org con spazio per
;; l'apertura, lo sviluppo e la conclusione. Le bozze e le ricerche
;; restano in cartelle separate. Il manoscritto riporta i collegamenti
;; nel piano di lavoro, escluso dall'esportazione.
;;
;; La panoramica raccoglie scaletta, bozze, ricerca, versioni,
;; revisione ed esportazione nello spazio dell'articolo.
;; Fonti, bozze e ricerche sono normali file Org del progetto.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'gdev-ui)
(require 'gdev-writing)

(use-package org :ensure t :commands org-mode)
(autoload 'org-export-dispatch "ox" nil t)
(autoload 'org-goto "org-goto" nil t)

(declare-function gdev-module-directory "gdev-modules" (category &optional module))
(declare-function gdev-compare-buffer-with-file "gdev-commands" (document file &optional label whole))
(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-open-folder "gdev-commands" (directory))
(declare-function org-fold-show-entry "org-fold" (&optional hide-drawers))
(defvar gdev-context-items)
(defvar org-goto-interface)

(autoload 'gdev-article-review
  (expand-file-name "gdev-article-revision" (gdev-module-directory :lang 'article)) nil t)
(autoload 'gdev-article-capture-source
  (expand-file-name "gdev-article-sources" (gdev-module-directory :lang 'article)) nil t)

(defconst gdev-article--marker ".gdev-article"
  "Nome del file che identifica la radice del progetto Articolo.")

(defconst gdev-article--manuscript "articolo.org"
  "Nome del manoscritto nella radice del progetto.")

(defconst gdev-article--versions ".gdev-article-versions"
  "Cartella delle versioni del manoscritto, creata al primo salvataggio.")

(defvar-local gdev-article--root nil
  "Cartella del progetto del documento Articolo corrente.")

(cl-defmethod project-root ((project (head gdev-article)))
  (cdr project))

(gdev-writing-register-project 'gdev-article gdev-article--marker)

(defun gdev-article--title (title)
  "Adatta TITLE a un titolo Org su una sola riga."
  (let ((single-line (string-trim (replace-regexp-in-string "[[:space:]]+" " " title))))
    (when (string-empty-p single-line)
      (user-error "Scrivi un titolo per continuare"))
    single-line))

(defun gdev-article--document (title content)
  "Crea il testo Org con TITLE e CONTENT."
  (concat "#+GDEV_TYPE: article\n#+TITLE: " title
          "\n#+LANGUAGE: it\n\n" content))

(defun gdev-article--write-file (file content)
  "Scrivi CONTENT in un nuovo FILE UTF-8."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region content nil file nil 'silent nil 'excl)))

(defun gdev-article--initialize (directory title)
  "Prepara DIRECTORY, nuova o vuota, per un articolo con TITLE."
  (let* ((title (gdev-article--title title))
         (root (file-name-as-directory (expand-file-name directory)))
         created-files created-directories done)
    (unwind-protect
        (progn
          (if (file-directory-p root)
              (unless (gdev-directory-empty-p root)
                (user-error "Scegli una cartella vuota per il progetto Articolo"))
            (make-directory root)
            (push root created-directories))
          (dolist (name '("bozze" "ricerche"))
            (let ((folder (expand-file-name name root)))
              (make-directory folder)
              (push folder created-directories)))
          (dolist (entry
                   `((,gdev-article--manuscript . ,(gdev-article--document
                                         title
                                         (concat "#+OPTIONS: toc:nil num:nil\n\n"
                                                 "* Piano di lavoro :noexport:\n\n"
                                                 "- [[file:bozze/prima-stesura.org][Prima stesura]]\n"
                                                 "- [[file:ricerche/indice.org][Piano di ricerca]]\n\n"
                                                 "** Domanda centrale\n\n** Pubblico e taglio\n\n"
                                                 "** Tesi in una frase\n\n** Lunghezza e consegna\n\n"
                                                 "* Apertura\n\n* Sviluppo\n\n* Conclusione\n\n* Fonti\n")))
                     ("bozze/prima-stesura.org" . ,(gdev-article--document
                                                    "Prima stesura"
                                                    (concat "[[file:../articolo.org][Torna all'articolo]]\n\n"
                                                            "* Scaletta\n\n* Stesura\n\n* Revisione\n")))
                     ("ricerche/indice.org" . ,(gdev-article--document
                                                "Piano di ricerca"
                                                (concat "[[file:../articolo.org][Torna all'articolo]]\n\n"
                                                        "* Domande da approfondire\n\n"
                                                        "* Fonti da consultare\n\n* Fatti da verificare\n")))
                     (,gdev-article--marker . "article\n")))
            (let ((file (expand-file-name (car entry) root)))
              (gdev-article--write-file file (cdr entry))
              (push file created-files)))
          (setq done t)
          root)
      (unless done
        (dolist (file created-files)
          (ignore-errors (delete-file file)))
        (dolist (folder created-directories)
          (ignore-errors (delete-directory folder)))))))

(defun gdev-article-new-project (directory title)
  "Crea e apre un progetto Articolo in DIRECTORY con TITLE."
  (interactive
   (let ((directory (read-directory-name "Cartella del progetto Articolo: ")))
     (list directory (read-string "Titolo dell’articolo: "
                                  (file-name-nondirectory (directory-file-name directory))))))
  (let* ((root (gdev-article--initialize directory title))
         (manuscript (expand-file-name gdev-article--manuscript root)))
    (gdev-open-folder root)
    (gdev-open-file manuscript)
    (when (and (derived-mode-p 'gdev-article-mode)
               (equal buffer-file-name manuscript))
      (goto-char (point-min))
      (when (re-search-forward "^\\* Apertura$" nil t)
        (org-fold-show-entry)
        (forward-line 1)))
    (gdev-writing-open)))

(defun gdev-article--project-root ()
  "Restituisci la radice del progetto Articolo corrente."
  (or gdev-article--root (gdev-writing-project-root 'gdev-article default-directory)
      (user-error "Apri un documento di un progetto Articolo")))

(defun gdev-article--open-file (file)
  "Apri un documento FILE disponibile nell'editor."
  (unless (file-regular-p file)
    (user-error "Il documento %s non è più disponibile" (file-name-nondirectory file)))
  (gdev-open-file file))

(defun gdev-article-open-manuscript ()
  "Apri il manoscritto principale del progetto Articolo."
  (interactive)
  (gdev-article--open-file (expand-file-name gdev-article--manuscript
                                           (gdev-article--project-root))))

(defun gdev-article--manuscript-buffer (&optional root)
  "Restituisci il buffer del manoscritto in ROOT, anche se non salvato."
  (let ((file (expand-file-name gdev-article--manuscript
                                (or root (gdev-article--project-root)))))
    (unless (file-regular-p file)
      (user-error "Manoscritto non trovato"))
    (or (find-buffer-visiting file) (find-file-noselect file))))

(defun gdev-article-outline ()
  "Vai a una sezione del manoscritto usando la scaletta di Org."
  (interactive)
  (let* ((source (gdev-article--manuscript-buffer))
         (position (with-current-buffer source
                     (save-excursion
                       (save-restriction
                         (widen)
                         (let ((org-goto-interface 'outline-path-completion))
                           (org-goto)
                           (point)))))))
    (gdev-article--open-file (buffer-file-name source))
    (unless (<= (point-min) position (point-max))
      (widen))
    (goto-char position)))

(defun gdev-article-save-version (label)
  "Conserva la stesura corrente del manoscritto con il nome LABEL."
  (interactive (list (read-string "Nome della versione: ")))
  (let* ((title (gdev-article--title label))
         (slug (truncate-string-to-width
                (string-trim (replace-regexp-in-string "[^[:alnum:]]+" "-" title) "-" "-") 45))
         (directory (expand-file-name gdev-article--versions (gdev-article--project-root)))
         (source (gdev-article--manuscript-buffer)))
    (when (string-empty-p slug)
      (user-error "Usa almeno una lettera o una cifra nel nome"))
    (make-directory directory t)
    (let* ((prefix (expand-file-name ".in-corso-" directory))
           (temporary (make-temp-file prefix))
           (version (expand-file-name
                     (format "%s · %s-%s.org" (format-time-string "%Y-%m-%d %H.%M.%S")
                             slug (substring temporary (length prefix)))
                     directory)))
      (unwind-protect
          (progn
            (with-current-buffer source
              (save-restriction
                (widen)
                (let ((coding-system-for-write 'utf-8-unix))
                  (write-region (point-min) (point-max) temporary nil 'silent))))
            (rename-file temporary version)
            (message "Versione conservata: %s" title)
            version)
        (when (file-exists-p temporary)
          (delete-file temporary))))))

(defun gdev-article-compare-version ()
  "Confronta una versione conservata con il manoscritto corrente."
  (interactive)
  (let* ((directory (expand-file-name gdev-article--versions (gdev-article--project-root)))
         (files (and (file-directory-p directory)
                     (seq-filter #'file-regular-p (directory-files directory t "\\.org\\'"))))
         (choices (mapcar (lambda (file) (cons (file-name-base file) file)) (reverse files))))
    (unless choices (user-error "Conserva una versione del manoscritto per poterla confrontare"))
    (let ((file (cdr (assoc (completing-read "Versione da confrontare: " choices nil t)
                            choices))))
      (unless (and file (file-regular-p file))
        (user-error "La versione scelta non è più disponibile"))
      (gdev-compare-buffer-with-file (gdev-article--manuscript-buffer) file "Versione conservata" t))))

(defun gdev-article--read-title ()
  "Leggi il primo titolo nel preambolo Org del buffer corrente."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (and (re-search-forward
                    "^\\(?:[ \t]*#\\+TITLE:[ \t]*\\([^ \t\r\n].*\\)\\|\\*+[ \t]\\|[ \t]*#\\+BEGIN_\\)"
                    (min (point-max) (+ (point-min) 8192)) t)
                   (match-beginning 1))
          (string-trim (match-string-no-properties 1)))))))

(defun gdev-article--document-title (file &optional buffer)
  "Restituisci il titolo di FILE, leggendo al massimo i primi 8 KiB.
Preferisci il testo corrente di BUFFER o del buffer che visita FILE."
  (or (if-let* ((editor (or buffer (get-file-buffer file))))
          (with-current-buffer editor (gdev-article--read-title))
        (with-temp-buffer
          (condition-case nil
              (progn
                (insert-file-contents file nil 0 8192)
                (gdev-article--read-title))
            (file-error nil))))
      (file-name-base file)))

(defun gdev-article--documents (root folder)
  "Elenca i documenti Org di FOLDER sotto ROOT come (TITOLO . FILE)."
  (let* ((directory (expand-file-name folder root))
         (files (when (file-directory-p directory)
                  (condition-case nil
                      (directory-files directory t "\\.org\\'")
                    (file-missing nil))))
         documents)
    (dolist (file files)
      (when (file-regular-p file)
        (push (cons (gdev-article--document-title file) file) documents)))
    (cl-stable-sort (nreverse documents) #'string-lessp
                    :key (lambda (document) (downcase (car document))))))

(defun gdev-article--document-choices (documents)
  "Prepara etichette univoche per i DOCUMENTS in completamento."
  (let ((counts (make-hash-table :test #'equal))
        (used (make-hash-table :test #'equal)))
    (dolist (document documents)
      (cl-incf (gethash (car document) counts 0)))
    (mapcar
     (pcase-lambda (`(,title . ,file))
       (let ((label title))
         (when (> (gethash title counts) 1)
           (let ((base (format "%s · %s" title (file-name-nondirectory file)))
                 (index 1))
             (setq label base)
             (while (or (gethash label counts) (gethash label used))
               (setq label (format "%s (%d)" base (cl-incf index))))))
         (puthash label t used)
         (cons label file)))
     documents)))

(defun gdev-article--open-document (folder prompt)
  "Scegli un documento Org di FOLDER con PROMPT e aprilo."
  (let ((choices (gdev-article--document-choices
                  (gdev-article--documents (gdev-article--project-root) folder))))
    (unless choices (user-error "Nessun documento nella cartella %s" folder))
    (let* ((choice (completing-read prompt choices nil t))
           (file (cdr (assoc choice choices))))
      (unless file
        (user-error "Il documento scelto non è più disponibile"))
      (gdev-article--open-file file))))

(defun gdev-article-open-drafts ()
  "Apri una delle bozze del progetto Articolo."
  (interactive)
  (gdev-article--open-document "bozze" "Bozza: "))

(defun gdev-article-open-research ()
  "Apri il piano di ricerca o una scheda tematica del progetto Articolo."
  (interactive)
  (gdev-article--open-document "ricerche" "Ricerca: "))

(defun gdev-article--new-document (folder title sections)
  "Crea in FOLDER il documento TITLE con le intestazioni SECTIONS."
  (let* ((title (gdev-article--title title))
         (slug (string-trim (replace-regexp-in-string "[^[:alnum:]]+" "-" (downcase title)) "-" "-"))
         (directory (expand-file-name folder (gdev-article--project-root))))
    (when (string-empty-p slug)
      (user-error "Usa almeno una lettera o una cifra nel titolo"))
    (unless (file-directory-p directory)
      (condition-case nil
          (make-directory directory)
        (file-already-exists
         (unless (file-directory-p directory)
           (user-error "Il percorso %s non è una cartella" folder)))
        (file-missing (user-error "La cartella del progetto non è più disponibile"))))
    (let ((file (expand-file-name (concat slug ".org") directory)))
      (condition-case nil
          (gdev-article--write-file
           file (gdev-article--document
                 title (concat "[[file:../articolo.org][Torna all'articolo]]\n\n"
                               (mapconcat (lambda (heading) (concat "* " heading "\n")) sections "\n"))))
        (file-already-exists (user-error "Esiste già un documento con questo titolo")))
      (gdev-open-file file))))

(defun gdev-article-new-draft (title)
  "Crea una bozza intitolata TITLE nel progetto Articolo."
  (interactive (list (read-string "Titolo della bozza: ")))
  (gdev-article--new-document "bozze" title '("Scaletta" "Stesura" "Revisione")))

(defun gdev-article-new-research (topic)
  "Crea una scheda di ricerca per TOPIC nel progetto Articolo."
  (interactive (list (read-string "Argomento da approfondire: ")))
  (gdev-article--new-document "ricerche" topic '("Domanda" "Fonti" "Appunti" "Verifiche")))

(defvar-keymap gdev-article-project-mode-map
  :parent special-mode-map
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-article-project-mode special-mode "Progetto articolo"
  "Consulta i documenti di un progetto Articolo."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-document)
  (visual-line-mode 1)
  (setq-local left-margin-width 2
              right-margin-width 2
              revert-buffer-function #'gdev-article--render-project))

(defun gdev-article--export-manuscript ()
  "Apri le opzioni di esportazione del manoscritto."
  (interactive)
  (gdev-article-open-manuscript)
  (call-interactively #'org-export-dispatch))

(defun gdev-article--project-button (label target &optional primary)
  "Inserisci LABEL per TARGET, un percorso o un comando.
Con PRIMARY usa la faccia riservata all'azione principale."
  (insert-text-button
   label 'type 'gdev-ui-action 'gdev-article-item target
   'gdev-article-file (and (stringp target) target)
   'help-echo label 'face (if primary 'gdev-ui-action-primary 'gdev-ui-action)
   'action (lambda (_)
             (if (stringp target)
                 (gdev-article--open-file target)
               (call-interactively target)))))

(defun gdev-article--project-actions (actions)
  "Inserisci i pulsanti di ACTIONS nella riga corrente."
  (pcase-dolist (`(,label . ,command) actions)
    (unless (bolp) (insert "   "))
    (gdev-article--project-button label command))
  (insert "\n"))

(defun gdev-article--project-section (label folder actions empty)
  "Disegna LABEL con i documenti di FOLDER e i pulsanti ACTIONS.
Mostra EMPTY quando FOLDER non contiene documenti."
  (insert (propertize label 'face 'gdev-ui-view-heading) "\n")
  (gdev-article--project-actions actions)
  (if-let* ((documents (gdev-article--document-choices
                        (gdev-article--documents gdev-article--root folder))))
      (dolist (document documents)
        (gdev-article--project-button (car document) (cdr document))
        (insert "\n"))
    (insert (propertize empty 'face 'gdev-ui-secondary) "\n")))

(defun gdev-article--render-project (&optional _ignore-auto _noconfirm)
  "Aggiorna la panoramica mantenendo selezionata la stessa azione."
  (let* ((selected (get-text-property (point) 'gdev-article-item))
         (manuscript (expand-file-name gdev-article--manuscript gdev-article--root))
         (exists (file-regular-p manuscript))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (gdev-ui-icon "edit" "·" nil 'gdev-ui-secondary) "  "
            (propertize "Progetto articolo" 'face 'gdev-ui-secondary) "\n"
            (propertize (if exists (gdev-article--document-title manuscript)
                          (file-name-nondirectory (directory-file-name gdev-article--root)))
                        'face 'gdev-ui-view-title)
            "\n\n"
            (propertize "Manoscritto" 'face 'gdev-ui-view-heading) "\n")
    (if exists
        (progn
          (gdev-article--project-button "Continua a scrivere" manuscript t)
          (insert "   ")
          (gdev-article--project-button "Scaletta…" #'gdev-article-outline)
          (insert "\n\n" (propertize "Revisione e consegna" 'face 'gdev-ui-view-heading) "\n")
          (gdev-article--project-actions '(("Rivedi il manoscritto" . gdev-article-review)
                                           ("Esporta…" . gdev-article--export-manuscript)))
          (insert "\n" (propertize "Versioni" 'face 'gdev-ui-view-heading) "\n")
          (gdev-article--project-actions '(("Conserva versione…" . gdev-article-save-version)
                                           ("Confronta versione…" . gdev-article-compare-version))))
      (insert (propertize "Manoscritto non trovato" 'face 'gdev-ui-secondary) "\n"))
    (insert "\n")
    (gdev-article--project-section "Bozze" "bozze"
                                   '(("Nuova bozza…" . gdev-article-new-draft)) "Nessuna bozza")
    (insert "\n")
    (gdev-article--project-section "Ricerca" "ricerche"
                                   '(("Raccogli fonte…" . gdev-article-capture-source)
                                     ("Nuova scheda…" . gdev-article-new-research)) "Nessuna scheda")
    (goto-char (point-min))
    (when-let* ((selected)
                (match (text-property-search-forward 'gdev-article-item selected #'equal)))
      (goto-char (prop-match-beginning match)))
    (set-buffer-modified-p nil)))

(defun gdev-article-open-project ()
  "Apri la panoramica dell'articolo nel gruppo editor corrente."
  (interactive)
  (let* ((root (gdev-article--project-root))
         (window (or (gdev-layout-editor) (selected-window)))
         (view (or (seq-find
                    (lambda (buffer)
                      (with-current-buffer buffer
                        (and (derived-mode-p 'gdev-article-project-mode)
                             (equal root gdev-article--root))))
                    (buffer-list))
                   (generate-new-buffer
                    (format "*Articolo · %s*" (file-name-nondirectory
                                               (directory-file-name root)))))))
    (with-current-buffer view
      (unless (derived-mode-p 'gdev-article-project-mode)
        (gdev-article-project-mode)
        (setq default-directory root
              gdev-article--root root))
      (gdev-article--render-project))
    (select-window window)
    (pop-to-buffer-same-window view)))

(defvar-keymap gdev-article-mode-map
  "C-c j" #'gdev-article-open-project)

(define-derived-mode gdev-article-mode org-mode "Articolo"
  "Modifica il testo, le bozze e le ricerche di un progetto Articolo."
  (gdev-ui-view-setup 'native)
  (visual-line-mode 1)
  (setq-local display-line-numbers nil
              gdev-article--root (gdev-writing-project-root 'gdev-article default-directory)
              gdev-context-items
              (append
               '(["Panoramica dell’articolo" gdev-article-open-project gdev-article--root]
                 ["Raccogli una fonte…" gdev-article-capture-source gdev-article--root]
                 ["Scaletta del manoscritto…" gdev-article-outline gdev-article--root]
                 ["Rivedi il manoscritto" gdev-article-review gdev-article--root]
                 ["Conserva una versione…" gdev-article-save-version gdev-article--root]
                 ["Confronta una versione…" gdev-article-compare-version gdev-article--root]
                 ["Modalità concentrazione" gdev-layout-toggle-focus]
                 ["Vai a una sezione…" imenu]
                 ["Apri il manoscritto" gdev-article-open-manuscript
                  (and gdev-article--root
                       (not (equal buffer-file-name
                                   (expand-file-name gdev-article--manuscript gdev-article--root))))]
                 ["Apri una bozza…" gdev-article-open-drafts gdev-article--root]
                 ["Nuova bozza…" gdev-article-new-draft gdev-article--root]
                 ["Apri una ricerca…" gdev-article-open-research gdev-article--root]
                 ["Nuova scheda di ricerca…" gdev-article-new-research gdev-article--root]
                 ["Inserisci una sezione" org-insert-heading-respect-content (not buffer-read-only)]
                 ["Inserisci un collegamento…" org-insert-link (not buffer-read-only)]
                 ["Mostra gli strumenti di scrittura" gdev-writing-open])
               (gdev-writing-actions))))

(add-to-list 'magic-mode-alist '("\\`#\\+GDEV_TYPE: article\\(?:\n\\|\\'\\)" . gdev-article-mode))

(provide 'gdev-article)
;;; config.el ends here
