# Step 1e: one playback snapshot

Re-architecture step 1e, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the [design note](../reference/playback-state-machine-design.md).
Commits `f64cbadf` to `691211a9`, started from `20d90c99`. Simulator-checked,
not verified.

## What changed

| Commit | Change |
|---|---|
| `f64cbadf` | `PlaybackSnapshot` holds the current track, state, queue, index, history, and mode flags. The service stores it as its one published value; the old properties read and write it and keep the `playbackState` and queue-revision side effects. Position, buffering, waveform, and frequency bands stay separate streams, so 10 Hz position ticks do not re-render queue readers. The 17 per-field publishers are gone from `PlaybackServiceProtocol`; the Now Playing view model, queue projection, watch bridge, App Shortcuts, offline downloads, Aurora, and profile settings read the snapshot, through `snapshotPublisher(\.field)` where they need one field. Removed the always-false `isAutoplayActive` (D7). The `ObservableObject` facade stays until step 2. |
| `b00761bb` | The queue snapshot on disk stores the unshuffled order as item IDs plus only the items missing from the live queue, instead of a second copy of every item. Earlier snapshots still restore. An older build reading a new snapshot restores the queue but not the unshuffled order. |
| `32a01186` | G7: a shuffle toggle during an Apple Music item or a SmartMix overlap changes the switch at once and applies the reorder at the next item boundary, before the next item is chosen, without restarting the MusicKit queue. Toggling back cancels it; replacing the queue drops it. |
| `938e6e96` | G17: playback asks the same `TrackAvailabilityResolver` the UI uses to grey tracks out. Behaviour changes: a track fully cached by streaming now plays offline, and an Apple Music track is treated as unplayable offline, matching the rows. |
| `691211a9` | G18: a paused stream whose download fails, or whose network changes, is marked stale, and Play restarts it at the same position instead of resuming into a dead connection and waiting out the 30-second rebuffer timeout. A failure there follows G11. |

## The reducer, and the line budget

The design's end state is one `PlaybackState` value changed only by a pure
`reduce`, with a runner executing effects. Steps 1b to 1e did not build that
form. What exists instead:

- one rule for what follows (`EnsembleQueuePolicy.advance`);
- one session gate and one per-event acceptance rule for both engines;
- one handler each for item change, natural end, item failure, and
  progress;
- pure decision functions for failure, Now Playing state, and handoff;
- one published snapshot.

The bug classes the design targeted (diverging paths, stale async results,
flags left set, wrong generation checks) are addressed by those. What is
not reached is the size target: the playback stack is 17,427 lines (18,200
at the start of step 1, target at most 12,000), and `PlaybackService.swift`
is 7,071 lines (target: no file over 1,500). Step 1f decides how to close
that gap; see the open question in the plan.

## Checks

- EnsembleCore: all playback, Now Playing, and Siri tests pass (356). New
  test: `testUnshuffledOrderRoundTripsAsIDsAndLegacySnapshotsStillDecode`.
  The two `PlaylistDetailViewModelTests` order-dependent failures recorded in
  step 1d are unchanged.
- Builds through `scripts/build_serial.py`: iOS Simulator, watchOS
  Simulator, macOS arm64, and the EnsembleUI tests, all succeeded.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`, build `0.4.0
(202610171331.6912)` from `691211a9`, clean tree, executable hash and PID
path matched. Shut down afterwards and confirmed `Shutdown`.

| Check | Result |
|---|---|
| Restored mini player shows the restored track, paused | pass |
| Playing from a playlist updates the mini player | pass |
| Queue page lists the upcoming tracks in album order | pass |
| Shuffle on: switch highlighted and order shuffled; off: album order restored | pass |
| Repeat toggle highlights | pass |
| Next updates Now Playing and the mini player | pass |
| History lists the previous track | pass |

Not run on the simulator: G7 (needs Apple Music or a SmartMix overlap), G17
offline cases, G18 (needs a failed or moved connection while paused). They
are in the device backlog.
