# Step 2: composition root and Observation

Re-architecture step 2, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the [design note](../reference/composition-observation-design.md), whose
five recommendations Felicity approved on 2026-10-21. She also approved doing
2e, then 2f, then finishing 2c and 2d, and giving view models an effect-free
init plus `start()`. Simulator-checked, not verified.

## Status

| Step | State |
|---|---|
| 2b One root | Done, `dfbd8ce8` |
| 2c UI off the global | Part 1, `a1757f07`: view bodies read the container from the environment. Remaining `.shared` uses are next |
| 2d Core off the global | Not started |
| 2e View models to Observation | Done, `2e35047c` to `31f8e27c` |
| 2f Services to snapshot plus events | Done, `4fcb7dc5` to `15d9b8ab`, with three agreed exceptions (below) |

## What changed

| Commit | Change |
|---|---|
| `dfbd8ce8` | `AppRoot.container` in the app target; `DependencyContainer` is `Observable` and injected with `.environment(container)`. Every scene and every hosted SwiftUI root (track tables, Stage Flow cells, Mac Get Info and split panes, external display) injects it explicitly, since hosted roots do not inherit the environment. |
| `a1757f07` | View bodies and methods read `@Environment(DependencyContainer.self)` instead of `.shared`. |
| `2e35047c`, `3d6bf3fb`, `a0fd23a6` | The 22 Core view models become `@Observable`. Views hold them in `@State` and build them from injected services; subscriptions move from init to `start()`, called from the view's `.task`. Self-publisher pipelines in `LibraryViewModel`, `SearchViewModel`, and the playlist and favourites models become `didSet`-scheduled tasks with the same debounce, detached compute, and generation checks. |
| `36296183` | `NowPlayingViewModel` and its five projections. `RootScreenModels` owns the scene's model and starts it on creation, so the first frame shows the restored track. View listeners on its publishers become `onChange`. |
| `5f4700ed` | UI-local models. The source-action presenter and AirPlay controller become `@Observable`; the aurora models, artwork continuity stores, and scroll-index interrupter published nothing and become plain classes. |
| `31f8e27c` | The view model factory file (327 lines) and the Combine filter-persistence helper are deleted. |

Container files: 1,317 lines before step 2, 982 after 2f.

### Rules the conversion settled

- `@State` evaluates its initial value on every parent init, so view model
  inits store dependencies and read cached values only. Effects go in
  `start()`, which is idempotent.
- iOS 17 has no lazy `@State`. Where a model must be built once per scene and
  started before the first frame, a small `ObservableObject` holder kept by
  `@StateObject` owns it: `RootScreenModels`, and the Mac Downloads window's
  Now Playing holder. These are the only `ObservableObject` types left in the
  UI.
- A class that is `@Observable` and still conforms to `ObservableObject`
  compiles but its `objectWillChange` never fires. The conversion removes the
  conformance in the same edit.
- Tracked properties cannot be touched from a nonisolated `deinit`; timers and
  cancellables that `deinit` cancels are `@ObservationIgnored`.

## Checks

- Builds through `scripts/build_serial.py`: iOS Simulator and macOS at every
  commit; watchOS Simulator at `31f8e27c`.
- EnsembleCore at `31f8e27c`: 1,157 tests, failures only in
  `testCreateFeedbackPreservesAccountIdentityAndEachBatchRetry` and
  `testPlaylistAddFeedbackPreservesActualCountsAndNavigation`, which failed
  before step 2.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1` (iOS 26.5), identity checked
by `scripts/prepare_runtime.py`, shut down after each run. Each build was made
from the working tree and committed unchanged afterwards.

| Build | For | Checks | Result |
|---|---|---|---|
| `202610211151.2767` | 2b | Album detail, Now Playing, Settings, Profile and storage, Downloads, Add Source | pass |
| `202610211239.1757` | 2e part 1 | Playlist sort, Downloads, Manage Downloads, account detail, Favorites rows, album detail | pass |
| `202610211252.2350` | 2e part 2 | Search typing, merged artist detail | pass |
| `202610211621.3636` | 2e part 3 | Feed, browse screens, album filter "Abbey" with genre chips updating, then cleared | pass |
| `202610211642.0236` | 2e part 4 | Restored track in the mini player at launch; play a playlist; playing-row indicator; Now Playing; queue; History; lyrics page; mini player after close | pass |
| `202610211650.3629` | 2e part 5 | Artists scroll index (M, W); source picker for a three-source artist, cancelled; Now Playing aurora | pass |

The Mac app built at each step was launched from `/tmp` with its PID path
checked. After 2b, the Profile, Downloads, and Settings windows and a second
main window opened from the menus with the app still running. After 2e part 4
the Downloads window, which now builds its own Now Playing model, opened and the app kept running; its contents were not read
because this session cannot capture the screen.

Not covered on the simulator: the native AirPlay picker did not open there,
and the controller converted in part 5 backs only the overflow AirPlay item;
the external display scene; App Shortcuts and Siri. These are in the device
backlog.

During the 2e part 4 run a swipe landed on the Now Playing scrubber and
seeked the Plex track "REDLIGHTS" (rating key 16558) to 3:33 of 3:42. It
played to its end before it could be paused; timeline reports reached 99%,
so Plex has probably counted one play. Later runs use the page dots instead
of swipes in Now Playing.

## Step 2f: services publish one snapshot plus events

Felicity approved the transport on 2026-10-21 (design decision 2) and three
choices during the work on 2026-10-22, recorded below.

### The pattern

`Broadcast` and `StreamSubscription` (in `EnsembleSupport`) carry every
service stream. A service keeps its state in stored `@Observable` properties,
which views read directly, and broadcasts one `Snapshot` value when it
changes; `snapshots()` returns the current snapshot, then each change. Things
that happen rather than hold go on an event stream. A listener calls
`observe(owner)`, which runs on the main actor while the owner lives;
dropping the returned subscription cancels it, as `AnyCancellable` did.

Every listener receives every value in order. A first version kept only the
latest value, and a change made right after subscribing then replaced the
starting value, so `dropFirst()` discarded the change. Three Home tests caught
it in part 4; the fix covered parts 1 to 3.

### Commits

| Commit | Change |
|---|---|
| `4fcb7dc5` | `Broadcast`, `StreamSubscription`, swift-async-algorithms; `NetworkMonitor` |
| `405c65f5` | `SettingsManager`: one `AppSettings` value replaces `@AppStorage`, persisted per changed field |
| `ccf48e68` | Search, playlist, and pinned models take the settings manager; the merge-preference notification goes |
| `23d5cb3c` | `AccountManager` snapshot and `sourceConfigurations()`; the `Broadcast` ordering fix |
| `d56a275b` | `SyncCoordinator` snapshot plus events; content changes become events; `start()` guards move to an `isStarted` flag |
| `81522f3f` | Playlist refresh, local rename, and source cleanup become sync events |
| `3c8b1ab4` | Visibility and hidden-media stores |
| `8b09fb39` | Offline downloads, mutation count, track availability |
| `e602c9c2` | Toasts, logs, foreground work, profile, and sync settings, which only views watched |
| `db315eed` | Power state, server health, WebSocket, readiness, lyrics, pins, cache manager |
| `5813d7f4` | `NavigationCoordinator` |
| `e84de275` | Playback snapshot stream (`snapshots()` on `PlaybackServiceProtocol`) |
| `aff030b7` | `LibraryChanges` replaces the downloads, metadata, library-cleared, and artwork-cleared notifications |
| `c30ccf4e` | Siri rebuild, artwork, cellular, artifact-cache, and pending-mutation notifications |
| `8413acaf` | `AccountManager` follows the connection policy setting itself |

Each service that others listen to has a transition table test: network,
settings, account source configuration, sync, visibility, hidden media, and
pins. They read the stream between changes and use a sentinel change to catch
an emission that should not happen.

### Decisions and exceptions

- **Library changes.** Downloads, metadata edits, cleared caches, artwork
  invalidation, and catalog changes reach view models through one
  `LibraryChanges` stream the container builds (Felicity, 2026-10-22). The
  step 5 store's change feed is expected to replace it.
- **Playback sample feeds stay on Combine.** Position, presentation time,
  buffering, waveform, and frequency bands run at 30 to 60 Hz and views read
  them with `onReceive` (Felicity, 2026-10-22). The playback snapshot moved.
- **Awaited and query hooks stay as container wiring.** Callers await the
  WebSocket handlers, sync's artwork and connection hooks, and the refresh
  reconcile hooks, or read their results, and several break construction
  cycles (Felicity, 2026-10-22). Signals moved where their listener could
  subscribe: low power to offline downloads, the connection policy to
  accounts, the cache cleanup worker's callbacks to construction. Playback's
  network-pressure signal stays wired, since its listeners are built first.
  Step 4's module split is expected to resolve these edges.
- **The account routing hook stays synchronous.** `NetworkMonitor` calls
  `AccountManager` before any stream listener so connections are re-resolved
  before sync or playback react.
- **Remaining app notifications are local.** The Stage Flow rotation signal
  (views to the app delegate) and the Playlists view's private mutation event
  are not between services.

### Checks

- Builds through `scripts/build_serial.py`: iOS Simulator and macOS at every
  part; watchOS at parts 1, 12, 13, and 14.
- EnsembleCore: 1,159 tests; failures only in the two playlist feedback tests
  that failed before step 2.

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`, identity checked by
`scripts/prepare_runtime.py`.

| Build | Part | Checks | Result |
|---|---|---|---|
| `202610212204.3476` | 1 | Simulated offline then online: WebSocket disconnect and reconnect, playback transition, sync journey, availability bump | pass |
| `202610212217.4757` | 2 | Accent color recolours live, persists across relaunch, restored | pass |
| `202610212224.4056` | 3 | Playlist merging off splits merged rows live; on re-merges them | pass |
| `202610212236.4868` | 4 | Launch readiness and Feed; account detail sections and sync status | pass |
| `202610212246.2353` | 5 | Playlists reload on sync state; offline disables New Playlist; online restores it | pass |
| `202610212300.5627` | 6 | Disposable playlist "Ensemble QA 2f" on Minibar: create triggers a refresh event, rename updates the list, delete confirmed by the server's WebSocket (item 17351, state 9) | pass |
| `202610212316.8152` | 7 | Hiding a library re-filters Artists live; restored | pass |
| `202610212325.3814` | 8 | Download and remove a three-track playlist; library summary and removal progress | pass |
| `202610212333.8093` | 9 | Test toast, Logs list, iCloud Sync screen | pass |
| `202610212344.6029` | 10 | Pin a playlist, shown under Pinned; unpin | pass |
| `202610212351.3152` | 11 | Detail push and back, tab switch, external route; Mac main, Profile, and Downloads windows open | pass |
| `202610220622.5813` | 12 | Play, pause, resume, Next; queue page; Aurora settles on pause | pass |
| `202610220638.8427` | 13 | Download from playlist detail shows badges; removal clears them | pass |
| `202610220656.0307` | 14 | Artwork across the Artists grid; Siri context and Spotlight refresh after launch | pass |

Not covered on the simulator: the Low Power Mode pause of downloads, the
cellular streaming toggle's effect, and artwork retry when a server comes
back; they are in the device backlog. Part 14's Siri and Spotlight refresh ran
after launch, but the log does not show whether `catalogChanged` or the launch
path started it; the sync rebuild tests cover the trigger.

Found along the way and logged as a P3 bug in AI Tasks: the availability
resolver's deferred bump after downloads never runs once any fast bump has
run, because the finished fast-bump task is never cleared.
