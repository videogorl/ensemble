# Ensemble re-architecture plan

Status: plan accepted by Felicity on 2026-10-13. Step 0 is implemented and
Mac-checked; its iPhone surface pass is still owed. Steps 1 to 6 not started.
Written 2026-10-13 against `790e7ed5` on `develop`.
Owner: Felicity. Any agent picking up a step must read this whole file first.

This is a living plan. Update it when a step finishes, when a decision
changes, or when a step's detailed design is written. Do not let it drift into
a history log; finished steps shrink to one line plus a link to their
verification note in `docs/investigations/`.

## 1. Goal

Make Ensemble smaller, more stable, and cheaper to change, without restarting
it and without removing features. Concretely:

- Playback stops breaking. This is the worst pain today.
- A change in one area cannot silently break another. The example that
  prompted this plan: the Screen Mirroring Now Playing view stopped working
  and nothing noticed.
- A third music source such as Jellyfin can be added by writing an adapter,
  not by editing shared code.
- The watch reaches parity where parity makes sense on a watch.
- Source lines outside tests drop by 25 to 30 percent while watch downloads
  and watch playlist management are added. This figure is an estimate and a
  target, not a measurement.

## 2. Settled decisions

Decided by Felicity on 2026-10-13. Do not reopen these without asking.

| Topic | Decision |
|---|---|
| Approach | Incremental rebuild inside the existing app. No rewrite, no long-lived branch. Each step ships on `develop`. |
| OS floors | iOS and iPadOS 17, macOS 15, watchOS 10. iOS 15 and 16 and macOS 12 to 14 support is removed. |
| Sources | The app stays multi-source. Nothing in shared code may be hard-coded to Plex or Apple Music. Jellyfin is the expected third source. Design the interface for it now; do not build Jellyfin yet. |
| Watch | Parity where it makes sense. Playlist management and downloads: yes. Track metadata editing: no. |
| Store | SQLite through GRDB is allowed as a new dependency. A persisted-data migration is allowed. |
| Migration | A one-time library resync after the store move is acceptable, provided downloads, offline selections, and pending edits carry over. |
| Features | No feature is cut. StageFlow, song.link sharing, moods, cross-source merging, and the logs screen were each confirmed as important. |
| Tests | The existing suite may be cut hard. Tests that pin internals of replaced code are deleted with that code. |
| Freeze | A scoped feature freeze applies to the subsystem being rebuilt. See section 6. |
| Verification | Nothing is called good until it has been exercised on the physical iPhone 16 Pro through Device Hub. See section 7. |
| Delegation | Subagents and the `codex` CLI may be used for implementation. |
| TestFlight | No TestFlight builds during this work. They resume when the project is done. A git tag before each step is the rollback point. |
| Devices | iPhone 16 Pro approved now. The paired Apple Watch and iPad Pro are approved for their steps; ask Felicity to connect them first. |
| Low-memory devices | No 2 GB device is a test target. Keep paging and memory discipline in code. |
| Screen Mirroring | The broken external-display Now Playing view is parked. Do not diagnose it until asked. It stays on the surface checklist as known-broken. |

## 3. Evidence

Measured at `790e7ed5`. Re-measure with the commands in section 8 before
quoting these numbers again.

### Size

| Unit | Source lines | Test lines |
|---|---:|---:|
| EnsembleCore | 69,802 | 38,674 |
| EnsembleUI | 47,505 | 2,924 |
| EnsemblePersistence | 8,284 | 4,501 |
| EnsembleAPI | 6,527 | 2,707 |
| Ensemble app target | 4,078 | 203 |
| EnsembleWatch app target | 3,914 | 0 |
| EnsembleWatchCore | 3,761 | 739 |
| EnsembleDomain | 1,235 | 267 |
| EnsembleSiriShared | 1,088 | 371 |
| EnsemblePlex | 1,011 | 206 |
| EnsembleSiriIntentsExtension | 910 | 0 |
| EnsembleSupport | 209 | 106 |
| Total | 148,324 | 50,698 |

### What the excess is not

- Dead code is small. A name-based scan found about 90 functions and types
  with no caller, a few hundred lines. Periphery is installed and should
  replace that crude scan in step 0.
- Copy-paste is small. 1.7 percent of significant lines sit inside a repeated
  block of eight lines or more.
- Old-OS fallback code is small, under 1,000 lines. The floor change matters
  because it enables the Observation framework and one navigation API, not
  because of what it deletes directly.

### What the excess is

| Area | Source lines | Finding |
|---|---:|---|
| Playback | 18,200 | `PlaybackService` is 7,293 lines with 143 stored variables, 125 task launch sites, 30 Boolean flags, and about 230 generation or token references. It is the most-changed file in the repo. |
| Offline downloads | 10,800 | The largest single feature. Four layers across three packages. |
| Watch | 9,600 | A second app: own model, catalogue cache, queue, and player. The phone core references the watch model types zero times. |
| Core Data layer | 8,300 | Managed objects, repositories, and mappers. Eleven model versions. |
| Sync | 7,500 | Each source owns its own database writer: Plex 1,867 lines, Apple Music 1,916. Full and incremental sync are separate paths. |
| Library and search screens | about 7,000 | One screen per item kind, each over 1,000 lines, changing together. |
| Track tables | 5,200 | Separate UIKit, AppKit, and queue tables with no tests. |
| Logs and diagnostics | 3,500 | Plus about 1,240 logging call sites elsewhere. |

Supporting signals:

- About 460 of 1,870 commits read as fixes or recoveries.
- State and events travel five ways: 363 `@Published` properties, 122 callback
  closures, 82 `NotificationCenter` uses, 19 Combine subjects, 11 async
  streams.
- `DependencyContainer.shared` is referenced 277 times across 60 files,
  including 50 UI files.
- A track has at least five shapes: `PlexTrack`, `CDTrack`, `Track`,
  `EnsembleTrack`, and the Siri index entry.
- `ratingKey`, a Plex term, appears about 1,090 times in shared Core, UI, and
  Persistence code.
- Production code carries 23 `ForTesting` functions.
- The Core services folder has four files over 2,000 lines and 36 under 120.
  Earlier extractions moved code without shrinking the hubs.
- The `architecture` skill lists dozens of ownership rules written as prose
  because one 70,000-line module cannot enforce them in the compiler.

The 2026-09-04 playback engine review
(`docs/investigations/2026-09-04-playback-engine-review.md`) already confirmed
in source that the Plex path and the Apple Music path carry separate queue
completion logic that disagree on Repeat All, and that only one path
generation-checks progress events. That is the playback problem in miniature.

## 4. Target architecture

### 4.1 Principles

1. One owner per piece of state, publishing immutable snapshots.
2. One way for state to travel: owners expose an observable snapshot and an
   async event stream. No cross-service callbacks, no `NotificationCenter`
   between app services.
3. Decisions are pure functions. Side effects are data returned from those
   functions and executed by a thin runner.
4. Boundaries are enforced by the compiler through module targets, not by
   prose rules.
5. Dependencies are passed in from a composition root. No global lookups.
6. Shared code speaks a source-neutral vocabulary.
7. Fewer mechanisms beat more features of a mechanism. Prefer deleting a path
   to adding a compatibility layer.

### 4.2 Modules

Target shape. Whether each is a separate package or a target inside an
existing package is decided in step 4; start with targets, because they give
the same compiler boundary for less churn.

| Module | Owns | May depend on |
|---|---|---|
| `EnsembleSupport` | Pure Foundation utilities | nothing |
| `EnsembleModel` | The one media model, source identity, capability flags, queue and playback value types | Support |
| `EnsembleSourceKit` | The source interface and its conformance test kit | Model |
| `EnsembleStore` | SQLite schema, migrations, single-writer queue, observed queries | Model |
| `EnsembleSync` | The shared reconciler, sync intents, Feed assembly | Model, SourceKit, Store |
| `EnsemblePlayback` | Playback state machine, queue policy, engines, system Now Playing bridge | Model, SourceKit, Store |
| `EnsembleDownloads` | Offline targets, queue, transfer, file layout | Model, SourceKit, Store |
| `EnsembleCloud` | Profile and preference sync over KVS and CloudKit | Model |
| `EnsembleSystem` | Siri, App Intents, Spotlight, permalinks | Model, Store |
| `EnsemblePlexSource` | Plex adapter. Absorbs `EnsembleAPI` and `EnsemblePlex` | SourceKit |
| `EnsembleAppleMusicSource` | Apple Music adapter | SourceKit |
| `EnsembleUI` | Phone, iPad, and Mac views | feature modules |
| Watch views | Watch target | feature modules, minus what the watch does not use |

Feature modules do not import each other. They meet through `EnsembleModel`
values. The app target holds the composition root and nothing else of
substance.

### 4.3 Playback

One state value, one event type, one pure transition function.

```swift
struct PlaybackState: Equatable, Sendable {
    var queue: PlaybackQueue          // items, order, shuffle, repeat, autoplay
    var session: PlaybackSession      // idle, resolving, starting, playing, paused, stalled, failed
    var position: PlaybackPosition    // generation-checked time and duration
    var route: PlaybackRoute          // interruption, output, mirroring
}

enum PlaybackEvent: Sendable {
    case command(PlaybackCommand)     // user and system intents
    case engine(EngineEvent, SessionID)
    case system(SystemEvent)          // interruption, route, lifecycle, network
    case resolved(ResolutionResult, SessionID)
}

func reduce(_ state: inout PlaybackState, _ event: PlaybackEvent) -> [PlaybackEffect]
```

- Every engine event carries a `SessionID`. The reducer drops stale ones in
  one place. The generation and token guards scattered through the service
  are deleted.
- Queue policy, meaning next, previous, completion, repeat, shuffle, and
  autoplay, exists once and is used for every source.
- An engine is an adapter with one contract: accept effects, emit events. Two
  engines exist and stay: the native audio graph and the MusicKit player.
  This plan does not replace, merge, or add engines.
- `PlaybackNowPlayingBridge`, reporting, persistence, prefetch, and donations
  become effect handlers that read snapshots. They never write playback state.
- The reducer is tested with tables of state, event, expected state, and
  expected effects. No mocks, no clocks, no `ForTesting` hooks.

Contracts to preserve, taken from the `architecture` and `known-issues`
skills:

- One live queue. No second published queue.
- Finite MusicKit queues stay disposable and one item long. The three-second
  Previous restart threshold stays.
- No silent PCM, empty audio graph, second media session, or
  `SystemMusicPlayer` keepalive.
- Only the Now Playing bridge writes `MPNowPlayingInfoCenter` and
  `MPRemoteCommandCenter`.
- Siri, App Shortcuts, remote commands, autoplay, restoration, and recovery
  do not donate playback starts.
- Direct file streams and universal transcode both stay valid.
- Timeline and scrobble reporting stay source-exact.

### 4.4 Source interface

A source is an adapter over a remote service. It does not touch the database.

```swift
protocol MusicSource: Sendable {
    var descriptor: SourceDescriptor { get }       // identity, display, capabilities
    var connector: SourceConnecting { get }        // sign-in, discovery, health
    var catalogue: SourceCatalogueReading { get }  // pages, changes since cursor, full ID inventory
    var playback: SourcePlayback { get }           // .stream(resolver) or .systemPlayer(controller)
    // Optional capabilities, each its own protocol, nil when unsupported:
    var playlists: SourcePlaylistEditing? { get }
    var ratings: SourceRating? { get }
    var lyrics: SourceLyricsProviding? { get }
    var radio: SourceRadioProviding? { get }
    var feed: SourceFeedProviding? { get }
    var downloads: SourceDownloadResolving? { get }
    var reporting: SourcePlaybackReporting? { get }
    var metadata: SourceMetadataEditing? { get }
    var liveChanges: SourceChangeNotifying? { get }
}
```

- `catalogue` returns normalized pages and deltas. The shared reconciler in
  `EnsembleSync` owns every write, deletion-safety rule, and cursor.
- Deletion is inferred only from a complete inventory. An unavailable or
  partial response never deletes. This existing rule moves into the one
  reconciler instead of being re-implemented per source.
- Sync takes an intent listing required phases. Overlapping intents for one
  source merge by union. This removes the known issue where a full refresh
  joins narrower in-flight work.
- Item identifiers are opaque and source-scoped. `ratingKey` and other Plex
  terms stay inside `EnsemblePlexSource`.
- A stream source such as Plex or Jellyfin reuses the whole native audio
  engine, download stack, and reporting path. A system-player source such as
  Apple Music supplies its own controller.
- `EnsembleSourceKit` ships a conformance test kit. Every source runs it
  against recorded fixtures. A fake in-memory source is the kit's reference
  conformer and the stand-in third source until Jellyfin exists.

### 4.5 Store

- One SQLite database through GRDB, one writer queue, WAL mode.
- Unique keys and foreign keys with cascade express the rules that are prose
  today. Duplicate playlist membership rows become impossible.
- Rows are `Sendable` structs. These are the model types or map to them
  trivially. Managed objects and context rules disappear.
- Screens observe queries. Refresh notifications and snapshot caches that
  exist to paper over missing observation are deleted.
- Reads are paged and column-limited for large libraries.
- Full-text search uses FTS5.
- The phone, the watch, and the Siri extension use the same schema and code.
- iCloud sync is unaffected. It never touched Core Data. It uses KVS plus two
  hand-written CloudKit records.
- Migration carries the data that exists only on the device: download
  records and file paths, offline targets and memberships, pending
  mutations. The library cache is rebuilt by resync.

### 4.6 Composition and observation

- The app target builds one object graph and hands each scene what it needs
  through the SwiftUI environment. Every scene, including the external
  display scene, is built by the same root.
- `DependencyContainer.shared` is removed from UI code first, then
  everywhere.
- View models move to the Observation framework. Views read only the
  properties they render.

### 4.7 UI

- One browse screen and one detail screen, configured per item kind.
- A browse screen renders a list and emits a selection. It does not know
  where the detail goes.
- A layout container at the scene root places panes. iPhone pushes. iPad and
  Mac show the detail in the next column.
- Each item kind declares full width or list plus detail.
- On iPad the hand-built split is replaced by the native one. On Mac the
  AppKit split stays until the native one is shown not to cause the sidebar
  pop-in listed in `known-issues`.

### 4.8 Packages and native APIs

Checked on GitHub on 2026-10-13. Re-check versions when a step adopts one.

| Choice | Use for | Status |
|---|---|---|
| GRDB 7.11 | The store, step 5 | Adopt. MIT, active, supports iOS 13 and watchOS 7 upward. |
| swift-async-algorithms 1.1 | Debounce, throttle, and merge on async streams, replacing 81 Combine operator uses and the hand-written debounce registry | Adopt in step 2. Apple, Apache 2.0. |
| Swift Testing | Table-driven reducer and conformance tests | Adopt. Ships with Xcode. |
| Observation, `CKSyncEngine` | View model observation; possibly the hand-written CloudKit record handling | Native on iOS 17. Evaluate `CKSyncEngine` in step 2. |
| Nuke | Artwork | Already used, pinned from 12; 13.2 is current. About 4,000 lines of artwork code sit on top of it, including hand-written URL caches and trackers. Review in step 5 how much Nuke's own caches can replace. |
| jellyfin-sdk-swift 3.3 | The Jellyfin adapter, later | Use when Jellyfin is built. MPL 2.0, which is file-level copyleft. |
| KeychainAccess | Keychain | Already used. Last release 2021. The wrapper is 84 lines; replacing it with direct Security calls is optional. |

Rejected:

- The Composable Architecture. The reducer in 4.3 is small; the framework
  would add code and concepts rather than remove them.
- A third-party audio engine such as SFBAudioEngine. Engines are out of
  scope, and it has no watchOS support.
- TPCircularBuffer for the render-thread buffer. It has no licence file on
  GitHub. If the lock in the audio callback is addressed, use Apple's
  swift-atomics.

## 5. Steps

Order follows the pain and the churn. Each step ends with deletion of the old
path. A step is not finished while the old path still compiles.

Steps 0 and 1 are specified here. Steps 2 to 6 are outlines; each needs a
short detailed design, added to this file and approved, before it starts.

### Step 0. Floors, safety net, and honest cleanup

Scope:

1. Raise deployment targets to iOS 17, macOS 15, watchOS 10 in the Xcode
   project and every `Package.swift`. Raise the Swift tools version to at
   least 5.9 so the Observation macro is available. Keep Swift 5 language
   mode; strict concurrency is not part of this step.
2. Delete availability branches at or below the new floors, the iOS 15 tab
   bar bridge, `NavigationView` uses, raw-string scene-role comparisons kept
   for iOS 15, and the pre-macOS-15 shell paths.
3. Run Periphery. Delete what it confirms unused. Entry points used by the
   system, such as App Intents, are not unused.
4. Write `docs/reference/surface-checklist.md`: every surface the app
   presents and a one-minute check for each. Main shell on iPhone, iPad, and
   Mac, mini player, Now Playing, Lock Screen and Control Center, Siri and
   App Shortcuts, Spotlight, external display, watch. Mark the external
   display as known-broken and parked.
5. Update `CLAUDE.md`, `README.md`, and the `architecture`, `code-style`,
   and `ui-conventions` skills for the new floors. `AGENTS.md` and
   `GEMINI.md` are symlinks to `CLAUDE.md`.
6. Record the baseline line counts from section 8 in this file.

Not in scope: Observation migration, navigation redesign, any behaviour
change.

Done when: the app builds for iOS, macOS, and watchOS; the surface checklist
passes on the iPhone 16 Pro through Device Hub and on the Mac build, except
the parked item; line counts are recorded.

Status at `254691f2`: scope items 1 to 6 are delivered and the three builds
succeed. Not done: the iPhone surface pass has not run, and six Mac rows that
need pointer or keyboard input are `not run`. See
[`2026-10-13-step-0-verification.md`](../investigations/2026-10-13-step-0-verification.md).

Line counts at `254691f2`, from the section 8 commands:

| Unit | Source lines | Test lines |
|---|---:|---:|
| EnsembleCore | 69,496 | 38,656 |
| EnsembleUI | 46,734 | 2,860 |
| EnsemblePersistence | 7,955 | 4,429 |
| EnsembleAPI | 6,335 | 2,693 |
| Ensemble app target | 4,030 | not measured |
| EnsembleWatch app target | 3,914 | 0 |
| EnsembleWatchCore | 3,740 | 739 |
| EnsembleDomain | 1,235 | 267 |
| EnsembleSiriShared | 1,077 | 371 |
| EnsemblePlex | 946 | 206 |
| EnsembleSiriIntentsExtension | 910 | 0 |
| EnsembleSupport | 198 | 106 |
| Total | 146,570 | 50,327 |

Source is down 1,754 lines, 1.2 percent, from the section 3 baseline. Periphery
listed 567 more candidates in Core, UI, Domain, SiriShared, and WatchCore; 507
were kept because a same-name reference or app-target use could not be ruled
out. Expect later steps, not another Periphery pass, to remove them.

### Step 1. Playback state machine

Freeze: playback. See section 6.

1a. Inventory. Read `PlaybackService`, `PlaybackQueueController`,
`PlaybackHandoffCoordinator`, `PlaybackStartupCoordinator`,
`PlaybackLaunchCoordinator`, `PlaybackTransportCoordinator`,
`AppleMusicPlaybackController`, and `AudioPlaybackEngine`. Produce the full
list of states, events, and side effects as a table in a design note. Every
stored variable in `PlaybackService` must be classified: state, derived,
effect bookkeeping, or removable. This table is the detailed design and must
be reviewed before 1b.

1b. Queue policy. Implement the queue portion of `reduce` and route both the
native and Apple Music completion and skip paths through it. This fixes the
Repeat All divergence and is shippable alone.

1c. Engine contract. Both engines emit the same normalized events tagged with
a session identifier. Progress, completion, error, and stall handling stop
being engine-specific in the service.

1d. Session lifecycle. Move resolve, start, retry, recovery, interruption,
route change, and handoff decisions into the reducer. Delete the flags,
generation counters, and task handles they replace.

1e. Snapshot. Publish one playback snapshot. Views and view models read it.
Keep the existing `ObservableObject` facade until step 2.

1f. Delete. Remove the old paths, `PlaybackServiceProtocol` if it has one
conformer, the coordinators that became effect handlers or empty, the
`ForTesting` hooks, and the tests that pinned them. Replace with reducer
tables.

Budget: the playback stack is 18,200 lines today. Target at most 12,000, with
no file over 1,500 lines. These are targets, not promises; report actuals.

Device acceptance on the iPhone 16 Pro, each item evidenced by the phone UI
or fresh logs:

- Start an uncached Plex track. Pause, resume, seek while playing, seek while
  paused.
- Next and Previous, including Previous within and after three seconds.
- Natural end of track into the next track, with the app foregrounded and
  with the phone locked.
- End of queue with repeat off, repeat all, and repeat one. Shuffle on and
  off. Play Next and Play Last. Reorder and remove in the queue.
- Plex to Apple Music, Apple Music to Apple Music, and Apple Music to Plex
  boundaries, with Next and with natural completion, if Apple Music is
  enabled on the device.
- Lock Screen and Control Center show the right item and respond to play,
  pause, next, previous, and scrub.
- A downloaded track plays in Airplane Mode.
- Kill and relaunch: the queue and position restore paused.
- Injected startup failure recovers; three failures show the Retry banner and
  Retry works. Uses the DEBUG hook in `docs/reference/agent-runtime-testing.md`.
- Interruption by another audio app, then return.

Mac acceptance: start, pause, seek, next, natural completion, relaunch
restore, using the explicitly launched built app.

### Step 2. Composition root and Observation

Remove global container access from UI, then from Core. Build all scenes from
one root. Move view models to Observation. Collapse the five state transports
toward snapshot plus event stream. Expect the container file to shrink from
about 1,300 lines to a few hundred.

### Step 3. Source interface and shared reconciler

Introduce `EnsembleSourceKit`. Convert Plex, then Apple Music, to adapters.
Move all database writes into one reconciler driven by sync intents. Rename
Plex vocabulary out of shared code. Add the fake source and the conformance
kit. Jellyfin is not built.

### Step 4. Module split

Split `EnsembleCore` along the seams steps 1 to 3 produced. Rewrite the
`architecture` skill as the short dependency table from section 4.2 and
delete the prose rules the compiler now enforces.

### Step 5. Store and shared model

Introduce `EnsembleStore` and `EnsembleModel`. Migrate device-only data,
resync the library, delete Core Data. Move the watch onto the shared model,
store, source interface, and playback and download modules. Add watch
playlist management and watch downloads. Collapse `EnsemblePlex` and most of
`EnsembleWatchCore`. Offline downloads are redesigned here against the new
store, with a line budget set in the step's detailed design.

### Step 6. Browse, detail, and panes

One browse screen, one detail screen, one pane container. Consolidate track
tables behind one configuration. Revisit the Mac split choice with evidence.

## 6. Scoped feature freeze

While a step is rebuilding a subsystem:

- No new features and no behaviour changes land in that subsystem. Blocking
  bug fixes are allowed and must also land in the new path.
- The rest of the app stays open.
- A git tag `pre-step-N` marks the commit before the step starts. It is the
  comparison baseline and the rollback point. No TestFlight build is made.
- `CLAUDE.md` carries one line naming the frozen subsystem, added when the
  step starts and removed when it ends.
- The freeze ends when the old path is deleted and device acceptance passes.

## 7. Verification protocol

"Good", "done", and "verified" are reserved for work that passed this
protocol. Anything else is reported as unverified, with the reason.

1. Build from `Ensemble.xcworkspace` for the exact device.
2. Install with `xcrun devicectl` and prove the installed build is the one
   just produced: record source commit, built app path, and installed
   version.
3. Drive the flow on Felicity's iPhone 16 Pro through Device Hub. The
   passcode is in the git-ignored root `.env` as `IPHONE_PASSCODE`. Never
   print, log, commit, or paste it.
4. Treat mirrored input as undelivered until the phone UI or fresh Ensemble
   logs confirm it.
5. Audio cannot always be heard through a mirror. Use advancing progress,
   system Now Playing, and render logs as evidence, and say which was used.
6. Only one agent drives Device Hub, Simulator Computer Use, or iPhone
   Mirroring at a time. Parallel agents build, test, and read; one agent
   holds the device.
7. Leave playback paused and the phone locked. Shut down every simulator
   that was started and confirm `Shutdown`.
8. Mac: launch the explicit built `.app`, verify the PID's executable path
   and build version, then check the flow.
9. Write a short verification note under `docs/investigations/` per step:
   what was exercised, evidence, and what was not exercised.

Standing approval exists for signed builds and installs to the iPhone 16 Pro
for this work. The paired Apple Watch and iPad Pro are approved for steps 5
and 6. Ask Felicity to connect them before those steps.

Destructive checks, meaning source removal, playlist deletion, queue
destruction, and cache cleanup on real data, still need explicit approval
each time, and use disposable items.

### Test policy

- Delete tests together with the code they pin.
- Keep or write tests only for: reducer and queue policy tables, the source
  conformance kit, store migrations of device-only data, deletion-safety and
  source cleanup, and parsing at trust boundaries.
- No `ForTesting` hooks in production code. If a test needs one, the unit
  boundary is wrong.

## 8. Reporting

After each step, report source and test lines per unit against the section 3
baseline:

```bash
for p in Packages/*; do
  s=$(rg --files "$p/Sources" -g '*.swift' | xargs cat | wc -l)
  t=$(rg --files "$p/Tests" -g '*.swift' 2>/dev/null | xargs cat 2>/dev/null | wc -l)
  echo "$(basename "$p") src=$s tests=$t"
done
for d in Ensemble EnsembleWatch EnsembleSiriIntentsExtension; do
  echo "$d src=$(rg --files "$d" -g '*.swift' | xargs cat | wc -l)"
done
```

Also append the user-facing result to the `{{future}}` changelog page as
`CLAUDE.md` requires, and update policy documents only where a durable
contract changed.

## 9. Handing work to another agent

- A work package is one lettered sub-step, for example 1b. It names the files
  it may touch, the contract it must preserve, and its acceptance check.
- The receiving agent starts with `git status --short`, reads `CLAUDE.md` and
  this file, and loads only the skills its package needs.
- Inventory, reading, and mechanical deletion parallelize well. Reducer
  design and device verification do not; keep them with one agent.
- A package returns a diff, the commands it ran with their real output, and a
  list of anything unverified. It does not self-certify device behaviour
  unless it held the device.
- Review every returned diff against section 4.1 before committing. Reject
  added compatibility layers, new callbacks between services, and new global
  lookups.

## 10. Risks and open items

- **Apple Music matrix.** Mixed-provider behaviour is only physically
  verified on some OS versions. Step 1 must not widen or narrow that claim
  without device evidence.
- **Rebuild regressions.** The fix history encodes real edge cases. Step 1a
  must mine `docs/investigations/` and the `known-issues` skill so the
  reducer tables cover them. Losing one silently is the main risk of this
  plan.
- **GRDB on watchOS.** Platform support is confirmed, see section 4.8.
  Check binary size at the start of step 5.
- **Estimates.** Every line target in this file is an estimate. Report
  actuals and revise the targets rather than bending the work to hit them.
- **Screen Mirroring.** Parked by decision. Step 2 rebuilds how the external
  display scene gets its dependencies, which may fix or expose the cause.
- **Watch verification.** How the watch is driven for acceptance is not yet
  decided.
