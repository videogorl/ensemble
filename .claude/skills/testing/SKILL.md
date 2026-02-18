---
name: testing
description: "Load before writing tests or after implementing a major feature. Test locations, what to test, mock patterns, async test patterns, commands to run tests, and the rule to run tests before committing."
---

# Ensemble Testing Guide

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

# Run all tests via Xcode (slower but comprehensive)
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

If tests fail, fix them before committing. Do not commit a broken test suite.

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
- `HubRepositoryProtocol` → mock for HomeViewModel / hub tests

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
| `PlaybackServiceTests.swift` | `Track.formattedDuration`, `RepeatMode` cycling |
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
