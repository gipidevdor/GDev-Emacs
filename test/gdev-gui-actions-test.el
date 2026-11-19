;;; gdev-gui-actions-test.el --- Prove di uscita, chiusura e voci di menu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il pulsante di chiusura dell'ultima finestra, la voce «Chiudi la finestra di
;; Emacs» e «Esci senza salvare» seguono le stesse regole di ⌘Q.  Le voci del
;; menu portano a comandi che esistono e non si ripetono.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-commands)
(require 'gdev-menu)

(defun gdev-test-gui--only-frame (body)
  "Esegui BODY con un solo frame visibile, senza chiudere davvero Emacs."
  (let ((frame (selected-frame)) quit killed)
    (cl-letf (((symbol-function 'gdev-quit) (lambda (&rest _) (setq quit t)))
              ((symbol-function 'save-buffers-kill-emacs) (lambda (&rest _) (setq killed t))))
      (funcall body frame)
      (list quit killed))))

(ert-deftest gdev-test-closing-the-last-frame-quits-like-command-q ()
  "Il pulsante rosso dell'ultima finestra esce come ⌘Q, senza il dialogo di Emacs."
  (pcase-let ((`(,quit ,killed)
               (gdev-test-gui--only-frame
                (lambda (frame) (handle-delete-frame (list 'delete-frame (list frame)))))))
    (should quit)
    (should-not killed)))

(ert-deftest gdev-test-closing-a-frame-keeps-the-others ()
  "Con un'altra finestra visibile il pulsante rosso chiude solo la finestra."
  (let ((frame (selected-frame)) deleted quit)
    (cl-letf (((symbol-function 'frame-list) (lambda () (list frame 'altro)))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'frame-parent) #'ignore)
              ((symbol-function 'frame-parameter) (lambda (&rest _) nil))
              ((symbol-function 'gdev-quit) (lambda (&rest _) (setq quit t)))
              ((symbol-function 'delete-frame)
               (lambda (&optional target force) (setq deleted (list target force)))))
      (handle-delete-frame (list 'delete-frame (list frame)))
      (should (equal deleted (list frame t)))
      (should-not quit)
      (setq deleted nil)
      (gdev-close-frame)
      (should deleted))))

(ert-deftest gdev-test-close-frame-of-the-sole-frame-quits ()
  "«Chiudi la finestra di Emacs» sull'unica finestra esce invece di dare errore."
  (pcase-let ((`(,quit ,killed) (gdev-test-gui--only-frame (lambda (_) (gdev-close-frame)))))
    (should quit)
    (should-not killed)))

(ert-deftest gdev-test-quit-without-saving-asks-first ()
  "«Esci senza salvare» non esce senza una conferma."
  (let (killed)
    (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t))))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (gdev-quit-without-saving))
      (should-not killed)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (gdev-quit-without-saving))
      (should killed))))

(ert-deftest gdev-test-menu-entries-reach-existing-commands-once ()
  "Espandi selezione usa il comando installato e HitHub non ripete la panoramica."
  (require 'package)
  (package-activate-all)
  (let ((gdev-modules '((:ui workbench) (:editor motion) (:tools hithub))))
    (let ((selection (gdev-menu-section-items 'gdev-selection)))
      (should (seq-some (lambda (entry) (and (vectorp entry) (eq (aref entry 1) 'expreg-expand)))
                        selection))
      (should-not (seq-some (lambda (entry) (and (vectorp entry) (eq (aref entry 1) 'er/expand-region)))
                            selection)))
    (load (gdev-module-file :tools 'hithub ".el") nil t t)
    (let ((hithub (gdev-menu-section-items 'gdev-hithub)))
      (should (= 1 (seq-count (lambda (entry)
                                (and (vectorp entry) (eq (aref entry 1) 'gdev-github-overview)))
                              hithub))))))

(ert-deftest gdev-test-copy-file-location-counts-from-the-file ()
  "In un buffer ristretto «Copia file:riga» riporta la riga del file."
  (with-temp-buffer
    (insert "uno\ndue\ntre\nquattro\ncinque\n")
    (setq buffer-file-name (expand-file-name "prova.txt" temporary-file-directory))
    (goto-char (point-min))
    (forward-line 3)
    (narrow-to-region (point) (point-max))
    (let ((kill-ring nil))
      (cl-letf (((symbol-function 'gdev-command-relative-name) #'file-name-nondirectory))
        (gdev-copy-file-location))
      (should (equal (car kill-ring) "prova.txt:4")))))

(ert-deftest gdev-test-quick-open-does-not-touch-remote-paths ()
  "Un percorso TRAMP con «@» non apre connessioni mentre si digita."
  (cl-letf (((symbol-function 'file-exists-p)
             (lambda (file) (when (file-remote-p file) (ert-fail "Controllo remoto")) nil))
            ((symbol-function 'file-regular-p)
             (lambda (file) (when (file-remote-p file) (ert-fail "Controllo remoto")) nil))
            ((symbol-function 'get-file-buffer) #'ignore))
    (should-not (gdev-quick-open--suffix "/ssh:me@host:/etc/hosts"))))

;;; gdev-gui-actions-test.el ends here
