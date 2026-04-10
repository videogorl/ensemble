---
name: trace-analysis
description: "Load when a user provides an Instruments .trace bundle and wants performance, hang, lifecycle, thermal, or timeline analysis. Use the bundled script to export xctrace tables, summarize run windows, and correlate trace timestamps with session logs."
---

# Trace Analysis

Use this skill when a user provides an Instruments `.trace` bundle and wants a concrete read on what the trace does or does not confirm.

Primary command:

```bash
python3 .claude/skills/trace-analysis/scripts/analyze_trace.py /absolute/path/to/session.trace --run latest
```

Useful variants:

```bash
python3 .claude/skills/trace-analysis/scripts/analyze_trace.py /absolute/path/to/session.trace --run 8
python3 .claude/skills/trace-analysis/scripts/analyze_trace.py /absolute/path/to/session.trace --run 8 --output-dir /tmp/trace8-export
python3 .claude/skills/trace-analysis/scripts/analyze_trace.py /absolute/path/to/session.trace --run 8 --include-time-profile
python3 .claude/skills/trace-analysis/scripts/analyze_trace.py /absolute/path/to/session.trace --run 8 --symbol "MyType.myMethod"
```

## Workflow

1. Run the script against the requested trace.
2. Read the summary first:
   - compatibility warnings from `open.creq`
   - run start/end times
   - lifecycle transitions
   - thermal state
   - hang and runloop table counts
   - symbol hits from `gcd-perf-event`
3. Add `--include-time-profile` when you need deeper CPU sampling and can tolerate a slower export.
4. Correlate the reported wall-clock timestamps with the user’s session log.
5. If needed, inspect the exported XML files in the script’s output directory for deeper context.

## Interpretation rules

- Empty `hang-risks` / `potential-hangs` does not mean the app was smooth. It only means Instruments did not record a qualifying hang.
- Treat repeated shorter samples in audio, download, database, SwiftUI, or UIKit paths as real contention even if the hang tables are empty.
- If `open.creq` reports unsupported engineering types or topology warnings, note that some exports may still work even when Instruments UI is unreliable.
- Always state which findings came from the trace versus the app log.

## Exports worth inspecting manually

- `trace-toc.xml`
- `life-cycle-period.xml`
- `device-thermal-state-intervals.xml`
- `hang-risks.xml`
- `potential-hangs.xml`
- `gcd-perf-event.xml`
- `region-of-interest.xml`
- `runloop-events.xml`
- `time-profile.xml`

## Ensemble-specific defaults

The bundled script already looks for common hot paths in this repo:

- `OfflineDownloadService`
- `DownloadManager`
- `LibraryViewModel.fetchAndMapInBackground`
- `LibraryRepository.fetchArtists`
- `PlaybackService`
- `AudioPlaybackEngine`
- `SyncCoordinator`
- `PlexAPIClient`
- `PlexWebSocketCoordinator`
- selected UIKit list / keyboard layout symbols

Add extra `--symbol` values when you are investigating a narrower subsystem.
