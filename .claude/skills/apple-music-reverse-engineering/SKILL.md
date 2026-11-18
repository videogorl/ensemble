---
name: apple-music-reverse-engineering
description: "Load when asked to find out how an Apple Music feature (AutoMix transitions or a later one) behaves so Ensemble can match it: collecting Music.app's logged plans and cached analysis on the Mac, recording its output, and scoring Ensemble's own result against it."
---

# Reverse-engineering Apple Music behaviour

Use this when Felicity asks what Apple Music does (for example after an OS update changes AutoMix) and wants
Ensemble to match it. The worked example is AutoMix into SmartMix:
`docs/investigations/2026-11-17-automix-reverse-engineering-plan.md` (method) and
`docs/investigations/2026-11-17-automix-findings.md` (results). Read both before starting; update the findings
file, or start a dated one, rather than repeating what it already settles.

## Ground rules

- Observe, do not disassemble. Everything so far came from Music's own log text, the files it caches, resource
  files inside system frameworks, and recordings of its output.
- Apple's files (`TransitionStyles.json`, per-song analysis JSON) and commercial audio never go in the repo.
  Lab data lives in `~/Developer/automix-lab-data/`. Describe what a file says in the findings; do not copy it.
- Ensemble's side may use only the decoded audio file and generic track fields, so it also works for a
  non-Plex source.
- State sample sizes with every number, and say which Mac, macOS and Music versions it was measured on. A
  finding from the Mac is not a finding about the iPhone until it is checked there.
- When Apple's behaviour conflicts with Ensemble's, Apple's is the default; Felicity may choose otherwise
  (she lifted Apple's genre gate on 2026-11-18). Ask with the input dialog.

## Where Music gives itself away (macOS)

1. **The log.** `log stream --level debug --predicate 'process == "Music" AND subsystem == ...'`. AutoMix logs
   under `com.apple.Sonic` and `com.apple.smarttransitions`: the chosen strategy and style, start, pivot and
   end times in each song, the speed of each song, and a reasoning trace saying why each strategy was accepted
   or rejected. For a new feature, stream Music's whole debug log while using the feature once and look for
   new subsystems before writing any tooling.
2. **The URL cache.** `~/Library/Caches/com.apple.Music/fsCachedData` holds what Music downloads to make its
   decision (for AutoMix, a per-song analysis: beats, bars, key, loudness curve, vocal activity, entry and
   exit points). It evicts old entries, so copy during a run.
3. **Framework resources and strings.** `ls` and `strings` on the private frameworks the log names (SonicKit,
   SonicFoundation, SonicAudioUnits). The style catalogue was a plain JSON resource.
4. **Preferences.** `defaults read com.apple.Music` before and after flipping a setting in the app shows the
   key; relaunch Music after writing one. Restore what you found.
5. **The sound itself.** Record Music's output and take the mix apart against reference recordings of each
   song. Slow (real time), so use it to confirm a few cases, not to gather statistics.

## Tools in `scripts/automix-lab/`

| Script | Use |
|---|---|
| `harvest.py` | Plays a list of library songs in order, reads each logged plan and trace, skips on. About 10 s a pair |
| `collect_analysis.py` | Copies Apple's cached per-song analysis out of Music's cache |
| `join.py` | One table of pairs: both songs, the plan, the analysis |
| `trace_summary.py` | Counts the planner's stated reasons per strategy |
| `capture.py`, `batch.py`, `tap/` | Record Music's output for a pair or a list of pairs (audio tap) |
| `decompose.py` | Takes a recorded transition apart into each song's position, speed and level |
| `tempo_eval.py` | Scores an estimator of ours against Apple's beat grid on songs in both libraries |

## Order of work

1. Write a dated plan in `docs/investigations/` with the questions to answer; get it approved if it needs
   Felicity's machine, library or time.
2. Harvest widely first (hundreds of pairs across genres and playlists), then read the planner's own reasons.
   Its trace text names the rule; fit thresholds only for what the trace leaves out.
3. Check a rule by counting exceptions over all pairs, and report the count ("0 of 1,058").
4. Run Ensemble's planner offline over the same songs (the ones in both libraries, same master: lengths
   within 1.5 s) and tabulate Apple's choice against ours.
5. Build the change, then run named pairs on a physical iPhone and read `[SmartMix] Planned` in the session
   log. Record what was run, and what still has to be heard, in
   `docs/reference/physical-device-backlog.md`.
6. Nothing is verified until Felicity has heard it.

## Lessons from the AutoMix round

- Read the trace before theorising: key was assumed to block blends until the trace showed it only selects a
  style.
- The lab's genres came from Apple; the phone's come from Plex (`Pop/Rock` on most songs). Check every input
  the planner uses against what the real library supplies, on the device, before trusting an offline result.
- Apple downloads its analysis; Ensemble computes it on the device. Measure the cost on the slowest supported
  phone (the iPhone SE took 8 to 12 s a song).
- Music's queue stalls on a track that will not load; the harvest restarts after it.
