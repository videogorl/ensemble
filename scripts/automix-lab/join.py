#!/usr/bin/env python3
"""Joins harvested plans with Apple's per-song analysis into one table.

  join.py <harvest-dir> <out.jsonl>

Reads every *.jsonl harvest in the directory and analysis/*.json, matches songs by title and
artist, and writes one flat record per pair that logged a plan or a reason for none.
"""
import glob, json, os, sys

def norm(text):
    return "".join(ch for ch in (text or "").lower() if ch.isalnum())

def main():
    root, out_path = sys.argv[1], sys.argv[2]
    songs = {}
    for path in glob.glob(os.path.join(root, "analysis", "*.json")):
        song = json.load(open(path))
        songs[(norm(song["name"]), norm(song["artist"]))] = song
    seen, records = set(), []
    for path in sorted(glob.glob(os.path.join(root, "*.jsonl"))):
        if os.path.abspath(path) == os.path.abspath(out_path):
            continue
        for line in open(path):
            row = json.loads(line)
            if not row.get("log") or (row["a"]["id"], row["b"]["id"]) in seen:
                continue
            seen.add((row["a"]["id"], row["b"]["id"]))
            row["a_song"] = songs.get((norm(row["a"]["name"]), norm(row["a"]["artist"])))
            row["b_song"] = songs.get((norm(row["b"]["name"]), norm(row["b"]["artist"])))
            row["source"] = os.path.basename(path)
            del row["log"]
            records.append(row)
    with open(out_path, "w") as out:
        for record in records:
            out.write(json.dumps(record) + "\n")
    both = sum(1 for r in records if r["a_song"] and r["b_song"])
    print(f"{len(records)} pairs, {both} with analysis for both songs")

if __name__ == "__main__":
    main()
