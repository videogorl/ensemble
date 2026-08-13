# Views And Navigation Recipes

## ViewModel

1. Place it in `EnsembleCore/Sources/ViewModels`.
2. Use `@MainActor` + `ObservableObject` with initializer-injected dependencies.
3. Add a `DependencyContainer` factory only when callers need construction.
4. Keep persistence/network work in existing repositories/services.

## SwiftUI View

1. Place screens/components under the matching `EnsembleUI` feature folder.
2. Reuse the neighboring screen's dependency injection and shared scaffold.
3. Route through scene-local typed `NavigationCoordinator` destinations.
4. Use shared state, action, and list/detail owners before adding local helpers.

## Detail Loading

When the caller has a concrete model, push the concrete detail. For ID-only hub
or deep-link input, follow the existing album/artist/playlist loader: render
cached data first, fetch through the repository in a cancellable `.task`, and
show compact loading/error/not-found states without replacing useful content.

## Large Screens And Now Playing

Keep compact navigation as the fallback. Put browse selection/detail inside the
existing root split host and keep selection in the stable parent. New Now
Playing panels go through `NowPlayingPanelCard` / `NowPlayingDetailPanel`; do not
add a platform-specific panel switch to every layout.
