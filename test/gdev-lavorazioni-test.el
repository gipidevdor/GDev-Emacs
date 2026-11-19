;;; gdev-lavorazioni-test.el --- Attività Lavorazioni del banco di lavoro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Copre la navigazione dall'attività al piano e la separazione degli
;; indici fra richieste e spazi di lavoro.

;;; Code:

(require 'ert)
(require 'gdev-lavorazioni)
(require 'gdev-lavorazione-composizione)

(ert-deftest gdev-test-lavorazioni-pannello-apre-e-conserva-il-sorgente ()
  (let* ((radice (file-name-as-directory (make-temp-file "gdev-pannello-prova-" t)))
         (file (expand-file-name "rapporto.lavorazione" radice))
         (auto-mode-alist (cons '("\\.lavorazione\\'" . gdev-lavorazione-mode) auto-mode-alist))
         indice vista sorgente composizione)
    (unwind-protect
        (gdev-test--with-layout
          (write-region "{\"versione\":1,\"passi\":[]}" nil file nil 'silent)
          (gdev-workspace-set-roots (list radice))
          (cl-letf (((symbol-function 'gdev-lavorazione-indice-avvia)
                     (lambda (radici rispondi)
                       (should (equal radici (list radice)))
                       (setq indice rispondi)
                       #'ignore)))
            (gdev-lavorazioni-pannello)
            (setq vista (current-buffer))
            (should (derived-mode-p 'gdev-lavorazioni-mode))
            (should (eq (selected-window) (gdev-layout-left-window)))
            (should (eq 'lavorazioni (gdev-workspace-state-get 'gdev-activity-view)))
            (funcall indice (list file) 'ok)
            (goto-char (gdev-lavorazioni--posizione file))
            (push-button (point))
            (setq composizione (current-buffer)
                  sorgente (window-buffer (gdev-layout-editor)))
            (should (derived-mode-p 'gdev-composizione-mode))
            (should (equal (buffer-file-name sorgente) file))
            (should (eq (window-buffer (gdev-layout-left-window)) vista))
            (gdev-lavorazioni-sync vista)
            (with-current-buffer vista
              (should (equal gdev-lavorazioni--aperti (list file)))
              (should (equal gdev-lavorazioni--corrente file))
              (should (equal (gdev-lavorazioni--voce) file)))
            (gdev-close-document)
            (should (eq (window-buffer (gdev-layout-editor)) sorgente))
            (select-window (gdev-layout-left-window))
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) (signal 'quit nil))))
              (should (eq 'annullato
                          (condition-case nil (gdev-lavorazioni-scegli-file)
                            (quit 'annullato)))))
            (should (eq (window-buffer (gdev-layout-editor)) sorgente))
            (should (eq (current-buffer) vista))
            (gdev-close-document)
            (should-not (gdev-layout-left-window))
            (should (buffer-live-p sorgente))))
      (dolist (buffer (list composizione sorgente vista))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory radice t))))

(ert-deftest gdev-test-lavorazioni-risultati-appartengono-alla-richiesta-e-allo-spazio ()
  (let* ((root-a (file-name-as-directory (make-temp-file "gdev-lavorazioni-a-" t)))
         (root-b (file-name-as-directory (make-temp-file "gdev-lavorazioni-b-" t)))
         (a (expand-file-name "a.lavorazione" root-a))
         (b (expand-file-name "b.lavorazione" root-b))
         richieste annullate prima seconda vista)
    (unwind-protect
        (gdev-test--with-layout
          (cl-letf (((symbol-function 'gdev-lavorazione-indice-avvia)
                     (lambda (radici rispondi)
                       (push rispondi richieste)
                       (lambda () (push radici annullate)))))
            (gdev-workspace-set-roots (list root-a))
            (setq vista (gdev-lavorazioni-buffer) prima (car richieste))
            (gdev-workspace-set-roots (list root-b))
            (gdev-lavorazioni-sync vista)
            (setq seconda (car richieste))
            (should (equal annullate (list (list root-a))))
            (funcall prima (list a) 'ok)
            (funcall seconda (list b) 'ok)
            (with-current-buffer vista
              (should (equal gdev-lavorazioni--progetto (list b)))
              (should (gdev-lavorazioni--posizione b))
              (should-not (gdev-lavorazioni--posizione a))
              (let ((gdev-lavorazioni--progetto (list a b))
                    (gdev-lavorazioni--aperti (list b))
                    aperto)
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (_prompt scelte &rest _)
                             (should (= (length scelte) 2))
                             (caar scelte)))
                          ((symbol-function 'gdev-lavorazioni-apri-file)
                           (lambda (file) (setq aperto file))))
                  (gdev-lavorazioni-cerca)
                  (should (equal aperto b))
                  (should (equal gdev-lavorazioni--progetto (list a b))))))
            (gdev-lavorazioni-sync vista nil t)
            (let ((richiesta (car richieste)))
              (gdev-workspace-state-set 'gdev-activity-buffers nil)
              (funcall richiesta (list a) 'ok)
              (with-current-buffer vista
                (should (equal gdev-lavorazioni--progetto (list b)))))))
      (when (buffer-live-p vista) (kill-buffer vista))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(ert-deftest gdev-test-lavorazioni-ridisegno-conserva-la-voce ()
  (gdev-test--with-layout
    (let ((vista (generate-new-buffer " *Lavorazioni prova larghezza*"))
          (file "/tmp/radice/nome-lungo-e-distinguibile-della-lavorazione.lavorazione"))
      (unwind-protect
          (let ((window (gdev-layout-show-left vista 'gdev-activity)))
            (with-current-buffer vista
              (gdev-lavorazioni-mode)
              (setq gdev-lavorazioni--progetto (list file) gdev-lavorazioni--corrente file)
              (gdev-lavorazioni--render window)
              (set-window-point window (gdev-lavorazioni--posizione file))
              (gdev-lavorazioni--render window)
              (let ((position (window-point window)))
                (should (equal (get-text-property position 'gdev-lavorazioni-file) file))
                (should (equal (get-text-property position 'help-echo) file))
                (goto-char position)
                (should (<= (string-width (buffer-substring (line-beginning-position) (line-end-position)))
                            (window-body-width window))))))
        (kill-buffer vista)))))

(ert-deftest gdev-test-lavorazioni-progetto-suddiviso-in-pagine ()
  (with-temp-buffer
    (gdev-lavorazioni-mode)
    (setq gdev-lavorazioni--progetto
          (cl-loop for i below (+ 2 gdev-lavorazioni--per-pagina)
                   collect (format "/tmp/prova-%03d.lavorazione" i)))
    (let ((prima (car gdev-lavorazioni--progetto))
          (ultima (car (last gdev-lavorazioni--progetto))))
      (gdev-lavorazioni--render nil)
      (should (gdev-lavorazioni--posizione prima))
      (should-not (gdev-lavorazioni--posizione ultima))
      (call-interactively (key-binding (kbd "]")))
      (should (gdev-lavorazioni--posizione ultima))
      (should-not (gdev-lavorazioni--posizione prima))
      (should (string-search "Pagina 2 di 2" (buffer-string)))
      (call-interactively (key-binding (kbd "[")))
      (should (gdev-lavorazioni--posizione prima))
      (should (= (length gdev-lavorazioni--progetto) (+ 2 gdev-lavorazioni--per-pagina))))))

(ert-deftest gdev-test-lavorazioni-aggiornamento-segue-la-voce-fra-pagine ()
  (with-temp-buffer
    (gdev-lavorazioni-mode)
    (setq gdev-lavorazioni--progetto
          (cl-loop for i below gdev-lavorazioni--per-pagina
                   collect (format "/tmp/piano-%03d.lavorazione" i)))
    (let ((scelta (car (last gdev-lavorazioni--progetto))))
      (gdev-lavorazioni--render nil)
      (goto-char (gdev-lavorazioni--posizione scelta))
      (push "/tmp/piano-000-prima.lavorazione" gdev-lavorazioni--progetto)
      (gdev-lavorazioni--render nil)
      (should (equal (gdev-lavorazioni--voce) scelta))
      (should (string-search "Pagina 2 di 2" (buffer-string)))
      (call-interactively (key-binding (kbd "[")))
      (should-not (gdev-lavorazioni--posizione scelta)))))

(ert-deftest gdev-test-lavorazioni-omonimi-mostrano-radice-e-aprono-dal-percorso ()
  (with-temp-buffer
    (gdev-lavorazioni-mode)
    (setq gdev-lavorazioni--radici '("/tmp/primo/" "/tmp/secondo/")
          gdev-lavorazioni--progetto
          '("/tmp/primo/piano.lavorazione" "/tmp/secondo/piano.lavorazione"))
    (gdev-lavorazioni--render nil)
    (let (aperta)
      (cl-letf (((symbol-function 'gdev-lavorazioni-apri-file)
                 (lambda (file) (setq aperta file))))
        (dolist (file gdev-lavorazioni--progetto)
          (goto-char (gdev-lavorazioni--posizione file))
          (let ((inizio (button-start (button-at (point))))
                (radice (file-name-nondirectory
                         (directory-file-name (file-name-directory file)))))
            (forward-line 1)
            (should (string-search radice (thing-at-point 'line t)))
            (should (eq inizio (button-start (button-at (point)))))
            (push-button (point))
            (should (equal aperta file))))))))

(provide 'gdev-lavorazioni-test)
;;; gdev-lavorazioni-test.el ends here
