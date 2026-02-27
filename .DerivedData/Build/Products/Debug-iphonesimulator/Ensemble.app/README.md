# Ensemble

A beautiful, universal Plex Music Player for iOS, iPadOS, macOS, and watchOS. Stream your music library from any Plex server with a native, information-dense interface.

## Features

### Current Features

**Core Functionality:**
- **Multi-Library Support** — Connect multiple Plex accounts, servers, and music libraries simultaneously
- **Platform-Adaptive UI** — Tab navigation on iPhone, sidebar on iPad/macOS, simplified controls on watchOS
- **Secure Authentication** — PIN-based OAuth with keychain token storage
- **Full Playback Controls** — Queue management, shuffle, repeat, background audio, remote controls (lock screen)

**Content Discovery:**
- **Hub-Based Home Screen** — Personalized sections: Recently Added, Recently Played, Most Played, etc.
  - Horizontally—scrolling hub sections with type-specific card layouts
  - Offline-first loading with cached hub data
  - Async DetailLoader components for smooth navigation
  - Intelligent fallback from section hubs to global hubs
  - **Customizable Hub Order** — Drag-to-reorder hub sections per music source with reset-to-default
- **Favorites** — Quick access to your highly-rated tracks (4+ stars)
- **Rich Metadata** — Browse by artists, albums, genres, playlists with beautiful artwork
- **3D CoverFlow Carousel** — Browse albums with perspective rotation, scaling, and tap-to-zoom/flip interactions
- **Search** — Fast search across your entire library with compact result layouts

**Advanced Features:**
- **Advanced Filtering** — Multi-select genres/artists, year ranges, sort options with persistence
- **Persistent Artwork Caching** — Artwork persists across app restarts for instant loading and offline viewing
- **Offline Library Caching** — CoreData-backed library caching for fast browsing without network
- **Network Resilience** — Automatic server failover (Local → Direct → Relay), health monitoring, connectivity detection
- **Customizable UI** — 7 accent colors, customizable tabs (enable/disable any tab)

**Playback Experience:**
- **Now Playing** — Full-screen player with dynamic artwork gradients, waveform visualization, and mini player overlay
- **Playback Tracking** — Automatic timeline reporting (every 10s) and scrobbling (at 90% completion) to Plex for accurate play counts and listening history
- **Waveform Visualization** — Real-time audio waveforms using Plex sonic analysis data (via `/library/streams/{streamId}/levels`) with intelligent deterministic fallback generation
- **Smart Navigation** — Navigate from Now Playing to artist/album details with automatic tab fallback logic
- **AirPlay Support** — Stream to AirPlay devices with native picker
- **Background Audio** — Continues playing when app is backgrounded
- **Lock Screen Controls** — Play/pause/skip from iOS Control Center and lock screen

**Management:**
- **Settings & Sync** — Manual library sync with progress tracking
- **Cache Management** — View storage usage by type (metadata, artwork, downloads) and clear selectively
- **Download Management** — Infrastructure for offline track downloads (UI complete, playback in progress)

### Planned Features
- **Offline Playback** — Wire up audio file downloads for true offline playback (infrastructure complete)
- **Apple Music Integration** — Multi-source architecture ready for additional services
- **Advanced Queue Management** — Reordering, playback history, queue persistence
- **Lyrics Support** — Display synced lyrics from Plex servers
- **CarPlay Support** — Native CarPlay interface for safe driving
- **Audio Enhancements** — Crossfade, gapless playback, equalizer
- **Smart Features** — Smart playlists, listening statistics, recommendations

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
| **EnsembleAPI** | Plex networking & auth | `PlexAPIClient` (with timeline/scrobble support), `PlexAuthService`, `KeychainService`, `ConnectionFailoverManager` |
| **EnsemblePersistence** | CoreData & downloads | `CoreDataStack`, `LibraryRepository`, `HubRepository`, `DownloadManager`, `ArtworkDownloadManager` |
| **EnsembleCore** | Business logic | `DependencyContainer`, `SyncCoordinator`, `PlaybackService` (with playback tracking), `ArtworkLoader`, `NetworkMonitor`, `ServerHealthChecker`, `SettingsManager`, `NavigationCoordinator`, `HubOrderManager`, ViewModels |
| **EnsembleUI** | User interface | `RootView`, `HomeView` (with `HubSection`/`HubItemCard`), `MediaDetailView`, `MiniPlayer`, `FilterSheet`, `ArtworkView`, `DetailLoaders`, `CoverFlowView`, `HubOrderingSheet`, `ArtworkColorExtractor`, `WaveformView`, `MarqueeText` |

### Key Design Patterns
- **MVVM** with `@MainActor` ObservableObject ViewModels
- **Dependency Injection** via centralized `DependencyContainer`
- **Repository Pattern** for CoreData access
- **Actor-based networking** for thread safety
- **Protocol-based view reuse** — Single detail view for multiple content types
- **Multi-source architecture** — Designed to support multiple services (Plex, future Apple Music, etc.)
- **Network resilience** — Multi-layered connectivity monitoring with automatic failover
- **Persistent artwork caching** — Two-tier caching (filesystem + memory) with local-first loading
- **Performance optimizations** — Debouncing, background processing, memory-efficient design
- **iOS 15 compatibility layer** — NestedNavigationLink pattern, traditional NavigationLink fallbacks, conditional feature checks

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

- **watchOS:** Authentication needs refactoring — references missing `AuthViewModel` (see `CLAUDE.md` for details)
  - This is intentional - iOS implementation needs to be completed first
- **Offline Playback:** Infrastructure complete but audio file downloads not wired to playback
- **Artwork Pre-Caching:** Methods exist but not automatically called during sync

## Development Status

**Current Phase:** Feature-rich MVP with advanced functionality and Plex ecosystem integration

**Completed:**
- Multi-library Plex support with network resilience
- Hub-based home screen with offline-first loading and DetailLoader pattern
- Customizable hub section ordering with drag-to-reorder interface
- 3D CoverFlow carousel for immersive album browsing
- Smart navigation with tab fallback logic from Now Playing
- Advanced filtering and customization
- Persistent artwork caching system with hub support
- Network monitoring and server health checks
- Playback tracking (timeline reporting every 10s and scrobbling at 90%)
- Waveform visualization with Plex sonic analysis integration and deterministic fallback
- iOS 15+ compatibility with NestedNavigationLink pattern
- Immersive mode support with ChromeVisibilityPreferenceKey for full-screen experiences

**Next Steps:**
- Complete offline playback wiring
- Fix watchOS authentication
- Add automatic artwork pre-caching during sync
- Implement queue reordering and waveform seeking
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
- [x] **Hub-Based Home Screen** — Personalized content discovery (Recently Added, Recently Played, etc.)
- [x] **Customizable Hub Order** — Drag-to-reorder hub sections per music source with reset-to—default
- [x] **3D CoverFlow Carousel** — Immersive album browsing with perspective transforms and tap-to-zoom/flip
- [x] **Favorites System** — Quick access to highly-rated tracks
- [x] **Advanced Filtering** — Multi-select genres/artists, year ranges, sort persistence
- [x] **Customizable UI** — Accent colors and customizable tabs

### Phase 4: Offline & Advanced (In Progress)
- [x] Download manager infrastructure
- [x] Downloads view
- [x] **Persistent Artwork Caching** — Artwork persists across app launches with local-first loading
- [x] **Cache Management** — View storage usage and clear caches by type
- [x] **Network Resilience** — Multi-layered connectivity monitoring with automatic failover
- [x] **Server Health Monitoring** — Concurrent health checks with connection priority (Local → Direct → Relay)
- [x] **Network State UI** — Connectivity banner and status indicators
- [x] **Playback Tracking** — Timeline reporting (every 10s) and scrobbling (at 90% completion) for accurate play counts
- [x] **Waveform Visualization** — Real-time audio waveforms using Plex sonic analysis data with intelligent fallback
- [ ] **Complete Offline Support** — Wire up audio file downloads for true offline playback
- [ ] **Artwork Pre-Caching During Sync** — Automatically download artwork during library sync
- [ ] **Background Sync** — Use iOS background refresh to keep library updated
- [ ] Queue reordering and persistence
- [ ] Waveform seeking (jump to specific parts of track)

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

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

See [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md) for third-party licenses and attributions.

---

**Note:** This is an active development project. Features and architecture may change frequently. Always refer to `CLAUDE.md` for the most up-to-date technical documentation.
