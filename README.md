# Ensemble

A beautiful, universal Plex Music Player for iOS, iPadOS, macOS, and watchOS. Stream your music library from any Plex server with a native, information-dense interface.

## Features

### Current Features
- **Multi-Library Support** — Connect multiple Plex accounts, servers, and music libraries simultaneously
- **Platform-Adaptive UI** — Tab navigation on iPhone, sidebar on iPad/macOS, simplified controls on watchOS
- **Secure Authentication** — PIN-based OAuth with keychain token storage
- **Full Playback Controls** — Queue management, shuffle, repeat, background audio
- **Offline Caching** — CoreData-backed library caching for fast browsing
- **Persistent Artwork Caching** — Artwork downloads persist across app restarts for faster loading and offline viewing
- **Rich Metadata** — Artists, albums, genres, playlists with artwork
- **Search** — Fast search across your entire library
- **Now Playing** — Full-screen player with mini player overlay
- **Settings & Sync** — Manual library sync with progress tracking
- **Cache Management** — View storage usage and clear caches by type

### Planned Features
- Offline playback (download management infrastructure exists)
- Apple Music integration
- Advanced queue management (reordering, history)
- Lyrics support
- CarPlay support
- Crossfade & gapless playback

## Requirements

- **iOS** 15.0+ (optimized for iOS 16+)
- **iPadOS** 15.0+
- **macOS** 12.0+
- **watchOS** 8.0+
- **Xcode** 15.0+
- **Swift** 5.9+

**Performance Target:** Optimized for devices with 2GB RAM (iPhone 6s, iPad Air 2)

## Getting Started

### Installation
1. Clone the repository
2. Open `Ensemble.xcworkspace` in Xcode (**not** the `.xcodeproj`)
3. Select your development team in project settings
4. Build and run on your target device

### First Launch
1. Launch the app
2. Tap "Add Plex Account"
3. Visit `plex.tv/link` and enter the PIN code
4. Select your Plex server
5. Choose a music library
6. Wait for initial sync to complete

## Architecture

Ensemble uses a **layered modular architecture** with Swift Package Manager:

```
┌─────────────────────────────────┐
│      EnsembleUI                 │  SwiftUI views & components
│      (Layer 3)                  │
└────────────┬────────────────────┘
             │
┌────────────▼────────────────────┐
│      EnsembleCore               │  ViewModels, services, domain models
│      (Layer 2)                  │
└────────┬───────────────┬────────┘
         │               │
┌────────▼────────┐ ┌───▼─────────────┐
│  EnsembleAPI    │ │ EnsemblePersist │  Networking & data
│  (Layer 1)      │ │ (Layer 1)       │
└─────────────────┘ └─────────────────┘
```

### Package Overview

| Package | Purpose | Key Components |
|---------|---------|----------------|
| **EnsembleAPI** | Plex networking & auth | `PlexAPIClient`, `PlexAuthService`, `KeychainService` |
| **EnsemblePersistence** | CoreData & downloads | `CoreDataStack`, `LibraryRepository`, `DownloadManager`, `ArtworkDownloadManager` |
| **EnsembleCore** | Business logic | `DependencyContainer`, `SyncCoordinator`, `PlaybackService`, `ArtworkLoader`, `CacheManager`, ViewModels |
| **EnsembleUI** | User interface | Screens, components, `RootView`, `MiniPlayer`, `ArtworkView` |

### Key Design Patterns
- **MVVM** with `@MainActor` ObservableObject ViewModels
- **Dependency Injection** via centralized `DependencyContainer`
- **Repository Pattern** for CoreData access
- **Actor-based networking** for thread safety
- **Multi-source architecture** — Designed to support multiple services (Plex, future Apple Music, etc.)
- **Persistent artwork caching** — Local-first loading with automatic network fallback

## Development

### Project Structure
```
ensemble/
├── Ensemble.xcworkspace          # Always open this
├── Ensemble/                     # Main app (iOS/iPadOS/macOS)
├── EnsembleWatch/                # watchOS app
└── Packages/                     # Swift Package modules
    ├── EnsembleAPI/
    ├── EnsemblePersistence/
    ├── EnsembleCore/
    └── EnsembleUI/
```

### Building & Testing
```bash
# Build full app
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator build

# Build individual package
swift build --package-path Packages/EnsembleCore

# Run package tests
swift test --package-path Packages/EnsembleCore

# Run all tests
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble test
```

### Code Guidelines
- **Target:** iOS 15+ devices with 2GB RAM
- Use clear, descriptive names
- Comment logical sections (not every line)
- Favor simplicity over premature optimization
- This is a pre-beta app — edge cases are not a priority yet

### Adding New Features
See `CLAUDE.md` for detailed development guidelines, including:
- How to add ViewModels, Views, and CoreData entities
- Multi-source architecture patterns
- Memory optimization tips

## External Dependencies

| Library | Version | Purpose |
|---------|---------|---------|
| [Nuke](https://github.com/kean/Nuke) | 12.0+ | High-performance image loading & caching |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | 4.2+ | Secure token storage |

## Known Issues

- **watchOS:** `AuthViewModel` is missing — app won't compile (see `CLAUDE.md`)
  - This is intentional - iOS implementation needs to be completed first

## Development Status

**Current Phase:** Feature-complete MVP with multi-library support

**Next Steps:**
- Fix watchOS authentication
- Implement offline playback
- Add advanced queue management
- Prepare for beta testing

## Roadmap

### Phase 1: Foundation ✅
- [x] Plex OAuth (PIN-based)
- [x] Multi-account/server/library support
- [x] Keychain token storage

### Phase 2: Core Playback ✅
- [x] Library browsing (Songs, Artists, Albums, Genres, Playlists)
- [x] CoreData caching with multi-source tracking
- [x] AVPlayer streaming
- [x] Now Playing screen with mini player
- [x] Background audio & remote controls

### Phase 3: Enhanced Experience ✅
- [x] Queue management with shuffle/repeat
- [x] Search functionality
- [x] iPad sidebar navigation
- [x] Settings & manual sync
- [x] watchOS basic playback

### Phase 4: Offline & Advanced (In Progress)
- [x] Download manager infrastructure
- [x] Downloads view
- [x] **Persistent Artwork Caching** — Artwork persists across app launches with local-first loading
- [x] **Cache Management** — View storage usage and clear caches by type
- [ ] **Complete Offline Support** — Wire up audio file downloads for true offline playback
- [ ] **Artwork Pre-Caching During Sync** — Automatically download artwork during library sync
- [ ] **Network Reachability Indicator** — Show online/offline status to users
- [ ] **Background Sync** — Use iOS background refresh to keep library updated
- [ ] Queue reordering
- [ ] Playback history

### Phase 5: Ecosystem Integration
- [ ] Apple Music support
- [ ] CarPlay
- [ ] Lyrics
- [ ] Crossfade & gapless playback
- [ ] macOS menu bar controls

## Contributing

This is a personal project, but contributions are welcome! Please:
1. Read `CLAUDE.md` for architecture details
2. Follow existing code patterns
3. Test on iOS 15 devices when possible
4. Focus on memory efficiency

## License

This project is for personal use.

---

**Note:** This is an active development project. Features and architecture may change frequently. Always refer to `CLAUDE.md` for the most up-to-date technical documentation.
