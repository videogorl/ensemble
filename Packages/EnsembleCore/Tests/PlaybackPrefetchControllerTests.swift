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

    func testUpcomingQueueIndicesDoesNotPrefetchForRepeatOne() {
        let controller = PlaybackPrefetchController()

        let indices = controller.upcomingQueueIndices(
            queueCount: 4,
            currentQueueIndex: 2,
            repeatMode: .one,
            depth: 3
        )

        XCTAssertEqual(indices, [])
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

    func testSmartMixSkipsConsecutiveTracksFromSameSourceAlbumWhenEnabled() {
        let outgoing = Track(id: "1", key: "/library/metadata/1", title: "One", albumRatingKey: "album-1", sourceCompositeKey: "source-a")
        let incoming = Track(id: "2", key: "/library/metadata/2", title: "Two", albumRatingKey: "album-1", sourceCompositeKey: "source-a")

        XCTAssertFalse(
            PlaybackPrefetchController.shouldUseSmartMix(
                outgoingTrack: outgoing,
                incomingTrack: incoming,
                isDisabledForAlbums: true
            )
        )
    }

    func testSmartMixAllowsSameAlbumWhenAlbumProtectionIsDisabled() {
        let outgoing = Track(id: "1", key: "/library/metadata/1", title: "One", albumRatingKey: "album-1", sourceCompositeKey: "source-a")
        let incoming = Track(id: "2", key: "/library/metadata/2", title: "Two", albumRatingKey: "album-1", sourceCompositeKey: "source-a")

        XCTAssertTrue(
            PlaybackPrefetchController.shouldUseSmartMix(
                outgoingTrack: outgoing,
                incomingTrack: incoming,
                isDisabledForAlbums: false
            )
        )
    }

    func testSmartMixAllowsMatchingAlbumKeysFromDifferentSources() {
        let outgoing = Track(id: "1", key: "/library/metadata/1", title: "One", albumRatingKey: "album-1", sourceCompositeKey: "source-a")
        let incoming = Track(id: "2", key: "/library/metadata/2", title: "Two", albumRatingKey: "album-1", sourceCompositeKey: "source-b")

        XCTAssertTrue(
            PlaybackPrefetchController.shouldUseSmartMix(
                outgoingTrack: outgoing,
                incomingTrack: incoming,
                isDisabledForAlbums: true
            )
        )
    }

    func testSmartMixAllowsTracksWithoutAlbumIdentity() {
        let outgoing = Track(id: "1", key: "/library/metadata/1", title: "One", sourceCompositeKey: "source-a")
        let incoming = Track(id: "2", key: "/library/metadata/2", title: "Two", sourceCompositeKey: "source-a")

        XCTAssertTrue(
            PlaybackPrefetchController.shouldUseSmartMix(
                outgoingTrack: outgoing,
                incomingTrack: incoming,
                isDisabledForAlbums: true
            )
        )
    }

    func testSmartMixDeferredPrefetchWaitsUntilTransitionWindow() {
        let controller = PlaybackPrefetchController()
        controller.deferSmartMixPrefetch(
            outgoingTrackID: "current",
            incomingTrackID: "next",
            until: 90
        )

        XCTAssertTrue(
            controller.shouldDeferSmartMixPrefetch(
                outgoingTrackID: "current",
                incomingTrackID: "next",
                currentTime: 89.9
            )
        )
        XCTAssertFalse(
            controller.shouldDeferSmartMixPrefetch(
                outgoingTrackID: "current",
                incomingTrackID: "next",
                currentTime: 90
            )
        )
    }

    func testSmartMixDeferredPrefetchClearsWhenQueueChanges() {
        let controller = PlaybackPrefetchController()
        controller.deferSmartMixPrefetch(
            outgoingTrackID: "current",
            incomingTrackID: "next",
            until: 90
        )

        XCTAssertFalse(
            controller.shouldDeferSmartMixPrefetch(
                outgoingTrackID: "current",
                incomingTrackID: "replacement",
                currentTime: 80
            )
        )
        XCTAssertFalse(
            controller.shouldDeferSmartMixPrefetch(
                outgoingTrackID: "current",
                incomingTrackID: "next",
                currentTime: 80
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

    func testStreamCacheCleanupKeepsSourceScopedCurrentTrackFile() throws {
        let controller = PlaybackPrefetchController()
        let current = makeTrack(id: "13685", sourceCompositeKey: "plex:felicity:server:music")
        let stale = makeTrack(id: "13686", sourceCompositeKey: "plex:felicity:server:music")
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let currentFile = cacheDir.appendingPathComponent(
            PlaybackStreamCacheIdentity.fileName(for: current.playbackIdentity, suffix: "current", pathExtension: "mp3")
        )
        let staleFile = cacheDir.appendingPathComponent(
            PlaybackStreamCacheIdentity.fileName(for: stale.playbackIdentity, suffix: "stale", pathExtension: "mp3")
        )
        try Data(repeating: 0x41, count: 16).write(to: currentFile)
        try Data(repeating: 0x42, count: 16).write(to: staleFile)

        controller.cleanupStreamCacheFiles(
            using: PlaybackStreamCacheContext(
                resolvedFileURLs: [current.playbackIdentity: currentFile],
                queue: [QueueItem(track: current)],
                currentQueueIndex: 0,
                scheduledTrackIDs: [],
                activeLoaderTrackIDs: []
            ),
            cacheDir: cacheDir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
    }

    func testStreamCacheCleanupKeepsLegacyRatingKeyFileForSourceScopedTrack() throws {
        let controller = PlaybackPrefetchController()
        let current = makeTrack(id: "13685", sourceCompositeKey: "plex:felicity:server:music")
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let legacyFile = cacheDir.appendingPathComponent("13685_legacy.mp3")
        try Data(repeating: 0x41, count: 16).write(to: legacyFile)

        controller.cleanupStreamCacheFiles(
            using: PlaybackStreamCacheContext(
                resolvedFileURLs: [current.playbackIdentity: legacyFile],
                queue: [QueueItem(track: current)],
                currentQueueIndex: 0,
                scheduledTrackIDs: [],
                activeLoaderTrackIDs: []
            ),
            cacheDir: cacheDir
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
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
