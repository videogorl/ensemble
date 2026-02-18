import XCTest
@testable import EnsembleCore

final class TrackSwipeLayoutTests: XCTestCase {
    func testDefaultLayoutMatchesProductDecision() {
        let layout = TrackSwipeLayout.default

        XCTAssertEqual(layout.leading, [.playNext, .playLast])
        XCTAssertEqual(layout.trailing, [.favoriteToggle, .addToPlaylist])
    }

    func testSanitizeTrimsToTwoSlotsPerEdge() {
        var layout = TrackSwipeLayout(
            leading: [.playNext, .playLast, .favoriteToggle],
            trailing: [.addToPlaylist, .favoriteToggle, .playNext]
        )

        layout.sanitize()

        XCTAssertEqual(layout.leading.count, 2)
        XCTAssertEqual(layout.trailing.count, 2)
    }

    func testSanitizeRemovesDuplicatesAcrossEdges() {
        var layout = TrackSwipeLayout(
            leading: [.playNext, .playLast],
            trailing: [.playNext, .favoriteToggle]
        )

        layout.sanitize()

        XCTAssertEqual(layout.leading, [.playNext, .playLast])
        XCTAssertEqual(layout.trailing, [nil, .favoriteToggle])
    }
}
