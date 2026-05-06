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
|   +-- capture_performance_gate.sh # Captures repeatable Instruments performance gate flows with traces, xctrace table exports, dSYM metadata, and JSON metrics
|   +-- check_core_warning_budget.sh # Builds EnsembleCore and fails when Core-package compiler warnings exceed the current budget
|   +-- design_token_audit.sh     # Non-blocking design-token literal inventory and hotspot report
|   +-- plex_hls_spike.sh        # Bounded PMS music-HLS viability probe used before transport changes
|   +-- update_build_number.sh    # Sets deterministic CFBundleVersion for app + Siri extension builds
|
+-- docs/
|   +-- investigations/
|       +-- 2026-04-03-plex-hls-spike.md # Written verdict from the PMS music-HLS spike
|       +-- 2026-04-14-repo-audit-baseline.md # Ranked audit findings + baseline verification notes
|       +-- 2026-05-04-function-ownership-context-menu-audit.md # Shared function/menu ownership audit and migration order
|       +-- 2026-05-04-platform-mutation-drag-performance-scaffold-audit.md # Cross-platform policy, mutation, drag/export, performance, and utility scaffold audit
|       +-- 2026-05-06-codebase-audit.md # Full Swift target/package audit with cleanup and migration backlog
|       +-- 2026-05-06-swift-file-index.json # Generated exhaustive one-row-per-Swift-file audit index
|       +-- 2026-05-06-swift-file-index.csv # CSV export of the exhaustive Swift file audit index
|
+-- Ensemble/                      # Main app target (iOS/iPadOS/macOS)
|   +-- App/
|   |   +-- EnsembleApp.swift     # App entry point
|   |   +-- AppDelegate.swift     # Audio session & background playback config
|   |   +-- ExternalDisplaySceneDelegate.swift # UIWindowSceneDelegate for AirPlay screen mirroring external display
|   |   +-- EnsembleAppShortcuts.swift # App Intents fallback entities/phrases for Siri album/playlist playback
|   +-- Resources/
|   |   +-- Assets.xcassets       # App icons, colors, images
|   |   +-- Base.lproj/AppIntentVocabulary.plist # Base SiriKit sample phrases and global vocabulary
|   |   +-- en.lproj/AppIntentVocabulary.plist   # English SiriKit sample phrases and global vocabulary
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
    +-- EnsembleSiriShared/       # Shared Siri normalization/scoring rules
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
|   +-- PlexAPIClient+Connections.swift # Server connection accessors, capability fetch, and connection refresh endpoints split from PlexAPIClient
|   +-- PlexAPIClient+Library.swift    # Library-section, inventory, hubs, search, and rating endpoints split from PlexAPIClient
|   +-- PlexAPIClient+Metadata.swift   # Single-item metadata fetch/edit endpoints split from PlexAPIClient
|   +-- PlexAPIClient+Playlists.swift  # Playlist list/mutation endpoints split from PlexAPIClient
|   +-- PlexAPIClient+Playback.swift   # Stream URL resolution, transcode decisions, and two-phase playback assembly split from PlexAPIClient
|   +-- PlexAPIClient+Downloads.swift  # Universal-download and download-queue transport helpers split from PlexAPIClient
|   +-- PlexErrorClassification.swift  # Unified error taxonomy for failover/retry decisions
|   +-- PlexRequestBuilder.swift       # Pure URLRequest/header assembly helper shared by PlexAPIClient transport paths
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
|   +-- ManagedObjects.swift           # NSManagedObject subclasses (CD* prefix, including CDHomeFeedSnapshot for Feed last-good cache)
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

## EnsembleSiriShared (Siri Shared Rules)

```
Sources/
+-- SiriMatching.swift                 # App Group constants, phrase normalization, query variants, and fuzzy scoring

Tests/
+-- SiriMatchingTests.swift            # Normalization, app suffix/prefix trimming, query variants, and fuzzy score coverage
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
|   +-- MediaFormatters.swift          # Shared duration/byte display formatting helpers
|   +-- MediaSourceIdentity.swift      # Shared source-key parsing and server-scope comparison helpers
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
|   +-- PlaylistMutationWorkflow.swift # Shared playlist add/create/rename/delete mutation workflow, outcome, and toast payload policy
|   +-- PlaylistActionService.swift    # Shared add-to-playlist source compatibility, default-server, dedupe, and source-stamping rules
|   +-- PlaylistDropResolver.swift     # Shared media-reference resolver for playlist drag/drop copy-add flows
|   +-- PinMutationWorkflow.swift      # Shared local pin/unpin/batch/reorder mutation policy with silent toast policy
|   +-- TrackRatingMutationWorkflow.swift # Shared favorite/rating mutation toast and queued/error policy
|   +-- MediaFilterEngine.swift        # Shared media filter rules for library, detail, playlist, and favorites surfaces
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
|   +-- PlaybackAudioSessionCoordinator.swift # AVAudioSession configuration/activation + interruption/route observation extracted from PlaybackService
|   +-- PlaybackHandoffCoordinator.swift # Disconnect/interruption/remote-command handoff reducer extracted from PlaybackService
|   +-- PlaybackQueueStore.swift       # Queue/history restoration persistence extracted from PlaybackService
|   +-- PlaybackQueueController.swift  # Queue/history mutation + queue snapshot persistence extracted from PlaybackService
|   +-- PlaybackStartupCoordinator.swift # Restored-playback snapshot validation + prebuffer decision policy extracted from PlaybackService
|   +-- PlaybackLaunchCoordinator.swift # Successful playback launch path (visualizer load, engine start, recovery seek, prefetch) extracted from PlaybackService
|   +-- PlaybackRecoveryPolicy.swift   # Buffering/stall-recovery policy extracted from PlaybackService
|   +-- PlaybackSessionStateMachine.swift # Playback session request/retry/failure policy extracted from PlaybackService
|   +-- PlaybackResolvedFileCache.swift # Serialized resolved-file URL cache + prefetch in-flight bookkeeping extracted from PlaybackService
|   +-- PlaybackPrefetchController.swift # Resolved-file cache eviction + stream-cache cleanup policy extracted from PlaybackService
|   +-- PlaybackNowPlayingBridge.swift # Lock-screen metadata + command-availability wiring extracted from PlaybackService
|   +-- PlaybackTransportCoordinator.swift # Stream/local transport resolution + progressive-loader cache extracted from PlaybackService
|   +-- PlaybackSettingsObserver.swift # Key-filtered UserDefaults observer for playback settings changes
|   +-- PlaybackReportingController.swift # Timeline reporting and scrobble policy extracted from PlaybackService
|   +-- AppBootstrapDiagnostics.swift # Structured cold-launch bootstrap summary service (accounts/sync/playback/offline/audio session)
|   +-- ProgressiveStreamLoader.swift  # AVAssetResourceLoaderDelegate bridge for chunked transcode streams
|   +-- ArtworkLoader.swift            # Persistent artwork caching & loading
|   +-- CacheManager.swift             # Cache size tracking & management (MainActor)
|   +-- NetworkMonitor.swift           # Network connectivity monitoring (NWPathMonitor)
|   +-- ServerHealthChecker.swift      # Concurrent server health checks
|   +-- ServerConnectionController.swift # Registry subscription + API-client endpoint synchronization extracted from SyncCoordinator
|   +-- SettingsManager.swift          # App settings (accent colors, customizable tabs)
|   +-- HubRepository.swift            # Hub data persistence (CDHub/CDHubItem/CDHomeFeedSnapshot last-good snapshots)
|   +-- HomeHubLoader.swift            # Feed hub snapshot loader shared by HomeViewModel and background refresh
|   +-- HubOrderManager.swift          # User-customizable hub section ordering
|   +-- BackgroundSyncScheduler.swift  # iOS BGAppRefreshTask scheduling for background sync
|   +-- BackgroundRefreshCoordinator.swift # Shared app-refresh/foreground Feed freshness sequence (health, sync, Feed snapshot, Siri context)
|   +-- OfflineDownloadService.swift   # Target-based offline queue, reconciliation, progress tracking, and healing orchestration
|   +-- DownloadMutationWorkflow.swift # Shared user-initiated download target/queue mutation boundary
|   +-- DownloadQueueCoordinator.swift # Sole owner of offline queue task lifecycle and worker orchestration
|   +-- OfflineDownloadCleanupCoordinator.swift # Best-effort orphaned-download cleanup for completed files that no longer have any offline target membership
|   +-- DownloadRetryPolicy.swift      # Stateful offline retry and direct-fallback policy
|   +-- DownloadTargetReconciler.swift # Membership resolution and orphan cleanup for offline targets
|   +-- DownloadTransferExecutor.swift # Direct-download/download-queue transfer pipeline, validation, recovery, and post-completion side effects extracted from OfflineDownloadService
|   +-- OfflineDownloadNotificationBridge.swift # Debounced downloadsDidChange fan-out + queue completion toast seam extracted from OfflineDownloadService
|   +-- OfflineBackgroundExecutionCoordinator.swift # Offline download background coordinator: iOS 26 continued processing, URLSession wake completion registry, macOS sleep/wake recovery
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
|   +-- AudioAnalyzer.swift            # Pre-computed frequency analysis, visualization consumer registry, and demand-driven display timer
|   +-- InstrumentalModeCapability.swift # Static AUSoundIsolation availability probe (iOS 16+ / A13+)
|   +-- InstrumentalAudioEngine.swift  # AVAudioEngine wrapper with AUSoundIsolation for vocal attenuation
|   +-- PowerStateMonitor.swift        # Low Power Mode observer; publishes isLowPowerMode for GPU/network throttling (@MainActor ObservableObject)
|   +-- SongLinkService.swift          # Universal song.link URL resolution via MusicKit + song.link API
|   +-- ShareService.swift             # Share payload coordinator (link/file/text) with temp download support
|   +-- LyricsService.swift            # LRC parser, lyrics models (LyricsLine/ParsedLyrics/LyricsState), LyricsService fetch pipeline + offline sidecar
|   +-- MutationCoordinator.swift      # Unified online/offline mutation queue for ratings, playlists, and scrobbles
|   +-- MetadataMutationService.swift  # Metadata edit coordination + invalidation notifications for UI refresh
|   +-- MetadataMutationWorkflow.swift # Shared track/album/artist metadata edit/delete workflow and toast payload policy
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
|   +-- NowPlayingProjections.swift     # Focused playback, queue, artwork, lyrics, and rating projections for low-churn UI observation
|   +-- TrackActionDispatching.swift    # Action-dispatch protocol for track rows/cards/tables that should not observe the full Now Playing model
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
+-- DownloadMutationWorkflowTests.swift # Shared download target/queue mutation workflow coverage
+-- DownloadQueueCoordinatorTests.swift # Queue lifecycle ownership, background wakeup, and restart coverage
+-- DownloadRetryPolicyTests.swift # Transfer retry accounting and direct-fallback gating coverage
+-- DownloadTargetReconcilerTests.swift # Target membership resolution and orphan cleanup coverage
+-- DownloadTransferExecutorTests.swift # Direct-download/download-queue transfer execution and fallback coverage
+-- OfflineDownloadNotificationBridgeTests.swift # Debounced downloadsDidChange fan-out and toast routing coverage
+-- OfflineDownloadCleanupCoordinatorTests.swift # Orphaned completed-download sweep coverage
+-- OfflineDownloadBackgroundCoordinatorTests.swift # URLSession completion registry and sleep/wake hook coverage
+-- BackgroundRefreshCoordinatorTests.swift # Shared app/foreground freshness sequencing and error/cooldown coverage
+-- HomeViewModelRefreshPolicyTests.swift
+-- HubRepositorySnapshotTests.swift  # CDHomeFeedSnapshot save/fetch/source cleanup/last-good preservation coverage
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
+-- PlaylistActionServiceTests.swift  # Add-to-playlist source compatibility and dedupe coverage
+-- PlaylistDropResolverTests.swift   # Playlist drag/drop target validation, expansion, dedupe, and source rejection coverage
+-- PlaylistMutationWorkflowTests.swift # Shared playlist add/create/rename/delete workflow and toast payload coverage
+-- PinMutationWorkflowTests.swift    # Shared pin/unpin/batch/reorder policy coverage
+-- TrackRatingMutationWorkflowTests.swift # Shared favorite/rating toast and queued/error policy coverage
+-- MetadataMutationWorkflowTests.swift # Shared metadata edit/delete workflow and toast payload coverage
+-- MediaFilterEngineTests.swift      # Shared media filter configurations and parity coverage
+-- MediaFormattersTests.swift        # Shared media duration/byte formatting coverage
+-- MediaSourceIdentityTests.swift    # Source-key parsing and server comparison coverage
+-- NavigationCoordinatorTests.swift  # Navigation destination target tabs, fallback, and path helper coverage
+-- UserProfileTests.swift            # Unit tests for UserProfile model
+-- SyncSettingsManagerTests.swift    # Unit tests for SyncSettingsManager toggle logic + dependency cascade
+-- PinManagerSyncTests.swift         # Unit tests for PinManager merge logic (union, remote-wins conflict)
```

## EnsembleUI (Presentation Layer)

```
Sources/
+-- DesignSystem/                    # Tokens, adaptive scaffolds, and shared chrome modifiers
|   +-- EnsembleDesign.swift
|   +-- EnsembleScaffold.swift
|   +-- TrackListLayoutMetrics.swift
|   +-- ArtworkCornerRadius.swift
|   +-- View+DesignModifiers.swift
+-- Artwork/                         # Artwork loading, backgrounds, composites, and color extraction
+-- Browse/                          # Browse split, filter sheet, GenreFilterHeader/GenreChipBar, scroll index, refresh command bridge
+-- Cards/                           # Album, artist, playlist, and genre cards
+-- TrackLists/                      # SwiftUI/UIKit/AppKit track row and table backends
|   +-- AppKit/
|   |   +-- MacNativeTrackTableView.swift # NSTableView backend used by SongsTrackListHost on macOS
|   +-- MediaTrackList.swift
|   +-- NativeMediaTableActionBuilder.swift
|   +-- NativeTrackListConfiguration.swift
|   +-- NativeTrackListSections.swift
|   +-- QueueTableView.swift
|   +-- SongsTrackListHost.swift
|   +-- StandardSwipeActions.swift
|   +-- TrackRow.swift
|   +-- TrackRowInteractionModel.swift
|   +-- TrackSwipeContainer.swift
+-- DetailSurfaces/                  # Shared media-detail shell/header/action/list-card primitives
+-- PlaybackChrome/                  # Mini player, AirPlay button, waveform
+-- NowPlaying/                      # Now Playing cards, carousel, queue, lyrics, page indicator
+-- StageFlow/                       # iPhone landscape StageFlow experience
+-- Aurora/                          # Aurora background and Metal/Canvas renderers
+-- Sheets/                          # Shared sheets and macOS auxiliary sheet/window scaffolds
+-- Utility/                         # Shared rows, menus, toolbar/profile helpers, keyboard/chrome utilities
|   +-- MediaDragPayload.swift        # Internal drag/drop payload for tracks, albums, playlists, and merged display playlists
|   +-- MediaDragExportPolicy.swift   # Drag/drop copy-vs-move and external file-promise policy matrix plus provider/writer helpers
|   +-- MediaMenuCatalog.swift        # Shared context-menu action catalog, section policy, roles, and context gating
|   +-- EnsemblePlatformFeaturePolicy.swift # Platform feature/rendering policy for root shell, commands, mini-player menus, native lists, and utility scaffolds
|   +-- PlaylistActionPresentationHost.swift # Shared add-to-playlist sheet request + recent-playlist presentation helpers
|   +-- EnsembleUtilityScreenScaffold.swift # Adaptive utility scaffold plus card-based macOS screen/section rows for menu-like tools
+-- Screens/
|   +-- Root/                         # RootView, MainTabView, MoreView, auxiliary presentation routing
|   |   +-- NavigationDestinationFactory.swift # Shared root tab/destination view factory used by iPhone tabs and iPad/macOS sidebar stacks
|   |   +-- NavigationCoordinator+Bindings.swift # SwiftUI path bindings backed by NavigationCoordinator path helpers
|   |   +-- SidebarSelection.swift    # Sidebar selection model and destination mapping for iPad/macOS root navigation
|   +-- Library/                      # Songs, Artists, Albums, Genres, Playlists, Favorites, Mood
|   +-- Details/                      # Media detail, merged playlist detail, async detail loaders
|   +-- Discovery/                    # Home/Feed and Search
|   +-- AccountSettings/              # Profile, settings, account setup, source detail, sync/swipe settings
|   +-- Downloads/                    # Downloads, download details/settings, offline servers, pending mutations
|   +-- NowPlaying/                   # Now Playing sheet, viewport root, external display
|   +-- Diagnostics/                  # Logs list/detail
+-- EnsembleLogger.swift              # Package logger categories
+-- EnsembleUI.swift                  # Public exports

Tests/
+-- EnsembleUITests.swift
+-- NavigationRootHelperTests.swift   # Sidebar destination mapping and NavigationCoordinator path binding coverage
+-- PlatformAndDragPolicyTests.swift # Platform feature policy and drag/export default matrix coverage
```
