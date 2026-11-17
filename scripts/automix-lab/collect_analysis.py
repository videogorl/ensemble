#!/usr/bin/env python3
"""Copies the per-song transition analysis Music.app has cached into <out-dir>/<song id>.json.

  collect_analysis.py <out-dir>

Music fetches this from Apple when it plans a transition and keeps it in its URL cache, which
evicts old entries, so run this during a harvest. Existing files are left alone.
"""
import glob, json, os, sys

CACHE = os.path.expanduser("~/Library/Caches/com.apple.Music/fsCachedData")

def collect(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    added = 0
    for path in glob.glob(os.path.join(CACHE, "*")):
        try:
            if os.path.getsize(path) > 4_000_000:
                continue
            raw = open(path, "rb").read()
            if b"flexml-analysis" not in raw and b"audio-analysis" not in raw:
                continue
            resources = json.loads(raw).get("resources", {})
        except (OSError, ValueError):
            continue
        for song_id, song in resources.get("songs", {}).items():
            target = os.path.join(out_dir, song_id + ".json")
            if os.path.exists(target):
                continue
            genre_ids = [g["id"] for g in song.get("relationships", {}).get("raw-genres", {}).get("data", [])]
            attributes = song.get("attributes", {})
            record = {
                "id": song_id,
                "name": attributes.get("name"), "artist": attributes.get("artistName"), "album": attributes.get("albumName"),
                "durationInMillis": attributes.get("durationInMillis"), "genreNames": attributes.get("genreNames"),
                "supportsSmartTransitions": attributes.get("supportsSmartTransitions"),
                "rawGenres": [resources.get("genres", {}).get(g, {}).get("attributes", {}).get("name") for g in genre_ids],
                "audioAnalysis": resources.get("audio-analysis", {}).get(song_id, {}).get("attributes"),
                "flexml": resources.get("flexml-analysis", {}).get(song_id, {}).get("attributes"),
            }
            with open(target, "w") as handle:
                json.dump(record, handle)
            added += 1
    return added

if __name__ == "__main__":
    print(collect(sys.argv[1]), "new songs")
