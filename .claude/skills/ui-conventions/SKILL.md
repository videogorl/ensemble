---
name: ui-conventions
description: "Load before building or modifying any SwiftUI view. Ensemble UI/UX conventions: navigation behavior, tab management, visual design specs, loading/error states, performance optimization, iOS 15 compatibility, DetailLoader pattern."
---

# Ensemble UI/UX Conventions

These are core design decisions that must be maintained throughout the app.

## Navigation Behavior

### Tab Navigation
- **Pop-to-root on re-tap:** When a tab button is tapped while already selected, pop to root if there's a navigation stack, otherwise request focus (for Search tab)
- **Implementation:** See `MainTabView.handleTabTap()` for reference
- **Haptic feedback:** Tab taps trigger `UISelectionFeedbackGenerator`
- **More tab support:** First 4 enabled tabs in tab bar, remaining tabs via "More" tab (5th position)
- **Tab customization:** Users enable/disable tabs via Settings; disabled tabs hidden from tab bar
- **Visible tabs sync:** `NavigationCoordinator.visibleTabs` synced from MainTabView for fallback logic

### Deep Linking
- **NavigationCoordinator.Destination:** Use typed destinations (artist, album, playlist, view) for all deep links
- **Pending navigation:** From sheets (like Now Playing), set `pendingNavigation` to defer until sheet dismisses
- **Tab fallback:** If navigating from Search tab (or hidden tab), fall back via `visibleTabs.first ?? .home`

### iOS 15 Compatibility
- **iOS 16+:** `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** `NestedNavigationLink` recursive pattern in `MainTabView.swift`
- **Feature detection:** Always wrap iOS 16+ features in `@available(iOS 16.0, *)` checks
- **Bottom spacing for mini player/tab bar:** Use `.miniPlayerBottomSpacing(...)` from `View+Extensions.swift` instead of ad-hoc per-screen spacer blocks

**NestedNavigationLink Pattern** (in `MainTabView.swift`):
```swift
struct NestedNavigationLink<Content: View>: View {
    let path: [NavigationCoordinator.Destination]
    let content: Content

    var body: some View {
        if let first = path.first {
            NavigationLink(destination: nextView(for: first)) { content }
        } else {
            content
        }
    }

    private func nextView(for destination: Destination) -> some View {
        NestedNavigationLink(path: Array(path.dropFirst())) {
            // Render destination view (AlbumDetailLoader, etc.)
        }
    }
}
```

**Feature Detection Pattern:**
```swift
if #available(iOS 16.0, macOS 13.0, *) {
    NavigationStack(path: $coordinator.homePath) { ... }
} else {
    NavigationView {
        NestedNavigationLink(path: coordinator.homePath) { ... }
    }
}
```

## Native UI Components

### Tab Bar
- **Stay native:** Use SwiftUI's native `TabView` unless there's a compelling reason
- **Immersive mode:** Tab bar hidden via `ChromeVisibilityPreferenceKey` (StageFlow, full-screen)
- **iOS 18+:** Uses `.sidebarAdaptable` tab view style when available
- **Mini player offset:** MiniPlayer sits 56pt above tab bar on iPhone

### StageFlow + Rotation Policy
- StageFlow is **iPhone-only** (`UIDevice.current.userInterfaceIdiom == .phone`), even though iPad shares `os(iOS)`.
- iPadOS and macOS always use their standard list/grid layouts for Songs, Albums, and Playlists.
- iOS orientation is portrait-locked by default and only unlocks landscape while a StageFlow-capable root view is active.

### Button Labels

- **Buttons that open a sheet or modal must end with an ellipsis (`…`)** — this is the Apple HIG convention signalling that the action requires further input before completing:

```swift
Button("Add to Playlist…") { showingPlaylistSheet = true }
Button("Rename…") { showingRenameSheet = true }
Button("Create Playlist…") { showingCreateSheet = true }
```

- Buttons that perform an immediate action (play, delete, save) do **not** get an ellipsis:

```swift
Button("Play") { play() }
Button("Remove", role: .destructive) { remove() }
```

Use the actual ellipsis character `…` (U+2026), not three dots `...`.

### System Integration
- Leverage native SwiftUI components and iOS system features (e.g., `AVRoutePickerView` for AirPlay, `MPRemoteCommandCenter` for lock screen)
- Views should adapt to platform idioms (tab bar on iPhone, sidebar on iPad/macOS)
- Respect safe areas unless deliberately edge-to-edge (like StageFlow)

### Desktop Sheets (macOS)
- Avoid reusing iOS-style `NavigationView` + `Form` modal shells on macOS for complex sheets; they tend to collapse into split/sidebar or table-like layouts.
- Prefer `DesktopSheetScaffold` for macOS modal chrome: title/subtitle header, flexible content region, and footer action bar.
- Keep desktop sheet sizing consistent with scaffold defaults unless a flow genuinely needs a different footprint.
- When a desktop flow needs drill-in selection (artists/genres, etc.), prefer a secondary focused sheet over embedding navigation chrome into the primary sheet.

### Now Playing on iPad/macOS
- iPad and macOS Now Playing should present as an in-app viewport-filling overlay, not a floating phone-style sheet.
- Reuse the existing Now Playing cards (`ControlsCard`, `QueueCard`, `LyricsCard`) and change the outer shell first before considering card-specific rewrites.
- For side-by-side layouts, prefer a desktop/tablet header with explicit close affordance and simple panel switching over page indicators or dismiss pills.
- On macOS, keep the Now Playing header below the window toolbar region and bind Escape to dismiss so close controls never compete with toolbar items.
- When viewport Now Playing is active, hide the underlying navigation/window chrome so titles, search bars, and toolbar items from the host screen do not show through behind the overlay.

### Toast Presentation
- iOS/iPadOS toasts are mounted once at app root via `installGlobalToastWindow(toastCenter:)` in `EnsembleApp`
- Do not mount `ToastHostView` in individual screens; call `deps.toastCenter.show(...)` and let the global host render it
- Global toast window must stay above mini player and modal sheets for consistent feedback visibility

### Gesture Actions (iOS/iPadOS)
- Track rows use a shared swipe layout from `SettingsManager.trackSwipeLayout` (2 leading slots, 2 trailing slots)
- Slot 1 on each edge is full-swipe enabled; slot 2 is reveal-only
- Supported swipe action catalog in v1: `Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle
- Keep primary tap behavior unchanged (tap still plays/navigates as before)
- Use `TrackSwipeContainer` for SwiftUI rows and `MediaTrackList` swipe delegates for UIKit-backed track lists
- macOS keeps existing interaction model (no custom swipe gesture layer in v1)

### Long-Press Menus
- Prefer `contextMenu` on album/artist/playlist cards/rows to mirror detail-view actions
- Album menu: `Play`, `Shuffle`, `Play Next`, `Play Last`, `Radio`, `Add to Playlist…`, `Pin/Unpin`
- Artist menu: `Play`, `Shuffle`, `Radio`, `Pin/Unpin`
- Playlist menu (Playlists screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin`, plus (for non-smart playlists) `Rename…`, `Edit Playlist`, `Delete`
- Playlist menu (Search screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin` (non-destructive only)

## Visual Design

### Artwork Display
- **Hub items:** 140x140pt artwork
- **Corner radius:** Albums/playlists use 8pt; artists use 70pt (circular)
- **Shadows:** `Color.black.opacity(0.15)` with radius 6 for card depth
- **Blurred backgrounds:** NowPlayingView and detail views use `BlurredArtworkBackground`

### Typography & Spacing
- **System fonts:** SF Pro with semantic styles (.headline, .subheadline, etc.)
- **Line limits:** `.lineLimit(1)` or `MarqueeText` for auto-scrolling long titles
- **Information density:** Dense layouts without clutter

## Loading & Error States

### Async Loading
- **DetailLoader pattern:** Use `AlbumDetailLoader`, `ArtistDetailLoader`, `PlaylistDetailLoader` for hub-to-detail navigation
- **Loading indicators:** `ProgressView` with descriptive text
- **Error handling:** Display error messages with retry options; never crash or show empty screens without explanation
- **Offline-first:** Load cached data immediately, then fetch fresh data in background

### Hub Loading
- **2-second debouncing** to prevent rapid successive loads
- **Fallback:** If fewer than 3 section hubs, fall back to global hubs
- **Empty states:** `EmptyLibraryView` with sync prompts

## DetailLoader Pattern

Async loading wrappers for smooth hub-to-detail navigation:

Three loaders in `EnsembleUI/Sources/Components/`:
- `AlbumDetailLoader` -- Loads full album data by ratingKey
- `ArtistDetailLoader` -- Loads full artist data by ratingKey
- `PlaylistDetailLoader` -- Loads full playlist data by ratingKey

Each follows this pattern:
```swift
struct AlbumDetailLoader: View {
    let albumId: String  // ratingKey from HubItem
    @State private var album: Album?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        if let album = album {
            AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
        } else if isLoading {
            ProgressView() + "Loading album..."
        } else if let error = error {
            ErrorView(error: error)
        } else {
            "Album not found"
        }
    }

    .task {
        album = try await deps.libraryRepository.fetchAlbum(ratingKey: albumId)
    }
}
```

**Benefits:**
- Separation of concerns: Hub data (lightweight) vs. full entity data (complete)
- Performance: Hub items load instantly with minimal data
- Offline support: Hubs display even when full sync hasn't completed
- Smooth UX: Loading spinner during fetch, not blocking navigation

## Performance Optimization

### Memory Efficiency (iOS 15 / 2GB RAM)
- **Lazy loading:** Use `LazyVGrid`, `LazyVStack`, and lazy image loading via Nuke
- **Background contexts:** Heavy CoreData operations use `CoreDataStack.performBackgroundTask`
- **Image caching:** Two-tier (filesystem + Nuke in-memory) with 100MB disk cache limit
- **Task.detached:** For non-blocking background work

### Debouncing
- **Network monitor:** 1s to reduce unnecessary UI updates
- **Home screen loading:** 2s to prevent rapid reloads
- **App launch:** Network monitor starts with 500ms delay

### GeometryReader: Background, Not Wrapper
Never wrap large view trees in `GeometryReader`. Use `.background(GeometryReader { ... })` to capture geometry into `@State`, then branch on the state value in body. Wrapping causes the entire subtree to re-layout on every geometry change.

### Context Menu Extraction
If a grid/list holds `@ObservedObject` only for context menu content (e.g., pinManager), extract the context menu into a separate View struct that owns the observation. This prevents the entire grid from re-evaluating when pin state changes.

### Scoped Sub-View Observation (MiniPlayer Pattern)
When a view needs multiple fields from a frequently-publishing ViewModel, extract observation into small sub-views:
- **Parent:** `let viewModel` (no observation) — handles layout, gestures, context menu
- **Sub-views:** `@ObservedObject var viewModel` — each reads only its relevant fields (track info, controls, background)

This prevents the entire parent tree from re-evaluating on every publish.

### `.searchable()` in Nested Sheets
`.searchable()` has version-specific bugs in nested presentation contexts (sheet-on-fullScreenCover). iOS 15 can freeze keyboard input.

**iOS 26 crash:** `NavigationView` + `.searchable()` triggers 997+ "Observation tracking feedback loop detected!" errors from `ScrollPocketCollectorModel`, freezing/crashing the app. **Fix:** Use `NavigationStack` on iOS 16+ (which is already the default in `MainTabView.tabRootView`). For sheets that create their own navigation container (like `PlaylistPickerSheet`), use `if #available(iOS 16.0, ...) { NavigationStack } else { NavigationView }`.

Tab-level views are already inside `NavigationStack` on iOS 16+ and are not affected. The crash was specific to `NavigationView` in sheet contexts.

## Genre Chip Bar

### GenreChipBar Pattern
- **Component:** `GenreChipBar` — horizontal scrollable chip bar for inline genre filtering
- **Behavior:** OR multi-select (selecting multiple genres shows items matching any selected genre)
- **Visibility:** Only renders when 2+ genres are available; hidden otherwise
- **Chip style:** Capsule shape — accent border when unselected, accent fill + white text when selected
- **Layout:** Fixed 36pt height, placed above content inside ScrollView
- **Clear button:** An xmark chip appears when any genres are selected, clearing the selection on tap
- **Usage:** Integrated into AlbumsView, SongsView, ArtistsView, PlaylistDetailView, and wired into FilterSheet

## Informational Badges

### Feature / Capability Badges
- **Pattern:** `ServerFeatureBadges` (private view in `MusicSourceAccountDetailView.swift`) displays small icon+label badges for server-level capabilities (e.g., Plex Pass, hardware transcoding).
- **Style:** Compact horizontal badges with SF Symbol + short label, secondary foreground color.
- **Per-library indicators:** Download permission badge (arrow.down.circle.fill) shown inline on library rows when `allowSync` is true.
- **Data source:** Badges are driven by `PlexServerCapabilities` and `PlexSubscription` populated during discovery -- no additional API calls at display time.

## Feature Philosophy

### Preserve Existing Functionality
- **Don't remove features** when refactoring unless explicitly directed
- **Backward compatibility:** Maintain iOS 15 support; use feature detection for newer OS
- **User preferences:** Respect accent colors, enabled tabs, filter preferences

### Incremental Enhancement
- Extend rather than replace working components
- Reuse established patterns (DetailLoader, HubRepository, FilterOptions)
- iOS 15 devices with 2GB RAM are the minimum target
