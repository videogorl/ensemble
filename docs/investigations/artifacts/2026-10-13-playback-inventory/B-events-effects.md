# B. PlaybackService inbound events and outbound effects

Source: `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` (7,289 lines, read in full at commit `2586f6e5`).
All bare line numbers below are `PlaybackService.swift:<line>`. Read-only inventory; nothing was built or run.

Conventions

- "gen" = `playbackGenerationCounter` (1140), the service-owned request generation.
- "AM gen" = `appleMusicPlaybackController.activeQueueGeneration`, a second, controller-owned generation, checked through `isCurrentAppleMusicQueue` (6449-6462).
- "AM" = Apple Music / MusicKit path (iOS 18+ only, every AM branch is behind `#if os(iOS)` + `#available(iOS 18, *)`).
- The class is `NSObject`, not `@MainActor` and not `ObservableObject` (258). Isolation is per-method.

---

## 1. Inbound events

### 1a. Commands (public or internal API, remote commands)

| Proposed event | Kind | Receiver (line) | Payload | Token check before acting |
|---|---|---|---|---|
| `playTracks` | command | `play(track:)` 2678, `play(track:context:)` 2682, `play(tracks:startingAt:)` 2689, `play(tracks:startingAt:context:)` 2694 | tracks, start index, `PlaybackStartContext` | No on entry. Nothing re-checked after `await resolvePlayableQueue` (2729) before the queue is replaced (2775-2777). gen is only bumped later in `playCurrentQueueItem` (4719) |
| `shufflePlayTracks` | command | `shufflePlay(tracks:)` 2842, `shufflePlay(tracks:context:)` 2846 | tracks, context | No (same gap after 2875). Not `@MainActor`, unlike `play` (2693) |
| `playQueueIndex` | command | `playQueueIndex(_:)` 3129 | index | Bounds only (3130); playability filter (3134-3141). Not `@MainActor` |
| `playFromHistory` | command | `playFromHistory(at:)` 3173 | history index | Bounds only (3174) |
| `pauseRequested(source: user)` | command | `pause()` 3217 -> `pauseInternally` 3224 | source | No. Hops through an unstructured Task (3218) |
| `resumeRequested(source: user)` | command | `resume()` 3232 -> `resumeInternally` 3239 -> `resumeCore` 3248 | source | State guard only: `.paused` or `.buffering` (3249) |
| `stopRequested` | command | `stop()` 3409 | none | No; it is itself a gen bump (3410) |
| `retryRequested` | command | `retryCurrentTrack()` 3480 -> private 5023 | none | No |
| `nextRequested` | command | `next()` 3486 | none | No. `!queue.isEmpty` (3487) |
| `previousRequested` | command | `previous()` 3688 | none | No |
| `seekRequested` | command | `seek(to:)` 3893 | time | `isFinite` only (3894). No state guard, no gen |
| `fastSeekStarted` / `fastSeekStopped` | command | `startFastSeeking` 3944, `stopFastSeeking` 3952 | direction | Engine has a track (3945) |
| `playNextRequested` | command | `playNext` 4021, 4026 | tracks | No |
| `playLastRequested` (alias `addToQueue`) | command | `addToQueue` 4011, 4016; `playLast` 4041, 4046 | tracks | No |
| `removeQueueItemRequested` | command | `removeFromQueue(at:)` 4061 | index | No. AM station pre-check (4064-4073) |
| `clearQueueRequested` | command | `clearQueue()` 4087 | none | No |
| `moveQueueItemRequested` | command | `moveQueueItem(byId:from:to:destinationSource:)` 4101 | item id, indices, optional target section | Item id validated inside `queueController.moveItem` (4102) |
| `shuffleToggled` / `shuffleSet` | command | `toggleShuffle` 4246, `setShuffleEnabled` 4277 | Bool | No |
| `repeatModeCycled` / `repeatModeSet` | command | `cycleRepeatMode` 4269, `setRepeatMode` 4286 | `RepeatMode` | No |
| `autoplayToggled` | command | `toggleAutoplay` 4306 | none | No |
| `smartMixSet` / `smartMixAlbumsSet` | command | `toggleSmartMix` 4327, `setSmartMixEnabled` 4331, `setSmartMixDisabledForAlbums` 4347 | Bool | Equality guard only |
| `autoplayRefreshRequested` | command | `refreshAutoplayQueue()` 4443 (public, also used internally) | none | See `autoplayRecommendationsResolved` |
| `radioEnabled` | command | `enableRadio(tracks:)` 4543 | tracks | No |
| `ratingAppliedLocally` | command | `applyRatingLocally(track:rating:)` 4592 | track, rating | Matches by `sourceScopedID` (2612) |
| `instrumentalModeSet` | command | `setInstrumentalMode(_:)` 3977 | Bool | Capability, equality, engine exists (3978-3980) |
| `visualizerPositionUpdated` / `visualizationConsumerSet` | command | 6764, 6768 | time / consumer, visibility | No |
| `tracksDeleted` | command | `removeDeletedTracks(_:)` 3454 (caller: `DependencyContainer.swift`) | set of playback identities | No |
| `restoreRequested` (launch) | command | `restorePlaybackState()` 7092 (callers: `AppDelegate+LaunchTasks.swift`, `EnsembleApp.swift`) | none | `startupCoordinator.beginRestoration()` (7093) |
| `persistSnapshotRequested` (app lifecycle, called from outside) | command | `persistPlaybackStateSnapshot()` 7081 (callers: `EnsembleApp.swift`, `DependencyContainer+ViewModelFactories.swift`) | none | `startupCoordinator.canPersist` (7082) |
| `airPlayRouteNudged` | command | `nudgeForAirPlayRoute()` 3393 (caller: `AppDelegate+Siri.swift`) | none | Track loaded in engine (3394) |
| `audioSessionConfigureRequested` / `routeSelectionRequested` / `audioSessionActivateRequested` | command | `ensureAudioSessionConfigured` 2088, `preparePlaybackRouteSelection` 2099, `activatePlaybackAudioSession` 2108 | `mixWithOthers` / `shouldStartPlayback` | No |
| `screenMirroringChanged` | command | `isScreenMirroringActive` didSet 1081 (setter: `ExternalDisplaySceneDelegate.swift`) | Bool | Equality |
| `dependenciesWired` | command | `setMutationCoordinator` 1368, `setSystemMediaIntegrationService` 1373 | service refs | No |
| `remotePlay` / `remotePause` / `remoteToggle` | command (system intent) | closures 2508-2527 -> `resumeInternally` / `pauseInternally` with `.system` | none | No |
| `remoteNext` / `remotePrevious` | command | 2528-2533 -> `next()` / `previous()` | none | Gate is in the bridge via `shouldAcceptSkip` (2546) -> `shouldAcceptRemoteSkipCommand` 2385: handoff state + 0.3 s debounce (2397). No gen |
| `remoteSeek` | command | 2534-2536 -> `seek(to:)` | position | Bridge pulls `trackAge` (2542-2545) and `currentTime` (2541) to reject stale seeks; no check in the service |
| `remoteRepeatSet` / `remoteShuffleSet` | command | 2537-2538 | mode / Bool | No |
| `remoteLike` / `remoteDislike` | command | 2539-2540 -> `toggleLike` 2554 | isLike | Availability (2559-2565) |
| `appleMusicPreviousInferred` | command, derived from an engine event | `handleAppleMusicTimeChanged` 6423-6433 -> `previous()` | none | AM gen (6406) + `appleMusicPreviousRestartGeneration == queueGeneration` (6427) |

### 1b. Engine events: native `AudioPlaybackEngine` (wired in `setupPlayer` 1377-1543)

| Proposed event | Receiver (line) | Payload | Token check |
|---|---|---|---|
| `nativePlaybackCompleted` | `onPlaybackComplete` 1387 -> `handleQueueExhausted` 1739 | generation | Yes, gen, twice (1389, 1402). First read happens on the engine's calling thread |
| `nativeTrackAdvanced` (gapless) | `onTrackAdvance` 1407 -> `handleEngineTrackAdvance` 1600 | trackId, generation | Yes, gen (1409). Then skip flag (1603) and handoff (1608) suppress it |
| `nativeSmartMixPromoted` | `onSmartMixPromote` 1414 -> `handleSmartMixPromotion` 1665 | trackId, generation | Yes, gen (1416). Not suppressed by skip flag or handoff, unlike gapless advance |
| `nativeSmartMixActiveChanged` | `onSmartMixTransitionActiveChanged` 1421 | Bool, generation | Yes, gen (1424) |
| `nativeFirstAudibleRender` | `onFirstAudibleRender` 1430 | trackId, generation | Yes, gen + current track identity (1433-1434) |
| `nativeBufferPressureChanged` | `onStreamingBufferPressureChanged` 1447 | Bool | **No.** No gen, no main hop; writes `streamingBufferLow` on the caller's thread |
| `nativeRebufferingChanged` | `onStreamingRebufferingChanged` 1452 | Bool, generation | Yes, gen + state (1453-1454). **No main hop**; assigns `playbackState` directly (1455) |
| `nativeBufferedProgress` | `onBufferedProgress` 1458 | trackId, generation, progress | Yes, gen + track identity (1461-1462); monotonic + 0.002 threshold (1464-1465) |
| `nativeStreamingFileCompleted` | `onStreamingFileComplete` 1471 | fileURL, artifact key (2 args ignored) | **No** |
| `nativeEngineError` | `onError` 1479 | error, trackId?, generation | Yes, gen (1481). trackId splits scheduled-track error (1482) from current-track error |
| `nativeProgressTick` | `currentTimeSubject` sink 1504-1540 | progress (time, generation, trackID) | Yes: `playbackState == .playing`, gen, `engine.isCurrentProgress` (1508-1510), then track identity (1519) |
| `nativeTrackDrift` (derived, polled on each tick) | `reconcileEngineTrackStateIfNeeded` 1705; promoted smart-mix poll 1512-1517 | engine's `currentTrackId` / `smartMixIncomingTrackId` | Inherits the tick's checks |
| `frequencyBandsUpdated` | analyzer publisher sink 6727-6733 | `[Double]` at up to 30 Hz | No |

### 1c. Engine events: Apple Music controller (wired in `setupAppleMusicPlayback` 6115-6177)

All are checked against AM gen, never against gen. `isCurrentAppleMusicQueue` (6449) also requires: not `isSynchronizingAppleMusicQueueMutation`, Apple Music enabled, current track is AM, state in loading/buffering/playing (paused only when opted in) (484-501).

| Proposed event | Receiver (line) | Payload | Token check |
|---|---|---|---|
| `appleMusicTrackChanged` | `onTrackChanged` 6121 -> `handleAppleMusicTrackChanged` 6261 | playback identity, queueGeneration | AM gen (6265) |
| `appleMusicTimeChanged` | `onTimeChanged` 6127 -> `handleAppleMusicTimeChanged` 6402 | time, queueGeneration | AM gen (6406). No track identity check |
| `appleMusicSegmentEnded` | `onEnded` 6133 -> `advanceAfterAppleMusicSegment` 6289 | queueGeneration | AM gen, accepts paused (6290-6293). Hops through an unstructured Task (6134) |
| `appleMusicPausedExternally` | `onPaused` 6140 | queueGeneration | AM gen + state playing/buffering (6142-6143) |
| `appleMusicResumedExternally` | `onResumed` 6146 | queueGeneration | AM gen (accepts paused) + state `.paused` (6148-6152) |
| `appleMusicStationTrackStarted` | `onDynamicTrack` 6157 -> `handleAppleMusicRadioTrack` 6342 | Track, queueGeneration | AM gen + station active (6346, 6466-6469) |
| `appleMusicTrackMetadataChanged` | `onTrackMetadataChanged` 6163 -> 6328 | Track, queueGeneration | AM gen + same identity (6332-6335) |
| `appleMusicStationQueueChanged` | `onDynamicQueueChanged` 6169 -> `handleAppleMusicRadioQueue` 6377 | upcoming tracks, queueGeneration | AM gen + station active (6381) |

### 1d. System events

| Proposed event | Receiver (line) | Payload | Token check |
|---|---|---|---|
| `audioInterruptionBegan` / `audioInterruptionEnded` | `setupAudioSession` 2068 -> `handleAudioSessionInterruption` 2406 | type, `shouldResume` option | No. Returns early if the current track is AM (2418-2424). `.ended` without an options key is dropped (2437) |
| `audioRouteChanged` | 2071 -> `handleAudioSessionRouteChange` 2452 | reason; new outputs read live (2481) | No. AM-owned early return (2462-2473) |
| `handoffSettleWindowFinished` (timer) | Task at 2316-2329 | deadline | Task cancellation only (2321) |
| `networkStateChanged` | `setupNetworkObservation` 5932-5950 -> `handleNetworkStateTransition` 6862 | previous, current `NetworkState` | No. **Subscription is cancelled by `cleanup()` (6959-6960) and only created in `init` (1340), see finding F2** |
| `serverHealthCheckCompleted` | `setupHealthCheckObservation` 5954 -> `handleHealthCheckCompletion` 5975 | none | No (`!queue.isEmpty` only, 5976) |
| `sourceConfigurationChanged` | `setupAccountSourcesObservation` 6068 -> `handleAccountSourcesChanged` 6773 | `SourceConfigurationSnapshot` | No |
| `visualizerSettingChanged` | `settingsObserver` 6087 -> `handleVisualizerSettingChanged` 6738 | Bool | No |
| `streamingQualityChanged` | `settingsObserver` 6090 -> `handleStreamingQualityChanged` 6098 -> 2 s debounce 6105 -> `reloadCurrentTrackForQualityChange` 6500, `invalidatePrefetchForQualityChange` 6548 | quality string | Task cancellation only (6107) |
| `downloadsChanged` (NotificationCenter, 500 ms debounce) | `setupDownloadChangeObservation` 6474-6485 -> `refreshQueueDownloadState` 6606 | none | No |
| `artworkCachesCleared` (NotificationCenter) | 6487-6496 | none | No |
| `backgroundTaskExpired` | expiration handler 1978-1980 -> `expireTrackTransitionBackgroundTask` 2045 | none | No |
| `skipTransitionSafetyFired` (10 s) | `armSkipTransitionSafety` 5913-5923 | none | Task cancellation only; not tied to gen |
| `audioCriticalHoldElapsed` (3 s) | `scheduleAudioCriticalInteractionEnd` 2822-2831 | none | Task cancellation |
| `postPlaybackAutoplayTimerFired` (1.5 s) | `schedulePostPlaybackAutoplayRefresh` 4407-4417 | none | Task cancellation |
| `fastSeekTick` (100 ms) | `startFallbackReverseSeeking` 3960-3970 | none | `isFastSeeking` flag |
| `preBufferDelayElapsed` (3 s) | 5988-5995 and 7213-7217 -> `preBufferRestoredTrack` 6013 | none | `pendingPreBufferTime != nil`, `.paused`, engine empty (6015-6018) |
| `gaplessScheduleDue` (derived from tick) | `scheduleGaplessIfNeeded` 5326 | none | One in flight at a time (5331) |
| `progressSnapshotDue` (derived from tick, 15 s) | `persistPlaybackSnapshotIfNeeded` 7068; policy 2148-2154 | time | n/a |
| `playbackStateDidChange` (internal didSet) | 819-830 | old, new | Equality (821) |
| Pull, not push: Now Playing state request | `nowPlayingBridge.currentState` 2504 -> `makeNowPlayingState` 6997 | none | n/a |
| Pull, not push: thermal and low-power state | `smartMixTempoMatchingGate` 750-768, read at 5565 | none | n/a |

No NotificationCenter observer for app foreground/background exists in this file; lifecycle arrives only as `persistSnapshotRequested` and `restoreRequested`.

### 1e. Resolved events (completion of async work the service started)

| Proposed event | Awaited at (line) | Payload | Token check after the await |
|---|---|---|---|
| `playableQueueResolved` | 2729, 2875 (`resolvePlayableQueue` 2996) | filtered tracks, start index, skipped count, or nil | **No** |
| `trackDownloadPathResolved` | 4788 (`resolveTrackForPlaybackIfNeeded` 7245) | Track with or without `localFilePath` | Yes: gen + queue identity via `shouldContinuePlaybackRequest` (4789-4798, 569-579) |
| `playbackSourceResolved` | 4863, 4877 (`resolvePlaybackSource` 5141) | `PlaybackSource` | Yes, gen via `isSuperseded` (4882-4889) |
| `playbackSourceFailed` | catch 4900 | error | Yes: cancellation + gen (4901-4911) |
| `connectionRefreshed` (in-request retry) | 4922 | success / error | Yes, gen (4931) |
| `audioSessionActivated` | 5723 | Bool | Yes, gen (5726) |
| `engineLoadCompleted` / `engineLoadFailed` | 5792, 5832 | none / error | Yes, gen (5798, 5805, 5838, 5877); stops the engine only if it still owns that generation (5799, 5806, 5839, 5878) |
| `launchCompleted` | 4892 (`launchCoordinator.completeLaunch`, calls back into `loadAndPlaySource` 5698, `seek` 1216-1220, `prefetchNextItem` 1221) | none | Seek callback checks gen (1217) |
| `serverHealthCheckFinished` (after connection failure) | 4977 | availability read at 4982 | Yes, gen (4978) |
| `tlsRecoveryStepCompleted` | 5097, 5106, 5117 in `handleTLSPlaybackFailure` 5061 | none / error | Yes, gen after every await (5066, 5101, 5109, 5114, 5118) |
| `appleMusicPlayReturned` | 6219 | set of unresolved playback identities, or error | Yes: gen + queue identity (6224-6227, 6242, 6250) |
| `appleMusicResumeReturned` | 3272 | success / error | Yes: gen + current track is AM (3273-3274, 3278-3279) |
| `appleMusicStationStarted` | 4521 | success / error | Yes: gen + station active + AM gen non-nil (4526-4528). Error path sets `recommendationsExhausted` without a check (4535) |
| `appleMusicSkipReturned` | 3506 | success / error | Yes, gen (3507-3514) |
| `preBufferFinished` (resume waits on it) | 3301 | none | Yes: gen + state `.buffering` (3302-3303) |
| `preBufferFileResolved` | 6034 | file URL | Yes: state + gen + identity (6036-6038) |
| `prefetchFileResolved` | 5485, 5498 (`resolveAudioFile` 5149) | file URL | Yes: `shouldContinue` = captured gen + still the next upcoming track (5450-5457, 5502) |
| `smartMixAnalysisResolved` | 5552-5559 | two `SmartMixAnalysis` | Partly: still upcoming + not scheduled (5560-5561); gen is not re-checked here |
| `prefetchFailed` | catch 5675 | error | Yes: gen + still upcoming (5676-5684) |
| `autoplayRecommendationsResolved` | 4469 | `[Track]?` | Identity, not gen: autoplay still on (4470), seed queue-item id (4472) or current track identity (4477) |
| `waveformLoaded` | 1882 | loudness array | **No.** Written to `waveformHeights` (1888) without re-checking that the track is still current |
| `queueSnapshotLoaded` | 7097 | `PlaybackQueueSnapshot?` or error | `startupCoordinator.restorationState == .restoring` (7107, 7126); queue empty and not playing/loading (7138) |
| `queueDownloadStateRefreshed` | 6607 | changed ids, eviction ids | **No.** `queue` is passed `inout` across the await (6608) |
| `ratingMutationFinished` | 2577-2581 | success / error | No gen; rollback keyed by track identity (2583-2585) |
| `qualityReloadFinished` | 6531 | none | **No.** Forces pause afterwards if it had been paused (6535-6540) |
| `sourcePruneReplayFinished` | 6811, 6813 | none | No |
| `artworkPrefetchResolved` | 5315 | image | `Task.isCancelled` (5316) |
| `truncatedDownloadMarkedFailed` | 5280-5287 | none | No |
| `playbackStartDonated` | 2968 | none | Result unused |
| `audioCriticalInteractionBegan` | 2818 | none | No |

---

## 2. Outbound effects

"Fed back" names the inbound `resolved` event from section 1e, or "no" when fire-and-forget or synchronous.

### Native engine

| Effect | Function(s) and lines | Awaited / fed back |
|---|---|---|
| `engineCreate` (+ wire 11 callbacks, time sink) | `setupPlayer` 1377-1543; via `prepareAudioEngineForPlaybackIfNeeded` 1576, `recreatePlayer` 1564 | sync |
| `engineDestroy` | `cleanup` 6938-6985 (from `stop` 3433, `recreatePlayer` 1566, `deinit` 1350) | sync |
| `engineLoadSource` | `loadAndPlaySource` 5792, 5832; `preBufferRestoredTrack` 6041 (sync `load(fileURL:)`) | awaited -> `engineLoadCompleted` / `engineLoadFailed` |
| `enginePlay` | 5856 | sync throw |
| `enginePause` | 1550, 2351, 2354, 3537, 3726, 3772, 4826, 4996, 5006, 5134, 6537, 6841 | sync |
| `engineResume` (+ `adoptPlaybackGeneration`) | 3307-3308, 3352-3353, 6887-6888 | sync throw |
| `engineStop` | 3357, 3876, 4734, 4769, 5731, 5748, 5799, 5806, 5813, 5839, 5878, 5888, 6244, 6252, 6842, 6948 | sync |
| `engineSeek` | 3912, 6052 | sync throw; `streamingSeekUnavailable` re-enters as a full reload (3920-3934) |
| `engineClearSchedule` | 3144, 3536, 3725, 3771, 3875, 4230, 4340, 5436, 5444, 5763, 6553, 6645 | sync |
| `engineScheduleGapless` | 5624, 5662 (via `schedulePrefetchedTrackIfStillUpcoming` 5373) | sync throw -> later `nativeTrackAdvanced` |
| `engineScheduleSmartMix` | 5608 | sync throw -> later `nativeSmartMixPromoted` |
| `engineRemoveScheduledTrack` | 1486 | sync |
| `engineAcceptSmartMix` / `engineCancelSmartMix` | 3628; 3641, 3895, 4216, 4300, 4339 | sync |
| `engineSetIsolation` (instrumental) | 3995 | sync throw |
| `enginePrepareForRouteChange` | 2476 | sync |

### Apple Music controller

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `appleMusicCreate` (+ wire 8 callbacks) | `setupAppleMusicPlayback` 6115-6177 | sync |
| `appleMusicPlay` | 6219 | awaited -> `appleMusicPlayReturned` |
| `appleMusicPause` | 2349 | sync |
| `appleMusicResume` | 3272 | awaited -> `appleMusicResumeReturned` |
| `appleMusicStop` | 3424, 3871, 4193, 4750, 6211, 6243, 6251, 6837 | sync |
| `appleMusicSeek` | 3901 | sync |
| `appleMusicSetRepeatOne` | 4296 | deferred through a Task (4291) |
| `appleMusicSetInterruptionActive` | 2417 | sync |
| `appleMusicStartStation` | 4521 | awaited -> `appleMusicStationStarted` |
| `appleMusicSkipToNextEntry` | 3506 | awaited -> `appleMusicSkipReturned` |
| `appleMusicDiscardUpcoming` | 4184 | sync Bool decides whether to rebuild (4184-4203) |
| `appleMusicRemoveUpcomingEntry` | 4069, 6392 | sync Bool |

### Now Playing bridge

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `installRemoteCommands` + state provider | 2503-2552 | commands come back as section 1a remote events |
| `publishNowPlaying` | `updateNowPlayingInfo` 6989, about 50 call sites, plus a deferred one from `playbackState` didSet (828) | no |
| `clearNowPlaying` | 3447, 6856 | no |
| `cancelNowPlayingArtwork` | 6993; called at 3434, 6844, 6982 | no |

### Audio session

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `observeAudioSession` / stop | 2067, 1351 | -> interruption and route events |
| `configureAudioSession(mixWithOthers:)` | 2088-2096; called at 3269, 4735, 4766, 4776, 4779, 5738, 5744, 6014 | sync Bool; failure becomes `.failed` (4736, 4770, 5749) |
| `prepareRouteSelection` | 2101 | awaited by the external caller |
| `activateAudioSession` | 2110, 5723 | awaited -> `audioSessionActivated` |
| Direct `AVAudioSession.setActive(true)`, bypassing the coordinator | 3342 | `try?`, result dropped |
| Direct `setPreferredIOBufferDuration` | 3992 | `try?` |
| Read route and latency | 2188-2206, 2481 | sync |

### Persistence / queue store

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `saveQueueSnapshot` | `savePlaybackState` 7045-7066 -> `queueController.saveSnapshot` 7057; about 45 call sites | no |
| `saveProgress` (15 s) | 7077 | no |
| `flushSnapshot` | 7087 | no |
| `loadQueueSnapshot` | 7097-7099 (`Task.detached`) | awaited -> `queueSnapshotLoaded` |
| `saveRepairedSnapshot` | `persistRestoredSnapshotRepair` 7229 | no |
| `recordStartupMutation` | 2674, 7046 | no |
| `savePreference` (UserDefaults) | shuffle 2766, 2910, 4248, 7183; repeat 4288; autoplay 4308, 4574; SmartMix 4334, 4350 | no. Read at property init 844-867 |
| `storeTrackRating` | 2608; called at 2577, 2585, 4595 | awaited -> `ratingMutationFinished` |
| `markDownloadFailed` + delete file | 5274, 5280-5287 | awaited, result logged only |

### Reporting / timeline / scrobble

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `reportTimelineState("paused")` | 2368 | no |
| `reportTimelineState("playing")` | 3316, 3382 (resume paths only) | no |
| `reportTimelineState("stopped")` | 3414 | no |
| `observePlayingProgress` | 1534-1539 (native tick only) | no |
| `resetReportingForTrack` | 1643, 1688, 6853 | no |
| `rateTrackRemote` | 2581 (`mutationCoordinator.rateTrack`) | awaited -> `ratingMutationFinished` |

### Prefetch / transport

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `prefetchUpcoming` | `prefetchNextItem` 5296 -> `prefetchUpcomingItems` 5386-5696; launched from 1659, 1699, 3313, 3378, 4231, 4233, 4337, 4341, 5339, 6564, 6647, 6822, 6825, 6933, and the launch coordinator 1221 | mostly unawaited -> `prefetchFileResolved` / `prefetchFailed` |
| `resolvePlaybackSource` | 5142 | awaited -> `playbackSourceResolved` |
| `resolveAudioFile` | 5153 | awaited -> `prefetchFileResolved`, `preBufferFileResolved` |
| `evictTransport` / `clearTransport` / `discardPreparedStreams` / `cancelResolution` / `takePreparedPipeline` | 4920, 5104, 5269, 5693; 3430, 6956; 4647, 5409, 5415; 6629; 5796, 5836 | sync |
| `recordPrefetchFailure` / clear / `deferSmartMixPrefetch` | 5687, 5507, 5594 | sync |
| `analyzeSmartMix` | 5552, 5556 | awaited -> `smartMixAnalysisResolved` |
| `prefetchArtwork` | `scheduleUpcomingArtworkPrefetch` 5301-5324 | not fed back |

### Artifact / resolved-file cache

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `cacheResolvedFile` | `cacheFileURL` 4605 (from 1474, 5144, 5160, 5165, 5759) | sync |
| `readResolvedFile` | `getCachedFileURL` 4623 | sync |
| `evictResolvedFiles` | 4632, 4646, 4684; `resolvedFileCache.clear` 3445, 6955 | sync |
| `cleanupStreamCacheFiles` | 4672 (from 1475, 4618, 4639, 4660, 6560) | no |
| `beginPrefetch` / `endPrefetch` in-flight markers | 5465, 5471 | sync |
| `readCompletedArtifact` | 3097 | sync |
| `evictTruncatedFile` | 5265-5294 | awaited |
| Synchronous `AVAudioFile` duration probe on the start path | 4872, 5493 | sync file IO |

### Analytics / journey log

| Effect | Lines |
|---|---|
| `UserJourneyLogger.log` | 2710, 2747, 2790, 2856, 2892, 2937, 4141, 6697 |
| `PlaybackJourneyLogger.start` / `mark` | 4811; 3909, 3915, 4858, 4860, 4862, 4864, 4913, 5783, 5803, 5811, 5823, 5843, 5886 |
| `EnsembleLogger` | throughout; state transitions at 823 |

### Siri / intent donation

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `donatePlaybackStart` | `donatePlaybackStartIfNeeded` 2959-2973, called at 2803 and 2950 | awaited, nothing fed back |

### Toast / UI notification

- None. The file posts no notification and raises no toast. Failures reach the UI only as `playbackState = .failed(message)` (assignment sites listed in section 4, "Failing").

### Network (direct, outside the transport coordinator)

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `refreshConnection` | 4922, 5049, 5106 (also injected into transport at 1181-1186) | awaited -> `connectionRefreshed` / TLS steps |
| `triggerServerHealthCheck` | 4977 | awaited -> `serverHealthCheckFinished` |
| `fetchLoudnessTimeline` | 1882 | awaited -> `waveformLoaded` |
| `fetchRadioRecommendations` | 4466-4469 | awaited -> `autoplayRecommendationsResolved` |
| `lookupDownloadPath` / `fetchDownload` | 3109, 6614, 7257; 5280 | awaited |

### Visualizer / analyzer

| Effect | Lines |
|---|---|
| `loadVisualizerTimeline` | 1238-1262 (`Task.detached`), from 1206, 5673, 6057, 6752 |
| `activateTimeline` | 1650, 1692, 5766, 6059, 6754 |
| `resumeUpdates` / `pauseUpdates` | 1438, 1651, 1693, 3312, 3364, 5863, 6755 / 2364, 3878, 4827, 6198 |
| `updatePlaybackPosition` | 1531, 2182, 6765 |
| `stopAnalysis`, `visualizationEnabled`, `setVisualizationConsumer` | 6944, 6743, 6769 |

### Foreground work scheduler and background time

| Effect | Lines | Awaited / fed back |
|---|---|---|
| `begin/endInteraction(.streamingStarved)` | 1018-1025 | no |
| `onNetworkWorkPressureChanged` callback | 1026 | no |
| `begin/endInteraction(.audioCritical)` | 2818, 2828 | begin awaited |
| `beginBackgroundTask` / `endBackgroundTask` | 1970-1993, 2053-2060; lease logic 1997-2051 | expiration -> `backgroundTaskExpired` |

### Timers

- Covered in section 6 (settle window, skip safety, audio-critical hold, autoplay refresh delay, pre-buffer delay, quality debounce, fast-seek loop, retry backoff 4849 and 5097, network-pressure poll 5387-5390).

---

## 3. Published outputs

`PlaybackService` is not an `ObservableObject`, so there is no `objectWillChange`; every consumer goes through a `PlaybackServiceProtocol` publisher or a synchronous getter. No file in `Packages/` or `Ensemble/` subscribes to `$property` directly. The comment at 851-852 about avoiding `objectWillChange` at 30 Hz no longer describes anything.

Consumer counts are files outside `PlaybackService.swift`, as "production / including tests and mocks".

| Output | Declared | Publisher | Consumers |
|---|---|---|---|
| `currentTrack` | 818 | 875 | 5 / 7: `NowPlayingViewModel`, `WatchCompanionBridge`, `OfflineDownloadService`, `DependencyContainer`, `EnsembleAppShortcuts` |
| `playbackState` | 819 (didSet side effects 820-829) | 879 | 5 / 8: `NowPlayingViewModel`, `WatchCompanionBridge`, `AuroraVisualizationView`, `DependencyContainer`, `OfflineDownloadService` |
| `currentTime` | 833 | 883 | 4 / 6: `NowPlayingViewModel`, `NowPlayingProjections`, `ControlsCard`, `WatchCompanionBridge` |
| `presentationTime` | 834 | 892 (`@MainActor`) | 1 / 3: `NowPlayingViewModel` |
| `bufferedProgress` | 835 | 904 | 4 / 6: `NowPlayingViewModel`, `NowPlayingProjections`, `ControlsCard`, `MiniPlayer` |
| `queue` | 836 | 908 | 3 / 5: `NowPlayingViewModel`, `NowPlayingProjections`, `WatchCompanionBridge` |
| `currentQueueIndex` | 839 | 912 | 2 / 4: `NowPlayingProjections`, `WatchCompanionBridge` |
| `queueStateRevision` (plain var, bumped by both didSets) | 842 | none | 1: `WatchCompanionBridge` |
| `isShuffleEnabled` | 844 | 916 | 2 / 4: `NowPlayingViewModel`, `WatchCompanionBridge` |
| `repeatMode` | 847 | 920 | 2 / 4: same two |
| `waveformHeights` | 850 | 924 | 4 / 6: `NowPlayingViewModel`, `NowPlayingProjections`, `ControlsCard`, `MiniPlayer` |
| `frequencyBands` (`CurrentValueSubject`) | 853-857 | 928 | 1 view / 4 files: `AuroraVisualizationView` (`AudioAnalyzer.swift` matches by name only, it is the upstream source) |
| `isExternalPlaybackActive` | 859 | 932 | **0 production** / 2 (test doubles only) |
| `isAutoplayEnabled` | 860 | 936 | 1 / 3: `NowPlayingViewModel` |
| `isSmartMixEnabled` | 863 | 940 | 2 / 4: `NowPlayingViewModel`, `ProfileSettingsSections` |
| `isSmartMixDisabledForAlbums` | 866 | 944 | 1 / 3 |
| `isSmartMixTransitionActive` | 868 | 948 | 1 / 3 |
| `autoplayTracks` | 869 | 952 | 1 / 3 |
| `isAutoplayActive` | 870 | 956 | 1 / 3. **Only ever assigned `false` (4319); never becomes true** |
| `radioMode` | 871 | 960 | 1 / 3. Set at 4322, 4573 |
| `recommendationsExhausted` | 872 | 964 | 1 / 3 |
| `isInstrumentalModeActive` | 873 | 968 | 1 / 3 |
| `playbackHistory` | 1133 | 1264 | 1 / 3: `NowPlayingProjections` |
| `duration` (computed, not published) | 975-980 | none | read synchronously |
| `onNetworkWorkPressureChanged` callback | 1008, fired 1026 | n/a | 1: `DependencyContainer` |
| `startupRestoreStatus` | 1109 | none | 1: `DependencyContainer` |
| `currentPlaybackFileInfo()` | 5224 | none | 2 / 4 |
| `shouldConfirmQueueReplacement()` | 4122 | none | 4 / 6 |
| `isTrackAutoGenerated(trackId:)` | 4588 | none | synchronous query |
| Diagnostics getters | 2116, 2124, 2128 | none | `currentAudioRouteDescription` 2 files |

- Notifications posted: none (the file only subscribes, at 6475 and 6488).
- Async streams: none.
- Unused protocol surface: `startFastSeeking` / `stopFastSeeking` have no production caller (test doubles only).

---

## 4. Session lifecycle as implemented

### Flags and counters that carry session state

| Field | Declared | Notes |
|---|---|---|
| `playbackGenerationCounter` | 1140 | Bumped at 2341 (every pause), 3410 (stop), 3866 (paused navigation), 4191 (AM queue resync), 4719 (every start), 6833 (source prune) |
| `appleMusicQueueMutationGeneration` | 1142 | 4174, 4708 |
| `isSynchronizingAppleMusicQueueMutation` | 1143 | True only between 4192 and 4194; cleared at 3425, 3872, 4755, 6212, 6838 |
| `isSkipTransitionInProgress` | 1137 | Set 3534, 3639, 3723, 3769, 4824, 6319; cleared at 1441, 1569, 2344, 3444, 4530, 4994, 5004, 5132, 5817, 5849, 5870, 5920, 6189, 6691 |
| `isHandlingQueueExhaustion` | 990 | 1771-1772 |
| `isHandlingTLSFailure` | 993 | 5067-5069; spin-waited on at 1744-1750 |
| `consecutivePlaybackFailures` | 995 | Incremented 4985, 4988, 5000, 5087; forced to max 4983; reset 1439, 1568, 1638, 3146, 3370, 3442, 3481, 5865, 5980. **Only read as a gate at 5088** |
| `playbackPreparationCount` / `playbackPreparationShouldStart` | 1011, 1141 | 2696-2699, 4711-4714 / 4721, read 3923 |
| `pendingPreBufferTime` | 1002 | Set 7194; cleared 3255, 3291, 6020, 6024, 6193 |
| `isNavigatingBackward` | 1135 | Set 3190, 3208, 3732, 3782, 3848; **cleared only at 1633** |
| `trackStartWallTime` | 1139 | 1639, 1684, 5858 (native only) |
| `streamingBufferLow`, `networkWorkDeferred` | 1009-1010 | 1449, 1017 |
| `queueExhaustedTimestamps` | 1145 | 1776-1780, 3443 |
| `handoffCoordinator` state | 1039 | Mutated only through `handle(...)`: 2234, 2236, 2322, 2430, 2439, 2489, 2675, 3225, 3240 |
| Dead state | | `unexpectedPauseCount` (1042) is written at 1646, 1689, 2327, 3399, 5774 and never read. `prefetchThrottleUntil` (997) is read at 1785 and never written. `loadingStateTask` (989) is cancelled in 9 places and never assigned. The watchdog sections at 5896-5907 are comments only |

### Starting a track, native

1. Entry: one of 14 call sites reaches `playCurrentQueueItem` (4701): 1810, 1820, 1840, 2788, 2935, 3166, 3193, 3210, 3261, 3280, 3324, 3327, 3335, 3562, 3577, 3600, 3661, 3673, 3751, 3790, 3927, 4197, 4578, 4957, 5042, 5055, 5122, 6322, 6531, 6811, 6813.
2. `playCurrentQueueItem` 4701: `appleMusicQueueMutationGeneration += 1` (4708); `playbackPreparationCount += 1` (4711); `playbackGenerationCounter += 1` (4719); `playbackPreparationShouldStart` (4721); `beginTrackTransitionBackgroundTask` (4725); index out of range -> `stop()` (4727-4730).
3. Stop MusicKit if it was active, reset visible state to `.loading` (4748-4765), `ensureAudioSessionConfigured(mixWithOthers: wasAppleMusicActive)` (4766).
4. `prepareAudioEngineForPlaybackIfNeeded` 1576 (create at 1585 or recreate at 1587).
5. `resolveTrackForPlaybackIfNeeded` 7245, then gen + identity check (4789).
6. Publish: `currentTrack`, times, `bufferedProgress = 0`, `waveformHeights = []`, `isSkipTransitionInProgress = true`, arm 10 s safety, `engine.pause()`, analyzer pause, `playbackState = .loading` (4819-4830).
7. `generateWaveform` 1854 (4838).
8. Resolve loop, 2 attempts with 0.5 s backoff (4844-4936): cached file (4854) or `resolvePlaybackSource` (4863); truncation probe (4869-4879); superseded check (4882); `launchCoordinator.completeLaunch` (4892).
9. `loadAndPlaySource` 5698: activate session (5723); restore non-mixable category with one retry (5737-5755); cache file URL (5759); clear gapless schedule (5763); activate timeline (5766); `unexpectedPauseCount = 0` (5774); `bufferedProgress = source.initialBufferedProgress` (5776).
10. `engine.load` (5832), then:
    - `shouldStartPlayback == false`: `.paused`, skip flag cleared, save, end background task (5846-5855).
    - Otherwise `engine.play()` (5856), `trackStartWallTime` (5858), `playbackState = .buffering` for a streaming source or `.playing` for a file (5860).
    - File source: analyzer resume, `consecutivePlaybackFailures = 0`, end background task, skip flag cleared (5862-5872).
    - Streaming source: those four happen later in `onFirstAudibleRender` (1435-1443).
    - Handoff active: load only, `.buffering`, skip flag cleared, background task and failure counter untouched (5780-5820).
11. No `reportState("playing")` and no `reportingController.resetForTrack()` on this path.

### Starting a track, Apple Music

1. Same steps 1-2, then the branch at 4733: `audioEngine?.stop()` (4734), `ensureAudioSessionConfigured(mixWithOthers: true)` (4735), `playCurrentAppleMusicSegment` (4741), end background task (4745).
2. `playCurrentAppleMusicSegment` 6182: `pendingPreBufferTime = nil` (6193); segment is always exactly one track (6194, 448-451); analyzer pause; `currentTrack`, times, clear waveform and bands, `.loading` (6198-6204); create controller (6207); `controller.stop()` (6211); `controller.play` (6219); gen + identity check (6224); prune unresolved items (6228-6238); `.playing` (6239).
3. Failure: stop both players, `.failed`, end background task (6241-6256).

Differences from native start:
- No retry loop, no `consecutivePlaybackFailures` accounting, no TLS or health-check path.
- `bufferedProgress` is not reset; `trackStartWallTime` is not updated (so the bridge's `trackAge` at 2542-2545 measures from the last native track); no waveform, no prefetch, no journey log.
- The skip flag is cleared only if it was already set on entry (6186-6192); the AM branch never sets it itself.
- No timeline reporting at all: `observePlayingProgress` exists only in the native tick (1534).

### Pausing

Canonical path:
1. `pause()` 3217 -> Task -> `pauseInternally` 3224 -> `handoffCoordinator.handle(.pauseRequested)` (3225) -> `applyHandoffOutcome` 2300 -> `applyPauseForHandoff` 2338.
2. `applyPauseForHandoff`: guard (2340); **gen bump** (2341); cancel `skipTransitionTask` (2342); skip flag cleared (2344); `appleMusicPlaybackController.pause()` or `audioEngine.pause()` (2347-2355); sync time from engine (2356-2359); `.paused` (2360); Now Playing (2361); analyzer pause (2363); report "paused" (2368); autoplay refresh for user/system reasons (2371-2375); end background task (2376).

Because pause bumps gen, every native engine callback is dropped until resume calls `adoptPlaybackGeneration` (3307, 3352, 6887). A pause during `.loading` therefore cancels the in-flight start.

Other code that produces `.paused` without that sequence:
- `selectQueueItemWhilePaused` 3863-3890: gen bump, `engine.stop()`, no report.
- `loadAndPlaySource` with `shouldStartPlayback == false` 5846-5855.
- `reloadCurrentTrackForQualityChange` 6535-6540: starts playback, then `engine.pause()` and `.paused`; no gen bump, no report, no check that state is unchanged after the await.
- `handleAccountSourcesChanged` 6813-6814: starts playback, then `applyPauseForHandoff`.
- `restorePlaybackState` 7192.
- MusicKit `onPaused` 6140-6145 calls `applyPauseForHandoff(reason: .system)` directly, so the handoff coordinator never records a pause reason.

### Resuming

`resume()` 3232 -> Task -> `resumeInternally` 3239 -> `.resumeRequested` -> `applyResumeForHandoff` 2380 -> `resumeCore` 3248 (guard: `.paused` or `.buffering`, 3249). Four branches:

| Branch | Lines | Sequence | Missing compared with branch D |
|---|---|---|---|
| A. Apple Music | 3252-3287 | `pendingPreBufferTime = nil`; `.buffering`; rebuild through `playCurrentQueueItem(seekTo:)` if restored or no active AM queue (3260-3265), else `controller.resume()` (3272) -> `.playing`; error -> rebuild (3280) | report, autoplay refresh, prefetch, failure reset |
| B. Native, engine empty, pre-buffer running | 3296-3331 | `.buffering`; await `preBufferTask`; adopt gen; `engine.resume()`; `.playing`; prefetch; autoplay; report | `setActive`, failure reset, end background task |
| C. Native, engine empty, no pre-buffer | 3334-3337 | `playCurrentQueueItem(seekTo: currentTime)` | full start path |
| D. Native, engine loaded | 3340-3383 | `setActive(true)` (3342); adopt gen (3352); `engine.resume()` (3353); sync time; end background task; analyzer resume; latency refresh; `.playing` (3366); `consecutivePlaybackFailures = 0` (3370); autoplay; prefetch; report "playing" (3382) | reference |

Also: `handleNetworkStateTransition` calls `engine.resume()` on reconnect while `.buffering` with no state change (6885-6888); MusicKit `onResumed` sets `.playing` directly (6146-6156); `nudgeForAirPlayRoute` 3393.

### Seeking (playing and paused)

`seek(to:)` 3893 handles both states identically except in the stream-restart case:
1. Cancel SmartMix (3895); clamp to `duration` (3896-3897).
2. Apple Music: clear inferred-previous marker (3900); `controller.seek` (3901); times; Now Playing; save (3902-3904).
3. Native: journey mark (3909); `engine.seek` (3912); times (3913); Now Playing; save (3917-3918).
4. Native stream that cannot seek in place (`streamingSeekUnavailable`, 3920): compute `shouldStartPlayback` (while `.loading` reuse `playbackPreparationShouldStart`, otherwise `state != .paused`, 3922-3923), capture gen, Task -> `playCurrentQueueItem(seekTo:shouldStartPlayback:)` (3925-3933). Paused seek ends in `.paused` through 5846.

Other seek paths:
- Launch coordinator recovery seek, gen-checked (1216-1220), goes through `seek(to:)` and therefore also saves and republishes.
- `preBufferRestoredTrack` seeks the engine directly (6052).
- Fast seek calls `seek(to:)` every 100 ms (3967), so it saves a queue snapshot and republishes Now Playing ten times a second.
- `previous()` restart (3705, 3761, 3815, 3836).

There is no seek token. A seek issued during `.stopped` or `.failed` is not rejected.

### Stalling

- Rebuffer: `onStreamingRebufferingChanged` flips `.playing` <-> `.buffering` (1452-1456).
- Buffer pressure: 1447-1451 -> `updateNetworkWorkPressure` 1013 -> scheduler interaction + callback; also blocks prefetch in a 250 ms poll (5387-5390).
- Stream error while playing/buffering/loading: `onError` (1487-1492) -> `recoverCurrentStream` 1546: guard one recovery at a time (1547); `engine.pause()`; `.buffering`; `stallRecoveryTask` -> `retryCurrentTrack(forceConnectionRefresh: false, reason: "stream-interrupted")` (1554-1559).
- Stall detection by watchdog no longer exists (5896-5907 are comments).

### Failing

`playbackState = .failed(...)` is assigned in 18 places, with different cleanup at each:

| Site | Cause | Skip flag cleared | Background task ended | Now Playing pushed | Failure counter |
|---|---|---|---|---|---|
| 1496 | engine error, non-streaming | no | yes | via didSet only | no |
| 1592 | engine could not be created | no | by caller 4783 | didSet | no |
| 2742, 2887 | nothing playable | via `stop()` | via `stop()` | didSet | reset by `stop()` |
| 3347, 3358 | resume failed | no | yes | yes | no |
| 3515 | AM station skip failed | no | no | didSet | no |
| 4736, 4770 | audio session unavailable | no | yes | yes | no |
| 4997 | connection failure | yes | yes | didSet | +1 or forced to max (4982-4989) |
| 5007 | generic failure | yes | yes | didSet | +1 |
| 5135 | TLS (`failTLSPlayback` 5131) | yes | by defer 5070 | yes | +1 at 5087 |
| 5706 | no engine in `loadAndPlaySource` | no | yes | didSet | no |
| 5732, 5749 | session activation / category | no | yes | 5749 only | no |
| 6245, 6253 | Apple Music play failed | if set on entry | yes | yes | no |
| 6690 | next item known unavailable | yes | no | didSet | no |

Every transition to `.failed` or `.stopped` also feeds `handoffCoordinator.handle(.playbackStopped)` through the didSet (2231-2240). `handleQueueExhausted` refuses to advance from `.failed` (1796-1799).

### Retrying and recovering

| Path | Lines | Trigger | Resumes at |
|---|---|---|---|
| In-request retry | 4844-4936 | resolve or load threw and `shouldRetryResolution` | same seek time |
| Local-open recovery | 4946-4964, test 5012-5021 | CoreAudio open error on a local file | same seek time, after `recreatePlayer()` |
| TLS recovery | 5061-5128 | `classifyTerminalFailure == .tls` (4967) | same seek time; backoff `failures x 0.5 s` (5097); refresh connection; rebuild upcoming; replay |
| Manual retry | 3480-3483 -> 5023 | user | **0** unless state is playing/buffering (5026-5032) |
| Stream interrupted | 1546-1560 | engine error on active stream | `currentTime` |
| Health-check recovery | 6001-6007 | health check completes while `.failed` and no local file | 0. Not restricted to Plex, so a failed Apple Music track is restarted as well |
| Download fallback | 5036-5045 | local file appeared | recovery time |
| Apple Music resume recovery | 3277-3284 | `controller.resume()` threw | `currentTime` |
| Network reconnect | 6879-6889 | reconnect | explicitly does nothing when `.failed` (6882-6884) |

The circuit breaker (`consecutivePlaybackFailures >= 3`) only stops TLS retries (5088). Connection and generic failures increment it but nothing else reads it.

### Interruption begin / end

1. `handleAudioSessionInterruption` 2406: tell MusicKit (2417); if the current track is Apple Music, return (2418-2424).
2. Began: `handoffCoordinator.handle(.interruptionBegan)` (2430) -> `applyHandoffOutcome` -> `.pausePlayback` -> `applyPauseForHandoff` (gen bump, engine pause, `.paused`, report).
3. Ended: `.interruptionEnded(shouldResume:)` (2439) -> `.resumePlayback` -> `resumeCore`.
4. While the coordinator says "suppress automatic advance": gapless advance ignored (1608), `handleQueueExhausted` returns and re-applies pause if `.buffering` (1759-1765), a new start loads without playing and parks in `.buffering` (5780-5820), remote skip refused (2387).
5. Any explicit start, next, or previous resets the coordinator (`resetHandoffForUserPlaybackIntent` 2673; called at 2722, 2868, 3492, 3716, 3764, 3826, 3839).
6. Apple Music: the service only mirrors MusicKit through `onPaused` / `onResumed` (6140-6156).

### Route change

1. `handleAudioSessionRouteChange` 2452: Apple Music with an active queue -> refresh latency and return (2462-2473).
2. Native: `engine.prepareForRouteChange()` (2476); for a new device compute a settle deadline, 4 s AirPlay or 2 s otherwise (2480-2484); `handoffCoordinator.handle(.routeChanged)` (2489).
3. Actions (2306-2334): refresh latency (2186), pause, schedule settle window (cancels the previous one, 2315), resume.
4. Settle task end: `.settleWindowFinished` (2322), `unexpectedPauseCount = 0` (2327).
5. Latency also refreshed after session configuration (2090-2092), activation (2111), resume (3365), play (5857), and mirroring changes (1085).

### Handoff between the native engine and Apple Music

| Direction | Sequence | Lines |
|---|---|---|
| Native -> Apple Music | Native track ends -> `handleQueueExhausted` -> `playCurrentQueueItem` -> `audioEngine.stop()` -> session `mixWithOthers: true` -> `playCurrentAppleMusicSegment`. Prefetch refuses to schedule an AM successor and clears the schedule (5442-5447), so this boundary is never gapless | 1817-1823, 4733-4747 |
| Apple Music -> native | `onEnded` -> `advanceAfterAppleMusicSegment` sets `.loading` and the skip flag (6318-6320) -> `playCurrentQueueItem` -> `controller.stop()` (4750) -> reset visible state (4756-4765) -> session still mixable (4766) -> `loadAndPlaySource` activates and switches back to non-mixable, one retry (5723-5755) | 6289-6324, 4748-4774, 5722-5756 |
| Apple Music -> Apple Music | Same as above; each track is its own one-item MusicKit queue (448-451) unless a station is active | 6194 |

Ownership of interruptions and route changes follows `currentTrack?.isAppleMusic` at the moment the notification arrives (2418, 2463).

### Places where two code paths implement the same transition differently

1. `play` (2694-2810) vs `shufflePlay` (2846-2957): near copies. Only `play` is `@MainActor` and only `play` raises `playbackPreparationCount` (2696-2701).
2. Advance to the next track has five implementations: `handleQueueExhausted` 1739, `next()` 3547-3609, `handleSmartMixNextIfNeeded` 3652-3681, `navigateToNextQueueItemWhilePaused` 3798, `advanceAfterAppleMusicSegment` 6289. End-of-queue behaviour differs in each (section 5).
3. "Current track changed" bookkeeping has four implementations: `handleEngineTrackAdvance` 1600-1663, `handleSmartMixPromotion` 1665-1703, `handleAppleMusicTrackChanged` 6261-6285, `handleAppleMusicRadioTrack` 6342-6373. Only the first resets the failure counter (1638) and honours `isNavigatingBackward` (1630). The two AM versions do not reset reporting, buffered progress, waveform, or `trackStartWallTime`, and start no prefetch or autoplay check.
4. Pause: six variants (above).
5. Resume: four branches plus two side paths (above).
6. `.failed`: 18 sites with inconsistent cleanup (table above).
7. Teardown: `stop()` 3409-3448, `clearPlaybackAfterSourcePrune` 6832-6858, `cleanup()` 6938-6985, `selectQueueItemWhilePaused` 3863. `stop()` clears `currentTrack` but leaves `queue` and `currentQueueIndex` and does not save. The source-prune version keeps the engine and does not report "stopped".
8. Start-complete cleanup happens in three places with different contents: 5862-5872 (file), 1435-1443 (stream), 5816-5818 (handoff-deferred).
9. Playability filtering: `resolvePlayableQueue` 2996-3084, `findNextPlayableTrackIndex` 6714, `playQueueIndex` 3134-3141, `reportUnavailableNextTrackIfNeeded` 6669.
10. Download-path resolution: `resolveOfflinePlayableTrack` 3086 (consults the artifact cache, 3097) vs `resolveTrackForPlaybackIfNeeded` 7245 (does not; clears a stale path at 7285-7286).
11. Truncated-file probe duplicated at 4869-4879 and 5491-5500.
12. `loadAndPlaySource` contains two copies of the load block (5782-5815, 5822-5843).
13. Deferred pre-buffer scheduled at 5988 and 7213; neither cancels an existing `preBufferTask`.

---

## 5. Queue operations as implemented

| Operation | Plex / native | Apple Music | Behavioural difference |
|---|---|---|---|
| Next, playing | `next()` 3486-3610: cancel previous skip task, set skip flag, `engine.clearScheduledFiles()` + `engine.pause()`, `.loading`, record history, then task: next playable -> `playCurrentQueueItem` | Same function. Station active: `skipToNextEntry` only (3498-3520). Otherwise the generic path runs | In the generic path nothing stops MusicKit until `controller.stop()` inside the new start (4750 or 6211). `engine.pause()` at 3537 is a no-op for AM, and AM time callbacks are still accepted in `.loading` (497) after `currentTrack` has moved (3557) |
| Next, during SmartMix | `handleSmartMixNextIfNeeded` 3613-3685: accept the incoming track if early (3627-3635), else cancel and skip past it | n/a | End of queue with autoplay on only calls `refreshAutoplayQueue()` (3676-3677): it neither plays nor stops, leaving `.loading` and the skip flag until the 10 s safety |
| Next, paused | `navigateToNextQueueItemWhilePaused` 3798-3809 -> `selectQueueItemWhilePaused` 3863 | Same (stops MusicKit, 3871) | No autoplay fetch and no stop at end of queue; the command is a no-op there |
| Previous + 3-second rule | `previous()` 3688-3711; target from `queueController.previousNavigationTarget` (3689) -> `EnsembleQueuePolicy.previousNavigationTarget` (`PlaybackQueuePolicy.swift:25-41`): `currentTime > 3` -> restart; else queue index - 1; else last history item; else restart. Threshold constant at 273. Playing: 3714, 3759. Paused: 3812-3850 | Same, plus an inferred previous: MusicKit restarts the track itself on a system "previous", so a rewind to <= 0.75 s from <= 3 s is treated as a previous command (276-285, 6417-6433) | AM needs two observations (restart marker at 6420-6422, then inference). Now Playing uses a literal `currentTime > 3` (7009) instead of the constant. Previous does not check playability of the target (3715), next does |
| Natural completion, successor pre-scheduled | `onTrackAdvance` -> `handleEngineTrackAdvance` 1600; SmartMix -> `handleSmartMixPromotion` 1665 | Station or MusicKit-internal advance -> `handleAppleMusicTrackChanged` 6261, `handleAppleMusicRadioTrack` 6342 | See difference 3 in section 4 |
| Natural completion, nothing scheduled | `onPlaybackComplete` -> `handleQueueExhausted` 1739-1852 | `onEnded` -> `advanceAfterAppleMusicSegment` 6289-6324 | Native has guards the AM path lacks: TLS wait (1744), skip in progress (1754), handoff (1759), re-entrancy (1767), rate limit of more than 3 calls in 2 s (1774-1783), `.failed` (1796). Native records history before deciding (1805); AM only when it advances (6314). Native follows with `checkAndRefreshAutoplayQueue` (1822); AM does not |
| End of queue | 1826-1851: autoplay on -> AM station if the seed is AM (1827-1830), else `refreshAutoplayQueue` and play the appended item (1831-1842), else `stop()` | 6303-6312: autoplay on and (no next item, or next item is an autoplay item) -> truncate the queue from that point and start a station (6305-6307); else `stop()` | AM discards already-queued autoplay items in favour of a station; native plays them |
| Repeat off | Falls through to end-of-queue | Same | none beyond the above |
| Repeat all | Natural: `nextQueueIndexAfterCompletion` 1729-1735 wraps to the first playable item (1720-1726). Gapless: wrap comes from `prefetchController.upcomingQueueIndices(repeatMode:)` (5348-5355). Manual: 3567-3582 | Natural: the same `nextQueueIndexAfterCompletion` (6294) | See "2026-09-04 review" below |
| Repeat one | Natural: replay through `playCurrentQueueItem` (1809-1813). Gapless: same track scheduled, `queueIndexForAdvance(repeatCurrent:)` (1613-1625, 538-553). Manual next ignores repeat one and advances (3550) | Delegated to MusicKit: `repeatOneEnabled` passed at 6222 and 4524, changed live at 4291-4297 | `advanceAfterAppleMusicSegment` has no repeat-one branch; correctness depends on the controller not firing `onEnded`. `setRepeatMode` (4286-4302) does not invalidate an already-scheduled gapless successor, it only cancels SmartMix (4300) |
| Shuffle on / off | `toggleShuffle` 4246-4267 -> `queueController.enableShuffle` / `disableShuffle` -> `commitQueueMutation` 4154 (save, AM sync, gapless invalidation 4212). `play` forces off (2764), `shufflePlay` forces on (2908), restore sets it (7182) | Same, then `synchronizeAppleMusicQueueAfterMutation` 4165-4206 | For AM, if `discardUpcomingEntries()` returns false the current track is stopped and restarted at `currentTime` (4191-4200), which is audible |
| Play next | `playNext` 4026-4038 -> `queueController.insertUpNext` -> `commitQueueMutation` | Same + AM sync | as shuffle |
| Play last | `playLast` 4046-4058 -> `insertAtEndOfManualQueue` -> `commitQueueMutation` | Same + AM sync | as shuffle |
| Reorder | `moveQueueItem` 4101-4119; `queue = queue` to force a publish (4115); `commitQueueMutation(refreshAutoplay: false)` | Same + AM sync | as shuffle |
| Remove | `removeFromQueue` 4061-4085 | Station autoplay item: removed from MusicKit first, abort if that fails (4064-4073), and AM sync skipped (4084) | Only path where the AM queue is edited in place |
| Clear | `clearQueue` 4087-4096 | Same | Does not stop either player in this file |
| Autoplay / radio continuation | `checkAndRefreshAutoplayQueue` 4397 (fewer than 5 remaining), `refreshAutoplayQueue` 4443-4502 (dedupe 4357, trim to 5 at 4421, fetch 10 at 4469, append), delayed kick 4407, `enableRadio` 4543, `toggleAutoplay` 4306 | Station: `startAppleMusicAutoplayStationIfPossible` 4514-4541, `handleAppleMusicRadioTrack` 6342, `handleAppleMusicRadioQueue` 6377 | Two unrelated mechanisms. Native appends items it fetched; AM mirrors whatever MusicKit reports and rewrites the queue tail (6382-6384) |
| Restoration at launch | `restorePlaybackState` 7092-7227: load off-main (7097), resolve download path (7122), prune by enabled sources (7132, 702-726), `startupCoordinator.makeRestoreDecision` (7158), publish as `.paused` with `pendingPreBufferTime` (7179-7194), pre-buffer now / after 3 s / after health check (7206-7218, 5986-5996), autoplay refresh (7220-7224) | Same publish step; pre-buffer is skipped (5986) and the first resume rebuilds the MusicKit queue at the saved time (3253-3265) | AM has no paused pre-load |

### The 2026-09-04 review, checked against the current file

**Repeat All: partly out of date.**
- The wrap decision is now shared. Both natural-completion paths call `nextQueueIndexAfterCompletion` (1729-1735), native at 1817 and Apple Music at 6294, and `completionQueueIndex` wraps when `repeatMode == .all` (1720-1726).
- They still differ around it:
  - Apple Music evaluates autoplay before advancing, and calls `shouldStartAppleMusicAutoplay` without the `isWrappingQueue` argument (6303; parameter declared at 522-526, passed only in `PlaybackServiceTests.swift:1700`). If the wrapped target is an autoplay item, `autoplayStart` becomes that index and `queue.removeSubrange(autoplayStart...)` (6305-6306) truncates from there, which for index 0 is the whole queue including the current item.
  - Native wraps unconditionally when a playable item exists and only then considers autoplay (1817-1826).
  - Manual `next()` wraps for both providers (3567-3579); paused next wraps (3802-3805); SmartMix next wraps (3665-3675).

**Progress generation checks: no longer accurate as stated.** Both paths check a token, but not the same one.
- Native: `playbackState == .playing`, `progress.generation == playbackGenerationCounter`, `engine.isCurrentProgress(progress)` (1507-1510), then track identity (1519).
- Apple Music: `isCurrentAppleMusicQueue(queueGeneration)` (6406), which compares against the controller's `activeQueueGeneration` (6456), not `playbackGenerationCounter`. No track-identity check. Accepted in `.loading` and `.buffering` as well as `.playing` (497).
- So an Apple Music time event is not invalidated by a service-side gen bump (pause 2341, new start 4719) until MusicKit is actually stopped.

---

## 6. Task launch sites

Counts (`rg` over the file; one false match on `preBufferTask {` at 3296 excluded):

| Construct | Count |
|---|---|
| Unstructured `Task { ... }` total | 68 |
| of which `Task { @MainActor ... }` | 51 |
| of which plain `Task { ... }` | 16 |
| of which `Task(priority: .utility) { ... }` | 1 (5309) |
| `Task.detached` | 2 (1250, 7097) |
| `DispatchQueue` references | 12: 7 `DispatchQueue.main.async` (828, 1408, 1415, 1422, 1431, 1459, 1480), 4 `.receive(on: DispatchQueue.main)` (1505, 6072, 6491, 6730), 1 debounce scheduler (6478) |
| `MainActor.run` | 42 |
| `MainActor.assumeIsolated` | 4 (1530, 1649, 1691, 6727) |

Classification of the 68 + 2:

| Group | Sites | Count |
|---|---|---|
| Bridge a callback or sync API onto the main actor | 1018, 1400, 1472, 1863, 2181, 2363, 2509, 2514, 2519, 2529, 2532, 2535, 3218, 3233, 3523, 3697, 5470, 5934, 5942, 5955, 5961, 6069, 6074, 6134, 6481, 6739, 6943 | 27 |
| Fire-and-forget side effect (prefetch, autoplay refresh, gapless invalidation, artwork) | 1659, 1660, 1699, 1700, 2372, 3313, 3314, 3373, 3378, 3889, 4213, 4312, 4337, 4341, 5302, 6563, 7221 | 17 |
| Fire-and-forget async operation whose result changes state | 1869 (waveform), 2568 (rating), 3258 (AM resume), 3300 (await pre-buffer), 3334 (start), 3502 (AM skip), 3925 (seek restart), 4177 (AM queue resync), 4291 (AM repeat one) | 9 |
| Stored transition task | `skipTransitionTask` 3547, 3652, 3748, 3787; `stallRecoveryTask` 1554; `gaplessScheduleRequestTask` 5338; `artworkPrefetchTask` 5309 | 7 |
| Stored debounce / delay | `handoffSettleTask` 2316; `audioCriticalInteractionEndTask` 2825 (3 s); `postPlaybackAutoplayRefreshTask` 4409 (1.5 s); `skipTransitionSafetyTask` 5915 (10 s); `preBufferTask` 5988, 7213 (3 s); `qualityDebounceTask` 6105 (2 s) | 7 |
| Stored loop | `fastSeekTask` 3962 (100 ms) | 1 |
| Detached | 1250 (visualizer timeline load, optional start delay), 7097 (snapshot read, awaited) | 2 |

Loops that live inside other tasks rather than owning one:
- Start retry: 2 attempts, 0.5 s (4844-4849).
- TLS backoff (5097).
- Prefetch waits on `networkWorkDeferred` in an unbounded 250 ms poll (5387-5390).
- `handleQueueExhausted` yields up to 100 times waiting for the TLS handler (1746-1749).

Not cancelled anywhere:
- All 53 unstored tasks in the first three groups. They rely on gen or identity checks where they have any; 1659/1660, 1699/1700, 3313/3314, 3373/3378 and the other prefetch and autoplay launches have none of their own.
- `Task.detached` at 1250: checks `Task.isCancelled` (1253) but the handle is discarded.
- `preBufferTask` (5988, 7213): never cancelled; only awaited (3301) and set to nil (3304, 5994, 7216). Not in `cleanup()` or `deinit`.

Cancelled only in some paths:
- `skipTransitionTask`: cancelled on re-entry (3530, 3637, 3719, 3766), pause (2342), paused navigation (3867). Not cancelled by `stop()` or `cleanup()`.
- `qualityDebounceTask`: re-arm (6104) and `deinit` (1354) only.
- `artworkPrefetchTask`: re-arm (5308), cache reset (6493), `deinit` (1362).
- `stallRecoveryTask`: 1802 and `cleanup()` 6963.
- `handoffSettleTask`: re-arm 2315 and `cleanup()` 6939.
- `gaplessScheduleRequestTask`, `audioCriticalInteractionEndTask`, `postPlaybackAutoplayRefreshTask`, `fastSeekTask`, `skipTransitionSafetyTask`: `cleanup()` 6966-6980 (plus their own re-arm).

Hazards visible from the launch sites:
- `cleanup()` runs from `deinit` (1350) and starts `Task { @MainActor in self.audioAnalyzer.stopAnalysis() }` with a strong `self` (6943-6945).
- `cleanup()` cancels `audioCriticalInteractionEndTask` (6977), so `endInteraction(.audioCritical)` (2828) is skipped if `stop()` runs within 3 s of a start.
- `gaplessScheduleRequestTask` and `preBufferTask` clear their own handle unconditionally when they finish (5340, 5994, 7216), which can erase a newer task's handle.

---

## 7. Findings that matter for the reducer, and open questions

### Findings (verified by reading)

- **F1. Two generation spaces.** Native callbacks are validated against `playbackGenerationCounter`; Apple Music callbacks against the controller's `activeQueueGeneration` (6449-6462). Pause bumps the first (2341) and resume re-adopts it into the engine (3352), so "generation" currently means "request", not "track session".
- **F2. Network observation does not survive the first `stop()`.** `cleanup()` cancels `networkStateObservation` (6959-6960); `stop()` and `recreatePlayer()` call `cleanup()` (3433, 1566); `setupNetworkObservation()` is called only from `init` (1340). After that, `handleNetworkStateTransition` never runs and `lastObservedNetworkState`, which feeds `observePlayingProgress` (1538), is frozen. Not confirmed at runtime.
- **F3. Awaits with no token afterwards:** `playableQueueResolved` (2729, 2875), `waveformLoaded` (1888), `queueDownloadStateRefreshed` with `inout queue` across the suspension (6607-6608), `qualityReloadFinished` (6531-6540), source-prune replay (6811-6814).
- **F4. Unsynchronised mutation.** The class has no actor. `shufflePlay`, `playQueueIndex`, `playFromHistory`, `playNext`, `playLast`, `clearQueue`, `moveQueueItem`, `toggleShuffle`, `setRepeatMode`, `toggleAutoplay`, `refreshAutoplayQueue`, `enableRadio`, `retryCurrentTrack`, `refreshQueueDownloadState` are not `@MainActor`, and two engine callbacks write state without hopping to main (1447-1456).
- **F5. `playbackState` didSet is a hidden effect fan-out** (819-830): work-pressure update, handoff coordinator sync, presentation-time refresh, deferred Now Playing publish.
- **F6. Dead or inert state:** `unexpectedPauseCount`, `prefetchThrottleUntil`, `loadingStateTask`, `isAutoplayActive` (never true), `isExternalPlaybackActivePublisher` (no production consumer), fast-seek API (no production caller), circuit breaker outside TLS.
- **F7. `isNavigatingBackward` is cleared only by the next gapless advance** (1633), so after any "previous" the next gapless transition skips its history entry (1630), while `handleQueueExhausted`, `next()` and the AM paths ignore the flag.
- **F8. Apple Music produces no timeline reporting from this file**, and native reports "playing" only on resume (3316, 3382), never on a fresh start.

### Open questions

1. Does `PlaybackReportingController.observePlayingProgress` detect track changes itself? `resetForTrack()` is only called on gapless advance, SmartMix promotion and source prune (1643, 1688, 6853), not on a normal start.
2. Does `AppleMusicPlaybackController` fire `onEnded` while repeat-one is enabled? `advanceAfterAppleMusicSegment` would advance if it does (6289-6324).
3. On which thread does `AudioPlaybackEngine` invoke `onPlaybackComplete`, `onStreamingBufferPressureChanged` and `onStreamingRebufferingChanged`? The handlers read or write service state without a main hop (1389, 1449, 1455).
4. What does `PlaybackHandoffCoordinator` return for each event (which route reasons pause, when it resumes, how long "suppress automatic advance" lasts)? The service only applies its actions (2306-2334); the rules live in `PlaybackHandoffCoordinator.swift`.
5. What happens to playback when `queueController.removeItem` removes the current item, and when `clearQueue` empties the queue? Neither stops a player in this file (4075-4096).
6. Does `syncCoordinator.makeRadioProvider(for:)` return a provider for an Apple Music source key? If so, native-style autoplay appends (4466-4501) and the station mechanism can both run for the same queue.
7. Is the Repeat All truncation at 6305-6306 reachable in practice (wrapped target with `source == .autoplay`)? It needs an autoplay item to be the first playable item in the queue.
8. Is F2 intended (comments at 5937 and 6864 say adaptive buffering was removed) or a regression? It also disables the upcoming-queue rebuild on interface switch (6875-6877).
9. Is the health-check auto-retry meant to apply to Apple Music tracks (6001-6007)?
10. After `setRepeatMode`, should an already-scheduled gapless successor be invalidated? Today it is not (4286-4302), so the previously scheduled track plays once more.
11. `stop()` leaves `queue` and `currentQueueIndex` populated with `currentTrack == nil` and does not persist (3409-3448). Is "stopped with a queue" a state the new `PlaybackState` must represent, or an accident?
12. Who owns the two start-context checks the bridge pulls (`trackAge`, `currentTime`, 2541-2545)? Stale-seek rejection is implemented in `PlaybackNowPlayingBridge`, not here, and `trackStartWallTime` is not maintained for Apple Music.
