# Similar Bug Scan: Keyboard Presenter Workarounds

**Date:** 2026-04-13
**Pattern:** Keyboard-entry flows wrapped in `keyboardSafeEditorPresentation(...)` even when the flow is a standard sheet or a context-menu editor that already presents full-screen on iPhone.
**Correct:** Use a plain `.sheet(...)` for ordinary filter/name-entry sheets, and use `phoneSafeAuxiliaryPresentation(...)` for context-menu-triggered metadata editors that already need iPhone full-screen presentation without the keyboard tracker.

## Summary

| Status | Count |
|--------|-------|
| Bugs Found | 3 |
| OK (Correct Usage) | 6 |
| Needs Review | 7 |

## Bugs Found

### 1. `Packages/EnsembleUI/Sources/Screens/FavoritesView.swift:136`
**Current code:** Favorites filter used `keyboardSafeEditorPresentation(isPresented:)`.

**Should be:** Plain `.sheet(isPresented:)` like Albums filter.

### 2. `Packages/EnsembleUI/Sources/Screens/ArtistsView.swift:150`
**Current code:** Artists filter used `keyboardSafeEditorPresentation(isPresented:)`.

**Should be:** Plain `.sheet(isPresented:)`.

### 3. `Packages/EnsembleUI/Sources/Screens/SongsView.swift:280`
**Current code:** Songs filter used `keyboardSafeEditorPresentation(isPresented:)`.

**Should be:** Plain `.sheet(isPresented:)`.

## Correct Usage (Reference)
- `Packages/EnsembleUI/Sources/Screens/AlbumsView.swift:245` - Album filter already restored to plain `.sheet(...)`.
- `Packages/EnsembleUI/Sources/Screens/ProfileView.swift:85` - Profile name editor uses plain `.sheet(...)`.
- `Packages/EnsembleUI/Sources/Screens/PlaylistsView.swift:44` - Playlist creation uses plain `.sheet(...)`.
- `Packages/EnsembleUI/Sources/Components/AlbumCard.swift:205` - Album metadata editor uses `phoneSafeAuxiliaryPresentation(...)`.
- `Packages/EnsembleUI/Sources/Components/ArtistCard.swift:141` - Artist metadata editor uses `phoneSafeAuxiliaryPresentation(...)`.
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift:285` - Root auxiliary presentation is intentionally isolated from keyboard-reactive tab chrome.

## Needs Review
- `Packages/EnsembleUI/Sources/Screens/PlaylistsView.swift:182` - Playlist rename from root list; tied to playlist chrome suppression behavior.
- `Packages/EnsembleUI/Sources/Screens/PlaylistsView.swift:195` - Smart playlist rename from root list; same risk family.
- `Packages/EnsembleUI/Sources/Screens/PlaylistsView.swift:937` - In-screen playlist rename prompt; likely coupled to the original regression surface.
- `Packages/EnsembleUI/Sources/Screens/MergedPlaylistDetailView.swift:97` - Merged playlist rename; same rename presenter family.
- `Packages/EnsembleUI/Sources/Screens/MediaDetailView.swift:279` - Shared detail filter presenter was not exposed by the populated iPhone 26.2 dataset, so it remains on the safer helper until it can be exercised directly.
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift:76` - Track metadata editor still uses `keyboardSafeEditorPresentation(...)`, but the iPhone Songs surface is backed by `MediaTrackList`, so this path was not exercised in the iOS 26 sweep.
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift:1160` and `:1170` - Root-coordinated playlist rename presenters; these are part of the remaining high-risk root-chrome path and should be changed only with dedicated runtime verification.
