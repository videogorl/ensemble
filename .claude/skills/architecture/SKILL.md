---
name: architecture
description: "Load before designing features, adding services, or touching multiple packages. Ensemble app architecture: package structure, key types, architectural patterns, dependency flow, domain model layers, subsystems (artwork caching, waveform, hubs, filtering, network resilience, playback tracking, playlist mutations, incremental sync, pinned content)"
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
- `PlexAPIClient` (actor) -- Thread-safe API requests with automatic failover
  - Core methods: `fetchLibraries()`, `fetchTracks()`, `fetchAlbums()`, `fetchArtists()`, etc.
  - Playback tracking: `reportTimeline()`, `scrobble()`
  - Waveform data: `getLoudnessTimeline(forStreamId:subsample:)`
- `KeychainService` -- Token persistence using KeychainAccess library
- `PlexModels.swift` -- Response types (`PlexServer`, `PlexLibrary`, `PlexTrack`, `PlexLoudnessTimeline`, etc.)

### EnsemblePersistence (Data Layer)
- **Location:** `Packages/EnsemblePersistence/`
- **Dependencies:** None (pure CoreData)
- **Purpose:** Local caching and offline storage

**Key Types:**
- `CoreDataStack` (singleton) -- Main/background contexts, saves on background queue
- `CD*` models -- `CDMusicSource`, `CDArtist`, `CDAlbum`, `CDTrack`, `CDGenre`, `CDPlaylist`, `CDServer`
- `LibraryRepository` / `PlaylistRepository` -- Protocol-based repository pattern
- `DownloadManager` -- Offline track file management
- `ArtworkDownloadManager` -- Persistent artwork caching to local filesystem

### EnsembleCore (Business Logic Layer)
- **Location:** `Packages/EnsembleCore/`
- **Dependencies:** EnsembleAPI, EnsemblePersistence, Nuke
- **Purpose:** Services, ViewModels, domain models, dependency injection

**Key Services:**
- `DependencyContainer` (singleton) -- Wires all services, creates ViewModels, injected via SwiftUI environment
- `AccountManager` (@MainActor) -- Manages multiple Plex accounts, servers, and libraries
- `SyncCoordinator` (@MainActor) -- Orchestrates library syncing across all enabled sources; provides timeline reporting and scrobbling methods
- `NavigationCoordinator` (@MainActor) -- Manages cross-view navigation state (artist/album deep links from NowPlayingView)
  - Maintains per-tab navigation paths (homePath, artistsPath, etc.)
  - `visibleTabs: [TabItem]` -- Synced from MainTabView to enable fallback logic
  - `navigateFromNowPlaying()` -- Falls back to first visible tab when navigating from Search
  - `pendingNavigation` -- Deferred navigation executed after sheet dismissal
- `PlaybackService` -- AVPlayer management, queue, shuffle, repeat, remote controls, timeline reporting (every 10s), and scrobbling (at 90% completion)
- `HubRepository` -- Repository for hub data persistence (implements `HubRepositoryProtocol`); manages CDHub/CDHubItem entities
- `HubOrderManager` -- Manages user-customizable hub section ordering per music source
  - Persists custom order to UserDefaults with per-source keys
  - `applyOrder(to:for:)` -- Reorders fetched hubs according to saved preferences
  - `saveOrder(_:for:)` / `saveDefaultOrder(_:for:)` -- Stores custom and default orders
  - `resetToDefaultOrder(for:)` -- Restores server's original hub order
- `ArtworkLoader` -- Persistent artwork caching with local-first loading strategy
- `CacheManager` (@MainActor) -- Tracks cache sizes and provides cache clearing functionality
- `NetworkMonitor` (@MainActor) -- Proactive network connectivity monitoring using NWPathMonitor with 1s debouncing
- `ServerHealthChecker` -- Concurrent health checks for all configured servers with automatic failover
- `SettingsManager` (@MainActor) -- Manages accent colors and customizable tab configuration
- `BackgroundSyncScheduler` -- iOS `BGAppRefreshTask` scheduling for hub refresh ~every 15min (system-controlled)
- `MoodRepository` -- Mood data persistence (CDMood)
- `ToastCenter` (@MainActor) -- App-wide toast notification coordination
- `PlexRadioProvider` -- Plex Radio support implementing `RadioProvider` protocol

**Key Models:**
- Domain models: `Track`, `Album`, `Artist`, `Genre`, `Playlist`, `Hub`, `HubItem` (UI-facing, protocol-conforming)
  - `Track` includes `streamId: Int?` -- Identifies audio stream for fetching loudness timeline data (waveform visualization)
- `MusicSource` / `MusicSourceIdentifier` -- Multi-account source tracking
- `PlexAccountConfig` -- Account/server/library hierarchy for configuration
- `FilterOptions` -- Comprehensive filtering with search, sort, genre/artist filters, year ranges, downloaded-only toggle
  - Includes `FilterPersistence` utility class for saving/loading filter state per-view to UserDefaults
- `NetworkState`, `NetworkType`, `ServerConnectionState`, `StatusColor` -- Network state management models
- `PinnedItem` -- User-pinned content (albums, artists, playlists) with sort order
- `Mood` -- Plex mood/vibe category (title and ratingKey)

**Key ViewModels:**
- `PinnedViewModel` -- Fetches `PinnedItem` CoreData records and resolves them into full domain objects

### EnsembleUI (Presentation Layer)
- **Location:** `Packages/EnsembleUI/`
- **Dependencies:** EnsembleCore, Nuke (NukeUI)
- **Purpose:** All SwiftUI views and reusable components

**Key Views:**
- `RootView` -- Adapts by platform: tab navigation on iPhone, sidebar on iPad/macOS
- `MiniPlayer` -- Persistent compact player overlay across all screens
- `MediaDetailView` -- Unified detail view using `MediaDetailViewModelProtocol` (supports Artist, Album, Playlist, Favorites)
- `ArtworkView` -- Local-first artwork loading with automatic fallback to network
- `HomeView` -- Hub-based home screen with horizontally-scrolling sections
- `FilterSheet` -- Advanced filtering UI with artist/genre multi-select, year ranges
- `AlbumDetailLoader` / `ArtistDetailLoader` / `PlaylistDetailLoader` -- Async loading wrappers for detail views
- `WaveformView` -- Audio waveform visualization with real Plex loudness data or fallback generation
- `CoverFlowView` -- 3D carousel view with perspective rotation, scaling, and tap-to-zoom/flip interactions

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
- **Multi-source architecture** -- Designed to support multiple Plex accounts and future services (Apple Music, Spotify)
  - `MusicSourceIdentifier` tracks source origin (accountId, serverId, libraryId)
  - `SyncCoordinator` orchestrates syncing across all enabled sources
  - Provider pattern allows pluggable sync implementations

## Subsystem: Artwork Caching

Persistent artwork caching that survives app restarts:

1. **ArtworkDownloadManager** (`EnsemblePersistence`) -- Downloads and stores artwork files locally
   - Stores in `Library/Application Support/Ensemble/Artwork/`
   - Filename format: `{ratingKey}_album.jpg` or `{ratingKey}_artist.jpg`
   - Methods: `downloadAndCacheArtwork()`, `getLocalArtworkPath()`, `clearArtworkCache()`

2. **ArtworkLoader** (`EnsembleCore`) -- Coordinates with local-first strategy
   - `artworkURLAsync()` checks local cache first using `ratingKey`
   - Falls back to network fetch via `SyncCoordinator` if not cached
   - `predownloadArtwork()` methods for batch downloading during sync
   - Configures Nuke's `ImagePipeline` with 100MB disk cache

3. **ArtworkView** (`EnsembleUI`) -- SwiftUI component
   - Passes `ratingKey` to enable local cache lookups
   - Convenience initializers for `Track`, `Album`, `Artist`, `Playlist`

4. **CacheManager** (`EnsembleCore`) -- Cache visibility and management
   - Methods: `refreshCacheInfo()`, `clearCache(type:)`, `clearAllCaches()`

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

5. **WaveformView** (`EnsembleUI`) -- Horizontal bars with playback progress

## Subsystem: Hub-Based Home Screen

Dynamic home screen powered by Plex's hub system:

- `Hub` domain model -- Sections like Recently Added, Recently Played
- `HubItem` -- Items within a hub (tracks, albums, artists, playlists)
- `HomeViewModel` -- Loads hub data with 2s debouncing
- `HomeView` -- Horizontally-scrolling sections with navigation
  - `HubSection` / `HubItemCard` inline structs
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

## Subsystem: Network Resilience

- **NetworkMonitor** -- `NWPathMonitor` with 1s debouncing, states: `.online`/`.offline`/`.limited`/`.unknown`
- **ServerHealthChecker** -- Concurrent health checks, tests Local -> Direct -> Relay
- **ConnectionFailoverManager** -- Automatic failover between server URLs

**App Lifecycle:**
- iOS: Network monitor starts in `AppDelegate` (delayed 500ms)
- macOS: Stops monitoring when backgrounded
- Proactive server health checks on foreground transition

## Subsystem: Customizable UI Settings

**SettingsManager** (`EnsembleCore/Services/SettingsManager.swift`):
- `AppAccentColor` enum: `.purple` (default), `.blue`, `.pink`, `.red`, `.orange`, `.yellow`, `.green`
- `TabItem` enum: 10 tabs, users can enable/disable via Settings
- Default enabled: Home, Artists, Playlists, Search

## Subsystem: Favorites

- `FavoritesViewModel` -- Filters tracks with `userRating >= 8.0` (4+ stars)
- Implements `MediaDetailViewModelProtocol` for consistency
- Reuses `MediaDetailView` for unified UI

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

## Subsystem: Pinned Content

User-pinnable items (albums, artists, playlists) persisted across sessions:

- `PinnedItem` domain model records item type, ratingKey, sourceIdentifier, and sort order
- `PinnedViewModel` fetches `CDPinnedItem` records from CoreData and resolves them into full domain objects
- Persisted in CoreData via `CDPinnedItem` entity

## Subsystem: Mood-Based Browsing

Plex mood/vibe categories for discovery:

- `Mood` domain model -- title and ratingKey from Plex API
- `MoodRepository` -- CoreData persistence via `CDMood` entity
- `MoodTracksView` (`EnsembleUI`) -- displays tracks for a selected mood

## Subsystem: Incremental Sync

Two sync modes to balance freshness and speed:

- **Full sync:** `SyncCoordinator.syncAll()` -- fetches entire library from Plex
- **Incremental sync:** `SyncCoordinator.syncAllIncremental()` -- uses `addedAt>=` / `updatedAt>=` Plex query params to fetch only new/changed items
- **Startup:** full sync if last sync >24h ago; incremental if >1h; skip if <1h
- **Periodic (foreground):** incremental library sync every 1h, hub refresh every 10min
- **Background (iOS):** `BackgroundSyncScheduler` registers `BGAppRefreshTask`; system triggers hub refresh approximately every 15min
- **Pull-to-refresh:** library views call incremental sync; `HomeView` refreshes hubs only
- **Key filtered fetch methods** in `PlexAPIClient`: `getArtists(sectionKey:addedAfter:)`, `getAlbums(sectionKey:addedAfter:)`, `getTracks(sectionKey:addedAfter:)`

## Multi-Source Architecture

When adding new music sources:
1. Create provider implementing `MusicSourceSyncProvider` protocol
2. Add source type to `MusicSourceType` enum
3. Register provider in `SyncCoordinator.refreshProviders()`
4. Add account configuration model similar to `PlexAccountConfig`
5. Update `AccountManager` to handle new account type
