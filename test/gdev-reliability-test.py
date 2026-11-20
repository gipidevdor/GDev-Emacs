#!/usr/bin/env python3
"""Prove ripetibili su API GDev reali, con oracolo SQLite/Python indipendente."""
# Copyright (C) 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
EMACS = os.environ.get("EMACS", shutil.which("emacs") or "emacs")
KEYS = ["gdev-layout-folder", "gdev-layout-explorer-width", "gdev-layout-panel-hidden"]
COUNTS = {"model_operations": 0, "sql_faults": 0, "crash_points": 0}
OPTIONS = None


class WorkerError(RuntimeError):
    """Un figlio non avviabile non conta come mutazione intercettata."""


def command(config, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    incoming, outgoing = directory / "input.json", directory / "result.json"
    incoming.write_text(json.dumps(config, ensure_ascii=False))
    env = dict(os.environ, GDEV_RELIABILITY_INPUT=str(incoming), GDEV_RELIABILITY_RESULT=str(outgoing),
               GDEV_STATE_DIR=str(directory / "state"), GDEV_USER_DIR=str(directory / "user"))
    if OPTIONS.overlay:
        env["GDEV_RELIABILITY_OVERLAY"] = str(Path(OPTIONS.overlay).resolve())
    return [EMACS, "--batch", "-Q", "-l", str(ROOT / "early-init.el"),
            "-l", str(ROOT / "test/gdev-reliability-worker.el")], env, outgoing


def worker(config, directory):
    args, env, result = command(config, directory)
    child = subprocess.run(args, env=env, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=45)
    if child.returncode or not result.exists():
        raise WorkerError(f"Processo isolato non avviabile ({child.returncode}):\n{child.stdout[:2500]}\n[...]\n{child.stdout[-1800:]}")
    return json.loads(result.read_text())


def database(root):
    return Path(root) / ".gdev/assurance/assurance.sqlite"


def snapshot(root):
    """Leggi tutto lo stato SQL senza usare le funzioni di verifica GDev."""
    path = database(root)
    if not path.exists():
        return {}
    with contextlib.closing(sqlite3.connect(f"file:{path}?mode=rw", uri=True)) as db:
        db.execute("pragma query_only=on")
        # La riapertura consente a SQLite di recuperare il journal dopo il crash.
        db.execute("pragma query_only=on")
        if db.execute("pragma integrity_check").fetchall() != [("ok",)]:
            raise AssertionError("Archivio corrotto dopo un guasto")
        if db.execute("pragma foreign_key_check").fetchall():
            raise AssertionError("Chiavi esterne violate dopo un guasto")
        tables = [row[0] for row in db.execute("select name from sqlite_master where type='table' order by name")]
        return {name: db.execute('select * from "' + name.replace('"', '""') + '" order by rowid').fetchall()
                for name in tables}


def setup(directory):
    root = Path(directory) / "project"
    root.mkdir(parents=True)
    result = worker({"scenario": "setup", "root": str(root)}, Path(directory) / "setup")
    if not result["ok"]:
        raise AssertionError(result)
    return root


def generated(seed, steps):
    """Genera operazioni e risultati attesi con un modello a dizionari."""
    state = seed
    def next_number(limit):
        nonlocal state
        state = (1664525 * state + 1013904223) % 4294967296
        return (state >> 8) % limit
    def value(key):
        choices = {KEYS[0]: [None, "", "/progetto/è/中", "/" + "nome-lungo/" * 20],
                   KEYS[1]: [None, 0, 1, 30, 120], KEYS[2]: [None, True]}
        return choices[key][next_number(len(choices[key]))]
    model = [{key: None for key in KEYS} for _ in range(2)]
    operations, expected = [], []
    for _ in range(steps):
        tab, action = next_number(2), next_number(8)
        rejected = False
        if action < 3:
            key = KEYS[next_number(len(KEYS))]
            operation = {"action": "set", "tab": tab, "key": key, "value": value(key)}
            model[tab][key] = operation["value"]
        elif action < 7:
            changes = []
            for _ in range(1 + next_number(4)):
                key = KEYS[next_number(len(KEYS))]
                changes.append({"key": key, "value": value(key)})
            if action == 6:
                changes.insert(next_number(len(changes) + 1), {"key": "campo-non-registrato", "value": 1})
                rejected = True
            else:
                for change in changes:
                    model[tab][change["key"]] = change["value"]
            operation = {"action": "batch", "tab": tab, "changes": changes}
        else:
            operation = {"action": "restore", "tab": tab}
        operations.append(operation)
        expected.append({"rejected": rejected, "tabs": [dict(item) for item in model]})
    return operations, expected


class Reliability(unittest.TestCase):
    def test_workspace(self):
        for seed in OPTIONS.seeds:
            operations, expected = generated(seed, OPTIONS.steps)
            with tempfile.TemporaryDirectory(prefix="gdev-model-") as directory:
                result = worker({"scenario": "workspace", "keys": KEYS, "operations": operations}, directory)
            self.assertTrue(result["ok"])
            self.assertEqual(len(expected), len(result["responses"]))
            for step, (wanted, actual) in enumerate(zip(expected, result["responses"])):
                self.assertEqual(wanted, actual, f"seed={seed} step={step}; replay={json.dumps(operations[:step+1])}")
            COUNTS["model_operations"] += len(operations)

    def faults(self, operation):
        with tempfile.TemporaryDirectory(prefix="gdev-fault-") as directory:
            directory = Path(directory)
            baseline = setup(directory / "base") if operation != "initialize" else directory / "base/project"
            baseline.mkdir(parents=True, exist_ok=True)
            before = snapshot(baseline)
            probe = directory / "probe/project"
            shutil.copytree(baseline, probe)
            result = worker({"scenario": "operation", "operation": operation, "root": str(probe)}, directory / "probe/job")
            self.assertTrue(result["ok"], result)
            self.assertGreater(result["calls"], 0)
            for sticky in (False, True):
                for point in range(1, result["calls"] + 1):
                    with self.subTest(operation=operation, point=point, sticky=sticky):
                        case = directory / f"case-{int(sticky)}-{point}"
                        root = case / "project"
                        shutil.copytree(baseline, root)
                        failure = worker({"scenario": "operation", "operation": operation, "root": str(root),
                                          "fault": point, "sticky": sticky}, case / "job")
                        self.assertFalse(failure["ok"], failure)
                        self.assertEqual(before, snapshot(root), "Il guasto ha lasciato una scrittura parziale")
                        COUNTS["sql_faults"] += 1

    def test_write_faults(self):
        for operation in ("open", "evidence"):
            self.faults(operation)

    def test_migration_faults(self):
        self.faults("initialize")

    def test_crashes(self):
        for journal in ("DELETE", "WAL"):
            with tempfile.TemporaryDirectory(prefix="gdev-crash-") as directory:
                directory = Path(directory)
                base = setup(directory / "base")
                with contextlib.closing(sqlite3.connect(database(base))) as db:
                    self.assertEqual(journal.lower(), db.execute(f"pragma journal_mode={journal}").fetchone()[0].lower())
                before = snapshot(base)
                reference = directory / "reference/project"
                shutil.copytree(base, reference)
                complete = worker({"scenario": "operation", "operation": "evidence", "root": str(reference)}, directory / "reference/job")
                self.assertTrue(complete["ok"], complete)
                after = snapshot(reference)
                for point in range(1, complete["calls"] + 1):
                    case = directory / f"crash-{point}"
                    root = case / "project"
                    shutil.copytree(base, root)
                    checkpoint = case / "checkpoint.json"
                    args, env, _ = command({"scenario": "operation", "operation": "evidence", "root": str(root),
                                            "stop": point, "checkpoint": str(checkpoint)}, case / "job")
                    with (case / "child.log").open("w") as log:
                        child = subprocess.Popen(args, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                        try:
                            deadline = time.monotonic() + 20
                            while not checkpoint.exists() and child.poll() is None and time.monotonic() < deadline:
                                time.sleep(0.01)
                            if not checkpoint.exists():
                                raise WorkerError("Il figlio non ha raggiunto il punto di arresto")
                            # Popen identifica esclusivamente il processo creato qui.
                            child.kill()
                            self.assertEqual(-signal.SIGKILL, child.wait(timeout=10))
                        finally:
                            if child.poll() is None:
                                child.kill()
                                child.wait(timeout=10)
                    actual = snapshot(root)
                    self.assertEqual(after if point == complete["calls"] else before, actual,
                                     f"Arresto {journal}/{point}: aggiornamento non atomico")
                    COUNTS["crash_points"] += 1

    def test_read(self):
        with tempfile.TemporaryDirectory(prefix="gdev-query-only-") as directory:
            root = setup(directory)
            before = snapshot(root)
            result = worker({"scenario": "read", "root": str(root)}, Path(directory) / "read")
            self.assertTrue(result["rejected"], "La connessione di lettura accetta una scrittura")
            self.assertEqual(before, snapshot(root))

    def test_audit(self):
        with tempfile.TemporaryDirectory(prefix="gdev-audit-") as directory:
            root = setup(directory)
            with contextlib.closing(sqlite3.connect(database(root))) as db:
                trigger = db.execute("select sql from sqlite_master where name='tx_event_no_update'").fetchone()[0]
                db.execute("drop trigger tx_event_no_update")
                db.execute("update tx_event set actor='alterato'")
                db.execute(trigger)
                db.commit()
            result = worker({"scenario": "verify", "root": str(root)}, Path(directory) / "verify")
            self.assertTrue(result["problems"], "Una catena manomessa è stata dichiarata integra")

    def test_resource(self):
        with tempfile.TemporaryDirectory(prefix="gdev-resource-") as directory:
            root = Path(directory) / "project"
            root.mkdir()
            result = worker({"scenario": "resource", "root": str(root)}, Path(directory) / "job")
            self.assertEqual({"error": True, "quit": True, "throw": True}, result["closed"])


MUTATIONS = [
    ("chiavi-non-validate", "lisp/gdev-workspace-state.el", "(unless (assq key gdev-workspace-state-fields)", "(unless t", "workspace", 1),
    ("snapshot-perso", "lisp/gdev-workspace-state.el", "(cons tab (copy-alist (cdr tab)))", "(cons tab nil)", "workspace", 1),
    ("aggiornamento-parziale", "lisp/gdev-workspace-state.el",
     "(setq entries (gdev-workspace-state--put entries (car change) (cdr change))))",
     "(setq entries (gdev-workspace-state--put entries (car change) (cdr change))) (setcdr tab entries))", "workspace", 1),
    ("commit-al-posto-del-rollback", "lisp/gdev-assurance-db.el", '(ignore-errors (sqlite-execute db "rollback"))',
     '(ignore-errors (sqlite-execute db "commit"))', "write_faults", 2),
    ("lettura-scrivibile", "lisp/gdev-assurance-db.el", '(sqlite-pragma db "query_only = on")', "(ignore db)", "read", 1),
    ("audit-omesso", "lisp/gdev-assurance.el", "(gdev-process-verify db)", "nil", "audit", 1),
    ("connessione-non-chiusa", "lisp/gdev-assurance-db.el", "(unless done (gdev-assurance-db-close db))",
     "(ignore done db)", "resource", 1),
]


def mutations(output):
    for name, filename, old, new, case, count in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix="gdev-mutant-") as directory:
            directory = Path(directory)
            source = (ROOT / filename).read_text()
            if source.count(old) != count:
                output.append({"name": name, "status": "invalid", "reason": "Il punto di mutazione è cambiato"})
                continue
            overlay = directory / "overlay"
            overlay.mkdir()
            (overlay / Path(filename).name).write_text(source.replace(old, new))
            report = directory / "report.json"
            args = [os.sys.executable, str(Path(__file__).resolve()), "--case", case, "--overlay", str(overlay),
                    "--output", str(report), "--seed", str(OPTIONS.seeds[0]), "--steps", str(OPTIONS.steps)]
            child = subprocess.run(args, cwd=ROOT, env=os.environ.copy(), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=120)
            data = json.loads(report.read_text()) if report.exists() else {}
            killed = child.returncode == 1 and data.get("failures", 0) > 0 and data.get("errors") == 0
            log = child.stdout.replace(str(ROOT) + os.sep, "")
            output.append({"name": name, "status": "killed" if killed else "survived" if child.returncode == 0 else "invalid",
                           "source": filename, "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                           "case": case, "log": log[-12000:]})


def source_inventory():
    """Fissa anche i dati e le prove, senza includere stato o bytecode."""
    try:
        names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                        cwd=ROOT, stderr=subprocess.DEVNULL).decode().split("\0")
    except subprocess.CalledProcessError:
        names = [str(path.relative_to(ROOT)) for path in ROOT.rglob("*") if path.is_file()]
    result = []
    for name in sorted(set(filter(None, names))):
        path = ROOT / name
        if name.startswith(".gdev-assurance/receipts/") or any(part in {".git", ".gdev", "__pycache__"} for part in Path(name).parts):
            continue
        if path.suffix not in {".el", ".py", ".eld", ".json", ".yml", ".yaml", ".c", ".h", ".m", ".swift", ".md", ".org", ".tmpl", ".lavorazione", ".csv", ".xlsx", ".pdf", ".svg", ".txt"} and not name.startswith("bin/gdev"):
            continue
        content = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        result.append({"path": name, "sha256": hashlib.sha256(content).hexdigest()})
    return result


def main():
    global OPTIONS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=[name[5:] for name in dir(Reliability) if name.startswith("test_")])
    parser.add_argument("--overlay", help=argparse.SUPPRESS)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--steps", type=int, default=160)
    parser.add_argument("--mutations", action="store_true")
    parser.add_argument("--output", type=Path)
    OPTIONS = parser.parse_args()
    if not 1 <= OPTIONS.steps <= 10000:
        parser.error("--steps deve essere compreso fra 1 e 10000")
    OPTIONS.seeds = [OPTIONS.seed] if OPTIONS.seed is not None else [1, 7, 42, 127, 1024, 65537, 20261119, 4294967295]
    suite = (unittest.TestSuite([Reliability("test_" + OPTIONS.case)]) if OPTIONS.case
             else unittest.defaultTestLoader.loadTestsFromTestCase(Reliability))
    sources = source_inventory()
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {"schema_version": 1, "emacs": EMACS, "seeds": OPTIONS.seeds, "steps": OPTIONS.steps,
              "tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
              "counts": COUNTS, "mutations": [], "sources": sources,
              "cases": [test.id().rsplit(".", 1)[-1][5:] for test in unittest.defaultTestLoader.loadTestsFromTestCase(Reliability)
                        if not OPTIONS.case or test.id().endswith("test_" + OPTIONS.case)],
              "human_approval": "NOT_VERIFIED"}
    if result.wasSuccessful() and OPTIONS.mutations:
        mutations(report["mutations"])
    passed = result.wasSuccessful() and all(item["status"] == "killed" for item in report["mutations"])
    report["sources_changed"] = source_inventory() != sources
    passed = passed and not report["sources_changed"]
    report["ok"] = passed
    if OPTIONS.output:
        OPTIONS.output.parent.mkdir(parents=True, exist_ok=True)
        OPTIONS.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in {"mutations", "sources"}}, ensure_ascii=False))
    if report["mutations"]:
        print("Mutazioni:", ", ".join(item["name"] + "=" + item["status"] for item in report["mutations"]))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
