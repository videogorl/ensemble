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

- **Git commits:** Follow the commit discipline in `CLAUDE.md`.
- **Code comments:** Explain non-obvious design decisions and complex logic. Do not narrate obvious Swift syntax.

Keep the following documents in sync when making changes:

| What changed | What to update |
|---|---|
| New service, subsystem, or major pattern | `architecture` skill |
| New file added anywhere | `project-structure` skill |
| New recipe, pattern, or call convention | `common-tasks` skill |
| New UI component, navigation pattern, or visual rule | `ui-conventions` skill |
| New coding rule, naming convention, or mandatory practice | `code-style` skill (this file) |
| New active bug, limitation, or tech debt | `known-issues` skill |
| User-visible feature or status change | `README.md` |
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
- **NEVER wrap `logger.*` calls in `#if DEBUG`.** `os.Logger` works in release and TestFlight builds — it is the *only* way to capture logs from a device or beta tester. Guarding with `#if DEBUG` silently strips the call from the builds where you need it most. Only use `#if DEBUG` if the surrounding code (not just the log line) must be absent from release.
- Treat logs as production data: use privacy-safe interpolation and avoid leaking secrets/tokens. Any diagnostic that includes URLs, query strings, headers, auth payloads, or token-like values must route through `AppLogger` / `EnsembleLogger` so redaction runs before unified-log and persistent-log writes.
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

Use the `testing` skill as the canonical verification policy. For Swift code, the default expectation is affected package tests after non-trivial logic changes, simulator validation for user-visible changes, and `scripts/check_core_warning_budget.sh` for `EnsembleCore` refactors.

The app is in active beta testing. Account for edge cases in CoreData models, validate inputs before saving, and handle nil/missing Plex fields defensively.

## MVVM Pattern

- All ViewModels: `@MainActor class ... ObservableObject`
- Inject dependencies via initializer
- Add factory method to `DependencyContainer`
- Use Combine publishers for reactive updates

## Performance Patterns (iOS 15)

These patterns are mandatory for views and ViewModels targeting A9 devices (2GB RAM). SwiftUI observation cascades are the #1 performance risk.

### Observation Extraction (`@ObservedObject` -> `let` + `@State` + `.onReceive`)

In large, persistent views (tabs, lists with 100+ items), never use `@ObservedObject` for singletons that publish frequently or broadly (NowPlayingViewModel, SyncCoordinator, OfflineDownloadService, PinManager). Instead:

```swift
let viewModel: SomeViewModel  // not @ObservedObject
@State private var specificValue: ValueType = initialValue

.onReceive(viewModel.$specificPublishedProperty) { newValue in
    if newValue != specificValue { specificValue = newValue }
}
```

For Now Playing surfaces, prefer the focused projections (`playbackProjection`, `queueProjection`, `artworkProjection`, `lyricsProjection`, `ratingProjection`) or `TrackActionDispatching` over observing the full `NowPlayingViewModel`. Keep the full model only where the view truly needs cross-cutting state or mutation methods.

For detail menus that only need the pin state for one item, store the relevant `Bool` in local `@State` and refresh it from `PinManager.objectWillChange` with a cached comparison. Do not observe the full `PinManager` in large detail surfaces just to render one Pin/Unpin label.

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

### Never Observe `UserDefaults.didChangeNotification` for a Specific Key

`UserDefaults.didChangeNotification` fires on ANY key write — not just the key you care about. PlaybackService writes `currentTime`, `queue`, etc. frequently, so an observer for a visualizer toggle fires 94+ times per session with only 1 real change. Instead, cache the last-known value and compare before creating a Task:

```swift
private var lastKnownSetting = UserDefaults.standard.bool(forKey: "mySetting")

// In observer:
let current = UserDefaults.standard.bool(forKey: "mySetting")
guard current != self?.lastKnownSetting else { return }
self?.lastKnownSetting = current
// ... proceed with actual change handling
```

Alternatively, use KVO on the specific key if you need change-only notifications.

### Guard `@Published` Dictionary Writes with `!= oldValue`

Dictionary mutations on `@Published` properties always publish Combine changes, even when the value being assigned is identical. `.removeDuplicates()` on subscribers doesn't help because dictionary value semantics publish on any mutation. This causes spurious SwiftUI re-renders downstream. Always guard:

```swift
// BAD: publishes every time, even if state hasn't changed
serverStates[serverKey] = state

// GOOD: only publishes on actual state transitions
if serverStates[serverKey] != state {
    serverStates[serverKey] = state
}
```

### Use `CurrentValueSubject` for High-Frequency Properties in Multi-Subscriber ViewModels

Never use `@Published` for properties updated at >2Hz in ViewModels with many subscribers. Every `@Published` assignment fires `objectWillChange` for ALL `@ObservedObject` subscribers — even cards/views that don't read the changed property. Use `CurrentValueSubject` with computed property getters and explicit `AnyPublisher` accessors. Consuming views subscribe via `.onReceive` with local `@State`:

```swift
// In ViewModel:
private let _highFreqValue = CurrentValueSubject<[Double], Never>([])
public var highFreqValue: [Double] {
    get { _highFreqValue.value }
    set { _highFreqValue.send(newValue) }
}
public var highFreqValuePublisher: AnyPublisher<[Double], Never> {
    _highFreqValue.eraseToAnyPublisher()
}

// In View:
@State private var highFreqValue: [Double] = []
.onReceive(viewModel.highFreqValuePublisher) { value in
    highFreqValue = value
}
```

Proven pattern from `PlaybackService.frequencyBands` and `NowPlayingViewModel.waveformHeights`/lyrics properties.

### Keep Per-Frame Visualizer State Out Of SwiftUI Observation

For `Canvas`, `TimelineView`, waveform, FFT, or other render surfaces updated every frame, do not store live render buffers in SwiftUI `@State`, `@Published`, or other observed properties. Even if the view is visually isolated, those writes can invalidate large root view trees 15-30 times per second and tank shell responsiveness.

Instead:
- Keep per-frame render state in a stable, non-publishing render model (`@StateObject` with no `@Published`, plain reference storage, or another non-observed cache).
- Feed analyzer/timer samples into that render model.
- Let `TimelineView` redraw on its own cadence and read the latest snapshot during rendering.

Use SwiftUI-observed state only for low-frequency lifecycle changes such as visibility, playback mode, or presentation state.

### Throttle Background CPU Work on ≤2-Core Devices

FFT analysis, image processing, and other CPU-heavy optional features should check `ProcessInfo.processInfo.processorCount` and use `.utility` or `.background` priority with yield pauses on dual-core devices (A9/A10). On quad-core+ devices, higher priorities are acceptable:

```swift
let isLowCoreDevice = ProcessInfo.processInfo.processorCount <= 2
let throttle = isInstrumentalModeActive || isLowCoreDevice
let priority: TaskPriority = isLowCoreDevice ? .utility : .userInitiated
```

### Separate Lifecycle Pauses from User-Initiated Pauses

When stopping CPU work on app background (e.g., display timers, analysis queues), use dedicated lifecycle methods rather than reusing the same flag as user-initiated pauses. Sharing state causes incorrect resume behavior when both overlap.

```swift
// BAD — pauseUpdates() is also called by PlaybackService on music pause.
// When app foregrounds: resumeUpdates() restarts the timer while music is still paused.
case .background: audioAnalyzer.pauseUpdates()
case .active:     audioAnalyzer.resumeUpdates()  // wrong if user paused music

// GOOD — separate method preserves isPaused flag, restarts only if music was playing
case .background: audioAnalyzer.enterBackground()   // stops timer, doesn't touch isPaused
case .active:     audioAnalyzer.exitBackground()    // restarts timer only if !isPaused
```

Pattern proven by `AudioAnalyzer.enterBackground()`/`exitBackground()` and `SidecarAnalysisQueue.suspend()`/`resume()` — see Phase 7 entry in `known-issues` skill.

### Never Call `ProcessInfo.processorCount` in Rendering or Animation Hot Paths

`ProcessInfo.processInfo.processorCount` is not a cheap syscall. Store it **once** as a `let` constant at init time for any view or service that makes rendering decisions per-frame. Never call it inside `drawAurora()`, `Canvas {}` closures, `TimelineView` callbacks, or any function that runs at >1Hz:

```swift
// GOOD — stored once in init, checked at 15-30fps with zero syscall overhead
private let isLowCoreDevice: Bool

init(...) {
    self.isLowCoreDevice = ProcessInfo.processInfo.processorCount <= 2
}

// BAD — syscall on every frame (15-30fps = thousands of calls per minute)
private var isLowCoreDevice: Bool {
    ProcessInfo.processInfo.processorCount <= 2
}
```
