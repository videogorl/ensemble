---
name: common-tasks
description: "Ensemble step-by-step recipes: adding ViewModels, views, CoreData entities, hub support, running sync, working with hubs. Code patterns and examples."
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
