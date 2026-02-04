# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- `DownloadManager` — Offline file management

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
│   ├── DomainModels.swift             # UI-facing models (Track, Album, Artist, etc.)
│   ├── ModelMappers.swift             # CD* ↔ Domain model conversions
│   ├── MusicSource.swift              # Multi-account source identification
│   └── PlexAccountConfig.swift        # Account/server/library configuration
├── Services/
│   ├── AccountManager.swift           # Multi-account configuration (MainActor)
│   ├── SyncCoordinator.swift          # Multi-source sync orchestration (MainActor)
│   ├── MusicSourceSyncProvider.swift  # Protocol for source-specific sync
│   ├── PlexMusicSourceSyncProvider.swift # Plex implementation of sync protocol
│   ├── PlaybackService.swift          # AVPlayer wrapper with queue/shuffle/repeat
│   └── ArtworkLoader.swift            # Nuke-based image loading
├── ViewModels/
│   ├── AddPlexAccountViewModel.swift
│   ├── AlbumDetailViewModel.swift
│   ├── ArtistDetailViewModel.swift
│   ├── DownloadsViewModel.swift
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
- `PlaybackService` — AVPlayer management, queue, shuffle, repeat, remote controls
- `ArtworkLoader` — Nuke-based async image loading with caching

**Key Models:**
- Domain models: `Track`, `Album`, `Artist`, `Genre`, `Playlist` (UI-facing, protocol-conforming)
- `MusicSource` / `MusicSourceIdentifier` — Multi-account source tracking
- `PlexAccountConfig` — Account/server/library hierarchy for configuration

#### EnsembleUI (Presentation Layer)
- **Location:** `Packages/EnsembleUI/`
- **Dependencies:** EnsembleCore, Nuke (NukeUI)
- **Purpose:** All SwiftUI views and reusable components

**File Structure:**
```
Sources/
├── Components/
│   ├── AlbumCard.swift               # Grid card for albums
│   ├── ArtistCard.swift              # Grid card for artists
│   ├── ArtworkView.swift             # Lazy-loading artwork with Nuke
│   ├── EmptyLibraryView.swift        # Empty state with sync prompt
│   ├── MediaTrackList.swift          # Reusable track list with context menu
│   ├── MiniPlayer.swift              # Compact persistent player overlay
│   ├── PlaylistCard.swift            # Grid card for playlists
│   └── TrackRow.swift                # Single track row with artwork
├── Screens/
│   ├── AddPlexAccountView.swift      # Account setup flow
│   ├── AlbumsView.swift              # Album grid
│   ├── ArtistsView.swift             # Artist grid
│   ├── DownloadsView.swift           # Offline downloads
│   ├── GenresView.swift              # Genre browsing
│   ├── MainTabView.swift             # iPhone tab bar
│   ├── MediaDetailView.swift         # Artist/Album detail (adaptive)
│   ├── MoreView.swift                # Additional options
│   ├── NowPlayingView.swift          # Full-screen player
│   ├── PlaylistsView.swift           # Playlist grid
│   ├── RootView.swift                # Platform-adaptive root (tabs vs sidebar)
│   ├── SearchView.swift              # Search interface
│   ├── SettingsView.swift            # App settings
│   ├── SongsView.swift               # All songs list
│   └── SyncPanelView.swift           # Library sync status & controls
└── EnsembleUI.swift                  # Public exports

Tests/
└── EnsembleUITests.swift
```

**Key Views:**
- `RootView` — Adapts by platform: tab navigation on iPhone, sidebar on iPad/macOS
- `MiniPlayer` — Persistent compact player overlay across all screens
- `MediaDetailView` — Unified artist/album detail view
- `ArtworkView` — Nuke-based lazy image loading with placeholder

### Key Architectural Patterns

- **MVVM** — All ViewModels are `@MainActor` ObservableObjects using Combine publishers
- **Dependency Injection** — Centralized `DependencyContainer` singleton, injected through SwiftUI environment key
- **Actor-based concurrency** — Thread-safe networking with `PlexAPIClient` and `PlexAuthService` actors
- **Repository pattern** — Protocol abstractions for CoreData access (`LibraryRepositoryProtocol`, `PlaylistRepositoryProtocol`)
- **Domain model separation** — Three distinct model layers:
  - API models (`Plex*` in EnsembleAPI) — Raw server responses
  - CoreData models (`CD*` in EnsemblePersistence) — Persisted entities
  - Domain models (in EnsembleCore) — UI-facing, protocol-conforming types
- **Multi-source architecture** — Designed to support multiple Plex accounts and future services (Apple Music, Spotify)
  - `MusicSourceIdentifier` tracks source origin (accountId, serverId, libraryId)
  - `SyncCoordinator` orchestrates syncing across all enabled sources
  - Provider pattern allows pluggable sync implementations

### App Targets

- **Ensemble** (`Ensemble/Ensemble/`) — iOS/iPadOS/macOS app target
  - Entry point: `EnsembleApp.swift`
  - Audio config: `AppDelegate.swift` (UIApplicationDelegate for audio session setup)
  - Supports iOS 15+, requires iOS 16+ for full feature set
  
- **EnsembleWatch** (`Ensemble/EnsembleWatch/`) — watchOS app target
  - Entry point: `EnsembleWatchApp.swift`
  - All views consolidated in `WatchRootView.swift`
  - Simplified UI: authentication, library browsing, now playing controls
  - **⚠️ Known Issue:** References missing `AuthViewModel` — needs implementation or refactor

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
- **watchOS Authentication Missing** — `WatchRootView.swift:5` references `AuthViewModel` and `DependencyContainer.makeAuthViewModel()` which don't exist
  - **Impact:** watchOS app won't compile
  - **Fix:** Create `AuthViewModel` or refactor watchOS to use `AddPlexAccountViewModel`

### Infrastructure
- ✅ **Legacy CocoaPods Cleanup** — Removed unused `ios/Pods/` directory (was leftover from earlier experimentation)

### Documentation
- ✅ Documentation updated to match actual implementation

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

