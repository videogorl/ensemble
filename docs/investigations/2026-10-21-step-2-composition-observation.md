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
| 2c UI off the global | Part 1, `a1757f07`: view bodies read the container from the environment. Remaining `.shared` uses wait for 2f |
| 2d Core off the global | Not started |
| 2e View models to Observation | Done, `2e35047c` to `31f8e27c` |
| 2f Services to snapshot plus events | Not started |

## What changed

| Commit | Change |
|---|---|
| `dfbd8ce8` | `AppRoot.container` in the app target; `DependencyContainer` is `Observable` and injected with `.environment(container)`. Every scene and every hosted SwiftUI root (track tables, Stage Flow cells, Mac Get Info and split panes, external display) injects it explicitly, since hosted roots do not inherit the environment. |
| `a1757f07` | View bodies and methods read `@Environment(DependencyContainer.self)` instead of `.shared`. |
| `2e35047c`, `3d6bf3fb`, `a0fd23a6` | The 22 Core view models become `@Observable`. Views hold them in `@State` and build them from injected services; subscriptions move from init to `start()`, called from the view's `.task`. Self-publisher pipelines in `LibraryViewModel`, `SearchViewModel`, and the playlist and favourites models become `didSet`-scheduled tasks with the same debounce, detached compute, and generation checks. |
| `36296183` | `NowPlayingViewModel` and its five projections. `RootScreenModels` owns the scene's model and starts it on creation, so the first frame shows the restored track. View listeners on its publishers become `onChange`. |
| `5f4700ed` | UI-local models. The source-action presenter and AirPlay controller become `@Observable`; the aurora models, artwork continuity stores, and scroll-index interrupter published nothing and become plain classes. |
| `31f8e27c` | The view model factory file (327 lines) and the Combine filter-persistence helper are deleted. |

Container files: 1,317 lines before step 2, 984 now. 2f removes the callback
wiring.

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
