;;; gdev-assessment-test.el --- Prove di standard, controlli e valutazione -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Il registro e le clausole, i controlli e i profili, la valutazione di una
;; transazione e la sua riproducibilità.  Le prove con dati alterati usano una
;; cartella temporanea che condivide con quella vera i dati degli standard.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gdev-assessment)

(defmacro gdev-test-controls--with-data (spec &rest body)
  "Esegui BODY con cartelle di dati temporanee.
SPEC è (CONTROLLI PROFILI): se un elemento è nil resta quello vero.  Gli standard
sono sempre quelli veri."
  (declare (indent 1) (debug ((form form) body)))
  `(let* ((real gdev-standards-directory)
          (directory (file-name-as-directory (make-temp-file "gdev-dati-" t)))
          (gdev-standards-directory directory))
     (unwind-protect
         (progn
           (make-symbolic-link (expand-file-name "standard" real) (concat directory "standard"))
           (make-directory (concat directory "profili"))
           (dolist (file '("controlli.eld" "profili.eld"))
             (copy-file (expand-file-name (concat "profili/" file) real)
                        (concat directory "profili/" file)))
           (pcase-let ((`(,controls ,profiles) (list ,(nth 0 spec) ,(nth 1 spec))))
             (let (print-length print-level)
               (when controls
                 (with-temp-file (concat directory "profili/controlli.eld")
                   (prin1 controls (current-buffer))))
               (when profiles
                 (with-temp-file (concat directory "profili/profili.eld")
                   (prin1 profiles (current-buffer))))))
           ,@body)
       (delete-directory directory t))))

(defun gdev-test-assessment--results (assessment)
  "Restituisci gli esiti di ASSESSMENT come alist (CONTROLLO . STATO)."
  (mapcar (lambda (result) (cons (alist-get 'control result) (alist-get 'status result)))
          (alist-get 'results assessment)))

(defun gdev-test-assessment--reason (assessment control)
  "Restituisci il motivo dell'esito di CONTROL in ASSESSMENT."
  (alist-get 'reason (seq-find (lambda (result) (equal (alist-get 'control result) control))
                               (alist-get 'results assessment))))

(defun gdev-test-assessment--baseline (db profile &rest evidence)
  "Porta una transazione di PROFILE a BASELINED in DB, con le prove di EVIDENCE.
Ogni prova è (STATO GENERE ORIGINE): si registra quando la transazione è in STATO."
  (let ((id (gdev-process-open db :title "Modifica di prova" :profile profile
                               :actor "proponente" :actor-kind 'human)))
    (dolist (state '(CLASSIFIED ANALYZED AUTHORIZED IMPLEMENTING VERIFYING REVIEWING APPROVED BASELINED))
      (dolist (item evidence)
        (when (eq (car item) (alist-get 'state (gdev-process-get db id)))
          (gdev-evidence-add db id :kind (nth 1 item) :origin (nth 2 item)
                             :description "Prova di prova" :content (format "%S" item)
                             :actor "ci" :actor-kind 'ci)))
      (gdev-process-advance db id state :actor "altra persona"
                            :actor-kind (if (memq state '(AUTHORIZED APPROVED BASELINED)) 'human 'agent)))
    id))

;;;; Standard

(ert-deftest gdev-test-standards-registry-is-valid-and-found-in-the-checkout ()
  "Il registro vero si legge, non ha problemi e sta nella cartella del checkout."
  (should (string-suffix-p "docs/assicurazione/" gdev-standards-directory))
  (let ((entries (gdev-standards-all)))
    (should (= (length entries) 23))
    (should-not (gdev-standards-problems entries))
    (should (equal (plist-get (gdev-standards-get "owasp-asvs") :edizione) "5.0.0"))
    (should-not (gdev-standards-get "inesistente"))))

(ert-deftest gdev-test-standards-registry-problems-are-reported ()
  "Voci incomplete, duplicate o con valori fuori elenco sono segnalate tutte."
  (let* ((good (car (gdev-standards-all)))
         (broken (list :id "rotto" :stato 'strano :classe-riuso 'libera))
         (problems (gdev-standards-problems (list good good broken))))
    (should (member (format "%s: identificativo duplicato" (plist-get good :id)) problems))
    (should (member "rotto: manca :titolo" problems))
    (should (member "rotto: stato non valido" problems))
    (should (member "rotto: classe di riuso non valida" problems))
    (should (equal (gdev-standards-problems 'nonunelenco) '("Il registro non è un elenco di voci")))
    (should (equal (gdev-standards-problems '(1 2)) '("Il registro non è un elenco di voci")))
    (should (member "voce senza :id: manca :id" (gdev-standards-problems (list (list :titolo "x")))))))

(ert-deftest gdev-test-standards-clause-index-comes-from-the-local-data ()
  "Le clausole esistono solo se i dati dello standard sono locali."
  (let ((asvs (gdev-standards-clauses "owasp-asvs"))
        (ssdf (gdev-standards-clauses "nist-sp-800-218")))
    (should (= (length asvs) 345))
    (should (member "V1.2.1" asvs))
    (dolist (clause '("PO.1" "PO.1.1" "PW.8.2" "RV.3.4" "PS.3.2"))
      (should (member clause ssdf)))
    ;; PW.4.3 non esiste nella versione 1.1.
    (should-not (member "PW.4.3" ssdf)))
  (should-not (gdev-standards-clauses "iso-iec-ieee-12207"))
  (should-not (gdev-standards-clauses "inesistente")))

(ert-deftest gdev-test-standards-references-must-be-true ()
  "Un riferimento falso è rifiutato col motivo: standard, stato, edizione, dati, clausola."
  (cl-flet ((check (id edition clause)
              (gdev-standards-check-reference (list :standard id :edizione edition :clausola clause))))
    (should-not (check "nist-sp-800-218" "1.1" "PW.8.2"))
    (should-not (check "owasp-asvs" "5.0.0" "V1.2.1"))
    (should (string-match-p "non è nel registro" (check "inesistente" "1" "x")))
    (should (string-match-p "non è nel registro" (check nil "1" "x")))
    (should (string-match-p "non ha dati locali" (check "ieee-1012" "2024" "x")))
    (should (string-match-p "è all'edizione 1.1, non 1.2" (check "nist-sp-800-218" "1.2" "PW.8.2")))
    (should (string-match-p "non ha dati locali" (check "iso-iec-ieee-12207" "2026" "6.4")))
    (should (string-match-p "non esiste" (check "ecss-e-st-40c" "Rev.1" "5.1")))
    (should (string-match-p "La clausola PW.4.3 non esiste" (check "nist-sp-800-218" "1.1" "PW.4.3")))))

(defvar gdev-test-standards--evaluated nil
  "Diventa non nil se un file di dati è stato valutato invece che letto.")

(ert-deftest gdev-test-standards-data-files-are-read-without-evaluating ()
  "Un file di dati si legge senza valutare nulla; un file rotto o assente è un errore chiaro."
  (gdev-test-assurance--with-root root
    (let ((good (concat root "buono.eld")) (eval-file (concat root "valuta.eld"))
          (broken (concat root "rotto.eld"))
          (gdev-test-standards--evaluated nil))
      (write-region "((:a 1) (:b \"è\"))" nil good nil 'silent)
      (write-region "(#.(setq gdev-test-standards--evaluated t))" nil eval-file nil 'silent)
      (write-region "((:a 1)" nil broken nil 'silent)
      (should (equal (gdev-standards-read good) '((:a 1) (:b "è"))))
      (dolist (file (list eval-file broken))
        (let ((err (should-error (gdev-standards-read file) :type 'gdev-standards-error)))
          (should (string-match-p "non si legge come dati" (cadr err)))))
      ;; Il rifiuto non basta: la forma non deve nemmeno essere stata valutata.
      (should-not gdev-test-standards--evaluated)
      (let ((err (should-error (gdev-standards-read (concat root "manca.eld"))
                               :type 'gdev-standards-error)))
        (should (string-match-p "File mancante" (cadr err)))))))

(ert-deftest gdev-test-standards-registry-with-problems-is-refused ()
  "Un registro con problemi non si usa: si segnala con tutti i problemi."
  (gdev-test-assurance--with-root root
    (make-directory (concat root "standard"))
    (write-region "((:id \"a\") (:id \"a\"))" nil (concat root "standard/registro.eld") nil 'silent)
    (let ((gdev-standards-directory root))
      (let ((err (should-error (gdev-standards-all) :type 'gdev-standards-error)))
        (should (string-match-p "a: manca :titolo" (cadr err)))
        (should (string-match-p "a: identificativo duplicato" (cadr err)))))))

;;;; Controlli e profili

(ert-deftest gdev-test-controls-real-data-is-valid-and-composes-the-profiles ()
  "I controlli e i profili veri sono validi e si compongono per eredità."
  (let* ((data (gdev-controls-load))
         (ids (lambda (profile)
                (mapcar (lambda (control) (plist-get control :id))
                        (gdev-controls-for-profile data profile)))))
    (should (= (length (plist-get data :controls)) 12))
    (should (equal (mapcar (lambda (profile) (plist-get profile :id)) (plist-get data :profiles))
                   gdev-process-profiles))
    (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get data :digest)))
    (should (equal (funcall ids 'core) '("GES-C01" "GES-C02" "GES-C03")))
    (should (equal (funcall ids 'quality) '("GES-C01" "GES-C02" "GES-C03" "GES-Q01")))
    (should (equal (funcall ids 'secure)
                   '("GES-C01" "GES-C02" "GES-C03" "GES-Q01" "GES-S01" "GES-S02" "GES-S03")))
    (should (equal (funcall ids 'high-assurance)
                   (append (funcall ids 'secure) '("GES-H01" "GES-H02" "GES-H03"))))
    (should (equal (funcall ids 'critical)
                   (append (funcall ids 'high-assurance) '("GES-K01" "GES-K02"))))
    (should (plist-get (gdev-controls-profile data 'critical) :provvisorio))
    (should-not (plist-get (gdev-controls-profile data 'core) :provvisorio))
    ;; Ogni riferimento di ogni controllo è vero.
    (dolist (control (plist-get data :controls))
      (dolist (reference (plist-get control :riferimenti))
        (should-not (gdev-standards-check-reference reference))))
    (let ((err (should-error (gdev-controls-for-profile data 'inesistente)
                             :type 'gdev-standards-error)))
      (should (string-match-p "Profilo sconosciuto" (cadr err))))))

(ert-deftest gdev-test-controls-problems-are-all-reported ()
  "Ogni genere di dato sbagliato in un controllo o in un profilo è segnalato."
  (let* ((reference '(:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.8.2"))
         (good `(:id "A" :titolo "t" :dovuto-da VERIFYING :metodo "m" :riferimenti (,reference)
                 :richiede ((:archivio-integro))))
         (problems
          (gdev-controls-problems
           (list good
                 good
                 '(:id "B")
                 `(:id "C" :titolo "t" :dovuto-da NOSTATO :metodo 5 :riferimenti nil :richiede nil)
                 `(:id "D" :titolo "t" :dovuto-da NEW :metodo "m"
                   :riferimenti ((:standard "nist-sp-800-218" :edizione "1.1" :clausola "PW.4.3"))
                   :richiede ((:passaggio :a NOSTATO :attore robot)
                              (:prova :genere opinione :origine presunta :minimo 0 :in NOSTATO)
                              (:separazione :stato NOSTATO)
                              (:archivio-integro :x 1)
                              (:sconosciuto)
                              (:passaggio :a)
                              storto))
                 "non-un-controllo")
           '((:id core :titolo "c" :eredita (nullo) :controlli ("A" "Z"))
             (:id quality :titolo 5 :eredita (core) :controlli ("A"))
             (:id secure :titolo "s" :eredita (critical) :controlli nil)
             (:id critical :titolo "k" :eredita (secure) :controlli nil)))))
    (dolist (fragment '("A: identificativo duplicato" "B: manca :titolo" "B: manca :richiede"
                        "C: :dovuto-da indica uno stato sconosciuto"
                        "C: :richiede deve elencare almeno un requisito"
                        "C: :metodo deve essere un testo" "C: serve almeno un riferimento"
                        "D: il passaggio indica uno stato sconosciuto"
                        "D: il passaggio indica un tipo d'attore sconosciuto"
                        "D: la prova indica un genere sconosciuto"
                        "D: la prova indica un'origine sconosciuta"
                        "D: la prova richiede un minimo intero positivo"
                        "D: la prova indica uno stato sconosciuto"
                        "D: la separazione indica uno stato sconosciuto"
                        "D: archivio-integro non ha argomenti"
                        "D: requisito sconosciuto"
                        "D: requisito non valido"
                        "La clausola PW.4.3 non esiste"
                        "Controllo non valido"
                        "I profili devono essere esattamente"
                        "core: eredita da un profilo che non esiste: nullo"
                        "core: cita il controllo Z, che non esiste"
                        "quality: :titolo deve essere un testo"
                        "quality: il controllo A è già di un altro profilo"
                        "secure: l'eredità è circolare"
                        "critical: l'eredità è circolare"))
      (should (seq-some (lambda (problem) (string-match-p (regexp-quote fragment) problem)) problems)))
    (should (member "I controlli non sono un elenco" (gdev-controls-problems 'x nil)))
    (should (member "I profili non sono un elenco" (gdev-controls-problems nil 'x)))))

(ert-deftest gdev-test-controls-load-refuses-invalid-data ()
  "Dati invalidi non si caricano: si segnalano tutti i problemi insieme."
  (gdev-test-controls--with-data ('((:id "X")) nil)
    (let ((err (should-error (gdev-controls-load) :type 'gdev-standards-error)))
      (should (string-match-p "X: manca :titolo" (cadr err)))
      (should (string-match-p "I profili" (concat (cadr err) "I profili")))))
  (gdev-test-controls--with-data (nil '((:id core :titolo "c" :eredita () :controlli ("GES-C01"))))
    (let ((err (should-error (gdev-controls-load) :type 'gdev-standards-error)))
      (should (string-match-p "I profili devono essere esattamente" (cadr err)))))
  (gdev-test-controls--with-data (nil nil)
    (delete-file (concat gdev-standards-directory "profili/profili.eld"))
    (should-error (gdev-controls-load) :type 'gdev-standards-error)))

(ert-deftest gdev-test-controls-digest-follows-the-data ()
  "L'impronta dei controlli è stabile per gli stessi dati e cambia se cambiano."
  (let ((first (plist-get (gdev-controls-load) :digest)))
    (should (equal first (plist-get (gdev-controls-load) :digest)))
    (gdev-test-controls--with-data ((let ((controls (gdev-standards-read
                                                     (expand-file-name "profili/controlli.eld"
                                                                       gdev-standards-directory))))
                                     (setf (plist-get (car controls) :metodo) "Un altro metodo.")
                                     controls)
                                   nil)
      (should-not (equal first (plist-get (gdev-controls-load) :digest))))))

;;;; Valutazione

(ert-deftest gdev-test-assessment-follows-a-transaction-through-its-states ()
  "Ogni controllo è NOT_VERIFIED finché il suo stato non è raggiunto e poi si decide."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-process-open db :title "Modifica" :profile 'secure
                                 :actor "proponente" :actor-kind 'human)))
      (let ((a (gdev-assessment-run db id)))
        (should (equal (gdev-test-assessment--results a)
                       '(("GES-C01" . "NOT_VERIFIED") ("GES-C02" . "SATISFIED")
                         ("GES-C03" . "NOT_VERIFIED") ("GES-Q01" . "NOT_VERIFIED")
                         ("GES-S01" . "NOT_VERIFIED") ("GES-S02" . "NOT_VERIFIED")
                         ("GES-S03" . "NOT_VERIFIED")))))
      (dolist (state '(CLASSIFIED ANALYZED))
        (gdev-process-advance db id state :actor "ag" :actor-kind 'agent))
      (gdev-evidence-add db id :kind 'deduction :description "Rischio" :content "x"
                         :actor "ci" :actor-kind 'ci)
      (gdev-process-advance db id 'AUTHORIZED :actor "altra persona" :actor-kind 'human)
      (let ((a (gdev-assessment-run db id)))
        (should (equal (cdr (assoc "GES-S01" (gdev-test-assessment--results a))) "SATISFIED"))
        (should (equal (cdr (assoc "GES-S02" (gdev-test-assessment--results a))) "SATISFIED"))
        (should (equal (cdr (assoc "GES-C01" (gdev-test-assessment--results a))) "NOT_VERIFIED")))
      (gdev-process-advance db id 'IMPLEMENTING :actor "ag" :actor-kind 'agent)
      (should (equal (cdr (assoc "GES-C01" (gdev-test-assessment--results (gdev-assessment-run db id))))
                     "SATISFIED"))
      (gdev-process-advance db id 'VERIFYING :actor "ag" :actor-kind 'agent)
      (gdev-evidence-add db id :kind 'fact :description "Test" :content "ok"
                         :actor "ci" :actor-kind 'ci)
      (gdev-process-advance db id 'REVIEWING :actor "ag" :actor-kind 'agent)
      (let ((a (gdev-assessment-run db id)))
        (should (equal (cdr (assoc "GES-Q01" (gdev-test-assessment--results a))) "SATISFIED"))
        (should (equal (cdr (assoc "GES-S03" (gdev-test-assessment--results a))) "NOT_VERIFIED"))))))

(ert-deftest gdev-test-assessment-satisfies-every-control-with-all-the-evidence ()
  "Con le prove richieste, una transazione secure arriva a BASELINED con tutto soddisfatto."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assessment--baseline
                db 'secure '(ANALYZED deduction collected) '(VERIFYING fact collected)
                '(REVIEWING fact collected)))
           (a (gdev-assessment-run db id)))
      (should (equal (delete-dups (mapcar #'cdr (gdev-test-assessment--results a))) '("SATISFIED")))
      (should (= (alist-get 'SATISFIED (alist-get 'summary a)) 7))
      (should (= (alist-get 'NOT_SATISFIED (alist-get 'summary a)) 0))
      (should (string-match-p "2 prove\\|1 prova" (gdev-test-assessment--reason a "GES-S02")))
      (should (equal (alist-get 'evidence (seq-find (lambda (r) (equal (alist-get 'control r) "GES-S02"))
                                                    (alist-get 'results a)))
                     ["EV-0001"])))))

(ert-deftest gdev-test-assessment-says-what-is-missing ()
  "Senza le prove richieste, un controllo dovuto è NOT_SATISFIED e dice cosa manca."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assessment--baseline db 'secure '(VERIFYING fact collected)))
           (a (gdev-assessment-run db id)))
      (should (equal (cdr (assoc "GES-S02" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
      (should (equal (cdr (assoc "GES-S03" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
      (should (string-match-p "Nessuna prova deduction (collected) registrata in ANALYZED"
                              (gdev-test-assessment--reason a "GES-S02")))
      (should (= (alist-get 'NOT_SATISFIED (alist-get 'summary a)) 2))
      (should (= (alist-get 'SATISFIED (alist-get 'summary a)) 5)))))

(ert-deftest gdev-test-assessment-does-not-count-reconstructed-evidence ()
  "Una prova ricostruita non soddisfa un controllo che chiede una prova raccolta."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assessment--baseline
                db 'secure '(ANALYZED deduction reconstructed) '(VERIFYING fact collected)
                '(REVIEWING hypothesis collected)))
           (a (gdev-assessment-run db id)))
      (should (equal (cdr (assoc "GES-S02" (gdev-test-assessment--results a))) "NOT_VERIFIED"))
      (should (string-match-p "prove deduction, ma non collected: ne servono 1 e ne risultano 0"
                              (gdev-test-assessment--reason a "GES-S02")))
      (should (equal (cdr (assoc "GES-S03" (gdev-test-assessment--results a))) "NOT_SATISFIED")))))

(ert-deftest gdev-test-assessment-follows-the-minimum-of-the-control ()
  "Un controllo che chiede più prove le conta una per una."
  (let ((controls (gdev-standards-read (expand-file-name "profili/controlli.eld"
                                                         gdev-standards-directory))))
    (setf (plist-get (nth 3 controls) :richiede)
          '((:prova :genere fact :origine collected :minimo 2 :in VERIFYING)))
    (gdev-test-controls--with-data (controls nil)
      (gdev-test-assurance--with-archive (root db)
        (let* ((one (gdev-test-assessment--baseline db 'quality '(VERIFYING fact collected)))
               (two (gdev-test-assessment--baseline db 'quality '(VERIFYING fact collected)
                                                    '(VERIFYING fact collected))))
          (should (equal (cdr (assoc "GES-Q01" (gdev-test-assessment--results
                                                 (gdev-assessment-run db one))))
                         "NOT_VERIFIED"))
          (should (equal (cdr (assoc "GES-Q01" (gdev-test-assessment--results
                                                 (gdev-assessment-run db two))))
                         "SATISFIED"))
          (should (string-match-p "2 prove fact (collected)"
                                  (gdev-test-assessment--reason (gdev-assessment-run db two)
                                                                "GES-Q01"))))))))

(ert-deftest gdev-test-assessment-detects-a-forged-history ()
  "Una catena riscritta per aggirare le regole non soddisfa i controlli di GDev."
  (gdev-test-assurance--with-archive (root db)
    ;; Un agente porta una transazione in AUTHORIZED, dichiarandosi persona, e salta passaggi.
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--walk db id 'CLASSIFIED)
      (gdev-assurance-db-transaction
       db (lambda ()
            (gdev-process-append-event db id 'transition 'CLASSIFIED 'IMPLEMENTING "ag" 'agent)
            (sqlite-execute db "update tx set state = 'IMPLEMENTING' where id = ?" (list id))))
      (let ((a (gdev-assessment-run db id)))
        (should (equal (cdr (assoc "GES-C01" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
        (should (string-match-p "Nessun passaggio a AUTHORIZED registrato"
                                (gdev-test-assessment--reason a "GES-C01")))
        (should (equal (cdr (assoc "GES-C02" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
        (should (string-match-p "La verifica dell'archivio trova" (gdev-test-assessment--reason a "GES-C02")))
        ;; AUTHORIZED non è mai stato raggiunto: la separazione non si può ancora dire.
        (should (equal (cdr (assoc "GES-S01" (gdev-test-assessment--results a))) "NOT_VERIFIED"))))
    ;; Un agente autorizza dichiarandosi tale: il passaggio c'è ma non è di una persona.
    (let ((id (gdev-test-assurance--open db 'core)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (gdev-assurance-db-transaction
       db (lambda ()
            (gdev-process-append-event db id 'transition 'ANALYZED 'AUTHORIZED "ag" 'agent)
            (gdev-process-append-event db id 'transition 'AUTHORIZED 'IMPLEMENTING "ag" 'agent)
            (sqlite-execute db "update tx set state = 'IMPLEMENTING' where id = ?" (list id))))
      (let ((a (gdev-assessment-run db id)))
        (should (string-match-p "è di un attore di tipo agent, non human"
                                (gdev-test-assessment--reason a "GES-C01")))))
    nil)
  ;; Chi propone autorizza: l'archivio non lo vieta nei dati, il controllo di separazione sì.
  ;; Un archivio a parte: l'integrità è un controllo dell'archivio intero.
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'secure)))
      (gdev-test-assurance--walk db id 'CLASSIFIED 'ANALYZED)
      (gdev-assurance-db-transaction
       db (lambda ()
            (gdev-process-append-event db id 'transition 'ANALYZED 'AUTHORIZED "proponente" 'human)
            (sqlite-execute db "update tx set state = 'AUTHORIZED' where id = ?" (list id))))
      (let ((a (gdev-assessment-run db id)))
        (should (equal (cdr (assoc "GES-C02" (gdev-test-assessment--results a))) "SATISFIED"))
        (should (equal (cdr (assoc "GES-S01" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
        (should (string-match-p "proponente ha aperto la transazione e l'ha portata a AUTHORIZED"
                                (gdev-test-assessment--reason a "GES-S01")))))))

(ert-deftest gdev-test-assessment-a-separation-control-needs-the-passage ()
  "Un controllo di separazione dovuto prima del passaggio lo cerca e non lo trova."
  (let ((controls (gdev-standards-read (expand-file-name "profili/controlli.eld"
                                                         gdev-standards-directory))))
    (setf (plist-get (nth 4 controls) :dovuto-da) 'PROPOSED)
    (gdev-test-controls--with-data (controls nil)
      (gdev-test-assurance--with-archive (root db)
        (let ((a (gdev-assessment-run db (gdev-test-assurance--open db 'secure))))
          (should (equal (cdr (assoc "GES-S01" (gdev-test-assessment--results a))) "NOT_SATISFIED"))
          (should (string-match-p "Nessun passaggio a AUTHORIZED registrato"
                                  (gdev-test-assessment--reason a "GES-S01"))))))))

(ert-deftest gdev-test-assessment-concluded-transactions-have-nothing-to-assess ()
  "Una transazione rifiutata o annullata ha tutti i controlli NOT_APPLICABLE."
  (gdev-test-assurance--with-archive (root db)
    (dolist (state '(REJECTED CANCELLED))
      (let ((id (gdev-test-assurance--open db 'secure)))
        (gdev-test-assurance--step db id state 'human)
        (let ((a (gdev-assessment-run db id)))
          (should (equal (delete-dups (mapcar #'cdr (gdev-test-assessment--results a)))
                         '("NOT_APPLICABLE")))
          (should (= (alist-get 'NOT_APPLICABLE (alist-get 'summary a)) 7))
          (should (string-match-p (format "è in %s" state)
                                  (gdev-test-assessment--reason a "GES-C01"))))))))

(ert-deftest gdev-test-assessment-is-reproducible-and-records-its-inputs ()
  "Gli stessi dati danno lo stesso risultato; l'impronta cambia solo se cambiano i dati."
  (gdev-test-assurance--with-archive (root db)
    (let* ((id (gdev-test-assurance--open db 'quality))
           (first (gdev-assessment-run db id))
           (second (gdev-assessment-run db id)))
      (should (equal first second))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (alist-get 'input_digest first)))
      (should (equal (alist-get 'chain_head first)
                     (caar (sqlite-select db "select hash from tx_event order by seq desc limit 1"))))
      (gdev-test-assurance--step db id 'CLASSIFIED)
      (let ((third (gdev-assessment-run db id)))
        (should-not (equal (alist-get 'input_digest first) (alist-get 'input_digest third)))
        (should-not (equal (alist-get 'chain_head first) (alist-get 'chain_head third)))
        (should (equal (alist-get 'controls_digest first) (alist-get 'controls_digest third))))
      (gdev-test-controls--with-data ((let ((controls (gdev-standards-read
                                                       (expand-file-name "profili/controlli.eld"
                                                                         gdev-standards-directory))))
                                       (setf (plist-get (car controls) :titolo) "Un altro titolo")
                                       controls)
                                     nil)
        (let ((changed (gdev-assessment-run db id)))
          (should-not (equal (alist-get 'controls_digest changed) (alist-get 'controls_digest first)))
          (should-not (equal (alist-get 'input_digest changed) (alist-get 'input_digest first))))))))

(ert-deftest gdev-test-assessment-never-produces-the-reserved-waiver ()
  "L'esito di deroga esiste fra quelli possibili ma nessuna valutazione lo produce."
  (should (memq 'WAIVED_WITH_AUTHORIZATION gdev-assessment-statuses))
  (should (= (length gdev-assessment-statuses) 5))
  (gdev-test-assurance--with-archive (root db)
    (let ((a (gdev-assessment-run db (gdev-test-assurance--open db 'critical))))
      (should (= (alist-get 'WAIVED_WITH_AUTHORIZATION (alist-get 'summary a)) 0))
      (should-not (member "WAIVED_WITH_AUTHORIZATION"
                          (mapcar #'cdr (gdev-test-assessment--results a))))
      (should (eq (alist-get 'provisional a) t))
      (should (equal (alist-get 'profile_title a) "GES Critical"))
      (should (string-match-p "non attesta la conformità" (alist-get 'note a))))))

(ert-deftest gdev-test-assessment-is-json-ready-and-cites-informative-references ()
  "La valutazione si serializza in JSON e riporta i riferimenti come testo."
  (gdev-test-assurance--with-archive (root db)
    (let ((a (gdev-assessment-run db (gdev-test-assurance--open db 'core))))
      (should (stringp (json-serialize a)))
      (should (equal (alist-get 'references (aref (alist-get 'results a) 0))
                     ["nist-sp-800-218 1.1 PO.2.3"]))
      (should (eq (alist-get 'provisional a) :false)))))

(ert-deftest gdev-test-assessment-refuses-a-missing-transaction-and-invalid-data ()
  "Senza la transazione, o con dati dei controlli invalidi, non si valuta nulla."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db)))
      (should-error (gdev-assessment-run db "GT-0099") :type 'gdev-assurance-no-transaction)
      (gdev-test-controls--with-data ('((:id "X")) nil)
        (should-error (gdev-assessment-run db id) :type 'gdev-standards-error)))))

(ert-deftest gdev-test-assessment-cli-prints-the-evaluation-and-fails-on-missing-controls ()
  "`gdev assurance assess' stampa la valutazione; esce con 1 se un controllo non è soddisfatto."
  (gdev-test-assurance--with-archive (root db)
    (let ((good (gdev-test-assessment--baseline
                 db 'secure '(ANALYZED deduction collected) '(VERIFYING fact collected)
                 '(REVIEWING fact collected)))
          (bad (gdev-test-assessment--baseline db 'secure '(VERIFYING fact collected)))
          (pending (gdev-test-assurance--open db 'critical)))
      (gdev-assurance-db-close db)
      (let ((result (gdev-test-assurance--cli root "assess" good)))
        (should (= (car result) 0))
        (should (string-match-p (format "Valutazione di %s: GES Secure" good) (cdr result)))
        (should (string-match-p "GES-C01 +Soddisfatto +Autorizzazione di una persona" (cdr result)))
        (should (string-match-p "Riepilogo: 7 Soddisfatto, 0 Non soddisfatto, 0 Da verificare" (cdr result)))
        (should (string-match-p "non attesta la conformità" (cdr result))))
      (let ((result (gdev-test-assurance--cli root "assess" bad)))
        (should (= (car result) 1))
        (should (string-match-p "GES-S02 +Non soddisfatto" (cdr result))))
      (let ((result (gdev-test-assurance--cli root "assess" pending)))
        (should (= (car result) 0))
        (should (string-match-p "GES Critical (provvisorio)" (cdr result))))
      (let ((result (gdev-test-assurance--cli root "assess" "GT-0099")))
        (should (= (car result) 1))
        (should (string-match-p "GT-0099 non esiste" (cdr result))))
      (let ((result (gdev-test-assurance--cli root "assess")))
        (should (= (car result) 2))
        (should (string-match-p "gdev assurance assess ID" (cdr result)))))))

(ert-deftest gdev-test-assessment-live-action-reads-the-evaluation ()
  "Lo strumento MCP `assess' restituisce la valutazione e chiede l'identificativo."
  (gdev-test-assurance--with-archive (root db)
    (let ((id (gdev-test-assurance--open db 'core)))
      (gdev-assurance-db-close db)
      (let ((data (gdev-test-assurance--live "assess" id root)))
        (should (equal (alist-get 'transaction data) id))
        (should (= (length (alist-get 'results data)) 3))
        (should (stringp (json-serialize (gdev-agent-interface--dispatch "assurance"
                                                                        (list "assess" id root))))))
      (let ((err (should-error (gdev-test-assurance--live "assess" "" root) :type 'user-error)))
        (should (string-match-p "Indica l.identificativo" (cadr err))))
      (let ((err (should-error (gdev-test-assurance--live "assess" "GT-0099" root) :type 'user-error)))
        (should (string-match-p "GT-0099 non esiste" (cadr err)))))))

(provide 'gdev-assessment-test)
;;; gdev-assessment-test.el ends here
