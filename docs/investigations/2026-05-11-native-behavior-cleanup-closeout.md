# Native Behavior Cleanup Closeout

Date: 2026-05-11

## Scope

Final closeout pass for the native-behavior cleanup plan. The scan focused on UI code that can fight SwiftUI/UIKit/AppKit ownership:

- `.ignoresSafeArea`
- `UIViewRepresentable` / `NSViewRepresentable`
- `hitTest`
- `performDragOperation`
- `GeometryReader`
- `DispatchQueue.main.async` / `asyncAfter`
- custom scroll/offset/drag handling
- forced infinite scroll frames
- safe-area, titlebar, toolbar, and navigation-bar bridge code

## Findings

### Keep: Active Platform Adapters

These remain intentional because they own real platform behavior rather than papering over SwiftUI layout:

- `MediaTrackList`, `QueueTableView`, and `MacNativeTrackTableView` for native row actions, tables, context menus, and AppKit/UIKit scrolling.
- `AirPlayButton` for `AVRoutePickerView`.
- `MetalAuroraSurface` for native Metal rendering.
- `GlobalToastWindowHost` / `PassthroughWindow` for app-wide toast z-order above sheets and the mini player.
- `ShareSheet` and `NativeMiniPlayerActionsMenuButton` for native share/menu presentation.
- `iOS15TabBarHider` and `MiniPlayerContainerInsetter` for iOS 15-only chrome/inset behavior that SwiftUI does not expose.
- `MacSidebarPlaylistDropBridge` for AppKit sidebar drop handling.

### Keep: Local Layout Measurement

Remaining `GeometryReader` usage is concentrated in measurement or intentionally immersive surfaces:

- `MeasuredWidthReader` and `MediaDetailSurface` width/header measurement.
- `NowPlayingWidePanelLayout`, `NowPlayingSheetView`, and `NowPlayingViewportRoot` adaptive layout.
- `StageFlowView` carousel geometry.
- `ArtistDetailView` overscroll hero behavior.
- Aurora/artwork backgrounds and responsive artwork composition.

### Removed Or Covered

- The unused SwiftUI track-row/swipe layer is documented as removed and should not return.
- The second pass removed private dead code that had no live call sites: stale playback seek/source scaffolding, a buffered-progress helper, analyzer/log constants, unused Search/StageFlow/MainTabView helpers, unused aurora drawing layers, and the old feed availability wrapper.
- Root-owned StageFlow now has coverage for visible tabs, Albums-in-More, and Playlists-in-More.
- Destructive library cleanup now has explicit test coverage that downloaded files and sidecar files are removed, not just CoreData download rows.
- Feed documentation now matches current behavior: native scroll views own gestures, and automatic refresh is deferred only while Feed is off-screen.

### Watchlist

- macOS 26 Feed toolbar Liquid Glass sampling still does not perfectly match the post-navigation state on first render. The current known-issues entry rejects hardcoded safe-area padding and window-wide background shims; future work should look for a root detail-column ownership fix.
- StageFlow geometry constants remain intentionally local. Treat future changes as a dedicated visual retune, not as generic token cleanup.
- Lyrics iOS 18+ scroll-phase affordances should stay view-local. Older OS versions should keep native unblurred behavior rather than gaining detector shims.

## Closeout Rule

Do not add custom safe-area compensation, delayed layout tasks, custom scroll detectors, or root-chrome mutation unless a current simulator/macOS repro proves native behavior is broken. If a bridge is needed, it should be owner-scoped, idempotent, and documented in `ui-conventions`.
