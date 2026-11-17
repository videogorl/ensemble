#!/usr/bin/env python3
"""Collects the transition plans Music.app logs for consecutive tracks of a sequence.

  harvest.py <tracks.txt> <out.jsonl>

tracks.txt lists library persistent IDs, one per line, in play order; every consecutive pair is
one transition. Music computes and logs its plan a few seconds after a track starts, so each pair
takes seconds: start the track, wait for the plan, skip to the next. Transitions must be on.
Each output line holds the two tracks, the parsed plan if there was one, and the raw log lines.
"""
import json, os, re, subprocess, sys, time

PLAYLIST = "zz AutoMix Lab run"
PREDICATE = ('process == "Music" AND (subsystem == "com.apple.Sonic" OR eventMessage CONTAINS "TRANSITION:" '
             'OR eventMessage CONTAINS "CMCrossfadeHandler")')

def music(script, timeout=600):
    out = subprocess.run(["osascript", "-e", f'with timeout of {timeout} seconds\ntell application "Music"\n{script}\nend tell\nend timeout'],
                         capture_output=True, text=True, timeout=timeout + 10)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip()

def facts(ids):
    wanted = set(ids)
    raw = music('set AppleScript\'s text item delimiters to linefeed\nset p to library playlist 1\n'
                'return ((persistent ID of every track of p) as text) & linefeed & "=====" & linefeed & ((name of every track of p) as text)'
                ' & linefeed & "=====" & linefeed & ((artist of every track of p) as text) & linefeed & "=====" & linefeed & ((genre of every track of p) as text)'
                ' & linefeed & "=====" & linefeed & ((duration of every track of p) as text) & linefeed & "=====" & linefeed & ((album of every track of p) as text)')
    columns = [block.split("\n") for block in raw.split("\n=====\n")]
    return {row[0]: dict(zip(["id", "name", "artist", "genre", "duration", "album"], row)) for row in zip(*columns) if row[0] in wanted}

def parse(lines):
    text = "\n".join(lines)
    plan = {}
    found = re.search(r"Smart transition setup complete with parameters: (\[.*\])", text)
    if found:
        try:
            plan = json.loads(found.group(1).replace("[", "{").replace("]", "}"))
        except ValueError:
            plan = {"unparsed": found.group(1)}
    info = re.search(r"OutgoingItemInfo: \((.*?)\)\.\s+IncomingItemInfo: \((.*?)\)", text)
    if info:
        plan["outgoingInfo"], plan["incomingInfo"] = info.group(1), info.group(2)
    downbeat = re.search(r"finalStartDownbeat: ([\d.]+)", text)
    if downbeat:
        plan["finalStartDownbeat"] = float(downbeat.group(1))
    return plan

def main():
    ids = [line.split()[0] for line in open(sys.argv[1]) if line.strip() and not line.startswith("#")]
    out_path = sys.argv[2]
    known = facts(ids)
    ids = [i for i in ids if i in known]
    log_path = out_path + ".log"
    stream = subprocess.Popen(["/usr/bin/log", "stream", "--level", "debug", "--style", "compact", "--predicate", PREDICATE],
                              stdout=open(log_path, "w"), stderr=subprocess.DEVNULL)
    try:
        listed = ", ".join(f'"{i}"' for i in ids)
        music(f'if exists user playlist "{PLAYLIST}" then delete user playlist "{PLAYLIST}"\n'
              f'set pl to make new user playlist with properties {{name:"{PLAYLIST}"}}\n'
              f'repeat with pid in {{{listed}}}\nduplicate (first track of library playlist 1 whose persistent ID is pid) to pl\nend repeat')
        music('set shuffle enabled to false\nset song repeat to off')
        log = open(log_path, errors="replace")
        time.sleep(2)
        log.read()
        music(f'play user playlist "{PLAYLIST}"')
        with open(out_path, "a") as out:
            for index in range(len(ids) - 1):
                lines, deadline, settled = [], time.time() + 14, None
                while time.time() < deadline:
                    chunk = log.read()
                    if chunk:
                        lines += chunk.splitlines()
                        joined = "\n".join(lines)
                        if "Updated outgoing item content with transition info" in joined:
                            break
                        if settled is None and re.search(r"Failed to|not eligible|No transition data|too short|cancelling crossfade|does not support", joined):
                            settled = time.time() + 1.5
                    if settled and time.time() > settled:
                        break
                    time.sleep(0.25)
                current = music("return persistent ID of current track")
                record = {"a": known[ids[index]], "b": known[ids[index + 1]], "current": current,
                          "plan": parse(lines), "log": [re.sub(r"^\S+ \S+ \S+ +\S+ ", "", l)[:1500] for l in lines]}
                out.write(json.dumps(record) + "\n"); out.flush()
                strategy = record["plan"].get("strategy", "none")
                print(f"{index + 1}/{len(ids) - 1} {known[ids[index]]['name'][:24]!r} -> {known[ids[index + 1]]['name'][:24]!r}: {strategy} {record['plan'].get('duration', '')}", flush=True)
                log.read()
                music("next track")
    finally:
        try:
            music(f'pause\nif exists user playlist "{PLAYLIST}" then delete user playlist "{PLAYLIST}"')
        finally:
            stream.terminate()

if __name__ == "__main__":
    main()
