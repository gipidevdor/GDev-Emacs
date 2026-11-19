;;; config.el --- :lang xml: modifica, navigazione e convalida XML -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Emacs modifica XML, XSD, XSLT, SVG e gli altri documenti XML con nXML.
;; Controlla la struttura in sottofondo e completa gli elementi quando
;; trova uno schema RELAX NG in sintassi compatta (.rnc).
;;
;;   M-TAB      completa elemento o attributo
;;   C-c l c    chiudi l'elemento
;;   C-c l d    inserisci la dichiarazione XML
;;   C-c l s    scegli uno schema RELAX NG compatto
;;   C-c l e    vai alla prossima segnalazione
;;   C-c l p    vai alla segnalazione precedente
;;   C-c l x    convalida il file salvato con uno schema XSD e xmllint
;;   C-c c f    rientra il documento mantenendo la disposizione delle righe
;;
;; Per associare gli schemi al progetto usa un file schemas.xml accanto
;; ai documenti. Per l'XSD scegli uno schema locale al momento della
;; convalida. Il rapporto appare nel pannello.

;;; Code:

(require 'gdev-lib)
(require 'gdev-handlers)
(require 'gdev-keys)

(declare-function gdev-describe-module "gdev-modules" (category module))
(declare-function nxml-finish-element "nxml-mode" ())
(declare-function nxml-insert-xml-declaration "nxml-mode" ())
(declare-function rng-next-error "rng-valid" (arg))
(declare-function rng-previous-error "rng-valid" (arg))
(declare-function rng-set-schema-file-and-validate "rng-valid" (filename))
(defvar gdev-context-items)
(defvar nxml-mode-map)
(defvar nxml-slash-auto-complete-flag)

(defun gdev-xml-setup ()
  "Configura la modifica e il menu contestuale del documento XML."
  (setq-local nxml-slash-auto-complete-flag t
              gdev-context-items
              '(["Completa elemento o attributo" completion-at-point]
                ["Chiudi elemento" nxml-finish-element]
                ["Inserisci dichiarazione XML" nxml-insert-xml-declaration]
                ["Rientra documento" gdev-xml-indent]
                ["Scegli schema RELAX NG…" gdev-xml-select-schema]
                ["Segnalazione successiva" rng-next-error]
                ["Segnalazione precedente" rng-previous-error]
                ["Convalida con XSD…" gdev-xml-validate-xsd buffer-file-name])))

(defun gdev-xml-indent ()
  "Rientra il documento con nXML, usando gli spazi e i rientri correnti."
  (interactive)
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "xml:space[[:space:]]*=[[:space:]]*['\"]preserve['\"]" nil t)
        (user-error "Questo XML dichiara spazi da conservare con xml:space"))
      (atomic-change-group
        (indent-region (point-min) (point-max))))))

(defun gdev-xml-select-schema (file)
  "Associa lo schema RELAX NG compatto FILE al documento."
  (interactive (list (read-file-name "Schema RELAX NG (.rnc): " nil nil t)))
  (unless (and (file-regular-p file) (file-readable-p file)
               (string-suffix-p ".rnc" file))
    (user-error "Scegli un file di schema RELAX NG .rnc leggibile"))
  (rng-set-schema-file-and-validate file))

(defun gdev-xml--file ()
  "Restituisci il nome del documento XML salvato sul disco locale."
  (let ((file (or buffer-file-name (user-error "Salva prima il documento XML"))))
    (when (file-remote-p file) (user-error "La convalida XSD usa file locali"))
    (unless (and (not (buffer-modified-p)) (file-regular-p file))
      (user-error "Salva le modifiche prima di convalidare il documento XML"))
    file))

(defun gdev-xml-validate-xsd (schema)
  "Convalida il documento XML salvato con lo SCHEMA XSD locale."
  (interactive
   (progn
     (gdev-xml--file)
     (list (read-file-name "Schema XSD: " nil nil t))))
  (let ((file (gdev-xml--file))
        (program (or (executable-find "xmllint")
                     (user-error "xmllint non disponibile"))))
    (when (file-remote-p schema) (user-error "Scegli uno schema XSD locale"))
    (unless (and (file-regular-p schema) (file-readable-p schema))
      (user-error "Scegli un file di schema XSD leggibile"))
    (gdev-compile (gdev-command-line program "--nonet" "--noout" "--schema"
                                     (expand-file-name schema) file)
                  (format "Convalida XML · %s" (file-name-nondirectory file))
                  (file-name-directory file))))

(defun gdev-xml-guide ()
  "Mostra la guida in italiano del modulo XML."
  (interactive)
  (gdev-describe-module :lang 'xml))

(add-to-list 'auto-mode-alist
             '("\\.\\(?:xml\\|xsd\\|xsl\\|xslt\\|rng\\|svg\\|wsdl\\|xhtml\\|xaml\\)\\'" . nxml-mode))
(add-hook 'nxml-mode-hook #'gdev-xml-setup)
(gdev-localleader nxml-mode nxml-mode-map
  "c" "chiudi elemento" #'nxml-finish-element
  "d" "inserisci dichiarazione XML" #'nxml-insert-xml-declaration
  "s" "scegli schema RELAX NG" #'gdev-xml-select-schema
  "e" "segnalazione successiva" #'rng-next-error
  "p" "segnalazione precedente" #'rng-previous-error
  "x" "convalida con XSD" #'gdev-xml-validate-xsd
  "k" "guida XML" #'gdev-xml-guide)
(gdev-set-formatter 'nxml-mode #'gdev-xml-indent)
(gdev-set-documentation 'nxml-mode #'gdev-xml-guide)
(gdev-doctor-executable "xmllint" "Installa libxml2 per convalidare con uno schema XSD" 'note)

;;; config.el ends here
