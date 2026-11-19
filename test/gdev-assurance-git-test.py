#!/usr/bin/env python3
"""Real Git and SSH flows, including --no-verify and pre-push bypass attempts.
SPDX-License-Identifier: GPL-3.0-or-later
"""

import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).resolve().parents[1] / "bin/gdev-assurance-check"
sys.dont_write_bytecode = True
LOADER = importlib.machinery.SourceFileLoader("assurance_checker", str(CHECKER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
API = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(API)


class GitAssuranceContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gdev-git-contract-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.root = self.directory / "project"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Prova")
        self.git("config", "user.email", "prova@example.org")
        self.source = self.root / "file con spazi.txt"
        self.source.write_text("iniziale\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Situazione precedente all'adozione")
        self.base = API.resolve(self.root, "HEAD")
        self.key = self.directory / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.signers = self.directory / "signers"
        self.signers.write_text("persona " + Path(str(self.key) + ".pub").read_text())
        self.message = self.directory / "message"

    def git(self, *args, check=True):
        result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=False)
        if check:
            self.assertEqual(0, result.returncode, result.stderr.decode())
        return result

    def approve(self, amend=False):
        self.source.write_text("modifica autorizzata amend\n" if amend else "modifica autorizzata\n")
        self.git("add", "--", self.source.name)
        data = {"format": "GES-commit-1", "transaction": "GT-0001", "profile": "core",
                "state": "AUTHORIZED", "authorized_by": "persona", "signer": "persona",
                "chain_head": "a" * 64, "controls_digest": "b" * 64,
                "repository": "test/project", **API.snapshot(self.root, amend=amend)}
        payload = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(payload).hexdigest()
        directory = self.root / ".gdev-assurance/receipts"
        directory.mkdir(parents=True, exist_ok=True)
        self.receipt = directory / (digest + ".json")
        self.receipt.write_bytes(payload)
        subprocess.run(["ssh-keygen", "-Y", "sign", "-n", API.NAMESPACE, "-f", str(self.key), str(self.receipt)],
                       capture_output=True, check=True)
        Path(str(self.receipt) + ".sig").rename(directory / (digest + ".sig"))
        self.git("add", ".gdev-assurance/receipts")
        self.message.write_text(f"Modifica\n\nGDev-Transaction: GT-0001\nGDev-Receipt: {digest}\n")

    def verify_staged(self, message=None, repository="test/project", signers=None):
        state = API.snapshot(self.root)
        tree = self.git("write-tree").stdout.decode().strip()
        return API.verify(self.root, tree, state["parents"], message or self.message.read_bytes(),
                          signers or self.signers, repository)

    def test_hooks_accept_signed_commit_and_pre_push_checks_only_after_baseline(self):
        API.install(self.root, self.signers, "test/project")
        self.approve()
        self.git("commit", "-qF", str(self.message))
        self.assertEqual(1, API.verify_range(self.root, self.base, "HEAD", self.signers, "test/project"))
        remote = self.directory / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "origin", "HEAD:main")

    def test_bypass_commit_hook_still_fails_pre_push_and_ci_range(self):
        API.install(self.root, self.signers, "test/project")
        self.source.write_text("senza autorizzazione\n")
        self.git("add", ".")
        self.assertNotEqual(0, self.git("commit", "-qm", "Senza transazione", check=False).returncode)
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "--no-verify equivalente")
        with self.assertRaises(API.Refused):
            API.verify_range(self.root, self.base, "HEAD", self.signers, "test/project")
        remote = self.directory / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.git("remote", "add", "origin", str(remote))
        self.assertNotEqual(0, self.git("push", "-q", "origin", "HEAD:main", check=False).returncode)

    def test_amend_receipt_binds_replaced_commit_parents(self):
        API.install(self.root, self.signers, "test/project")
        self.approve()
        self.git("commit", "-qF", str(self.message))
        self.approve(amend=True)
        self.git("commit", "--amend", "-qF", str(self.message))
        self.assertEqual(1, API.verify_range(self.root, self.base, "HEAD", self.signers, "test/project"))

    def test_merge_receipt_binds_both_parents_and_every_intermediate_commit(self):
        API.install(self.root, self.signers, "test/project")
        self.git("checkout", "-qb", "principal")
        self.approve()
        self.git("commit", "-qF", str(self.message))
        self.git("checkout", "-qb", "laterale", self.base)
        (self.root / "altro.txt").write_text("modifica laterale\n")
        self.git("add", "altro.txt")
        self.approve()
        self.git("commit", "-qF", str(self.message))
        self.git("checkout", "-q", "principal")
        self.git("merge", "--no-commit", "--no-ff", "laterale")
        self.approve()
        self.git("commit", "-qF", str(self.message))
        self.assertEqual(3, API.verify_range(self.root, self.base, "HEAD", self.signers, "test/project"))

    def test_signature_binds_source_parent_repository_and_principal(self):
        self.approve()
        self.verify_staged()
        with self.assertRaises(API.Refused):
            self.verify_staged(repository="other/project")
        other = self.directory / "untrusted-signers"
        other.write_text("altro " + Path(str(self.key) + ".pub").read_text())
        with self.assertRaises(API.Refused):
            self.verify_staged(signers=other)
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Genitore diverso")
        with self.assertRaises(API.Refused):
            self.verify_staged()

    def test_source_and_mode_changes_after_signature_are_rejected(self):
        self.approve()
        self.source.write_text("modifica successiva\n")
        self.git("add", ".")
        with self.assertRaises(API.Refused):
            self.verify_staged()
        self.source.write_text("modifica autorizzata\n")
        self.git("add", ".")
        self.git("update-index", "--chmod=+x", "--", self.source.name)
        with self.assertRaises(API.Refused):
            self.verify_staged()

    def test_optional_snapshot_tree_remains_bound_to_the_original_index(self):
        old = API.snapshot(self.root, include_tree=True)
        self.assertEqual({"source_digest", "parents", "tree"}, set(old))
        self.assertEqual({"source_digest", "parents"}, set(API.snapshot(self.root)))
        self.source.write_bytes(b"nuovi byte\x00\xff\n")
        self.git("add", "--", self.source.name)
        new = API.snapshot(self.root, include_tree=True)
        self.assertNotEqual(old["tree"], new["tree"])
        self.assertNotEqual(old["source_digest"], new["source_digest"])
        self.assertEqual(old["source_digest"], API.tree_entries(self.root, old["tree"])[0])
        result = subprocess.run([str(CHECKER), "--root", str(self.root), "snapshot", "--tree"],
                                capture_output=True, check=True)
        self.assertEqual(new, json.loads(result.stdout))

    def test_receipt_edit_duplicate_trailer_and_body_text_are_rejected(self):
        self.approve()
        with self.assertRaises(API.Refused):
            self.verify_staged(self.message.read_bytes() + b"GDev-Transaction: GT-0002\n")
        with self.assertRaises(API.Refused):
            self.verify_staged(self.message.read_bytes() + b"\nQuesto e' testo finale del messaggio.\n")
        self.receipt.write_text(self.receipt.read_text().replace("AUTHORIZED", "APPROVED"))
        self.git("add", ".")
        with self.assertRaises(API.Refused):
            self.verify_staged()

    def test_install_preserves_existing_hooks_and_rejects_candidate_trust_keys(self):
        self.git("config", "core.hooksPath", "my-hooks")
        with self.assertRaises(API.Refused):
            API.install(self.root, self.signers, "test/project")
        self.assertEqual("my-hooks", self.git("config", "--get", "core.hooksPath").stdout.decode().strip())
        self.git("config", "--unset", "core.hooksPath")
        internal = self.root / "signers"
        internal.write_text(self.signers.read_text())
        with self.assertRaises(API.Refused):
            API.install(self.root, internal, "test/project")


if __name__ == "__main__":
    unittest.main()
