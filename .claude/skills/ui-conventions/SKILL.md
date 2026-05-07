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
- **Root path helpers:** Use `NavigationCoordinator.pathSnapshot(for:)`, `setPath(_:for:)`, and the EnsembleUI `pathBinding(for:)` extension instead of adding new per-tab switch statements in root views. Use `NavigationDestinationFactory` for tab/destination view routing, and use `NavigationCoordinator.targetTab(for:)` plus `SidebarSelection.selection(for:fallback:)` for destination-to-root selection mapping.

### iOS 15 Compatibility
- **iOS 16+:** `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** `NestedNavigationLink` recursive pattern in `MainTabView.swift`
- **Feature detection:** Always wrap iOS 16+ features in `@available(iOS 16.0, *)` checks
- **Bottom spacing for mini player/tab bar:** Use `.miniPlayerBottomSpacing(...)` from `View+Extensions.swift` instead of ad-hoc per-screen spacer blocks
- **Shared list spacing:** Use `TrackListLayoutMetrics` for standard row height, leading insets, divider alignment/color, native separator color, and default mini-player clearance instead of repeating `68/54/16/140/70/52` or raw separator alpha across screens. SwiftUI `List` track rows should hide system row separators and draw `TrackListDivider` so Artist pages, Media Detail pages, and native table rows do not drift.
- **Utility sheet spacing:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for compact sheet rows, drag-order surfaces, and lightweight action pickers instead of introducing standalone `12/16` spacing constants
- **Now Playing utility spacing:** Inside Now Playing cards, keep compact metadata rows, empty states, page indicators, and queue/status affordances on `TrackListLayoutMetrics` spacing tokens unless the layout truly needs its own card-scale rhythm
- **Now Playing carousel readiness:** Carousel cards should separate visual readiness from live update activity: render the selected card plus adjacent cards during `.page` swipes so panels are complete before selection commits, while keeping high-frequency playback/lyrics work scoped to the active card or explicitly always-visible viewport cards.
- **Detail gutter:** Treat the 40pt horizontal gutter used by Now Playing and queue surfaces as the app's premium detail inset. Reuse `TrackListLayoutMetrics.detailHorizontalPadding` and `utilityListRowInsets()` for downloads/settings/manual utility rows instead of hardcoding fresh edge values.
- **MediaTrackList padding:** Do not wrap `MediaTrackList` in an extra outer horizontal padding layer for normal full-width track lists; the rows already own their horizontal inset through `TrackListLayoutMetrics`
- **Detail action strips:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for repeated Play/Shuffle-style button rows and lightweight status banners in media/detail screens
- **Shared row actions:** Use `TrackRowInteractionModel` to resolve per-track context-menu availability, recent-playlist gating, and favorite state for both `TrackRow` and native table paths. UIKit table menus should be built through `NativeMediaTableActionBuilder`; keep swipe gestures owned by `TrackSwipeContainer`/`MediaTrackList` so card and shelf interfaces do not inherit row gestures.

### Keyboard-Heavy Editors (iPhone)
- Default to a normal `.sheet` for short rename/create/filter flows on iPhone, including profile-name, playlist creation, album/favorites/artists/songs filters, and the validated playlist rename flows.
- Do **not** pre-emptively hide root tab, mini-player, or navigation/search chrome for those ordinary sheets. Broad chrome suppression was the workaround that masked the iOS 26 keyboard regression and also swallowed valid presentations.
- Reserve `keyboardSafeEditorPresentation(...)` for the few remaining root-owned presenters that are still intentionally isolated, such as the pinned/sidebar playlist rename presenters in `MainTabView` and any shared/root presenter that has not yet been revalidated with a normal sheet.
- On iPhone, that helper still uses `fullScreenCover` so the presenting root container stays out of the keyboard layout pass when isolation is actually required.
- Root tab shells should own keyboard/search avoidance decisions. Child detail views should not inherit an active search or keyboard presenter from an offscreen tab.
- Context-menu metadata editors are a separate case: use `phoneSafeAuxiliaryPresentation(...)` with a short dismissal delay so the menu teardown finishes before presentation begins.
- Profile should present as a normal sheet again on iPhone.
- Profile and Downloads should use the same single-column rhythm on macOS auxiliary windows as they do on iOS sheets. Host them through `MacAuxiliaryWindowScaffold` at about 420pt max width, and compose macOS content with `EnsembleUtilityScreenScaffold`/`EnsembleUtilityCardSection` instead of raw `List` rows when the screen is menu-like.
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
- Large mini-player layouts with waveform should expose Previous, Play/Pause, Next, and a row-style ellipsis menu. Compact mini-player layouts keep the simpler Play/Pause + Next controls. On iPadOS, use a plain popover anchored to the ellipsis so the mini-player remains visible behind the menu. On macOS, host the menu with an AppKit `NSButton`/`NSMenu` so the control does not show a pull-down chevron.

### Large-Screen Browse Surfaces
- Artists, Playlists, and Genres keep the app's root `NavigationSplitView` as a stable two-column sidebar/detail shell on iPadOS/macOS. Their browse list + selected detail split lives inside the detail host so switching sections does not recreate the app sidebar or reset its scroll state.
- Compact iPhone and unsupported OS fallbacks keep the existing push/list root behavior by rendering each browse screen in compact mode.
- Store selected artist/playlist/genre state in `SidebarView`, outside the section-owned split subtree, so selection survives detail host rebuilds, compact collapse/expand, and detail pushes.
- Persistent root/sidebar shells should not observe the full `SettingsManager` for one-off values. Cache specific settings such as `accentColor` in `@State`, listen to `settingsManager.objectWillChange`, and assign only when the projected value actually changes.
- Sidebar caches that depend on multiple `PlaylistViewModel` publishers should merge those publishers into one invalidation stream and keep one rebuild handler, so the cache-preservation policy stays centralized.
- Keep selection rows visually dense and use `LargeScreenPlaceholderView` for empty right-pane states such as "Select an Artist".
- Do not clip the selected detail pane inside large-screen browse splits. Artwork-backed detail screens rely on top safe-area bleed plus transparent toolbar chrome so the media wash continues behind search and toolbar controls on iPadOS/macOS.
- On macOS, SwiftUI toolbar actions that need to sit to the right of a search field should use `EnsembleToolbarLeadingSpacer` before the action group. Do this as a toolbar-level alignment spacer, not as column-width math or screen-level toolbar delegate proxying.
- Browse screens should use `EnsembleBrowseToolbar` for sort/filter/overflow action groups so iOS trailing placement and macOS search-spacer placement stay consistent. Use `EnsembleBrowseFilterButton` for active-filter badges instead of rebuilding the badge per screen.
- Notes/Mail-style toolbar sections require a real window-toolbar owner with `NSTrackingSeparatorToolbarItem`. Do not proxy SwiftUI's private toolbar delegate from a screen-level view; that can collapse or drop existing SwiftUI toolbar items. If toolbar tracking is needed, introduce a dedicated macOS toolbar coordinator at the window/root split level.
- Artist detail keeps the full-width square hero on compact/collapsed layouts across platforms, then switches at wide widths to a media-detail-style header with circular artist artwork on the left and metadata/actions on the right.
- Compact Artist detail keeps navigation toolbar material and the iOS 26 top scroll-edge effect hidden while the hero artwork intersects the toolbar, then reveals toolbar chrome only after the hero scrolls past the toolbar bottom.
- Songs uses `SongsTrackListHost` on large screens, with adaptive artist/album metadata columns when width allows. iPad hosts rows in `MediaTrackList`/`UITableView`; macOS hosts rows in the AppKit `NSTableView` backend. Keep row actions resolved through `TrackRowInteractionModel` so UIKit/AppKit behavior stays aligned. Do not use `TrackSwipeContainer` or reintroduce a column-customization table for Songs unless explicitly requested.
- Native track-list surfaces should pass display and state through `NativeTrackListConfiguration` / `NativeTrackListSection` when they need the shared host. Keep direct `MediaTrackList` use for compact iPhone or self-scrolling table-header cases where the UIKit table owns the header/footer.
- Persistent native track-list callers that need download and availability row refreshes should keep those values as state projections and attach `trackListRuntimeObservation(activeDownloadRatingKeys:availabilityGeneration:)`. Do not duplicate the `OfflineDownloadService.$activeDownloadRatingKeys` + `TrackAvailabilityResolver.$availabilityGeneration` `onReceive` pair in each large view.
- Persistent native track-list callers that need Now Playing row highlighting and recent-playlist menu labels should attach `nowPlayingTrackListObservation(...)` and keep only projected `@State` values such as current track id or recent playlist title/id. Do not observe the full `NowPlayingViewModel` from these large surfaces.
- Persistent list/detail surfaces that only need container width for supplemental track-list metadata should use `.measuredWidth(onChange:)` and keep a guarded state assignment in the caller, rather than duplicating background `GeometryReader` blocks.
- Persistent root/search views should capture shared managers once in `init`, initialize local `@State` projections from those managers, and subscribe to focused publishers instead of repeatedly reaching into `DependencyContainer.shared` from body modifiers.
- Persistent list views that react to a family of related `NotificationCenter` events should fan them into a typed event publisher and route through one handler, so payload parsing, toast cleanup, and cached-list refresh policy do not drift across receivers.
- Toolbar buttons nested inside persistent lists should project only the singleton state they need, such as `SyncCoordinator.isOffline`, with guarded `@State` updates instead of observing the whole singleton object.
- Native track-list metadata columns must be fixed-width and right-pinned with equality constraints; only the title region should flex/truncate. Keep duration and status/download lanes fixed-width too. Do not chain artist/album/duration with `lessThanOrEqual` constraints, or mixed title/artist/album lengths, duration strings, or download state will shift columns per row.
- Search song results and virtual collection/detail track lists such as Favorites, Mood, and Artist Favorited Tracks should use the same native track-list backends (`MediaTrackList` on iOS/iPadOS and `SongsTrackListHost`/AppKit table host on macOS) instead of `TrackListView` or hand-built compact track rows, so wide metadata columns, context menus, and native row actions stay aligned.
- Do not replace compact `TrackRow` lists with table rows on iPhone. Compact Songs must keep genre chips, row swipe actions, and existing mini-player spacing.
- Refreshable root screens should also attach `.refreshCommand { ... }` so macOS View > Refresh invokes the focused screen's same async refresh action.

### Aurora Surfaces
- `AuroraVisualizationView` should use the shared `MetalAuroraSurface` renderer when Metal is available, with the Canvas path kept as the compatibility fallback.
- Keep root/sidebar backdrops in the low-cost surface tier and Now Playing/viewport surfaces in the richer tier. Do not throttle playback frequency publishers to reduce visual cost; change renderer tier, pass count, or frame interval at the visual surface instead.
- Preserve the full-width backdrop/fade composition while constraining active aurora bands through `activeContentMaxWidth` when the caller provides it.
- The Metal renderer should output only premultiplied colored aurora content over a transparent MTKView backing layer. Keep the foreground/bottom fade as a SwiftUI overlay above Metal so the fade stays in front without making the Metal drawable an opaque background band.
- Preserve the "horizon" read by drawing a stronger accent wash under the foreground fade, not by baking opaque color into the Metal layer. The fade should unify the aurora and horizon band as one composition.
- Keep the Metal aurora's outer layer broad and low-opacity so the top dissolves like the older Canvas blur passes instead of reading as a hard oval blob.

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
- App-level Settings commands route through `NavigationCoordinator.openProfileFromActiveScene(fallback:)`; `RootView` registers its window-scoped coordinator as the active auxiliary command coordinator on appear/scene activation so `⌘,` opens Profile in the active scene instead of the legacy shared coordinator.
- The button displays the user's profile image if set, otherwise falls back to a person icon

### System Integration
- Leverage native SwiftUI components and iOS system features (e.g., `AVRoutePickerView` for AirPlay, `MPRemoteCommandCenter` for lock screen)
- Views and commands should adapt to platform idioms (tab bar on iPhone, sidebar on iPad/macOS, native command menus/shortcuts) through shared policy helpers such as `EnsemblePlatformFeaturePolicy` when the same feature can render natively in multiple ways.
- Respect safe areas unless deliberately edge-to-edge (like CoverFlow)

### Toast Presentation
- iOS/iPadOS toasts are mounted once at app root via `installGlobalToastWindow(toastCenter:)` in `EnsembleApp`
- Do not mount `ToastHostView` in individual screens; call `deps.toastCenter.show(...)` and let the global host render it
- Global toast window must stay above mini player and modal sheets for consistent feedback visibility

### Gesture Actions (iOS/iPadOS)
- Track rows use a shared swipe layout from `SettingsManager.trackSwipeLayout` (2 leading slots, 2 trailing slots)
- UIKit/AppKit native track-list delegates should receive `SettingsManager` through their coordinator dependencies instead of reaching back into `DependencyContainer.shared` from delegate callbacks.
- Slot 1 on each edge is full-swipe enabled; slot 2 is reveal-only
- Supported swipe action catalog in v1: `Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle
- Keep primary tap behavior unchanged (tap still plays/navigates as before)
- Use `TrackSwipeContainer` for SwiftUI rows and `MediaTrackList` swipe delegates for UIKit-backed track lists
- macOS keeps existing interaction model (no custom swipe gesture layer in v1)

### Long-Press Menus
- Shared media context-menu policy lives in `MediaMenuCatalog`. New track, album, artist, playlist, or merged-playlist menus should use the catalog for action order, section grouping, and destructive/editing gating; parent views should add only local handlers such as queue removal, MiniPlayer shuffle/repeat, or pinned unpin behavior.
- Use `TrackActionsContextMenu` for standalone SwiftUI track cards/menus outside `TrackRow` or native table rows, including feed cards, mini-player long-press menus, and queue/history fallback rows. It renders the shared catalog and lets the parent inject only navigation, playlist-picker presentation, or removal handlers.
- Add-to-playlist follow-up UI should be presented through `PlaylistActionPresentationHost` and `.playlistActionPresentation(request:nowPlayingVM:)`; menus and row actions should request the shared host instead of owning a local sheet payload.
- Prefer `contextMenu` on album/artist/playlist cards/rows to mirror detail-view actions
- Album menu: `Play`, `Shuffle`, `Play Next`, `Play Last`, `Radio`, `Add to Playlist…`, `Pin/Unpin`
- Artist menu: `Play`, `Shuffle`, `Radio`, `Pin/Unpin`
- Playlist menu (Playlists screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin`, plus (for non-smart playlists) `Rename…`, `Edit Playlist`, `Delete`
- Playlist menu (Search screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin` (non-destructive only)

### Genre Filters
- Use `GenreFilterHeader` for browse and detail genre filter rows. Do not place `GenreChipBar` directly in screens; the header owns the shared spacing and optional supplementary content such as merged-playlist source chips.

## Visual Design

### Design Tokens And Adaptive Patterns
- Use `EnsembleDesign` for semantic UI values instead of introducing new raw literals for repeatable roles.
- Token groups cover spacing, radius, typography, color, icons, breakpoints, effects, and semantic material roles.
- Keep specialized existing helpers where they encode behavior, such as `TrackListLayoutMetrics` for track rows and `ArtworkCornerRadius` for media artwork. These bridge into `EnsembleDesign` instead of being replaced by unrelated literals.
- Use `EnsembleScaffold` for larger adaptive patterns, such as OS-aware filter presentation and shared empty/loading/error states.
- Filter presenters should use `.ensembleFilterPresentation(...)` instead of raw `.sheet` when presenting `FilterSheet`, so compact iPhone stays sheet-based while regular-width modern iPadOS and macOS can use toolbar popovers.
- Large-screen browse splits should use `LargeScreenBrowseSplitView` with `EnsembleScaffold.BrowseSplit.Configuration` presets instead of repeating raw pane width, breakpoint, and resize-handle values per screen.
- Media-style detail screens should keep header/list/action/shadow metrics under `EnsembleScaffold.DetailSurface` and render through `MediaDetailSurface` helpers rather than inventing parallel detail surface constants.
- Artist detail's custom square/circular adaptive header should keep its specialized thresholds, hero dimensions, section rhythm, and overlay strengths under `EnsembleScaffold.ArtistDetail`.
- macOS Profile/Downloads-style utility windows should use `MacAuxiliaryWindowScaffold` plus `EnsembleScaffold.AuxiliaryWindow.Configuration` presets so scene sizing and in-window content width stay in sync. For menu-like rows, use `EnsembleAdaptiveUtilityScaffold` when a screen needs iOS grouped-list and macOS card-section variants; use `EnsembleUtilityScreenScaffold`, `EnsembleUtilityCardSection`, `EnsembleUtilityCardRow`, and `EnsembleUtilityCardDivider` for the macOS card body so macOS avoids bordered `List` chrome. Current migrated examples include Filters, Logs, account detail, playlist create/edit, and text-input sheets.
- Loading, empty, and error states should use `EnsembleStateScaffold`. Use the default full-screen presentation for standalone states and `.compactFooter` for track-list/table-footer states.
- Library browse empty states that branch on cloud restore, missing sources, syncing, disabled libraries, or true empty content should use `EnsembleLibraryEmptyStateScaffold` instead of rebuilding that decision tree per screen.
- Library browse screens that have already displayed cached content should not publish a transient empty list or swap to a full blank/loading state during refresh. Keep last-good rows visible, mark stale/loading locally when needed, and use stable placeholder rows only for the very first load before any cached content exists. Playlists is the reference implementation.
- Filled actions inside empty/loading/error states should use `EnsembleStateActionLabel`; account setup/authentication surfaces should use `EnsembleScaffold.AccountSetup` for PIN, card, row, and sheet sizing.
- Profile, downloads, account detail, and lightweight settings rows should use `EnsembleUtilitySectionHeader`, `EnsembleUtilityIcon`, `EnsembleUtilityInlineStatusRow`, `EnsembleUtilityTextStack`, `EnsembleUtilityRowLabel`, and `EnsembleScaffold.UtilityRow` for section headers, icon lanes, thumbnail dimensions, nested status indentation, and compact text/status spacing.
- Shared browse toolbar groups live in `EnsembleBrowseToolbar`; keep screen-owned actions as small button/menu helpers and let the scaffold own platform placement and spacing.
- Standalone macOS detail toolbar actions that need trailing alignment should use `EnsembleDetailToolbarLeadingSpacer`; ordinary root/action toolbars should use `EnsembleToolbarLeadingSpacer`; large-screen browse detail panes are marked by `LargeScreenBrowseSplitView` so detail spacers are suppressed in dual-pane mode.
- Indexed browse section headers should use `EnsembleBrowseSectionHeader`, and large-screen browse selection rows should use `EnsembleScaffold.BrowseSelection` / `browseSelectionBackground(isSelected:)`.
- Content shelves and tappable section headers should use `EnsembleContentSectionHeader` so title weight, color, and disclosure icons stay aligned across Feed, Search, and library sections.
- Shared media menu and swipe labels should use `MediaActionLabel` so icons, ellipses, and verb choices stay consistent across rows, cards, shelves, and detail surfaces.
- SF Symbols should be referenced through `EnsembleDesign.Icon` for app/navigation/action intent. Keep account/profile person symbols separate from artist/music symbols; artist-facing UI uses `EnsembleDesign.Icon.artist`/`artists`.
- Reusable utility metrics should live under the matching `EnsembleScaffold` family (`Sidebar`, `ScrollIndex`, `BrowseSplit`, `TrackSwipe`, `Waveform`, `Marquee`, `LogViewer`, `Toast`, etc.) instead of local raw sizes.
- StageFlow geometry, animation, mask, and transform constants are intentionally local unless a future pass explicitly retunes StageFlow as a whole; do not silently normalize those values during broad token sweeps.
- The 2026 design-token sweep re-checked StageFlow and Now Playing literals: Now Playing's remaining strict spacing hits are structural zero-spacings, while StageFlow's remaining nonzero values are panel, footer, reflection, and dismissal-control tuning. Treat a future StageFlow namespace as a dedicated visual retune, not as part of routine utility/card token cleanup.
- Shared card/chip geometry should use `EnsembleScaffold.MediaCard` and `EnsembleScaffold.Chip`; hub cards, playlist chips, merged-source chips, and download status chips should avoid local padding/font/radius literals unless the component has a documented one-off layout reason.
- Liquid Glass and fallback material stacks should go through `EnsembleDesign.Material.Role` or a documented local composition when the surface is too specialized, such as artwork-reactive mini-player backgrounds.
- UIKit/AppKit chrome fallbacks, auxiliary window backgrounds, and specialized compositions should still pull blur style, fallback material, background color, stroke, and shadow values from `EnsembleDesign.Material.Role` so the semantic material policy stays centralized.
- Mini-player and mini-player-adjacent popovers should use the `EnsembleScaffold.MiniPlayer` material role and corner-radius tokens. Keep separate semantic roles for mini-player and popover, but keep their fallback glass values aligned unless a deliberate material retune is requested.
- iOS 15 navigation/tab/toolbar chrome fallback opacity should come from the matching material role, such as `EnsembleDesign.Material.Role.sidebar.chromeBackgroundAlpha(auroraEnabled:)`, instead of local alpha literals.
- During broad literal sweeps, ask before normalizing ambiguous values that could change visual rhythm, iPad/macOS breakpoints, prominent material opacity, or established icon intent.
- Use `scripts/design_token_audit.sh` as a non-blocking inventory before and after broad sweeps; it reports literal counts and the largest screen/component hotspots.

### Artwork Display
- **Hub items:** 140x140pt artwork
- **Corner radius:** Albums/playlists use 8pt; artists use 70pt (circular)
- **Shadows:** use `EnsembleDesign.Effect` / component bridge tokens for shared card/detail depth; StageFlow keeps its own tuned 3D shadows.
- **Blurred backgrounds:** NowPlayingView and detail views use `BlurredArtworkBackground`
- **Shared detail artwork wash:** `MediaDetailView` and `DownloadTargetDetailView` must use `ArtworkDetailBackground` for the blurred header image so dark/light overlay behavior stays identical across detail screens. The wash should cross-fade artwork changes using `EnsembleScaffold.DetailSurface.backgroundFadeDuration` instead of swapping the blurred layer abruptly during navigation or cached artwork loads.
- **Shared detail shell:** Media-style detail screens should build their hero artwork, metadata block, action row, and list-card styling on `MediaDetailSurface` so `MediaDetailView` and `DownloadTargetDetailView` do not drift on spacing, wide-layout behavior, or light/dark presentation
- **Detail loading stability:** Album, playlist, artist, and virtual collection detail loads should avoid full-screen centered loaders that later swap to top-aligned headers. Use `MediaDetailSurface.LoadingState` or keep the shared header/table shell mounted with a compact footer loader during initial data fetches. On macOS, keep the detail root top-aligned, keep the native table's top content inset fixed at zero, and let the AppKit backend use a deterministic wide-header row height; do not force the native table host itself to infinite height as a reflow workaround.
- **Shared virtual detail headers:** Favorites, mood, smart playlist, and other virtual collections that do not have album artwork should use `MediaDetailSurface.Header` with `MediaDetailSurface.SymbolArtwork` so compact and large-screen headers inherit the same fluid resizing behavior as media detail screens.
- **Shared detail actions:** Detail Play/Shuffle-style button labels should use `MediaDetailSurface.ActionLabel`, repeated compact Play/Shuffle action strips should use `MediaDetailSurface.ActionRow`/`PlaybackActionRow`, wide metadata-column headers should use `AdaptivePlaybackActionRow`, nested compact sections should use `CompactPlaybackActionRow`, and icon-only actions such as Radio should use `IconActionLabel` so filled/accent, secondary action, spacing, disabled state, and chromeless button treatment stay aligned across media detail variants.

### Typography & Spacing
- **System fonts:** SF Pro through `EnsembleDesign.Typography` for repeatable roles; only keep local font styles when the component has a documented rendering reason.
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

Three loaders in `EnsembleUI/Sources/Screens/Details/`:
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
