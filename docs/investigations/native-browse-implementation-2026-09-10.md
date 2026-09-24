# Native browse implementation

## Shipping behavior

Ensemble uses the native browse shell automatically on iPadOS 18+ and macOS
15+. iPhone, iPadOS 15–17, and macOS 12–14 retain the existing shell. The
deployment targets remain iOS 15 and macOS 12.

Artists, Genres, and Playlists use `NavigationSplitView`'s real `content:`
column for their browser and `detail:` for the selected item. Albums, Songs,
Favorites, Downloads, Search, and other root sections remain two-column views
inside the same app sidebar. SwiftUI owns column collapsing and divider
resizing; Ensemble does not add a second sidebar or a custom splitter.

## State ownership

- `RootView` owns the scene-local app section and external-route handoff.
- `SidebarView` owns native item selections above replaceable section roots.
- `NavigationCoordinator` owns each section's detail path.
- `NativeBrowseScrollState` retains at most one leading item ID per three-column
  section. The shared native scroll view uses stable IDs, `scrollPosition(id:)`,
  and one geometry-confirmed `ScrollViewReader.scrollTo` restoration because an
  `onAppear`-only restoration reproduced a 350-point return jump.
- Root chrome registration identifies the column that owns the content frame,
  so the shared mini-player follows native column resizing and sidebar changes.

No new service, singleton, persistence, cache, dependency, pixel-offset tracker,
or controller introspection was introduced. Scroll restoration is scene-local,
survives section replacement, and intentionally does not survive app relaunch.

## Platform details

The native shell allows all orientations on iPadOS 18+. Older iPadOS releases
retain the existing orientation policy. macOS uses a 1,100-point minimum window
width for the native three-column layout; the legacy shell keeps its existing
minimum.

The middle columns use inline titles and the existing toolbar-material helper.
macOS keeps a single search-toolbar owner to avoid duplicate SwiftUI search-item
registration. Compact iPhone browse lists and grids are unchanged.

## Verification

The September 11 shipping-gate pass completed with the production availability
policy and no native-browse launch argument:

- All 24 `NavigationRootHelperTests` passed.
- `testNativeBrowseRetainsScrolledItemAcrossSections` passed for Artists,
  Genres, and Playlists.
- `testNativeBrowseRotation` passed portrait/landscape resizing and switching
  between three-column Artists and two-column Albums.
- Fresh iPadOS and macOS Debug builds passed, as did an unsigned macOS Release
  build targeting macOS 12.
- A fresh iPhone launch retained the tab shell; a fresh iPad launch selected the
  native Artists content/detail shell automatically.

Earlier direct iPad and macOS checks covered native selection, nested navigation,
sidebar hide/show, divider resizing, and mini-player alignment.

## Residual verification

Older-OS runtime parity, exhaustive keyboard/focus behavior, arbitrary Stage
Manager sizes, and comparative memory/binary profiling are not established by
the focused checks. Source availability guards preserve the older implementation,
but release validation should still include representative older runtimes.
Both the prior gated build and the shipping-gate macOS Debug build emitted
AppKit's reentrant `NSTableView` delegate warning during startup. It did not
prevent launch and was not introduced or localized by the availability cleanup.
