# Step 1d: session lifecycle

Re-architecture step 1d, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the [design note](../reference/playback-state-machine-design.md).
Commits `68979441` to `2544a52a`, started from `bc523c16`. Simulator-checked,
not verified: physical, Apple Music, and Mac items are in the device backlog.

## What changed

Done in slices, each committed and tested:

| Commit | Change |
|---|---|
| `68979441` | D1: network observation now lasts for the service's lifetime, so `cleanup()` on Stop no longer cancels it. D4: the engine's started event reports "playing" to Plex on a fresh start. Removed dead `loadingStateTask`, `prefetchThrottleUntil`, `handoffEventCounter`. |
| `2aa7585f` | G11, G12: one `handleItemFailure` for every item failure (load, TLS after its refresh, Apple Music start, engine error mid-play). While the intent is to play, a failed item is skipped once; if the item reached by that skip also fails, or the intent was to stay paused, playback halts with Retry. The three-strike `consecutivePlaybackFailures` counter and `failTLSPlayback` are gone; TLS refreshes the connection once per item. The failure hook takes a list of tracks. |
| `fbb0ca51` | G14: a load that finishes during an interruption or after a lost route ends paused, not buffering, so only the should-resume hint resumes it. G22: Mac sleep and wake go to the handoff coordinator as an interruption that ends without a resume hint. |
| `16d19d58` | One session ID. The request counter and the engine session are now one value, `sessionGeneration`. It advances on every load request, stop, select while paused, Apple Music resync, station start, skip, and a pause that cancels a load. Pausing playback keeps the session. Removed `isSkipTransitionInProgress` (20 writes), its 10-second watchdog, `isHandlingTLSFailure` and the natural-end wait loop, and the stale AVPlayer watchdog comments (answering design question Q6: the watchdog was not live). Remote skips are accepted while loading (G4). |
| `d4af2959` | The service is `@MainActor`. Pure statics are `nonisolated`; the launch coordinator's callbacks are main-actor; `deinit` tears down directly. The download-state refresh no longer passes the live queue `inout` across an `await`. |
| `b137af02` | G20: the rapid-advance limit (Q3) pauses on the current item instead of stopping. G10: Play Next or Play Last with no current item starts playback. |
| `9afd31ff` | System Now Playing publishes a loading or buffering item as playing only when the intent is to play, matching Apple Music. |
| `c2955b21`, `2544a52a` | G5: a seek during a load is held for that item and applied when it starts, across retries of the same item; seeking to the exact end while paused applies the end-of-track rule without playing. |

`PlaybackService.swift` is 7,023 lines (7,040 after 1c).

### Not done in 1d, and why

- **No reducer type or effect runner yet.** Lifecycle decisions now live in
  single pure functions next to the queue rule: `acceptsEngineEvent`,
  `itemFailureResponse`, the handoff coordinator, and
  `systemPlaybackState`. The state they read is still the service's
  `@Published` fields, and async work still runs in service methods guarded
  by the session. Putting that state into one `PlaybackState` value and
  running effects from a reducer needs the snapshot that 1e introduces.
- **Remaining G rows:** G7 (shuffle toggled during an Apple Music track or
  SmartMix transition), G17 (one playability answer for the UI), G18
  (silent stream refresh after a long pause; today the existing recovery
  path runs), and the unshuffled order as IDs in the snapshot. These
  touch the snapshot and the UI, so they move to 1e.
- **"Clear queue" under G20 is unresolved.** `clearQueue()` keeps the
  current track playing and clears what follows it. A literal reading of
  G20 would stop playback and clear everything. That is a visible change,
  so it waits for Felicity's answer.

## Checks

- EnsembleCore playback tests: 314 pass, repeated six times after the
  launch-coordinator fix. The full EnsembleCore suite has two
  `PlaylistDetailViewModelTests` failures that also fail without these
  changes and pass when run alone; they are order-dependent and unrelated.
- New tests: `testItemFailureSkipsOnceThenHalts`,
  `testFailureHookMatchesAnyListedTrack`,
  `testSystemNowPlayingStateDuringALoadFollowsIntent`; coordinator tests
  updated for the new remote-skip rule.
- Builds through `scripts/build_serial.py`: iOS Simulator, watchOS Simulator,
  macOS arm64, all succeeded on the final commit.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1` (iPhone 17 Pro, iOS 26.5).
Each run was prepared with `scripts/prepare_runtime.py` from a clean tree.
Relaunches with failure-hook environment variables were checked against the
same installed executable path. Shut down afterwards and confirmed
`Shutdown`.

| Check | Build | Result | Evidence |
|---|---|---|---|
| G11: REDLIGHTS fails (TLS, after its one refresh) | `2aa7585f` | pass | `ITEM_FAILED ... skipping to idx 1`, then Paladin Strait `firstAudibleRender` and playing |
| G11: REDLIGHTS and Paladin Strait both fail | `2aa7585f` | pass | Skip after REDLIGHTS, then `ITEM_FAILED: 'Paladin Strait' ... halting`; UI shows the error and Retry |
| Retry retries the current track | `2aa7585f` | pass | `caller: retryCurrentTrack(manual)` on Paladin Strait |
| Rapid Next twice | `16d19d58` | pass | Landed on Tessellate, playing; two `SKIP: next()` lines, no stale-event drops |
| Previous within three seconds | `16d19d58` | pass | Back to Ripe & Ruin |
| Pause and resume keep the session | `16d19d58` | pass | Paused at 0:07, 0:13 five seconds after Play |
| Gapless advance after a seek | `16d19d58` | pass | `ITEM_CHANGED ... via gapless` |
| G5: seek to the end while paused | `c2955b21` | pass | `QUEUE_NAVIGATE_PAUSED: seekToEnd`, next item paused at 0:00 |
| G5: seek during a held load | `c2955b21` | fail, then fixed | The TLS retry of the same item dropped the pending seek |
| G5: seek during a held load | `2544a52a` | pass | Restored at 2:15, scrubbed to 1:59 during the load, started at 1:59 (`seek requires stream restart at 119.35s`), then 2:02 |
| Relaunch restores paused on the same track and position (G13) | `2544a52a` | pass | Breezeblocks restored paused at 2:15 |

Observed, unchanged: while an item loads, the in-app centre button sends
Play (ignored as `resume ignored ... playbackState=loading`), so a load
cannot be paused from that button. Pause during a load is covered only by
reading.

Not run on the simulator: interruptions (G14), Mac sleep (G22), Apple Music,
and Lock Screen state while loading.
