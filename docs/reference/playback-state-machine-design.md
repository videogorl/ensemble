# Playback state machine: step 1 design

Status: draft for Felicity's review. Step 1b does not start until this is
approved. Written 2026-10-13 against `2586f6e5`. Read-only work; nothing in
the playback code has changed.

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
| `queue.unshuffledOrder` | Original order while shuffled; nil when not | `originalQueue`, `isShuffleEnabled` |
| `queue.history` | Played items for Previous and the History page | `playbackHistory`, `isNavigatingBackward` |
| `queue.repeatMode` | off, all, one | `repeatMode` |
| `queue.continuation` | `.none`, `.autoplay(exhausted: Bool)`, `.radio(seed)`, `.station(engineOwned)` | `isAutoplayEnabled`, `radioMode`, `recommendationsExhausted`, `isAutoplayActive`, station flags |
| `queue.hasUserEdits`, `queue.revision` | Edit marker; revision for the watch bridge | `hasUserQueueEdits`, `queueStateRevision` |
| `session.id` | `SessionID`, new for every load of an item into an engine | all three generation spaces |
| `session.phase` | `idle`, `restored(position)`, `resolving`, `loading(intent)`, `playing`, `paused(reason)`, `stalled`, `failed(reason)` | `playbackState`, `isSkipTransitionInProgress`, `playbackPreparationShouldStart`, `pendingPreBufferTime`, `startupRestoreStatus` |
| `session.engine` | `.native`, `.appleMusic`, or none | implicit in which controller exists and is active |
| `session.scheduledNext` | The item pre-scheduled for gapless or SmartMix, if any | engine-side scheduled-track arrays read back by the service |
| `session.retry` | Attempts used and last failure for the current item | `consecutivePlaybackFailures`, `isHandlingTLSFailure` |
| `position` | Time, duration, buffered fraction, timeline revision | `currentTime`, `duration`, `bufferedProgress`, `playbackTimelineRevision` |
| `route` | Output kind, interruption state, resume-after-interruption intent | `presentationRouteKind`, `isExternalPlaybackActive`, `isScreenMirroringActive`, `PlaybackHandoffCoordinator` state |
| `settings` | SmartMix switches, instrumental mode, quality, network state | settings mirrors and `lastObservedNetworkState` |

`paused(reason)` distinguishes user, interruption, route loss, and restored.
That one field replaces the handoff coordinator's separate record of why
playback stopped.

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
autoplay, restoration, and recovery do not donate" a property of the data
rather than of which function was called. Six non-UI origins are already
declared today and never constructed.

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
| Next, any phase | Next playable item. Repeat One does not hold a manual Next. At the end: wrap if Repeat All, else continuation, else no-op while paused or stop while playing |
| Previous | Over 3 seconds in: restart. Otherwise the previous queue item, else the last history item, else restart |
| Natural end, Repeat One | Same item again, new session |
| Natural end mid-queue | Next playable item |
| Natural end at the end, Repeat All | First playable item |
| Natural end at the end, continuation available | Continue: play fetched autoplay items, or hand over to a station |
| Natural end at the end, nothing else | Stop, keep the queue |
| Item unplayable | Skip forward to the next playable item; report it once |
| Shuffle on or off, Play Next, Play Last, move, remove | Edit the queue value; if the pre-scheduled next item changed, emit `clearScheduled` and `scheduleNext` |

Where today's two paths disagree, and which behaviour this design keeps.
These are behaviour changes on one path each, so they need a decision; see
section 9.

| # | Today | Proposed single behaviour |
|---|---|---|
| Q1 | At the end of the queue with autoplay on, native plays already-fetched autoplay items; Apple Music discards them and starts a station | Keep both, as a property of the continuation kind rather than of the path |
| Q2 | Repeat All wrap: native wraps first and then considers autoplay. Apple Music considers autoplay first and can truncate the queue from the wrapped index, which at index 0 is the whole queue (by reading) | Wrap first on both. Repeat All never truncates |
| Q3 | Natural end has guards on native only: skip in progress, re-entrancy, a limit of 3 advances in 2 seconds, stay put when failed | The session check covers the first two. Keep the rapid-advance limit and the failed-state rule for both |
| Q4 | "Current track changed" resets reporting, buffered progress, and waveform on native only | Reset on every item change, both engines |
| Q5 | `setRepeatMode` leaves an already-scheduled gapless successor in place, so the old choice plays once more (by reading) | Changing repeat re-evaluates the scheduled item |
| Q6 | Reordering while shuffled is lost when shuffle is turned off | Decide: keep the reorder, or document the loss |
| Q7 | Next during SmartMix at the end of the queue with autoplay on neither plays nor stops until the 10-second watchdog (by reading) | Same as any other Next at the end |

Apple Music stations are the one place the engine owns the order. The design
models a station as `queue.continuation = .station`: the reducer stops
deciding what is next, mirrors `itemChanged(.engineOwned)` and
`upcomingChanged`, and takes control back on any queue edit. That matches
today's behaviour, including that a queue edit during a station restarts the
current track as a finite item.

## 7. Suspected defects found on the way

Found by reading, not reproduced. None is fixed here. The plan's freeze
allows blocking bug fixes during step 1; none of these looks blocking, and
each disappears in the new path.

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

The plan's 1b to 1f hold. Three adjustments from what the inventory showed:

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

Line budget from the plan, 18,200 down to at most 12,000, still looks
reachable: the service's 36 bookkeeping properties, 70 task launches, and
duplicated transitions are where the lines are.

## 9. Decisions for Felicity

1. **Approve the state, event, and effect shapes** in sections 2 to 5, or mark
   what should change.
2. **Q1 to Q7.** Each makes one path behave like the other. The proposed
   column is the recommendation. Q6 is a real choice: keeping a reorder made
   while shuffled is the less surprising behaviour, and is recommended.
3. **External Next on an Apple Music item.** MusicKit cannot distinguish it
   from a natural end, so with Repeat One it replays instead of advancing.
   Recommended: accept as a limitation and add it to `known-issues`.
4. **Watch-initiated starts are donated as app UI today.** Recommended: give
   them the `watch` origin and stop donating, to match the other non-UI
   origins.
5. **D1 to D5.** Recommended: do not patch the old path; let 1b to 1d remove
   them, and put D1 and D3 on the simulator acceptance list for those steps.

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

The acceptance list implies 22 behaviours that no document, test, or commit
describes (inventory section 5). Examples: the final state at the end of the
queue with repeat off; Next at the last item under each repeat mode; Previous
at index 0 with no history; whether repeat mode and autoplay survive a
relaunch; Play Next with an empty queue; whether the three-failure limit
counts per track; an interruption during loading; when Stop is issued rather
than Pause.

Proposed rule: for each, 1b to 1d read what the current code does, pin that
as the table row, and list the row in the step's note. Felicity is asked only
where the current behaviour looks wrong. This keeps step 1 free of unplanned
behaviour changes.

One conflict to settle by reading before 1d:
`2026-09-06-system-playback-state.md` says a loading track publishes rate 0
to system Now Playing, while two later commits made skip loads publish
"playing", and the test that pinned it is gone.

Track radio and autoplay are live behaviour with past bugs and are missing
from the plan's step 1 acceptance list. They are added to the simulator
acceptance for 1b.
