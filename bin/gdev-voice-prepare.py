#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepara gli strumenti e un modello locale verificato per Voce GDev."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def valid(path, model):
    return (path.is_file() and not path.is_symlink()
            and path.stat().st_size == model["size"]
            and digest(path) == model["sha256"])


def download(model, destination, opener=urllib.request.urlopen):
    """Riprendi i byte parziali; pubblica solo dopo dimensione e SHA-256."""
    partial = destination.with_suffix(destination.suffix + ".part")
    if destination.is_symlink() or partial.is_symlink():
        raise ValueError("Collegamento del modello conservato: scegli una cache locale regolare")
    if any(path.exists() and not path.is_file() for path in (destination, partial)):
        raise ValueError("Il percorso del modello contiene un elemento non regolare: conservato")
    if valid(destination, model):
        return destination
    if destination.exists():
        preserved = destination.with_name(destination.name + ".conservato-" + str(time.time_ns()))
        destination.rename(preserved)
        print("Modello non valido conservato in " + str(preserved), file=sys.stderr, flush=True)
    if valid(partial, model):
        partial.replace(destination)
        return destination
    url = ("https://huggingface.co/" + model["repository"] + "/resolve/"
           + model["revision"] + "/" + model["file"])
    for attempt in range(2):
        offset = partial.stat().st_size if partial.exists() else 0
        if offset >= model["size"]:
            partial.unlink()
            offset = 0
        request = urllib.request.Request(url, headers={"Range": "bytes=%d-" % offset} if offset else {})
        print("Scarico il modello italiano multilingue (%.0f MB); ripresa da %.0f MB"
              % (model["size"] / 1000000, offset / 1000000), file=sys.stderr, flush=True)
        with opener(request, timeout=45) as response:
            append = offset and response.status == 206
            if append and not response.headers.get("Content-Range", "").startswith("bytes %d-" % offset):
                raise ValueError("Il server non ha confermato il punto di ripresa")
            total = offset if append else 0
            with partial.open("ab" if append else "wb") as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > model["size"]:
                        raise ValueError("Il download supera la dimensione del modello dichiarata")
                    output.write(chunk)
        if valid(partial, model):
            partial.replace(destination)
            return destination
        # Il file .part appartiene a questo download e non è mai stato pubblicato.
        partial.unlink(missing_ok=True)
    raise ValueError("Dimensione o SHA-256 del modello non corrispondono: download non pubblicato")


def read_catalog(manifest, model_name):
    catalog = json.loads(manifest.read_text(encoding="utf-8"))
    if catalog.get("version") != 2 or model_name not in catalog.get("models", {}):
        raise ValueError("Modello non presente nel catalogo verificato")
    model, engine = catalog["models"][model_name], catalog.get("engine", {})
    if (not model["file"] or model["file"] in (".", "..")
            or Path(model["file"]).name != model["file"] or model["license"] != "MIT"):
        raise ValueError("Manifesto del modello non valido")
    if (engine.get("kind") != "whisper.cpp" or engine.get("license") != "MIT"
            or not re.fullmatch(r"[0-9a-f]{40}", engine.get("revision", ""))
            or not engine.get("repository", "").startswith("https://github.com/")):
        raise ValueError("Origine o revisione del fork whisper.cpp non valida")
    return engine, model


def build_options():
    options = ["-G", "Unix Makefiles", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DWHISPER_BUILD_TESTS=OFF",
               "-DWHISPER_BUILD_EXAMPLES=ON", "-DWHISPER_BUILD_SERVER=ON", "-DGGML_OPENMP=OFF",
               "-DGGML_NATIVE=OFF"]
    if platform.machine().lower() in ("x86_64", "amd64", "i386", "i686"):
        options.extend("-DGGML_" + instruction + "=OFF" for instruction in ("SSE42", "AVX", "AVX2", "BMI2", "FMA", "F16C"))
    metal = blas = False
    if sys.platform == "darwin":
        numbers = platform.mac_ver()[0].split(".")
        version = tuple(int(part) for part in numbers[:2]) if numbers[0] else (0, 0)
        version += (0,) * (2 - len(version))
        metal, blas = version >= (12, 0), version >= (13, 3)
        options.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0")
    return options + ["-DGGML_METAL=" + ("ON" if metal else "OFF"),
                      "-DGGML_BLAS=" + ("ON" if blas else "OFF")]


def build_identity():
    return dict(platform=sys.platform, architecture=platform.machine(), options=build_options())


def publish_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def runtime_valid(directory, record, engine):
    if (not isinstance(record, dict) or any(not isinstance(record.get(name), str)
            for name in ("runtime", "binary", "binary_sha256", "source_revision", "source_repository"))):
        return False
    runtime = Path(record["runtime"])
    binary = Path(record["binary"])
    return (record.get("engine") == engine and record.get("build") == build_identity()
            and record.get("source_revision") == engine["revision"]
            and record.get("source_repository") == engine["repository"]
            and runtime.parent.resolve() == directory.resolve() and runtime.name.startswith("motore-")
            and not runtime.is_symlink() and binary == runtime / "build/bin/whisper-server"
            and binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK)
            and digest(binary) == record.get("binary_sha256"))


def run_build(command):
    environment = dict(os.environ)
    if command[0] == "cmake":
        for name in ("CMAKE_GENERATOR", "CMAKE_GENERATOR_PLATFORM", "CMAKE_GENERATOR_TOOLSET", "CMAKE_GENERATOR_INSTANCE"):
            environment.pop(name, None)
    return subprocess.run(command, check=True, stdout=sys.stderr, stderr=sys.stderr, env=environment)


def prepare_runtime(directory, engine, install, check):
    record_path = directory / "motore.json"
    if record_path.is_file():
        try:
            previous = json.loads(record_path.read_text(encoding="utf-8"))
            if not isinstance(previous, dict):
                raise ValueError("Riscontro non strutturato")
        except ValueError as error:
            if check or not install:
                raise RuntimeError("Riscontro del motore non valido: scegli Attiva riconoscimento locale") from error
            record_path.rename(record_path.with_name(record_path.name + ".conservato-" + str(time.time_ns())))
            previous = {}
        if runtime_valid(directory, previous, engine):
            return previous
    if check or not install:
        raise RuntimeError("Motore del fork whisper.cpp assente o diverso: scegli Attiva riconoscimento locale")
    def missing_build_tools():
        return ([tool for tool in ("git", "cmake") if not shutil.which(tool)]
                + ([] if shutil.which("make") or shutil.which("gmake") else ["make"]))
    missing = missing_build_tools()
    if missing and sys.platform == "darwin" and shutil.which("brew"):
        run_build(["brew", "install", *missing])
        missing = missing_build_tools()
    if missing:
        raise RuntimeError("Per compilare il tuo fork installa " + ", ".join(missing))
    runtime = Path(tempfile.mkdtemp(prefix="motore-" + engine["revision"][:12] + "-", dir=directory))
    source, build = runtime / "sorgenti", runtime / "build"
    try:
        print("Compilo il tuo fork " + engine["repository"] + " @ " + engine["revision"], file=sys.stderr, flush=True)
        run_build(["git", "init", str(source)])
        run_build(["git", "-C", str(source), "remote", "add", "origin", engine["repository"]])
        run_build(["git", "-C", str(source), "fetch", "--depth", "1", "origin", engine["revision"]])
        run_build(["git", "-C", str(source), "checkout", "--detach", "FETCH_HEAD"])
        def git_read(*arguments):
            return subprocess.run(["git", "-C", str(source), *arguments], check=True,
                                  capture_output=True, text=True).stdout.strip()
        revision = git_read("rev-parse", "HEAD")
        repository = git_read("remote", "get-url", "origin")
        if revision != engine["revision"] or repository != engine["repository"] or git_read("status", "--porcelain"):
            raise RuntimeError("Sorgenti del fork non corrispondenti alla revisione fissata")
        identity = build_identity()
        run_build(["cmake", "-S", str(source), "-B", str(build), *identity["options"]])
        jobs = max(1, min(4, os.cpu_count() or 2))
        run_build(["cmake", "--build", str(build), "--config", "Release", "--target", "whisper-server",
                   "--parallel", str(jobs)])
        binary = build / "bin/whisper-server"
        if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
            raise RuntimeError("Il fork non ha prodotto whisper-server eseguibile")
        result = subprocess.run([str(binary), "--help"], check=True, capture_output=True, text=True)
        help_text = result.stdout + result.stderr
        if any(option not in help_text for option in ("--model", "--language", "--host", "--port", "--inference-path", "--prompt")):
            raise RuntimeError("Il server del fork non offre il contratto richiesto dalla voce GDev")
        record = dict(runtime=str(runtime), binary=str(binary), binary_sha256=digest(binary), engine=dict(engine),
                      source_revision=revision, source_repository=repository, build=identity)
        publish_json(record_path, record)
        return record
    except BaseException:
        shutil.rmtree(runtime)
        raise


def missing_tools():
    missing = [name for name in ("curl",) if not shutil.which(name)]
    if not (shutil.which("sox") or shutil.which("ffmpeg")):
        missing.append("registratore")
    return missing


def prepare(directory, model_name, manifest, install=True, check=False):
    engine, model = read_catalog(manifest, model_name)
    if check and not directory.is_dir():
        raise ValueError("Modello facoltativo assente: scegli Attiva riconoscimento locale")
    if not check:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name in ("preparazione.lock", "Whisper-MIT.txt", "installazione.json", "installazione.json.tmp",
                 "motore.json", "motore.json.tmp"):
        path = directory / name
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError("File gestito non regolare conservato: " + str(path))
    lock_path = directory / "preparazione.lock"
    if check and not lock_path.exists():
        raise RuntimeError("Preparazione facoltativa assente: scegli Attiva riconoscimento locale")
    with lock_path.open("r" if check else "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("La preparazione della voce è già in corso in un'altra istanza")
        missing = missing_tools()
        if missing and install and not check and sys.platform == "darwin" and shutil.which("brew"):
            packages = ["sox" if name == "registratore" else name for name in missing]
            run_build(["brew", "install", *packages])
            missing = missing_tools()
        if missing:
            raise RuntimeError("Strumenti mancanti: " + ", ".join(missing) + ". Scegli Attiva riconoscimento locale")
        target = directory / model["file"]
        if check and not valid(target, model):
            raise ValueError("Modello facoltativo assente o non valido: scegli Attiva riconoscimento locale")
        runtime = prepare_runtime(directory, engine, install, check)
        result = {"schema_version": 2, "ok": True, "model": str(target.resolve()), "model_name": model_name,
                  "sha256": model["sha256"], "license": model["license"], "revision": model["revision"],
                  "engine": dict(engine), "runtime": runtime, "recognizer": runtime["binary"],
                  "recorder": shutil.which("sox") or shutil.which("ffmpeg"), "transport": shutil.which("curl")}
        if check:
            receipt = directory / "installazione.json"
            if not receipt.is_file():
                raise RuntimeError("Installazione facoltativa assente: scegli Attiva riconoscimento locale")
            previous = json.loads(receipt.read_text(encoding="utf-8"))
            if (not isinstance(previous, dict) or previous.get("schema_version") != 2 or previous.get("ok") is not True
                    or any(previous.get(key) != result[key] for key in
                           ("engine", "recognizer", "model", "sha256", "runtime", "recorder", "transport"))):
                raise RuntimeError("Installazione del tuo fork da aggiornare: scegli Attiva riconoscimento locale")
            return result
        download(model, target)
        license_source = (manifest.parent / model["license_file"]).resolve()
        shutil.copyfile(license_source, directory / "Whisper-MIT.txt")
        publish_json(directory / "installazione.json", result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--check", action="store_true", help="Verifica senza installare o scaricare")
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("gdev-voice-models.json"))
    args = parser.parse_args()
    try:
        result = prepare(args.directory.expanduser().resolve(), args.model, args.manifest.resolve(),
                         install=not args.check, check=args.check)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"schema_version": 2, "ok": False, "error": str(error)}, ensure_ascii=False), flush=True)
        return 1
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
