---
name: architecture
description: "Load before designing features, adding services, or touching multiple packages. Ensemble app architecture: package structure, key types, architectural patterns, dependency flow, domain model layers, subsystems (artwork caching, waveform, frequency visualizer, hubs, filtering, network resilience, playback tracking, playlist mutations, playlist merging, incremental sync, Siri media intents, pinned content, persistent session logging, user profile & CloudKit sync)"
---

# Ensemble Architecture

## Layered Module Architecture

Four Swift Packages under `Packages/`:

```
Layer 3: EnsembleUI (SwiftUI views & components)
              |
Layer 2: EnsembleCore (ViewModels, services, domain models)
              |
Layer 1: EnsembleAPI (Networking) + EnsemblePersistence (CoreData)
```

## Package Details

### EnsembleAPI (Networking Layer)
- **Location:** `Packages/EnsembleAPI/`
- **Dependencies:** KeychainAccess
- **Purpose:** All Plex server communication and authentication

**Key Types:**
- `PlexAuthService` (actor) -- PIN-based OAuth authentication
- `PlexAuthTokenMetadata` -- Parsed auth token metadata (`iat`/`exp`) used for lifecycle enforcement
- `PlexAPIClient` (actor) -- Thread-safe API requests with automatic failover
  - Server capabilities: `getServerCapabilities()` (fetches root endpoint for subscription & feature info)
  - Core methods: `fetchLibraries()`, `fetchTracks()`, `fetchAlbums()`, `fetchArtists()`, etc.
  - Stream routing (two-phase): `makeStreamDecision()` → `StreamDecision` (endpoint-independent), `assembleStreamResolution()` → `StreamResolution` (uses fresh endpoint from registry). Legacy `resolveStreamURL()` chains both.
  - Decision parsing: `callTranscodeDecision()` → `TranscodeDecisionResult` (directplay/copy/transcode)
  - Playback tracking: `reportTimeline()`, `scrobble()`
  - Waveform data: `getLoudnessTimeline(forStreamId:subsample:)`
  - File-partitioned endpoint groups now live beside the actor in `PlexAPIClient+Library`, `PlexAPIClient+Metadata`, and `PlexAPIClient+Playlists`, while shared request execution/failover remains in `PlexAPIClient.swift`
- `PlexRequestBuilder` -- Pure URLRequest/header assembly helper used by PlexAPIClient's shared transport paths
- `StreamDecision` / `TranscodeStreamDecision` -- Endpoint-independent streaming decisions (cached across network transitions)
- `PlexConnectionPolicy` types -- Endpoint descriptors, ordering policies, probe classifications, and structured refresh outcomes
- `PlexErrorClassification` -- Unified error taxonomy (transport vs. semantic) for failover and retry decisions
- `ServerConnectionRegistry` (actor) -- Single source of truth for per-server active endpoints
- `PlexWebSocketManager` (actor) -- Per-server WebSocket connections with exponential backoff reconnect
- `KeychainService` -- Token persistence using KeychainAccess library
- `PlexModels.swift` -- Response types (`PlexServer`, `PlexLibrary`, `PlexTrack`, `PlexLoudnessTimeline`, `PlexSubscription`, `PlexServerCapabilities`, etc.)

### EnsemblePersistence (Data Layer)
- **Location:** `Packages/EnsemblePersistence/`
- **Dependencies:** None (pure CoreData)
- **Purpose:** Local caching and offline storage

**Key Types:**
- `CoreDataStack` (singleton) -- Main/background contexts, saves on background queue
- `CD*` models -- `CDMusicSource`, `CDArtist`, `CDAlbum`, `CDTrack`, `CDGenre`, `CDPlaylist`, `CDServer`, `CDOfflineDownloadTarget`, `CDOfflineDownloadMembership`
- `LibraryRepository` / `PlaylistRepository` -- Protocol-based repository pattern
- `DownloadManager` -- Offline track file management (source-aware, quality-aware)
- `OfflineDownloadTargetRepository` -- Offline target metadata and target->track membership persistence
- `ArtworkDownloadManager` -- Persistent artwork caching to local filesystem

### EnsembleCore (Business Logic Layer)
- **Location:** `Packages/EnsembleCore/`
- **Dependencies:** EnsembleAPI, EnsemblePersistence, Nuke
- **Purpose:** Services, ViewModels, domain models, dependency injection

**Key Services:**
- `DependencyContainer` (singleton) -- Wires all services, creates ViewModels, injected via SwiftUI environment
- `AccountManager` (@MainActor) -- Manages multiple Plex accounts, servers, and libraries
- `PlexAccountDiscoveryService` -- Discovers account identity + normalized server/library inventory during add-account and reconciliation flows
- `LocalNetworkPermissionProbe` -- Onboarding helper that prompts for local-network access before Plex server discovery work
- `SyncCoordinator` (@MainActor) -- Orchestrates library syncing across all enabled sources; provides timeline reporting and scrobbling methods
  - Publishes `lastContentChange` for consumers that need actual library/playlist mutations; `sourceStatuses` remains the transport/progress surface
  - Delegates playlist create/rename/delete/replace control flow to `PlaylistMutationController` so mutation validation, duplicate checks, refresh triggering, and target persistence stay out of the main sync facade
  - Delegates full/incremental/startup sync execution to `SyncExecutionController` so sync loops, per-source status transitions, playlist-once-per-server handling, and incremental fallback logic stay out of the main facade
  - Delegates health-refresh gating/coalescing to `RefreshOrchestrator` so foreground/network-triggered probes share one cooldown/staleness path
  - Delegates app-foreground and network-transition policy to `NetworkLifecycleController` so lifecycle events produce explicit refresh/invalidation plans before side effects run
  - Delegates API-client endpoint synchronization and registry observation to `ServerConnectionController` so sync flow no longer owns registry subscription tasks directly
- `NavigationCoordinator` (@MainActor) -- Manages cross-view navigation state (artist/album deep links from NowPlayingView)
  - Maintains per-tab navigation paths (homePath, artistsPath, etc.)
  - `visibleTabs: [TabItem]` -- Synced from MainTabView to enable fallback logic
  - `navigateFromNowPlaying()` -- Falls back to first visible tab when navigating from Search
  - `pendingNavigation` -- Deferred navigation executed after sheet dismissal
  - `openSettings()` / `openDownloads()` -- Shared auxiliary presentation entry points for large-screen sidebar/actions
  - `activeAuxiliaryPresentation` / `auxiliaryWindowRequest` -- Root-level modal/window routing state; screens should request presentation through the coordinator instead of owning duplicated sheet state
  - On iPhone, `Profile` is routed through `activeAuxiliaryPresentation` but presented as a normal root sheet in `MainTabView`; `Downloads` keeps the auxiliary full-screen presenter because it still benefits from root-shell isolation
- `RootView` owns the scene/window-scoped `NavigationCoordinator` and `NowPlayingViewModel`, while playback services remain shared through `DependencyContainer`. This keeps multiple iPad/macOS windows on independent navigation paths without forking playback state.
- Large-screen Now Playing presentation is split at the UI layer: `NowPlayingSheetView` is the shared iPhone/iPad sheet-style presenter, while `NowPlayingViewportRoot` is reserved for macOS viewport presentation and coordinated separately through `WindowChromeBridge` so toolbar content can swap without moving the titlebar/traffic lights
- `PlaybackService` -- AVPlayer management, queue, shuffle, repeat, remote controls, timeline reporting (every 10s), and scrobbling (at 90% completion). Publishes both raw transport time (`currentTime`) and presentation-adjusted time (`presentationTime`) so lyrics/Aurora can compensate for AirPlay/Bluetooth output delay without affecting seek/reporting semantics. `frequencyBands` uses `CurrentValueSubject` (not `@Published`) to avoid firing `objectWillChange` at 30Hz. Uses `ProgressiveStreamLoader` for transcode streams and `streamLoaders` dict for lifecycle management
- `AudioPlaybackEngine` -- Gapless local-file playback engine used behind `PlaybackService`; owns route recovery, scheduling, and instrumental-mode audio graph concerns
- `PlaybackHandoffCoordinator` -- Internal playback-handoff reducer extracted from `PlaybackService`; owns disconnect/interruption/remote-command pause intent, settle-window policy, and handoff logging decisions while the service remains the side-effect boundary
- `PlaybackQueueStore` -- Persists queue/history restoration state outside `PlaybackService`; writes a single snapshot plus legacy keys so queue-restoration refactors can proceed without breaking existing installs
- `PlaybackQueueController` -- Internal queue/history seam extracted from `PlaybackService`; owns queue snapshot persistence plus autoplay flattening/history normalization while the service remains the playback side-effect boundary
- `PlaybackLaunchCoordinator` -- Internal playback-launch seam extracted from `PlaybackService`; owns the successful-resolution path (visualizer planning, engine load, recovery seek application, and prefetch kickoff) while the façade still owns queue mutation and transport retry loops
- `PlaybackRecoveryPolicy` -- Internal playback buffering/stall policy seam extracted from `PlaybackService`; owns buffering profiles, conservative-mode escalation, prefetch throttling, and unexpected-pause recovery decisions while `PlaybackService` remains the façade
- `PlaybackSessionStateMachine` -- Internal playback-session seam extracted from `PlaybackService`; owns request validation, retry policy, supersession checks, and terminal failure classification for `playCurrentQueueItem` while queue mutation and engine control remain in the façade
- `PlaybackPrefetchController` -- Internal prefetch/cache seam extracted from `PlaybackService`; owns resolved-file URL eviction, temporary stream-cache cleanup, and network-transition re-prefetch invalidation policy
- `PlaybackNowPlayingBridge` -- Internal lock-screen seam extracted from `PlaybackService`; owns `MPNowPlayingInfoCenter` metadata, artwork loading, feedback-command state, and remote-command registration
- `PlaybackTransportCoordinator` -- Internal transport seam extracted from `PlaybackService`; owns stream-decision caching, in-flight resolution deduplication, and progressive-loader lifecycle for local-file vs streaming resolution without changing playback queue semantics
- `ProgressiveStreamLoader` -- AVAssetResourceLoaderDelegate + URLSessionDataDelegate bridge. Proxies PMS's chunked transcode stream (via custom `ensemble-transcode://` scheme) to AVPlayer progressively, writing to a growing temp file. Post-download callbacks: `onDownloadComplete` for frequency analysis, `onDownloadFailed` for HTTP errors and invalid payloads. Validates HTTP status (non-2xx → `ProgressiveStreamError.httpError`) and payload size (< 256 bytes → `.invalidPayload`). Error body captured to diagnostic buffer (not written to audio file)
- `ProgressiveStreamError` -- Error type for stream download failures: `.httpError(statusCode:bodySnippet:)` and `.invalidPayload(bytesReceived:)`. Mapped to `PlaybackError` in `PlaybackService.mapToPlaybackError`
- `HubRepository` -- Repository for hub data persistence (implements `HubRepositoryProtocol`); manages CDHub/CDHubItem entities
- `HubOrderManager` -- Manages user-customizable hub section ordering per music source
  - Persists custom order to UserDefaults with per-source keys
  - `applyOrder(to:for:)` -- Reorders fetched hubs according to saved preferences
  - `saveOrder(_:for:)` / `saveDefaultOrder(_:for:)` -- Stores custom and default orders
  - `resetToDefaultOrder(for:)` -- Restores server's original hub order
- `ArtworkLoader` -- Persistent artwork caching with local-first loading strategy
- `CacheManager` (@MainActor) -- Tracks cache sizes and provides cache clearing functionality
- `NetworkMonitor` (@MainActor) -- Proactive network connectivity monitoring using NWPathMonitor with 1s debouncing
- `RefreshOrchestrator` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns health-refresh coalescing, cooldown/staleness checks, and startup-health claim tracking while `SyncCoordinator` remains the façade
- `SyncExecutionController` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns full/incremental/startup sync execution, progress routing, and cancellation/error status restoration while the coordinator keeps helper side effects and published state
- `NetworkLifecycleController` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns app-foreground and observed-network transition policy (offline state, refresh triggers, and startup-transition skipping) while the coordinator applies side effects
- `PeriodicSyncController` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns foreground periodic-sync timer scheduling and WebSocket-aware polling interval changes while `SyncCoordinator` keeps the actual sync policy
- `PlaylistRefreshController` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns server-scoped playlist refresh resolution (incremental vs fallback full sync) for mutation refreshes, playlist-only sync, and WebSocket-triggered playlist updates
- `WebSocketSyncController` (@MainActor) -- Internal sync seam extracted from `SyncCoordinator`; owns WebSocket-triggered section resolution and server playlist refresh routing so the coordinator does not inline provider lookup logic
- `ServerHealthChecker` -- Concurrent health checks for all configured servers with automatic failover
- `ServerConnectionController` (@MainActor) -- Internal network seam extracted from `SyncCoordinator`; owns registry-driven API-client URL updates and explicit endpoint refresh fan-out while `SyncCoordinator` remains the façade
- `SettingsManager` (@MainActor) -- Manages accent colors, customizable tab configuration, and track swipe action layout settings
- `BackgroundSyncScheduler` -- iOS `BGAppRefreshTask` scheduling for hub refresh ~every 15min (system-controlled)
- `MoodRepository` -- Mood data persistence (CDMood)
- `LibraryVisibilityStore` (@MainActor) -- Persists visibility profiles and active profile state for source-level browse filtering
- `ToastCenter` (@MainActor) -- App-wide toast notification coordination
- `PlexRadioProvider` -- Plex Radio support implementing `RadioProvider` protocol
- `PlexWebSocketCoordinator` (@MainActor) -- Routes WebSocket events from `PlexWebSocketManager` to `SyncCoordinator` and `ServerHealthChecker`
  - Coalesces section-level library updates with debounce + in-flight/cooldown guards so scans do not cascade into redundant incremental syncs
  - Publishes aggregate WebSocket availability changes so periodic-sync timer policy can follow actual socket connectivity without app-layer polling
- `TrackAvailabilityResolver` (@MainActor ObservableObject) -- Reactive per-track availability combining server connection state and download state; publishes `TrackAvailability` enum
- `SiriMediaIndexStore` -- Builds/persists shared App Group Siri candidate index (track/album/artist/playlist)
- `SiriPlaybackCoordinator` -- Executes Siri playback payloads in app process using existing playback queue entry points
- `OfflineDownloadService` (@MainActor) -- Target-based offline orchestration (reconciliation, progress publishing, reference-counted cleanup, façade for queue control)
  - Uses an internal `DownloadWorkMode` policy (`interactivePlayback`, `foregroundIdle`, `background`) so playback-sensitive sessions throttle queue concurrency and coalesce expensive target-progress publishes instead of treating every queue/network event as full-speed work
  - Delegates debounced `downloadsDidChange` fan-out, view-context refresh routing, and queue-completion toast presentation to `OfflineDownloadNotificationBridge` so queue/target logic stays separate from UI-facing notifications
  - Runs `OfflineDownloadCleanupCoordinator` during startup and healing refreshes to remove completed downloads whose track files no longer belong to any offline target membership
  - Delegates direct-download, download-queue, file validation, completion recovery, and per-track post-completion work to `DownloadTransferExecutor` so retry policy and target-refresh logic stay in the façade
- `DownloadQueueCoordinator` (@MainActor) -- Sole owner of offline queue task lifecycle, worker fan-out, background wakeup handling, and queue wind-down/restart decisions
- `DownloadRetryPolicy` (@MainActor) -- Stateful transfer retry accounting and direct-original fallback gating for offline downloads
- `DownloadTargetReconciler` -- Resolves offline target memberships, queues missing downloads, and deletes orphaned download files when targets change
- `DownloadTransferExecutor` (@MainActor) -- Internal offline seam extracted from `OfflineDownloadService`; owns download-queue vs direct-original transfer execution, payload validation, completion recovery, artwork/lyrics/sidecar post-processing, and direct-fallback bookkeeping while the service keeps membership checks, retry policy, and target refresh decisions
- `OfflineDownloadCleanupCoordinator` (@MainActor) -- Internal offline seam extracted from `OfflineDownloadService`; scans completed downloads for zero-membership tracks and removes stray files/records during startup and healing refreshes
- `OfflineDownloadNotificationBridge` (@MainActor) -- Internal offline seam extracted from `OfflineDownloadService`; owns debounced `downloadsDidChange` posting, refresh fan-out, and queue-completion toast routing while the service keeps target and transfer logic
- `OfflineBackgroundExecutionCoordinator` (@MainActor) -- Optional iOS 26+ `BGContinuedProcessingTask` adapter; no-op on unsupported platforms/OS versions
- `FrequencyAnalysisService` -- Pre-computed audio frequency analysis using Accelerate FFT; produces `FrequencyTimeline` data for visualizer display decoupled from the audio pipeline
- `PowerStateMonitor` (@MainActor ObservableObject) -- Observes iOS Low Power Mode via `NSProcessInfoPowerStateDidChange` and publishes `isLowPowerMode: Bool`. Consumers (Aurora visualizer, LyricsCard, download service) read this to reduce GPU passes, frame rates, and network work when the device is in LPM
- `SongLinkService` (actor) -- Resolves universal song.link URLs for tracks and albums via MusicKit catalog search + song.link API; in-memory cache with positive/negative entries
- `ShareService` (@MainActor) -- Coordinates share payloads: link (song.link/Apple Music URL), text (fallback), or file (local download or temp download via Plex stream URL)
- `MutationCoordinator` (@MainActor) -- Unified online/offline mutation queue for ratings, playlist changes, and scrobbles
- `MetadataMutationService` -- Metadata edit coordination for tracks/albums/artists/playlists, plus invalidation notifications that refresh browse/detail surfaces
- `SiriAffinityCoordinator` (@MainActor) -- Executes Siri love/dislike/remove-rating requests against the current track
- `SiriAddToPlaylistCoordinator` (@MainActor) -- Executes Siri add-to-playlist requests and routes them through the optimistic mutation path
- `SiriMediaUserContextManager` -- Persists recent Siri playback context to improve subsequent media resolution and ranking

**Key Models:**
- Domain models: `Track`, `Album`, `Artist`, `Genre`, `Playlist`, `Hub`, `HubItem` (UI-facing, protocol-conforming)
  - `Track` includes `streamId: Int?` -- Identifies audio stream for fetching loudness timeline data (waveform visualization)
- `MusicSource` / `MusicSourceIdentifier` -- Multi-account source tracking
- `PlexAccountConfig` -- Account/server/library hierarchy for configuration (includes `PlexSubscription` on account, `PlexServerCapabilities` on server, `allowSync` on library)
- `LibraryVisibilityProfile` -- Named profile of hidden source composite keys (non-destructive visibility filtering)
- `FilterOptions` -- Comprehensive filtering with search, sort, genre/artist filters, year ranges, downloaded-only toggle
  - Includes `FilterPersistence` utility class for saving/loading filter state per-view to UserDefaults
- `NetworkState`, `NetworkType`, `ServerConnectionState`, `StatusColor` -- Network state management models
- `PinnedItem` -- User-pinned content (albums, artists, playlists) with sort order
- `Mood` -- Plex mood/vibe category (title and ratingKey)
- `SiriPlaybackRequestPayload` / `SiriMediaKind` -- Versioned extension -> app handoff contract for Siri media intents
- `SiriMediaIndex` / `SiriMediaIndexItem` -- Compact index records used by extension-side lookup/ranking

**Key ViewModels:**
- `PinnedViewModel` -- Fetches `PinnedItem` CoreData records and resolves them into full domain objects

### EnsembleUI (Presentation Layer)
- **Location:** `Packages/EnsembleUI/`
- **Dependencies:** EnsembleCore, Nuke (NukeUI)
- **Purpose:** All SwiftUI views and reusable components

**Key Views:**
- `RootView` -- Adapts by platform: tab navigation on iPhone, sidebar on iPad/macOS; also owns the root aurora layer, the single shared mini player overlay, and the scene-local navigation/Now Playing coordinators
- `MiniPlayer` -- Persistent compact player overlay across all screens
- `MediaDetailView` -- Unified detail view using `MediaDetailViewModelProtocol` (supports Artist, Album, Playlist, Favorites)
- `ArtworkView` -- Local-first artwork loading with automatic fallback to network
- `HomeView` -- Hub-based home screen with horizontally-scrolling sections
- `FilterSheet` -- Advanced filtering UI with artist/genre multi-select, year ranges
- `AlbumDetailLoader` / `ArtistDetailLoader` / `PlaylistDetailLoader` -- Async loading wrappers for detail views
- `WaveformView` -- Audio waveform visualization with real Plex loudness data or fallback generation
- `StageFlowView` -- iPhone landscape stage carousel with snapping, inward-facing side cards, and a trailing track panel
- `TrackSwipeContainer` -- Shared swipe-action wrapper for track rows on iOS/iPadOS
- `TrackSwipeActionsSettingsView` -- Settings screen for swipe slot assignment
- `AddPlexAccountView` -- PIN auth flow with grouped server/library checklist and copy-on-tap PIN
- `MusicSourceAccountDetailView` -- Account-scoped server/library selection + per-library sync/connection status
- `DownloadManagerSettingsView` -- Settings-only offline manager screen (`Servers` + target status list)
- `OfflineServersView` -- Server-grouped, sync-enabled library toggles for library-wide offline targets

## Key Architectural Patterns

- **MVVM** -- All ViewModels are `@MainActor` ObservableObjects using Combine publishers
- **Dependency Injection** -- Centralized `DependencyContainer` singleton, injected through SwiftUI environment key
- **Actor-based concurrency** -- Thread-safe networking with `PlexAPIClient` and `PlexAuthService` actors
- **Repository pattern** -- Protocol abstractions for CoreData access (`LibraryRepositoryProtocol`, `PlaylistRepositoryProtocol`)
- **Protocol-based view reuse** -- `MediaDetailViewModelProtocol` enables single `MediaDetailView` for multiple content types (Artist, Album, Playlist, Favorites)
- **Domain model separation** -- Three distinct model layers:
  - API models (`Plex*` in EnsembleAPI) -- Raw server responses
  - CoreData models (`CD*` in EnsemblePersistence) -- Persisted entities
  - Domain models (in EnsembleCore) -- UI-facing, protocol-conforming types
- **In-app-first Siri execution** -- Siri extension resolves/disambiguates and returns `handleInApp`; playback always executes in main app process through `SiriPlaybackCoordinator`
- **Dual Siri invocation surfaces** -- SiriKit Media Intents remains primary for media-domain routing, while app-level App Intents shortcuts provide album/playlist fallback phrase routing when SiriKit does not invoke the extension
- **Multi-source architecture** -- Designed to support multiple Plex accounts and future services (Apple Music, Spotify)
  - `MusicSourceIdentifier` tracks source origin (accountId, serverId, libraryId)
  - `SyncCoordinator` orchestrates syncing across all enabled sources
  - Provider pattern allows pluggable sync implementations

## Subsystem: Artwork Caching

Persistent artwork caching that survives app restarts:

1. **ArtworkDownloadManager** (`EnsemblePersistence`) -- Downloads and stores artwork files locally
   - Stores in `Library/Application Support/Ensemble/Artwork/`
   - Filename format: `{ratingKey}_album.jpg` or `{ratingKey}_artist.jpg`
   - Methods: `downloadAndCacheArtwork()`, `getLocalArtworkPath()`, `clearArtworkCache()`, `deleteArtwork(ratingKey:type:)`

2. **ArtworkLoader** (`EnsembleCore`) -- Coordinates with local-first strategy
   - `artworkURLAsync()` checks local cache first using `ratingKey`
   - Falls back to network fetch via `SyncCoordinator` if not cached
   - `predownloadArtwork()` methods for batch downloading during sync
   - Configures Nuke's `ImagePipeline` with 100MB disk cache
   - `invalidateArtwork(ratingKey:type:)` clears URL cache + local file + targeted Nuke cache eviction (per ratingKey via `ArtworkURLTracker`) and posts `artworkDidInvalidate` notification

3. **ArtworkView** (`EnsembleUI`) -- SwiftUI component
   - Passes `ratingKey` to enable local cache lookups
   - Convenience initializers for `Track`, `Album`, `Artist`, `Playlist`
   - Listens for `artworkDidInvalidate` notification and re-triggers load when matching ratingKey is invalidated

4. **CacheManager** (`EnsembleCore`) -- Cache visibility and management
   - Methods: `refreshCacheInfo()`, `clearCache(type:)`, `clearAllCaches()`
   - Artwork cleanup on de-sync: `SyncCoordinator.cleanupRemovedSource()` and `cleanupServerPlaylists()` collect ratingKeys before CoreData deletion, then call `ArtworkDownloadManager.deleteArtwork(forRatingKeys:)` to remove cached files

5. **WebSocket-Driven Invalidation** -- Server artwork changes trigger cache eviction
   - `PlexWebSocketCoordinator.onArtworkInvalidation` fires on album (type=9) and artist (type=8) metadata updates (state=5)
   - `DependencyContainer` wires this to `ArtworkLoader.invalidateArtwork()` so UI refreshes automatically

6. **Sync-Driven Reparenting Invalidation** -- When tracks change albums during sync, stale artwork is evicted
   - `LibraryRepository` detects album reparenting during `upsertTrack` and `batchUpsertTracks` by comparing old vs new `albumRatingKey`
   - `TrackReparentInfo` events accumulate in a lock-protected buffer, drained by `SyncCoordinator` after each sync path
   - `SyncCoordinator.onTrackAlbumChanged` callback wired to `ArtworkLoader.invalidateArtwork()` for both the old album and the track's own ratingKey
   - `ArtworkView` re-triggers load via `artworkDidInvalidate` notification, fetching the correct new album cover

**Usage:**
```swift
// During sync - pre-download artwork
let count = try await artworkLoader.predownloadArtwork(for: albums, sourceKey: key, size: 500)

// In UI - loads from cache automatically
ArtworkView(album: album, size: .medium)
```

## Subsystem: Waveform Visualization

Displays audio waveforms in NowPlayingView:

1. **Plex Sonic Analysis (Preferred)** -- Uses Plex server's loudness analysis data
   - Data accessed via `/library/metadata/{ratingKey}/loudness` endpoint
   - Returns ~100-200 loudness samples

2. **PlexLoudnessTimeline** (`EnsembleAPI`) -- Model for loudness data
   - Field: `loudness: [Double]?`

3. **PlexAPIClient.getLoudnessTimeline()** -- Fetches waveform data using `streamId`

4. **PlaybackService.generateWaveform()** (`EnsembleCore`) -- Generation logic
   - **Primary:** Fetches real loudness data from `/library/streams/{streamId}/levels`
   - **Fallback:** Deterministic pseudo-random waveform seeded by `ratingKey` (~120 samples)
   - **Normalization:** `pow((value - minValue) / (maxValue - minValue), 1.5) * 0.9 + 0.1`

5. WaveformView (EnsembleUI) -- Horizontal bars with playback progress

## Subsystem: Pre-Computed Frequency Visualizer

Frequency analysis is pre-computed on disk and decoupled from the audio pipeline:

1. **FrequencyAnalysisService** (`EnsembleCore`) -- Analyzes audio files using Accelerate FFT (1024-pt FFT, 24 log-spaced bands 60Hz-16kHz). Produces `FrequencyTimeline` (time-indexed frequency snapshots at 30fps, ~216KB per 5-min song). Manages an in-memory cache of active timelines.
2. **FrequencyTimeline** -- Model containing an array of `FrequencySnapshot` frames with timestamps and band magnitudes. Supports binary serialization for sidecar persistence.
3. **FrequencyTimelinePersistence** -- Reads/writes `.freq` binary sidecar files alongside offline downloads for instant visualizer load on cached tracks.
4. **PlaybackService Integration** -- On track load, requests analysis from `FrequencyAnalysisService`. A 30Hz display timer reads `player.currentTime()` and looks up the matching frame from the active timeline. No `MTAudioProcessingTap`, `audioMix`, fade timers, or simulated bands.
5. **Scrubber Sync** -- `ControlsCard` scrubber drag calls `NowPlayingViewModel.updateVisualizerPosition()` so the visualizer tracks seek position in real time.
6. **Offline Sidecar** -- `OfflineDownloadService` generates `.freq` sidecar after downloading a track. `DownloadManager` cleans up sidecars when downloads are removed.
7. **Extension Probing** -- `FrequencyAnalysisService` probes unrecognized file extensions to determine if they are readable audio formats before attempting analysis.

## Subsystem: Aurora Visualization

Dynamic background effect that reacts to music intensity:

1. **Root Integration** -- Mounted in `RootView` using a `ZStack` at the bottom layer.
2. **Reactivity** -- Observes `PlaybackService` for playback state, current time, and frequency band data from the pre-computed `FrequencyTimeline`.
3. **Sampling** -- `AuroraVisualizationView` samples frequency bands using `currentTime / duration` to drive real-time animation intensity.
4. **Drawing** -- Uses `Canvas` and `TimelineView(.animation(minimumInterval: 1/30))` to draw overlapping fan-shaped sectors with radial gradients at 30fps.
5. **Blending** -- Overlapping sectors naturally create "denser" areas of light as they intersect. 3 glow passes (blur=18, 12, 8) for depth.
6. **Transparency Seam** -- Root views of tabs and navigation destinations use `.auroraBackgroundSupport()` to hide system backgrounds and let the aurora show through.
7. **Policy** -- Only visible when `playbackState` is `.playing` or `.buffering`, with a 1s fade transition. Paused when Now Playing sheet is open (`isPaused` parameter from `MainTabView`).
8. **Low Power Mode** -- When `PowerStateMonitor.isLowPowerMode` is true, aurora drops to 1 glow pass at 15fps (from 3 passes at 30fps). `LyricsCard` also disables progressive blur in LPM. Downloads are auto-paused/resumed on LPM toggle via `DependencyContainer` wiring.

## Subsystem: Hub-Based Home Screen


Dynamic home screen powered by Plex's hub system:

- `Hub` domain model -- Sections like Recently Added, Recently Played
- `HubItem` -- Items within a hub (tracks, albums, artists, playlists)
- `HomeViewModel` -- Loads hub data with 2s debouncing and defers auto-refresh/snapshot application while users are actively scrolling
- `HomeView` -- Horizontally-scrolling sections with navigation
  - `HubSection` / `HubItemCard` inline structs
  - Reports view visibility + scroll interaction to `HomeViewModel` so deferred refreshes are applied when idle
  - Artwork: 140x140pt, circular for artists (radius 70), rounded for albums (radius 8)

**Hub Persistence:**
- `HubRepository` manages `CDHub` and `CDHubItem` CoreData entities
- Methods: `fetchHubs()`, `saveHubs()`, `deleteAllHubs()`
- Offline-first: loads cached hubs immediately, fetches fresh in background

**Hub API Endpoints:**
- `getHubs(sectionKey:)` -- Section-specific hubs
- `getGlobalHubs()` -- Global hubs across all libraries
- `getHubItems(hubKey:)` -- Items for specific hub
- Fallback: if fewer than 3 section hubs, falls back to global hubs

## Subsystem: Timeline Reporting & Scrobbling

**Timeline Reporting:**
- Reports playback state every 10 seconds
- `PlaybackService` -> `SyncCoordinator.reportTimeline()` -> `PlexAPIClient.reportTimeline()`
- HTTP POST to `/:/timeline`

**Scrobbling:**
- Marks track as "played" at 90% completion
- `PlaybackService` -> `SyncCoordinator.scrobbleTrack()` -> `PlexAPIClient.scrobble()`
- HTTP POST to `/:/scrobble`

**Protocol:** `MusicSourceSyncProvider` includes `reportTimeline()` and `scrobble()` methods

## Subsystem: Advanced Filtering

**FilterOptions Model** (`EnsembleCore/Models/FilterOptions.swift`):
- `searchText`, `sortOption`, `sortDirection`, `selectedGenreIds`, `selectedArtistIds`, `yearRange`, `onlyDownloaded`
- `FilterPersistence` saves/loads per-view to UserDefaults

**FilterSheet UI:** Search bar, sort picker, genre/artist multi-select chips, year range slider, downloaded-only toggle

## Subsystem: Account-Centric Source Management

- Add-account flow uses `PlexAccountDiscoveryService` to fetch account identity, servers, and music libraries in one pass.
- Discovery flow also fetches per-server capabilities (`getServerCapabilities`) and populates `PlexSubscription` (account), `PlexServerCapabilities` (server), and `allowSync` (library) for feature gating.
- `MusicSourceAccountDetailView` displays `ServerFeatureBadges` (Plex Pass, hardware transcoding) and per-library download badges based on discovered capabilities.
- `SettingsView` shows account-level source rows (title + account identifier subtitle) instead of per-library rows.
- `MusicSourceAccountDetailViewModel`/`MusicSourceAccountDetailView` own library enablement, reconciliation, and sync status actions.
- Reconciliation defaults newly discovered libraries to unchecked and auto-disables/cleans removed libraries.
- Unchecking a library purges that library only; disabling/removing the last enabled library on a server also purges server-level playlists.
- Legacy standalone Sync Panel routes were removed from `MainTabView`/`MoreView`/sidebar flows.

## Subsystem: Offline Download Manager (Target-Based)

- Persistence adds `CDOfflineDownloadTarget` (target metadata/state/progress) and `CDOfflineDownloadMembership` (target track snapshot).
- `OfflineDownloadService` is the orchestrator for:
  - toggling target types (`library`, `album`, `artist`, `playlist`, `favorites`)
  - resolving target memberships from repositories
  - enqueuing missing track downloads
  - reconciling after sync/playlist updates
  - reference-counted cleanup of shared tracks when targets are removed
  - publishing `@Published activeDownloadRatingKeys: Set<String>` for UI download spinners in `TrackRow`/`MediaTrackList`
- `DownloadManager` stores download quality and uses source-aware lookup/delete (`ratingKey + sourceCompositeKey`) to prevent collisions.
- Queue policy is Wi-Fi/wired only; active downloads pause on cellular/offline and resume when allowed.
- Queue policy is also lifecycle-aware: user pause, Low Power Mode, app backgrounding, and iOS 26 continued-processing windows all feed the same scheduler so the service can pause aggressively on older devices without losing resumability.
- Full target-progress recomputation is coalesced during playback/background load; per-track completion still uses targeted owning-target refreshes so UI accuracy is preserved without rebuilding every target on each queue event.
- Sync integration:
  - `SyncCoordinator` publishes playlist refresh completion via `onPlaylistRefreshCompleted`.
  - `OfflineDownloadService` also watches source sync timestamps to reconcile library/album/artist targets after incremental/full sync updates.
- iOS 26+ optional acceleration:
  - `OfflineBackgroundExecutionCoordinator` submits/handles `BGContinuedProcessingTaskRequest`.
  - Background path is best-effort only; persistent queue state remains source of truth.

## Subsystem: Siri Media Intents (In-App-First)

- Siri extension target (`EnsembleSiriIntentsExtension`) implements `INPlayMediaIntentHandling` for query resolution/disambiguation only.
- Extension reads `SiriMediaIndex` from the shared App Group container and ranks candidates deterministically:
  - Match quality: exact normalized > prefix > contains
  - Tie-breaks: last played > play count > track count > deterministic name/id
- Extension returns `.handleInApp` with serialized `SiriPlaybackRequestPayload` in `NSUserActivity.userInfo`.
- `AppDelegate.application(_:continue:restorationHandler:)` routes payloads to `DependencyContainer.shared.siriPlaybackCoordinator`.
- `SiriPlaybackCoordinator` resolves media against enabled sources and executes:
  - Track: direct playback from resolved track
  - Album: queue album tracks from first track
  - Artist: queue artist tracks
  - Playlist: queue playlist tracks in saved order
- `SiriMediaIndexStore` rebuilds the index after sync completion and account/source configuration changes.
- App target registers `EnsembleAppShortcutsProvider` fallback shortcuts for album/playlist phrases (`PlayEnsembleAlbumIntent`, `PlayEnsemblePlaylistIntent`).
- App shortcut entities resolve against the same shared Siri index so Siri vocabulary tracks cached library content without direct extension CoreData access.
- `AppDelegate` calls `EnsembleAppShortcutsProvider.updateAppShortcutParameters()` at launch so App Intents metadata stays aligned with current index contents.

## Subsystem: Library Visibility Profiles (Groundwork)

- `LibraryVisibilityProfile` stores hidden `sourceCompositeKey` values independent of sync enablement.
- `LibraryVisibilityStore` persists profiles + active profile in `UserDefaults`.
- `LibraryViewModel`, `SearchViewModel`, and `HomeViewModel` apply visibility filtering seams to published collections without toggling `PlexLibraryConfig.isEnabled`.
- Selector/editor UI for switching profiles is intentionally deferred; groundwork is backend/viewmodel only.

## Subsystem: Network Resilience

Multi-layered network resilience spanning endpoint management, push-based updates, reactive availability, queue resilience, and unified error classification.

### Endpoint Truth -- ServerConnectionRegistry
- **`ServerConnectionRegistry`** (`EnsembleAPI`, actor) -- Single source of truth for per-server active endpoints.
- `PlexAPIClient` seeds the registry on init with the first discovered endpoint, and reports failover results back so all consumers share the latest healthy endpoint.
- `ServerHealthChecker` writes probe results into the registry after health checks.
- `SyncCoordinator` subscribes to registry changes to trigger downstream refreshes.
- `AccountManager` owns the registry instance; `DependencyContainer` wires it to all dependents.

### Push-Based Updates -- PlexWebSocketManager & PlexWebSocketCoordinator
- **`PlexWebSocketManager`** (`EnsembleAPI`, actor) -- Manages one `URLSessionWebSocketTask` per server with exponential backoff reconnect.
- **`PlexWebSocketCoordinator`** (`EnsembleCore`, @MainActor) -- Routes incoming WebSocket events to sync and health systems.
  - `onLibraryUpdate` / `onPlaylistUpdate` -- Debounced section/playlist sync triggers (3s / 5s)
  - `onArtworkInvalidation` -- Fires on album/artist metadata updates for cache eviction
  - `onServerOffline` / `onServerHealthy` -- Server health signal callbacks
  - `@Published serverScanProgress: [String: Int]` -- Per-server library scan progress (0-100) from activity events
- `SyncCoordinator` supports adjustable timer policy and incremental section-level sync triggered by WS events.
- `SyncCoordinator.rateTrack()` triggers debounced post-rating playlist sync (5s) for smart playlist freshness.
- `AppDelegate` starts/stops WebSocket connections on foreground/background transitions.

### Reactive Track Availability -- TrackAvailabilityResolver
- **`TrackAvailabilityResolver`** (`EnsembleCore`, @MainActor ObservableObject) -- Publishes per-track availability by combining per-server connection state with per-track download state.
- `TrackAvailability` enum: `.available`, `.availableDownloadedOnly`, `.unavailableServerOffline`, `.unavailableNetworkOffline`.
- `TrackRow`, `CompactSearchRows`, and `MediaTrackList` use the resolver instead of inline offline checks for consistent dimming/blocking behavior.
- Exposed via `DependencyContainer.trackAvailabilityResolver`.

### Two-Phase Stream Resolution
- **`StreamDecision`** / **`TranscodeStreamDecision`** (`EnsembleAPI`) -- Endpoint-independent streaming decisions that survive network transitions. Capture codec, quality, session params without the server base URL.
- **`PlexAPIClient.makeStreamDecision()`** -- Phase 1: Calls PMS `/decision` endpoint, returns `StreamDecision` (cacheable).
- **`PlexAPIClient.assembleStreamResolution()`** -- Phase 2: Reads freshest endpoint from `ServerConnectionRegistry`, builds `StreamResolution` with current URL. No network calls.
- **`PlaybackService.cachedStreamDecisions`** -- Decision cache keyed by trackId. On network transition, decisions persist while resolved URLs are evicted. Re-prefetch skips `/decision` call and only re-assembles URL.
- `resolveStreamURL()` remains as convenience that chains both phases (backward compat).

### Queue Resilience (PlaybackService)
- Circuit breaker scans for downloaded alternatives when server is unreachable.
- `retryCurrentTrack()` falls back to local download if available.
- Cache eviction for newly downloaded queue items so AVPlayer picks up fresh local files.
- Auto-resume playback when `ServerHealthChecker` completes a successful health check.

### Unified Error Taxonomy -- PlexErrorClassification
- **`PlexErrorClassification`** (`EnsembleAPI`) -- Classifies errors as transport (retryable/failover-eligible), rate-limited (retryable, no failover), or semantic (not retryable). HTTP 429 is classified as `.rateLimited`.
- `PlexAPIClient` uses `PlexErrorClassification` for failover gating instead of ad-hoc status code checks.
- `MutationCoordinator` uses it to decide which failed mutations to queue for retry vs. discard. `drainQueue()` applies exponential backoff (capped at 30s) after 2+ consecutive failures and breaks out after 5.

### Scrobble Queuing
- `MutationCoordinator` now queues failed scrobble calls as `CDPendingMutation` (`.scrobble` type).
- `SyncCoordinator` exposes `scrobbleTrackThrowing()` so `PlaybackService` can route scrobbles through the mutation coordinator.
- `PendingMutationsViewModel` and `PendingMutationsView` display queued scrobbles alongside playlist mutations.

### Foundation Layer (unchanged)
- **NetworkMonitor** -- `NWPathMonitor` with 1s debouncing, states: `.online`/`.offline`/`.limited`/`.unknown`
  - Lifecycle-safe restart behavior: `stopMonitoring()` cancels/releases the current monitor and `startMonitoring()` creates a new monitor instance.
- **SyncCoordinator** -- Transition-aware health orchestration for reconnects and interface switches
  - Coalesces concurrent health refresh requests.
  - Applies 30s cooldown and 60s app-foreground staleness threshold.
  - Limits checks to servers with at least one enabled library.
- **Plex endpoint policy layer** -- `PlexEndpointDescriptor` + `ConnectionSelectionPolicy` classify endpoints by locality/protocol/relay and order local-first with relay-last fallback.
- **Settings-driven insecure policy** -- `AllowInsecureConnectionsPolicy` is persisted in `SettingsManager` and applied when filtering endpoint candidates.
- **ConnectionFailoverManager** -- Policy-aware failover with preferred recent healthy endpoint fast-path and probe failure classification.
- **PlexAPIClient failover policy** -- Alternate endpoint probing is transport-only (no failover for HTTP semantic failures) and `refreshConnection()` returns a structured `ConnectionRefreshResult`.
- **ServerHealthChecker** -- Concurrent checks with per-server TTL caching (120s), forced refresh support, and failure taxonomy (`localOnlyReachable`, `remoteAccessUnavailable`, `relayUnavailable`, `tlsPolicyBlocked`, `offline`).
- **Resources discovery parity** -- resources requests include HTTPS/relay/IPv6 parameters plus common Plex client headers.
- **Auth lifecycle enforcement** -- `AccountManager` enforces auth migration cutover and token expiry checks on load/foreground.

### Dependency Flow
```
PlexWebSocketManager ──events──> PlexWebSocketCoordinator ──> SyncCoordinator (incremental section sync)
                                                          ──> ServerHealthChecker (probe triggers)
PlexAPIClient ──failover──> ServerConnectionRegistry <──writes── ServerHealthChecker
                                        |
                                        v
                               SyncCoordinator (subscribes to endpoint changes)
                                        |
                                        v
                            TrackAvailabilityResolver (server state + download state -> per-track availability)
                                        |
                                        v
                             TrackRow / CompactSearchRows / MediaTrackList (UI dimming/blocking)

PlaybackService ──makeStreamDecision──> SyncCoordinator ──> PlexMusicSourceSyncProvider ──> PlexAPIClient.makeStreamDecision()
PlaybackService ──assembleStream──> SyncCoordinator ──> PlexMusicSourceSyncProvider ──> PlexAPIClient.assembleStreamResolution()
                                                                                              └──> ServerConnectionRegistry (reads fresh endpoint)
PlaybackService.cachedStreamDecisions ── survives ──> network transitions (decisions are endpoint-independent)

PlaybackService ──scrobble──> MutationCoordinator ──(on failure)──> CDPendingMutation (.scrobble)
PlexAPIClient / MutationCoordinator ── use ──> PlexErrorClassification (transport vs. semantic)
```

**App Lifecycle:**
- iOS: Network monitor starts in `AppDelegate` (delayed 500ms)
- iOS: WebSocket connections start on foreground, stop on background (`AppDelegate`)
- Foreground network-health recovery routes through `SyncCoordinator.handleAppWillEnterForeground()` to avoid duplicate immediate + monitor-triggered checks
- macOS: Stops monitoring when backgrounded
- macOS active transition also routes through `SyncCoordinator.handleAppWillEnterForeground()`

## Subsystem: Customizable UI Settings

**SettingsManager** (`EnsembleCore/Services/SettingsManager.swift`):
- `AppAccentColor` enum: `.purple` (default), `.blue`, `.pink`, `.red`, `.orange`, `.yellow`, `.green`
- `TabItem` enum: 10 tabs, users can enable/disable via Settings
- Default enabled: Home, Artists, Playlists, Search
- `TrackSwipeAction` enum + `TrackSwipeLayout` model define 2 leading and 2 trailing swipe slots
- Layout is persisted in `@AppStorage` and sanitized to prevent duplicate action assignment

## Subsystem: Favorites

- `FavoritesViewModel` -- Filters tracks with `userRating >= 8.0` (4+ stars)
- Implements `MediaDetailViewModelProtocol` for consistency
- Reuses `MediaDetailView` for unified UI
- **Sort options:** `FavoritesSortOption` enum (title, artist, album, dateAdded, duration, lastPlayed, rating, playCount) with `defaultDirection` per option. Persisted via `FilterOptions.sortBy`. Tapping the active sort option toggles ascending/descending; tapping a new option uses its default direction.
- **Download target:** `.favorites` kind in `CDOfflineDownloadTarget.Kind` downloads all favorites across all libraries. `OfflineDownloadService.setFavoritesDownloadEnabled` manages the target; `reconcileFavoritesTargetIfEnabled` is called after source syncs and rating changes.
- **Post-rating reconciliation:** `SyncCoordinator.onFavoritesRatingChanged` closure fires with a 2s debounce after `rateTrack`, triggering `OfflineDownloadService.reconcileFavoritesTargetIfEnabled` so newly favorited tracks start downloading and unfavorited tracks are cleaned up.

## App Targets

- **Ensemble** (`Ensemble/Ensemble/`) -- iOS/iPadOS/macOS
  - `EnsembleApp.swift` -- Scene-based lifecycle with environment injection
  - `AppDelegate.swift` (iOS) -- AVAudioSession, remote commands, network monitoring

- **EnsembleWatch** (`Ensemble/EnsembleWatch/`) -- watchOS
  - `WatchRootView.swift` -- Consolidated views (auth, library, now playing)

## Subsystem: Playlist Mutations

Server-backed playlist mutations with automatic local cache refresh:

- `SyncCoordinator` orchestrates all mutations: `createPlaylist()`, `addTracksToPlaylist()`, `removeTrackFromPlaylist()`, `movePlaylistItem()`, `renamePlaylist()`
- Smart playlists are read-only; all mutations throw `PlaylistMutationError.smartPlaylistReadOnly`
- All successful mutations trigger server refresh + CoreData update for the affected source
- UI entry points: `PlaylistActionSheets.swift` (shared add/create sheet), `NowPlayingViewModel` (queue snapshot, add current track), `PlaylistViewModel` (rename, reorder, remove), `MediaTrackList` (per-track add)

## Subsystem: Gesture Actions

iOS/iPadOS gesture system for track swipe actions and long-press media actions:

- Track swipe actions are layout-driven from `SettingsManager.trackSwipeLayout` and shared across Songs/Favorites/Mood/Search/detail track lists
- SwiftUI track surfaces use `TrackSwipeContainer`; UIKit-backed detail lists use `MediaTrackList` `UIContextualAction` APIs
- `NowPlayingViewModel` exposes `setTrackFavorite(_:for:)` and `toggleTrackFavorite(_:)` for non-current track favorite mutations
- Album/artist/playlist cards and search rows expose `contextMenu` actions aligned with detail-view capabilities

## Subsystem: External Display (AirPlay Screen Mirroring)

Non-interactive Now Playing UI shown on an external display when the user activates AirPlay Screen Mirroring:

- `ExternalDisplaySceneDelegate` (app target) handles the `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene lifecycle — creates a `UIWindow` with a `UIHostingController` hosting the SwiftUI view
- `ExternalDisplayNowPlayingView` (EnsembleUI) is the TV-adapted variant of `NowPlayingViewportRoot` — two-column layout (ControlsCard + detail panel), dark-only, no interactive controls
- The external display observes the **same** `NowPlayingViewModel` instance as the main UI via `DependencyContainer.activeNowPlayingViewModel` — all state (playback, lyrics, queue, panel selection) stays in sync
- `AppDelegate.configurationForConnecting` routes the external display role to `ExternalDisplaySceneDelegate`; Stage Manager extended desktop uses the `windowApplication` role and is unaffected
- The Info.plist declares a `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene configuration
- **Important:** When adding a new card/panel to `NowPlayingViewportRoot` or `NowPlayingCarousel`, it must also be added to `ExternalDisplayNowPlayingView.detailPanel`

## Subsystem: Pinned Content

User-pinnable items (albums, artists, playlists) persisted across sessions:

- `PinnedItem` domain model records item type, ratingKey, sourceIdentifier, and sort order
- `PinnedViewModel` fetches `CDPinnedItem` records from CoreData and resolves them into full domain objects
- Persisted in CoreData via `CDPinnedItem` entity

## Subsystem: Sharing (song.link + Audio File)

Universal link and audio file sharing for tracks and albums:

1. **SongLinkService** (`EnsembleCore`, actor) -- Two-step resolution: searches Apple Music catalog via MusicKit `MusicCatalogSearchRequest` (no subscription needed), then passes the Apple Music URL to `song.link/v1-alpha.1/links` for a universal link. In-memory cache stores both positive and negative results.
2. **ShareService** (`EnsembleCore`, @MainActor) -- Coordinates share payloads:
   - Link sharing: song.link URL -> Apple Music URL -> plain text fallback
   - File sharing: local download path (if downloaded) or temp download via Plex universal stream URL
   - Temp files stored in `NSTemporaryDirectory()/EnsembleShare/`, cleaned after share sheet dismissal
3. **ShareSheetPresenter** (`EnsembleUI`) -- iOS 15-compatible `UIActivityViewController` wrapper with imperative presentation via topmost window scene. macOS uses `NSSharingServicePicker`.
4. **ShareActions** (`EnsembleUI`) -- Static namespace bridging `ShareService` -> share sheet, with toast feedback for download progress and text fallback.
5. **Context menu integration** -- "Share Link..." and "Share Audio File..." in `TrackRow`, `MediaTrackList`, and Now Playing ellipsis menu. "Share Link..." in `AlbumCard` context menu.
6. **Drag and drop (iPad)** -- `TrackRow.onDrag` and `MediaTrackList` `UITableViewDragDelegate` provide `NSItemProvider` with audio file URL for downloaded tracks.
7. **MusicKit configuration** -- `com.apple.developer.music-kit` entitlement + `NSAppleMusicUsageDescription` in Info.plist. `#if canImport(MusicKit)` guard for watchOS 8.

## Subsystem: Mood-Based Browsing

Plex mood/vibe categories for discovery:

- `Mood` domain model -- title and ratingKey from Plex API
- `MoodRepository` -- CoreData persistence via `CDMood` entity
- `MoodTracksView` (`EnsembleUI`) -- displays tracks for a selected mood

## Subsystem: Incremental Sync

Two sync modes to balance freshness and speed:

- **Full sync:** `SyncCoordinator.syncAll()` -- fetches entire library from Plex
- **Incremental sync:** `SyncCoordinator.syncAllIncremental()` -- uses `addedAt>=` / `updatedAt>=` Plex query params to fetch only new/changed items (with 5s timestamp buffer to avoid missing near-boundary changes)
- **Startup:** full sync if last sync >24h ago; incremental if >1h; skip if <1h
- **Periodic (foreground):** incremental library sync every 1h, hub refresh every 10min
- **Background (iOS):** `BackgroundSyncScheduler` registers `BGAppRefreshTask`; system triggers hub refresh approximately every 15min
- **Pull-to-refresh:** library views call incremental sync; `HomeView` refreshes hubs only
- **Key filtered fetch methods** in `PlexAPIClient`: `getArtists(sectionKey:addedAfter:)`, `getAlbums(sectionKey:addedAfter:)`, `getTracks(sectionKey:addedAfter:)`

## Subsystem: Instrumental Mode (Vocal Attenuation)

On-device vocal removal using Apple's AUSoundIsolation AudioUnit (same technology as Apple Music Sing). Uses hybrid engine switching:

1. **InstrumentalModeCapability** (`EnsembleCore`) -- Static probe for AUSoundIsolation AudioComponent availability. Returns true on iOS 16+ / A13+ devices.
2. **InstrumentalAudioEngine** (`EnsembleCore`) -- Isolated AVAudioEngine wrapper. Audio graph: `AVAudioPlayerNode -> AVAudioUnitEffect(AUSoundIsolation) -> mainMixerNode -> outputNode`. WetDryMix set to 100% for full vocal removal. Handles play/pause/seek/stop with frame-accurate time tracking via `playerNode.playerTime(forNodeTime:)`.
3. **PlaybackService Integration** -- Hybrid engine switching:
   - Toggle ON: captures AVQueuePlayer position, pauses it, creates InstrumentalAudioEngine, loads local file, plays from captured position
   - Toggle OFF: captures engine position, stops engine, seeks AVQueuePlayer to position, resumes
   - Track skip while active: stops engine, lets AVQueuePlayer load new track, re-engages engine
   - Queue injection: auto-disables instrumental mode (`play(tracks:)`, `shufflePlay(tracks:)`)
   - File resolution: uses `track.localFilePath` (downloaded), `streamLoader.localFileURL` (completed transcode), or defers until download completes
4. **NowPlayingViewModel** -- Published `isInstrumentalModeActive` and static `isInstrumentalModeSupported` for UI binding. `toggleInstrumentalMode()` action.
5. **LyricsCard** -- Toggle button in header (mic.circle / mic.slash.circle). Hidden on unsupported devices. Active color matches shuffle/repeat toggle pattern.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/InstrumentalModeCapability.swift`
- `Packages/EnsembleCore/Sources/Services/InstrumentalAudioEngine.swift`
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` (engine switching logic)
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift`
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift`

## Subsystem: Live Lyrics

Karaoke-style time-synced lyrics fetched from Plex and displayed in the Lyrics Card:

1. **LRCParser** (`EnsembleCore`, static) -- Parses LRC-format lyrics files into `LyricsLine` structs (timestamp + text). Also handles plain-text (unsynced) lyrics as a single block. Resides inside `LyricsService.swift`.

2. **LyricsService** (`EnsembleCore`, @MainActor ObservableObject) -- Orchestrates the full fetch pipeline for the current track:
   - **Cache check:** In-memory cache keyed by `ratingKey:sourceCompositeKey` (max ~20 entries, LRU eviction). Avoids redundant API calls on track revisit.
   - **Sidecar check:** Reads `.lrc` sidecar file alongside the audio download for offline lyrics (no network required).
   - **API fetch:** Calls `SyncCoordinator.apiClient(for:)` → `PlexAPIClient.getLyricsContent(streamKey:)` to fetch raw LRC text from `/library/streams/{streamKey}`.
   - Publishes `@Published lyricsState: LyricsState` (`.loading`, `.notAvailable`, `.available(ParsedLyrics)`).

3. **Models** -- `LyricsLine` (timestamp + text), `ParsedLyrics` (array of lines + synced flag), `LyricsState` (loading/notAvailable/available).

4. **NowPlayingViewModel Integration** -- Subscribes to `LyricsService.lyricsState` and `PlaybackService.currentTimePublisher`. Uses binary search on the lines array to publish `@Published currentLyricsLineIndex: Int?` for the active line.

5. **LyricsCard** (`EnsembleUI`) -- Displays one of three states:
   - **Loading:** progress spinner
   - **Not available:** centered "No Lyrics" message
   - **Available:** scrollable karaoke-style list where the active line is highlighted and auto-scrolled into center; past/future lines are dimmed

6. **Offline Sidecar** -- `OfflineDownloadService` generates a `.lrc` sidecar after downloading a track (if the track has a lyrics stream). `DownloadManager` cleans up `.lrc` sidecars when downloads are removed.

7. **API Accessor** -- `SyncCoordinator.apiClient(for:)` exposes the underlying `PlexAPIClient` for a given source, used by `LyricsService` to make direct lyrics content requests. `PlexMusicSourceSyncProvider.exposedAPIClient` provides the underlying client.

8. **PlexModels Extension** -- `PlexStream` gained lyrics fields (`format`, `key`, `streamKey`). `PlexTrack.lyricsStream` returns the first stream with `streamType == 4`.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/LyricsService.swift` - LRCParser, models, LyricsService
- `Packages/EnsembleCore/Tests/LyricsServiceTests.swift` - LRC parser tests
- `Packages/EnsembleAPI/Sources/Models/PlexModels.swift` - PlexStream lyrics fields, PlexTrack.lyricsStream
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - getLyricsContent(streamKey:)
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires LyricsService
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - lyricsState, currentLyricsLineIndex
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - apiClient(for:) accessor
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` - exposedAPIClient
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - .lrc sidecar generation
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - .lrc sidecar cleanup
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - three-state lyrics display

**Known limitation:** The `/library/streams/` endpoint occasionally returns 404 for tracks that report a valid `lyricsStream`. See Known Issues.

## Subsystem: Playlist Merging

Visually merges same-named playlists across multiple Plex servers into a single entry:

- `DisplayPlaylist` (`EnsembleCore`) -- Wrapper that holds one or more `Playlist` objects. Single-source playlists pass through; multi-source playlists are presented as merged.
- `PlaylistViewModel` groups playlists via Combine pipeline: `$filteredPlaylists` + `$isMergeEnabled` → `$displayPlaylists`. Toggle state sourced from `SettingsManager.playlistMergeEnabled`.
- `MergedPlaylistDetailViewModel` handles the merged detail view, including bulk rename and delete across constituent playlists.
- `MergedPlaylistDetailView` / `MergedPlaylistDetailLoader` (`EnsembleUI`) -- Detail UI and async loading wrapper for merged playlists.
- Track ordering: interleaved round-robin from constituent playlists.
- `PlaylistRowChip` (`EnsembleUI`) -- Visual indicator for multi-source merged playlists.
- Navigation: `NavigationCoordinator.Destination.mergedPlaylist` and `SidebarSelection.mergedPlaylist` provide routing support.

## Subsystem: Persistent Session Logging

Real-time dual-write logging for TestFlight diagnostics. Each `EnsembleLogger` method writes to both `os.log` and a session file via a static `fileLogHandler` closure so debug-level traces remain available in release/TestFlight builds. `PersistentLogService` (in EnsembleCore) owns the `LogFileWriter` which serializes file I/O on a private `DispatchQueue`. Session files are stored at `Library/Application Support/Ensemble/Logs/`. Handlers for Core/API/Persistence loggers are wired in `DependencyContainer`; UI and App loggers are wired in `EnsembleApp` on first activation.

- **Key types:** `PersistentLogService`, `LogFileWriter` (private), `LogSession`
- **Key files:** `PersistentLogService.swift`, all `EnsembleLogger.swift` files, `DependencyContainer.swift`, `EnsembleApp.swift`

## Subsystem: User Profile & CloudKit Sync

User-editable profile (display name, profile image) with iCloud private database sync:

1. **UserProfile** (`EnsembleCore/Models`) -- Data model with `displayName`, `profileImagePath`, and `lastModified` fields.
2. **UserProfileStore** (`EnsembleCore/Services`, @MainActor ObservableObject) -- Local profile persistence and image processing. Publishes the current profile for UI binding.
3. **CloudSyncService** (`EnsembleCore/Services`, actor) -- CloudKit private database sync using container `iCloud.com.videogorl.ensemble`, record type `UserProfile`. Supports push, pull, subscription setup, silent-push delivery handling, and foreground recovery refresh. Prefers CloudKit server `modificationDate` when ordering pulled profile changes, and exposes transport state (`available`, `notAuthenticated`, `networkUnavailable`, etc.) so profile sync can degrade independently from KVS-backed features.
4. **ProfileView** (`EnsembleUI/Screens`) -- Full profile screen replacing the previous SettingsView content. Settings are migrated into ProfileView; SettingsView redirects here.
5. **ProfileHeaderView** (`EnsembleUI/Components`) -- Circular profile image + display name header with photo picker integration.
6. **ProfileToolbarButton** (`EnsembleUI/Components`) -- 28×28pt circular profile image button rendered by `MainTabView` on iPhone root tab destinations and by the sidebar toolbar on iPad/macOS.
7. **Navigation change:** `AuxiliaryPresentation.settings` renamed to `.profile`; `openSettings()` renamed to `openProfile()` (legacy alias kept for backward compatibility).
8. **DependencyContainer** wires `UserProfileStore` and `CloudSyncService` as singleton services and triggers a foreground profile reconcile path on iOS/macOS activation so missed silent pushes self-heal quickly.

- **Key types:** `UserProfile`, `UserProfileStore`, `CloudSyncService`
- **Key files:** `UserProfile.swift`, `UserProfileStore.swift`, `CloudSyncService.swift`, `ProfileView.swift`, `ProfileHeaderView.swift`, `ProfileToolbarButton.swift`, `DependencyContainer.swift`

## Subsystem: iCloud Sync (Phase 2 — KVS + Keychain)

Hybrid sync architecture for cross-device settings and credential sharing:

```
┌──────────────────────────────────────────────────────┐
│  iCloud Sync Mechanisms                              │
├──────────────┬──────────────────┬─────────────────────┤
│  KVS         │  iCloud Keychain │  CloudKit           │
│  (small data)│  (credentials)   │  (profile)          │
├──────────────┼──────────────────┼─────────────────────┤
│ Accent color │ Plex tokens      │ Display name        │
│ Swipe layout │ Server URLs      │ Profile image       │
│ Pins         │ Account IDs      │                     │
│ Library flags│                  │                     │
└──────────────┴──────────────────┴─────────────────────┘
```

**Sync mechanisms:**
1. **KVS (`KVSSyncService`)** — `NSUbiquitousKeyValueStore` wrapper for small settings. Push/pull/observe with echo-loop suppression (1s window after pushing). Tracks whether initial iCloud KVS delivery has actually settled so bootstrap code can defer seeding local defaults until remote absence is authoritative. Each KVS key maps to a feature toggle in `SyncSettingsManager`. Library flags are encoded in canonical sorted order so identical state does not generate false remote changes from dictionary key reordering.
2. **iCloud Keychain (`KeychainService`)** — Synchronizable keychain items for Plex credentials. Uses `saveSynchronizable`/`getSynchronizable`/`deleteSynchronizable` APIs with `KeychainKey.plexAccountsSync`. No live observer exists, so `DependencyContainer` runs a foreground reconciliation pass that re-checks synced credentials and discovers any newly arrived accounts.
3. **CloudKit (`CloudSyncService`)** — Private database sync for user profile (existing, see User Profile subsystem).

**Key behaviors:**
- **Dependency cascade:** Libraries toggle auto-disables when Sources is turned off.
- **Bootstrap flow:** `DependencyContainer` owns a shared per-feature bootstrap path (`accentColor`, `swipeActions`, `pins`, `sources`, `libraries`). On first iCloud connection or feature re-enable, existing cloud state wins. KVS-backed features now wait for authoritative initial-sync settlement before treating `nil` as "remote absent"; only then do they seed local state.
- **Runtime feature state:** `SyncSettingsManager` tracks in-memory per-feature state (`idle`, `bootstrapping`, `appliedRemote`, `seededLocal`, `waitingForTransport`, `transportUnavailable`, `error`). `hasCompletedFirstConnect` is now only set once all enabled features have settled into a terminal state instead of being marked optimistically at launch.
- **Ongoing updates:** Local edits push their latest full snapshot; other devices apply the remote snapshot when it changes.
- **Pins:** Remote pin sync is snapshot-based, not union-based, so pin deletions and reorderings propagate across devices.

**Sync settings toggles (per-device, UserDefaults):**
- `sources` — account credentials via iCloud Keychain
- `libraries` — library enabled/disabled flags (depends on `sources`)
- `pins` — pinned content
- `accentColor` — app accent color
- `swipeActions` — track swipe action layout

- **Key types:** `SyncSettingsManager`, `KVSSyncService`, `SyncableAccountCredential`, `SyncableServerCredential`, `SyncableLibraryRef`
- **Key files:** `SyncSettingsManager.swift`, `KVSSyncService.swift`, `SyncSettingsView.swift`, `DependencyContainer.swift`, `AccountManager.swift`, `KeychainService.swift`, `PlexAccountConfig.swift`, `PinnedItem.swift`

## Multi-Source Architecture

When adding new music sources:
1. Create provider implementing `MusicSourceSyncProvider` protocol
2. Add source type to `MusicSourceType` enum
3. Register provider in `SyncCoordinator.refreshProviders()`
4. Add account configuration model similar to `PlexAccountConfig`
5. Update `AccountManager` to handle new account type
