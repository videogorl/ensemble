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

## Adding Large-Screen Browse Polish

For browse roots that need a regular-width selection/detail layout:

1. Keep the existing compact list/push navigation as the compact root fallback.
2. Keep `SidebarView`'s root `NavigationSplitView` as the stable app sidebar + detail host. Put the browse list/detail split inside the selected section's detail host so the app sidebar is not recreated when switching between single-pane and browse sections.
3. Store the selected item in `SidebarView` state; pass it into the browse screen's selection-column mode with a `Binding`.
4. Use `LargeScreenPlaceholderView` for the unselected state.
5. Add `.refreshCommand { await viewModel.refresh() }` whenever the screen already supports `.refreshable`.

Do not route iPhone through the large-screen browse host, and do not remove existing compact navigation links.

## Modifying StageFlow Browse Surfaces

`MainTabView` owns iPhone StageFlow activation, chrome suppression, and the single rotation-support registration. Browse screens should only read `@Environment(\.isStageFlowActive)` and swap their local content when the root says StageFlow is active.

When adding or changing a StageFlow-capable browse screen:
1. Add the tab to `MainTabView.selectedTabSupportsStageFlow` if it should unlock landscape.
2. Keep playback resolution and `StageFlowTrackPanel` ownership in the browse screen.
3. Do not add screen-local `GeometryReader` landscape detection, rotation delay timers, or `stageFlowRotationSupport(...)`; those recreate the presenter during sheet/keyboard flows.
4. Do not delay root orientation unregister when the selected tab stops supporting StageFlow; unsupported tabs should return to portrait immediately so custom root chrome is not laid out in transient landscape.

## Adding a New Now Playing Panel/Card

When adding a new card/panel to the Now Playing view, it must be added in **three** places:

1. `NowPlayingCarousel.swift` — iPhone swipe carousel (TabView pages)
2. `NowPlayingViewportRoot.swift` — iPad/macOS two-column detail panel
3. `ExternalDisplayNowPlayingView.swift` — AirPlay external display detail panel

All three switch on `viewModel.currentPage`. Assign your new card a page index and add a case in each file's `detailPanel` / carousel body.

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

// Save a last-good Feed snapshot for offline-first launch.
let snapshot = HomeFeedCachedSnapshot(
    sourceScopeKey: "plex:account:server",
    sourceName: "Editing Music",
    fetchedAt: Date(),
    refreshReason: "network",
    freshnessState: .fresh,
    isLastGood: true,
    hubs: hubs
)
try await deps.hubRepository.saveHomeFeedSnapshot(snapshot)

// Load cached hubs
let cachedSnapshot = try await deps.hubRepository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:server")

// Clear all cached hubs
try await deps.hubRepository.deleteAllHubs()
```

Rules:
- Feed refresh should use `HomeHubLoader` or `BackgroundRefreshCoordinator`, not a transient `HomeViewModel`.
- Do not save empty network hub results over the last-good snapshot.
- Use `saveHubs(_:)`/`fetchHubs()` only for legacy compatibility; new Feed freshness work should use `HomeFeedCachedSnapshot`.

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

## Updating Plex Source Selection (Account-Centric Flow)

When modifying Plex library enablement/sync behavior:
1. Keep source entry points in `SettingsView` and `MusicSourceAccountDetailView` (do not reintroduce standalone sync-panel routes).
2. Use `MusicSourceAccountDetailViewModel.refreshInventory()` reconciliation semantics:
   - Newly discovered libraries default to unchecked.
   - Removed libraries are auto-disabled and purged.
3. For toggle-off behavior, call `toggleLibraryEnabled(...)` and preserve selective purge semantics:
   - Purge only the unchecked library’s cache.
   - If no enabled libraries remain on that server, also purge server-level playlists via `SyncCoordinator.purgeServerPlaylists(...)`.
4. Keep sync-enable (`PlexLibraryConfig.isEnabled`) logic separate from non-destructive visibility filtering.

## Working With LibraryVisibilityProfile Groundwork

Use this for browse-surface visibility controls that must not affect sync:

```swift
let store = DependencyContainer.shared.libraryVisibilityStore

// Hide a source in the active profile (without changing isEnabled)
store.setSourceVisibility(sourceCompositeKey: sourceKey, isVisible: false)

// Switch active profile
store.setActiveProfile(id: profileID)
```

Rules:
- Visibility profiles hide/show content only; they do not enable/disable sync libraries.
- Apply profile filtering in ViewModels after loading data (`LibraryViewModel`, `SearchViewModel`, `HomeViewModel` seams).
- Keep source filtering keyed by full `sourceCompositeKey` to avoid collisions across servers/libraries.

## Creating a DetailLoader

For new content types that need async hub-to-detail navigation:

Before adding new root navigation glue, register typed destinations through `NavigationCoordinator.Destination`. Reuse `NavigationCoordinator.targetTab(for:)`, `pathSnapshot(for:)`, `setPath(_:for:)`, and EnsembleUI's `pathBinding(for:)` extension for per-tab stacks. On iPad/macOS sidebar roots, map destinations through `SidebarSelection.selection(for:fallback:)` so compact/regular split behavior stays consistent.

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

var filteredTracks: [Track] {
    MediaFilterEngine.filterTracks(items, with: filterOptions, configuration: .library)
}

// Load/save persisted filters
FilterPersistence.load(for: "MyView")
FilterPersistence.save(filterOptions, for: "MyView")
```

Use `MediaFilterEngine` instead of reimplementing search, genre, download, year, or artist filters in views or ViewModels. Pick an existing named configuration (`.library`, `.playlistDetail`, `.favorites`, `.albumDetail`, `.artistDetail`) or add a tested configuration when a surface intentionally differs. Keep expensive filtering/sorting out of SwiftUI body computation; cache results through a Combine pipeline when the source list can be large.

Use `MediaFormatters` instead of local `ByteCountFormatter`, minute/second, or collection-duration helpers. `bytes(_:)` is for download estimates/progress, `fileBytes(_:)` is for ordinary file-size display, `logBytes(_:)` is for diagnostic log sizes, and `trackClock(_:)`/`collectionDuration(_:)` cover media durations.

## Working with Playlist Mutations

All playlist mutations go through `SyncCoordinator`, which handles the server call and then refreshes the local CoreData cache automatically.

## Adding Media Drag And Drop

Use `MediaDragPayload` in `Packages/EnsembleUI/Sources/Utility/` for in-app drags involving tracks, albums, playlists, or merged display playlists. Track drag sources should use `MediaDragPayload.trackItemProvider(for:shareService:)` on iOS/iPadOS and `MediaDragPayload.trackPasteboardWriter(for:shareService:)` for native AppKit rows: both keep the app-specific payload internal for Ensemble drops, and expose the same prepared audio file URL and `TrackFileExportMetadata` export naming used by Share File to external destinations such as Finder or Files. Do not expose the JSON fallback to external pasteboards.

Playlist drops are copy/add operations only. UI drag providers should route through `MediaDragExportPolicy` so track drags keep internal payload plus external file-promise copy support while album/playlist drags stay app-internal only. Drop surfaces should load `MediaDragPayload`, pass `payload.dropReferences` into Core `PlaylistDropResolver`, then present toasts for `PlaylistDropResolutionError`. Do not duplicate media matching, source compatibility, album/playlist expansion, or dedupe in views. Reject smart or merged playlist targets, unresolved items, and cross-source drops without changing playlist contents.

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
- Use `PlaylistActionPresentationHost` plus `.playlistActionPresentation(request:nowPlayingVM:)` for view-owned "Add to Playlist…" sheets and recent-playlist quick actions. Do not add local `PlaylistPickerPayload` structs, duplicate `PlaylistPickerSheet` modifiers, or direct recent-playlist add logic in root/detail views.
- Use `PlaylistMutationWorkflow` for playlist rename/delete UI, including merged playlist Rename All/Delete All. It returns pending/result toast payloads and mutation outcomes; views should only handle confirmations, local optimistic state, navigation dismissal, and pin/sidebar updates. Treat merged "all" operations strictly: partial rename is a warning and partial delete is an error.
- Use `MetadataMutationWorkflow` for track, album, and artist metadata edit/delete UI. It builds mutation requests, calls the mutation service, and returns standardized toast payloads; views should only own local `ContextMenuMetadataEditorRequest` sheet state, confirmation dialogs, and post-delete navigation. Do not route context-menu metadata editors through root presenters or hide local navigation/search chrome around them.
- Use `PlaylistActionService` or the `NowPlayingViewModel` compatibility wrappers before add-to-playlist mutations. They normalize library-scoped keys to server keys, reject known cross-server tracks, dedupe repeated tracks, and stamp unknown-source tracks with the selected server key for the mutation path.
- Use `PlaylistDropResolver` for drag/drop playlist copy-add flows. It returns the resolved target playlist and compatible tracks; the view should only call `addTracksOptimistically(_:to:)` and map resolver errors to user feedback.

## Adding Offline Download Targets (Library / Album / Artist / Playlist)

Use this flow for target-based offline support:

1. Persist target state in `OfflineDownloadTargetRepository` using a stable target key:
   - `OfflineDownloadService.targetKey(kind:ratingKey:sourceCompositeKey:)`
2. Resolve memberships from repositories:
   - library target: `LibraryRepository.fetchTracks(forSource:)`
   - album target: `LibraryRepository.fetchTracks(forAlbum:sourceCompositeKey:)`
   - artist target: `LibraryRepository.fetchTracks(forArtist:sourceCompositeKey:)`
   - playlist target: `PlaylistRepository.fetchPlaylist(ratingKey:sourceCompositeKey:)` + tracks
3. Upsert downloads through source-aware `DownloadManager` APIs:
   - `createDownload(forTrackRatingKey:sourceCompositeKey:quality:)`
   - `fetchDownload(forTrackRatingKey:sourceCompositeKey:)`
   - `deleteDownload(forTrackRatingKey:sourceCompositeKey:)`
4. Keep removal reference-counted by checking membership counts before deleting local files.
5. Trigger reconcile after source changes:
   - observe `SyncCoordinator.sourceStatuses` for sync timestamp updates in download/offline services
   - observe `SyncCoordinator.lastContentChange` for browse-surface reloads; do not drive full library reloads from generic `sourceStatuses` churn
   - wire `SyncCoordinator.onPlaylistRefreshCompleted` for playlist-target refresh
6. Respect download quality by reading `downloadQuality` and passing mapped `StreamingQuality` into stream URL generation.

Background/recovery rules:
- Keep `OfflineDownloadService` as the queue and target source of truth. Platform events must route through `OfflineDownloadBackgroundCoordinating`; do not start queue work directly from `AppDelegate`, macOS delegates, or URLSession callbacks.
- iOS background URLSession wakeups call `handleBackgroundURLSessionEvents(identifier:completionHandler:)`; the completion handler must run only after download recovery/healing and target progress refresh complete.
- macOS sleep should pause in-flight bookkeeping as resumable/paused, not failed. Wake/foreground should run the same recovery sweep and then resume eligible pending work under network/user/Low Power policy.
- Stale `.downloading` records from a previous process/session must be normalized to `.pending` or `.paused`; never leave them stuck in `.downloading`.

UI integration rules:
- Settings manager entry point remains `SettingsView` -> `DownloadManagerSettingsView` (do not repurpose `DownloadsView`).
- Keep library-wide offline toggles inside `DownloadManagerSettingsView`; only include sync-enabled libraries.
- Album/artist/playlist download toggles are context/detail menu actions (`Download` / `Remove Download`), not inline buttons.
- Track rows should dim and block taps offline when `!track.isDownloaded`, with toast feedback.

## Adding Track Swipe or Long-Press Actions

Use these patterns when extending gesture actions:

1. Add/adjust action definitions in `SettingsManager.TrackSwipeAction` and keep `TrackSwipeLayout.default` sane (2 leading + 2 trailing).
2. Ensure layout sanitization prevents duplicate assignments and malformed persisted payloads.
3. For track lists, prefer `MediaTrackList` or `SongsTrackListHost` so row actions stay native and shared across iOS/iPadOS/macOS.
4. For detail track tables, map actions in `MediaTrackList` via `leadingSwipeActionsConfigurationForRowAt` / `trailingSwipeActionsConfigurationForRowAt`.
5. For high-volume track rows/cards/tables, accept `TrackActionDispatching` for playback/queue/favorite/playlist commands and observe `NowPlayingRatingProjection` or row-local state instead of the full `NowPlayingViewModel`.
6. For favorite mutations, call `NowPlayingViewModel.toggleTrackFavorite(_:)`, `setTrackFavorite(_:for:)`, or the matching `TrackActionDispatching` method so server rating + local cache stay consistent.
7. For context menus, define the allowed action set in `MediaMenuCatalog` and render it through `SwiftUIMediaMenuRenderer`, `UIKitMediaMenuRenderer`, or `AppKitMediaMenuRenderer`. For standalone SwiftUI track cards/menus, use `TrackActionsContextMenu`. Parent views should add only scoped actions such as queue removal, pin/unpin, edit/delete, shuffle/repeat, playlist-picker presentation, or playlist management.
8. If action opens follow-up UI, keep ellipsis in labels (`Add to Playlist…`, `Rename…`).

## Adding or Updating Siri Media Play Intents (In-App-First)

Use this flow for Siri phrases like "play track/album/artist/playlist ... on Ensemble":

1. Use `EnsembleSiriShared` for all Siri phrase normalization and fuzzy scoring:
   - `SiriSharedConstants` owns the App Group identifier and Siri index filename.
   - `SiriPhraseNormalizer` owns basic normalization, app-name suffix trimming, connector-word trimming, media-type prefix stripping, and query variants.
   - `SiriMatchScorer` owns exact/prefix/contains/token-overlap/edit-distance scoring.
   - Do not add new local `normalize`, `scoreMatch`, token-overlap, or edit-distance implementations in app, extension, or Core code; add shared tests in `Packages/EnsembleSiriShared/Tests/` instead.
2. Keep extension logic thin in `EnsembleSiriIntentsExtension/PlayMediaIntentHandler.swift`:
   - Resolve candidates from `SiriMediaIndexStore` data.
   - Rank deterministically (exact normalized > prefix > contains + tie-breakers).
   - Return disambiguation when confidence is close.
   - Return `.handleInApp` only; never execute playback in the extension.
3. Encode handoff payload with `SiriPlaybackActivityCodec` (`SiriIntentPayload.swift`) and include schema version.
4. Route in app lifecycle via `AppDelegate+Siri.application(_:continue:restorationHandler:)`.
5. Execute playback in `SiriPlaybackCoordinator`:
   - `executePlayTrack(request:)`
   - `executePlayAlbum(request:)`
   - `executePlayArtist(request:)`
   - `executePlayPlaylist(request:)`
6. Use repository precision-search APIs for Siri matching (`LibraryRepository`/`PlaylistRepository`), scoped to enabled source keys.
7. Keep index fresh by posting `SiriMediaIndexNotifications.postRebuildRequest(...)` after sync/account configuration changes.
8. Add App Intents fallback for album/playlist in app target (`EnsembleAppShortcutsProvider`) so phrase routing still reaches Ensemble when SiriKit media-domain handoff misses.
9. After index availability checks/rebuilds at launch, call `EnsembleAppShortcutsProvider.updateAppShortcutParameters()` (iOS 16+) to refresh Siri shortcut parameter vocabulary.

Coordinator usage pattern:
```swift
let payload = SiriPlaybackActivityCodec.payload(from: userActivity.userInfo)
if let payload {
    try await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
}
```

App Intents fallback pattern:
```swift
if #available(iOS 16.0, *) {
    EnsembleAppShortcutsProvider.updateAppShortcutParameters()
}
```

## Adding a New Synced Feature to KVS

When adding a new setting or data type to iCloud KVS sync:

1. **Add a KVS key** in `KVSSyncService` for the new data:
```swift
// In KVSSyncService
static let myFeatureKey = "ensemble_myFeature"
```

2. **Add a feature toggle** in `SyncSettingsManager`:
```swift
// Add case to the SyncFeature enum or add a new toggle property
@Published var isMyFeatureSyncEnabled: Bool {
    didSet { UserDefaults.standard.set(isMyFeatureSyncEnabled, forKey: "syncMyFeature") }
}
```

3. **Add a remote-change callback** to handle incoming KVS data:
```swift
// In the service that owns the data (e.g., SettingsManager, PinManager)
func applyRemoteMyFeature(_ data: Data) {
    // Decode and merge remote data, remote wins on conflict
}
```

4. **Add push wiring** so local changes push to KVS:
```swift
// After local mutation, push to KVS if enabled
if syncSettingsManager.isMyFeatureSyncEnabled {
    kvsSyncService.push(key: KVSSyncService.myFeatureKey, value: encodedData)
}
```

5. **Gate with SyncSettingsManager toggle** — always check `syncSettingsManager.isMyFeatureSyncEnabled` before pushing or applying remote changes.

6. **Wire in DependencyContainer** — register the KVS observer callback in `DependencyContainer` alongside existing sync wiring.

**Rules:**
- KVS has a 1 MB total limit and 1024 key limit — only use for small data.
- Echo-loop suppression is automatic in `KVSSyncService` (1s window after push).
- If the feature has a dependency (like libraries → sources), add cascade logic in `SyncSettingsManager`.
- On re-enable, pull from iCloud and overwrite local (consistent with existing re-enable flow).

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
