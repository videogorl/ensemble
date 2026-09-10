# Native browse content-column source references

Date: 2026-09-10. Read-only source research; none of these external apps was built or run. These are patterns to study, not dependencies to add. No inspected project proves the exact combination of adaptive tab sidebar, real supplementary/content column, and section-dependent two/three-column layout that Ensemble wants.

## 1. Foods navigation example: explicit two/three-column variants

Tunde Adegoroye's sample is the closest small SwiftUI example for changing column count. `MenuView` selects `ThreeColumnMenuView` or `TwoColumnMenuView`; both receive the same external router and visibility state. In the three-column version, the category sidebar, selectable item list in `content:`, and a detail `NavigationStack` are distinct roles. The two-column version puts a list/grid and its navigation stack in detail. Sources: [MenuView](https://github.com/tunds/SwiftUI-Navigation-Multiplatform-Example/blob/240160eebf0b272feb39c77673dd864a49f03302/Project/Introduction%20to%20NavigationStack/Menu/Views/MenuView.swift), [ThreeColumnMenuView](https://github.com/tunds/SwiftUI-Navigation-Multiplatform-Example/blob/240160eebf0b272feb39c77673dd864a49f03302/Project/Introduction%20to%20NavigationStack/Menu/Views/ThreeColumnMenuView.swift), [TwoColumnMenuView](https://github.com/tunds/SwiftUI-Navigation-Multiplatform-Example/blob/240160eebf0b272feb39c77673dd864a49f03302/Project/Introduction%20to%20NavigationStack/Menu/Views/TwoColumnMenuView.swift).

Useful for Ensemble: keep selected section, item ID, and detail path outside the replaceable container. Borrow the small structural switch, not the app's router wholesale. Its [NavigationRouter](https://github.com/tunds/SwiftUI-Navigation-Multiplatform-Example/blob/240160eebf0b272feb39c77673dd864a49f03302/Project/Introduction%20to%20NavigationStack/NavigationRouter.swift) stores those values separately.

Caveats: this is an educational sample, not proof of regression-free transitions. It switches by a setting, not by selected section. Its [app root](https://github.com/tunds/SwiftUI-Navigation-Multiplatform-Example/blob/240160eebf0b272feb39c77673dd864a49f03302/Project/Introduction%20to%20NavigationStack/Introduction_to_NavigationStackApp.swift) uses an older tab view and hides the tab bar on non-phone devices; it does not establish interoperability with iOS 18 adaptive tab sidebars. External navigation state does not by itself preserve scroll position or native container presentation state when the view identity changes.

## 2. NetNewsWire: production UIKit column roles

NetNewsWire's iOS storyboard supplies master, supplementary, and detail controllers to one native split controller. Its scene coordinator maps feeds to `.primary`, article list to `.supplementary`, and article to `.secondary`; it gives primary and supplementary independent minimum/maximum/preferred widths. Sources: [Main.storyboard](https://github.com/Ranchero-Software/NetNewsWire/blob/dc74019c2434acf4a9a7826e709257a4a2541361/iOS/Base.lproj/Main.storyboard#L169-L178), [SceneCoordinator initialization](https://github.com/Ranchero-Software/NetNewsWire/blob/dc74019c2434acf4a9a7826e709257a4a2541361/iOS/SceneCoordinator.swift#L340-L373).

Useful for Ensemble: genuine column roles, separate width policy, and selection-aware compact collapse. Its [collapse delegate](https://github.com/Ranchero-Software/NetNewsWire/blob/dc74019c2434acf4a9a7826e709257a4a2541361/iOS/SceneCoordinator.swift#L1702-L1727) chooses the top column based on whether a feed/article exists.

Caveats: this is not an adaptive-tab integration or section-dependent structural switch. Its [RootSplitViewController](https://github.com/Ranchero-Software/NetNewsWire/blob/dc74019c2434acf4a9a7826e709257a4a2541361/iOS/RootSplitViewController.swift#L30-L59) distinguishes navigation from restoring display modes, demonstrating that native columns still need intentional state handling. Do not transplant its large application coordinator or assume UIKit makes all transitions automatically correct.

## 3. Ice Cubes: current adaptive tabs, but not the missing middle column

Ice Cubes' [AppView](https://github.com/Dimillian/IceCubesApp/blob/b2db3033fbf67a97b54d25d6dac2df8a029b26b1/IceCubesApp/App/Main/AppView.swift) applies `.sidebarAdaptable` to a tab view, and optionally places a fixed-maximum-width notifications view alongside it in an `HStack`. This is useful evidence for dynamic native tab sections, but the extra panel is not a native supplementary/content column. It would not solve Ensemble's structural concern; do not copy that composition as the fix.

## Implication for the next experiment

First prove a minimal section-driven switch between a real three-column root (app sidebar / browse list / detail) and two-column root (app sidebar / album or song content), reusing Ensemble's existing navigation state. This is a control experiment, not a proposal to silently remove the adaptive tab bar. Retaining that bar and its sidebar transition is a separate acceptance gate: none of the inspected sources validates the exact combination. Test section changes, portrait/compact collapse and expansion, selection/path retention, list/grid changes, keyboard focus, and chrome ownership before adopting the arrangement across all browse surfaces.

### Apple API constraints

- SwiftUI's three-column `.doubleColumn` visibility shows **content and detail**, not sidebar and detail. Consequently it cannot supply the Albums layout merely by hiding the middle column. Use explicit two/three-column configurations in the control experiment. [NavigationSplitViewVisibility.doubleColumn](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility/doublecolumn)
- The adaptable tab sidebar is a separate navigation container; Apple's tab/sidebar session describes its conversion to the top tab bar, not a public method for merging it into a split view's primary column. [WWDC24: Elevate your tab and sidebar experience](https://developer.apple.com/videos/play/wwdc2024/10147/)
- UIKit offers distinct primary/supplementary/secondary roles and column sizing controls. Its `primaryBackgroundStyle = .none` removes the primary background effect, but this is not evidence that a primary column has become supplementary. A small owned UIKit container is a fallback to investigate, not an already-proven fix or a reason to introspect SwiftUI's private controllers. [UISplitViewController](https://developer.apple.com/documentation/uikit/uisplitviewcontroller), [BackgroundStyle](https://developer.apple.com/documentation/uikit/uisplitviewcontroller/backgroundstyle)

### Ensemble implementation boundary and acceptance

Start with Artists and Albums behind the existing debug gate in this worktree. `SidebarView` already owns the selected artist/genre/playlist above tab content; keep that ownership, the scene navigation coordinator, existing action owners, and root mini-player ownership. Explicitly verify scroll position and active detail paths across container replacement; external model state alone is insufficient. Do not add a router, dependency, custom divider, guessed safe-area inset, or delayed layout fix.

Keep the iOS 15–17 and macOS 12–14 paths unchanged. A UIKit fallback would be iPad-specific and would not establish native AppKit macOS compatibility; validate the SwiftUI desktop shell independently. Generalize to Genres and Playlists only after the two-section experiment passes. Reuse the existing native-browse rotation journey and navigation coverage, extending only the specific transition evidence they lack. Compare equivalent baseline/modified flows for build size, retained memory, and repeated-switch responsiveness before claiming low overhead.

This note is a proposal and source review only. No application code or installed simulator build was changed for this research.
