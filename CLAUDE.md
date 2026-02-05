# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


## Coding style

Leave doc comments and comments above classes and other elements so that both the user and the agent know what's going on: keep this up to date.

As you make big architectural changes, please update this document and the README.md file as necessary.

Please don't remove existing functionality (unless directed) when re-architecting parts of the code. I've had to re-implement multiple things that I had asked for and that were removed.

## Project Overview

Ensemble is a universal Plex Music Player built with SwiftUI, targeting iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It streams music from Plex servers using PIN-based OAuth authentication. It is very important features work on iOS 15, and are memory and speed optimized for devices with 2GB or less of RAM.

Right now, this app is not released to the public, and isn't in beta. As a result, we don't need to account for edge cases as we're developing the CoreData model.

The goal of this app is to provide a beautiful, information-dense, and customizable native experience for the Plex server.

Please comment code so that it's understandable. Don't over comment, just comment on what each "piece" does.

As you make big architectural changes, please be sure to update this document and the README.md file to describe the app structure in a way that helps both you and me.

Do not use emojis (except in debugging).

## Project Structure

```
ensemble/
├── Ensemble.xcworkspace          # Main workspace (always use this, not .xcodeproj)
├── Ensemble.xcodeproj             # Xcode project file
├── CLAUDE.md                      # This file
├── README.md                      # User-facing documentation
│
├── Ensemble/                      # Main app target (iOS/iPadOS/macOS)
│   ├── App/
│   │   ├── EnsembleApp.swift     # App entry point
│   │   └── AppDelegate.swift     # Audio session & background playback config
│   ├── Resources/
│   │   └── Assets.xcassets       # App icons, colors, images
│   └── Info.plist
│
├── EnsembleWatch/                 # watchOS app target
│   ├── App/
│   │   └── EnsembleWatchApp.swift
│   ├── Views/
│   │   └── WatchRootView.swift   # All watchOS views (authentication, library, now playing)
│   ├── Resources/
│   │   └── Assets.xcassets
│   └── Info.plist
│
└── Packages/                      # Swift Package modules
    ├── EnsembleAPI/              # Layer 1: Networking
    ├── EnsemblePersistence/      # Layer 1: Data persistence
    ├── EnsembleCore/             # Layer 2: Business logic
    └── EnsembleUI/               # Layer 3: User interface
```

## Build & Test Commands

**Build the full app (iOS simulator):**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build
```

**Build a single package:**
```bash
swift build --package-path Packages/EnsembleAPI
swift build --package-path Packages/EnsembleCore
swift build --package-path Packages/EnsemblePersistence
swift build --package-path Packages/EnsembleUI
```

**Run tests for a single package:**
```bash
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
```

**Run all tests via Xcode:**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' test
```

**IMPORTANT:** Always open `Ensemble.xcworkspace` (not `.xcodeproj`) when working in Xcode.

## Architecture

The app uses a layered modular architecture via four Swift Packages under `Packages/`:

```
Layer 3: EnsembleUI (SwiftUI views & components)
              ↓
Layer 2: EnsembleCore (ViewModels, services, domain models)
              ↓
Layer 1: EnsembleAPI (Networking) + EnsemblePersistence (CoreData)
```

### Package Details

#### EnsembleAPI (Networking Layer)
- **Location:** `Packages/EnsembleAPI/`
- **Dependencies:** KeychainAccess
- **Purpose:** All Plex server communication and authentication

**File Structure:**
```
Sources/
├── Auth/
│   ├── KeychainService.swift          # Secure token storage wrapper
│   └── PlexAuthService.swift          # PIN-based OAuth flow (actor)
├── Client/
│   ├── PlexAPIClient.swift            # HTTP client for Plex API (actor)
│   └── ConnectionFailoverManager.swift # Server connection resilience
├── Models/
│   └── PlexModels.swift               # API response models (Plex*)
└── EnsembleAPI.swift                   # Public exports

Tests/
└── PlexAPIClientTests.swift
```

**Key Types:**
- `PlexAuthService` (actor) — PIN-based OAuth authentication
- `PlexAPIClient` (actor) — Thread-safe API requests with automatic failover
- `KeychainService` — Token persistence using KeychainAccess library
- `PlexModels.swift` — Response types (`PlexServer`, `PlexLibrary`, `PlexTrack`, etc.)

#### EnsemblePersistence (Data Layer)
- **Location:** `Packages/EnsemblePersistence/`
- **Dependencies:** None (pure CoreData)
- **Purpose:** Local caching and offline storage

**File Structure:**
```
Sources/
├── CoreData/
│   ├── Ensemble.xcdatamodeld          # CoreData schema
│   ├── CoreDataStack.swift            # Singleton stack with background contexts
│   └── ManagedObjects.swift           # NSManagedObject subclasses (CD* prefix)
├── Downloads/
│   ├── DownloadManager.swift          # Track download queue & file storage
│   └── ArtworkDownloadManager.swift   # Image caching
├── Repositories/
│   ├── LibraryRepository.swift        # CRUD for artists, albums, tracks, genres
│   └── PlaylistRepository.swift       # CRUD for playlists
└── EnsemblePersistence.swift          # Public exports

Tests/
└── LibraryRepositoryTests.swift
```

**Key Types:**
- `CoreDataStack` (singleton) — Main/background contexts, saves on background queue
- `CD*` models — `CDMusicSource`, `CDArtist`, `CDAlbum`, `CDTrack`, `CDGenre`, `CDPlaylist`, `CDServer`
- `LibraryRepository` / `PlaylistRepository` — Protocol-based repository pattern
- `DownloadManager` — Offline track file management
- `ArtworkDownloadManager` — Persistent artwork caching to local filesystem

#### EnsembleCore (Business Logic Layer)
- **Location:** `Packages/EnsembleCore/`
- **Dependencies:** EnsembleAPI, EnsemblePersistence, Nuke
- **Purpose:** Services, ViewModels, domain models, dependency injection

**File Structure:**
```
Sources/
├── DI/
│   └── DependencyContainer.swift      # Singleton DI container & VM factories
├── Models/
│   ├── DomainModels.swift             # UI-facing models (Track, Album, Artist, Hub, etc.)
│   ├── ModelMappers.swift             # CD* ↔ Domain model conversions
│   ├── MusicSource.swift              # Multi-account source identification
│   ├── PlexAccountConfig.swift        # Account/server/library configuration
│   ├── FilterOptions.swift            # Filter/sort configuration with persistence
│   └── NetworkModels.swift            # Network state & connectivity models
├── Services/
│   ├── AccountManager.swift           # Multi-account configuration (MainActor)
│   ├── SyncCoordinator.swift          # Multi-source sync orchestration (MainActor)
│   ├── MusicSourceSyncProvider.swift  # Protocol for source-specific sync
│   ├── PlexMusicSourceSyncProvider.swift # Plex implementation of sync protocol
│   ├── NavigationCoordinator.swift    # Centralized navigation state management (MainActor)
│   ├── PlaybackService.swift          # AVPlayer wrapper with queue/shuffle/repeat
│   ├── ArtworkLoader.swift            # Persistent artwork caching & loading
│   ├── CacheManager.swift             # Cache size tracking & management (MainActor)
│   ├── NetworkMonitor.swift           # Network connectivity monitoring (NWPathMonitor)
│   ├── ServerHealthChecker.swift      # Concurrent server health checks
│   └── SettingsManager.swift          # App settings (accent colors, customizable tabs)
├── ViewModels/
│   ├── AddPlexAccountViewModel.swift
│   ├── AlbumDetailViewModel.swift
│   ├── ArtistDetailViewModel.swift
│   ├── DownloadsViewModel.swift
│   ├── FavoritesViewModel.swift       # Tracks rated 4+ stars
│   ├── HomeViewModel.swift            # Hub-based home screen (Recently Added, etc.)
│   ├── LibraryViewModel.swift
│   ├── NowPlayingViewModel.swift
│   ├── PlaylistViewModel.swift
│   ├── SearchViewModel.swift
│   └── SyncPanelViewModel.swift
└── EnsembleCore.swift                 # Public exports

Tests/
└── PlaybackServiceTests.swift
```

**Key Services:**
- `DependencyContainer` (singleton) — Wires all services, creates ViewModels, injected via SwiftUI environment
- `AccountManager` (@MainActor) — Manages multiple Plex accounts, servers, and libraries
- `SyncCoordinator` (@MainActor) — Orchestrates library syncing across all enabled sources
- `NavigationCoordinator` (@MainActor) — Manages cross-view navigation state (artist/album deep links from NowPlayingView)
- `PlaybackService` — AVPlayer management, queue, shuffle, repeat, remote controls
- `ArtworkLoader` — Persistent artwork caching with local-first loading strategy
- `CacheManager` (@MainActor) — Tracks cache sizes and provides cache clearing functionality
- `NetworkMonitor` (@MainActor) — Proactive network connectivity monitoring using NWPathMonitor with 1s debouncing
- `ServerHealthChecker` — Concurrent health checks for all configured servers with automatic failover
- `SettingsManager` (@MainActor) — Manages accent colors and customizable tab configuration

**Key Models:**
- Domain models: `Track`, `Album`, `Artist`, `Genre`, `Playlist`, `Hub`, `HubItem` (UI-facing, protocol-conforming)
- `MusicSource` / `MusicSourceIdentifier` — Multi-account source tracking
- `PlexAccountConfig` — Account/server/library hierarchy for configuration
- `FilterOptions` — Comprehensive filtering with search, sort, genre/artist filters, year ranges, downloaded-only toggle
- `NetworkState`, `NetworkType`, `ServerConnectionState`, `StatusColor` — Network state management models

#### EnsembleUI (Presentation Layer)
- **Location:** `Packages/EnsembleUI/`
- **Dependencies:** EnsembleCore, Nuke (NukeUI)
- **Purpose:** All SwiftUI views and reusable components

**File Structure:**
```
Sources/
├── Components/
│   ├── AirPlayButton.swift           # AVRoutePickerView wrapper for AirPlay
│   ├── AlbumCard.swift               # Grid card for albums
│   ├── ArtistCard.swift              # Grid card for artists
│   ├── BlurredArtworkBackground.swift # Heavily blurred artwork background with contrast/saturation
│   ├── ArtworkView.swift             # Lazy-loading artwork with Nuke
│   ├── ConnectionStatusBanner.swift  # Network status UI indicator
│   ├── EmptyLibraryView.swift        # Empty state with sync prompt
│   ├── FilterSheet.swift             # Advanced filtering UI with persistence
│   ├── MediaTrackList.swift          # Reusable track list with context menu
│   ├── MiniPlayer.swift              # Compact persistent player overlay
│   ├── PlaylistCard.swift            # Grid card for playlists
│   ├── ScrollIndex.swift             # A-Z index for fast scrolling
│   ├── TrackRow.swift                # Single track row with artwork
│   └── WaveformView.swift            # Audio waveform visualization
├── Screens/
│   ├── AddPlexAccountView.swift      # Account setup flow
│   ├── AlbumsView.swift              # Album grid
│   ├── ArtistsView.swift             # Artist grid
│   ├── DownloadsView.swift           # Offline downloads
│   ├── FavoritesView.swift           # Tracks rated 4+ stars
│   ├── GenresView.swift              # Genre browsing
│   ├── HomeView.swift                # Hub-based home screen (Recently Added, etc.)
│   ├── MainTabView.swift             # iPhone tab bar
│   ├── MediaDetailView.swift         # Artist/Album/Playlist detail (adaptive, protocol-based)
│   ├── MoreView.swift                # Additional options
│   ├── NowPlayingView.swift          # Full-screen player
│   ├── PlaylistsView.swift           # Playlist grid
│   ├── RootView.swift                # Platform-adaptive root (tabs vs sidebar)
│   ├── SearchView.swift              # Search interface
│   ├── SettingsView.swift            # App settings with customizable tabs & accent colors
│   ├── SongsView.swift               # All songs list
│   └── SyncPanelView.swift           # Library sync status & controls
└── EnsembleUI.swift                  # Public exports

Tests/
└── EnsembleUITests.swift
```

**Key Views:**
- `RootView` — Adapts by platform: tab navigation on iPhone, sidebar on iPad/macOS
- `MiniPlayer` — Persistent compact player overlay across all screens
- `MediaDetailView` — Unified detail view using `MediaDetailViewModelProtocol` (supports Artist, Album, Playlist, Favorites)
- `ArtworkView` — Local-first artwork loading with automatic fallback to network
- `HomeView` — Hub-based home screen with horizontally-scrolling sections (Recently Added, Recently Played, etc.)
- `FavoritesView` — Displays tracks rated 4+ stars
- `FilterSheet` — Advanced filtering UI with artist/genre multi-select, year ranges, downloaded-only filter
- `ArtworkColorExtractor` — Actor-based background color extraction for dynamic gradients on detail views
- `ConnectionStatusBanner` — Network connectivity status banner
- `AirPlayButton` — Native AirPlay route picker integration
- `WaveformView` — Audio waveform visualization with real Plex loudness data or fallback generation

### Key Architectural Patterns

- **MVVM** — All ViewModels are `@MainActor` ObservableObjects using Combine publishers
- **Dependency Injection** — Centralized `DependencyContainer` singleton, injected through SwiftUI environment key
- **Actor-based concurrency** — Thread-safe networking with `PlexAPIClient` and `PlexAuthService` actors
- **Repository pattern** — Protocol abstractions for CoreData access (`LibraryRepositoryProtocol`, `PlaylistRepositoryProtocol`)
- **Protocol-based view reuse** — `MediaDetailViewModelProtocol` enables single `MediaDetailView` for multiple content types (Artist, Album, Playlist, Favorites)
- **Domain model separation** — Three distinct model layers:
  - API models (`Plex*` in EnsembleAPI) — Raw server responses
  - CoreData models (`CD*` in EnsemblePersistence) — Persisted entities
  - Domain models (in EnsembleCore) — UI-facing, protocol-conforming types
- **Multi-source architecture** — Designed to support multiple Plex accounts and future services (Apple Music, Spotify)
  - `MusicSourceIdentifier` tracks source origin (accountId, serverId, libraryId)
  - `SyncCoordinator` orchestrates syncing across all enabled sources
  - Provider pattern allows pluggable sync implementations
- **Network resilience** — Multi-layered approach for robust connectivity
  - `NetworkMonitor` — OS-level connectivity monitoring (NWPathMonitor) with 1s debouncing
  - `ServerHealthChecker` — Concurrent health checks for all configured servers
  - `ConnectionFailoverManager` — Automatic failover between server URLs (Local → Direct → Relay)
- **Persistent artwork caching** — Two-tier caching system for optimal performance
  - Local filesystem cache via `ArtworkDownloadManager` (survives app restarts)
  - In-memory cache via Nuke's `ImagePipeline` (fast access during session)
  - Local-first loading strategy: check filesystem → fetch from network if needed
- **Performance optimizations** — Debouncing and background processing throughout
  - Network monitor debouncing (1s) to reduce unnecessary UI updates
  - Home screen loading debouncing (2s) to prevent rapid reloads
  - Delayed network monitor start (500ms) to avoid blocking app launch
  - Task.detached for non-blocking background work
  - Blurred artwork background for efficient and beautiful visuals (replaces complex color extraction)

### Artwork Caching System

The app implements a persistent artwork caching system that survives app restarts:

**Architecture:**
1. **ArtworkDownloadManager** (`EnsemblePersistence`) — Downloads and stores artwork files locally
   - Stores artwork in `Library/Application Support/Ensemble/Artwork/`
   - Filename format: `{ratingKey}_album.jpg` or `{ratingKey}_artist.jpg`
   - Provides methods: `downloadAndCacheArtwork()`, `getLocalArtworkPath()`, `clearArtworkCache()`

2. **ArtworkLoader** (`EnsembleCore`) — Coordinates artwork loading with local-first strategy
   - `artworkURLAsync()` checks local cache first using `ratingKey`
   - Falls back to network fetch via `SyncCoordinator` if not cached
   - `predownloadArtwork()` methods for batch downloading during sync
   - Configures Nuke's `ImagePipeline` with 100MB disk cache for additional performance layer

3. **ArtworkView** (`EnsembleUI`) — SwiftUI component that displays artwork
   - Passes `ratingKey` to enable local cache lookups
   - Shows placeholder while loading
   - Automatically falls back to network if local cache misses
   - Convenience initializers for `Track`, `Album`, `Artist`, `Playlist` domain models

4. **CacheManager** (`EnsembleCore`) — Provides cache visibility and management
   - Tracks cache sizes across all cache types (metadata, artwork, downloads, Nuke)
   - Methods: `refreshCacheInfo()`, `clearCache(type:)`, `clearAllCaches()`
   - Used by Settings UI to show users storage usage

**Usage Flow:**
```swift
// During library sync - pre-download artwork for offline use
let albums = try await libraryRepository.fetchAlbums()
let count = try await artworkLoader.predownloadArtwork(
    for: albums.map { /* convert to CDAlbum */ },
    sourceKey: sourceCompositeKey,
    size: 500
)

// In UI - artwork loads from cache automatically
ArtworkView(album: album, size: .medium)
// → Checks local cache using album.id (ratingKey)
// → Falls back to network if not found
// → Caches for next time
```

**Benefits:**
- Artwork persists across app launches
- Reduced network traffic after initial sync
- Faster loading on subsequent views
- Supports offline viewing (when track files are also downloaded)
- Memory efficient (iOS 15+ / 2GB RAM compatible)

### Waveform Visualization System

The app implements an intelligent waveform visualization system that displays audio waveforms in the NowPlayingView:

**Architecture:**

1. **Plex Sonic Analysis (Preferred)** — Uses Plex server's loudness analysis data
   - Plex servers perform sonic analysis on tracks (requires Plex Pass)
   - Analysis generates loudness timeline data (similar to Plexamp's "SoundPrints")
   - Data is accessed via `/library/metadata/{ratingKey}/loudness` endpoint
   - Returns ~100-200 loudness samples representing the track's audio profile
   - This is the same data Plexamp uses for waveform seeking

2. **PlexLoudnessTimeline** (`EnsembleAPI`) — Model for Plex loudness data
   - Decodes loudness arrays from Plex server response
   - Handles multiple response formats (array or comma-separated string)
   - Field: `loudness: [Double]?` — Array of loudness values

3. **PlexAPIClient.getLoudnessTimeline()** (`EnsembleAPI`) — API method to fetch waveform data
   - Asynchronously fetches loudness timeline for a track
   - Returns `nil` if server hasn't performed sonic analysis yet
   - Non-blocking and fails gracefully (missing data is normal, not an error)

4. **PlaybackService.generateWaveform()** (`EnsembleCore`) — Waveform generation logic
   - **Primary:** Attempts to fetch real loudness data from Plex server
   - **Fallback:** Generates pseudo-random waveform if Plex data unavailable
   - Normalizes loudness values to 0.3-1.0 range with contrast enhancement (power curve)
   - Applies floor boosting for better visual prominence and contrast
   - Runs asynchronously to avoid blocking playback

5. **WaveformView** (`EnsembleUI`) — SwiftUI visualization component
   - Displays waveform as horizontal bars with variable heights
   - Shows playback progress (played vs unplayed portions)
   - Supports both real Plex data and fallback visualization
   - Automatically updates when track changes

**Implementation Flow:**
```swift
// In PlaybackService when track changes
private func generateWaveform(for ratingKey: String) {
    Task {
        // Try to fetch from Plex
        if let timeline = try await apiClient.getLoudnessTimeline(for: ratingKey),
           let loudness = timeline.loudness {
            // Use real waveform data
            self.waveformHeights = normalizeLoudnessData(loudness)
        } else {
            // Fallback to pseudo-random waveform
            self.waveformHeights = generateFallbackWaveform(for: ratingKey)
        }
    }
}

// In NowPlayingView
WaveformView(
    progress: viewModel.progress,
    color: .white,
    heights: viewModel.waveformHeights
)
```

**Plex Sonic Analysis:**
- **Purpose:** Enables features like "Sonically Similar Albums", "Track Radio", and waveform visualization
- **Requirement:** Plex Pass subscription
- **Setup:** Server → Settings → Library → "Perform sonic analysis for music"
- **Processing:** Analyzes loudness, tempo, timbre, and harmony
- **Timeline:** Sonic analysis runs as scheduled task or during library scans

**Fallback Waveform:**
- Deterministic pseudo-random generation based on track ID
- Generates consistent waveform for same track across sessions
- Creates realistic-looking patterns with multiple peaks
- ~120 samples for smooth visualization
- Used when Plex sonic analysis hasn't been performed

**Benefits:**
- Real audio waveforms when Plex sonic analysis available
- Graceful degradation to attractive fallback visualization
- No client-side audio processing required (no battery/memory impact)
- Leverages existing Plex infrastructure (same as Plexamp)
- Non-blocking async loading doesn't delay playback

**Future Enhancements:**
- Cache waveform data locally to reduce repeated API calls
- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming

### Hub-Based Home Screen

The app features a dynamic home screen powered by Plex's hub system:

**Architecture:**
- `Hub` domain model — Represents content sections (Recently Added, Recently Played, Most Played, etc.)
- `HubItem` domain model — Individual items within a hub (can be tracks, albums, artists, playlists)
- `HomeViewModel` — Loads hub data from Plex API with 2s debouncing to prevent rapid reloads
- `HomeView` — Displays horizontally-scrolling sections with navigation to detail views

**Implementation Details:**
- Uses `Task.detached` for non-blocking hub loading
- Supports hub-specific navigation (tapping an item navigates to appropriate detail view)
- Fetches from Plex API's `/hubs` endpoint
- Automatically refreshes when accounts change

**User Experience:**
- Provides personalized music discovery
- Quick access to recently added content
- Shows listening history and favorites
- Mimics Plex's web/mobile interface patterns

### Advanced Filtering System

Comprehensive filtering with persistence across app launches:

**FilterOptions Model** (`EnsembleCore/Models/FilterOptions.swift`):
- `searchText` — Text search across titles, artists, albums
- `sortOption` — Generic sort options (title, artist, album, duration, track number, etc.)
- `sortDirection` — Ascending or descending
- `selectedGenreIds` — Multi-select genre filtering
- `selectedArtistIds` — Multi-select artist filtering
- `yearRange` — Closed range for filtering by release year
- `onlyDownloaded` — Toggle to show only offline content

**FilterPersistence:**
- Saves filters to UserDefaults per-view (e.g., "albumsFilter", "songsFilter")
- Automatic serialization using Codable
- Survives app restarts

**UI Components:**
- `FilterSheet` — Full-screen filter interface with:
  - Search bar
  - Sort option picker
  - Genre multi-select (chips)
  - Artist multi-select (chips)
  - Year range slider
  - Downloaded-only toggle

**Usage in ViewModels:**
- All list ViewModels support `FilterOptions`
- `filteredTracks`, `filteredAlbums`, etc. computed properties apply filters
- Real-time filtering as user types or changes selections

### Network State Management

Multi-layered network resilience for reliable streaming:

**NetworkMonitor Service** (`EnsembleCore/Services/NetworkMonitor.swift`):
- Uses `NWPathMonitor` for OS-level connectivity detection
- MainActor-isolated for direct UI updates
- 1s debouncing to prevent rapid state changes
- Published properties: `isConnected`, `networkState`, `networkType`
- Detects: WiFi, Cellular, Wired, Unknown connection types
- States: `.online`, `.offline`, `.limited`, `.unknown`

**ServerHealthChecker Service** (`EnsembleCore/Services/ServerHealthChecker.swift`):
- Concurrent health checks for all configured servers
- Returns `ServerConnectionState` per server (connected/connecting/disconnected/error)
- Tests connection URLs in priority order: Local → Direct → Relay
- Used by sync operations to avoid offline servers

**ConnectionFailoverManager** (`EnsembleAPI/Client/ConnectionFailoverManager.swift`):
- Automatic failover between server connection URLs
- Retries failed requests on alternate URLs
- Updates preferred connection for future requests

**UI Integration:**
- `ConnectionStatusBanner` — Shows warning when offline/limited
- Status indicators throughout the app
- `StatusColor` enum provides consistent color coding (green/yellow/red/gray)

**App Lifecycle Integration:**
- iOS: Network monitor starts in `AppDelegate` (delayed 500ms to avoid blocking launch)
- macOS: Stops monitoring when app goes to background (energy efficiency)
- Proactive server health checks on foreground transition

### Customizable UI Settings

User customization via `SettingsManager` (`EnsembleCore/Services/SettingsManager.swift`):

**Accent Colors:**
- `AppAccentColor` enum with 7 colors: `.purple` (default), `.blue`, `.pink`, `.red`, `.orange`, `.yellow`, `.green`
- Stored in `@AppStorage("accentColor")`
- Applied app-wide via `.tint()` modifier

**Customizable Tabs:**
- `TabItem` enum with 10 available tabs:
  - Core: Home, Artists, Albums, Songs, Playlists, Genres
  - Features: Search, Downloads, Favorites, More
- Users can enable/disable tabs via Settings
- Default enabled tabs: Home, Artists, Playlists, Search
- Stored in `@AppStorage("enabledTabs")` as array of raw values
- Tab order preserved, just hidden when disabled

**Settings UI:**
- `SettingsView` provides interface for all customization
- Real-time preview of accent colors
- Toggle switches for each tab
- Cache management controls

### Favorites System

Quick access to highly-rated music:

**Implementation:**
- `FavoritesViewModel` — Filters tracks with `userRating >= 8.0` (4+ stars out of 5)
- `FavoritesView` — Dedicated screen in app navigation
- Implements `MediaDetailViewModelProtocol` for consistency with Album/Artist/Playlist views
- Reuses `MediaDetailView` for unified UI

**Features:**
- Shows all favorited tracks across all sources
- Supports all standard track list features (play, queue, shuffle, etc.)
- Filtering and sorting like other library views
- Real-time updates when ratings change

### App Targets

- **Ensemble** (`Ensemble/Ensemble/`) — iOS/iPadOS/macOS app target
  - Entry point: `EnsembleApp.swift` — Scene-based lifecycle with environment injection
  - Audio config: `AppDelegate.swift` (iOS only, UIApplicationDelegate) — Handles:
    - AVAudioSession configuration for background playback
    - Remote command center setup (play/pause/skip controls on lock screen)
    - Network monitoring lifecycle (delayed start 500ms to avoid blocking launch)
    - Proactive server health checks on foreground transition
  - Platform-specific behavior:
    - iOS: Full feature set, background playback, remote controls
    - macOS: Network monitoring stops on background for energy efficiency
  - Supports iOS 15+, requires iOS 16+ for full feature set

- **EnsembleWatch** (`Ensemble/EnsembleWatch/`) — watchOS app target
  - Entry point: `EnsembleWatchApp.swift`
  - All views consolidated in `WatchRootView.swift`:
    - `WatchRootView` — Root with auth state management
    - `WatchLoginView` — PIN authentication flow
    - `WatchMainView` — Tab-based navigation
    - `WatchNowPlayingView` — Playback controls
    - `WatchLibraryView` — Recent tracks list
  - Simplified UI: authentication, library browsing, now playing controls
  - **⚠️ CRITICAL ISSUE:** References `DependencyContainer.shared.makeAuthViewModel()` on line 5 which does not exist
    - **Impact:** watchOS app won't compile
    - **Fix:** Create `AuthViewModel` or refactor watchOS to use `AddPlexAccountViewModel`

## External Dependencies

- **KeychainAccess** (4.2.0+) — Secure token storage (EnsembleAPI)
  - Used by: `KeychainService` for auth token persistence
  - SPM: `https://github.com/kishikawakatsumi/KeychainAccess.git`
- **Nuke** (12.0.0+) — High-performance image loading and caching
  - Used by: `ArtworkLoader` (EnsembleCore) and `ArtworkView` (EnsembleUI via NukeUI)
  - SPM: `https://github.com/kean/Nuke.git`
  - Products: `Nuke` (Core) and `NukeUI` (SwiftUI views)

## Known Issues & Technical Debt

### Critical
- **watchOS Authentication Missing** — `EnsembleWatch/Views/WatchRootView.swift:5`
  - **Issue:** References `DependencyContainer.shared.makeAuthViewModel()` which does not exist
  - **Impact:** watchOS app won't compile
  - **Root Cause:** iOS uses `AddPlexAccountViewModel`, watchOS was designed with different auth flow
  - **Fix Options:**
    1. Create `AuthViewModel` in EnsembleCore and add factory method to DependencyContainer
    2. Refactor watchOS to use existing `AddPlexAccountViewModel`
    3. Create watchOS-specific auth flow that matches iOS patterns

### Feature Completeness
- **Offline Playback Infrastructure Exists But Not Wired Up**
  - `DownloadManager` handles track file downloads
  - `DownloadsView` shows download queue
  - Missing: Wire up audio file downloads to `PlaybackService` for true offline playback

- **Artwork Pre-Caching Not Automatic**
  - `ArtworkLoader.predownloadArtwork()` methods exist
  - Not currently called during library sync
  - Would improve offline experience if wired up to `SyncCoordinator`

### Infrastructure
- ✅ **Legacy CocoaPods Cleanup** — Removed unused `ios/Pods/` directory (was leftover from earlier experimentation)

### Documentation
- ✅ **Documentation Fully Updated** — CLAUDE.md now reflects all implemented features including:
  - Hub-based home screen
  - Advanced filtering system
  - Network state management
  - Customizable UI settings
  - Favorites system
  - All new UI components
  - Complete service layer documentation

## Development Guidelines

### Code Style
- Use clear, descriptive variable/function names
- Add comments to explain "what" each logical section does (not "how" — code should be self-documenting)
- Don't over-comment — focus on complex logic and architectural decisions

### Memory & Performance
- **Target:** iOS 15+ devices with 2GB RAM (iPhone 6s, iPad Air 2)
- Fetch in batches from CoreData
- Use `@FetchRequest` limits and offsets for large lists
- Lazy-load images with Nuke
- Background context for heavy CoreData operations

### Testing
- Unit tests for business logic (services, repositories)
- Integration tests for sync flows
- Not required for simple ViewModels or UI-only code
- Not accounting for edge cases during early development (pre-beta)

### Multi-Source Architecture
When adding support for new music sources (Apple Music, Spotify, etc.):
1. Create new provider implementing `MusicSourceSyncProvider` protocol
2. Add source type to `MusicSourceType` enum
3. Register provider in `SyncCoordinator.refreshProviders()`
4. Add account configuration model similar to `PlexAccountConfig`
5. Update `AccountManager` to handle new account type

## Common Tasks

### Adding a New ViewModel
1. Create in `Packages/EnsembleCore/Sources/ViewModels/`
2. Make it `@MainActor class ... ObservableObject`
3. Add factory method to `DependencyContainer`
4. Inject dependencies via initializer

### Adding a New View
1. Create in `Packages/EnsembleUI/Sources/Screens/` or `.../Components/`
2. Inject ViewModel via `@StateObject` using `DependencyContainer.shared.makeXViewModel()`
3. Access environment dependencies: `@Environment(\.dependencies) var deps`

### Adding a New CoreData Entity
1. Update `Ensemble.xcdatamodeld` in `Packages/EnsemblePersistence/Sources/CoreData/`
2. Create `@objc(CDEntityName)` class in `ManagedObjects.swift`
3. Add domain model in `EnsembleCore/Sources/Models/DomainModels.swift`
4. Add mapper in `ModelMappers.swift`
5. Update relevant repository

### Running a Full Sync
```swift
// In any ViewModel or View with access to DependencyContainer
Task {
    await deps.syncCoordinator.syncAll()
}
```

