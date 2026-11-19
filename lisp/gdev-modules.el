;;; gdev-modules.el --- Sistema dei moduli: gdev!, caricamento, file privati -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; GDev-Emacs è un piccolo nucleo (lisp/) più i moduli in
;; modules/CATEGORY/MODULE/config.el.  Il file privato init.el li attiva:
;;
;;   (gdev! :completion vertico corfu
;;          :editor (format +onsave) snippets
;;          :lang cc perl)
;;
;; Un modulo è un simbolo, oppure (MODULE +FLAG...) per attivare le opzioni
;; (flag) che il modulo documenta.  I moduli si caricano nell'ordine del
;; blocco. La compilazione include tutti i sorgenti Lisp nella loro cartella.
;;
;; Un modulo dichiara i suoi pacchetti dove li configura (use-package
;; :ensure): un modulo disattivato non installa e non carica nulla.
;; `gdev sync' installa ciò che serve ai moduli attivi, rimuove ciò che non
;; serve più e compila il risultato in codice intermedio (bytecode).

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)

(defvar gdev-user-directory)            ; early-init.el

;;;; Dichiarazione dei moduli

(defconst gdev-module-categories
  '(:completion :ui :editor :emacs :term :checkers :tools :os :lang :app :config)
  "Categorie dei moduli, cioè le cartelle sotto modules/.")

(defvar gdev-modules nil
  "Moduli dichiarati, in ordine di caricamento.
Ogni elemento è (CATEGORY MODULE . FLAGS).")

(defvar gdev-modules-private-errors nil
  "Errori incontrati caricando init.el e packages.el privati: (FILE . MESSAGGIO).
Senza questo elenco un file privato rotto lascia solo un avviso su stderr.")

(defvar gdev-failed-modules nil
  "(CATEGORY MODULE ERROR) per ogni modulo che non si è caricato.")

(defvar gdev-modules--loading nil
  "Coppia (CATEGORY MODULE) del modulo in attivazione.")

(defun gdev-modules--add-private-load-path ()
  "Aggiungi le librerie dei moduli personali attivi dopo quelle distribuite."
  (dolist (entry gdev-modules)
    (let ((directory (gdev-module-directory (car entry) (cadr entry))))
      (when (gdev-private-module-file-p directory)
        (add-to-list 'load-path directory t)))))

(defconst gdev-module--aliases
  '((:ui (popup . workbench))
    (:tools (github . hithub))
    (:lang (sql . postgresql)))
  "Nomi alternativi per i moduli distribuiti.")

(defun gdev-module--canonical-name (category module)
  "Risolve il nome di MODULE nella CATEGORY dichiarata."
  (or (alist-get module (alist-get category gdev-module--aliases)) module))

(defun gdev-module-directory (category &optional module)
  "Restituisce la cartella di CATEGORY, o quella di MODULE al suo interno."
  (let* ((name (and module (symbol-name (gdev-module--canonical-name category module))))
         (relative (format "modules/%s/%s" (string-remove-prefix ":" (symbol-name category)) (or name "")))
         (bundled (file-name-as-directory (gdev-config-file relative)))
         (private (file-name-as-directory (expand-file-name relative gdev-user-directory))))
    (if (and name (memq category gdev-module-categories)
             (not (file-regular-p (expand-file-name "config.el" bundled)))
             (file-regular-p (expand-file-name "config.el" private)))
        private
      bundled)))

(defconst gdev-module-shared-directory
  (gdev-module-directory :ui 'workbench)
  "Cartella delle librerie condivise con il nucleo.")

(add-to-list 'load-path gdev-module-shared-directory)

(defun gdev-module-shared-sources ()
  "Elenca le librerie richieste dal nucleo anche senza configurare Workbench."
  (mapcar (lambda (file) (expand-file-name file gdev-module-shared-directory))
          '("gdev-ui.el" "gdev-layout.el")))

(defun gdev-module-file (category module &optional extension)
  "Restituisce il file config di MODULE in CATEGORY, con EXTENSION se data.
Senza EXTENSION `load' sceglie il file compilato in codice intermedio
\(bytecode), se aggiornato."
  (concat (gdev-module-directory category module) "config" (or extension "")))

(defun gdev-module-source-files (category module)
  "Elenca i sorgenti Lisp di MODULE in CATEGORY, con config.el per ultimo."
  (let* ((config (gdev-module-file category module ".el"))
         (sources (directory-files (file-name-directory config) t "\\`[^.].*\\.el\\'")))
    (append (delete config (seq-filter #'file-regular-p sources)) (list config))))

(defun gdev-modules--declare (declarations)
  "Imposta `gdev-modules' dalle DECLARATIONS di un blocco `gdev!'."
  (let ((entries (make-hash-table :test #'equal))
        category modules)
    (dolist (item declarations)
      (cond ((keywordp item)
             (unless (memq item gdev-module-categories)
               (display-warning 'gdev (format "gdev!: categoria sconosciuta %s" item)))
             (setq category item))
            ((null category)
             (error "gdev!: %S compare prima di qualsiasi :categoria" item))
            (t
             (let* ((module (gdev-module--canonical-name category (if (consp item) (car item) item)))
                    (flags (and (consp item) (cdr item)))
                    (key (cons category module))
                    (entry (gethash key entries)))
               (cond (entry
                      (setf (cddr entry) (delete-dups (append (cddr entry) flags nil))))
                     ((file-exists-p (gdev-module-file category module ".el"))
                      (let ((entry (cons category (cons module (delete-dups (copy-sequence flags))))))
                        (puthash key entry entries)
                        (push entry modules)))
                     (t (display-warning 'gdev (format "gdev!: modulo %s %s inesistente, ignorato"
                                                      category module))))))))
    (setq gdev-modules (nreverse modules))
    (gdev-modules--add-private-load-path)))

(defmacro gdev! (&rest declarations)
  "Attiva i moduli.  DECLARATIONS alterna una :categoria e i suoi moduli.
Un modulo è un simbolo, o una lista (MODULE +FLAG...) che attiva opzioni.
Ripetere un modulo aggiunge opzioni alla prima dichiarazione."
  `(gdev-modules--declare ',declarations))

(defun gdev-module--declaration (category module)
  "Restituisci la dichiarazione di MODULE in CATEGORY."
  (cl-find-if (lambda (entry) (and (eq (car entry) category) (eq (cadr entry) module)))
              gdev-modules))

(defun gdev-module--failure (category module)
  "Restituisci il fallimento registrato per MODULE in CATEGORY."
  (cl-find-if (lambda (entry) (and (eq (car entry) category) (eq (cadr entry) module)))
              gdev-failed-modules))

(defun gdev-module--loading-p (category module)
  "Indica se è in corso la valutazione di MODULE in CATEGORY."
  (and gdev-modules--loading
       (eq category (car gdev-modules--loading))
       (eq module (cadr gdev-modules--loading))))

(defun gdev-module-p (category module &optional flag)
  "Indica se MODULE di CATEGORY è dichiarato e utilizzabile.
Con FLAG, richiede che l'opzione sia stata dichiarata.
Durante l'avvio le dichiarazioni successive sono consultabili."
  (when-let* ((module (gdev-module--canonical-name category module))
              (entry (gdev-module--declaration category module))
              ((or (gdev-module--loading-p category module)
                   (not (gdev-module--failure category module)))))
    (or (null flag) (memq flag (cddr entry)))))

(defconst gdev-modules--language-suffixes
  '(("go" . go) ("rs" . rust) ("swift" . swift) ("zig" . zig)
    ("java" . java) ("cs" . csharp))
  "Estensioni dei linguaggi opzionali da suggerire all'apertura.")

(defun gdev-modules-suggest-language ()
  "Indica come abilitare il modulo GDev del file appena aperto."
  (when-let* (((not noninteractive))
              (file buffer-file-name)
              (module (assoc-default (or (file-name-extension file) "")
                                     gdev-modules--language-suffixes))
              ((not (gdev-module-p :lang module))))
    (message "Per questo file aggiungi %s a :lang in %s, poi esegui gdev sync."
             module (abbreviate-file-name (gdev-user-file "init.el")))))

(add-hook 'find-file-hook #'gdev-modules-suggest-language 95)

(defun gdev-modules-missing-from-template ()
  "Elenca i moduli del modello assenti dalla configurazione corrente."
  (let ((active gdev-modules)
        (gdev-modules nil)
        (load-path (copy-sequence load-path)))
    (load (gdev-config-file "templates/init.el") nil t t)
    (cl-remove-if (lambda (entry)
                    (cl-find (cl-subseq entry 0 2) active :test #'equal
                             :key (lambda (module) (cl-subseq module 0 2))))
                  gdev-modules)))

;;;; File privati

(defconst gdev-private-config-names '("init" "packages" "config")
  "Nomi, senza estensione, dei file della configurazione privata.")

(defun gdev-user-file (name)
  "Restituisce NAME dentro la cartella della configurazione privata."
  (expand-file-name name gdev-user-directory))

(defun gdev-private-module-file-p (file)
  "Indica se FILE appartiene a un modulo personale."
  (string-prefix-p (file-name-as-directory (gdev-user-file "modules")) file))

(defun gdev-modules--private-file (name)
  "Restituisce il file privato NAME.el o, se manca, quello in templates/."
  (let ((private (gdev-user-file (concat name ".el"))))
    (if (file-exists-p private)
        private
      (gdev-config-file (concat "templates/" name ".el")))))

(defun gdev-modules--load-private (name &optional source-only)
  "Carica il file privato NAME, preferendo il bytecode se aggiornato.
Con SOURCE-ONLY carica sempre il sorgente.  I modelli si caricano da .el."
  (let* ((source (gdev-modules--private-file name))
         (bytecode (concat source "c"))
         (file (if (and (not source-only)
                        (equal source (gdev-user-file (concat name ".el")))
                        (file-regular-p bytecode)
                        (file-readable-p bytecode)
                        (not (file-newer-than-file-p source bytecode)))
                   bytecode
                 source)))
    (if init-file-debug
        (load file nil 'nomessage 'nosuffix)
      (condition-case err
          (load file nil 'nomessage 'nosuffix)
        (error
         (push (cons file (error-message-string err)) gdev-modules-private-errors)
         (display-warning 'gdev (format "%s: %s" file (error-message-string err))
                          :error))))))

;;;; Pacchetti aggiuntivi (packages.el privato)

(defvar gdev-packages nil
  "Pacchetti dichiarati con `gdev-package', che `gdev sync' conserva.")

(defun gdev-package (package &rest properties)
  "Assicura che PACKAGE sia installato e attivo.
PROPERTIES può contenere :vc URL, un repository Git per i pacchetti
assenti da ogni archivio, e :rev REVISION.  In un avvio normale costa una
ricerca in una lista; l'installazione avviene solo se il pacchetto manca."
  (cl-pushnew package gdev-packages)
  (unless (memq package (bound-and-true-p package-activated-list))
    (if-let* ((url (plist-get properties :vc)))
        (gdev-package-vc-ensure package url (plist-get properties :rev))
      (gdev-package-ensure package '(t) nil))))

;;;; Caricamento

(defvar gdev-module-load-times nil
  "((CATEGORY MODULE) . SECONDS) per modulo caricato, il più lento in fondo.")

(defvar gdev-after-init-hook nil
  "Gancio (hook) eseguito dopo i moduli e il config.el privato.")

(defun gdev-module-status (category module)
  "Restituisci lo stato di MODULE in CATEGORY o nil se assente."
  (let ((module (gdev-module--canonical-name category module)))
    (cond ((gdev-module--loading-p category module) 'loading)
          ((gdev-module--failure category module) 'failed)
          ((assoc (list category module) gdev-module-load-times) 'active)
          ((gdev-module--declaration category module) 'declared))))

(defun gdev-modules--load (category module)
  "Carica MODULE di CATEGORY, ne misura il tempo e segnala un errore."
  (let* ((module (gdev-module--canonical-name category module))
         (key (list category module))
         (file (gdev-module-file category module))
         (gdev--bundled-packages-only (not (gdev-private-module-file-p file)))
         (previous-failure (gdev-module--failure category module))
         (start (float-time)))
    (condition-case-unless-debug err
        (gdev-load-module-registrations
         (lambda ()
           (let ((gdev-modules--loading key))
             (load file nil 'nomessage)))
         (lambda ()
           (setq gdev-failed-modules (delq previous-failure gdev-failed-modules))
           (setf (alist-get key gdev-module-load-times nil nil #'equal)
                 (- (float-time) start))))
      (error
       (when init-file-debug (signal (car err) (cdr err)))
       (setq gdev-failed-modules
             (cons (list category module err) (delq previous-failure gdev-failed-modules)))
       (display-warning 'gdev
                        (format "Modulo %s %s non caricato: %s\nEsegui `gdev doctor' o avvia Emacs con --debug-init."
                                category module (error-message-string err))
                        :error)))
    (setf (alist-get key gdev-module-load-times nil nil #'equal)
          (- (float-time) start))))

(defun gdev-modules-initialize ()
  "Carica init.el e packages.el privati, ogni modulo attivo, poi config.el."
  (gdev-modules--load-private "init")
  (gdev-modules--load-private "packages")
  (pcase-dolist (`(,category ,module . ,_) gdev-modules)
    (gdev-modules--load category module))
  (setq gdev-module-load-times (sort gdev-module-load-times :key #'cdr))
  (gdev-modules--load-private "config")
  (run-hooks 'gdev-after-init-hook))

;;;; Descrizione dei moduli

(defun gdev-modules-available ()
  "Restituisce i moduli su disco come (CATEGORY . MODULE), per categoria."
  (delete-dups
   (cl-loop for category in gdev-module-categories
            for bundled = (gdev-module-directory category)
            for private = (gdev-user-file (concat "modules/" (substring (symbol-name category) 1)))
            append (cl-loop for directory in (list bundled private)
                            when (file-directory-p directory)
                            append (cl-loop for name in (directory-files directory nil "^[[:alnum:]_-]+$")
                                            when (file-regular-p (expand-file-name (concat name "/config.el") directory))
                                            collect (cons category (intern name)))))))

(declare-function gdev-ui-module-icon "gdev-ui")
(declare-function lm-summary "lisp-mnt" (&optional file))
(declare-function lm-commentary "lisp-mnt" (&optional file))

(defun gdev-describe-module (category module)
  "Mostra la guida di MODULE in CATEGORY e un collegamento al sorgente."
  (interactive
   (let* ((candidates (mapcar (lambda (entry)
                                (cons (format "%s %s%s" (car entry) (cdr entry)
                                              (pcase (gdev-module-status (car entry) (cdr entry))
                                                ('failed "  (caricamento fallito)")
                                                ('nil "  (disattivato)")
                                                (_ "")))
                                      entry))
                              (gdev-modules-available)))
          (completion-extra-properties
           (when (fboundp 'gdev-ui-module-icon)
             (list :annotation-function
                   (lambda (candidate)
                     (when-let* ((entry (cdr (assoc candidate candidates))))
                       (concat "  " (gdev-ui-module-icon (car entry) (cdr entry))))))))
          (choice (cdr (assoc (completing-read "Modulo: " candidates nil t) candidates))))
     (list (car choice) (cdr choice))))
  (require 'lisp-mnt)
  (let* ((module (gdev-module--canonical-name category module))
         (id (format "%s %s" category module))
         (file (gdev-module-file category module ".el"))
         (documentation (with-temp-buffer
                          (insert-file-contents file)
                          (cons (lm-summary) (lm-commentary)))))
    (let ((inhibit-message t)
          (message-log-max nil))
      (with-help-window (format "*Guida del modulo %s*" id)
        (with-current-buffer standard-output
          (insert (propertize (string-remove-prefix
                               (concat id ": ") (or (car documentation) id))
                              'face 'bold)
                  "\n\n"
                  (or (cdr documentation) "Guida del modulo non disponibile.")
                  "\n\n")
          (insert-text-button "Apri il sorgente del modulo"
                              'follow-link t
                              'action (lambda (_) (view-file file)))
          (insert "\n\nPremi q per chiudere questa guida.\n"))))))

(defun gdev-module-load-report ()
  "Mostra quanto ha impiegato ogni modulo a caricarsi, dal più lento."
  (interactive)
  (with-current-buffer (get-buffer-create "*gdev-modules*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Emacs pronto in %s. %d moduli dichiarati, %d con errori.\n\n"
                      (emacs-init-time "%.3fs") (length gdev-modules) (length gdev-failed-modules)))
      (pcase-dolist (`((,category ,module) . ,seconds) (reverse gdev-module-load-times))
        (insert (format "%8.1f ms  %s %s%s\n" (* 1000 seconds) category module
                        (if (gdev-module--failure category module) "  (caricamento fallito)" "")))))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(provide 'gdev-modules)
;;; gdev-modules.el ends here
