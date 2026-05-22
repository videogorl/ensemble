# Top-Level Navigation Pop-In And Audio Stutter Investigation

Date: 2026-05-22

## Trigger

While music is playing on macOS, navigating between top-level sidebar destinations can produce CoreAudio `HALC_ProxyIOContext` overload logs and an audible stutter. The same flow also shows visible content pop-in: destination chrome appears first, then rows/cards/chips populate after a short delay.

## Findings

This is not primarily an Aurora frame-rate problem. Aurora should continue to run at 30fps unless constrained by Low Power Mode. The top-level navigation path produces layout and data-publication bursts that can coincide with playback.

The macOS/iPad sidebar shell renders a single selected detail subtree:

- `SidebarView.detailView` switches on `selection`.
- `sidebarNavigationStack(for:)` creates the active top-level content.
- Switching sidebar rows destroys the previous top-level view subtree and creates the next one.

Several top-level surfaces keep their display-ready state in newly-created view-local state or view-local ViewModels:

- `HomeView` creates a fresh `HomeViewModel`. Cached hubs restore asynchronously from init, so the screen can render loading/empty before cached hubs arrive.
- `FavoritesView` creates a fresh `FavoritesViewModel`, which loads tracks from CoreData in init.
- `SearchView` receives a stable `SearchViewModel` from the root, but creates fresh `PinnedViewModel` and an unused fresh `LibraryViewModel`; the unused library model still installs observers and can react to global sync/account events.
- `AlbumsView` and `ArtistsView` store section groupings in view-local `@State` (`cachedAlbumSections`, `cachedArtistSections`). These arrays are empty on every new top-level view instance, even when `LibraryViewModel` already has albums/artists.

`LibraryViewModel` also publishes raw library arrays before it publishes display projections:

- `tracks`, `albums`, `artists`, and `genres` are assigned after CoreData mapping.
- `filteredTracks`, `trackSections`, `filteredAlbums`, `displayArtists`, and available genre chips are produced by debounced Combine pipelines, usually 200-300ms later.
- Top-level views generally decide whether to show content from raw arrays, but render rows from the delayed display projections. That creates an intermediate "content shell with empty rows" state.

This explains both symptoms:

- Visual pop-in: top-level views show their layout before display projections and view-local sections are ready.
- Playback stutter: sidebar navigation, AppKit/SwiftUI layout, CoreData refresh/observer work, and delayed display projection publishes can land in a burst while audio is active.

## Likely Fix Direction

Do not mitigate by reducing Aurora cadence or pausing the root backdrop during navigation. Instead:

1. Hoist top-level ViewModels that own cached content to the root/sidebar shell, especially Home, Favorites, and pinned Search content.
2. Remove the unused `SearchView` `LibraryViewModel`.
3. Move persistent display projections out of view-local `@State` and into `LibraryViewModel` or another root-owned cache, especially album/artist sections.
4. Seed display projections synchronously when raw cached library arrays are assigned, then use background/debounced pipelines only for subsequent expensive recomputation.
5. Make top-level views gate visible content on the same display projection they render, or keep the previous non-empty projection visible while recomputing.

## Verification Needed

After the structural fix, verify on macOS with audio actively playing:

- Home -> Search -> Albums -> Songs -> Artists -> Home via sidebar.
- No `HALC_ProxyIOContext` overload entries in a focused log window.
- No blank intermediate top-level content shell before rows/cards/chips appear.

Also verify iOS simulator compile/runtime because the root view and top-level browse views are shared.
