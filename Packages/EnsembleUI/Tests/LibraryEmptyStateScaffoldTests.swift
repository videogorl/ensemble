import XCTest
@testable import EnsembleUI

final class LibraryEmptyStateScaffoldTests: XCTestCase {
    func testRecoveryPrioritizesCloudRestoreSourcesSyncAndDisabledLibraries() {
        XCTAssertEqual(
            EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: true,
                hasAnySources: false,
                isSyncing: true,
                hasEnabledLibraries: false,
                emptyMessage: "Empty"
            ),
            .restoringCloudSources
        )

        XCTAssertEqual(
            EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: false,
                hasAnySources: false,
                isSyncing: true,
                hasEnabledLibraries: false,
                emptyMessage: "Empty"
            ),
            .noSources
        )

        XCTAssertEqual(
            EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: false,
                hasAnySources: true,
                isSyncing: true,
                hasEnabledLibraries: false,
                emptyMessage: "Empty"
            ),
            .syncing
        )

        XCTAssertEqual(
            EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: false,
                hasAnySources: true,
                isSyncing: false,
                hasEnabledLibraries: false,
                emptyMessage: "Empty"
            ),
            .noEnabledLibraries
        )
    }

    func testRecoveryUsesEmptyMessageWhenLibraryStateIsReady() {
        XCTAssertEqual(
            EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: false,
                hasAnySources: true,
                isSyncing: false,
                hasEnabledLibraries: true,
                emptyMessage: "Nothing here"
            ),
            .empty(message: "Nothing here")
        )
    }
}
