;;; gdev-voice-italian.el --- Grammatica italiana comune della voce -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Il riconoscitore consegna testo, mai codice. La grammatica produce intenti
;; dichiarativi; il catalogo dell'editor ne risolve le azioni nel contesto reale.
;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst gdev-voice-italian-punctuation
  '((punct "," "virgola") (punct "." "punto")
    (punct ":" "due punti") (punct ";" "punto e virgola")
    (punct "?" "punto interrogativo") (punct "!" "punto esclamativo")
    (punct "…" "puntini di sospensione" "tre puntini")
    (open "(" "apri parentesi" "parentesi aperta")
    (close ")" "chiudi parentesi" "parentesi chiusa")
    (open "[" "apri parentesi quadra") (close "]" "chiudi parentesi quadra")
    (open "{" "apri parentesi graffa") (close "}" "chiudi parentesi graffa")
    (open "\"" "apri virgolette") (close "\"" "chiudi virgolette")
    (join "—" "trattino lungo") (break "\n" "a capo" "nuova riga")
    (break "\n\n" "nuovo paragrafo"))
  "Punteggiatura italiana nel formato estensibile di Voce GDev/Earwig.")

(defconst gdev-voice-italian--small-numbers
  '("zero" "uno" "due" "tre" "quattro" "cinque" "sei" "sette" "otto" "nove"
    "dieci" "undici" "dodici" "tredici" "quattordici" "quindici" "sedici"
    "diciassette" "diciotto" "diciannove"))

(defun gdev-voice-italian-number (text)
  "Leggi cifre o un numero italiano da zero a 999999, senza valutare TEXT."
  (let ((word (replace-regexp-in-string "[[:space:]]+" "" (downcase (string-trim text)))))
    (setq word (replace-regexp-in-string "é" "e" word))
    (cl-labels
        ((small (s)
           (or (cl-position s gdev-voice-italian--small-numbers :test #'equal)
               (cl-loop for stem in '("venti" "trenta" "quaranta" "cinquanta" "sessanta" "settanta" "ottanta" "novanta")
                        for tens from 2
                        thereis
                        (let* ((full (string-prefix-p stem s))
                               (short (and (not full) (string-prefix-p (substring stem 0 -1) s)))
                               (tail (and (or full short) (substring s (- (length stem) (if short 1 0)))))
                               (unit (and tail (cl-position tail gdev-voice-italian--small-numbers :test #'equal))))
                          (cond ((equal s stem) (* tens 10))
                                ((and unit (> unit 0) (< unit 10)
                                      (if short (memq unit '(1 8)) (not (memq unit '(1 8)))))
                                 (+ (* tens 10) unit)))))))
         (hundreds (s)
           (or (small s)
               (when (string-match "\\`\\(.*?\\)cent\\(o?\\)\\(.*\\)\\'" s)
                 (let* ((head (match-string 1 s)) (o (match-string 2 s)) (tail (match-string 3 s))
                        (factor (if (string-empty-p head) 1 (small head)))
                        (rest (if (string-empty-p tail) 0
                                (or (small tail) (and (equal o "o") (small (concat "o" tail)))))))
                   (when (and factor (> factor 0) (< factor 10) rest
                              (or (equal o "o") (string-prefix-p "ott" tail)))
                     (+ (* factor 100) rest)))))))
      (cond ((string-match-p "\\`[0-9]+\\'" word)
             (let ((value (string-to-number word))) (and (<= value 999999) value)))
            ((equal word "mille") 1000)
            ((string-match "\\`\\(.*?\\)\\(mila\\|mille\\)\\(.*\\)\\'" word)
             (let* ((head (match-string 1 word)) (suffix (match-string 2 word)) (tail (match-string 3 word))
                    (factor (if (and (equal suffix "mille") (string-empty-p head)) 1 (hundreds head)))
                    (rest (if (string-empty-p tail) 0 (hundreds tail))))
               (and factor (> factor 0) (<= factor 999) rest (+ (* factor 1000) rest))))
            (t (hundreds word))))))

(defun gdev-voice-italian-key (text)
  "Normalizza soltanto una parola di comando o un'etichetta, senza i suoi dati."
  (downcase (string-trim
             (replace-regexp-in-string "[[:space:]]+" " "
               (replace-regexp-in-string "[…]+\\|\\.\\.\\." "" text)))))

(defun gdev-voice-italian--split (text separator)
  "Dividi TEXT a SEPARATOR fuori dalle virgolette, conservandone i dati."
  (let* ((start 0) (index 0) quoted escaped result
         (next (string-match separator text))
         (end (and next (match-end 0))))
    (while (< index (length text))
      (let ((char (aref text index)))
        (cond (escaped (setq escaped nil))
              ((and quoted (= char ?\\)) (setq escaped t))
              ((= char ?\") (setq quoted (not quoted))))
        (when (and next (= index next))
          (unless quoted
            (push (substring text start index) result)
            (setq start end))
          (setq next (string-match separator text end)
                end (and next (match-end 0)))))
      (cl-incf index))
    (unless quoted
      (nreverse (cons (substring text start) result)))))

(defun gdev-voice-italian--literal (text)
  "Restituisci il dato TEXT senza virgolette esterne; non eseguire alcun codice."
  (setq text (string-trim text))
  (if (and (>= (length text) 2) (string-prefix-p "\"" text) (string-suffix-p "\"" text))
      (replace-regexp-in-string "\\\\\\([\\\"]\\)" "\\1" (substring text 1 -1))
    text))

(defun gdev-voice-italian-target (text)
  "Forma il bersaglio dichiarativo italiano TEXT, senza leggere il documento."
  (let* ((raw (gdev-voice-italian--literal text)) (key (gdev-voice-italian-key raw))
         (units '(("parola" . "word") ("parole" . "words") ("riga" . "line") ("righe" . "lines")
                  ("frase" . "sentence") ("frasi" . "sentences")
                  ("paragrafo" . "paragraph") ("paragrafi" . "paragraphs"))))
    (cond
     ((string-prefix-p "\"" (string-trim text)) (list :kind 'literal :text raw))
     ((member key '("tutto" "tutto il testo" "tutto il documento" "documento"))
      '(:kind structural :spec "everything"))
     ((member key '("selezione" "la selezione" "testo selezionato"))
      '(:kind structural :spec "selection"))
     ((member key '("questo" "questo testo" "quello")) '(:kind structural :spec "that"))
     ((string-match "\\`\\(?:l[ae] \\)?\\(ultim[aeio]\\|precedent[ei]\\|prossim[aeio]\\|successiv[aeio]\\|quest[aeio]\\) \\(.*?\\)\\(parol[ae]\\|riga\\|righe\\|fras[ei]\\|paragraf[io]\\)\\'" key)
      (let* ((direction (match-string 1 key)) (amount (string-trim (match-string 2 key)))
             (unit (cdr (assoc (match-string 3 key) units)))
             (count (if (string-empty-p amount) 1 (gdev-voice-italian-number amount))))
        (when (and unit count (> count 0))
          (list :kind 'structural :spec (format "%s %d %s"
            (cond ((string-prefix-p "quest" direction) "this")
                  ((or (string-prefix-p "prossim" direction) (string-prefix-p "successiv" direction)) "next")
                  (t "last")) count unit)))))
     ((or (assoc key units) (and (string-prefix-p "la " key) (assoc (substring key 3) units)))
      (list :kind 'structural :spec (concat "this " (cdr (or (assoc key units) (assoc (substring key 3) units))))))
     ((string-match-p "\\`\\(?:l[ae] \\)?\\(?:ultim[aeio]\\|precedent[ei]\\|prossim[aeio]\\|successiv[aeio]\\|quest[aeio]\\)\\b" key) nil)
     ((not (string-empty-p raw)) (list :kind 'literal :text raw)))))

(defun gdev-voice-italian--catalog (text catalog)
  "Risolvi TEXT in CATALOG, senza scegliere tra comandi omonimi."
  (let ((key (gdev-voice-italian-key text)) candidates)
    (dolist (entry catalog)
      (when (or (equal key (gdev-voice-italian-key (car entry)))
                (equal key (gdev-voice-italian-key (car (split-string (car entry) " · ")))))
        (push (cdr entry) candidates)))
    (setq candidates (delete-dups candidates))
    (when (= (length candidates) 1) (list :kind 'command :command (car candidates)))))

(defun gdev-voice-italian-parse-one (text catalog)
  "Leggi un intento da TEXT e CATALOG; nil indica frase ignota o incompleta."
  (let* ((case-fold-search t)
         (text (string-trim text)) (key (gdev-voice-italian-key text)))
    (or
     (gdev-voice-italian--catalog text catalog)
     (cond
      ((string-match "\\`\\(?:vai\\|passa\\) \\(?:alla \\)?riga \\(.+\\)\\'" text)
       (let ((number (gdev-voice-italian-number (match-string 1 text))))
         (and number (> number 0) (list :kind 'line :number number))))
      ((string-match "\\`\\(seleziona\\|cancella\\|elimina\\|taglia\\|copia\\|maiuscolo\\|minuscolo\\|iniziale maiuscola\\) \\(.+\\)\\'" text)
       (let ((verb (gdev-voice-italian-key (match-string 1 text)))
             (target (gdev-voice-italian-target (match-string 2 text))))
         (when target (list :kind 'edit :verb verb :target target))))
      ((string-match "\\`sostituisci \\(.+\\)\\'" text)
       (let* ((parts (gdev-voice-italian--split (match-string 1 text) " +con +")))
         (when (= (length parts) 2)
           (let* ((replacement (cadr parts))
                  (scope (gdev-voice-italian--split replacement " +\\(?:ovunque\\|in tutto il documento\\)\\'")))
             (when (and scope (not (string-empty-p (gdev-voice-italian--literal (car parts)))))
               (list :kind 'replace :from (gdev-voice-italian--literal (car parts))
                     :to (gdev-voice-italian--literal (car scope)) :all (> (length scope) 1)))))))
      ((string-match "\\`\\(cerca\\|apri file\\|apri cartella\\) \\(.+\\)\\'" text)
       (list :kind (pcase (gdev-voice-italian-key (match-string 1 text))
                     ("cerca" 'search) ("apri file" 'file) (_ 'folder))
             :text (gdev-voice-italian--literal (match-string 2 text))))
      ((member key '("annulla comando" "lascia perdere" "non importa")) '(:kind cancel))))))

(defun gdev-voice-italian-parse (text catalog)
  "Forma tutti gli intenti di TEXT in CATALOG prima di qualsiasi effetto.
Le parti unite da «e poi» o «quindi» rispettano le stringhe tra virgolette.
Una frase incompleta rende incompleta l'intera sequenza."
  (let* ((case-fold-search t)
         (text (replace-regexp-in-string "[«»“”]" "\"" (string-trim text)))
         (text (replace-regexp-in-string "[.!?]+\\'" "" text))
         (parts (gdev-voice-italian--split text " +\\(?:e poi\\|quindi\\) +"))
         (intents (mapcar (lambda (part) (gdev-voice-italian-parse-one part catalog)) parts)))
    (cond ((seq-some (lambda (intent) (eq 'cancel (plist-get intent :kind))) intents) '((:kind cancel)))
          ((and parts (cl-every #'identity intents)) intents))))

(provide 'gdev-voice-italian)
;;; gdev-voice-italian.el ends here
