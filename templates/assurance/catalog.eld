;;; catalog.eld --- Definizione versionata -*- lisp-data -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1 :procedures
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
		(".gdev-assurance/project.eld") :required t)))
