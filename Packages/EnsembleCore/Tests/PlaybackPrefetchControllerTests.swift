@testable import EnsembleCore
import XCTest

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

    func testGaplessSchedulingWaitsUntilLeadTime() {
        XCTAssertFalse(
            PlaybackPrefetchController.shouldScheduleGaplessNow(
                currentTime: 30,
                duration: 240,
                playbackState: .playing
            )
        )
    }

    func testGaplessSchedulingStartsNearTrackEnd() {
        XCTAssertTrue(
            PlaybackPrefetchController.shouldScheduleGaplessNow(
                currentTime: 225,
                duration: 240,
                playbackState: .playing
            )
        )
    }

    func testGaplessSchedulingDoesNotRunWhilePaused() {
        XCTAssertFalse(
            PlaybackPrefetchController.shouldScheduleGaplessNow(
                currentTime: 225,
                duration: 240,
                playbackState: .paused
            )
        )
    }

    func testScheduledTracksStayValidWhenQueueAppendLeavesNextTrackUnchanged() {
        let controller = PlaybackPrefetchController()
        let queue = makeQueue(["current", "next", "later", "appended"])

        XCTAssertFalse(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: [queue[1].track.playbackIdentity],
                queue: queue,
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
    }

    func testScheduledTracksInvalidateWhenPlayNextChangesImmediateUpcomingTrack() {
        let controller = PlaybackPrefetchController()
        let queue = makeQueue(["current", "new-next", "next", "later"])

        XCTAssertTrue(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: [makeTrack(id: "next").playbackIdentity],
                queue: queue,
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
    }

    func testScheduledTrackValidationDistinguishesDuplicateRatingKeys() {
        let controller = PlaybackPrefetchController()
        let firstSourceTrack = makeTrack(id: "7551", sourceCompositeKey: "plex:felicity:server:music")
        let secondSourceTrack = makeTrack(id: "7551", sourceCompositeKey: "plex:felicity-test:server:music")
        let queue = [
            QueueItem(track: makeTrack(id: "current")),
            QueueItem(track: firstSourceTrack),
            QueueItem(track: secondSourceTrack),
        ]

        XCTAssertFalse(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: [firstSourceTrack.playbackIdentity],
                queue: queue,
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
        XCTAssertTrue(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: [secondSourceTrack.playbackIdentity],
                queue: queue,
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
    }

    func testScheduledTracksInvalidateWhenQueueNoLongerHasUpcomingTrack() {
        let controller = PlaybackPrefetchController()
        let queue = makeQueue(["current"])

        XCTAssertTrue(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: ["next"],
                queue: queue,
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
    }

    func testEmptyScheduleDoesNotRequireInvalidation() {
        let controller = PlaybackPrefetchController()

        XCTAssertFalse(
            controller.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: [],
                queue: makeQueue(["current", "next"]),
                currentQueueIndex: 0,
                repeatMode: .off
            )
        )
    }

    private func makeQueue(_ ids: [String]) -> [QueueItem] {
        ids.map { QueueItem(track: makeTrack(id: $0)) }
    }

    private func makeTrack(
        id: String,
        sourceCompositeKey: String? = "plex:account:server:library"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
