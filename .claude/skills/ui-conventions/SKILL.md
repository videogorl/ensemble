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
- **Window-scoped navigation:** `RootView` creates the `NavigationCoordinator` for that scene/window and injects it with `.environmentObject(...)`. Do not read `DependencyContainer.shared.navigationCoordinator` from screen or component code for user-driven navigation, or multiple iPad/macOS windows will mirror each other's pushes.
- **Top-level iPhone titles:** Root tab destinations should use the system large-title behavior by default. Don't force `.inline` on top-level browse/search screens; let the title appear large at rest and collapse naturally as content scrolls.
- **Search chrome ownership:** In tab-based navigation, attach `.searchable` only while that tab is the active root screen. Collapse/remove search chrome before pushing detail or switching away so stale `UISearchController` state doesn't leak padding, keyboard state, or toolbar behavior into pushed views or other tabs.

### Deep Linking
- **NavigationCoordinator.Destination:** Use typed destinations (artist, album, playlist, view) for all deep links
- **Pending navigation:** From sheets (like Now Playing), set `pendingNavigation` to defer until sheet dismisses
- **Tab fallback:** If navigating from Search tab (or hidden tab), fall back via `visibleTabs.first ?? .home`

### iOS 15 Compatibility
- **iOS 16+:** `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** `NestedNavigationLink` recursive pattern in `MainTabView.swift`
- **Feature detection:** Always wrap iOS 16+ features in `@available(iOS 16.0, *)` checks
- **Bottom spacing for mini player/tab bar:** Use `.miniPlayerBottomSpacing(...)` from `View+Extensions.swift` instead of ad-hoc per-screen spacer blocks
- **Shared list spacing:** Use `TrackListLayoutMetrics` for standard row height, leading insets, divider alignment, and default mini-player clearance instead of repeating `68/54/16/140/70/52` across screens
- **Utility sheet spacing:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for compact sheet rows, drag-order surfaces, and lightweight action pickers instead of introducing standalone `12/16` spacing constants
- **Now Playing utility spacing:** Inside Now Playing cards, keep compact metadata rows, empty states, page indicators, and queue/status affordances on `TrackListLayoutMetrics` spacing tokens unless the layout truly needs its own card-scale rhythm
- **Detail gutter:** Treat the 40pt horizontal gutter used by Now Playing and queue surfaces as the app's premium detail inset. Reuse `TrackListLayoutMetrics.detailHorizontalPadding` and `utilityListRowInsets()` for downloads/settings/manual utility rows instead of hardcoding fresh edge values.
- **MediaTrackList padding:** Do not wrap `MediaTrackList` in an extra outer horizontal padding layer for normal full-width track lists; the rows already own their horizontal inset through `TrackListLayoutMetrics`
- **Detail action strips:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for repeated Play/Shuffle-style button rows and lightweight status banners in media/detail screens
- **Shared row actions:** Use `TrackRowInteractionModel` to resolve per-track context-menu availability, recent-playlist gating, and favorite state for both `TrackRow` and `MediaTrackList` paths instead of duplicating that logic per framework

### Keyboard-Heavy Editors (iPhone)
- Default to a normal `.sheet` for short rename/create/filter flows on iPhone, including profile-name, playlist creation, album/favorites/artists/songs filters, and the validated playlist rename flows.
- Do **not** pre-emptively hide root tab, mini-player, or navigation/search chrome for those ordinary sheets. Broad chrome suppression was the workaround that masked the iOS 26 keyboard regression and also swallowed valid presentations.
- Reserve `keyboardSafeEditorPresentation(...)` for the few remaining root-owned presenters that are still intentionally isolated, such as the pinned/sidebar playlist rename presenters in `MainTabView` and any shared/root presenter that has not yet been revalidated with a normal sheet.
- On iPhone, that helper still uses `fullScreenCover` so the presenting root container stays out of the keyboard layout pass when isolation is actually required.
- Root tab shells should own keyboard/search avoidance decisions. Child detail views should not inherit an active search or keyboard presenter from an offscreen tab.
- Context-menu metadata editors are a separate case: use `phoneSafeAuxiliaryPresentation(...)` with a short dismissal delay so the menu teardown finishes before presentation begins.
- Profile should present as a normal sheet again on iPhone.
- Profile and Downloads should use the same single-column rhythm on macOS auxiliary windows as they do on iOS sheets. Host them through `MacAuxiliaryWindowScaffold` at about 420pt max width instead of adding a separate macOS header/chrome layer.
- Do not pre-hide root tab, mini-player, or searchable-header chrome for the entire auxiliary transition; only suppress root chrome for actual immersive modes or the remaining explicitly-isolated keyboard presenters.
- The helper owns keyboard-editor registration timing; do not duplicate `beginKeyboardEditorPresentation()` or `endKeyboardEditorPresentation()` inside the editor view itself
- Keyboard editors can use a local `NavigationStack`/`NavigationView` plus system toolbar actions for a native look whether they are hosted in a normal sheet or one of the remaining isolated presenters.
- For any modal text-input flow with an explicit Done/Cancel action, dismiss the focused field first and delay the modal dismissal slightly so the keyboard animation completes before the presentation tears down

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
- **Immersive mode:** Tab bar hidden via `ChromeVisibilityPreferenceKey` (CoverFlow, full-screen)
- **iOS 18+:** Uses `.sidebarAdaptable` tab view style when available
- **Mini player offset:** MiniPlayer sits 56pt above tab bar on iPhone

### CoverFlow + Rotation Policy
- CoverFlow is **iPhone-only** (`UIDevice.current.userInterfaceIdiom == .phone`), even though iPad shares `os(iOS)`.
- iPadOS and macOS always use their standard list/grid layouts for Songs, Albums, and Playlists.
- iOS orientation is portrait-locked by default and only unlocks landscape while a CoverFlow-capable root view is active.
- StageFlow rotation support is registered with a per-view token and the app delays the final unregister briefly, so SwiftUI view recreation during rotation does not snap the app back to portrait.

### Large-Screen Browse Surfaces
- Artists, Playlists, and Genres use `LargeScreenBrowseSplitView` only on macOS and regular-width iPad layouts. Compact iPhone keeps the existing push-navigation list.
- The split shell owns the left selection list and right detail pane. Keep selection rows visually dense and use `LargeScreenPlaceholderView` for empty right-pane states such as "Select an Artist".
- Songs uses the shared `TrackRow` list treatment on large screens, with adaptive artist/album metadata columns when width allows. The row host must be a native `List` with `.trackSwipeActions(...)`, not `TrackSwipeContainer`, so iPad/macOS keep system swipe physics and trackpad two-finger gestures. On large-screen iPad Songs, disable leading full-swipe while keeping the reveal/tap actions native; iPadOS can otherwise expose a blank over-drag region beside the sidebar. Do not reintroduce a column-customization table for Songs unless explicitly requested.
- Do not replace compact `TrackRow` lists with table rows on iPhone. Compact Songs must keep genre chips, row swipe actions, and existing mini-player spacing.
- Refreshable root screens should also attach `.refreshCommand { ... }` so macOS View > Refresh invokes the focused screen's same async refresh action.

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

### Profile Toolbar Button
- **iPhone:** `ProfileToolbarButton` (28×28pt circular profile image) is owned by `MainTabView` and shown only on root tab destinations: the visible tab-bar tabs plus the root `More` view. Do not add it per-screen, or it will leak into pushed `More` destinations and can disappear on iOS 15 when trailing toolbar items compete.
- **iPad/macOS:** `ProfileToolbarButton` placed in sidebar toolbar, replacing the previous gear icon
- Tapping opens `ProfileView` via `AuxiliaryPresentation.profile` (formerly `.settings`)
- The button displays the user's profile image if set, otherwise falls back to a person icon

### System Integration
- Leverage native SwiftUI components and iOS system features (e.g., `AVRoutePickerView` for AirPlay, `MPRemoteCommandCenter` for lock screen)
- Views should adapt to platform idioms (tab bar on iPhone, sidebar on iPad/macOS)
- Respect safe areas unless deliberately edge-to-edge (like CoverFlow)

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
- **Shared detail artwork wash:** `MediaDetailView` and `DownloadTargetDetailView` must use `ArtworkDetailBackground` for the blurred header image so dark/light overlay behavior stays identical across detail screens
- **Shared detail shell:** Media-style detail screens should build their hero artwork, metadata block, action row, and list-card styling on `MediaDetailSurface` so `MediaDetailView` and `DownloadTargetDetailView` do not drift on spacing, wide-layout behavior, or light/dark presentation

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

## Feature Philosophy

### Preserve Existing Functionality
- **Don't remove features** when refactoring unless explicitly directed
- **Backward compatibility:** Maintain iOS 15 support; use feature detection for newer OS
- **User preferences:** Respect accent colors, enabled tabs, filter preferences

### Incremental Enhancement
- Extend rather than replace working components
- Reuse established patterns (DetailLoader, HubRepository, FilterOptions)
- iOS 15 devices with 2GB RAM are the minimum target
