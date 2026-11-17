#!/usr/bin/env python3
"""Plays a stretch of a Music.app playlist while recording Music's output through AutoMixTap.

  capture.py pair <out-prefix> <id-a> <id-b> [--lead 50] [--tail 60]
      Starts A <lead> seconds before its end and records until <tail> seconds into B.
  capture.py head <out-prefix> <id> [--seconds 70]
  capture.py tail <out-prefix> <id> [--seconds 70]
      Reference recordings of one track's start or end.

Tracks are library persistent IDs. Each run rebuilds the playlist "zz AutoMix Lab run" with just
those tracks and plays the playlist, because playing a single playlist track lets Autoplay choose
what follows.

Writes <out-prefix>.caf and <out-prefix>.json (track facts plus a player-position timeline whose
times are seconds from the first recorded sample, to within the polling error).
"""
import argparse, json, os, subprocess, sys, time

TAP = os.environ.get("AUTOMIX_TAP", os.path.join(os.environ.get("TMPDIR", "/tmp"), "automix-lab/AutoMixTap.app"))

def music(script):
    out = subprocess.run(["osascript", "-e", f'tell application "Music"\n{script}\nend tell'],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        sys.exit(f"Music script failed: {out.stderr.strip()}")
    return out.stdout.strip()

PLAYLIST = "zz AutoMix Lab run"

def build_playlist(ids):
    listed = ", ".join(f'"{i}"' for i in ids)
    music(f'if exists user playlist "{PLAYLIST}" then delete user playlist "{PLAYLIST}"\n'
          f'set pl to make new user playlist with properties {{name:"{PLAYLIST}"}}\n'
          f'repeat with pid in {{{listed}}}\n'
          'duplicate (first track of library playlist 1 whose persistent ID is pid) to pl\nend repeat')

def track_facts(index):
    raw = music(f'set t to track {index} of user playlist "{PLAYLIST}"\n'
                'return (persistent ID of t) & "\t" & (name of t) & "\t" & (artist of t) & "\t" & (album of t)'
                ' & "\t" & (genre of t) & "\t" & (duration of t) & "\t" & (bpm of t) & "\t" & (cloud status of t as text)')
    keys = ["id", "name", "artist", "album", "genre", "duration", "bpm", "cloud"]
    facts = dict(zip(keys, raw.split("\t")))
    facts["duration"] = float(facts["duration"])
    return facts

def poll():
    raw = music('if player state is playing then\n'
                'return (persistent ID of current track) & "\t" & player position\n'
                'else\nreturn "stopped\t0"\nend if')
    ident, position = raw.split("\t")
    return ident, float(position)

def record(prefix, seconds):
    for suffix in (".caf", ".caf.started", ".caf.error"):
        if os.path.exists(prefix + suffix):
            os.remove(prefix + suffix)
    proc = subprocess.Popen(["open", "-n", "-W", TAP, "--args", "com.apple.Music", str(seconds), prefix + ".caf", "mute"])
    deadline = time.time() + 30
    while not os.path.exists(prefix + ".caf.started"):
        if os.path.exists(prefix + ".caf.error"):
            sys.exit(open(prefix + ".caf.error").read())
        if time.time() > deadline:
            sys.exit("tap did not start")
        time.sleep(0.02)
    start = time.time()
    os.remove(prefix + ".caf.started")
    return proc, start

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["pair", "head", "tail"])
    parser.add_argument("prefix")
    parser.add_argument("ids", nargs="+")
    parser.add_argument("--lead", type=float, default=50)
    parser.add_argument("--tail", type=float, default=60)
    parser.add_argument("--seconds", type=float, default=70)
    args = parser.parse_args()

    build_playlist(args.ids)
    first = track_facts(1)
    result = {"mode": args.mode, "a": first,
              "settings": subprocess.run(["defaults", "read", "com.apple.Music", "TransitionStyle"],
                                         capture_output=True, text=True).stdout.strip()}
    if args.mode == "pair":
        result["b"] = track_facts(2)
        seek = max(0, first["duration"] - args.lead)
        length = args.lead + args.tail + 5
    elif args.mode == "tail":
        seek = max(0, first["duration"] - args.seconds)
        length = args.seconds + 3
    else:
        seek = 0
        length = args.seconds

    music('set shuffle enabled to false\nset song repeat to off')
    music("stop")
    proc, start = record(args.prefix, length + 6)
    music(f'play user playlist "{PLAYLIST}"')
    # Seeking right after play is sometimes ignored, so seek once playback is moving and check it.
    for _ in range(20):
        ident, position = poll()
        if ident == first["id"] and seek <= position < seek + 8:
            break
        if position > 0.2 or seek == 0:
            music(f"set player position to {seek}")
        time.sleep(0.3)
    else:
        subprocess.run(["pkill", "-TERM", "-x", "AutoMixTap"])
        sys.exit("seek did not take")
    length += time.time() - start
    timeline = []
    while time.time() - start < length - 0.5:
        before = time.time()
        ident, position = poll()
        timeline.append([round((before + time.time()) / 2 - start, 3), ident, round(position, 3)])
        if args.mode == "tail" and ident != first["id"]:
            break
        time.sleep(0.2)
    music("pause")
    if args.mode == "tail":
        subprocess.run(["pkill", "-TERM", "-x", "AutoMixTap"])
    proc.wait()
    result["seek"] = seek
    result["timeline"] = timeline
    with open(args.prefix + ".json", "w") as handle:
        json.dump(result, handle, indent=1)
    switch = next((row for row in timeline if row[1] != first["id"]), None)
    if args.mode == "pair" and (switch is None or switch[1] != result["b"]["id"]):
        sys.exit(f"wrong or missing next track: {switch}")
    print(f"{args.mode} {first['name']!r}: recorded {timeline[-1][0]:.0f}s, track change at {switch[0] if switch else None}")

if __name__ == "__main__":
    main()
