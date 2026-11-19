;;; gdev-print.el --- Stampa dei documenti con i colori dell'editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; La stampa conserva colori, grassetto, corsivo, sottolineatura e
;; barratura del documento, letti dalle facce del testo (non dagli
;; evidenziatori temporanei come la riga corrente o la selezione).
;;
;; I colori pensati per lo schermo si adattano alla carta bianca: il testo
;; conserva la tinta e si scurisce finché raggiunge un contrasto di almeno
;; 4,5:1, gli sfondi scuri del tema scuro diventano tinte chiare.  Con il
;; tema chiaro i colori restano quelli dell'editor.
;;
;; Su macOS il testo composto passa, in JSON, al dialogo di stampa nativo
;; (bin/gdev-print-macos.swift), con anteprima e scelta della stampante.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'seq)
(require 'subr-x)
(require 'gdev-lib)

(defconst gdev-print-minimum-contrast 4.5
  "Contrasto minimo fra il testo stampato e il suo sfondo.")

(defconst gdev-print--paper '(1.0 1.0 1.0)
  "Colore della carta, in componenti sRGB fra 0 e 1.")

(defconst gdev-print--bold-weights
  '(semi-bold semibold demibold demi-bold bold extra-bold extrabold
              ultra-bold ultrabold heavy black ultra-heavy)
  "Spessori stampati in grassetto.")

;;;; Colori

(defun gdev-print--rgb (color)
  "Componenti sRGB di COLOR, un nome o una specifica #RRGGBB, o nil."
  (when (and (stringp color) (not (string-prefix-p "unspecified" color)))
    ;; `color-values-from-color-spec' legge #RRGGBB anche senza schermo
    ;; grafico; `color-values' risolve i nomi sullo schermo corrente.
    (when-let* ((values (or (color-values-from-color-spec color) (color-values color))))
      (mapcar (lambda (value) (/ value 65535.0)) values))))

(defun gdev-print--luminance (rgb)
  "Luminanza relativa WCAG del colore sRGB RGB."
  (cl-loop for component in rgb
           for weight in '(0.2126 0.7152 0.0722)
           sum (* weight (if (<= component 0.04045) (/ component 12.92)
                           (expt (/ (+ component 0.055) 1.055) 2.4)))))

(defun gdev-print--contrast (first second)
  "Rapporto di contrasto WCAG fra i colori sRGB FIRST e SECOND."
  (let ((a (gdev-print--luminance first))
        (b (gdev-print--luminance second)))
    (/ (+ (max a b) 0.05) (+ (min a b) 0.05))))

(defun gdev-print--hex (rgb)
  "Specifica #RRGGBB del colore sRGB RGB."
  (apply #'format "#%02x%02x%02x"
         (mapcar (lambda (component) (round (* 255 (min 1.0 (max 0.0 component))))) rgb)))

(defun gdev-print--paper-background (rgb)
  "Sfondo RGB adattato alla carta: uno sfondo scuro diventa una tinta chiara."
  (if (>= (gdev-print--luminance rgb) 0.3)
      rgb
    (pcase-let ((`(,hue ,saturation ,lightness) (apply #'color-rgb-to-hsl rgb)))
      (color-hsl-to-rgb hue (min saturation 0.6) (max 0.88 (- 1.0 lightness))))))

(defun gdev-print--ink (rgb background)
  "Colore RGB scurito, con la stessa tinta, fino al contrasto minimo su BACKGROUND."
  (pcase-let ((`(,hue ,saturation ,lightness) (apply #'color-rgb-to-hsl rgb)))
    (while (and (> lightness 0.0)
                (< (gdev-print--contrast rgb background) gdev-print-minimum-contrast))
      (setq lightness (max 0.0 (- lightness 0.02))
            rgb (color-hsl-to-rgb hue saturation lightness)))
    rgb))

;;;; Facce

(defun gdev-print--face-value (spec attribute)
  "Valore di ATTRIBUTE nella proprietà `face' SPEC, o nil se non è indicato.
SPEC è una faccia, una lista di facce o una faccia anonima, come nelle
proprietà del testo; vince la prima faccia che indica ATTRIBUTE."
  (let ((value
         (cond ((null spec) nil)
               ((symbolp spec)
                (and (facep spec) (face-attribute spec attribute nil t)))
               ((keywordp (car-safe spec))
                (if-let* ((cell (plist-member spec attribute)))
                    (cadr cell)
                  (gdev-print--face-value (plist-get spec :inherit) attribute)))
               ((eq (car-safe spec) 'foreground-color)
                (and (eq attribute :foreground) (cdr spec)))
               ((eq (car-safe spec) 'background-color)
                (and (eq attribute :background) (cdr spec)))
               ((consp spec)
                (seq-some (lambda (face) (gdev-print--face-value face attribute)) spec)))))
    (unless (eq value 'unspecified) value)))

(defun gdev-print--style (spec defaults)
  "Stile di stampa (PRIMO-PIANO SFONDO STILE) della proprietà `face' SPEC.
DEFAULTS è (PRIMO-PIANO . SFONDO) della faccia `default', in sRGB.  I
colori sono specifiche #RRGGBB, nil per l'inchiostro e la carta; STILE
somma 1 per il grassetto, 2 per il corsivo, 4 per la sottolineatura e 8
per la barratura."
  (let ((foreground (gdev-print--rgb (gdev-print--face-value spec :foreground)))
        (background (gdev-print--rgb (gdev-print--face-value spec :background))))
    (when (eq (gdev-print--face-value spec :inverse-video) t)
      (setq foreground (prog1 (or background (cdr defaults)) (setq background (or foreground (car defaults))))))
    (when (equal foreground (car defaults)) (setq foreground nil))
    (when (equal background (cdr defaults)) (setq background nil))
    (let* ((paper (and background (gdev-print--paper-background background)))
           (ink (and foreground (gdev-print--ink foreground (or paper gdev-print--paper))))
           (underline (gdev-print--face-value spec :underline))
           (strike (gdev-print--face-value spec :strike-through)))
      (list (and ink (gdev-print--hex ink))
            (and paper (gdev-print--hex paper))
            (+ (if (memq (gdev-print--face-value spec :weight) gdev-print--bold-weights) 1 0)
               (if (memq (gdev-print--face-value spec :slant)
                         '(italic oblique reverse-italic reverse-oblique))
                   2 0)
               (if underline 4 0)
               (if strike 8 0))))))

(defun gdev-print-runs (&optional start end)
  "Tratti di testo fra START ed END con lo stesso stile di stampa.
Ogni tratto è (TESTO PRIMO-PIANO SFONDO STILE), come in `gdev-print--style'.
Contano le facce del testo, comprese quelle di font-lock; gli
evidenziatori sovrapposti (overlay) restano fuori dalla stampa.  Il testo
nascosto, per esempio un blocco ripiegato o la parte nascosta di un
collegamento di Org, non si stampa: sulla carta compare ciò che si vede."
  (let* ((start (or start (point-min)))
         (end (or end (point-max)))
         (defaults (cons (gdev-print--rgb (face-attribute 'default :foreground nil t))
                         (gdev-print--rgb (face-attribute 'default :background nil t))))
         (styles (make-hash-table :test #'equal))
         (position start)
         ;; Ogni elemento è (PARTI-IN-ORDINE-INVERSO . STILE).
         runs)
    (while (< position end)
      (let ((next (min (next-single-property-change position 'face nil end)
                       (next-single-char-property-change position 'invisible nil end))))
        (unless (invisible-p position)
          (let* ((spec (get-text-property position 'face))
                 (style (or (gethash spec styles)
                            (puthash spec (gdev-print--style spec defaults) styles)))
                 (text (buffer-substring-no-properties position next)))
            (if (and runs (equal (cdr (car runs)) style))
                (push text (car (car runs)))
              (push (cons (list text) style) runs))))
        (setq position next)))
    (mapcar (lambda (run) (cons (apply #'concat (nreverse (car run))) (cdr run)))
            (nreverse runs))))

;;;; Dialogo di stampa di macOS

(defun gdev-print--payload ()
  "Documento corrente in JSON per il dialogo di stampa, come stringa UTF-8."
  (font-lock-ensure)
  (let ((document
         `((font . ,(or (let ((family (face-attribute 'default :family nil t)))
                          (and (stringp family) family))
                        :null))
           (tab . ,tab-width)
           (runs . ,(vconcat
                     (mapcar (lambda (run)
                               (vconcat (mapcar (lambda (value) (or value :null)) run)))
                             (gdev-print-runs)))))))
    (condition-case nil
        (json-serialize document)
      (wrong-type-argument
       (user-error "Il documento contiene caratteri che non si possono stampare in UTF-8")))))

(defun gdev-print--payload-file (payload)
  "Scrive PAYLOAD in un file temporaneo privato e restituisce il suo percorso.
Swift compila lo script prima di leggere: spingere un documento grande nella
pipe del processo fermerebbe l'interfaccia fino a quel momento."
  (let ((file (make-temp-file "gdev-print-" nil ".json")))
    (condition-case err
        (let ((coding-system-for-write 'binary))
          (write-region (if (multibyte-string-p payload)
                            (encode-coding-string payload 'utf-8 t)
                          payload)
                        nil file nil 'silent)
          file)
      (error (ignore-errors (delete-file file))
             (signal (car err) (cdr err))))))

(defun gdev-print-macos ()
  "Apri il dialogo di stampa di macOS per il buffer corrente, con i suoi colori."
  (unless (eq 0 (call-process "/usr/bin/xcrun" nil nil nil "--find" "swift"))
    (user-error "Il dialogo di stampa richiede gli strumenti da riga di comando di Xcode"))
  (let* ((file (gdev-print--payload-file (gdev-print--payload)))
         (default-directory temporary-file-directory)
         (output (generate-new-buffer " *gdev-print*"))
         (title (if buffer-file-name
                    (file-name-nondirectory buffer-file-name)
                  (buffer-name))))
    (condition-case err
        (make-process
         :name "gdev-print" :buffer output :connection-type 'pipe
         :command (list "/usr/bin/swift" (gdev-config-file "bin/gdev-print-macos.swift")
                        title (gdev-config-file gdev-application-icon) file)
         :coding '(utf-8-unix . binary) :noquery t
         :sentinel
         (lambda (process _event)
           (when (memq (process-status process) '(exit signal))
             (ignore-errors (delete-file file))
             (when (buffer-live-p output)
               (with-current-buffer output
                 (unless (zerop (process-exit-status process))
                   (message "Stampa non riuscita: %s" (string-trim (buffer-string)))))
               (kill-buffer output)))))
      (error
       (ignore-errors (delete-file file))
       (when (buffer-live-p output) (kill-buffer output))
       (signal (car err) (cdr err))))))

(provide 'gdev-print)
;;; gdev-print.el ends here
