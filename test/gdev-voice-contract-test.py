"""Contratti offline del modello vocale facoltativo, inclusi nella suite CLI."""
# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gdev_voice_prepare", ROOT / "bin/gdev-voice-prepare.py")
VOICE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VOICE)


class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class VoiceContracts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gdev-voice-contract-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = "modello italiano di prova, nessun peso reale".encode()
        self.model = {"file": "ggml-small.bin", "size": len(self.data),
                      "sha256": hashlib.sha256(self.data).hexdigest(), "license": "MIT",
                      "repository": "example/fixture", "revision": "a" * 40,
                      "license_file": "LICENSE"}
        self.target = self.root / "ggml-small.bin"
        self.engine = dict(kind="whisper.cpp", repository="https://github.com/gipidevdor/whisper.cpp.git",
                           revision="b" * 40, version="1.9.6-dev", license="MIT")
        self.manifest = self.root / "modelli.json"
        self.manifest.write_text(json.dumps({"version": 2, "engine": self.engine, "models": {"small": self.model}}))
        (self.root / "LICENSE").write_text("MIT fixture\n")

    def test_voice_download_resumes_and_verifies_before_publishing(self):
        partial = self.target.with_suffix(".bin.part")
        partial.write_bytes(self.data[:9])
        def opener(request, timeout):
            self.assertEqual(request.get_header("Range"), "bytes=9-")
            self.assertEqual(timeout, 45)
            self.assertIn("/" + "a" * 40 + "/", request.full_url)
            self.assertFalse(self.target.exists())
            return Response(self.data[9:], 206, {"Content-Range": "bytes 9-%d/%d" % (len(self.data)-1, len(self.data))})
        self.assertEqual(VOICE.download(self.model, self.target, opener), self.target)
        self.assertEqual(self.target.read_bytes(), self.data)
        self.assertFalse(partial.exists())

    def test_voice_server_ignoring_range_restarts_instead_of_appending(self):
        self.target.with_suffix(".bin.part").write_bytes(self.data[:4])
        VOICE.download(self.model, self.target, lambda *_args, **_kwargs: Response(self.data))
        self.assertEqual(self.target.read_bytes(), self.data)

    def test_voice_invalid_range_cannot_publish(self):
        self.target.with_suffix(".bin.part").write_bytes(self.data[:4])
        with self.assertRaisesRegex(ValueError, "punto di ripresa"):
            VOICE.download(self.model, self.target,
                           lambda *_args, **_kwargs: Response(self.data, 206, {"Content-Range": "bytes 2-9/10"}))
        self.assertFalse(self.target.exists())

    def test_voice_corruption_and_oversize_are_not_published(self):
        for data in (b"x" * len(self.data), self.data + b"extra"):
            with self.subTest(size=len(data)):
                with self.assertRaises(ValueError):
                    VOICE.download(self.model, self.target, lambda *_args, **_kwargs: Response(data))
                self.assertFalse(self.target.exists())

    def test_voice_partial_promotion_preserves_an_unrelated_invalid_target(self):
        self.target.write_bytes(b"user file")
        self.target.with_suffix(".bin.part").write_bytes(self.data)
        VOICE.download(self.model, self.target, lambda *_args, **_kwargs: self.fail("Rete inutile"))
        self.assertEqual(self.target.read_bytes(), self.data)
        self.assertEqual([path.read_bytes() for path in self.root.glob("*.conservato-*")], [b"user file"])

    def test_voice_model_symlink_is_preserved(self):
        original = self.root / "personale.bin"
        original.write_bytes(self.data)
        self.target.symlink_to(original)
        with self.assertRaises(ValueError):
            VOICE.download(self.model, self.target, lambda *_args, **_kwargs: self.fail("Rete implicita"))
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(original.read_bytes(), self.data)

    def test_voice_check_never_installs_or_downloads_even_with_install_default(self):
        directory = self.root / "cache"
        directory.mkdir()
        (directory / "preparazione.lock").touch()
        def which(name):
            return "/usr/bin/" + name if name in ("brew", "curl") else None
        with patch.object(VOICE.shutil, "which", side_effect=which), \
             patch.object(VOICE.sys, "platform", "darwin"), \
             patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Installazione implicita")), \
             patch.object(VOICE, "download", side_effect=AssertionError("Download implicito")):
            with self.assertRaisesRegex(RuntimeError, "Strumenti mancanti"):
                VOICE.prepare(directory, "small", self.manifest, check=True)

    def test_voice_check_requires_the_optional_model(self):
        directory = self.root / "cache"
        directory.mkdir()
        (directory / "preparazione.lock").touch()
        with patch.object(VOICE.shutil, "which", side_effect=lambda name: "/bin/" + name), \
             patch.object(VOICE, "download", side_effect=AssertionError("Download implicito")):
            with self.assertRaisesRegex(ValueError, "facoltativo assente"):
                VOICE.prepare(directory, "small", self.manifest, check=True)

    def fake_build(self, command, **_kwargs):
        self.commands.append(command)
        output = ""
        if command[:2] == ["git", "init"]:
            source = Path(command[2])
            source.mkdir(parents=True)
            (source / "LICENSE").write_text("MIT engine fixture\n")
        if "rev-parse" in command:
            output = self.engine["revision"]
        elif "get-url" in command:
            output = self.engine["repository"]
        elif command[:2] == ["cmake", "--build"]:
            binary = Path(command[2]) / "bin/whisper-server"
            binary.parent.mkdir(parents=True)
            binary.write_text("#!/bin/sh\nprintf 'server fork fixture\\n'\n")
            binary.chmod(0o700)
        elif command[0].endswith("whisper-server"):
            self.assertEqual(command[1:], ["--help"])
            output = "--model --language --host --port --inference-path --prompt"
        return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

    def prepare_fixture(self, directory):
        self.commands = []
        def download(_model, destination):
            destination.write_bytes(self.data)
            return destination
        with patch.object(VOICE.shutil, "which", side_effect=lambda name: "/bin/" + name), \
             patch.object(VOICE.subprocess, "run", side_effect=self.fake_build), \
             patch.object(VOICE, "download", side_effect=download):
            return VOICE.prepare(directory, "small", self.manifest)

    def test_voice_explicit_prepare_uses_the_pinned_fork_and_keeps_licenses(self):
        directory = self.root / "cache"
        receipt = self.prepare_fixture(directory)
        self.assertEqual(receipt["engine"], self.engine)
        self.assertEqual(receipt["runtime"]["source_revision"], self.engine["revision"])
        self.assertEqual(receipt["runtime"]["source_repository"], self.engine["repository"])
        self.assertEqual(receipt["recognizer"], receipt["runtime"]["binary"])
        self.assertTrue(Path(receipt["recognizer"]).is_relative_to(directory))
        self.assertNotEqual(receipt["recognizer"], "/bin/whisper-server")
        self.assertEqual((directory / "Whisper-MIT.txt").read_text(), "MIT fixture\n")
        self.assertEqual((Path(receipt["runtime"]["runtime"]) / "sorgenti/LICENSE").read_text(), "MIT engine fixture\n")
        fetch = next(command for command in self.commands if "fetch" in command)
        self.assertEqual(fetch[-5:], ["fetch", "--depth", "1", "origin", self.engine["revision"]])
        remote = next(command for command in self.commands if "add" in command)
        self.assertEqual(remote[-1], self.engine["repository"])
        build = next(command for command in self.commands if command[:2] == ["cmake", "--build"])
        self.assertIn("whisper-server", build)
        self.assertEqual(json.loads((directory / "installazione.json").read_text()), receipt)

    def test_voice_check_is_read_only_and_never_runs_git_cmake_or_download(self):
        directory = self.root / "cache"
        receipt = self.prepare_fixture(directory)
        def snapshot():
            return {str(path.relative_to(directory)): (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in directory.rglob("*") if path.is_file()}
        before = snapshot()
        with patch.object(VOICE.shutil, "which", side_effect=lambda name: "/bin/" + name), \
             patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Processo implicito")), \
             patch.object(VOICE, "download", side_effect=AssertionError("Download implicito")):
            self.assertEqual(VOICE.prepare(directory, "small", self.manifest, check=True), receipt)
        self.assertEqual(before, snapshot())

    def test_voice_check_rejects_legacy_or_missing_receipt_without_writing(self):
        directory = self.root / "cache"
        self.prepare_fixture(directory)
        path = directory / "installazione.json"
        for legacy in (None, [], {"schema_version": 1, "ok": True, "recognizer": "/bin/whisper-server"}):
            with self.subTest(legacy=legacy):
                if legacy is None:
                    path.unlink()
                else:
                    path.write_text(json.dumps(legacy))
                before = {str(item.relative_to(directory)): item.read_bytes() for item in directory.rglob("*") if item.is_file()}
                with patch.object(VOICE.shutil, "which", side_effect=lambda name: "/bin/" + name), \
                     patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Processo implicito")):
                    with self.assertRaisesRegex(RuntimeError, "Attiva riconoscimento locale"):
                        VOICE.prepare(directory, "small", self.manifest, check=True)
                self.assertEqual(before, {str(item.relative_to(directory)): item.read_bytes()
                                          for item in directory.rglob("*") if item.is_file()})

    def test_voice_check_absent_directory_has_no_side_effects(self):
        directory = self.root / "assente"
        with patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Processo implicito")):
            with self.assertRaisesRegex(ValueError, "facoltativo assente"):
                VOICE.prepare(directory, "small", self.manifest, check=True)
        self.assertFalse(directory.exists())

    def test_voice_changed_binary_or_foreign_host_is_not_reused(self):
        directory = self.root / "cache"
        receipt = self.prepare_fixture(directory)
        binary = Path(receipt["recognizer"])
        original = binary.read_bytes()
        binary.write_bytes(original + b"alterato")
        with patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Ricompilazione implicita")):
            with self.assertRaisesRegex(RuntimeError, "Motore del fork"):
                VOICE.prepare_runtime(directory, self.engine, True, True)
        binary.write_bytes(original)
        receipt["runtime"]["build"]["architecture"] = "altra architettura"
        (directory / "motore.json").write_text(json.dumps(receipt["runtime"]))
        with self.assertRaisesRegex(RuntimeError, "Motore del fork"):
            VOICE.prepare_runtime(directory, self.engine, True, True)

    def test_voice_wrong_checkout_cannot_publish_or_keep_partial_build(self):
        directory = self.root / "cache"
        directory.mkdir()
        self.commands = []
        def run(command, **kwargs):
            result = self.fake_build(command, **kwargs)
            if "rev-parse" in command:
                result.stdout = "a" * 40
            return result
        with patch.object(VOICE.shutil, "which", return_value="/bin/tool"), \
             patch.object(VOICE.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "revisione fissata"):
                VOICE.prepare_runtime(directory, self.engine, True, False)
        self.assertFalse(list(directory.iterdir()))
        self.assertFalse(any(command[0] == "cmake" for command in self.commands))

    def test_voice_build_uses_apis_available_on_each_supported_macos(self):
        for version, metal, blas in (("11.7", "OFF", "OFF"), ("12.0", "ON", "OFF"), ("13.3", "ON", "ON")):
            with self.subTest(version=version), patch.object(VOICE.sys, "platform", "darwin"), \
                 patch.object(VOICE.platform, "mac_ver", return_value=(version, (), "arm64")):
                options = VOICE.build_options()
                self.assertIn("-DGGML_METAL=" + metal, options)
                self.assertIn("-DGGML_BLAS=" + blas, options)
                self.assertIn("-DGGML_NATIVE=OFF", options)

    def test_voice_invalid_runtime_receipt_is_passive_or_preserved_when_rebuilt(self):
        for text in ("{", "[]"):
            directory = self.root / ("cache-" + str(len(text)))
            directory.mkdir()
            record = directory / "motore.json"
            record.write_text(text)
            with patch.object(VOICE.subprocess, "run", side_effect=AssertionError("Processo implicito")):
                with self.assertRaisesRegex(RuntimeError, "Attiva riconoscimento locale"):
                    VOICE.prepare_runtime(directory, self.engine, True, True)
            self.assertEqual(record.read_text(), text)
            self.commands = []
            with patch.object(VOICE.shutil, "which", return_value="/bin/tool"), \
                 patch.object(VOICE.subprocess, "run", side_effect=self.fake_build):
                VOICE.prepare_runtime(directory, self.engine, True, False)
            self.assertEqual([path.read_text() for path in directory.glob("motore.json.conservato-*")], [text])
            self.assertEqual(json.loads(record.read_text())["engine"], self.engine)

    def test_voice_build_generator_is_explicit_and_does_not_inherit_xcode_settings(self):
        with patch.dict(VOICE.os.environ, {"CMAKE_GENERATOR": "Xcode", "CMAKE_GENERATOR_PLATFORM": "arm64"}), \
             patch.object(VOICE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            VOICE.run_build(["cmake", "-G", "Unix Makefiles"])
        self.assertNotIn("CMAKE_GENERATOR", run.call_args.kwargs["env"])
        self.assertNotIn("CMAKE_GENERATOR_PLATFORM", run.call_args.kwargs["env"])
        self.assertEqual(VOICE.build_options()[:2], ["-G", "Unix Makefiles"])

    def test_voice_intel_baseline_disables_unsupported_native_instructions(self):
        with patch.object(VOICE.platform, "machine", return_value="x86_64"):
            options = VOICE.build_options()
        for instruction in ("NATIVE", "SSE42", "AVX", "AVX2", "BMI2", "FMA", "F16C"):
            self.assertIn("-DGGML_" + instruction + "=OFF", options)

    def test_voice_another_preparation_owns_the_lock(self):
        directory = self.root / "cache"
        directory.mkdir()
        with (directory / "preparazione.lock").open("a+") as lock:
            VOICE.fcntl.flock(lock, VOICE.fcntl.LOCK_EX | VOICE.fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, "altra istanza"):
                VOICE.prepare(directory, "small", self.manifest, check=True)


    def test_voice_managed_metadata_does_not_follow_user_symlinks(self):
        directory = self.root / "cache"
        directory.mkdir()
        original = self.root / "personale.txt"
        original.write_text("conservare")
        (directory / "Whisper-MIT.txt").symlink_to(original)
        with self.assertRaisesRegex(ValueError, "non regolare"):
            VOICE.prepare(directory, "small", self.manifest, check=True)
        self.assertEqual(original.read_text(), "conservare")

    def test_voice_partial_directory_is_never_moved_or_overwritten(self):
        partial = self.target.with_suffix(".bin.part")
        partial.mkdir()
        with self.assertRaisesRegex(ValueError, "non regolare"):
            VOICE.download(self.model, self.target, lambda *_args, **_kwargs: self.fail("Rete inutile"))
        self.assertTrue(partial.is_dir())


if __name__ == "__main__":
    unittest.main()
