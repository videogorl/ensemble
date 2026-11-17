#!/usr/bin/env python3
"""Scores tempo estimators against Apple's beat grid on songs present in both libraries.

  tempo_eval.py <data-dir> [--limit N]

Reads <data-dir>/overlap.json (Apple library track paired with a local file) and
<data-dir>/harvest/analysis/*.json, decodes the first and last 30 seconds of each local file
(cached under <data-dir>/clips), and reports how often each estimator lands within 2% of the
tempo Apple's beats give for the same stretch, with octave errors (half/double) counted apart.
"""
import glob, json, os, subprocess, sys

import numpy as np

RATE, CLIP = 11025, 30.0

def norm(text):
    return "".join(ch for ch in (text or "").lower() if ch.isalnum())

def clip(path, cache, start, key):
    target = os.path.join(cache, key + ".npy")
    if os.path.exists(target):
        return np.load(target)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{max(0, start):.3f}", "-t", str(CLIP), "-i", path,
                          "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"], capture_output=True).stdout
    samples = np.frombuffer(raw, dtype=np.float32)
    np.save(target, samples)
    return samples

def apple_tempo(beats_ms, start, end):
    """Median beat interval of Apple's grid inside [start, end] seconds, as BPM."""
    beats = np.array([b / 1000 for b in beats_ms if start <= b / 1000 <= end])
    if len(beats) < 8:
        return None
    return 60 / float(np.median(np.diff(beats)))

# --- estimators ---------------------------------------------------------------------------------

def current(samples):
    """What SmartMixTempoEstimator does today: loudness rises, plain autocorrelation, 70-180 BPM."""
    hop = max(512, int(RATE * 0.023))
    frames = len(samples) // hop
    if frames < 16:
        return None
    env = np.sqrt((samples[:frames * hop].reshape(frames, hop) ** 2).mean(axis=1))
    flux = np.maximum(0, np.diff(env, prepend=env[0]))
    return autocorrelation_peak(flux, RATE / hop, 70, 180, prior=False, comb=False)

def onset_strength(samples, hop=128, window=1024, bands=24):
    """Rises in loudness per frequency band, summed: drums and note starts in any register count."""
    frames = 1 + (len(samples) - window) // hop
    if frames < 64:
        return None, 0
    index = np.arange(window)[None, :] + hop * np.arange(frames)[:, None]
    spectrum = np.abs(np.fft.rfft(samples[index] * np.hanning(window), axis=1))
    edges = np.unique(np.geomspace(2, spectrum.shape[1] - 1, bands + 1).astype(int))
    banded = np.stack([spectrum[:, a:b].sum(axis=1) for a, b in zip(edges[:-1], edges[1:])], axis=1)
    level = np.log1p(100 * banded)
    flux = np.maximum(0, level[1:] - level[:-1]).sum(axis=1)
    # Remove the slow swell so only sharp rises remain.
    smooth = np.convolve(flux, np.ones(87) / 87, mode="same")
    return np.maximum(0, flux - smooth), RATE / hop

def autocorrelation_peak(flux, rate, low, high, prior=True, comb=True):
    flux = flux - flux.mean()
    size = 1 << int(np.ceil(np.log2(2 * len(flux))))
    spectrum = np.fft.rfft(flux, size)
    acf = np.fft.irfft(spectrum * np.conj(spectrum))[:len(flux)]
    acf = acf / (acf[0] + 1e-12)
    lags = np.arange(int(rate * 60 / high), int(rate * 60 / low) + 1)
    score = acf[lags].copy()
    if comb:
        # A real beat period also repeats at twice and four times its length.
        for multiple, weight in ((2, 0.5), (4, 0.25)):
            reach = lags * multiple
            ok = reach < len(acf)
            score[ok] += weight * acf[reach[ok]]
    if prior:
        bpm = 60 * rate / lags
        score = score * np.exp(-0.5 * (np.log2(bpm / 120) / 0.9) ** 2)
    best = int(np.argmax(score))
    lag = float(lags[best])
    if 0 < best < len(lags) - 1:
        a, b, c = score[best - 1], score[best], score[best + 1]
        if a - 2 * b + c != 0:
            lag += 0.5 * (a - c) / (a - 2 * b + c)
    return 60 * rate / lag

def spectral(samples):
    """Onsets across frequency bands, autocorrelation reinforced at 2x and 4x the period."""
    flux, rate = onset_strength(samples)
    return None if flux is None else autocorrelation_peak(flux, rate, 70, 180)

ESTIMATORS = {"current": current, "spectral": spectral}

# --- scoring ------------------------------------------------------------------------------------

def verdict(estimate, truth):
    if estimate is None:
        return "none"
    for factor, name in ((1, "right"), (2, "double"), (0.5, "half"), (1.5, "x1.5"), (2 / 3, "x2/3"), (4 / 3, "x4/3"), (0.75, "x3/4")):
        if abs(estimate / (truth * factor) - 1) <= 0.02:
            return name
    return "wrong"

def main():
    data = sys.argv[1]
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    cache = os.path.join(data, "clips")
    os.makedirs(cache, exist_ok=True)
    songs = {}
    for path in glob.glob(os.path.join(data, "harvest", "analysis", "*.json")):
        song = json.load(open(path))
        songs[(norm(song["name"]), norm(song["artist"]))] = song
    tallies = {name: {} for name in ESTIMATORS}
    used = 0
    for entry in json.load(open(os.path.join(data, "overlap.json")))[:limit]:
        song = songs.get((norm(entry["apple"]["name"]), norm(entry["apple"]["artist"])))
        path = entry["plex"]["file"]
        beats = ((song or {}).get("audioAnalysis") or {}).get("beats", {}).get("beatsInMilliseconds")
        if not beats or not os.path.exists(path):
            continue
        duration = float(entry["plex"]["duration"])
        # The two libraries can hold different masters; skip songs whose lengths disagree.
        if abs(duration - song["durationInMillis"] / 1000) > 1.5 or duration < 90:
            continue
        used += 1
        for part, start in (("head", 0.0), ("tail", duration - CLIP)):
            truth = apple_tempo(beats, start, start + CLIP)
            if truth is None:
                continue
            samples = clip(path, cache, start, f"{entry['apple']['id']}_{part}")
            if len(samples) < RATE * 10:
                continue
            for name, estimator in ESTIMATORS.items():
                key = verdict(estimator(samples), truth)
                tallies[name][key] = tallies[name].get(key, 0) + 1
    print(f"{used} songs")
    for name, tally in tallies.items():
        total = sum(tally.values())
        parts = ", ".join(f"{k} {v}" for k, v in sorted(tally.items(), key=lambda kv: -kv[1]))
        print(f"{name:18s} right {100 * tally.get('right', 0) / max(total, 1):5.1f}% of {total}  ({parts})")

if __name__ == "__main__":
    main()
