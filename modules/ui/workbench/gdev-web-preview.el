;;; gdev-web-preview.el --- Navigatore e anteprima web affiancata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; L'anteprima riusa il motore HTML di Emacs.  Il documento locale usa il
;; testo dell'editor; un indirizzo di loopback usa una richiesta asincrona.
;; Il riquadro e il suo lavoro seguono la durata dello spazio di origine.

;;; Code:

(require 'browse-url)
(require 'gdev-activity)
(require 'gdev-layout)
(require 'gdev-ui)
(require 'gdev-workspace-state)
(require 'shr)
(require 'url-http)

(declare-function eww "eww" (url &optional new-buffer buffer))
(declare-function gdev-close-document "gdev-commands" ())
(declare-function libxml-parse-html-region "xml.c" (start end &optional base-url discard-comments))
(defvar eww-prompt-history)
(defvar url-http-end-of-headers)        ; url-http.el, locale alla risposta
(defvar url-http-response-status)

(defconst gdev-web-preview--byte-limit (* 2 1024 1024))
(defconst gdev-web-preview--refresh-delay 0.2)
(defconst gdev-web-preview--timeout 10)
(defvar-local gdev-web-preview--owner nil)
(defvar-local gdev-web-preview--target nil)
(defvar-local gdev-web-preview--url nil)
(defvar-local gdev-web-preview--root nil)
(defvar-local gdev-web-preview--source nil)
(defvar-local gdev-web-preview--source-views nil)
(defvar-local gdev-web-preview--generation 0)
(defvar-local gdev-web-preview--timer nil)
(defvar-local gdev-web-preview--response nil)
(defvar-local gdev-web-preview--deadline nil)
(defvar-local gdev-web-preview--dom nil)
(defvar-local gdev-web-preview--status nil)
(defvar-local gdev-web-preview--width nil)

(defun gdev-web-browser ()
  "Cerca sul Web o apri un indirizzo nel navigatore di Emacs."
  (interactive)
  (when gdev-layout-mode (select-window (gdev-layout-editor)))
  (require 'eww)
  (eww (read-string "Indirizzo o ricerca sul Web: " (thing-at-point 'url t)
                    'eww-prompt-history)
       current-prefix-arg))

(defun gdev-web-preview--html-p (file)
  (let ((case-fold-search t))
    (and file (not (file-remote-p file)) (string-match-p (rx ".htm" (? "l") eos) file))))

(defun gdev-web-preview--local-url-p (address)
  (let ((url (url-generic-parse-url address)))
    (and (member (url-type url) '("http" "https"))
         (member (downcase (or (url-host url) "")) '("localhost" "127.0.0.1" "[::1]"))
         (not (url-user url)) (not (url-password url)))))

(defun gdev-web-preview--input (target directory)
  "Valida TARGET rispetto a DIRECTORY e restituisci il tipo e l'indirizzo."
  (let ((target (string-trim target)))
    (if (string-match-p (rx bos alpha (* (any alnum "+.-")) "://") target)
        (if (gdev-web-preview--local-url-p target) (cons 'http target)
          (user-error "Usa un indirizzo HTTP o HTTPS di localhost"))
      (let ((file (expand-file-name target directory)))
        (unless (and (gdev-web-preview--html-p file)
                     (or (find-buffer-visiting file)
                         (and (file-regular-p file) (file-readable-p file))))
          (user-error "Scegli un file HTML locale leggibile"))
        (cons 'file file)))))

(defun gdev-web-preview--window ()
  "Restituisci la finestra visibile del riquadro nel suo spazio di origine."
  (let ((buffer (current-buffer)))
    (seq-find
     (lambda (window)
       (eq gdev-web-preview--owner (gdev-workspace-state-id (window-frame window))))
     (get-buffer-window-list buffer nil 'visible))))

(defun gdev-web-preview--abort-response ()
  (let ((response gdev-web-preview--response))
    (setq gdev-web-preview--response nil)
    (when (timerp gdev-web-preview--deadline) (cancel-timer gdev-web-preview--deadline))
    (setq gdev-web-preview--deadline nil)
    (when (buffer-live-p response)
      (when-let* ((process (get-buffer-process response)))
        (set-process-query-on-exit-flag process nil))
      (kill-buffer response))))

(defun gdev-web-preview--invalidate ()
  (cl-incf gdev-web-preview--generation)
  (when (timerp gdev-web-preview--timer) (cancel-timer gdev-web-preview--timer))
  (setq gdev-web-preview--timer nil)
  (gdev-web-preview--abort-response))

(defun gdev-web-preview--source-changed (&rest _)
  (dolist (view gdev-web-preview--source-views)
    (when (buffer-live-p view)
      (with-current-buffer view (gdev-web-preview--schedule)))))

(defun gdev-web-preview--detach-source ()
  (when (buffer-live-p gdev-web-preview--source)
    (let ((view (current-buffer)))
      (with-current-buffer gdev-web-preview--source
        (setq gdev-web-preview--source-views (delq view gdev-web-preview--source-views))
        (unless gdev-web-preview--source-views
          (remove-hook 'after-change-functions #'gdev-web-preview--source-changed t)
          (remove-hook 'after-revert-hook #'gdev-web-preview--source-changed t)))))
  (setq gdev-web-preview--source nil))

(defun gdev-web-preview--track-source (source)
  (unless (eq source gdev-web-preview--source)
    (gdev-web-preview--detach-source)
    (when (buffer-live-p source)
      (let ((view (current-buffer)))
        (setq gdev-web-preview--source source)
        (with-current-buffer source
          (cl-pushnew view gdev-web-preview--source-views)
          (add-hook 'after-change-functions #'gdev-web-preview--source-changed nil t)
          (add-hook 'after-revert-hook #'gdev-web-preview--source-changed nil t))))))

(defun gdev-web-preview--dispose ()
  (gdev-web-preview--detach-source)
  (gdev-web-preview--invalidate))

(defun gdev-web-preview--close-auxiliary (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'gdev-web-preview-mode) (gdev-web-preview--dispose)))))

(defun gdev-web-preview--parse ()
  (save-restriction
    (widen)
    (when (> (1- (position-bytes (point-max))) gdev-web-preview--byte-limit)
      (user-error "La pagina supera il limite dell’anteprima (2 MiB)"))
    (libxml-parse-html-region (point-min) (point-max) nil t)))

(defun gdev-web-preview--local-document (file)
  (let ((source (find-buffer-visiting file)))
    (gdev-web-preview--track-source source)
    (if source
        (with-current-buffer source (gdev-web-preview--parse))
      (with-temp-buffer
        (insert-file-contents file nil 0 (1+ gdev-web-preview--byte-limit))
        (gdev-web-preview--parse)))))

(defun gdev-web-preview--status-text (status)
  (if (eq status 'loading) "Caricamento della pagina…"
    (or status "La pagina è vuota")))

(defun gdev-web-preview--external ()
  "Apri la pagina nel navigatore di sistema."
  (interactive)
  (if (eq (car gdev-web-preview--target) 'file)
      (browse-url-of-file (cdr gdev-web-preview--target))
    (browse-url gdev-web-preview--url)))

(defun gdev-web-preview--render (window)
  "Disegna il documento e conserva il collegamento selezionato, se presente."
  (let* ((width (window-body-width window))
         (position (window-point window))
         (link (get-text-property position 'shr-url))
         (line (line-number-at-pos position))
         (start-line (line-number-at-pos (window-start window)))
         (inhibit-read-only t)
         (shr-use-colors nil)
         (shr-inhibit-images t)
         (shr-width (max 12 (- width 2)))
         (shr-external-rendering-functions nil))
    (setq gdev-web-preview--width width)
    (erase-buffer)
    (insert (propertize "Anteprima web" 'face 'gdev-ui-view-title) "\n")
    (insert (propertize
             (gdev-ui-fit-text (cdr gdev-web-preview--target) (max 1 (- width 2)) #'string-width)
             'face 'gdev-ui-secondary 'help-echo (cdr gdev-web-preview--target)) "\n")
    (insert-text-button "Aggiorna" :type 'gdev-ui-action
                        'action (lambda (_) (gdev-web-preview-refresh)))
    (insert "   ")
    (insert-text-button "Apri nel navigatore" :type 'gdev-ui-action
                        'action (lambda (_) (gdev-web-preview--external)))
    (insert "\n\n")
    (when (or gdev-web-preview--status (not gdev-web-preview--dom))
      (insert (propertize (gdev-web-preview--status-text gdev-web-preview--status)
                          'face 'gdev-ui-secondary) "\n"))
    (when gdev-web-preview--dom
      (shr-insert-document (list 'base (list (cons 'href gdev-web-preview--url))
                                 gdev-web-preview--dom)))
    (goto-char (point-min))
    (forward-line (1- start-line))
    (set-window-start window (point) t)
    (goto-char (point-min))
    (forward-line (1- line))
    (set-window-point window (or (and link (text-property-any (point-min) (point-max) 'shr-url link))
                                 (point)))
    (set-buffer-modified-p nil)))

(defun gdev-web-preview--publish (dom status)
  (setq gdev-web-preview--dom dom gdev-web-preview--status status)
  (when-let* ((window (gdev-web-preview--window))) (gdev-web-preview--render window)))

(defun gdev-web-preview--http-document (status)
  (when (or (plist-get status :error)
            (not (and (integerp url-http-response-status)
                      (<= 200 url-http-response-status 299)
                      (markerp url-http-end-of-headers))))
    (user-error "Impossibile leggere la pagina%s"
                (if (integerp url-http-response-status)
                    (format " (HTTP %d)" url-http-response-status) "")))
  (let* ((start (marker-position url-http-end-of-headers))
         (charset (save-excursion
                    (goto-char (point-min))
                    (let ((case-fold-search t))
                      (when (re-search-forward
                             (rx bol "content-type:" (* nonl) "charset=" (? (any "\"'"))
                                 (group (+ (any "-" alnum "_")))) start t)
                        (intern-soft (downcase (match-string-no-properties 1)))))))
         (coding (or (and charset (coding-system-p charset) charset) 'utf-8)))
    (when (> (- (point-max) start) gdev-web-preview--byte-limit)
      (user-error "La pagina supera il limite dell’anteprima (2 MiB)"))
    (let ((html (decode-coding-string (buffer-substring-no-properties start (point-max)) coding)))
      (with-temp-buffer
        (insert html)
        (gdev-web-preview--parse)))))

(defun gdev-web-preview--receive (status view generation)
  "Consegna STATUS a VIEW soltanto per la generazione ancora visibile."
  (let ((response (current-buffer)))
    (unwind-protect
        (when (and (buffer-live-p view)
                   (with-current-buffer view
                     (and (eq generation gdev-web-preview--generation) (gdev-web-preview--window))))
          (let (dom error)
            (condition-case failure
                (setq dom (gdev-web-preview--http-document status))
              (error (setq error (error-message-string failure))))
            (with-current-buffer view
              (setq gdev-web-preview--response nil)
              (gdev-web-preview--abort-response)
              (gdev-web-preview--publish dom error))))
      (when (buffer-live-p response) (kill-buffer response)))))

(defun gdev-web-preview--expire (view generation)
  (when (buffer-live-p view)
    (with-current-buffer view
      (when (and (eq generation gdev-web-preview--generation)
                 (buffer-live-p gdev-web-preview--response))
        (gdev-web-preview--invalidate)
        (gdev-web-preview--publish nil "Il servizio locale non ha risposto in tempo")))))

(defun gdev-web-preview--reload ()
  (when (gdev-web-preview--window)
    (condition-case failure
        (if (eq (car gdev-web-preview--target) 'file)
            (gdev-web-preview--publish (gdev-web-preview--local-document
                                        (cdr gdev-web-preview--target)) nil)
          (let ((url-max-redirections 0)
                (view (current-buffer))
                (generation gdev-web-preview--generation))
            (when (not gdev-web-preview--dom) (gdev-web-preview--publish nil 'loading))
            (setq gdev-web-preview--response
                  (url-retrieve gdev-web-preview--url #'gdev-web-preview--receive
                                (list view generation) t t))
            (when (buffer-live-p gdev-web-preview--response)
              (setq gdev-web-preview--deadline
                    (run-at-time gdev-web-preview--timeout nil
                                 #'gdev-web-preview--expire view generation)))))
      (error (gdev-web-preview--publish nil (error-message-string failure))))))

(defun gdev-web-preview--schedule ()
  "Ricarica dopo l'ultimo cambiamento, soltanto finché la vista è visibile."
  (gdev-web-preview--invalidate)
  (when (gdev-web-preview--window)
    (let ((view (current-buffer)))
      (setq gdev-web-preview--timer
            (run-at-time gdev-web-preview--refresh-delay nil
                         (lambda ()
                           (when (buffer-live-p view)
                             (with-current-buffer view
                               (setq gdev-web-preview--timer nil)
                               (gdev-web-preview--reload)))))))))

(defun gdev-web-preview-refresh ()
  "Ricarica l'anteprima corrente."
  (interactive)
  (gdev-web-preview--invalidate)
  (gdev-web-preview--reload))

(defun gdev-web-preview--after-save ()
  (when-let* ((file buffer-file-name)
              ((not (file-remote-p file)))
              (view (alist-get 'web-preview (gdev-workspace-state-get 'gdev-activity-buffers)))
              ((buffer-live-p view)))
    (with-current-buffer view
      (when (and (eq (car gdev-web-preview--target) 'http)
                 gdev-web-preview--root (file-in-directory-p file gdev-web-preview--root))
        (gdev-web-preview--schedule)))))

(defun gdev-web-preview--window-change (window)
  (if (eq (window-buffer window) (current-buffer))
      (when (eq gdev-web-preview--owner (gdev-workspace-state-id (window-frame window)))
        (gdev-web-preview--schedule))
    (unless (gdev-web-preview--window) (gdev-web-preview--dispose))))

(defun gdev-web-preview--resize (window)
  (when (and gdev-web-preview--target
             (eq (window-buffer window) (current-buffer))
             (eq gdev-web-preview--owner (gdev-workspace-state-id (window-frame window)))
             (not (eql gdev-web-preview--width (window-body-width window))))
    (gdev-web-preview--render window)))

(defvar-keymap gdev-web-preview-mode-map
  "g" #'gdev-web-preview-refresh
  "q" #'gdev-close-document
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode gdev-web-preview-mode special-mode "Anteprima web"
  "Mostra una pagina HTML accanto all'editor."
  (gdev-ui-view-setup 'document)
  (gdev-layout-mark-auxiliary)
  (add-hook 'window-buffer-change-functions #'gdev-web-preview--window-change nil t)
  (add-hook 'window-size-change-functions #'gdev-web-preview--resize nil t)
  (add-hook 'kill-buffer-hook #'gdev-web-preview--dispose nil t))

(defun gdev-web-preview (&optional target)
  "Mostra TARGET a fianco.  Con prefisso, chiedi un file HTML o un URL locale."
  (interactive)
  (unless gdev-layout-mode (user-error "Attiva il banco di lavoro per mostrare l’anteprima"))
  (unless (libxml-available-p) (user-error "L’anteprima richiede il supporto HTML di Emacs (libxml2)"))
  (let* ((editor (gdev-layout-editor))
         (source (window-buffer editor))
         (directory (buffer-local-value 'default-directory source))
         (file (buffer-file-name source))
         (input (gdev-web-preview--input
                 (or target (and (not current-prefix-arg) (gdev-web-preview--html-p file) file)
                     (read-string "File HTML o indirizzo localhost: " nil nil file))
                 directory))
         (root (unless (file-remote-p directory) (gdev-project-root directory)))
         (owner (gdev-workspace-state-ensure-id))
         (view (gdev-activity-buffer 'web-preview "*Anteprima web*" #'gdev-web-preview-mode)))
    (with-current-buffer view
      (gdev-web-preview--dispose)
      (setq-local gdev-activity-kind nil)
      (setq gdev-web-preview--owner owner gdev-web-preview--target input gdev-web-preview--root root
            gdev-web-preview--url (if (eq (car input) 'http) (cdr input)
                                   (browse-url-file-url (cdr input)))
            gdev-web-preview--dom nil gdev-web-preview--status nil))
    (save-selected-window (display-buffer view))
    (with-current-buffer view (gdev-web-preview-refresh))
    view))

(add-hook 'after-save-hook #'gdev-web-preview--after-save)
(advice-add 'gdev-layout-close-auxiliary :after #'gdev-web-preview--close-auxiliary)

(provide 'gdev-web-preview)
;;; gdev-web-preview.el ends here
