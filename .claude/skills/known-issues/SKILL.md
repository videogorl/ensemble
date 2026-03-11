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

## Feature Completeness Gaps

### Intermittent 404 on /library/streams/ for Lyrics
- **Location:** `LyricsService.swift`, `PlexAPIClient.getLyricsContent(streamKey:)`
- **Issue:** Some tracks report a valid `lyricsStream` (streamType=4) in the `/library/metadata/{ratingKey}` response, but the subsequent `GET /library/streams/{streamKey}` call returns HTTP 404. This appears to be a Plex server bug where the stream record exists in metadata but the stream content is not actually stored.
- **Impact:** Lyrics show "No Lyrics" for affected tracks despite the track appearing to have a lyrics attachment.
- **Current behavior:** `LyricsService` treats the 404 as `.notAvailable` and does not retry. The result is cached to avoid repeated 404 traffic for the same track.
- **Workaround:** None; the issue is server-side. Pulling to refresh or clearing cache may resolve it if the server regenerates the stream.

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
- **Current behavior:** `PlexWebSocketCoordinator` treats WS events as acceleration hints; polling-based sync timers remain active as fallback for all account types. If a WebSocket connection fails repeatedly, the backoff cap prevents excessive reconnect attempts.

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

### Aurora Visualizer Optimized to 30fps + 3 Passes
- **Resolved (March 11, 2026)**
- **Previous:** 60fps `TimelineView(.animation)` with 6 blur passes (144 blur filter applications/frame). Never paused behind Now Playing sheet.
- **Fix:** Capped at 30fps via `minimumInterval: 1/30`. Reduced to 3 glow passes (blur=18, 12, 8). Pauses when Now Playing sheet covers it (`isPaused` binding). Skips identical frequency band publishes. Display timer uses `MainActor.assumeIsolated` instead of `Task { @MainActor }`.
- **Key files:** `AuroraVisualizationView.swift`, `MainTabView.swift`, `AudioAnalyzer.swift`

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

## Future Enhancements (Waveform System)

- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming
