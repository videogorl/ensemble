#!/usr/bin/env python3
"""Records references and transitions for a list of pairs, skipping what already exists.

  batch.py <data-dir> <pairs.tsv> [--style N]

pairs.tsv has one "id-a<TAB>id-b" per line (library persistent IDs). References are recorded with
transitions off, then every pair with transitions on in style N (Music's TransitionStyle value;
default leaves the current one). Music is relaunched to apply each setting, and the settings found
at the start are restored at the end.
"""
import argparse, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))

def defaults(key, value=None):
    if value is None:
        return subprocess.run(["defaults", "read", "com.apple.Music", key], capture_output=True, text=True).stdout.strip()
    subprocess.run(["defaults", "write", "com.apple.Music", key, "-int", str(value)], check=True)

def relaunch(enabled, style):
    subprocess.run(["osascript", "-e", 'tell application "Music" to quit'])
    time.sleep(3)
    defaults("TransitionsEnabled", enabled)
    if style is not None:
        defaults("TransitionStyle", style)
    subprocess.run(["osascript", "-e", 'tell application "Music"\nlaunch\ndelay 5\nend tell'])

def capture(*arguments):
    for attempt in range(2):
        done = subprocess.run([sys.executable, os.path.join(HERE, "capture.py"), *arguments], capture_output=True, text=True)
        print((done.stdout + done.stderr).strip(), flush=True)
        if done.returncode == 0:
            return True
    return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data"); parser.add_argument("pairs"); parser.add_argument("--style", type=int)
    args = parser.parse_args()
    pairs = [line.split()[:2] for line in open(args.pairs) if line.strip() and not line.startswith("#")]
    original = (defaults("TransitionsEnabled"), defaults("TransitionStyle"))
    refs, mixes = os.path.join(args.data, "refs"), os.path.join(args.data, f"style{args.style if args.style is not None else original[1]}")
    os.makedirs(refs, exist_ok=True); os.makedirs(mixes, exist_ok=True)
    try:
        todo = [("tail", a, "160") for a in dict.fromkeys(p[0] for p in pairs)] + [("head", b, "130") for b in dict.fromkeys(p[1] for p in pairs)]
        todo = [item for item in todo if not os.path.exists(os.path.join(refs, f"{item[1]}_{item[0]}.json"))]
        if todo:
            relaunch(0, None)
            for mode, ident, seconds in todo:
                capture(mode, os.path.join(refs, f"{ident}_{mode}"), ident, "--seconds", seconds)
        wanted = [p for p in pairs if not os.path.exists(os.path.join(mixes, f"{p[0]}_{p[1]}.json"))]
        if wanted:
            relaunch(1, args.style)
            for a, b in wanted:
                capture("pair", os.path.join(mixes, f"{a}_{b}"), a, b, "--lead", "150", "--tail", "70")
    finally:
        relaunch(original[0] or 1, original[1] or None)
        subprocess.run(["osascript", "-e", 'tell application "Music" to if exists user playlist "zz AutoMix Lab run" then delete user playlist "zz AutoMix Lab run"'])

if __name__ == "__main__":
    main()
