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
}
