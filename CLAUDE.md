# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ensemble is a universal Plex Music Player built with SwiftUI, targeting iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It streams music from Plex servers using PIN-based OAuth authentication.

## Build & Test Commands

**Build the full app (iOS simulator):**
```
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build
```

**Build a single package:**
```
swift build --package-path Packages/EnsembleAPI
swift build --package-path Packages/EnsembleCore
swift build --package-path Packages/EnsemblePersistence
swift build --package-path Packages/EnsembleUI
```

**Run tests for a single package:**
```
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
```

**Run all tests via Xcode:**
```
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Always open `Ensemble.xcworkspace` (not `.xcodeproj`) when working in Xcode.

## Architecture

The app uses a layered modular architecture via four Swift Packages under `Packages/`:

```
EnsembleUI  (SwiftUI views & components)
     ↓
EnsembleCore  (ViewModels, services, domain models)
     ↓
EnsembleAPI  (Plex networking & auth)  +  EnsemblePersistence  (CoreData)
```

### Package Responsibilities

- **EnsembleAPI** — Plex server communication. `PlexAPIClient` and `PlexAuthService` are both Swift actors. Auth tokens stored via `KeychainService` (wraps KeychainAccess). API response models are in `PlexModels.swift`.
- **EnsemblePersistence** — CoreData stack (`CoreDataStack` singleton) with managed objects (`CDArtist`, `CDAlbum`, `CDTrack`, etc.). Repositories (`LibraryRepository`, `PlaylistRepository`) provide protocol-based data access. `DownloadManager` handles offline file storage.
- **EnsembleCore** — Business logic layer. `DependencyContainer` (singleton) wires all services and creates ViewModels. Injected into SwiftUI via an environment key. Domain models (`Track`, `Album`, `Artist`, etc.) are separate from API/CoreData models, mapped via `ModelMappers`. Key services: `PlaybackService` (AVPlayer wrapper with queue/shuffle/repeat), `LibrarySyncService` (syncs Plex library to CoreData), `ArtworkLoader` (Nuke-based image loading).
- **EnsembleUI** — All SwiftUI screens and reusable components. `RootView` adapts by platform: tab navigation on iPhone, sidebar on iPad/macOS. `MiniPlayer` is the persistent compact player overlay.

### Key Patterns

- **MVVM** with `@MainActor` ObservableObject ViewModels using Combine publishers
- **Dependency Injection** via centralized `DependencyContainer` singleton, injected through SwiftUI environment
- **Actor-based concurrency** for thread-safe networking (`PlexAPIClient`, `PlexAuthService`)
- **Repository pattern** with protocol abstractions for CoreData access
- **Domain model separation** — API models (`Plex*`), CoreData models (`CD*`), and domain models are distinct types

### App Targets

- `Ensemble/` — iOS/iPadOS/macOS app target (entry point: `EnsembleApp.swift`, audio config: `AppDelegate.swift`)
- `EnsembleWatch/` — watchOS app target with simplified views

## External Dependencies

- **KeychainAccess** (4.2.0+) — Secure token storage (used in EnsembleAPI)
- **Nuke** (12.0.0+) — Image loading/caching (used in EnsembleCore and EnsembleUI via NukeUI)
