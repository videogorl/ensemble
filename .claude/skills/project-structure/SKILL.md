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
+-- scripts/
|   +-- compile_coredata_model.sh # Compiles SwiftPM CoreData model bundle for package tests
|   +-- update_build_number.sh    # Sets deterministic CFBundleVersion for app + Siri extension builds
|
+-- Ensemble/                      # Main app target (iOS/iPadOS/macOS)
|   +-- App/
|   |   +-- EnsembleApp.swift     # App entry point
|   |   +-- AppDelegate.swift     # Audio session & background playback config
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
|   +-- KeychainService.swift          # Secure token storage wrapper
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
|   +-- Compiled/SwiftPMEnsemble.momd # Precompiled model copy used by SwiftPM tests
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
|   +-- DomainModels.swift             # UI-facing models (Track, Album, Artist, Hub, etc.)
|   +-- ModelMappers.swift             # CD* <-> Domain model conversions
|   +-- MusicSource.swift              # Multi-account source identification
|   +-- PlexAccountConfig.swift        # Account/server/library configuration
|   +-- SiriIntentPayload.swift        # Siri extension->app payload codec + schema
|   +-- SiriMediaIndex.swift           # Siri media index model used by extension lookup
|   +-- LibraryVisibilityProfile.swift # Source visibility profile model (non-sync filtering)
|   +-- ConnectionPolicy.swift         # Core-level aliases/UI labels for API connection policy types
|   +-- FilterOptions.swift            # Filter/sort configuration with persistence
|   +-- NetworkModels.swift            # Network state & connectivity models
|   +-- PinnedItem.swift               # Pinned content model (albums, artists, playlists)
+-- Services/
|   +-- AccountManager.swift           # Multi-account configuration (MainActor)
|   +-- SyncCoordinator.swift          # Multi-source sync orchestration (MainActor)
|   +-- MusicSourceSyncProvider.swift  # Protocol for source-specific sync
|   +-- PlexMusicSourceSyncProvider.swift # Plex implementation of sync protocol
|   +-- NavigationCoordinator.swift    # Centralized navigation state management (MainActor)
|   +-- PlaybackService.swift          # AVPlayer wrapper with queue/shuffle/repeat
|   +-- ArtworkLoader.swift            # Persistent artwork caching & loading
|   +-- CacheManager.swift             # Cache size tracking & management (MainActor)
|   +-- NetworkMonitor.swift           # Network connectivity monitoring (NWPathMonitor)
|   +-- ServerHealthChecker.swift      # Concurrent server health checks
|   +-- SettingsManager.swift          # App settings (accent colors, customizable tabs)
|   +-- HubRepository.swift            # Hub data persistence (CDHub/CDHubItem)
|   +-- HubOrderManager.swift          # User-customizable hub section ordering
|   +-- BackgroundSyncScheduler.swift  # iOS BGAppRefreshTask scheduling for background sync
|   +-- OfflineDownloadService.swift   # Target-based offline queue, reconciliation, and progress tracking
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
|   +-- PowerStateMonitor.swift        # Low Power Mode observer; publishes isLowPowerMode for GPU/network throttling (@MainActor ObservableObject)
|   +-- SongLinkService.swift          # Universal song.link URL resolution via MusicKit + song.link API
|   +-- ShareService.swift             # Share payload coordinator (link/file/text) with temp download support
|   +-- LyricsService.swift            # LRC parser, lyrics models (LyricsLine/ParsedLyrics/LyricsState), LyricsService fetch pipeline + offline sidecar
+-- EnsembleLogger.swift               # Package logger categories
+-- ViewModels/
|   +-- AddPlexAccountViewModel.swift
|   +-- AlbumDetailViewModel.swift
|   +-- ArtistDetailViewModel.swift
|   +-- DownloadsViewModel.swift
|   +-- FavoritesViewModel.swift       # Tracks rated 4+ stars, sorting (FavoritesSortOption), download toggle
|   +-- HomeViewModel.swift            # Hub-based home screen (Recently Added, etc.)
|   +-- LibraryViewModel.swift
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
+-- NetworkMonitorTests.swift
+-- SyncCoordinatorNetworkHealthTests.swift
+-- HomeViewModelRefreshPolicyTests.swift
+-- ServerHealthCheckerClassificationTests.swift
+-- SettingsManagerConnectionPolicyTests.swift
+-- AccountManagerAuthPolicyTests.swift
+-- SearchSectionOrderingTests.swift   # Deterministic search section tie-break ordering
+-- LibraryVisibilityProfileTests.swift # Visibility profile persistence + filtering seams
+-- SiriIntentPayloadTests.swift       # Siri payload serialization + userInfo contract
+-- SiriPlaybackCoordinatorTests.swift # In-app Siri playback execution coverage
+-- SongLinkServiceTests.swift         # Song.link URL resolution + caching + fallback tests
+-- ShareServiceTests.swift            # Share payload assembly + file detection tests
+-- LyricsServiceTests.swift           # LRC parser timestamp parsing + line lookup coverage
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
|   +-- ArtworkView.swift             # Lazy-loading artwork with Nuke
|   +-- AuroraVisualizationView.swift # Aurora-style background visualization of music loudness
|   +-- BlurredArtworkBackground.swift # Heavily blurred artwork background with contrast/saturation
|   +-- CollapsingToolbar.swift      # Shared collapsing toolbar title with nav bar appearance toggle
|   +-- ChromeVisibilityPreferenceKey.swift # SwiftUI preference key for hiding tab bar in immersive views
|   +-- CompactSearchRows.swift       # Compact row layouts for search results
|   +-- ConnectionStatusBanner.swift  # Network status UI indicator
|   +-- CoverFlowView.swift           # 3D carousel with perspective rotation and scaling
|   +-- CoverFlowItemView.swift       # Individual item in CoverFlow carousel
|   +-- CoverFlowDetailView.swift     # Flipped detail view for CoverFlow items
|   +-- EmptyLibraryView.swift        # Empty state with sync prompt
|   +-- FilterSheet.swift             # Advanced filtering UI with persistence
|   +-- FlipOpacity.swift             # View modifier for flip animations
|   +-- GenreCard.swift               # Grid card for genres
|   +-- HubOrderingSheet.swift        # Sheet for reordering hub sections with drag & drop
|   +-- KeyboardObserver.swift        # iOS-specific keyboard height tracking with view modifier
|   +-- MarqueeText.swift             # Auto-scrolling text component for long titles
|   +-- MediaTrackList.swift          # Reusable track list with context menu
|   +-- MiniPlayer.swift              # Compact persistent player overlay
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
|   +-- TrackSwipeContainer.swift     # iOS/iPadOS swipe gesture container for track row actions
|   +-- View+Extensions.swift         # SwiftUI view extensions and helpers
|   +-- WaveformView.swift            # Audio waveform visualization
+-- Screens/
|   +-- AddPlexAccountView.swift      # Account setup flow
|   +-- AlbumsView.swift              # Album grid
|   +-- ArtistsView.swift             # Artist grid
|   +-- DownloadsView.swift           # Offline downloads
|   +-- FavoritesView.swift           # Tracks rated 4+ stars
|   +-- GenresView.swift              # Genre browsing
|   +-- HomeView.swift                # Hub-based home screen (Recently Added, etc.)
|   +-- MainTabView.swift             # iPhone tab bar
|   +-- MediaDetailView.swift         # Artist/Album/Playlist detail (adaptive, protocol-based)
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
|   +-- SettingsView.swift            # App settings with customizable tabs & accent colors
|   +-- TrackSwipeActionsSettingsView.swift # Settings UI for configuring track swipe action slots
|   +-- SongsView.swift               # All songs list
|   +-- MusicSourceAccountDetailView.swift # Source account detail (library toggles + sync status/actions)
+-- EnsembleLogger.swift              # Package logger categories
+-- EnsembleUI.swift                  # Public exports

Tests/
+-- EnsembleUITests.swift
```
