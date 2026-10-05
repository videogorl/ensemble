# Playlist and queue state efficiency

Implemented the five approved follow-ups in `codex/state-efficiency`, based on
`73e87f94`. Production Swift changes add 379 lines and remove 389. No new service,
dependency, persistence schema, or state framework was introduced.

## Changes

- `PlaylistViewModel` prepares list, sidebar, and collision projections through
  one Core builder. It groups once, shares the sorted result when search is
  empty, publishes changed fields only, and rejects outdated background results.
  Cached data still prepares the initial display synchronously. The macOS sidebar
  consumes this prepared projection; its separate merging and sorting paths are
  removed.
- Playlist detail observers filter canonical server identities before debounce.
  Missing identities still refresh conservatively. Merged details match any
  constituent server.
- A single foreground timer replaces the separate hourly and minute timers. It
  checks every five minutes with 60 seconds of tolerance. Library sync retains
  its one-hour/four-hour freshness interval. Downloaded-playlist fallback checks
  skip servers with a successful complete inventory less than five minutes old.
  Incremental-only cursors do not suppress orphan reconciliation. Stopping the
  timer cancels its task; overlapping ticks are suppressed.
- Queue, index, and history bind directly from `PlaybackService` into the existing
  queue projection. Their intermediate published copies in `NowPlayingViewModel`
  are removed. iOS table sections rebuild only for changes to the displayed
  queue/history mode. Full item equality preserves same-ID metadata changes.
- Single and merged detail loads share an in-flight task and coalesce trailing
  requests. Revision/source guards discard reads invalidated by local edits or
  changed constituents. Merged occurrence/edit maps commit with the track snapshot.

The five-minute inventory fallback remains intentional: prior physical-device
evidence showed a playlist membership change missed by WebSocket delivery. This
change reduces polling without relying on perfect event delivery.

## Verification

Both Debug workspace builds succeeded with Xcode 27.0 (27A266a). No unit or
integration suite was added or run. The obsolete two-timer cadence test was
removed; the existing source-specific timer check now references the shared timer.

- macOS: launched the explicit built app and verified PID 46012's executable
  path in the new DerivedData directory. Version `0.4.0 / 202610050652.7387`.
  Inspected the prepared list/sidebar ordering, changed sort and restored Title
  ascending, opened a two-source 246-track merged detail and a large single-source
  detail, then played the merged queue. Next advanced to the second source's track;
  History showed the completed first track. Playback ended paused and the original
  shuffle preference was restored.
- iOS: simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`, actual iOS 26.5 runtime.
  Version `0.4.0 / 202610050702.7387`; built and installed executable/debug-dylib
  SHA-256 hashes matched, and PID 52585 used that installed app. A launch-triggered
  real playlist refresh completed. Search found the merged 246-track playlist;
  detail preserved alternating source order. Playback, automatic advances, upcoming
  queue, and History/Queue switching were inspected. Playback ended paused.
- macOS LLDB: an unrelated server refresh notification produced zero merged-detail
  load breakpoint hits; a global notification produced reloads. Three concurrent
  requests on a repository-backed, two-source fixture completed with one committed
  load, 246 tracks, and `isLoading == false`. A debugger-only revision change during
  a cached read prevented that read from overwriting the fixture; a subsequent
  load restored all 246 tracks. These probes did not edit persisted playlists.
- Live coordinator inspection found one valid 300-second timer, 60-second
  tolerance, and a 14,400-second library interval while WebSocket was active.
  Firing it with no downloaded-playlist targets produced no playlist inventory
  request. A temporary target-provider hook then exercised the production fallback
  against a configured server: four checks produced one stale inventory refresh;
  subsequent checks reused the fresh cursor. The original provider was restored.

Raw logs, endpoint responses, database backups, debugger commands, and screenshots
remain local under `/tmp/ensemble-state-efficiency.beoyiwb4`; they are not committed.

## Limits and follow-up

The [follow-up investigation](2026-10-05-state-efficiency-follow-up.md) records
physical profiling, the upstream count-discrepancy cause, additional runtime
checks, and the remaining confidence gaps. The paragraph below is the first-pass
checkpoint, before that follow-up.

This establishes behavior and several avoided-work paths, not an energy or frame
time benchmark. Physical-device energy profiling, downloaded-playlist background
cancellation under a slow connection, and Apple Music detail loading remain
unverified. Simulator drag attempts did not establish queue reordering; no reorder
behavior change is claimed. Same-ID queue metadata handling was inspected in code.

The cached smart-playlist inventory/body count discrepancy existed in the
pre-change database and remains outside this refactor. Evidence and next steps
are tracked in [issue #98](https://github.com/videogorl/ensemble/issues/98).
