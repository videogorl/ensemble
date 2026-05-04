# Function Ownership And Context Menu Audit

Date: 2026-05-04

## Baseline

- `swift test --package-path Packages/EnsembleUI`: passed, 23 tests.
- `swift test --package-path Packages/EnsembleCore`: baseline runner instability. Listed suites were passing, then `xctest` exited with unexpected signal code 5 during the Core package run. Treat subsequent Core failures cautiously until reproduced after a clean retry.

## Highest-Risk Duplication Clusters

| Cluster | Current drift | Target owner | Verification |
|---|---|---|---|
| Track context menus | SwiftUI `TrackRow`, UIKit/AppKit native table builders, `QueueCard`, `MiniPlayer`, and `ControlsCard` each build different track action sets. | `MediaMenuCatalog` action sections plus platform renderers in EnsembleUI. | Catalog tests for action IDs/order by context; renderer tests for UIKit/AppKit parity. |
| Album/artist/playlist context menus | `MediaContextMenus` shares some wrappers, but wrappers still mix rendering, track resolution, offline toggles, pin behavior, and mutation actions. | Keep wrappers temporarily; make them consume `MediaMenuCatalog` and shared media-resolution services. | Search menus remain non-destructive; library/sidebar/detail menus expose management actions only where allowed. |
| Playlist add actions | `presentPlaylistPicker` and quick-add helpers are repeated across NPV cards, MiniPlayer, Songs, Artists, Favorites, Mood, Search, and StageFlow. | Core `PlaylistActionService`; EnsembleUI `PlaylistActionPresentationHost`. | Add-to-recent compatibility tests and UI smoke tests for every migrated surface. |
| Sidebar playlist drops | `MainTabView.SidebarPlaylistDragDropHost` owns media payload resolution, source compatibility, dedupe, and toasts. | Core `MediaTrackResolver` and `PlaylistDropResolver`; UI owns only drag/drop presentation. | Drop resolver tests for track/album/playlist, smart/unresolved/cross-source, and dedupe. |
| Source identity | Server/library key parsing is repeated in `NowPlayingViewModel`, `SyncCoordinator`, `SyncExecutionController`, `OfflineDownloadService`, and `MainTabView`. | Core `MediaSourceIdentity`. | Parse/comparison tests for full library keys, server keys, nil/empty values, and cross-server rejection. |
| Track swipe action presentation | UIKit/AppKit use `NativeTrackSwipeActionPresenter`; SwiftUI swipe helpers still duplicate titles, icons, tints, and toasts. | Generalized `TrackActionPresentation`. | Presenter tests for favorite state, toast payloads, and supported action filtering. |
| Filters and formatters | `applyFilters`, duration strings, and byte strings are repeated across detail VMs and views. | Core `MediaFilterEngine` and `MediaFormatters`. | Boundary tests for durations/bytes and parity tests for detail filters. |
| Siri matching | Query normalization and fuzzy scoring are duplicated in app, extension, and Core. Extension does not link Core today. | New small `EnsembleSiriShared` target. | Shared tests for prefix stripping, connector trimming, token overlap, edit similarity, and payload parsing. |

## Menu Ownership Rules

- `MediaMenuCatalog` owns action order, section grouping, roles, and context gating.
- Parent views supply availability and closures through handlers; they do not rebuild menu policy.
- Common safe media actions should appear consistently across item types and platforms.
- Destructive and editing actions are context-gated:
  - Search menus are non-destructive.
  - Queue menus can add `Remove from Queue`.
  - MiniPlayer menus can add shuffle/repeat controls.
  - Pinned/sidebar menus can add `Unpin` or `Unpin All`.
  - Playlist rename/edit/delete are restricted to non-smart playlists in management contexts.

## Migration Order

1. Add `MediaMenuCatalog` and tests without changing UI.
2. Move track row, UIKit table, AppKit table, queue, and MiniPlayer menus to the catalog.
3. Make album/artist/playlist wrappers consume catalog sections while preserving existing wrapper call sites.
4. Extract playlist action and track-resolution services, then remove duplicated helper methods.
5. Extract source identity, filters, formatters, Siri shared code, and mutation workflows in separate commits.

## Implementation Notes

- Track context menus now route through `MediaMenuCatalog`; native AppKit table menu parity is covered by `testAppKitTrackContextMenuUsesSharedCatalogOrder`.
- Album, artist, playlist, and merged playlist wrappers now consume catalog sections while keeping existing wrapper call sites.
- `PlaylistActionService` owns add-to-playlist compatibility, dedupe, default-server selection, and unknown-source stamping. `NowPlayingViewModel` keeps compatibility wrappers for migrated call sites.
- `PlaylistDropResolver` and `MediaTrackResolver` now own sidebar playlist drop resolution. `MainTabView.SidebarPlaylistDragDropHost` loads `MediaDragPayload`, converts it to Core `MediaDropItemReference`, maps resolver errors to toasts, and performs the final mutation only after Core returns a resolved target and compatible tracks.
- `MediaFilterEngine` now owns shared track, album, artist, and genre filtering. ViewModels call named configurations to preserve intentional surface differences, such as album detail searching title/artist, artist detail searching title/album, favorites ignoring genre filters, and playlist/library tracks applying genre include/exclude filters.
- `NavigationCoordinator` now owns target-tab mapping and per-tab path mutation helpers. EnsembleUI adds a path-binding adapter plus a standalone `SidebarSelection` mapper so MainTabView no longer duplicates these switches between phone tab stacks and large-screen sidebar detail stacks.
- `EnsembleSiriShared` now owns Siri App Group/index constants, phrase normalization/query variants, and fuzzy scoring. App App Intents, AppDelegate fallback handling, Siri extension handlers, `SiriMediaIndexStore`, and `SiriPlaybackCoordinator` route through it instead of carrying local token-overlap/edit-distance/normalization implementations.
- `PlaylistMutationWorkflow` now owns playlist rename/delete title normalization, mutation outcome routing, and pending/success/failure toast payload policy. Playlist root rows, playlist detail actions, and sidebar pinned playlist actions route through the workflow while retaining local confirmation, optimistic list state, navigation dismissal, and pin updates in the owning view.

## Latest Verification

- `swift test --package-path Packages/EnsembleCore --filter PlaylistDropResolverTests`: passed, 5 tests.
- `swift test --package-path Packages/EnsembleCore --filter MediaFilterEngineTests`: passed, 6 tests.
- `swift test --package-path Packages/EnsembleCore --filter NavigationCoordinatorTests`: passed, 5 tests.
- `swift test --package-path Packages/EnsembleUI --filter NavigationRootHelperTests`: passed, 4 tests.
- `swift test --package-path Packages/EnsembleSiriShared`: passed, 4 tests.
- `swift test --package-path Packages/EnsembleCore --filter SiriPlaybackCoordinatorTests`: passed, 8 tests.
- `swift test --package-path Packages/EnsembleCore --filter PlaylistMutationWorkflowTests`: passed, 8 tests.
- `swift test --package-path Packages/EnsembleUI --filter Playlist`: passed, 6 selected playlist/menu tests.
- `swift test --package-path Packages/EnsembleCore`: passed, 466 XCTest tests plus 4 Swift Testing tests.
- `swift test --package-path Packages/EnsembleUI`: passed, 38 tests.
- `scripts/check_core_warning_budget.sh`: passed, 0 warnings.
- `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad (A16)' build`: passed for iPad (A16), iOS 26.4.1.
- `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk macosx -destination 'platform=macOS' build`: passed.
