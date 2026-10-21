import Observation

/// Scenes inject the app's one container with `.environment(container)`, and
/// views read it with `@Environment(DependencyContainer.self)`. There is no
/// default: a view outside an injected tree traps instead of reaching a global.
extension DependencyContainer: Observable {}
