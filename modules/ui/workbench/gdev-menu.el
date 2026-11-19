;;; gdev-menu.el --- Barra dei menu di GDev-Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La barra raggruppa i comandi per attività, con quelli frequenti in
;; primo piano. I sottomenu dei moduli e del linguaggio corrente leggono
;; le mappe dei tasti, comprese le modifiche della configurazione privata.

;;; Code:

(require 'easymenu)
(require 'cl-lib)
(require 'seq)
(require 'gdev-handlers)
(require 'gdev-keys)
(require 'gdev-modules)
(require 'gdev-workspace-roots)
(require 'gdev-workspace-state)

(declare-function gdev-editor-document "gdev-commands")
(declare-function gdev-context--timeline-target "gdev-context" ())

;;;; Menu dalle mappe dei tasti

(defun gdev-menu--label (text)
  "Restituisce TEXT con l'iniziale maiuscola, come nei menu di macOS."
  (if (string-empty-p text) text (concat (upcase (substring text 0 1)) (substring text 1))))

(defun gdev-menu--command-label (command)
  "Restituisci la forma leggibile di un COMMAND privo di descrizione.
Usa l'etichetta registrata con `gdev-keys-register-commands', se esiste."
  (gdev-menu--label
   (or (gdev-keys-command-label command t)
       (string-replace "-" " " (string-remove-prefix "gdev-" (symbol-name command))))))

(defun gdev-menu--event< (a b)
  "Ordina gli eventi A e B: per lettera, la minuscola prima della maiuscola."
  (let ((a (key-description (vector a)))
        (b (key-description (vector b))))
    (if (string= (downcase a) (downcase b))
        (string> a b)
      (string< (downcase a) (downcase b)))))

(defun gdev-menu-command-available-p (command)
  "Indica se COMMAND è definito e utilizzabile nel contesto corrente.
Un modulo dichiara quando un suo comando si può usare con la proprietà
`gdev-menu-available': una funzione senza argomenti valutata nella vista
corrente.  La barra dei menu mostra in grigio il comando non disponibile,
Comandi non lo elenca: un clic non resta senza esito."
  (and (commandp command)
       (if-let* ((predicate (get command 'gdev-menu-available)))
           (condition-case nil (funcall predicate) (error nil))
         t)))

(defun gdev-menu--binding-item (label command key)
  (vconcat (list label command :active `(gdev-menu-command-available-p ',command))
           (gdev-menu--preferred-key key command)))

(defun gdev-menu--items (keymap prefix)
  "Restituisce le voci di menu di KEYMAP, i cui tasti seguono PREFIX.
Le sottomappe con nome diventano sottomenu; ogni voce porta la sua
scorciatoia completa."
  (let (entries)
    (map-keymap (lambda (event binding)
                  (unless (assq event entries)
                    (push (cons event binding) entries)))
                keymap)
    (delq nil
          (mapcar
           (pcase-lambda (`(,event . ,binding))
             (let ((keys (concat prefix " " (key-description (vector event)))))
               (pcase binding
                 (`(,(and label (pred stringp)) . ,(and map (pred keymapp)))
                  (cons (gdev-menu--label label) (gdev-menu--items map keys)))
                 ;; Un comando non ancora disponibile resta visibile, in grigio.
                 (`(,(and label (pred stringp)) . ,(and command (pred symbolp)))
                  (gdev-menu--binding-item (gdev-menu--label label) command keys))
                 (`(,(and label (pred stringp)) . ,(and command (pred commandp)))
                  (gdev-menu--binding-item (gdev-menu--label label) command keys))
                 ((and (pred symbolp) (guard binding))
                  (gdev-menu--binding-item (gdev-menu--command-label binding) binding keys)))))
           (sort entries (lambda (a b) (gdev-menu--event< (car a) (car b))))))))

(defun gdev-menu--language-map ()
  "Restituisce la mappa C-c l attiva nell'area di testo corrente, se esiste."
  (let ((map (key-binding (kbd "C-c l"))))
    (and (keymapp map) map)))

;;;; Barra dei menu

(defcustom gdev-menu-personal-items nil
  "Voci aggiuntive di Strumenti › Comandi personali, nel formato easy-menu."
  :type '(repeat (choice (vector (string :tag "Nome nel menu")
                                  (function :tag "Comando"))
                         (sexp :tag "Voce avanzata")))
  :group 'gdev)

(defcustom gdev-menu-show-mode-menus nil
  "Se non nil, aggiunge alla barra anche i menu forniti dalle modalità."
  :type 'boolean
  :group 'gdev)

(defvar gdev-menu--mode-maps nil)
(defvar-local gdev-menu--hidden-events nil)
(defvar-local gdev-menu-local-events nil
  "Eventi di menu locali già adattati all'interfaccia di GDev.")

(defun gdev-menu--hide-mode-menus ()
  "Aggiorna la mappa che nasconde i menu aggiunti dalle modalità."
  (let (events)
    (unless gdev-menu-show-mode-menus
      (let ((gdev-menu--mode-maps nil))
        (dolist (map (current-active-maps nil (point)))
          (unless (eq map (current-global-map))
            (when-let* ((menu (lookup-key map [menu-bar]))
                        ((keymapp menu)))
              (map-keymap (lambda (event _binding)
                            (unless (memq event gdev-menu-local-events)
                              (cl-pushnew event events)))
                          menu))))))
    (unless (equal events gdev-menu--hidden-events)
      (setq-local gdev-menu--hidden-events events)
      (setq-local gdev-menu--mode-maps
                  (when events
                    (let ((map (make-sparse-keymap)))
                      (dolist (event events)
                        (define-key map (vector 'menu-bar event) #'undefined))
                      (list (cons 'menu-bar-mode map))))))))

(defconst gdev-menu--sections
  '((gdev-file "File"
     ["Nuovo documento" gdev-new-buffer :key-sequence "s-n"]
     ["Appunti" gdev-scratch :key-sequence "C-c b x"]
     ["Apri file…" gdev-open-file :key-sequence "s-o"]
     ["Apri cartella…" gdev-open-folder :key-sequence "s-O"]
     ["Apri recenti…" (consult-recent-file recentf-open)]
     ["Confronta due file…" gdev-compare-files]
     ["Confronta con il file salvato" gdev-compare-with-saved
      :active (when-let* ((document (gdev-editor-document))) (buffer-file-name document))]
     ["Unisci tre file…" gdev-merge-files :key-sequence "C-c g 3"]
     ["Risolvi i conflitti…" gdev-merge-conflict :key-sequence "C-c g !" :active (gdev-editor-document)]
     ["Riprendi l’unione" gdev-merge-resume
      :active (and (fboundp 'gdev-merge-preview-available-p) (gdev-merge-preview-available-p))]
     ["Cronologia del file" gdev-timeline-open :active (gdev-context--timeline-target)
      :key-sequence "C-c f h"]
     ["Mostra nel Finder" gdev-macos-reveal-in-finder]
     "--"
     ["Salva" gdev-save-document :active (when-let* ((document (gdev-editor-document)))
                                           (buffer-modified-p document)) :key-sequence "s-s"]
     ["Salva con nome…" gdev-save-document-as :active (gdev-editor-document) :key-sequence "s-S"]
     ["Salva tutti i file" gdev-save-all-documents :key-sequence "M-s-s"]
     ["Ricarica dal disco" gdev-reload-document
      :active (when-let* ((document (gdev-editor-document))) (buffer-file-name document))]
     ["Stampa…" gdev-print-document :active (gdev-editor-document)]
     ["Chiudi vista" gdev-close-document :key-sequence "s-w"]
     ["Riapri l’ultima scheda chiusa" gdev-layout-reopen-document
      :active (gdev-layout--closed-documents) :key-sequence "s-T"]
     ["Conserva le bozze" gdev-drafts-toggle-hot-exit :style toggle
      :selected (bound-and-true-p gdev-drafts-hot-exit)]
     "--"
     (:group "Gestione file" gdev-file-map "C-c f")
     (:group "Documenti aperti" gdev-buffer-map "C-c b")
     (:group "Sessione" gdev-quit-map "C-c q"))
    (gdev-edit "Modifica"
     ["Annulla" gdev-undo :active (gdev-undo-available-p)
      :key-sequence "s-z"]
     ["Ripeti" gdev-redo :active (gdev-redo-available-p) :key-sequence ("s-Z" "s-y")]
     ["Annulla operazione dello spazio" gdev-operation-undo
      :active (and (fboundp 'gdev-operation-undo-label) (gdev-operation-undo-label))
      :key-sequence "C-c w z"]
     ["Ripeti operazione dello spazio" gdev-operation-redo
      :active (and (fboundp 'gdev-operation-redo-label) (gdev-operation-redo-label))
      :key-sequence "C-c w Z"]
     "--"
     ["Taglia" gdev-cut-dwim :active (not buffer-read-only) :key-sequence "s-x"]
     ["Copia" gdev-copy-dwim :key-sequence "s-c"]
     ["Incolla" yank :active (not buffer-read-only) :key-sequence "s-v"]
     ["Cronologia appunti…" (consult-yank-pop yank-pop) :active (not buffer-read-only)]
     "--"
     ["Duplica riga o selezione" duplicate-dwim :active (not buffer-read-only)
      :key-sequence "s-D"]
     ["Aumenta rientro" gdev-indent-right :active (not buffer-read-only) :key-sequence "s-]"]
     ["Riduci rientro" gdev-indent-left :active (not buffer-read-only) :key-sequence "s-["]
     ["Elimina fino a inizio riga" gdev-kill-to-line-start :active (not buffer-read-only)
      :key-sequence "s-<backspace>"]
     (:group "Inserisci" gdev-insert-map "C-c i"))
    (gdev-selection "Selezione"
     ["Seleziona tutto" mark-whole-buffer :key-sequence "s-a"]
     ["Espandi selezione" expreg-expand :key-sequence "C-+"]
     ["Seleziona blocco" mark-paragraph]
     ["Modifica selezione come rettangolo" rectangle-mark-mode :style toggle
      :selected (bound-and-true-p rectangle-mark-mode)]
     "--"
     ["Aggiungi occorrenza successiva" mc/mark-next-like-this-word :key-sequence "s-d"]
     ["Cursori sulle righe selezionate" mc/edit-lines :active (use-region-p)]
     ["Seleziona tutte le occorrenze" mc/mark-all-dwim])
    (gdev-search "Cerca"
     ["Trova…" isearch-forward :key-sequence "s-f"]
     ["Trova successivo" gdev-find-next :active (gdev-find-repeat-available-p)
      :key-sequence "s-g"]
     ["Trova precedente" gdev-find-previous :active (gdev-find-repeat-available-p)
      :key-sequence "s-G"]
     ["Sostituisci…" query-replace :active (not buffer-read-only)]
     "--"
     ["Cerca nei file…" (gdev-search-query consult-ripgrep project-find-regexp) :key-sequence "s-F"]
     ("Comandi di Cerca"
      ["Nuova ricerca…" gdev-search-query :active (derived-mode-p 'gdev-search-mode)]
      ["Ripeti ricerca" gdev-search-repeat :active (derived-mode-p 'gdev-search-mode)]
      ["Filtra percorsi…" gdev-search-filters :active (derived-mode-p 'gdev-search-mode)]
      ["Azzera filtri" gdev-search-clear-filters :active (gdev-search-path-filters-p)]
      ["Espressione regolare" gdev-search-toggle-regexp :style toggle
       :active (derived-mode-p 'gdev-search-mode) :selected (bound-and-true-p gdev-search--regexp)]
      ["Distingui maiuscole e minuscole" gdev-search-toggle-case :style toggle
       :active (derived-mode-p 'gdev-search-mode) :selected (bound-and-true-p gdev-search--case-sensitive)]
      ["Parola intera" gdev-search-toggle-word :style toggle
       :active (derived-mode-p 'gdev-search-mode) :selected (bound-and-true-p gdev-search--whole-word)]
      ["Includi file ignorati" gdev-search-toggle-ignored :style toggle
       :active (derived-mode-p 'gdev-search-mode) :selected (bound-and-true-p gdev-search--include-ignored)]
      ["Risultato successivo" gdev-search-next-hit :active (derived-mode-p 'gdev-search-mode)]
      ["Risultato precedente" gdev-search-previous-hit :active (derived-mode-p 'gdev-search-mode)]
      ["Apri risultato" gdev-search-visit :active (derived-mode-p 'gdev-search-mode)]
      ["Seleziona o deseleziona riga" gdev-search-toggle-hit :active (derived-mode-p 'gdev-search-mode)]
      ["Seleziona o deseleziona tutti" gdev-search-toggle-all :active (derived-mode-p 'gdev-search-mode)]
      ["Anteprima sostituzioni…" gdev-search-preview :active (derived-mode-p 'gdev-search-mode)]
      ["Applica sostituzioni" gdev-search-apply :active (bound-and-true-p gdev-search--plan)])
     ["Sostituisci nel progetto…" project-query-replace-regexp]
     (:group "Altre ricerche" gdev-search-map "C-c s"))
    (gdev-navigate "Vai a"
     ["Vai a qualsiasi cosa…" gdev-quick-open :key-sequence "s-p"]
     ["Documento aperto…" (gdev-modeline-switch-buffer consult-buffer switch-to-buffer)]
     ["Vai alla riga…" goto-line :key-sequence "s-l"]
     ["Simbolo nel documento…" (gdev-breadcrumb-symbols consult-imenu imenu)]
     ["Struttura del documento" gdev-outline-show :key-sequence "C-c w O"]
     ["Simbolo nel progetto…" gdev-find-project-symbol
      :visible (gdev-module-p :tools 'lsp) :key-sequence "C-c p s"]
     "--"
     ["Definizione" gdev-find-definition :key-sequence ("<f12>" "M-.")]
     ["Tutti i riferimenti" gdev-find-references :key-sequence ("S-<f12>" "M-?")]
     ["Vai all’implementazione" gdev-lsp-find-implementation :key-sequence "C-c c i"
      :active (gdev-lsp-capable-p :implementationProvider (gdev-editor-document))]
     ["Vai alla definizione del tipo" gdev-lsp-find-type-definition :key-sequence "C-c c t"
      :active (gdev-lsp-capable-p :typeDefinitionProvider (gdev-editor-document))]
     ["Torna alla posizione precedente" xref-go-back]
     ["Vai alla posizione successiva" xref-go-forward]
     ["Problema successivo" next-error :key-sequence "<f8>"]
     ["Problema precedente" previous-error :key-sequence "S-<f8>"])
    (gdev-view "Vista"
     ["Riquadro laterale" (gdev-activity-toggle gdev-sidebar-toggle) :style toggle
      :key-sequence "s-b" :selected (gdev-layout-left-window)]
     ["Comandi a destra" gdev-command-sidebar-toggle :style toggle
      :key-sequence ("M-s-b" "C-c w t") :selected (gdev-layout-command-sidebar-window)]
     ["Passa tra Comandi ed editor" gdev-command-sidebar-focus :key-sequence "C-c w T"]
     ["Scegli categoria di Comandi…" gdev-command-sidebar-select]
     ["Cerca comandi del contesto…" gdev-command-sidebar-find]
     ["Strumenti di scrittura" gdev-writing-open :key-sequence "C-c w W"
      :active (when-let* ((editor (gdev-layout-editor)))
                (with-current-buffer (window-buffer editor) (gdev-writing-context-p)))]
     ["Scegli vista laterale…" gdev-activity-select :key-sequence "C-c w v"]
     ("Attività"
      ["Esplora file" gdev-sidebar-focus]
      ["Cerca" gdev-search-show]
      ["Hit" gdev-project-view-git :visible (gdev-module-p :tools 'git)]
      ["Debug dello spazio" gdev-project-view-run]
      ["Test" gdev-project-view-tests :visible (gdev-module-p :tools 'build)]
      ["Lavorazioni" gdev-lavorazioni-pannello :key-sequence "C-c w L"])
     ["Passa tra Esplora file ed editor" gdev-sidebar-focus :key-sequence "s-0"]
     ["Pannello degli strumenti" gdev-popup-toggle :style toggle
      :key-sequence "s-j" :selected (window-with-parameter 'gdev-layout-panel t)]
     ["Problemi" gdev-checkers-toggle-problems :key-sequence ("s-M" "C-c ! P")]
     ["Problemi del documento" gdev-checkers-document-problems :key-sequence "C-c ! d"]
     ["Problemi del progetto" gdev-checkers-project-problems :key-sequence "C-c ! D"]
     ["Vai a uno strumento aperto…" gdev-layout-choose-panel
      :active (gdev-layout-open-tools) :key-sequence "s-J"]
     ["Apri terminale del progetto" gdev-term-project :key-sequence "C-c o t"
      :visible (gdev-module-p :term 'eat)]
     ["Nuovo terminale del progetto" gdev-term-new :key-sequence "C-c o n"
      :visible (gdev-module-p :term 'eat)]
     ["Nuovo terminale con profilo…" gdev-term-new-profile :key-sequence "C-c o p"
      :visible (gdev-module-p :term 'eat)]
     ["Affianca un terminale" gdev-term-split :key-sequence "C-c o s"
      :visible (gdev-module-p :term 'eat) :active (gdev-term-split-available-p)]
     ["Vai al terminale affiancato" gdev-term-focus-other :key-sequence "C-c o ]"
      :visible (gdev-module-p :term 'eat) :active (gdev-term-split-visible-p)]
     ["Cruscotto" gdev-dashboard]
     ["Aggiorna il cruscotto" gdev-dashboard-refresh :active (derived-mode-p 'gdev-dashboard-mode)]
     "--"
     ["Schermo intero" toggle-frame-fullscreen :style toggle
      :selected (memq (frame-parameter nil 'fullscreen) '(fullboth fullscreen))]
     ["Modalità concentrazione" gdev-layout-toggle-focus :style toggle
      :selected (frame-parameter nil 'gdev-layout-focus)]
     ["Minimappa" gdev-minimap-toggle :style toggle :active (and gdev-layout-mode (display-graphic-p))
      :selected (gdev-workspace-state-get 'gdev-layout-minimap-visible) :key-sequence "C-c t m"]
     ["A capo automatico" visual-line-mode :style toggle
      :selected (bound-and-true-p visual-line-mode)]
     ["Numeri di riga" display-line-numbers-mode :style toggle
      :selected (bound-and-true-p display-line-numbers-mode)]
     ["Cambia tema" gdev-ui-toggle-theme]
     ["Aspetto…" gdev-preferences-open-appearance :key-sequence "C-c t A"]
     ["Usa l’aspetto di sistema" gdev-ui-sync-appearance :visible gdev-macos-p]
     ["Carattere grande" gdev-big-font-mode :style toggle
      :selected (bound-and-true-p gdev-big-font-mode)]
     "--"
     ("Comandi di Esplora file"
      ["Mostra il file aperto nell’albero" gdev-sidebar-reveal-current-file]
      ["Apri voce selezionata" gdev-sidebar-open :active (derived-mode-p 'gdev-sidebar-mode)]
      ["Mostra anteprima della voce selezionata" gdev-sidebar-preview
       :active (derived-mode-p 'gdev-sidebar-mode)]
      ["Aggiorna" gdev-sidebar-refresh :active (derived-mode-p 'gdev-sidebar-mode)]
      ["Legenda Git" gdev-sidebar-git-legend]
      ["Apri terminale qui" gdev-sidebar-terminal :active (derived-mode-p 'gdev-sidebar-mode)]
      ["Apri sul web" gdev-sidebar-web :active (derived-mode-p 'gdev-sidebar-mode)]
      ["Torna all’editor" gdev-focus-editor :active (derived-mode-p 'gdev-sidebar-mode)])
     (:group "Opzioni di visualizzazione" gdev-toggle-map "C-c t"))
    (gdev-code "Codice"
     ["Commenta riga o selezione" comment-line :active (not buffer-read-only)
      :key-sequence "s-/"]
     ["Formatta" gdev-format-dwim :active (gdev-menu--can-format-p)]
     ["Formatta tutto il documento" gdev-format-buffer :active (gdev-menu--can-format-p)]
     ["Rinomina simbolo…" gdev-lsp-rename
      :active (gdev-lsp-capable-p :renameProvider (gdev-editor-document)) :key-sequence "C-c c r"]
     ["Estrai selezione…" gdev-lsp-extract
      :active (gdev-lsp-capable-p :codeActionProvider (gdev-editor-document)) :key-sequence "C-c c E"]
     ["Azioni sul codice…" gdev-lsp-code-actions
      :active (gdev-lsp-capable-p :codeActionProvider (gdev-editor-document)) :key-sequence "C-c c a"]
     ["Valuta" gdev-eval-dwim]
     ["Passa tra sorgente e intestazione" gdev-cc-switch-source-header
      :visible (derived-mode-p 'c-mode 'c++-mode 'objc-mode 'c-ts-mode 'c++-ts-mode)]
     "--"
     (:language)
     ["Problemi del documento" gdev-checkers-document-problems :key-sequence "C-c ! d"]
     (:group "Azioni sul codice" gdev-code-map "C-c c")
     (:group "Problemi e ortografia" gdev-checkers-map "C-c !"))
    (gdev-project "Progetto"
     ("Nuovo progetto"
      ["Articolo…" gdev-article-new-project]
      ["LaTeX…" gdev-latex-new-project])
     ["Panoramica dell’articolo" gdev-article-open-project :key-sequence "C-c j"
      :visible (and (derived-mode-p 'gdev-article-mode) (bound-and-true-p gdev-article--root))]
     ["Cambia progetto…" project-switch-project]
     ["Apri file del progetto…" project-find-file :key-sequence "C-c p f"]
     ["Dipendenze del progetto" gdev-project-dependencies-show :key-sequence "C-c p e"]
     ["Assicurazione del progetto" gdev-assurance-show :key-sequence "C-c p i"]
     ["Catalogo degli standard" gdev-assurance-catalog :key-sequence "C-c p I"]
     ["Apri spazio di lavoro…" tabspaces-open-or-create-project-and-workspace]
     ["Fidati di questa cartella…" gdev-trust-project :visible (not (file-remote-p default-directory))]
     ["Aggiungi cartella allo spazio…" gdev-workspace-add-folder]
     ["Rimuovi cartella dallo spazio…" gdev-workspace-remove-folder
      :active (and (fboundp 'gdev-workspace-roots) (gdev-workspace-roots))]
     "--"
     ["Compila" gdev-build :key-sequence ("s-B" "s-b" "<f7>")]
     ["Configura compilazione" gdev-build-configure :key-sequence "S-<f7>"]
     ["Esegui" gdev-run-dwim :key-sequence ("s-r" "C-<f5>")]
     ["Esegui un programma compilato…" gdev-build-run]
     ["Scegli profilo di avvio…" gdev-launch-select-profile]
     ["Esegui profilo selezionato" gdev-project-view-launch :active (eq (bound-and-true-p gdev-activity-kind) 'run)]
     ["Avvia debug del profilo selezionato" gdev-project-view-debug
      :active (and (gdev-module-p :tools 'debugger) (eq (bound-and-true-p gdev-activity-kind) 'run))]
     ["Esegui test" gdev-test-dwim :key-sequence ("s-u" "<f6>")]
     (:when (gdev-module-p :tools 'build) ("Test e copertura"
      ["Apri Test" gdev-project-view-tests]
      ["Rileva test" gdev-project-view-refresh :active (eq (bound-and-true-p gdev-activity-kind) 'test)]
      ["Esegui tutti" gdev-project-view-test-all
       :active (and (eq (bound-and-true-p gdev-activity-kind) 'test) (bound-and-true-p gdev-project-view--lines))]
      ["Esegui test al cursore" gdev-project-view-test-at-point :key-sequence "C-c p q"]
      ["Riesegui i falliti" gdev-project-view-test-failed :key-sequence "C-c p Q"]
      ["Misura copertura…" gdev-test-coverage-run :key-sequence "C-c p v"]
      ["Rapporto di copertura" gdev-test-coverage-show :key-sequence "C-c p V"]
      ["Importa rapporto LCOV…" gdev-test-coverage-import]))
     ["Esegui attività…" gdev-run-project-task :key-sequence "C-c p a"]
     ["Ripeti l’ultima attività" gdev-repeat-project-task :key-sequence "C-c p A"]
     ["Operazioni dello spazio" gdev-workbench-operations-show :key-sequence "C-c w N"]
     ["Interrompi l’operazione" gdev-workbench-operation-cancel :key-sequence "s-."]
     "--"
     ["Stato Git" gdev-git-status :visible (not (gdev-module-p :tools 'git))
      :key-sequence "C-c g g"]
     (:group "Controllo versione" gdev-git-map "C-c g" (not (gdev-module-p :tools 'git)))
     (:group "Gestione del progetto" gdev-project-map "C-c p"))
    (gdev-hithub "HitHub"
     ["Panoramica dell'archivio" gdev-github-overview :key-sequence "C-c g h h"]
     ["Guida di HitHub" hithub-guida]
     "--"
     (:keys gdev-github-map "C-c g h"))
    (gdev-hit "Git (Hit)"
     ["Apri Hit" (hit-status gdev-git-status) :key-sequence "C-c g g"]
     ["Guida di Hit" hit-guida]
     ["Mostra modifiche nel riquadro laterale" gdev-project-view-git]
     ["Aggiorna modifiche nel riquadro laterale" gdev-project-view-refresh
      :active (eq (bound-and-true-p gdev-activity-kind) 'git)]
     "--"
     (:group "Azioni di controllo versione" gdev-git-map "C-c g"))
    (gdev-tools "Strumenti"
     ["Tavolozza dei comandi…" gdev-command-palette :key-sequence "s-P"]
     ["Preferenze…" (gdev-preferences-open gdev-open-private-config) :key-sequence "s-,"]
     ["Scorciatoie…" gdev-preferences-open-shortcuts]
     ["Filtra preferenze…" gdev-preferences-filter :active (derived-mode-p 'gdev-preferences-mode)]
     ["Assegna scorciatoia…" gdev-preferences-edit-shortcut]
     ["Personalizza il menu…" gdev-menu-customize]
     (:personal)
     "--"
     ["Avvia o continua debug" gdev-debug-dwim :key-sequence "<f5>"]
     ["Eccezioni…" gdev-debug-exceptions
      :active (and (fboundp 'gdev-debug-exceptions-available-p)
                   (gdev-debug-exceptions-available-p))]
     ["Attiva o disattiva punto di interruzione" dape-breakpoint-toggle :key-sequence "<f9>"]
     ("Avvia con un debugger"
      ["Programma compilato con LLDB…" gdev-debug-program]
      ["Script Perl con Perl::LanguageServer…" gdev-debug-perl-file
       :visible (and buffer-file-name (derived-mode-p 'perl-mode 'cperl-mode))])
     (:group "Debug" gdev-debug-map "C-c d")
     (:group "Profilazione" gdev-profile-map "C-c P")
     ["Copertura di un progetto CMake" gdev-profile-llvm-coverage :visible (gdev-menu--cmake-p)]
     "--"
     ["Apri navigatore web…" gdev-web-browser :key-sequence "C-c o w"]
     ["Anteprima web affiancata" gdev-web-preview :key-sequence "C-c o W"]
     (:group "Terminali e altre utilità" gdev-open-map "C-c o")
     (:group "Connessioni remote" gdev-remote-map "C-c r")
     (:group "Agenti" gdev-agent-map "C-c a")
     (:group "Note e procedure" gdev-notes-map "C-c n")
     ["Installa grammatiche dei linguaggi" gdev-treesit-install-grammars]
     (:tool-actions)
     (:catalog))
    (gdev-window "Finestra"
     ["Nuova finestra" make-frame-command]
     ["Nuovo spazio di lavoro" tab-bar-new-tab :key-sequence "s-t"]
     ["Chiudi lo spazio corrente" tab-bar-close-tab :active (> (length (tab-bar-tabs)) 1)]
     ["Spazio di lavoro precedente" tab-bar-switch-to-prev-tab]
     ["Spazio di lavoro successivo" tab-bar-switch-to-next-tab]
     "--"
     ["Documenti aperti…" gdev-workspaces-switch-document :key-sequence "C-c b o"]
     ["Scheda di documento precedente" gdev-workspaces-previous-document :key-sequence "M-s-<left>"]
     ["Scheda di documento successiva" gdev-workspaces-next-document :key-sequence "M-s-<right>"]
     ["Sposta scheda a sinistra" gdev-workspaces-move-document-left
      :active (gdev-workspaces-document-move-available-p -1) :key-sequence "C-c b <left>"]
     ["Sposta scheda a destra" gdev-workspaces-move-document-right
      :active (gdev-workspaces-document-move-available-p 1) :key-sequence "C-c b <right>"]
     "--"
     ["Dividi a destra" gdev-split-editor-right :key-sequence "s-\\"]
     ["Dividi in basso" gdev-split-editor-below :key-sequence "C-c w <down>"]
     ["Griglia 2×2" gdev-split-editor-grid :key-sequence "C-c w g" :visible gdev-layout-mode]
     ["Ruota i due gruppi" gdev-rotate-editor-pair
      :visible gdev-layout-mode :active (= (length (gdev-layout--editors)) 2)]
     ["Affianca documento…" gdev-workspaces-open-beside :key-sequence "C-c w a"]
     ["Apri documento in basso…" gdev-workspaces-open-below :key-sequence "C-c w A"]
     ["Conserva anteprima" gdev-editor-pin-preview
      :active (let ((editor (gdev-layout-editor)))
                (and editor (gdev-editor-preview-p (window-buffer editor) editor)))]
     ["Sposta documento in un altro gruppo…" gdev-editor-move-to-group
      :active (and (fboundp 'gdev-editor-move-to-group-available-p)
                   (gdev-editor-move-to-group-available-p)) :key-sequence "C-c w M"]
     ["Passa al gruppo di modifica successivo" gdev-focus-other-editor :active (gdev-layout-split-p)
      :key-sequence "s-'"]
     ["Torna all’editor" gdev-focus-editor :active (window-parameter nil 'window-side)]
     ["Chiudi gruppo editor" gdev-close-editor-group :active (gdev-layout-split-p)
      :key-sequence "s-W"]
     ["Ingrandisci o ripristina riquadro" gdev-toggle-maximize-window]
     (:group "Disposizione e spazi di lavoro" gdev-workspace-map "C-c w"))
    (gdev-help "Aiuto"
     ["Scorciatoie di GDev" gdev-cheat-sheet]
     ["Diagnosi dell’ambiente" gdev-doctor]
     ("Ambiente della shell"
      ["Aggiorna dalla shell di login" gdev-env-refresh]
      ["Salva l’ambiente corrente" gdev-env-save-current])
     ["Descrivi modulo…" gdev-describe-module]
     ["Documentazione e firma al cursore" eldoc-doc-buffer :active (bound-and-true-p eldoc-mode)]
     ["Cerca nella documentazione…" apropos-documentation]
     "--"
     ["Guida a Emacs in italiano" gdev-emacs-guide :key-sequence "C-h d g"]
     ["Esercitazione di Emacs in italiano" gdev-emacs-tutorial-italian :key-sequence "C-h d i"]
     ["Manuale GNU di Emacs" info-emacs-manual]
     ["Informazioni su Emacs" about-emacs]
     (:group "Aiuto GDev" gdev-help-map "C-h d")))
  "Sezioni e voci nell'ordine in cui appaiono nella barra dei menu.")

(defun gdev-menu--submenu (label map prefix)
  "Crea un sottomenu LABEL dai comandi di MAP raggiungibili con PREFIX."
  (when-let* ((items (and map (gdev-menu--items map prefix))))
    (cons label items)))

(defun gdev-menu--language ()
  "Costruisce il sottomenu dei comandi del linguaggio corrente."
  (gdev-menu--submenu "Linguaggio corrente" (gdev-menu--language-map) "C-c l"))

(defun gdev-menu--can-format-p ()
  "Restituisce non nil se il documento corrente si può formattare."
  (and (not buffer-read-only)
       (or (gdev-handler :format)
           (and (bound-and-true-p eglot--managed-mode)
                (eglot-server-capable :documentFormattingProvider)))))

(declare-function eglot-server-capable "eglot")

(dolist (command '(gdev-format-dwim gdev-format-buffer))
  (put command 'gdev-menu-available #'gdev-menu--can-format-p))

(defun gdev-menu-customize ()
  "Apre le impostazioni dei comandi personali della barra."
  (interactive)
  (customize-option 'gdev-menu-personal-items))

(defun gdev-menu--catalog ()
  "Costruisce il catalogo dei gruppi configurati."
  (cons "Tutti i comandi GDev"
        (delq nil
              (append
               (mapcar (pcase-lambda (`(,key ,map ,label))
                         (gdev-menu--submenu (gdev-menu--label label)
                                             (symbol-value map) (concat "C-c " key)))
                       gdev-leader-groups)
               (list (gdev-menu--language)
                     (gdev-menu--submenu "Aiuto GDev" gdev-help-map "C-h d"))))))

(defvar ns-command-modifier 'super)
(defvar ns-alternate-modifier 'meta)
(defvar gdev-preferences-keybindings)
(defvar gdev-menu--defer-context nil
  "Conserva scorciatoie candidate e condizioni per le viste a richiesta.")

(defun gdev-menu--mac-key-label (event)
  "Restituisce la notazione macOS di EVENT, se i modificatori corrispondono."
  (let ((modifiers (event-modifiers event))
        (key (event-basic-type event)))
    (when (and (seq-every-p (lambda (modifier) (memq modifier '(control meta shift super)))
                            modifiers)
               (or (not (memq 'super modifiers))
                   (eq ns-command-modifier 'super))
               (or (not (memq 'meta modifiers))
                   (eq ns-alternate-modifier 'meta)))
      (concat (when (memq 'control modifiers) "⌃")
              (when (memq 'meta modifiers) "⌥")
              (when (memq 'shift modifiers) "⇧")
              (when (memq 'super modifiers) "⌘")
              (if (eq key 'backspace) "⌫"
                (upcase (if (characterp key) (char-to-string key) (symbol-name key))))))))

(defun gdev-menu-key-label (sequence)
  "Mostra SEQUENCE con la notazione dei tasti della finestra corrente."
  (if (eq (framep (selected-frame)) 'ns)
      (mapconcat (lambda (event)
                   (or (gdev-menu--mac-key-label event) (key-description (vector event))))
                 (append sequence nil) " ")
    (key-description sequence)))

(defun gdev-menu-command-key (command &optional keys)
  "Restituisci una scorciatoia effettiva di COMMAND fra quelle personali e KEYS."
  (seq-some (lambda (key)
              (when-let* (((stringp key)) ((key-valid-p key)) (sequence (kbd key)))
                (when (eq (key-binding sequence) command) sequence)))
            (append (mapcar #'car (seq-filter (lambda (entry) (eq (cdr entry) command))
                                              (bound-and-true-p gdev-preferences-keybindings)))
                    (ensure-list keys))))

(defun gdev-menu--preferred-key (keys command)
  "Mostra la scorciatoia effettiva di COMMAND nel formato della piattaforma."
  (if gdev-menu--defer-context
      (when keys (list :key-sequence keys))
    (when-let* ((sequence (gdev-menu-command-key command keys)))
      (if (eq (framep (selected-frame)) 'ns)
          (list :keys (gdev-menu-key-label sequence))
        (list :key-sequence sequence)))))

(defun gdev-menu--cmake-p ()
  "Verifica se la cartella attiva contiene un progetto CMake locale."
  (let ((directory (or (gdev-workspace-directory) default-directory)))
    (and (not (file-remote-p directory))
         (locate-dominating-file directory "CMakeLists.txt"))))

(defun gdev-menu--conditional-entry (condition resolver)
  "Risolvi una voce con RESOLVER conservando o verificando CONDITION."
  (if gdev-menu--defer-context
      (when-let* ((entry (funcall resolver)))
        (list :when condition entry))
    (when (eval condition t) (funcall resolver))))

(defun gdev-menu--entry (item)
  "Risolve una voce ITEM della barra per l'area di testo corrente."
  (pcase item
    (`(:when ,condition ,entry)
     (gdev-menu--conditional-entry condition (lambda () (gdev-menu--entry entry))))
    (`(:group ,label ,map ,prefix . ,condition)
     (if condition
         (gdev-menu--conditional-entry
          (car condition)
          (lambda () (when (boundp map) (gdev-menu--submenu label (symbol-value map) prefix))))
       (gdev-menu--submenu label (symbol-value map) prefix)))
    ('(:language) (gdev-menu--language))
    ('(:catalog) (gdev-menu--catalog))
    ('(:personal)
     (when gdev-menu-personal-items
       (cons "Comandi personali" gdev-menu-personal-items)))
    ('(:tool-actions)
     (when-let* ((groups (gdev-menu--entries
                          (mapcar (lambda (group) (cons (nth 1 group) (nthcdr 3 group)))
                                  gdev-tool-action-groups))))
       (cons "Moduli" groups)))
    ((pred vectorp)
     (let* ((choice (aref item 1))
            (command (if (consp choice) (seq-find #'commandp choice) choice))
            (properties (append (seq-drop item 2) nil))
            (keys (plist-get properties :key-sequence)))
       (when (commandp command)
         (when keys
           (cl-remf properties :key-sequence))
         ;; Senza una condizione propria vale quella dichiarata dal modulo.
         (when (and (get command 'gdev-menu-available)
                    (not (plist-member properties :active))
                    (not (plist-member properties :enable)))
           (setq properties (append properties
                                    `(:active (gdev-menu-command-available-p ',command)))))
         (vconcat (list (aref item 0) command) properties
                  (gdev-menu--preferred-key keys command)))))
    (`(,(and label (pred stringp)) . ,items)
     (when-let* ((entries (gdev-menu--entries items)))
       (cons label entries)))
    ((pred stringp) item)))

(defun gdev-menu--entries (items)
  "Risolve ITEMS e rimuove i separatori rimasti isolati."
  (let (entries)
    (dolist (item items)
      (pcase item
        (`(:keys ,map ,prefix)
         (when (boundp map)
           (dolist (entry (gdev-menu--items (symbol-value map) prefix))
             ;; Una voce già scritta per lo stesso comando non si ripete.
             (unless (and (vectorp entry)
                          (seq-some (lambda (seen)
                                      (and (vectorp seen) (equal (aref seen 1) (aref entry 1))))
                                    entries))
               (push entry entries)))))
        (_
         (when-let* ((entry (gdev-menu--entry item)))
           (unless (and (equal entry "--")
                        (or (null entries) (equal (car entries) "--")))
             (push entry entries))))))
    (when (equal (car entries) "--")
      (pop entries))
    (nreverse entries)))

(defun gdev-menu--section-enabled-p (event)
  "Restituisci non nil per le sezioni EVENT dei moduli attivi."
  (pcase event
    ('gdev-hithub (gdev-module-p :tools 'hithub))
    ('gdev-hit (gdev-module-p :tools 'git))
    (_ t)))

(defun gdev-menu-section-items (event &optional omit)
  "Risolvi le voci della sezione EVENT escludendo le forme in OMIT."
  (when (gdev-menu--section-enabled-p event)
    (gdev-menu--entries
     (seq-remove (lambda (item) (member item omit))
                 (cddr (assq event gdev-menu--sections))))))

(defun gdev-menu--available-item-p (item &optional include-disabled)
  "Valuta visibilità e disponibilità di ITEM.
INCLUDE-DISABLED ammette anche le voci disattivate."
  (let ((properties (append (seq-drop item 2) nil)))
    (condition-case nil
        (seq-every-p (lambda (key)
                       (or (not (plist-member properties key))
                           (eval (plist-get properties key) t)))
                     (if include-disabled '(:visible) '(:active :enable :visible)))
      (void-function nil)
      (void-variable nil))))

(defun gdev-menu-command-items (&optional include-disabled)
  "Restituisci le azioni dei menu attive come coppie (ETICHETTA . COMANDO).
Con INCLUDE-DISABLED includi le azioni visibili che richiedono un altro stato.
Le etichette includono la sezione per distinguere le omonimie."
  (let ((seen-commands (make-hash-table :test #'eq))
        (seen-labels (make-hash-table :test #'equal))
        result)
    (cl-labels ((collect (items section)
                  (dolist (item items)
                    (pcase item
                      ((pred vectorp)
                       (let* ((command (aref item 1))
                              (label (concat (aref item 0) " · " section)))
                         (when (and (commandp command) (not (eq command 'gdev-command-palette))
                                    (not (gethash command seen-commands))
                                    (gdev-menu--available-item-p item include-disabled))
                           (puthash command t seen-commands)
                           (let ((base label) (index 1))
                             (while (gethash label seen-labels)
                               (setq label (format "%s (%d)" base (cl-incf index)))))
                           (puthash label t seen-labels)
                           (push (cons label command) result))))
                      (`(,(and title (pred stringp)) . ,children)
                       (collect children (concat section " › " title)))))))
      (pcase-dolist (`(,event ,section . ,_) gdev-menu--sections)
        (collect (gdev-menu-section-items event '((:catalog) :catalog)) section)))
    (nreverse result)))

(defun gdev-menu-install ()
  "Installa la barra dei menu di GDev al posto di quella globale di Emacs."
  (let ((bar (make-sparse-keymap "Barra dei menu")))
    (define-key bar [mouse-1] #'menu-bar-open-mouse)
    (pcase-dolist (`(,event ,label . ,items) gdev-menu--sections)
      (when (gdev-menu--section-enabled-p event)
        (define-key-after bar (vector event)
          `(menu-item ,label ,(make-sparse-keymap label)
                      :filter ,(lambda (_menu)
                                 (easy-menu-create-menu label (gdev-menu--entries items)))))))
    (define-key global-map [menu-bar] bar))
  ;; La mappa di precedenza contiene solo eventi della barra dei menu.
  (add-to-list 'emulation-mode-map-alists 'gdev-menu--mode-maps)
  (add-hook 'menu-bar-update-hook #'gdev-menu--hide-mode-menus 90))

(provide 'gdev-menu)
;;; gdev-menu.el ends here
