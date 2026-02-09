# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


## Workflow (MUST follow for every task)

**Before writing any code**, set up a git worktree:

1. **Create a branch** from `develop` with a descriptive name:
   - Features: `feat/{branch-name}`
   - Bug fixes: `fix/{branch-name}`
   - Refactors: `refactor/{branch-name}`
   - Docs: `docs/{branch-name}`
2. **Create the worktree** in `../ensemble-worktrees/{branch-name}/`
3. **Do all work inside the worktree**, not in the main repo directory
4. **When finished**, create a PR that merges back into `develop`

Example:
```bash
git worktree add -b feat/queue-reorder ../ensemble-worktrees/feat/queue-reorder develop
cd ../ensemble-worktrees/feat/queue-reorder
# ... do work here ...
```

**Commit discipline:**
- Git commit after each logical "step" when implementing a plan
- Always commit before waiting for the user to test (so changes can be rolled back if context is lost or something breaks)

## Coding Style

This project is connected to Xcode's MCP server: please use it to inform you of how best to operate.

Leave doc comments and comments above classes and other elements so that both the user and the agent know what's going on: keep this up to date.

As you make big architectural changes, please update this document and the README.md file as necessary.

Please don't remove existing functionality (unless directed) when re-architecting parts of the code. I've had to re-implement multiple things that I had asked for and that were removed.

## Troubleshooting

When a problem is mentioned, **interview the user first** to help hone in on where the problem is originating from — don't jump straight to code changes. Ask clarifying questions about when it happens, what they see, and what they expect.

When investigating, add logs to the appropriate files so debugging can be more efficient. Remove or reduce log verbosity once the issue is resolved.

## Using the Gemini CLI

You have access to the Gemini CLI (`gemini -p`) which leverages Google Gemini's massive context window. Use it as a complementary tool in the following situations:

**When to use Gemini:**
- **Large codebase analysis:** When you need to analyze many files or large amounts of code that might strain your context limits, pipe content to `gemini -p` to take advantage of its large context capacity.
- **UI implementation:** Gemini excels at identifying UI patterns and implementing SwiftUI views. When implementing UI changes, **plan the approach here in Claude first**, then delegate the implementation to Gemini. Review and integrate what it produces.

**When NOT to use Gemini:**
- **Architectural decisions:** Do not delegate architectural changes, structural refactors, or design decisions to Gemini. All architectural planning and decisions must stay in Claude.
- **Planning:** Claude handles all planning. Gemini is an implementation tool, not a planning tool.

**Typical workflow for UI changes:**
1. **Claude:** Plan the UI change (what views to create/modify, what patterns to follow, what components to reuse)
2. **Gemini:** Implement the planned UI code via `gemini -p` with the plan and relevant context
3. **Claude:** Review the output, integrate it, and ensure it follows project conventions

## Project Overview

Ensemble is a universal Plex Music Player built with SwiftUI, targeting iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It streams music from Plex servers using PIN-based OAuth authentication. It is very important features work on iOS 15, and are memory and speed optimized for devices with 2GB or less of RAM.

Right now, this app is not released to the public, and isn't in beta. As a result, we don't need to account for edge cases as we're developing the CoreData model.

The goal of this app is to provide a beautiful, information-dense, and customizable native experience for the Plex server.

Please comment code so that it's understandable. Don't over comment, just comment on what each "piece" does.

As you make big architectural changes, please be sure to update this document and the README.md file to describe the app structure in a way that helps both you and me.

Do not use emojis (except in debugging).

## UI/UX Design Principles & Conventions

These are core design decisions that should be maintained throughout the app. When implementing new features or making changes, adhere to these principles:

### Navigation Behavior

**Tab Navigation:**
- **Pop-to-root on re-tap:** When a tab button is tapped while already selected, the app should pop to root if there's a navigation stack, otherwise request focus (for Search tab)
- **Implementation:** See `MainTabView.handleTabTap()` for reference implementation
- **Haptic feedback:** Tab taps trigger `UISelectionFeedbackGenerator` for tactile response
- **More tab support:** The app displays first 4 enabled tabs in the tab bar, with remaining tabs accessible via "More" tab (5th position)
- **Tab customization:** Users can enable/disable tabs via Settings; disabled tabs are hidden from the tab bar
- **Visible tabs synchronization:** `NavigationCoordinator.visibleTabs` is synced from MainTabView to enable fallback logic when navigating from Now Playing

**Deep Linking:**
- **NavigationCoordinator.Destination:** Use typed destinations (artist, album, playlist, view) for all deep links
- **Pending navigation:** When navigating from sheets (like Now Playing), set `pendingNavigation` to defer navigation until sheet dismisses
- **Tab fallback:** If navigating from Search tab (or hidden tab), fall back to first visible tab via `visibleTabs.first ?? .home`

**iOS 15 Compatibility:**
- **iOS 16+:** Use `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** Use `NestedNavigationLink` recursive pattern in `MainTabView.swift` for multi-level navigation
- **Feature detection:** Always wrap iOS 16+ features in `@available(iOS 16.0, *)` checks

### Native UI Components

**Tab Bar:**
- **Stay native:** The tab bar uses SwiftUI's native `TabView` and should remain that way unless there's a compelling reason to change
- **Immersive mode:** Tab bar can be hidden via `ChromeVisibilityPreferenceKey` preference (used in CoverFlow and full-screen experiences)
- **iOS 18+:** Uses `.sidebarAdaptable` tab view style when available for modern iOS appearance
- **Mini player offset:** Mini player sits 56pt above tab bar on iPhone to avoid overlap

**System Integration:**
- **Use pre-existing elements:** Leverage native SwiftUI components and iOS system features where possible (e.g., `AVRoutePickerView` for AirPlay, `MPRemoteCommandCenter` for lock screen controls)
- **Platform adaptivity:** Views should adapt to platform idioms (tab bar on iPhone, sidebar on iPad/macOS)
- **Safe area respect:** Content should respect safe areas unless deliberately edge-to-edge (like CoverFlow)

### Visual Design

**Artwork Display:**
- **Consistent sizing:** Hub items use 140x140pt artwork; detail views adapt based on context
- **Corner radius:** Albums/playlists use 8pt radius; artists use 70pt (circular)
- **Shadows:** Use `Color.black.opacity(0.15)` with radius 6 for card depth
- **Blurred backgrounds:** NowPlayingView and detail views use `BlurredArtworkBackground` for efficient, beautiful backgrounds

**Typography & Spacing:**
- **System fonts:** Use SF Pro (system default) with semantic font styles (.headline, .subheadline, etc.)
- **Line limits:** Truncate long text with `.lineLimit(1)` or use `MarqueeText` for auto-scrolling
- **Information density:** Aim for information-dense layouts without clutter

### Loading & Error States

**Async Loading:**
- **DetailLoader pattern:** Use `AlbumDetailLoader`, `ArtistDetailLoader`, `PlaylistDetailLoader` for hub-to-detail navigation
- **Loading indicators:** Show `ProgressView` with descriptive text during async operations
- **Error handling:** Display error messages with retry options; never crash or show empty screens without explanation
- **Offline-first:** Load cached data immediately, then fetch fresh data in background

**Hub Loading:**
- **2-second debouncing:** Hub fetches are debounced to prevent rapid successive loads
- **Fallback logic:** If fewer than 3 section hubs, fall back to global hubs
- **Empty states:** Use `EmptyLibraryView` with clear sync prompts when no data available

### Performance Optimization

**Memory Efficiency (iOS 15 / 2GB RAM):**
- **Lazy loading:** Use `LazyVGrid`, `LazyVStack`, and lazy image loading via Nuke
- **Background contexts:** Heavy CoreData operations use background contexts via `CoreDataStack.performBackgroundTask`
- **Image caching:** Artwork uses two-tier caching (filesystem + Nuke's in-memory cache) with 100MB disk cache limit
- **Task.detached:** Use for non-blocking background work to avoid main thread stalls

**Debouncing:**
- **Network monitor:** 1s debouncing to reduce unnecessary UI updates
- **Home screen loading:** 2s debouncing to prevent rapid reloads
- **App launch:** Network monitor starts with 500ms delay to avoid blocking launch

### Code Documentation

**Comment Guidelines:**
- **"What" not "how":** Comment on what each logical section does, not how Swift works
- **Class/function headers:** Include doc comments (`///`) for all public types and methods
- **Complex logic:** Explain non-obvious algorithms, formulas, or architectural decisions
- **Avoid over-commenting:** Self-documenting code is preferred; don't comment the obvious

**Change Documentation:**
- **Update CLAUDE.md:** When making architectural changes, update this file with new patterns and conventions
- **Update README.md:** Keep user-facing documentation in sync with implemented features
- **Git commits:** Commit after each logical step with descriptive messages; always commit before waiting for testing
- **Code comments:** Leave comments in the code itself so future developers (including AI assistants) understand the design

### Feature Philosophy

**Preserve Existing Functionality:**
- **Don't remove features:** When refactoring, preserve existing functionality unless explicitly directed to remove it
- **Backward compatibility:** Maintain iOS 15 support; use feature detection for newer OS features
- **User preferences:** Respect user settings (accent colors, enabled tabs, filter preferences)

**Incremental Enhancement:**
- **Build on existing code:** Extend rather than replace working components
- **Reuse patterns:** Use established patterns (DetailLoader, HubRepository, FilterOptions) for consistency
- **Test on target devices:** iOS 15 devices with 2GB RAM are the minimum target

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
  - Core methods: `fetchLibraries()`, `fetchTracks()`, `fetchAlbums()`, `fetchArtists()`, etc.
  - Playback tracking: `reportTimeline()`, `scrobble()`
  - Waveform data: `getLoudnessTimeline(forStreamId:subsample:)`
- `KeychainService` — Token persistence using KeychainAccess library
- `PlexModels.swift` — Response types (`PlexServer`, `PlexLibrary`, `PlexTrack`, `PlexLoudnessTimeline`, etc.)

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
│   ├── SettingsManager.swift          # App settings (accent colors, customizable tabs)
│   ├── HubRepository.swift            # Hub data persistence (CDHub/CDHubItem)
│   └── HubOrderManager.swift          # User-customizable hub section ordering
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
- `SyncCoordinator` (@MainActor) — Orchestrates library syncing across all enabled sources; provides timeline reporting and scrobbling methods
- `NavigationCoordinator` (@MainActor) — Manages cross-view navigation state (artist/album deep links from NowPlayingView)
  - Maintains per-tab navigation paths (homePath, artistsPath, etc.)
  - `visibleTabs: [TabItem]` — Synced from MainTabView to enable fallback logic
  - `navigateFromNowPlaying()` — Falls back to first visible tab when navigating from Search
  - `pendingNavigation` — Deferred navigation executed after sheet dismissal
- `PlaybackService` — AVPlayer management, queue, shuffle, repeat, remote controls, timeline reporting (every 10s), and scrobbling (at 90% completion)
- `HubRepository` — Repository for hub data persistence (implements `HubRepositoryProtocol`); manages CDHub/CDHubItem entities
- `HubOrderManager` — Manages user-customizable hub section ordering per music source
  - Persists custom order to UserDefaults with per-source keys
  - `applyOrder(to:for:)` — Reorders fetched hubs according to saved preferences
  - `saveOrder(_:for:)` / `saveDefaultOrder(_:for:)` — Stores custom and default orders
  - `resetToDefaultOrder(for:)` — Restores server's original hub order
- `ArtworkLoader` — Persistent artwork caching with local-first loading strategy
- `CacheManager` (@MainActor) — Tracks cache sizes and provides cache clearing functionality
- `NetworkMonitor` (@MainActor) — Proactive network connectivity monitoring using NWPathMonitor with 1s debouncing
- `ServerHealthChecker` — Concurrent health checks for all configured servers with automatic failover
- `SettingsManager` (@MainActor) — Manages accent colors and customizable tab configuration

**Key Models:**
- Domain models: `Track`, `Album`, `Artist`, `Genre`, `Playlist`, `Hub`, `HubItem` (UI-facing, protocol-conforming)
  - `Track` includes `streamId: Int?` — Identifies audio stream for fetching loudness timeline data (waveform visualization)
- `MusicSource` / `MusicSourceIdentifier` — Multi-account source tracking
- `PlexAccountConfig` — Account/server/library hierarchy for configuration
- `FilterOptions` — Comprehensive filtering with search, sort, genre/artist filters, year ranges, downloaded-only toggle
  - Includes `FilterPersistence` utility class for saving/loading filter state per-view to UserDefaults
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
│   ├── AlbumDetailLoader.swift       # Async loader for album detail with loading/error states
│   ├── ArtistCard.swift              # Grid card for artists
│   ├── ArtistDetailLoader.swift      # Async loader for artist detail with loading/error states
│   ├── ArtworkColorExtractor.swift   # Actor-based color extraction from artwork for dynamic gradients
│   ├── ArtworkView.swift             # Lazy-loading artwork with Nuke
│   ├── BlurredArtworkBackground.swift # Heavily blurred artwork background with contrast/saturation
│   ├── ChromeVisibilityPreferenceKey.swift # SwiftUI preference key for hiding tab bar in immersive views
│   ├── CompactSearchRows.swift       # Compact row layouts for search results
│   ├── ConnectionStatusBanner.swift  # Network status UI indicator
│   ├── CoverFlowView.swift           # 3D carousel with perspective rotation and scaling
│   ├── CoverFlowItemView.swift       # Individual item in CoverFlow carousel
│   ├── CoverFlowDetailView.swift     # Flipped detail view for CoverFlow items
│   ├── EmptyLibraryView.swift        # Empty state with sync prompt
│   ├── FilterSheet.swift             # Advanced filtering UI with persistence
│   ├── FlipOpacity.swift             # View modifier for flip animations
│   ├── GenreCard.swift               # Grid card for genres
│   ├── HubOrderingSheet.swift        # Sheet for reordering hub sections with drag & drop
│   ├── KeyboardObserver.swift        # iOS-specific keyboard height tracking with view modifier
│   ├── MarqueeText.swift             # Auto-scrolling text component for long titles
│   ├── MediaTrackList.swift          # Reusable track list with context menu
│   ├── MiniPlayer.swift              # Compact persistent player overlay
│   ├── PlaylistCard.swift            # Grid card for playlists
│   ├── PlaylistDetailLoader.swift    # Async loader for playlist detail with loading/error states
│   ├── ScrollIndex.swift             # A-Z index for fast scrolling
│   ├── TrackRow.swift                # Single track row with artwork
│   ├── View+Extensions.swift         # SwiftUI view extensions and helpers
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
  - `HubSection` (inline) — Container for individual hub sections with title and horizontal scrolling items
  - `HubItemCard` (inline) — Cards within hubs displaying albums/artists/tracks/playlists with artwork and navigation
- `FavoritesView` — Displays tracks rated 4+ stars
- `FilterSheet` — Advanced filtering UI with artist/genre multi-select, year ranges, downloaded-only filter
- `AlbumDetailLoader` / `ArtistDetailLoader` / `PlaylistDetailLoader` — Async loading wrappers with loading/error states for detail views
  - Used by HomeView's HubItemCard for smooth navigation from hubs to detail views
  - Fetches full entity data from CoreData before showing detail view
  - Displays loading spinner, error messages, or "not found" states
- `ArtworkColorExtractor` — Actor-based color extraction from artwork images; determines dominant/accent colors and background lightness for dynamic gradients
- `ConnectionStatusBanner` — Network connectivity status banner
- `AirPlayButton` — Native AirPlay route picker integration
- `WaveformView` — Audio waveform visualization with real Plex loudness data or fallback generation
- `MarqueeText` — Auto-scrolling text component for long titles that exceed container width
- `KeyboardObserver` — iOS-specific keyboard height tracking with `.keyboardAware()` modifier for automatic bottom padding
- `HubOrderingSheet` — Drag-to-reorder interface for customizing hub section order per music source
- `CoverFlowView` — 3D carousel view with perspective rotation, scaling, and tap-to-zoom/flip interactions
  - `CoverFlowItemView` — Individual carousel items with 3D transforms
  - `CoverFlowDetailView` — Flipped card detail view for zoomed items
- `ChromeVisibilityPreferenceKey` — SwiftUI preference key for hiding tab bar in immersive experiences (CoverFlow, etc.)
- `CompactSearchRows` — Compact result layouts for search interface
- `GenreCard` — Grid card component for genre browsing

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
- **iOS 15 Support** — Compatibility layer for older iOS versions
  - `NestedNavigationLink` in MainTabView provides recursive navigation for iOS 15 (no NavigationStack)
  - DetailLoader pattern with traditional NavigationLink for hub navigation
  - Conditional @available checks throughout for iOS 16+ features

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
   - Asynchronously fetches loudness timeline for a track using `streamId`
   - `streamId` identifies the audio stream for the track (stored in `Track.streamId`)
   - Returns `nil` if server hasn't performed sonic analysis yet
   - Non-blocking and fails gracefully (missing data is normal, not an error)

4. **PlaybackService.generateWaveform()** (`EnsembleCore`) — Waveform generation logic
   - **Primary:** Attempts to fetch real loudness data from Plex server using track's `streamId`
     - Fetches from `/library/streams/{streamId}/levels` endpoint
     - API method: `PlexAPIClient.getLoudnessTimeline(forStreamId:subsample:)`
     - Returns `nil` gracefully if sonic analysis not yet performed
   - **Fallback:** Generates pseudo-random waveform if Plex data unavailable or `streamId` missing
     - Deterministic generation seeded by track's `ratingKey`
     - ~120 samples for smooth visualization
     - Creates realistic patterns with multiple peaks
   - **Normalization:** `normalizeLoudnessData()` method
     - Maps loudness values to 0.1-1.0 range for visual impact
     - Applies 1.5 exponent power curve for contrast enhancement
     - Formula: `pow((value - minValue) / (maxValue - minValue), 1.5) * 0.9 + 0.1`
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
  - Includes `sourceCompositeKey` for offline-first artwork loading
  - Contains `track` reference for direct track playback
  - Supports `thumbPath` for artwork URLs
- `HomeViewModel` — Loads hub data from Plex API with 2s debouncing to prevent rapid reloads
- `HomeView` — Displays horizontally-scrolling sections with navigation to detail views
  - `HubSection` (inline struct) — Individual hub section with title and horizontal scroll
  - `HubItemCard` (inline struct) — Cards displaying hub items with type-specific styling
    - Circular artwork for artists (cornerRadius: 70)
    - Rounded artwork for albums/playlists (cornerRadius: 8)
    - Shadow effects for depth (black.opacity(0.15), radius: 6)
    - 140x140pt artwork size for consistency

**Implementation Details:**
- Uses `Task.detached` for non-blocking hub loading
- Supports hub-specific navigation:
  - **iOS 16+:** Uses NavigationLink(value:) with NavigationCoordinator.Destination
  - **iOS 15:** Uses traditional NavigationLink with DetailLoader components
  - **Tracks:** Direct play via button action (no navigation)
- Fetches from Plex API's `/hubs` endpoints:
  - `getHubs(sectionKey:)` — Section-specific hubs with count and includeLibrary params
  - `getGlobalHubs()` — Global hubs across all libraries with music-type filtering
  - `getHubItems(hubKey:)` — Items for specific hub by key
- Automatically refreshes when accounts change
- **Fallback logic:** If fewer than 3 section hubs found, falls back to global hubs

**User Experience:**
- Provides personalized music discovery
- Quick access to recently added content
- Shows listening history and favorites
- Mimics Plex's web/mobile interface patterns
- Pull-to-refresh support for manual updates
- Empty state with error messages and refresh button

**Hub Persistence:**
- `HubRepository` service (implements `HubRepositoryProtocol`)
- Manages `CDHub` and `CDHubItem` CoreData entities
  - `CDHub` — Stores hub metadata with `order` field for sorting
  - `CDHubItem` — Stores item data including sourceCompositeKey for offline support
  - Ordered relationships preserve hub and item order
- Methods: 
  - `fetchHubs()` — Retrieves cached hubs sorted by order
  - `saveHubs()` — Persists hubs to CoreData (clears existing first)
  - `deleteAllHubs()` — Removes all cached hub data
- Used by `HomeViewModel` for offline-first loading
  - Loads cached hubs immediately on init
  - Fetches fresh data in background
  - Updates UI when fresh data arrives

**DetailLoader Pattern:**
The app uses async DetailLoader components for smooth hub-to-detail navigation:
- `AlbumDetailLoader` / `ArtistDetailLoader` / `PlaylistDetailLoader`
- Async fetches full entity data from CoreData by ratingKey
- Shows loading spinner while fetching
- Displays error state if fetch fails
- Renders actual detail view (AlbumDetailView, etc.) once loaded
- This pattern enables:
  - Offline-first hub item display (minimal data in HubItem)
  - Smooth transitions with loading feedback
  - Graceful error handling
  - Separation of hub data from full entity data

### Timeline Reporting & Scrobbling

The app reports playback activity back to Plex servers for accurate tracking and personalized recommendations:

**Architecture:**

**Timeline Reporting:**
- **Purpose:** Informs Plex servers about current playback state (playing/paused/stopped) and progress
- **Frequency:** Every 10 seconds during active playback
- **Implementation:**
  - `PlaybackService` tracks `lastTimelineReportTime` to control reporting interval
  - Calls `SyncCoordinator.reportTimeline()` which delegates to appropriate provider
  - `PlexMusicSourceSyncProvider` passes through to `PlexAPIClient.reportTimeline()`
  - HTTP POST to `/:/timeline` with state, time, duration, and track metadata

**Scrobbling:**
- **Purpose:** Marks a track as "played" in Plex's database for play counts and Recently Played hubs
- **Trigger:** Automatically at 90% track completion
- **Implementation:**
  - `PlaybackService` tracks `hasScrobbled` flag to ensure one scrobble per track
  - Calls `SyncCoordinator.scrobbleTrack()` which delegates to appropriate provider
  - `PlexMusicSourceSyncProvider` passes through to `PlexAPIClient.scrobble()`
  - HTTP POST to `/:/scrobble` with track's `ratingKey`

**Protocol Integration:**
- `MusicSourceSyncProvider` protocol includes:
  - `reportTimeline(ratingKey:key:state:time:duration:)` — Required for timeline reporting
  - `scrobble(ratingKey:)` — Required for scrobbling
- Enables multi-source architecture support (future Apple Music, Spotify integration)

**State Management:**
- Both tracking fields reset automatically when changing tracks
- Non-blocking async implementation to avoid playback interruption
- Gracefully handles network failures without disrupting playback

**Benefits:**
- Accurate play counts and listening history
- Populates "Recently Played" and "Most Played" hubs
- Enables Plex's recommendation algorithms
- Syncs listening activity across all Plex clients
- Maintains compatibility with Plex ecosystem features

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

### DetailLoader Pattern

Async loading wrapper components for smooth hub-to-detail navigation:

**Architecture:**
Three specialized loader components in `EnsembleUI/Sources/Components/`:
- `AlbumDetailLoader` — Loads full album data by ratingKey
- `ArtistDetailLoader` — Loads full artist data by ratingKey
- `PlaylistDetailLoader` — Loads full playlist data by ratingKey

**Implementation:**
Each DetailLoader follows the same pattern:
```swift
struct AlbumDetailLoader: View {
    let albumId: String  // ratingKey from HubItem
    @State private var album: Album?
    @State private var isLoading = true
    @State private var error: Error?
    
    var body: some View {
        if let album = album {
            AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
        } else if isLoading {
            ProgressView() + "Loading album..."
        } else if let error = error {
            ErrorView(error: error)
        } else {
            "Album not found"
        }
    }
    
    .task {
        // Async fetch from CoreData via libraryRepository
        album = try await deps.libraryRepository.fetchAlbum(ratingKey: albumId)
    }
}
```

**Usage:**
- Used by `HomeView`'s `HubItemCard` for iOS 15 navigation fallback
- Enables offline-first hub display (HubItem contains minimal data)
- Fetches full entity data only when user navigates to detail view
- Provides loading/error states for better UX

**Benefits:**
- **Separation of concerns:** Hub data (lightweight) vs. full entity data (complete)
- **Performance:** Hub items load instantly with minimal data
- **Offline support:** Hubs display even when full sync hasn't completed
- **Error handling:** Graceful degradation if entity not found in CoreData
- **Smooth UX:** Loading spinner during fetch, not blocking navigation

### iOS 15 Compatibility

The app maintains compatibility with iOS 15 while leveraging iOS 16+ features where available:

**Navigation System:**
- **iOS 16+:** Uses `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** Uses traditional `NavigationLink` with destination views via `NestedNavigationLink`

**NestedNavigationLink Pattern:**
Located in `MainTabView.swift`, provides recursive navigation for iOS 15:
```swift
struct NestedNavigationLink<Content: View>: View {
    let path: [NavigationCoordinator.Destination]
    let content: Content
    
    var body: some View {
        if let first = path.first {
            NavigationLink(destination: nextView(for: first)) {
                content
            }
        } else {
            content
        }
    }
    
    private func nextView(for destination: Destination) -> some View {
        NestedNavigationLink(path: Array(path.dropFirst())) {
            // Render destination view (AlbumDetailLoader, etc.)
        }
    }
}
```

**Feature Detection:**
Throughout the codebase, features are conditionally enabled:
```swift
if #available(iOS 16.0, macOS 13.0, *) {
    NavigationStack(path: $coordinator.homePath) { ... }
} else {
    NavigationView {
        NestedNavigationLink(path: coordinator.homePath) { ... }
    }
}
```

**iOS 15 Limitations:**
- No NavigationStack (use NestedNavigationLink instead)
- Some SwiftUI features unavailable (graceful fallbacks provided)
- DetailLoader pattern used more extensively for iOS 15 navigation

**Testing Target:**
- Primary: iOS 15.0+ on devices with 2GB RAM (iPhone 6s, iPad Air 2)
- Optimal: iOS 16.0+ for full feature set

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
- ✅ **Documentation Fully Updated** — CLAUDE.md and README.md now reflect all implemented features including:
  - Hub-based home screen with HubSection/HubItemCard components
  - DetailLoader pattern for async navigation
  - iOS 15 compatibility layer (NestedNavigationLink)
  - NavigationCoordinator with visibleTabs synchronization
  - Advanced filtering system
  - Network state management
  - Customizable UI settings
  - Favorites system
  - Waveform generation with normalization formulas
  - Playback tracking (timeline reporting and scrobbling)
  - HubRepository persistence layer
  - All UI components and services

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

### Troubleshooting
- **Interview first:** When a bug or issue is reported, ask clarifying questions before changing code — understand the symptom, when it occurs, and what's expected
- **Add logs:** Insert temporary logging in relevant code paths to narrow down the problem efficiently
- **Clean up logs:** Remove or reduce log verbosity once the issue is resolved

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

### Working with Hubs
```swift
// Load hubs from Plex API
let hubs = try await deps.syncCoordinator.fetchHubs(for: sourceKey)

// Save hubs to CoreData for offline access
try await deps.hubRepository.saveHubs(hubs)

// Load cached hubs
let cachedHubs = try await deps.hubRepository.fetchHubs()

// Clear all cached hubs
try await deps.hubRepository.deleteAllHubs()
```

### Adding Hub Support to New Content Types
If you need to add support for a new hub item type:
1. Update `HubItem` domain model in `DomainModels.swift` with new type
2. Add case to `HubItemCard.destination` computed property
3. Add case to `HubItemCard.destinationView` ViewBuilder
4. Create DetailLoader if needed (e.g., `GenreDetailLoader`)
5. Update `PlexModels.swift` to decode new type from API
6. Add mapper in `ModelMappers.swift` for Hub/HubItem if needed


