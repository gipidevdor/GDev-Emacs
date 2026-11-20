;;; gdev-commands.el --- Comandi per file, buffer, finestre e sessioni -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Piccoli comandi usati dai tasti guida (leader), indipendenti da qualsiasi
;; pacchetto: copiare la posizione di un file, eliminare un file o riaprirlo
;; come root, aree di testo temporanee (scratch buffer), ingrandire una
;; finestra, salvare la sessione e riavviare ritrovandola.

;;; Code:

(require 'gdev-lib)
(require 'gdev-modules)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-layout)
(require 'gdev-native-state)
(require 'gdev-workspace-state)
(require 'gdev-workspace-roots)
(require 'gdev-command-context)
(require 'isearch)
(require 'project)

(defvar gdev-user-directory)            ; early-init.el
(defvar imenu-auto-rescan)
(defvar imenu-flatten)
(declare-function imenu--make-index-alist "imenu")
(declare-function imenu--flatten-index-alist "imenu")
(declare-function gdev-editor-pin-preview "gdev-editor-tabs" (&optional buffer))
(declare-function winner-undo "winner")
(declare-function eglot-server-capable "eglot")
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-setup-windows-plain "ediff-wind")
(declare-function tab-line-mode "tab-line")
(defvar ediff-this-buffer-ediff-sessions)
(defvar ediff-window-A)
(defvar ediff-window-B)
(defvar ediff-window-C)
(defvar ediff-window-Ancestor)
(defvar ediff-window-setup-function)
(defvar ediff-mode-map)
(defvar tab-line-tabs-function)
(defvar tab-line-tab-name-function)
(defvar tab-line-close-tab-function)
(declare-function consult--read "consult")
(declare-function consult--temporary-files "consult")
(declare-function gdev-menu-command-items "gdev-menu")
(declare-function gdev-ui-fit-text "gdev-ui" (text width measure))
(declare-function gdev-ui-fit-file-name "gdev-ui" (name width measure))
(declare-function gdev-ui-string-pixel-width "gdev-ui" (text))
(declare-function face-remap-add-relative "face-remap" (face &rest specs))
(declare-function face-remap-remove-relative "face-remap" (cookie))
(defvar consult--completion-candidate-hook)
(defvar consult--completion-refresh-hook)
(defvar vertico-mouse-mode)

(defvar gdev-quick-open--refresh-interval 2
  "Intervallo in secondi fra scansioni durante l'apertura rapida.")

(defvar gdev-quick-open--recent-project-files nil
  "Istantanee dei file confermate di recente, ordinate per utilizzo.")

(defconst gdev-quick-open--cache-budget (* 6 1024 1024)
  "Budget stimato in byte per gli indici conservati fra le aperture.")

(cl-defstruct gdev-quick-open--index fingerprint files cost)

(defun gdev-quick-open--remember-files (scope fingerprint names)
  "Conserva NAMES e FINGERPRINT per SCOPE entro il budget della cache."
  (let* ((remaining gdev-quick-open--cache-budget)
         (cached (cdr (assoc scope gdev-quick-open--recent-project-files)))
         (index (if (and cached (equal fingerprint (gdev-quick-open--index-fingerprint cached)))
                    cached
                  (make-gdev-quick-open--index
                   :fingerprint fingerprint :files names
                   ;; Intestazioni di stringa e cella, allineamento e percorso.
                   :cost (cl-loop for name in names sum (+ 64 (string-bytes name)) into size
                                  finally return (+ 256 size))))))
    (setq gdev-quick-open--recent-project-files
          (cl-loop for entry in (cons (cons scope index)
                                      (assoc-delete-all scope gdev-quick-open--recent-project-files))
                   for cost = (gdev-quick-open--index-cost (cdr entry))
                   when (<= cost remaining)
                   collect entry and do (cl-decf remaining cost)))))

(defconst gdev-quick-open--project-file-list
  '(lambda (project directory)
     (let* ((root (project-root project))
            ;; Emacs 30 perde le esclusioni Git ancorate se si passa una sottocartella.
            (dirs (unless (or (equal directory root)
                              (and (< emacs-major-version 31) (eq (car-safe project) 'vc)))
                    (list directory)))
            (default-directory (if dirs directory root))
            (project-files-relative-names t)
            (local (not (file-remote-p default-directory)))
            (prefix (unless (equal default-directory directory)
                      (file-relative-name directory default-directory))))
       (cl-loop for file in (project-files project dirs)
                for relative = (if (file-name-absolute-p file)
                                   (file-relative-name file default-directory)
                                 file)
                when (and (or (not prefix) (string-prefix-p prefix relative))
                          ;; Git può elencare file rimossi ancora presenti nell'indice.
                          (or (not local) (file-exists-p file)))
                collect (if prefix (substring relative (length prefix)) relative))))
  "Funzione di elenco condivisa con il processo Emacs dedicato alla scansione.")

(defun gdev-quick-open--scan-response (output snapshot)
  "Leggi la risposta in OUTPUT, riusando SNAPSHOT se l'impronta coincide."
  (with-current-buffer output
    (goto-char (point-min))
    (condition-case nil
        (if snapshot
            (let ((fingerprint (read (current-buffer))))
              (when (stringp fingerprint)
                (list (if (equal fingerprint (car snapshot))
                          (cdr snapshot)
                        (read (current-buffer)))
                      t fingerprint)))
          (list (read (current-buffer)) t))
      (error nil))))

(defun gdev-quick-open--scan (project notify &optional directory snapshot)
  "Elenca i file di PROJECT in un Emacs separato.
NOTIFY riceve l'elenco e un indicatore di successo.
Se DIRECTORY è presente, limita l'elenco a quella cartella del progetto.
SNAPSHOT è una coppia con l'ultima impronta e l'elenco corrispondente.
Con SNAPSHOT, NOTIFY riceve anche l'impronta della risposta."
  (let* ((root (or directory (project-root project)))
         (default-directory (if (file-remote-p root) temporary-file-directory root))
         (settings
          (cl-loop for variable in '(find-program vc-git-program vc-directory-exclusion-list
                                     grep-find-ignored-files grep-find-ignored-directories
                                     project-vc-ignores project-vc-include-untracked
                                     project-vc-merge-submodules enable-dir-local-variables
                                     file-name-coding-system)
                   when (boundp variable)
                   collect (list variable (list 'quote (default-value variable)))))
         (expression
          `(progn
             (require 'project)
             (require 'find-dired)
             (require 'grep)
             (require 'vc-git)
             (let ((default-directory ,root)
                   (print-length nil)
                   (print-level nil)
                   (enable-local-eval nil)
                   (exec-path ',exec-path)
                   ,@settings)
               (let ((files (,gdev-quick-open--project-file-list ',project ,root)))
                 (if ,(and snapshot t)
                     (with-temp-buffer
                       (prin1 files (current-buffer))
                       (let ((fingerprint (secure-hash 'sha256 (current-buffer))))
                         (prin1 fingerprint)
                         (terpri)
                         (unless (equal fingerprint ,(car snapshot))
                           (princ (buffer-string)))))
                   (prin1 files))))))
         (output (generate-new-buffer " *gdev-project-files*"))
         (errors (generate-new-buffer " *gdev-project-files-errors*"))
         process)
    (unwind-protect
        (setq process
              (make-process
               :name "gdev-project-files" :buffer output :stderr errors
               :command (list (expand-file-name invocation-name invocation-directory)
                              "--batch" "-Q" "--eval" (prin1-to-string expression))
               :connection-type 'pipe :coding 'utf-8-unix :noquery t
               :sentinel
               (lambda (child _event)
                 (when (memq (process-status child) '(exit signal failed))
                   (unwind-protect
                       (apply notify
                              (or (when (and (buffer-live-p output) (eq (process-status child) 'exit)
                                             (zerop (process-exit-status child)))
                                    (gdev-quick-open--scan-response output snapshot))
                                  (if snapshot '(nil nil nil) '(nil nil))))
                     (dolist (buffer (list output errors))
                       (when (buffer-live-p buffer) (kill-buffer buffer))))))))
      (unless process
        (kill-buffer output)
        (kill-buffer errors)))))

;;;; File

(defun gdev-editor-document ()
  "Restituisce il documento visibile nel riquadro editor attivo."
  (when-let* ((editor (gdev-layout-editor))
              (buffer (window-buffer editor))
              ((gdev-layout-document-tab-p buffer)))
    buffer))

(defun gdev-save-document (&optional arg)
  "Salva il documento dell'editor attivo.  Passa ARG a `save-buffer'."
  (interactive "p")
  (with-current-buffer (or (gdev-editor-document) (user-error "Apri un documento da salvare"))
    (save-buffer arg)))

(defun gdev-save-document-as ()
  "Salva il documento dell'editor attivo con un altro nome."
  (interactive)
  (with-current-buffer (or (gdev-editor-document) (user-error "Apri un documento da salvare"))
    (call-interactively #'write-file)))

(defun gdev-save-all-documents ()
  "Salva tutti i documenti associati a un file."
  (interactive)
  (save-some-buffers t (lambda ()
                         (and buffer-file-name (gdev-layout-document-tab-p (current-buffer))))))

(defun gdev-reload-document ()
  "Rileggi dal disco il documento dell'editor attivo."
  (interactive)
  (if-let* ((document (gdev-editor-document))
            ((buffer-file-name document)))
      (with-current-buffer document (call-interactively #'revert-buffer-quick))
    (user-error "Apri un file da ricaricare")))

(autoload 'gdev-print-macos "gdev-print")

(defun gdev-print-document ()
  "Stampa tutto il documento visibile, comprese le modifiche in memoria.
Su macOS la stampa conserva i colori e gli stili dell'editor, adattati
alla carta: vedi `gdev-print-macos'."
  (interactive)
  (let ((buffer (or (gdev-editor-document)
                    (user-error "Apri un documento da stampare"))))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (if (eq system-type 'darwin)
              (gdev-print-macos)
            (print-buffer)))))))

(defun gdev-comparison--split-window ()
  "Disponi i documenti affiancati quando le colonne sono sufficienti."
  (let ((split-width-threshold 72))
    (if (and (>= (window-total-width (frame-root-window)) 92)
             (window-splittable-p (selected-window) t))
        (split-window-horizontally)
      (split-window-vertically))))

(defun gdev-comparison--tab ()
  "Restituisci l'unica scheda del pannello di confronto."
  (list (current-buffer)))

(defun gdev-comparison--tab-name (_buffer _tabs)
  "Mostra il nome della vista di confronto sulla sua scheda."
  "  Confronto  ")

(defun gdev-comparison-control-at-window (&optional window)
  "Restituisci il controllo Ediff di WINDOW, o della finestra selezionata."
  (let ((window (or window (selected-window))))
    (with-current-buffer (window-buffer window)
      (if (derived-mode-p 'ediff-mode)
          (current-buffer)
        (seq-find (lambda (control)
                    (and (buffer-live-p control)
                         (with-current-buffer control
                           (memq window (list ediff-window-A ediff-window-B
                                              ediff-window-C ediff-window-Ancestor)))))
                  (bound-and-true-p ediff-this-buffer-ediff-sessions))))))

(defun gdev-comparison-close (&optional control)
  "Termina il confronto della vista corrente o della scheda CONTROL."
  (interactive)
  (let* ((origin (selected-window))
         (buffer (window-buffer origin))
         (control (or control (gdev-comparison-control-at-window))))
    (unless (buffer-live-p control)
      (user-error "Seleziona una vista del confronto"))
    (unwind-protect
        (progn
          (when-let* ((window (get-buffer-window control t)))
            (select-window window))
          (set-buffer control)
          (call-interactively #'ediff-quit))
      (when (and (buffer-live-p control) (window-live-p origin)
                 (eq (window-buffer origin) buffer))
        (select-window origin)))))

(defun gdev-comparison--controls ()
  "Presenta i controlli di Ediff come vista di GDev."
  (when (eq ediff-window-setup-function 'ediff-setup-windows-default)
    (setq-local ediff-window-setup-function #'ediff-setup-windows-plain))
  (setq-local tab-line-tabs-function #'gdev-comparison--tab
              tab-line-tab-name-function #'gdev-comparison--tab-name
              tab-line-close-tab-function #'gdev-comparison-close)
  (tab-line-mode 1))

(defun gdev-comparison--keys ()
  "Aggiungi i tasti di chiusura di GDev al pannello Ediff.
Chiudere il buffer dei controlli con `C-x k' termina il confronto come `q'
e ripristina le finestre."
  (dolist (key '("q" "x" "X" "<remap> <kill-current-buffer>" "<remap> <kill-buffer>"))
    (keymap-set ediff-mode-map key #'gdev-comparison-close)))

(with-eval-after-load 'ediff
  (add-hook 'ediff-mode-hook #'gdev-comparison--controls)
  (add-hook 'ediff-keymap-setup-hook #'gdev-comparison--keys))

(defun gdev-comparison--start (function)
  "Avvia FUNCTION nell'editor e ripristina la disposizione all'uscita."
  (require 'ediff)
  (let* ((layout (current-window-configuration))
         (frame (selected-frame))
         (previous (gdev-workspace-state-get 'gdev-comparison-control))
         (setup (lambda ()
                  (let ((control (current-buffer)))
                    (gdev-workspace-state-set 'gdev-comparison-control control)
                    (add-hook 'ediff-quit-hook
                              (lambda ()
                                (when (and (frame-live-p frame)
                                           (eq control (gdev-workspace-state-get
                                                        'gdev-comparison-control frame)))
                                  (with-selected-frame frame
                                    (gdev-workspace-state-set 'gdev-comparison-control
                                                               (and (buffer-live-p previous) previous))
                                    (gdev-layout-restore-configuration layout))))
                              'append t))))
         control)
    (unwind-protect
        (progn
          (setq control (gdev-call-with-editor (lambda () (funcall function setup))))
          (when-let* ((window (get-buffer-window control t)))
            (select-window window))
          control)
      (unless control
        (set-window-configuration layout)))))

(defun gdev-compare-files (&optional first second)
  "Confronta FIRST e SECOND nella finestra di GDev.
Chiedi i percorsi omessi."
  (interactive)
  (gdev-comparison--start
   (lambda (setup)
     (let* ((file-a (or first (read-file-name "Primo file da confrontare: " nil buffer-file-name t)))
            (file-b (or second (read-file-name "Secondo file da confrontare: "
                                             (file-name-directory file-a) nil t))))
       (dolist (file (list file-a file-b))
         (unless (and (file-regular-p file) (file-readable-p file))
           (user-error "Il percorso non è un file leggibile: %s" file)))
       (when (file-equal-p file-a file-b)
         (user-error "Scegli due file diversi"))
       (ediff-buffers (or (find-buffer-visiting file-a) (find-file-noselect file-a))
                      (or (find-buffer-visiting file-b) (find-file-noselect file-b))
                      (list setup))))))

(defun gdev-compare-with-saved ()
  "Confronta il documento dell'editor con il file salvato su disco."
  (interactive)
  (let* ((document (or (gdev-editor-document) (user-error "Apri un documento da confrontare")))
         (file (buffer-file-name document)))
    (unless (and file (file-regular-p file) (file-readable-p file))
      (user-error "Non c'è una copia leggibile su disco"))
    (unless (or (buffer-modified-p document) (not (verify-visited-file-modtime document)))
      (user-error "Il documento coincide con l'ultima versione salvata"))
    (gdev-compare-buffer-with-file document file)))

(defun gdev-compare-buffer-with-file (document file &optional label whole)
  "Confronta DOCUMENT con una copia in sola lettura di FILE.
LABEL identifica la copia. Con WHOLE accedi a tutto DOCUMENT fino all'uscita."
  (let ((snapshot (generate-new-buffer
                   (format "*%s · %s*" (or label "Su disco") (file-name-nondirectory file))))
        (bounds (when whole
                  (with-current-buffer document
                    (when (buffer-narrowed-p)
                      (cons (copy-marker (point-min)) (copy-marker (point-max) t))))))
        control)
    (cl-labels ((release ()
                  (when (and bounds (buffer-live-p document))
                    (with-current-buffer document
                      (narrow-to-region (car bounds) (cdr bounds))))
                  (when (and (buffer-live-p snapshot) (not (buffer-modified-p snapshot)))
                    (kill-buffer snapshot))))
      (unwind-protect
          (progn
            (when bounds (with-current-buffer document (widen)))
            (setq control
                  (gdev-comparison--start
                   (lambda (setup)
                     (with-current-buffer snapshot
                       (insert-file-contents file)
                       (delay-mode-hooks
                         (funcall (buffer-local-value 'major-mode document)))
                       (set-buffer-modified-p nil)
                       (setq buffer-read-only t))
                     (ediff-buffers snapshot document
                                    (list setup
                                          (lambda ()
                                            (add-hook 'ediff-quit-hook #'release 'append t))))))))
        (unless control (release))))))

(defun gdev-open-file (file &optional wildcards)
  "Apri FILE nel riquadro editor attivo, anche partendo da un pannello.
Con WILDCARDS espandi i caratteri jolly nel percorso."
  (interactive
   (let* ((editor (gdev-layout-editor))
          (default-directory (or (gdev-workspace-directory)
                                 (and editor (buffer-local-value 'default-directory (window-buffer editor)))
                                 default-directory)))
     (find-file-read-args "Apri file: " (confirm-nonexistent-file-or-buffer))))
  (gdev-focus-editor)
  (find-file file wildcards))

(defun gdev-quick-open--symbols (buffer)
  "Raccogli in BUFFER i simboli navigabili con Imenu."
  (require 'imenu)
  (with-current-buffer buffer
    (let* ((imenu-auto-rescan t)
           (imenu-flatten 'annotation)
           (index (condition-case nil (imenu--make-index-alist t)
                    (imenu-unavailable nil)))
           (symbols (make-hash-table :test #'equal)))
      (dolist (entry (imenu--flatten-index-alist (delq nil (copy-sequence index)) t))
        (let* ((name (car entry))
               (base (concat (substring-no-properties name)
                             (get-text-property 0 'imenu-section name)))
               (label base)
               (number 1))
          (while (gethash label symbols)
            (setq label (format "%s [%d]" base (cl-incf number))))
          (puthash label (get-text-property 0 'imenu-choice name) symbols)))
      symbols)))

(defun gdev-quick-open--file-and-line (input)
  "Dividi INPUT in un percorso e un eventuale numero di riga."
  (let ((file (expand-file-name input))
        line)
    (when (and (string-match "\\`\\(.+\\):\\([0-9]+\\)\\'" input)
               (save-match-data
                 (not (or (get-file-buffer file) (file-exists-p file)))))
      (setq file (expand-file-name (match-string 1 input))
            line (string-to-number (match-string 2 input))))
    (cons file line)))

(defun gdev-quick-open--suffix (input)
  "Leggi il suffisso @SIMBOLO o #TESTO di INPUT, se presente.
Un percorso esistente o già aperto ha la precedenza su un suffisso."
  (when-let* (;; Un percorso TRAMP contiene «@»: controllarlo aprirebbe una connessione a ogni tasto.
              ((not (file-remote-p input)))
              (separator (string-match "[@#]" input))
              ((not (or (file-exists-p input) (get-file-buffer input)))))
    (if (zerop separator)
        (list (substring input 0 1) nil (aref input 0) (substring input 1))
      (save-match-data
        (let (suffix)
          (while separator
            (let ((file (substring input 0 separator))
                  (next (1+ separator)))
              (when (or (file-regular-p file) (get-file-buffer file))
                (setq suffix (list (substring input 0 next) (expand-file-name file)
                                   (aref input separator) (substring input next))))
              (setq separator (string-match "[@#]" input next))))
          suffix)))))

(defun gdev-quick-open--text-position (buffer query)
  "Trova la prima occorrenza di QUERY in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward query nil t)
        (match-beginning 0)))))

(defun gdev-quick-open--line-position (buffer line)
  "Trova l'inizio della riga LINE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (point)))))

(defun gdev-quick-open--preview (editor open symbols)
  "Crea l'anteprima reversibile in EDITOR con OPEN e SYMBOLS."
  (let ((directory default-directory)
        (original (window-buffer editor))
        (start (window-start editor))
        (point (window-point editor))
        (horizontal (window-hscroll editor))
        (vertical (window-vscroll editor))
        (previous (window-prev-buffers editor))
        (next (window-next-buffers editor))
        (tabs (window-parameter editor 'tab-line-buffers))
        shown)
    (cl-labels
     ((restore-history ()
        (set-window-prev-buffers editor previous)
        (set-window-next-buffers editor next)
        (set-window-parameter editor 'tab-line-buffers tabs))
      (restore-scroll ()
        (set-window-hscroll editor horizontal)
        (set-window-vscroll editor vertical))
      (restore ()
        (when (and shown (window-live-p editor) (buffer-live-p original))
          (set-window-buffer-start-and-point editor original start point)
          (restore-scroll)
          (restore-history)
          (setq shown nil)))
      (show (candidate)
        (unless (or (null candidate) (string-prefix-p ">" candidate)
                    (file-remote-p (expand-file-name candidate)))
          (pcase-let*
              ((`(,_ ,file ,kind ,query) (gdev-quick-open--suffix candidate))
               (`(,path . ,line)
                (cond (kind (cons file nil))
                      ((string-match "\\`:\\([1-9][0-9]*\\)\\'" candidate)
                       (cons nil (string-to-number (match-string 1 candidate))))
                      (t (gdev-quick-open--file-and-line candidate))))
               (buffer (if path
                           (or (get-file-buffer path)
                               (and (file-regular-p path) (funcall open path)))
                         original)))
            (when (buffer-live-p buffer)
              (let* ((item (and (eq kind ?@) (gethash query (funcall symbols buffer))))
                     (location (if (consp (cdr item)) (cadr item) (cdr item)))
                     (position (cond ((and line (> line 0)) (gdev-quick-open--line-position buffer line))
                                     ((and (eq kind ?#) (not (string-empty-p query)))
                                      (gdev-quick-open--text-position buffer query))
                                     ((number-or-marker-p location) location)))
                     (same (eq buffer original))
                     (record (unless same (assq buffer previous))))
                (set-window-buffer-start-and-point editor buffer
                                                   (or position (if same start (nth 1 record)))
                                                   (or position (if same point (nth 2 record))))
                (when same (restore-scroll))
                (restore-history)
                (setq shown t)))))))
     (lambda (action candidate)
       (let ((default-directory directory))
         (pcase action
           ('preview
            (when (and (window-live-p editor) (not (show candidate)))
              (restore)))
           ((or 'exit 'return) (restore))))))))

(defun gdev-quick-open--typed-location ()
  "Considera come anteprima anche la ricerca di testo e il numero di riga."
  (let ((input (minibuffer-contents-no-properties)))
    (when (or (string-prefix-p "#" input)
              (string-match-p ":[0-9]+\\'" input)
              (eq (nth 2 (gdev-quick-open--suffix input)) ?#))
      input)))

(defvar-keymap gdev-quick-open-map
  "<escape>" #'abort-recursive-edit)

(defun gdev-command-palette ()
  "Apri la ricerca rapida direttamente sui comandi."
  (interactive)
  (gdev-quick-open ">"))

(defun gdev-quick-open--text-width (text)
  "Misura TEXT anche con il carattere usato per la riga selezionata."
  (let ((width (gdev-ui-string-pixel-width text)))
    (if (not (facep 'vertico-current)) width
      (let ((selected (copy-sequence text)))
        (add-face-text-property 0 (length selected) 'vertico-current t selected)
        (max width (gdev-ui-string-pixel-width selected))))))

(defun gdev-quick-open--folder-distinction (folder peers)
  "Restituisci l'inizio del suffisso che distingue FOLDER da PEERS."
  (when-let* ((others (remove folder peers)))
    (let ((start (1+ (or (cl-position ?/ folder :from-end t) -1))))
      (while (and (> start 0)
                  (let ((suffix (substring folder (1- start))))
                    (seq-some (lambda (other) (string-suffix-p suffix (concat "/" other)))
                              others)))
        (setq start (1+ (or (cl-position ?/ folder :end (1- start) :from-end t) -1))))
      start)))

(defun gdev-quick-open--folder-label (folder width &optional peers)
  "Mostra FOLDER in WIDTH pixel distinguendo le cartelle PEERS, se presenti."
  (if (<= (gdev-quick-open--text-width folder) width) folder
    (let ((ellipsis (propertize "…" 'face '(gdev-ui-secondary variable-pitch))))
      (if-let* ((start (gdev-quick-open--folder-distinction folder peers)))
          (let ((tail (if (zerop start) folder (concat ellipsis (substring folder (1- start))))))
            (if (<= (gdev-quick-open--text-width tail) width) tail
              (let* ((end (string-search "/" folder start))
                     (ancestor (substring folder start end))
                     (short (if end (concat ancestor "/" ellipsis) ancestor)))
                (gdev-ui-fit-text short width #'gdev-quick-open--text-width))))
        (let ((slash (string-search "/" folder)) visible)
          (while (and slash (not visible))
            (let ((tail (concat ellipsis (substring folder slash))))
              (when (<= (gdev-quick-open--text-width tail) width)
                (setq visible tail)))
            (setq slash (string-search "/" folder (1+ slash))))
          (or visible
              (gdev-ui-fit-text (substring folder (1+ (or (cl-position ?/ folder :from-end t) -1)))
                                width #'gdev-quick-open--text-width)))))))

(defun gdev-quick-open--file-folder (candidate)
  "Restituisci la cartella su una riga per il file CANDIDATE."
  (let ((end (length (file-name-directory candidate))))
    (when (> end 0)
      (replace-regexp-in-string "[\r\n\t]" " " (substring candidate 0 (max 1 (1- end)))))))

(defun gdev-quick-open--file-row (candidate width &optional peers)
  "Mostra CANDIDATE in WIDTH pixel con il suo percorso e le cartelle PEERS."
  (let* ((dir-length (length (file-name-directory candidate)))
         (name (replace-regexp-in-string "[\r\n\t]" " " (substring candidate dir-length)))
         (folder (gdev-quick-open--file-folder candidate))
         (gap (propertize "  " 'face 'variable-pitch))
         (gap-width (gdev-quick-open--text-width gap))
         (reserve (if folder (min (/ width 3) (* 14 gap-width)) 0)))
    (add-face-text-property 0 (length name) '(gdev-ui-view-heading variable-pitch) t name)
    (setq name (gdev-ui-fit-file-name name (- width reserve) #'gdev-quick-open--text-width))
    (let* ((remaining (- width gap-width (gdev-quick-open--text-width name)))
           (detail (when (and folder (> remaining 0))
                     (add-face-text-property 0 (length folder) '(gdev-ui-secondary variable-pitch) t folder)
                     (gdev-quick-open--folder-label folder remaining peers)))
           (row (if (string-empty-p (or detail "")) name (concat name gap detail)))
           (label (propertize (gdev-ui-fit-text row width #'gdev-quick-open--text-width)
                              'help-echo (substring-no-properties candidate))))
      (list (propertize (substring-no-properties candidate) 'display label) "" ""))))

(defun gdev-quick-open--files-affixation (candidates)
  "Presenta CANDIDATES nello spazio visibile senza cambiare le corrispondenze."
  (let* ((window (active-minibuffer-window))
         (width (max 0 (- (window-body-width window t)
                          (* 2 (frame-char-width (window-frame window))))))
         (folders (make-hash-table :test #'equal)))
    (dolist (candidate candidates)
      (when-let* ((folder (gdev-quick-open--file-folder candidate)))
        (push folder (gethash (file-name-nondirectory candidate) folders))))
    (mapcar (lambda (candidate)
              (gdev-quick-open--file-row candidate width
                                        (gethash (file-name-nondirectory candidate) folders)))
            candidates)))

(defun gdev-quick-open--preview-key (directory candidate)
  "Mostra subito i documenti locali già aperti in DIRECTORY.
Conserva un breve intervallo per CANDIDATE che può richiedere lettura."
  (if (or (string-prefix-p ">" candidate)
          (let ((file (expand-file-name candidate directory)))
            (and (not (file-remote-p file)) (get-file-buffer file))))
      'any
    '(:debounce 0.12 any)))

(defun gdev-quick-open--read (initial-input table editor open read-symbols)
  "Leggi con TABLE e, quando OPEN è disponibile, mostra l'anteprima in EDITOR."
  (let ((prompt (if (equal initial-input ">") "Comando: "
                  (propertize "Vai a: " 'help-echo "File, :riga, @simbolo, #testo o >comando"))))
    (if open
        (let ((state (gdev-quick-open--preview editor open read-symbols))
              (preview-key (list :keys 'any :predicate
                                 (apply-partially #'gdev-quick-open--preview-key default-directory)))
              (vertico-mouse-mode (or (bound-and-true-p vertico-mouse-mode)
                                      (and (display-graphic-p)
                                           (require 'vertico-mouse nil t) t)))
              (consult--completion-candidate-hook
               (cons #'gdev-quick-open--typed-location consult--completion-candidate-hook))
              minibuffer hover)
          (unwind-protect
              (minibuffer-with-setup-hook
                  (lambda ()
                    (when (and vertico-mouse-mode (display-graphic-p) (facep 'gdev-ui-side-hover))
                      (setq minibuffer (current-buffer)
                            hover (face-remap-add-relative 'vertico-mouse 'gdev-ui-side-hover))))
                (consult--read table :prompt prompt :initial initial-input
                               :keymap gdev-quick-open-map :preview-key preview-key
                               :state state))
            (when (and hover (buffer-live-p minibuffer))
              (with-current-buffer minibuffer (face-remap-remove-relative hover)))
            (funcall state 'exit nil)
            (funcall open)))
      (minibuffer-with-setup-hook
          (lambda () (use-local-map (make-composed-keymap gdev-quick-open-map (current-local-map))))
        (completing-read prompt table nil nil initial-input)))))

(defun gdev-quick-open--visit (input editor buffer read-symbols applicable-command-p &optional commands)
  "Esegui INPUT in EDITOR, usando i simboli di BUFFER e i comandi applicabili."
  (cond
   ((string-empty-p input) nil)
   ((string-prefix-p ">" input)
    (let* ((name (substring input 1))
           (item (assoc name commands))
           (command (if item (cdr item) (intern-soft name))))
      ;; Un'etichetta del catalogo porta il comando reale del menu, anche se
      ;; M-x lo chiama con un altro nome; un nome digitato segue M-x.
      (unless (if item
                  (gdev-keys-command-applicable-p command buffer)
                (funcall applicable-command-p command))
        (user-error "Comando non disponibile: %s" name))
      (select-window editor)
      (if (symbolp command)
          (let ((id (symbol-name command)))
            (add-to-history 'extended-command-history id)
            (funcall-interactively #'execute-extended-command current-prefix-arg id))
        (setq this-command command)
        (call-interactively command))))
   ((when-let* ((suffix (gdev-quick-open--suffix input)))
      (pcase-let* ((`(,_ ,file ,kind ,query) suffix)
                   (target (if file (find-file-noselect file) buffer))
                   (location (if (eq kind ?@)
                                 (gethash query (funcall read-symbols target))
                               (gdev-quick-open--text-position target query))))
        (unless (and location (not (string-empty-p query)))
          (user-error (if (eq kind ?@)
                          "Indica un simbolo presente da cercare nel documento"
                        "Indica un testo presente da cercare nel documento")))
        (select-window editor)
        (unless (eq (window-buffer editor) target) (switch-to-buffer target))
        (if (eq kind ?@) (imenu location) (goto-char location))
        (when (and file (fboundp 'gdev-editor-pin-preview))
          (gdev-editor-pin-preview target))
        t)))
   ((string-match "\\`:\\([0-9]+\\)\\'" input)
    (let ((line (string-to-number (match-string 1 input))))
      (unless (> line 0) (user-error "Le righe partono da 1"))
      (select-window editor)
      (funcall-interactively #'goto-line line)))
   (t
    (pcase-let ((`(,file . ,line) (gdev-quick-open--file-and-line input)))
      (unless (or (file-exists-p file) (get-file-buffer file))
        (user-error "Percorso non trovato: %s" (abbreviate-file-name file)))
      (when line
        (unless (> line 0) (user-error "Le righe partono da 1"))
        (when (file-directory-p file) (user-error "Scegli un file per andare a una riga")))
      (gdev-open-file file)
      (when line (funcall-interactively #'goto-line line))))))

(defun gdev-quick-open--project (directory)
  "Associa l'ambito DIRECTORY al progetto che lo contiene."
  (cons directory (or (project-current nil directory) (cons 'transient directory))))

(defun gdev-quick-open--pending-files (root)
  "Elenca i documenti aperti con un nome in ROOT e ancora assenti dal disco."
  (sort (cl-loop for buffer in (buffer-list)
                 for file = (buffer-file-name buffer)
                 when (and file (not (file-remote-p file))
                           (with-current-buffer buffer (equal (visited-file-modtime) -1))
                           (file-in-directory-p file root)
                           (not (file-exists-p file)))
                 collect (file-relative-name file root))
        #'string-lessp))

(defun gdev-quick-open--candidate-names (names root directory)
  "Rendi i file NAMES di ROOT relativi alla cartella DIRECTORY."
  (when names
    (let* ((root (file-name-as-directory (expand-file-name root)))
           (relative (unless (or gdev-windows-p (file-remote-p root) (file-remote-p directory))
                       (file-relative-name root directory)))
           (prefix (when (and relative
                              ;; Un antenato può contenere anche la cartella attiva.
                              (not (string-match-p "\\`\\(?:\\.\\./\\)+\\'" relative))
                              ;; Se la grafia differisce, Emacs stabilisce per ogni
                              ;; percorso se ignorare le maiuscole.
                              (equal root (expand-file-name relative directory)))
                     (if (equal relative "./") "" relative))))
      (mapcar (lambda (name)
                (if (and prefix (string-match-p "\\`[^~/]" name)
                         (not (string-match-p "//\\|\\(?:\\`\\|/\\)\\.\\.?\\(?:/\\|\\'\\)" name)))
                    (concat prefix name)
                  (file-relative-name (expand-file-name name root) directory)))
              names))))

(defun gdev-quick-open (&optional initial-input)
  "Vai a un file o aggiungi :RIGA, @SIMBOLO o #TESTO.
Digita >COMANDO per aprire la tavolozza dei comandi.
INITIAL-INPUT è il testo iniziale della ricerca."
  (interactive)
  (let* ((editor (or (gdev-layout-editor) (user-error "Apri una finestra dell'editor")))
         (buffer (window-buffer editor))
         (explorer (gdev-workspace-state-get 'gdev-layout-explorer-buffer))
         (roots (gdev-workspace-roots))
         (multiple (cdr roots))
         (folder (gdev-workspace-directory))
         (directory (or folder
                        (buffer-local-value 'default-directory
                                            (if (buffer-live-p explorer) explorer buffer))))
         (project (unless multiple
                    (if (and (gdev-workspace-state-get 'gdev-layout-folder)
                             (not (file-remote-p directory)))
                        (gdev-quick-open--project directory)
                      (when-let* ((backend (project-current nil directory)))
                        (cons (project-root backend) backend)))))
         (default-directory (if project (car project) directory))
         (files (make-hash-table :test #'equal))
         (snapshots (make-hash-table :test #'equal))
         (scans (make-hash-table :test #'equal))
         (fingerprints (make-hash-table :test #'equal))
         workspace-projects candidate-lists workspace-candidates
         minibuffer-window minibuffer-buffer refresh-timer candidates-dirty
         (commands 'unread)
         (open (and (gdev-module-p :completion 'vertico)
                    (require 'consult nil t) (consult--temporary-files)))
         (symbols (make-hash-table :test #'eq)))
    (cl-labels ((read-symbols (target)
                  (or (gethash target symbols)
                      (puthash target (gdev-quick-open--symbols target) symbols)))
                (applicable-command-p (symbol)
                  (and (commandp symbol)
                       (or (not (symbolp symbol)) (not read-extended-command-predicate)
                           (funcall read-extended-command-predicate symbol buffer))))
                (command-items ()
                  (when (eq commands 'unread)
                    (setq commands (when (and (gdev-module-p :ui 'workbench)
                                              (fboundp 'gdev-menu-command-items))
                                     (with-selected-window editor
                                       ;; Le voci portano il simbolo reale del comando: un
                                       ;; comando rinominato in M-x resta nel catalogo.
                                       (seq-filter (lambda (item)
                                                     (gdev-keys-command-applicable-p (cdr item) buffer))
                                                   (gdev-menu-command-items))))))
                  commands)
                (candidate-names (scope names)
                  (if (not multiple) names
                    (gdev-quick-open--candidate-names names (car scope) directory)))
                (set-project-candidates (scope names pending)
                  (let ((snapshot (cons names pending)))
                    (unless (equal snapshot (gethash scope snapshots))
                      (puthash scope snapshot snapshots)
                      (puthash scope (candidate-names scope
                                                     (if pending (delete-dups (append names pending nil)) names))
                               files)
                      t)))
                (file-search-active-p ()
                  (and minibuffer-window (eq minibuffer-window (active-minibuffer-window))
                       (eq minibuffer-buffer (window-buffer minibuffer-window))
                       (with-current-buffer minibuffer-buffer
                         (eq (completion-metadata-get (complete (minibuffer-contents-no-properties)
                                                               nil 'metadata)
                                                      'category)
                             'gdev-quick-open-file))))
                (refresh-candidates ()
                  (when (and candidates-dirty (file-search-active-p))
                    (setq candidates-dirty nil)
                    (with-current-buffer minibuffer-buffer
                      (completion--flush-all-sorted-completions)
                      (run-hooks 'consult--completion-refresh-hook))))
                (start-project-scan (scope)
                  (let* ((started (float-time))
                         (scan (cons nil (+ started gdev-quick-open--refresh-interval)))
                         (root (car scope))
                         (backend (cdr scope)))
                    (puthash scope scan scans)
                    (setcar scan
                            (condition-case nil
                                (gdev-quick-open--scan
                                 backend
                                 (lambda (names success fingerprint)
                                   (when (eq scan (gethash scope scans))
                                     (let* ((now (float-time))
                                            (interval gdev-quick-open--refresh-interval)
                                            (delay (max interval (min (* 3 interval) (* 3 (- now started))))))
                                       (setcdr scan (+ now delay)))
                                     (when (and success minibuffer-window)
                                       (puthash scope fingerprint fingerprints)
                                       (gdev-quick-open--remember-files scope fingerprint names)
                                       (when (set-project-candidates scope names (cdr (gethash scope snapshots)))
                                         (setq candidates-dirty t)
                                         (refresh-candidates)))))
                                 (unless (equal root (project-root backend)) root)
                                 (cons (gethash scope fingerprints) (car (gethash scope snapshots))))
                              (file-error nil)))))
                (refresh-project-scans ()
                  (when (file-search-active-p)
                    (let ((now (float-time)))
                      (maphash (lambda (scope scan)
                                 (let ((root (car scope)))
                                   (when (and (not (file-remote-p root))
                                              (set-project-candidates scope (car (gethash scope snapshots))
                                                                       (gdev-quick-open--pending-files root)))
                                     (setq candidates-dirty t)))
                                 (when (and (<= (cdr scan) now) (not (process-live-p (car scan))))
                                   (start-project-scan scope)))
                               scans))
                    (refresh-candidates)))
                (project-candidates (scope)
                  (unless (gethash scope snapshots)
                    (let* ((root (car scope))
                           (backend (cdr scope))
                           (local (not (file-remote-p root)))
                           (pending (and local (gdev-quick-open--pending-files root)))
                           (cached (cdr (assoc scope gdev-quick-open--recent-project-files)))
                           (names (and cached (gdev-quick-open--index-files cached))))
                      (when-let* (((not noninteractive))
                                  ((memq (car-safe backend) '(vc transient)))
                                  (window (active-minibuffer-window)))
                        (setq minibuffer-window window minibuffer-buffer (window-buffer window))
                        (set-project-candidates scope names pending)
                        (when cached
                          (puthash scope (gdev-quick-open--index-fingerprint cached) fingerprints))
                        (start-project-scan scope)
                        (unless refresh-timer
                          (let ((tick (min 1 gdev-quick-open--refresh-interval)))
                            (setq refresh-timer (run-at-time tick tick #'refresh-project-scans)))))
                      (unless (processp (car (gethash scope scans)))
                        (set-project-candidates
                         scope (if local (funcall gdev-quick-open--project-file-list backend root) names)
                         pending))))
                  (gethash scope files))
                (all-candidates ()
                  (unless workspace-projects
                    (setq workspace-projects (mapcar #'gdev-quick-open--project roots)))
                  (let ((lists (mapcar #'project-candidates workspace-projects)))
                    (unless (and candidate-lists (cl-every #'eq lists candidate-lists))
                      (setq candidate-lists lists
                            workspace-candidates (delete-dups (apply #'append (append lists '(nil))))))
                    workspace-candidates))
                (complete (string pred action)
                  (cond
                   ((string-prefix-p ">" string)
                    (let* ((query (substring string 1))
                           (catalog (unless (string-match-p "\\`[^[:space:]-]+-[^[:space:]]*\\'" query)
                                      (command-items))))
                      (cond ((eq action 'metadata)
                             (if catalog '(metadata (category . gdev-command))
                               '(metadata (category . command))))
                            (catalog (completion-table-with-context ">" catalog query pred action))
                            (t (gdev-keys-refresh-aliases)
                               ;; Con una tabella di simboli, `completion-table-with-context'
                               ;; passa al filtro il nome con il prefisso («>nome»): senza
                               ;; ricavarne il simbolo il filtro ammetterebbe ogni cosa.
                               (completion-table-with-context
                                ">" obarray query
                                (lambda (name)
                                  (let ((symbol (intern-soft (string-remove-prefix ">" name))))
                                    (and symbol (applicable-command-p symbol)
                                         (or (not pred) (funcall pred symbol)))))
                                action)))))
                   ((when-let* ((suffix (gdev-quick-open--suffix string)))
                      (pcase-let ((`(,prefix ,file ,kind ,query) suffix))
                        (if (eq action 'metadata)
                            '(metadata (category . imenu))
                          (and (eq kind ?@)
                               (when-let* ((target (if file (and (not (file-remote-p file))
                                                                 (or (get-file-buffer file)
                                                                     (and open (funcall open file))))
                                                     buffer)))
                                 (completion-table-with-context prefix (read-symbols target)
                                                                query pred action)))))))
                   ((string-match-p "\\`:[0-9]*\\'" string)
                    (if (eq action 'metadata) '(metadata)
                      (when (eq (car-safe action) 'boundaries) '(boundaries 1 . 0))))
                   ((or (and (null project) (not multiple))
                        (string-match-p "\\`\\(?:[~/]\\|\\.\\.?/\\)" string))
                    (completion-file-name-table string pred action))
                   ((eq action 'metadata)
                    (if (and (bound-and-true-p vertico-mode)
                             (display-graphic-p) (fboundp 'gdev-ui-fit-file-name))
                        '(metadata (category . gdev-quick-open-file)
                                   (affixation-function . gdev-quick-open--files-affixation))
                      '(metadata (category . gdev-quick-open-file))))
                   (t
                    (complete-with-action action
                                          (if multiple (all-candidates) (project-candidates project))
                                          string pred)))))
      (let ((input (unwind-protect
                       (let ((completion-category-defaults
                              (cons '(gdev-quick-open-file (styles flex)) completion-category-defaults))
                             (completion-flex-nospace t))
                         (gdev-quick-open--read initial-input #'complete editor open #'read-symbols))
                     (setq minibuffer-window nil)
                     (when refresh-timer (cancel-timer refresh-timer))
                     (maphash (lambda (_scope scan)
                                (when (process-live-p (car scan)) (delete-process (car scan))))
                              scans))))
        (gdev-quick-open--visit input editor buffer #'read-symbols #'applicable-command-p
                              (and (string-prefix-p ">" input) (command-items)))))))

(defun gdev-call-with-editor (function)
  "Esegui FUNCTION nel gruppo editor attivo.
In caso di annullamento o errore ripristina il riquadro di partenza."
  (let ((origin (selected-window))
        (editor (or (gdev-layout-editor) (user-error "Apri una finestra dell'editor")))
        done)
    (select-window editor)
    (unwind-protect
        (prog1 (funcall function) (setq done t))
      (when (and (not done) (window-live-p origin))
        (select-window origin)))))

(defun gdev-call-for-document (function &optional from-user)
  "Esegui FUNCTION per il documento attivo.
Con FROM-USER, vero quando il comando arriva da tastiera, menu o M-x, il
comando lanciato da Esplora file, dal pannello o da Comandi passa prima
all'editor, come F5 e la tavolozza dei comandi."
  (if (and from-user (bound-and-true-p gdev-layout-mode)
           (when-let* ((editor (gdev-layout-editor))) (not (eq editor (selected-window)))))
      (gdev-call-with-editor function)
    (funcall function)))

(defun gdev-find-definition ()
  "Vai alla definizione del simbolo nel documento attivo."
  (interactive)
  (require 'xref)
  (gdev-call-with-editor
   (lambda ()
     (let ((this-command 'xref-find-definitions))
       (call-interactively this-command)))))

(defun gdev-find-references ()
  "Mostra i riferimenti al simbolo nel documento attivo."
  (interactive)
  (require 'xref)
  (gdev-call-with-editor
   (lambda ()
     (if (and gdev-layout-mode (not current-prefix-arg)
              (fboundp 'gdev-lsp-capable-p) (gdev-lsp-capable-p :referencesProvider)
              (eq (xref-find-backend) 'eglot))
         (gdev-lsp-navigation-show 'references)
       (let ((this-command 'xref-find-references))
         (call-interactively this-command))))))

(declare-function gdev-lsp-capable-p "../modules/tools/lsp/config" (capability &optional buffer))
(declare-function gdev-lsp-navigation-show "gdev-lsp-navigation" (kind))

(defun gdev-find-project-symbol ()
  "Cerca un simbolo nel progetto tramite il server del documento attivo."
  (interactive)
  (let* ((editor (or (gdev-layout-editor) (user-error "Apri una finestra dell'editor")))
         (query (with-selected-window editor
                  (unless (and (eq (xref-find-backend) 'eglot)
                               (eglot-server-capable :workspaceSymbolProvider))
                    (user-error "Apri un file con un server di linguaggio che indicizza i simboli del progetto"))
                  (read-string "Simbolo nel progetto: " nil nil (thing-at-point 'symbol t)))))
    (unless (string-blank-p query)
      (gdev-call-with-editor (lambda () (xref-find-apropos (string-trim query)))))))

(defun gdev-copy-file-name (&optional absolute)
  "Copia il nome del file corrente, relativo alla cartella che lo contiene.
La cartella è quella dello spazio di lavoro, come in Esplora file, o
altrimenti il progetto.  Con l'argomento prefisso ABSOLUTE copia il nome
assoluto.  In Esplora file e in Dired copia la voce della riga."
  (interactive "P")
  (let* ((file (or (gdev-command-file) (user-error "Questo buffer non ha un file")))
         (name (if absolute file (gdev-command-relative-name file))))
    (kill-new name)
    (message "Copiato: %s" name)))

(defun gdev-copy-file-location ()
  "Copia \"file/relativo:RIGA\", la forma usata da compilatori e revisori."
  (interactive)
  (unless buffer-file-name (user-error "Questo buffer non ha un file"))
  ;; ABSOLUTE: in un buffer ristretto la riga è quella del file, non della porzione.
  (let ((location (format "%s:%d" (gdev-command-relative-name buffer-file-name)
                          (line-number-at-pos nil t))))
    (kill-new location)
    (message "Copiato: %s" location)))

(defun gdev-delete-visited-file ()
  "Sposta nel Cestino il file visitato e chiude il suo buffer.
Un file tracciato da Git viene rimosso con git rm."
  (interactive)
  (let* ((file (or buffer-file-name (user-error "Questo buffer non ha un file")))
         (name (file-name-nondirectory file))
         (prompt (format "Eliminare %s? " name))
         (backend (vc-backend file))
         (buffer (current-buffer)))
    (cond ((and backend (< emacs-major-version 31))
           ;; In Emacs 30 VC chiede conferma e accetta un solo argomento.
           (let ((ask (symbol-function 'y-or-n-p)))
             (cl-letf (((symbol-function 'y-or-n-p)
                        (lambda (question)
                          (if (equal question (format "Really want to delete %s? " name))
                              (or (funcall ask prompt) (user-error "Eliminazione annullata"))
                            (funcall ask question)))))
               (vc-delete-file file))))
          ((yes-or-no-p prompt)
           (if backend (vc-delete-file file t) (delete-file file t))
           (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun gdev--sudo-file-name (file)
  "Restituisce il nome TRAMP che apre FILE come root, in locale o in remoto.
/ssh:host:/etc/x diventa /ssh:host|sudo:root@host:/etc/x."
  (if (file-remote-p file)
      (let* ((vec (tramp-dissect-file-name file))
             (local (tramp-file-name-localname vec))
             (prefix (substring file 0 (- (length file) (length local)))))
        (concat (string-remove-suffix ":" prefix)
                "|sudo:root@" (tramp-file-name-host vec) ":" local))
    (concat "/sudo:root@localhost:" (expand-file-name file))))
(declare-function tramp-dissect-file-name "tramp")
(declare-function tramp-file-name-host "tramp")
(declare-function tramp-file-name-localname "tramp")

(defun gdev-sudo-this-file ()
  "Riapre il file visitato con i privilegi di root (sudo tramite TRAMP)."
  (interactive)
  (find-alternate-file (gdev--sudo-file-name (or buffer-file-name
                                                 (user-error "Questo buffer non ha un file")))))

(defun gdev-sudo-find-file (file)
  "Apre FILE con i privilegi di root, in locale o sull'host remoto corrente."
  (interactive "FApri come root: ")
  (find-file (gdev--sudo-file-name file)))

(defun gdev-open-private-config ()
  "Apre un file della configurazione privata (~/.config/gdev)."
  (interactive)
  (unless (file-directory-p gdev-user-directory)
    (user-error "Nessuna configurazione privata: esegui `gdev install' in un terminale"))
  (let ((default-directory gdev-user-directory))
    (find-file (read-file-name "Configurazione privata: " gdev-user-directory nil t "config.el"))))

(defun gdev-find-framework-file ()
  "Apre un file della copia di lavoro di GDev-Emacs."
  (interactive)
  (let ((default-directory gdev-config-directory))
    (project-find-file)))

(defun gdev-edit-dir-locals ()
  "Apre il .dir-locals.el del progetto: le impostazioni per progetto."
  (interactive)
  (find-file (expand-file-name ".dir-locals.el" (gdev-project-root))))

(defun gdev-find-other-file ()
  "Apre il file compagno di questo: intestazione e sorgente, modulo e test.
I moduli di linguaggio dicono qual è il compagno; altrimenti si usa
`ff-find-other-file'."
  (interactive)
  (if-let* ((handler (gdev-handler :other-file)))
      (funcall handler)
    (ff-find-other-file nil t)))

(declare-function gdev-sidebar-show nil)  ; modulo :ui sidebar
(declare-function project-remember-project "project")
(defvar project-current-directory-override)

(defvar gdev-open-folder-hook nil
  "Funzioni chiamate con il percorso della cartella appena aperta.")

(add-to-list 'project-vc-extra-root-markers ".project")
(add-to-list 'project-vc-extra-root-markers ".gdev-assurance")

(defun gdev-create-project-directory (directory initialize)
  "Prepara DIRECTORY, nuova o vuota, con INITIALIZE e aprila a creazione conclusa."
  (let ((root (file-name-as-directory (expand-file-name directory)))
        created complete)
    (if (file-exists-p (directory-file-name root))
        (unless (and (file-directory-p root) (gdev-directory-empty-p root))
          (user-error "Scegli una cartella nuova o vuota per il progetto"))
      (make-directory root)
      (setq created t))
    (unwind-protect
        (progn (funcall initialize root) (setq complete t))
      (when (and created (not complete)) (ignore-errors (delete-directory root))))
    ;; La cartella può essere già stata visitata prima di avere il marcatore.
    (let ((project-vc-cache-timeout 0) (non-essential nil))
      (gdev-open-folder root))
    root))

(defun gdev-new-empty-project (directory)
  "Crea in DIRECTORY un progetto vuoto e aprilo nello spazio corrente."
  (interactive (list (read-directory-name "Cartella del nuovo progetto: ")))
  (gdev-create-project-directory
   directory (lambda (root) (write-region "" nil (expand-file-name ".project" root) nil 'silent nil 'excl))))

(defun gdev--read-workspace-directory (directory)
  "Convalida DIRECTORY prima di modificare lo spazio di lavoro."
  (unless (file-directory-p directory)
    (user-error "Cartella non trovata: %s" (abbreviate-file-name directory)))
  (file-name-as-directory
   (if (file-remote-p directory) (expand-file-name directory) (file-truename directory))))

(defun gdev--remember-open-folder (directory)
  "Notifica l'apertura di DIRECTORY e ricorda il suo progetto."
  (run-hook-with-args 'gdev-open-folder-hook directory)
  (when-let* ((project (project-current nil directory)))
    (project-remember-project project)))

(defun gdev--reveal-folder (directory)
  "Mostra DIRECTORY in Esplora file o in Dired."
  (if (fboundp 'gdev-sidebar-show)
      (gdev-sidebar-show directory)
    (dired directory)))

(defun gdev-open-folder (directory)
  "Apre DIRECTORY al posto delle cartelle dello spazio di lavoro.
Se la barra laterale (modulo :ui sidebar) è attiva mostra lì l'albero dei
file; altrimenti apre la cartella in Dired."
  (interactive (list (read-directory-name "Apri cartella: " nil nil t)))
  (let ((directory (gdev--read-workspace-directory directory)))
    (gdev--remember-open-folder directory)
    (when gdev-layout-mode
      (gdev-workspace-set-roots (list directory)))
    (gdev--reveal-folder directory)))

(defun gdev-workspace-add-folder (directory)
  "Aggiungi DIRECTORY alle cartelle dello spazio di lavoro attivo."
  (interactive (list (read-directory-name "Aggiungi cartella allo spazio di lavoro: " nil nil t)))
  (let* ((directory (gdev--read-workspace-directory directory))
         (roots (gdev-workspace-roots)))
    (unless (member directory roots)
      (gdev--remember-open-folder directory)
      (setq roots (append roots (list directory)))
      (gdev-workspace-set-roots roots))
    (gdev--reveal-folder directory)))

(defun gdev-workspace-remove-folder (directory)
  "Rimuovi DIRECTORY dallo spazio di lavoro, mantenendo i documenti aperti."
  (interactive
   (let ((roots (gdev-workspace-roots)))
     (unless roots
       (user-error "Lo spazio di lavoro non contiene cartelle"))
     (list (completing-read "Rimuovi cartella dallo spazio di lavoro: " roots nil t
                            nil nil (gdev-workspace-directory)))))
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (roots (gdev-workspace-roots))
         (sidebar (window-with-parameter 'gdev-sidebar t))
         (buffer (gdev-workspace-state-get 'gdev-layout-explorer-buffer)))
    (unless (member directory roots)
      (user-error "La cartella non appartiene a questo spazio di lavoro"))
    (setq roots (remove directory roots))
    (gdev-workspace-set-roots roots)
    (if roots
        (when sidebar (gdev-sidebar-show (car roots) t))
      (when sidebar (delete-window sidebar))
      (gdev-workspace-state-set 'gdev-layout-explorer-buffer nil)
      (when (and (buffer-live-p buffer) (not (get-buffer-window buffer t)))
        (kill-buffer buffer)))))

(defun gdev-project-open-folder ()
  "Apri in Esplora file la cartella del progetto o dello spazio corrente."
  (interactive)
  (let ((override (bound-and-true-p project-current-directory-override))
        (roots (and gdev-layout-mode (gdev-workspace-roots))))
    (if (and (cdr roots) (not override))
        (gdev--reveal-folder (car roots))
      (gdev-open-folder (or override (car roots) (project-root (project-current t)))))))

(defun gdev-git-status ()
  "Apri lo stato Git della cartella di lavoro corrente."
  (interactive)
  (let ((default-directory
         (or (gdev-workspace-directory)
             (when-let* ((editor (gdev-layout-editor)))
               (buffer-local-value 'default-directory (window-buffer editor)))
             default-directory)))
    (if (and (gdev-module-p :tools 'git) (commandp 'magit-status))
        (call-interactively #'magit-status)
      (vc-dir default-directory))))

(declare-function magit-status "magit-status")

;;;; Ripeti la ricerca nel testo

(defvar gdev-find--last nil
  "Ultima ricerca confermata, con il punto e l'altro estremo dell'occorrenza.")

(defun gdev-find--remember ()
  "Conserva i parametri della ricerca confermata per poterla ripetere."
  (when (and (not isearch-mode-end-hook-quit) isearch-success
             (not (string-empty-p isearch-string)))
    (setq gdev-find--last
          (list isearch-string isearch-regexp isearch-regexp-function
                isearch-message isearch-case-fold-search
                (point-marker) isearch-other-end (buffer-chars-modified-tick)))))

(add-hook 'isearch-mode-end-hook #'gdev-find--remember)

(defun gdev-find-repeat-available-p ()
  "Indica se si può ripetere una ricerca nel testo."
  (or isearch-mode gdev-find--last search-ring regexp-search-ring))

(defun gdev-find--repeat (forward arg)
  "Ripeti in direzione FORWARD rispettando il prefisso numerico ARG."
  (if isearch-mode
      (funcall (if forward #'isearch-repeat-forward #'isearch-repeat-backward) arg)
    (unless (gdev-find-repeat-available-p)
      (user-error "Avvia prima una ricerca nel testo"))
    (let* ((count (prefix-numeric-value arg))
           (forward (if (< count 0) (not forward) forward))
           (direction (if forward 'forward 'backward))
           (position (point))
           (regexp (null search-ring))
           (query (car (or search-ring regexp-search-ring)))
           (isearch-wrap-pause (and isearch-wrap-pause 'no-ding))
           found)
      (pcase-let ((`(,text ,regexp ,matcher ,label ,fold ,end ,other ,tick)
                   (or gdev-find--last
                       (list query regexp (get-text-property 0 'isearch-regexp-function query)
                             query (if (plist-member (text-properties-at 0 query)
                                                     'isearch-case-fold-search)
                                       (get-text-property 0 'isearch-case-fold-search query)
                                     case-fold-search)
                             nil nil nil))))
        (when (and end (eq (marker-buffer end) (current-buffer))
                   (= position end) (= tick (buffer-chars-modified-tick))
                   other (<= (point-min) other (point-max)))
          (cond ((if forward (< position other) (> position other)) (goto-char other))
                ((= position other)
                 (if (if forward (eobp) (bobp))
                     (when isearch-wrap-pause
                       (goto-char (if forward (point-min) (point-max))))
                   (forward-char (if forward 1 -1))))))
        (unwind-protect
            (progn
              (isearch-resume text regexp matcher forward label fold)
              (when (and (not isearch-success) isearch-wrap-pause)
                (isearch-repeat direction))
              (when (and isearch-success (> (abs count) 1))
                (isearch-repeat direction (1- (abs count))))
              (setq found isearch-success))
          (when isearch-mode (isearch-done (not found)))
          (unless found (goto-char position)))))))

(defun gdev-find-next (&optional arg)
  "Vai all'occorrenza successiva dell'ultima ricerca nel testo."
  (interactive "P")
  (gdev-find--repeat t arg))

(defun gdev-find-previous (&optional arg)
  "Vai all'occorrenza precedente dell'ultima ricerca nel testo."
  (interactive "P")
  (gdev-find--repeat nil arg))

;;;; Modifica come nelle app del Mac

;; Senza selezione, copia e taglia agiscono sulla riga intera, come negli
;; altri editor; con una selezione si comportano come sempre.

(defun gdev-copy-dwim ()
  "Copia la selezione negli appunti; senza selezione copia la riga corrente."
  (interactive)
  (if (use-region-p)
      (kill-ring-save (region-beginning) (region-end))
    (kill-ring-save (line-beginning-position) (min (point-max) (1+ (line-end-position))))
    (message "Riga copiata")))

(defun gdev-cut-dwim ()
  "Taglia la selezione; senza selezione taglia la riga corrente."
  (interactive)
  (if (use-region-p)
      (kill-region (region-beginning) (region-end))
    (kill-whole-line)))

(defun gdev-kill-to-line-start ()
  "Cancella il testo dall'inizio della riga fino al cursore."
  (interactive)
  (kill-region (line-beginning-position) (point)))

(defun gdev--indent-rigidly (columns)
  "Sposta di COLUMNS colonne la selezione, o la riga corrente senza selezione.
La selezione resta attiva, così il comando si può ripetere."
  (let ((deactivate-mark nil))
    (if (use-region-p)
        (indent-rigidly (region-beginning) (region-end) columns)
      (indent-rigidly (line-beginning-position) (line-end-position) columns))))

(defun gdev-indent-right ()
  "Aumenta il rientro della selezione, o della riga corrente."
  (interactive)
  (gdev--indent-rigidly (max 1 (or (bound-and-true-p standard-indent) 4))))

(defun gdev-indent-left ()
  "Diminuisce il rientro della selezione, o della riga corrente."
  (interactive)
  (gdev--indent-rigidly (- (max 1 (or (bound-and-true-p standard-indent) 4)))))

;;;; Buffer e finestre

(defun gdev-focus-editor ()
  "Seleziona il riquadro editor usato più di recente."
  (interactive)
  (let ((editor (gdev-layout-editor)))
    (unless editor (user-error "Apri una finestra dell'editor"))
    (select-window editor)))

(defun gdev-split-editor-right (&optional source)
  "Dividi il gruppo di modifica SOURCE a destra."
  (interactive)
  (if gdev-layout-mode
      (gdev-layout-split-editor 'right source)
    (select-window (split-window-right))))

(defun gdev-split-editor-below (&optional source)
  "Dividi il gruppo di modifica SOURCE in basso."
  (interactive)
  (if gdev-layout-mode
      (gdev-layout-split-editor 'below source)
    (select-window (split-window-below))))

(defun gdev-focus-other-editor ()
  "Passa al gruppo di modifica successivo nello stesso spazio."
  (interactive)
  (if gdev-layout-mode
      (when-let* ((editor (gdev-layout-editor))
                  (target (if (eq editor (selected-window))
                              (gdev-layout-other-editor editor)
                            editor)))
        (select-window target))
    (other-window 1)))

(defun gdev-split-editor-grid (&optional source)
  "Completa una griglia di quattro gruppi senza spostare il fuoco da SOURCE."
  (interactive)
  (gdev-layout-split-editor-grid source))

(defun gdev-rotate-editor-pair (&optional source)
  "Cambia l'orientamento della coppia di gruppi."
  (interactive)
  (gdev-layout-rotate-editor-pair source))

(defun gdev-scratch ()
  "Apri Appunti nel gruppo editor, conservandone testo e modalità di modifica."
  (interactive)
  (gdev-focus-editor)
  (let ((buffer (get-scratch-buffer-create)))
    (with-current-buffer buffer
      (gdev-ui-setup-scratch)
      (gdev-layout-mark-document))
    (pop-to-buffer-same-window buffer)))

(defun gdev-new-buffer ()
  "Apre un nuovo buffer vuoto, nella modalità principale di quello corrente."
  (interactive)
  (gdev-focus-editor)
  (let ((mode (if (derived-mode-p 'prog-mode 'text-mode) major-mode #'fundamental-mode))
        (buffer (generate-new-buffer "senza titolo")))
    (with-current-buffer buffer
      (funcall mode)
      (setq-local buffer-offer-save 'always)
      (gdev-layout-mark-document))
    (pop-to-buffer-same-window buffer)))

(declare-function gdev-operation-undo "gdev-operation-history" ())
(declare-function gdev-operation-redo "gdev-operation-history" ())
(declare-function gdev-operation-undo-label "gdev-operation-history" ())
(declare-function gdev-operation-redo-label "gdev-operation-history" ())

(defun gdev-document-undo-context-p ()
  "Restituisci non nil se il buffer corrente conserva la cronologia del testo."
  (and (not buffer-read-only) (not (eq buffer-undo-list t))))

(defun gdev-undo ()
  "Annulla nel documento modificabile o nello spazio di lavoro."
  (interactive)
  (cond ((gdev-document-undo-context-p) (call-interactively #'undo))
        ((fboundp 'gdev-operation-undo) (gdev-operation-undo))
        (t (user-error "Nessuna cronologia di annullamento in questa vista"))))

(defun gdev-redo ()
  "Ripeti nel documento modificabile o nello spazio di lavoro."
  (interactive)
  (cond ((gdev-document-undo-context-p) (call-interactively #'undo-redo))
        ((fboundp 'gdev-operation-redo) (gdev-operation-redo))
        (t (user-error "Nessuna cronologia di ripetizione in questa vista"))))

(defun gdev-undo-available-p ()
  "Restituisci non nil se Annulla è disponibile nella vista corrente."
  (if (gdev-document-undo-context-p) (consp buffer-undo-list)
    (and (fboundp 'gdev-operation-undo-label) (gdev-operation-undo-label))))

(defun gdev-redo-available-p ()
  "Restituisci non nil se Ripeti può agire nella vista corrente."
  (if (gdev-document-undo-context-p)
      (undo--last-change-was-undo-p buffer-undo-list)
    (and (fboundp 'gdev-operation-redo-label) (gdev-operation-redo-label))))

(defun gdev-close-document ()
  "Chiudi il confronto, la scheda o lo strumento della vista attiva."
  (interactive)
  (if-let* ((control (gdev-comparison-control-at-window)))
      (gdev-comparison-close control)
    (cond ((window-parameter nil 'gdev-layout-auxiliary)
           (gdev-layout-close-auxiliary (current-buffer)))
          ((window-parameter nil 'gdev-layout-panel)
           (gdev-layout--close-panel-tab (current-buffer)))
          ((or (window-parameter nil 'gdev-sidebar)
               (window-parameter nil 'gdev-activity)
               (window-parameter nil 'gdev-layout-commands)
               (window-parameter nil 'gdev-minimap))
           (delete-window))
          ((and (not (window-minibuffer-p))
                (not (window-parameter nil 'window-side))
                (gdev-layout-document-tab-p (current-buffer)))
           (gdev-layout-close-editor-tab (current-buffer)))
          (t (kill-current-buffer)))))

(defun gdev-quit-view (&optional kill window)
  "Esci dalla vista di WINDOW con `q', secondo il riquadro che la mostra.
Nel pannello in basso e nelle viste ausiliarie chiude la vista come la sua
×, con le stesse protezioni per i processi in corso.  In Esplora file,
nelle attività e in Comandi riporta il fuoco all'editor e lascia aperta
la colonna, che si nasconde con la ×.  Altrove esce come `quit-window',
che con KILL chiude il buffer."
  (interactive "P")
  (let ((window (window-normalize-window window t)))
    (cond ((not gdev-layout-mode) (quit-window kill window))
          ((or (window-parameter window 'gdev-layout-panel)
               (window-parameter window 'gdev-layout-auxiliary))
           (select-window window)
           (gdev-close-document))
          ((or (window-parameter window 'gdev-sidebar)
               (window-parameter window 'gdev-activity)
               (window-parameter window 'gdev-layout-commands))
           (gdev-focus-editor))
          (t (quit-window kill window)))))

(defun gdev-close-editor-group (&optional source)
  "Chiude il gruppo editor attivo e torna al più recente."
  (interactive)
  (let ((source (or source (gdev-layout-editor))))
    (unless (memq source (gdev-layout--editors))
      (user-error "Scegli un gruppo di modifica nella finestra attiva"))
    (when (eq source (window-main-window))
      (user-error "Questo è l'ultimo gruppo editor"))
    (delete-window source)
    (gdev-focus-editor)))

(defun gdev-copy-buffer ()
  "Copia l'intero buffer negli appunti di Emacs (kill ring)."
  (interactive)
  (kill-new (buffer-substring-no-properties (point-min) (point-max)))
  (message "Buffer copiato"))

(defun gdev-toggle-maximize-window ()
  "Ingrandisce la finestra selezionata.
Una seconda chiamata ripristina la disposizione precedente."
  (interactive)
  (if gdev-layout-mode
      (gdev-layout-toggle-maximize)
    (if (and (one-window-p) (bound-and-true-p winner-mode))
        (winner-undo)
      (delete-other-windows))))

;;;; Sessioni

(defun gdev--desktop-save ()
  "Salva la sessione con desktop.el."
  (require 'desktop)
  (let ((directory (gdev-state-file "session/")))
    (make-directory directory t)
    (gdev-native-state-desktop directory t)))

(defun gdev--desktop-load ()
  "Ripristina la sessione salvata da `gdev--desktop-save'."
  (require 'desktop)
  (gdev-native-state-desktop (gdev-state-file "session/") nil))

(defvar gdev-session-save-function #'gdev--desktop-save
  "Salva buffer, finestre e schede.
Con ui/workspaces salva invece gli spazi di lavoro (workspace).")
(defvar gdev-session-load-function #'gdev--desktop-load
  "Ripristina ciò che `gdev-session-save-function' ha salvato.")

(defvar gdev-session-hot-exit-function nil
  "Funzione per uscire conservando i documenti in corso.")

(defvar gdev-drafts-hot-exit)

(defvar gdev-session--restarting nil
  "Non nil durante un riavvio con ripristino della sessione.")

(defun gdev-session-save ()
  "Salva la sessione, per ripristinarla in seguito."
  (interactive)
  (funcall gdev-session-save-function)
  (message "Sessione salvata"))

(defun gdev-session-load ()
  "Ripristina l'ultima sessione salvata."
  (interactive)
  (funcall gdev-session-load-function))

(defun gdev-quit (&optional arg)
  "Esci da GDev.  Con ARG salva normalmente i file prima di uscire."
  (interactive "P")
  (if (and gdev-session-hot-exit-function (bound-and-true-p gdev-drafts-hot-exit)
           (not arg) (not (frame-parameter nil 'client)))
      (funcall gdev-session-hot-exit-function nil)
    (save-buffers-kill-terminal arg)))

(defun gdev-quit-without-saving ()
  "Esci da GDev senza salvare, dopo una conferma.
Le modifiche non salvate e le bozze si perdono: la conferma evita
un'uscita con un clic."
  (interactive)
  (when (y-or-n-p "Uscire da GDev senza salvare? Le modifiche non salvate andranno perse. ")
    (let ((gdev-drafts-hot-exit nil))
      (kill-emacs))))

(defun gdev-close-frame ()
  "Chiudi la finestra di Emacs; se è l'ultima esci come con ⌘Q."
  (interactive)
  (if (gdev-quit--other-frame-p (selected-frame))
      (delete-frame)
    (gdev-quit)))

(defun gdev-quit--other-frame-p (frame)
  "Indica se un'altra finestra visibile resta aperta oltre a FRAME."
  (seq-some (lambda (other)
              (and (not (eq other frame))
                   (frame-visible-p other)
                   (not (frame-parent other))
                   (not (frame-parameter other 'delete-before))))
            (frame-list)))

(defun gdev-quit--on-delete-frame (function event)
  "Il pulsante di chiusura dell'ultima finestra esce con `gdev-quit'.
FUNCTION è `handle-delete-frame', che altrimenti chiederebbe di uscire con
il dialogo di Emacs e perderebbe le bozze; EVENT è l'evento di chiusura."
  (if (gdev-quit--other-frame-p (posn-window (event-start event)))
      (funcall function event)
    (gdev-quit)))

(advice-add 'handle-delete-frame :around #'gdev-quit--on-delete-frame)

(defun gdev-restart-and-restore ()
  "Salva la sessione, riavvia Emacs e ripristina la sessione."
  (interactive)
  (if (and gdev-session-hot-exit-function (bound-and-true-p gdev-drafts-hot-exit))
      (funcall gdev-session-hot-exit-function t)
    (let ((gdev-session--restarting t)
          (kill-emacs-hook (copy-sequence kill-emacs-hook)))
      (add-hook 'kill-emacs-hook #'gdev-session--save-for-restart -10)
      (restart-emacs))))

(defun gdev-session--save-for-restart ()
  "Prepara il ripristino dopo la conferma di uscita."
  (gdev-state-db-with (_db t)
    (funcall gdev-session-save-function)
    (gdev-session--mark-restore)))

(defun gdev-session--mark-restore ()
  "Richiedi il ripristino della sessione all'avvio successivo."
  (gdev-state-db-set "applicazione" "" "ripristino_richiesto" (gdev-state-db--print (current-time))))

(defvar desktop-restore-eager)
(defvar desktop-load-locked-desktop)
(setq desktop-restore-eager 8           ; il resto quando Emacs è inattivo
      desktop-load-locked-desktop 'check-pid)

(defun gdev-session--restore-on-start ()
  "Riprendi la sessione salvata, lasciando la richiesta in caso di errore."
  (let* ((flag (gdev-state-file "restore-session-on-start"))
         (request (gdev-state-db-entries "applicazione" "" "ripristino_richiesto")))
    (when (or request (file-exists-p flag))
      (condition-case err
          (progn
            (gdev-session-load)
            (when request
              (gdev-state-db-with (db t)
                (when (equal request (gdev-state-db-entries "applicazione" "" "ripristino_richiesto"))
                  (sqlite-execute db "DELETE FROM impostazione WHERE id_ambito=? AND nome='ripristino_richiesto'"
                                  (list (gdev-state-db--scope db "applicazione" ""))))))
            (when (file-exists-p flag) (delete-file flag)))
        (error (display-warning 'gdev (error-message-string err)))))))

(add-hook 'window-setup-hook #'gdev-session--restore-on-start)

;;;; Aiuto

(autoload 'gdev-doctor "gdev-doctor" "Verifica l'installazione e mostra cosa manca." t)

(defun gdev-cheat-sheet ()
  "Apre in sola lettura il promemoria delle scorciatoie."
  (interactive)
  (view-file (gdev-config-file "docs/keymap.md")))

(defun gdev-emacs-guide ()
  "Apre la guida introduttiva a Emacs in italiano."
  (interactive)
  (view-file (gdev-config-file "docs/emacs.md")))

(defun gdev-emacs-tutorial-italian ()
  "Avvia o riprende l'esercitazione ufficiale di Emacs in italiano."
  (interactive)
  (let* ((current-language-environment "Italian")
         (name (get-language-info current-language-environment 'tutorial))
         (lesson (or (get-buffer name)
                     (save-window-excursion
                       (gdev-focus-editor)
                       (help-with-tutorial)
                       (get-buffer name)))))
    (when lesson
      (gdev-focus-editor)
      (switch-to-buffer lesson))))

(provide 'gdev-commands)
;;; gdev-commands.el ends here
