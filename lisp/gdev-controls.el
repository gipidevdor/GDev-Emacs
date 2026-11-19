;;; gdev-controls.el --- Controlli operativi e profili di rigore -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Un controllo operativo dice che cosa si osserva nell'archivio di assicurazione
;; perché una transazione sia in regola: un passaggio compiuto da una persona,
;; una prova raccolta in un certo stato, un'integrità verificata.  Lo scrive
;; GDev e non riproduce testo normativo; i riferimenti a uno standard sono un
;; collegamento informativo e ogni clausola citata esiste nei dati locali.
;;
;; Un profilo è una composizione di controlli: i propri più quelli dei profili
;; che eredita.  I cinque profili sono quelli dello schema dell'archivio.
;;
;; I dati stanno in docs/assicurazione/profili: `controlli.eld' e `profili.eld'.
;; Si leggono come dati, si controllano per intero prima dell'uso e hanno
;; un'impronta (SHA-256), che una valutazione registra per essere riproducibile.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gdev-process)
(require 'gdev-evidence)
(require 'gdev-standards)

(defconst gdev-controls--required-keys
  '(:id :titolo :decidibile :dovuto-da :richiede :metodo :riferimenti)
  "Chiavi che ogni controllo deve avere.")

(defconst gdev-controls--decision-kinds '(waiver not-applicable)
  "Generi di decisione che un requisito può citare: come `gdev-decision-kinds'.
Non si legge da `gdev-decisions', che dipende da questo file.")

(defun gdev-controls--requirement-problems (id requirement)
  "Restituisci i problemi del requisito REQUIREMENT del controllo ID."
  (let ((kind (car-safe requirement))
        (arguments (cdr-safe requirement))
        problems)
    (cl-flet ((bad (format-string &rest values)
                (push (format "%s: %s" id (apply #'format format-string values)) problems)))
      (if (not (plistp arguments))
          (bad "requisito non valido: %S" requirement)
        (pcase kind
          (:passaggio
           (unless (memq (plist-get arguments :a) gdev-process-states)
             (bad "il passaggio indica uno stato sconosciuto"))
           (unless (memq (plist-get arguments :attore) gdev-process-actor-kinds)
             (bad "il passaggio indica un tipo d'attore sconosciuto")))
          (:prova
           (unless (memq (plist-get arguments :genere) gdev-evidence-kinds)
             (bad "la prova indica un genere sconosciuto"))
           (unless (memq (plist-get arguments :origine) gdev-evidence-origins)
             (bad "la prova indica un'origine sconosciuta"))
           (unless (and (integerp (plist-get arguments :minimo)) (>= (plist-get arguments :minimo) 1))
             (bad "la prova richiede un minimo intero positivo"))
           (unless (memq (plist-get arguments :in) gdev-process-states)
             (bad "la prova indica uno stato sconosciuto"))
           (when (and (plist-member arguments :attore)
                      (not (memq (plist-get arguments :attore) gdev-process-actor-kinds)))
             (bad "la prova indica un tipo d'attore sconosciuto"))
           (when (and (plist-member arguments :indipendente-da-chi-porta-a)
                      (not (memq (plist-get arguments :indipendente-da-chi-porta-a)
                                 gdev-process-states)))
             (bad "la prova indica uno stato sconosciuto per l'indipendenza")))
          (:valutazione-registrata
           (unless (memq (plist-get arguments :prima-di) gdev-process-states)
             (bad "la valutazione registrata indica uno stato sconosciuto")))
          (:attori-distinti
           (let ((states (plist-get arguments :stati)))
             (unless (and (proper-list-p states) (= (length states) 2)
                          (cl-every (lambda (state) (memq state gdev-process-states)) states))
               (bad "gli attori distinti richiedono due stati noti"))))
          (:nessuna-decisione
           (unless (memq (plist-get arguments :genere) gdev-controls--decision-kinds)
             (bad "la decisione indica un genere sconosciuto")))
          (:separazione
           (unless (memq (plist-get arguments :stato) gdev-process-states)
             (bad "la separazione indica uno stato sconosciuto")))
          (:archivio-integro
           (when arguments (bad "archivio-integro non ha argomenti")))
          (_ (bad "requisito sconosciuto: %S" kind)))))
    problems))

(defun gdev-controls--control-problems (control)
  "Restituisci i problemi del controllo CONTROL: nil se è valido."
  (let ((id (or (and (plistp control) (plist-get control :id)) "controllo senza :id"))
        problems)
    (if (not (plistp control))
        (push (format "Controllo non valido: %S" control) problems)
      (dolist (key gdev-controls--required-keys)
        (unless (plist-member control key)
          (push (format "%s: manca %s" id key) problems)))
      (unless (and (stringp (plist-get control :id)) (not (string-empty-p (plist-get control :id)))
                   (stringp (plist-get control :titolo)))
        (push (format "%s: identificativo e titolo devono essere testi" id) problems))
      (unless (memq (plist-get control :decidibile) '(t nil))
        (push (format "%s: :decidibile deve essere t o nil" id) problems))
      (unless (memq (plist-get control :dovuto-da) gdev-process-states)
        (push (format "%s: :dovuto-da indica uno stato sconosciuto" id) problems))
      (unless (and (consp (plist-get control :richiede)) (proper-list-p (plist-get control :richiede)))
        (push (format "%s: :richiede deve elencare almeno un requisito" id) problems))
      (dolist (requirement (and (proper-list-p (plist-get control :richiede))
                                (plist-get control :richiede)))
        (setq problems (append (nreverse (gdev-controls--requirement-problems id requirement))
                               problems)))
      (unless (stringp (plist-get control :metodo))
        (push (format "%s: :metodo deve essere un testo" id) problems))
      (unless (and (consp (plist-get control :riferimenti))
                   (proper-list-p (plist-get control :riferimenti)))
        (push (format "%s: serve almeno un riferimento" id) problems))
      (dolist (reference (and (proper-list-p (plist-get control :riferimenti))
                              (plist-get control :riferimenti)))
        (when-let* ((reason (gdev-standards-check-reference reference)))
          (push (format "%s: %s" id reason) problems))))
    (nreverse problems)))

(defun gdev-controls-problems (controls profiles)
  "Restituisci i problemi di CONTROLS e PROFILES: nil se i dati sono validi."
  (let (problems ids)
    (if (not (proper-list-p controls))
        (push "I controlli non sono un elenco" problems)
      (dolist (control controls)
        (setq problems (append (reverse (gdev-controls--control-problems control)) problems))
        (let ((id (and (plistp control) (plist-get control :id))))
          (when (member id ids) (push (format "%s: identificativo duplicato" id) problems))
          (push id ids))))
    (if (not (proper-list-p profiles))
        (push "I profili non sono un elenco" problems)
      (let ((profile-ids (mapcar (lambda (profile) (and (plistp profile) (plist-get profile :id)))
                                 profiles))
            owned)
        (unless (equal (sort (mapcar #'symbol-name (cl-remove-if-not #'symbolp profile-ids)) #'string<)
                       (sort (mapcar #'symbol-name gdev-process-profiles) #'string<))
          (push (format "I profili devono essere esattamente %s"
                        (mapconcat #'symbol-name gdev-process-profiles ", "))
                problems))
        (dolist (profile profiles)
          (unless (and (plistp profile) (proper-list-p (plist-get profile :eredita))
                       (cl-every #'symbolp (plist-get profile :eredita))
                       (proper-list-p (plist-get profile :controlli))
                       (cl-every #'stringp (plist-get profile :controlli)))
            (push "I profili richiedono elenchi di genitori e controlli validi" problems)))
        (setq profiles (cl-remove-if-not
                        (lambda (profile) (and (plistp profile)
                                               (proper-list-p (plist-get profile :eredita))
                                               (cl-every #'symbolp (plist-get profile :eredita))
                                               (proper-list-p (plist-get profile :controlli))
                                               (cl-every #'stringp (plist-get profile :controlli)))) profiles))
        (dolist (profile profiles)
          (let ((id (and (plistp profile) (plist-get profile :id))))
            (unless (and (plistp profile) (stringp (plist-get profile :titolo)))
              (push (format "%s: :titolo deve essere un testo" id) problems))
            (dolist (parent (plist-get profile :eredita))
              (unless (memq parent profile-ids)
                (push (format "%s: eredita da un profilo che non esiste: %s" id parent) problems)))
            (dolist (control-id (plist-get profile :controlli))
              (unless (member control-id ids)
                (push (format "%s: cita il controllo %s, che non esiste" id control-id) problems))
              (when (member control-id owned)
                (push (format "%s: il controllo %s è già di un altro profilo" id control-id) problems))
              (push control-id owned))))
        ;; Un'eredità circolare non finisce mai: si cerca prima di comporre.
        (dolist (profile profiles)
          (let ((seen nil) (queue (list (plist-get profile :id))))
            (while queue
              (let ((current (pop queue)))
                (if (memq current seen)
                    nil
                  (push current seen)
                  (let ((parents (plist-get (cl-find current profiles
                                                     :key (lambda (item) (plist-get item :id)))
                                            :eredita)))
                    (when (memq (plist-get profile :id) parents)
                      (push (format "%s: l'eredità è circolare" (plist-get profile :id)) problems))
                    (setq queue (append queue parents)))))))))
      (delete-dups problems))
    (nreverse (delete-dups problems))))

(defun gdev-controls-load ()
  "Leggi e controlla controlli e profili.  Restituisci (:controls C :profiles P
:digest D).  Segnala `gdev-standards-error' con tutti i problemi se i dati
non sono validi."
  (let* ((directory (expand-file-name "profili/" gdev-standards-directory))
         (controls (gdev-standards-read (expand-file-name "controlli.eld" directory)))
         (profiles (gdev-standards-read (expand-file-name "profili.eld" directory)))
         (problems (gdev-controls-problems controls profiles)))
    (when problems
      (signal 'gdev-standards-error (list (mapconcat #'identity problems "; "))))
    (list :controls controls :profiles profiles
          :digest (secure-hash 'sha256 (encode-coding-string
                                        (let ((print-length nil) (print-level nil))
                                          (prin1-to-string (list controls profiles)))
                                        'utf-8)))))

(defun gdev-controls-profile (data profile)
  "Restituisci la voce del profilo PROFILE, un simbolo, nei DATA di
`gdev-controls-load'."
  (cl-find profile (plist-get data :profiles) :key (lambda (item) (plist-get item :id))))

(defun gdev-controls-for-profile (data profile)
  "Restituisci i controlli di PROFILE secondo DATA: prima quelli ereditati.
L'ordine è stabile: i profili ereditati nell'ordine in cui sono elencati, poi i
controlli propri nell'ordine del profilo."
  (let ((entry (gdev-controls-profile data profile)))
    (unless entry
      (signal 'gdev-standards-error (list (format "Profilo sconosciuto: %s" profile))))
    (let (ids)
      (dolist (parent (plist-get entry :eredita))
        (dolist (control (gdev-controls-for-profile data parent))
          (cl-pushnew (plist-get control :id) ids :test #'equal)))
      (dolist (id (plist-get entry :controlli))
        (cl-pushnew id ids :test #'equal))
      (mapcar (lambda (id)
                (cl-find id (plist-get data :controls) :key (lambda (item) (plist-get item :id))
                         :test #'equal))
              (nreverse ids)))))

(provide 'gdev-controls)
;;; gdev-controls.el ends here
