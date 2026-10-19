#!/usr/bin/env python3
"""Build/install/launch an exact Ensemble target, then collect reusable evidence."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.videogorl.ensemble"
SURFACES = ("home", "songs", "artists", "albums", "genres", "playlists",
            "favorites", "search", "downloads", "settings", "profile",
            "profile-storage", "add-source")


def run(*args, output=None, timeout=120, stream_output=False):
    if stream_output:
        with Path(output).open("w") as file:
            result = subprocess.run(args, cwd=ROOT, stdout=file,
                                    stderr=subprocess.STDOUT, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed ({result.returncode}). See {output}")
        return ""
    result = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    if output:
        Path(output).write_text(result.stdout)
    if result.returncode:
        detail = f"See {output}" if output else result.stdout[-2000:]
        raise RuntimeError(f"{args[0]} failed ({result.returncode}). {detail}")
    return result.stdout.strip()


def device_command(state, name, *args):
    path = Path(state["run_dir"]) / f"{name}.json"
    run("xcrun", "devicectl", *args[:3], "--device", state["udid"],
        "--timeout", "60", "--json-output", str(path),
        *args[3:],
        output=path.with_suffix(".txt"))
    return json.loads(path.read_text())["result"]


def objects(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from objects(item)
    elif isinstance(value, list):
        for item in value:
            yield from objects(item)


def simulator(udid):
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))
    for runtime, entries in devices["devices"].items():
        for entry in entries:
            if entry["udid"].lower() == udid.lower():
                return {**entry, "runtime": runtime}
    raise RuntimeError(f"Available simulator UUID not found: {udid}")


def save(state):
    (Path(state["run_dir"]) / "run.json").write_text(json.dumps(state, indent=2) + "\n")


def fingerprint(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_process(state):
    if state["platform"] == "simulator":
        executable = run("ps", "-p", str(state["pid"]), "-o", "comm=")
        if Path(executable).resolve() != Path(state["installed_executable"]).resolve():
            raise RuntimeError(f"PID {state['pid']} is not the installed Ensemble executable")
        if fingerprint(Path(executable)) != state["executable_sha256"]:
            raise RuntimeError("Running executable differs from the built artifact")
        return {"pid": state["pid"], "executable": executable}
    result = device_command(state, "processes", "device", "info", "processes")
    matches = [item for item in objects(result)
               if item.get("processIdentifier") == state["pid"]]
    if len(matches) != 1 or "Ensemble.app/Ensemble" not in str(matches[0].get("executable", "")):
        raise RuntimeError("Launched Ensemble PID/executable not present in device process evidence")
    return matches[0]


def prepare(args):
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})", args.udid):
        raise RuntimeError("Supply an exact simulator UUID or physical UDID, never a name or 'booted'")
    directory = Path(args.run_dir).resolve() if args.run_dir else Path(tempfile.mkdtemp(prefix="ensemble-runtime-"))
    if args.run_dir:
        directory.mkdir(parents=True, exist_ok=False)
    state = {"run_dir": str(directory), "platform": args.platform, "udid": args.udid,
             "source_commit": run("git", "rev-parse", "HEAD"),
             "source_status": run("git", "status", "--short"),
             "surface": args.surface, "prepared": False}
    save(state)
    print(f"Run: {directory}", flush=True)
    if args.platform == "simulator":
        state["device"] = simulator(args.udid)
        save(state)
        if state["device"]["state"] == "Shutdown":
            run("xcrun", "simctl", "boot", args.udid)
        run("xcrun", "simctl", "bootstatus", args.udid, "-b", timeout=300)
    else:
        state["device"] = device_command(state, "device", "device", "info", "details")
        save(state)
    derived = directory / "DerivedData"
    destination = f"platform=iOS Simulator,id={args.udid}" if args.platform == "simulator" else f"id={args.udid}"
    print("Building Ensemble.xcworkspace; full output goes to build.log", flush=True)
    run(sys.executable, str(ROOT / "scripts" / "build_serial.py"),
        "-workspace", "Ensemble.xcworkspace", "-scheme", "Ensemble",
        "-configuration", "Debug", "-destination", destination,
        "-derivedDataPath", str(derived), "build", output=directory / "build.log",
        timeout=1800, stream_output=True)
    suffix = "iphonesimulator" if args.platform == "simulator" else "iphoneos"
    app = derived / "Build" / "Products" / f"Debug-{suffix}" / "Ensemble.app"
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info["CFBundleIdentifier"] != BUNDLE:
        raise RuntimeError("Built artifact has an unexpected bundle identifier")
    state.update(app=str(app), version=info["CFBundleShortVersionString"],
                 build=info["CFBundleVersion"],
                 executable_sha256=fingerprint(app / info["CFBundleExecutable"]))
    launch_args = ["-EnsembleAutomationMode", "YES", "-EnsembleAutomationStartSurface", args.surface]
    if args.disable_animations:
        launch_args += ["-EnsembleAutomationDisableAnimations", "YES"]
    # Explicit NO overrides automation defaults left behind by previous runs.
    else:
        launch_args += ["-EnsembleAutomationDisableAnimations", "NO"]
    save(state)
    if args.platform == "simulator":
        run("xcrun", "simctl", "install", args.udid, str(app), output=directory / "install.txt")
        installed = Path(run("xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "app"))
        state["installed_executable"] = str(installed / info["CFBundleExecutable"])
        if fingerprint(Path(state["installed_executable"])) != state["executable_sha256"]:
            raise RuntimeError("Installed simulator executable differs from built executable")
        state["launched_at"] = datetime.now(timezone.utc).isoformat()
        launch = run("xcrun", "simctl", "launch", "--terminate-running-process", args.udid,
                     BUNDLE, *launch_args, output=directory / "launch.txt")
        state["pid"] = int(launch.rsplit(":", 1)[1].strip())
    else:
        installed = device_command(state, "install", "device", "install", "app", str(app))
        # Recent devicectl versions report "unknown"; the installed build version
        # check below and the launched PID's executable still prove identity.
        identifiers = [item["launchServicesIdentifier"] for item in objects(installed)
                       if item.get("launchServicesIdentifier") not in (None, "", "unknown")]
        if len(identifiers) > 1:
            raise RuntimeError("Fresh installation reported several launch services identifiers")
        apps = device_command(state, "apps", "device", "info", "apps", "--bundle-id", BUNDLE)
        matches = [item for item in objects(apps) if item.get("bundleIdentifier") == BUNDLE]
        if len(matches) != 1 or str(matches[0].get("bundleVersion")) != str(state["build"]):
            raise RuntimeError("Installed device build version does not match built artifact")
        state["installed_app"] = matches[0]
        state["launched_at"] = datetime.now(timezone.utc).isoformat()
        persistent = ["--launch-persistent-identifier", identifiers[0]] if identifiers else []
        launch = device_command(state, "launch", "device", "process", "launch",
                                "--terminate-existing", *persistent, "--", BUNDLE, *launch_args)
        state["pid"] = launch["process"]["processIdentifier"]
    state["process"] = verify_process(state)
    state["prepared"] = True
    save(state)
    collect(state)
    print("Prepared and captured. Inspect the UI and exercise the requested behavior before claiming a pass.")
    if args.platform == "device":
        print("Finish through Device Hub with playback paused and the phone locked; verify lock state independently.")


def collect(state):
    if not state["prepared"]:
        raise RuntimeError("Preparation did not complete; inspect build/install/launch evidence first")
    state["process"] = verify_process(state)
    directory = Path(state["run_dir"]) / datetime.now().strftime("capture-%Y%m%d-%H%M%S-%f")
    directory.mkdir()
    if state["platform"] == "simulator":
        run("xcrun", "simctl", "io", state["udid"], "screenshot", str(directory / "screen.png"))
        run("xcrun", "simctl", "spawn", state["udid"], "log", "show", "--last", "2m",
            "--style", "compact", "--predicate", 'process == "Ensemble"',
            output=directory / "os-log.txt")
        container = Path(run("xcrun", "simctl", "get_app_container", state["udid"], BUNDLE, "data"))
        logs = container / "Library" / "Application Support" / "Ensemble" / "Logs"
        launched = datetime.fromisoformat(state["launched_at"]).timestamp()
        candidates = [path for path in logs.glob("session-*.log")
                      if path.stat().st_mtime >= launched]
        if candidates:
            shutil.copy2(max(candidates, key=lambda path: path.stat().st_mtime), directory / "persistent-session.log")
        else:
            (directory / "persistent-session-unavailable.txt").write_text("No session log modified since this launch.\n")
    else:
        device_command(state, "lock-state", "device", "info", "lockState")
        for name in ("processes.json", "lock-state.json"):
            shutil.copy2(Path(state["run_dir"]) / name, directory / name)
        run("xcrun", "devicectl", "device", "copy", "from", "--device", state["udid"],
            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
            "--source", "Library/Application Support/Ensemble/Logs",
            "--destination", str(directory / "session-logs"), "--timeout", "60",
            output=directory / "copy-logs.txt")
    (directory / "identity.json").write_text(json.dumps({
        "udid": state["udid"], "version": state["version"], "build": state["build"],
        "executable_sha256": state["executable_sha256"], "process": state["process"],
        "launched_at": state["launched_at"],
    }, indent=2) + "\n")
    state["last_capture"] = str(directory)
    save(state)
    print(f"Evidence: {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare", help="Build, install, relaunch, verify identity, and capture")
    prep.add_argument("--platform", choices=("simulator", "device"), required=True)
    prep.add_argument("--udid", required=True)
    prep.add_argument("--surface", choices=SURFACES, required=True)
    prep.add_argument("--run-dir", help="New directory; defaults to a unique temporary directory")
    prep.add_argument("--disable-animations", action="store_true")
    for command in ("collect", "shutdown"):
        child = commands.add_parser(command, help="Capture current evidence" if command == "collect" else "Shut down only this run's simulator")
        child.add_argument("--run-dir", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
        return
    state = json.loads((Path(args.run_dir) / "run.json").read_text())
    if args.command == "collect":
        collect(state)
    else:
        if state["platform"] != "simulator":
            raise RuntimeError("Physical phones must be paused and locked through Device Hub")
        if simulator(state["udid"])["state"] != "Shutdown":
            run("xcrun", "simctl", "shutdown", state["udid"])
        if simulator(state["udid"])["state"] != "Shutdown":
            raise RuntimeError("Simulator shutdown was not confirmed")
        state["shutdown_confirmed"] = True
        save(state)
        print(f"Shutdown confirmed: {state['udid']}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        sys.exit(f"Runtime preparation failed: {error}")
