# Navigation And Platform UI

- `RootView` owns the scene `NavigationCoordinator`; root tab/sidebar shells
  inject it. Use typed destinations and existing path helpers. Do not reach into
  `DependencyContainer.shared.navigationCoordinator` for user-driven routing.
- Route media links, cards, relationship links, menus, and deep links through
  `NavigationCoordinator`. When a concrete model is available, push the concrete
  detail rather than an ID loader. A sheet-to-route handoff uses pending
  navigation owned by the root, not an animation delay.
- iOS 16+ uses `NavigationStack`; iOS 15 keeps the existing mounted
  `NestedNavigationLink` bridge. Add availability branches only at the shared
  owner, not at every caller.
- iPhone uses the tab shell; regular-width iPadOS/macOS use the native root
  split/sidebar shell. Preserve compact push navigation. Keep selection outside
  replaceable detail subtrees so resizing or section changes do not reset it.
- Keep root profile/search/tab/mini-player/Now Playing chrome at the root owner.
  Leaf views must not compensate for root safe areas, hide global chrome, or
  mutate UIKit/AppKit appearance to repair a local transition.
- Keep persistent navigation and scroll roots structurally stable across runtime
  environment changes; pass changing values into modifiers instead of choosing
  conditional modifier branches.
- StageFlow is iPhone-only. `MainTabView` owns activation, orientation support,
  and root chrome suppression. Browse screens only consume
  `isStageFlowActive`; do not add local rotation detection or delay timers.
- Use `TrackListLayoutMetrics`, `LargeScreenBrowseSplitView`,
  `EnsembleBrowseToolbar`, and native track-list hosts rather than duplicating
  spacing, pane math, row gestures, or table columns.
- Keep intentional native bridges for native tables, AirPlay, Metal aurora,
  global toast hosting, share/menu hosting, and iOS 15 tab/mini-player behavior.
  New representables must own real platform functionality, not timing/layout
  workarounds.
- Native table callers pass value requests with coordinator-owned handled IDs.
  Avoid mutating SwiftUI bindings from representable update callbacks.
- Root and persistent views subscribe to focused state projections. Do not
  observe a broad manager for one label, badge, or row highlight.
- Refresh commands and pull-to-refresh attach to the actual native scroll owner,
  including empty/error states that advertise refresh.
