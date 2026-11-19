;;; config.el --- :ui system-monitor: CPU, RAM e rete locali -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Questo file fa parte di GDev-Emacs.  I termini completi sono in LICENSE.

;;; Commentary:

;; Su macOS, CPU, RAM e traffico di rete nella barra di stato.  Le letture
;; di iostat, vm_stat e netstat partono in parallelo quando Emacs è attivo.
;; C-c o M (o un clic nella barra) mostra i valori estesi.
;; C-c t M attiva o disattiva la raccolta.

;;; Code:

(require 'gdev-lib)

(defgroup gdev-system-monitor nil
  "Statistiche della macchina locale."
  :group 'gdev)

(defcustom gdev-system-monitor-interval 10
  "Secondi fra i campioni di CPU, RAM e rete."
  :type 'integer)

(defcustom gdev-system-monitor-at-startup nil
  "Abilita le statistiche all'avvio su macOS."
  :type 'boolean)

(defvar gdev-system-monitor--timer nil)
(defvar gdev-system-monitor--jobs nil)
(defvar gdev-system-monitor--values nil)
(defvar gdev-system-monitor--network-baseline nil)
(defvar gdev-system-monitor-after-sample-hook nil
  "Hook eseguito quando il campione locale cambia o viene azzerato.")

(defun gdev-system-monitor--cpu ()
  "Leggi il carico CPU dall'ultimo intervallo nell'area di testo di iostat."
  (goto-char (point-max))
  (when (re-search-backward "^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+\\([0-9]+\\)[ \t]+" nil t)
    (max 0 (- 100 (string-to-number (match-string 1))))))

(defun gdev-system-monitor--memory-used ()
  "Stima i byte di RAM occupata dall'area di testo di vm_stat."
  (goto-char (point-min))
  (when (re-search-forward "page size of \\([0-9]+\\) bytes" nil t)
    (let ((page-size (string-to-number (match-string 1)))
          (pages 0))
      (while (re-search-forward
              "^\\(Anonymous pages\\|Pages wired down\\|Pages occupied by compressor\\|Pages purgeable\\):[ \t]+\\([0-9]+\\)[.]" nil t)
        (let ((count (string-to-number (match-string 2))))
          (cl-incf pages (if (equal (match-string 1) "Pages purgeable") (- count) count))))
      (* page-size (max 0 pages)))))

(defun gdev-system-monitor--memory-total ()
  "Leggi il totale fisico in byte dall'area di testo di sysctl."
  (let ((bytes (string-to-number (buffer-string))))
    (and (> bytes 0) bytes)))

(defun gdev-system-monitor--network-counters ()
  "Leggi i contatori in byte delle interfacce Ethernet e Wi-Fi da netstat."
  (let (interfaces)
    (dolist (line (split-string (buffer-string) "\n" t))
      (let ((fields (split-string line "[ \t]+" t)))
        (when (and (>= (length fields) 10)
                   (string-match-p "\\`en[0-9]+\\*?\\'" (car fields))
                   (string-prefix-p "<Link#" (nth 2 fields)))
          ;; Le ultime sette colonne sono i contatori, anche senza indirizzo MAC.
          (let ((counters (last fields 7)))
            (push (list (string-remove-suffix "*" (car fields))
                        (string-to-number (nth 2 counters))
                        (string-to-number (nth 5 counters)))
                  interfaces)))))
    interfaces))

(defun gdev-system-monitor--network (&optional now)
  "Calcola il traffico al secondo dal campione precedente a NOW."
  (let* ((time (or now (float-time)))
         (counters (gdev-system-monitor--network-counters))
         (baseline gdev-system-monitor--network-baseline))
    (setq gdev-system-monitor--network-baseline (cons time counters))
    (when (and baseline (< (car baseline) time)
               (<= (- time (car baseline)) (* 3 (max 2 gdev-system-monitor-interval))))
      (let ((elapsed (- time (car baseline)))
            (down 0) (up 0))
        (pcase-dolist (`(,name ,received ,sent) counters)
          (when-let* ((previous (assoc name (cdr baseline))))
            (cl-incf down (max 0 (- received (nth 1 previous))))
            (cl-incf up (max 0 (- sent (nth 2 previous))))))
        (list (/ down (* 1.0 elapsed)) (/ up (* 1.0 elapsed)))))))

(defun gdev-system-monitor--probe (metric command parser)
  "Campiona METRIC eseguendo COMMAND e leggendo il risultato con PARSER."
  (unless (alist-get metric gdev-system-monitor--jobs)
    (let ((default-directory temporary-file-directory)
          (process-environment (cons "LC_ALL=C" process-environment))
          (output (generate-new-buffer " *gdev-system-monitor*")))
      (condition-case nil
          (setf (alist-get metric gdev-system-monitor--jobs)
                (make-process
                 :name (format "gdev-system-%s" metric) :buffer output
                 :noquery t :connection-type 'pipe :command command
                 :sentinel (lambda (process _event)
                             (when (memq (process-status process) '(exit signal))
                               (unwind-protect
                                   (when (eq process (alist-get metric gdev-system-monitor--jobs))
                                     (setf (alist-get metric gdev-system-monitor--jobs nil 'remove) nil
                                           (alist-get metric gdev-system-monitor--values)
                                           (when (zerop (process-exit-status process))
                                             (with-current-buffer output (funcall parser))))
                                     (unless gdev-system-monitor--jobs
                                       (force-mode-line-update t)
                                       (run-hooks 'gdev-system-monitor-after-sample-hook)))
                                 (kill-buffer output))))))
        (error (kill-buffer output))))))

(defun gdev-system-monitor--sample-machine ()
  "Aggiorna CPU, memoria e rete in parallelo mentre Emacs è attivo."
  (when (cl-some (lambda (frame)
                   (and (eq (frame-visible-p frame) t)
                        (or (not (display-graphic-p frame)) (frame-focus-state frame))))
                 (frame-list))
    (gdev-system-monitor--probe 'cpu '("/usr/sbin/iostat" "-C" "-n" "0" "-w" "1" "-c" "2")
                                #'gdev-system-monitor--cpu)
    (gdev-system-monitor--probe 'used '("/usr/bin/vm_stat") #'gdev-system-monitor--memory-used)
    (gdev-system-monitor--probe 'network '("/usr/sbin/netstat" "-ibn") #'gdev-system-monitor--network)
    (unless (alist-get 'total gdev-system-monitor--values)
      (gdev-system-monitor--probe 'total '("/usr/sbin/sysctl" "-n" "hw.memsize")
                                  #'gdev-system-monitor--memory-total))))

(defun gdev-system-monitor--sample ()
  "Restituisce i dati raccolti dal monitor."
  (when-let* ((cpu (alist-get 'cpu gdev-system-monitor--values))
              (used (alist-get 'used gdev-system-monitor--values))
              (total (alist-get 'total gdev-system-monitor--values)))
    (list cpu (min used total) total (alist-get 'network gdev-system-monitor--values))))

(defun gdev-system-monitor--network-label (network)
  "Mostra le velocità NETWORK in byte al secondo con prefissi binari."
  (if network
      (format "↓%s/s ↑%s/s"
              (file-size-human-readable (car network) 'iec " ")
              (file-size-human-readable (cadr network) 'iec " "))
    "↓— ↑—"))

(defun gdev-system-monitor--details ()
  "Restituisce i valori estesi dell'ultimo campione locale."
  (pcase (gdev-system-monitor--sample)
    (`(,cpu ,used ,total ,network)
     (format "Mac locale · CPU %d%% · RAM %.1f / %.1f GiB · rete Ethernet/Wi-Fi %s"
             cpu (/ used 1073741824.0) (/ total 1073741824.0)
             (gdev-system-monitor--network-label network)))))

(defun gdev-system-monitor-show ()
  "Mostra l'ultimo campione di CPU, RAM e rete della macchina locale."
  (interactive)
  (unless (bound-and-true-p gdev-system-monitor-mode)
    (gdev-system-monitor-mode 1))
  (message "%s" (or (gdev-system-monitor--details) "Campionamento delle risorse del Mac…")))

(defun gdev-system-monitor-segment ()
  "Restituisce il riepilogo cliccabile, usando soltanto il campione in memoria."
  (when (>= (window-total-width) 90)
    (pcase (gdev-system-monitor--sample)
      (`(,cpu ,used ,total ,network)
       (propertize (format "CPU %d%% · RAM %.0f%% · %s"
                           cpu (/ (* 100.0 used) total)
                           (gdev-system-monitor--network-label network))
                   'face 'shadow
                   'help-echo (gdev-system-monitor--details)
                   'mouse-face 'mode-line-highlight
                   'local-map (make-mode-line-mouse-map 'mouse-1 #'gdev-system-monitor-show))))))

(define-minor-mode gdev-system-monitor-mode
  "Campiona CPU, RAM e rete della macchina locale su macOS."
  :global t
  (when gdev-system-monitor--timer
    (cancel-timer gdev-system-monitor--timer)
    (setq gdev-system-monitor--timer nil))
  (cond (gdev-system-monitor-mode
         (if gdev-macos-p
             (setq gdev-system-monitor--timer
                   (run-with-timer 0 (max 2 gdev-system-monitor-interval)
                                   #'gdev-system-monitor--sample-machine))
           (setq gdev-system-monitor-mode nil)
           (user-error "Le statistiche della macchina richiedono macOS")))
        (t
         (let ((jobs gdev-system-monitor--jobs))
           (setq gdev-system-monitor--values nil
                 gdev-system-monitor--network-baseline nil
                 gdev-system-monitor--jobs nil)
           (dolist (job jobs)
             (when (process-live-p (cdr job))
               (delete-process (cdr job)))))
         (force-mode-line-update t)
         (run-hooks 'gdev-system-monitor-after-sample-hook))))

(defun gdev-system-monitor--startup ()
  "Avvia il monitor dopo l'inizializzazione, se abilitato."
  (when (and (not noninteractive) gdev-macos-p gdev-system-monitor-at-startup)
    (gdev-system-monitor-mode 1)))

(add-hook 'emacs-startup-hook #'gdev-system-monitor--startup)

;;; config.el ends here
