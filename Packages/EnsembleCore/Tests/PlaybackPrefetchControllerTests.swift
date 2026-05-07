import XCTest
@testable import EnsembleCore

final class PlaybackPrefetchControllerTests: XCTestCase {
    func testUpcomingQueueIndicesStopsAtQueueEndWhenRepeatIsOff() {
        let controller = PlaybackPrefetchController()

        let indices = controller.upcomingQueueIndices(
            queueCount: 4,
            currentQueueIndex: 2,
            repeatMode: .off,
            depth: 3
        )

        XCTAssertEqual(indices, [3])
    }

    func testUpcomingQueueIndicesWrapsWhenRepeatAllIsEnabled() {
        let controller = PlaybackPrefetchController()

        let indices = controller.upcomingQueueIndices(
            queueCount: 4,
            currentQueueIndex: 2,
            repeatMode: .all,
            depth: 3
        )

        XCTAssertEqual(indices, [3, 0, 1])
    }

    func testUpcomingQueueIndicesReturnsCurrentIndexForRepeatOne() {
        let controller = PlaybackPrefetchController()

        let indices = controller.upcomingQueueIndices(
            queueCount: 4,
            currentQueueIndex: 2,
            repeatMode: .one,
            depth: 3
        )

        XCTAssertEqual(indices, [2])
    }

    func testPrefetchedTrackIsNotScheduledAfterItBecomesCurrent() {
        XCTAssertFalse(
            PlaybackPrefetchController.shouldSchedulePrefetchedTrack(
                prefetchedTrackID: "track-2",
                currentTrackID: "track-2",
                nextUpcomingTrackID: "track-3"
            )
        )
    }

    func testPrefetchedTrackIsNotScheduledWhenUpcomingQueueChanges() {
        XCTAssertFalse(
            PlaybackPrefetchController.shouldSchedulePrefetchedTrack(
                prefetchedTrackID: "track-2",
                currentTrackID: "track-1",
                nextUpcomingTrackID: "track-3"
            )
        )
    }

    func testPrefetchedTrackSchedulesOnlyWhenStillNextUpcoming() {
        XCTAssertTrue(
            PlaybackPrefetchController.shouldSchedulePrefetchedTrack(
                prefetchedTrackID: "track-2",
                currentTrackID: "track-1",
                nextUpcomingTrackID: "track-2"
            )
        )
    }
}
