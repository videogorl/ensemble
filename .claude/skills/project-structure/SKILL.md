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
|
+-- Ensemble/                      # Main app target (iOS/iPadOS/macOS)
|   +-- App/
|   |   +-- EnsembleApp.swift     # App entry point
|   |   +-- AppDelegate.swift     # Audio session & background playback config
|   +-- Resources/
|   |   +-- Assets.xcassets       # App icons, colors, images
|   +-- Info.plist
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
+-- Client/
|   +-- PlexAPIClient.swift            # HTTP client for Plex API (actor)
|   +-- ConnectionFailoverManager.swift # Server connection resilience
+-- Models/
|   +-- PlexModels.swift               # API response models (Plex*)
+-- EnsembleAPI.swift                   # Public exports

Tests/
+-- PlexAPIClientTests.swift
```

## EnsemblePersistence (Data Layer)

```
Sources/
+-- CoreData/
|   +-- Ensemble.xcdatamodeld          # CoreData schema
|   +-- CoreDataStack.swift            # Singleton stack with background contexts
|   +-- ManagedObjects.swift           # NSManagedObject subclasses (CD* prefix)
+-- Downloads/
|   +-- DownloadManager.swift          # Track download queue & file storage
|   +-- ArtworkDownloadManager.swift   # Image caching
+-- Repositories/
|   +-- LibraryRepository.swift        # CRUD for artists, albums, tracks, genres
|   +-- PlaylistRepository.swift       # CRUD for playlists
+-- EnsemblePersistence.swift          # Public exports

Tests/
+-- LibraryRepositoryTests.swift
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
|   +-- MoodRepository.swift           # Mood data persistence (CDMood)
|   +-- QueueManager.swift             # Queue management (extracted from PlaybackService)
|   +-- ToastCenter.swift              # App-wide toast notification coordination (MainActor)
|   +-- PlexRadioProvider.swift        # Plex Radio support implementing RadioProvider protocol
|   +-- RadioProvider.swift            # Protocol for radio/station providers
+-- ViewModels/
|   +-- AddPlexAccountViewModel.swift
|   +-- AlbumDetailViewModel.swift
|   +-- ArtistDetailViewModel.swift
|   +-- DownloadsViewModel.swift
|   +-- FavoritesViewModel.swift       # Tracks rated 4+ stars
|   +-- HomeViewModel.swift            # Hub-based home screen (Recently Added, etc.)
|   +-- LibraryViewModel.swift
|   +-- NowPlayingViewModel.swift
|   +-- PinnedViewModel.swift          # Resolves PinnedItem references into domain objects
|   +-- PlaylistViewModel.swift
|   +-- SearchViewModel.swift
|   +-- SyncPanelViewModel.swift
+-- EnsembleCore.swift                 # Public exports

Tests/
+-- PlaybackServiceTests.swift
```

## EnsembleUI (Presentation Layer)

```
Sources/
+-- Components/
|   +-- AirPlayButton.swift           # AVRoutePickerView wrapper for AirPlay
|   +-- AlbumCard.swift               # Grid card for albums
|   +-- AlbumDetailLoader.swift       # Async loader for album detail with loading/error states
|   +-- ArtistCard.swift              # Grid card for artists
|   +-- ArtistDetailLoader.swift      # Async loader for artist detail with loading/error states
|   +-- ArtworkColorExtractor.swift   # Actor-based color extraction from artwork for dynamic gradients
|   +-- ArtworkView.swift             # Lazy-loading artwork with Nuke
|   +-- BlurredArtworkBackground.swift # Heavily blurred artwork background with contrast/saturation
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
|   +-- PlaylistActionSheets.swift    # Shared add-to-playlist and create-playlist UI sheets
|   +-- PlaylistCard.swift            # Grid card for playlists
|   +-- PlaylistDetailLoader.swift    # Async loader for playlist detail with loading/error states
|   +-- QueueTableView.swift          # UIKit-backed drag-to-reorder table view for queue
|   +-- ScrollIndex.swift             # A-Z index for fast scrolling
|   +-- ToastView.swift               # Toast notification overlay component
|   +-- TrackRow.swift                # Single track row with artwork
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
|   +-- PlaylistsView.swift           # Playlist grid
|   +-- RootView.swift                # Platform-adaptive root (tabs vs sidebar)
|   +-- SearchView.swift              # Search interface
|   +-- SettingsView.swift            # App settings with customizable tabs & accent colors
|   +-- SongsView.swift               # All songs list
|   +-- SyncPanelView.swift           # Library sync status & controls
+-- EnsembleUI.swift                  # Public exports

Tests/
+-- EnsembleUITests.swift
```
