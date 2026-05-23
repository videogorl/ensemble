# UI Platform Policy

Load this reference for platform navigation, native UI ownership, persistent surfaces, cached-content stability, detail surfaces, utility screens, menu/swipe actions, visual surfaces, or watch behavior.

## Policies

- Root shells own platform navigation: tab shell on iPhone, split/sidebar shell on iPadOS and macOS where supported.
- Navigation coordinators are scene/window-scoped. Do not route user-driven navigation through shared singleton state that mirrors iPad/macOS windows.
- Keep native platform owners for behavior SwiftUI does not expose: native track tables, AirPlay picker, Metal aurora, global toast window, native share/menu hosts, iOS 15 tab/mini-player bridges, and macOS menu/window behavior.
- On iOS and iPadOS, the root mini player should hide while the software keyboard is visible. Root chrome owners should suppress the mini-player overlay and its reserved clearance instead of letting the mini player ride above the keyboard, then fade the mini player back in after keyboard dismissal.
- Treat new safe-area compensation, delayed layout tasks, custom scroll detectors, root-chrome mutation, toolbar proxies, or broad UIKit/AppKit appearance changes as suspect until a current simulator/macOS repro proves native behavior is broken.
- Persistent list/detail surfaces should observe focused projections or local state snapshots, not broad high-frequency singleton objects.
- Library browse screens that have already displayed cached content should not publish transient empty lists or swap to blank loading states during refresh.
- Shared media menu and swipe action policy lives in `MediaMenuCatalog` and native table/menu renderers. Parent views should add only local handlers.
- iPhone and iPad native track-list rows expose configured track swipe actions from the shared swipe layout; do not gate `MediaTrackList` swipe configurations to phone idiom only.
- Library track, album, and single-playlist context menus expose `Get Info…` through `MediaMenuCatalog`. iOS/iPadOS present it as a sheet; macOS presents one reusable native window whose content updates for the latest selected item. The panel shows file/library metadata only and must not include live Now Playing rows such as current playback file, queue quality, lyrics, network, or active connection status. Track and album file sections may show original Plex media paths, but those paths must be hidden when Demo Mode is enabled.
- The macOS Dock menu is an AppKit bridge owned by the app target. It shows pinned albums/artists/playlists first, then Now Playing controls, and dispatches to existing navigation, playback, and mutation owners instead of creating alternate UI business logic.
- Detail screens with artwork-backed washes should use shared detail surface and toolbar-bleed owners so media details, download details, and artist details do not drift. Media detail artwork should use one image-loading owner for the header and backdrop: reserve a stable artwork frame, seed from low-resolution artwork, then replace with the full-resolution image without an intermediate nil/placeholder frame. Backdrops should keep the previous resolved artwork wash while the next detail artwork is unavailable, then cross-fade the wash only when the new artwork arrives. Artist detail hero images should avoid nil-to-image layout flashes and may use the same low-resolution seed before the full image resolves. Content should still render immediately without artificial reveal delays.
- Media detail screens should render cached header/list content immediately. User-driven navigation from a surface that already has an `Album`, `Artist`, or `Playlist` model, including resolved sidebar pins, should push the concrete detail view directly instead of routing through an ID-only loader. Do not hide cached detail content behind artificial reveal delays, opacity fades, or supplemental metadata loads; richer metadata may fill in after the base detail surface is interactive.
- Playlist detail navigation should not load or map full track relationships before rendering the detail surface. If tracks or derived filters are still loading, show that state inside the track list/footer and reserve stable genre-chip header space so the header and toolbar remain stable.
- Loading, empty, and error states should use shared state scaffolds rather than rebuilding decision trees per screen.
- The Lyrics panel may expose chord streams with the `music.pages` control beside instrumental mode when the current track has a chord stream. Chord rendering is fully monospace, treats whitespace as source data, colors chord symbols with the selected app accent color, renders chord rows paired above lyric rows, shows `🎵🎵🎵` as the lyric placeholder for chord-only rows, wraps chord and lyric text on shared character-column boundaries, does not apply progressive lyric blur, and highlights the current plus next timed row so musicians can prepare for upcoming changes. Timed chord parsing treats timestamped rows as lyric rows and the immediately preceding untimestamped physical row as that timestamp's chord row. Untimed chord streams use simple physical row pairs: chord row, then lyric row. Paired wrapping is applied within each visual lyric line so manual returns do not count as chord columns.
- Watch is an independent lightweight Plex client plus optional iPhone remote, not a full `EnsembleCore`/`EnsembleUI` client. Downloads are outside the current standalone watch scope.

## Owners

- `RootView`, `MainTabView`, and `SidebarView` own root navigation, root chrome, auxiliary presentation, and scene/window coordinator injection.
- `NavigationCoordinator` owns typed destinations, pending navigation, active auxiliary presentation, and scene-local routing.
- `EnsemblePlatformFeaturePolicy` owns shared platform feature availability.
- `MediaTrackList`, `SongsTrackListHost`, native menu/share hosts, AirPlay, Metal, and toast bridges own platform-specific behavior.
- `MediaMenuCatalog`, `NativeMediaTableActionBuilder`, and menu renderers own shared action availability and ordering.
- `EnsembleScaffold`, `MediaDetailSurface`, `ArtworkDetailBackground`, and design tokens own shared UI structure and visual policy.

## Implementation Hooks

- Load `ui-conventions` for detailed SwiftUI/component implementation rules after loading this policy.
- Keep search, tab, toolbar, and mini-player chrome ownership at the root or platform owner; avoid leaf-level fixes unless the leaf owns the real platform behavior.
- Keep compact iPhone fallbacks separate from large-screen split behavior.
- Use shared scaffolds, labels, icons, materials, and track-list metrics instead of local duplicates.
- Use native commands and keyboard shortcuts where available; do not install app-wide input monitors for ordinary shortcuts.

## Verification

- Use simulator/macOS validation for navigation, modal presentation, keyboard, toolbar, safe-area, split-view, or root chrome changes.
- Use screenshot or accessibility evidence for substantial visible UI behavior changes.
- Validate Lyrics chord UI changes for button visibility, monospace alignment, paired wrapping, chord-only timed rows, and current-plus-next highlighting.
- Use performance checks when changing persistent root/list observation, Feed refresh UI, Downloads queue UI, or high-frequency visual surfaces.
