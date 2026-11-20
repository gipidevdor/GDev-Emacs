;;; gdev-make.el --- Operazioni e metadati dei progetti Make -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Make interpreta regole, include e variabili. GDev legge il database del
;; motore soltanto su richiesta e conserva le scelte separate dai sorgenti.
;; Le viste possono mostrare l'ultima osservazione senza eseguire programmi.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'gdev-lib)
(require 'gdev-compilation)

(declare-function gdev-build--get "config" (key &optional root))
(declare-function gdev-build--put "config" (key value &optional root))
(declare-function gdev-build--jobs "config" ())

(defcustom gdev-make-program "make"
  "Programma Make usato per i progetti che non hanno un profilo esplicito."
  :type 'string :group 'gdev)

(defcustom gdev-make-inspection-timeout 5
  "Secondi massimi per interrogare i metadati di un progetto Make."
  :type 'number :group 'gdev)

(defcustom gdev-make-inspection-max-bytes (* 16 1024 1024)
  "Dimensione massima della risposta usata per il catalogo Make."
  :type 'integer :group 'gdev)

(defvar gdev-make-variables-history nil)

(defun gdev-make--assignment (text)
  "Valida l'assegnamento TEXT senza interpretarne il valore."
  (unless (and (stringp text)
               (not (string-match-p "[\0\n\r]" text))
               (string-match "\\`[A-Za-z_.][A-Za-z0-9_.-]*=" text))
    (user-error "Usa assegnamenti Make NOME=VALORE, uno per argomento"))
  text)

(defun gdev-make--goal (goal)
  "Valida GOAL come obiettivo, conservando spazi e caratteri di shell."
  (when goal
    (unless (and (stringp goal) (not (string-empty-p goal))
                 (not (string-prefix-p "-" goal))
                 (not (string-match-p "[=\0\n\r]" goal)))
      (user-error "Obiettivo Make non valido: %S" goal)))
  goal)

(defun gdev-make-variables (root)
  "Leggi e valida le variabili di Make del progetto ROOT."
  (let ((variables (gdev-build--get :make-variables root)))
    (unless (proper-list-p variables)
      (user-error "Le variabili Make devono essere una lista di NOME=VALORE"))
    (mapcar #'gdev-make--assignment variables)))

(defun gdev-make-command (root action &optional goal)
  "Prepara il comando Make per ACTION in ROOT e l'eventuale GOAL.
Senza un obiettivo di compilazione esplicito decide Make."
  (let* ((target (gdev-make--goal
                  (or goal (pcase action
                             ('build (gdev-build--get :make-target root))
                             ('test "test") ('clean "clean") ('run "run")
                             (_ (user-error "Operazione Make non disponibile: %s" action))))))
         (arguments (append (when (eq action 'build) (list "-j" (gdev-build--jobs)))
                            (gdev-make-variables root) (when target (list "--" target)))))
    (gdev-command-line gdev-make-program arguments)))

(defun gdev-make-configure (root)
  "Modifica gli assegnamenti Make di ROOT senza riscrivere i Makefile."
  (let* ((current (gdev-make-variables root))
         (input (read-string "Variabili Make (NOME=VALORE, vuoto = valori del progetto): "
                             (mapconcat #'gdev-shell-quote current " ")
                             'gdev-make-variables-history))
         (values (condition-case nil (gdev-shell-split input)
                   (end-of-file (user-error "Chiudi le virgolette nei valori Make")))))
    (mapc #'gdev-make--assignment values)
    (gdev-build--put :make-variables values root)
    (message "Make · %s: %d variabili personali; sorgenti del progetto conservati"
             (gdev-project-name root) (length values))))

(defun gdev-make--parse-database ()
  "Leggi il database GNU Make nel buffer corrente.
Le regole stampate da Make sono già espanse. I file prerequisiti che il
motore marca «Not a target» non diventano attività della persona."
  (let ((case-fold-search nil) targets default section skip)
    (goto-char (point-min))
    (unless (re-search-forward "^# GNU Make " nil t)
      (user-error "Il motore non fornisce un database GNU Make; puoi indicare un obiettivo esplicito"))
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
        (cond
         ((string-match "^\\.DEFAULT_GOAL[ \t]*:=[ \t]*\\(.*\\)$" line)
          (setq default (string-trim (match-string 1 line))))
         ((equal line "# Files") (setq section t skip nil))
         ((string-prefix-p "# files hash-table stats:" line) (setq section nil))
         ((and section (equal line "# Not a target:")) (setq skip t))
         ((and section (not (string-empty-p line))
               (not (memq (aref line 0) '(?# ?\t ?\s)))
               (string-match "\\`\\(.+?\\):\\(?::\\)?\\(?:[ \t]\\|$\\)" line))
          (let ((target (match-string 1 line)))
            (unless (or skip (string-prefix-p "." target) (string-match-p "[%=\0]" target))
              (push target targets)))
          (setq skip nil))))
      (forward-line 1))
    (list :default (unless (or (null default) (string-empty-p default)) default)
          :targets (sort (delete-dups targets) #'string<))))

(defun gdev-make--check-output (output errors)
  "Imponi il limite complessivo in byte ai buffer OUTPUT ed ERRORS."
  (when (> (+ (with-current-buffer output (1- (position-bytes (point-max))))
              (with-current-buffer errors (1- (position-bytes (point-max)))))
           gdev-make-inspection-max-bytes)
    (user-error "Catalogo Make troppo grande: usa un obiettivo esplicito")))

(defun gdev-make-inspect (root)
  "Interroga Make in ROOT con limiti di tempo e di dimensione.
Il programma può valutare le espressioni dei Makefile. Questa operazione
è riservata alle richieste esplicite della persona, come la scelta di un
obiettivo; non si usa nell'apertura delle viste o nel ridisegno."
  (let* ((default-directory root)
         (process-environment (cons "LC_ALL=C" process-environment))
         (output (generate-new-buffer " *gdev-make-database*"))
         (errors (generate-new-buffer " *gdev-make-errors*"))
         (deadline (+ (float-time) gdev-make-inspection-timeout))
         child)
    (gdev-build-check-scope (gdev-build-scope root root))
    (unwind-protect
        (progn
          (setq child (make-process
                       :name "gdev-make-inspect" :buffer output :stderr errors
                       :command (append (list gdev-make-program "-qp" "--no-print-directory")
                                        (gdev-make-variables root))
                       :connection-type 'pipe :coding 'utf-8-unix :noquery t
                       :file-handler t :sentinel #'ignore))
          (when (process-live-p child) (ignore-errors (process-send-eof child)))
          (while (process-live-p child)
            (accept-process-output child 0.02)
            (gdev-make--check-output output errors)
            (when (> (float-time) deadline)
              (user-error "Make non ha risposto in tempo: usa un obiettivo esplicito")))
          (gdev-make--check-output output errors)
          (unless (and (eq (process-status child) 'exit) (memq (process-exit-status child) '(0 1)))
            (user-error "Impossibile leggere Make: %s"
                        (with-current-buffer errors (string-trim (buffer-string)))))
          (with-current-buffer output (gdev-make--parse-database)))
      (when (process-live-p child) (delete-process child))
      (kill-buffer output)
      (kill-buffer errors))))

(provide 'gdev-make)
;;; gdev-make.el ends here
