import XCTest
@testable import EnsembleCore

final class PlexMusicSourceSyncProviderTests: XCTestCase {
    private struct IncrementalItem: Equatable {
        let ratingKey: String
        let updatedAt: Int?
        let marker: String
        let ratingChanged: Bool
    }

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

    func testIncrementalChangeSelectionDeduplicatesAndLetsUpdatedItemWin() {
        let added = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "added", ratingChanged: false)
        let updated = IncrementalItem(ratingKey: "1", updatedAt: 101, marker: "updated", ratingChanged: false)

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [added],
            updated: [updated],
            existingTimestamps: ["1": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.uniqueCount, 1)
        XCTAssertEqual(changes.changedItems, [updated])
    }

    func testIncrementalChangeSelectionSkipsUnchangedAndMissingServerTimestampWhenLocalExists() {
        let unchanged = IncrementalItem(ratingKey: "1", updatedAt: 100, marker: "unchanged", ratingChanged: false)
        let missingTimestampExisting = IncrementalItem(
            ratingKey: "2",
            updatedAt: nil,
            marker: "missing-existing",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [unchanged, missingTimestampExisting],
            updated: [],
            existingTimestamps: [
                "1": Date(timeIntervalSince1970: 100),
                "2": Date(timeIntervalSince1970: 50)
            ],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertTrue(changes.changedItems.isEmpty)
    }

    func testIncrementalChangeSelectionSyncsMissingTimestampWhenLocalIsAbsent() {
        let missingTimestampNew = IncrementalItem(
            ratingKey: "new",
            updatedAt: nil,
            marker: "missing-new",
            ratingChanged: false
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [missingTimestampNew],
            updated: [],
            existingTimestamps: [:],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt }
        )

        XCTAssertEqual(changes.changedItems, [missingTimestampNew])
    }

    func testIncrementalChangeSelectionAllowsAdditionalChangePredicate() {
        let ratingOnly = IncrementalItem(
            ratingKey: "track",
            updatedAt: 100,
            marker: "rating",
            ratingChanged: true
        )

        let changes = PlexMusicSourceSyncProvider.deduplicatedChangedItems(
            added: [],
            updated: [ratingOnly],
            existingTimestamps: ["track": Date(timeIntervalSince1970: 100)],
            ratingKey: { $0.ratingKey },
            updatedAt: { $0.updatedAt },
            hasAdditionalChange: { $0.ratingChanged }
        )

        XCTAssertEqual(changes.changedItems, [ratingOnly])
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

    func testPlaylistTrackSyncSkipsUnchangedPlaylist() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesChangedPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 101,
                existingModifiedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testPlaylistTrackSyncFetchesNewPlaylist() {
        XCTAssertTrue(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: 100,
                existingModifiedAt: nil
            )
        )
    }

    func testPlaylistTrackSyncSkipsExistingPlaylistWhenServerUpdatedAtIsMissing() {
        XCTAssertFalse(
            PlexMusicSourceSyncProvider.shouldFetchPlaylistTracks(
                serverUpdatedAt: nil,
                existingModifiedAt: Date.distantPast
            )
        )
    }
}
