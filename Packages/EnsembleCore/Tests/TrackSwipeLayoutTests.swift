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

    func testSanitizeAllowsSameActionOnOppositeEdges() {
        var layout = TrackSwipeLayout(
            leading: [.playNext, .playLast],
            trailing: [.playNext, .favoriteToggle]
        )

        layout.sanitize()

        XCTAssertEqual(layout.leading, [.playNext, .playLast])
        XCTAssertEqual(layout.trailing, [.playNext, .favoriteToggle])
    }

    func testSanitizeRemovesDuplicatesWithinEachEdge() {
        var layout = TrackSwipeLayout(
            leading: [.playNext, .playNext],
            trailing: [.favoriteToggle, .favoriteToggle]
        )

        layout.sanitize()

        XCTAssertEqual(layout.leading, [.playNext, nil])
        XCTAssertEqual(layout.trailing, [.favoriteToggle, nil])
    }

    func testSanitizeRestoresDefaultsWhenAllSlotsEmpty() {
        var layout = TrackSwipeLayout(
            leading: [nil, nil],
            trailing: [nil, nil]
        )

        layout.sanitize()

        XCTAssertEqual(layout.leading, [.playNext, .playLast])
        XCTAssertEqual(layout.trailing, [.favoriteToggle, .addToPlaylist])
    }
}
