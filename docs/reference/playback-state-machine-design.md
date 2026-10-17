# Playback state machine: step 1 design

Status: approved. Written 2026-10-13 against `2586f6e5`. Felicity approved
decisions 1 to 5 on 2026-10-14, decision 6 on 2026-10-16, and decision 7
on 2026-10-17; section 9 records them, and they are folded into the
sections they affect. Steps 1b to 1e are implemented. Decision 7 replaces
the full reducer with the shape 1b to 1e built; read sections 2 to 5 as the
target model, not the code.

This is the detailed design that
[`rearchitecture-plan.md`](rearchitecture-plan.md) step 1a asks for. It turns
the outline in plan section 4.3 into concrete state, events, and effects, and
lists the decisions that are Felicity's to make.

The raw inventories are in
[`docs/investigations/artifacts/2026-10-13-playback-inventory/`](../investigations/artifacts/2026-10-13-playback-inventory/).
Line numbers there and here refer to `2586f6e5`. Findings marked "by reading"
were not reproduced at runtime.

## 1. What the inventory found

| Measure | Count |
|---|---:|
| Stored properties in `PlaybackService` | 106 |
| of which real playback state | 27 |
| of which bookkeeping for in-flight side effects | 36 |
| of which dependencies | 29 |
| of which derivable from other state | 9 |
| of which dead or write-only | 5 |
| Further mutable properties in the engine, Apple Music controller, and coordinators, by a rough count | about 170 |
| Ways control enters the service | 109 |
| Side effects the service performs | 82 |
| Unstructured `Task` launches in the file | 70 |

The plan's section 3 said 143 stored variables. The careful count is 106 in
the service itself; the rest of the state already lives in collaborators.

Inbound control by kind: 39 commands, 21 engine callbacks (13 native, 8 Apple
Music), 19 system events, 30 completions of work the service started.

The five findings that shape the design:

1. **"Is this callback still current" has three answers.** Native callbacks
   check the service's request counter, Apple Music callbacks check the
   controller's own queue generation, and the native engine keeps a third
   private one. The service counter is bumped by pause and re-adopted on
   resume, so it identifies the latest request, not the track that produced
   an event. An Apple Music progress event survives a service-side pause or
   new start until MusicKit actually stops.
2. **One transition phase is spread over four fields with repair code.**
   `isSkipTransitionInProgress` has 20 write sites, is set by every load and
   not only by skips, and has a 10-second watchdog to un-stick it. It overlaps
   `playbackState == .loading`, `playbackPreparationShouldStart`, and
   `pendingPreBufferTime`.
3. **The same transition has several implementations.** Advancing to the next
   track: five. "Current track changed" bookkeeping: four. Pause: six
   variants. Entering `.failed`: 18 sites with different cleanup. Teardown:
   four.
4. **Most queue policy is already shared.** Both engines are driven from the
   same service methods and `EnsembleQueuePolicy`. The differences are
   concentrated in natural completion, end of queue, Apple Music stations, and
   commands issued from outside the app.
5. **The class has no isolation.** It is not an actor. Fourteen public
   mutators are not `@MainActor`, and two engine callbacks write state without
   hopping to main.

## 2. State

One value. Everything the app renders or decides from comes from here.

```swift
struct PlaybackState: Equatable, Sendable {
    var queue: PlaybackQueue
    var session: PlaybackSession
    var position: PlaybackPosition
    var route: PlaybackRoute
    var settings: PlaybackSettings      // read-only inputs, updated by events
}
```

| Part | Holds | Replaces today |
|---|---|---|
| `queue.items`, `queue.currentIndex` | The one live queue, in play order | `queue`, `currentQueueIndex` |
| `queue.unshuffledOrder` | Original order while shuffled, as item IDs; nil when not. A reorder made while shuffled is carried into it (Q6) | `originalQueue`, `isShuffleEnabled` |
| `queue.history` | Played items for Previous and the History page | `playbackHistory`, `isNavigatingBackward` |
| `queue.repeatMode` | off, all, one | `repeatMode` |
| `queue.continuation` | `.none`, `.autoplay(exhausted: Bool)`, `.radio(seed)`, `.station(engineOwned)` | `isAutoplayEnabled`, `radioMode`, `recommendationsExhausted`, `isAutoplayActive`, station flags |
| `queue.hasUserEdits`, `queue.revision` | Edit marker; revision for the watch bridge | `hasUserQueueEdits`, `queueStateRevision` |
| `queue.pendingShuffle` | A shuffle toggle made during an Apple Music track or a SmartMix transition, applied when it finishes (G7) | none |
| `session.id` | `SessionID`, new for every load of an item into an engine | all three generation spaces |
| `session.phase` | `idle`, `restored(position)`, `resolving`, `loading(intent, pendingSeek)`, `playing`, `paused(reason)`, `stalled`, `failed(reason, intent)`. There is no stopped phase: Stop leaves `idle` with an empty queue | `playbackState`, `isSkipTransitionInProgress`, `playbackPreparationShouldStart`, `pendingPreBufferTime`, `startupRestoreStatus` |
| `session.engine` | `.native`, `.appleMusic`, or none | implicit in which controller exists and is active |
| `session.scheduledNext` | The item pre-scheduled for gapless or SmartMix, if any | engine-side scheduled-track arrays read back by the service |
| `session.retry` | Whether the current item was reached by skipping a failed one, and the last failure. No counter (G11) | `consecutivePlaybackFailures`, `isHandlingTLSFailure` |
| `position` | Time, duration, buffered fraction, timeline revision | `currentTime`, `duration`, `bufferedProgress`, `playbackTimelineRevision` |
| `route` | Output kind, interruption state, resume-after-interruption intent | `presentationRouteKind`, `isExternalPlaybackActive`, `isScreenMirroringActive`, `PlaybackHandoffCoordinator` state |
| `settings` | SmartMix switches, instrumental mode, quality, network state, and per-source and download availability. `playability(item, settings)` is a pure function the UI also calls to grey tracks out (G17) | settings mirrors, `lastObservedNetworkState`, UI-side availability checks |

`paused(reason)` distinguishes user, interruption, route loss, end of queue,
and restored. That one field replaces the handoff coordinator's separate
record of why playback stopped. Mac sleep is an interruption (G22).

`loading` and `failed` keep the intent, so a load or a failure never turns a
paused session into a playing one (G12). `loading(intent: .play)` is the only
loading state published to system Now Playing as playing; this matches Apple
Music, and a track that loads while paused stays paused.

**Shuffle representation.** Felicity asked whether keeping the original
order adds too much overhead, and how other players do it. There are two
common models. Android's Media3 keeps items in their original order and holds
shuffle as a separate immutable permutation that is cloned on every insert,
remove, and move ([`ShuffleOrder`](https://developer.android.com/reference/androidx/media3/exoplayer/source/ShuffleOrder)).
Apple Music and Spotify present the shuffled list as the queue and restore
the set order when shuffle is turned off; MusicKit exposes no unshuffled
order, so an app that wants one keeps its own copy. Ensemble uses the second
model because the queue UI, the watch bridge, MusicKit's one-item queue, and
history all read play order directly, and a permutation would put an
indirection in every one of those reads. The cost today is that
`originalQueue` holds a second full copy of every `QueueItem`, including its
`Track`, and the queue snapshot encodes both. Holding the original order as
IDs instead keeps the model and removes the duplicate. It lands in 1d with the
persistence handler, not 1b: turning shuffle on drops already-played items
from the live queue, so the IDs need those items kept somewhere, and the
snapshot must still decode the old field.

Not in the state: waveform and frequency data, artwork, lyrics. They are
presentation data loaded by effect handlers and published beside the snapshot.

## 3. Events

Four kinds, as in the plan. Every engine and resolution event carries the
`SessionID` it belongs to, and the reducer drops a mismatch in one place.

| Kind | Cases | Today |
|---|---|---|
| `command` | play, shufflePlay, playIndex, playFromHistory, pause, resume, toggle, stop, next, previous, seek, playNext, playLast, move, remove, clear, setShuffle, setRepeat, setAutoplay, startRadio, retry. Each carries an origin: appUI, remoteCommand, siri, appShortcut, watch, restoration, recovery | 39 entry points |
| `engine` | The normalized set in section 5 | 21 callbacks on two unrelated surfaces |
| `system` | interruptionBegan, interruptionEnded(shouldResume), routeChanged, networkChanged, appLifecycle, settingsChanged, sourcesChanged, downloadsChanged, timerFired(kind) | 19 observers |
| `resolved` | sourceResolved, playableQueueResolved, autoplayFetched, stationStarted, restoreLoaded, downloadStateRefreshed, each with success or failure | 30 continuations, five of which check nothing after the await |

The command origin is what makes "Siri, App Shortcuts, remote commands,
the watch, autoplay, restoration, and recovery do not donate" a property of
the data rather than of which function was called. Six non-UI origins are
already declared today and never constructed. Watch-initiated starts are
donated as app UI today; they take the `watch` origin and stop donating
(decision 4).

## 4. Effects

The reducer returns these. A runner executes them and feeds results back as
events. No effect handler writes playback state.

| Effect | Handler | Feeds back |
|---|---|---|
| `resolve(item, session)` | Transport coordinator: cached file, download, direct stream, or transcode | `resolved.sourceResolved` |
| `load`, `play`, `pause`, `seek`, `stop`, `scheduleNext`, `clearScheduled`, `setRepeatOne` | The engine adapter named in `session.engine` | `engine.*` |
| `configureAudioSession`, `deactivateAudioSession` | Audio session coordinator | `system.interruption*`, `system.routeChanged` |
| `publishNowPlaying` | Now Playing bridge, the only writer of `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` | remote commands arrive as `command` |
| `report(timeline or scrobble)` | Reporting controller | none |
| `persistQueue` | Queue store | none |
| `prefetch(items)`, `cancelPrefetch` | Prefetch through the transport coordinator | `resolved.*` |
| `fetchAutoplay(seed)`, `startStation(seed)` | Radio providers, Apple Music adapter | `resolved.autoplayFetched`, `resolved.stationStarted` |
| `donate(start)` | System media integration | none |
| `startTimer(kind, after)`, `cancelTimer(kind)` | Runner | `system.timerFired` |
| `beginBackgroundTask`, `endBackgroundTask` | Runner | none |
| `log(journey)`, `toast` | Logger, toast centre | none |

Timers become data. The stall watchdog, the deferred pre-buffer, the
near-end lease, and retry backoff are `startTimer` effects whose firing is an
event checked against the session like any other. The 36 task handles and
tokens that exist to cancel or ignore late work go away with them.

## 5. Engine contract

Two engines stay. Each gets an adapter that accepts the engine effects above
and emits this one event type.

```swift
struct EngineEventEnvelope: Sendable {
    let session: SessionID
    let event: EngineEvent
}

enum EngineEvent: Sendable {
    case prepared(duration: TimeInterval?, isSeekable: Bool)
    case started                              // audio is reaching the output
    case progress(position: TimeInterval)
    case buffered(fraction: Double)           // native only
    case stalled(Bool)                        // native only
    case itemChanged(EngineItem, via: AdvanceKind)   // gapless, crossfade, engineOwned
    case transitionActive(Bool)               // native only, SmartMix overlap
    case ended                                // finished with nothing scheduled
    case externallyPaused                     // Apple Music only
    case externallyResumed                    // Apple Music only
    case upcomingChanged([Track])             // Apple Music stations only
    case outputReconfigured(position: TimeInterval, isPlaying: Bool)
    case failed(EngineFailure, position: TimeInterval?)
}
```

What each adapter must do, and what it cannot do:

- **Native.** Stamp every event with the session passed in `load`. Its
  private schedule and progress generations stay inside the adapter. `ended`
  must stop firing synchronously from inside `play`, `seek`, and
  `clearScheduled`; today the skip flag absorbs that.
- **Apple Music.** Stamp events with the session from the start effect. It
  cannot supply `stalled` or `buffered`, cannot give a reason for a pause, and
  cannot tell an external Next from a natural end. `ended` rests on four
  heuristics and a poll. The reducer must not depend on signals this adapter
  cannot give; the adapter must not invent them.
- **MusicKit queue.** Finite queues stay one item long and disposable. The
  controller still carries multi-item resolution and pruning code that this
  contract makes unreachable; it is deleted in 1f.

The coordinators become:

| Today | Becomes |
|---|---|
| `PlaybackSessionStateMachine` (stateless despite the name), `PlaybackStartupCoordinator`, the timing predicates in `PlaybackPrefetchController`, `PlaybackHandoffCoordinator`, `EnsembleQueuePolicy` | Reducer logic and reducer state |
| `PlaybackTransportCoordinator`, `PlaybackAudioSessionCoordinator`, `PlaybackNowPlayingBridge`, `PlaybackReportingController`, `PlaybackQueueStore`, `PlaybackArtifactCache`, `PlaybackResolvedFileCache` | Effect handlers |
| `PlaybackLaunchCoordinator`, the pass-through half of `PlaybackPrefetchController`, `PlaybackQueueController` | Deleted; the reducer and runner replace them |

## 6. Queue policy

One function decides what follows the current item. It is used for natural
completion, Next, gapless scheduling, and SmartMix, on both engines.

| Situation | Decision |
|---|---|
| Next, mid-queue | Next playable item. Repeat One does not hold a manual Next |
| Next at the last item | Repeat All or Repeat One: wrap to the first item (G3). Repeat off: the autoplay item if autoplay is on, else as natural end with nothing else (G2) |
| Next at a Plex and Apple Music boundary | The new item becomes current at once, in `loading` (G16) |
| Previous | Over 3 seconds in: restart. Otherwise the previous item in the order heard, which under shuffle is history, skipping unavailable items; at the first item with no history, restart. Keeps the paused or playing intent. During a load: cancel the load and go back (G4) |
| Natural end, Repeat One | Same item again, new session |
| Natural end mid-queue | Next playable item. Locked or not, an uncached Plex item streams normally (G15) |
| Natural end at the end, Repeat All | First playable item |
| Natural end at the end, continuation available | Continue: play fetched autoplay items, or hand over to a station |
| Natural end at the end, nothing else | Stay on the last item, `paused(.endOfQueue)` at position 0, keep the queue (G1) |
| Seek | Applies to both engines and to remote scrubs alike, and keeps the paused or playing intent (G5, G6). During a load: held in `pendingSeek` and applied when the item starts. Past the buffered part: `stalled`, then resume. To exactly the end: treated as a natural end |
| Item fails | Skip to the next playable item. If the item reached by that skip also fails, halt in `failed` and offer Retry, which retries the current item. No counter (G11). Applies to a locked advance (G15) and to a refresh on Play (G18) |
| Play after a long pause | If the stream expired or the network changed, re-resolve silently at the same position (G18) |
| Play from `restored` | Resolve from the restored position, including offline and transcode checks (G13) |
| Item unplayable | Skip forward to the next playable item; report it once. The same `playability` answer greys it out in the UI (G17) |
| Play Next, Play Last, Start Radio | With no queue: start playback. With a queue: edit it and keep the current intent; a paused queue stays paused (G10, G21) |
| Shuffle on or off | Keep the current item and re-pick the next. During an Apple Music item or a SmartMix transition: record in `queue.pendingShuffle` and apply when it finishes (G7) |
| Move, remove | Edit the queue value. Moving or removing the scheduled next item cancels its prefetch and schedules the new next item. Removing the last item mid-transition ends as natural end with nothing else (G9) |
| Any edit that changes the scheduled next item | Emit `clearScheduled` and `scheduleNext` |
| Interruption begins | During a load or handoff, let it finish, then pause. Otherwise pause. Resume only on the system's should-resume hint; locked or not, stay paused otherwise (G14) |
| Stop | Only on sign-out or server removal. Clears the current item and the queue. Every other halt is Pause (G20, amended 2026-10-17) |
| Clear queue | Keeps the current item playing and clears only the upcoming items (G20, amended 2026-10-17) |
| Relaunch | Restore paused, on the same item and position, with shuffle, repeat, and autoplay (G8, G13) |

The Mac follows the same table: seek, track endings, relaunch, and route
changes behave as on iOS, and all windows share one player (G19, G22).

Where today's two paths disagree, and which behaviour this design keeps.
These are behaviour changes on one path each. Felicity approved the right
column on 2026-10-14 (decision 2).

| # | Today | Single behaviour |
|---|---|---|
| Q1 | At the end of the queue with autoplay on, native plays already-fetched autoplay items; Apple Music discards them and starts a station | Keep both, as a property of the continuation kind rather than of the path |
| Q2 | Repeat All wrap: native wraps first and then considers autoplay. Apple Music considers autoplay first and can truncate the queue from the wrapped index, which at index 0 is the whole queue (by reading) | Wrap first on both. Repeat All never truncates |
| Q3 | Natural end has guards on native only: skip in progress, re-entrancy, a limit of 3 advances in 2 seconds, stay put when failed | The session check covers the first two. Keep the rapid-advance limit and the failed-state rule for both |
| Q4 | "Current track changed" resets reporting, buffered progress, and waveform on native only | Reset on every item change, both engines |
| Q5 | `setRepeatMode` leaves an already-scheduled gapless successor in place, so the old choice plays once more (by reading) | Changing repeat re-evaluates the scheduled item |
| Q6 | Reordering while shuffled is lost when shuffle is turned off | Keep the reorder: a moved item keeps its new neighbour when shuffle is turned off |
| Q7 | Next during SmartMix at the end of the queue with autoplay on neither plays nor stops until the 10-second watchdog (by reading) | Same as any other Next at the end |

Apple Music stations are the one place the engine owns the order. The design
models a station as `queue.continuation = .station`: the reducer stops
deciding what is next, mirrors `itemChanged(.engineOwned)` and
`upcomingChanged`, and takes control back on any queue edit. That matches
today's behaviour, including that a queue edit during a station restarts the
current track as a finite item.

## 7. Suspected defects found on the way

Found by reading, not reproduced. None is patched in the old path
(decision 5). The plan's freeze allows blocking bug fixes during step 1;
none of these looks blocking, and each disappears in the new path: D2 in 1b,
D3 and D5 in 1c, D1 and D4 in 1d.

| # | Finding | Where |
|---|---|---|
| D1 | Network-transition handling appears to stop after the first `stop()`: `cleanup()` cancels the observation, and only `init` installs it | `PlaybackService.swift:6959`, `:1340`, `:3433` |
| D2 | After any Previous, the next gapless advance skips its history entry: `isNavigatingBackward` is cleared only there | `:1630-1633` |
| D3 | Reporting is not reset on an ordinary track start, so scrobble and timeline gating may carry over between non-gapless tracks | `:1643`, `:1688`, `:6853` are the only reset sites |
| D4 | Apple Music produces no timeline reporting from the service, and native reports "playing" on resume but not on a fresh start | inventory B, finding F8 |
| D5 | External Previous inside a station may append a duplicate autoplay item | `:6357-6366` |
| D6 | The audio render callback takes locks and dispatches to main on the audio thread | `AudioPlaybackEngine.swift:1142-1161` |
| D7 | Dead state: `loadingStateTask` is never assigned, `prefetchThrottleUntil` never written, `unexpectedPauseCount` never read, `isAutoplayActive` is always false yet published | inventory A |

D6 is inside the engine and outside step 1's boundary. It is recorded here
and not addressed.

## 8. How the sub-steps change

The plan's 1b to 1f hold. Four adjustments from what the inventory and the
gap decisions showed:

- **1b is smaller than planned and should also create the state value.**
  Queue policy is mostly shared already. 1b introduces `PlaybackQueue`, the
  single "what follows" function, and its table tests, then routes the five
  advance implementations and the two completion paths through it. It fixes
  Q2, Q5, and Q7 as a consequence.
- **1c carries the most risk.** Replacing three generation spaces with one
  `SessionID` touches every callback. Do the native adapter first, behind the
  existing service, and the Apple Music adapter second.
- **Add isolation in 1d.** The reducer's owner becomes a single
  `@MainActor` type. This removes the unsynchronised mutators without
  enabling strict concurrency, which stays out of scope.
- **Simulator acceptance additions.** 1b: Previous followed by a gapless
  advance keeps both history entries (D2), Repeat All wraps without
  truncating on both engines (Q2), changing repeat changes the scheduled
  successor (Q5), and a reorder made while shuffled survives turning shuffle
  off (Q6). 1c: a second ordinary track start reports and scrobbles from zero
  (D3). 1d: network-change handling still works after a Stop (D1).
- **Extend the failure hook.** `ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_TRACK`
  takes one track. Proving G11 needs two consecutive tracks to fail, so the
  hook takes a list in the step that changes failure handling.

Line budget from the plan, 18,200 down to at most 12,000, still looks
reachable: the service's 36 bookkeeping properties, 70 task launches, and
duplicated transitions are where the lines are.

## 9. Decisions

Decisions 1 to 5 were approved on 2026-10-14 and decision 6 on 2026-10-16.

1. **State, event, and effect shapes** in sections 2 to 5: approved as
   designed. The shuffle review kept the model and changed only how the
   original order is held (section 2).
2. **Q1 to Q7:** approved as proposed. Q6 keeps a reorder made while
   shuffled.
3. **External Next on an Apple Music item under Repeat One** replays instead
   of advancing, because MusicKit cannot tell it from a natural end.
   Accepted as a limitation and recorded in `known-issues`.
4. **Watch-initiated starts** take the `watch` origin and are no longer
   donated, matching the other non-UI origins.
5. **D1 to D5:** not patched in the old path. 1b to 1d remove them; D1 and D3
   are on the simulator acceptance for their steps (section 8).
6. **The 22 undocumented behaviours, G1 to G22:** decided individually. The
   rulings are in inventory `E-edge-cases.md` section 5 and are applied in
   sections 2 and 6. G20 was amended on 2026-10-17: Clear Queue keeps the
   current track playing.
7. **Step 1f keeps the current shape (2026-10-17).** The full reducer, one
   `PlaybackState` value changed only by `reduce` with an effect runner, is
   not built. Steps 1b to 1e left one queue rule, one session gate and
   acceptance rule for both engines, one handler each for item change,
   natural end, and item failure, pure decision functions, and one
   published snapshot. 1f deletes dead code and splits `PlaybackService`
   into focused files (queue, session lifecycle, Apple Music, persistence,
   reporting), each with table tests. The reducer may be revisited after
   device testing if transition bugs persist.

## 10. Contracts and past bugs to carry over

From `docs/investigations/`, the `known-issues`, `architecture`, and
`app-policies` skills, the playback test names, and the 150 most recent of
263 playback commits. Full tables: inventory `E-edge-cases.md`, sections 1 to
4. Commit messages have almost no bodies, so root causes for the newer
commit-only bugs are a reading of the diffs.

| | Count |
|---|---:|
| Behaviour contracts | 162 |
| that are pure reducer decisions | 78 |
| that an effect handler must preserve | 52 |
| that need both | 20 |
| that are engine internal | 12 |
| Past playback bugs | 68 |
| in the class the reducer removes: diverging paths 16, stale async result 14, state left set 11, wrong generation check 4 | 39 |
| Open limitations the rebuild must not worsen or claim to fix | 16 |

Every reducer contract becomes a row in a reducer table. Every past bug in
the removable class gets the row that would have caught it. Existing tests
that pin flags, generations, or `ForTesting` hooks are deleted with the code;
the inventory's section 4 lists which test groups carry a contract worth
re-expressing.

The five contracts most likely to be lost, because they are not simple "drop
the stale event" cases:

1. **MusicKit remote Next and Previous.** Next appears as a reset to time 0;
   Previous is inferred only after an observed restart. These live in the
   Apple Music adapter, which must turn them into commands before the reducer
   sees them.
2. **Stale Apple Music completions.** A late completion must re-assert the
   latest stop or pause on the shared player. Dropping the event is not
   enough; the reducer must answer a stale Apple event with a corrective
   effect.
3. **Paused seek.** Paused intent must survive a stream reload, a connection
   refresh, and a TLS retry. Fixed on 2026-10-03. In this design it is
   `loading(intent: .stayPaused)`.
4. **Unknown server health never filters or strands the queue.** Fixed twice
   in opposite directions. Playability takes a three-valued input: available,
   unavailable, unknown; unknown is playable.
5. **Gapless schedule.** Invalidate only when the immediate next item changes,
   and every audible advance must emit an event. Three past "UI one track
   behind" bugs came from this.

### Behaviours no document states

The acceptance list implied 22 behaviours that no document, test, or commit
described (inventory section 5). Felicity decided all of them on 2026-10-16;
section 6 carries the rulings, and inventory section 5 lists each one beside
the gap it closes. They are target behaviour, not a record of today's code.
Where 1b to 1d find the current code doing something else, the step's note
lists the difference as an approved change.

The same decision settles the conflict between
`2026-09-06-system-playback-state.md` and the later skip-load commits:
system Now Playing publishes a loading track as playing only if the user
pressed Play (section 2).

Track radio and autoplay are added to the plan's step 1 acceptance list as
ordinary queue sources (G21).
