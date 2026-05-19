@testable import EnsembleCore
import XCTest

@MainActor
final class LibraryItemInfoViewModelTests: XCTestCase {
    func testPersistedTrackDurationConvertsMillisecondsToSeconds() {
        XCTAssertEqual(
            LibraryItemInfoViewModel.persistedTrackDurationSeconds(210_000),
            210,
            accuracy: 0.001
        )
    }
}
