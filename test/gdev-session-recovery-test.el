;;; gdev-session-recovery-test.el --- Prove delle bozze di una sessione interrotta -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Dopo un arresto anomalo il checkpoint è l'unica copia delle bozze: la prima
;; scrittura di una sessione nuova non deve distruggerlo prima che l'utente
;; abbia deciso se riprenderlo.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-workspaces)
(require 'gdev-commands)

(defmacro gdev-test-workspaces--with-state (directory &rest body)
  "Esegui BODY con i file di stato in una cartella temporanea DIRECTORY."
  (declare (indent 1))
  `(let* ((,directory (file-name-as-directory (make-temp-file "gdev-recupero-" t)))
          (gdev-workspaces--session-active nil))
     (unwind-protect
         (cl-letf (((symbol-function 'gdev-state-file)
                    (lambda (name) (expand-file-name name ,directory))))
           ,@body)
       (delete-directory ,directory t))))

(ert-deftest gdev-test-workspaces-keep-the-unrestored-session-with-drafts ()
  "Una sessione con bozze, non ripresa, si conserva prima di essere sostituita."
  (gdev-test-workspaces--with-state directory
    (let* ((file (gdev-state-file "gdev-workspaces.eld"))
           (backup (gdev-workspaces--interrupted-file file)))
      (write-region "sessione con bozze" nil file nil 'silent)
      ;; Senza bozze non c'è nulla da conservare.
      (cl-letf (((symbol-function 'gdev-workspaces--read) (lambda (&rest _) (list :tabs nil))))
        (gdev-workspaces--keep-unrestored file))
      (should-not (file-exists-p backup))
      ;; Con bozze, ma già ripresa o salvata da questa sessione: nemmeno.
      (cl-letf (((symbol-function 'gdev-workspaces--read)
                 (lambda (&rest _) (list :drafts '("bozza")))))
        (let ((gdev-workspaces--session-active t))
          (gdev-workspaces--keep-unrestored file))
        (should-not (file-exists-p backup))
        ;; Con bozze e nessuna ripresa: la copia nasce, uguale all'originale.
        (cl-letf (((symbol-function 'message) #'ignore))
          (gdev-workspaces--keep-unrestored file))
        (should (equal (with-temp-buffer (insert-file-contents backup) (buffer-string))
                       "sessione con bozze"))))))

(ert-deftest gdev-test-workspaces-save-keeps-the-interrupted-session-first ()
  "Il salvataggio normale conserva la sessione interrotta prima di sostituirla."
  (gdev-test-workspaces--with-state directory
    (let* ((file (gdev-state-file "gdev-workspaces.eld"))
           (backup (gdev-workspaces--interrupted-file file))
           backup-existed)
      (write-region "bozze da salvare" nil file nil 'silent)
      (cl-letf (((symbol-function 'gdev-workspaces--read)
                 (lambda (&rest _) (list :drafts '("bozza"))))
                ((symbol-function 'message) #'ignore)
                ((symbol-function 'gdev-write-state-data)
                 (lambda (&rest _) (setq backup-existed (file-exists-p backup)))))
        (gdev-workspaces--write '(:version 1 :tabs nil)))
      (should backup-existed)
      (should gdev-workspaces--session-active))))

(ert-deftest gdev-test-workspaces-restore-the-interrupted-session ()
  "Il comando riprende la copia conservata e poi la elimina."
  (gdev-test-workspaces--with-state directory
    (let* ((file (gdev-state-file "gdev-workspaces.eld"))
           (backup (gdev-workspaces--interrupted-file file))
           restored)
      (should-error (gdev-workspaces-restore-interrupted) :type 'user-error)
      (write-region "copia" nil backup nil 'silent)
      (cl-letf (((symbol-function 'gdev-workspaces-restore)
                 (lambda (&optional source) (setq restored source))))
        (gdev-workspaces-restore-interrupted))
      (should (equal restored backup))
      (should-not (file-exists-p backup)))))

(ert-deftest gdev-test-workspaces-restore-names-keep-drafts-of-same-named-tabs ()
  "Una scheda salvata con bozze non viene assorbita da una già aperta con lo stesso nome."
  (let ((drafts (make-hash-table :test #'equal))
        (record '(:name "README.md" :files ("/p/README.md"))))
    (puthash "/p/README.md" '("bozza") drafts)
    ;; Con bozze e un nome già in uso: una scheda distinta, che si può riconoscere.
    (should (equal (gdev-workspaces--restored-name record '("README.md") drafts)
                   "README.md (bozze)"))
    ;; Ripetendo il ripristino lo stesso nome torna fuori e la scheda esiste già:
    ;; chi chiama la trova tra gli spazi aperti e non la ripete.
    (let ((name (gdev-workspaces--restored-name record '("README.md" "README.md (bozze)") drafts)))
      (should (equal name "README.md (bozze)"))
      (should (seq-position '("README.md" "README.md (bozze)") name)))
    ;; Senza bozze, o con un nome libero, il nome resta quello salvato.
    (should (equal (gdev-workspaces--restored-name '(:name "README.md" :files ("/p/altro.md"))
                                                    '("README.md") drafts)
                   "README.md"))
    (should (equal (gdev-workspaces--restored-name record '("Altro") drafts) "README.md"))
    (should (equal (gdev-workspaces--restored-name record '("README.md") nil) "README.md"))))

(ert-deftest gdev-test-workspaces-keep-an-unreadable-session ()
  "Una sessione che non si legge più può contenere bozze: si conserva comunque."
  (gdev-test-workspaces--with-state directory
    (let* ((file (gdev-state-file "gdev-workspaces.eld"))
           (backup (gdev-workspaces--interrupted-file file)))
      (write-region "(:version 99 formato sconosciuto" nil file nil 'silent)
      (cl-letf (((symbol-function 'gdev-workspaces--read)
                 (lambda (&rest _) (user-error "Impossibile leggere la sessione")))
                ((symbol-function 'message) #'ignore))
        (gdev-workspaces--keep-unrestored file))
      (should (equal (with-temp-buffer (insert-file-contents backup) (buffer-string))
                     "(:version 99 formato sconosciuto")))))

(ert-deftest gdev-test-workspaces-ordinary-exit-keeps-the-latest-drafts ()
  "Un'uscita ordinaria conserva anche le modifiche successive al checkpoint."
  (gdev-test--with-layout
    (let* ((gdev-state-directory (make-temp-file "gdev-uscita-bozze-" t))
           (gdev-workspaces--session-active nil)
           (gdev-workspaces--checkpoint-signature nil)
           (gdev-workspaces--checkpoint-file nil)
           (gdev-workspaces--checkpoint-cache nil)
           (gdev-drafts-hot-exit t)
           (file (gdev-state-file "documento.txt"))
           document draft)
      (unwind-protect
          (progn
            (with-temp-file file (insert "Sul disco\n"))
            (gdev-open-file file)
            (setq document (current-buffer))
            (insert "Prima del checkpoint\n")
            (gdev-new-buffer)
            (setq draft (current-buffer))
            (insert "Bozza prima del checkpoint\n")
            (gdev-workspaces-checkpoint)
            (with-current-buffer document (insert "Dopo il checkpoint\n"))
            (insert "Bozza dopo il checkpoint\n")
            (let ((noninteractive nil)
                  (gdev-session--restarting nil)
                  (kill-emacs-hook '(gdev-workspaces-save-on-exit)))
              (run-hooks 'kill-emacs-hook))
            (let* ((saved (gdev-workspaces--read))
                   (drafts (plist-get saved :drafts)))
              (should (= (length drafts) 2))
              (should (equal (plist-get (cdr (assoc file drafts)) :text)
                             (with-current-buffer document (buffer-string))))
              (should (equal (plist-get (cdr (assoc (list 'bozza (buffer-name draft)) drafts)) :text)
                             (with-current-buffer draft (buffer-string)))))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "Sul disco\n"))
            (switch-to-buffer "*scratch*")
            (dolist (buffer (list document draft))
              (with-current-buffer buffer (set-buffer-modified-p nil))
              (kill-buffer buffer))
            (set-frame-parameter nil 'tabs nil)
            (gdev-workspaces-restore)
            (setq document (find-buffer-visiting file)
                  draft (current-buffer))
            (should (buffer-live-p document))
            (should (equal (with-current-buffer document (buffer-string))
                           "Prima del checkpoint\nDopo il checkpoint\nSul disco\n"))
            (should (equal (buffer-string)
                           "Bozza prima del checkpoint\nBozza dopo il checkpoint\n"))
            (should (buffer-modified-p document))
            (should (buffer-modified-p draft)))
        (dolist (buffer (list document draft))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory gdev-state-directory t)))))

(ert-deftest gdev-test-workspaces-exit-without-saving-discards-only-after-confirmation ()
  "Annullare conserva il checkpoint; confermare scarta le bozze senza scrivere il file."
  (gdev-test--with-layout
    (let* ((gdev-state-directory (make-temp-file "gdev-uscita-scarto-" t))
           (gdev-workspaces--session-active nil)
           (gdev-workspaces--checkpoint-signature nil)
           (gdev-workspaces--checkpoint-file nil)
           (gdev-workspaces--checkpoint-cache nil)
           (gdev-drafts-hot-exit t)
           (gdev-session--restarting nil)
           (file (gdev-state-file "documento.txt"))
           (session (gdev-state-file "gdev-workspaces.eld"))
           document draft before killed)
      (unwind-protect
          (progn
            (with-temp-file file (insert "Sul disco\n"))
            (gdev-open-file file)
            (setq document (current-buffer))
            (insert "Da scartare\n")
            (gdev-new-buffer)
            (setq draft (current-buffer))
            (insert "Bozza da scartare\n")
            (gdev-workspaces-checkpoint)
            (setq before (with-temp-buffer (insert-file-contents session) (buffer-string)))
            (let ((noninteractive nil)
                  (kill-emacs-hook '(gdev-workspaces-save-on-exit)))
              (cl-letf (((symbol-function 'kill-emacs)
                         (lambda (&rest _)
                           (setq killed t)
                           (run-hooks 'kill-emacs-hook))))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
                  (call-interactively #'gdev-quit-without-saving))
                (should-not killed)
                (should (equal before (with-temp-buffer (insert-file-contents session) (buffer-string))))
                (should (buffer-modified-p document))
                (should (buffer-modified-p draft))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
                  (call-interactively #'gdev-quit-without-saving))))
            (should killed)
            (should gdev-drafts-hot-exit)
            (should-not (plist-get (gdev-workspaces--read) :drafts))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "Sul disco\n")))
        (dolist (buffer (list document draft))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))
        (delete-directory gdev-state-directory t)))))

(ert-deftest gdev-test-workspaces-exit-with-draft-persistence-disabled-keeps-no-drafts ()
  "Con la conservazione disattivata, l'uscita salva solo lo stato degli spazi."
  (gdev-test--with-layout
    (let* ((gdev-state-directory (make-temp-file "gdev-uscita-opzione-" t))
           (gdev-workspaces--session-active t)
           (gdev-drafts-hot-exit nil)
           (draft (generate-new-buffer "Bozza senza conservazione")))
      (unwind-protect
          (progn
            (switch-to-buffer draft)
            (gdev-layout-mark-document)
            (insert "Da non conservare\n")
            (let ((noninteractive nil) (gdev-session--restarting nil))
              (gdev-workspaces-save-on-exit))
            (should-not (plist-get (gdev-workspaces--read) :drafts))
            (should (buffer-modified-p draft)))
        (kill-buffer draft)
        (delete-directory gdev-state-directory t)))))

;;; gdev-session-recovery-test.el ends here
