# Step 1f: dead code and the PlaybackService split

Re-architecture step 1f, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the [design note](../reference/playback-state-machine-design.md)
(decision 7: keep the current shape, no full reducer). Commits `1565afe7`
to `302a5d78`, started from `9e772163`. Simulator-checked, not verified.

## What changed

| Commit | Change |
|---|---|
| `1565afe7` | Removed code Periphery found unused: fast seeking (hold-to-scan), the context-free `play(track:)`, the `PlaybackServiceProtocol` requirements and protocol-extension defaults that nothing called through the protocol, the Now Playing view model's `stop()` and add-to-queue wrappers, `NetworkTransitionDecision.shouldRefreshConnection`, and `PlaybackArtifactCache.removeAll()`. |
| `15487c8c` | `PlaybackService.swift` split into extensions by concern. Stored state, publishers, init, and observation setup stay in the core file. `private` members became internal so the other files can reach them. No behaviour change. Also dropped comments left behind by functions removed earlier. |
| `7d127734` | One table test per split concern (below). |
| `302a5d78` | Apple Music items start one at a time without the multi-item path. The service only ever handed MusicKit the current track, so resolving several tracks, skipping unresolved later ones, and pruning them from the queue never acted (design note section 4 marked it for deletion in 1f). The controller now resolves one song, catalog first and then the library, and throws the lookup error or `musicKitPlaybackRequired` as before. Removes the resolution policy's `select`, the pruning helper, and their five tests. |

### Files

| File | Lines | Concern |
|---|---|---|
| `PlaybackService.swift` | 908 | State, publishers, init, observation setup, teardown |
| `PlaybackService+Queue.swift` | 1,398 | What plays next, queue navigation and edits, shuffle, repeat, autoplay |
| `PlaybackService+Session.swift` | 1,382 | Playback commands, engine events, item failure, the transition background task |
| `PlaybackService+Loading.swift` | 1,381 | Resolving, loading, and prefetching sources; the resolved-file cache |
| `PlaybackService+Routing.swift` | 612 | Audio session, interruptions, route changes, network transitions |
| `PlaybackService+Presentation.swift` | 335 | Playback time, presentation latency, waveform, visualizer, instrumental mode |
| `PlaybackService+Persistence.swift` | 316 | Saving and restoring the queue snapshot |
| `PlaybackService+AppleMusic.swift` | 249 | MusicKit queue starts, stations, boundary rules |
| `PlaybackService+Reporting.swift` | 282 | System Now Playing, remote commands, ratings, donations |
| `PlaybackService+Downloads.swift` | 207 | Streaming-quality changes and download-state refreshes for queued items |

### Table tests

| Concern | Table |
|---|---|
| Queue | `testQueueAdvanceTable` (EnsembleDomain, from step 1b) |
| Session | `testEngineEventAcceptanceByPlaybackState`, `testItemFailureSkipsOnceThenHalts` (from 1c and 1d) |
| Apple Music | `testAppleMusicPreviousInferenceTable` (new: restart threshold and minimum jump rows) |
| Persistence | `testPlaybackSnapshotPersistenceTable`, `testRestoredPausedSeekTimeTable` (new: first save, zero time, negative, missing and invalid duration rows) |
| Reporting | `testRemoteFeedbackTable`, `testSystemFeedbackAvailabilityTable` (new: rating boundaries, no current track) |

The new tables replace eight single-case tests.

## Line budget

| | Lines |
|---|---|
| Playback stack at the start of step 1 | 18,200 |
| At `9e772163` (end of 1e) | 17,427 |
| After dead code (`1565afe7`) | 17,328 |
| After the split (`15487c8c`) | 17,452 |
| After the Apple Music cleanup (`302a5d78`) | 17,287 |
| Target | at most 12,000 |

The split adds about 125 lines of imports and file headers. No
`PlaybackService` file is over 1,500 lines now (the largest was 7,071).
`AudioPlaybackEngine.swift` (2,544) is the one file in the stack still over
that limit; it was outside this step. Under decision 7 the 12,000 target is
not reached and is not pursued further in step 1.

## Plan 1f items not done

- `PlaybackServiceProtocol` stays: test mocks conform to it.
- No `ForTesting` hooks remain in the playback stack.
- Coordinators were not folded into effect handlers; that needed the reducer.

## Clear Queue (follow-up, 2026-10-19)

`clearQueue()` had no caller after 1f. Felicity decided to keep it and add
Clear Queue to the Queue Card's More menu (`5b2792ad`), on iOS and macOS
alike since both use the card. It follows G20 as written: everything after
the current track is removed; the current track keeps playing, and History
and the already-played items before the current index stay. The previous
implementation also emptied History, which G20 does not ask for. Cleared
items also leave the unshuffled order. The action is disabled when nothing
follows the current track. Test: `testClearUpcomingTable`, replacing
`testClearRetainsCurrentItemAndClearsHistory`.

Simulator, build `0.4.0 (202610190655.5279)` from `5b2792ad`, clean tree,
identity matched, shut down afterwards:

| Check | Result |
|---|---|
| More menu lists Clear Queue in the destructive style, below Save Queue as Playlist | pass |
| After Clear Queue, the queue page shows no upcoming items and the track keeps playing | pass |
| History still lists the earlier track | pass |
| Clear Queue is disabled with nothing upcoming | pass |
| Next then pauses at the end of the queue on the current track (G2, G1); the already-prefetched next track does not play | pass |

Physical iPhone 16 Pro (`00008140-00023030117B001C`), build `0.4.0
(202610190723.8453)`, app code as at `676358bf`, installed by the test run.
Driven by `PlaybackDeviceAcceptanceUITests` (skipped unless
`ENSEMBLE_DEVICE_ACCEPTANCE=1`), with screenshots and the app's session log.

| Check | Result |
|---|---|
| `testClearQueueKeepsCurrentTrackAndHistory` with the Plex playlist "Ambient Electric", Autoplay on | pass |
| The More menu shows Clear Queue in the destructive style | pass |
| After Clear Queue every Continue Playing track is gone; Autoplay refills with recommendations, as G2 allows | pass |
| History keeps the first track; the current track keeps playing | pass |
| Next plays an Autoplay recommendation, never a cleared track | pass |

Not done on the device: the disabled state (Autoplay kept the queue
non-empty), Clear Queue during an Apple Music track, and the step 1f Apple
Music advance. The first Apple Music attempt used "am test", which turned
out to hold Plex tracks: it played three Plex tracks by gapless advance and,
by seeking near their ends, scrobbled two real Plex plays (rating keys 12323
and 13729). The test now refuses to seek unless the row is labelled Apple
Music and takes its playlist from `ENSEMBLE_DEVICE_APPLE_MUSIC_PLAYLIST`.
That run also showed 8 of the playlist's 14 items skipped because one Plex
server failed its remote probes on cellular; the 6 played came from the
stream cache, as G17 allows.

## Checks

- EnsembleCore: playback, Now Playing, Siri, and Apple Music tests pass
  (383 at `302a5d78`). EnsembleDomain `testQueueAdvanceTable` passes.
- Builds through `scripts/build_serial.py`: iOS Simulator, macOS, and
  watchOS Simulator, all succeeded at `7d127734` and again at `302a5d78`.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`, build `0.4.0
(202610171815.7127)` from `7d127734`, clean tree, executable hash and PID
path matched. Shut down afterwards and confirmed `Shutdown`.

| Check | Result |
|---|---|
| Restored mini player shows the restored track, paused | pass |
| Playing from a playlist updates the mini player and starts playback | pass |
| Next advances (log: `next()`, idx 1 then 2 of 13) | pass |
| Pause and resume | pass |
| Queue page lists the upcoming tracks in album order | pass |
| Shuffle on reorders; off restores album order | pass |
| History lists the previous tracks | pass |

The simulator run was on `7d127734`, before the Apple Music change. That
change is in iOS-only MusicKit code the simulator cannot play, so it is
compiled and unit-tested only; its check is in the device backlog. Because
the split moves code without changing it, the device checks owed from steps
1b to 1e cover the rest.
