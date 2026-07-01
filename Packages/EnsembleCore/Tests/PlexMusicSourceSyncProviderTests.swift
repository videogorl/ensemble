import XCTest
@testable import EnsembleCore

final class PlexMusicSourceSyncProviderTests: XCTestCase {
    func testIncrementalLibraryPreflightSkipsOnlyWhenSectionIsOlderThanQueryWindow() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldSkipIncrementalLibrarySync(
                sectionUpdatedAt: 99,
                queryTimestamp: 100
            )
        )
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldSkipIncrementalLibrarySync(
                sectionUpdatedAt: 100,
                queryTimestamp: 100
            )
        )
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldSkipIncrementalLibrarySync(
                sectionUpdatedAt: 101,
                queryTimestamp: 100
            )
        )
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldSkipIncrementalLibrarySync(
                sectionUpdatedAt: nil,
                queryTimestamp: 100
            )
        )
    }

    func testPlaylistOrphanCheckRunsWhenPlaylistsChanged() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 1,
                lastCheckedAt: Date().timeIntervalSince1970,
                now: Date()
            )
        )
    }

    func testPlaylistOrphanCheckSkipsRecentUnchangedCleanup() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 0,
                lastCheckedAt: 900,
                now: now,
                interval: 200
            )
        )
    }

    func testPlaylistOrphanCheckRunsWhenUnchangedCleanupIsStale() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldCheckPlaylistOrphans(
                changedPlaylistCount: 0,
                lastCheckedAt: 700,
                now: now,
                interval: 200
            )
        )
    }
}
