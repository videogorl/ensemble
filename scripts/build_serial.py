#!/usr/bin/env python3
"""Run xcodebuild with a shared per-user lock and bounded parallelism.

Usage: python3 scripts/build_serial.py <xcodebuild arguments>
All worktrees share the lock. Direct xcodebuild/MCP builds bypass it.
"""

import fcntl
from pathlib import Path
import signal
import subprocess
import sys


def main():
    if len(sys.argv) == 1:
        print(__doc__.strip())
        return 2
    if "-jobs" in sys.argv[1:]:
        print("Build parallelism is capped at two jobs; omit -jobs.", file=sys.stderr)
        return 2
    directory = Path.home() / "Library" / "Caches" / "Ensemble"
    directory.mkdir(parents=True, exist_ok=True)
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupt)
    with (directory / "build.lock").open("a") as lock:
        print("Waiting for the shared Ensemble build lock…", file=sys.stderr, flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print("Build lock acquired; running xcodebuild with two jobs.", file=sys.stderr, flush=True)
        with subprocess.Popen(["xcodebuild", "-jobs", "2", *sys.argv[1:]]) as process:
            try:
                return process.wait()
            except KeyboardInterrupt:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                return 130


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
