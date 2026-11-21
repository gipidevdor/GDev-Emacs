"""Prove di contratto della CLI e del trasporto MCP di GDev-Emacs."""

# Copyright (C) 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: GPL-3.0-or-later

from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import shutil
import shlex
import sqlite3
import socket
import subprocess
import tempfile
import time
import unittest
import importlib.util
import hashlib


ROOT = Path(__file__).resolve().parents[1]
EMACS = os.environ.get("EMACS") or shutil.which("emacs")


class CliContracts(unittest.TestCase):
    def test_external_catalog_is_queryable_paged_and_recoverable_from_cli_and_mcp(self):
        root = self.directory / "external project è"
        authority = root / "authority"
        authority.mkdir(parents=True)
        source = authority / "gates.yaml"
        source.write_text("original authority\n")
        formal = root / ".gdev-assurance"
        formal.mkdir()
        (formal / "project.eld").write_text('''(:version 1 :id "EXTERNAL" :name "External" :profile quality :criticality normal
 :catalogs ((:id "SOURCE" :path ".gdev-assurance/catalog.json" :directories ("authority")
             :refresh ("python3" "export.py"))))''')

        def publish():
            data = {"schema_version": 1, "id": "SOURCE",
                    "inputs": [{"path": "authority/gates.yaml", "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}],
                    "records": [{"id": f"GATE-{number:03}", "kind": "gate", "state": "IMPLEMENTATA",
                                 "path": "authority/gates.yaml", "data": {"evidence": []}}
                                for number in range(105)]}
            (formal / "catalog.json").write_text(json.dumps(data))

        def read(argument):
            return json.loads(self.cli("agente", "assicurazione", str(root), "catalogo", argument).stdout)["data"]

        publish()
        page = read("GATE-")
        self.assertEqual(100, len(page["items"]))
        self.assertEqual(105, page["total"])
        last = read(page["next_argument"])
        self.assertEqual(5, len(last["items"]))
        self.assertEqual(page["catalogs"][0]["inputs_sha256"], last["catalogs"][0]["inputs_sha256"])
        with self.editor() as socket:
            (reply,) = self.mcp(socket, [self.call("gdev_assurance", command="catalog", root=str(root), argument="GATE-001")])
            live = self.payload(reply)["assurance"]
            self.assertEqual("GATE-001", live["items"][0]["id"])
            self.assertEqual("IMPLEMENTATA", live["items"][0]["state"])
            self.assertFalse(live["certification"])
        source.write_text("changed authority\n")
        stale = read("GATE-")
        self.assertEqual([], stale["items"])
        self.assertEqual("INVALID", stale["catalogs"][0]["status"])
        self.assertEqual(["python3", "export.py"], stale["catalogs"][0]["recovery"]["argv"])
        self.assertFalse(stale["catalogs"][0]["recovery"]["automatic"])
        publish()
        self.assertEqual("CURRENT", read("GATE-001")["catalogs"][0]["status"])
        self.assertFalse((root / ".gdev").exists(), "Le letture non creano un archivio")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gdev-contract-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.user = self.directory / "user"
        self.state = self.directory / "state"
        (self.user / "snippets").mkdir(parents=True)
        self.state.mkdir()
        self.env = dict(os.environ, EMACS=EMACS, GDEV_USER_DIR=str(self.user),
                        GDEV_STATE_DIR=str(self.state), GDEV_APPLICATIONS_DIR=str(self.directory / "Applications"))
        for variable in ("GDEV_PROFILE", "GDEV_DEBUG"):
            self.env.pop(variable, None)

    def cli(self, *arguments, check=True, cwd=ROOT):
        return subprocess.run(
            [str(ROOT / "bin/gdev"), *arguments], cwd=cwd, env=self.env, check=check,
            capture_output=True, encoding="utf-8", timeout=40,
        )

    def test_agent_italian_commands_preserve_discovery_contract(self):
        for italian, original in [("uso", "use"), ("sviluppo", "develop")]:
            with self.subTest(italian=italian):
                translated = json.loads(self.cli("agente", italian).stdout)
                legacy = json.loads(self.cli("agent", original).stdout)
                self.assertEqual(translated, legacy)
        workflow = json.loads(self.cli("agente", "sviluppo").stdout)["development"]
        self.assertTrue(workflow["manifest_present"])
        self.assertEqual(workflow["identity"], "agent")
        self.assertIn("gdev agente assicurazione", workflow["agent_entry"])

    def test_agent_formal_process_keeps_identity_without_an_editor(self):
        project = self.directory / "progetto formale è 日本語"
        project.mkdir()
        self.env["GDEV_ASSURANCE_ACTOR"] = "persona_delegante"

        def operation(command, *operands, check=True):
            result = self.cli("agente", "assicurazione", str(project), command, *operands, check=check)
            return result, json.loads(result.stdout)

        _, created = operation("apri", "Sviluppo controllato", "qualità")
        self.assertEqual(created["actor_kind"], "agent")
        identifier = created["data"]
        operation("avanza", identifier, "classificata")
        operation("avanza", identifier, "in-analisi")
        result, refused = operation("avanza", identifier, "autorizzata", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(refused["ok"])
        self.assertIn("Autorizzata", refused["error"])
        _, shown = operation("mostra", identifier)
        self.assertEqual(shown["data"]["transaction"]["state"], "ANALYZED")
        self.assertTrue(all(row["actor_kind"] == "agent" for row in shown["data"]["events"]))
        with closing(sqlite3.connect(project / ".gdev/assurance/assurance.sqlite")) as db:
            self.assertEqual(db.execute("SELECT DISTINCT actor, actor_kind FROM tx_event").fetchall(),
                             [("persona_delegante", "agent")])
        self.assertFalse(list(self.state.iterdir()), "La richiesta non deve inizializzare il profilo")

    def test_agent_cache_is_isolated_before_libraries_and_removed_on_exit(self):
        standard = self.directory / "emacs-standard"
        record = self.directory / "avvio.json"
        bootstrap = f"""(progn
          (setq user-emacs-directory {json.dumps(str(standard) + '/')}
                native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
          (advice-add 'require :before
            (lambda (feature &rest _)
              (when (and (eq feature 'cl-lib) (not (file-exists-p {json.dumps(str(record))})))
                (make-directory (expand-file-name "eln-cache" user-emacs-directory) t)
                (with-temp-file {json.dumps(str(record))}
                  (insert (json-serialize
                    (list :directory user-emacs-directory :cache (car native-comp-eln-load-path)))))))))"""
        wrapper = self.directory / "emacs-prova.sh"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(EMACS) + " --eval " + shlex.quote(bootstrap) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.env["EMACS"] = str(wrapper)
        for mode, expected in [("use", 0), ("inesistente", 1)]:
            with self.subTest(mode=mode):
                record.unlink(missing_ok=True)
                result = self.cli("agent", mode, check=False)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                observed = json.loads(record.read_text())
                temporary = Path(observed["directory"])
                self.assertNotEqual(temporary, standard)
                self.assertFalse(temporary.exists(), "La cache temporanea deve essere rimossa anche dopo un errore")
                self.assertFalse(standard.exists(), "Il percorso standard non deve essere creato")
                if observed["cache"]:
                    self.assertEqual(Path(observed["cache"]).parent, temporary)

    def test_project_test_command_isolates_state_and_finishes_hooks_before_cleanup(self):
        record = self.directory / "test-command.json"
        bootstrap = f"""(progn
          (setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
          (advice-add 'load :around
            (lambda (original file &rest arguments)
              (if (string-suffix-p \"test/gdev-test.el\" file)
                  (progn
                    (fset 'ert-run-tests-batch (lambda (&rest _) (string-to-number (getenv \"GDEV_TEST_FAKE_FAILURES\"))))
                    (fset 'ert-stats-completed-unexpected #'identity)
                    (add-hook 'kill-emacs-hook
                      (lambda ()
                        (with-temp-file {json.dumps(str(record))}
                          (insert (json-serialize
                            (list :state user-emacs-directory :exists (if (file-directory-p user-emacs-directory) t :false)))))))
                    t)
                (apply original file arguments)))))"""
        wrapper = self.directory / "emacs-test-command.sh"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(EMACS) + " --eval " + shlex.quote(bootstrap) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.env["EMACS"] = str(wrapper)
        for failures in (0, 1):
            with self.subTest(failures=failures):
                self.env["GDEV_TEST_FAKE_FAILURES"] = str(failures)
                result = self.cli("test", check=False)
                self.assertEqual(result.returncode, failures, result.stdout + result.stderr)
                observed = json.loads(record.read_text())
                self.assertTrue(observed["exists"], "Gli hook terminano prima della pulizia")
                self.assertNotEqual(Path(observed["state"]), self.state)
                self.assertFalse(Path(observed["state"]).exists())

    def test_agent_formal_plan_does_not_load_editor_views(self):
        guard = """(progn
          (setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
          (advice-add 'require :before
          (lambda (feature &rest _)
            (when (memq feature '(gdev-ui gdev-layout gdev-context gdev-workspace-roots gdev-workspace-state))
              (error "La pianificazione ha caricato una vista: %s" feature)))))"""
        wrapper = self.directory / "emacs-senza-viste.sh"
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(EMACS) + " --eval " + shlex.quote(guard) + ' "$@"\n')
        wrapper.chmod(0o700)
        self.env["EMACS"] = str(wrapper)
        result = self.cli("agente", "assicurazione", str(ROOT), "piano-procedura", "GDEV-VERIFY", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["ok"])
        self.assertEqual(data["data"]["status"], "PLANNED")
        self.assertFalse(data["data"]["effects_applied"])
        self.assertFalse(list(self.state.iterdir()))

    def test_cli_rejects_unknown_arguments(self):
        commands = json.loads(self.cli("agent", "use").stdout)["cli_commands"]
        for command in (name for name in commands if name not in {"agent", "emacs"}):
            with self.subTest(command=command):
                arguments = ("--native", "--sconosciuto") if command == "compile" else ("--sconosciuto",)
                result = self.cli(command, *arguments, check=False)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(f"Uso: gdev {command}", result.stdout)
        for arguments in [("bench", "0"), ("bench", "2", "3"),
                          ("rollback", "HEAD", "HEAD~1"), ("fork-merge", "sly", "base")]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.cli(*arguments, check=False).returncode, 2)
        self.assertEqual(self.cli("info").returncode, 0)
        self.assertEqual(self.cli("--profile", "prova", "info").returncode, 0)
        for mode in ("use", "develop"):
            result = self.cli("agent", mode, "--sconosciuto", check=False)
            self.assertNotEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])
            self.assertEqual(payload["schema_version"], 1)

    def test_empty_profile_boots_and_preserves_values_on_the_second_start(self):
        fresh = self.directory / "installazione nuova è 日本語"
        env = dict(self.env, GDEV_STATE_DIR=str(fresh / "dati"),
                   GDEV_USER_DIR=str(fresh / "configurazione"))
        boot = """(progn
          (setq native-comp-jit-compilation nil)
          (require 'package)
          (package-activate-all)
          (load (expand-file-name "init.el" gdev-config-directory) nil t)
          (run-hooks 'emacs-startup-hook)
          (when (or gdev-state-startup-issue gdev-failed-modules gdev-modules-private-errors)
            (error "Primo avvio incompleto"))
          (unless (> (length gdev-module-load-times) 40) (error "Moduli non caricati"))
          (gdev-scoped-options-catalog-sync))"""
        write = """(progn
          (gdev-state-db-set "prova_installazione" "" "valore" '("città" 42 [1 2]))
          (gdev-state-db-backup))"""
        read = """(unless (equal '("città" 42 [1 2])
                          (cdar (gdev-state-db-entries "prova_installazione" "" "valore")))
                    (error "Valore non conservato dopo il riavvio"))"""
        self.assertFalse(fresh.exists())
        for phase in (write, read):
            result = subprocess.run(
                [EMACS, "--batch", "-Q", "-l", "early-init.el", "--eval", boot,
                 "--eval", phase], cwd=ROOT, env=env, capture_output=True,
                encoding="utf-8", timeout=40,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        database = fresh / "dati/stato.sqlite"
        with closing(sqlite3.connect(database)) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (2,))
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
            self.assertGreater(db.execute("SELECT count(*) FROM catalogo_opzione").fetchone()[0], 1000)
        if os.name != "nt":
            self.assertEqual(database.stat().st_mode & 0o777, 0o600)
            self.assertEqual(database.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(list((database.parent / "copie-stato").glob("*.sqlite")))

    def test_simultaneous_first_writers_keep_every_committed_value(self):
        fresh = self.directory / "primo avvio simultaneo"
        env = dict(self.env, GDEV_STATE_DIR=str(fresh))
        processes = []
        try:
            for writer in range(4):
                processes.append(subprocess.Popen(
                    [EMACS, "--batch", "-Q", "-l", "early-init.el", "--eval",
                     f'(gdev-state-db-set "prima_scrittura" "" "processo-{writer}" {writer})'],
                    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    encoding="utf-8",
                ))
            for process in processes:
                out, err = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, out + err)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)
        with closing(sqlite3.connect(fresh / "stato.sqlite")) as db:
            self.assertEqual(db.execute("SELECT nome FROM impostazione ORDER BY nome").fetchall(),
                             [(f"processo-{writer}",) for writer in range(4)])
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
            self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_missing_sqlite_reports_the_requirement_and_preserves_basic_editing(self):
        fresh = self.directory / "senza SQLite"
        form = """(progn
          (setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
          (require 'cl-lib)
          (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
            (load (expand-file-name "early-init.el") nil t)
            (load (expand-file-name "init.el") nil t)
            (unless (and gdev-state-startup-issue
                         (string-match-p "SQLite integrato" gdev-state-startup-issue))
              (error "Requisito SQLite non segnalato"))
            (with-temp-buffer
              (insert "Editor disponibile")
              (write-region (point-min) (point-max)
                            (expand-file-name "documento.txt" gdev-state-directory) nil 'silent))))"""
        result = subprocess.run(
            [EMACS, "--batch", "-Q", "--eval", form], cwd=ROOT,
            env=dict(self.env, GDEV_STATE_DIR=str(fresh)), capture_output=True,
            encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Profilo sospeso", result.stderr)
        self.assertEqual((fresh / "documento.txt").read_text(), "Editor disponibile")
        self.assertFalse((fresh / "stato.sqlite").exists())

    def test_state_recovers_with_a_damaged_primary(self):
        subprocess.run(
            [EMACS, "--batch", "-Q", "-l", "early-init.el", "--eval",
             "(gdev-state-db-set \"prova\" \"\" \"risposta\" 42)"],
            cwd=ROOT, env=self.env, check=True, capture_output=True, timeout=20,
        )
        self.assertIn("versione 2", self.cli("stato", "verifica").stdout)
        self.cli("stato", "copia")
        self.assertIn(".sqlite", self.cli("stato", "copie").stdout)
        primary = self.state / "stato.sqlite"
        primary.write_bytes(b"Archivio illeggibile")
        self.assertNotEqual(self.cli("stato", "verifica", check=False).returncode, 0)
        self.assertEqual(self.cli("stato", "sconosciuto", check=False).returncode, 2)
        recovered = self.directory / "recuperato"
        self.cli("stato", "recupera", "ultima", str(recovered))
        self.assertIn("versione 2", self.cli("stato", "verifica", str(recovered / "stato.sqlite")).stdout)
        self.assertEqual(primary.read_bytes(), b"Archivio illeggibile")

    def test_interrupted_state_recovery_can_retry_the_same_destination(self):
        destination = self.directory / "profilo recuperato"
        marker = self.directory / "prima-della-copia"
        form = """(progn
          (require 'gdev-state-db-maintenance)
          (gdev-state-db-set "prova" "" "risposta" 42)
          (gdev-state-db-backup)
          (advice-add 'gdev-state-db-backup :before
                      (lambda (&rest _)
                        (write-region "pronto" nil (getenv "GDEV_TEST_MARKER") nil 'silent)
                        (sleep-for 60)))
          (gdev-state-db-recover "ultima" (getenv "GDEV_TEST_DEST")))"""
        with subprocess.Popen(
            [EMACS, "--batch", "-Q", "-l", "early-init.el", "--eval", form],
            cwd=ROOT, env=dict(self.env, GDEV_TEST_DEST=str(destination), GDEV_TEST_MARKER=str(marker)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) as process:
            try:
                deadline = time.monotonic() + 20
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
            finally:
                process.kill()
                _, errors = process.communicate(timeout=10)
            self.assertTrue(marker.exists(), errors)
        self.assertFalse(destination.exists())
        self.cli("stato", "recupera", "ultima", str(destination) + os.sep)
        copies = list((destination / "copie-stato").glob("*.sqlite"))
        self.assertEqual(len(copies), 1)
        self.cli("stato", "verifica", str(copies[0]))
        result = subprocess.run(
            [EMACS, "--batch", "-Q", "-l", "early-init.el", "--eval",
             '(princ (cdar (gdev-state-db-entries "prova" "" "risposta")))'],
            cwd=ROOT, env=dict(self.env, GDEV_STATE_DIR=str(destination)),
            capture_output=True, text=True, check=True, timeout=20,
        )
        self.assertEqual(result.stdout, "42")

    def test_cli_distinguishes_usage_errors_from_operation_errors(self):
        for command in [
            ("--profile", "../profilo", "info"),
            ("--profile",),
            ("comando-sconosciuto",),
            ("compile", "-w", "--sconosciuto"),
            ("sync", "-u", "--no-docs", "--sconosciuto"),
        ]:
            with self.subTest(command=command):
                result = self.cli(*command, check=False)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

        for command, message in [
            (("fork-merge", "pacchetto-inesistente", ".", "."), "Pacchetto fuori registro"),
            (("rollback", "refs/gdev-prova/revisione-inesistente"), "gdev rollback non riuscito"),
        ]:
            with self.subTest(command=command):
                result = self.cli(*command, check=False)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)

        self.env.pop("EMACS")
        self.assertIn("gdev sync", self.cli().stdout)

    def test_cli_dispatches_the_documented_maintenance_signatures(self):
        form = """(dolist (arguments '(
                             ("sync") ("sync" "--native" "-u" "--no-docs")
                             ("compile") ("compile" "-w" "--native")
                             ("fork-merge" "sly" "./base originale" "./nuova versione")
                             ("rollback") ("rollback" "HEAD~1")
                             ("bench") ("bench" "3")))
                   (let* ((command-line-args-left arguments)
                          (function (cadr (assoc (car arguments) gdev-cli-commands)))
                          received)
                     (cl-letf (((symbol-function function)
                                (lambda (&rest forwarded)
                                  (setq received (cons function forwarded))
                                  0)))
                       (unless (and (zerop (gdev-cli-main))
                                    (equal received (cons function (cdr arguments))))
                         (error "Firma non riconosciuta: %S" arguments)))))"""
        result = subprocess.run(
            [EMACS, "--batch", "-Q", "-l", "early-init.el", "-l", "lisp/gdev-cli.el",
             "--eval", form],
            cwd=ROOT, env=self.env, capture_output=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_rejects_a_regular_file_as_editor_socket(self):
        socket_file = self.directory / "non-socket"
        socket_file.touch()
        result = self.cli("agent", "live", str(socket_file), "status", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("socket Unix", json.loads(result.stdout)["error"])

    def test_cli_validates_the_live_action_and_checkout(self):
        with self.editor(configured=False) as socket:
            for action in [("status", "argomento-in-più"), ("open-file",), ("sconosciuta",)]:
                with self.subTest(action=action):
                    result = self.cli("agent", "live", str(socket), *action, check=False)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("numero di argomenti", json.loads(result.stdout)["error"])
            result = self.cli("agent", "live", str(socket), "status", check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("checkout", json.loads(result.stdout)["error"])

    def test_audit_reads_only_the_distributed_configuration(self):
        original = json.loads(self.cli("audit").stdout)
        (self.state / "custom.el").write_text(
            ';; -*- lexical-binding: t -*-\n'
            "(custom-set-variables '(gdev-menu-personal-items "
            "'([\"Etichetta privata di prova\" gdev-open-file t])))\n",
            encoding="utf-8",
        )
        (self.user / "init.el").write_text('(error "Caricata configurazione privata")\n',
                                          encoding="utf-8")
        configured = json.loads(self.cli("audit").stdout)
        self.assertEqual(original, configured)
        self.assertNotIn("Etichetta privata di prova", json.dumps(configured, ensure_ascii=False))
        self.assertEqual(original, json.loads(self.cli("--profile", "prova", "audit").stdout))
        self.assertFalse((self.state / "profiles").exists())

    def test_audit_and_discovery_agree_on_derived_modes(self):
        name = "gdev-search-mode"
        audit = json.loads(self.cli("audit").stdout)
        discover = json.loads(self.cli("agent", "develop", name).stdout)
        declaration = next(symbol for symbol in discover["symbols"] if symbol["name"] == name)
        self.assertEqual(declaration["kind"], "define-derived-mode")
        self.assertIs(declaration["interactive"], True)
        self.assertIn(declaration, audit["definitions"])

    def test_fork_precedes_an_installed_copy_with_the_same_version(self):
        fork = ROOT / "vendor" / "elpa" / "gdev-sposta-testo-2.0.10"
        installed = self.state / "elpa" / fork.name
        installed.mkdir(parents=True)
        shutil.copyfile(fork / "gdev-sposta-testo-pkg.el", installed / "gdev-sposta-testo-pkg.el")
        (installed / "gdev-sposta-testo.el").write_text('(error "Copia ELPA caricata")\n',
                                                       encoding="utf-8")
        form = """(progn
          (unless (eq (key-binding (kbd "M-<down>")) 'gdev-sposta-testo-giu)
            (error "Scorciatoia di Sposta testo non associata"))
          (with-temp-buffer
            (insert "prima\nseconda")
            (goto-char (point-min))
            (call-interactively (key-binding (kbd "M-<down>")))
            (unless (equal (buffer-string) "seconda\nprima")
              (error "Sposta testo non ha invertito le righe")))
          (princ (file-truename (symbol-file 'gdev-sposta-testo-giu 'defun))))"""
        bootstrap = [EMACS, "--batch", "-Q", "-l", "early-init.el"]
        startup = ["--eval", "(progn (require 'package) (package-activate-all))", "-l", "init.el"]
        for entry in ("scorciatoia", "percorso precedente"):
            with self.subTest(entry=entry):
                legacy = ["-l", "lisp/gdev-sposta-testo.el"] if entry == "percorso precedente" else []
                result = subprocess.run(
                    [*bootstrap, *startup, *legacy, "--eval", form],
                    cwd=ROOT, env=self.env, capture_output=True, encoding="utf-8", timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(Path(result.stdout.strip()).parent, fork)

        refresh = subprocess.run(
            [*bootstrap, "--eval", "(progn (require 'package) (package-quickstart-refresh))"],
            cwd=ROOT, env=self.env, capture_output=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(refresh.returncode, 0, refresh.stdout + refresh.stderr)
        self.assertTrue(list(self.state.glob("package-quickstart-*.el")))
        quickstart = subprocess.run(
            [*bootstrap, *startup, "--eval", form],
            cwd=ROOT, env=self.env, capture_output=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(quickstart.returncode, 0, quickstart.stdout + quickstart.stderr)
        self.assertEqual(Path(quickstart.stdout.strip()).parent, fork)

    def unicode_project(self):
        root = self.directory / "progetto"
        root.mkdir()
        created = json.loads(self.cli("assurance", "project-init", "DEMO", "Progetto è 日本語", cwd=root).stdout)
        self.assertEqual("Progetto è 日本語", created["project"]["name"])
        return root

    def test_formal_project_cli_unicode_and_preview(self):
        root = self.unicode_project()

        def assurance(*arguments, expected=0):
            result = self.cli("assurance", *arguments, cwd=root, check=False)
            self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
            return result

        self.assertEqual("INCOMPLETE", json.loads(assurance("project", expected=1).stdout)["status"])
        parameters = json.dumps({"title": "È una prova", "content": "日本語 $(touch nope)"}, ensure_ascii=False)
        preview = json.loads(assurance("snippet-preview", "SNIP-DOCUMENTATION", parameters).stdout)
        self.assertIn("日本語 $(touch nope)", preview["content"])
        self.assertEqual("PLANNED", json.loads(assurance("procedure-plan", "PROC-FEATURE").stdout)["status"])
        self.assertFalse((root / ".gdev").exists())
        missing = assurance("snippet-preview", "SNIP-DOCUMENTATION", "{}", expected=1)
        self.assertIn("Compila il parametro", missing.stdout)
        self.assertFalse((root / "nope").exists())

    def test_formal_project_live_mcp_unicode_and_taxonomy_pagination(self):
        with self.editor() as socket:
            root = self.unicode_project()
            project, first = self.mcp(socket, [
                self.call("gdev_assurance", command="project", root=str(root)),
                self.call("gdev_assurance", command="taxonomy", argument="owasp-asvs", root=str(root)),
            ])
            self.assertEqual("Progetto è 日本語", self.payload(project)["assurance"]["project"]["name"])
            first = self.payload(first)["assurance"]["taxonomies"][0]
            self.assertEqual(200, len(first["nodes"]))
            cursor = first["next_argument"]
            seen = {row["id"] for row in first["nodes"]}
            while cursor:
                (reply,) = self.mcp(socket, [self.call("gdev_assurance", command="taxonomy", argument=cursor, root=str(root))])
                page = self.payload(reply)["assurance"]["taxonomies"][0]
                self.assertTrue(0 < len(page["nodes"]) <= 200)
                identifiers = {row["id"] for row in page["nodes"]}
                self.assertFalse(seen & identifiers)
                seen.update(identifiers)
                self.assertNotEqual(cursor, page["next_argument"])
                cursor = page["next_argument"]
            self.assertEqual(first["node_count"], len(seen))
        self.assertFalse((root / ".gdev").exists())

    @contextmanager
    def editor(self, configured=True):
        probe_path = self.directory / "probe.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.bind(str(probe_path))
            except PermissionError as error:
                if self.env.get("GDEV_TEST_REQUIRE_IPC") == "1":
                    raise
                self.skipTest(f"Il sistema nega l'apertura di un socket Unix: {error.strerror}")
        probe_path.unlink()
        socket_file = self.directory / "s" / "test"
        log = self.directory / "emacs.log"
        form = (
            "(progn (require 'server) "
            '(when (bound-and-true-p gdev-failed-modules) '
            '(error "Moduli non caricati: %S" gdev-failed-modules)) '
            f"(setq server-socket-dir {json.dumps(str(socket_file.parent))} "
            'server-name "test" server-use-tcp nil) '
            "(server-start) (while t (accept-process-output nil 0.1)))"
        )
        startup = [
            "-l", "early-init.el", "--eval", "(progn (require 'package) (package-activate-all))",
            "-l", "init.el",
        ] if configured else []
        with log.open("w", encoding="utf-8") as output:
            process = subprocess.Popen(
                [EMACS, "--batch", "-Q", *startup, "--eval", form],
                cwd=ROOT, env=self.env, stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 15
                while not socket_file.is_socket() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(socket_file.is_socket(), log.read_text(encoding="utf-8"))
                yield socket_file
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)

    @staticmethod
    def initialize(protocol):
        return {"jsonrpc": "2.0", "id": 0, "method": "initialize",
                "params": {"protocolVersion": protocol, "capabilities": {},
                           "clientInfo": {"name": "prove-gdev", "version": "1"}}}

    def mcp_exchange(self, socket, messages):
        arguments = ["./bin/gdev-mcp"]
        if socket is not None:
            arguments.extend(["--socket", str(socket)])
        lines = [message if isinstance(message, str) else json.dumps(message) for message in messages]
        result = subprocess.run(
            arguments, cwd=ROOT, env=self.env, input="\n".join(lines) + "\n",
            capture_output=True, check=True, encoding="utf-8", timeout=45,
        )
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertTrue(all(response["jsonrpc"] == "2.0" for response in responses))
        return responses

    def mcp(self, socket, requests, protocol="2025-11-25", negotiated=None):
        messages = [
            self.initialize(protocol),
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
        messages.extend(
            {"jsonrpc": "2.0", "id": index, "method": method, "params": params}
            for index, (method, params) in enumerate(requests, 1)
        )
        replies = self.mcp_exchange(socket, messages)
        self.assertEqual(len(replies), len(requests) + 1)
        responses = {reply["id"]: reply["result"] for reply in replies}
        self.assertEqual(responses.pop(0)["protocolVersion"], negotiated or protocol)
        return [responses[index] for index in range(1, len(requests) + 1)]

    @staticmethod
    def call(name, **arguments):
        return "tools/call", {"name": name, "arguments": arguments}

    def payload(self, result, error=False):
        self.assertEqual(result["isError"], error, result)
        payload = result["structuredContent"]
        self.assertEqual(payload, json.loads(result["content"][0]["text"]))
        self.assertEqual(payload["schema_version"], 1)
        return payload

    def test_mcp_discovery_without_socket_supports_previous_protocols(self):
        for protocol, negotiated in [
            ("2024-11-05", "2024-11-05"),
            ("2025-03-26", "2025-03-26"),
            ("2025-06-18", "2025-06-18"),
            ("2030-01-01", "2025-11-25"),
        ]:
            with self.subTest(protocol=protocol):
                listed, discovered = self.mcp(None, [
                    ("tools/list", {}),
                    self.call("gdev_discover", mode="develop", prefix="gdev-layout-editor"),
                ], protocol=protocol, negotiated=negotiated)
                self.assertEqual([tool["name"] for tool in listed["tools"]], ["gdev_discover"])
                self.assertEqual("annotations" in listed["tools"][0], negotiated != "2024-11-05")
                legacy = negotiated < "2025-06-18"
                self.assertEqual("structuredContent" in discovered, not legacy)
                self.assertFalse(discovered["isError"])
                payload = json.loads(discovered["content"][0]["text"])
                self.assertEqual(Path(payload["root"]), ROOT)
                self.assertEqual(payload["schema_version"], 1)
                self.assertIn("gdev-layout-editor", [entry["name"] for entry in payload["symbols"]])
                if not legacy:
                    self.assertEqual(discovered["structuredContent"], payload)

    def test_mcp_rpc_errors_leave_the_transport_usable(self):
        responses = self.mcp_exchange(None, [
            "{",
            {"jsonrpc": "1.0", "id": 1, "method": "ping"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "ping"},
            self.initialize("2025-11-25"),
            {"jsonrpc": "2.0", "id": 4, "method": "tools/list"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": {"cursor": "sconosciuto"}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "gdev_status"}},
            {"jsonrpc": "2.0", "id": 7, "method": "ping", "params": []},
            {"jsonrpc": "2.0", "id": 8, "method": "metodo-sconosciuto"},
            dict(self.initialize("2025-11-25"), id=10),
            {"jsonrpc": "2.0", "id": True, "method": "ping"},
            {"jsonrpc": "2.0", "id": 9, "method": "tools/list"},
        ])
        self.assertEqual([(reply["id"], reply.get("error", {}).get("code")) for reply in responses],
                         [(None, -32700), (None, -32600), (2, -32002), (3, None), (0, None),
                          (4, -32002), (5, -32602), (6, -32602), (7, -32602), (8, -32601),
                          (10, -32602), (None, -32600), (9, None)])
        self.assertEqual(responses[3]["result"], {})
        self.assertEqual(responses[-1]["result"]["tools"][0]["name"], "gdev_discover")

    def test_mcp_reports_the_missing_socket_over_stdio(self):
        (unavailable,) = self.mcp(self.directory / "socket-assente", [self.call("gdev_status")])
        self.assertIn("socket Unix", self.payload(unavailable, error=True)["error"])

    def test_mcp_reports_the_correct_error_at_each_live_tool_boundary(self):
        with self.editor() as socket:
            document = self.directory / "documento-assente"
            missing, wrong_type, wrong_field, too_large, outside = self.mcp(socket, [
                self.call("gdev_open_file", path=str(document)),
                self.call("gdev_shortcuts", query=False),
                self.call("gdev_status", campo_sconosciuto=True),
                self.call("gdev_cursor_write", path=str(document), agent="prova",
                          revision="1-1-1:1", text="x" * (1024 * 1024)),
                self.call("gdev_lavorazione_leggi", path=str(self.directory / "Bozza.lavorazione")),
            ])
            for result in (missing, wrong_type, wrong_field):
                self.assertTrue(result["isError"])
                self.assertEqual(set(result["structuredContent"]), {"error"})
            self.assertTrue(too_large["isError"])
            self.assertIn("1 MiB", too_large["structuredContent"]["error"])
            self.assertIn("Apri prima la lavorazione", self.payload(outside, error=True)["error"])

    def test_mcp_navigation_and_context_follow_the_editor(self):
        document = self.directory / "Documento.txt"
        document.write_text("Contenuto\n", encoding="utf-8")
        folder = self.directory / "cartella"
        folder.mkdir()
        with self.editor() as socket:
            opened, project, status, commands, by_key, by_command = self.mcp(socket, [
                self.call("gdev_open_file", path=str(document)),
                self.call("gdev_open_folder", path=str(folder)),
                self.call("gdev_status"),
                self.call("gdev_commands"),
                self.call("gdev_shortcuts", query="C-c w z"),
                self.call("gdev_shortcuts", query="gdev-operation-undo"),
            ])
            self.assertEqual(self.payload(opened)["state"]["editor"]["file"], str(document))
            project_state = self.payload(project)["state"]
            self.assertEqual(project_state["workspace_roots"], [str(folder) + "/"])
            self.assertEqual(self.payload(status)["state"], project_state)
            self.assertIn("gdev-open-file", [entry["command"] for entry in self.payload(commands)["commands"]])
            self.assertEqual(self.payload(by_key)["shortcut"]["command"], "gdev-operation-undo")
            self.assertIn("C-c w z", [entry["key"] for entry in self.payload(by_command)["shortcut"]["keys"]])

    def test_mcp_falls_back_to_dired_without_workbench(self):
        (self.user / "init.el").write_text(";;; -*- lexical-binding: t; -*-\n(gdev!)\n",
                                          encoding="utf-8")
        with self.editor() as socket:
            opened, unavailable = self.mcp(socket, [
                self.call("gdev_open_folder", path=str(self.directory)),
                self.call("gdev_lavorazione_catalogo"),
            ])
            state = self.payload(opened)["state"]
            self.assertEqual(state["configured_modules"], [])
            self.assertEqual(state["editor"]["mode"], "dired-mode")
            self.assertIn("Workbench", self.payload(unavailable, error=True)["error"])

    def test_mcp_discovers_the_contract_and_edits_the_live_document(self):
        document = self.directory / "Prova è Ω.txt"
        document.write_text("αβ caffè\n", encoding="utf-8")
        path = str(document)
        plan_file = self.directory / "Bozza.lavorazione"
        with self.editor() as socket:
            listed, discovered, opened, state, actions, draft = self.mcp(socket, [
                ("tools/list", {}),
                self.call("gdev_discover", mode="use"),
                self.call("gdev_open_file", path=path),
                self.call("gdev_cursor_state", path=path),
                self.call("gdev_lavorazione_catalogo"),
                self.call("gdev_lavorazione_apri", path=str(plan_file)),
            ])
            catalog = self.payload(discovered)
            signatures = {row["action"]: row["arity"] for row in catalog["live_signatures"]}
            tools = {
                tool["name"].removeprefix("gdev_").replace("_", "-"): len(tool["inputSchema"]["properties"])
                for tool in listed["tools"] if tool["name"] != "gdev_discover"
            }
            self.assertEqual(tools, signatures)
            self.assertEqual(set(signatures), set(catalog["live_actions"]))
            open_action = next(row for row in self.payload(actions)["actions"] if row["name"] == "apri-file")
            self.assertTrue(open_action["opens_document"])
            self.assertIn("file", [field["name"] for field in open_action["arguments"]])
            self.assertEqual(self.payload(opened)["state"]["editor"]["file"], path)
            original = self.payload(state)["document"]
            self.assertEqual(original["text"], "αβ caffè\n")
            cursor = {"path": path, "agent": "revisore", "revision": original["revision"]}
            revision = self.payload(draft)["composition"]["revision"]
            plan = {"versione": 1, "passi": [{"azione": "apri-file", "argomenti": {"file": document.name}}]}
            placed, written, rejected, read_back, composed = self.mcp(socket, [
                self.call("gdev_cursor_place", **cursor, offsets=[0, 3]),
                self.call("gdev_cursor_write", **cursor, text="Ω🖊️"),
                self.call("gdev_cursor_write", **cursor, text="SCRITTURA SUPERATA"),
                self.call("gdev_cursor_state", path=path, offset=1),
                self.call("gdev_lavorazione_componi", path=str(plan_file), plan=plan, revision=revision),
            ])
            groups = self.payload(placed)["document"]["cursors"]
            self.assertEqual(groups, [{"agent": "revisore", "offsets": [0, 3]}])
            changed = self.payload(written)["document"]
            self.assertNotEqual(changed["revision"], original["revision"])
            self.assertFalse(self.payload(rejected, error=True)["ok"])
            self.assertEqual(self.payload(read_back)["document"]["text"], "🖊️αβ Ω🖊️caffè\n")
            self.assertEqual(document.read_text(encoding="utf-8"), "αβ caffè\n")
            composition = self.payload(composed)["composition"]
            self.assertEqual(composition["plan"], plan)
            self.assertFalse(plan_file.exists())
            invalid_plan = {"versione": 1, "passi": [{"azione": "sconosciuta", "argomenti": {}}]}
            invalid, read_plan, cleared, saved = self.mcp(socket, [
                self.call("gdev_lavorazione_componi", path=str(plan_file), plan=invalid_plan,
                          revision=composition["revision"]),
                self.call("gdev_lavorazione_leggi", path=str(plan_file)),
                self.call("gdev_cursor_clear", path=path, agent=cursor["agent"]),
                self.call("gdev_lavorazione_salva", path=str(plan_file), revision=composition["revision"]),
            ])
            self.assertFalse(self.payload(invalid, error=True)["ok"])
            self.assertEqual(self.payload(read_plan)["composition"], composition)
            self.assertEqual(self.payload(cleared)["document"]["cursors"], [])
            self.assertTrue(self.payload(saved)["ok"])
            self.assertEqual(json.loads(plan_file.read_text(encoding="utf-8")), plan)


class MacosBootstrapContracts(unittest.TestCase):
    """Primo ingresso: dipendenze simulate, argomenti e profili reali su disco."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gdev-bootstrap-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.home = self.directory / "utente"
        self.home.mkdir()
        self.repository = self.directory / "checkout con spazi è"
        (self.repository / "bin").mkdir(parents=True)
        self.commands = self.directory / "comandi"
        self.commands.mkdir()
        self.log = self.directory / "argomenti"
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.directory),
                        PATH=str(self.commands) + os.pathsep + os.environ["PATH"],
                        GDEV_BOOTSTRAP_TEST_LOG=str(self.log))
        for name in ("XDG_CONFIG_HOME", "GDEV_USER_DIR", "GDEV_STATE_DIR", "GDEV_PROFILE"):
            self.env.pop(name, None)
        shutil.copy2(ROOT / "bin/gdev-bootstrap-macos", self.repository / "bin/gdev-bootstrap-macos")
        self.script("uname", "echo Darwin\n")
        self.script("xcode-select", "echo /strumenti-di-prova\n")
        self.script("brew", "echo /homebrew-di-prova\n")
        self.script("sleep", "/bin/sleep 0.01\n")
        self.script("gdev", """printf '%s\\n' "$@" >> "$GDEV_BOOTSTRAP_TEST_LOG"
if [ "$1" = install ]; then exit "${GDEV_BOOTSTRAP_TEST_INSTALL_STATUS:-0}"; fi
if [ -n "${GDEV_STARTUP_CHECK_DIR:-}" ] && [ "${GDEV_BOOTSTRAP_TEST_SILENT:-0}" != 1 ]; then
  printf '{"ok":true}\\n' > "$GDEV_STARTUP_CHECK_DIR/result.json"
  printf '%s\\n' "${GDEV_BOOTSTRAP_TEST_STARTUP:-ready}" > "$GDEV_STARTUP_CHECK_DIR/status"
fi
""", self.repository / "bin/gdev")

    def script(self, name, content, destination=None):
        destination = destination or self.commands / name
        destination.write_text("#!/bin/sh\nset -eu\n" + content)
        destination.chmod(0o700)

    def bootstrap(self, *options):
        return subprocess.run([str(self.repository / "bin/gdev-bootstrap-macos"),
                               "--skip-brew", "--skip-perl", "--skip-lisp", *options],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def test_first_launch_waits_for_the_running_interface(self):
        result = self.bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("interfaccia verificata", result.stdout)
        self.assertEqual(self.log.read_text().splitlines(), ["install", "emacs"])
        self.assertEqual((self.home / ".config/emacs").resolve(), self.repository.resolve())

    def test_existing_and_broken_configurations_are_preserved(self):
        for broken in (False, True):
            with self.subTest(broken=broken):
                config = self.home / ".config/emacs"
                config.parent.mkdir(exist_ok=True)
                if broken:
                    config.symlink_to(self.directory / "cartella-assente")
                else:
                    config.mkdir()
                    (config / "init.el").write_text(";; personale\n")
                (self.home / ".emacs.el").write_text(";; da conservare\n")
                result = self.bootstrap()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.home / ".emacs.el").read_text(), ";; da conservare\n")
                if broken:
                    self.assertTrue(config.is_symlink())
                    config.unlink()
                else:
                    self.assertEqual((config / "init.el").read_text(), ";; personale\n")
                    shutil.rmtree(config)

    def test_existing_cli_files_directories_and_foreign_links_are_preserved(self):
        command = self.home / ".local/bin/gdev"
        command.parent.mkdir(parents=True)
        personal = self.directory / "comando personale"
        personal.write_text("#!/bin/sh\necho personale\n")
        for kind in ("file", "directory", "link", "broken-link"):
            with self.subTest(kind=kind):
                if kind == "file":
                    command.write_text("comando da conservare\n")
                elif kind == "directory":
                    command.mkdir()
                    (command / "personale").write_text("da conservare\n")
                else:
                    command.symlink_to(personal if kind == "link" else self.directory / "assente")
                before = command.lstat()
                result = self.bootstrap("--no-launch")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("esistente conservato; da terminale usa", result.stdout)
                self.assertIn(str(self.repository / "bin/gdev"), result.stdout)
                self.assertEqual(command.lstat().st_ino, before.st_ino)
                if kind == "file":
                    self.assertEqual(command.read_text(), "comando da conservare\n")
                elif kind == "directory":
                    self.assertEqual((command / "personale").read_text(), "da conservare\n")
                else:
                    self.assertTrue(command.is_symlink())
                    self.assertEqual(os.readlink(command), str(personal if kind == "link" else self.directory / "assente"))
                self.assertEqual(personal.read_text(), "#!/bin/sh\necho personale\n")
                if kind == "directory":
                    shutil.rmtree(command)
                else:
                    command.unlink()

    def test_correct_cli_link_is_reused_without_replacement(self):
        command = self.home / ".local/bin/gdev"
        command.parent.mkdir(parents=True)
        # Anche un collegamento relativo verso il checkout è già corretto.
        command.symlink_to(os.path.relpath(self.repository / "bin/gdev", command.parent))
        before = command.lstat()
        for _ in range(2):
            result = self.bootstrap("--no-launch")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(command.lstat().st_ino, before.st_ino)
            self.assertEqual(command.resolve(), (self.repository / "bin/gdev").resolve())

    def test_failed_and_missing_startup_receipts_do_not_report_ready(self):
        for flag in ("GDEV_BOOTSTRAP_TEST_STARTUP", "GDEV_BOOTSTRAP_TEST_SILENT"):
            with self.subTest(flag=flag):
                self.env[flag] = "failed" if flag.endswith("STARTUP") else "1"
                result = self.bootstrap()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("interfaccia verificata", result.stdout)
                self.env.pop(flag)

    def test_no_launch_and_failed_install_never_claim_a_verified_window(self):
        result = self.bootstrap("--no-launch")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("interfaccia verificata", result.stdout)
        self.assertEqual(self.log.read_text().splitlines(), ["install"])
        self.env["GDEV_BOOTSTRAP_TEST_INSTALL_STATUS"] = "7"
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("emacs", self.log.read_text().splitlines())

    def test_editor_entry_supplies_a_complete_init_directory_argument(self):
        self.script("emacs-argomenti", 'printf "%s\\n" "$@" > "$GDEV_BOOTSTRAP_TEST_LOG"\n')
        self.env["EMACS"] = str(self.commands / "emacs-argomenti")
        result = subprocess.run([str(ROOT / "bin/gdev"), "emacs"], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.log.read_text().splitlines()
        self.assertEqual(args[0], "--init-directory=" + str(ROOT))
        self.assertNotIn("--init-directory", args)
        self.assertTrue(Path(args[0].split("=", 1)[1], "init.el").is_file())
        self.assertEqual(args[1:], ["--load", str(ROOT / "bin/gdev-startup-check.el")])


_voice_spec = importlib.util.spec_from_file_location("gdev_voice_contracts", ROOT / "test/gdev-voice-contract-test.py")
_voice_contracts = importlib.util.module_from_spec(_voice_spec)
_voice_spec.loader.exec_module(_voice_contracts)
VoiceContracts = _voice_contracts.VoiceContracts


if __name__ == "__main__":
    unittest.main()
