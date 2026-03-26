---
name: known-issues
description: "Ensemble known issues and technical debt: critical bugs, feature gaps, infrastructure debt. Use when investigating bugs, planning work, or understanding limitations."
---

# Ensemble Known Issues & Technical Debt

## Critical

### watchOS Authentication Missing
- **Location:** `EnsembleWatch/Views/WatchRootView.swift:5`
- **Issue:** References `DependencyContainer.shared.makeAuthViewModel()` which does not exist
- **Impact:** watchOS app won't compile
- **Status (February 21, 2026):** Deferred by scope decision; not being fixed in current remediation pass
- **Root Cause:** iOS uses `AddPlexAccountViewModel`, watchOS was designed with different auth flow
- **Fix Options:**
  1. Create `AuthViewModel` in EnsembleCore and add factory method to DependencyContainer
  2. Refactor watchOS to use existing `AddPlexAccountViewModel`
  3. Create watchOS-specific auth flow that matches iOS patterns

## Resolved Issues

### Download Worker Context Invalidation (Mar 26, 2026)
- **Location:** `OfflineDownloadService.swift` (`process(download:)`, `completeViaDownloadQueue`)
- **Issue:** Download worker held CDTrack/CDDownload managed object references from the viewContext throughout async downloads (several seconds). When `SyncCoordinator` ran `refreshViewContext()` → `viewContext.reset()` mid-download, property access returned empty/default values (`track.ratingKey` → `""`, `track.sourceCompositeKey` → `nil`). Additionally, CDTrack→CDDownload cascade delete (deletionRule="Cascade") removed the CDDownload when sync's `removeOrphanedTracks()` deleted the CDTrack. Symptoms: files saved as `_unknown_medium.mp3`, `completeDownload(objectID)` threw "object not found in store", downloads silently failed.
- **Fix:** `process(download:)` now captures ALL CDTrack/CDDownload properties into a value-type `DownloadContext` struct BEFORE async work begins. All downstream methods (`completeViaDownloadQueue`, `localFileURL`, `cacheArtworkForDownloadedTrack`) use captured values. `completeDownloadWithRecovery()` recreates the CDDownload record if the primary objectID-based completion fails due to cascade delete.
- **Key files:** `OfflineDownloadService.swift`

### Download Target Shows '0 Tracks' After Data Loss (Mar 25, 2026)
- **Location:** `OfflineDownloadService.swift`, `DownloadsViewModel.swift`
- **Issue:** When CDOfflineDownloadMembership records were lost (iOS update, corruption), `refreshTargetProgress()` found 0 references → aggressively wrote totalTrackCount=0 → UI showed "0 tracks". Recovery required waiting ~15min for sync-triggered reconciliation.
- **Fix:** Three-part self-healing: preserve stale counts for orphaned targets, immediate reconciliation via `reconcileOrphanedTargets()`, startup + pull-to-refresh file existence checks via `refreshStateWithHealing()`.

### Queue Skipping Cascade (Mar 18, 2026)
- **Location:** `PlaybackService.swift`
- **Issue:** Rapid previous()/next() taps caused a cascade: AVPlayer XPC errors (`err=-17221`) → old AVPlayerItem fails asynchronously → `handleQueueExhausted()` fires phantom auto-advance → queue never recovers, even starting a new queue fails.
- **Root causes:** (1) `handleQueueExhausted()` didn't guard for `isSkipTransitionInProgress` or `.loading` state. (2) `previous()` didn't cancel `skipTransitionTask`, piling up concurrent loads. (3) `consecutivePlaybackFailures` was reset on skip entry, disabling the circuit breaker.
- **Fix:** Guards in `handleQueueExhausted()`, `previous()` now manages `skipTransitionTask` like `next()`, failure counter only resets on confirmed audio. Added `recreatePlayer()` for corrupted AVPlayer recovery and a 15s stuck-loading watchdog.

### iOS 26 `.searchable()` Crash in Sheets (Mar 18, 2026)
- **Location:** `PlaylistActionSheets.swift`
- **Issue:** `NavigationView` + `.searchable()` on iOS 26 triggers 997+ "Observation tracking feedback loop detected!" errors from `ScrollPocketCollectorModel`, freezing/crashing the app.
- **Fix:** Use `NavigationStack` on iOS 16+ for sheet navigation containers. Tab-level views already use `NavigationStack` via `MainTabView.tabRootView`.

## Feature Completeness Gaps

### Intermittent 404 on /library/streams/ for Lyrics
- **Location:** `LyricsService.swift`, `PlexAPIClient.getLyricsContent(streamKey:)`
- **Issue:** Some tracks report a valid `lyricsStream` (streamType=4) in the `/library/metadata/{ratingKey}` response, but the subsequent `GET /library/streams/{streamKey}` call returns HTTP 404. This appears to be a Plex server bug where the stream record exists in metadata but the stream content is not actually stored. More frequent on iOS 15.
- **Impact:** Lyrics show "No Lyrics" for affected tracks despite the track appearing to have a lyrics attachment.
- **Current behavior (Mar 18, 2026):** `PlexAPIClient.getLyricsContent` retries 3 times with increasing delays (2s, 3s). If all fail, `LyricsService` schedules a background retry after 10s. If the background retry succeeds and the same track is still playing (lyrics still showing `.notAvailable`), the UI updates automatically. `.notAvailable` results are NOT cached so subsequent playback can retry.
- **Workaround:** None needed for most cases; the retry logic handles transient PMS cache misses. Persistent 404s are server-side.

### BG Continued Processing Is Best-Effort (iOS 26+)
- `OfflineBackgroundExecutionCoordinator` submits `BGContinuedProcessingTaskRequest` for user-initiated bulk offline work.
- The OS may reject queued requests, cancel queued work if the app is removed from switcher, or expire active tasks.
- **Current behavior:** `OfflineDownloadService` treats BG execution as an accelerator only; persistent queue state remains source of truth and resumes in normal foreground/background opportunities.

### Offline Transcode Availability Varies by Plex Server
- Some Plex server configurations reject all `/music|audio/:/transcode/universal/*` download requests with HTTP `400` even when direct `/library/parts/...` access succeeds.
- **Current behavior:** `OfflineDownloadService` treats this as a server capability limitation, marks the server as `offline-transcode-unsupported`, and skips repeated transcode attempts by downloading original quality directly.
- **User impact:** Download quality settings (`high/medium/low`) may not be attainable for affected servers; downloaded files remain original quality.

### WebSocket Library Notifications Require Plex Pass
- `PlexWebSocketManager` maintains one `URLSessionWebSocketTask` per server with exponential backoff reconnect.
- **Plex Pass limitation:** Library change notifications (`timeline`, `activity`) are only delivered to server owner/admin accounts with Plex Pass. Non-Plex Pass shared users only receive session-level notifications (e.g., `playing`). The WebSocket still provides implicit health signals for all account types.
- Some Plex server configurations (especially behind strict NATs or reverse proxies) may not support WebSocket connections at all.
- **Current behavior:** `PlexWebSocketCoordinator` treats WS events as acceleration hints; polling-based sync timers remain active as fallback for all account types. If a WebSocket connection fails repeatedly, a circuit breaker activates after 5 failures and switches to 5-minute retry intervals (vs normal 5s→60s backoff). The circuit breaker resets on successful connection, deliberate start(), or endpoint URL change.

### WebSocket Server 1001 (Going Away) Immediate Disconnect
- **Location:** `PlexWebSocketManager.swift`
- **Issue:** Some Plex servers (observed on specific PMS configurations) close the WebSocket connection with code 1001 immediately after the client connects, before sending any messages. This causes a reconnect loop.
- **Impact:** Without the circuit breaker, the connection would retry every 60s forever, burning CPU and network. With the circuit breaker, retries drop to every 5 minutes after the first 5 failures.
- **Root cause:** Unknown server-side issue. May be related to PMS configuration, NAT, or reverse proxy behavior. The WebSocket URL and auth token are confirmed valid.

### Artwork Pre-Caching Sync-Path Only
- `ArtworkLoader.predownloadArtwork()` is now called during sync for albums, artists, and playlists
- However, artwork is only cached for items that pass through a sync path; browsing an uncached item still requires network

### Library Visibility Profile Selector UI Not Shipped Yet
- `LibraryVisibilityProfile` + `LibraryVisibilityStore` groundwork exists in `EnsembleCore`
- `LibraryViewModel`, `SearchViewModel`, and `HomeViewModel` already support source-key visibility filtering seams
- **Missing:** user-facing selector/editor UI to switch and manage profiles in Settings
- **Current behavior:** filtering is foundation-only; sync-enable state remains unchanged

## Resolved

### Playback Failure Loop with Non-Plex-Pass / Universal Transcode Failures
- **Resolved (March 7, 2026)**
- **Issue:** When universal transcode endpoint failed (e.g. non-Plex-Pass users), the app entered an infinite loop: track fails → retry/advance → next track fails → repeat. Users couldn't pause or stop because tracks failed within milliseconds.
- **Root causes:**
  - Circuit breaker reset on item insertion instead of confirmed playback, so the counter went 0→1→reset→0→1 and never reached threshold
  - `handleQueueExhausted` and `handleTLSPlaybackFailure` raced concurrently with no mutual exclusion
  - "resource unavailable" (transcode pipeline error) was misclassified as TLS error, triggering wasteful connection refresh cycles
- **Fix:** Circuit breaker resets only when `timeControlStatus == .playing`. TLS handler sets `isHandlingTLSFailure` flag; queue exhaustion handler waits for it. "resource unavailable" classified as transcode pipeline error with direct circuit breaker increment. Play button gated on track availability after queue restoration.
- **Key files:** `PlaybackService.swift`, `NowPlayingViewModel.swift`, `ControlsCard.swift`, `MiniPlayer.swift`

### Server Offline: Tracks Not Dimmed and Queue Played Unavailable Tracks
- **Resolved (March 5, 2026)**
- **Issue:** When a Plex server went offline (but device stayed on Wi-Fi), tracks showed as available, playback queue tried every unavailable track, artwork didn't fall back to cache, and health checks only ran on network transitions (not server failures).
- **Root causes:**
  - `NWPathMonitor` doesn't detect server-level outages (network path stays "satisfied")
  - `serverStates` started empty at launch; `TrackAvailabilityResolver` treated missing entries as "available"
  - `performStartupSync()` didn't run health checks
  - `resolvePlayableQueue` only checked device-level offline, not per-server health
  - `next()`/`handleQueueExhausted` blindly advanced to next queue index
  - `@Environment` (EnvironmentKey) doesn't create SwiftUI observation bindings for nested ObservableObjects
- **Fix:** Startup health checks populate `serverStates` before sync. AVPlayer KVO error path classifies server-unreachable errors and triggers targeted health checks. `resolvePlayableQueue`, `next()`, `handleQueueExhausted`, and `playQueueIndex` all filter by per-server availability. `ArtworkLoader` falls back to local cache when server is offline. Track row views use `@ObservedObject` on `DependencyContainer.shared.trackAvailabilityResolver` for reactive dimming.
- **Key files:** `SyncCoordinator.swift`, `PlaybackService.swift`, `ArtworkLoader.swift`, `TrackRow.swift`, `CompactSearchRows.swift`, `MediaTrackList.swift`

### HomePod Siri Media Intents handle() Never Called
- **Resolved (February 26, 2026)**
- **Issue:** For HomePod requests, iOS's SiriKit never calls `handle()` after `confirm()` returns `.ready`. This appears to be an iOS limitation affecting third-party media apps.
- **Workaround:** Extension writes playback payload to App Group and posts a Darwin notification; app listens for the notification and executes playback directly, bypassing the broken `handle()` flow.
- **Key files:** `PlayMediaIntentHandler.swift` (confirm + Darwin post), `AppDelegate.swift` (Darwin listener)

### Downloaded Tracks Unplayable After App Reinstall
- **Resolved (March 5, 2026)**
- **Issue:** iOS changes the app sandbox UUID on every reinstall/rebuild. Absolute paths stored in `CDDownload.filePath` and `CDTrack.localFilePath` became invalid, causing "cannot play non-downloaded tracks" errors even though files still existed on disk.
- **Fix:** Store only filenames in CoreData (not absolute paths). Resolve filename → absolute path at the model mapping boundary (`Track(from: CDTrack)`, `Download(from: CDDownload)`). Legacy absolute paths are migrated to filenames on first `fetchDownloads()`.
- **Key files:** `DownloadManager.swift` (filename storage, `absolutePath(forFilename:)`, `extractFilename(from:)`), `ModelMappers.swift` (resolution at mapping boundary), `OfflineDownloadService.swift` (stores `.lastPathComponent`)

### Instrumental Mode Known Limitations
- **Toggle gap:** ~100-300ms audio gap when switching between AVQueuePlayer and AVAudioEngine (acceptable tradeoff)
- **Progressive transcode deferral:** If the transcode is still downloading when instrumental mode is toggled ON, playback continues via AVQueuePlayer until the download completes, then switches
- **Direct remote streams:** If no local file or stream loader exists (rare edge case), instrumental mode defers until a file becomes available
- **No slider:** Vocal attenuation is binary (full removal). No partial slider/mix control.
- **iOS 16+ only:** AUSoundIsolation requires iOS 16.0+ / macOS 13.0+ and A13+ chip. Button is hidden on unsupported devices.

### Infrastructure
- **Legacy CocoaPods Cleanup** -- Removed unused `ios/Pods/` directory

### Documentation
- **Documentation Fully Updated** -- CLAUDE.md and README.md reflect all implemented features

### Persistence SwiftPM Test Crash
- **Resolved (February 21, 2026)**
- `CoreDataStack` now loads bundled models with resilient `.momd`/`.mom` fallback candidates.
- `CoreDataStack.inMemory()` now uses a true in-memory store (`/dev/null`).
- Persistence tests use in-memory stack instead of `.shared`.
- SwiftPM model compilation workflow is documented and scripted (`scripts/compile_coredata_model.sh`).

### Network Handoff Endpoint Staleness + Health Check Overactivity
- **Resolved (February 21, 2026)**
- `PlaybackService` now heals upcoming queue items on reconnect/interface-switch transitions.
- `NetworkMonitor` lifecycle is restart-safe across background/foreground transitions.
- `SyncCoordinator` coalesces network-health refreshes and applies cooldown/staleness guards.
- `HomeViewModel` defers hub refresh/apply while users are scrolling to prevent feed jumps.

### Plex Endpoint Policy + Auth Lifecycle Parity
- **Resolved (February 22, 2026)**
- Discovery requests now include IPv6 resource candidates and common Plex headers.
- Endpoint selection now follows local-first, relay-last policy with settings-driven insecure fallback rules.
- Failover now triggers only for transport/connectivity failures, avoiding probe storms on HTTP semantic errors.
- Server health now reports classified failure reasons instead of generic offline.
- Auth cutover now enforces token metadata lifecycle and forced re-login migration.

### Residual Risk: Forced Re-Login After Auth/Account Migrations
- **Status:** Expected behavior
- **Impact:** Existing beta users are signed out once when migration version bumps (auth lifecycle and account-schema cutovers).
- **Mitigation:** Add release-note callout for one-time sign-in requirement.

## Performance Notes

### Incremental Sync ratedAfter Fetch Returns All Rated Tracks
- **Resolved (March 10, 2026)**
- **Fix:** `ratedAfter` fetch is now skipped when the sync timestamp is older than 10 minutes. Within that window (foreground/background cycling), the full rated-tracks fetch runs. Beyond 10 minutes, rating changes are caught by the next full sync.
- **Key files:** `PlexMusicSourceSyncProvider.swift` (lines 155-167)

### Wall-Clock Boundary Timer Limitations
- **Location:** `PlaybackService.swift` (wall-clock boundary section in periodic time observer)
- **Issue:** The wall-clock safety timer estimates track end based on elapsed wall time since last seek. Over AirPlay or with high-latency outputs, actual playback can lag behind wall time. The timer is now suppressed when AVQueuePlayer has items queued (gapless case), but may still fire prematurely for the last track in a queue over high-latency outputs.
- **Impact:** Minor — only affects the last track in a queue over AirPlay/high-latency. Gapless transitions are protected.
- **Mitigation:** Grace period is 1.0s; could be increased for AirPlay sessions if needed.

### Pre-Computed Frequency Visualizer: Brief Delay on First Play
- **Location:** `AudioAnalyzer.swift` (`FrequencyAnalysisService`)
- **Issue:** When a track is played for the first time (no cached `.freq` sidecar), the frequency analysis runs asynchronously on the audio file. The visualizer shows no data until analysis completes (typically <1s for local files, longer for streamed files that must buffer first).
- **Impact:** Minor visual delay; playback itself is unaffected since the visualizer is fully decoupled from the audio pipeline.
- **Mitigation:** Offline downloads generate `.freq` sidecars immediately after download, so cached tracks have instant visualizer data.

### Low Power Mode Awareness
- **Resolved (March 11, 2026)**
- **Feature:** `PowerStateMonitor` (@MainActor ObservableObject) observes iOS Low Power Mode via `NSProcessInfoPowerStateDidChange` and publishes `isLowPowerMode: Bool`.
- **GPU throttling:** Aurora visualizer drops to 1 glow pass at 15fps (from 3 at 30fps) when LPM active. LyricsCard disables progressive blur (returns 0 for all lines).
- **Network throttling:** Downloads are auto-paused on LPM activation and auto-resumed on deactivation via `DependencyContainer` wiring.
- **Key files:** `PowerStateMonitor.swift`, `AuroraVisualizationView.swift`, `LyricsCard.swift`, `DependencyContainer.swift`, `MainTabView.swift`

### Aurora Visualizer Optimized to 30fps + 3 Passes + 4fps Breathing
- **Resolved (March 11, 2026)**
- **Previous:** 60fps `TimelineView(.animation)` with 6 blur passes (144 blur filter applications/frame). Never paused behind Now Playing sheet. Still ran at 30fps during breathing mode (playback paused), causing 25.6% GPU drain.
- **Fix:** Capped at 30fps via `minimumInterval: 1/30`. Reduced to 3 glow passes (blur=18, 12, 8). Pauses when Now Playing sheet covers it (`isPaused` binding). Skips identical frequency band publishes. Display timer uses `MainActor.assumeIsolated` instead of `Task { @MainActor }`. Breathing mode (paused) drops to 4fps — the slow sine waves look smooth at very low rates, saving ~87% GPU vs 30fps.
- **Key files:** `AuroraVisualizationView.swift`, `MainTabView.swift`, `AudioAnalyzer.swift`

### Download Target Shows "0 Tracks" After Data Loss
- **Resolved (March 25, 2026)**
- **Previous:** When CDOfflineDownloadMembership records were lost (e.g., after iOS update or data corruption), `refreshTargetProgress()` found 0 memberships and aggressively wrote `totalTrackCount: 0, completedTrackCount: 0` to the CDOfflineDownloadTarget. The UI showed "0 tracks" even though the target itself survived. Recovery only happened after sync completed and triggered reconciliation (~15 min delay).
- **Fix:** Three-part self-healing: (1) `refreshTargetProgress` now preserves stale total count and sets status to `.pending` when memberships are empty but the target previously had tracks, so UI shows "37 tracks - Queued" instead of "0 tracks". (2) `refreshAllTargetProgresses` calls `reconcileOrphanedTargets()` which immediately rebuilds memberships from existing library data. (3) Startup and pull-to-refresh both run download metadata self-healing (`fetchDownloads()` file-existence check) before computing progress.
- **Key files:** `OfflineDownloadService.swift`, `DownloadsViewModel.swift`

### Downloads Stuck in "Downloading" After App Kill
- **Resolved (March 18, 2026)**
- **Previous:** When the app was killed mid-download, CoreData status stayed `.downloading`. On next launch, `fetchPendingDownloads()` counted them (includes `.downloading`) so workers spawned, but `fetchNextPendingDownload()` found 0 (only `.pending`) so workers immediately exited — endlessly.
- **Fix:** `OfflineDownloadService.init()` resets stale `.downloading` → `.pending` before starting the queue. At init time, no download can be actively in-progress.
- **Key files:** `OfflineDownloadService.swift`

### Download Queue Workers Spawned With No Pending Downloads
- **Resolved (March 11, 2026)**
- **Previous:** `startQueueIfNeeded()` (called from `init` and ~15 other sites) only checked `queueTask == nil`, so 3 worker tasks were spawned on every app launch even with zero pending downloads. Each worker ran a CoreData query, found nothing, and exited — 18+ "Worker exit: no pending download" log lines.
- **Fix:** `runQueueLoop()` now checks `fetchPendingDownloads().count` before spawning the task group. If zero pending, exits immediately without creating worker tasks.
- **Key files:** `OfflineDownloadService.swift`

### WebSocket Circuit Breaker for Repeated Failures
- **Resolved (March 11, 2026)**
- **Previous:** WebSocket reconnect backoff capped at 60s, retrying forever even when the server always returned 1001 (Going Away). This burned CPU and network during foreground.
- **Fix:** Circuit breaker activates after 5 consecutive failures and switches to 5-minute retry intervals. Resets on successful message receipt, `start()`, or endpoint URL change.
- **Key files:** `PlexWebSocketManager.swift`

### Download System Query Batching
- **Resolved (March 11, 2026)**
- **Previous:** After each download completion, `refreshAllTargetProgresses()` ran O(targets x tracks) individual CoreData queries. iPhone 6s crawled during bulk downloads.
- **Fix:** Targeted refresh only updates owning targets (`fetchTargetKeys(containing:)`). Batch download status queries use single `IN` predicate (`fetchDownloadsBatch`). Dynamic debounce: 3s when >3 pending, 1s otherwise.
- **Key files:** `OfflineDownloadService.swift`, `DownloadManager.swift`, `OfflineDownloadTargetRepository.swift`

### PlaybackService objectWillChange Fired at 30Hz
- **Resolved (March 11, 2026)**
- **Previous:** `@Published var frequencyBands` caused `objectWillChange` to fire 30x/sec, re-rendering all views observing `PlaybackService`.
- **Fix:** Replaced with `CurrentValueSubject<[Double], Never>`. `objectWillChange` no longer fires for band updates. `NowPlayingViewModel.applyLyricsPosition()` also guards against no-change assignments.
- **Key files:** `PlaybackService.swift`, `NowPlayingViewModel.swift`

### TrackRow Mass Re-Render on Availability Change
- **Resolved (March 11, 2026)**
- **Previous:** `@ObservedObject availabilityResolver` (singleton) caused ALL visible TrackRows to re-render when generation counter bumped.
- **Fix:** Replaced with `@State private var cachedAvailability` + `.onReceive` that only updates `@State` when THIS track's availability actually changed. Applied to both `TrackRow` and `CompactTrackRow`.
- **Key files:** `TrackRow.swift`, `CompactSearchRows.swift`

### Songs View 1500+ Track Choppiness
- **Resolved (March 11, 2026)**
- **Previous:** `SongsView` wrapped `MediaTrackList` (UITableView) in a fixed-height frame (`CGFloat(trackCount * 68)`), defeating both `LazyVStack` lazy loading and UITableView cell recycling. Search filtering ran synchronously on every keystroke.
- **Fix:** Non-indexed sort renders `MediaTrackList` directly without ScrollView wrapper or fixed-height frame. Search text filtering debounced at 150ms via Combine pipeline.
- **Key files:** `SongsView.swift`, `LibraryViewModel.swift`

### LyricsCard Full Re-Render Every 0.5s
- **Resolved (March 11, 2026)**
- **Previous:** When `currentLyricsLineIndex` changed, ALL lyrics lines recalculated visual params and triggered animations.
- **Fix:** Extracted `LyricsLineView` as `Equatable` struct with pre-computed params. Wrapped in `EquatableView` so SwiftUI skips unchanged lines (~2 re-renders per tick instead of N).
- **Key files:** `LyricsCard.swift`

### Download Queue Polling + WebSocket Routing
- **Resolved (March 11, 2026)**
- **Previous:** `PlexAPIClient.downloadTranscodedMediaViaQueue()` polled PMS every 1s with fixed interval. WebSocket `media.download` activity events were parsed but not routed — only `library.refresh`/`library.update` types were handled by `PlexWebSocketCoordinator`. This meant PMS download queue completions never notified the download service, so the queue could stall after workers exited.
- **Fix:** Polling uses exponential backoff (1s→2s→4s→8s, capped 15s). `PlexWebSocketCoordinator` now handles `media.download ended` events via `onDownloadQueueCompleted` callback, which triggers `OfflineDownloadService.handleDownloadQueueCompleted()` to restart the queue.
- **Key files:** `PlexAPIClient.swift`, `PlexWebSocketCoordinator.swift`, `OfflineDownloadService.swift`, `DependencyContainer.swift`

### MediaTrackList Layout Outside View Hierarchy
- **Resolved (March 11, 2026)**
- **Previous:** SwiftUI eagerly created `MediaTrackList` UITableView instances for navigation destinations not yet displayed. UITableView performed layout on init even without a window, causing "layout outside view hierarchy" warnings and unnecessary work at launch.
- **Fix:** `DeferredLayoutTableView` subclass skips `layoutSubviews()` when not in a window and triggers `reloadData()` on `didMoveToWindow`. `updateUIView` early-returns when the table has no window.
- **Key files:** `MediaTrackList.swift`

### WebSocket Settings Changed Event Spam
- **Resolved (March 11, 2026)**
- **Previous:** Rapid bursts of PMS settings-changed WebSocket events (e.g. 5 pairs in 3s) each logged and processed individually.
- **Fix:** Settings events debounced per server with 5s window in `PlexWebSocketCoordinator`.
- **Key files:** `PlexWebSocketCoordinator.swift`

### NowPlaying Carousel Cards Rendered Off-Screen
- **Resolved (March 11, 2026)**
- **Previous:** TabView `.page` style renders ALL child views simultaneously. LyricsCard's `.blur()` effects, QueueCard's UIKit QueueTableView, and InfoCard's async fetches all ran off-screen. LyricsCard blur alone was 3.8% of GPU trace (`RB::Filter::GaussianBlur`). QueueCard triggered "UITableView layout outside view hierarchy" warnings.
- **Fix:** Each card gates its expensive content behind a `currentPage == N` check. Off-screen cards show a lightweight `Color.clear` placeholder. InfoCard also defers its async album fetch until the card becomes visible.
- **Key files:** `LyricsCard.swift`, `QueueCard.swift`, `InfoCard.swift`

### WebSocket Scan Progress Event Spam
- **Resolved (March 11, 2026)**
- **Previous:** `PlexWebSocketCoordinator.serverScanProgress` (@Published) was updated every ~10ms during library scans with zero throttling. Each update fired `objectWillChange` on the singleton, causing cascading UI invalidations.
- **Fix:** Only publish when progress changes by >=5 percentage points (or on started/ended), cutting ~95% of scan-related objectWillChange events.
- **Key files:** `PlexWebSocketCoordinator.swift`

### MediaTrackList Singleton Observer Cascade (N×3 Subscriptions)
- **Resolved (March 11, 2026)**
- **Previous:** `MediaTrackList` directly observed 3 singletons as `@ObservedObject` (networkMonitor, offlineDownloadService, trackAvailabilityResolver). When SongsView rendered 26 alphabetic sections, this created 78 independent subscriptions (26×3). Every publish triggered `updateUIView` on ALL instances → reconfigured ALL visible cells.
- **Fix:** Removed the 3 `@ObservedObject` declarations from MediaTrackList. Parent views observe the singletons once and pass `availabilityGeneration: UInt` and `activeDownloadRatingKeys: Set<String>` as value parameters. Network state read from DependencyContainer at updateUIView time (not observed).
- **Key files:** `MediaTrackList.swift`, `SongsView.swift`, `MediaDetailView.swift`, `FavoritesView.swift`, `SearchView.swift`, `ArtistsView.swift`, `StageFlowTrackPanel.swift`

### Per-Track activeDownloadRatingKeys Refresh During Bulk Downloads
- **Resolved (March 11, 2026)**
- **Previous:** Each track completion called `refreshActiveDownloadRatingKeys()` via `refreshTargetsForTrack()`, firing the @Published property per-track and causing N UI updates during bulk downloads.
- **Fix:** Removed redundant per-track call. The debounced `scheduleDownloadChangeNotification()` (1-3s window) already handles this, batching spinner updates.
- **Key files:** `OfflineDownloadService.swift`

### Premature "Downloads Complete" Toast
- **Resolved (March 11, 2026)**
- **Previous:** Toast appeared at 73/79 tracks, then queue got stuck. Workers exited when `fetchNextPendingDownload()` returned nil, but PMS was still preparing remaining downloads. `queueTask` was only nil'd after the toast, so WebSocket-triggered `handleDownloadQueueCompleted()` couldn't restart the queue.
- **Fix:** Nil `queueTask` before the wind-down check. Add 500ms grace period, then re-check for pending downloads. If more work arrived, restart the queue instead of showing toast.
- **Key files:** `OfflineDownloadService.swift`

### Downloads View Artwork Flashing
- **Resolved (March 11, 2026)**
- **Previous:** `DownloadsViewModel` replaced the `items` array wholesale on every `offlineDownloadService.$targets` publish, causing ForEach to re-render all rows (including artwork) even when only progress numbers changed.
- **Fix:** Made `DownloadedItemSummary` Equatable. Only assign `items` when mapped values actually differ. Guard `resolveThumbPaths()` against redundant publishes.
- **Key files:** `DownloadsViewModel.swift`

### Large Playlist Detail View Hang (1400+ tracks)
- **Resolved (March 11, 2026)**
- **Previous:** `MediaDetailView.tracksSection` applied `.frame(height: CGFloat(trackCount * 68))` to MediaTrackList, forcing all 1436 cells to render at once — same anti-pattern fixed for unsorted SongsView.
- **Fix:** Added `managesOwnScrolling: Bool` parameter to MediaTrackList. When track count >200, uses a regular UITableView with scroll enabled for cell recycling. Small lists (albums) keep embedded behavior. Removed fixed `.frame(height:)` for large lists.
- **Key files:** `MediaTrackList.swift`, `MediaDetailView.swift`

### Queue View Hang with Large Playlists + Artwork Race on Rearrange
- **Resolved (March 11, 2026)**
- **Previous:** `QueueTableView` used `IntrinsicTableView` inside a SwiftUI `ScrollView`. `IntrinsicTableView` reported full content height as `intrinsicContentSize`, forcing all 1436 cells to render. Artwork could also flash incorrectly during drag-to-rearrange due to stale async loads.
- **Fix:** Replaced `IntrinsicTableView` with regular `UITableView` (scroll enabled). Removed `ScrollView` wrapper in `QueueCard`. Added `configureGeneration` counter to `QueueItemCell` — async artwork loads check their generation matches before assigning.
- **Key files:** `QueueTableView.swift`, `QueueCard.swift`

## Future Enhancements (Waveform System)

- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming
