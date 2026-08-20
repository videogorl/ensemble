import XCTest
@testable import EnsembleCore

final class PlaybackStartupCoordinatorTests: XCTestCase {
    func testRestoreDecisionSkipsWhenPlaybackAlreadyActive() {
        let coordinator = PlaybackStartupCoordinator()
        let snapshot = PlaybackQueueSnapshot(
            queue: [QueueItem(track: makeTrack(id: "track-1"))],
            history: [],
            currentIndex: 0,
            currentTime: 42
        )

        let decision = coordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: makeTrack(id: "track-1"),
            playbackState: .playing,
            existingQueueCount: 1,
            isShuffleEnabled: false,
            serverReady: true
        )

        XCTAssertNil(decision)
    }

    func testRestoreDecisionRequestsImmediatePrebufferForLocalTrack() {
        let coordinator = PlaybackStartupCoordinator()
        let localTrack = makeTrack(id: "track-1", localFilePath: "/tmp/local.mp3")
        let snapshot = PlaybackQueueSnapshot(
            queue: [QueueItem(track: localTrack)],
            history: [],
            currentIndex: 0,
            currentTime: 88
        )

        let decision = coordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: localTrack,
            playbackState: .stopped,
            existingQueueCount: 0,
            isShuffleEnabled: true,
            serverReady: false
        )

        XCTAssertEqual(decision?.prebufferMode, .immediateLocal)
        XCTAssertEqual(decision?.restoredTime, 88)
        XCTAssertEqual(decision?.shuffleEnabled, true)
    }

    func testRestoreDecisionRequestsDeferredPrebufferForStreamingTrackWhenServerReady() {
        let coordinator = PlaybackStartupCoordinator()
        let track = makeTrack(id: "track-1")
        let snapshot = PlaybackQueueSnapshot(
            queue: [QueueItem(track: track)],
            history: [],
            currentIndex: 0,
            currentTime: 12
        )

        let decision = coordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: track,
            playbackState: .stopped,
            existingQueueCount: 0,
            isShuffleEnabled: false,
            serverReady: true
        )

        XCTAssertEqual(decision?.prebufferMode, .deferredAfterDelay)
    }

    func testRestoreDecisionWaitsForHealthCheckWhenStreamingServerNotReady() {
        let coordinator = PlaybackStartupCoordinator()
        let track = makeTrack(id: "track-1")
        let snapshot = PlaybackQueueSnapshot(
            queue: [QueueItem(track: track)],
            history: [],
            currentIndex: 0,
            currentTime: 12
        )

        let decision = coordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: track,
            playbackState: .stopped,
            existingQueueCount: 0,
            isShuffleEnabled: false,
            serverReady: false
        )

        XCTAssertEqual(decision?.prebufferMode, .waitForHealthCheck)
    }

    func testRestoreDecisionDoesNotPrebufferAppleMusicTrack() {
        let coordinator = PlaybackStartupCoordinator()
        let track = makeTrack(
            id: "apple-track",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let snapshot = PlaybackQueueSnapshot(
            queue: [QueueItem(track: track)],
            history: [],
            currentIndex: 0,
            currentTime: 12
        )

        let decision = coordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: track,
            playbackState: .stopped,
            existingQueueCount: 0,
            isShuffleEnabled: false,
            serverReady: true
        )

        XCTAssertEqual(decision?.prebufferMode, PlaybackStartupPrebufferMode.none)
    }

    private func makeTrack(
        id: String,
        localFilePath: String? = nil,
        sourceCompositeKey: String? = nil
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            duration: 180,
            localFilePath: localFilePath,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
