# Ensemble

A beautiful, universal Plex Music Player for iOS, iPadOS, macOS, and watchOS. Stream your music library from any Plex server with a native, information-dense interface.

## Features

### Current Features

**Core Functionality:**
- **Multi-Library Support** — Connect multiple Plex accounts, servers, and music libraries simultaneously
- **Platform-Adaptive UI** — Tab navigation on iPhone, sidebar on iPad/macOS
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
- **Gesture Actions (iOS/iPadOS)** — Mail-style track swipe actions (`Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle) across library and search track lists
- **Long-Press Menus** — Album, artist, and playlist cards expose context actions that match detail-view capabilities

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
- **Siri Voice Playback (In-App-First + Fallback)** — “Play track/album/artist/playlist ... on Ensemble” resolves in SiriKit and executes playback in-app via `handleInApp`; album/playlist App Shortcuts fallback phrases are also registered when SiriKit media-domain routing misses
- **AirPlay Support** — Stream to AirPlay devices with native picker
- **Background Audio** — Continues playing when app is backgrounded
- **Lock Screen Controls** — Play/pause/skip from iOS Control Center and lock screen

**Management:**
- **Account-Centric Music Sources** — Manage Plex accounts as sources, with account identifier subtitles, server-grouped library checklists, per-library sync/connection status, and “Sync Enabled Libraries” in one detail screen
- **Library Visibility Foundation** — Source-level visibility profiles are supported in core data flow (selector UI planned)
- **Swipe Action Customization** — Configure leading/trailing swipe slots and reset defaults from Settings → Playback
- **Cache Management** — View storage usage by type (metadata, artwork, downloads) and clear selectively
- **Offline Download Manager (Target-Based)** — Settings-managed `Manage Downloads` flow with `Servers` bulk toggles, album/artist/playlist target toggles, progress rows, reference-counted cleanup across overlapping targets, and a Downloads toolbar action to refresh completed files to the currently selected download quality (with automatic original-quality fallback on servers that reject offline transcode requests)
- **Offline-Safe Track UX** — While offline, non-downloaded tracks are dimmed and blocked with a toast prompt

### Planned Features
- **Apple Music Integration** — Multi-source architecture ready for additional services
- **Library Visibility Profile Selector** — Add UI to switch and edit visibility presets without changing sync enablement
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
3. Visit `plex.tv/link` and enter the PIN code (the PIN can be tapped to copy)
4. Review discovered servers and music libraries in one grouped checklist
5. Keep at least one library selected and add the account
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
| **EnsembleCore** | Business logic | `DependencyContainer`, `SyncCoordinator`, `PlaybackService` (with playback tracking), `PlexAccountDiscoveryService`, `LibraryVisibilityStore`, `ArtworkLoader`, `NetworkMonitor`, `ServerHealthChecker`, `SettingsManager`, `NavigationCoordinator`, `HubOrderManager`, ViewModels |
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
- App is in active beta testing — handle edge cases defensively, especially in CoreData model

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

- **watchOS (deferred as of February 21, 2026):** Authentication path references missing `AuthViewModel`, so the watch target does not currently compile/run.
  - iOS/macOS remediation is prioritized first; watchOS restoration is intentionally out of scope for this pass.
- **Background continued processing limits (iOS 26+):** `BGContinuedProcessingTask` is best-effort; queued requests can be rejected or canceled by the system, and the app falls back to the persistent in-app queue.
- **Artwork Pre-Caching:** Methods exist but not automatically called during sync
- **Visibility Profile UI:** `LibraryVisibilityProfile` groundwork is implemented, but profile selector/editor UI is not shipped yet

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
- Account-centric Music Sources flow with grouped server/library selection and integrated sync status/actions
- Library visibility profile groundwork with source-level filtering seams in Library/Search/Home (no selector UI yet)
- Siri media intents (track/album/artist/playlist) with thin extension resolution and in-app playback execution coordinator
- App Intents album/playlist fallback shortcuts wired to the same Siri playback coordinator and shared Siri index vocabulary
- Target-based offline download manager with server/library bulk toggles and reference-counted membership reconciliation
- Optional iOS 26 `BGContinuedProcessingTask` acceleration path for user-initiated bulk offline downloads

**Next Steps:**
- Fix watchOS authentication
- Add automatic artwork pre-caching during sync
- Implement queue reordering and waveform seeking

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
- [x] Account-centric Music Sources settings and detail flow
- [x] watchOS basic playback (historical implementation; currently blocked by deferred auth compile issue)
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
- [x] **Target-Based Offline Manager** — Settings-managed targets (`Servers`, albums, artists, playlists), source-safe queueing, and reference-counted cleanup
- [x] **Complete Offline Support** — Downloaded tracks are persisted locally and playback/offline row behavior now respects download availability
- [ ] **Artwork Pre-Caching During Sync** — Automatically download artwork during library sync
- [x] **Background Sync** — iOS BGAppRefreshTask refreshes hubs every ~15 minutes (system-controlled)
- [x] **Optional BG Continued Processing** — iOS 26+ best-effort `BGContinuedProcessingTask` accelerator for large offline jobs
- [x] **Library Visibility Profile Groundwork** — Core profile/store + visibility filtering seams (selector UI still pending)
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
