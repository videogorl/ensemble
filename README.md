# Ensemble

A beautiful, universal Plex Music Player for iOS, iPadOS, macOS, and watchOS. Stream your music library from any Plex server with a native, information-dense interface.

## Features

### Current Features

**Core Functionality:**
- **Multi-Library Support** — Connect multiple Plex accounts, servers, and music libraries simultaneously
- **Apple Music Source (iOS/iPadOS 18+)** — Device-local Apple Music library sync, catalog search and add-to-library, MusicKit playback/AirPlay, playlist adds, favorites, cross-source merged playlists, and normalized Recently Added/Played/Most Played Feed hubs alongside Plex
- **Platform-Adaptive UI** — Tab navigation on iPhone, sidebar on iPad/macOS
- **Secure Authentication** — PIN-based OAuth with keychain token storage
- **Full Playback Controls** — Queue management with accidental-replacement protection, shuffle, repeat, background audio, remote controls (lock screen)

**Content Discovery:**
- **Hub-Based Home Screen** — Personalized sections: Recently Added, Recently Played, Most Played, etc.
  - Horizontally—scrolling hub sections with type-specific card layouts
  - Offline-first loading with cached hub data
  - Recently Added, Recent Plays, and Most Played merge across enabled libraries and servers using Plex timestamps and play counts
  - Async DetailLoader components for smooth navigation
  - Intelligent fallback from section hubs to global hubs
  - **Customizable Hub Order** — Drag-to-reorder the combined Feed with reset-to-default
- **Favorites** — Quick access to loved Plex tracks and Apple Music favorites
- **Rich Metadata** — Browse by artists, albums, genres, playlists with beautiful artwork
- **StageFlow** — Immersive landscape browsing with a centered stage, snapping, and slide-out track details
- **Search** — Fast search across your entire library with compact result layouts
- **Gesture Actions (iOS/iPadOS)** — Mail-style track swipe actions (`Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle) across library and search track lists
- **Long-Press Menus** — Album, artist, and playlist cards expose context actions that match detail-view capabilities
- **Share Ensemble Links** — Share portable song, artist, album, or playlist links that resolve against another user's own enabled libraries without exposing Plex server IDs; existing streaming-link and audio-file sharing remain separate options

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
- **Route-Aware Lyrics + Aurora Sync** — Automatically compensates AirPlay and Bluetooth output delay for lyric highlighting and the Aurora visualization
- **SmartMix** — Optional playback mode with Profile settings, silence-aware DJ-style overlaps, crossfading Now Playing artwork, same-album protection by default, an eased outgoing high-pass sweep, and tempo matching when analysis confidence is high
- **Smart Navigation** — Navigate from Now Playing to artist/album details with automatic tab fallback logic
- **Siri Voice Playback + App Intents** — “Play track/album/artist/playlist ... on Ensemble” resolves indexed music from enabled sources in SiriKit and executes playback in-app via `handleInApp`; App Intents also expose non-playing media navigation and portable Ensemble-link creation
- **AirPlay Support** — Stream to AirPlay devices with native picker
- **Background Audio** — Continues playing when app is backgrounded
- **Lock Screen Controls** — Play/pause/skip from iOS Control Center and lock screen
- **Apple Watch App** — Standalone watchOS experience with iCloud Keychain/Plex Link setup, indexed library browsing, cross-server playlist merging, artwork-rich details and modal Now Playing, gapless album/playlist queues, system Crown volume and media controls, sleep-safe watch-local streaming, and phone remote control through WatchConnectivity

**Management:**
- **Account-Centric Music Sources** — Manage Plex accounts as sources, with account identifier subtitles, server-grouped library checklists, per-library sync/connection status, and an explicit “Force Full Sync” action in one detail screen
- **Resilient Mixed-Library Playlists** — Songs from disabled libraries remain visible and editable in playlists while playback and downloads stay disabled only for those songs
- **Library Visibility Foundation** — Source-level visibility profiles are supported in core data flow (selector UI planned)
- **Swipe Action Customization** — Configure leading/trailing swipe slots and reset defaults from Settings → Playback
- **Large-Screen Library Polish** — Regular-width iPad and macOS browse Artists, Playlists, and Genres with adaptive selection/detail panes; Songs gains a dense customizable metadata table while compact iPhone navigation stays unchanged
- **Cache Management** — View storage usage by type (metadata, artwork, downloads) and clear selectively
- **Offline Download Manager (Target-Based)** — Settings-managed `Manage Downloads` flow with `Servers` bulk toggles, album/artist/playlist target toggles, progress rows, reference-counted cleanup across overlapping targets, and a Downloads toolbar action to refresh completed files to the currently selected download quality (with automatic original-quality fallback on servers that reject offline transcode requests)
- **Offline-Safe Track UX** — While offline, non-downloaded tracks are dimmed and blocked with a toast prompt

### Planned Features
- **Library Visibility Profile Selector** — Add UI to switch and edit visibility presets without changing sync enablement
- **Advanced Queue Management** — Reordering, playback history, queue persistence
- **CarPlay Support** — Native CarPlay interface for safe driving
- **Audio Enhancements** — Equalizer and advanced mix controls
- **Smart Features** — Smart playlists, listening statistics, recommendations

## Requirements

- **iOS** 15.0+ (optimized for iOS 16+)
- **iPadOS** 15.0+
- **macOS** 12.0+
- **watchOS** 10.0+
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
2. Tap "Add Source" and choose Plex or Apple Music (Apple Music requires iOS/iPadOS 18+)
3. For Plex, visit `plex.tv/link` and enter the PIN code (the PIN can be tapped to copy)
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
| **EnsembleDomain** | Portable domain models | Watch-safe account credentials, media summaries, tracks, library categories, playback target/status |
| **EnsemblePlex** | Portable Plex facade | Watch account discovery, selected-library catalog snapshots, detail track loading, low-bitrate stream URL resolution |
| **EnsembleWatchCore** | watchOS runtime | Plex Link fallback, iCloud credential restore, watch-local library selection, local catalog cache, watch-local playback, local/remote Now Playing target |
| **EnsemblePersistence** | CoreData & downloads | `CoreDataStack`, `LibraryRepository`, `HubRepository`, `DownloadManager`, `ArtworkDownloadManager` |
| **EnsembleCore** | Business logic | `DependencyContainer`, `SyncCoordinator`, `PlaybackService` (with playback tracking), `PlexAccountDiscoveryService`, `LibraryVisibilityStore`, `ArtworkLoader`, `NetworkMonitor`, `ServerHealthChecker`, `SettingsManager`, `NavigationCoordinator`, `HubOrderManager`, ViewModels |
| **EnsembleUI** | User interface | `RootView`, `HomeView` (with `HubSection`/`HubItemCard`), `MediaDetailView`, `MiniPlayer`, `FilterSheet`, `ArtworkView`, `DetailLoaders`, `StageFlowView`, `HubOrderingSheet`, `WaveformView`, `MarqueeText` |

### Key Design Patterns
- **MVVM** with `@MainActor` ObservableObject ViewModels
- **Dependency Injection** via centralized `DependencyContainer`
- **Repository Pattern** for CoreData access
- **Actor-based networking** for thread safety
- **Protocol-based view reuse** — Single detail view for multiple content types
- **Multi-source architecture** — Plex and device-local Apple Music sources share library, playlist, search, and queue surfaces
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
    ├── EnsembleDomain/
    ├── EnsemblePlex/
    ├── EnsembleWatchCore/
    ├── EnsemblePersistence/
    ├── EnsembleCore/
    └── EnsembleUI/
```

### Building & Testing
```bash
# Build full app
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Build individual package
swift build --package-path Packages/EnsembleCore

# Run package tests
swift test --package-path Packages/EnsembleCore

# Run all tests
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble test
```

For agent-driven development, passing tests are only part of verification. User-visible changes should also be validated in the running app with the iOS Simulator MCP server so the agent can launch the app, interact with the UI, and confirm behavior without manual user input.

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

- **watchOS:** Downloads are intentionally deferred from standalone watch V1. The watch app builds through the `EnsembleWatch` scheme as an independent target; phone remote control still works when the iPhone app is also installed.
- **Background continued processing limits (iOS 26+):** `BGContinuedProcessingTask` is best-effort; queued requests can be rejected or canceled by the system, and the app falls back to the persistent in-app queue.
- **Artwork Pre-Caching:** Methods exist but not automatically called during sync

## Development Status

**Current Phase:** Feature-rich MVP with advanced functionality and Plex ecosystem integration

**Completed:**
- Multi-library Plex support with network resilience
- Profile Focus menu for device-local library visibility without changing sync configuration
- Hub-based home screen with offline-first loading and DetailLoader pattern
- Customizable hub section ordering with drag-to-reorder interface
- StageFlow immersive carousel for albums, songs, and playlists in iPhone landscape
- Smart navigation with tab fallback logic from Now Playing
- Advanced filtering and customization
- Persistent artwork caching system with hub support
- Network monitoring and server health checks
- Playback tracking (timeline reporting every 10s and scrobbling at 90%)
- Waveform visualization with Plex sonic analysis integration and deterministic fallback
- iOS 15+ compatibility with NestedNavigationLink pattern
- StageFlow chrome suppression for iPhone landscape carousel experiences
- Account-centric Music Sources flow with grouped server/library selection and integrated sync status/actions
- Library visibility profile groundwork with source-level filtering seams in Library/Search/Home (no selector UI yet)
- Siri media intents (track/album/artist/playlist) with thin extension resolution and in-app playback execution coordinator
- App Intents album/playlist fallback shortcuts wired to the same Siri playback coordinator and shared Siri index vocabulary
- Target-based offline download manager with server/library bulk toggles and reference-counted membership reconciliation
- Optional iOS 26 `BGContinuedProcessingTask` acceleration path for user-initiated bulk offline downloads

**Next Steps:**
- Add manual watchOS downloads with watch-specific storage and background-transfer policy
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
- [x] watchOS iPhone Now Playing remote controls
- [x] watchOS standalone authentication, browsing, and independent playback
- [ ] watchOS manual downloads
- [x] **Hub-Based Home Screen** — Personalized content discovery (Recently Added, Recently Played, etc.)
- [x] **Customizable Hub Order** — Drag-to-reorder the combined Feed with reset-to—default
- [x] **StageFlow** — Immersive landscape browsing with centered snapping, inward-facing side cards, and a slide-out track panel
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
- [x] Apple Music support on iOS/iPadOS 18+
- [ ] CarPlay
- [ ] Lyrics
- [x] SmartMix silence-aware overlap
- [x] Tempo-matched SmartMix with subtle outgoing high-pass
- [ ] Advanced crossfade controls
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
