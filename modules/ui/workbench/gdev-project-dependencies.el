;;; gdev-project-dependencies.el --- Manifesti e dipendenze dirette -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Legge i manifesti locali e, su richiesta, modifica una dichiarazione
;; nel suo buffer. L'installazione delle dipendenze resta al progetto.

;;; Code:

(require 'button)
(require 'json)
(require 'treesit)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-lib)
(require 'gdev-ui)
(require 'gdev-workspace-roots)

(declare-function gdev-open-file "gdev-commands" (file &optional wildcards))
(declare-function gdev-close-document "gdev-commands" ())

(defconst gdev-project-dependencies--names
  '("package.json" "Cargo.toml" "pyproject.toml"))

(defconst gdev-project-dependencies--node-groups
  '(("dependencies" . "Produzione")
    ("devDependencies" . "Sviluppo")
    ("peerDependencies" . "Compatibilità")
    ("optionalDependencies" . "Facoltative")))

(defconst gdev-project-dependencies--cargo-groups
  '(("dependencies" . "Produzione")
    ("dev-dependencies" . "Sviluppo")
    ("build-dependencies" . "Compilazione")))

(defconst gdev-project-dependencies--manifest-limit (* 1024 1024))
(defconst gdev-project-dependencies--page-size 60)

(cl-defstruct (gdev-project-dependencies--entry
               (:constructor gdev-project-dependencies--make-entry))
  group name value id position start end literal)

(defvar-local gdev-project-dependencies--manifests nil)
(defvar-local gdev-project-dependencies--manifest nil)
(defvar-local gdev-project-dependencies--entries nil)
(defvar-local gdev-project-dependencies--error nil)
(defvar-local gdev-project-dependencies--filter "")
(defvar-local gdev-project-dependencies--page 0)

(defun gdev-project-dependencies--decode (text)
  "Decodifica il letterale JSON o TOML TEXT per la presentazione."
  (cond
   ((or (string-prefix-p "\"\"\"" text) (string-prefix-p "'''" text))
    (string-trim (substring text 3 -3)))
   ((string-prefix-p "'" text) (substring text 1 -1))
   (t (condition-case nil (json-parse-string text)
        (json-parse-error (substring text 1 -1))))))

(defun gdev-project-dependencies--string (node)
  "Decodifica la stringa JSON o TOML di NODE."
  (when (member (treesit-node-type node) '("string" "quoted_key"))
    (gdev-project-dependencies--decode (treesit-node-text node t))))

(defun gdev-project-dependencies--entry (group name value &optional anchor editable id)
  "Crea la riga GROUP, NAME, VALUE; ancora e modifica usano nodi distinti."
  (let ((literal (and editable (treesit-node-text editable t))))
    (when (and literal (string-match-p "\n" literal)) (setq literal nil))
    (gdev-project-dependencies--make-entry
     :group group :name name :value value :id (or id (list group name))
     :position (and anchor (treesit-node-start anchor))
     :start (and literal (treesit-node-start editable))
     :end (and literal (treesit-node-end editable)) :literal literal)))

(defun gdev-project-dependencies--root-node (language)
  "Analizza il manifesto corrente con LANGUAGE e rifiuta sintassi incompleta."
  (let* ((parser (treesit-parser-create language))
         (root (treesit-parser-root-node parser)))
    (when (treesit-node-check root 'has-error)
      (user-error "Il manifesto contiene un errore di sintassi"))
    root))

(defun gdev-project-dependencies--json-entries ()
  "Leggi le dipendenze dirette del manifesto Node corrente."
  (let* ((manifest (json-parse-buffer :object-type 'hash-table))
         (positions (make-hash-table :test #'equal)))
    (unless (hash-table-p manifest) (user-error "package.json deve contenere un oggetto"))
    (when (treesit-language-available-p 'json)
      (let ((root (gdev-project-dependencies--root-node 'json)))
        (dolist (group-node (treesit-node-children (treesit-node-child root 0 t) t))
          (let* ((key (treesit-node-child-by-field-name group-node "key"))
                 (name (and key (gdev-project-dependencies--string key)))
                 (value (treesit-node-child-by-field-name group-node "value")))
            (when (and (assoc name gdev-project-dependencies--node-groups)
                       (equal (treesit-node-type value) "object"))
              (dolist (dependency (treesit-node-children value t))
                (when-let* ((node (treesit-node-child-by-field-name dependency "key"))
                            (package (gdev-project-dependencies--string node)))
                  (puthash (cons name package) dependency positions))))))))
    (cl-loop for (key . group) in gdev-project-dependencies--node-groups
             for declared = (gethash key manifest)
             when (hash-table-p declared)
             append (cl-loop for package being the hash-keys of declared using (hash-values value)
                             when (stringp value)
                             collect (let* ((node (gethash (cons key package) positions))
                                            (edit (and node (treesit-node-child-by-field-name node "value"))))
                                       (gdev-project-dependencies--entry group package value node edit))))))

(defun gdev-project-dependencies--toml-key (node)
  "Restituisci i componenti della chiave TOML di NODE."
  (pcase (treesit-node-type node)
    ("dotted_key" (mapcan #'gdev-project-dependencies--toml-key (treesit-node-children node t)))
    ("bare_key" (list (treesit-node-text node t)))
    ("quoted_key" (list (gdev-project-dependencies--string node)))))

(defun gdev-project-dependencies--toml-fields (root)
  "Raccogli da ROOT le foglie TOML con chiave, valore e ancora."
  (let (fields)
    (cl-labels
        ((collect-pair (pair prefix)
           (let* ((key (treesit-node-child pair 0 t))
                  (value (treesit-node-child pair 1 t))
                  (path (append prefix (gdev-project-dependencies--toml-key key))))
             (if (and (equal (treesit-node-type value) "inline_table")
                      (treesit-node-child value 0 t))
                 (dolist (child (treesit-node-children value t))
                   (when (equal (treesit-node-type child) "pair") (collect-pair child path)))
               (push (list path value key) fields)))))
      (dolist (node (treesit-node-children root t))
        (pcase (treesit-node-type node)
          ("pair" (collect-pair node nil))
          ("table"
           (let ((prefix (gdev-project-dependencies--toml-key (treesit-node-child node 0 t))))
             (dolist (child (treesit-node-children node t))
               (when (equal (treesit-node-type child) "pair") (collect-pair child prefix))))))))
    (nreverse fields)))

(defun gdev-project-dependencies--cargo-scope (path)
  "Ricava gruppo, pacchetto e proprietà Cargo da PATH."
  (let* ((context (car path))
         (scope (pcase context
                  ("workspace" (cons (cdr path) "Spazio Cargo"))
                  ("target" (cons (cddr path) (cadr path)))
                  (_ (list path)))))
    (pcase-let ((`((,kind ,name . ,property) . ,suffix) scope))
      (when-let* ((label (cdr (assoc kind gdev-project-dependencies--cargo-groups)))
                  (name))
        (list (if suffix (concat label " · " suffix) label) name property)))))

(defun gdev-project-dependencies--poetry-scope (path)
  "Ricava gruppo, pacchetto e proprietà Poetry da PATH."
  (pcase path
    (`("tool" "poetry" "dependencies" ,name . ,property)
     (unless (equal name "python") (list "Produzione · Poetry" name property)))
    (`("tool" "poetry" "dev-dependencies" ,name . ,property)
     (list "Sviluppo · Poetry" name property))
    (`("tool" "poetry" "group" ,group "dependencies" ,name . ,property)
     (list (concat "Poetry · " group) name property))))

(defun gdev-project-dependencies--named-entries (fields scope)
  "Raggruppa le proprietà di FIELDS usando la funzione SCOPE."
  (let ((packages (make-hash-table :test #'equal)) ids)
    (pcase-dolist (`(,path ,value ,anchor) fields)
      (when-let* ((parts (funcall scope path)))
        (pcase-let* ((`(,group ,name ,property) parts) (id (list group name)))
          (unless (gethash id packages) (push id ids))
          (push (list property value anchor) (gethash id packages)))))
    (cl-loop for (group name) in (nreverse ids)
             for fields = (nreverse (gethash (list group name) packages))
             for version = (or (cadr (assoc '("version") fields)) (cadr (assq nil fields)))
             for spec = (and version (gdev-project-dependencies--string version))
             for notes = (cl-loop for (field label) in '(("workspace" "Dal workspace Cargo")
                                                        ("path" "Percorso") ("git" "Git") ("optional" "Facoltativa"))
                                  for item = (cadr (assoc (list field) fields))
                                  when (and item (not (equal (treesit-node-text item t) "false")))
                                  collect (if-let* ((content (gdev-project-dependencies--string item)))
                                              (concat label " · " content) label))
             collect (gdev-project-dependencies--entry
                      group name (if (or spec notes) (string-join (delq nil (cons spec notes)) " · ")
                                   "Dichiarazione nel manifesto")
                      (caddr (car fields)) (and spec version)))))

(defun gdev-project-dependencies--python-group (path)
  "Ricava il gruppo di requisiti Python da PATH."
  (pcase path
    ('("project" "dependencies") "Produzione")
    ('("build-system" "requires") "Compilazione")
    (`("project" "optional-dependencies" ,group) (concat "Facoltative · " group))
    (`("dependency-groups" ,group) (concat "Gruppo · " group))))

(defun gdev-project-dependencies--python-name (requirement)
  "Ricava da REQUIREMENT il nome dichiarato, prima di extra o vincoli."
  (when (string-match "\\`[[:blank:]]*\\([A-Za-z0-9][A-Za-z0-9_.-]*\\)" requirement)
    (match-string 1 requirement)))

(defun gdev-project-dependencies--python-entries (fields)
  "Raccogli le dichiarazioni di dipendenza Python da FIELDS."
  (let ((ordinals (make-hash-table :test #'equal)) entries)
    (pcase-dolist (`(,path ,value ,_) fields)
      (when-let* ((group (gdev-project-dependencies--python-group path))
                  ((equal (treesit-node-type value) "array")))
        (dolist (item (treesit-node-children value t))
          (if-let* ((spec (gdev-project-dependencies--string item))
                    (name (gdev-project-dependencies--python-name spec)))
              (let* ((key (list path name))
                     (id (list path name (gethash key ordinals 0))))
                (puthash key (1+ (nth 2 id)) ordinals)
                (push (gdev-project-dependencies--entry group name spec item item id) entries))
            (when (equal (treesit-node-type item) "inline_table")
              (pcase-dolist (`(,key ,value ,_) (gdev-project-dependencies--toml-fields item))
                (when-let* (((equal key '("include-group")))
                            (name (gdev-project-dependencies--string value)))
                  (push (gdev-project-dependencies--entry
                         group name "Includi gruppo" item nil (list path name 'include)) entries))))))))
    (append (nreverse entries)
            (gdev-project-dependencies--named-entries fields #'gdev-project-dependencies--poetry-scope))))

(defun gdev-project-dependencies--parse (file)
  "Leggi le dichiarazioni di FILE dal buffer corrente."
  (pcase (file-name-nondirectory file)
    ("package.json" (gdev-project-dependencies--json-entries))
    ((or "Cargo.toml" "pyproject.toml")
     (unless (treesit-language-available-p 'toml)
       (user-error "Lettura TOML non disponibile. Installa la grammatica con gdev sync"))
     (let ((fields (gdev-project-dependencies--toml-fields
                    (gdev-project-dependencies--root-node 'toml))))
       (if (string-suffix-p "Cargo.toml" file)
           (gdev-project-dependencies--named-entries fields #'gdev-project-dependencies--cargo-scope)
         (gdev-project-dependencies--python-entries fields))))
    (_ (user-error "Scegli package.json, Cargo.toml o pyproject.toml"))))

(defun gdev-project-dependencies--read (file)
  "Leggi FILE o le modifiche in memoria, con un limite per manifesto."
  (let* ((visiting (find-buffer-visiting file))
         (limit gdev-project-dependencies--manifest-limit))
    (with-temp-buffer
      (if visiting
          (insert (with-current-buffer visiting
                    (save-restriction
                      (widen)
                      (when (> (buffer-size) limit) (user-error "Manifesto troppo grande per la vista"))
                      (buffer-substring-no-properties (point-min) (point-max)))))
        (unless (file-regular-p file) (user-error "Il manifesto non è più disponibile"))
        (when (> (file-attribute-size (file-attributes file)) limit)
          (user-error "Manifesto troppo grande per la vista"))
        (insert-file-contents file nil 0 limit))
      (goto-char (point-min))
      (gdev-project-dependencies--parse file))))

(defun gdev-project-dependencies--paths (directory)
  "Trova i manifesti fra DIRECTORY e le radici note, senza scansionare l'albero."
  (let* ((roots (gdev-workspace-roots))
         (root (unless (file-remote-p directory)
                 (or (gdev-workspace-root-for directory roots)
                     (gdev-project-root directory))))
         (current (and root (file-name-as-directory (expand-file-name directory))))
         parents)
    (while (and current (string-prefix-p root current))
      (push current parents)
      (setq current (unless (equal root current)
                      (file-name-directory (directory-file-name current)))))
    (delete-dups
     (cl-loop for candidate in (append (nreverse parents) roots)
              unless (file-remote-p candidate)
              append (cl-loop for name in gdev-project-dependencies--names
                              for manifest = (expand-file-name name candidate)
                              when (file-regular-p manifest)
                              collect manifest)))))

(defun gdev-project-dependencies--button (label action &optional identity tooltip)
  (insert-text-button label 'type 'gdev-ui-action 'help-echo tooltip
                      'gdev-dependencies-focus identity
                      'action (lambda (_) (funcall action))))

(defun gdev-project-dependencies--row (entry)
  (let* ((start (point))
         (name (gdev-project-dependencies--entry-name entry))
         (value (gdev-project-dependencies--entry-value entry))
         (id (gdev-project-dependencies--entry-id entry)))
    (gdev-project-dependencies--button
     name (lambda () (gdev-project-dependencies--visit entry)) (cons 'name id) name)
    (insert "\n")
    (if (gdev-project-dependencies--entry-literal entry)
        (gdev-project-dependencies--button
         value (lambda () (gdev-project-dependencies--edit entry)) (cons 'edit id)
         (concat "Modifica · " value))
      (insert (propertize value 'face 'gdev-ui-secondary 'help-echo value)))
    (put-text-property start (point) 'gdev-dependencies-entry entry)
    (insert "\n")))

(defun gdev-project-dependencies--render ()
  "Ridisegna la pagina preservando l'identità della voce selezionata."
  (let* ((at-point (get-text-property (point) 'gdev-dependencies-entry))
         (identity (get-text-property (point) 'gdev-dependencies-focus))
         (selected (and at-point (gdev-project-dependencies--entry-id at-point)))
         (query (regexp-quote gdev-project-dependencies--filter))
         (case-fold-search t)
         (entries (if (string-empty-p query) gdev-project-dependencies--entries
                    (seq-filter (lambda (entry)
                                  (string-match-p query (gdev-project-dependencies--entry-name entry)))
                                gdev-project-dependencies--entries)))
         (found (and selected (seq-position entries selected
                                             (lambda (entry id)
                                               (equal id (gdev-project-dependencies--entry-id entry))))))
         (size gdev-project-dependencies--page-size)
         (page (if found (/ found size)
                 (max 0 (min gdev-project-dependencies--page (/ (max 0 (1- (length entries))) size)))))
         (start (* page size))
         (inhibit-read-only t)
         last-group row-position)
    (setq gdev-project-dependencies--page page)
    (erase-buffer)
    (insert (propertize "Dipendenze del progetto" 'face 'gdev-ui-view-title) "\n")
    (cond
     (gdev-project-dependencies--manifest
      (insert (propertize (abbreviate-file-name gdev-project-dependencies--manifest)
                          'face 'gdev-ui-secondary 'help-echo gdev-project-dependencies--manifest) "\n\n")
      (gdev-project-dependencies--button "Apri manifesto" #'gdev-project-dependencies-visit 'manifest)
      (insert "   ")
      (gdev-project-dependencies--button "Scegli manifesto…" #'gdev-project-dependencies-choose 'choose)
      (insert "\n")
      (gdev-project-dependencies--button "Aggiorna" #'gdev-project-dependencies-refresh 'refresh)
      (insert "   ")
      (gdev-project-dependencies--button
       (if (string-empty-p gdev-project-dependencies--filter) "Filtra per nome…"
         (concat "Filtro · " gdev-project-dependencies--filter))
       #'gdev-project-dependencies-filter 'filter)
      (insert "\n\n")
      (cond
       (gdev-project-dependencies--error
        (insert (propertize gdev-project-dependencies--error 'face 'gdev-ui-status-warning) "\n"))
       ((not entries)
        (insert (propertize (if (string-empty-p query)
                               "Nessuna dipendenza diretta"
                             "Nessuna dipendenza corrisponde al filtro")
                            'face 'gdev-ui-secondary) "\n"))
       (t
        (when (or (> start 0) (> (length entries) size))
          (when (> start 0)
            (gdev-project-dependencies--button "‹ Precedenti" #'gdev-project-dependencies-previous 'previous)
            (insert "   "))
          (when (> (length entries) (+ start size))
            (gdev-project-dependencies--button "Successive ›" #'gdev-project-dependencies-next 'next)
            (insert "   "))
          (insert (propertize (format "%d–%d di %d" (1+ start) (min (length entries) (+ start size))
                                      (length entries)) 'face 'gdev-ui-secondary) "\n\n"))
        (dolist (entry (seq-take (nthcdr start entries) size))
          (unless (equal last-group (gdev-project-dependencies--entry-group entry))
            (when last-group (insert "\n"))
            (setq last-group (gdev-project-dependencies--entry-group entry))
            (insert (propertize last-group 'face 'gdev-ui-view-heading) "\n"))
          (when (and selected (equal selected (gdev-project-dependencies--entry-id entry)))
            (setq row-position (point)))
          (gdev-project-dependencies--row entry)))))
     (t
      (insert "\n" (propertize "Nessun manifesto nella cartella di lavoro" 'face 'gdev-ui-secondary) "\n\n")
      (gdev-project-dependencies--button "Scegli manifesto…" #'gdev-project-dependencies-choose 'choose)
      (insert "\n")))
    (goto-char (point-min))
    (let ((match (and identity (text-property-search-forward 'gdev-dependencies-focus identity #'equal))))
      (goto-char (or (and match (prop-match-beginning match)) row-position (point-min))))
    ;; Il ridisegno può avvenire da un'altra finestra: anche le viste
    ;; visibili restano sulla voce selezionata.
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-point window (point)))
    (set-buffer-modified-p nil)))

(defun gdev-project-dependencies-refresh ()
  "Rileggi il manifesto, conservando filtro e selezione."
  (interactive)
  (setq gdev-project-dependencies--entries nil gdev-project-dependencies--error nil)
  (when gdev-project-dependencies--manifest
    (condition-case failure
        (let ((entries (gdev-project-dependencies--read gdev-project-dependencies--manifest)))
          (setq gdev-project-dependencies--entries
                (sort entries
                      (lambda (left right)
                        (let ((a (gdev-project-dependencies--entry-group left))
                              (b (gdev-project-dependencies--entry-group right)))
                          (if (equal a b)
                              (string-lessp (downcase (gdev-project-dependencies--entry-name left))
                                            (downcase (gdev-project-dependencies--entry-name right)))
                            (string-lessp a b)))))))
      (json-parse-error (setq gdev-project-dependencies--error "Il manifesto contiene JSON non valido"))
      ((user-error file-error)
       (setq gdev-project-dependencies--error (error-message-string failure)))))
  (gdev-project-dependencies--render))

(defun gdev-project-dependencies--select (file)
  "Mostra le dichiarazioni del manifesto FILE."
  (unless (equal file gdev-project-dependencies--manifest)
    (setq gdev-project-dependencies--manifest file gdev-project-dependencies--filter ""
          gdev-project-dependencies--page 0)
    (goto-char (point-min)))
  (gdev-project-dependencies-refresh))

(defun gdev-project-dependencies-choose ()
  "Scegli un manifesto noto oppure indicane uno con il prefisso."
  (interactive)
  (let ((origin (gdev-workspace-state-ensure-id))
        (view (current-buffer))
        (manifests gdev-project-dependencies--manifests)
        (file (if (and gdev-project-dependencies--manifests (not current-prefix-arg))
                  (completing-read "Manifesto: " gdev-project-dependencies--manifests nil t)
                (read-file-name "Manifesto: " default-directory nil t))))
    (unless (and (buffer-live-p view) (eq origin (gdev-workspace-state-id)))
      (user-error "Lo spazio di lavoro è cambiato"))
    (with-current-buffer view
      (setq file (gdev-project-dependencies--validate-file file))
      (unless (member file manifests) (push file gdev-project-dependencies--manifests))
      (gdev-project-dependencies--select file))))

(defun gdev-project-dependencies-filter ()
  "Filtra le dipendenze per nome."
  (interactive)
  (setq gdev-project-dependencies--filter
        (read-string "Nome della dipendenza: " gdev-project-dependencies--filter)
        gdev-project-dependencies--page 0)
  (goto-char (point-min))
  (gdev-project-dependencies--render))

(defun gdev-project-dependencies-previous ()
  "Mostra la pagina precedente."
  (interactive)
  (cl-decf gdev-project-dependencies--page)
  (goto-char (point-min))
  (gdev-project-dependencies--render))

(defun gdev-project-dependencies-next ()
  "Mostra la pagina successiva."
  (interactive)
  (cl-incf gdev-project-dependencies--page)
  (goto-char (point-min))
  (gdev-project-dependencies--render))

(defun gdev-project-dependencies--validate-file (file)
  (let ((path (expand-file-name file)))
    (unless (and (member (file-name-nondirectory path) gdev-project-dependencies--names)
                 (not (file-remote-p path)) (file-regular-p path))
      (user-error "Scegli un manifesto locale package.json, Cargo.toml o pyproject.toml"))
    path))

(defun gdev-project-dependencies--updated-entry (file entry)
  "Trova ENTRY nella versione corrente di FILE."
  (seq-find (lambda (candidate)
              (equal (gdev-project-dependencies--entry-id candidate)
                     (gdev-project-dependencies--entry-id entry)))
            (gdev-project-dependencies--read file)))

(defun gdev-project-dependencies--visit (&optional entry)
  "Apri il manifesto nella posizione corrente di ENTRY."
  (let* ((file (gdev-project-dependencies--validate-file gdev-project-dependencies--manifest))
         (updated (and entry (gdev-project-dependencies--updated-entry file entry))))
    (gdev-open-file file)
    (when-let* ((updated) (position (gdev-project-dependencies--entry-position updated)))
      (widen)
      (goto-char position))))

(defun gdev-project-dependencies-visit ()
  "Apri il manifesto per aggiungere o rimuovere dichiarazioni."
  (interactive)
  (unless gdev-project-dependencies--manifest (user-error "Scegli prima un manifesto"))
  (gdev-project-dependencies--visit))

(defun gdev-project-dependencies--replace (file entry value)
  "Modifica solo il letterale di ENTRY in FILE, nel buffer di modifica."
  (save-restriction
    (widen)
    (unless (verify-visited-file-modtime (current-buffer))
      (user-error "Il manifesto su disco è cambiato; aprilo di nuovo"))
    (let* ((updated (gdev-project-dependencies--updated-entry file entry))
           (literal (and updated (gdev-project-dependencies--entry-literal updated))))
      (unless (and literal (equal literal (gdev-project-dependencies--entry-literal entry)))
        (user-error "La dichiarazione è cambiata; aggiorna la vista e riprova"))
      (goto-char (gdev-project-dependencies--entry-start updated))
      (atomic-change-group
        (delete-region (point) (gdev-project-dependencies--entry-end updated))
        (insert (if (and (string-prefix-p "'" literal)
                         (not (string-match-p "['[:cntrl:]]" value)))
                    (concat "'" value "'")
                  (gdev-json-text value)))))))

(defun gdev-project-dependencies--edit (entry)
  "Chiedi una nuova dichiarazione per ENTRY e modificala senza salvare."
  (let* ((view (current-buffer))
         (origin (gdev-workspace-state-ensure-id))
         (file (gdev-project-dependencies--validate-file gdev-project-dependencies--manifest))
         (literal (gdev-project-dependencies--entry-literal entry))
         (_ (unless literal (user-error "Apri la dichiarazione nel manifesto per modificarla")))
         (old (gdev-project-dependencies--decode literal))
         (value (read-string (format "Dichiarazione di %s: " (gdev-project-dependencies--entry-name entry)) old)))
    (unless (and (buffer-live-p view) (eq origin (gdev-workspace-state-id))
                 (equal file (buffer-local-value 'gdev-project-dependencies--manifest view)))
      (user-error "Lo spazio o il manifesto è cambiato"))
    (when (string-empty-p (string-trim value)) (user-error "Scrivi una dichiarazione"))
    (unless (equal old value)
      (with-current-buffer (gdev-open-file file)
        (gdev-project-dependencies--replace file entry value))
      (with-current-buffer view (gdev-project-dependencies-refresh))
      (message "Dichiarazione modificata. Salva il manifesto per applicarla su disco"))))

(defun gdev-project-dependencies-edit ()
  "Modifica la dichiarazione della dipendenza selezionata."
  (interactive)
  (let ((entry (get-text-property (point) 'gdev-dependencies-entry)))
    (unless entry (user-error "Scegli una dipendenza"))
    (gdev-project-dependencies--edit entry)))

(defvar-keymap gdev-project-dependencies-mode-map
  "RET" #'push-button
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "e" #'gdev-project-dependencies-edit
  "g" #'gdev-project-dependencies-refresh
  "f" #'gdev-project-dependencies-filter
  "m" #'gdev-project-dependencies-choose
  "q" #'gdev-close-document)

(define-derived-mode gdev-project-dependencies-mode special-mode "Dipendenze"
  "Consulta o modifica le dichiarazioni del progetto."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (visual-line-mode 1))

(defun gdev-project-dependencies-show (&optional file)
  "Mostra le dipendenze del progetto o del manifesto FILE."
  (interactive (list (when current-prefix-arg (read-file-name "Manifesto: " nil nil t))))
  (let* ((editor (gdev-layout-editor))
         (directory (if editor (buffer-local-value 'default-directory (window-buffer editor))
                      default-directory))
         (explicit (and file (gdev-project-dependencies--validate-file file)))
         (manifests (gdev-project-dependencies--paths directory))
         (view (gdev-activity-buffer 'dependencies "*Dipendenze del progetto*"
                                     #'gdev-project-dependencies-mode)))
    (with-current-buffer view
      (let ((previous gdev-project-dependencies--manifest))
        (setq-local gdev-activity-kind nil)
        (setq default-directory directory
              gdev-project-dependencies--manifests (delete-dups (if explicit (cons explicit manifests) manifests)))
        (gdev-project-dependencies--select (or explicit (car manifests) previous))))
    (pop-to-buffer view)))

(provide 'gdev-project-dependencies)
;;; gdev-project-dependencies.el ends here
