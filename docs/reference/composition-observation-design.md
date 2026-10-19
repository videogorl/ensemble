# Step 2 design: composition root and Observation

Status: draft for Felicity's review, 2026-10-19, against `50445322` on
`develop`. Re-architecture plan step 2
([`rearchitecture-plan.md`](rearchitecture-plan.md), sections 4.1, 4.6 and
step 2). Nothing here is implemented yet.

Step 2 asks for four things: remove global container access from the UI, then
from Core; build every scene from one root; move view models to Observation;
collapse the five state transports toward one snapshot plus event stream.

## 1. What the inventory found

| Measure | Plan baseline (2026-10-13) | Now |
|---|---:|---:|
| `DependencyContainer.shared` uses | 277 in 60 files | 279 in 62 files |
| of which in `EnsembleUI` | 50 files | 163 in 52 files |
| of which in the app target | | 114 in 8 files (73 in `EnsembleApp.swift`) |
| of which in `EnsembleCore` | | 2 (the environment key default, `ArtworkLoader`) |
| Container files | about 1,300 lines | 1,317 (976 container, 327 view model factories, 14 environment key) |
| `ObservableObject` types | | 62: 22 view models, 22 services, 8 UI, 2 models, 1 watch |
| `@Published` properties | 363 | 355 in 53 files |
| `@StateObject` / `@ObservedObject` / `@EnvironmentObject` in views | | 31 / 97 / 79 |
| `$property` Combine subscriptions | | 140 (86 in Core, 36 in UI) |
| `onReceive` / `objectWillChange` | | 63 / 24 |
| Callback closures (`var onX: (…)`) | 122 | 135 in 25 files |
| `NotificationCenter` uses | 82 | 87 in 46 files; 15 app-defined names between services |
| Combine subjects / async streams | 19 / 11 | 16 / 7 |
| `@Observable` types | | 0 |

What these numbers mean:

1. **The environment is a global in disguise.** The `dependencies`
   environment key defaults to `DependencyContainer.shared`. The 45
   `@Environment(\.dependencies)` reads therefore work whether or not a
   scene injected anything, so they hide the same global the other 163 UI
   uses name directly.
2. **Four places build scenes, each reaching for the global.** The main
   `WindowGroup`, the Mac Profile and Downloads windows, and the UIKit
   external-display scene each inject `DependencyContainer.shared`
   themselves. `LibraryItemInfoPresentation` re-injects it mid-tree.
3. **View models and services are different problems.** View models are
   created by container factories and observed only by views; moving them to
   Observation is mechanical. The 22 observable services are also subscribed
   by other services through `$property` publishers (86 Core subscriptions).
   `@Observable` removes those publishers, and the Observation-to-stream
   bridge (`Observations`) needs iOS 26, above the iOS 17 floor.
4. **Most callbacks are not step 2's.** The callback count is dominated by
   UI action closures (`MediaContextMenus`, `MediaTrackList`), which are
   ordinary SwiftUI parameters, and by engine adapters already rebuilt in
   step 1. The cross-service transports step 2 can collapse are the 15
   app-defined notifications, the container's five `wire…Callbacks`
   helpers, and the Core `$property` subscriptions.
5. **The watch and the Siri extension are already clean.** Neither uses the
   global. The watch moves onto the shared stack in step 5.

## 2. Target

- `EnsembleApp` creates the one `DependencyContainer` and keeps it. There is
  no `static let shared`.
- Every scene receives it from the app: the main window, the Mac auxiliary
  windows, and the external display (through the app delegate the app
  owns). App Intents and App Shortcuts receive services through
  `AppDependencyManager` and `@Dependency`, Apple's mechanism for intents.
- Views get dependencies only from the environment. A scene that forgot to
  inject fails at once in a Debug build instead of silently reaching a global.
- View models are `@Observable`. Views hold them with `@State` and read only
  the properties they render, so a change re-renders only its readers.
- Each service that views or other services watch publishes one snapshot
  value, the pattern step 1 used for `PlaybackSnapshot`, and one event
  stream for things that happen rather than state that holds.
- The container shrinks to construction. Cross-service wiring moves to the
  owners' streams.

## 3. Sub-steps

Each sub-step builds on iOS, macOS and watchOS, passes the affected tests,
gets a simulator surface pass, and ends in a commit and a short note, as in
step 1.

| Step | Change | Done when |
|---|---|---|
| 2a | This inventory and design | Felicity approves the decisions in section 4 |
| 2b | One root. `EnsembleApp` owns the container; all four scenes and the app delegate receive it; App Intents use `AppDependencyManager`; the environment key no longer defaults to the global | No `.shared` in the app target; Mac multi-window and external display still work |
| 2c | UI off the global. Replace the 163 UI uses with environment reads; view model factories are called from the environment | No `.shared` in `EnsembleUI` |
| 2d | Core off the global. Remove the `ArtworkLoader` default; delete `static let shared` | The symbol no longer exists |
| 2e | View models to Observation. The 22 Core view models and 8 UI-local models become `@Observable`; `@StateObject` becomes `@State`, `@ObservedObject` a plain property or `@Bindable`, `@EnvironmentObject` `@Environment(Type.self)` | No `ObservableObject` view model remains |
| 2f | Services to snapshot plus events. Each of the 22 observable services exposes one `@Observable` snapshot for views and one stream for other services; replace the 15 app notifications and the container's callback wiring with those streams | No app-defined `Notification.Name` between services; the container is construction only |

2b to 2d are low risk and mostly mechanical. 2e is wide but each view model is
independent. 2f carries the risk: it changes how services learn about each
other, which is where ordering and missed-update bugs come from. It goes
service by service, highest fan-out first (`SettingsManager`,
`AccountManager`, `SyncCoordinator`, `NetworkMonitor`), each with a table test
of its snapshot transitions.

## 4. Decisions for Felicity

1. **How views find dependencies.** Recommended: make the container
   injectable with SwiftUI's typed environment
   (`.environment(container)` / `@Environment(DependencyContainer.self)`), which
   traps when a scene forgot to inject. Alternative: keep the custom key but
   with no global default. Either removes the hidden global; the typed form
   is native and needs no key code.
2. **The service-to-service transport.** The plan's principle is an
   observable snapshot plus an async event stream. Recommended: each owner
   exposes `snapshots: AsyncStream<Snapshot>` and, where needed,
   `events: AsyncStream<Event>`, with a small shared helper that fans one
   owner out to several listeners. Combine stays only where an Apple API
   hands it to us. Alternative: keep Combine `CurrentValueSubject` as the one
   Core transport, which is less churn but keeps two mechanisms (Observation
   for views, Combine for services).
3. **Where the container type lives.** Recommended: keep `DependencyContainer`
   in `EnsembleCore` during step 2 and move construction into the app target
   when step 4 splits the modules. Moving it now would mean exporting every
   concrete service type from Core twice in a row.
4. **The shared `NavigationCoordinator`.** The container holds one, and the
   Mac Profile and Downloads windows receive it, while main windows create
   their own per scene. Recommended: keep that split in step 2 and only
   document it; it is navigation behaviour, not composition.
5. **Line budget.** The plan expects the container files to go from about
   1,300 lines to a few hundred. Today the initializer and bootstrap
   builders for the 50 services are about 680 lines and the callback wiring
   about 180; 2f removes the wiring, but construction alone stays above the
   target. The view model factories (327) stay unless 2e makes views
   construct their own view models from injected services.
   Recommended: let views construct view models from injected services and
   delete the factory file, which is the native SwiftUI pattern.

## 5. Out of scope

- The watch app and `EnsembleWatchCore` (step 5).
- Engine callbacks inside playback (rebuilt in step 1).
- UI action closures passed as view parameters.
- System notifications (app lifecycle, audio session, `UserDefaults`,
  memory warnings). They are Apple's transport and stay.
- Module boundaries (step 4) and the source interface (step 3).

## 6. Verification

- Unit: existing view model and service tests keep passing after each
  sub-step; each 2f service gains one snapshot-transition table test.
- Simulator: a surface pass after 2b, 2c and 2e (every root tab, a detail
  push, Now Playing, settings, add-source sheet), and the Mac with two
  windows plus the Profile and Downloads windows after 2b.
- Device (owed to the backlog, not blocking): the external display scene on
  the iPhone after 2b, and App Shortcuts and Siri after 2b.
