"""Contratti di isolamento e degli esiti negativi del runner GUI."""

# SPDX-License-Identifier: GPL-3.0-or-later

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("gdev_gui_startup", Path(__file__).with_name("gdev-gui-startup-test.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class GuiRunnerContracts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gdev-gui-runner-contract-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()

    def test_cache_copy_does_not_follow_recursive_directory_links(self):
        build = self.directory / "build"
        native = build / "eln-cache/version/core.eln"
        native.parent.mkdir(parents=True)
        native.write_bytes(b"cache di prova")
        (build / "eln-cache/loop").symlink_to(build / "eln-cache", target_is_directory=True)
        grammar = build / "tree-sitter/libtree-sitter-json.dylib"
        grammar.parent.mkdir(parents=True)
        grammar.write_bytes(b"grammatica di prova")
        (grammar.parent / "loop").symlink_to(grammar.parent, target_is_directory=True)
        state = self.directory / "state"
        self.assertEqual(runner.copy_build_cache(build, state), 1)
        self.assertEqual((state / "eln-cache/version/core.eln").read_bytes(), native.read_bytes())
        self.assertEqual((state / "tree-sitter" / grammar.name).read_bytes(), grammar.read_bytes())
        self.assertFalse((state / "tree-sitter/loop").exists())

    def test_receipts_reject_other_processes_profiles_and_non_native_windows(self):
        output = self.directory / "receipts"
        output.mkdir()
        state, private = self.directory / "state", self.directory / "private"
        startup = dict(ok=True, pid=1234, root=str(runner.ROOT), private=str(private), graphical=True, workbench=True)
        gui = dict(ok=True, pid=1234, token="prova", state=str(state), private=str(private),
                   graphical=True, visible=True, native=True, window_system="ns")
        (output / "status").write_text("ready\n")
        for change in (dict(pid=999), dict(token="altra istanza"), dict(native=False),
                       dict(window_system="tty"), dict(state=str(self.directory / "altro"))):
            with self.subTest(change=change):
                (output / "result.json").write_text(json.dumps(startup))
                (output / "gui-result.json").write_text(json.dumps(dict(gui, **change)))
                with self.assertRaises(RuntimeError):
                    runner.validate_receipts(output, SimpleNamespace(pid=1234), "prova", state, private)

    def test_timeout_reaps_only_the_started_process(self):
        root = self.directory / "checkout"
        script = root / "bin/gdev"
        script.parent.mkdir(parents=True)
        script.write_text("#!" + sys.executable + "\nimport os,pathlib,time\n"
                          "pathlib.Path(os.environ['GDEV_STARTUP_CHECK_DIR'],'pid').write_text(str(os.getpid()))\n"
                          "time.sleep(60)\n")
        script.chmod(0o700)
        build = self.directory / "build/eln-cache/version"
        build.mkdir(parents=True)
        (build / "core.eln").write_bytes(b"cache di prova")
        output = self.directory / "output"
        output.mkdir()
        args = SimpleNamespace(require=True, timeout=0.5, build_state=self.directory / "build")
        sibling = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with patch.object(runner, "ROOT", root), patch.object(runner, "aqua_session", return_value=(True, None)):
                with self.assertRaisesRegex(RuntimeError, "Timeout"):
                    runner.run(args, output)
            pid = int((output / "pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            self.assertIsNone(sibling.poll(), "La pulizia non deve terminare altre istanze")
        finally:
            sibling.terminate()
            sibling.wait(timeout=5)

    def test_standard_entry_is_prepared_without_inheriting_shell_options(self):
        output = self.directory / "output"
        output.mkdir()
        env = dict(os.environ, GDEV_PROFILE="gui-contract",
                   GDEV_STATE_DIR=str(self.directory / "state"),
                   GDEV_USER_DIR=str(self.directory / "private"),
                   GDEV_TOOLS_DIR=str(self.directory / "tools"),
                   GDEV_STARTUP_CHECK_DIR=str(output), GDEV_GUI_TEST_TOKEN="contratto")
        executable, entry = runner.prepare_standard_entry(self.directory, env, output, 30)
        installed = json.loads((output / "installation.json").read_text())
        self.assertTrue(Path(executable).is_file())
        for name in installed["environment"]:
            self.assertNotIn(name, env, "Il lancio deve ricostruire questa opzione dal wrapper")
        self.assertEqual(env["HOME"], str(entry.parent))
        self.assertEqual(env["GDEV_STARTUP_CHECK_DIR"], str(output))
        self.assertEqual(env["GDEV_GUI_TEST_TOKEN"], "contratto")
        self.assertIn('"GDEV_PROFILE" "gui-contract"', (entry / "early-init.el").read_text())

    def test_standard_entry_uses_the_app_declared_launcher(self):
        app = self.directory / "Emacs.app"
        launcher = app / "Contents/MacOS/Emacs"
        launcher.parent.mkdir(parents=True)
        launcher.write_bytes(b"ingresso app")
        internal = launcher.with_name("Emacs-arm64")
        internal.write_bytes(b"binario interno")
        with (app / "Contents/Info.plist").open("wb") as metadata:
            plistlib.dump(dict(CFBundleExecutable="Emacs"), metadata)
        self.assertEqual(runner.macos_app_executable(str(internal)), str(launcher))


if __name__ == "__main__":
    unittest.main()
