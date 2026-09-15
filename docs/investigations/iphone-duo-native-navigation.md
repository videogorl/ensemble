# Native navigation and iPhone Duo

Research checked on 2026-09-15. Local tools are Xcode 27.0 (27A266a), SDK 27.0.

## Implementation constraints

Keep Ensemble's browse navigation native. Apple says `NavigationSplitView`,
`UISplitViewController`, `TabView`, and `UITabBarController` adapt across Duo poses:
columns collapse when closed and tile or overlay when open. Layout decisions
should use size classes and available bounds, not device idiom or interface
orientation. The inner display is regular in both dimensions. Respect each safe
area edge independently, because the insets can be asymmetric.

Full Duo testing requires Xcode 27.1 and its simulator. Building with SDK 27.1
also enables the full inner-display layout and adapted system bars; the 27.0 SDK
does not provide that complete experience.

Source: [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/).

## New content-layout APIs

`ArrangementView` and `UIArrangementViewController` arrive in iOS 27.1. Their
split and overlay arrangements account for size classes, aspect ratio, and
active division regions. They arrange content within navigation; they are not
replacements for navigation infrastructure. Apple specifically advises against
putting `NavigationSplitView` inside an arrangement.

Standard navigation and scrolling containers already adapt to the fold. Custom
chrome, including Ensemble's mini-player, needs a separate reserved-region review
on SDK 27.1 so its controls do not straddle the hinge or cameras. Width-only
simulator resizing is not proof of fold-aware behavior.

Source: [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/).

## Current sidebar investigation

On the iOS 27.0 iPhone simulator, entering Artists at 1126×844 or 1280×960 hides
the app sidebar. Instrumentation observed `.all` when the three-column view
appeared, followed by a native writeback to `.doubleColumn` about 97 ms later.
UIKit reported an expanded triple-column controller with a regular width class.
Explicit detail widths and changing the preferred compact column did not resolve
the behavior. Both scene size classes were regular at 1126×844.

A draft using Ensemble's custom browse splitter preserved the sidebar, but was
rejected because retaining native adaptivity is a requirement. That draft was
removed. Do not treat its screenshots as verification of a native fix.

A separate minimal app reproduced the behavior on simulator
`AAD6D5F8-634F-4216-843F-54E9833FB52F` (iOS 27.0, build 24A434):

- Plain `NavigationSplitView`, `.all`, and `.balanced` stayed collapsed at
  1126×844 without a size-class override.
- Providing a regular horizontal size class, including only above a measured
  width threshold, showed content and detail but hid the primary sidebar.
- The sample contains only two lists and a text detail, with no preferred compact
  column binding or Ensemble code. Source and evidence are retained in
  `/tmp/ensemble-native-split-probe` for this run.

Minimal reproduction (present this view in a `WindowGroup`, then resize from
402×874 to 1126×844 in Device Hub):

```swift
struct Probe: View {
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $visibility) {
                List { Text("PRIMARY SIDEBAR") }.navigationTitle("Sidebar")
            } content: {
                List { Text("CONTENT LIST") }.navigationTitle("Content")
            } detail: {
                Text("DETAIL PANE").navigationTitle("Detail")
            }
            .navigationSplitViewStyle(.balanced)
            .environment(\.horizontalSizeClass, geometry.size.width >= 700 ? .regular : .compact)
        }
    }
}
```

The temporary probe was uninstalled afterward. Ensemble's native build from
`4499f95b` was restored and verified by installed binary hash and running PID;
Feed was left at 1126×844 with playback paused. No physical device was used.

This isolates the failure to the current native framework/Device Hub path, but
does not establish whether a newer runtime fixes it. Apple DTS acknowledged a
related Device Hub navigation resizing issue, FB23340323, and asked developers
to retest beta 3. That report does not prove the specific three-column defect is
the same issue.

Source: [Apple DTS: Adaptive Layouts iOS 27](https://developer.apple.com/forums/thread/835768).

The native sidebar consistency fix remains unresolved; no custom fallback is
being shipped. Next, retest the minimal sample with an updated runtime and
verify section changes, sidebar toggles, selection retention, and Duo's open,
closed, rotated, folded, and multitasking configurations on 27.1.
