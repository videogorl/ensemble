---
name: code-style
description: "Load before writing any Swift code. Contains mandatory rules that override defaults: structured Logger usage (no print), edge case handling required (active beta), memory targets, MVVM pattern, and debug logging conventions."
---

# Ensemble Code Style & Development Guidelines

## Comment Guidelines

- **"What" not "how":** Comment on what each logical section does, not how Swift works
- **Class/function headers:** Include doc comments (`///`) for all public types and methods
- **Complex logic:** Explain non-obvious algorithms, formulas, or architectural decisions
- **Avoid over-commenting:** Self-documenting code is preferred; don't comment the obvious
- Leave comments above classes and other elements so both the user and the agent understand what's going on

## Change Documentation

- **Git commits:** Commit after each logical step with descriptive messages; always commit before waiting for testing
- **Code comments:** Leave comments in code so future developers (including AI assistants) understand the design

Keep the following documents in sync when making changes:

| What changed | What to update |
|---|---|
| New service, subsystem, or major pattern | `architecture` skill + CLAUDE.md Recent Major Changes |
| New file added anywhere | `project-structure` skill |
| New recipe, pattern, or call convention | `common-tasks` skill |
| New UI component, navigation pattern, or visual rule | `ui-conventions` skill |
| New coding rule, naming convention, or mandatory practice | `code-style` skill (this file) |
| New known bug, limitation, or tech debt | `known-issues` skill |
| Feature shipped or roadmap item completed | `README.md` |
| New test patterns or changes to what needs testing | `testing` skill |
| Anything that changes how agents should work in this repo | `CLAUDE.md` |

## Code Style

- Use clear, descriptive variable/function names
- Use Xcode's MCP server to inform best practices
- Don't over-comment -- focus on complex logic and architectural decisions
- Do not use emojis (except in debugging)

## Debug Logging

Use structured `os.Logger` logging, not `print()`.

Rules:
- Use package/app logger helpers (`AppLogger` / `EnsembleLogger`) with category-specific logger instances.
- Use log levels intentionally: `.debug` for verbose traces, `.info` for key state transitions, `.error` for recoverable failures, `.fault` for critical failures.
- Keep verbose diagnostic logging debug-only when it could be noisy.
- Treat logs as production data: use privacy-safe interpolation and avoid leaking secrets/tokens.
- `print(` is disallowed in production codepaths. Keep repository-wide `print(` count at zero for Swift sources.

## Preserve Existing Functionality

- **Don't remove features** when refactoring unless explicitly directed
- **Backward compatibility:** Maintain iOS 15 support; use feature detection for newer OS features
- **User preferences:** Respect user settings (accent colors, enabled tabs, filter preferences)
- Build on existing code; extend rather than replace working components
- Reuse established patterns (DetailLoader, HubRepository, FilterOptions)

## Memory & Performance Targets

- **Target:** iOS 15+ devices with 2GB RAM (iPhone 6s, iPad Air 2)
- Fetch in batches from CoreData
- Use `@FetchRequest` limits and offsets for large lists
- Lazy-load images with Nuke
- Background context for heavy CoreData operations (`CoreDataStack.performBackgroundTask`)
- Use `LazyVGrid`, `LazyVStack` for list views
- Use `Task.detached` for non-blocking background work
- Two-tier image caching (filesystem + Nuke in-memory) with 100MB disk cache limit

## Debouncing Standards

- **Network monitor:** 1s debouncing
- **Home screen loading:** 2s debouncing
- **App launch:** Network monitor starts with 500ms delay

## Testing Policy

- Unit tests for business logic (services, repositories)
- Integration tests for sync flows
- Not required for simple ViewModels or UI-only code
- App is in active beta testing — account for edge cases in CoreData model
- Validate inputs before saving to CoreData; handle nil/missing fields defensively

## MVVM Pattern

- All ViewModels: `@MainActor class ... ObservableObject`
- Inject dependencies via initializer
- Add factory method to `DependencyContainer`
- Use Combine publishers for reactive updates

## Performance Patterns (iOS 15)

These patterns are mandatory for views and ViewModels targeting A9 devices (2GB RAM). SwiftUI observation cascades are the #1 performance risk.

### Observation Extraction (`@ObservedObject` -> `let` + `@State` + `.onReceive`)

In large, persistent views (tabs, lists with 100+ items), never use `@ObservedObject` for singletons that publish frequently (NowPlayingViewModel, SyncCoordinator, OfflineDownloadService). Instead:

```swift
let viewModel: SomeViewModel  // not @ObservedObject
@State private var specificValue: ValueType = initialValue

.onReceive(viewModel.$specificPublishedProperty) { newValue in
    if newValue != specificValue { specificValue = newValue }
}
```

**When NOT to apply:** Short-lived modals with small view trees (<20 rows, <5s lifetime). The PlaylistPickerSheet revert (5 workaround commits -> full revert) proved the complexity cost exceeds performance benefit for these cases.

### Combine Pipeline Caching

Any property that is (a) accessed in body, (b) requires O(n) or O(n log n) work, and (c) recomputes on every body eval must be `@Published` with a Combine pipeline:

```swift
@Published var filteredItems: [Item] = []

Publishers.CombineLatest($items, $filterOption)
    .debounce(for: .milliseconds(100), scheduler: backgroundQueue)
    .map { items, option in Self.filterAndSort(items, option: option) }
    .removeDuplicates { Self.idsEqual($0, $1) }
    .receive(on: DispatchQueue.main)
    .assign(to: &$filteredItems)
```

Key details: debounce 100-150ms, compute on background queue, `.removeDuplicates` to avoid no-op publishes.

### Guard `@Published` Assignments

Before assigning to a `@Published` property, check if the value actually changed. Every assignment fires `objectWillChange` regardless:

```swift
private static func idsEqual<T: Identifiable>(_ a: [T], _ b: [T]) -> Bool where T.ID == String {
    guard a.count == b.count else { return false }
    return zip(a, b).allSatisfy { $0.id == $1.id }
}

// Guard the assignment
if !Self.idsEqual(artists, newArtists) { artists = newArtists }
```

### Pre-Compute Sort Keys

For string-based sorts on collections, cache the sort key once per element:

```swift
private static func sortByCachedKey<T: Identifiable>(
    _ items: [T], keyExtractor: (T) -> String, ascending: Bool
) -> [T] where T.ID == String {
    let keyed = items.map { ($0, keyExtractor($0)) }
    return keyed.sorted {
        let result = $0.1.localizedStandardCompare($1.1)
        if result == .orderedSame { return $0.0.id < $1.0.id }  // stable tiebreaker
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }.map { $0.0 }
}
```

### Custom Equatable for Domain Models

Models with internal-only fields (cache keys, dates, source composite keys) should implement custom `==` comparing only UI-visible fields. This dramatically reduces SwiftUI diffing cost:

- Album: compare id, title, artistName, albumArtist, year, trackCount, thumbPath, rating — skip internal fields
- Playlist: compare id, title, trackCount, duration, compositePath, isSmart — skip internal fields

Always keep `hash(into:)` consistent — hash only `id`.

### Task Priority for Background Work

Downloads and FFT analysis should use `.utility` priority. Guard CPU-heavy optional features (visualizer) behind their enable flag to prevent starvation on dual-core devices.

### CoreData Prefetching

When fetching entities that will have relationships accessed during mapping, set `relationshipKeyPathsForPrefetching` to avoid fault-firing cascades.

### Batch I/O Over Per-Item Calls

For operations like checking file existence across 1000+ items, pre-compute results in bulk (`FileManager.contentsOfDirectory` -> `Set<String>`) and pass the set to per-item initializers. Never call `FileManager.fileExists` in a loop.
