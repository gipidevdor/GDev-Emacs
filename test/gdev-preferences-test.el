;;; gdev-preferences-test.el --- Regressioni delle Preferenze -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs. I termini completi sono in LICENSE.

;;; Commentary:

;; Esercita il catalogo, la precedenza dei tasti e le preferenze di progetto.

;;; Code:

(require 'ert)
(require 'gdev-preferences)
(require 'gdev-drafts)

(ert-deftest gdev-test-preferences-preserves-selection-and-restores-each-key ()
  "Ridisegnare conserva la riga selezionata e ogni pulsante ripristina il proprio tasto."
  (let* ((gdev-preferences-keybindings '(("<f19>" . next-line) ("<f20>" . next-line)))
         (gdev-preferences--base-bindings (make-hash-table :test #'equal))
         (previous (mapcar #'gdev-preferences--global-entry '("<f19>" "<f20>"))))
    (unwind-protect
        (with-temp-buffer
          (gdev-preferences-mode)
          (cl-letf (((symbol-function 'gdev-menu-command-items)
                     (lambda (&optional _) '(("Riga successiva · Vai a" . next-line))))
                    ((symbol-function 'customize-save-variable)
                     (lambda (name value) (set name value))))
            (gdev-preferences-apply-shortcuts)
            (setq-local gdev-preferences--scope 'keys)
            (gdev-preferences--render)
            (goto-char (point-min))
            (search-forward "Riga successiva")
            (backward-char)
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "riga")))
              (gdev-preferences-filter))
            (should (eq (get-text-property (point) 'gdev-preferences-entry) 'next-line))
            (search-forward "Ripristina")
            (button-activate (button-at (1- (point))))
            (should (equal gdev-preferences-keybindings '(("<f20>" . next-line))))
            (should (eq (keymap-lookup (current-global-map) "<f20>" nil t) 'next-line))
            ;; Un modulo può aver preso il tasto dopo l'assegnazione personale.
            (keymap-global-set "<f20>" 'previous-line)
            (gdev-preferences-reset-shortcut "<f20>")
            (should (eq (keymap-lookup (current-global-map) "<f20>" nil t) 'previous-line))
            (should-not gdev-preferences-keybindings)
            (setq-local gdev-preferences--filter "azione inesistente")
            (gdev-preferences--render)
            (should (string-search "Nessuna scorciatoia corrispondente" (buffer-string)))))
      (cl-mapc #'keymap-global-set '("<f19>" "<f20>") previous))))

(ert-deftest gdev-test-preferences-redraw-is-not-a-change ()
  "Ridisegnare le Preferenze non le segna come documento da salvare."
  (with-temp-buffer
    (gdev-preferences-mode)
    (cl-letf (((symbol-function 'gdev-menu-command-items) (lambda (&optional _) nil)))
      (dolist (scope '(personal appearance keys))
        (setq-local gdev-preferences--scope scope)
        (gdev-preferences--render)
        (should (next-button (point-min)))
        (should-not (buffer-modified-p))
        (should-not (gdev-drafts--key (current-buffer)))))))

(ert-deftest gdev-test-preferences-preserves-local-bindings-on-cancel ()
  "Una scorciatoia locale prevale, e rifiutare il conflitto conserva la configurazione."
  (let* ((gdev-preferences-keybindings nil)
         (gdev-preferences--base-bindings (make-hash-table :test #'equal))
         (sequence "<f19>")
         (previous (gdev-preferences--global-entry sequence)))
    (unwind-protect
        (with-temp-buffer
          (use-local-map (make-sparse-keymap))
          (keymap-local-set sequence #'ignore)
          (keymap-global-set sequence nil)
          (cl-letf (((symbol-function 'read-key-sequence-vector) (lambda (&rest _) (kbd sequence)))
                    ((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (should (string-search "vista di origine" prompt)) nil))
                    ((symbol-function 'customize-save-variable)
                     (lambda (&rest _) (ert-fail "Configurazione salvata dopo l’annullamento"))))
            (should-error (gdev-preferences-edit-shortcut #'next-line) :type 'user-error)
            (should (eq (keymap-lookup nil sequence) 'ignore))
            (should-not (keymap-lookup (current-global-map) sequence))
            (should-not gdev-preferences-keybindings)))
      (keymap-global-set sequence previous))))

(ert-deftest gdev-test-preferences-rejects-invalid-assignment ()
  "Rifiuta un comando assente e il tasto di annullamento prima di scrivere."
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "gdev-test-comando-inesistente"))
            ((symbol-function 'read-key-sequence-vector)
             (lambda (&rest _) (ert-fail "Lettura del tasto senza un comando"))))
    (should-error (gdev-preferences-edit-shortcut) :type 'user-error))
  (cl-letf (((symbol-function 'read-key-sequence-vector) (lambda (&rest _) (kbd "C-g")))
            ((symbol-function 'customize-save-variable)
             (lambda (&rest _) (ert-fail "Il tasto di annullamento è riservato"))))
    (should-error (gdev-preferences-edit-shortcut #'next-line) :type 'user-error)))

(ert-deftest gdev-test-preferences-restores-a-named-prefix-binding ()
  "Ripristinare un tasto composto conserva l'etichetta nella mappa del prefisso."
  (let* ((gdev-preferences-keybindings '(("<f20> a" . next-line)))
         (gdev-preferences--base-bindings (make-hash-table :test #'equal))
         (original (gdev-preferences--global-entry "<f20>"))
         (prefix (make-sparse-keymap)))
    (unwind-protect
        (with-temp-buffer
          (gdev-preferences-mode)
          (gdev-bind prefix "a" "azione originale" #'ignore)
          (keymap-global-set "<f20>" prefix)
          (gdev-preferences-apply-shortcuts)
          (should (eq (keymap-lookup prefix "a" nil t) 'next-line))
          (cl-letf (((symbol-function 'customize-save-variable)
                     (lambda (name value) (set name value))))
            (gdev-preferences-reset-shortcut "<f20> a"))
          (should (equal (gdev-preferences--global-entry "<f20> a") '("azione originale" . ignore)))
          (should (eq (keymap-lookup prefix "a" nil t) 'ignore)))
      (keymap-global-set "<f20>" original))))

(ert-deftest gdev-test-preferences-edits-the-active-project ()
  "Il valore validato aggiorna il documento di origine e il database del progetto."
  (require 'gdev-commands)
  (let* ((root (file-name-as-directory (make-temp-file "gdev-preferenze-progetto-" t)))
         (gdev-state-directory root)
         (configuration (expand-file-name dir-locals-file root))
         (document (generate-new-buffer "gdev-test-impostazioni"))
         preferences)
    (unwind-protect
        (gdev-test--with-layout
          (switch-to-buffer document)
          (setq default-directory root)
          (gdev-layout-mark-document)
          (gdev-preferences-open)
          (setq preferences (current-buffer))
          (should (equal gdev-preferences--project root))
          (should (eq gdev-preferences--source document))
          (gdev-preferences-open-shortcuts)
          (should (eq (current-buffer) preferences))
          (should (eq gdev-preferences--scope 'keys))
          (setq gdev-preferences--scope 'project)
          (gdev-preferences--render)
          (goto-char (point-min))
          (search-forward "Larghezza della tabulazione")
          (let ((tab-width-button (button-at (1- (point)))))
            (cl-letf (((symbol-function 'read-number) (lambda (&rest _) -1)))
              (should-error (button-activate tab-width-button) :type 'user-error)
              (should-not (find-buffer-visiting configuration)))
            (cl-letf (((symbol-function 'read-number) (lambda (&rest _) 6)))
              (save-window-excursion (button-activate tab-width-button))))
          (goto-char (point-min))
          (search-forward "Rientra con tabulazioni")
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Sì")))
            (save-window-excursion (button-activate (button-at (1- (point))))))
          (should-not (file-exists-p configuration))
          (should (= 6 (buffer-local-value 'tab-width document)))
          (should (buffer-local-value 'indent-tabs-mode document))
          (should (equal (gdev-state-db-entries "preferenze_progetto" root)
                         '(("indent-tabs-mode" . t) ("tab-width" . 6)))))
      (when (buffer-live-p preferences) (kill-buffer preferences))
      (kill-buffer document)
      (delete-directory root t))))

(provide 'gdev-preferences-test)
;;; gdev-preferences-test.el ends here
