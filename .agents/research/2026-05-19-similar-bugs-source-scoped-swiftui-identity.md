# Similar Bug Scan: Source-Scoped SwiftUI Identity

**Date:** 2026-05-19
**Pattern:** SwiftUI collection renderers using default `Identifiable.id` for Plex media whose rating keys can collide across sources.
**Correct:** Use source-scoped identities for media rows and cards, or use a wrapper/positional identity when that is the stable row identity.

## Summary

| Status | Count |
|--------|-------|
| Bugs Found | 8 |
| OK (Correct Usage) | 11 |
| Needs Review | 1 |

## Bugs Found

### 1. `Packages/EnsembleUI/Sources/Cards/ArtistCard.swift:95`
Artist grids used raw artist rating keys through `Identifiable.id`.

### 2. `Packages/EnsembleUI/Sources/Screens/Library/ArtistsView.swift:1262`
Related artist shelves used raw artist rating keys through `Identifiable.id`.

### 3. `Packages/EnsembleUI/Sources/Sheets/PlaylistActionSheets.swift:122`
Playlist picker rows used raw playlist rating keys through `Identifiable.id`.

### 4. `Packages/EnsembleUI/Sources/Screens/Details/MergedPlaylistDetailView.swift:216`
Merged-playlist edit picker keyed constituent playlists by raw playlist ID.

### 5. `Packages/EnsembleUI/Sources/Screens/Discovery/HomeView.swift:241`
Home hub items used raw hub item IDs, which are Plex media IDs.

### 6. `Packages/EnsembleUI/Sources/Screens/Discovery/SearchView.swift:279`
Search recommendations used raw hub item IDs.

### 7. `Packages/EnsembleUI/Sources/Screens/Discovery/SearchView.swift:399`
Recently played album grid used raw album IDs through a generic helper.

### 8. `Packages/EnsembleUI/Sources/Screens/Library/PlaylistsView.swift:1198`
Inline playlist editor keyed tracks by raw track ID, which can collide for duplicate playlist entries or cross-source tracks.

## Correct Usage

- Album grid and related album shelves now use `Album.sourceScopedID`.
- DisplayArtist lists already use DisplayArtist IDs, which are source-scoped for singles and grouped for merged artists.
- DisplayPlaylist lists already use DisplayPlaylist IDs, which encode source for singles and grouping for merged playlists.
- Pinned item grids already use `ResolvedPinnedItem.id`, backed by pin source-scoped identity.
- Download rows use membership IDs or offline target keys.
- Queue rows use generated `QueueItem.id`.
- Track sections, album sections, genre rows, settings rows, account rows, and logs use non-media wrapper or enum identities.

## Needs Review

- Home `Hub` rows use `Hub.id`; this is a hub identity rather than an individual media identity. No bug was patched because the blank-cell symptom came from repeated media item identities inside a grid, but hub IDs may deserve a separate source-aware audit if duplicate hub sections appear across sources.
