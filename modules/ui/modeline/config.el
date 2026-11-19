;;; config.el --- :ui modeline: barra di stato essenziale -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Una barra di stato asciutta.  A sinistra lo stato del file e
;; il suo nome; a destra, in grigio, solo ciò che serve in quel momento:
;;
;;   ● main.cpp  @web1                 ✕ 2 ▲ 1  ⎇ main  12:4  c++
;;
;;   ●        modifiche non salvate (◌ sola lettura)
;;   @nome    il file è su una macchina remota
;;   ✕ ▲ ✓    errori, avvisi, oppure tutto a posto: le segnalazioni di Flymake
;;   ⎇        ramo Git
;;   reg      si sta registrando una macro
;;
;; Col mouse: clic sul nome per cambiare area di testo, sulle
;; segnalazioni per l'elenco degli errori, sul ramo per lo stato Git, sul
;; linguaggio per il suo menu. L'icona Git viene preparata al primo uso:
;; si calcola in microsecondi a ogni ridisegno.  Nelle finestre non
;; selezionate resta solo il nome.
;;
;; Disattivando il modulo resta la barra di stato di Emacs, già sfoltita
;; dal nucleo.

;;; Code:

(require 'gdev-lib)
(require 'gdev-ui)

(declare-function flymake-show-buffer-diagnostics "flymake")
(declare-function eglot-managed-p "eglot")
(declare-function gdev-git-status "gdev-commands")
(declare-function gdev-assurance-show-active "gdev-assurance-workbench" ())
(declare-function gdev-system-monitor-segment "../system-monitor/config")
(defvar flymake-mode)
(defvar flymake-suppress-zero-counters)

;;;; Facce (faces)

(defgroup gdev-modeline nil
  "La barra di stato (mode line)."
  :group 'gdev)

(defface gdev-modeline-dim '((t :inherit gdev-ui-secondary))
  "Informazioni secondarie, a destra.")

(defface gdev-modeline-name '((t :weight bold))
  "Nome dell'area di testo.")

(defface gdev-modeline-modified '((t :inherit warning))
  "Indicatore di modifiche non salvate.")

(defface gdev-modeline-error '((t :inherit error))
  "Numero di errori.")

(defface gdev-modeline-warning '((t :inherit warning))
  "Numero di avvisi.")

(defface gdev-modeline-accent '((t :inherit success))
  "Host remoto, tutto a posto.")

;;;; Clic

(defvar gdev-modeline--mouse-maps (make-hash-table :test #'eq)
  "Mappe dei comandi cliccabili, riusate a ogni ridisegno.")

(defun gdev-modeline--clickable (text help command)
  "Restituisce TEXT che esegue COMMAND al clic, con il suggerimento HELP."
  (propertize text
              'help-echo help
              'mouse-face 'mode-line-highlight
              'keymap (or (gethash command gdev-modeline--mouse-maps)
                          (puthash command (make-mode-line-mouse-map 'mouse-1 command)
                                   gdev-modeline--mouse-maps))))

(defun gdev-modeline-switch-buffer ()
  "Sceglie un'area di testo (dal clic sul nome)."
  (interactive)
  (call-interactively (if (fboundp 'consult-buffer) #'consult-buffer #'switch-to-buffer)))

(defun gdev-modeline-show-diagnostics ()
  "Apri il pannello Problemi dal contatore delle segnalazioni."
  (interactive)
  (if (fboundp 'gdev-checkers-problems)
      (gdev-checkers-problems)
    (flymake-show-buffer-diagnostics)))

(define-obsolete-function-alias 'gdev-modeline-vc-status #'gdev-git-status "2026-11")

;;;; Segmenti

(defun gdev-modeline--state ()
  "● se ci sono modifiche non salvate, ◌ se l'area di testo è in sola lettura."
  (cond ((and buffer-file-name (buffer-modified-p))
         (propertize "● " 'face 'gdev-modeline-modified 'help-echo "modifiche non salvate"))
        (buffer-read-only
         (propertize "◌ " 'face 'gdev-modeline-dim 'help-echo "sola lettura"))
        (t "  ")))

(defun gdev-modeline--name (selected)
  "Nome dell'area di testo; in grassetto se SELECTED."
  (gdev-modeline--clickable
   (propertize (gdev-ui-buffer-name) 'face (if selected 'gdev-modeline-name 'gdev-modeline-dim))
   (or buffer-file-truename "Scegli un’area di testo") #'gdev-modeline-switch-buffer))

(defun gdev-modeline--remote ()
  "@host se il file è remoto."
  (when-let* ((host (file-remote-p default-directory 'host)))
    (propertize (concat "  @" host) 'face 'gdev-modeline-accent
                'help-echo (concat "Host della directory remota " host))))

(defun gdev-modeline--flags ()
  "Registrazione di una macro e vista ristretta (narrow)."
  (concat (when defining-kbd-macro
            (propertize "  reg" 'face 'gdev-modeline-error 'help-echo "registrazione di una macro"))
          (when (buffer-narrowed-p)
            (propertize "  ristretto" 'face 'gdev-modeline-dim
                        'help-echo "Vista ristretta. C-x n w ripristina il documento intero"))))

(defun gdev-modeline--diagnostic-count (counter icon face singular plural)
  "Mostra COUNTER in FACE, con ICON e il livello SINGULAR o PLURAL."
  (let ((count (string-trim (format-mode-line counter 0))))
    (unless (string-empty-p count)
      (gdev-modeline--clickable
       (propertize (concat icon " " count) 'face face)
       (format "%s %s nel documento · Apri Problemi"
               count (if (equal count "1") singular plural))
       #'gdev-modeline-show-diagnostics))))

(defun gdev-modeline--diagnostics ()
  "Mostra le segnalazioni Flymake per livello o un segno di spunta."
  (when (bound-and-true-p flymake-mode)
    (let* ((flymake-suppress-zero-counters t)
           (counts (gdev-modeline--join
                    (gdev-modeline--diagnostic-count 'flymake-mode-line-error-counter
                                                    "✕" 'gdev-modeline-error "errore" "errori")
                    (gdev-modeline--diagnostic-count 'flymake-mode-line-warning-counter
                                                    "▲" 'gdev-modeline-warning "avviso" "avvisi")
                    (gdev-modeline--diagnostic-count 'flymake-mode-line-note-counter
                                                    "ⓘ" 'gdev-modeline-dim "nota" "note"))))
      (if (string-empty-p counts)
          (gdev-modeline--clickable (propertize "✓" 'face 'gdev-modeline-accent)
                                   "Nessuna segnalazione rilevata · Apri Problemi"
                                   #'gdev-modeline-show-diagnostics)
        counts))))

(defconst gdev-modeline--lsp-activity
  '(eglot-mode-line-error eglot-mode-line-pending-requests
    eglot-mode-line-progress eglot-mode-line-action-suggestion)
  "Parti di Eglot mostrate accanto a LSP: errori, richieste, avanzamento e azioni.")

(defun gdev-modeline--lsp-summary-p ()
  "Indica che la voce LSP riassume l'attività di Eglot.
Eglot 1.19 e successivi espongono le singole parti della propria voce."
  (boundp 'eglot-mode-line-format))

(defun gdev-modeline--lsp-activity ()
  "Errori, richieste in corso, avanzamento e azioni del server di linguaggio."
  (when (and (gdev-modeline--lsp-summary-p) (fboundp 'eglot-managed-p) (eglot-managed-p))
    (string-join (seq-remove #'string-empty-p
                             (mapcar (lambda (part) (string-trim (format-mode-line part)))
                                     gdev-modeline--lsp-activity))
                 " ")))

(defun gdev-modeline--misc-info ()
  "Restituisci `mode-line-misc-info' senza la voce che LSP già riassume."
  (if (gdev-modeline--lsp-summary-p)
      (seq-remove (lambda (entry) (eq (car-safe entry) 'eglot--managed-mode))
                  mode-line-misc-info)
    mode-line-misc-info))

(defun gdev-modeline--language-tools ()
  "Mostra la connessione al server di linguaggio e il rientro del codice."
  (let ((wide (and (derived-mode-p 'prog-mode) (>= (window-total-width) 90))))
    (gdev-modeline--join
     (when (and wide (fboundp 'eglot-managed-p) (eglot-managed-p))
       (propertize "LSP" 'face 'gdev-modeline-dim
                   'help-echo "Server di linguaggio connesso\nClic per il menu del server"
                   'mouse-face 'mode-line-highlight
                   'keymap (bound-and-true-p eglot--server-menu-map)))
     ;; L'attività del server segue LSP e resta visibile anche nelle finestre strette.
     (gdev-modeline--lsp-activity)
     (when wide
       (propertize (if indent-tabs-mode (format "Tab %d" tab-width) "Spazi")
                   'face 'gdev-modeline-dim 'help-echo "Caratteri usati per il rientro")))))

(defun gdev-modeline--branch ()
  "Ramo Git del file, senza il nome del sistema di versione."
  (when (and vc-mode buffer-file-name)
    (let ((branch (replace-regexp-in-string "\\` *[A-Za-z]+[-:@!?]" ""
                                            (substring-no-properties vc-mode))))
      (gdev-modeline--clickable
       (propertize (concat (gdev-ui-icon "git" "⎇" nil 'gdev-modeline-dim) " " branch)
                   'face 'gdev-modeline-dim)
       "Apri il controllo di versione del progetto" #'gdev-git-status))))

(defun gdev-modeline--assurance ()
  "Mostra l'identità della transazione senza leggere l'archivio al ridisegno."
  (when (and (commandp 'gdev-assurance-show-active) (fboundp 'gdev-workspace-state-get))
    (when-let* ((active (gdev-workspace-state-get 'gdev-assurance-transaction)))
      (gdev-modeline--clickable (propertize (plist-get active :id) 'face 'gdev-modeline-dim)
                              "Transazione attiva · Apri Assicurazione" #'gdev-assurance-show-active))))

(defun gdev-modeline--position ()
  "Riga:colonna, oppure le dimensioni della selezione."
  (if (use-region-p)
      (let ((lines (count-lines (region-beginning) (region-end))))
        (propertize (format "%d %s, %d car." lines (if (= lines 1) "riga" "righe")
                            (- (region-end) (region-beginning)))
                    'face 'gdev-modeline-dim 'help-echo "Righe e caratteri della selezione"))
    (propertize (format-mode-line "%l:%c")
                'face 'gdev-modeline-dim 'help-echo "Riga e colonna del cursore")))

(defun gdev-modeline--encoding ()
  "Codifica e fine riga, solo se diverse da UTF-8 e LF."
  (let* ((coding buffer-file-coding-system)
         (base (coding-system-base coding))
         (eol (coding-system-eol-type coding)))
    (concat (unless (memq base '(utf-8 utf-8-unix prefer-utf-8 undecided no-conversion))
              (propertize (downcase (symbol-name base))
                          'face 'gdev-modeline-dim 'help-echo "Codifica del testo"))
            (pcase eol
              (1 (propertize " crlf" 'face 'gdev-modeline-dim
                             'help-echo "Fine riga CRLF (Windows)"))
              (2 (propertize " cr" 'face 'gdev-modeline-dim
                             'help-echo "Fine riga CR"))))))

(defun gdev-modeline--mode ()
  "Nome della modalità principale, con accesso al suo menu."
  (propertize (gdev-ui-mode-label)
              'face 'gdev-modeline-dim
              'help-echo "Apri il menu della modalità corrente"
              'mouse-face 'mode-line-highlight
              'keymap mode-line-major-mode-keymap))

;;;; La barra

(defun gdev-modeline--join (&rest segments)
  "Unisce i SEGMENTS non vuoti con due spazi."
  (string-join (cl-remove-if (lambda (segment) (or (null segment) (string-empty-p segment)))
                             segments)
               "  "))

(defun gdev-modeline--left ()
  "Parte sinistra."
  (let ((selected (mode-line-window-selected-p)))
    (concat " " (if selected (gdev-modeline--state) "  ")
            (gdev-modeline--name selected)
            (when selected (concat (gdev-modeline--remote) (gdev-modeline--flags))))))

(defun gdev-modeline--right ()
  "Parte destra, solo nella finestra selezionata."
  (when (mode-line-window-selected-p)
    (concat (gdev-modeline--join (string-trim (format-mode-line mode-line-process))
                                 (string-trim (format-mode-line (gdev-modeline--misc-info)))
                                 (gdev-modeline--diagnostics)
                                 (gdev-modeline--branch)
                                 (gdev-modeline--assurance)
                                 (gdev-modeline--position)
                                 (gdev-modeline--encoding)
                                 (gdev-modeline--language-tools)
                                 (gdev-modeline--mode)
                                 (when (fboundp 'gdev-system-monitor-segment)
                                   (gdev-system-monitor-segment)))
            "  ")))

(defvar gdev-modeline-format
  '((:eval (gdev-modeline--literal (gdev-modeline--left)))
    mode-line-format-right-align
    (:eval (gdev-modeline--literal (gdev-modeline--right))))
  "La barra di stato di GDev-Emacs.")

(defun gdev-modeline--literal (text)
  "Protegge i caratteri percento di TEXT dalle direttive della barra."
  (when text
    (replace-regexp-in-string
     "%" (lambda (percent) (concat percent percent)) text t t)))

(defun gdev-modeline-setup ()
  "Usa la barra di GDev-Emacs in ogni area di testo."
  (setq mode-line-right-align-edge 'right-fringe)
  (setq-default mode-line-format gdev-modeline-format))

(gdev-modeline-setup)

;;; config.el ends here
