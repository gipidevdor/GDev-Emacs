;;; config.el --- :ui workbench: interfaccia e disposizione di GDev -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Attiva l'aspetto, i menu, le viste laterali e i gruppi di modifica di GDev.
;; Comandi, minimappa e pannello seguono lo spazio di lavoro corrente.
;;
;;   C-`  o  C-'    mostra o nascondi il pannello
;;   C-c w r        sposta lo strumento attivo nell'area di modifica
;;   C-c w t        mostra o nasconde il riquadro Comandi
;;   C-c w T        passa tra Comandi ed editor

;;; Code:

(require 'gdev-ui)
(require 'gdev-menu)
(require 'gdev-layout)
(require 'gdev-context)
(require 'gdev-minimap)
(require 'gdev-activity)
(require 'gdev-editor-tabs)
(require 'gdev-search)
(require 'gdev-preferences)

(autoload 'gdev-workbench-operation-start "gdev-workbench-operations")
(autoload 'gdev-workbench-operation-compilation-start "gdev-workbench-operations")
(autoload 'gdev-workbench-operation-cancel "gdev-workbench-operations" nil t)
(autoload 'gdev-workbench-operations-show "gdev-workbench-operations" nil t)
(add-hook 'compilation-start-hook #'gdev-workbench-operation-compilation-start)

(autoload 'gdev-timeline-open "gdev-timeline" nil t)
(autoload 'gdev-outline-show "gdev-outline" nil t)
(autoload 'gdev-timeline-record "gdev-timeline")
(add-hook 'after-save-hook #'gdev-timeline-record)

(autoload 'gdev-web-browser "gdev-web-preview" nil t)
(autoload 'gdev-web-preview "gdev-web-preview" nil t)
(autoload 'gdev-project-dependencies-show "gdev-project-dependencies" nil t)
(dolist (command '(gdev-assurance-show gdev-assurance-show-active gdev-assurance-catalog gdev-assurance-new gdev-assurance-select
                   gdev-assurance-advance gdev-assurance-select-standards gdev-assurance-proof
                   gdev-assurance-standard-decision gdev-assurance-control-decision gdev-assurance-decision
                   gdev-assurance-adopt gdev-assurance-install-hooks gdev-assurance-evidence gdev-assurance-artifact
                   gdev-assurance-link gdev-assurance-record gdev-assurance-check-documents
                   gdev-assurance-generate-documents gdev-assurance-sign gdev-assurance-sign-amend
                   gdev-assurance-help gdev-assurance-project gdev-assurance-project-new gdev-assurance-create-project
                   gdev-assurance-work-bind gdev-assurance-snippet gdev-assurance-requirement-new
                   gdev-assurance-project-edit gdev-assurance-project-fill gdev-assurance-project-bind
                   gdev-assurance-taxonomy gdev-assurance-procedures gdev-assurance-procedure-plan
                   gdev-assurance-procedure-run gdev-assurance-procedure-resume))
  (autoload command "gdev-assurance-workbench" nil t))
(gdev-set-tool-actions 'assurance "Assicurazione" "test"
                       ["Assicurazione del progetto" gdev-assurance-show]
                       ["Catalogo degli standard" gdev-assurance-catalog]
                       ["Requisiti del progetto" gdev-assurance-project]
                       ["Nuovo requisito…" gdev-assurance-requirement-new]
                       ["Modelli…" gdev-assurance-snippet]
                       ["Collega scheda lavorazione…" gdev-assurance-work-bind]
                       ["Definisci progetto…" gdev-assurance-project-new]
                       ["Compila campo del progetto…" gdev-assurance-project-fill]
                       ["Collega definizione alla transazione" gdev-assurance-project-bind]
                       ["Tassonomie e copertura" gdev-assurance-taxonomy]
                       ["Procedure del progetto" gdev-assurance-procedures]
                       ["Controlla piano…" gdev-assurance-procedure-plan]
                       ["Avvia procedura…" gdev-assurance-procedure-run]
                       ["Nuova transazione…" gdev-assurance-new]
                       ["Adotta progetto esistente…" gdev-assurance-adopt]
                       ["Scegli transazione…" gdev-assurance-select]
                       ["Passaggio di stato…" gdev-assurance-advance]
                       ["Scegli standard…" gdev-assurance-select-standards]
                       ["Registra prova specifica…" gdev-assurance-proof]
                       ["Decisione sullo standard…" gdev-assurance-standard-decision]
                       ["Decisione sul controllo…" gdev-assurance-control-decision]
                       ["Raccogli prova…" gdev-assurance-evidence]
                       ["Registra artefatto…" gdev-assurance-artifact]
                       ["Collega artefatti…" gdev-assurance-link]
                       ["Registra valutazione" gdev-assurance-record]
                       ["Controlla documenti" gdev-assurance-check-documents]
                       ["Genera documenti" gdev-assurance-generate-documents]
                       ["Firma indice…" gdev-assurance-sign]
                       ["Firma amend…" gdev-assurance-sign-amend]
                       ["Installa ganci Git…" gdev-assurance-install-hooks]
                       ["Guida dell'assicurazione" gdev-assurance-help])
(dolist (command '(gdev-assurance-advance gdev-assurance-select-standards gdev-assurance-proof
                   gdev-assurance-standard-decision gdev-assurance-control-decision gdev-assurance-evidence gdev-assurance-artifact
                   gdev-assurance-link gdev-assurance-record gdev-assurance-sign gdev-assurance-sign-amend
                   gdev-assurance-work-bind gdev-assurance-snippet
                   gdev-assurance-project-bind gdev-assurance-procedure-run gdev-assurance-procedure-resume))
  (put command 'gdev-menu-available
       (lambda () (and (derived-mode-p 'gdev-assurance-mode) (bound-and-true-p gdev-assurance--transaction)))))
(autoload 'gdev-merge-files "gdev-merge" nil t)
(autoload 'gdev-merge-conflict "gdev-merge" nil t)
(autoload 'gdev-merge-resume "gdev-merge" nil t)

(autoload 'gdev-project-view-buffer "gdev-project-view")
(autoload 'gdev-project-view-git "gdev-project-view" nil t)
(autoload 'gdev-project-view-run "gdev-project-view" nil t)
(autoload 'gdev-project-view-tests "gdev-project-view" nil t)
(autoload 'gdev-project-view-select-profile "gdev-project-view" nil t)
(autoload 'gdev-project-view-launch "gdev-project-view" nil t)
(autoload 'gdev-project-view-debug "gdev-project-view" nil t)
(autoload 'gdev-project-view-refresh "gdev-project-view" nil t)
(autoload 'gdev-project-view-test-all "gdev-project-view" nil t)
(autoload 'gdev-project-view-test-failed "gdev-project-view" nil t)
(autoload 'gdev-project-view-test-at-point "gdev-project-view" nil t)
(autoload 'gdev-test-coverage-run "gdev-test-coverage-providers" nil t)
(autoload 'gdev-test-coverage-import "gdev-test-coverage-providers" nil t)
(autoload 'gdev-test-coverage-show "gdev-test-coverage" nil t)

(autoload 'gdev-command-sidebar-sync "gdev-command-sidebar")
(autoload 'gdev-command-sidebar-toggle "gdev-command-sidebar" nil t)
(autoload 'gdev-command-sidebar-focus "gdev-command-sidebar" nil t)
(autoload 'gdev-command-sidebar-select "gdev-command-sidebar" nil t)
(autoload 'gdev-command-sidebar-find "gdev-command-sidebar" nil t)
(declare-function gdev-command-sidebar-install "gdev-command-sidebar" ())
(with-eval-after-load 'gdev-command-sidebar (gdev-command-sidebar-install))

(autoload 'gdev-lavorazione-mode "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazione-registra "gdev-lavorazione")
(autoload 'gdev-lavorazione-nuova "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazione-composizione "gdev-lavorazione-composizione" nil t)
(autoload 'gdev-lavorazione-catalogo "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazione-aggiungi-passo "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazione-verifica "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazione-esegui "gdev-lavorazione" nil t)
(autoload 'gdev-lavorazioni-pannello "gdev-lavorazioni" nil t)
(autoload 'gdev-lavorazioni-buffer "gdev-lavorazioni")
(autoload 'gdev-lavorazioni-scegli-file "gdev-lavorazioni" nil t)
(add-to-list 'auto-mode-alist '("\\.lavorazione\\'" . gdev-lavorazione-mode))
(gdev-set-tool-actions 'lavorazioni "Lavorazioni" "code"
                       ["Pannello Lavorazioni" gdev-lavorazioni-pannello]
                       ["Nuova lavorazione…" gdev-lavorazione-nuova]
                       ["Apri file di lavorazione…" gdev-lavorazioni-scegli-file]
                       ["Catalogo delle azioni" gdev-lavorazione-catalogo]
                       ["Apri composizione" gdev-lavorazione-composizione
                        :visible (derived-mode-p 'gdev-lavorazione-mode)]
                       ["Aggiungi un passo…" gdev-lavorazione-aggiungi-passo
                        :visible (derived-mode-p 'gdev-lavorazione-mode)]
                       ["Verifica la lavorazione" gdev-lavorazione-verifica
                        :visible (derived-mode-p 'gdev-lavorazione-mode)]
                       ["Esegui la lavorazione…" gdev-lavorazione-esegui
                        :visible (derived-mode-p 'gdev-lavorazione-mode)])

(gdev-ui-install)
(add-hook 'gdev-after-init-hook #'gdev-menu-install)
(add-hook 'gdev-after-init-hook #'gdev-context-install)
(add-hook 'gdev-after-init-hook #'gdev-preferences-apply-shortcuts 90)
(add-hook 'gdev-ui-after-theme-hook #'gdev-activity-refresh-chrome)
(add-hook 'tab-bar-tab-pre-close-functions #'gdev-activity-close-tab)
(gdev-layout-mode 1)
(gdev-operation-install)
(gdev-editor-tabs-install)
(gdev-minimap-install)

(defalias 'gdev-popup-toggle #'gdev-layout-toggle-panel)
(defalias 'gdev-popup-raise #'gdev-layout-promote-panel)

(keymap-global-set "C-`" #'gdev-popup-toggle)
(keymap-global-set "C-'" #'gdev-popup-toggle)

;;; config.el ends here
