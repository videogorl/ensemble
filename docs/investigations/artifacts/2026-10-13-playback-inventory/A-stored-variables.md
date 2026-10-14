# PlaybackService stored-property inventory

Source: `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` (7,289 lines, class body 258-7289, no extensions). All line references below are `PlaybackService.swift:<line>`.

**Total found: 106 stored instance properties** (not the expected 140-190). Every stored property is declared between lines 818 and 1199; a search for deeper-indented or late declarations found only the five inside `#if` blocks (1046-1048, 1129-1130). The shortfall is because state has already been moved into collaborator types that the service owns (see "Hidden state" at the end); those were not inventoried here.

Not counted as instance state: `static let previousRestartThreshold` (273), `static let audioCriticalInteractionHoldNs` (274), `static let maxHistorySize` (1134), `PlaybackPreferenceKey` string constants (582-586). Nested value types `NetworkTransitionDecision` (265), `QueueSourcePruneResult` (424), `AudioEnginePreparation` (728) are transient results, never stored. The file-level struct `PlaybackBackgroundTaskOwnership` (234) has one stored field, `generation: UInt64?` (235), held through row 58.

Writer counts are assignment/mutation sites inside the file, found by regex and corrected by hand where noted; treat them as accurate to within one or two for the high-count rows.

## Table

| # | Name (line) | Type | Class | Writers | Notes |
|---|---|---|---|---|---|
| 1 | `currentTrack` (818) | `Track?` @Published | state: session (current item) | 26: public commands (play, shufflePlay, stop, next, previous, select), engine callbacks (1637, 1683), async continuation in `playCurrentQueueItem` (4758, 4820), Apple Music callbacks (6199-6368), source-prune notification (6816, 6849), restore (7188), rating edit (2614) | Mostly `queue[currentQueueIndex].track`, but holds the download-resolved copy (4788, 4820) and is nil after `stop()` while the index is kept (3438). Written separately from the index, so they diverge during transitions (1819 vs 4820). See duplicates. |
| 2 | `playbackState` (819) | `PlaybackState` enum @Published | state: session | 49: every command, engine callbacks (1436, 1455, 1496), load continuations (5706-5860), Apple Music callbacks, restore, source prune | `didSet` (820-829) fans out to network pressure, handoff coordinator, presentation time, and a deferred now-playing update. |
| 3 | `playbackTimelineRevision` (832) | `UInt64` | derived (count of backward jumps in `currentTime`) | 1: `updatePlaybackTimes` (2142) | Read once (7035) for now-playing `timelineRevision`, only for Apple Music; native playback uses `audioEngine.progressRevision` instead. Two revision sources for one fact. |
| 4 | `currentTime` (833) | `TimeInterval` @Published | state: position | 1: `updatePlaybackTimes` (2144), called from engine time sink, commands, Apple Music time callback | Single writer; clean. |
| 5 | `presentationTime` (834) | `TimeInterval` @Published | derived from `currentTime`, `playbackState`, `effectivePresentationLatency` (2132-2138) | 2: 2145, 2179 | Recomputed on state and route change. |
| 6 | `bufferedProgress` (835) | `Double` @Published | state: position (buffer extent) | 11: engine callback (1467), track-change resets, stop, cleanup (6984), load (5776) | Engine-reported; monotonic guard at 1464. |
| 7 | `queue` (836) | `[QueueItem]` @Published | state: queue | 22 direct + 11 `inout` through `queueController` (3777-6608) | `didSet` bumps `queueStateRevision` (837). |
| 8 | `currentQueueIndex` (839) | `Int` @Published | state: queue | 30 direct + 5 `inout` | `-1` means none. Often set before the await that loads the track (1819, 1839, 3599). |
| 9 | `queueStateRevision` (842) | `Int` | derived (change counter for 7 and 8) | 2: the two `didSet`s (837, 840) | Only reader is `WatchCompanionBridge.swift:162`. |
| 10 | `hasUserQueueEdits` (843) | `Bool` | state: queue (protection flag) | 1: `setQueueProtection` (4140) | Persisted in snapshot (7064); drives replace-queue confirmation (4135). |
| 11 | `isShuffleEnabled` (844) | `Bool` @Published | state: queue | 4: toggle (4247), play (2765), shufflePlay (2909), restore (7182) | Mirrored to UserDefaults at each site. |
| 12 | `repeatMode` (847) | `RepeatMode` @Published | state: queue | 1: `setRepeatMode` (4287) | Mirrored to UserDefaults and Apple Music controller. |
| 13 | `waveformHeights` (850) | `[Double]` @Published | derived (async analysis result keyed by current track) | 10: resets on track change, `generateWaveform` (1856-1888) | Presentation cache; not playback state. |
| 14 | `frequencyBandsSubject` (853) | `CurrentValueSubject<[Double],Never>` | derived (relay of `audioAnalyzer.frequencyBandsPublisher`) | 3 sends via setter: 4762, 6202, 6732 | Pure pass-through plus two manual clears. |
| 15 | `isExternalPlaybackActive` (859) | `Bool` @Published | derived from `presentationRouteKind != .builtInOrWired` (2202) | 2: 2202, 2218 | No production reader found outside the file other than through the protocol. |
| 16 | `isAutoplayEnabled` (860) | `Bool` @Published | state: queue (autoplay) | 2: toggle (4307), enableRadio (4572) | UserDefaults-backed. |
| 17 | `isSmartMixEnabled` (863) | `Bool` @Published | state: session (setting) | 1: 4333 | UserDefaults-backed. |
| 18 | `isSmartMixDisabledForAlbums` (866) | `Bool` @Published | state: session (setting) | 1: 4349 | UserDefaults-backed. |
| 19 | `isSmartMixTransitionActive` (868) | `Bool` @Published | state: session (engine-reported) | 2: engine callback (1426), cleanup (6950) | UI copy only; the service itself reads `audioEngine.isSmartMixTransitionActive` directly at 1527, 1711, 3615, 4215, 5327, 5380, 5550. See duplicates. |
| 20 | `autoplayTracks` (869) | `[Track]` @Published | derived from `queue` (future items with `source == .autoplay`, exactly as computed at 6394) | 5: 2643, 4320, 4483, 4496, 6394 | Two different derivations: last fetch result (4496) vs queue filter (6394). |
| 21 | `isAutoplayActive` (870) | `Bool` @Published | removable: only write is `= false` (4319) | 1 | Constant false, yet published to `NowPlayingViewModel.swift:340`. |
| 22 | `radioMode` (871) | `RadioMode` @Published | state: queue (autoplay) | 2: 4322 (`.off`), 4573 (`.trackRadio`) | |
| 23 | `recommendationsExhausted` (872) | `Bool` @Published | state: queue (autoplay) | 4: 4484, 4497, 4529, 4535 | Result of the last autoplay fetch. |
| 24 | `isInstrumentalModeActive` (873) | `Bool` @Published | state: session | 1: `setInstrumentalMode` (3996) | Force-reset by play (2725) and stop (3418). |
| 25 | `audioEngine` (985) | `AudioPlaybackEngine?` | dependency (lazily built effect handler) | 2: `setupPlayer` (1542), `cleanup` (6949) | Destroyed on every `stop()`; nil-ness is used as "engine needs creating" (1578). |
| 26 | `maxCachedFileURLs` (986) | `Int` const 10 | dependency (config) | 0 | Passed to `resolvedFileCache` (1333). |
| 27 | `engineTimeCancellable` (988) | `AnyCancellable?` | effect-bookkeeping | 2: 1504, 6951-6952 | Engine time sink. |
| 28 | `loadingStateTask` (989) | `Task?` | removable: never assigned a task | 0 real; 10 cancel/nil sites | Dead remnant of a delayed-loading transition. |
| 29 | `isHandlingQueueExhaustion` (990) | `Bool` | effect-bookkeeping (re-entrancy guard) | 2: 1771, 1772 (defer) | Guards the async `handleQueueExhausted`. |
| 30 | `isHandlingTLSFailure` (993) | `Bool` | effect-bookkeeping | 2: 5067, 5069 (defer) | RACE WORKAROUND: polled in a 100-iteration `Task.yield()` loop (1744-1749). |
| 31 | `consecutivePlaybackFailures` (995) | `Int` | effect-bookkeeping (retry budget) | 14: resets on success in callbacks and commands, increments in load failure paths (4983-5000, 5087), health check (5980) | Circuit breaker; see "Could not classify". |
| 32 | `maxConsecutiveFailuresBeforeStop` (996) | `Int` const 3 | dependency (config) | 0 | |
| 33 | `prefetchThrottleUntil` (997) | `Date?` | removable: never written | 0 | Read once for a log line (1785); always nil. |
| 34 | `networkStateObservation` (998) | `AnyCancellable?` | effect-bookkeeping | 2: 5938 (init only), 6959-6960 (cleanup) | SUSPECTED BUG: cancelled by `cleanup()`, which runs on every `stop()` (3433) and engine recreate (1566), but only re-created from `init` (1340). |
| 35 | `accountSourcesObservation` (999) | `AnyCancellable?` | effect-bookkeeping | 2: 6071, deinit | |
| 36 | `healthCheckCompletionObservation` (1000) | `AnyCancellable?` | effect-bookkeeping | 1: 5957 | Never cancelled. |
| 37 | `pendingPreBufferTime` (1002) | `TimeInterval?` | state: session ("restored, not yet loaded in engine") | 6: restore (7194), resume (3255, 3291), pre-buffer (6020, 6024), Apple Music (6193) | Non-nil is a hidden sub-state of `.paused`. |
| 38 | `preBufferTask` (1005) | `Task?` | effect-bookkeeping | 3 assigns: 5988, 7213, cleared 3304 / self-clear | Never cancelled; `resume` awaits it (3296-3301). |
| 39 | `qualityDebounceTask` (1006) | `Task?` | effect-bookkeeping (2 s debounce) | 2: 6104-6105, deinit | |
| 40 | `gaplessScheduleRequestTask` (1007) | `Task?` | effect-bookkeeping (single-flight) | 3: 5338, cleanup, deinit | Non-nil used as an in-flight guard (5331). |
| 41 | `onNetworkWorkPressureChanged` (1008) | `((Bool)->Void)?` | dependency (output callback) | 1 external: `DependencyContainer.swift:891` | |
| 42 | `streamingBufferLow` (1009) | `Bool` | state: session (engine-reported buffer pressure) | 1: engine callback (1449) | Not generation-checked, unlike its neighbours. |
| 43 | `networkWorkDeferred` (1010) | `Bool` | derived from 44, 2, 42 (1014-1015) | 1: 1017 | Cached for edge detection; also polled in a 250 ms sleep loop (5387). |
| 44 | `playbackPreparationCount` (1011) | `Int` | effect-bookkeeping (in-flight request count) | 4: 2696/2699, 4711/4714 | |
| 45 | `audioCriticalInteractionEndTask` (1029) | `Task?` | effect-bookkeeping (3 s hold) | 2: 2824-2825, cleanup | |
| 46 | `postPlaybackAutoplayRefreshTask` (1030) | `Task?` | effect-bookkeeping (1.5 s delay) | 2: 4408-4409, cleanup | |
| 47 | `downloadChangeObserver` (1031) | `AnyCancellable?` | effect-bookkeeping | 2: 6475, deinit | |
| 48 | `artworkCacheResetObserver` (1032) | `AnyCancellable?` | effect-bookkeeping | 2: 6488, deinit | |
| 49 | `artworkPrefetchTask` (1033) | `Task?` | effect-bookkeeping | 2: 5308-5309, deinit | |
| 50 | `lastObservedNetworkState` (1034) | `NetworkState?` | derived (copy of `networkMonitor.networkState`) | 2: 5936, 5945 | Kept for previous-value diffing; goes stale with row 34. Read by reporting at 1538. |
| 51 | `stallRecoveryTask` (1035) | `Task?` | effect-bookkeeping (single-flight) | 3: 1554 (self-clears 1556), 1802-1803, cleanup | Non-nil used as guard (1547). |
| 52 | `skipTransitionTask` (1038) | `Task?` | effect-bookkeeping | 16: next/previous/select commands, pause (2342) | Not cancelled by `stop()` or `cleanup()`; relies on the generation counter. |
| 53 | `handoffCoordinator` (1039) | `PlaybackHandoffCoordinator` (struct) | state: route / session (pause reason, interruption, route transition) | 9 mutating `handle` calls: 2234, 2236, 2322, 2430, 2439, 2489, 2675, 3225, 3240 | Already a value-type state machine; holds real state invisible to this table. |
| 54 | `handoffSettleTask` (1040) | `Task?` | effect-bookkeeping (settle-window timer) | 2: 2315-2316, cleanup | |
| 55 | `handoffEventCounter` (1041) | `UInt64` | removable: log sequence number only | 1: 2290 | |
| 56 | `unexpectedPauseCount` (1042) | `Int` | removable: write-only, only ever set to 0 | 5: 1646, 1689, 2327, 3399, 5774 | Remnant of an AVPlayer pause-loop detector. |
| 57 | `trackTransitionBackgroundTask` (1046, UIKit) | `UIBackgroundTaskIdentifier` | effect-bookkeeping | 2: 1990, 2058 | |
| 58 | `trackTransitionBackgroundTaskOwnership` (1047, UIKit) | `PlaybackBackgroundTaskOwnership` | effect-bookkeeping | 4 mutating calls: 1975, 1982, 2029, 2038 | Which generation owns row 57. |
| 59 | `endTransitionLeaseGeneration` (1048, UIKit) | `UInt64?` | effect-bookkeeping | 7: 1397, 1973, 2010, 2018, 2027, 2037, 2049 | RACE WORKAROUND: restored after expiry (2047-2049) to stop an expired lease immediately re-acquiring. |
| 60 | `isFastSeeking` (1072) | `Bool` | effect-bookkeeping | 4: 3946, 3955, 3437, 6981 | Read only inside the seek loop (3964, 3966); same fact as `fastSeekTask != nil`. |
| 61 | `fastSeekForward` (1073) | `Bool` | effect-bookkeeping (loop parameter) | 1: 3947 | |
| 62 | `fastSeekTask` (1074) | `Task?` | effect-bookkeeping (100 ms loop) | 4: 3961-3962, 3953-3954, 3435-3436, cleanup | |
| 63 | `presentationRouteKind` (1075) | enum (3 cases) | state: route | 2: 2197, 2216 | Sampled from `AVAudioSession` on route/handoff events. |
| 64 | `effectivePresentationLatency` (1076) | `TimeInterval` | state: route | 2: 2203, 2217 | Sampled from `AVAudioSession`. |
| 65 | `isScreenMirroringActive` (1081) | `Bool` | state: route (external input) | 0 internal; 2 external: `ExternalDisplaySceneDelegate.swift:67,103` | `didSet` re-samples the route. |
| 66-82 | `syncCoordinator` (1089), `networkMonitor` (1090), `artworkLoader` (1091), `audioAnalyzer` (1092), `downloadManager` (1093), `trackRatingLocalStore` (1094), `queueStore` (1095), `queueController` (1096), `artifactCache` (1097), `prefetchController` (1098), `smartMixAnalysisService` (1099), `nowPlayingBridge` (1100), `audioSessionCoordinator` (1101), `startupCoordinator` (1102), `resolvedFileCache` (1103), `settingsObserver` (1104), `reportingController` (1105) | `let` collaborators (17) | dependency | 1 each: init (1318-1335) | Six are injected; eleven are constructed inside init, several holding playback state of their own. |
| 83 | `processorCount` (1106) | `Int` | dependency (config) | 0 | |
| 84 | `systemMediaIntegrationService` (1107) | optional | dependency (late-injected) | 1: 1374 | |
| 85 | `foregroundWorkScheduler` (1108) | `weak` optional | dependency | 1: init (1325) | |
| 86 | `startupRestoreStatus` (1109) | enum | state: session (one-shot restore outcome) | 8: all in `restorePlaybackState` (7102-7200) | Diagnostic; read by `DependencyContainer.swift:729`. Low confidence, see below. |
| 87 | `mutationCoordinator` (1121) | optional | dependency (late-injected) | 1: 1369 | |
| 88 | `originalQueue` (1122) | `[QueueItem]` | state: queue (pre-shuffle order) | 13 direct + 5 `inout` | Every queue edit must be applied twice (e.g. 3462-3463, 4317-4318). |
| 89 | `lastPlaybackSnapshotTime` (1123) | `TimeInterval` | effect-bookkeeping (persist throttle) | 2: 7047, 7076 | |
| 90 | `audioAnalyzerCancellable` (1124) | `AnyCancellable?` | effect-bookkeeping | 1: 6727 | Never cancelled. |
| 91 | `maxQueueLookahead` (1127) | `Int` const 5 | dependency (config) | 0 | A literal `5` at 4401 states the same threshold. |
| 92 | `appleMusicPlaybackController` (1129, iOS) | optional | dependency (lazily built effect handler) | 1: 6175 | Holds its own `activeQueueGeneration`, `isStationActive`. |
| 93 | `appleMusicPreviousRestartGeneration` (1130, iOS) | `UInt64?` | effect-bookkeeping | 4: 3900, 6418, 6421, 6429 | RACE/INFERENCE WORKAROUND: detects a system "previous" command from a time rewind. |
| 94 | `playbackHistory` (1133) | `[QueueItem]` @Published | state: queue | 11 direct + 5 `inout` | Capped at 100. |
| 95 | `isNavigatingBackward` (1135) | `Bool` | effect-bookkeeping (one-shot message to a later callback) | 6: set true by previous/history commands, cleared only at 1633 | STALE-FLAG HAZARD: only consumed by the next gapless advance (1630), so after `previous()` the next natural advance skips its history entry. |
| 96 | `isSkipTransitionInProgress` (1137) | `Bool` | state: session (transition phase) | 20 | Set true by every `playCurrentQueueItem` (4824), not just skips; cleared at first audible render (1441), load end, failure, stop, pause. See flags. |
| 97 | `lastRemoteSkipTime` (1138) | `CFTimeInterval` | effect-bookkeeping (0.3 s debounce) | 1: 2401 | |
| 98 | `trackStartWallTime` (1139) | `CFTimeInterval` | effect-bookkeeping | 3: 1639, 1684, 5858 | RACE WORKAROUND: rejects stale remote seeks by track age (2544). Low confidence, see below. |
| 99 | `playbackGenerationCounter` (1140) | `UInt64` | effect-bookkeeping | 6 bumps: 2341, 3410, 3866, 4191, 4719, 6833 | About 58 read sites. See generation section. |
| 100 | `playbackPreparationShouldStart` (1141) | `Bool` | state: session (intent of the in-flight load) | 1: 4721 | Read once (3923) to keep intent across a seek-triggered reload. |
| 101 | `appleMusicQueueMutationGeneration` (1142) | `UInt64` | effect-bookkeeping | 2: 4174, 4708 | |
| 102 | `isSynchronizingAppleMusicQueueMutation` (1143) | `Bool` | effect-bookkeeping | 7 | RACE WORKAROUND: true only across one synchronous `stop()` (4192-4194) to mute re-entrant callbacks (6453). The other five writes set false and are redundant. |
| 103 | `queueExhaustedTimestamps` (1145) | `[Date]` | effect-bookkeeping (rate limiter) | 4: 1776, 1777, 1780, 3443 | More than 3 in 2 s forces stop. |
| 104 | `skipTransitionSafetyTask` (1147) | `Task?` | effect-bookkeeping (10 s watchdog) | 3: 5914-5915, 5927-5928, cleanup | WORKAROUND: force-clears row 96 if stuck. |
| 105 | `transportCoordinator` (1148) | `lazy` | dependency | 0 | Holds stream decisions and prepared pipelines. |
| 106 | `launchCoordinator` (1199) | `lazy` | dependency | 0 | Used once (4892). |

## Counts

| Class | Count |
|---|---|
| state | 27 |
| derived | 9 |
| effect-bookkeeping | 36 |
| dependency | 29 |
| removable | 5 |
| **Total** | **106** |

State by part: queue 10 (rows 7, 8, 10, 11, 12, 16, 22, 23, 88, 94), session 11 (rows 1, 2, 17, 18, 19, 24, 37, 42, 86, 96, 100), position 2 (rows 4, 6), route 4 (rows 53, 63, 64, 65). Row 53 spans route and session.

## Generation and token counters

| Counter | Invalidates | Bumped | Checked |
|---|---|---|---|
| `playbackGenerationCounter` (1140) | Every in-flight load, engine callback, Apple Music resume/skip, pre-buffer | pause (2341), stop (3410), select-while-paused (3866), Apple Music queue resync (4191), every `playCurrentQueueItem` (4719), source prune (6833) | Engine callbacks 1389-1509; load path 4791, 4938-4978, 5066, 5710-5877; resume 3273-3302; next 3507-3513; seek 3924-3926; `launchCoordinator.seek` 1217; pre-buffer 6025; Apple Music segment 6224-6242. The engine holds its own copy (`adoptPlaybackGeneration`, 3307, 3352; `playbackRequestGeneration`, 5799). |
| `appleMusicQueueMutationGeneration` (1142) | Deferred Apple Music queue resync task | 4174, and by every `playCurrentQueueItem` (4708) | 4179 |
| `appleMusicPreviousRestartGeneration` (1130) | Not a staleness token: remembers which Apple Music queue generation showed a rewind | 6421 | 6427 |
| `endTransitionLeaseGeneration` (1048) | Near-end background-task lease | 2010 | 1972, 2005, 2017, 2026 |
| `trackTransitionBackgroundTaskOwnership.generation` (235) | Stale requests ending a newer request's background task | 1975 | 2009, 2029 |
| `queueStateRevision` (842) | Nothing internally; watch bridge change detection | 837, 840 | `WatchCompanionBridge.swift:162` |
| `playbackTimelineRevision` (832) | Nothing; now-playing timeline identity | 2142 | 7035 |
| `handoffEventCounter` (1041) | Nothing; log numbering | 2290 | 2293 |
| External: `appleMusicPlaybackController.activeQueueGeneration` | Apple Music callbacks | in the controller | 3254, 3510, 4749, 6456 |

## Boolean flags

- **Transition phase (one enum in disguise):** `isSkipTransitionInProgress` (1137) + `playbackState == .loading/.buffering` + `playbackPreparationShouldStart` (1141) + `pendingPreBufferTime != nil` (1002). Together they encode: idle, restored-unloaded, loading(intent: play or stay paused), awaiting-first-audio, playing. `isSkipTransitionInProgress` is true from load start (4824) until first audible render (1441) or local-file play (5870), so it means "transition not yet confirmed", not "skip".
- **Async handler re-entrancy:** `isHandlingQueueExhaustion` (990), `isHandlingTLSFailure` (993). Both are "this recovery effect is in flight"; the second is polled by the first (1744).
- **Fast seek:** `isFastSeeking` (1072), `fastSeekForward` (1073), `fastSeekTask != nil` (1074) are one value: off, forward, backward.
- **Autoplay:** `isAutoplayEnabled` (860), `radioMode` (871), `recommendationsExhausted` (872), `isAutoplayActive` (870, constant false). `isAutoplayEnabled` and `radioMode` change together at 4572-4573 and 4319-4322; candidates for one enum: off, autoplay, radio, with an exhausted marker.
- **Network pressure:** `streamingBufferLow` (1009) is input; `networkWorkDeferred` (1010) is the derived output (1014).
- **Route:** `isExternalPlaybackActive` (859) is `presentationRouteKind != .builtInOrWired`; `isScreenMirroringActive` (1081) is an input to that inference (2200).
- **Queue:** `isShuffleEnabled` (844) always changes with `queue`/`originalQueue` reordering (4247-4262); `hasUserQueueEdits` (843) independent.
- **Settings, independent:** `isSmartMixEnabled` (863), `isSmartMixDisabledForAlbums` (866), `isInstrumentalModeActive` (873).
- **Engine mirror:** `isSmartMixTransitionActive` (868).
- **One-shot messages:** `isNavigatingBackward` (1135), `isSynchronizingAppleMusicQueueMutation` (1143). Both pass a fact from a command to a later callback and would become event payload.

## Task handles and timers

| Handle | Started by | Cancelled by |
|---|---|---|
| `skipTransitionTask` (1038) | next (3547), smart-mix next (3652), previous (3748, 3787) | Next skip command (3530, 3637, 3719, 3766, 3867), pause (2342). Not stop or cleanup. |
| `skipTransitionSafetyTask` (1147) | `armSkipTransitionSafety` (5915): next, previous, every load | `disarmSkipTransitionSafety` (5927), cleanup (6967) |
| `stallRecoveryTask` (1035) | Engine stream error (1554) | Queue exhaustion (1802), cleanup (6963), self-clear (1556) |
| `preBufferTask` (1005) | Health check (5988), restore (7213); 3 s delay | Never; awaited by resume (3301) |
| `qualityDebounceTask` (1006) | Quality setting change (6105); 2 s | Re-trigger (6104), deinit |
| `gaplessScheduleRequestTask` (1007) | Engine time tick near track end (5338) | cleanup (6975), deinit, self-clear |
| `audioCriticalInteractionEndTask` (1029) | End of `play` (2825); 3 s | Re-trigger (2824), cleanup (6977) |
| `postPlaybackAutoplayRefreshTask` (1030) | End of `play` (4409); 1.5 s | Re-trigger (4408), cleanup (6979) |
| `artworkPrefetchTask` (1033) | `scheduleUpcomingArtworkPrefetch` (5309) | Re-trigger (5308), deinit |
| `handoffSettleTask` (1040) | Handoff outcome `.scheduleSettleWindow` (2316) | Re-trigger (2315), cleanup (6939) |
| `fastSeekTask` (1074) | `startFastSeeking` (3962); 100 ms loop | stopFastSeeking (3953), stop (3435), cleanup (6973) |
| `loadingStateTask` (989) | Never | Six cancel sites; dead |
| `trackTransitionBackgroundTask` (1046) | 1976: engine completion (1399), every load (4725), near-end lease (2011) | 2057 via generation-owned end (2024), force end (2035), expiry (2045) |
| Cancellables | `engineTimeCancellable` 1504; `networkStateObservation` 5938; `accountSourcesObservation` 6071; `healthCheckCompletionObservation` 5957; `downloadChangeObserver` 6475; `artworkCacheResetObserver` 6488; `audioAnalyzerCancellable` 6727 | cleanup for the first two (6951, 6959); deinit for accounts, downloads, artwork (1352-1361); health check and analyzer never |

Untracked work: many `Task { ... }` launches hold no handle and are guarded only by the generation counter or not at all (for example 1659-1660, 3258, 3300, 3334, 4177, 4312).

## Suspected duplicates or contradictions

1. `currentTrack` (818) vs `queue[currentQueueIndex].track`: written at separate moments (index at 1819/1839/3599, track later at 4820); `stop()` clears the track but keeps the index (3438); `removeDeletedTracks` patches both by hand (3466-3474).
2. `isSmartMixTransitionActive` (868) vs `audioEngine.isSmartMixTransitionActive`: the service decides on the engine value (1527, 1711, 3615, 4215, 5327, 5380, 5550) and publishes a main-queue-delayed copy (1422-1426).
3. `playbackTimelineRevision` (832) vs `audioEngine.progressRevision`: chosen by provider at 7034-7035.
4. `playbackGenerationCounter` (1140) vs the engine's own generation (3307, 3352, 5799) vs `appleMusicPlaybackController.activeQueueGeneration` (6456): three generation spaces for "is this callback current".
5. `isSkipTransitionInProgress` (1137) vs `playbackState == .loading`: overlapping, with a 10 s watchdog (5913-5922) to repair disagreement.
6. `isFastSeeking` (1072) vs `fastSeekTask != nil` (1074).
7. `isExternalPlaybackActive` (859) vs `presentationRouteKind` (1075).
8. `lastObservedNetworkState` (1034) vs `networkMonitor.networkState`, which is read directly elsewhere (1055, 1065, 2737).
9. `autoplayTracks` (869) vs autoplay-sourced items in `queue` vs `queueController`'s auto-generated id set (4500, 4565, 6799): three records of which tracks were auto-added.
10. `originalQueue` (1122) vs `queue` (836): parallel arrays edited pairwise; any missed pair corrupts un-shuffle.
11. `trackTransitionBackgroundTask` (1046), its ownership struct (1047), and `endTransitionLeaseGeneration` (1048): three fields for one "who holds the background task and why".
12. `maxQueueLookahead` (1127) vs literal `5` at 4401.
13. Contradiction: `networkStateObservation` is torn down by `cleanup()` (6959) on every `stop()` but only installed in `init` (1340), so `lastObservedNetworkState` and network-transition handling appear to stop updating after the first stop or engine recreate. Not reproduced at runtime; read from code only.
14. Contradiction: doc comments describe AVPlayer/AVQueuePlayer behaviour that no longer exists (3388-3391, 5893-5907), matching the dead fields in rows 28, 33, 56.

## Could not classify

- `consecutivePlaybackFailures` (995): filed as effect-bookkeeping because the brief lists retry counters there, but it decides whether the session ends in `.failed` (4983, 5088), so the reducer probably needs it in state.
- `trackStartWallTime` (1139): filed as effect-bookkeeping; it is equally "position: when the current track started". Only reader is the remote-command stale-seek check (2544).
- `startupRestoreStatus` (1109): filed as state because it is a result callers read, but it is a one-shot diagnostic and may belong to the startup coordinator.
- `isSkipTransitionInProgress` (1137) and `playbackPreparationShouldStart` (1141): filed as state; they might disappear entirely if the session enum gains a `loading(intent:)` case.
- `isAutoplayActive` (870): filed as removable because it is constant false in this file; it is still part of `PlaybackServiceProtocol` (123) and consumed by `NowPlayingViewModel`, so removal touches the protocol and test doubles.
- `audioEngine` (985) and `appleMusicPlaybackController` (1129): filed as dependencies, but their existence is created and destroyed by playback flow, so "engine exists" is implicit state today.
- `waveformHeights` (850) and `frequencyBandsSubject` (853): filed as derived; they are async presentation data, not computable from playback state alone.
- Row 34 bug claim and row 95 stale-flag claim come from reading code paths, not from running the app.
- Writer counts for rows 1, 2, 7, 8, 96 were regex-derived and only spot-checked.

## Hidden state (outside this inventory's scope)

The service owns collaborators with their own mutable stored properties, which a `PlaybackState` design must also absorb or keep as effect handlers. Rough `var` counts by regex, not audited: `PlaybackHandoffCoordinator` about 11 (a struct, `state` at its line 136), `PlaybackQueueController` about 14, `PlaybackNowPlayingBridge` about 10, `PlaybackPrefetchController` about 5, `PlaybackTransportCoordinator` about 5, `PlaybackReportingController` about 4, `PlaybackResolvedFileCache` about 4, `PlaybackAudioSessionCoordinator` about 3, `PlaybackSettingsObserver` about 3, `PlaybackStartupCoordinator` about 1, `AudioPlaybackEngine` about 67, `AppleMusicPlaybackController` about 43. With these the true figure is well above the 140-190 estimate.

## Appendix: computed properties exposing state

`frequencyBands` (854, get/set over row 14), `duration` (975, from `currentTrack` and `audioEngine.fileDuration`), `currentTimeValue` (887), `presentationTimeValue` (896), `bufferedProgressValue` (900), `isVisualizerEnabled` (1115, reads UserDefaults), `lastRealTrackIndex` (1271), `currentPresentationRouteKindDescription` (2124), `isAudioSessionConfiguredForDiagnostics` (2128), `currentPauseReason` (2223), `shouldSuppressAutomaticAdvanceDuringHandoff` (2227), and the publisher accessors at 875-968 and 1264.
