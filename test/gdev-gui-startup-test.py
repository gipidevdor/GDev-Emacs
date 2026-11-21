#!/usr/bin/env python3
"""Prova l'ingresso grafico macOS e il nucleo nativo in una nuova istanza.

Preparare prima `gdev compile --native -w` con la cartella di stato indicata
da --build-state. --require rende l'assenza di una sessione Aqua un errore;
senza questa opzione una macchina senza GUI registra esplicitamente SKIPPED.
Prova sia bin/gdev emacs sia l'icona Emacs ordinaria, senza --init-directory,
dopo aver predisposto l'ingresso con configurazioni personali in conflitto.
Log e riscontri rimangono in --output, mentre stato e profilo vengono rimossi.
"""

# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def positive_timeout(value):
    timeout = float(value)
    if not math.isfinite(timeout) or timeout <= 0:
        raise argparse.ArgumentTypeError("Il timeout deve essere positivo e finito")
    return timeout


def aqua_session():
    """Controlla il dominio della persona corrente, senza leggerne l'ambiente."""
    if sys.platform != "darwin":
        return False, "La prova richiede macOS e una sessione Aqua"
    try:
        result = subprocess.run(
            ["/bin/launchctl", "print", f"gui/{os.getuid()}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"Sessione Aqua non verificabile: {error}"
    if result.returncode:
        return False, "Sessione Aqua assente: " + result.stderr.strip()
    return True, None


def copy_build_cache(build_state, state):
    """Copia soltanto librerie, senza seguire cartelle o link ricorsivi."""
    native_cache = build_state / "eln-cache"
    native_files = [path for path in native_cache.rglob("*.eln") if path.is_file()]
    if not native_files:
        raise RuntimeError("Cache nativa assente: esegui prima gdev compile --native -w")
    for source in native_files:
        target = state / "eln-cache" / source.relative_to(native_cache)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    grammars = build_state / "tree-sitter"
    if grammars.is_dir():
        for source in grammars.iterdir():
            if source.suffix in {".dylib", ".so", ".dll"} and source.is_file():
                target = state / "tree-sitter" / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    return len(native_files)


def validate_receipts(output, process, token, state, private):
    """Richiede i due riscontri della stessa istanza e i percorsi isolati."""
    startup = json.loads((output / "result.json").read_text())
    gui = json.loads((output / "gui-result.json").read_text())
    if (output / "status").read_text().strip() != "ready" or startup.get("ok") is not True:
        raise RuntimeError("Avvio GDev incompleto: " + str(startup.get("reason")))
    if startup.get("pid") != process.pid or gui.get("pid") != process.pid or gui.get("token") != token:
        raise RuntimeError("Il riscontro non appartiene all'istanza avviata dalla prova")
    if Path(startup.get("root", "")).resolve() != ROOT or Path(startup.get("private", "")).resolve() != private:
        raise RuntimeError("L'avvio ha caricato un checkout o un profilo diverso da quello richiesto")
    if Path(gui.get("state", "")).resolve() != state or Path(gui.get("private", "")).resolve() != private:
        raise RuntimeError("La finestra non usa le cartelle isolate della prova")
    if not all(gui.get(key) is True for key in ("ok", "graphical", "visible", "native")) or gui.get("window_system") != "ns":
        raise RuntimeError("Verifica GUI non riuscita: " + str(gui.get("reason")))
    if not startup.get("graphical") or not startup.get("workbench"):
        raise RuntimeError("Il riscontro dell'avvio non conferma finestra e Workbench")
    return startup, gui


def stop_instance(process):
    """Termina esclusivamente il processo creato, senza cercare altre istanze."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def macos_app_executable(executable):
    """Usa l'ingresso dichiarato dall'app, non un binario interno d'architettura."""
    for app in Path(executable).parents:
        if app.suffix == ".app":
            with (app / "Contents/Info.plist").open("rb") as metadata:
                name = plistlib.load(metadata)["CFBundleExecutable"]
            if not isinstance(name, str) or Path(name).name != name:
                raise RuntimeError("CFBundleExecutable non valido nell'app Emacs")
            launcher = app / "Contents/MacOS" / name
            if not launcher.is_file():
                raise RuntimeError("Ingresso dichiarato dall'app Emacs assente")
            return str(launcher)
    return executable


def prepare_standard_entry(directory, env, output, timeout):
    """Installa l'ingresso condiviso in una HOME di prova con precedenze reali."""
    home_directory = directory / "home con spazi è"
    env["HOME"] = str(home_directory)
    env["XDG_CONFIG_HOME"] = str(home_directory / ".config")
    originals = {name: f';; originale {name}\n(error "Configurazione originale oscurante")\n'
                 for name in (".emacs", ".emacs.el", ".emacs.elc", ".emacs.d/init.el", ".emacs.d/early-init.el")}
    for name, text in originals.items():
        target = home_directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    xdg = home_directory / ".config/emacs/init.el"
    xdg.parent.mkdir(parents=True)
    xdg.write_text(';; configurazione XDG da conservare\n(error "XDG originale")\n')
    receipt = output / "installation.json"
    form = """(progn
      (require 'gdev-install)
      (let ((result (gdev-install-standard-entry %s))
            (coding-system-for-write 'utf-8-unix))
        (with-temp-file %s
          (insert (json-serialize
            (list :entry (plist-get result :entry) :backup (plist-get result :backup)
                  :executable (expand-file-name invocation-name invocation-directory)
                  :environment (vconcat gdev-install-launcher-environment)))))))""" % (
        json.dumps(str(home_directory)), json.dumps(str(receipt)))
    # Usa il selettore dell'eseguibile di bin/gdev per preparare l'ingresso;
    # il successivo avvio grafico userà direttamente quell'Emacs, senza opzioni init.
    with (output / "installation.log").open("w") as log:
        subprocess.run([str(ROOT / "bin/gdev"), "emacs", "--batch", "-Q",
                        "-l", str(ROOT / "early-init.el"), "--eval", form],
                       cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=log,
                       stderr=subprocess.STDOUT, timeout=timeout, check=True)
    installed = json.loads(receipt.read_text())
    backup = Path(installed["backup"])
    for name, text in originals.items():
        if (backup / name).read_text() != text:
            raise RuntimeError("Configurazione originale non conservata: " + name)
    if not (backup / "ripristino.eld").is_file() or xdg.read_text() != ';; configurazione XDG da conservare\n(error "XDG originale")\n':
        raise RuntimeError("Manifest di ripristino o configurazione XDG non conservati")
    # Il Dock non eredita le opzioni della shell d'installazione. L'elenco
    # viene dall'installatore, così la prova non ne mantiene una seconda copia.
    for name in installed["environment"]:
        env.pop(name, None)
    installed["app_executable"] = macos_app_executable(installed["executable"])
    receipt.write_text(json.dumps(installed, ensure_ascii=False, indent=2) + "\n")
    return installed["app_executable"], home_directory / ".emacs.d"


def run(args, output, entry="explicit"):
    available, reason = aqua_session()
    if not available:
        return {"status": "FAILED" if args.require else "SKIPPED", "reason": reason}
    with tempfile.TemporaryDirectory(prefix="gdev-gui-session-") as temporary:
        directory = Path(temporary).resolve()
        token = uuid.uuid4().hex
        profile = "gui-" + token[:12]
        state = directory / "state/profiles" / profile
        private = directory / "user/profiles" / profile
        state.mkdir(parents=True)
        (private / "snippets").mkdir(parents=True)
        native_count = copy_build_cache(args.build_state.resolve(), state)
        # Il profilo univoco isola anche nome e socket del server Emacs.
        env = dict(os.environ, GDEV_PROFILE=profile,
                   GDEV_STATE_DIR=str(directory / "state"),
                   GDEV_USER_DIR=str(directory / "user"),
                   GDEV_TOOLS_DIR=str(directory / "tools"),
                   GDEV_APPLICATIONS_DIR=str(directory / "Applications"),
                   GDEV_STARTUP_CHECK_DIR=str(output),
                   GDEV_STARTUP_REQUIRE_WORKBENCH="1", GDEV_STARTUP_REQUIRE_GRAPHICAL="1",
                   GDEV_GUI_TEST_TOKEN=token)
        env.pop("GDEV_DEBUG", None)
        startup_directory = None
        if entry == "standard":
            executable, startup_directory = prepare_standard_entry(directory, env, output, args.timeout)
            command = [executable]
        else:
            command = [str(ROOT / "bin/gdev"), "emacs"]
        command += ["--no-splash",
                   "--eval", "(setq native-comp-jit-compilation nil)",
                   "--load", str(ROOT / "test/gdev-gui-startup-check.el")]
        process = None
        try:
            with (output / "emacs.log").open("w") as log:
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                (output / "launch.json").write_text(json.dumps(
                    dict(pid=process.pid, command=command, entry=entry,
                         expected_state=str(state), expected_private=str(private)), indent=2) + "\n")
                deadline = time.monotonic() + args.timeout
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"Timeout di {args.timeout:g} secondi in attesa della finestra e dei riscontri")
                    time.sleep(0.1)
                if process.returncode != 0:
                    raise RuntimeError(f"Emacs è terminato con stato {process.returncode}; consulta emacs.log e i riscontri")
                startup, gui = validate_receipts(output, process, token, state, private)
                if startup_directory is not None:
                    for key, name in (("early_init_file", "early-init.el"), ("user_init_file", "init.el")):
                        if Path(gui.get(key, "")).resolve() != startup_directory / name:
                            raise RuntimeError("Emacs non ha scelto l'ingresso ordinario nella HOME di prova: " + key)
                return {"status": "PASSED", "startup": startup, "gui": gui,
                        "copied_native_files": native_count, "entry": entry}
        finally:
            if process is not None:
                stop_instance(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-state", type=Path, required=True,
                        help="Cartella di stato già compilata con --native")
    parser.add_argument("--output", type=Path, required=True,
                        help="Cartella in cui conservare log e riscontri")
    parser.add_argument("--timeout", type=positive_timeout, default=60)
    parser.add_argument("--require", action="store_true", help="Fallisci se la sessione Aqua non è disponibile")
    parser.add_argument("--entry", choices=("both", "explicit", "standard"), default="both",
                        help="Ingresso da provare; per impostazione predefinita entrambi")
    args = parser.parse_args()
    output = args.output.resolve()
    # Una cartella per esecuzione conserva anche le prove precedenti.
    output.mkdir(parents=True, exist_ok=True)
    output = output / ("run-" + uuid.uuid4().hex[:12])
    output.mkdir(mode=0o700)
    start = time.monotonic()
    runs = []
    for entry in (("explicit", "standard") if args.entry == "both" else (args.entry,)):
        evidence = output / entry
        evidence.mkdir(mode=0o700)
        try:
            result = run(args, evidence, entry)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            result = {"status": "FAILED", "reason": str(error)}
        result.update(entry=entry, evidence=str(evidence))
        runs.append(result)
    status = "FAILED" if any(result["status"] == "FAILED" for result in runs) else (
        "SKIPPED" if all(result["status"] == "SKIPPED" for result in runs) else "PASSED")
    report = {"status": status, "runs": runs}
    report.update(schema_version=1, seconds=round(time.monotonic() - start, 3), evidence=str(output))
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    return 1 if report["status"] == "FAILED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
