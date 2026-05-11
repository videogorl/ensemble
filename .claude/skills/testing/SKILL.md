---
name: testing
description: "Load before writing tests or after implementing a major feature. Test locations, what to test, mock patterns, async test patterns, commands to run tests, and the rule to run tests before committing."
---

# Ensemble Testing Guide

## Definition Of Done

For this project, "done" requires both automated tests and runtime verification:

- Run the affected Swift package tests after any non-trivial code change.
- For any user-visible change, bug fix, navigation change, playback fix, or workflow update, validate the affected flow in the iOS Simulator before marking the task done.
- Use the iOS Simulator MCP server for that runtime validation so the agent can drive the app directly instead of asking the user to click through the UI.
- If runtime verification is blocked by credentials, third-party service availability, or an environment limitation the agent cannot overcome, call out the blocker explicitly and do not present the task as finished.

Load `simulator-test` alongside this skill whenever the change needs runtime confirmation.

## When to Write Tests

**Required:**
- New services (business logic, sync, playback, repositories)
- New sync flows or incremental sync logic
- CoreData model changes (save/fetch/delete round-trips)
- Playlist mutation logic
- Any complex domain model logic (filtering, sorting, mapping)

**Not required:**
- Simple ViewModels that only pass data through
- Pure UI / SwiftUI views
- Trivial one-liners

**When adding a major architectural feature:** write at least one test per public method on any new service or repository before committing. This ensures future refactors don't silently break the feature.

---

## Run Tests Before Committing

**Always run the affected package's tests before committing after a non-trivial change:**

```bash
# Test the package you modified
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI

# Keep the Core warning budget at or below the current baseline
scripts/check_core_warning_budget.sh

# Capture repeatable before/after Instruments gates when changing SwiftUI
# observation, root chrome, Feed launch/refresh, or Downloads queue behavior
scripts/capture_performance_gate.sh --platform device \
  --device "Felicity’s iPhone 16 Pro" \
  --destination "id=00008140-00023030117B001C"

# Run all tests via Xcode (slower but comprehensive)
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

If tests fail, fix them before committing. Do not commit a broken test suite.

**Tests alone are not enough for UI-facing work.** After the relevant package tests pass, run simulator verification for the affected flow and confirm the observed behavior matches the intended result.

---

## Runtime Verification With The iOS Simulator MCP Server

Use the simulator MCP tools when you need to prove a change works in the running app:

- `open_simulator` to open Simulator
- `get_booted_sim_id` to target the current device
- `install_app` to install the built `.app`
- `launch_app` to start the app
- `ui_describe_all` to inspect the accessibility tree and locate controls
- `ui_tap`, `ui_type`, and `ui_swipe` to drive the UI
- `ui_view` and `screenshot` to visually confirm the current state

Typical expectations:

- Bug fixes: reproduce the old path if possible, apply the fix, then verify the corrected path in simulator.
- New UI: navigate to the new surface, exercise the key interactions, and confirm the expected labels/state.
- Playback/networking flows: combine simulator interaction with log capture from `simulator-test` so you have both UI and runtime evidence.

If the user asks for a feature and the agent cannot verify the visible result in simulator, the task is still incomplete.

---

## Test File Locations

Each package has a `Tests/` folder beside `Sources/`:

```
Packages/EnsembleAPI/Tests/PlexAPIClientTests.swift
Packages/EnsembleCore/Tests/PlaybackServiceTests.swift
Packages/EnsemblePersistence/Tests/LibraryRepositoryTests.swift
Packages/EnsembleUI/Tests/EnsembleUITests.swift
```

Add new test files to the appropriate `Tests/` folder. One file per major class/service is fine; group related tests in the same file using `// MARK:` sections.

---

## Basic Test Structure

```swift
import XCTest
@testable import EnsembleCore  // use @testable to access internal types

final class MyServiceTests: XCTestCase {

    // MARK: - My Feature

    func testSomethingHappens() throws {
        // Arrange
        let sut = MyService()

        // Act
        let result = sut.doSomething()

        // Assert
        XCTAssertEqual(result, expectedValue)
    }

    func testAsyncOperation() async throws {
        let sut = MyService()
        let result = try await sut.fetchSomething()
        XCTAssertFalse(result.isEmpty)
    }
}
```

---

## Mocking Dependencies (Protocol-Based)

Services use protocol-based dependencies — inject a mock in tests instead of the real implementation:

```swift
// Define a mock conforming to the protocol
private final class MockKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func save(_ value: String, forKey key: String) throws {
        storage[key] = value
    }
    func get(_ key: String) throws -> String? {
        storage[key]
    }
    func delete(_ key: String) throws {
        storage.removeValue(forKey: key)
    }
}

// Inject it
func testClientUsesInjectedKeychain() async throws {
    let keychain = MockKeychain()
    let client = PlexAPIClient(
        connection: PlexServerConnection(
            url: "https://example.com",
            token: "token123",
            identifier: "server",
            name: "Server"
        ),
        keychain: keychain
    )
    // ... test behavior
}
```

The same pattern applies to any protocol in the codebase:
- `KeychainServiceProtocol` → mock for API tests
- `LibraryRepositoryProtocol` → mock for ViewModel/service tests
- `PlaylistRepositoryProtocol` → mock for playlist mutation tests
- `HubRepositoryProtocol` → mock for HomeViewModel / hub tests; cover `HomeFeedCachedSnapshot` source cleanup, last-good preservation, and stale metadata in `HubRepositorySnapshotTests`
- `PlaylistRepositoryProtocol` → mock for playlist browse/detail stability; cover last-good PlaylistViewModel seeding, transient empty reload preservation, stale seed clearing when cache is truly empty, and playlist-detail track preservation during intermediate empty relationship reloads
- `SourceCacheCleanupService` / `CacheManager` → use in-memory CoreData plus real temporary download records to prove destructive cleanup removes library rows, offline targets, download records, downloaded files, and sidecar files without blocking the UI actor
- `BackgroundRefreshCoordinating` / `BackgroundRefreshCoordinator` → use closure seams to test app refresh, iOS 15 foreground fallback, cooldown, cancellation/error collection, and Feed/Siri sequencing without constructing the app container
- `OfflineDownloadBackgroundCoordinating` / `OfflineBackgroundExecutionCoordinator` → test background URLSession completion-handler lifecycle, iOS 26 continued-processing request/progress seams where injectable, macOS sleep/wake hooks, and service recovery sweeps that prevent stale `.downloading` records

When testing non-protocol concrete services (for example `SyncCoordinator` or `HomeViewModel`), prefer internal test seams (`...ForTesting` closures/helpers) over production-facing API changes.

---

## Testing CoreData (In-Memory Store)

Use an in-memory `CoreDataStack` to avoid touching the real database:

```swift
func testSaveAndFetchTrack() async throws {
    // Use an in-memory store — fast, isolated, no cleanup needed
    let stack = CoreDataStack(inMemory: true)
    let repo = LibraryRepository(context: stack.viewContext)

    // Save
    try await repo.saveTrack(makeFakeTrack())

    // Fetch
    let tracks = try await repo.fetchTracks(sourceIdentifier: "test-source")
    XCTAssertEqual(tracks.count, 1)
    XCTAssertEqual(tracks.first?.title, "Test Track")
}
```

Never use `CoreDataStack.shared` in tests — it writes to the real app database.

---

## Testing JSON Decoding (API Models)

Plex API model decoding is high-value to test because the server response shape can change:

```swift
func testPlexTrackDecoding() throws {
    let json = """
    {
        "ratingKey": "42",
        "title": "My Song",
        "parentTitle": "My Album",
        "grandparentTitle": "My Artist",
        "duration": 240000
    }
    """
    let track = try JSONDecoder().decode(PlexTrack.self, from: json.data(using: .utf8)!)
    XCTAssertEqual(track.ratingKey, "42")
    XCTAssertEqual(track.durationSeconds, 240.0)
}
```

Test for nil-safety: Plex often omits optional fields. Verify missing fields decode to `nil` rather than crashing:

```swift
func testPlexTrackDecodesWithMissingOptionals() throws {
    let json = """{ "ratingKey": "1", "title": "Minimal" }"""
    let track = try JSONDecoder().decode(PlexTrack.self, from: json.data(using: .utf8)!)
    XCTAssertNil(track.parentTitle)
    XCTAssertNil(track.duration)
}
```

---

## Testing Domain Model Logic

Domain model transformations (mapping, filtering, sorting) are pure functions — easy to test, high value:

```swift
func testFilterOptionsMatchesByGenre() {
    var filter = FilterOptions()
    filter.selectedGenreIds = ["rock"]

    let rockTrack = Track(id: "1", title: "Rock Song", genreIds: ["rock"])
    let jazzTrack = Track(id: "2", title: "Jazz Song", genreIds: ["jazz"])

    XCTAssertTrue(filter.matches(rockTrack))
    XCTAssertFalse(filter.matches(jazzTrack))
}
```

---

## What's Already Tested

| File | What it covers |
|------|---------------|
| `PlexAPIClientTests.swift` | `PlexTrack`/`PlexDevice` JSON decoding, DELETE request building |
| `ConnectionFailoverManagerTests.swift` | Local-first ordering, relay-last fallback, preferred fast path, fallback probing, connection health counters |
| `PlexResourcesSpecTests.swift` | Resources endpoint query/header contract (`includeHttps`, `includeRelay`, `includeIPv6`, Plex headers) |
| `PlexAPIClientFailoverPolicyTests.swift` | Failover triggers on transport failures only (not HTTP semantic/decoding failures) |
| `PlexAuthTokenLifecycleTests.swift` | JWT metadata parsing and expired-token detection |
| `PlaybackServiceTests.swift` | `Track.formattedDuration`, `RepeatMode` cycling |
| `NetworkMonitorTests.swift` | monitor restart/idempotency behavior and debounced state publishing |
| `SyncCoordinatorNetworkHealthTests.swift` | reconnect/interface-switch triggers, cooldown/staleness gating, offline handling |
| `ServerHealthCheckerClassificationTests.swift` | failure taxonomy classification (`localOnlyReachable`, `tlsPolicyBlocked`, etc.) |
| `SettingsManagerConnectionPolicyTests.swift` | persisted insecure-policy default + round-trip persistence |
| `AccountManagerAuthPolicyTests.swift` | auth migration cutover and expired-account pruning |
| `HomeViewModelRefreshPolicyTests.swift` | Feed visibility/cadence refresh policy, coalescing, 10-minute automatic refresh gating, manual-refresh bypass |
| `LibraryVisibilityProfileTests.swift` | visibility profile persistence + source-level filtering seams (without changing sync enablement) |
| `LibraryRepositoryTests.swift` | `CoreDataStack` initialization (minimal — expand as needed) |

When adding tests, check this list first to avoid duplicating coverage.

---

## What Needs More Coverage (Priority Areas)

These are under-tested and worth expanding as features grow:

- `SyncCoordinator` — incremental sync logic, timestamp filtering
- `PlaylistRepository` — CRUD round-trips, smart playlist read-only guard
- `FilterOptions` — matching and sorting logic
- `ModelMappers` — `CD*` ↔ domain model conversions
- `PlexMusicSourceSyncProvider` — incremental sync since-timestamp logic

---

## Spec-Parity Network Test Pattern

When touching endpoint discovery/routing/auth lifecycle:

1. Add an API-level contract test for request composition (query parameters + required Plex headers).
2. Add failover-policy tests that separate transport errors from HTTP semantic failures.
3. Add endpoint-ordering tests that validate local/direct preference and relay-last fallback.
4. Add Core-level tests for failure classification and user-facing policy state persistence.
5. Add auth lifecycle tests for migration and token expiry enforcement.

Run both:

```bash
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
```
