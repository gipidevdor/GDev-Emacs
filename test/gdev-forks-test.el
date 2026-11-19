;;; gdev-forks-test.el --- Contratti dei fork inclusi -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Riproduce errori delle API e protegge lo stato dei chiamanti.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'package)
(package-activate-all)

(ert-deftest gdev-test-forks-consult-imenu-preserves-types-faces-and-targets ()
  "La visita iterativa conserva ordine, proprietà, marcatori e input originali."
  (require 'consult-imenu)
  (with-temp-buffer
    (insert (make-string 100 ?x))
    (let* ((top (propertize "top" 'help-echo "Originale"))
           (index `((,top . 10) ("Functions" ("inner" ("alpha" . 20)) ("beta" . 30))))
           (snapshot (read (prin1-to-string index)))
           (types '(("Functions" ?f font-lock-function-name-face)))
           (actual (consult-imenu--flatten nil nil index types)))
      (should (equal (mapcar #'car actual) '("top" "Functions/inner alpha" "Functions beta")))
      (should (eq (caar actual) top))
      (should (equal-including-properties index snapshot))
      (should (equal (mapcar (lambda (row) (marker-position (cdr row))) actual) '(10 20 30)))
      (should (eq (get-text-property 0 'consult--type (car (nth 1 actual))) ?f))
      (should (memq 'font-lock-function-name-face (ensure-list (get-text-property 16 'face (car (nth 1 actual))))))
      (should (memq 'consult-imenu-prefix (ensure-list (get-text-property 0 'face (car (nth 1 actual))))))
      (let* ((imenu-default-goto-function #'ignore)
             (special (consult-imenu--flatten "extern" 'italic '(("leaf" . 25)) types)))
        (should (equal (caar special) "extern leaf"))
        (should (equal (seq-take (cdar special) 2) '(25 consult-imenu--switch-buffer)))
        (should (eq (nth 2 (cdar special)) (current-buffer)))))))

(ert-deftest gdev-test-forks-consult-imenu-handles-deep-prefixes-with-a-bounded-stack ()
  "Tremila gruppi non ricostruiscono ogni prefisso né consumano la pila Lisp."
  (require 'consult-imenu)
  (with-temp-buffer
    (insert "x")
    (let ((index '(("leaf" . 1))))
      (dotimes (number 3000) (setq index (list (cons (format "N%d" number) index))))
      (let* ((max-lisp-eval-depth 100) (result (consult-imenu--flatten nil nil index nil)))
        (should (= 1 (length result)))
        (should (string-prefix-p "N2999/N2998/" (caar result)))
        (should (string-suffix-p "N0 leaf" (caar result)))
        (should (= 2999 (cl-count ?/ (caar result))))
        (should (= 1 (marker-position (cdar result))))))))

(ert-deftest gdev-test-forks-gptel-describes-derived-modes ()
  (require 'gptel)
  (let ((gptel--mode-description-alist nil))
    (should (equal "emacs-lisp" (gptel--strip-mode-suffix 'emacs-lisp-mode)))
    (should (equal "text" (gptel--strip-mode-suffix 'text-mode)))
    (should (equal "" (gptel--strip-mode-suffix 'fundamental-mode)))))

(ert-deftest gdev-test-forks-dired-subtree-reads-listings-with-and-without-dot-entries ()
  (require 'dired-subtree)
  (dolist (dots '(nil t))
    (cl-letf (((symbol-function 'insert-directory)
               (lambda (&rest _)
                 (insert "total 8\n")
                 (when dots
                   (insert "drwxr-xr-x  2 user staff 64 Nov 19 08:00 .\n"
                           "drwxr-xr-x  2 user staff 64 Nov 19 08:00 ..\n"))
                 (insert "-rw-r--r--  1 user staff 12 Nov 19 08:00 esempio.txt\n"))))
      (let ((listing (dired-subtree--readin default-directory)))
        (should (string-match-p "esempio\\.txt" listing))
        (should-not (string-match-p "total\\| 08:00 \\.\\.?$" listing))))))

(ert-deftest gdev-test-forks-web-scanning-and-indentation-preserve-caller-state ()
  (require 'web-mode)
  (cl-progv '(tnameraw prev-line-end) '(unchanged unchanged)
    (with-temp-buffer
      (insert "<article>\n<section>Testo</section>\n</article>\n")
      (web-mode)
      (web-mode-scan-region (point-min) (point-max))
      (indent-region (point-min) (point-max))
      (goto-char (point-min))
      (let ((text (buffer-string)) (position (point)))
        (web-mode-column-show)
        (should (equal text (buffer-string)))
        (should (= position (point)))
        (web-mode-column-hide))
      (should (eq 'unchanged (symbol-value 'tnameraw)))
      (should (eq 'unchanged (symbol-value 'prev-line-end))))))

(ert-deftest gdev-test-forks-multiple-cursors-imports-the-same-clipboard-order ()
  (require 'multiple-cursors-core)
  (with-temp-buffer
    (insert "ab")
    (let* ((external (list "primo" "secondo"))
           (kill-ring '("precedente"))
           (kill-ring-yank-pointer nil)
           (interprogram-cut-function nil)
           (calls 0)
           (interprogram-paste-function (lambda () (when (zerop (prog1 calls (cl-incf calls))) external))))
      (dolist (position '(1 2))
        (let ((cursor (make-overlay position position)))
          (overlay-put cursor 'type 'fake-cursor)
          (overlay-put cursor 'kill-ring '("precedente"))))
      (should (equal "primo" (current-kill 0)))
      (should (equal '("primo" "secondo") external))
      (should (equal '("primo" "secondo" "precedente") kill-ring))
      (dolist (cursor (mc/all-fake-cursors))
        (should (equal kill-ring (overlay-get cursor 'kill-ring)))))))

(ert-deftest gdev-test-forks-keyboard-macros-run-only-for-the-real-cursor ()
  (require 'multiple-cursors-core)
  (let* ((calls 0) (observer (lambda (&rest _) (cl-incf calls))))
    (unwind-protect
        (progn
          (advice-add 'execute-kbd-macro :before observer '((depth . 100)))
          (let ((mc--executing-command-for-fake-cursor t)) (execute-kbd-macro []))
          (should (zerop calls))
          (let ((mc--executing-command-for-fake-cursor nil)) (execute-kbd-macro []))
          (should (= 1 calls)))
      (advice-remove 'execute-kbd-macro observer))))

(defmacro gdev-test-forks--with-pcre (&rest body)
  "Esegui BODY con PCRE attivo, ripristinando mappe e advice."
  (declare (indent 0))
  `(progn
     (require 'pcre2el)
     (let ((pcre-mode nil) (pcre-old-isearch-key-bindings nil)
           (isearch-mode-map (copy-keymap isearch-mode-map))
           (pcre-mode-cache (make-hash-table :test #'equal))
           (pcre-mode-reverse-cache (make-hash-table :test #'equal))
           (pcre-cache-ring (make-ring pcre-mode-cache-size)))
       (unwind-protect (progn (pcre-mode 1) ,@body) (pcre-mode -1)))))

(ert-deftest gdev-test-forks-pcre-repeated-enable-restores-original-keybindings ()
  (require 'pcre2el)
  (let* ((isearch-mode-map (copy-keymap isearch-mode-map))
         (pcre-mode nil) (pcre-old-isearch-key-bindings nil)
         (before (copy-keymap isearch-mode-map)))
    (unwind-protect
        (progn
          (pcre-mode 1) (pcre-mode 1)
          (pcre-mode -1)
          (cl-loop for key being the key-seqs of rxt--read-pcre-mode-map
                   for expected = (lookup-key before key)
                   do (should (equal (if (numberp expected) nil expected)
                                     (lookup-key isearch-mode-map key))))
          (dolist (target '(read-regexp align-regexp sort-regexp-fields evil-search-function))
            (should-not (advice-member-p (intern (format "pcre--advice-%s" target)) target))))
      (pcre-mode -1))))

(ert-deftest gdev-test-forks-pcre-reader-history-and-sort-share-the-original-expression ()
  (gdev-test-forks--with-pcre
    (require 'sort)
    (let ((regexp-history nil)
          (query-replace-from-history-variable 'regexp-history)
          prompt)
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (text &rest _) (setq prompt text) "\\d+")))
        (let ((translated (read-regexp "Espressione: ")))
          (should (string-prefix-p "[PCRE] " prompt))
          (should (string-match-p translated "123"))
          (should-not (string-match-p translated "abc"))
          (add-to-history 'regexp-history translated)
          (should (equal "\\d+" (car regexp-history)))
          (should (equal "\\d+" (query-replace-descr translated)))))
      (with-temp-buffer
        (insert "2:bb\n1:aa\n")
        (sort-regexp-fields nil "^\\d+:[a-z]+$" "\\d+" (point-min) (point-max))
        (should (equal "1:aa\n2:bb\n" (buffer-string)))))))

(ert-deftest gdev-test-forks-pcre-align-supports-interactive-input-and-cancellation ()
  (require 'align)
  (gdev-test-forks--with-pcre
    (with-temp-buffer
      (insert "a =x\nbbbb =y\n")
      (goto-char (point-min)) (set-mark (point-max))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "\\s*=")))
        (call-interactively #'align-regexp))
      (goto-char (point-min)) (search-forward "=")
      (let ((column (current-column)) (before (buffer-string)))
        (forward-line) (search-forward "=")
        (should (= column (current-column)))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (signal 'quit nil))))
          (should (eq 'cancelled (condition-case nil (call-interactively #'align-regexp) (quit 'cancelled)))))
        (should (equal before (buffer-string)))))))

(ert-deftest gdev-test-forks-rebuilder-roundtrips-pcre-and-rx ()
  (require 'pcre2el)
  (save-window-excursion
    (let ((target (generate-new-buffer " *gdev-forks-regexp*"))
          (reb-buffer "*gdev-forks-rebuilder*") (reb-re-syntax 'string)
          (reb-target-buffer nil))
      (unwind-protect
          (progn
            (switch-to-buffer target) (insert "Testo 123")
            (re-builder)
            (with-current-buffer reb-buffer
              (reb-change-syntax 'pcre)
              (let ((inhibit-modification-hooks t)) (erase-buffer) (insert "\n/\\d+/"))
              (should (reb-update-regexp))
              (should (string-match-p (buffer-local-value 'reb-regexp target) "123"))
              (should-not (reb-update-regexp))
              (reb-change-syntax 'rx)
              (should (eq 'rx reb-re-syntax))
              (should (string-match-p (reb-cook-regexp (reb-read-regexp)) "123"))
              (should-error (reb-change-syntax 'invalid) :type 'error)))
        (when (get-buffer reb-buffer) (kill-buffer reb-buffer))
        (kill-buffer target)))))

(ert-deftest gdev-test-forks-seq-patterns-support-nesting-rest-and-tree-editing ()
  (require 'treepy)
  (should (equal '(1 2 3 [4 5])
                 (seq-let (first (second third) &rest tail) [1 [2 3] 4 5]
                   (list first second third tail))))
  (let* ((root (treepy-list-zip '(a (b c) d)))
         (child (treepy-down (treepy-right (treepy-down root)))))
    (should (equal '(a (z c) d) (treepy-root (treepy-replace child 'z))))))

(ert-deftest gdev-test-forks-rmsbolt-retains-default-and-custom-language-descriptors ()
  (require 'rmsbolt)
  (with-temp-buffer
    (let ((major-mode 'c-mode) (rmsbolt-language-descriptor nil))
      (should (rmsbolt-lang-p (rmsbolt--get-lang))))
    (let ((major-mode 'gdev-test-mode) (rmsbolt-language-descriptor nil)
          (custom (make-rmsbolt-lang :compile-cmd "custom")))
      (cl-progv '(rmsbolt-languages) (list (list (cons 'gdev-test-mode custom)))
        (should (eq custom (rmsbolt--get-lang)))))
    (should (string-match rmsbolt-directive ".text\nseconda riga"))
    (should (equal ".text" (match-string 0 ".text\nseconda riga")))))

(ert-deftest gdev-test-forks-emmet-retains-nested-parser-bindings ()
  (require 'emmet-mode)
  (let ((html (emmet-transform "ul>li.voce$*2")))
    (should (string-match-p "<ul>" html))
    (should (string-match-p "class=\"voce1\"" html))
    (should (string-match-p "class=\"voce2\"" html))))

(ert-deftest gdev-test-forks-sly-completion-fills-a-displayed-window-before-resizing ()
  (require 'sly)
  (save-window-excursion
    ;; La regola globale dei pannelli sostituisce intenzionalmente l'altezza.
    ;; Qui si verifica il contratto ACTION del fork, con la sua politica.
    (let ((noninteractive nil) (display-buffer-alist nil) (display-buffer-base-action nil)
          (layout-display (advice-member-p 'gdev-layout--display-advice 'display-buffer))
          (name " *gdev-forks-completion*") events
          (origin (selected-window)))
      (unwind-protect
          (progn
            (when layout-display (advice-remove 'display-buffer 'gdev-layout--display-advice))
            (let ((result
                 (sly--completion-with-displayed-buffer-window name
                     `((display-buffer-pop-up-window)
                       (body-function . ,(lambda (_window) (push 'previous events)))
                       (window-height . ,(lambda (window)
                                           (should (equal "Testo" (with-current-buffer (window-buffer window) (buffer-string))))
                                           (push 'height events))))
                     (lambda (_window value) (push 'quit events) value)
                   (should (get-buffer-window (current-buffer)))
                   (insert "Testo") (push 'body events) :completed)))
            (should (eq :completed result))
            (should (equal '(previous body height quit) (nreverse events)))
            (should (eq origin (selected-window)))))
        (when layout-display (advice-add 'display-buffer :around 'gdev-layout--display-advice))
        (when (get-buffer name) (kill-buffer name))))))

(ert-deftest gdev-test-forks-web-server-preserves-framing-and-authentication-closures ()
  (require 'web-server)
  (dolist (size '(0 125 126 65535 65536))
    (let* ((body (make-string size ?x)) (frame (ws-web-socket-frame body))
           (length-size (cond ((< size 126) 0) ((< size 65536) 2) (t 8))))
      (should (= (+ 2 length-size size) (length frame)))
      (should (= 129 (aref frame 0)))
      (should (string-suffix-p body frame))
      (when (> length-size 0)
        (let ((decoded 0))
          (dotimes (index length-size) (setq decoded (+ (ash decoded 8) (aref frame (+ 2 index)))))
          (should (= size decoded))))))
  (let* ((called nil)
         (wrapper (ws-with-authentication
                   (lambda (_) (push 'accepted called)) '(("utente" . "password")) nil
                   (lambda (_) (push 'missing called)) (lambda (_) (push 'invalid called)))))
    (dolist (credentials '(nil ("utente" . "errata") ("utente" . "password")))
      (let ((request (make-instance 'ws-request)))
        (setf (headers request) (and credentials (list (cons :AUTHORIZATION (cons 'basic credentials)))))
        (funcall wrapper request)))
    (should (equal '(accepted invalid missing) called))))

(provide 'gdev-forks-test)
;;; gdev-forks-test.el ends here
