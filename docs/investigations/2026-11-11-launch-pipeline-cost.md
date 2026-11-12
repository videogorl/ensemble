# Launch pipeline cost, and what a background intent launch needs (2026-11-11)

Status: Part 1 (session log at process launch) is implemented. Part 2 is a read-only design and **needs the owner's
approval before any implementation**; it changes launch ownership.

Evidence (iPhone 16 Pro, Debug build 3323, iOS 27.3): `$TMPDIR/ensemble-16pro/warm-phone-analysis.md`,
`warm-phone-profile.md`, session logs in `logs3`, `logs4`, `logs5`. Code references are to this branch
(`perf/intent-cold-launch`, from `develop` 47dacbc7). Every number below is a Debug-build number from one phone;
no Release or Time Profiler launch exists yet.

## Part 1: why a background launch wrote no log, and the change

Cause: the persistent log session started only from SwiftUI scene hooks: `RootView.onAppear`
(`EnsembleApp.swift:89`) and the first `.active` scene phase (`:344`, macOS `:434`). A process started for an App
Intent or SiriKit request may never create a scene, or creates it late. Proof from the logs:
`session-2026-11-11-144619.log` is a Siri-launched process whose log opens at 14:46:19.766 with
`rootView.task.start elapsed=52.325s` (the process was 52 s old), `Scene phase changed to background`, then the
Siri intent. Everything the process did in those 52 s, and everything done by a pure `AudioPlaybackIntent`
process that never gets a scene, was unlogged. Also, `AppLogger` had no file handler before `RootView`, so even
the `PERF_LAUNCH` lines of `didFinishLaunching` never reached a file.

Change (commit 9b381290):

- `AppDelegate+LaunchPipeline.swift:42` starts the session right after the container exists and before any launch
  task, through `AppRoot.startPersistentLogSession(launch:)` (`EnsembleApp.swift:25`), which also wires the app and
  UI loggers. The scene hooks call the same function with `.foregroundScene`; macOS (no `didFinishLaunching`
  here) still starts it with the scene.
- `PersistentLogService.startSession(launch:)` (`PersistentLogService.swift:131`) now does nothing while a session
  is open, so the scene call after launch is a no-op. The first line is
  `Ensemble Session Log (launch: <kind>)`.
- `ProcessLaunchKind.classify` (`PersistentLogService.swift:21`) uses only what UIKit gives at launch:
  `applicationState == .background`, and the `userActivityDictionary`, `url` and `remoteNotification` launch
  options. Kinds: foreground scene, user activity (Spotlight or Handoff), URL, remote notification, background.
- Limit, by design: at `didFinishLaunching` UIKit cannot tell an App Intent from a SiriKit request from a
  `BGAppRefresh` launch. They all read `background (intent, Siri, refresh or system work)`; the request that
  follows is already logged with its own origin (`SIRI_APP: [origin=intent]`, `Background refresh phase=`). Spotlight
  and URL launches delivered to a scene (not through launch options, the normal case with SwiftUI) read as
  `foreground scene` or `background` and are identified by the existing `onContinueUserActivity` / `onOpenURL` lines.
- **Rotation risk to decide on:** the log keeps the newest 5 files (`PersistentLogService.maxSessions`). Logs are
  now written for every launch, so five quick intent launches (a Shortcuts automation) evict the foreground
  session you wanted. Bounded as required, but consider raising it (for example 20; files are about 100 to 400 KB)
  or exempting foreground logs. Not changed.

## Part 2: the launch pipeline

### How a launch starts, in order (iOS)

1. `AppRoot.container` is a lazy static (`EnsembleApp.swift:20`). The first touch in `didFinishLaunching` builds the
   whole `DependencyContainer`: bootstrap builders, `wireCrossSubsystemCallbacks()`
   (`DependencyContainer.swift:371`), then `scheduleDeferredSyncStartup()` (`:377`, `:839`) and a 2 s task that clears
   the `.launching` interaction state (`:378`). `OfflineDownloadService.init` ends by starting
   `recoverInterruptedDownloads(reason: .launch)` (`OfflineDownloadService.swift:495`).
2. `AppDelegate+LaunchPipeline.swift:8-77` then runs synchronously: Siri authorization (`:26`), Darwin
   notification registration (`:35`), `registerForRemoteNotifications` (`:49`), `accountManager.loadAccounts()` (`:57`),
   `updateAppShortcutParameters()` (`:60`), `prepopulateUnknownStates()` (`:68`), then schedules the six launch tasks
   (`:71-76`) from `AppDelegate+LaunchTasks.swift`.
3. A scene (only for a foreground launch, or when the system connects one) then runs `RootView.task`, the tab
   `.task` (`MainTabView.swift:166`, `SidebarView.swift:394`: library map and pins), `HomeView.swift:85` (hubs) and
   the `.active` scene phase (`EnsembleApp.swift:331-395`).

### Task table

"On bg intent launch today" is derived from code, not from a log (there is no bg-launch log until Part 1 is on
the phone). The decisive facts:

- `ForegroundWorkScheduler.isForegroundActive` is initialised `true` (`ForegroundWorkScheduler.swift:78`) and only
  `scenePhase` handlers set it `false` (`EnsembleApp.swift:394, 421, 528, 540`).
  `OfflineDownloadService.isAppInBackground` is initialised `false` (`:231`), set `true` only from the
  scene-driven `handleAppDidEnterBackground` (`:1158`). So a process launched in the background **with no scene
  treats itself as foreground**: every `.idleOnly` gate opens after the 2 s launching state clears. The 14:46:19
  "skipped because foreground work is unavailable" lines in the Siri log came from a scene that connected and went
  straight to `.background`, which is not the case for a scene-less intent process.
- Because that `.active` handler never runs, a scene-less process also never starts the periodic timer
  (`startPeriodicSync`, `SyncCoordinator.swift:2893`), the library map, hubs, or the foreground download recovery.

| # | Task | Trigger (file:line) | Bg intent launch today | Measured cost | Depends on it |
|---|---|---|---|---|---|
| 1 | Container build, DI wiring | first `AppRoot.container` touch (`EnsembleApp.swift:20`) | Yes | not separately logged (`PERF_LAUNCH dependencyContainer.ready` exists, not in the pulled logs because `AppLogger` had no file sink) | everything |
| 2 | Siri auth, Darwin observers, remote-notification registration | `LaunchPipeline.swift:30-49` | Yes | unmeasured, small | Siri/Shortcuts hand-off from the extension; CloudKit silent push |
| 3 | Account load (sync Keychain read) | `LaunchPipeline.swift:57`; intents use `loadAccountsAsync()` when state is not `.loaded` (`BackgroundPlaybackReadiness.swift:17`) | Yes | unmeasured | all four intent classes below except a pure setting toggle |
| 4 | `updateAppShortcutParameters()` (twice: `LaunchPipeline.swift:60`, `LaunchTasks.swift:92`) | launch + after health | Yes | unmeasured | Shortcuts parameter suggestions only |
| 5 | Health-check prepopulate (all `.unknown`) | `LaunchPipeline.swift:68` | Yes | trivial | `TrackAvailabilityResolver` dimming |
| 6 | Early health checks, 3 servers, ~13 probes | `LaunchTasks.swift:7-37` -> `SyncCoordinator.performStartupHealthChecks` (`SyncCoordinator.swift:2818`) | Yes (also starts `NetworkMonitor`) | `Startup health checks complete in 1.49s` (14:30:02.907), 0.68 to 3.22 s over 12 launches; a second forced pass `Health refresh complete in 1.46s` at 14:30:04.369 | start-of-playback stream URLs (c), (d); task 7, 9, 10 wait on it |
| 7 | WebSockets, 3 servers | `LaunchTasks.swift:101-107` after #6; `PlexWebSocketCoordinator.start()` `:142` | Yes | 3 `Connecting` at 17:11:12.496, 3 more at 17:11:13.4 (server close 1001 at 14:30:03.997), unmeasured CPU | live library/playlist deltas, download-queue and artwork invalidation events |
| 8 | Playback restore | `LaunchTasks.swift:39-63` (skipped if `hasPendingSiriIntent` or Siri executing); also `PlaybackService.waitForStartupRestoration` (`PlaybackService+Persistence.swift:121`) | Yes (unless a Siri intent is pending) | 14:30:01.577 complete 0.5 s after start; builds the audio engine and prebuffers (`ENGINE: creating missing audio engine` 14:30:07.401) | (b) control current playback; (c) must not race it |
| 9 | Startup sync (5 sources; Plex cursors removed first) | `LaunchTasks.swift:110-160`, `.idleOnly`; `SyncCoordinator.performStartupSync` `:1519`; cursor removal `:1527`, `:1532` | Yes after about 2 s (gate open, see above); defers 2 s more when a pending Siri file exists (`:131`) | 14:30:03.093 start to 14:30:11.928 complete (8.8 s); `bootstrapElapsed=11.37s` (14:30:11.941); 9 `Background refresh phase=` lines; Apple Music 157-playlist read ~6 s inside it | library data freshness; nothing an intent needs |
| 10 | Siri index rebuild, vocabulary, Spotlight refresh | `LaunchTasks.swift:65-99`, `.idleOnly`; `refreshSiriCatalog` (`SystemMediaIntegrationService.swift:451`), `refreshSpotlightIndex` `:433` | Yes after about 2 s; also after each sync phase commit (`DependencyContainer.swift:898-915`) | `siriIndexRebuild ... changed=true elapsedMs=296` 14:30:05.490, 228 ms 14:30:11.885, six `changed=false` 146 to 322 ms; `Spotlight indexed 200 changed media items` 14:34:12.029 | Siri and Shortcuts entity lookup (reads the index file, does not need the rebuild to run now) |
| 11 | Deferred iCloud/KVS bootstrap | container `:839-851`, `.idleOnly` | Yes after about 2 s | `Sync startup: deferred iCloud/KVS bootstrap skipped` when no foreground | profile/settings reconcile, not intents |
| 12 | Download recovery sweep + deferred healing (repair, 331-file truncation scan, orphan cleanup) | `OfflineDownloadService.swift:495`, `:2102-2125` (8 s delay, skipped only if `isAppInBackground`), `:1938` | Yes if the process lives 8 s | `downloadTruncationScan completed=331 ... elapsedMs=887` + `downloadHealing ... elapsedMs=1216` (14:30:17.644); again 1,211 ms 14:34:17, 1,144 ms 14:35:40, 1,078 ms 14:36:52; 2,790/3,708 ms on a cold cache 11:41:26 | file integrity of downloads; offline playback correctness, not intents |
| 13 | Library map build | `LibraryViewModel.loadLibraryIfNeeded` from `MainTabView.swift:166` / `SidebarView.swift:394` (`LibraryViewModel.swift:600-650`) | **No** (UI-owned, needs a scene) | `libraryMap generation=1 ... tracks=21654 elapsedMs=3000` (14:30:04.573); range 1,114 to 10,295 ms over 14 launches; generations 2 and 3 followed at 11:41:31 (2,042 ms) and 11:41:34 (1,589 ms) | browse UI only |
| 14 | Home hubs, pins, feed | `HomeView.swift:85`, `MainTabView.swift:167` | **No** (scene) | not separately logged | Home screen |
| 15 | Periodic sync timer (5-min fallback) | `startPeriodicSync` `:2893`, from `.active` (`EnsembleApp.swift:366`) | **No** | none fired in the window | freshness while foreground |
| 16 | Foreground recovery: mutation queue drain, sidecar FFT resume, Watch snapshot | `.active` handler `EnsembleApp.swift:373-390` | **No** | unmeasured | pending offline mutations (see risk 3) |
| 17 | Cold-launch diagnostics line | `LaunchTasks.swift:162` | Yes (awaits tasks 6, 8, 9) | trivial | logging only |

Log summary for one foreground cold launch (143001): 11.37 s to bootstrap summary, then 1.2 s of healing at
+16 s. CPU for a full cold launch on the phone was 14.9 s in 23.6 s (pid 24322, Activity Monitor delta, Debug),
which matches about 20 s per launch from an earlier jetsam snapshot. **The cost of a background intent launch is
unmeasured**; Part 1 is what makes it measurable. From the code, tasks 1 to 12 and 17 run in it, tasks 13 to 16 do not.

### What an intent actually needs

| Need | Intent examples (`Ensemble/App/AppIntents`) | Required | Not required |
|---|---|---|---|
| (a) toggle a setting | `SetEnsembleShuffleIntent`, `Repeat`, `Autoplay` (`NowPlayingIntents.swift:265-293`), `SetEnsemblePlaybackOptionIntent` | container (settings, playback service); when already playing, no accounts. Smart Mix enable calls `readyContainer()` (`:90, :101`) | health, WebSockets, sync, index, healing, restore unless the toggle changes a live queue |
| (b) control current playback | Play/Pause, Next, Previous (`NowPlayingIntents.swift:323-405`) | `currentTrackOrThrow` -> credentials + `waitForStartupRestoration(timeout: 5 s)` (`PlaybackIntents.swift:84-95`); then `readyContainer()` for resolving the next stream | startup sync, Siri refresh, WebSockets, healing |
| (c) start playback of a named item | `PlayEnsemble*Intent`, `AddToEnsemblePlaylist` via Siri coordinator (`PlaybackIntents.swift:107-155`) | `readyContainer()` = `prepareForBackgroundPlayback` (`BackgroundPlaybackReadiness.swift:15`): credentials, `prepopulateUnknownStates`, `NetworkMonitor`, bounded (8 s) join of `earlyHealthCheckTask` or a forced health pass, then `refreshProviders()`; the Siri media index file for entity lookup | startup sync, Spotlight, WebSockets, healing, restore (Siri path already skips it, `LaunchTasks.swift:46-52`) |
| (d) add to a playlist | `AddCurrentSongToEnsemblePlaylistIntent`, `AddToEnsemblePlaylistIntent` (`NowPlayingIntents.swift:156-196`) | credentials, `readyContainer()` (reachable server), mutation coordinator; the `MutationError`/offline path queues the add | WebSockets, sync, Siri refresh, restore, healing |

Already gated:

- `prepareForBackgroundPlayback` already **joins** the AppDelegate health-check task instead of running a second
  set (`BackgroundPlaybackReadiness.swift:41-43`), skips health checks offline, is bounded at 8 s, and registers
  providers only when not cancelled. It starts nothing else.
- `PlaybackService.waitForStartupRestoration` starts the one-time restore if nothing has (`...Persistence.swift:121-125`)
  and polls the `.notAttempted` status; restoration is idempotent (`startupCoordinator.beginRestoration()`), so the
  AppDelegate kick (task 8) is redundant for an intent that calls it, and harmful nowhere.
- `ForegroundWorkScheduler` `.idleOnly` gates tasks 9, 10, 11, 12 on `isForegroundActive`, the thermal state and
  the `.launching` state. It cannot protect a scene-less launch because the flag starts `true` (above).

## Proposal: tell the launch pipeline what kind of launch it is

### Current design

One path for every launch: `didFinishLaunching` schedules tasks 6 to 12 and 17 unconditionally. The gates that
look like "skip when not foreground" depend on a scene having reported its phase. The scene's first `.active`
(`EnsembleApp.swift:352-357`) deliberately skips starting the monitor and WebSockets because "the launch pipeline
owns" them.

### Proposed design (smallest)

1. **Seed the existing flags from the launch kind** (one place, `didFinishLaunching`, using the `ProcessLaunchKind`
   from Part 1). For a `.background` launch call `foregroundWorkScheduler.setForegroundActive(false)` and
   `offlineDownloadService` background mode before the container schedules work. That alone makes tasks 9, 10,
   11, 12 skip, because their gates already return `false` when `isForegroundActive` is false
   (`ForegroundWorkScheduler.swift:131, :160-161`; `OfflineDownloadService.swift:2121`). No new gate machinery.
2. **Do not start tasks 6 and 7 in `didFinishLaunching` for a `.background` launch.** Intents that need servers already
   call `prepareForBackgroundPlayback`, which runs health checks itself when `earlyHealthCheckTask` is nil
   (`:46-50`; the nil case is the existing code path "No connected servers - running health checks"). Task 7
   (WebSockets) has no intent consumer: a background process is not shown library changes.
3. **Make the deferred work run exactly once on the first foreground transition.** The first `.active` handler
   (`EnsembleApp.swift:337`) already distinguishes `isInitialActivation`. Replace "skip, the launch pipeline owns it"
   with `AppDelegate.startForegroundLaunchWork()`, an idempotent function holding tasks 6, 7, 9, 10, 17 (the current
   `startEarlyHealthCheckTask`, `...WebSocket...`, `...StartupSync...`, `...Siri...`). A foreground launch calls it
   from `didFinishLaunching` as today; a background launch calls it from the first `.active`, guarded by a stored
   `Task?`/flag on the AppDelegate so it can never run twice. Foreground launch behaviour is unchanged.
4. **Intents keep working unchanged:** `earlyHealthCheckTask` stays an optional that `prepareForBackgroundPlayback`
   already treats as optional. Playback restore (task 8) stays, because (b) needs it and `waitForStartupRestoration`
   already guards it; for an intent that does not need it (setting toggle, add to playlist, play named item) it is the
   one remaining background-launch cost, about 0.5 s to the first resolved queue plus an engine build. Optional follow-up:
   drop the AppDelegate kick for `.background` launches and let `waitForStartupRestoration` start it on demand.

### What disappears

For a `.background` launch: the early health pass when an intent does not need servers, three WebSocket
connects, the startup sync with its cursor removal, the Siri index rebuild, vocabulary registration and Spotlight
refresh, iCloud/KVS bootstrap, the deferred 331-file healing, and the diagnostics line. In code: the
"launch pipeline owns monitor/WebSocket startup" special case, and the assumption that the flags default to
"foreground". Nothing is added except one idempotent function and one flag seed. No new service, no package.

### Expected saving per launch kind (estimates, not measurements)

| Launch kind | Today | Proposed |
|---|---|---|
| Foreground scene | full pipeline: 14.9 s CPU in 23.6 s (Debug) | unchanged; gains only from the small fixes below |
| Background intent that needs only (a) or (b) | tasks 1 to 12, 17 after about 2 s, if the process lives that long; unmeasured | tasks 1 to 5 and 8 only; saves the whole of 6, 7, 9, 10, 11, 12 (on a foreground launch these were about 1.5 s of probes, 8.8 s of sync window, 0.3 to 0.6 s of index work, 1.2 s of healing) |
| Background intent that starts playback or adds to a playlist (c, d) | same as above | adds only the bounded health join inside `prepareForBackgroundPlayback` (0.7 to 3 s wall, measured on a foreground launch) |
| Background refresh (`BGAppRefresh`) | does its own bounded work plus the launch pipeline in front of it (not separately logged) | unchanged work, minus the pipeline; its handler already runs sync itself (`BackgroundSyncScheduler`) |
| Spotlight / URL (scene) | full pipeline | unchanged (a scene is foreground) |

The CPU split inside the 14.9 s is **not** attributed (no stacks for a launch exist). Save the number only after
the Part 1 log plus one App Launch trace on a Release build.

### Behavioural risks

1. **Stale data.** A background intent launch no longer refreshes the library or index in that process.
   Mitigation: it never did usefully (the process is seconds long); the next foreground launch does it. The Siri index
   an intent reads is the file written by the last foreground rebuild, as today.
2. **Missed WebSocket events.** A background process misses live deltas. They are only delivered while a socket is
   open, and the foreground process always runs a startup sync that reconciles (cursor removal, `:1527`), so
   nothing durable depends on them. If the cursor-removal rule is relaxed (small fix 2), this reconcile becomes
   the only safety net: keep it at least once per N hours.
3. **Deferred work exactly once.** The flag must be set by the first foreground transition and survive a scene
   created after the intent finished. Failure modes: a scene that reaches `.active` before the delegate sets its
   flag (set it synchronously in the delegate), and two scenes on iPad (guard on the AppDelegate, not per scene).
   Verify with the log: one `Starting startup sync...` line per process.
4. **Mutation queue.** `drainQueue()` is in the `.active` handler (`EnsembleApp.swift:373`). An intent that queued an
   add-to-playlist while offline relies on the next foreground to drain it; that is current behaviour, not a regression.
5. **Playback started by an intent continues while the app is in the background.** The audio engine, now-playing,
   reporting and prefetch are owned by `PlaybackService`, not by tasks 6 to 12. Stream URLs need a reachable
   server: the bounded join covers it, and a stream that cannot resolve fails on its own, as the doc comment says.
   The health-state `.unknown` seed (task 5) still dims tracks until a check runs; for a long-lived background
   playback process a later health pass is needed on `NetworkMonitor` transitions. Keep `NetworkMonitor` start in
   `prepareForBackgroundPlayback` (already there, `:26`) and confirm it triggers a health refresh when it goes
   online. **Check this on the phone first**: it is the riskiest assumption.
6. **Thermal gate.** Unchanged: nonessential work still waits for non-serious thermal state.

### How to verify on a phone (with the Part 1 log)

1. Baseline before the change: from a killed app run one `AudioPlaybackIntent` (Shortcut: play favorites) and one
   Siri request; pull `Application Support/Ensemble/Logs`. The first line of the new session file reads
   `launch: background`. Record per file: time to `Server connectivity ready`, `Starting startup sync`,
   `WebSocket ... Connecting` count, `siriIndexRebuild`, `Spotlight indexed`, `downloadHealing` lines and how
   many of them occur before the process ends.
2. Cost: Activity Monitor CPU delta for the intent process (`xctrace record --all-processes`, USB) plus the
   file above. If the bg-intent count of tasks 6 to 12 is already near zero, the proposal's saving is smaller
   than estimated and only small fixes 1 and 2 matter.
3. After the change: same two requests. Expect no tasks 7, 9, 10, 11, 12 lines; `Server connectivity ready` still
   appears; playback starts. Then open the app: exactly one startup sync, one WebSocket start, one health pass
   per process; hubs and library appear as before.
4. Regression passes: foreground cold launch log unchanged in task order; a Siri request while the app is
   foreground; an intent while offline; one intent then immediate foreground within 2 s.
5. Everything above is a physical-device item for `docs/reference/physical-device-backlog.md`.

## Separate, smaller fixes (each independent of the proposal)

1. **Start background launches in the right state** (the first step of the proposal, valuable alone). Seed
   `ForegroundWorkScheduler.isForegroundActive` and `OfflineDownloadService.isAppInBackground` from
   `applicationState` at launch. Few lines, removes the false-foreground default. Risk: a launch whose state is
   `.inactive` but later becomes active must call `setForegroundActive(true)`, which `.active` already does.
2. **Plex cursors are removed on every cold launch** (`SyncCoordinator.swift:1527`, `:1532`). It forces a full
   re-read of 5 sources each launch (the startup sync window was 8.8 s on this phone; the `performStartupSync(registrations:)`
   path `:3330-3347` already forces a full sync when the last sync is more than 24 h old). Proposal: only invalidate
   when the last authoritative reconcile is older than a bound (for example 24 h, stored with the cursor) and keep the
   incremental path otherwise. Risk: a delete missed by the incremental feed is reconciled up to a day later, which is
   already how the 24 h rule behaves. Decision for the owner (it changes the documented "authoritative pass every
   launch" rule noted in `ON_DECK.md`).
3. **Download healing rescans the same 331 files on each foreground** (`OfflineDownloadService.swift:1938`,
   `:2114-2125`, `:1645-1655`): `AVAudioFile(forReading:)` on every file, 0.9 to 1.0 s each pass, `truncated=0`
   `artworkMisses=0` every time (14:30:17, 14:34:17, 14:35:40, 14:36:52). The deferred task is reset to nil after
   each run so every foreground re-runs it. Proposal: remember a verified stamp (path, size, mtime) per completed
   file and rescan only files whose size or mtime changed or that are new; keep a full scan on launch after an
   app-version change. Risk: a file corrupted without a size/mtime change would not be caught; today's check
   (duration under half of expected) only catches truncation, which changes size.
4. **Two health passes at launch, 1.5 s apart** (`Startup health checks complete in 1.49s` at 14:30:02.907, then
   `account_inventory_refresh force=true` `Health refresh complete in 1.46s` at 14:30:04.369): the second is
   redundant within 2 s of the first. Proposal: find the caller of the forced refresh and skip when the early
   pass finished less than about 10 s ago. Not investigated to the call site; suspected.
5. **Library map rebuilt after each sync phase** (11:41:27, 11:41:31, 11:41:34: generations 1, 2, 3 at 4.6,
   2.0, 1.6 s in one launch; 14:30 had one). Proposal: coalesce rebuild requests during startup sync into one
   rebuild after it completes. The mapping itself (21,654 tracks into value types on every cold launch,
   1.1 to 10.3 s) needs a design of its own (paged or per-section load): out of scope, and a scene-only cost, so it does
   not affect background launches.
6. **Siri index rebuilt on every foreground** with `changed=false` 6 of 8 times (146 to 322 ms) and
   offline target reconciliation repeated per sync phase (23 lines in 9 s). Cheap individually; a "no source
   committed since the last rebuild" short-circuit would remove the repeat. Low priority.
7. **Session-log retention** (Part 1 follow-up): keep 5 files means five background launches erase older
   foreground logs. Raise the count or exempt larger sessions.
8. **Single-file log size is unbounded** within a session (a 2 h 15 min process wrote one file). Not a
   problem yet; note only.

## Decisions for the owner

1. Approve the proposal, or only small fix 1 (seed the flags) as the minimal first step?
2. Should a background-launched intent skip WebSockets and the health pass entirely, leaving `prepareForBackgroundPlayback`
   as the only on-demand connectivity (recommended), or keep the early health check on every launch?
3. Relax the per-launch Plex cursor removal to once per 24 h (small fix 2)?
4. Raise the log retention (5 now) before the next round of intent testing?
5. Do you want a Release App Launch trace first to attribute the 14.9 s CPU (recommended before judging the saving)?
