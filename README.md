# Ensemble

Universal Plex Music Player for iOS, iPadOS, macOS, and watchOS.

## Requirements

- iOS 15.0+
- iPadOS 15.0+
- macOS 12.0+
- watchOS 8.0+
- Xcode 15.0+
- Swift 5.9+

## Getting Started

1. Open `Ensemble.xcworkspace` in Xcode
2. Select your development team in the project settings
3. Build and run on your target device

## Architecture

The project uses a modular architecture with Swift Packages:

```
ensemble/
├── Ensemble.xcworkspace
├── Ensemble/                    # iOS/iPadOS/macOS app target
├── EnsembleWatch/               # watchOS target
├── Packages/
│   ├── EnsembleAPI/             # Plex networking & authentication
│   ├── EnsembleCore/            # Shared business logic & ViewModels
│   ├── EnsembleUI/              # Shared SwiftUI components
│   └── EnsemblePersistence/     # CoreData layer
└── EnsembleTests/
```

### Package Dependencies

- **EnsembleAPI**: Handles all Plex server communication and authentication
- **EnsemblePersistence**: CoreData stack for local caching
- **EnsembleCore**: Business logic, services, and ViewModels (depends on API & Persistence)
- **EnsembleUI**: SwiftUI views and components (depends on Core)

## Features

### Phase 1: Foundation (Current)
- [x] Plex OAuth authentication (PIN-based flow)
- [x] Server discovery and selection
- [x] Keychain token storage

### Phase 2: Core Playback (MVP)
- [x] Library browsing (Songs, Artists, Albums, Genres)
- [x] CoreData caching
- [x] Classic 5-tab navigation
- [x] AVPlayer streaming
- [x] Now Playing screen
- [x] Mini player
- [x] Background audio & remote controls

### Phase 3: Enhanced Playback
- [x] Queue management
- [x] Shuffle and repeat modes
- [x] Search functionality
- [x] Settings
- [x] iPad sidebar navigation
- [x] watchOS basic playback

### Phase 4: Playlists
- [x] Fetch and display playlists
- [x] Playlist detail view

### Phase 5: Offline Sync
- [x] Download manager infrastructure
- [x] Downloads view

## External Dependencies

- [Nuke](https://github.com/kean/Nuke) - Image loading and caching
- [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) - Secure token storage

## License

This project is for personal use.
