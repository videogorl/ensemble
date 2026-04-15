---
name: project-structure
description: "Load when locating files, deciding where a new file belongs, or verifying what already exists. Full file trees for all packages and targets."
---

# Ensemble Project Structure

## Root Layout

```
ensemble/
+-- Ensemble.xcworkspace          # Main workspace (always use this, not .xcodeproj)
+-- Ensemble.xcodeproj             # Xcode project file
+-- CLAUDE.md                      # Agent instructions
+-- README.md                      # User-facing documentation
+-- .claude/skills/                # Project-specific agent skills and bundled helper scripts
|   +-- trace-analysis/            # Instruments .trace export + correlation workflow
+-- scripts/
|   +-- compile_coredata_model.sh # Compiles SwiftPM CoreData model bundle for package tests
|   +-- verify_package_baseline.sh # Rebuilds the SwiftPM CoreData bundle, then runs package tests with pass/fail summary
|   +-- capture_runtime_baseline.sh # Captures or summarizes repeatable simulator/runtime baselines (OS log + persistent log + optional trace)
|   +-- plex_hls_spike.sh        # Bounded PMS music-HLS viability probe used before transport changes
|   +-- update_build_number.sh    # Sets deterministic CFBundleVersion for app + Siri extension builds
|
+-- docs/
|   +-- investigations/
|       +-- 2026-04-03-plex-hls-spike.md # Written verdict from the PMS music-HLS spike
|       +-- 2026-04-14-repo-audit-baseline.md # Ranked audit findings + baseline verification notes
|
+-- Ensemble/                      # Main app target (iOS/iPadOS/macOS)
|   +-- App/
|   |   +-- EnsembleApp.swift     # App entry point
|   |   +-- AppDelegate.swift     # Audio session & background playback config
|   |   +-- ExternalDisplaySceneDelegate.swift # UIWindowSceneDelegate for AirPlay screen mirroring external display
|   |   +-- EnsembleAppShortcuts.swift # App Intents fallback entities/phrases for Siri album/playlist playback
|   +-- Resources/
|   |   +-- Assets.xcassets       # App icons, colors, images
|   +-- Info.plist
|   +-- Ensemble.entitlements     # App entitlements (Siri + shared App Group)
|
+-- EnsembleSiriIntentsExtension/  # SiriKit Media Intents extension target
|   +-- IntentHandler.swift        # Extension entry point for intent handlers
|   +-- PlayMediaIntentHandler.swift # INPlayMediaIntentHandling implementation
|   +-- Info.plist                 # Intents extension configuration
|   +-- EnsembleSiriIntentsExtension.entitlements # Extension entitlements (Siri + shared App Group)
|
+-- EnsembleWatch/                 # watchOS app target
|   +-- App/
|   |   +-- EnsembleWatchApp.swift
|   +-- Views/
|   |   +-- WatchRootView.swift   # All watchOS views (auth, library, now playing)
|   +-- Resources/
|   |   +-- Assets.xcassets
|   +-- Info.plist
|
+-- Packages/                      # Swift Package modules
    +-- EnsembleAPI/              # Layer 1: Networking
    +-- EnsemblePersistence/      # Layer 1: Data persistence
    +-- EnsembleCore/             # Layer 2: Business logic
    +-- EnsembleUI/               # Layer 3: User interface
```

## EnsembleAPI (Networking Layer)

```
Sources/
+-- Auth/
|   +-- KeychainService.swift          # Secure token storage wrapper + synchronizable iCloud Keychain support (saveSynchronizable/getSynchronizable/deleteSynchronizable)
|   +-- PlexAuthService.swift          # PIN-based OAuth flow (actor)
|   +-- PlexAuthTokenMetadata.swift    # JWT metadata parsing/helpers (iat/exp)
+-- Client/
|   +-- PlexConnectionPolicy.swift     # Endpoint descriptors, routing policies, refresh/probe result models
|   +-- PlexAPIClient.swift            # HTTP client for Plex API (actor)
|   +-- PlexErrorClassification.swift  # Unified error taxonomy for failover/retry decisions
|   +-- PlexWebSocketManager.swift     # Per-server WebSocket connections with exponential backoff (actor)
|   +-- ServerConnectionRegistry.swift # Single source of truth for per-server endpoints (actor)
|   +-- ConnectionFailoverManager.swift # Server connection resilience
|   +-- AudioFormatConverter.swift      # MP3→CAF conversion for zero-gap gapless playback
|   +-- MP3VBRHeaderUtility.swift      # XING VBR header injection for transcoded MP3 files
+-- Models/
|   +-- PlexModels.swift               # API response models (Plex*)
+-- EnsembleLogger.swift               # Package logger categories
+-- EnsembleAPI.swift                   # Public exports

Tests/
+-- PlexAPIClientTests.swift
+-- ConnectionFailoverManagerTests.swift
+-- PlexResourcesSpecTests.swift
+-- PlexAPIClientFailoverPolicyTests.swift
+-- PlexAuthTokenLifecycleTests.swift
```

## EnsemblePersistence (Data Layer)

```
Sources/
+-- CoreData/
|   +-- Ensemble.xcdatamodeld          # CoreData schema
|   +-- Compiled/SwiftPMEnsemble.momd # Precompiled model copy used by SwiftPM tests; refreshed by verify_package_baseline.sh
|   +-- CoreDataStack.swift            # Singleton stack with background contexts
|   +-- ManagedObjects.swift           # NSManagedObject subclasses (CD* prefix)
+-- Downloads/
|   +-- DownloadManager.swift          # Track download queue & file storage
|   +-- OfflineDownloadTargetRepository.swift # Offline target + membership persistence
|   +-- ArtworkDownloadManager.swift   # Image caching
+-- Repositories/
|   +-- LibraryRepository.swift        # CRUD for artists, albums, tracks, genres
|   +-- PlaylistRepository.swift       # CRUD for playlists
+-- EnsembleLogger.swift               # Package logger categories
+-- EnsemblePersistence.swift          # Public exports

Tests/
+-- LibraryRepositoryTests.swift
+-- PlaylistRepositoryTests.swift
+-- DownloadManagerTests.swift
+-- OfflineDownloadTargetRepositoryTests.swift
```

## EnsembleCore (Business Logic Layer)

```
Sources/
+-- DI/
|   +-- DependencyContainer.swift      # Singleton DI container & VM factories
+-- Models/
|   +-- DisplayPlaylist.swift          # Merge-aware playlist wrapper (single or multi-server merged)
|   +-- DomainModels.swift             # UI-facing models (Track, Album, Artist, Hub, etc.)
|   +-- ModelMappers.swift             # CD* <-> Domain model conversions
|   +-- MusicSource.swift              # Multi-account source identification
|   +-- PlexAccountConfig.swift        # Account/server/library configuration + SyncableAccountCredential, SyncableServerCredential, SyncableLibraryRef models
|   +-- SiriIntentPayload.swift        # Siri extension->app payload codec + schema
|   +-- SiriMediaIndex.swift           # Siri media index model used by extension lookup
|   +-- LibraryVisibilityProfile.swift # Source visibility profile model (non-sync filtering)
|   +-- ConnectionPolicy.swift         # Core-level aliases/UI labels for API connection policy types
|   +-- FilterOptions.swift            # Filter/sort configuration with persistence
|   +-- NetworkModels.swift            # Network state & connectivity models
|   +-- PinnedItem.swift               # Pinned content model (albums, artists, playlists) + applyRemotePins merge + exportPinsData + updateTitle
|   +-- UserProfile.swift              # Profile data model (displayName, profileImagePath, lastModified)
+-- Services/
|   +-- AccountManager.swift           # Multi-account configuration (MainActor) + pushSyncCredentials/pullSyncCredentials/exportLibraryFlags/applyLibraryFlags
|   +-- PlexAccountDiscoveryService.swift # Discovers account identity + normalized server/library inventory for add-account and reconciliation flows
|   +-- LocalNetworkPermissionProbe.swift # Local-network permission prompt helper used during account onboarding
|   +-- SyncCoordinator.swift          # Multi-source sync orchestration (MainActor)
|   +-- PlaylistMutationController.swift # Playlist create/rename/delete/replace control-flow seam extracted from SyncCoordinator
|   +-- SyncExecutionController.swift  # Full/incremental/startup sync execution seam extracted from SyncCoordinator
|   +-- RefreshOrchestrator.swift      # Health-refresh gating, cooldown/staleness policy, and startup-health ownership extracted from SyncCoordinator
|   +-- NetworkLifecycleController.swift # App-foreground and network-transition policy extracted from SyncCoordinator
|   +-- PeriodicSyncController.swift   # Foreground periodic-sync timer scheduling + WebSocket-aware interval policy extracted from SyncCoordinator
|   +-- PlaylistRefreshController.swift # Server-scoped playlist refresh orchestration extracted from SyncCoordinator
|   +-- WebSocketSyncController.swift  # WebSocket-triggered section resolution + playlist refresh routing extracted from SyncCoordinator
|   +-- MusicSourceSyncProvider.swift  # Protocol for source-specific sync
|   +-- PlexMusicSourceSyncProvider.swift # Plex implementation of sync protocol
|   +-- NavigationCoordinator.swift    # Centralized navigation state management (MainActor)
|   +-- PlaybackService.swift          # AVPlayer wrapper with queue/shuffle/repeat
|   +-- AudioPlaybackEngine.swift      # Gapless local-file playback engine with route recovery and instrumental mode support
|   +-- PlaybackHandoffCoordinator.swift # Disconnect/interruption/remote-command handoff reducer extracted from PlaybackService
|   +-- PlaybackQueueStore.swift       # Queue/history restoration persistence extracted from PlaybackService
|   +-- PlaybackQueueController.swift  # Queue/history mutation + queue snapshot persistence extracted from PlaybackService
|   +-- PlaybackLaunchCoordinator.swift # Successful playback launch path (visualizer load, engine start, recovery seek, prefetch) extracted from PlaybackService
|   +-- PlaybackRecoveryPolicy.swift   # Buffering/stall-recovery policy extracted from PlaybackService
|   +-- PlaybackSessionStateMachine.swift # Playback session request/retry/failure policy extracted from PlaybackService
|   +-- PlaybackPrefetchController.swift # Resolved-file URL cache + stream-cache cleanup policy extracted from PlaybackService
|   +-- PlaybackNowPlayingBridge.swift # Lock-screen metadata + remote-command wiring extracted from PlaybackService
|   +-- PlaybackTransportCoordinator.swift # Stream/local transport resolution + progressive-loader cache extracted from PlaybackService
|   +-- ProgressiveStreamLoader.swift  # AVAssetResourceLoaderDelegate bridge for chunked transcode streams
|   +-- ArtworkLoader.swift            # Persistent artwork caching & loading
|   +-- CacheManager.swift             # Cache size tracking & management (MainActor)
|   +-- NetworkMonitor.swift           # Network connectivity monitoring (NWPathMonitor)
|   +-- ServerHealthChecker.swift      # Concurrent server health checks
|   +-- ServerConnectionController.swift # Registry subscription + API-client endpoint synchronization extracted from SyncCoordinator
|   +-- SettingsManager.swift          # App settings (accent colors, customizable tabs)
|   +-- HubRepository.swift            # Hub data persistence (CDHub/CDHubItem)
|   +-- HubOrderManager.swift          # User-customizable hub section ordering
|   +-- BackgroundSyncScheduler.swift  # iOS BGAppRefreshTask scheduling for background sync
|   +-- OfflineDownloadService.swift   # Target-based offline queue, reconciliation, progress tracking, and healing orchestration
|   +-- DownloadQueueCoordinator.swift # Sole owner of offline queue task lifecycle and worker orchestration
|   +-- OfflineDownloadCleanupCoordinator.swift # Best-effort orphaned-download cleanup for completed files that no longer have any offline target membership
|   +-- DownloadRetryPolicy.swift      # Stateful offline retry and direct-fallback policy
|   +-- DownloadTargetReconciler.swift # Membership resolution and orphan cleanup for offline targets
|   +-- DownloadTransferExecutor.swift # Direct-download/download-queue transfer pipeline, validation, recovery, and post-completion side effects extracted from OfflineDownloadService
|   +-- OfflineDownloadNotificationBridge.swift # Debounced downloadsDidChange fan-out + queue completion toast seam extracted from OfflineDownloadService
|   +-- OfflineBackgroundExecutionCoordinator.swift # Optional iOS 26+ BG continued-processing adapter
|   +-- MoodRepository.swift           # Mood data persistence (CDMood)
|   +-- LibraryVisibilityStore.swift   # Persisted visibility profiles + active profile state
|   +-- SiriMediaIndexStore.swift      # Shared App Group Siri index persistence/rebuild hooks
|   +-- SiriPlaybackCoordinator.swift  # In-app Siri play intent execution (track/album/artist/playlist)
|   +-- QueueManager.swift             # Queue management (extracted from PlaybackService)
|   +-- ToastCenter.swift              # App-wide toast notification coordination (MainActor)
|   +-- PlexRadioProvider.swift        # Plex Radio support implementing RadioProvider protocol
|   +-- PlexWebSocketCoordinator.swift # Routes WebSocket events to sync/health systems (@MainActor)
|   +-- RadioProvider.swift            # Protocol for radio/station providers
|   +-- TrackAvailabilityResolver.swift # Reactive per-server+per-download track availability (@MainActor ObservableObject)
|   +-- AudioAnalyzer.swift            # Pre-computed frequency analysis (FrequencyTimeline, FrequencyAnalysisService, FrequencyTimelinePersistence)
|   +-- InstrumentalModeCapability.swift # Static AUSoundIsolation availability probe (iOS 16+ / A13+)
|   +-- InstrumentalAudioEngine.swift  # AVAudioEngine wrapper with AUSoundIsolation for vocal attenuation
|   +-- PowerStateMonitor.swift        # Low Power Mode observer; publishes isLowPowerMode for GPU/network throttling (@MainActor ObservableObject)
|   +-- SongLinkService.swift          # Universal song.link URL resolution via MusicKit + song.link API
|   +-- ShareService.swift             # Share payload coordinator (link/file/text) with temp download support
|   +-- LyricsService.swift            # LRC parser, lyrics models (LyricsLine/ParsedLyrics/LyricsState), LyricsService fetch pipeline + offline sidecar
|   +-- MutationCoordinator.swift      # Unified online/offline mutation queue for ratings, playlists, and scrobbles
|   +-- MetadataMutationService.swift  # Metadata edit coordination + invalidation notifications for UI refresh
|   +-- PersistentLogService.swift     # Persistent session logging with real-time file writes for TestFlight diagnostics
|   +-- SiriAffinityCoordinator.swift  # In-app Siri love/dislike coordinator using the playback + mutation services
|   +-- SiriAddToPlaylistCoordinator.swift # In-app Siri add-to-playlist coordinator with optimistic queueing
|   +-- SiriMediaUserContextManager.swift # Persists recency/context hints that improve Siri media ranking
|   +-- UserProfileStore.swift        # @MainActor ObservableObject for local profile persistence + image processing
|   +-- CloudSyncService.swift        # CloudKit actor for private database sync (push/pull/subscribe)
|   +-- SyncSettingsManager.swift    # Master + per-feature iCloud sync toggles (UserDefaults, per-device)
|   +-- KVSSyncService.swift         # NSUbiquitousKeyValueStore wrapper for iCloud KVS sync (push/pull/observe, echo-loop suppression)
+-- EnsembleLogger.swift               # Package logger categories
+-- ViewModels/
|   +-- AddPlexAccountViewModel.swift
|   +-- AlbumDetailViewModel.swift
|   +-- ArtistDetailViewModel.swift
|   +-- DownloadsViewModel.swift
|   +-- FavoritesViewModel.swift       # Tracks rated 4+ stars, sorting (FavoritesSortOption), download toggle
|   +-- HomeViewModel.swift            # Hub-based home screen (Recently Added, etc.)
|   +-- LibraryViewModel.swift
|   +-- MergedPlaylistDetailViewModel.swift # ViewModel for merged playlist detail (interleaved tracks, rename/delete all)
|   +-- MusicSourceAccountDetailViewModel.swift
|   +-- NowPlayingViewModel.swift
|   +-- DownloadManagerSettingsViewModel.swift # Settings manager list for offline targets
|   +-- DownloadTargetDetailViewModel.swift # Per-track detail for a single download target
|   +-- LibraryDownloadDetailViewModel.swift # All downloads for a library (by sourceCompositeKey)
|   +-- OfflineServersViewModel.swift  # Server-grouped sync-enabled library toggles for offline targets
|   +-- PendingMutationsViewModel.swift # Offline-queued mutations (pending/failed playlist & track changes)
|   +-- PinnedViewModel.swift          # Resolves PinnedItem references into domain objects
|   +-- PlaylistViewModel.swift
|   +-- SearchViewModel.swift
+-- EnsembleCore.swift                 # Public exports

Tests/
+-- PlaybackServiceTests.swift
+-- PlaybackHandoffCoordinatorTests.swift
+-- PlaybackRecoveryPolicyTests.swift
+-- PlaybackLaunchCoordinatorTests.swift
+-- PlaybackSessionStateMachineTests.swift
+-- PlaybackTransportCoordinatorTests.swift
+-- PlaybackQueueStoreTests.swift
+-- NetworkMonitorTests.swift
+-- SyncCoordinatorNetworkHealthTests.swift
+-- RefreshOrchestratorTests.swift # Health-refresh coalescing, cooldown/staleness gating, and startup ownership coverage
+-- NetworkLifecycleControllerTests.swift # Foreground and network-transition policy coverage for SyncCoordinator lifecycle decisions
+-- PeriodicSyncControllerTests.swift # Foreground timer scheduling and WebSocket-aware interval coverage
+-- PlaylistRefreshControllerTests.swift # Server playlist refresh fallback and trigger-policy coverage
+-- WebSocketSyncControllerTests.swift # WebSocket section resolution and playlist refresh routing coverage
+-- ServerConnectionControllerTests.swift # Registry-update processing and API-client endpoint synchronization coverage
+-- PlexWebSocketCoordinatorTests.swift # Aggregate WebSocket availability callback coverage
+-- OfflineDownloadServicePolicyTests.swift # Playback/background download work-mode policy coverage
+-- DownloadQueueCoordinatorTests.swift # Queue lifecycle ownership, background wakeup, and restart coverage
+-- DownloadRetryPolicyTests.swift # Transfer retry accounting and direct-fallback gating coverage
+-- DownloadTargetReconcilerTests.swift # Target membership resolution and orphan cleanup coverage
+-- DownloadTransferExecutorTests.swift # Direct-download/download-queue transfer execution and fallback coverage
+-- OfflineDownloadNotificationBridgeTests.swift # Debounced downloadsDidChange fan-out and toast routing coverage
+-- OfflineDownloadCleanupCoordinatorTests.swift # Orphaned completed-download sweep coverage
+-- HomeViewModelRefreshPolicyTests.swift
+-- ServerHealthCheckerClassificationTests.swift
+-- SettingsManagerConnectionPolicyTests.swift
+-- AccountManagerAuthPolicyTests.swift
+-- AccountManagerLibrarySyncTests.swift
+-- SearchSectionOrderingTests.swift   # Deterministic search section tie-break ordering
+-- LibraryVisibilityProfileTests.swift # Visibility profile persistence + filtering seams
+-- SiriIntentPayloadTests.swift       # Siri payload serialization + userInfo contract
+-- SiriPlaybackCoordinatorTests.swift # In-app Siri playback execution coverage
+-- SongLinkServiceTests.swift         # Song.link URL resolution + caching + fallback tests
+-- ShareServiceTests.swift            # Share payload assembly + file detection tests
+-- LyricsServiceTests.swift           # LRC parser timestamp parsing + line lookup coverage
+-- UserProfileTests.swift            # Unit tests for UserProfile model
+-- SyncSettingsManagerTests.swift    # Unit tests for SyncSettingsManager toggle logic + dependency cascade
+-- PinManagerSyncTests.swift         # Unit tests for PinManager merge logic (union, remote-wins conflict)
```

## EnsembleUI (Presentation Layer)

```
Sources/
+-- Components/
|   +-- NowPlaying/
|   |   +-- ControlsCard.swift        # Center card with artwork, scrubber, playback controls
|   |   +-- InfoCard.swift            # Track metadata and streaming/connection details card
|   |   +-- LyricsCard.swift          # Lyrics display card: loading / not-available / karaoke-style timed line highlight
|   |   +-- NowPlayingCarousel.swift  # Horizontal paging carousel for all cards
|   |   +-- PageIndicator.swift       # Page dots/icons for carousel navigation
|   |   +-- QueueCard.swift           # Queue list with shuffle/repeat/autoplay controls
|   +-- AirPlayButton.swift           # AVRoutePickerView wrapper for AirPlay
|   +-- AlbumCard.swift               # Grid card for albums
|   +-- AlbumDetailLoader.swift       # Async loader for album detail with loading/error states
|   +-- ArtistCard.swift              # Grid card for artists
|   +-- ArtistDetailLoader.swift      # Async loader for artist detail with loading/error states
|   +-- ArtworkColorExtractor.swift   # Actor-based color extraction from artwork for dynamic gradients
|   +-- ArtworkDetailBackground.swift # Shared detail-screen blurred artwork + overlay treatment used by MediaDetailView and download detail screens
|   +-- ArtworkView.swift             # Lazy-loading artwork with Nuke
|   +-- CompositeArtworkView.swift    # Composite 2x2 artwork grid for merged playlists + PlaylistArtwork wrapper
|   +-- AuroraVisualizationView.swift # Aurora-style background visualization of music loudness
|   +-- BlurredArtworkBackground.swift # Heavily blurred artwork background with contrast/saturation
|   +-- CollapsingToolbar.swift      # Shared collapsing toolbar title with nav bar appearance toggle
|   +-- ChromeVisibilityPreferenceKey.swift # SwiftUI preference key for hiding tab bar in immersive views
|   +-- CompactSearchRows.swift       # Compact row layouts for search results
|   +-- DesktopSheetScaffold.swift    # Shared macOS sheet scaffold with title bar and footer actions
|   +-- OfflineIndicatorOverlay.swift  # Device-aware offline connectivity indicator (DI/notch/classic)
|   +-- SongsStageFlowAlbum.swift     # Builds StageFlow album cards from filtered song results
|   +-- StageFlowView.swift           # Center-stage carousel with snapping and transport overlay
|   +-- StageFlowItemView.swift       # Individual card used in StageFlow
|   +-- StageFlowTrackPanel.swift     # Slide-out track panel for centered StageFlow items
|   +-- EmptyLibraryView.swift        # Empty state with sync prompt
|   +-- FilterSheet.swift             # Advanced filtering UI with persistence
|   +-- FlipOpacity.swift             # View modifier for flip animations
|   +-- GenreCard.swift               # Grid card for genres
|   +-- GenreChipBar.swift            # Horizontal scrollable genre filter chips (OR multi-select)
|   +-- HubOrderingSheet.swift        # Sheet for reordering hub sections with drag & drop
|   +-- KeyboardObserver.swift        # iOS-specific keyboard height tracking with view modifier
|   +-- MarqueeText.swift             # Auto-scrolling text component for long titles
|   +-- MediaContextMenus.swift       # Shared album/artist/playlist/merged-playlist context menu actions for grids, search, and sidebar pins
|   +-- MediaTrackList.swift          # Reusable track list with context menu
|   +-- MiniPlayer.swift              # Compact persistent player overlay
|   +-- ExternalDisplayNowPlayingView.swift # Non-interactive Now Playing for AirPlay screen mirroring (TV)
|   +-- NowPlayingViewportRoot.swift  # Dedicated iPad/macOS Now Playing root + macOS window chrome bridge
|   +-- PendingChangesRow.swift        # Shared row for pending mutations (used in Downloads + Source Detail)
|   +-- PlaylistActionSheets.swift    # Shared add-to-playlist and create-playlist UI sheets
|   +-- ShareSheet.swift              # iOS 15-compatible UIActivityViewController / NSSharingServicePicker wrapper
|   +-- ShareActions.swift            # Static helpers bridging ShareService payloads to share sheet presentation
|   +-- PlaylistCard.swift            # Grid card for playlists
|   +-- PlaylistDetailLoader.swift    # Async loader for playlist detail with loading/error states
|   +-- QueueTableView.swift          # UIKit-backed drag-to-reorder table view for queue
|   +-- ScrollIndex.swift             # A-Z index for fast scrolling
|   +-- ToastView.swift               # Toast notification overlay component
|   +-- TrackRow.swift                # Single track row with artwork
|   +-- TrackListLayoutMetrics.swift  # Shared row spacing, separator insets, and mini-player clearance tokens
|   +-- TrackRowInteractionModel.swift # Shared per-track action/favorite/recent-playlist resolver for SwiftUI + UIKit rows
|   +-- TrackSwipeContainer.swift     # Shared swipe gesture container for track row actions on large-screen + iOS
|   +-- ProfileHeaderView.swift      # Circular profile image + name header with photo picker
|   +-- ProfileToolbarButton.swift   # 28×28pt toolbar profile button for all top-level views
|   +-- View+Extensions.swift         # SwiftUI view extensions and helpers
|   +-- WaveformView.swift            # Audio waveform visualization
+-- Screens/
|   +-- AddPlexAccountView.swift      # Account setup flow
|   +-- AlbumsView.swift              # Album grid
|   +-- ArtistsView.swift             # Artist grid
|   +-- AuxiliaryPresentationContainer.swift # Shared Settings/Downloads modal+window root wrappers
|   +-- DownloadsView.swift           # Offline downloads
|   +-- FavoritesView.swift           # Tracks rated 4+ stars
|   +-- GenresView.swift              # Genre browsing
|   +-- HomeView.swift                # Hub-based home screen (Recently Added, etc.)
|   +-- MainTabView.swift             # iPhone tab bar
|   +-- MediaDetailView.swift         # Artist/Album/Playlist detail (adaptive, protocol-based)
|   +-- MergedPlaylistDetailView.swift # Detail view + loader for merged playlists (source servers, edit picker)
|   +-- MoodTracksView.swift          # Track list for a specific Plex mood/vibe category
|   +-- MoreView.swift                # Additional options
|   +-- NowPlayingView.swift          # Full-screen player
|   +-- PendingMutationsView.swift    # Offline-queued mutations (pending/failed playlist & track changes)
|   +-- PlaylistsView.swift           # Playlist grid
|   +-- DownloadManagerSettingsView.swift # Settings-only offline manager (quality, cellular toggle, remove all)
|   +-- DownloadTargetDetailView.swift # Per-track detail for album/artist/playlist download target
|   +-- LibraryDownloadDetailView.swift # All downloaded tracks in a library (by sourceCompositeKey)
|   +-- OfflineServersView.swift      # (Legacy) Server-grouped sync-enabled library toggles
|   +-- RootView.swift                # Platform-adaptive root (tabs vs sidebar)
|   +-- SearchView.swift              # Search interface
|   +-- ProfileView.swift             # Full profile view (replaces SettingsView content; includes all settings)
|   +-- SettingsView.swift            # Legacy redirect to ProfileView
|   +-- SyncSettingsView.swift       # Toggle UI for iCloud sync features (shown in ProfileView)
|   +-- TrackSwipeActionsSettingsView.swift # Settings UI for configuring track swipe action slots
|   +-- SongsView.swift               # All songs list
|   +-- LogsSettingsView.swift        # Log session management (toggle, session list, delete)
|   +-- LogDetailView.swift           # Full-text log viewer with share
|   +-- MusicSourceAccountDetailView.swift # Source account detail (library toggles + sync status/actions)
+-- EnsembleLogger.swift              # Package logger categories
+-- EnsembleUI.swift                  # Public exports

Tests/
+-- EnsembleUITests.swift
```
