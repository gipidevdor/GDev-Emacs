;;; config.el --- :tools git: stato, richieste di integrazione e differenze -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;;   C-c g g  C-x g    stato del repository in Hit: prepara
;;                     i blocchi con s, registra le modifiche con c c.
;;                     In alto ramo, modifiche e azioni frequenti;
;;                     l'azione evidenziata segue lo stato dell'archivio
;;   C-c g d / f       tutti i comandi di Hit / i comandi su questo file
;;   Hit > Guida di Hit  manuale in italiano, disponibile anche in Info
;;   C-c g B           autori riga per riga, senza lasciare l'area
;;                     di testo
;;   C-c g L           cronologia di questo file
;;   C-c g F           Forge: richieste di integrazione e
;;                     segnalazioni dentro Hit
;;   C-c g D           differenze strutturali (difftastic) della modifica
;;                     sotto il cursore
;;   C-c p l           elenco dei TODO/FIXME dell'archivio Git
;;
;; Forge richiede una chiave d'accesso di GitHub, salvata una
;; volta sola nel Portachiavi:
;;   security add-internet-password -a "UTENTE^forge" -s api.github.com -w
;; `git commit' digitato in un interprete dei comandi locale di GDev apre il
;; messaggio in questo Emacs.
;; Il Convertitore regex GDev (pcre2el), usato dai Promemoria di Hit,
;; mantiene le espressioni PCRE e i flag del minibuffer nel fork locale.

;;; Code:

(require 'gdev-lib)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'button)
(require 'cl-lib)
(require 'map)

(require 'gdev-keys)

(declare-function magit-git-lines "magit-git" (&rest args))
(declare-function magit-refresh-buffer "magit-mode" (&rest args))

(eval-and-compile
  ;; Il quickstart può ancora conoscere una vecchia installazione ELPA.
  (dolist (name '(magit magit-section))
    (let ((directory (gdev-bundled-package-directory name)))
      (setq load-path (cons directory (delete directory load-path))))))

;; Le dipendenze del fork vengono conservate da gdev sync.
(use-package compat :ensure t)
(use-package cond-let :ensure t)
(use-package llama :ensure t)
(use-package seq :ensure t)
(use-package transient :ensure t)

(declare-function magit-display-buffer-same-window-except-diff-v1 "magit-mode")
(declare-function magit-restore-window-configuration "magit-mode")
;; Serve alla macro di with-editor, che la espande: nessun uso esplicito.
(declare-function with-editor--setup "with-editor" ())
(declare-function gdev-merge-conflict-file "../../ui/workbench/gdev-merge" (file))
(defvar magit-ediff-preview-conflicts-function)
(defvar with-editor-previous-winconf)

(with-eval-after-load 'magit-ediff
  (when (gdev-module-p :ui 'workbench)
    (autoload 'gdev-merge-conflict-file "gdev-merge")
    (setq magit-ediff-preview-conflicts-function #'gdev-merge-conflict-file)))

(defun gdev-git--display-buffer (buffer)
  "Mostra BUFFER secondo le regole dei riquadri attive."
  (if gdev-layout-mode
      (display-buffer buffer)
    (magit-display-buffer-same-window-except-diff-v1 buffer)))

(defun gdev-git--bury-buffer (kill-buffer)
  "Chiude la vista di Hit corrente, eliminandone l'area di testo con KILL-BUFFER."
  (if gdev-layout-mode
      (quit-window kill-buffer)
    (magit-restore-window-configuration kill-buffer)))

(defun gdev-git--keep-layout-after-edit ()
  "Conserva la disposizione corrente quando si conclude una modifica Git."
  (when gdev-layout-mode
    (setq with-editor-previous-winconf nil)))

(defun gdev-git--restore-layout (restore configuration)
  "Delega a RESTORE il ripristino di CONFIGURATION fuori dal layout gestito."
  (unless gdev-layout-mode
    (funcall restore configuration)))

;;;; Nomi dei comandi

(defconst gdev-git--command-labels
  '((magit-dispatch . "Comandi di Hit")
    (magit-file-dispatch . "Comandi di Hit sul file")
    (magit-edit-thing . "Modifica l'elemento")
    (magit-browse-thing . "Apri l'elemento nel navigatore")
    (magit-copy-thing . "Copia l'elemento")
    (magit-copy-buffer-revision . "Copia la revisione mostrata")
    (magit-next-reference . "Riferimento successivo")
    (magit-previous-reference . "Riferimento precedente")
    (magit-go-backward . "Vista precedente")
    (magit-go-forward . "Vista successiva")
    (magit-section-forward-sibling . "Sezione successiva, stesso livello")
    (magit-section-backward-sibling . "Sezione precedente, stesso livello")
    (magit-section-show-level-1-all . "Tutte le sezioni al livello 1")
    (magit-section-show-level-2-all . "Tutte le sezioni al livello 2")
    (magit-section-show-level-3-all . "Tutte le sezioni al livello 3")
    (magit-section-show-level-4-all . "Tutte le sezioni al livello 4")
    (magit-add-change-log-entry . "Voce nel ChangeLog")
    (magit-add-change-log-entry-other-window . "Voce nel ChangeLog, altro riquadro")
    (magit-diff-edit-hunk-commit . "Modifica il commit del blocco")
    (magit-diff-trace-definition . "Cronologia della definizione")
    (magit-diff-visit-file-other-window . "Apri il file in un altro riquadro")
    (magit-diff-visit-file-other-frame . "Apri il file in un'altra finestra")
    (magit-diff-while-committing . "Differenze del commit in corso")
    (magit-dired-jump . "Apri la cartella del file")
    (magit-log-move-to-parent . "Vai al commit padre"))
  "Etichette dei comandi di Hit mostrati senza menu, come in which-key.")

;; which-key e i menu mostrano «Hit» e queste etichette, mai il nome del fork;
;; in M-x i comandi si chiamano hit-…
(gdev-keys-register-commands "magit-" "Hit" :labels gdev-git--command-labels :alias "hit-")

(defun gdev-git--summary (lines)
  "Riassume LINES, l'uscita di git status --porcelain=v2 --branch.
Restituisce una lista di proprietà con :branch, :upstream, :ahead,
:behind, :staged, :unstaged, :untracked e :conflicts."
  (let ((summary (list :ahead 0 :behind 0 :staged 0 :unstaged 0 :untracked 0 :conflicts 0)))
    (dolist (line lines)
      (cond
       ((string-prefix-p "# branch.head " line)
        (let ((branch (substring line 14)))
          (setq summary (plist-put summary :branch (unless (equal branch "(detached)") branch)))))
       ((string-prefix-p "# branch.upstream " line)
        (setq summary (plist-put summary :upstream (substring line 18))))
       ((string-match "\\`# branch\\.ab \\+\\([0-9]+\\) -\\([0-9]+\\)" line)
        (setq summary (plist-put summary :ahead (string-to-number (match-string 1 line))))
        (setq summary (plist-put summary :behind (string-to-number (match-string 2 line)))))
       ((string-match "\\`[12] \\(.\\)\\(.\\) " line)
        (unless (equal (match-string 1 line) ".")
          (cl-incf (plist-get summary :staged)))
        (unless (equal (match-string 2 line) ".")
          (cl-incf (plist-get summary :unstaged))))
       ((string-prefix-p "u " line) (cl-incf (plist-get summary :conflicts)))
       ((string-prefix-p "? " line) (cl-incf (plist-get summary :untracked)))))
    summary))

(defun gdev-git--count (count one many)
  "Descrive COUNT con ONE al singolare o con il formato MANY."
  (if (= count 1) one (format many count)))

(defun gdev-git--badges (summary)
  "Restituisce gli stati da mostrare per SUMMARY, ciascuno con icona e testo."
  (pcase-let (((map :ahead :behind :staged :unstaged :untracked :conflicts) summary))
    (or (delq nil
              (list (when (> conflicts 0)
                      (list "status-failure" 'gdev-ui-status-error
                            (gdev-git--count conflicts "1 conflitto" "%d conflitti")))
                    (when (> staged 0)
                      (list "status-success" 'gdev-ui-status-success
                            (gdev-git--count staged "1 nell'indice" "%d nell'indice")))
                    (when (> unstaged 0)
                      (list "git-diff" 'gdev-ui-status-warning
                            (gdev-git--count unstaged "1 da preparare" "%d da preparare")))
                    (when (> untracked 0)
                      (list "file" 'gdev-ui-secondary
                            (gdev-git--count untracked "1 non tracciato" "%d non tracciati")))
                    (when (> ahead 0)
                      (list "push" 'gdev-ui-action
                            (gdev-git--count ahead "1 da inviare" "%d da inviare")))
                    (when (> behind 0)
                      (list "pull" 'gdev-ui-action
                            (gdev-git--count behind "1 da scaricare" "%d da scaricare")))))
        (list (list "status-success" 'gdev-ui-status-success "Albero di lavoro pulito")))))

(defun gdev-git--actions (summary)
  "Azioni dell'intestazione di Hit, con la principale scelta da SUMMARY."
  (pcase-let* (((map :ahead :behind :staged) summary)
               (primary (cond ((> staged 0) 'commit) ((> ahead 0) 'push) ((> behind 0) 'pull))))
    (delq nil
          (list (list "git-commit" "●" "Registra" #'magit-commit :primary (eq primary 'commit)
                      :help "Registra le modifiche nell'indice (commit) · c")
                (list "push" "↑" "Invia" #'magit-push :primary (eq primary 'push)
                      :help "Invia le registrazioni al ramo remoto · P")
                (list "pull" "↓" "Scarica" #'magit-pull :primary (eq primary 'pull)
                      :help "Scarica e integra le modifiche remote · F")
                (list "git-diff" "±" "Differenze" #'magit-diff :help "Differenze · d")
                (list "git-history" "↶" "Cronologia" #'magit-log :help "Cronologia · l")
                (list "git" "⑂" "Rami" #'magit-branch :help "Rami · b")
                (when (fboundp 'gdev-github-overview)
                  (list "repository" "▣" "HitHub" #'gdev-github-overview
                        :help "Richieste, segnalazioni ed esecuzioni su GitHub · C-c g h h"))))))

(defvar-local gdev-git--header nil
  "Riassunto e larghezza in pixel dell'intestazione mostrata: (SUMMARY . WIDTH).")

(defun gdev-git--header-width ()
  "Larghezza in pixel disponibile per l'intestazione di Hit.
Prima della comparsa usa l'editor, dove lo stato si aprirà."
  (or (gdev-ui-buffer-pixel-width)
      (let ((window (and (bound-and-true-p gdev-layout-mode) (gdev-layout-editor))))
        (and (window-live-p window) (window-body-width window t)))
      (* 80 (frame-char-width))))

(defun gdev-git--insert-header-text (summary width)
  "Inserisce l'intestazione di Hit per SUMMARY disposta in WIDTH pixel."
  (let* ((branch (plist-get summary :branch))
         (upstream (plist-get summary :upstream))
         (gap (gdev-ui-string-pixel-width "   "))
         (fit (lambda (text help)
                ;; Un nome troppo lungo si accorcia e resta intero nel suggerimento.
                (if (<= (gdev-ui-string-pixel-width text) width) text
                  (propertize (gdev-ui-fit-text text width #'gdev-ui-string-pixel-width)
                              'help-echo help))))
         (used 0))
    (insert (funcall fit
                     (concat (gdev-ui-icon "git" "⑂" nil 'gdev-ui-view-title) " "
                             (propertize (file-name-nondirectory (directory-file-name default-directory))
                                         'face 'gdev-ui-view-title
                                         'help-echo (abbreviate-file-name default-directory)))
                     (abbreviate-file-name default-directory))
            "\n")
    (dolist (badge (cons (list "git" 'gdev-ui-secondary
                               (cond ((and branch upstream) (format "%s → %s" branch upstream))
                                     (branch (format "%s · senza ramo remoto" branch))
                                     (t "Testa staccata (detached HEAD)")))
                         (gdev-git--badges summary)))
      (let* ((text (funcall fit (apply #'gdev-ui-badge (car badge) "•" (cdr badge)) (nth 2 badge)))
             (size (gdev-ui-string-pixel-width text)))
        (cond ((zerop used))
              ((> (+ used gap size) width) (insert "\n") (setq used 0))
              (t (insert "   ") (setq used (+ used gap))))
        (insert text)
        (setq used (+ used size))))
    (insert "\n\n")
    (gdev-ui-insert-actions (gdev-git--actions summary) width)
    (insert "\n")))

(defun gdev-git--insert-header ()
  "Mostra in cima allo stato di Hit archivio, ramo, modifiche e azioni."
  (let ((summary (gdev-git--summary (magit-git-lines "status" "--porcelain=v2" "--branch")))
        (width (gdev-git--header-width))
        (start (point)))
    (gdev-git--insert-header-text summary width)
    (put-text-property start (point) 'gdev-git-header t)
    (setq gdev-git--header (cons summary width))))

(defun gdev-git--rewrap-header (window)
  "Ridispone l'intestazione di Hit quando cambia la larghezza di WINDOW.
Usa la finestra più stretta che mostra lo stato e il riassunto già letto,
quindi non esegue git."
  (with-current-buffer (window-buffer window)
    (pcase-let ((`(,summary . ,width) gdev-git--header)
                (current (gdev-git--header-width)))
      (when-let* (((and summary (/= width current)))
                  (start (text-property-any (point-min) (point-max) 'gdev-git-header t))
                  (end (or (next-single-property-change start 'gdev-git-header) (point-max))))
        (let ((inhibit-read-only t)
              (buffer-undo-list t)
              (section (get-text-property start 'magit-section)))
          (save-excursion
            ;; Il nuovo testo entra prima del vecchio: i segni delle sezioni
            ;; che seguono restano dopo l'intestazione.
            (goto-char start)
            (gdev-git--insert-header-text summary current)
            (add-text-properties start (point) (list 'gdev-git-header t 'magit-section section))
            (delete-region (point) (+ (point) (- end start)))))
        (setq gdev-git--header (cons summary current))))))

(defvar-local gdev-git--theme-stale nil
  "Non nil se il tema è cambiato mentre questo stato di Hit non era visibile.")

(defun gdev-git--refresh-stale (buffer)
  "Ridisegna lo stato di Hit in BUFFER se il tema è cambiato in sua assenza."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when gdev-git--theme-stale
        (setq gdev-git--theme-stale nil)
        ;; Una cartella sparita non deve produrre un errore a ogni visita.
        (with-demoted-errors "Hit: %S"
          (magit-refresh-buffer))))))

(defun gdev-git--on-display (&optional _window)
  "Quando lo stato di Hit torna visibile, ridisegna le icone se il tema è cambiato."
  (when gdev-git--theme-stale
    (run-at-time 0 nil #'gdev-git--refresh-stale (current-buffer))))

(defun gdev-git--follow-width ()
  "Collega l'intestazione di Hit alla larghezza della finestra che la mostra."
  (add-hook 'window-size-change-functions #'gdev-git--rewrap-header nil t)
  (add-hook 'window-buffer-change-functions #'gdev-git--rewrap-header nil t)
  (add-hook 'window-buffer-change-functions #'gdev-git--on-display nil t))

(add-hook 'magit-status-mode-hook #'gdev-git--follow-width)

(defun gdev-git--refresh-after-theme ()
  "Ridisegna gli stati di Hit visibili, perché le icone seguano il tema.
Gli altri si ridisegnano quando tornano visibili."
  (let ((visible (delete-dups (mapcar #'window-buffer (window-list-1 nil 'nomini t)))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'magit-status-mode)
          (if (memq buffer visible)
              ;; Una cartella sparita non deve fermare il cambio di tema.
              (with-demoted-errors "Hit: %S"
                (magit-refresh-buffer))
            (setq gdev-git--theme-stale t)))))))

(add-hook 'gdev-ui-after-theme-hook #'gdev-git--refresh-after-theme)

(defun gdev-git--style-headings ()
  "Usa il carattere dell'interfaccia per i titoli delle sezioni di Hit."
  (face-remap-add-relative 'magit-section-heading
                           '(:inherit (variable-pitch gdev-ui-view-heading))))

(dolist (hook '(magit-status-mode-hook magit-refs-mode-hook magit-repolist-mode-hook
                git-commit-setup-hook git-rebase-mode-hook
                forge-topic-mode-hook forge-topics-mode-hook
                forge-repository-list-mode-hook forge-post-mode-hook))
  (add-hook hook #'gdev-layout-mark-document))

(gdev-set-popup-rule '(derived-mode . (magit-diff-mode magit-log-mode magit-shortlog-mode
                                       magit-cherry-mode magit-reflog-mode
                                       magit-process-mode difftastic-mode)))

(use-package magit
  :ensure t
  :commands (magit-status magit-status-here magit-dispatch magit-file-dispatch magit-info magit-blame-addition
             magit-diff magit-log magit-commit
             magit-log-buffer-file magit-clone magit-init magit-stage-file
             magit-unstage-file magit-branch-checkout magit-commit-create magit-fetch)
  :custom
  (magit-display-buffer-function #'gdev-git--display-buffer)
  (magit-bury-buffer-function #'gdev-git--bury-buffer)
  (magit-save-repository-buffers nil)
  ;; Evidenzia le singole parole cambiate in ogni blocco modificato.
  (magit-diff-refine-hunk 'all)
  (magit-diff-refine-ignore-whitespace t)
  ;; I repository sotto queste radici compaiono in magit-list-repositories.
  (magit-repository-directories '(("~/Documents" . 1)))
  ;; Repository remoti via TRAMP: un pty tiene in vita le domande di git.
  (magit-tramp-pipe-stty-settings 'pty)
  :config
  (add-hook 'magit-status-sections-hook #'gdev-git--insert-header -25)
  (add-hook 'magit-mode-hook #'gdev-git--style-headings)
  (setq git-commit-summary-max-length 72
        git-commit-style-convention-checks '(non-empty-second-line overlong-summary-line)))

(keymap-global-set "C-x g" #'gdev-git-status)
(declare-function gdev-git-status "gdev-commands")
(defalias 'hit-status #'gdev-git-status)
(defalias 'hit-comandi #'magit-dispatch)
(defalias 'hit-comandi-file #'magit-file-dispatch)
(defalias 'hit-guida #'magit-info)

(defvar magit-commit-restore-window-configuration-function)
(with-eval-after-load 'magit-commit
  (setq magit-commit-restore-window-configuration-function
        (apply-partially #'gdev-git--restore-layout #'set-window-configuration)))

(use-package with-editor
  :ensure t
  :hook ((eshell-mode . with-editor-export-editor)
         ((with-editor-pre-finish with-editor-pre-cancel) . gdev-git--keep-layout-after-edit)))

(eval-when-compile (require 'with-editor))

(defun gdev-git--local-terminal-editor (open &rest args)
  "Usa Emacs come editor del terminale locale avviato da OPEN con ARGS."
  (if (and (not (file-remote-p default-directory))
           (require 'with-editor nil t)
           with-editor-emacsclient-executable)
      (with-editor (apply open args))
    (apply open args)))

(defun gdev-git--terminal-editor (open &optional program arg)
  "Configura l'editor della shell predefinita avviata da OPEN con PROGRAM e ARG."
  (if program
      (funcall open program arg)
    (gdev-git--local-terminal-editor open program arg)))

(with-eval-after-load 'eat
  (advice-add 'eat-other-window :around #'gdev-git--terminal-editor))

(advice-add 'gdev-term--make-profile-session :around #'gdev-git--local-terminal-editor)

(use-package forge
  :ensure t
  :after magit
  :commands forge-dispatch
  :custom (forge-database-file (gdev-state-file "forge-database.sqlite")))

(defvar transient--prefix)
(defvar transient-force-single-column)
(defvar-local gdev-git--forge-truncation nil)

(defun gdev-git--layout-forge-menu (insert-menu setup)
  "Adatta ogni ridisegno di una tavolozza Forge alla finestra di origine."
  (let* ((compact (and (< (frame-width) 132)
                       (string-prefix-p "forge-" (symbol-name (oref transient--prefix command)))))
         (transient-force-single-column (or transient-force-single-column compact)))
    (cond (compact
           (unless gdev-git--forge-truncation
             (setq gdev-git--forge-truncation (cons (local-variable-p 'truncate-lines) truncate-lines)))
           (setq-local truncate-lines nil))
          (gdev-git--forge-truncation
           (if (car gdev-git--forge-truncation)
               (setq-local truncate-lines (cdr gdev-git--forge-truncation))
             (kill-local-variable 'truncate-lines))
           (setq gdev-git--forge-truncation nil)))
    (funcall insert-menu setup)))

(with-eval-after-load 'forge-commands
  ;; Il buffer di Transient può essere riutilizzato durante i passaggi di menu.
  (advice-add 'transient--insert-menu :around #'gdev-git--layout-forge-menu))

(with-eval-after-load 'forge-post
  (advice-add 'forge--maybe-restore-winconf :around #'gdev-git--restore-layout))

(use-package magit-todos
  :ensure t
  :commands magit-todos-list
  :custom (magit-todos-exclude-globs '(".git/" "build*/" "node_modules/" "*.min.js")))

;; Differenze sull'albero sintattico: codice spostato o riformattato non è
;; rumore.
(use-package difftastic
  :if (gdev-find-executable "difft")
  :ensure t
  :commands (difftastic-magit-diff difftastic-magit-show difftastic-dired-diff)
  :config
  (with-eval-after-load 'magit-diff
    (transient-append-suffix 'magit-diff '(-1 -1)
      [("D" "Differenze strutturali (difftastic)" difftastic-magit-diff)
       ("S" "Mostra con difftastic" difftastic-magit-show)])))

;;; config.el ends here
