---
name: recent-changes
description: "Changelog of recent major features and subsystem changes. Load when debugging, investigating prior work, understanding how a feature was implemented, or before touching an area that was recently modified. Covers: cold launch optimization, low power mode, app performance optimization, live lyrics, sharing, startup/sync performance, playback/scroll performance, frequency visualizer, WebSocket enhancements, network resilience, offline downloads, universal transcode, Siri intents, account management, sync system, playlist mutations, gesture actions, network health, Plex connectivity, adaptive playback."
user-invocable: true
---

# Recent Major Changes

### Cold Launch Startup Optimization (Mar 2026)
Three independent bottleneck fixes saving ~7.5s total on normal user launches:

1. **Deferred stream pre-buffer (saves ~3.35s):** `restoreQueueFromItems()` no longer immediately creates an `AVURLAsset` + `AVPlayerItem` for streaming tracks. The UI only needs track metadata (already restored from QueueItem JSON). Local files still pre-buffer instantly. Streaming tracks defer pre-buffer to 3s after health checks complete. `resume()` already handles the no-player-item case via `playCurrentQueueItem()`.

2. **Removed 5s unconditional sync delay (saves ~5s):** The blanket `Task.sleep(5s)` before startup sync is removed. Normal launches start sync immediately. Siri launches retain a 2s delay for audio session setup. Sync runs at `.utility` priority so it doesn't compete with the Siri audio path.

3. **MainActor task sequencing (saves ~300ms):** Siri media index rebuild and WebSocket coordinator start now `await earlyHealthCheckTask?.value` before beginning, giving health checks uncontested MainActor time during the critical launch window.

**Key files:**
- `Ensemble/App/AppDelegate.swift` — sync delay removal, MainActor sequencing
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — deferred pre-buffer in `restoreQueueFromItems()` and `handleHealthCheckCompletion()`

### HomePod Siri AirPlay Routing — FIXED (Mar 2026)
Fixed HomePod Siri → Ensemble playback routing to HomePod (previously played on iPhone speaker).

**Root cause:** Both the app and extension declared `INPlayMediaIntent` in their Info.plists. iOS always chose the in-app handler via `INAppIntentDeliverer`, bypassing the Siri extension entirely. The extension returning `.handleInApp` is the signal iOS needs to establish AirPlay routing from HomePod — without the extension in the loop, no routing context existed.

**Fix (3 pieces):**
1. **Removed `INPlayMediaIntent` from app's Info.plist `INIntentsSupported`** — Forces iOS to route through the extension. The extension returns `.handleInApp` which triggers AirPlay route establishment.
2. **In-app handler returns `.success` immediately** — On cold launch, server health checks + playback take 5-8s, exceeding Siri's ~8s timeout. The handler now calls `completion(.success)` immediately and starts playback in the background.
3. **Extension writes Darwin notification fallback** — Belt-and-suspenders: writes payload to App Group and posts Darwin notification before returning `.handleInApp`, in case `UISIntentForwardingAction` delivery fails.

**Flow:** Extension invoked → `.handleInApp` → AirPlay route established → intent forwarded to app → immediate `.success` → background playback starts → audio plays on HomePod.

**Cold launch latency:** ~14s from Siri trigger to audio (10s is app startup overhead). Optimization opportunity: start server health checks during `didFinishLaunching`.

### HomePod Siri Cold Launch Failures — Earlier Fixes (Mar 2026)
Fixed three failure modes when HomePod Siri cold-launches Ensemble:
1. **Session activation denied (error -16980)** — `setActive(true)` called before audio session category configured. Fixed by calling `ensureAudioSessionConfigured()` first.
2. **Playback started on iPhone instead of HomePod** — `setActive(true)` called after route poll. Fixed by activating before polling, extending poll from 6s to 10s.
3. **AirPlay starts but immediately pauses** — `unexpectedPauseCount` carried over from previous track. Fixed by resetting counters at gapless transitions and extending AirPlay settle window to 4s.

Also removed `.allowBluetooth` from audio session options (caused error -12981 on iOS 26).

**Key files:**
- `Ensemble/App/AppDelegate.swift` — `application(handlerFor:)`, `InAppPlayMediaIntentHandler`, `executeSiriPlaybackInBackground`
- `Ensemble/Info.plist` — NO `INIntentsSupported` (only in extension)
- `EnsembleSiriIntentsExtension/PlayMediaIntentHandler.swift` — `handle()` with Darwin fallback
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — `ensureAudioSessionConfigured()`, `nudgeForAirPlayRoute()`

### Crash Fix: Duplicate Hub IDs in HubOrderManager (Mar 2026)
Fixed a P0 crash affecting all users: `HubOrderManager.applyOrder(to:for:)` and `applyDefaultOrder(to:for:)` called `Dictionary(uniqueKeysWithValues:)` which Swift fatally traps on duplicate keys. Duplicate hub IDs entered CoreData via a concurrent-save race: both `HomeViewModel` and `SearchViewModel` call `saveHubs` via detached background Tasks that each do a delete-all + insert in separate CoreData contexts; when they run concurrently, both insert a full hub list → 2× rows with identical IDs in the store. The next launch reads those duplicates, calls `applyOrder`, and crashes immediately (3–4s after launch) with `EXC_BREAKPOINT` / `_assertionFailure`.

**Fixes:**
- `HubOrderManager.applyOrder` and `applyDefaultOrder`: changed `Dictionary(uniqueKeysWithValues:)` to `Dictionary(uniquingKeysWith:)` — crash guard against any future duplicates
- `HubRepository.fetchHubs`: deduplicate by hub ID at read time so existing corrupt CoreData rows no longer reach `applyOrder`
- `HubRepository.saveHubs`: deduplicate input by hub ID before inserting, so the race can no longer write duplicate rows

**Key files:**
- `Packages/EnsembleCore/Sources/Services/HubOrderManager.swift` — `applyOrder`, `applyDefaultOrder`
- `Packages/EnsembleCore/Sources/Services/HubRepository.swift` — `fetchHubs`, `saveHubs`

### Background Playback Pause Bug Fix (Mar 2026)
Fixed an inconsistent bug where a track ending in the background would queue the next track but immediately pause it, requiring the user to press Play from system controls to resume.

**Root cause:** In the gapless transition path (`handleItemChange()`), `unexpectedPauseCount` and `lastUnexpectedPauseAt` were never reset when AVQueuePlayer auto-advanced to the next prefetched item. Stale pause counts from the previous track carried over. At gapless item boundaries, `timeControlStatus` briefly oscillates through `.paused`. If `unexpectedPauseCount` was already >0 from prior network stalls, the boundary pause could push it past the 3-pause loop-detection threshold, triggering the backoff (`playbackState = .buffering` + 5s stall recovery). The non-gapless path was unaffected because `loadAndPlay()` always resets the counter before calling `player?.play()`.

**Fix:** Reset `unexpectedPauseCount = 0` and `lastUnexpectedPauseAt = nil` in `handleItemChange()` when a gapless track transition occurs, mirroring what `loadAndPlay()` already does. Also improved debug logging at the `loadAndPlay()` deferred-start path.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — `handleItemChange()` counter reset; `loadAndPlay()` improved deferral log

### Low Power Mode Awareness (Mar 2026)
`PowerStateMonitor` observes iOS Low Power Mode and automatically reduces GPU and network work across the app:

- **PowerStateMonitor:** New `@MainActor ObservableObject` that listens for `NSProcessInfoPowerStateDidChange` notifications and publishes `isLowPowerMode: Bool`. Injected via `DependencyContainer`.
- **Aurora visualizer throttling:** When LPM is active, aurora drops to 1 glow pass at 15fps (from 3 passes at 30fps in normal mode). `isLowPowerMode` plumbed through `MainTabView`, `NowPlayingSheetView`, and `NowPlayingCarousel` to `AuroraVisualizationView`.
- **LyricsCard blur disabled:** Progressive blur returns 0 for all lines when LPM is active, eliminating expensive `GaussianBlur` filter applications on the lyrics surface.
- **Download auto-pause:** `DependencyContainer` wiring auto-pauses active downloads when LPM activates and auto-resumes when LPM deactivates.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PowerStateMonitor.swift` - LPM observer, publishes isLowPowerMode
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires PowerStateMonitor, auto-pauses/resumes downloads
- `Packages/EnsembleUI/Sources/Components/AuroraVisualizationView.swift` - 1 glow pass at 15fps in LPM
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - progressive blur disabled in LPM
- `Packages/EnsembleUI/Sources/Components/NowPlaying/NowPlayingCarousel.swift` - plumbs isLowPowerMode to cards
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift` - plumbs isLowPowerMode to aurora and Now Playing
- `Packages/EnsembleUI/Sources/Screens/NowPlayingSheetView.swift` - plumbs isLowPowerMode to carousel

### App Performance Optimization (Mar 2026)
Multi-phase optimization pass targeting GPU waste, download system queries, SwiftUI invalidation cascades, scroll performance, lyrics rendering, download queue polling, MediaTrackList layout waste, WebSocket event spam, singleton observer cascades, download toast bugs, artwork flashing, large playlist hangs, and queue performance:

- **Aurora visualizer:** Capped at 30fps (was 60fps -- band data already updates at 30fps). Reduced glow passes from 6 to 3 (blur=18, 12, 8). Pauses when Now Playing sheet covers it. Display timer uses `MainActor.assumeIsolated` instead of `Task { @MainActor }`. Identical frequency band publishes are skipped.
- **Download query batching:** After download completion, only owning targets are refreshed (not all). Batch `IN` predicate query replaces per-track `fetchDownload()` loops. Dynamic debounce: 3s when >3 downloads pending, 1s otherwise.
- **PlaybackService objectWillChange:** `frequencyBands` moved from `@Published` to `CurrentValueSubject<[Double], Never>` so `objectWillChange` no longer fires at 30Hz. `NowPlayingViewModel.applyLyricsPosition()` guards against no-change assignments of 4 `@Published` properties.
- **TrackRow availability decoupling:** `@ObservedObject availabilityResolver` (singleton) replaced with `@State private var cachedAvailability` + `.onReceive` that only updates when THIS track's availability changed. Applied to `TrackRow` and `CompactTrackRow`.
- **Songs view layout fix:** Non-indexed sort renders `MediaTrackList` directly without ScrollView wrapper or fixed-height frame (was defeating UITableView cell recycling). Search text filtering debounced at 150ms.
- **LyricsCard line isolation:** Extracted `LyricsLineView` as `Equatable` struct wrapped in `EquatableView`. SwiftUI skips unchanged lines (~2 re-renders per tick instead of N).
- **Download queue polling:** Fixed 1s polling in `PlexAPIClient.downloadTranscodedMediaViaQueue()` replaced with exponential backoff (1s->2s->4s->8s, capped 15s). WebSocket `media.download ended` events now routed through `PlexWebSocketCoordinator` to restart the download queue, fixing a bug where only 1 of N downloads stored.
- **MediaTrackList deferred layout:** `DeferredLayoutTableView` subclass skips `layoutSubviews()` before being in a window, eliminating early layout warnings from eagerly-created navigation destinations.
- **WebSocket settings debounce:** `PlexWebSocketCoordinator` debounces settings-changed events per server (5s window) to coalesce rapid bursts.
- **WebSocket scan progress throttle:** `serverScanProgress` only publishes when progress changes by >=5% (was every ~10ms). Cuts ~95% of scan-related objectWillChange events.
- **MediaTrackList singleton decoupling:** Removed 3 `@ObservedObject` singletons from `MediaTrackList`. Parent views observe once and pass `availabilityGeneration` + `activeDownloadRatingKeys` as value params. Eliminates N*3 subscriptions (26 sections * 3 singletons) in SongsView.
- **activeDownloadRatingKeys batching:** Removed per-track `refreshActiveDownloadRatingKeys()` from `refreshTargetsForTrack()`. The debounced `scheduleDownloadChangeNotification()` (1-3s) already handles it, batching spinner updates.
- **Download toast race fix:** `queueTask` is nil'd before the 500ms grace period re-check, so WebSocket `handleDownloadQueueCompleted()` can restart the queue. Re-checks for pending downloads before showing "Downloads Complete" toast.
- **Downloads view artwork stability:** `DownloadedItemSummary` made `Equatable`; `items` only assigned when values actually differ. Prevents ForEach from re-rendering all rows (and flashing artwork) on progress-only changes.
- **Large playlist layout fix:** `MediaTrackList` gains `managesOwnScrolling: Bool`. Track lists >200 items use self-scrolling UITableView with cell recycling. Removes `.frame(height:)` that forced all 1436 cells to render at once.
- **Queue performance fix:** `QueueTableView` replaced `IntrinsicTableView` with regular `UITableView` (scroll enabled). Removed `ScrollView` wrapper in `QueueCard`. `QueueItemCell` uses `configureGeneration` counter to prevent stale artwork during rearrange.

**Key files:**
- `Packages/EnsembleUI/Sources/Components/AuroraVisualizationView.swift` - 30fps cap, 3 passes, isPaused, state dedup
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift` - passes isPaused to aurora
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - no-change guard, MainActor.assumeIsolated
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - targeted refresh, dynamic debounce, toast race fix, activeDownloadRatingKeys batching
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - fetchDownloadsBatch
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift` - fetchTargetKeys(containing:)
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - CurrentValueSubject for frequencyBands
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - no-change guard in applyLyricsPosition
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - @State cached availability
- `Packages/EnsembleUI/Sources/Components/CompactSearchRows.swift` - @State cached availability
- `Packages/EnsembleUI/Sources/Screens/SongsView.swift` - removed fixed-height frame for unsorted case
- `Packages/EnsembleCore/Sources/ViewModels/LibraryViewModel.swift` - 150ms search debounce
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - Equatable LyricsLineView
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - exponential backoff for download queue polling
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - media.download routing, settings debounce, scan progress throttle
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - DeferredLayoutTableView, managesOwnScrolling, singleton decoupling
- `Packages/EnsembleUI/Sources/Screens/MediaDetailView.swift` - large playlist self-scrolling threshold
- `Packages/EnsembleCore/Sources/ViewModels/DownloadsViewModel.swift` - Equatable diff before assigning items
- `Packages/EnsembleUI/Sources/Components/QueueTableView.swift` - regular UITableView, configureGeneration guard
- `Packages/EnsembleUI/Sources/Components/NowPlaying/QueueCard.swift` - removed ScrollView wrapper

### Live Lyrics (Mar 2026)
Karaoke-style time-synced lyrics fetched from Plex and displayed in the Now Playing Lyrics Card:

- **LRC parser:** `LRCParser` (static) parses LRC-format files into timestamped `LyricsLine` structs. Falls back to plain-text (unsynced) parsing for tracks without timestamps.
- **LyricsService:** @MainActor ObservableObject that runs a three-step fetch pipeline: in-memory cache -> `.lrc` sidecar file -> Plex API. Cache is keyed by `ratingKey:sourceCompositeKey` with ~20-entry LRU eviction.
- **API endpoint:** `PlexAPIClient.getLyricsContent(streamKey:)` fetches raw LRC text from `/library/streams/{streamKey}`. `PlexStream` extended with lyrics fields; `PlexTrack.lyricsStream` returns the first stream with `streamType == 4`.
- **NowPlayingViewModel integration:** Subscribes to `LyricsService.lyricsState` and `PlaybackService.currentTimePublisher`. Binary search over the lines array produces `currentLyricsLineIndex` for the active line.
- **LyricsCard rewrite:** Three states -- loading spinner, "No Lyrics" empty state, and a scrollable karaoke list (active line highlighted, auto-scrolled to center; past/future lines dimmed).
- **Offline sidecar:** `OfflineDownloadService` generates `.lrc` sidecar after download when the track has a lyrics stream. `DownloadManager` cleans it up on removal.
- **API accessor:** `SyncCoordinator.apiClient(for:)` and `PlexMusicSourceSyncProvider.exposedAPIClient` allow `LyricsService` to make direct API calls for lyrics content without going through the full sync path.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/LyricsService.swift` - LRCParser, LyricsLine, ParsedLyrics, LyricsState, LyricsService
- `Packages/EnsembleCore/Tests/LyricsServiceTests.swift` - LRC parser tests
- `Packages/EnsembleAPI/Sources/Models/PlexModels.swift` - PlexStream lyrics fields, PlexTrack.lyricsStream
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - getLyricsContent(streamKey:)
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires LyricsService
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - lyricsState, currentLyricsLineIndex
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - apiClient(for:) accessor
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` - exposedAPIClient
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - .lrc sidecar generation
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - .lrc sidecar cleanup
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - three-state lyrics UI

### Sharing: song.link URLs + Audio File Sharing (Mar 2026)
Tracks and albums can now be shared via universal song.link links or as audio files:

- **Universal link resolution:** Two-step chain: MusicKit catalog search (no subscription needed) -> song.link API for universal sharing link. Falls back to Apple Music URL or plain text.
- **Audio file sharing:** Downloaded tracks share local file directly. Non-downloaded tracks download to temp directory via Plex universal stream URL, then present share sheet.
- **Context menu integration:** "Share Link..." and "Share Audio File..." in all track context menus (TrackRow, MediaTrackList). "Share Link..." in album context menu (AlbumCard).
- **Now Playing:** Share link button in secondary controls + share actions in ellipsis menu.
- **Drag and drop (iPad):** Downloaded tracks can be dragged from track lists to other apps (Files, GarageBand, etc.) via `NSItemProvider` on both SwiftUI and UIKit surfaces.
- **In-memory caching:** SongLinkService caches positive and negative results to avoid re-querying MusicKit/song.link.
- **Toast feedback:** Progress toast for non-downloaded file sharing, fallback toast when sharing as text.
- **Platform guards:** `#if canImport(MusicKit)` for watchOS 8 compatibility; `NoOpMusicCatalogSearcher` fallback produces text-only payloads.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/SongLinkService.swift` - MusicKit search + song.link API + caching
- `Packages/EnsembleCore/Sources/Services/ShareService.swift` - Share payload coordinator + temp download
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - Service wiring
- `Packages/EnsembleUI/Sources/Components/ShareSheet.swift` - UIActivityViewController / NSSharingServicePicker wrapper
- `Packages/EnsembleUI/Sources/Components/ShareActions.swift` - Static share action helpers with toast feedback
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - Share context menu + onDrag
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - UIKit share menu + drag delegate
- `Packages/EnsembleUI/Sources/Components/AlbumCard.swift` - Album share link in context menu
- `Packages/EnsembleUI/Sources/Components/NowPlaying/ControlsCard.swift` - Share button + menu items
- `Ensemble/Info.plist` - NSAppleMusicUsageDescription
- `Ensemble/Ensemble.entitlements` - MusicKit entitlement

### Startup & Sync Performance Optimization (Mar 2026)
Eleven-item optimization pass targeting startup latency, network traffic, CPU waste, and temp storage:

- **Persisted failed hub keys:** `failedHubKeys` saved to UserDefaults so 404-returning hub endpoints are skipped across app launches. Cleared on pull-to-refresh or account changes.
- **Quality change debounce (2s):** Rapid quality setting changes debounce the expensive stream reload. Stale prefetch items are invalidated and re-fetched at the new quality.
- **Tighter stream cache eviction:** Cache files limited to playback neighborhood (current + next 2 + previous 1) instead of all cached player item IDs.
- **Faster FFT cancellation:** Cancellation checks every 2 keyframes (~0.2s) instead of 10 (~1s). Cancelled tasks no longer block callers.
- **Waveform fetch guard:** Skip waveform API call when track has no stream ID (reduces log noise, avoids unnecessary codepath).
- **Optimistic network state:** Last-known `NetworkState` cached to UserDefaults and restored on launch, so dependents begin immediately instead of waiting ~5s for NWPathMonitor.
- **Deferred audio session:** `configureAudioSession()` moved from `didFinishLaunching` to first playback (`ensureAudioSessionConfigured()`), avoiding Code=-50 errors. Adds `setActive(true)`.
- **ratedAfter optimization:** Skips the `lastRatedAt>=` fetch when sync timestamp is >10 minutes old, eliminating ~1MB of redundant API traffic per hourly sync.
- **CoreData merge policy:** `replaceMemberships()` uses `mergeByPropertyObjectTrumpMergePolicy` with single retry for concurrent target writes referencing shared tracks.

**Key files:**
- `Packages/EnsembleCore/Sources/ViewModels/HomeViewModel.swift` - persisted failedHubKeys
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - quality debounce, stream cache, audio session deferral, waveform guard
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - faster FFT cancellation
- `Packages/EnsembleCore/Sources/Services/NetworkMonitor.swift` - cached network state
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` - ratedAfter optimization
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift` - merge policy + retry
- `Ensemble/App/AppDelegate.swift` - removed configureAudioSession from launch

### Playback & Scroll Performance Optimization (Mar 2026)
Three-phase optimization targeting tap-to-play latency, visualizer timing, and scroll performance:

- **Fire-and-forget FFT analysis:** `loadTimeline()` is no longer `await`ed before `loadAndPlay()`. Uses `Task.detached` to avoid MainActor contention during multi-second FFT analysis. Visualizer shows zeros until analysis completes, then smoothly starts. Current-track analysis runs at `.userInitiated` priority; prefetch uses `.utility`.
- **Visualizer timing fix:** `activateTimeline()` now starts paused (`isPaused = true`). Visualizer only begins interpolating when `resumeUpdates()` is called after `timeControlStatus == .playing` is confirmed. Gapless transitions call `resumeUpdates()` immediately since audio is already playing.
- **Selective player item cache:** Queue start paths use `evictPlayerItemsNotIn()` instead of `clearPlayerItemCache()`, preserving prefetched items that overlap with the new queue.
- **Scroll performance:** Artwork URL cache TTL increased from 5s to 60s. `TrackAvailabilityResolver.bumpGeneration()` debounced at 100ms to coalesce rapid launch-time bumps.
- **Gapless over AirPlay:** Wall-clock boundary timer suppressed when AVQueuePlayer has items queued, preventing premature `handleQueueExhausted()` that caused gaps over AirPlay.
- **Memory alignment fixes:** FFT analysis uses `withUnsafeBufferPointer` on `[Float]` for aligned DSPComplex reinterpretation. Sidecar loading uses `loadUnaligned()` for `Data` buffer reads.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - fire-and-forget loadTimeline, visualizer resume on .playing, selective cache eviction, wall-clock boundary suppression
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - activateTimeline starts paused, priority-aware analysis, alignment fixes
- `Packages/EnsembleCore/Sources/Services/ArtworkLoader.swift` - increased URL cache TTL
- `Packages/EnsembleCore/Sources/Services/TrackAvailabilityResolver.swift` - debounced bumpGeneration

### Pre-Computed Frequency Visualizer (Mar 2026)
Replaced the MTAudioProcessingTap-based real-time audio visualizer with a pre-computed frequency analysis system, fully decoupling the visualizer from the audio pipeline:

- **Accelerate FFT analysis:** Audio files are analyzed on disk using a 1024-pt FFT with 24 log-spaced frequency bands (60Hz-16kHz). Results stored as `FrequencyTimeline` (time-indexed snapshots at 30fps, ~216KB per 5-min song).
- **Display timer:** A 30Hz timer reads `player.currentTime()` and looks up the matching frame from the active timeline -- no audio tap or mix required.
- **Binary sidecar files:** `.freq` files are generated alongside offline downloads for instant visualizer load on cached tracks. `DownloadManager` cleans up sidecars on download removal.
- **Removed:** `MTAudioProcessingTap`, `audioMix`, fade timers, and simulated frequency bands are all gone from `PlaybackService`.
- **Scrubber sync:** Scrubber drag in `ControlsCard` calls `NowPlayingViewModel.updateVisualizerPosition()` so the visualizer tracks seek position in real time.
- **Extension probing:** `FrequencyAnalysisService` probes unrecognized file extensions to determine if they are readable audio before attempting analysis.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - FrequencyTimeline model, FrequencyAnalysisService, FrequencyTimelinePersistence
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - removed tap/fade/simulated-bands; wires loadTimeline/activateTimeline/evictTimeline/updatePlaybackPosition
- `Packages/EnsembleUI/Sources/Components/NowPlaying/ControlsCard.swift` - scrubber drag syncs visualizer
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - updateVisualizerPosition method
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - swapped AudioAnalyzer for FrequencyAnalysisService
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - .freq sidecar cleanup
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - sidecar generation after download

### WebSocket Enhancements + Download Spinners (Mar 2026)
Six improvements building on the WebSocket infrastructure:

- **Playlist auto-update:** `PlaylistViewModel` now subscribes to `syncCoordinator.$sourceStatuses` (1s debounce) as defensive fallback for WebSocket-triggered playlist changes.
- **Download spinners:** `OfflineDownloadService` publishes `activeDownloadRatingKeys: Set<String>`. `TrackRow` and `MediaTrackList` show a spinner for actively downloading tracks, replaced by download icon on completion.
- **Scan progress indicator:** `PlexWebSocketCoordinator` tracks `serverScanProgress: [String: Int]` from activity events. `MusicSourceAccountDetailView` shows a linear progress bar per server during library scans.
- **Smart playlist auto-refresh:** `SyncCoordinator.rateTrack()` triggers a debounced (5s) playlist sync after rating changes so smart playlists reflect new state.
- **Artwork cache invalidation:** WebSocket album/artist metadata updates (type=9/8, state=5) fire `onArtworkInvalidation`. `ArtworkLoader.invalidateArtwork()` clears URL cache + local file + Nuke cache and posts notification. `ArtworkView` re-triggers load on invalidation.
- **Incremental sync timestamp buffer:** 5s subtracted from `since` timestamp to avoid missing near-boundary changes.

**Key files:**
- `Packages/EnsembleCore/Sources/ViewModels/PlaylistViewModel.swift` - sourceStatuses observer
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - activeDownloadRatingKeys
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - download spinner
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - UIKit download spinner
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - serverScanProgress, onArtworkInvalidation
- `Packages/EnsembleCore/Sources/ViewModels/MusicSourceAccountDetailViewModel.swift` - scanProgressByServer
- `Packages/EnsembleUI/Sources/Screens/MusicSourceAccountDetailView.swift` - scan progress bar UI
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - post-rating playlist sync, 5s timestamp buffer
- `Packages/EnsembleCore/Sources/Services/ArtworkLoader.swift` - invalidateArtwork, artworkDidInvalidate notification
- `Packages/EnsemblePersistence/Sources/Downloads/ArtworkDownloadManager.swift` - deleteArtwork
- `Packages/EnsembleUI/Sources/Components/ArtworkView.swift` - invalidation listener
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - onArtworkInvalidation wiring

### Network Resilience & Offline Architecture v1 (Mar 2026)
Five-phase overhaul of network resilience, push-based server updates, reactive track availability, queue resilience, and unified error handling:

- **Phase 1 -- ServerConnectionRegistry:** New actor (`ServerConnectionRegistry`) is the single source of truth for per-server endpoints. `PlexAPIClient` reports failover results back to the registry; `ServerHealthChecker` writes probe results; `SyncCoordinator` subscribes to registry changes; `AccountManager` owns the registry; `DependencyContainer` wires it.
- **Phase 2 -- PlexWebSocketManager + PlexWebSocketCoordinator:** `PlexWebSocketManager` (actor) manages one `URLSessionWebSocketTask` per server with exponential backoff reconnect. `PlexWebSocketCoordinator` (@MainActor) routes WS events to sync and health systems. `SyncCoordinator` gains adjustable timer policy and incremental section-level sync. `AppDelegate` starts/stops WebSocket connections on foreground/background.
- **Phase 3 -- TrackAvailabilityResolver:** New @MainActor ObservableObject publishes per-track availability by combining per-server connection state with per-track download state. `TrackAvailability` enum (`.available`, `.availableDownloadedOnly`, `.unavailableServerOffline`, `.unavailableNetworkOffline`) replaces inline offline checks in `TrackRow`, `CompactSearchRows`, and `MediaTrackList`.
- **Phase 4 -- Queue Resilience:** `PlaybackService` circuit breaker scans for downloaded alternatives; `retryCurrentTrack()` falls back to local downloads; cache eviction for newly downloaded queue items; auto-resume on health check completion.
- **Phase 5 -- Mutation Queue Hardening:** `PlexErrorClassification` provides unified error taxonomy (transport vs. semantic). `PlexAPIClient` and `MutationCoordinator` use it for failover/retry decisions. `MutationCoordinator` queues failed scrobbles as `CDPendingMutation` (`.scrobble` type). `PlaybackService` routes scrobbles through the mutation coordinator via `SyncCoordinator.scrobbleTrackThrowing()`. `PendingMutationsViewModel` and `PendingMutationsView` display queued scrobbles.

**Key files:**
- `Packages/EnsembleAPI/Sources/Client/ServerConnectionRegistry.swift` - actor, per-server endpoint truth
- `Packages/EnsembleAPI/Sources/Client/PlexWebSocketManager.swift` - actor, per-server WebSocket with backoff
- `Packages/EnsembleAPI/Sources/Client/PlexErrorClassification.swift` - unified error taxonomy
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - failover reports to registry, uses error classification
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - routes WS events to sync/health
- `Packages/EnsembleCore/Sources/Services/TrackAvailabilityResolver.swift` - reactive per-track availability
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - registry subscription, adjustable timers, scrobbleTrackThrowing
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - queue resilience, download fallback, scrobble routing
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires registry, WS coordinator, availability resolver
- `Packages/EnsemblePersistence/Sources/CoreData/ManagedObjects.swift` - CDPendingMutation .scrobble type
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Components/CompactSearchRows.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Screens/PendingMutationsView.swift` - shows queued scrobbles
- `Ensemble/App/AppDelegate.swift` - WS start/stop on foreground/background

### Offline Download Manager v1 (Settings-Managed, Target-Based) (Mar 2026)
Offline downloads now use target-based management with source-safe reconciliation and optional iOS 26 continued background processing acceleration:

- **Inline libraries section:** Downloads tab shows a "Libraries" section with each sync-enabled library as a rich row (toggle, download stats, drill-in navigation), replacing the previous "Bulk Downloads" -> `Servers` drill-in.
- **Library detail view:** tapping a library row shows all downloaded tracks for that library regardless of which target type (library, album, playlist, artist) triggered the download.
- **Target types:** albums, artists, and playlists can be toggled via context/detail menus (`Download` / `Remove Download`).
- **Reference-counted memberships:** shared tracks are retained until all referencing targets are removed; orphaned downloads are removed automatically.
- **Source-safe identity:** track downloads and target memberships are keyed by `ratingKey + sourceCompositeKey` to avoid cross-server/library collisions.
- **Quality-aware downloads:** download queue uses Audio Quality setting (`downloadQuality`) and universal streaming URL generation for quality-aware fetches.
- **Network policy:** queue defaults to Wi-Fi/wired only; optional "Allow Downloading on Cellular" toggle in Manage Downloads settings enables cellular downloads.
- **Sync-triggered reconciliation:** library/playlist targets re-evaluate after source sync updates and playlist refresh completion events.
- **Optional iOS 26 BG accelerator:** `BGContinuedProcessingTask` path is best-effort for user-initiated bulk work; persistent queue remains source of truth and fallback.
- **Offline UX hardening:** when offline, non-downloaded tracks are dimmed and taps are blocked with toast feedback.

**Key files:**
- `Packages/EnsemblePersistence/Sources/CoreData/Ensemble.xcdatamodeld/Ensemble.xcdatamodel/contents`
- `Packages/EnsemblePersistence/Sources/CoreData/ManagedObjects.swift`
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift`
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift`
- `Packages/EnsemblePersistence/Sources/Repositories/LibraryRepository.swift`
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift`
- `Packages/EnsembleCore/Sources/Services/OfflineBackgroundExecutionCoordinator.swift`
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift`
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift`
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift`
- `Packages/EnsembleCore/Sources/ViewModels/DownloadsViewModel.swift`
- `Packages/EnsembleCore/Sources/ViewModels/LibraryDownloadDetailViewModel.swift`
- `Packages/EnsembleUI/Sources/Screens/DownloadsView.swift`
- `Packages/EnsembleUI/Sources/Screens/DownloadManagerSettingsView.swift`
- `Packages/EnsembleUI/Sources/Screens/LibraryDownloadDetailView.swift`
- `Packages/EnsembleUI/Sources/Components/TrackDownloadRowView.swift`
- `Ensemble/App/AppDelegate.swift`
- `Ensemble/Info.plist`

### Universal Transcode Endpoint + Quality Settings (Mar 2026)
Streaming now uses Plex's universal transcode endpoint with quality settings support, fixing playback for non-Plex Pass accounts:

- **Universal endpoint:** All streaming routes through `/music/:/transcode/universal/start.mp3` with `protocol=http` (progressive download). Falls back to direct file URLs if the universal endpoint fails (URL construction error).
- **Decision endpoint required:** The `/music/:/transcode/universal/decision` endpoint MUST be called before `/start.mp3` to warm up the transcode session. Without this, PMS returns 400. The `getUniversalStreamURL()` method handles this automatically.
- **Quality-aware routing:** "Original" quality uses `directPlay=0&directStream=1` (PMS direct-streams original codec through its pipeline); reduced qualities add `musicBitrate`/`audioBitrate` params and PMS transcodes to MP3 at the target bitrate.
- **Non-Plex Pass fix:** Direct file URLs were cut off at ~655KB for non-Plex Pass users; universal endpoint streams through PMS's pipeline and works for all account types.
- **Quality mapping:** original=direct-stream, high=320kbps MP3, medium=192kbps MP3, low=128kbps MP3.
- **Client profile:** `transcodeClientProfileExtra()` declares both transcode output codecs (AAC, MP3) and direct-play codecs (AAC, MP3, FLAC, ALAC) so PMS knows what the client can handle natively.
- **Settings integration:** `streamingQuality` AppStorage value (from Settings -> Audio Quality) is respected during playback via `PlexMusicSourceSyncProvider.getStreamURL()`.

**Key files:**
- `PlexAPIClient.swift` - `StreamingQuality` enum, `getUniversalStreamURL()` method, `callTranscodeDecision()`, `transcodeClientProfileExtra()`
- `PlexMusicSourceSyncProvider.swift` - quality-aware routing through universal endpoint with direct-stream fallback
- `SyncCoordinator.swift` - quality parameter routing to provider
- `PlaybackService.swift` - reads `streamingQuality` from UserDefaults and passes to stream URL generation

### Siri Media Intents v1.1 (In-App-First) (Feb 2026)
Siri playback now supports **track, album, artist, and playlist** phrases through SiriKit Media Intents with in-app execution:

- **Thin extension:** `INPlayMediaIntentHandling` resolves/ranks candidates and uses Siri disambiguation when confidence is low.
- **In-app execution:** extension returns `handleInApp`; the app decodes a versioned payload and executes playback via a dedicated coordinator.
- **Indexing path:** shared App Group JSON index includes track/album/artist/playlist candidates with ranking metadata.
- **Precision search:** repositories now expose scoped title/name search methods for deterministic Siri matching.
- **Routing + outcomes:** deterministic ranking (exact > prefix > contains), tie-breakers, and Siri-friendly failure mapping.
- **HomePod workaround:** For HomePod requests, iOS never calls `handle()` after `confirm()` returns `.ready`. As a workaround, `confirm()` writes the payload to App Group and posts a Darwin notification; the app listens for this notification and executes playback directly, bypassing the broken `handle()` flow.

**Key files:**
- `EnsembleSiriIntentsExtension/IntentHandler.swift` + `PlayMediaIntentHandler.swift` + `Info.plist` - Siri media extension entry and intent handling
- `SiriIntentPayload.swift` + `SiriMediaIndex.swift` - versioned handoff payload + compact index models
- `SiriMediaIndexStore.swift` - App Group index persistence/rebuild notification hooks
- `SiriPlaybackCoordinator.swift` - in-app execution for track/album/artist/playlist intents
- `AppDelegate.swift` + `DependencyContainer.swift` - lifecycle routing + DI wiring + Darwin notification listener
- `LibraryRepository.swift` + `PlaylistRepository.swift` - precision search methods used by Siri matching

### Siri App Intents Fallback for Album/Playlist (Feb 2026)
Siri playback now also includes an App Intents fallback path for album/playlist phrases when SiriKit media-domain routing does not invoke Ensemble:

- **App shortcut phrases:** explicit album/playlist phrases are registered via `AppShortcutsProvider`.
- **Dynamic entity resolution:** shortcut entity queries read album/playlist candidates from the shared Siri media index (App Group JSON derived from cached library data).
- **In-app execution reuse:** fallback intents execute playback through `SiriPlaybackCoordinator` using the same payload contract as SiriKit.
- **Vocabulary refresh:** app launch now refreshes App Shortcuts parameter metadata after index availability checks so Siri phrase resolution stays current.

**Key files:**
- `Ensemble/App/EnsembleAppShortcuts.swift` - App Intents entities/queries/intents and shortcut phrases
- `Ensemble/App/AppDelegate.swift` - startup App Shortcuts parameter refresh

### Account-Centric Source Management + Sign-In Redesign (Feb 2026)
The Plex source flow now centers on accounts (not individual server rows), and sync controls live in account detail:

- **Add-account flow:** PIN can be copied on tap; discovery returns account identity plus all available servers/libraries in one checklist.
- **Music Sources settings:** list now shows account-level sources (`Plex` + account identifier subtitle), and navigation opens account detail.
- **Account detail:** shows server-grouped libraries (checked + unchecked), per-library sync/connection status, and a single "sync enabled libraries" action.
- **Reconciliation behavior:** newly discovered libraries default unchecked; removed libraries are auto-disabled and purged.
- **Purge semantics:** unchecking a library purges only that library's cache; if the last enabled library for a server is removed/disabled, server-level playlists are purged.
- **Navigation cleanup:** legacy standalone Sync Panel routes were removed from tab/more/sidebar flows.
- **Visibility groundwork:** `LibraryVisibilityProfile` + `LibraryVisibilityStore` are in place, and `LibraryViewModel`/`SearchViewModel`/`HomeViewModel` now support source-level visibility filtering (without changing sync enablement).

**Key files:**
- `AddPlexAccountViewModel.swift` + `AddPlexAccountView.swift` - account discovery, grouped selection, PIN copy UX
- `SettingsView.swift` + `MusicSourceAccountDetailView.swift` + `MusicSourceAccountDetailViewModel.swift` - account-level source list and detail flow
- `AccountManager.swift` + `SyncCoordinator.swift` + `PlaylistRepository.swift` - reconciliation, selective purge, server playlist cleanup
- `MainTabView.swift` + `MoreView.swift` - Sync Panel entry-point removal
- `LibraryVisibilityProfile.swift` + `LibraryVisibilityStore.swift` - visibility profile foundation
- `LibraryViewModel.swift` + `SearchViewModel.swift` + `HomeViewModel.swift` - visibility filter seams

### Sync System Overhaul (Feb 2026)
The sync system now supports **incremental sync** using Plex API timestamp filters (`addedAt>=`, `updatedAt>=`):

- **Pull-to-refresh:** Library views perform incremental sync (fast), HomeView refreshes hubs only
- **Startup sync:** Full sync if >24h old, incremental if >1h old, skip if fresh (<1h)
- **Background refresh (iOS):** `BGAppRefreshTask` refreshes hubs every ~15min (system-controlled)
- **Routine updates:** Incremental library sync every 1h, hubs every 10min while app is active
- **Offline-first:** All syncs respect offline state, fall back to CoreData cache

**Key files:**
- `SyncCoordinator.swift` - `syncAllIncremental()`, `performStartupSync()`, periodic timers
- `PlexMusicSourceSyncProvider.swift` - `syncLibraryIncremental(since:)`
- `PlexAPIClient.swift` - Filtered fetch methods (e.g., `getArtists(sectionKey:addedAfter:)`)
- `BackgroundSyncScheduler.swift` - iOS background refresh scheduling

### Playlist Mutations Rollout (Feb 2026)
Playlist management now supports server-backed mutations with local cache refresh:

- **Now Playing:** add current track to playlist, save current queue snapshot
- **Playlist Detail:** rename and edit playlist track ordering/removals
- **Album Detail:** add full filtered album track list to playlist from the pin menu
- **Consistency:** all successful playlist mutations trigger server refresh + CoreData update
- **Smart playlists:** treated as read-only for mutation operations

**Key files:**
- `PlexAPIClient.swift` - Create/rename/add/remove/move playlist mutation endpoints
- `SyncCoordinator.swift` - Playlist mutation orchestration + post-mutation playlist refresh
- `NowPlayingViewModel.swift` - Queue snapshot logic and shared playlist action methods
- `PlaylistViewModel.swift` - Playlist detail rename/edit mutation hooks
- `PlaylistActionSheets.swift` - Shared add/create playlist UI sheets

### Gesture Actions v1 (Feb 2026)
Library and search surfaces now support configurable swipe actions for track rows plus long-press menus for album/artist/playlist items:

- **Track swipe actions (iOS/iPadOS):** shared 2 leading + 2 trailing layout with customizable slot assignment
- **Action catalog:** `Play Next`, `Play Last`, `Add to Playlist...`, favorite toggle (Loved on/off)
- **Full swipe:** executes slot 1 on each edge
- **Long-press menus:** album/artist/playlist menus on cards/rows; playlist menus respect smart-playlist mutation guards
- **Settings:** Playback section includes `Track Swipe Actions` customization with reset to defaults

**Key files:**
- `SettingsManager.swift` - `TrackSwipeAction`/`TrackSwipeLayout` model + persisted/sanitized slot configuration
- `TrackSwipeContainer.swift` - Shared SwiftUI swipe layer for track rows
- `MediaTrackList.swift` - UIKit leading/trailing swipe actions aligned to shared layout
- `TrackSwipeActionsSettingsView.swift` - Slot customization UI in Settings
- `NowPlayingViewModel.swift` - Per-track favorite mutation methods used by swipe/context actions

### Network Health + Hub Refresh Hardening (Feb 2026)
Network transition handling now coalesces health checks, repairs stale endpoint usage after interface handoff, and avoids Home feed jumps while users scroll:

- **Network monitor lifecycle safety:** `NetworkMonitor` recreates `NWPathMonitor` instances on restart so background/foreground cycles continue publishing connectivity changes.
- **Transition-aware health orchestration:** `SyncCoordinator` classifies reconnect/interface-switch transitions, applies 30s cooldown + 60s foreground staleness guards, and coalesces concurrent refreshes into a single run.
- **Scoped health checks:** only servers with enabled libraries are checked during sync health refresh runs.
- **Probe fan-out reduction:** `ConnectionFailoverManager` tries a recent healthy URL first, then falls back to parallel probing if needed.
- **Home scrolling stability:** `HomeViewModel` defers auto-refresh and hub snapshot application while users are interacting, then applies once idle.
- **Lifecycle routing:** foreground health refresh now flows through `SyncCoordinator.handleAppWillEnterForeground()` so app lifecycle and monitor transitions share one policy path.

**Key files:**
- `NetworkMonitor.swift` - restart-safe monitor lifecycle and debounce testing seams
- `SyncCoordinator.swift` - transition classification, cooldown/staleness policy, coalesced refresh path
- `ServerHealthChecker.swift` - per-server TTL cache, forced refresh support, cancellation fixes
- `ConnectionFailoverManager.swift` - preferred recent connection fast-path
- `HomeViewModel.swift` - deferred auto-refresh + idle apply policy
- `HomeView.swift` - visibility and scroll interaction callbacks

### Plex Connectivity Spec Parity Cutover (Feb 2026)
Plex endpoint discovery/routing/auth now follows a stricter spec-parity path to avoid stale routing and generic "server unavailable" failures:

- **Discovery parity:** resource discovery requests now include IPv6 candidates and shared Plex headers.
- **Policy-driven endpoint ordering:** connection selection now prefers local/direct endpoints before remote and relay, with secure-first behavior and configurable insecure fallback policy.
- **Failover discipline:** endpoint failover now triggers on transport/connectivity failures only (not arbitrary HTTP semantic errors).
- **Structured refresh outcomes:** server connection refresh returns typed outcomes instead of swallowing failures, and call sites now react explicitly.
- **Failure taxonomy:** server checks classify failures (local-only reachable, remote access unavailable, relay unavailable, TLS policy blocked, offline) for clearer user-facing messages.
- **Auth lifecycle cutover:** account token metadata stores JWT `iat`/`exp`; a migration version bump forces re-login and expired tokens are rejected on load/foreground.

**Key files:**
- `PlexAPIClient.swift` - resources request contract, transport-only failover policy, structured refresh
- `PlexConnectionPolicy.swift` - endpoint descriptors, selection policy, connection refresh result types
- `ConnectionFailoverManager.swift` - policy-aware probing and probe failure classification
- `PlexAuthService.swift` + `PlexAuthTokenMetadata.swift` - auth token metadata parsing and lifecycle helpers
- `AccountManager.swift` - auth migration cutover and expiry enforcement
- `ServerHealthChecker.swift` - classified health failure reasons

### Adaptive Playback Stability (Feb 2026)
Playback buffering now uses an internal adaptive profile tuned by network conditions and recent stall history to reduce skip/seek buffering loops:

- **Adaptive profile defaults:** Wi-Fi/wired uses low-latency buffering with deeper prefetch (`prefetchDepth=2`), while cellular/other uses anti-stall waits with deeper forward buffering (`prefetchDepth=1`).
- **Stall escalation:** repeated stalls in a short window temporarily switch playback into a conservative recovery profile.
- **Windowed prefetch:** upcoming queue prefetch is depth-based instead of single-item, and queue rebuild paths refill using the active profile depth.
- **Seek stability:** pending seek progress gate now stays active longer while buffering to prevent scrubber/audio drift during unbuffered seeks.
- **Recovery throttling:** stall retries use profile-based timeout and a retry cooldown to avoid rapid reload thrash on weak links.

**Key files:**
- `PlaybackService.swift` - adaptive buffering profile, stall escalation/cooldown logic, windowed prefetch, seek-progress gating
- `PlaybackServiceTests.swift` - adaptive profile/escalation and seek-gate helper coverage
