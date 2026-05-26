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
- **Tab customization editor:** More tab edit mode should use native `List` editing for visible tab reordering and simple tap actions for add/remove. Do not reintroduce custom row-frame preference keys, section drop delegates, or insertion-index drag math for tab sorting unless native list editing is proven insufficient.
- **Visible tabs sync:** `NavigationCoordinator.visibleTabs` synced from MainTabView for fallback logic
- **Window-scoped navigation:** `RootView` creates the `NavigationCoordinator` for that scene/window and injects it with `.environmentObject(...)`. Do not read `DependencyContainer.shared.navigationCoordinator` from screen or component code for user-driven navigation, or multiple iPad/macOS windows will mirror each other's pushes.
- **Top-level iPhone titles:** Root tab destinations should use the system large-title behavior by default. Don't force `.inline` on top-level browse/search screens; let the title appear large at rest and collapse naturally as content scrolls.
- **Search chrome ownership:** In tab-based navigation, attach `.searchable` only while that tab is the active root screen. Collapse/remove search chrome before pushing detail or switching away so stale `UISearchController` state doesn't leak padding, keyboard state, or toolbar behavior into pushed views or other tabs. Use SwiftUI's `dismissSearch` environment action to collapse search; do not force keyboard dismissal with `UIApplication.sendAction(...)`.

### Deep Linking
- **NavigationCoordinator.Destination:** Use typed destinations (artist, album, playlist, view) for all deep links
- **Pending navigation:** From sheets (like Now Playing), set `pendingNavigation` to defer until sheet dismisses. `RootView` owns the Now Playing presenter dismissal handoff; do not add screen-local `asyncAfter` timers in `MainTabView` or `SidebarView` to wait for the sheet animation.
- **Tab fallback:** If navigating from Search tab (or hidden tab), fall back via `visibleTabs.first ?? .home`
- **Root path helpers:** Use `NavigationCoordinator.pathSnapshot(for:)`, `setPath(_:for:)`, and the EnsembleUI `pathBinding(for:)` extension instead of adding new per-tab switch statements in root views. Use `NavigationDestinationFactory` for tab/destination view routing, and use `NavigationCoordinator.targetTab(for:)` plus `SidebarSelection.selection(for:fallback:)` for destination-to-root selection mapping.

### iOS 15 Compatibility
- **iOS 16+:** `NavigationStack` with `NavigationLink(value:)` and typed paths
- **iOS 15:** Use `NestedNavigationLink` only as the root `NavigationView` bridge for coordinator-driven entry into a tab or hidden More destination. Once inside a browse/detail stack, use native `NavigationLink(destination:)` for in-stack pushes so SwiftUI owns animations and back behavior.
- **Route-owned links:** For feed cards, hub headers, and other coordinator-owned typed routes that must survive source/list refreshes, use `NavigationCoordinator.routeLink(to:)` instead of local `#available` branches or inline destination closures. Context menu navigation actions should use `routeFromMenu(to:)` or `navigateFromMenu(to:)` so path updates happen after native menu dismissal.
- **Feature detection:** Always wrap iOS 16+ features in `@available(iOS 16.0, *)` checks
- **Bottom spacing for mini player/tab bar:** Use `.miniPlayerBottomSpacing(...)` from `View+Extensions.swift` instead of ad-hoc per-screen spacer blocks
- **Shared list spacing:** Use `TrackListLayoutMetrics` for standard row height, leading insets, divider alignment/color, native separator color, and default mini-player clearance instead of repeating `68/54/16/140/70/52` or raw separator alpha across screens. Native table rows and compact SwiftUI track/search rows should share these metrics so Artist pages, Media Detail pages, and Songs/Search rows do not drift.
- **Utility sheet spacing:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for compact sheet rows, drag-order surfaces, and lightweight action pickers instead of introducing standalone `12/16` spacing constants
- **Now Playing utility spacing:** Inside Now Playing cards, keep compact metadata rows, empty states, page indicators, and queue/status affordances on `TrackListLayoutMetrics` spacing tokens unless the layout truly needs its own card-scale rhythm
- **Now Playing carousel readiness:** Carousel cards should separate visual readiness from live update activity: render the selected card plus adjacent cards during `.page` swipes so panels are complete before selection commits, while keeping high-frequency playback/lyrics work scoped to the active card or explicitly always-visible viewport cards.
- **Now Playing card ownership:** All Now Playing layouts should render Queue, Controls, Lyrics, and Info through `NowPlayingPanelCard` / `NowPlayingDetailPanel` instead of instantiating those cards directly per layout. Single-panel, carousel, wide, and external-display layouts may own different containers, pickers, and sizing, but card selection and per-card flags should stay centralized so visual/control changes land once.
- **Now Playing loading indicators:** Controls should use `.task(id:)` cancellation for state-owned delayed indicators such as short loading spinners. Do not store manual `Task` properties just to cancel/restart view-local loading-state swaps.
- **Lyrics scrolling:** Lyrics should rely on SwiftUI `ScrollView`/`TabView` native gesture arbitration. Native scroll phase observation may drive view-only affordances such as temporarily disabling lyric blur and recentering after user-driven scroll; on older OS versions without native scroll-phase support, keep timed lyrics unblurred instead of adding detector shims. Do not reintroduce UIKit/AppKit drag or scroll-wheel detector probes, paging-pan failure wiring, competing SwiftUI drag recognizers, offset-reader scroll detection, or ViewModel-level timed scroll suppression unless a current simulator repro proves native behavior is broken and the smaller owner-scoped fix is documented.
- **Marquee animation lifecycle:** Long-text marquee loops should run through cancellable `.task(id:)` sequences keyed by measured text/container width. Do not build recursive `DispatchQueue.main.asyncAfter` chains for view-owned animation loops.
- **Detail gutter:** Treat the 40pt horizontal gutter used by Now Playing and queue surfaces as the app's premium detail inset. Reuse `TrackListLayoutMetrics.detailHorizontalPadding` for downloads/settings/manual utility rows instead of hardcoding fresh edge values.
- **MediaTrackList padding:** Do not wrap `MediaTrackList` in an extra outer horizontal padding layer for normal full-width track lists; the rows already own their horizontal inset through `TrackListLayoutMetrics`
- **Detail action strips:** Reuse `TrackListLayoutMetrics.rowInterItemSpacing` and `rowHorizontalPadding` for repeated Play/Shuffle-style button rows and lightweight status banners in media/detail screens
- **Shared row actions:** Use `TrackRowInteractionModel` to resolve per-track context-menu availability, recent-playlist gating, and favorite state for native table paths and compact standalone track rows. UIKit table menus should be built through `NativeMediaTableActionBuilder`; keep row swipes owned by `MediaTrackList`/native table delegates so card and shelf interfaces do not inherit row gestures.

### Keyboard-Heavy Editors (iPhone)
- Default to native presentation for short rename/create/filter flows on iPhone: playlist rename uses a `TextField` alert, while profile-name, playlist creation, and album/favorites/artists/songs filters use normal `.sheet` presentation.
- Do **not** pre-emptively route ordinary sheets through full-screen keyboard presenters or broad app-wide chrome suppression. If runtime logs prove the presenting screen's own navigation/search chrome is causing a UIKit feedback loop, let that parent screen suppress only its own chrome while its local modal is active.
- Do not reintroduce the deleted `keyboardSafeEditorPresentation(...)` full-screen workaround for playlist rename or other short text-input flows.
- Root tab shells should own search avoidance decisions, but should not subscribe to global keyboard notifications just to hide chrome. Let native sheets, focus state, and keyboard safe areas own keyboard-driven layout. Child detail views should not inherit an active search presenter from an offscreen tab.
- Context-menu metadata editors present as normal local `.sheet` flows and reuse `TextInputView` for the keyboard-heavy text field. Album, artist, and detail context menus should keep metadata sheet state beside their add-to-playlist/delete presenters. Do not route these editors through root presenters or hide/restore parent navigation/search chrome around them; interactive sheet dismissal with a focused keyboard can otherwise race UIKit chrome updates and recreate the iOS 26 feedback loop.
- Profile and Downloads should present as normal sheets on iPhone.
- Root auxiliary sheets should be attached through `auxiliaryPresentationSheets(...)` and `addAccountPresentationSheet()` from the active root shell (`MainTabView` or `SidebarView`). Do not duplicate profile/download/add-account `.sheet` wiring per root shell or add `onDismiss` handlers that race the binding setter's native dismissal path.
- Profile and Downloads should use the same single-column rhythm on macOS auxiliary windows as they do on iOS sheets. Host them through `MacAuxiliaryWindowScaffold` at about 420pt max width, and compose macOS content with `EnsembleUtilityScreenScaffold`/`EnsembleUtilityCardSection` instead of raw `List` rows when the screen is menu-like.
- Do not pre-hide root tab, mini-player, navigation, or searchable-header chrome for ordinary local sheets. Suppress parent chrome only for actual immersive modes or a current simulator-proved local-presenter conflict.
- Short iPhone text editors should use `TextInputView`, and short utility sheets should use `.nativeSheetNavigationContainer()` for the iOS 16+/macOS 13+ `NavigationStack` path plus the iOS 15/macOS 12 `NavigationView` fallback. Do not reintroduce custom sheet headers or full-screen keyboard presenters unless a current simulator/hardware repro proves native sheet dismissal is broken.
- For modal text-input flows with explicit Done/Cancel actions, prefer direct native dismissal. Do not add keyboard delays or focus choreography unless a current simulator/hardware repro proves native dismissal is broken.
- When one sheet needs to hand off to another sheet, store the pending target and present it from the first sheet's `onDismiss`; do not use arbitrary `DispatchQueue.main.asyncAfter` delays to wait for sheet teardown.
- Do not install app-wide `UIApplication.sendEvent` swizzles or `GCKeyboard` monitors for hardware shortcuts. Use native SwiftUI commands/keyboard shortcuts where the platform supports them, and leave iOS text input events on the responder chain.

**NestedNavigationLink Pattern** (in `MainTabView.swift`):
```swift
struct NestedNavigationLink: View {
    let path: [NavigationCoordinator.Destination]
    let destinationBuilder: (NavigationCoordinator.Destination) -> AnyView

    var body: some View {
        if let first = path.first {
            NavigationLink(destination: destinationBuilder(first)) {
                EmptyView()
            }
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
- **StageFlow chrome suppression:** `MainTabView` hides root chrome directly from active phone StageFlow landscape geometry. Do not reintroduce preference/notification bridges or delayed immersive-mode clear timers for this path.
- **iOS 18+:** Uses `.sidebarAdaptable` tab view style when available
- **Mini player offset:** Root chrome registration owns MiniPlayer placement. Use `TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom:)` for tab-root chrome and `TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom:)` for registered split/detail panes. Modern iOS keeps the standard floating lift while iOS 15 derives the root lift from the live tab/safe-area edge. Do not add per-screen mini-player offsets.

### CoverFlow + Rotation Policy
- CoverFlow is **iPhone-only** (`UIDevice.current.userInterfaceIdiom == .phone`), even though iPad shares `os(iOS)`.
- iPadOS and macOS always use their standard list/grid layouts for Songs, Albums, and Playlists. iPhone Songs, Albums, and Playlists can render StageFlow in landscape when their tab is active.
- iOS orientation is portrait-locked by default and only unlocks landscape while `MainTabView` is on a StageFlow-capable tab. StageFlow-capable tabs pushed from More, such as Albums when hidden from the tab bar, must be detected from the More navigation path and handled by the same root policy.
- `MainTabView` owns StageFlow activation, root tab-bar/mini-player suppression, and the single rotation-support token. Browse screens consume `EnvironmentValues.isStageFlowActive`; they may hide local navigation/search chrome for StageFlow, but must not add per-screen tab-bar hiding, `GeometryReader` rotation detection, `UIScreen` height clamps, or `stageFlowRotationSupport(...)` calls.
- Leaving a StageFlow-capable tab should unregister landscape support immediately. Do not add delayed orientation unregisters; unsupported tabs can otherwise remain briefly in landscape and lay out root chrome/mini-player in the wrong coordinate space.
- Large mini-player layouts with waveform should expose Previous, Play/Pause, Next, and a row-style ellipsis menu. Compact mini-player layouts keep the simpler Play/Pause + Next controls. On iPadOS, use a plain popover anchored to the ellipsis so the mini-player remains visible behind the menu. On macOS, host the menu with an AppKit `NSButton`/`NSMenu` so the control does not show a pull-down chevron.
- Mini-player swipe gestures should resolve immediately at gesture end, matching the native transport buttons. Do not add arbitrary timers to wait for swipe-out animations before previous/next playback changes.
- External-display, iPad sheet, and macOS viewport Now Playing should reuse `NowPlayingWidePanelLayout`, `NowPlayingDetailPanel`, and `NowPlayingBackdrop`; keep platform-specific code limited to presentation chrome such as dismissal, dark presentation, and the visualization consumer. Wide dual-pane Now Playing surfaces show one controls card on the left, so the right detail panel must not repeat lyrics transport controls or the track-title header.
- `NowPlayingWidePanelLayout` should center its constrained content for wide Now Playing surfaces such as the iPad sheet, macOS viewport, and AirPlay external display. Compact carousel callers keep their existing paging layout.
- macOS viewport Now Playing should keep content in the root's native safe area while `NowPlayingBackdrop` handles edge-to-edge artwork/aurora bleed. Do not put `.windowResizability(.contentMinSize)` on the main scene; SwiftUI can refit the root window to transient NPV content. `RootView` owns the main window's minimum frame and temporary window-toolbar suppression while viewport Now Playing is active. Prefer SwiftUI toolbar visibility APIs for macOS 13+; do not toggle `NSToolbar.isVisible`, force `contentMinSize`, or call `NSWindow.setFrame` from the viewport path. Do not add leaf-level titlebar or traffic-light padding constants, screen-level toolbar-item hiding, or fake full-window sheet shims.
- On iOS/iPadOS, `RootView` owns software-keyboard visibility for root chrome. The mini player and its reserved clearance should be hidden while the software keyboard is visible, then fade back in after keyboard dismissal; leaf text-entry screens should not move or offset the mini player locally.

### Large-Screen Browse Surfaces
- Artists, Playlists, and Genres keep the app's root `NavigationSplitView` as a stable two-column sidebar/detail shell on iPadOS/macOS. Their browse list + selected detail split lives inside the detail host so switching sections does not recreate the app sidebar or reset its scroll state.
- Compact iPhone and unsupported OS fallbacks keep the existing push/list root behavior by rendering each browse screen in compact mode.
- Store selected artist/playlist/genre state in `SidebarView`, outside the section-owned split subtree, so selection survives detail host rebuilds, compact collapse/expand, and detail pushes.
- Keep the macOS root sidebar native and collapsible. Do not remove the system sidebar toggle command, install `NSEvent` monitors to swallow sidebar shortcuts, or walk `NSSplitView`/`NSSplitViewController` internals to force non-collapsible sidebar state.
- Persistent root/sidebar shells should not observe the full `SettingsManager` for one-off values. Cache specific settings such as `accentColor` in `@State`, listen to `settingsManager.objectWillChange`, and assign only when the projected value actually changes. Do not add a `DispatchQueue.main.async` hop around those snapshot updates; settings mutations are readable synchronously from the notification.
- Sidebar caches that depend on multiple `PlaylistViewModel` publishers should merge those publishers into one invalidation stream and keep one rebuild handler, so the cache-preservation policy stays centralized.
- Keep selection rows visually dense and use `LargeScreenPlaceholderView` for empty right-pane states such as "Select an Artist".
- Do not clip the selected detail pane inside large-screen browse splits. Artwork-backed detail screens rely on top safe-area bleed plus transparent toolbar chrome so the media wash continues behind search and toolbar controls on iPadOS/macOS.
- On macOS, SwiftUI toolbar actions that need to sit to the right of a search field should use `EnsembleToolbarLeadingSpacer` before the action group. Do this as a toolbar-level alignment spacer, not as column-width math or screen-level toolbar delegate proxying.
- Browse screens should use `EnsembleBrowseToolbar` for sort/filter/overflow action groups so iOS trailing placement and macOS search-spacer placement stay consistent. Use `EnsembleBrowseFilterButton` for active-filter badges instead of rebuilding the badge per screen.
- Notes/Mail-style toolbar sections require a real window-toolbar owner with `NSTrackingSeparatorToolbarItem`. Do not proxy SwiftUI's private toolbar delegate from a screen-level view; that can collapse or drop existing SwiftUI toolbar items. If toolbar tracking is needed, introduce a dedicated macOS toolbar coordinator at the window/root split level.
- Large Now Playing viewport surfaces should leave toolbar item visibility and `NSWindow` resize constraints to the root scene/window shell. Do not add screen-level `NSViewRepresentable` bridges that hide every toolbar item or force `contentMinSize` while a leaf presentation is active.
- Artist detail keeps the full-width square hero on compact/collapsed layouts across platforms, then switches at wide widths to a media-detail-style header with circular artist artwork on the left and metadata/actions on the right. Its blurred artwork wash and toolbar bleed should render through `MediaDetailSurface` / `artworkBackedToolbarBleed()` so Artist and album/playlist details share the same backdrop/chrome owner even when their header layouts differ.
- On iOS 16+, navigation/tab/toolbar background changes should use SwiftUI `.toolbarBackground(...)` or native container behavior; `NavigationBarAppearanceConfigurator` and root-level UIKit appearance proxy mutation are iOS 15-only fallbacks and must remain no-ops on modern iOS so UIKit appearance mutation does not fight native chrome behavior.
- Root chrome bridge probes should apply from `updateUIView` / `didMoveToWindow` lifecycle ownership and keep retry state only after a native controller is found. Do not add next-runloop `DispatchQueue.main.async` probes to wait for tab-bar, mini-player inset, or iOS 15 navigation-bar hierarchy setup.
- macOS window chrome bridges should apply from `NSViewRepresentable` update/lifecycle/layout callbacks. Do not add `DispatchQueue.main.asyncAfter` retries to wait for toolbar or window attachment; keep the coordinator idempotent and let native view lifecycle retry.
- Detail header pin state should observe `PinManager.$pinnedItems` and derive state from the emitted snapshot. Do not add `objectWillChange` plus `DispatchQueue.main.async` delays to wait for the manager's stored value to catch up.
- Songs uses `SongsTrackListHost` on large screens, with adaptive artist/album metadata columns when width allows. iPad hosts rows in `MediaTrackList`/`UITableView`; macOS hosts rows in the AppKit `NSTableView` backend. Keep row actions resolved through `TrackRowInteractionModel` so UIKit/AppKit behavior stays aligned. Do not use `TrackSwipeContainer` or reintroduce a column-customization table for Songs unless explicitly requested.
- Native track-list surfaces should pass display and state through `NativeTrackListConfiguration` / `NativeTrackListSection` when they need the shared host. Keep direct `MediaTrackList` use for compact iPhone or self-scrolling table-header cases where the UIKit table owns the header/footer.
- Keep the following representable/bridge adapters as intentional platform ownership, not cleanup targets: `MediaTrackList`/`QueueTableView` UIKit tables, `MacNativeTrackTableView` AppKit tables, `AirPlayButton`, Metal aurora surfaces, the global toast window, native share-sheet/AppKit menu hosts, `iOS15TabBarHider`, and the iOS 15 mini-player safe-area inset bridge. These should be simplified only when replacing them with an equivalent native owner, not with SwiftUI gesture/layout shims.
- Native table representables should consume parent scroll requests as value objects with coordinator-owned handled ids. Do not clear SwiftUI bindings from `updateUIView` / `updateNSView` through main-queue hops.
- Persistent native track-list callers that need download and availability row refreshes should keep those values as state projections and attach `trackListRuntimeObservation(activeDownloadRatingKeys:availabilityGeneration:)`. Do not duplicate the `OfflineDownloadService.$activeDownloadRatingKeys` + `TrackAvailabilityResolver.$availabilityGeneration` `onReceive` pair in each large view.
- Persistent native track-list callers that need Now Playing row highlighting and recent-playlist menu labels should attach `nowPlayingTrackListObservation(...)` and keep only projected `@State` values such as current track id or recent playlist title/id. Do not observe the full `NowPlayingViewModel` from these large surfaces.
- Persistent list/detail surfaces that only need container width for supplemental track-list metadata should use `.measuredWidth(onChange:)` and keep a guarded state assignment in the caller, rather than duplicating background `GeometryReader` blocks.
- Persistent root/search views should capture shared managers once in `init`, initialize local `@State` projections from those managers, and subscribe to focused publishers instead of repeatedly reaching into `DependencyContainer.shared` from body modifiers.
- Persistent list views that react to a family of related `NotificationCenter` events should fan them into a typed event publisher and route through one handler, so payload parsing, toast cleanup, and cached-list refresh policy do not drift across receivers.
- Cached section/grouping work in persistent browse screens should use `.task(id:)` with SwiftUI cancellation, then assign guarded `@State` results. Do not add manual GCD token counters or `DispatchQueue.main.async` hops to wait for stale layout/search computations to settle.
- Toolbar buttons nested inside persistent lists should project only the singleton state they need, such as `SyncCoordinator.isOffline`, with guarded `@State` updates instead of observing the whole singleton object.
- Native track-list metadata columns must be fixed-width and right-pinned with equality constraints; only the title region should flex/truncate. Keep duration and status/download lanes fixed-width too. Do not chain artist/album/duration with `lessThanOrEqual` constraints, or mixed title/artist/album lengths, duration strings, or download state will shift columns per row.
- Search song results and virtual collection/detail track lists such as Favorites, Mood, and Artist Favorited Tracks should use the same native track-list backends (`MediaTrackList` on iOS/iPadOS and `SongsTrackListHost`/AppKit table host on macOS) instead of reintroducing `TrackListView` or hand-built compact track rows, so wide metadata columns, context menus, and native row actions stay aligned.
- Do not reintroduce the deleted `TrackRow`/`TrackSwipeContainer` stack for compact iPhone lists. Compact Songs should keep its current `MediaTrackList` path with genre chips, native row swipe actions, and existing mini-player spacing.
- Compact iPhone Songs should attach `GenreFilterHeader` as a sticky top `safeAreaInset` on `SongsTrackListHost`, with a matching native table `topContentInset`, instead of wrapping the table in a parent `VStack`. This keeps genre chips pinned during normal row scrolling, lets the navigation/search chrome collapse from the native table's scroll, lets the chip inset follow the table's top rubber-band stretch, and keeps section headers below the chips while the native table owns rows/actions. macOS Songs should embed genre chips as native table header content so they scroll away with the songs list instead of staying pinned above the table. Let the compact `MediaTrackList` extend through the top and bottom safe-area container edges so content can bleed behind toolbar and tab-bar chrome while the table's own bottom inset keeps final rows reachable. Keep compact indexed Songs' `ScrollIndex` overlay outside that bleeding table so it stays aligned to the same safe-area viewport and default bottom-chrome placement as Albums/Artists. Compact indexed Songs should keep one `MediaTrackList` as the row owner and drive section jumps through that overlay. Keep its native table section headers visually aligned with `EnsembleBrowseSectionHeader`. Do not enable `UITableView`'s built-in section index for this surface; on iOS 26 it anchors to the table's adjusted frame, draws a tracking background, and can sit below floating headers.
- Refreshable root screens should attach `.refreshable { ... }` directly to the native vertical scroll owner for every visible content state, including empty/error states that mention pull-to-refresh. Also attach `.refreshCommand { ... }` with the default "Refresh" title, which publishes through the scene-focused refresh action so macOS View > Refresh and iPadOS keyboard/menu commands invoke the active screen's same async refresh action without requiring a child control to hold focus.
- Feed uses a stale-while-revalidate cadence: show cached hubs immediately, fetch once per app session/when the last network snapshot is at least 10 minutes old, and let manual pull-to-refresh bypass the cadence. Do not call `loadHubs()` unconditionally from `HomeView.task`.
- Native-behavior cleanup closeout rule: keep platform bridges only when they own real platform functionality (`MediaTrackList`, `MacNativeTrackTableView`, AirPlay, Metal, toast window, iOS 15 tab/mini-player bridges, native share/menu hosts). Treat any new safe-area compensation, delayed layout task, custom scroll detector, or root-chrome mutation as suspect until a current simulator or macOS repro proves native behavior is broken.

### Aurora Surfaces
- `AuroraVisualizationView` should use the shared `MetalAuroraSurface` renderer when Metal is available, with the Canvas path kept as the compatibility fallback.
- Keep root/sidebar backdrops in the low-cost surface tier and Now Playing/viewport surfaces in the richer tier. Do not throttle playback frequency publishers to reduce visual cost; change renderer tier, pass count, or frame interval at the visual surface instead.
- Preserve the full-width backdrop/fade composition while constraining active aurora bands through `activeContentMaxWidth` when the caller provides it.
- The Metal renderer should output only premultiplied colored aurora content over a transparent MTKView backing layer. Keep the foreground/bottom fade as a SwiftUI overlay above Metal so the fade stays in front without making the Metal drawable an opaque background band.
- Preserve the "horizon" read by drawing a stronger accent wash under the foreground fade, not by baking opaque color into the Metal layer. The fade should unify the aurora and horizon band as one composition.
- Keep the Metal aurora's outer layer broad and low-opacity so the top dissolves like the older Canvas blur passes instead of reading as a hard oval blob.

### Button Labels

- Detail-surface playback actions use native Liquid Glass button styles on iOS 26+/macOS 26+ with explicit `.buttonBorderShape(.capsule)` so Play/Shuffle/Radio keep capsule geometry and native press feedback across platforms. Primary actions such as Play use accent-tinted interactive glass plus the native tint environment with white foreground text/icons on both iOS and macOS. Secondary actions such as Shuffle and Radio use neutral interactive glass. Now Playing's primary play/pause control uses neutral native interactive glass with `.buttonBorderShape(.circle)` and primary foreground, so it keeps press feedback without using the app accent color. Keep older OS fallbacks routed through the shared action-row owners.

- Do not wrap Liquid Glass control groups in `.chromelessMediaControlButton()` on macOS. That helper applies `.buttonStyle(.plain)` and will suppress native glass rendering and press interaction. Apply borderless/plain styling only to the specific non-glass controls that need it.

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
- The watchOS target is a standalone lightweight Plex client plus optional phone remote, not a full `EnsembleCore` client. Watch UI should stay compact, text-first, and shallow: pins first on Home, then library category rows (Albums, Artists, Playlists, Recently Added), then detail track lists. Source settings should use a lightweight account → server → library toggle list plus an explicit selected-library sync action, not the full iOS/macOS profile UI. Keep Now Playing as a persistent top-right toolbar button and let it switch between watch-local playback and phone remote control. Do not import `EnsembleUI` or the iOS playback dependency graph.
- Watch Now Playing toolbar access should use SwiftUI's explicit top-bar trailing placement on watchOS 10+ (`ToolbarItemPlacement.topBarTrailing`). Do not use `.primaryAction` for this, because Apple places watchOS primary actions beneath the navigation bar and reveals them by scrolling. For watchOS 8/9 compatibility, use the local `watchNowPlayingToolbar()` fallback overlay in `WatchRootView`.

### Toast Presentation
- iOS/iPadOS toasts are mounted once at app root via `installGlobalToastWindow(toastCenter:)` in `EnsembleApp`
- Do not mount `ToastHostView` in individual screens; call `deps.toastCenter.show(...)` and let the global host render it
- Global toast window must stay above mini player and modal sheets for consistent feedback visibility
- The global toast window should attach from the hidden UIKit probe view's `didMoveToWindow` lifecycle. Do not add `DispatchQueue.main.async` retries to wait for `windowScene`; the probe view owns scene attachment.

### Gesture Actions (iOS/iPadOS)
- Track rows use a shared swipe layout from `SettingsManager.trackSwipeLayout` (2 leading slots, 2 trailing slots)
- UIKit/AppKit native track-list delegates should receive `SettingsManager` through their coordinator dependencies instead of reaching back into `DependencyContainer.shared` from delegate callbacks.
- Slot 1 on each edge is full-swipe enabled; slot 2 is reveal-only
- Supported swipe action catalog in v1: `Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle
- Keep primary tap behavior unchanged (tap still plays/navigates as before)
- Use `MediaTrackList` swipe delegates for UIKit-backed track lists; do not bring back the deleted SwiftUI `TrackSwipeContainer` layer for new rows.
- macOS keeps existing interaction model (no custom swipe gesture layer in v1)

### Long-Press Menus
- Shared media context-menu policy lives in `MediaMenuCatalog`. New track, album, artist, playlist, or merged-playlist menus should use the catalog for action order, section grouping, and destructive/editing gating; parent views should add only local handlers such as queue removal, MiniPlayer shuffle/repeat, or pinned unpin behavior.
- Use `TrackActionsContextMenu` for standalone SwiftUI track cards/menus outside native table rows, including feed cards, mini-player long-press menus, and queue/history fallback rows. It renders the shared catalog and lets the parent inject only navigation, playlist-picker presentation, or removal handlers.
- Add-to-playlist follow-up UI should be presented through `PlaylistActionPresentationHost` and `.playlistActionPresentation(request:nowPlayingVM:)`; menus and row actions should request the shared host instead of owning a local sheet payload.
- Prefer `contextMenu` on album/artist/playlist cards/rows to mirror detail-view actions
- Album menu: `Play`, `Shuffle`, `Play Next`, `Play Last`, `Radio`, `Add to Playlist…`, `Pin/Unpin`
- Artist menu: `Play`, `Shuffle`, `Radio`, `Pin/Unpin`
- Playlist menu (Playlists screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin`, plus (for non-smart playlists) `Rename…`, `Edit Playlist`, `Delete`
- Playlist menu (Search screen): `Play`, `Shuffle`, `Play Next`, `Play Last`, `Pin/Unpin` (non-destructive only)

### Genre Filters
- Use `GenreFilterHeader` for browse and detail genre filter rows. Do not place `GenreChipBar` directly in screens; the header owns the shared spacing and optional supplementary content such as merged-playlist source chips.
- Genre chip rows should scroll as ordinary content or native table header content. Do not pin genre chips with `pinnedViews`, sticky overlays, or scroll-offset/safe-area shims.
- Liquid Glass genre chips should keep material/shadow clearance inside the `GlassEffectContainer` content, not as padding outside the container, so the glass material is not clipped by the container or native table header. Do not add `clipShape` before `glassEffect`; pass the intended shape to `glassEffect(_:in:)` and let the native effect own its rendering bounds.

## Visual Design

### Design Tokens And Adaptive Patterns
- Use `EnsembleDesign` for semantic UI values instead of introducing new raw literals for repeatable roles.
- Token groups cover spacing, radius, typography, color, icons, breakpoints, effects, and semantic material roles.
- App-accent surfaces should use `EnsembleDesign.Color.accent` / `Color.accentColor` so macOS follows Apple's accent policy: explicit System Settings accent colors override the app accent, while Multicolor lets the app-provided accent show. Do not pass `SettingsManager.accentColor.color` directly into ambient custom surfaces such as artwork washes, aurora, toast accents, utility row icons, sidebar adornments, or Now Playing chrome; reserve the stored setting for establishing the app accent environment and for actual accent picker swatches.
- Keep specialized existing helpers where they encode behavior, such as `TrackListLayoutMetrics` for track rows and `ArtworkCornerRadius` for media artwork. These bridge into `EnsembleDesign` instead of being replaced by unrelated literals.
- Use `EnsembleScaffold` for larger adaptive patterns, such as shared empty/loading/error states.
- Filter presenters should present `FilterSheet` directly with native `.sheet(...)` on iPhone, iPadOS, and macOS. Do not reintroduce toolbar popovers or a custom filter presentation wrapper unless a current simulator repro proves native sheets are broken.
- Large-screen browse splits should use `LargeScreenBrowseSplitView` with `EnsembleScaffold.BrowseSplit.Configuration` presets instead of repeating raw pane width, breakpoint, and resize-handle values per screen.
- `LargeScreenBrowseSplitView` owns browse-split width measurement and resize clamping. Keep its geometry local to the shell; child browse/detail screens should not add their own column-width math or forced max-height wrappers to correct split layout.
- Media-style detail screens should keep header/list/action/shadow metrics under `EnsembleScaffold.DetailSurface` and render through `MediaDetailSurface` helpers rather than inventing parallel detail surface constants.
- Artist detail's custom square/circular adaptive header should keep its specialized thresholds, hero dimensions, section rhythm, and overlay strengths under `EnsembleScaffold.ArtistDetail`.
- macOS Profile/Downloads-style utility windows should use `MacAuxiliaryWindowScaffold` plus `EnsembleScaffold.AuxiliaryWindow.Configuration` presets so scene sizing and in-window content width stay in sync. For menu-like rows, use `EnsembleAdaptiveUtilityScaffold` when a screen needs iOS grouped-list and macOS card-section variants; use `EnsembleUtilityScreenScaffold`, `EnsembleUtilityCardSection`, `EnsembleUtilityCardRow`, and `EnsembleUtilityCardDivider` for the macOS card body so macOS avoids bordered `List` chrome. Filter sheets are an exception: keep `FilterSheet` on the native form/navigation sheet path across iPhone, iPadOS, and macOS instead of maintaining a separate macOS card shell. Current migrated utility examples include Logs, account detail, playlist create/edit, and text-input sheets.
- Loading, empty, and error states should use `EnsembleStateScaffold`. Use the default full-screen presentation for standalone states and `.compactFooter` for track-list/table-footer states.
- Library browse empty states that branch on cloud restore, missing sources, syncing, disabled libraries, or true empty content should use `EnsembleLibraryEmptyStateScaffold` instead of rebuilding that decision tree per screen.
- Library browse screens that have already displayed cached content should not publish a transient empty list or swap to a full blank/loading state during refresh. Keep last-good rows visible, mark stale/loading locally when needed, and use stable placeholder rows only for the very first load before any cached content exists. Playlists is the reference implementation.
- Filled actions inside empty/loading/error states should use `EnsembleStateActionLabel`; account setup/authentication surfaces should use `EnsembleScaffold.AccountSetup` for PIN, card, row, and sheet sizing.
- Profile, downloads, account detail, and lightweight settings rows should use `EnsembleUtilitySectionHeader`, `EnsembleUtilityIcon`, `EnsembleUtilityInlineStatusRow`, `EnsembleUtilityTextStack`, `EnsembleUtilityRowLabel`, and `EnsembleScaffold.UtilityRow` for section headers, icon lanes, thumbnail dimensions, nested status indentation, and compact text/status spacing.
- Shared browse toolbar groups live in `EnsembleBrowseToolbar`; keep screen-owned actions as small button/menu helpers and let the scaffold own platform placement and spacing.
- Standalone macOS detail toolbar actions that need trailing alignment should use `EnsembleDetailToolbarLeadingSpacer`; ordinary root/action toolbars should use `EnsembleToolbarLeadingSpacer`; large-screen browse detail panes are marked by `LargeScreenBrowseSplitView` so detail spacers are suppressed in dual-pane mode.
- Indexed browse section headers should use `EnsembleBrowseSectionHeader`, and large-screen browse selection rows should use `EnsembleScaffold.BrowseSelection` / `browseSelectionBackground(isSelected:)`. Native indexed track section headers should not paint their own background; leave the surrounding scroll/table surface visible so adjacent Liquid Glass and material effects are not visually clipped.
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
- **Shared detail shell:** Media-style detail screens should build their hero artwork, metadata block, action row, and list-card styling on `MediaDetailSurface` so `MediaDetailView` and `DownloadTargetDetailView` do not drift on spacing, wide-layout behavior, or light/dark presentation. Artwork-backed detail screens that need content to pass under translucent titlebar/toolbar chrome should set `contentBleedsUnderTopChrome: true` on `MediaDetailSurface` instead of adding local `.ignoresSafeArea(edges: .top)` modifiers.
- **Detail loading stability:** Album, playlist, artist, and virtual collection detail loads should avoid full-screen centered loaders that later swap to top-aligned headers. Use `MediaDetailSurface.LoadingState` or keep the shared header/table shell mounted with a compact footer loader during initial data fetches. On macOS, keep the detail root top-aligned, let AppKit own native table safe-area/content insets and clip views, use a bottom spacer row for mini-player clearance, let the AppKit backend use a deterministic wide-header row height, preload the initial album/playlist track snapshot in loaders before mounting the shared detail table, and publish virtual collection filtered snapshots before clearing their loading state so the first table layout already has its final rows; do not force the native table host itself to infinite height as a reflow workaround.
- **Artwork-backed toolbar bleed:** Artwork-backed roots such as Feed, MediaDetail, and Artist detail should apply `artworkBackedToolbarBleed()` from the surface owner so artwork and scrolling content can remain visible behind native translucent toolbar chrome. On macOS 26+, hide only the window-toolbar background and let `ArtworkDetailBackground` use `backgroundExtensionEffect()` so Liquid Glass can sample the artwork wash. On pre-26 macOS, leave the toolbar background native/visible for readability instead of forcing transparent chrome. Keep the main macOS window on the native titlebar style, keep AppKit scroll/clip views transparent, and do not add titlebar drag bridges or AppKit toolbar proxies to leaf views.
- **macOS detail footer scrolling:** Do not put horizontal SwiftUI shelves inside `SongsTrackListHost` table footers on macOS. AppKit should own the native track table scroll; related album content in a table footer should be a non-scrolling adaptive grid, while horizontal shelves belong in SwiftUI-owned vertical scroll surfaces such as Feed.
- **Feed scrolling:** Do not add outer `DragGesture`/scroll-idle detectors around the Feed `ScrollView` to defer hub updates. Hidden Feed refreshes can wait until visibility returns, but visible hub snapshots should apply directly and let native scrolling own gesture arbitration. Do not force Feed's root `ScrollView` under the macOS toolbar with local safe-area padding; that clips the first row on launch.
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
- **Empty states:** Use `EnsembleStateScaffold` with the relevant sync/setup prompt.

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
