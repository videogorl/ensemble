#!/usr/bin/env python3
"""Takes a recorded transition apart into its two source tracks.

  decompose.py <mix-prefix> <a-tail-prefix> <b-head-prefix> [--from S] [--to S] [--json out.json]

For each moment of the mix it finds which moment of A and of B is sounding (a path through each
reference that may speed up, slow down, hold or jump), then fits each track's level in three
frequency bands. Prints one row per 2 s: song position, speed relative to the original, and level.
"""
import argparse, json, subprocess
import numpy as np

RATE, FFT, HOP = 22050, 2048, 512
FRAME = HOP / RATE
BANDS = [(30, 250), (250, 2500), (2500, 10000)]

def load(prefix):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", prefix + ".caf", "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

def spectrogram(signal):
    frames = 1 + (len(signal) - FFT) // HOP
    index = np.arange(FFT)[None, :] + HOP * np.arange(frames)[:, None]
    return np.abs(np.fft.rfft(signal[index] * np.hanning(FFT), axis=1)).astype(np.float32)

def features(spec):
    """Log-spaced band energies, compressed and unit length, so matching ignores level."""
    freqs = np.fft.rfftfreq(FFT, 1 / RATE)
    edges = np.geomspace(60, 9000, 73)
    bands = np.stack([spec[:, (freqs >= lo) & (freqs < hi)].sum(axis=1) for lo, hi in zip(edges[:-1], edges[1:])], axis=1)
    bands = np.log1p(50 * bands)
    return bands / (np.linalg.norm(bands, axis=1, keepdims=True) + 1e-9)

def song_clock(prefix):
    """Offset to add to recording time to get song position, per track id, from Music's reports."""
    meta = json.load(open(prefix + ".json"))
    clocks = {}
    for ident in {row[1] for row in meta["timeline"]}:
        rows = [row for row in meta["timeline"] if row[1] == ident and row[2] > 0.5]
        if rows:
            clocks[ident] = float(np.median([row[2] - row[0] for row in rows[-40:]]))
    return meta, clocks

def follow(mix_feat, ref_feat, jump_cost=6.0):
    """Path through ref for every mix frame. Steps of 0-3 ref frames per mix frame are cheap
    (speeds 0x-3x); any other move is a jump and costs jump_cost."""
    cost = 1 - mix_feat @ ref_feat.T
    frames, size = cost.shape
    total = cost[0].copy()
    back = np.zeros((frames, size), dtype=np.int32)
    step_cost = [0.02, 0.0, 0.02, 0.06]
    for t in range(1, frames):
        best = total + step_cost[0]
        origin = np.arange(size)
        for step in (1, 2, 3):
            shifted = np.full(size, np.inf); shifted[step:] = total[:-step] + step_cost[step]
            better = shifted < best
            best = np.where(better, shifted, best); origin = np.where(better, np.arange(size) - step, origin)
        jump_from = int(np.argmin(total))
        jumped = total[jump_from] + jump_cost
        better = jumped < best
        best = np.where(better, jumped, best); origin = np.where(better, jump_from, origin)
        back[t] = origin
        total = best + cost[t]
    path = np.zeros(frames, dtype=np.int32)
    path[-1] = int(np.argmin(total))
    for t in range(frames - 1, 0, -1):
        path[t - 1] = back[t, path[t]]
    return path, cost[np.arange(frames), path]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mix"); parser.add_argument("a"); parser.add_argument("b")
    parser.add_argument("--from", dest="start", type=float); parser.add_argument("--to", dest="stop", type=float)
    parser.add_argument("--json")
    args = parser.parse_args()

    mix_meta, mix_clock = song_clock(args.mix)
    a_meta, a_clock = song_clock(args.a)
    b_meta, b_clock = song_clock(args.b)
    a_id, b_id = mix_meta["a"]["id"], mix_meta["b"]["id"]
    switch = next(row[0] for row in mix_meta["timeline"] if row[1] == b_id)
    start = args.start if args.start is not None else max(0, switch - 50)
    stop = args.stop if args.stop is not None else switch + 45

    mix = load(args.mix)[int(start * RATE): int(stop * RATE)]
    spec_m, spec_a, spec_b = spectrogram(mix), spectrogram(load(args.a)), spectrogram(load(args.b))
    feat_m = features(spec_m)
    path_a, cost_a = follow(feat_m, features(spec_a))
    path_b, cost_b = follow(feat_m, features(spec_b))

    freqs = np.fft.rfftfreq(FFT, 1 / RATE)
    window = int(round(2 / FRAME))
    rows = []
    print(f"{mix_meta['a']['name']}  ->  {mix_meta['b']['name']}")
    print(f"A is {mix_meta['a']['duration']:.1f}s long. Music showed B from mix {switch:.1f}s.")
    print(" mix_s | A pos  speed match  lo  mid   hi | B pos  speed match  lo  mid   hi | unexplained")
    for frame in range(0, len(feat_m) - window, window):
        span = slice(frame, frame + window)
        row = {"mix": round(start + frame * FRAME, 1)}
        gains_all, basis_all = [], []
        for name, path, cost, spec, clock in (("a", path_a, cost_a, spec_a, a_clock[a_id]), ("b", path_b, cost_b, spec_b, b_clock[b_id])):
            positions = path[span] * FRAME + clock
            speed = np.polyfit(np.arange(window) * FRAME, path[span] * FRAME, 1)[0]
            row[name + "_pos"] = round(float(np.median(positions)), 1)
            row[name + "_speed"] = round(float(speed), 3)
            row[name + "_match"] = round(float(1 - cost[span].mean()), 2)
            basis_all.append(spec[path[span]])
        unexplained = []
        for low, high in BANDS:
            band = (freqs >= low) & (freqs < high)
            target = spec_m[span][:, band].ravel()
            basis = np.stack([basis_all[0][:, band].ravel(), basis_all[1][:, band].ravel()], axis=1)
            gains = np.clip(np.linalg.lstsq(basis, target, rcond=None)[0], 0, None)
            gains_all.append(gains)
            unexplained.append(np.linalg.norm(target - basis @ gains) / (np.linalg.norm(target) + 1e-9))
        db = lambda v: -99.0 if v < 1e-4 else round(float(20 * np.log10(v)), 1)
        row["a_db"] = [db(g[0]) for g in gains_all]; row["b_db"] = [db(g[1]) for g in gains_all]
        row["unexplained"] = round(float(np.mean(unexplained)), 2)
        rows.append(row)
        fmt = lambda k: f"{row[k+'_pos']:6.1f} {row[k+'_speed']:5.2f} {row[k+'_match']:5.2f} " + " ".join(f"{v:4.0f}" for v in row[k + "_db"])
        print(f"{row['mix']:6.1f} | {fmt('a')} | {fmt('b')} | {row['unexplained']:.2f}")
    if args.json:
        json.dump({"a": mix_meta["a"], "b": mix_meta["b"], "switch": switch, "rows": rows}, open(args.json, "w"), indent=1)

if __name__ == "__main__":
    main()
