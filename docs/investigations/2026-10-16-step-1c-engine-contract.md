# Step 1c: one engine event contract

Re-architecture step 1c, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the [design note](../reference/playback-state-machine-design.md), section 5.
Code commit `5dfdef45`, started from `a9bb183a`. Simulator-checked, not
verified: Apple Music and physical items are in the device backlog.

## What changed

- `PlaybackEngineContract.swift`: `PlaybackSessionID`, `PlaybackEngineEvent`
  and the envelope both engines emit.
- `NativePlaybackEngineAdapter`: wraps every `AudioPlaybackEngine` callback
  and the progress subject. The engine is loaded with the session's raw value
  as its generation, so its stamp is the session. Events are always delivered
  asynchronously on main, so an engine command cannot re-enter the service.
  It also owns the polling backstop for a missed gapless or SmartMix callback,
  which used to live in the service.
- `AppleMusicEngineEventAdapter`: wraps the MusicKit controller. Only callbacks
  from the controller's active queue pass, stamped with the session the service
  bound before starting that queue. MusicKit Previous inference (an observed
  restart, then a second rewind) moved here and is reported as
  `externalPrevious`.
- `PlaybackService.handleEngineEvent`: the one entry point. It drops events from
  any session but the active one, then applies one per-event state rule for
  both engines (`acceptsEngineEvent`). The only engine difference in that rule
  is declared: MusicKit reports its end while paused; a native end while
  paused is late and dropped.
- One handler per concern, shared by both engines: progress, item change
  (gapless, SmartMix midpoint, MusicKit-owned advance, station pick), natural
  end, and failure. Natural end on Apple Music now runs the same guards as
  native (rate limit, failed-state rule, handoff suppression) and the same
  station replacement rule (Q1).
- The session changes on every load into an engine and on stop, select while
  paused, and an Apple Music queue resync. It survives pause and resume:
  resume re-adopts the session instead of the request counter.
  `playbackGenerationCounter` remains only for in-flight request staleness;
  1d replaces it.

Defects removed (decision 5):

- **D3, confirmed by reading:** reporting was reset only on gapless and
  SmartMix advances. After any skip or ordinary start the next track waited
  behind the old track's timeline clock and, if the old track had scrobbled,
  never scrobbled. Now an item change on either engine, and any start from the
  beginning, resets it (Q4).
- **D5:** a station Previous now reuses the existing queue item instead of
  appending a duplicate autoplay item.
- **D7 partly:** `unexpectedPauseCount` (write-only) and the dead
  `removeScheduledTrack` path are gone.

Also removed: the per-engine Apple Music handlers, `isCurrentAppleMusicQueue`
and `shouldAcceptAppleMusicCallback`, the `isSynchronizingAppleMusicQueueMutation`
re-entrancy flag (ending the session before the controller stops does the same
job), `appleMusicPreviousRestartGeneration`, and the service's reconcile
helper. Tests that pinned them were replaced by one acceptance table,
`testEngineEventAcceptanceByPlaybackState`.

Dropped from the Apple Music acceptance check, deliberately: "Apple Music is
enabled" and "current track is Apple Music". The session already identifies
the Apple Music item that was started; disabling the source tears playback
down separately.

Added one log line, `SCROBBLE: trackId=… at …s of …s`, at the reporting owner,
so a scrobble is visible in session logs.

Lines: `PlaybackService.swift` 7,289 to 7,040; the contract and two adapters
add 267.

## Checks

- `swift test` for the playback groups in EnsembleCore (166 tests) and the
  reporting and service groups after the log line: all pass.
- Builds through `scripts/build_serial.py`: iOS Simulator, watchOS Simulator,
  macOS arm64, all succeeded.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1` (iPhone 17 Pro, iOS 26.5).
Prepared with `scripts/prepare_runtime.py`, run directory
`/tmp/ensemble-step1c-sim`, source `5dfdef45`, clean tree, build
`0.4.0 (202610161813.5452)`, executable hash and PID path matched, same PID
throughout. Driven with `agent-device`. Shut down afterwards and confirmed
`Shutdown`.

| Check | Result | Evidence |
|---|---|---|
| Restored track resumes (prebuffer and session re-adopt path) | pass | Tessellate played from the mini player |
| Pause and resume keep the session | pass | Paused at 1:13; 1:18 five seconds after Play |
| Stream seek reload | pass | `seek(stream-restart)` then playing at 2:50 |
| D3 reporting reset on an ordinary start | pass | After Tessellate reported at 168 s, Next started Taro and Taro reported at 10 s; before the fix the next report waited until about 178 s. The same reset clears the scrobble gate |
| Gapless advance through the adapter | pass | `ITEM_CHANGED: 'Taro' (idx 3) → 'Breezeblocks' (idx 4) via gapless`; Breezeblocks reported from 10 s |
| Natural end at the last item through the adapter | pass | `QUEUE_EXHAUSTED` then `handleQueueExhausted-endOfQueue`; Paladin Strait paused at 0:00 |

The scrobble itself was not observed: scrobbling is switched off in this
simulator's settings, and turning it on would change play counts in the real
Plex library. Not run: anything on Apple Music (no Apple Music on this
simulator) and the Mac app.
