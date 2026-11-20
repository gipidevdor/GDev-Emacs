;;; gdev-gherkin.el --- Gherkin GDev, parser derivato da Ecukes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Modificato per GDev-Emacs il 2026-11-20: parser italiano e inglese,
;; controllo dei passi ignorati e uso indipendente dal runner Ecukes.
;; I due file ecukes-*.el conservano il parser originale di Ecukes.

;;; Commentary:

;; Legge feature, background, scenari, outline, tabelle e stringhe multilinea.
;; I passi vengono eseguiti dal ponte BDD del progetto, senza commander,
;; ansi, Espuds o l'interfaccia interattiva originale.

;;; Code:

(require 'cl-lib)
(require 'ecukes-parse)

;;;###autoload
(defun gdev-gherkin-read (file)
  "Leggi FILE in italiano o inglese, rifiutando un corpus senza scenari.
Il risultato conserva le strutture `ecukes-feature' e `ecukes-scenario'."
  (let* ((ecukes-parse-intro-re "^[ \t]*\\(?:Feature\\|Funzionalità\\):[ \t]*\\(.+?\\)[ \t]*$")
         (ecukes-parse-background-re "^[ \t]*\\(?:Background\\|Contesto\\):")
         (ecukes-parse-scenario-re "^[ \t]*Scenario:[ \t]*\\(.+?\\)[ \t]*$")
         (ecukes-parse-outline-re "^[ \t]*\\(?:Scenario Outline\\|Schema dello scenario\\):[ \t]*\\(.+?\\)[ \t]*$")
         (ecukes-parse-examples-re "^[ \t]*\\(?:Examples\\|Esempi\\):")
         (ecukes-parse-step-re "^[ \t]*\\(Given\\|When\\|Then\\|And\\|But\\|Dato\\|Data\\|Dati\\|Date\\|Quando\\|Allora\\|E\\|Ma\\)[ \t]+\\(.+?\\)[ \t]*$")
         (feature nil))
    ;; Il parser originale può ignorare una riga non riconosciuta. Dopo
    ;; l'inizio dei passi, una parola chiave errata deve invece fallire.
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let (active string-block)
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
            (cond
             ((string-match-p "^[ \t]*\"\"\"" line) (setq string-block (not string-block)))
             (string-block)
             ((or (string-match-p "^[ \t]*\\(?:#.*\\|@.*\\)?$" line)
                  (string-match-p ecukes-parse-intro-re line)))
             ((or (string-match-p ecukes-parse-scenario-re line)
                  (string-match-p ecukes-parse-outline-re line)
                  (string-match-p ecukes-parse-background-re line)) (setq active t))
             ((or (string-match-p ecukes-parse-step-re line)
                  (string-match-p ecukes-parse-examples-re line)
                  (string-match-p ecukes-parse-table-re line))
              (unless active (error "Passo fuori da uno scenario, riga %d" (line-number-at-pos))))
             (active (error "Riga Gherkin non riconosciuta, %d: %s" (line-number-at-pos) line))))
          (forward-line 1))
        (when string-block (error "Stringa Gherkin non terminata: %s" file))))
    (setq feature (ecukes-parse-feature file))
    (unless (and (ecukes-feature-intro feature) (ecukes-feature-scenarios feature))
      (error "La feature deve avere un'intestazione e almeno uno scenario: %s" file))
    (dolist (scenario (ecukes-feature-scenarios feature))
      (unless (ecukes-scenario-steps scenario)
        (error "Scenario senza passi: %s" (ecukes-scenario-name scenario))))
    feature))

(provide 'gdev-gherkin)
;;; gdev-gherkin.el ends here
