;;; config.el --- :tools kubernetes: risorse, eventi e log -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Giacomo Picchiarelli
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; M-x gdev-kubernetes-resources apre pod, servizi, deployment o eventi.
;; M-x gdev-kubernetes-logs mostra i log di un pod. Tutti i comandi
;; rispettano il contesto e lo spazio dei nomi di questa sessione GDev.

;;; Code:

(require 'gdev-handlers)

(defgroup gdev-kubernetes nil
  "Accesso ai cluster tramite kubectl."
  :group 'gdev)

(defcustom gdev-kubernetes-context nil
  "Nome del contesto kubectl da usare, o nil per il contesto corrente."
  :type '(choice (const :tag "Contesto corrente" nil) string))

(defcustom gdev-kubernetes-namespace nil
  "Spazio dei nomi, o nil per quello indicato dal contesto."
  :type '(choice (const :tag "Dal contesto" nil) string))

(defun gdev-kubernetes--options ()
  "Restituisci le opzioni comuni a kubectl."
  (append (when gdev-kubernetes-context (list "--context" gdev-kubernetes-context))
          (when gdev-kubernetes-namespace (list "--namespace" gdev-kubernetes-namespace))))

(defun gdev-kubernetes--show (name &rest arguments)
  "Mostra in NAME l'esito del comando kubectl ARGUMENTS."
  (unless (executable-find "kubectl") (user-error "kubectl non è disponibile"))
  (gdev-compile (gdev-command-line "kubectl" (gdev-kubernetes--options) arguments)
                (concat "Kubernetes · " name) default-directory))

(defun gdev-kubernetes-select-context (context)
  "Usa CONTEXT per le viste Kubernetes di GDev."
  (interactive
   (list (completing-read "Contesto Kubernetes: "
                          (process-lines "kubectl" "config" "get-contexts" "-o" "name") nil t)))
  (setq gdev-kubernetes-context context))

(defun gdev-kubernetes-resources (resource)
  "Mostra la risorsa Kubernetes RESOURCE."
  (interactive (list (completing-read "Risorsa Kubernetes: "
                                     '("pods" "deployments" "services" "ingresses" "events" "jobs")
                                     nil t nil nil "pods")))
  (gdev-kubernetes--show resource "get" resource "-o" "wide" "--request-timeout=15s"))

(defun gdev-kubernetes-logs (pod &optional container)
  "Mostra le ultime righe di POD, con CONTAINER opzionale."
  (interactive (list (read-string "Pod: ") (read-string "Container (vuoto = predefinito): ")))
  (unless (and (not (string-empty-p pod)) (not (string-prefix-p "-" pod)))
    (user-error "Indica il nome del pod"))
  (gdev-kubernetes--show "Registro" "logs" pod "--tail=200" "--request-timeout=20s"
                        (when (and container (not (string-empty-p container)))
                          (concat "--container=" container))))

(gdev-set-tool-actions 'kubernetes "Kubernetes" "remote"
  ["Scegli contesto…" gdev-kubernetes-select-context]
  ["Risorse del cluster…" gdev-kubernetes-resources]
  ["Registro di un pod…" gdev-kubernetes-logs])

(gdev-doctor-executable "kubectl" "Installa kubectl" 'note)

;;; config.el ends here
