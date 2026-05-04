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
