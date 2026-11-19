"""Prove di contratto della CLI e del trasporto MCP di GDev-Emacs."""

# Copyright (C) 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: GPL-3.0-or-later

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
EMACS = os.environ.get("EMACS") or shutil.which("emacs")


class CliContracts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gdev-contract-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.user = self.directory / "user"
        self.state = self.directory / "state"
        (self.user / "snippets").mkdir(parents=True)
        self.state.mkdir()
        self.env = dict(os.environ, EMACS=EMACS, GDEV_USER_DIR=str(self.user),
                        GDEV_STATE_DIR=str(self.state))
        for variable in ("GDEV_PROFILE", "GDEV_DEBUG"):
            self.env.pop(variable, None)

    def cli(self, *arguments, check=True):
        return subprocess.run(
            ["./bin/gdev", *arguments], cwd=ROOT, env=self.env, check=check,
            capture_output=True, encoding="utf-8", timeout=40,
        )

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

    def test_cli_validates_the_socket_and_the_live_action(self):
        socket_file = self.directory / "non-socket"
        socket_file.touch()
        result = self.cli("agent", "live", str(socket_file), "status", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("socket Unix", json.loads(result.stdout)["error"])
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

    def test_formal_project_cli_mcp_unicode_and_taxonomy_pagination(self):
        root = self.directory / "progetto"
        root.mkdir()

        def assurance(*arguments, expected=0):
            result = subprocess.run([str(ROOT / "bin/gdev"), "assurance", *arguments], cwd=root,
                                    env=self.env, capture_output=True, encoding="utf-8", timeout=40)
            self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
            return result

        created = json.loads(assurance("project-init", "DEMO", "Progetto è 日本語").stdout)
        self.assertEqual("Progetto è 日本語", created["project"]["name"])
        self.assertEqual("INCOMPLETE", json.loads(assurance("project", expected=1).stdout)["status"])
        parameters = json.dumps({"title": "È una prova", "content": "日本語 $(touch nope)"}, ensure_ascii=False)
        preview = json.loads(assurance("snippet-preview", "SNIP-DOCUMENTATION", parameters).stdout)
        self.assertIn("日本語 $(touch nope)", preview["content"])
        self.assertEqual("PLANNED", json.loads(assurance("procedure-plan", "PROC-FEATURE").stdout)["status"])
        self.assertFalse((root / ".gdev").exists())
        missing = assurance("snippet-preview", "SNIP-DOCUMENTATION", "{}", expected=1)
        self.assertIn("Compila il parametro", missing.stdout)
        self.assertFalse((root / "nope").exists())
        with self.editor() as socket:
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
        socket = self.directory / "s" / "test"
        log = self.directory / "emacs.log"
        form = (
            "(progn (require 'server) "
            '(when (bound-and-true-p gdev-failed-modules) '
            '(error "Moduli non caricati: %S" gdev-failed-modules)) '
            f"(setq server-socket-dir {json.dumps(str(socket.parent))} "
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
                while not socket.is_socket() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(socket.is_socket(), log.read_text(encoding="utf-8"))
                yield socket
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

    def test_mcp_reports_the_correct_error_at_each_tool_boundary(self):
        (unavailable,) = self.mcp(self.directory / "socket-assente", [self.call("gdev_status")])
        self.assertIn("socket Unix", self.payload(unavailable, error=True)["error"])
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


if __name__ == "__main__":
    unittest.main()
