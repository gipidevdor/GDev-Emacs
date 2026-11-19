<!-- Generato da GDev; non modificare. Fonti sha256:6041bf5270f555baf615068a687092a736eb575762ca34c1f671509abeff310d -->

# Analisi dei rischi

## Fonte: .gdev-assurance/project.eld

```eld
;;; project.eld --- Definizione versionata -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :id "GDEV-EMACS" :name "GDev-Emacs" :profile quality
	  :criticality normal :standards
	  ((:id "nist-sp-800-218" :edition "1.1" :applicability
		applicable :decision accepted :scope indexed :reason
		"Pratiche e compiti della tabella SSDF acquisita; applicazione tecnica, senza certificazione")
	   (:id "nist-ir-8397" :edition "2021" :applicability
		applicable :decision accepted :scope indexed :reason
		"Strategia di verifica; l’indice è completo nel perimetro numerato, la scomposizione degli obblighi resta da integrare")
	   (:id "iso-iec-ieee-29148" :edition "2018" :applicability
		applicable :decision accepted :scope bibliographic
		:reason
		"Riferimento per requisiti; tassonomia integrale non disponibile localmente")
	   (:id "iso-iec-ieee-42010" :edition "2022" :applicability
		applicable :decision accepted :scope bibliographic
		:reason
		"Riferimento architetturale, senza clausole inventate")
	   (:id "iso-iec-25010" :edition "2023" :applicability
		applicable :decision accepted :scope bibliographic
		:reason
		"Riferimento delle caratteristiche di qualità; da integrare la tassonomia normativa")
	   (:id "iso-iec-ieee-12207" :edition "2026" :applicability
		applicable :decision accepted :scope bibliographic
		:reason
		"Riferimento del ciclo di vita; attuazione GDev distinta dalla conformità integrale"))
	  :requirements
	  ((:id "GDEV-P01" :version 1 :statement
		"Ogni progetto deve dichiarare requisiti tipizzati, responsabilità e criteri di accettazione verificabili."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category process :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources ("lisp/gdev-project.el") :tests
		("gdev-test-project-schema-rejects-duplicates-and-unresolved-references"
		 "gdev-test-project-drafts-explain-missing-fields-and-keep-defaults-proposed")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P02" :version 1 :statement
		"Le tassonomie devono conservare gerarchia, fonte, edizione, impronte e lacune senza attribuire conformità implicita."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category data :priority must :criticality high :owner
		"Manutentori di GDev" :status accepted :applicability
		applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-taxonomy.el" "bin/gdev-taxonomy-import.py"
		 "docs/assicurazione/standard/indici-fonti.json")
		:tests
		("gdev-test-project-taxonomies-preserve-hierarchy-source-and-incompleteness")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P03" :version 2 :statement
		"I modelli parametrizzati devono offrire anteprima letterale e proteggere i file esistenti dai conflitti e archiviare versione, parametri e impronte."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category functional :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-project-templates.el"
		 "templates/assurance/catalog.eld" "lisp/gdev-project-store.el")
		:tests
		("gdev-test-project-snippet-preview-is-literal-and-conflicts-preserve-user-files"
 "gdev-test-project-manual-snippet-retains-values-after-reopening-the-archive"
 "gdev-test-project-manual-snippet-refusal-precedes-any-file-effect"
 "gdev-test-project-manual-snippet-sql-failure-can-be-reconciled-without-overwriting")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P04" :version 1 :statement
		"Le procedure devono conservare tentativi, errori, annullamenti e punti di ripresa senza duplicare effetti già confermati."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category functional :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-procedures.el"
		 "modules/ui/workbench/gdev-lavorazione.el")
		:tests
		("gdev-test-project-runs-preserve-failures-and-resume-without-repeating-completed-effects")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P05" :version 1 :statement
		"I controlli critici devono essere esplorati su un modello finito con assunzioni, limiti e controesempi riproducibili."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category process :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method model-check :sources
		("lisp/gdev-formal.el" "lisp/gdev-project-store.el")
		:tests
		("model"
		 "gdev-test-project-finite-model-finds-unsafe-guards")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P06" :version 1 :statement
		"Gli artefatti derivati devono essere riproducibili e le prove devono scadere al cambiamento delle fonti pertinenti."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category quality :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-project-report.el"
		 "lisp/gdev-documents.el" "lisp/gdev-project-store.el")
		:tests
		("project-report"
		 "gdev-test-project-real-lifecycle-requires-current-runs-and-invalidates-changes")
		:procedure "GDEV-VERIFY")
   (:id "GDEV-P07" :version 3 :statement
		"Tasti, pulsanti, menu, CLI e MCP devono usare gli stessi servizi e preservare il contesto dello spazio. La consultazione evita scansioni di verifica superflue e mantiene navigazione, filtri e azioni accessibili nelle finestre strette. La selezione di un risultato di ricerca aggiorna solo il suo controllo e il riepilogo; le frecce, Invio e Spazio mantengono distinte navigazione, apertura e selezione per la sostituzione."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category usability :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("modules/ui/workbench/gdev-project-workbench.el"
		 "modules/ui/workbench/gdev-assurance-workbench.el"
		 "modules/ui/workbench/gdev-context.el"
		 "modules/ui/workbench/gdev-search.el"
		 "lisp/gdev-assurance.el"
		 "lisp/gdev-cli.el"
		 "lisp/gdev-assurance-actions.el"
		 "lisp/gdev-assurance-api.el")
		:tests
		("gdev-test-assurance-ui-all-sections-render-and-official-source-is-an-explicit-action"
		 "gdev-test-assurance-view-keeps-informational-reads-small"
		 "gdev-test-assurance-ui-actions-use-unverified-choice-metadata"
		 "gdev-test-assurance-view-controls-and-full-data-recheck-sources"
		 "gdev-test-assurance-ui-compact-navigation-and-filter-reset"
		 "gdev-test-assurance-ui-page-focus-follows-visible-data"
		 "gdev-test-assurance-ui-reader-handles-immediate-result-and-startup-error"
         "gdev-test-assurance-ui-reader-drains-terminal-output-once"
		 "gdev-test-project-workbench-reader-is-asynchronous-and-ignores-an-old-section"
		 "gdev-test-cli-bench-refuses-invalid-counts-before-starting"
		 "gdev-test-search-selection-updates-only-its-control-and-summary"
		 "gdev-test-search-selection-keeps-both-viewports-and-invalidates-preview"
		 "gdev-test-search-selection-rebuilds-after-geometry-or-component-change"
		 "gdev-test-search-arrows-open-and-selection-share-visible-target"
		 "gdev-test-search-selection-keeps-button-role-with-font-padding"
		 "test/gdev-cli-contract-test.py")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P08" :version 1 :statement
		"La simulazione deve validare tutto il piano senza scritture o creazione implicita di un archivio."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category functional :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources ("lisp/gdev-procedures.el")
		:tests
		("gdev-test-project-simulation-and-source-reads-do-not-create-an-archive")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-P09" :version 1 :statement
		"GDev deve usare realmente la definizione di progetto e mantenere distinte le approvazioni umane dalle prove automatiche."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category process :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		(".gdev-assurance/project.eld"
		 "lisp/gdev-project-store.el"
		 ".gdev-assurance/self-check.eld")
		:tests
		("gdev-test-project-distribution-has-a-complete-live-definition")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-Q01" :version 1 :statement
		"Il dominio deve caricare autonomamente, avere proprietari univoci e non dipendere dalle viste."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category quality :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-assurance.el" "docs/architettura.md")
		:tests
		("gdev-test-architecture-load-dependencies-have-no-cycles"
		 "gdev-test-architecture-assurance-domain-does-not-load-the-editor")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-Q02" :version 1 :statement
		"Migrazioni e scritture devono rimanere atomiche in presenza di guasti singoli, persistenti e arresti improvvisi."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category quality :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-assurance-db.el" "lisp/gdev-process.el"
		 "lisp/gdev-evidence.el"
		 "test/gdev-reliability-test.py")
		:tests ("test/gdev-reliability-test.py") :procedure
		"GDEV-VERIFY")
	   (:id "GDEV-Q03" :version 1 :statement
		"Gli spazi devono conservare stato coerente e isolato attraverso aggiornamenti, errori e ripristini."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category quality :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-workspace-state.el"
		 "test/gdev-reliability-worker.el")
		:tests ("test/gdev-reliability-test.py") :procedure
		"GDEV-VERIFY")
	   (:id "GDEV-Q04" :version 1 :statement
		"Le letture non devono scrivere dati e l’audit deve rilevare alterazioni anche quando i trigger vengono ripristinati."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category security :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-assurance-db.el" "lisp/gdev-assurance.el")
		:tests
		("test/gdev-reliability-test.py"
		 "test/gdev-assurance-git-test.py")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-Q05" :version 1 :statement
		"I fork devono conservare i contratti di integrazione e la distribuzione deve mantenere la compatibilità dichiarata."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category compatibility :priority must :criticality
		high :owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("vendor/pacchetti.el"
		 "modules/emacs/ibuffer/config.el"
		 "lisp/gdev-commands.el")
		:tests
		("gdev-test-forks-multiple-cursors-imports-the-same-clipboard-order"
		 "gdev-test-forks-rebuilder-roundtrips-pcre-and-rx"
		 "gdev-test-forks-sly-completion-fills-a-displayed-window-before-resizing")
		:procedure "GDEV-VERIFY")
	   (:id "GDEV-Q06" :version 1 :statement
		"Il motore di assicurazione deve essere verificato sulle stesse fonti distribuite, distinguendo fixture e approvazioni reali."
		:origin "Mandato dell’utente e AGENTS.md" :rationale
		"Rendere lo sviluppo controllato e dimostrabile"
		:category process :priority must :criticality high
		:owner "Manutentori di GDev" :status accepted
		:applicability applicable :acceptance
		"Tutti i casi di verifica collegati devono risultare superati sulla revisione corrente."
		:method test :sources
		("lisp/gdev-standard-assessment.el"
		 "lisp/gdev-trace.el"
		 "test/gdev-self-assurance-test.el")
		:tests
		("gdev-test-self-assurance-applies-its-engine-to-distributed-sources")
		:procedure "GDEV-VERIFY")
   (:id "GDEV-Q07" :version 1 :statement
        "Gli algoritmi delle viste e delle analisi devono dichiarare costo in tempo e memoria, con aggregazione dei marcatori ordinati lineare e visita dei grafi indicizzata e priva di ricorsione. La visualizzazione conserva priorità, conteggi, destinazioni e contesto durante gli aggiornamenti."
        :origin "Richiesta dell’utente su algoritmi, complessità e visualizzazione dell’informazione"
        :rationale "Rendere scalabilità e leggibilità verificabili con limiti dichiarati"
        :category performance :priority must :criticality normal
        :owner "Manutentori di GDev" :status accepted :applicability applicable
        :acceptance "Le prove collegate devono verificare limiti strutturali e invarianza dei risultati; il catalogo distingue algoritmo, rendering e I/O."
        :method test
        :sources ("modules/ui/workbench/gdev-minimap.el" "modules/ui/workbench/gdev-search.el"
                  "lisp/gdev-graph.el" "lisp/gdev-project.el" "lisp/gdev-taxonomy.el"
                  "lisp/gdev-trace.el" "lisp/gdev-capability.el" "lisp/gdev-assurance-git.el"
                  "vendor/elpa/consult-3.10/consult-imenu.el"
                  "docs/algoritmi-e-visualizzazione.md")
        :tests ("gdev-test-minimap-ordered-binning-avoids-per-mark-search"
                "gdev-test-minimap-binning-preserves-salience-under-permutations"
                "gdev-test-minimap-empty-bins-and-boundaries-are-safe"
                "gdev-test-assurance-trace-indexes-large-changed-path-sets"
                "gdev-test-assurance-trace-reachability-is-stable-with-diamonds-and-duplicate-edges"
                "gdev-test-search-selection-updates-only-its-control-and-summary"
                "gdev-test-project-graph-deep-chains-and-cycle-witness"
                "gdev-test-project-graph-matches-independent-transitive-closure"
                "gdev-test-project-graph-empty-duplicate-and-nil-nodes"
                "gdev-test-project-validates-deep-dependencies-without-recursion"
                "gdev-test-project-imported-taxonomy-validates-deep-parent-chains-once"
                "gdev-test-project-source-inventory-shares-one-output-index"
                "gdev-test-project-source-collections-do-not-mutate-definition"
                "gdev-test-forks-consult-imenu-preserves-types-faces-and-targets"
                "gdev-test-forks-consult-imenu-handles-deep-prefixes-with-a-bounded-stack"
                "gdev-test-capability-dynamic-controls-preserve-first-seen-order")
        :procedure "GDEV-VERIFY")
   (:id "GDEV-P10" :version 1
        :statement "I linguaggi distribuiti non dichiarati permanenti devono attivarsi quando un documento ne richiede la modalità. Le capacità temporanee sono condivise dai documenti e dalle operazioni; l'ultimo proprietario le rilascia. Errori, annullamenti e callback tardive non devono lasciare registrazioni attive né alterare le preferenze personali."
        :origin "Richiesta dell’utente sull’attivazione e disattivazione automatica"
        :rationale "Aprire un documento deve rendere disponibili colorazione e comandi senza modificare init.el"
        :category functional :priority must :criticality high
        :owner "Manutentori di GDev" :status accepted :applicability applicable
        :acceptance "L'apertura del primo file Swift all'avvio attiva colori e comandi; chiusure annullate conservano il proprietario, processi attivi lo trattengono e il rilascio elimina capacità e callback possedute."
        :method test
        :sources ("lisp/gdev-auto-modules.el" "lisp/gdev-modules.el" "lisp/gdev-handlers.el"
                  "lisp/gdev-language-modes.el" "lisp/gdev-cli.el" "modules/lang/swift/config.el")
        :tests ("gdev-test-auto-modules-swift-files-activate-share-release-and-reopen"
                "gdev-test-auto-modules-first-command-line-file-activates-in-ordinary-startup"
                "gdev-test-auto-modules-first-file-applies-newly-registered-mode-remapping"
                "gdev-test-auto-modules-close-cancellation-and-mode-change-preserve-state"
                "gdev-test-auto-modules-compilation-outlives-document-and-output-buffer"
                "gdev-test-auto-modules-work-scopes-release-on-error-and-quit"
                "gdev-test-auto-modules-eglot-deferred-effects-expire-with-their-owner"
                "gdev-test-auto-modules-owned-hooks-and-deferred-advice-expire"
                "gdev-test-auto-modules-catalogue-providers-release-all-capability-registries")
        :procedure "GDEV-VERIFY")
   (:id "GDEV-P11" :version 1
        :statement "Le operazioni di un progetto Xcode locale devono usare un profilo ricavato dai suoi metadati. Compilazione, test, avvio e debug condividono radice, schema e cartella di build del progetto; l'avvio dipendente da una compilazione procede solo dopo un esito positivo. Menu e riquadri usano il documento attivo anche se il fuoco è altrove."
        :origin "Segnalazione dell’utente sulla compilazione e sul contesto frammentato"
        :rationale "Evitare richieste di salvataggio del buffer o scelta manuale del programma per le operazioni già definite dal progetto"
        :category usability :priority must :criticality high
        :owner "Manutentori di GDev" :status accepted :applicability applicable
        :acceptance "Il profilo macOS predefinito usa build/gdev; la compilazione dal riquadro non chiede nomi di file. I profili personali prevalgono, i prodotti restano nel progetto e un errore interrompe l'avvio."
        :method test
        :sources ("lisp/gdev-xcode.el" "lisp/gdev-launch.el" "modules/tools/build/config.el"
                  "modules/ui/workbench/gdev-command-sidebar.el")
        :tests ("gdev-test-xcode-profile-reads-product-and-keeps-products-in-project"
                "gdev-test-xcode-build-from-pane-uses-document-project-without-save-dialogue"
                "gdev-test-xcode-run-builds-first-and-does-not-launch-after-failure"
                "gdev-test-xcode-private-profile-prevails-and-view-reads-have-no-io"
                "gdev-test-xcode-rejects-products-and-directories-outside-project"
                "gdev-test-command-sidebar-menu-opens-search-when-the-pane-cannot-fit")
        :procedure "GDEV-VERIFY"))
	  :procedures
	  ((:id "PROC-FEATURE" :version 1 :title "Feature" :types
		("feature") :requirements nil :snippets nil :outputs
		("docs/assicurazione/generati/project.md") :steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "verify" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "PROC-BUGFIX" :version 1 :title "Bugfix" :types
		("bugfix") :requirements nil :snippets nil :outputs
		("docs/assicurazione/generati/project.md") :steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "verify" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "PROC-REFACTOR" :version 1 :title "Refactor" :types
		("refactor") :requirements nil :snippets nil :outputs
		("docs/assicurazione/generati/project.md") :steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "verify" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "PROC-DOCS" :version 1 :title "Docs" :types ("docs")
		:requirements nil :snippets nil :outputs
		("docs/assicurazione/generati/project.md") :steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "documents" :plan
		      ".gdev-assurance/procedures/documents.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "PROC-DEPENDENCY" :version 1 :title "Dependency"
		:types ("dependency") :requirements nil :snippets nil
		:outputs ("docs/assicurazione/generati/project.md")
		:steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "verify" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "PROC-RELEASE" :version 1 :title "Release" :types
		("release") :requirements nil :snippets nil :outputs
		("docs/assicurazione/generati/project.md") :steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "verify" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification)
	   (:id "GDEV-VERIFY" :version 1 :title
		"Verifica completa della distribuzione" :types
		("feature" "bugfix" "refactor" "release")
		:requirements
		("GDEV-P01" "GDEV-P02" "GDEV-P03" "GDEV-P04"
		 "GDEV-P05" "GDEV-P06" "GDEV-P07" "GDEV-P08"
		 "GDEV-P09" "GDEV-Q01" "GDEV-Q02" "GDEV-Q03"
		 "GDEV-Q04" "GDEV-Q05" "GDEV-Q06" "GDEV-Q07" "GDEV-P10" "GDEV-P11")
		:outputs
		("docs/assicurazione/generati/project.md"
		 ".gdev/assurance/reports/reliability.json")
		:steps
		((:id "preflight" :plan
		      ".gdev-assurance/procedures/preflight.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "model" :plan
		      ".gdev-assurance/procedures/verify.lavorazione"
		      :timeout 60 :replay safe :required t)
		 (:id "ert" :plan
		      ".gdev-assurance/procedures/ert.lavorazione"
		      :timeout 900 :replay safe :required t)
		 (:id "cli" :plan
		      ".gdev-assurance/procedures/cli.lavorazione"
		      :timeout 300 :replay safe :required t)
		 (:id "git" :plan
		      ".gdev-assurance/procedures/git.lavorazione"
		      :timeout 300 :replay safe :required t)
		 (:id "reliability" :plan
		      ".gdev-assurance/procedures/reliability.lavorazione"
		      :timeout 900 :replay safe :required t)
		 (:id "report" :plan
		      ".gdev-assurance/procedures/report.lavorazione"
		      :timeout 60 :replay safe :required t :outputs
		      ("docs/assicurazione/generati/project.md")))
		:purpose
		"Guidare il lavoro dichiarato e produrre controlli tracciati"
		:preconditions
		"Progetto compilato, requisiti risolti e input dei passi disponibili"
		:permissions
		"Effetti limitati alle azioni dichiarate; approvazioni riservate al nucleo"
		:success
		"Tutti i passi obbligatori riusciti e uscite dichiarate presenti"
		:failure
		"Giornale conservato; primo errore obbligatorio interrompe la procedura"
		:interruption
		"Annullamento cooperativo e arresto dei figli; esiti precedenti conservati"
		:recovery
		"Riprendere solo con contesto invariato e uscite coerenti; riconciliare gli effetti manuali"
		:mode verification))
	  :snippets
	  ((:id "SNIP-PROJECT" :version 1 :description "Progetto"
		:language "markdown" :template
		".gdev-assurance/snippets/project.tmpl" :parameters
		((:name "name" :required t :reason "Nome")
		 (:name "id" :required t :reason "Identificativo")
		 (:name "owner" :required t :reason "Responsabile")
		 (:name "purpose" :required t :reason "Scopo"))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("markdown" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-PROJECT, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-REQUIREMENT" :version 1 :description "Requisito"
		:language "markdown" :template
		".gdev-assurance/snippets/requirement.tmpl"
		:parameters
		((:name "id" :required t :reason "Identificativo")
		 (:name "title" :required t :reason "Titolo")
		 (:name "statement" :required t :reason "Requisito")
		 (:name "acceptance" :required t :reason
			"Criterio di accettazione")
		 (:name "owner" :required t :reason "Responsabile"))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("markdown" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-REQUIREMENT, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-WORK" :version 1 :description "Lavorazione"
		:language "markdown" :template
		".gdev-assurance/snippets/work.tmpl" :parameters
		((:name "id" :required t :reason "Identificativo")
		 (:name "title" :required t :reason "Titolo")
		 (:name "purpose" :required t :reason "Scopo")
		 (:name "requirement" :required t :reason
			"Requisito di origine")
		 (:name "procedure" :required t :reason "Procedura"))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("markdown" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-WORK, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-PROCEDURE" :version 1 :description "Procedura"
		:language "markdown" :template
		".gdev-assurance/snippets/procedure.tmpl" :parameters
		((:name "id" :required t :reason "Identificativo")
		 (:name "title" :required t :reason "Titolo")
		 (:name "purpose" :required t :reason "Scopo")
		 (:name "preconditions" :required t :reason
			"Prerequisiti")
		 (:name "acceptance" :required t :reason
			"Criterio di accettazione"))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("markdown" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-PROCEDURE, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-FUNCTION" :version 1 :description
		"Funzione Emacs Lisp" :language "emacs-lisp" :template
		".gdev-assurance/snippets/function.tmpl" :parameters
		((:name "name" :required t :reason "Nome" :type symbol)
		 (:name "purpose" :required t :reason "Scopo" :type
			string))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("emacs-lisp" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-FUNCTION, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-TEST" :version 1 :description
		"Test ERT da completare" :language "emacs-lisp"
		:template ".gdev-assurance/snippets/test.tmpl"
		:parameters
		((:name "name" :required t :reason "Nome" :type symbol)
		 (:name "purpose" :required t :reason "Scopo" :type
			string)
		 (:name "requirement" :required t :reason
			"Requisito di origine" :type string))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("emacs-lisp" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-TEST, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-DOCUMENTATION" :version 1 :description
		"Documentazione" :language "markdown" :template
		".gdev-assurance/snippets/documentation.tmpl"
		:parameters
		((:name "title" :required t :reason "Titolo")
		 (:name "content" :required t :reason "Contenuto")
		 (:name "status" :required nil :default "Bozza"
			:reason "Stato del documento" :type text))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("markdown" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-DOCUMENTATION, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-CONFIGURATION" :version 1 :description
		"Configurazione dati" :language "emacs-lisp" :template
		".gdev-assurance/snippets/configuration.tmpl"
		:parameters
		((:name "purpose" :required t :reason "Scopo" :type
			string)
		 (:name "id" :required t :reason "Identificativo"
			:type string))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("emacs-lisp" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-CONFIGURATION, compila i parametri, esamina l'anteprima e crea un file nuovo")
	   (:id "SNIP-ERROR" :version 1 :description
		"Gestione degli errori" :language "emacs-lisp"
		:template ".gdev-assurance/snippets/error.tmpl"
		:parameters
		((:name "name" :required t :reason "Nome" :type string))
		:scope
		"Progetto formale; inserimento letterale senza esecuzione"
		:tags ("emacs-lisp" "assurance") :prerequisites
		("Parametri richiesti compilati e file di destinazione libero")
		:checks
		("Anteprima prima della scrittura"
		 "Conflitti e percorsi verificati")
		:example
		"Scegli SNIP-ERROR, compila i parametri, esamina l'anteprima e crea un file nuovo"))
	  :artifacts
	  ((:id "PROJECT-REPORT" :type report :path
		"docs/assicurazione/generati/project.md" :sources
		(".gdev-assurance/project.eld") :required t))
	  :purpose
	  "Fornire una postazione Emacs e una piattaforma di sviluppo governato che applica a se stessa requisiti, procedure e controlli."
	  :scope
	  "Nucleo Lisp, moduli distribuiti, fork inclusi, CLI, MCP, documentazione e automazioni del repository. Le tassonomie protette senza fonti complete restano esplicitamente da integrare."
	  :owner "Manutentori di GDev" :context
	  "Emacs 30.1 e successivi; macOS con finestra nativa e uso da terminale; CI Linux e macOS. Stato e configurazione privata esterni al checkout."
	  :verification
	  "ERT, contratti Python di CLI/MCP/Git, modello finito, guasti SQL, crash DELETE/WAL, generazione di sequenze, mutazioni, compilazione e avvio isolati."
	  :validation
	  "Percorsi reali da tastiera, puntatore, menu, CLI e MCP. Verifica nativa di temi chiaro/scuro, spazio ristretto, chiusura, conferma e annullamento; eventuali prove impedite sono registrate come mancanti."
	  :configuration
	  "Sorgenti versionati in Git, registro dei fork, manifesti .eld letti come dati, migrazioni append-only e impronte di ogni contesto verificato."
	  :release
	  "Controlli obbligatori superati sulla revisione candidata; rapporto ed evidenze correnti; approvazioni umane e configurazione remota richieste restano separate e visibili."
	  :maintenance
	  "Correggere regressioni con prove riproducibili, migrare esplicitamente schemi e standard, conservare la storia e ripetere le verifiche invalidate."
	  :stakeholders
	  ("Utilizzatori di GDev" "Manutentori" "Agenti e CI")
	  :constraints
	  ("Compatibilità minima Emacs 30.1"
	   "Nessuna dipendenza da modelli linguistici nel nucleo"
	   "Nessuna approvazione umana sintetica nel progetto reale")
	  :risks
	  ((:id "RISK-01" :description
		"Prove o indici incompleti possono produrre attestazioni indebite"
		:mitigation
		"Copertura esplicita, gate e invalidazione tramite impronte"
		:owner "Manutentori di GDev")
	   (:id "RISK-02" :description
		"Un agente con eval condivide il processo e può alterare le regole locali"
		:mitigation
		"Verificatore esterno e ricevute; configurazione remota ancora esplicita"
		:owner "Manutentori di GDev"))
	  :source-roots
	  ("lisp" "modules" "vendor" "test" "bin" "templates" "docs"
	   ".github" ".gdev-assurance" ".agents")
	  :source-files
	  ("AGENTS.md" "README.md" "early-init.el" "init.el"
	   ".gitignore" "LICENSE"))
```
