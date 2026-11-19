;;; gdev-language-modes.el --- Scelta della modalità dei documenti -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Sceglie Tree-sitter durante l'apertura quando esiste un modo classico
;; utilizzabile per lo stesso linguaggio.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(defconst gdev-language--common-commands
  '(("b" "Compila" gdev-build :build-root)
    ("t" "Esegui i test" gdev-test-dwim :test)
    ("r" "Esegui" gdev-run-dwim :run)
    ("f" "Formatta" gdev-format-dwim :format)
    ("e" "Valuta il codice" gdev-eval-dwim :eval)
    ("z" "Apri interprete" gdev-open-repl :repl))
  "Azioni comuni risolte dalle capacità effettive del documento.")

(defun gdev-language-install-command-map ()
  "Rendi disponibili menu, Comandi e C-c l per le capacità del documento.
Conserva i prefissi personali. Una mappa locale leggera eredita le altre
scorciatoie dalla modalità, senza copiare né modificare la sua mappa."
  (when (and (current-local-map) (not (keymapp (key-binding (kbd "C-c l")))))
    (let ((commands (make-sparse-keymap)) (local (make-sparse-keymap)) available)
      (pcase-dolist (`(,key ,label ,command ,kind) gdev-language--common-commands)
        (when (and (gdev-handler kind) (commandp command))
          (setq available t)
          (define-key commands (kbd key) (cons label command))))
      (when available
        (set-keymap-parent local (current-local-map))
        (define-key local (kbd "C-c l") (cons "linguaggio" commands))
        (use-local-map local)
        (run-hooks 'gdev-tool-actions-change-hook)))))

(autoload 'so-long-statistics-excessive-p "so-long")
(autoload 'treesit-ready-p "treesit")

(defvaralias 'gdev-js-tree-sitter-max-bytes 'gdev-tree-sitter-auto-max-bytes)

(defcustom gdev-tree-sitter-auto-max-bytes (* 16 1024)
  "Dimensione massima per scegliere Tree-sitter se esiste un modo classico.
La scelta automatica richiede una grammatica disponibile e righe di
lunghezza normale. Le modalità scelte esplicitamente restano disponibili."
  :type 'natnum
  :group 'gdev)

(defcustom gdev-tree-sitter-auto-classic-modes
  '(c-mode c++-mode python-mode sh-mode java-mode csharp-mode)
  "Modi classici preferiti per ridurre il lavoro all'apertura.
Rimuovi un modo dall'elenco per scegliere automaticamente Tree-sitter
anche per quel linguaggio quando la grammatica è pronta e il file è piccolo."
  :type '(repeat symbol)
  :group 'gdev)

(defun gdev-language-register-tree-sitter (classic native grammar &optional eligible)
  "Apri con NATIVE i file di CLASSIC quando GRAMMAR è pronta entro la soglia.
ELIGIBLE, se presente, decide se NATIVE è adatta al documento corrente.
Le associazioni personali in `major-mode-remap-alist' hanno precedenza."
  (unless (assq classic major-mode-remap-defaults)
    ;; La voce deve essere un simbolo: per `mode: …' nelle variabili locali
    ;; Emacs chiama `fboundp' sul valore, e una funzione anonima segnala errore.
    (let ((dispatcher (intern (format "gdev-language--open-%s" classic))))
      (defalias dispatcher
        (lambda ()
          (if (and (not (memq classic gdev-tree-sitter-auto-classic-modes))
                   (<= (1- (position-bytes (point-max)))
                       gdev-tree-sitter-auto-max-bytes)
                   (or (not eligible) (funcall eligible))
                   (not (so-long-statistics-excessive-p))
                   (treesit-ready-p grammar t))
              (funcall native)
            (funcall classic)))
        (format "Apre un file di `%s' con `%s' se la grammatica è pronta, altrimenti con `%s'."
                classic native classic))
      (push (cons classic dispatcher) major-mode-remap-defaults))))

(provide 'gdev-language-modes)
;;; gdev-language-modes.el ends here
