---
name: common-tasks
description: "Load when adding a ViewModel, view, CoreData entity, hub, music source, playlist mutation, or sync trigger. Step-by-step recipes with code patterns."
---

# Ensemble Common Development Tasks

## Adding a New ViewModel

1. Create in `Packages/EnsembleCore/Sources/ViewModels/`
2. Make it `@MainActor class ... ObservableObject`
3. Add factory method to `DependencyContainer`
4. Inject dependencies via initializer

```swift
@MainActor
class MyNewViewModel: ObservableObject {
    @Published var items: [Item] = []

    private let libraryRepository: LibraryRepositoryProtocol

    init(libraryRepository: LibraryRepositoryProtocol) {
        self.libraryRepository = libraryRepository
    }
}
```

In `DependencyContainer`:
```swift
func makeMyNewViewModel() -> MyNewViewModel {
    MyNewViewModel(libraryRepository: libraryRepository)
}
```

## Adding a New View

1. Create in `Packages/EnsembleUI/Sources/Screens/` or `.../Components/`
2. Inject ViewModel via `@StateObject` using `DependencyContainer.shared.makeXViewModel()`
3. Access environment dependencies: `@Environment(\.dependencies) var deps`

```swift
struct MyNewView: View {
    @StateObject private var viewModel = DependencyContainer.shared.makeMyNewViewModel()
    @Environment(\.dependencies) var deps

    var body: some View {
        // ...
    }
}
```

## Adding a New CoreData Entity

1. Update `Ensemble.xcdatamodeld` in `Packages/EnsemblePersistence/Sources/CoreData/`
2. Create `@objc(CDEntityName)` class in `ManagedObjects.swift`
3. Add domain model in `EnsembleCore/Sources/Models/DomainModels.swift`
4. Add mapper in `ModelMappers.swift`
5. Update relevant repository

## CoreData Model Compilation for SwiftPM Tests

When `Ensemble.xcdatamodeld` changes, refresh the precompiled model used by SwiftPM tests:

```bash
scripts/compile_coredata_model.sh
```

What this does:
1. Compiles `Packages/EnsemblePersistence/Sources/CoreData/Ensemble.xcdatamodeld`
2. Outputs `Packages/EnsemblePersistence/Sources/CoreData/Compiled/SwiftPMEnsemble.momd`
3. Keeps package tests stable across environments where model bundle resolution differs

Validation workflow after model changes:
1. Run `swift test --package-path Packages/EnsemblePersistence`
2. Run dependent package tests (`EnsembleCore`, `EnsembleUI`) to ensure no resource regressions
3. Run app build (`xcodebuild ... -scheme Ensemble ... build`) to verify no duplicate-model outputs

## Running a Full Sync

```swift
// In any ViewModel or View with access to DependencyContainer
Task {
    await deps.syncCoordinator.syncAll()
}
```

## Working with Hubs

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

## Adding Hub Support to New Content Types

1. Update `HubItem` domain model in `DomainModels.swift` with new type
2. Add case to `HubItemCard.destination` computed property
3. Add case to `HubItemCard.destinationView` ViewBuilder
4. Create DetailLoader if needed (e.g., `GenreDetailLoader`)
5. Update `PlexModels.swift` to decode new type from API
6. Add mapper in `ModelMappers.swift` for Hub/HubItem if needed

## Adding a New Music Source

When adding support for new music sources (Apple Music, Spotify, etc.):
1. Create new provider implementing `MusicSourceSyncProvider` protocol
2. Add source type to `MusicSourceType` enum
3. Register provider in `SyncCoordinator.refreshProviders()`
4. Add account configuration model similar to `PlexAccountConfig`
5. Update `AccountManager` to handle new account type

## Creating a DetailLoader

For new content types that need async hub-to-detail navigation:

```swift
struct MyDetailLoader: View {
    let itemId: String  // ratingKey from HubItem
    @State private var item: MyModel?
    @State private var isLoading = true
    @State private var error: Error?
    @Environment(\.dependencies) var deps

    var body: some View {
        if let item = item {
            MyDetailView(item: item)
        } else if isLoading {
            ProgressView("Loading...")
        } else if let error = error {
            Text("Error: \(error.localizedDescription)")
        } else {
            Text("Not found")
        }
    }
    // .task { fetch from repository by ratingKey }
}
```

## Using FilterOptions

```swift
// In ViewModel
@Published var filterOptions = FilterOptions()

var filteredItems: [Item] {
    items.filter { filterOptions.matches($0) }
         .sorted(by: filterOptions.sortComparator)
}

// Load/save persisted filters
FilterPersistence.load(key: "myViewFilter")
FilterPersistence.save(filterOptions, key: "myViewFilter")
```

## Working with Playlist Mutations

All playlist mutations go through `SyncCoordinator`, which handles the server call and then refreshes the local CoreData cache automatically.

```swift
let syncCoordinator = DependencyContainer.shared.syncCoordinator

// Create a new playlist
try await syncCoordinator.createPlaylist(name: "My Playlist", for: sourceIdentifier)

// Add tracks to an existing playlist
try await syncCoordinator.addTracksToPlaylist(playlistKey: "12345", trackKeys: ["111", "222"], for: sourceIdentifier)

// Remove a track from a playlist (by its playlistItemID, not ratingKey)
try await syncCoordinator.removeTrackFromPlaylist(playlistKey: "12345", playlistItemID: "999", for: sourceIdentifier)

// Move a track within a playlist
try await syncCoordinator.movePlaylistItem(playlistKey: "12345", itemID: "999", afterItemID: "888", for: sourceIdentifier)

// Rename a playlist
try await syncCoordinator.renamePlaylist(playlistKey: "12345", newTitle: "New Name", for: sourceIdentifier)
```

**Rules:**
- Smart playlists are read-only. All mutations on smart playlists throw `PlaylistMutationError.smartPlaylistReadOnly`. Guard for this before showing mutation UI.
- After a successful mutation, `SyncCoordinator` automatically refreshes the affected playlist from the server and updates CoreData.
- Use `PlaylistActionSheets.swift` for standard add-to-playlist / create-playlist UI — it wires up these calls consistently across the app.

## Adding Track Swipe or Long-Press Actions

Use these patterns when extending gesture actions:

1. Add/adjust action definitions in `SettingsManager.TrackSwipeAction` and keep `TrackSwipeLayout.default` sane (2 leading + 2 trailing).
2. Ensure layout sanitization prevents duplicate assignments and malformed persisted payloads.
3. For SwiftUI track rows, wrap row content in `TrackSwipeContainer` and pass closures for play next/last, add-to-playlist, and favorite toggle.
4. For detail track tables, map the same actions in `MediaTrackList` via `leadingSwipeActionsConfigurationForRowAt` / `trailingSwipeActionsConfigurationForRowAt`.
5. For favorite mutations, call `NowPlayingViewModel.toggleTrackFavorite(_:)` or `setTrackFavorite(_:for:)` so server rating + local cache stay consistent.
6. For album/artist/playlist long-press, use `contextMenu` and mirror detail-view capabilities; keep Search playlist menus non-destructive.
7. If action opens follow-up UI, keep ellipsis in labels (`Add to Playlist…`, `Rename…`).

## Triggering Incremental vs Full Sync

```swift
let syncCoordinator = DependencyContainer.shared.syncCoordinator

// Full sync — fetches the entire library from Plex. Use after initial setup
// or when data integrity is uncertain. Slow on large libraries.
await syncCoordinator.syncAll()

// Incremental sync — fetches only items added/updated since the last sync
// using addedAt>= / updatedAt>= Plex query params. Use for routine updates.
await syncCoordinator.syncAllIncremental()

// Hub-only refresh — fetches fresh hub data for a single source.
// Used by HomeView pull-to-refresh and the periodic 10-minute timer.
try await syncCoordinator.refreshHubs(for: sourceIdentifier)
```

**When to use each:**
- `syncAll()` — manual "sync now" triggered by user, post-account-add, or when >24h since last sync
- `syncAllIncremental()` — pull-to-refresh on library views, startup sync when 1–24h old, periodic 1h timer
- `refreshHubs(for:)` — HomeView pull-to-refresh, periodic 10-min hub timer, post-mutation refresh
