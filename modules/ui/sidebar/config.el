;;; config.el --- :ui sidebar: esplora file e stato Git -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; L'esplora file si apre a sinistra al primo file o cartella. ⌘0 (C-c t e)
;; sposta il fuoco fra l'albero e l'area di modifica. Un clic o Spazio mostra
;; l'anteprima, doppio clic o Invio apre il file. Comando-clic e m aggiungono
;; o rimuovono una voce. Maiusc-clic e Maiusc con le frecce estendono la scelta.
;; Invio apre i file selezionati, c copia i loro percorsi ed Esc torna a una
;; voce. r rivela il file, g aggiorna e ? mostra la legenda Git.
;; Le frecce sinistra e destra chiudono e aprono i rami. Le cartelle riassumono
;; i cambiamenti anche quando sono chiuse. La barra offre un interprete dei
;; comandi nella cartella selezionata, l'apertura di un progetto SSH e il
;; navigatore EWW. Git gira in un processo asincrono. Solo le barre locali
;; visibili si aggiornano periodicamente; per una connessione SSH si usa g.

;;; Code:

(require 'button)
(require 'face-remap)
(require 'hl-line)
(require 'text-property-search)
(require 'gdev-lib)
(require 'gdev-commands)
(require 'gdev-ui)
(require 'gdev-workspace-state)

(declare-function gdev-term-here "../../term/eat/config")
(declare-function gdev-remote-open-folder "../../tools/remote/config")
(declare-function gdev-editor-open-preview "../workbench/gdev-editor-tabs")
(defvar mac-command-modifier)
(defvar ns-command-modifier)

(defgroup gdev-sidebar nil
  "Esplora file e stato Git."
  :group 'gdev)

(defcustom gdev-sidebar-refresh-interval 12
  "Secondi fra gli aggiornamenti Git delle barre locali visibili."
  :type '(integer :tag "Secondi"))

(defcustom gdev-sidebar-hidden-names '(".git" ".svn" ".hg" "CVS" ".DS_Store" "Thumbs.db")
  "Nomi di file e cartelle che Esplora file non mostra.
Valgono a ogni livello dell'albero. Gli altri file nascosti restano visibili."
  :type '(repeat (string :tag "Nome")))

(defconst gdev-sidebar--badges
  '((conflict "!" error "conflitto")
    (deleted "−" error "eliminato")
    (renamed "→" font-lock-keyword-face "rinominato")
    (added "+" success "aggiunto")
    (modified "●" warning "modificato")
    (untracked "?" font-lock-constant-face "non tracciato")
    (staged "✓" success "nell'indice Git")
    (ignored "·" shadow "ignorato")))

(defface gdev-sidebar-current-file
  '((t :inherit gdev-ui-action :weight semi-bold))
  "Indicatore del documento aperto nell'editor."
  :group 'gdev-sidebar)

(defface gdev-sidebar-selection
  '((t :inherit gdev-ui-side-selection :extend t))
  "Sfondo delle voci selezionate nell’albero."
  :group 'gdev-sidebar)

(defface gdev-sidebar-focus-row
  '((t :underline t))
  "Posizione della tastiera durante una selezione multipla."
  :group 'gdev-sidebar)

(defface gdev-sidebar-current-row
  '((t :inherit gdev-ui-side-current :extend t))
  "Riga del file aperto o della cartella che lo contiene."
  :group 'gdev-sidebar)

(defface gdev-sidebar-hover
  '((t :inherit gdev-ui-side-hover))
  "Evidenzia la voce sotto il puntatore."
  :group 'gdev-sidebar)

(defface gdev-sidebar-title
  '((t :inherit gdev-ui-side-title))
  "Nome della cartella di lavoro."
  :group 'gdev-sidebar)

(defface gdev-sidebar-filename
  '((t :inherit variable-pitch))
  "Nomi dei file nell'albero grafico."
  :group 'gdev-sidebar)

(defface gdev-sidebar-folder-name
  '((t :inherit gdev-sidebar-filename :weight semi-bold))
  "Nomi delle cartelle nell'albero grafico."
  :group 'gdev-sidebar)

(defface gdev-sidebar-control
  '((t :inherit (gdev-sidebar-current-file variable-pitch) :weight medium))
  "Comandi in alto in Esplora file."
  :group 'gdev-sidebar)

(defun gdev-sidebar--command-as-meta (command)
  "Rendi disponibile COMMAND se la tastiera usa Comando come Meta."
  (when (pcase window-system
          ('mac (eq mac-command-modifier 'meta))
          ('ns (eq ns-command-modifier 'meta)))
    command))

(defvar-keymap gdev-sidebar-entry-map
  :parent button-map
  "RET" #'gdev-sidebar-open
  "<follow-link>" #'ignore
  "<mouse-1>" #'gdev-sidebar-click
  "<double-mouse-1>" #'gdev-sidebar-click
  "S-<mouse-1>" #'gdev-sidebar-click
  "s-<mouse-1>" #'gdev-sidebar-click
  "M-<mouse-1>" '(menu-item "" gdev-sidebar-click :filter gdev-sidebar--command-as-meta))

(define-button-type 'gdev-sidebar-entry
  'face nil 'keymap gdev-sidebar-entry-map 'mouse-face 'gdev-sidebar-hover)

(defvar-local gdev-sidebar--root nil)
(defvar-local gdev-sidebar--roots nil)
(defvar-local gdev-sidebar--expanded nil)
(defvar-local gdev-sidebar--directory-cache nil)
(defvar-local gdev-sidebar--directory-times nil)
(defvar-local gdev-sidebar--directory-process nil)
(defvar-local gdev-sidebar--directory-paths nil)
(defvar-local gdev-sidebar--directory-check-timer nil)
(defvar-local gdev-sidebar--deferred-reveal nil)
(defvar gdev-sidebar--cold-directories nil)
(defvar gdev-sidebar--defer-directory-reads nil)
(defvar gdev-sidebar--force-directory-reads nil)

(defvar-local gdev-sidebar--repo nil)
(defvar-local gdev-sidebar--status nil)
(defvar-local gdev-sidebar--removed nil)
(defvar-local gdev-sidebar--last-output nil)
(defvar-local gdev-sidebar--git-needs-render nil)
(defvar-local gdev-sidebar--process nil)
(defvar-local gdev-sidebar--current-file nil)
(defvar-local gdev-sidebar--current-marker nil)
(defvar-local gdev-sidebar--current-row nil)
(defvar-local gdev-sidebar--render-width nil)
(defvar-local gdev-sidebar--positions nil
  "Indice dei percorsi mostrati nell'ultimo ridisegno dell'albero.")
(defvar-local gdev-sidebar--positions-tick nil)
(defvar-local gdev-sidebar--selection nil
  "Percorsi della selezione esplicita, associati alla loro evidenziazione.")
(defvar-local gdev-sidebar--selection-anchor nil
  "Percorso dal quale estendere la selezione nella vista corrente.")
(defvar gdev-sidebar--timer nil)

(defconst gdev-sidebar--directory-read-limit 256
  "Soglia di voci oltre la quale la lettura passa al sottoprocesso.")

(defun gdev-sidebar--git-kinds (xy)
  "Traduce i due caratteri XY dello stato porcelain di Git in indicatori."
  (cond ((member xy '("DD" "AU" "UD" "UA" "DU" "AA" "UU")) '(conflict))
        ((equal xy "??") '(untracked))
        ((equal xy "!!") '(ignored))
        (t (delq nil (list (unless (eq (aref xy 0) ?\s) 'staged)
                           (and (string-match-p "D" xy) 'deleted)
                           (and (string-match-p "R" xy) 'renamed)
                           (and (string-match-p "[AC]" xy) 'added)
                           (and (string-match-p "[MT]" xy) 'modified))))))

(defun gdev-sidebar--record-git (file kinds root status removed deleted-children)
  "Registra KINDS per FILE e per le cartelle fino a ROOT.
DELETED-CHILDREN evita di confrontare a ogni inserimento la lista in REMOVED."
  (when (string-prefix-p root file)
    (dolist (kind kinds)
      (cl-pushnew kind (gethash file status)))
    (unless (equal kinds '(ignored))
      (let ((child file)
            (parent (file-name-directory file)))
        (while (and parent (string-prefix-p root parent))
          (let ((directory (directory-file-name parent)))
            (dolist (kind kinds)
              (cl-pushnew kind (gethash directory status)))
            (when (and (memq 'deleted kinds) (not (gethash child deleted-children)))
              (puthash child t deleted-children)
              (push child (gethash directory removed)))
            (setq child directory
                  parent (unless (equal parent root)
                           (file-name-directory directory)))))))))

(defun gdev-sidebar--git-index (output repo root)
  "Indicizza OUTPUT da Git in REPO per il sottoalbero ROOT.
Restituisce (STATI . RIMOSSI), due tabelle per percorso assoluto."
  (let ((status (make-hash-table :test #'equal))
        (removed (make-hash-table :test #'equal))
        (deleted-children (make-hash-table :test #'equal))
        (entries (split-string output "\0" t)))
    (while entries
      (let ((entry (pop entries)))
        (when (and (> (length entry) 3) (eq (aref entry 2) ?\s))
          (let* ((xy (substring entry 0 2))
                 (file (directory-file-name (concat repo (substring entry 3)))))
            (gdev-sidebar--record-git file (gdev-sidebar--git-kinds xy)
                                      root status removed deleted-children)
            (when-let* (((string-match-p "[RC]" xy))
                        (source (pop entries))
                        ((string-match-p "R" xy)))
              (gdev-sidebar--record-git (concat repo source) '(deleted)
                                        root status removed deleted-children))))))
    (cons status removed)))

(defun gdev-sidebar--badges-for (file)
  "Restituisce gli indicatori per FILE, con legenda al passaggio del mouse."
  (when (and gdev-sidebar--status (> (hash-table-count gdev-sidebar--status) 0))
    (let ((kinds (gethash file gdev-sidebar--status)))
      (unless kinds
        (let ((dir (file-name-directory file)))
          (while (and dir (not kinds) (string-prefix-p gdev-sidebar--root dir))
            (when (memq 'ignored (gethash (directory-file-name dir) gdev-sidebar--status))
              (setq kinds '(ignored)))
            (setq dir (unless (equal dir gdev-sidebar--root)
                        (file-name-directory (directory-file-name dir)))))))
      (when kinds
        (apply #'concat
               (cl-loop for (kind icon face label) in gdev-sidebar--badges
                        when (memq kind kinds)
                        collect (propertize icon 'face face 'help-echo (concat "Git: " label))))))))

(defun gdev-sidebar-git-legend ()
  "Mostra il significato delle icone Git nella barra laterale."
  (interactive)
  (let ((help-window-select t))
    (with-help-window "*Legenda Git*"
      (princ "Le cartelle riassumono gli stati dei file al loro interno.\n\n")
      (pcase-dolist (`(,_ ,icon ,face ,label) gdev-sidebar--badges)
        (princ (concat "  " (propertize icon 'face face) "   " label "\n"))))))

(defun gdev-sidebar--cache-directory (directory folders files)
  "Conserva FOLDERS e FILES di DIRECTORY nell'ordine mostrato dall'albero.
Esclude le voci di `gdev-sidebar-hidden-names'."
  (when gdev-sidebar-hidden-names
    (let ((visible (lambda (path)
                     (not (member (file-name-nondirectory path) gdev-sidebar-hidden-names)))))
      (setq folders (seq-filter visible folders)
            files (seq-filter visible files))))
  (unless (file-remote-p directory)
    (puthash directory (file-attribute-modification-time (file-attributes directory))
             gdev-sidebar--directory-times))
  (puthash directory (list (sort folders #'string-lessp) (sort files #'string-lessp))
           gdev-sidebar--directory-cache))

(defun gdev-sidebar--read-directory (directory &optional limit)
  "Leggi e conserva i percorsi reali di DIRECTORY.
Con LIMIT restituisci nil se la cartella contiene più di LIMIT voci."
  (let ((entries (ignore-errors
                   (if limit
                       (directory-files-and-attributes
                        directory t directory-files-no-dot-files-regexp t nil (1+ limit))
                     (directory-files-and-attributes
                      directory t directory-files-no-dot-files-regexp t))))
        folders files)
    (unless (and limit (length> entries limit))
      (dolist (entry entries)
        (let ((path (car entry)))
          (if (or (eq (file-attribute-type (cdr entry)) t)
                  (and (stringp (file-attribute-type (cdr entry)))
                       (file-directory-p path)))
              (push path folders)
            (push path files))))
      (gdev-sidebar--cache-directory directory folders files))))

(defun gdev-sidebar--directory-entries (directory)
  "Restituisci le voci di DIRECTORY, o nil durante una lettura differita."
  (or (gethash directory gdev-sidebar--directory-cache)
      (cond
       ((or (not gdev-sidebar--defer-directory-reads)
            (file-remote-p directory)
            (find-file-name-handler directory 'directory-files-and-attributes))
        (gdev-sidebar--read-directory directory))
       ((or (member directory gdev-sidebar--directory-paths)
            (member directory gdev-sidebar--cold-directories))
        nil)
       ((gdev-sidebar--read-directory directory gdev-sidebar--directory-read-limit))
       ((gdev-find-executable "perl")
        (push directory gdev-sidebar--cold-directories)
        nil)
       (t (gdev-sidebar--read-directory directory)))))

(defun gdev-sidebar--children (directory)
  "Elenca le voci di DIRECTORY, comprese quelle eliminate da Git."
  (let ((entries (gdev-sidebar--directory-entries directory))
        (removed (and gdev-sidebar--removed
                      (gethash (directory-file-name directory) gdev-sidebar--removed))))
    (if (or (not entries) (not removed))
        entries
      (let* ((folders (car entries))
             (files (cadr entries))
             ;; Poche eliminazioni costano meno di un indice temporaneo.
             (existing (when (nthcdr 32 removed)
                         (make-hash-table :test #'equal
                                          :size (+ (length folders) (length files)))))
             deleted-folders deleted-files)
        (when existing
          (dolist (path folders) (puthash path t existing))
          (dolist (path files) (puthash path t existing)))
        (dolist (path removed)
          (unless (if existing (gethash path existing)
                    (or (member path folders) (member path files)))
            (if (gethash path gdev-sidebar--removed)
                (push path deleted-folders)
              (push path deleted-files))))
        (list (gdev-sidebar--merge-deletions folders deleted-folders)
              (gdev-sidebar--merge-deletions files deleted-files))))))

(defun gdev-sidebar--merge-deletions (entries deleted)
  "Unisci DELETED alle ENTRIES già ordinate, lasciando intatta la cache."
  (if deleted
      (cl-merge 'list (copy-sequence entries) (sort deleted #'string-lessp) #'string-lessp)
    entries))

(defun gdev-sidebar--cache-scanned-directories (records)
  "Aggiorna la cache con i RECORDS prodotti dal processo di scansione."
  (let (directory folders files)
    (dolist (record records)
      (let ((path (substring record 1)))
        (pcase (aref record 0)
          (?R (when directory (gdev-sidebar--cache-directory directory folders files))
              (setq directory path folders nil files nil))
          (?D (push path folders))
          (?F (push path files)))))
    (when directory (gdev-sidebar--cache-directory directory folders files))))

(defun gdev-sidebar--cancel-directory-check ()
  "Annulla il controllo dei metadati delle cartelle."
  (when gdev-sidebar--directory-check-timer
    (cancel-timer gdev-sidebar--directory-check-timer)
    (setq gdev-sidebar--directory-check-timer nil)))

(defun gdev-sidebar--cancel-directory-scan ()
  "Ferma la scansione legata all'albero corrente."
  (gdev-sidebar--cancel-directory-check)
  (let ((process gdev-sidebar--directory-process))
    (setq gdev-sidebar--directory-process nil
          gdev-sidebar--directory-paths nil)
    (when (process-live-p process) (delete-process process))))

(defun gdev-sidebar--directory-scan-fallback ()
  "Rileggi le cartelle direttamente dopo un errore del sottoprocesso."
  (clrhash gdev-sidebar--directory-cache)
  (let ((gdev-sidebar--force-directory-reads t))
    (gdev-sidebar--render)))

(defun gdev-sidebar--apply-directory-scan (process sidebar)
  "Applica il risultato di PROCESS se appartiene ancora a SIDEBAR."
  (when (buffer-live-p sidebar)
    (with-current-buffer sidebar
      (when (eq process gdev-sidebar--directory-process)
        (setq gdev-sidebar--directory-process nil
              gdev-sidebar--directory-paths nil)
        (if (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
            (let ((records (with-current-buffer (process-buffer process)
                             (split-string (buffer-string) "\0" t)))
                  changed)
              (gdev-sidebar--cache-scanned-directories records)
              (dolist (entry (process-get process 'gdev-sidebar-cold-times))
                (let ((directory (car entry)) (time (cdr entry)))
                  (unless (equal time (gethash directory gdev-sidebar--directory-times))
                    (puthash directory time gdev-sidebar--directory-times)
                    (push directory changed))))
              (when (get-buffer-window sidebar 'visible)
                (when changed (gdev-sidebar--refresh-directories changed))
                (gdev-sidebar--render)))
          (if (get-buffer-window sidebar 'visible)
              (gdev-sidebar--directory-scan-fallback)
            (clrhash gdev-sidebar--directory-cache)))))))

(defun gdev-sidebar--refresh-directories (&optional directories)
  "Aggiorna DIRECTORIES o tutta la cache senza bloccare l'albero visibile."
  (setq directories
        (delete-dups
         (append (or directories (hash-table-keys gdev-sidebar--directory-cache))
                 gdev-sidebar--directory-paths nil)))
  (gdev-sidebar--cancel-directory-scan)
  (unless
      (when-let* (((not (file-remote-p gdev-sidebar--root)))
                  (directories (seq-remove #'file-remote-p directories))
                  (perl (gdev-find-executable "perl")))
        (let* ((sidebar (current-buffer))
              (cold-times (cl-loop for directory in directories
                                   unless (gethash directory gdev-sidebar--directory-cache)
                                   collect (cons directory
                                                 (file-attribute-modification-time
                                                  (file-attributes directory)))))
              (output (generate-new-buffer " *gdev-sidebar-directories*"))
              (errors (generate-new-buffer " *gdev-sidebar-directories-errors*"))
              (sentinel
               (lambda (child _event)
                 (when (memq (process-status child) '(exit signal failed))
                   (unwind-protect
                       (gdev-sidebar--apply-directory-scan child sidebar)
                     (when (buffer-live-p output) (kill-buffer output))
                     (when (buffer-live-p errors) (kill-buffer errors)))))))
          (condition-case nil
              (progn
                (setq gdev-sidebar--directory-paths directories
                      gdev-sidebar--directory-process
                      (make-process
                       :name "gdev-sidebar-directories" :buffer output :stderr errors :noquery t
                       :connection-type 'pipe
                       :coding (or file-name-coding-system default-file-name-coding-system 'utf-8-unix)
                       ;; Protocollo delimitato da NUL, valido anche per nomi con a capo.
                       :command (append
                                 (list perl "-e"
                                       "for my $dir (@ARGV) {
  print \"R\", $dir, \"\\0\";
  opendir(my $handle, $dir) or next;
  my $prefix = $dir =~ m{/$} ? $dir : \"$dir/\";
  while (defined(my $name = readdir($handle))) {
    next if $name eq \".\" || $name eq \"..\";
    my $path = $prefix . $name;
    next unless lstat($path);
    print((-d $path ? \"D\" : \"F\"), $path, \"\\0\");
  }
}" "--")
                                 directories)
                       ;; La risposta può arrivare già dentro `make-process'.
                       ;; Collega prima identità e metadati, poi la callback.
                       :sentinel #'ignore))
                (let ((process gdev-sidebar--directory-process))
                  (process-put process 'gdev-sidebar-cold-times cold-times)
                  (set-process-sentinel process sentinel)
                  (when (memq (process-status process) '(exit signal failed))
                    (funcall sentinel process ""))
                  process))
            (file-error
             (setq gdev-sidebar--directory-paths nil)
             (kill-buffer output)
             (kill-buffer errors)
             nil))))
    (gdev-sidebar--directory-scan-fallback)))

(defun gdev-sidebar--check-directories (pending changed)
  "Controlla PENDING a gruppi, aggiungendo le cartelle modificate a CHANGED."
  (let ((deadline (+ (float-time) 0.004))
        (remaining 128))
    (while (and pending (> remaining 0) (< (float-time) deadline))
      (let ((directory (pop pending)))
        (cl-decf remaining)
        (unless (equal (gethash directory gdev-sidebar--directory-times)
                       (file-attribute-modification-time (file-attributes directory)))
          (push directory changed)))))
  (cond (pending
         (let ((sidebar (current-buffer)) timer)
           (setq timer
                 (run-at-time 0.01 nil
                              (lambda ()
                                (when (buffer-live-p sidebar)
                                  (with-current-buffer sidebar
                                    (when (eq timer gdev-sidebar--directory-check-timer)
                                      (setq gdev-sidebar--directory-check-timer nil)
                                      (when (get-buffer-window sidebar 'visible)
                                        (gdev-sidebar--check-directories pending changed))))))))
           (setq gdev-sidebar--directory-check-timer timer)))
        (changed (gdev-sidebar--refresh-directories changed))
        (gdev-sidebar--git-needs-render (gdev-sidebar--render))))

(defun gdev-sidebar--refresh-git-tree (redraw)
  "Rileggi le cartelle modificate e, con REDRAW, aggiorna gli indicatori."
  (when redraw
    (setq gdev-sidebar--git-needs-render t))
  (gdev-sidebar--cancel-directory-check)
  (gdev-sidebar--check-directories
   (unless (file-remote-p gdev-sidebar--root) (hash-table-keys gdev-sidebar--directory-cache))
   nil))

(defun gdev-sidebar--icons (frame)
  "Prepara le due icone dell'albero per colori e scala di FRAME."
  (when (and (display-graphic-p frame) (image-type-available-p 'svg))
    (let ((size (round (* 1.7 (frame-char-width frame)))))
      (cons (create-image (gdev-config-file "icons/project.svg") 'svg nil
                          :width size :height size :ascent 'center
                          :foreground (face-foreground 'gdev-sidebar-current-file frame t))
            (create-image (gdev-config-file "icons/file.svg") 'svg nil
                          :width size :height size :ascent 'center
                          :foreground (face-foreground 'gdev-ui-secondary frame t))))))

(defun gdev-sidebar--column (column)
  "Restituisce uno spazio che fa avanzare fino a COLUMN."
  (propertize " " 'display `(space :align-to ,column)))

(defun gdev-sidebar--fit-label (label face width &optional file measure)
  "Mostra LABEL in FACE entro WIDTH, mantenendo l'estensione di FILE.
MEASURE è la funzione di misura. Il valore predefinito usa i pixel."
  (let* ((measure (or measure #'string-pixel-width))
         (label (propertize label 'face face)))
    (cond ((<= (funcall measure label) width) label)
          ;; Un solo punto di verità: `gdev-ui-fit-file-name' protegge i nomi senza
          ;; estensione, per i quali `file-name-extension' dà una stringa vuota.
          (file (gdev-ui-fit-file-name label width measure))
          (t (gdev-ui-fit-text label width measure)))))

(defun gdev-sidebar--insert-entry (path folder depth width graphical icons &optional label)
  "Inserisce PATH a DEPTH in WIDTH colonne, con ICONS su GRAPHICAL.
FOLDER indica un ramo espandibile e LABEL ne può sostituire il nome."
  (let* ((expanded (and folder (gethash path gdev-sidebar--expanded)))
         (mark (or (gdev-sidebar--badges-for path) ""))
         (badge-start (- width (string-width mark) 2))
         (icon (if folder (car icons) (cdr icons)))
         (indent (min (* 2 depth) (max 0 (- badge-start (if icon 10 8)))))
         (name (string-replace "\n" "\\n" (or label (file-name-nondirectory path)))))
    (insert (make-string (1+ indent) ?\s))
    (let ((start (point)))
      (unless (gethash path gdev-sidebar--positions)
        (puthash path start gdev-sidebar--positions))
      (if graphical
          (let* ((column (+ indent (if icon 5 3)))
                 (face (if folder 'gdev-sidebar-folder-name 'gdev-sidebar-filename))
                 (pixels (* (max 1 (- badge-start column 2)) (frame-char-width))))
            (insert (propertize (cond (expanded "⌄") (folder "›") (t " "))
                                'face 'gdev-ui-secondary)
                    (gdev-sidebar--column (+ indent 3)))
            (when icon
              (insert (propertize " " 'display icon) (gdev-sidebar--column column)))
            (insert (gdev-sidebar--fit-label name face pixels (not folder))))
        (insert (cond (expanded "▾ ") (folder "▸ ") (t "  "))
                (gdev-sidebar--fit-label name (if folder 'bold 'default)
                                         (max 1 (- badge-start indent 5))
                                         (not folder) #'string-width)))
      (unless (string-empty-p mark)
        (insert (gdev-sidebar--column badge-start)))
      (put-text-property start (point) 'help-echo path)
      (insert mark)
      (make-text-button start (point) :type 'gdev-sidebar-entry
                        'gdev-sidebar-path path 'gdev-sidebar-folder folder
                        'action #'gdev-sidebar--activate))
    (insert "\n")
    (when expanded (gdev-sidebar--insert-children path (1+ depth) width graphical icons))))

(defconst gdev-sidebar--render-limit 2000
  "Voci mostrate al massimo per cartella.
Ogni voce è un pulsante con la sua misura in pixel: con decine di migliaia
di file (registri, cache, dati) ogni ridisegno bloccherebbe l'editor.")

(defun gdev-sidebar--insert-note (text depth width graphical)
  "Inserisce la riga informativa TEXT a DEPTH in WIDTH colonne, con GRAPHICAL."
  (let* ((indent (min (* 2 depth) (max 0 (- width 6))))
         (available (max 1 (- width indent 3))))
    (insert (make-string (1+ indent) ?\s)
            (gdev-sidebar--fit-label text 'gdev-ui-secondary
                                     (if graphical (* available (frame-char-width)) available)
                                     nil (unless graphical #'string-width))
            "\n")))

(defun gdev-sidebar--insert-children (directory depth width graphical icons)
  "Inserisce le voci in DIRECTORY a DEPTH in WIDTH colonne, con ICONS su GRAPHICAL."
  (if-let* ((entries (gdev-sidebar--children directory)))
      (let ((budget gdev-sidebar--render-limit)
            (hidden 0))
        (dolist (path (car entries))
          (unless (member (file-name-as-directory path) gdev-sidebar--roots)
            (if (> budget 0)
                (progn (gdev-sidebar--insert-entry path t depth width graphical icons)
                       (cl-decf budget))
              (cl-incf hidden))))
        (dolist (path (cadr entries))
          (if (> budget 0)
              (progn (gdev-sidebar--insert-entry path nil depth width graphical icons)
                     (cl-decf budget))
            (cl-incf hidden)))
        (when (> hidden 0)
          (gdev-sidebar--insert-note (format "… altre %d voci non mostrate" hidden)
                                     depth width graphical)))
    (gdev-sidebar--insert-note "Lettura della cartella…" depth width graphical)))

(defun gdev-sidebar--insert-roots (width graphical icons)
  "Inserisce le cartelle di lavoro in WIDTH colonne, con ICONS su GRAPHICAL."
  (if (cdr gdev-sidebar--roots)
      (let ((names (mapcar (lambda (root) (file-name-nondirectory (directory-file-name root)))
                           gdev-sidebar--roots)))
        (cl-loop for root in gdev-sidebar--roots
                 for name in names
                 for label = (if (or (string-empty-p name) (> (cl-count name names :test #'equal) 1))
                                 (abbreviate-file-name root)
                               name)
                 do (gdev-sidebar--insert-entry (directory-file-name root) t 0 width graphical icons label)))
    (gdev-sidebar--insert-children gdev-sidebar--root 0 width graphical icons)))

(defun gdev-sidebar-web ()
  "Cerca sul Web o apri un indirizzo nella finestra principale."
  (interactive)
  (gdev-focus-editor)
  (call-interactively (if (commandp 'gdev-web-browser) 'gdev-web-browser #'eww)))

(defun gdev-sidebar--row ()
  "Restituisce il pulsante del file o della cartella sulla riga corrente."
  (let* ((start (line-beginning-position))
         (button (or (button-at start)
                     (next-button start))))
    (and button (< (button-start button) (line-end-position)) button)))

(defun gdev-sidebar--path-at-point ()
  "Restituisce il percorso della voce sulla riga corrente."
  (when-let* ((row (gdev-sidebar--row)))
    (button-get row 'gdev-sidebar-path)))

(defun gdev-sidebar--path-position (path)
  "Trova la posizione della voce PATH tra le righe visibili."
  (when path
    (if (and (not (buffer-narrowed-p)) (eql gdev-sidebar--positions-tick (buffer-modified-tick)))
        (gethash path gdev-sidebar--positions)
      (save-excursion
        (goto-char (point-min))
        (when-let* ((match (text-property-search-forward 'gdev-sidebar-path path t)))
          (prop-match-beginning match))))))

(defun gdev-sidebar--selection-at-point ()
  "Restituisci i percorsi selezionati sulla riga corrente, in ordine visibile."
  (when-let* ((path (gdev-sidebar--path-at-point)))
    (if (and (> (hash-table-count gdev-sidebar--selection) 1)
             (gethash path gdev-sidebar--selection))
        (sort (hash-table-keys gdev-sidebar--selection)
              (lambda (a b) (< (gdev-sidebar--path-position a) (gdev-sidebar--path-position b))))
      (list path))))

(defun gdev-sidebar--update-focus-face ()
  "Distingui il fuoco dalle voci della selezione esplicita."
  (setq hl-line-face (if (hash-table-empty-p gdev-sidebar--selection)
                        'gdev-sidebar-selection
                      'gdev-sidebar-focus-row))
  (when (overlayp hl-line-overlay)
    (overlay-put hl-line-overlay 'face hl-line-face)))

(defun gdev-sidebar--paint-selection-row (overlay position)
  "Estendi OVERLAY alla riga di POSITION senza uscire dal riquadro."
  (save-excursion
    (goto-char position)
    (move-overlay overlay (line-beginning-position) (min (point-max) (1+ (line-end-position))))))

(defun gdev-sidebar--select-path (path position)
  "Aggiungi PATH alla selezione, evidenziandone la riga di POSITION."
  (let ((overlay (make-overlay position position)))
    (overlay-put overlay 'face 'gdev-sidebar-selection)
    (overlay-put overlay 'priority (1- hl-line-overlay-priority))
    (puthash path overlay gdev-sidebar--selection)
    (gdev-sidebar--paint-selection-row overlay position)))

(defun gdev-sidebar--refresh-selection ()
  "Riallinea la selezione dopo un ridisegno e scarta le righe scomparse."
  (maphash (lambda (path overlay)
             (if-let* ((position (gdev-sidebar--path-position path)))
                 (gdev-sidebar--paint-selection-row overlay position)
               (delete-overlay overlay)
               (remhash path gdev-sidebar--selection)))
           gdev-sidebar--selection)
  (unless (gdev-sidebar--path-position gdev-sidebar--selection-anchor)
    (setq gdev-sidebar--selection-anchor nil))
  (gdev-sidebar--update-focus-face))

(defun gdev-sidebar-clear-selection ()
  "Ritorna alla sola voce corrente dell’albero."
  (interactive)
  (maphash (lambda (_ overlay) (delete-overlay overlay)) gdev-sidebar--selection)
  (clrhash gdev-sidebar--selection)
  (setq gdev-sidebar--selection-anchor nil)
  (gdev-sidebar--update-focus-face))

(defun gdev-sidebar-toggle-selection (&optional origin)
  "Aggiungi o rimuovi la voce corrente dalla selezione.
ORIGIN è la voce che aveva il fuoco prima di un clic modificato."
  (interactive)
  (when-let* ((path (gdev-sidebar--path-at-point)))
    (when (and (hash-table-empty-p gdev-sidebar--selection) (not (equal path origin)))
      (when-let* ((position (gdev-sidebar--path-position origin)))
        (gdev-sidebar--select-path origin position)))
    (if-let* ((overlay (gethash path gdev-sidebar--selection)))
        (progn
          (delete-overlay overlay)
          (remhash path gdev-sidebar--selection))
      (gdev-sidebar--select-path path (gdev-sidebar--path-position path)))
    (setq gdev-sidebar--selection-anchor path
          gdev-sidebar--deferred-reveal nil)
    (gdev-sidebar--update-focus-face)))

(defun gdev-sidebar--select-range (origin)
  "Estendi la selezione da ORIGIN alla riga corrente, mantenendo l’ancora."
  (when-let* ((path (gdev-sidebar--path-at-point))
              (end (gdev-sidebar--path-position path)))
    (let* ((anchor (or gdev-sidebar--selection-anchor origin path))
           (start (or (gdev-sidebar--path-position anchor) end))
           (first (min start end))
           (last (max start end)))
      (maphash (lambda (selected overlay)
                 (unless (<= first (gdev-sidebar--path-position selected) last)
                   (delete-overlay overlay)
                   (remhash selected gdev-sidebar--selection)))
               gdev-sidebar--selection)
      (save-excursion
        (goto-char first)
        (while (<= (point) last)
          (when-let* ((row (gdev-sidebar--row))
                      (entry (button-get row 'gdev-sidebar-path))
                      ((not (gethash entry gdev-sidebar--selection))))
            (gdev-sidebar--select-path entry (button-start row)))
          (forward-line 1)))
      (setq gdev-sidebar--selection-anchor anchor
            gdev-sidebar--deferred-reveal nil)
      (gdev-sidebar--update-focus-face))))

(defun gdev-sidebar--move-row (step)
  "Sposta il fuoco alla prossima voce visibile nella direzione STEP."
  (let ((origin (point)))
    (while (and (zerop (forward-line step)) (not (gdev-sidebar--path-at-point))))
    (unless (gdev-sidebar--path-at-point) (goto-char origin))))

(defun gdev-sidebar-select-next ()
  "Estendi la selezione alla voce seguente."
  (interactive)
  (let ((origin (gdev-sidebar--path-at-point)))
    (gdev-sidebar--move-row 1)
    (gdev-sidebar--select-range origin)))

(defun gdev-sidebar-select-previous ()
  "Estendi la selezione alla voce precedente."
  (interactive)
  (let ((origin (gdev-sidebar--path-at-point)))
    (gdev-sidebar--move-row -1)
    (gdev-sidebar--select-range origin)))

(defun gdev-sidebar-select-all ()
  "Seleziona tutti i file e le cartelle visibili nell’albero."
  (interactive)
  (unless (gdev-sidebar--path-at-point)
    (gdev-sidebar--move-row 1))
  (when-let* ((path (gdev-sidebar--path-at-point)))
    (maphash (lambda (entry position)
               (unless (gethash entry gdev-sidebar--selection)
                 (gdev-sidebar--select-path entry position)))
             gdev-sidebar--positions)
    (setq gdev-sidebar--selection-anchor path
          gdev-sidebar--deferred-reveal nil)
    (gdev-sidebar--update-focus-face)))

(defun gdev-sidebar--ancestors (file)
  "Elenca le cartelle che contengono FILE, dalla radice dell'albero in giù."
  (let ((root (gdev-sidebar--root-for file))
        (parent (file-name-directory file))
        ancestors)
    (while (and root parent (string-prefix-p root parent)
                (or (cdr gdev-sidebar--roots) (not (equal parent root))))
      (let ((directory (directory-file-name parent)))
        (push directory ancestors)
        (setq parent (unless (equal parent root) (file-name-directory directory)))))
    ancestors))

(defun gdev-sidebar--shown-roots ()
  "Restituisce le cartelle mostrate nell'albero."
  (or gdev-sidebar--roots (and gdev-sidebar--root (list gdev-sidebar--root))))

(defun gdev-sidebar--root-for (path)
  "Restituisce la cartella mostrata che contiene PATH."
  (gdev-workspace-root-for path (gdev-sidebar--shown-roots)))

(defun gdev-sidebar-copy-paths ()
  "Copia i percorsi assoluti delle voci selezionate, uno per riga."
  (interactive)
  (if-let* ((paths (gdev-sidebar--selection-at-point)))
      (progn
        (kill-new (string-join paths "\n"))
        (message (if (cdr paths) "Percorsi copiati" "Percorso copiato")))
    (user-error "Seleziona un file o una cartella dell’albero")))

(defun gdev-sidebar-copy-relative-path ()
  "Copia i percorsi selezionati, ciascuno relativo alla propria radice."
  (interactive)
  (if-let* ((paths (gdev-sidebar--selection-at-point)))
      (progn
        (kill-new (mapconcat (lambda (path)
                               (gdev-command-relative-name path (gdev-sidebar--shown-roots)))
                             paths "\n"))
        (message (if (cdr paths) "Percorsi relativi copiati" "Percorso relativo copiato")))
    (user-error "Seleziona un file o una cartella dell’albero")))

(defun gdev-sidebar--folder-p (path)
  "Restituisci non nil se PATH è mostrato come cartella."
  (when-let* ((position (gdev-sidebar--path-position path)))
    (get-text-property position 'gdev-sidebar-folder)))

(defun gdev-sidebar-compare-selection-p ()
  "Indica se dalla riga corrente sono selezionati due file da confrontare."
  (and (derived-mode-p 'gdev-sidebar-mode)
       (= (hash-table-count gdev-sidebar--selection) 2)
       (gethash (gdev-sidebar--path-at-point) gdev-sidebar--selection)
       (not (seq-some #'gdev-sidebar--folder-p (hash-table-keys gdev-sidebar--selection)))))

(defun gdev-sidebar-compare-selection ()
  "Confronta i due file selezionati nella vista di confronto di GDev."
  (interactive)
  (unless (gdev-sidebar-compare-selection-p)
    (user-error "Seleziona due file nell’albero"))
  (apply #'gdev-compare-files (gdev-sidebar--selection-at-point)))

(defun gdev-sidebar-find-entry ()
  "Seleziona una voce già visibile nell'albero."
  (interactive)
  (unless (and gdev-sidebar--positions (not (hash-table-empty-p gdev-sidebar--positions)))
    (user-error "Nessuna voce visibile nell’albero"))
  (let ((root (unless (cdr gdev-sidebar--roots) gdev-sidebar--root))
        (home (when (cdr gdev-sidebar--roots) (expand-file-name "~/" "/")))
        (completion-styles (append completion-styles '(substring)))
        candidates)
    (maphash
     (lambda (path _)
       ;; Le chiavi dell'indice sono percorsi assoluti già letti dal renderer.
       (push (cons (cond ((and root (string-prefix-p root path))
                          (substring path (length root)))
                         ((and home (string-prefix-p home path))
                          (concat "~/" (substring path (length home))))
                         (t path))
                   path)
             candidates))
     gdev-sidebar--positions)
    (let* ((choice (completing-read "Cerca nell’albero: " candidates nil t))
           (path (cdr (assoc choice candidates))))
      (unless (string-empty-p choice)
        (if-let* ((position (gdev-sidebar--path-position path)))
            (progn
              (gdev-sidebar-clear-selection)
              (setq gdev-sidebar--deferred-reveal nil)
              (goto-char position))
          (user-error "La voce non è più visibile nell’albero"))))))

(defun gdev-sidebar-collapse-folders ()
  "Comprimi i rami dell’albero, lasciando visibile la voce più vicina."
  (interactive)
  (unless (hash-table-empty-p gdev-sidebar--expanded)
    (let* ((selected (gdev-sidebar--path-at-point))
           (roots (when (cdr gdev-sidebar--roots)
                    (mapcar #'directory-file-name gdev-sidebar--roots)))
           (open-roots (seq-filter (lambda (root) (gethash root gdev-sidebar--expanded)) roots))
           (collapse-roots (= (length open-roots) (hash-table-count gdev-sidebar--expanded))))
      (clrhash gdev-sidebar--expanded)
      (unless collapse-roots
        (dolist (root open-roots) (puthash root t gdev-sidebar--expanded)))
      (setq gdev-sidebar--deferred-reveal nil)
      (gdev-sidebar--render
       (or (seq-find (lambda (path) (not (gethash path gdev-sidebar--expanded)))
                     (and selected (gdev-sidebar--ancestors selected)))
           selected)))))

(defun gdev-sidebar--mark-current-file ()
  "Segna il documento attivo o il ramo chiuso che lo contiene."
  (when (overlayp gdev-sidebar--current-marker)
    (delete-overlay gdev-sidebar--current-marker))
  (when (overlayp gdev-sidebar--current-row)
    (delete-overlay gdev-sidebar--current-row))
  (when (and gdev-sidebar--current-file
             (gdev-sidebar--root-for gdev-sidebar--current-file))
    (let ((path (or (seq-find (lambda (directory) (not (gethash directory gdev-sidebar--expanded)))
                              (gdev-sidebar--ancestors gdev-sidebar--current-file))
                    gdev-sidebar--current-file)))
      (when-let* ((position (gdev-sidebar--path-position path)))
        (save-excursion
          (goto-char position)
          (let* ((start (line-beginning-position))
                 (file-p (equal path gdev-sidebar--current-file))
                 (marker (or gdev-sidebar--current-marker
                             (setq gdev-sidebar--current-marker (make-overlay start (1+ start))))))
            (move-overlay marker start (1+ start))
            (overlay-put marker 'display
                         (propertize (if file-p "▏" "┊")
                                     'face 'gdev-sidebar-current-file))
            (overlay-put marker 'help-echo (if file-p "File aperto nell’editor"
                                             "Questa cartella contiene il file aperto"))
            (when (display-graphic-p)
              (unless gdev-sidebar--current-row
                (setq gdev-sidebar--current-row (make-overlay start start))
                (overlay-put gdev-sidebar--current-row 'face 'gdev-sidebar-current-row)
                (overlay-put gdev-sidebar--current-row 'priority (1- hl-line-overlay-priority)))
              (move-overlay gdev-sidebar--current-row start
                            (min (point-max) (1+ (line-end-position)))))))))))

(defun gdev-sidebar--editor-file (&optional frame)
  "Restituisce il file del gruppo editor attivo di FRAME."
  (when-let* ((editor (gdev-layout-editor frame)))
    (with-current-buffer (window-buffer editor)
      (and buffer-file-name (expand-file-name (or buffer-file-truename buffer-file-name))))))

(defun gdev-sidebar-actions ()
  "Mostra le azioni disponibili in Esplora file."
  (interactive)
  (let* ((choices (seq-filter (lambda (choice) (and (commandp (cdr choice))
                                                    (pcase (cdr choice)
                                                      ('gdev-sidebar-compare-selection
                                                       (gdev-sidebar-compare-selection-p))
                                                      ((or 'gdev-sidebar-copy-paths
                                                           'gdev-sidebar-copy-relative-path
                                                           'gdev-sidebar-toggle-selection)
                                                       (gdev-sidebar--path-at-point))
                                                      ('gdev-sidebar-clear-selection
                                                       (not (hash-table-empty-p gdev-sidebar--selection)))
                                                      (_ t))))
                              '(("Mostra il file aperto" . gdev-sidebar-reveal-current-file)
                                ("Cerca nell’albero…" . gdev-sidebar-find-entry)
                                ("Seleziona tutte le voci visibili" . gdev-sidebar-select-all)
                                ("Aggiungi o rimuovi la voce dalla selezione" . gdev-sidebar-toggle-selection)
                                ("Riduci la selezione alla voce corrente" . gdev-sidebar-clear-selection)
                                ("Copia percorsi" . gdev-sidebar-copy-paths)
                                ("Copia percorsi relativi" . gdev-sidebar-copy-relative-path)
                                ("Confronta file selezionati" . gdev-sidebar-compare-selection)
                                ("Comprimi tutti i rami" . gdev-sidebar-collapse-folders)
                                ("Aggiungi cartella allo spazio di lavoro…" . gdev-workspace-add-folder)
                                ("Rimuovi cartella dallo spazio di lavoro…" . gdev-workspace-remove-folder)
                                ("Apri terminale qui" . gdev-sidebar-terminal)
                                ("Apri cartella via SSH…" . gdev-remote-open-folder)
                                ("Cerca sul Web…" . gdev-sidebar-web)
                                ("Aggiorna Esplora file" . gdev-sidebar-refresh)
                                ("Apri stato Git" . gdev-git-status)
                                ("Mostra legenda Git" . gdev-sidebar-git-legend))))
         (choice (completing-read "Esplora file: " choices nil t)))
    (call-interactively (cdr (assoc choice choices)))))

(defun gdev-sidebar--render (&optional reveal)
  "Ridisegna la barra, conservando la selezione o mostrando REVEAL."
  (let* ((window (get-buffer-window (current-buffer) 'visible))
         (width (if window (window-body-width window) gdev-sidebar-width))
         (frame (and window (window-frame window)))
         (graphical (display-graphic-p frame))
         (position (if window (window-point window) (point)))
         (selected (save-excursion (goto-char position) (gdev-sidebar--path-at-point)))
         (deferred (when (equal (or selected position) (cdr gdev-sidebar--deferred-reveal))
                     (car gdev-sidebar--deferred-reveal)))
         (reveal (or reveal deferred))
         (path (or reveal selected))
         (top (when window (save-excursion
                             (goto-char (window-start window))
                             (gdev-sidebar--path-at-point))))
         (line (line-number-at-pos position))
         (root (abbreviate-file-name gdev-sidebar--root))
         (basename (file-name-nondirectory (directory-file-name root)))
         (title (cond ((cdr gdev-sidebar--roots) "Cartelle dello spazio di lavoro")
                      ((string-empty-p basename) root)
                      (t basename)))
         (inhibit-read-only t)
         (gdev-sidebar--defer-directory-reads
          (and window (not noninteractive) (not gdev-sidebar--force-directory-reads)
               (not (file-remote-p gdev-sidebar--root))))
         (gdev-sidebar--cold-directories nil))
    (setq gdev-sidebar--render-width width
          header-line-format
          (list "  " (propertize (string-replace "%" "%%"
                                  (if graphical
                                      (gdev-sidebar--fit-label title 'gdev-sidebar-title
                                                               (* (max 1 (- width 4)) (frame-char-width frame)))
                                    title))
                                  'face (if graphical 'gdev-sidebar-title 'bold)
                                  'help-echo (if (cdr gdev-sidebar--roots) title root))))
    (setq gdev-sidebar--positions-tick nil)
    (if gdev-sidebar--positions
        (clrhash gdev-sidebar--positions)
      (setq gdev-sidebar--positions (make-hash-table :test #'equal)))
    (erase-buffer)
    (insert "  ")
    (insert-text-button "Azioni…" 'action (lambda (_) (gdev-sidebar-actions))
                        :type 'gdev-sidebar-entry
                        'face (if graphical 'gdev-sidebar-control 'link)
                        'help-echo "Azioni di Esplora file (a)")
    (when (and gdev-sidebar--repo (>= width 16))
      (insert "  ")
      (insert-text-button (if (>= width 18)
                              (concat (gdev-ui-icon "git" "⎇" frame 'gdev-sidebar-control) " Git")
                            "Git")
                          'action (lambda (_) (gdev-git-status))
                          :type 'gdev-sidebar-entry
                          'face (if graphical 'gdev-sidebar-control 'link)
                          'help-echo "Apri lo stato Git del progetto"))
    (insert (if graphical "\n" "\n\n"))
    (gdev-sidebar--insert-roots width graphical (and (>= width 16) (gdev-sidebar--icons frame)))
    (setq gdev-sidebar--positions-tick (buffer-modified-tick))
    (goto-char (point-min))
    (let ((target (gdev-sidebar--path-position path)))
      (if target (goto-char target) (forward-line (1- line)))
      (setq gdev-sidebar--deferred-reveal
            (when (and reveal (not target)
                       (seq-some (lambda (directory)
                                   (string-prefix-p (file-name-as-directory directory) reveal))
                                 (append gdev-sidebar--cold-directories
                                         gdev-sidebar--directory-paths)))
              (cons reveal (or (gdev-sidebar--path-at-point) (point)))))
      (when window
        (set-window-point window (point))
        (when-let* ((start (gdev-sidebar--path-position top)))
          (set-window-start window (save-excursion (goto-char start) (line-beginning-position))))
        (when (and deferred target (not (pos-visible-in-window-p target window)))
          (with-selected-window window (recenter)))))
    (gdev-sidebar--mark-current-file)
    (gdev-sidebar--refresh-selection)
    (setq gdev-sidebar--git-needs-render nil)
    (when gdev-sidebar--cold-directories
      (gdev-sidebar--refresh-directories gdev-sidebar--cold-directories))))

(defun gdev-sidebar--activate (button &optional preview)
  "Apre o espande BUTTON, usando PREVIEW per mostrare un'anteprima del file."
  (let ((path (button-get button 'gdev-sidebar-path)))
    (cond ((button-get button 'gdev-sidebar-folder)
           (if (gethash path gdev-sidebar--expanded)
               (remhash path gdev-sidebar--expanded)
             (puthash path t gdev-sidebar--expanded))
           (gdev-sidebar--render path))
          ((not (file-exists-p path))
           (user-error "Questo file è stato eliminato: %s" path))
          ((and preview gdev-layout-mode (fboundp 'gdev-editor-open-preview))
           (gdev-editor-open-preview path))
          (t (gdev-open-file path)))))

(defun gdev-sidebar-click (event)
  "Mostra il file indicato da EVENT, confermando l'apertura con due clic."
  (interactive "e")
  (let* ((position (event-end event))
         (window (posn-window position))
         (point (posn-point position))
         (modifiers (event-modifiers event))
         (double (memq 'double modifiers)))
    (when (and (window-live-p window) (integer-or-marker-p point))
      (select-window window)
      (let ((origin (gdev-sidebar--path-at-point)))
        (goto-char point)
        (when-let* ((button (or (button-at (point)) (gdev-sidebar--row))))
          (cond ((not (button-get button 'gdev-sidebar-path))
                 (unless (or double (memq 'shift modifiers) (memq 'super modifiers)
                             (memq 'meta modifiers) (memq 'control modifiers))
                   (button-activate button)))
                ((memq 'shift modifiers) (gdev-sidebar--select-range origin))
                ((or (memq 'super modifiers) (memq 'meta modifiers) (memq 'control modifiers))
                 (gdev-sidebar-toggle-selection origin))
                (t
                 (gdev-sidebar-clear-selection)
                 (setq gdev-sidebar--deferred-reveal nil)
                 (unless (and double (button-get button 'gdev-sidebar-folder))
                   (gdev-sidebar--activate button (not double))))))))))

(defun gdev-sidebar-open ()
  "Apri la cartella corrente o i file della selezione nell’editor."
  (interactive)
  (let ((paths (gdev-sidebar--selection-at-point)))
    (if (cdr paths)
        (let ((files (seq-remove #'gdev-sidebar--folder-p paths)))
          (unless files (user-error "Seleziona almeno un file da aprire"))
          (dolist (file files)
            (unless (and (file-regular-p file) (file-readable-p file))
              (user-error "Il percorso non è un file leggibile: %s" file)))
          (dolist (file files) (gdev-open-file file)))
      (when-let* ((button (or (button-at (point)) (gdev-sidebar--row))))
        (button-activate button)))))

(defun gdev-sidebar-preview ()
  "Mostra in anteprima il file sulla riga corrente o espandi la cartella."
  (interactive)
  (when-let* ((row (gdev-sidebar--row))
              ((button-get row 'gdev-sidebar-path)))
    (gdev-sidebar--activate row t)))

(defun gdev-sidebar-left ()
  "Chiudi la cartella sulla riga o torna a quella che la contiene."
  (interactive)
  (when-let* ((row (gdev-sidebar--row))
              (path (button-get row 'gdev-sidebar-path)))
    (if (gethash path gdev-sidebar--expanded)
        (gdev-sidebar--activate row)
      (when-let* ((parent (gdev-sidebar--path-position (directory-file-name (file-name-directory path)))))
        (goto-char parent)))))

(defun gdev-sidebar-right ()
  "Apri la cartella sulla riga o entra nella prima voce visibile."
  (interactive)
  (when-let* ((row (gdev-sidebar--row))
              ((button-get row 'gdev-sidebar-folder))
              (path (button-get row 'gdev-sidebar-path)))
    (if (not (gethash path gdev-sidebar--expanded))
        (gdev-sidebar--activate row)
      (when (and (member path gdev-sidebar--directory-paths)
                 (not (gethash path gdev-sidebar--directory-cache)))
        (let ((other-paths (remove path gdev-sidebar--directory-paths)))
          (gdev-sidebar--cancel-directory-scan)
          (gdev-sidebar--read-directory path)
          (gdev-sidebar--render path)
          (when other-paths (gdev-sidebar--refresh-directories other-paths))))
      (let ((child (save-excursion (forward-line 1) (gdev-sidebar--path-at-point))))
        (when (and child (equal (file-name-directory child) (file-name-as-directory path)))
          (forward-line 1))))))

(defun gdev-sidebar-terminal ()
  "Apre una nuova shell nella cartella selezionata."
  (interactive)
  (let* ((row (gdev-sidebar--row))
         (path (and row (button-get row 'gdev-sidebar-path)))
         (directory (cond ((not path) gdev-sidebar--root)
                          ((button-get row 'gdev-sidebar-folder) path)
                          (t (file-name-directory path))))
         (default-directory (if (file-directory-p directory)
                                (file-name-as-directory directory)
                              gdev-sidebar--root)))
    (if (fboundp 'gdev-term-here) (gdev-term-here) (shell))))

(defun gdev-sidebar--apply-git-status (text)
  "Aggiorna gli indicatori da TEXT e controlla i metadati dell'albero."
  (let (redraw)
    (unless (equal text gdev-sidebar--last-output)
      (setq redraw (or (not (string-empty-p text))
                       (and gdev-sidebar--last-output
                            (not (string-empty-p gdev-sidebar--last-output)))))
      (pcase-let ((`(,status . ,removed)
                   (gdev-sidebar--git-index text gdev-sidebar--repo gdev-sidebar--root)))
        (setq gdev-sidebar--last-output text
              gdev-sidebar--status status
              gdev-sidebar--removed removed)))
    (when (get-buffer-window (current-buffer) 'visible)
      (gdev-sidebar--refresh-git-tree redraw))))

(defun gdev-sidebar--read-git ()
  "Avvia un solo aggiornamento Git in background per questa barra."
  (when (and gdev-sidebar--repo (not (process-live-p gdev-sidebar--process)))
    (let ((sidebar (current-buffer))
          (output (generate-new-buffer " *gdev-sidebar-git*"))
          (default-directory gdev-sidebar--repo))
      (condition-case nil
          (setq gdev-sidebar--process
                (make-process
                 :name "gdev-sidebar-git" :buffer output :noquery t
                 :connection-type 'pipe :file-handler t
                 :coding (or file-name-coding-system default-file-name-coding-system 'utf-8-unix)
                 :command (list "git" "--no-optional-locks" "status" "--porcelain=v1" "-z"
                                "--untracked-files=all" "--ignored=matching"
                                "--" (concat ":(literal)" (file-relative-name gdev-sidebar--root
                                                                              gdev-sidebar--repo)))
                 :sentinel (lambda (process _event)
                             (when (memq (process-status process) '(exit signal))
                               (unwind-protect
                                   (when (and (buffer-live-p sidebar)
                                              (eq process (buffer-local-value 'gdev-sidebar--process sidebar))
                                              (zerop (process-exit-status process)))
                                     (let ((text (with-current-buffer output (buffer-string))))
                                       (with-current-buffer sidebar
                                         (gdev-sidebar--apply-git-status text))))
                                 (kill-buffer output))))))
        (error (kill-buffer output))))))

(defun gdev-sidebar--reset-git ()
  "Scarta la richiesta Git in corso e gli indicatori associati."
  (let ((process gdev-sidebar--process))
    (setq gdev-sidebar--process nil
          gdev-sidebar--status nil
          gdev-sidebar--removed nil
          gdev-sidebar--last-output nil
          gdev-sidebar--git-needs-render nil)
    (when (process-live-p process)
      (delete-process process))))

(defun gdev-sidebar-refresh ()
  "Aggiorna l'albero dei file e richiedi lo stato Git."
  (interactive)
  (dolist (directory (hash-table-keys gdev-sidebar--directory-cache))
    (when (file-remote-p directory)
      (remhash directory gdev-sidebar--directory-cache)))
  (let ((repo (locate-dominating-file gdev-sidebar--root ".git")))
    (unless (equal repo gdev-sidebar--repo)
      (gdev-sidebar--reset-git)
      (setq gdev-sidebar--repo repo)))
  (gdev-sidebar--refresh-directories)
  (gdev-sidebar--read-git))

(defun gdev-sidebar--refresh-visible (&optional path)
  "Aggiorna Git nelle barre attive che contengono PATH, se indicato."
  (let (sidebars visible)
    (walk-windows
     (lambda (window)
       (let ((frame (window-frame window))
             (buffer (window-buffer window)))
         (when (eq (frame-visible-p frame) t)
           (with-current-buffer buffer
             (when (and gdev-sidebar--root (not (memq buffer sidebars))
                        (not (file-remote-p gdev-sidebar--root)))
               (setq visible t)
               (when (and (or (not (display-graphic-p frame)) (eq (frame-focus-state frame) t))
                          (or (not path) (gdev-sidebar--root-for path)))
                 (push buffer sidebars)
                 (gdev-sidebar--read-git)
                 ;; Fuori da un repository nessun git status riporta le cartelle
                 ;; cambiate: senza questo l'albero non si aggiornerebbe mai.
                 (unless gdev-sidebar--repo
                   (gdev-sidebar--refresh-git-tree nil))))))))
     'no-minibuffer t)
    (unless (or visible path (not gdev-sidebar--timer))
      (cancel-timer gdev-sidebar--timer)
      (setq gdev-sidebar--timer nil))))

(defun gdev-sidebar--after-change ()
  "Aggiorna le barre aperte dopo un salvataggio o un'azione di Hit."
  (when gdev-sidebar--timer
    (gdev-sidebar--refresh-visible (or buffer-file-name default-directory))))

(add-hook 'after-save-hook #'gdev-sidebar--after-change)
(with-eval-after-load 'magit
  (add-hook 'magit-post-refresh-hook #'gdev-sidebar--after-change))

(defvar-keymap gdev-sidebar-mode-map
  "RET" #'gdev-sidebar-open
  "SPC" #'gdev-sidebar-preview
  "<mouse-1>" #'gdev-sidebar-click
  "<double-mouse-1>" #'gdev-sidebar-click
  "<triple-mouse-1>" #'ignore
  "S-<mouse-1>" #'gdev-sidebar-click
  "s-<mouse-1>" #'gdev-sidebar-click
  "M-<mouse-1>" '(menu-item "" gdev-sidebar-click :filter gdev-sidebar--command-as-meta)
  "M-<down-mouse-1>" '(menu-item "" ignore :filter gdev-sidebar--command-as-meta)
  "S-<up>" #'gdev-sidebar-select-previous
  "S-<down>" #'gdev-sidebar-select-next
  "m" #'gdev-sidebar-toggle-selection
  "s-a" #'gdev-sidebar-select-all
  "<remap> <mark-whole-buffer>" #'gdev-sidebar-select-all
  "<escape>" #'gdev-sidebar-clear-selection
  "c" #'gdev-sidebar-copy-paths
  "s-c" #'gdev-sidebar-copy-paths
  "<remap> <gdev-copy-dwim>" #'gdev-sidebar-copy-paths
  "<left>" #'gdev-sidebar-left
  "<right>" #'gdev-sidebar-right
  "/" #'gdev-sidebar-find-entry
  "M-s-f" #'gdev-sidebar-find-entry
  "a" #'gdev-sidebar-actions
  "r" #'gdev-sidebar-reveal-current-file
  "g" #'gdev-sidebar-refresh
  "?" #'gdev-sidebar-git-legend
  "t" #'gdev-sidebar-terminal
  "w" #'gdev-sidebar-web
  "q" #'gdev-focus-editor)

(unless (eq system-type 'darwin)
  (keymap-set gdev-sidebar-entry-map "C-<mouse-1>" #'gdev-sidebar-click)
  (keymap-set gdev-sidebar-mode-map "C-<mouse-1>" #'gdev-sidebar-click))

(define-derived-mode gdev-sidebar-mode special-mode "Esplora file"
  "Albero dei file del progetto con indicatori Git."
  (gdev-ui-view-setup 'sidebar)
  (setq-local gdev-command-file-function #'gdev-sidebar--path-at-point
              hl-line-face 'gdev-sidebar-selection
              gdev-sidebar--selection (make-hash-table :test #'equal)
              gdev-sidebar--expanded (make-hash-table :test #'equal)
              gdev-sidebar--directory-times (make-hash-table :test #'equal)
              gdev-sidebar--directory-cache (make-hash-table :test #'equal))
  (when (display-graphic-p)
    (setq-local cursor-type nil))
  (add-hook 'window-size-change-functions #'gdev-sidebar--resize nil t)
  (add-hook 'kill-buffer-hook #'gdev-sidebar--cancel-directory-scan nil t)
  (add-hook 'kill-buffer-hook #'gdev-sidebar--reset-git nil t)
  (hl-line-mode 1))

(defun gdev-sidebar--resize (window)
  "Riadatta nomi e simboli alla larghezza di WINDOW."
  (when (and gdev-sidebar--root (not (equal gdev-sidebar--render-width (window-body-width window))))
    (gdev-sidebar--render)))

(defun gdev-sidebar--refresh-appearance ()
  "Aggiorna le icone delle barre visibili dopo un cambio di tema."
  (walk-windows (lambda (window)
                  (when (window-parameter window 'gdev-sidebar)
                    (with-selected-window window
                      (when gdev-sidebar--root (gdev-sidebar--render)))))
                'no-minibuffer 'visible))

(add-hook 'gdev-ui-after-theme-hook #'gdev-sidebar--refresh-appearance)

(defun gdev-sidebar--display (buffer)
  "Mostra BUFFER nel riquadro a sinistra."
  (if gdev-layout-mode
      (gdev-layout-show-explorer buffer)
    (display-buffer-in-side-window
     buffer `((side . left) (slot . 0) (window-width . ,gdev-sidebar-width)
              (window-parameters . ((gdev-sidebar . t)
                                    (no-other-window . t)
                                    (no-delete-other-windows . t)))))))

(defun gdev-sidebar--window-state-shows-p (state buffer)
  "Indica se lo stato delle finestre STATE contiene BUFFER.
Tab Bar conserva le finestre degli spazi non selezionati con il nome del buffer."
  (let ((name (buffer-name buffer)))
    (named-let search ((node state))
      (and (consp node)
           (or (and (eq (car node) 'buffer) (consp (cdr node))
                    (or (eq (cadr node) buffer) (equal (cadr node) name)))
               (search (car node))
               (search (cdr node)))))))

(defun gdev-sidebar--tab-uses-p (tab frame buffer)
  "Indica se TAB di FRAME usa BUFFER come Esplora file.
Uno spazio duplicato mostra lo stesso buffer prima di registrarlo."
  (or (eq (gdev-workspace-state-read 'gdev-layout-explorer-buffer tab) buffer)
      (if (eq (car tab) 'current-tab)
          (get-buffer-window buffer frame)
        (gdev-sidebar--window-state-shows-p (alist-get 'ws (cdr tab)) buffer))))

(defun gdev-sidebar--release (frame tabs)
  "Chiudi gli Esplora file usati da TABS di FRAME e da nessun altro spazio."
  (let ((hidden (mapcar (lambda (tab)
                          (cons tab (gdev-workspace-state-read 'gdev-layout-explorer-hidden tab)))
                        tabs)))
    (dolist (buffer (buffer-list))
      (when (and (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                          'gdev-sidebar-mode)
                 (seq-some (lambda (tab) (gdev-sidebar--tab-uses-p tab frame buffer)) tabs)
                 (not (seq-some
                       (lambda (other)
                         (seq-some (lambda (tab)
                                     (and (not (memq tab tabs))
                                          (gdev-sidebar--tab-uses-p tab other buffer)))
                                   (gdev-workspace-state-tabs other)))
                       (frame-list))))
        (kill-buffer buffer)))
    ;; Il riquadro chiuso con il buffer non nasconde Esplora file nello spazio.
    (pcase-dolist (`(,tab . ,value) hidden)
      (gdev-workspace-state-set 'gdev-layout-explorer-hidden value tab))))

(defun gdev-sidebar--close-tab (tab last-tab)
  "Rilascia Esplora file di TAB quando lo spazio si chiude e non è LAST-TAB."
  (unless (or last-tab gdev-workspace-state--moving-tab)
    (gdev-sidebar--release (selected-frame) (list tab))))

(defun gdev-sidebar--close-frame (frame)
  "Rilascia gli Esplora file degli spazi di FRAME.
Le finestre figlie, come i riquadri a comparsa, non hanno spazi propri."
  (unless (frame-parent frame)
    (gdev-sidebar--release frame (gdev-workspace-state-tabs frame))))

(defun gdev-sidebar--reopen-tab (_tab)
  "Ricostruisci Esplora file nello spazio riaperto con Tab Bar.
Alla chiusura lo spazio ha rilasciato il buffer.  Al suo posto Tab Bar mostra
un segnaposto, che viene chiuso, oppure nessun riquadro."
  (let ((released (gdev-workspace-state-get 'gdev-layout-explorer-buffer))
        (window (window-with-parameter 'gdev-sidebar t)))
    (when-let* ((gdev-layout-mode)
                ((bufferp released))
                ((not (buffer-live-p released)))
                ((not (gdev-workspace-state-get 'gdev-layout-explorer-hidden)))
                ((not (gdev-workspace-state-get 'gdev-activity-view)))
                (root (gdev-workspace-state-get 'gdev-layout-explorer-root)))
      (let ((placeholder (and window (window-buffer window))))
        (gdev-sidebar-show root t)
        (when (and (buffer-live-p placeholder)
                   (string-prefix-p " *Old buffer " (buffer-name placeholder))
                   (not (get-buffer-window placeholder t)))
          (kill-buffer placeholder))))))

(add-hook 'tab-bar-tab-pre-close-functions #'gdev-sidebar--close-tab)
(defun gdev-sidebar--after-undo-close-tab (&rest _)
  "Ricostruisci Esplora file dopo `tab-bar-undo-close-tab' in Emacs 30."
  (gdev-sidebar--reopen-tab nil))

;; `tab-bar-post-undo-close-tab-functions' esiste solo da Emacs 31, e la versione
;; minima è la 30.1: prima si consiglia il comando che riapre lo spazio.
(if (< emacs-major-version 31)
    (advice-add 'tab-bar-undo-close-tab :after #'gdev-sidebar--after-undo-close-tab)
  (add-hook 'tab-bar-post-undo-close-tab-functions #'gdev-sidebar--reopen-tab))
(add-hook 'delete-frame-functions #'gdev-sidebar--close-frame)

(defun gdev-sidebar-show (directory &optional keep-focus)
  "Mostra DIRECTORY a sinistra e rivela il file corrente, se presente.
Se lo spazio di lavoro contiene cartelle esplicite, mostra ciascuna di esse.
Con KEEP-FOCUS lascia il fuoco nella finestra chiamante."
  (let* ((roots (or (and gdev-layout-mode (gdev-workspace-state-get 'gdev-workspace-roots))
                    (list (file-name-as-directory (if (file-remote-p directory)
                                                      (expand-file-name directory)
                                                    (file-truename directory))))))
         (root (car roots))
         (reveal (gdev-sidebar--editor-file))
         (sidebar (window-with-parameter 'gdev-sidebar t))
         ;; Dopo la riapertura di uno spazio Tab Bar può mostrare qui un segnaposto.
         (shown (and sidebar
                     (with-current-buffer (window-buffer sidebar)
                       (derived-mode-p 'gdev-sidebar-mode))
                     (window-buffer sidebar)))
         (cached (if gdev-layout-mode
                     (gdev-workspace-state-get 'gdev-layout-explorer-buffer)
                   (frame-parameter nil 'gdev-sidebar-buffer)))
         (buffer (cond (shown)
                       ((buffer-live-p cached) cached)
                       (t (generate-new-buffer "*Esplora file*"))))
         reuse-directory-cache)
    (if gdev-layout-mode
        (gdev-workspace-state-update
         `((gdev-layout-explorer-root . ,root)
           (gdev-layout-explorer-buffer . ,buffer)))
      (set-frame-parameter nil 'gdev-sidebar-buffer buffer))
    (with-current-buffer buffer
      (unless (derived-mode-p 'gdev-sidebar-mode)
        (gdev-sidebar-mode))
      (setq reuse-directory-cache
            (and (equal roots gdev-sidebar--roots)
                 (not (file-remote-p root))
                 (gethash root gdev-sidebar--directory-cache)
                 (or (not reveal) (not (gdev-sidebar--root-for reveal))
                     (gdev-sidebar--path-position reveal))
                 (gdev-find-executable "perl")))
      (unless (equal gdev-sidebar--root root)
        (gdev-sidebar--reset-git)
        (setq default-directory root
              gdev-sidebar--root root
              gdev-sidebar--repo (locate-dominating-file root ".git")))
      (unless (equal roots gdev-sidebar--roots)
        (setq gdev-sidebar--deferred-reveal nil)
        (unless (seq-intersection roots gdev-sidebar--roots #'equal)
          (gdev-sidebar-clear-selection)
          (clrhash gdev-sidebar--expanded)
          (goto-char (point-min)))
        (when (cdr roots)
          (dolist (directory roots)
            (unless (and (cdr gdev-sidebar--roots) (member directory gdev-sidebar--roots))
              (puthash (directory-file-name directory) t gdev-sidebar--expanded))))
        (setq gdev-sidebar--roots roots))
      (setq gdev-sidebar--current-file reveal)
      (when reveal
        (dolist (parent (gdev-sidebar--ancestors reveal))
          (puthash parent t gdev-sidebar--expanded)))
      (unless reuse-directory-cache
        (gdev-sidebar--cancel-directory-scan)
        (clrhash gdev-sidebar--directory-cache)
        (clrhash gdev-sidebar--directory-times)))
    (when-let* ((window (if shown sidebar (gdev-sidebar--display buffer))))
      (unless keep-focus (select-window window))
      (with-current-buffer buffer
        (gdev-sidebar--render reveal)
        (when reuse-directory-cache (gdev-sidebar--refresh-directories))
        (gdev-sidebar--read-git))
      (unless (or gdev-sidebar--timer (file-remote-p root))
        (let ((interval (max 2 gdev-sidebar-refresh-interval)))
          (setq gdev-sidebar--timer
                (run-with-timer interval interval #'gdev-sidebar--refresh-visible))))
      window)))

(defun gdev-sidebar-reveal-current-file ()
  "Espandi il ramo del file aperto e porta il fuoco sulla sua riga."
  (interactive)
  (let ((file (or (gdev-sidebar--editor-file) (user-error "Nessun file aperto nell’editor"))))
    (when-let* ((window (or (window-with-parameter 'gdev-sidebar t)
                            (gdev-sidebar-show (gdev-sidebar--workspace-root)))))
      (with-selected-window window
        (unless (gdev-sidebar--root-for file)
          (user-error "Il file aperto è fuori da questa cartella"))
        (setq gdev-sidebar--current-file file)
        (dolist (parent (gdev-sidebar--ancestors file))
          (puthash parent t gdev-sidebar--expanded))
        (gdev-sidebar--render file)
        (unless (pos-visible-in-window-p (point) window) (recenter)))
      (select-window window))))

(defun gdev-sidebar-select ()
  "Mostra Esplora file e porta il fuoco nell'albero dello spazio."
  (interactive)
  (if-let* ((window (window-with-parameter 'gdev-sidebar t)))
      (select-window window)
    (gdev-sidebar-show (gdev-sidebar--workspace-root))))

(defun gdev-sidebar-focus ()
  "Sposta il fuoco fra l'esplora file persistente e l'editor."
  (interactive)
  (if (window-parameter (selected-window) 'gdev-sidebar)
      (gdev-focus-editor)
    (gdev-sidebar-select)))

(defun gdev-sidebar--workspace-root ()
  "Restituisce la cartella dell'albero o del documento attivo."
  (or (and gdev-layout-mode
           (car (gdev-workspace-roots)))
      (with-current-buffer (window-buffer (gdev-layout-editor))
        (if (file-remote-p default-directory)
            default-directory
          (gdev-project-root)))))

(defun gdev-sidebar-toggle ()
  "Nasconde o ripristina l'albero dello spazio di lavoro."
  (interactive)
  (if-let* ((window (window-with-parameter 'gdev-sidebar t)))
      (delete-window window)
    (gdev-sidebar-show (gdev-sidebar--workspace-root) t)))

(defun gdev-sidebar--unaccompanied-editor (frame)
  "Restituisce la finestra con il file attivo se FRAME non ha un albero."
  (let ((editor (gdev-layout-editor frame)))
    (when (and editor
               (not (frame-parameter frame 'gdev-layout-focus))
               (buffer-local-value 'buffer-file-name (window-buffer editor))
               (not (window-with-parameter 'gdev-sidebar t frame)))
      editor)))

(defun gdev-sidebar--sync-frame (frame)
  "Allinea l'esplora file al file aperto nella finestra di sistema FRAME."
  (when (frame-live-p frame)
    (set-frame-parameter frame 'gdev-sidebar-update nil)
    (if-let* ((sidebar (window-with-parameter 'gdev-sidebar t frame)))
        (let ((file (gdev-sidebar--editor-file frame)))
          (with-current-buffer (window-buffer sidebar)
            (when (and gdev-sidebar--root (not (equal file gdev-sidebar--current-file)))
              (setq gdev-sidebar--current-file file)
              (gdev-sidebar--mark-current-file))))
      (when-let* ((editor (gdev-sidebar--unaccompanied-editor frame))
                  ((not (window-with-parameter 'gdev-activity t frame)))
                  ((not (and gdev-layout-mode
                             (gdev-workspace-state-get 'gdev-layout-explorer-hidden frame)))))
        (with-selected-window editor
          (gdev-sidebar-show (gdev-sidebar--workspace-root) t))))))

(defun gdev-sidebar--schedule-sync (frame)
  "Richiedi un aggiornamento dell'albero dopo il ridisegno di FRAME."
  (when (and (not noninteractive)
             (not gdev-layout-mode)
             (not (frame-parameter frame 'gdev-sidebar-update))
             (or (window-with-parameter 'gdev-sidebar t frame)
                 (gdev-sidebar--unaccompanied-editor frame)))
    (set-frame-parameter frame 'gdev-sidebar-update
                         (run-at-time 0 nil #'gdev-sidebar--sync-frame frame))))

(add-hook 'window-state-change-functions #'gdev-sidebar--schedule-sync)

;;; config.el ends here
