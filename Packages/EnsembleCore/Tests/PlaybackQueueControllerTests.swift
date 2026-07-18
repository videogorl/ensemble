@testable import EnsembleCore
import XCTest

final class PlaybackQueueControllerTests: XCTestCase {
    func testRecordToHistoryNormalizesManualSourcesAndSkipsConsecutiveDuplicates() {
        let controller = makeController()
        let track = makeTrack(id: "played")
        var history = [QueueItem]()

        controller.recordToHistory(
            QueueItem(track: track, source: .upNext),
            playbackHistory: &history
        )
        controller.recordToHistory(
            QueueItem(track: track, source: .autoplay),
            playbackHistory: &history
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].track.playbackIdentity, track.playbackIdentity)
        XCTAssertEqual(history[0].source, .continuePlaying)
    }

    func testRecordToHistoryKeepsMostRecentItemsWithinLimit() {
        let controller = makeController(maxHistorySize: 2)
        var history = [
            QueueItem(track: makeTrack(id: "oldest")),
            QueueItem(track: makeTrack(id: "middle")),
        ]

        controller.recordToHistory(
            QueueItem(track: makeTrack(id: "newest")),
            playbackHistory: &history
        )

        XCTAssertEqual(history.map(\.track.id), ["middle", "newest"])
    }

    func testFlattenAutoplayItemsOnlyChangesUpcomingItemsBeforeInsertion() {
        let controller = makeController()
        var queue = [
            QueueItem(track: makeTrack(id: "history-auto"), source: .autoplay),
            QueueItem(track: makeTrack(id: "current")),
            QueueItem(track: makeTrack(id: "upcoming-auto"), source: .autoplay),
            QueueItem(track: makeTrack(id: "boundary-auto"), source: .autoplay),
        ]

        controller.flattenAutoplayItemsBeforeIndex(
            3,
            currentQueueIndex: 1,
            queue: &queue
        )

        XCTAssertEqual(queue.map(\.source), [
            .autoplay,
            .continuePlaying,
            .continuePlaying,
            .autoplay,
        ])
    }

    func testPreviousNavigationChoosesRestartQueueAndHistoryTargets() {
        let controller = makeController()

        XCTAssertEqual(
            controller.previousNavigationTarget(
                currentTime: 5,
                currentQueueIndex: 2,
                playbackHistoryCount: 2,
                restartThreshold: 3
            ),
            .seekToZero
        )
        XCTAssertEqual(
            controller.previousNavigationTarget(
                currentTime: 1,
                currentQueueIndex: 2,
                playbackHistoryCount: 2,
                restartThreshold: 3
            ),
            .queueIndex(1)
        )
        XCTAssertEqual(
            controller.previousNavigationTarget(
                currentTime: 1,
                currentQueueIndex: 0,
                playbackHistoryCount: 2,
                restartThreshold: 3
            ),
            .historyIndex(1)
        )
    }

    func testNextPlayableIndexSkipsUnavailableItems() {
        let controller = makeController()
        let queue = [makeItem(id: "current"), makeItem(id: "offline"), makeItem(id: "available")]

        let index = controller.nextPlayableIndex(in: queue, after: 0) {
            $0.id == "available"
        }

        XCTAssertEqual(index, 2)
        XCTAssertNil(controller.nextPlayableIndex(in: queue, after: 2) { _ in true })
    }

    func testRestorePreviousHistoryItemUsesExistingQueueItemAndTruncatesHistory() {
        let controller = makeController()
        let previous = makeItem(id: "previous")
        var queue = [previous, makeItem(id: "current")]
        var history = [makeItem(id: "older"), previous]

        let index = controller.restorePreviousHistoryItem(
            at: 1,
            queue: &queue,
            playbackHistory: &history,
            currentQueueIndex: 1
        )

        XCTAssertEqual(index, 0)
        XCTAssertEqual(queue.map(\.track.id), ["previous", "current"])
        XCTAssertEqual(history.map(\.track.id), ["older"])
    }

    func testRestorePreviousHistoryItemInsertsMissingItemAtCurrentPosition() {
        let controller = makeController()
        var queue = [makeItem(id: "current"), makeItem(id: "after")]
        var history = [makeItem(id: "previous")]

        let index = controller.restorePreviousHistoryItem(
            at: 0,
            queue: &queue,
            playbackHistory: &history,
            currentQueueIndex: 0
        )

        XCTAssertEqual(index, 0)
        XCTAssertEqual(queue.map(\.track.id), ["previous", "current", "after"])
        XCTAssertTrue(history.isEmpty)
    }

    func testRecordCurrentAndSkippedItemsCapturesWholeJump() {
        let controller = makeController()
        let queue = [
            makeItem(id: "current"),
            makeItem(id: "skipped-1", source: .upNext),
            makeItem(id: "skipped-2", source: .autoplay),
            makeItem(id: "target"),
        ]
        var history = [QueueItem]()

        controller.recordCurrentAndSkippedItems(
            before: 3,
            queue: queue,
            currentQueueIndex: 0,
            playbackHistory: &history
        )

        XCTAssertEqual(history.map(\.track.id), ["current", "skipped-1", "skipped-2"])
        XCTAssertTrue(history.allSatisfy { $0.source == .continuePlaying })
    }

    func testAutoGeneratedIdentityPrefersQueueItemSource() {
        let controller = makeController()
        let manual = makeTrack(id: "manual")
        let autoplay = makeTrack(id: "autoplay")
        let queue = [
            QueueItem(track: manual, source: .continuePlaying),
            QueueItem(track: autoplay, source: .autoplay),
        ]

        XCTAssertTrue(controller.isTrackAutoGenerated(id: autoplay.playbackIdentity, queue: queue))
        XCTAssertFalse(controller.isTrackAutoGenerated(id: manual.playbackIdentity, queue: queue))
    }

    func testPlayNextInsertionStartsImmediatelyAfterCurrentItem() {
        let controller = makeController()
        let queue = [
            QueueItem(track: makeTrack(id: "current")),
            QueueItem(track: makeTrack(id: "original")),
            QueueItem(track: makeTrack(id: "autoplay"), source: .autoplay),
        ]

        XCTAssertEqual(controller.playNextInsertionIndex(in: queue, currentQueueIndex: 0), 1)
    }

    func testPlayNextInsertionAppendsAfterExistingUpNextItems() {
        let controller = makeController()
        let queue = [
            QueueItem(track: makeTrack(id: "current")),
            QueueItem(track: makeTrack(id: "added-1"), source: .upNext),
            QueueItem(track: makeTrack(id: "added-2"), source: .upNext),
            QueueItem(track: makeTrack(id: "original")),
            QueueItem(track: makeTrack(id: "autoplay"), source: .autoplay),
        ]

        XCTAssertEqual(controller.playNextInsertionIndex(in: queue, currentQueueIndex: 0), 3)
    }

    func testPlayNextInsertionStaysAtEndOfAddedListInsteadOfEntireQueue() {
        let controller = makeController()
        let queue = [
            QueueItem(track: makeTrack(id: "current")),
            QueueItem(track: makeTrack(id: "added"), source: .upNext),
            QueueItem(track: makeTrack(id: "original-1")),
            QueueItem(track: makeTrack(id: "original-2")),
            QueueItem(track: makeTrack(id: "autoplay"), source: .autoplay),
        ]

        XCTAssertEqual(controller.playNextInsertionIndex(in: queue, currentQueueIndex: 0), 2)
    }

    func testInsertUpNextPreservesBatchOrderAndShuffleRestoreOrder() {
        let controller = makeController()
        var queue = [
            makeItem(id: "current"),
            makeItem(id: "generated-before-added", source: .autoplay),
            makeItem(id: "existing-added", source: .upNext),
            makeItem(id: "original"),
        ]
        var originalQueue = [
            queue[0],
            queue[2],
            queue[3],
            queue[1],
        ]
        let additions = [
            makeItem(id: "new-1", source: .upNext),
            makeItem(id: "new-2", source: .upNext),
        ]

        controller.insertUpNext(
            additions,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: 0,
            shuffleEnabled: true
        )

        XCTAssertEqual(queue.map(\.track.id), [
            "current",
            "generated-before-added",
            "existing-added",
            "new-1",
            "new-2",
            "original",
        ])
        XCTAssertEqual(queue[1].source, .continuePlaying)
        XCTAssertEqual(originalQueue.map(\.track.id), [
            "current",
            "existing-added",
            "new-1",
            "new-2",
            "original",
            "generated-before-added",
        ])
    }

    func testInsertAtEndOfManualQueueStaysBeforeAutoplayInBothOrders() {
        let controller = makeController()
        var queue = [
            makeItem(id: "current"),
            makeItem(id: "manual"),
            makeItem(id: "generated", source: .autoplay),
        ]
        var originalQueue = queue

        controller.insertAtEndOfManualQueue(
            [makeItem(id: "added-last")],
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: 0,
            shuffleEnabled: true
        )

        XCTAssertEqual(queue.map(\.track.id), ["current", "manual", "added-last", "generated"])
        XCTAssertEqual(originalQueue.map(\.track.id), ["current", "manual", "added-last", "generated"])
    }

    func testRemoveItemBeforeCurrentAdjustsIndexAndShuffleRestoreQueue() {
        let controller = makeController()
        var queue = [
            makeItem(id: "before"),
            makeItem(id: "current"),
            makeItem(id: "after"),
        ]
        var originalQueue = queue
        var currentQueueIndex = 1

        let removed = controller.removeItem(
            at: 0,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: &currentQueueIndex,
            shuffleEnabled: true
        )

        XCTAssertEqual(removed?.track.id, "before")
        XCTAssertEqual(queue.map(\.track.id), ["current", "after"])
        XCTAssertEqual(originalQueue.map(\.track.id), ["current", "after"])
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testRemoveItemRejectsCurrentTrack() {
        let controller = makeController()
        var queue = [makeItem(id: "current"), makeItem(id: "after")]
        var originalQueue = queue
        var currentQueueIndex = 0

        let removed = controller.removeItem(
            at: 0,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: &currentQueueIndex,
            shuffleEnabled: false
        )

        XCTAssertNil(removed)
        XCTAssertEqual(queue.map(\.track.id), ["current", "after"])
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testClearRetainsCurrentItemAndClearsHistory() {
        let controller = makeController()
        var queue = [
            makeItem(id: "before"),
            makeItem(id: "current"),
            makeItem(id: "after"),
        ]
        var originalQueue = Array(queue.reversed())
        var history = [makeItem(id: "history")]
        var currentQueueIndex = 1

        controller.clear(
            queue: &queue,
            originalQueue: &originalQueue,
            playbackHistory: &history,
            currentQueueIndex: &currentQueueIndex
        )

        XCTAssertEqual(queue.map(\.track.id), ["current"])
        XCTAssertEqual(originalQueue, queue)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testMoveItemFlattensAutoplayAndTracksCurrentPosition() {
        let controller = makeController()
        var queue = [
            makeItem(id: "current"),
            makeItem(id: "generated-before", source: .autoplay),
            makeItem(id: "manual"),
            makeItem(id: "generated-moved", source: .autoplay),
        ]
        var currentQueueIndex = 0

        let result = controller.moveItem(
            byId: queue[3].id,
            from: 3,
            to: 2,
            queue: &queue,
            currentQueueIndex: &currentQueueIndex
        )

        XCTAssertEqual(result?.destinationIndex, 2)
        XCTAssertEqual(queue.map(\.track.id), [
            "current",
            "generated-before",
            "generated-moved",
            "manual",
        ])
        XCTAssertEqual(queue[1].source, .continuePlaying)
        XCTAssertEqual(queue[2].source, .continuePlaying)
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testMoveCurrentItemUpdatesCurrentIndex() {
        let controller = makeController()
        var queue = [makeItem(id: "before"), makeItem(id: "current"), makeItem(id: "after")]
        var currentQueueIndex = 1

        let result = controller.moveItem(
            byId: queue[1].id,
            from: 1,
            to: 3,
            queue: &queue,
            currentQueueIndex: &currentQueueIndex
        )

        XCTAssertEqual(result?.destinationIndex, 2)
        XCTAssertEqual(queue.map(\.track.id), ["before", "after", "current"])
        XCTAssertEqual(currentQueueIndex, 2)
    }

    func testMoveItemAdoptsDestinationQueueSection() {
        let controller = makeController()
        var queue = [
            makeItem(id: "current"),
            makeItem(id: "next", source: .upNext),
            makeItem(id: "last", source: .continuePlaying),
        ]
        var currentQueueIndex = 0

        controller.moveItem(
            byId: queue[2].id,
            from: 2,
            to: 2,
            destinationSource: .upNext,
            queue: &queue,
            currentQueueIndex: &currentQueueIndex
        )

        XCTAssertEqual(queue.map(\.track.id), ["current", "next", "last"])
        XCTAssertEqual(queue[2].source, .upNext)
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testEnableShuffleKeepsCurrentFirstAutoplayLastAndExcludesHistory() {
        let controller = makeController()
        var queue = [
            makeItem(id: "played"),
            makeItem(id: "current"),
            makeItem(id: "candidate-1"),
            makeItem(id: "candidate-2"),
            makeItem(id: "generated", source: .autoplay),
        ]
        let original = queue
        var originalQueue = [QueueItem]()
        var currentQueueIndex = 1

        controller.enableShuffle(
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: &currentQueueIndex,
            playbackHistory: [makeItem(id: "played")],
            shuffleCandidates: { $0 = Array($0.reversed()) }
        )

        XCTAssertEqual(originalQueue, original)
        XCTAssertEqual(queue.map(\.track.id), ["current", "candidate-2", "candidate-1", "generated"])
        XCTAssertEqual(currentQueueIndex, 0)
    }

    func testDisableShuffleRestoresOriginalOrderAroundCurrentItem() {
        let controller = makeController()
        let originalQueue = [makeItem(id: "first"), makeItem(id: "current"), makeItem(id: "last")]
        var queue = [originalQueue[1], originalQueue[2], originalQueue[0]]
        var currentQueueIndex = 0

        controller.disableShuffle(
            queue: &queue,
            originalQueue: originalQueue,
            currentQueueIndex: &currentQueueIndex
        )

        XCTAssertEqual(queue, originalQueue)
        XCTAssertEqual(currentQueueIndex, 1)
    }

    func testPruneDuplicateFutureAutoplayItemsRemovesAlternateAlbumVersion() {
        let current = QueueItem(
            id: "current",
            track: makeTrack(id: "12728", title: "Telephone", artistName: "Lady Gaga", duration: 221)
        )
        let manual = QueueItem(
            id: "manual",
            track: makeTrack(id: "12730", title: "Teeth", artistName: "Lady Gaga", duration: 220.693)
        )
        let duplicate = QueueItem(
            id: "duplicate",
            track: makeTrack(id: "11979", title: "Teeth", artistName: "Lady Gaga", duration: 220.693),
            source: .autoplay
        )
        let unique = QueueItem(
            id: "unique",
            track: makeTrack(id: "11980", title: "Bang!", artistName: "AJR", duration: 170),
            source: .autoplay
        )

        let result = PlaybackQueueController.pruneDuplicateFutureAutoplayItems(
            queue: [current, manual, duplicate, unique],
            currentQueueIndex: 0
        )

        XCTAssertEqual(result.queue.map(\.id), ["current", "manual", "unique"])
        XCTAssertEqual(result.removedTrackIds, [duplicate.track.playbackIdentity])
        XCTAssertEqual(result.removedItemCount, 1)
    }

    func testPruneDuplicateFutureAutoplayItemsKeepsManualDuplicates() {
        let first = QueueItem(
            id: "first",
            track: makeTrack(id: "one", title: "Teeth", artistName: "Lady Gaga", duration: 220.693)
        )
        let second = QueueItem(
            id: "second",
            track: makeTrack(id: "two", title: "Teeth", artistName: "Lady Gaga", duration: 220.693)
        )

        let result = PlaybackQueueController.pruneDuplicateFutureAutoplayItems(
            queue: [first, second],
            currentQueueIndex: 0
        )

        XCTAssertEqual(result.queue, [first, second])
        XCTAssertEqual(result.removedItemCount, 0)
    }

    func testExcessFutureAutoplayIndicesPreservesManualQueueItems() {
        let controller = makeController()
        let manualItems = (1 ... 10).map { makeItem(id: "manual-\($0)") }
        let autoplayItems = (1 ... 7).map { makeItem(id: "autoplay-\($0)", source: .autoplay) }
        let queue = [makeItem(id: "current")] + manualItems + autoplayItems

        let indices = controller.excessFutureAutoplayIndices(
            queue: queue,
            currentQueueIndex: 0,
            maximumCount: 5
        )

        XCTAssertEqual(indices.map { queue[$0].track.id }, ["autoplay-6", "autoplay-7"])
    }

    func testAutoGeneratedIdentityDistinguishesDuplicateRatingKeys() {
        let controller = makeController()
        let subscriberTrack = makeTrack(id: "7551", sourceCompositeKey: "plex:felicity:server:music")
        let freeAccountTrack = makeTrack(id: "7551", sourceCompositeKey: "plex:felicity-test:server:music")
        let queue = [
            QueueItem(track: subscriberTrack, source: .continuePlaying),
            QueueItem(track: freeAccountTrack, source: .autoplay),
        ]

        XCTAssertFalse(controller.isTrackAutoGenerated(id: subscriberTrack.playbackIdentity, queue: queue))
        XCTAssertTrue(controller.isTrackAutoGenerated(id: freeAccountTrack.playbackIdentity, queue: queue))
    }

    func testAutoGeneratedIdentityFallsBackToLegacyTrackedIds() {
        let controller = makeController()
        let queue = [
            QueueItem(track: makeTrack(id: "legacy"), source: .continuePlaying),
        ]

        controller.markAutoGeneratedTrack(id: "legacy")

        XCTAssertTrue(controller.isTrackAutoGenerated(id: "legacy", queue: queue))
    }

    func testAutoGeneratedTrackingCanClearReplaceAndSyncFromQueue() {
        let controller = makeController()
        controller.replaceAutoGeneratedTrackIds(with: ["radio-seed", "stale"])

        XCTAssertTrue(controller.isTrackAutoGenerated(id: "radio-seed", queue: []))
        XCTAssertTrue(controller.removeAutoGeneratedTrack(id: "stale"))
        XCTAssertFalse(controller.isTrackAutoGenerated(id: "stale", queue: []))

        let queue = [
            QueueItem(track: makeTrack(id: "manual"), source: .continuePlaying),
            QueueItem(track: makeTrack(id: "restored-auto"), source: .autoplay),
        ]
        controller.syncAutoGeneratedTrackIds(from: queue)

        XCTAssertFalse(controller.isTrackAutoGenerated(id: "radio-seed", queue: []))
        XCTAssertTrue(controller.isTrackAutoGenerated(id: queue[1].track.playbackIdentity, queue: []))

        controller.clearAutoGeneratedTrackIds()

        XCTAssertFalse(controller.isTrackAutoGenerated(id: queue[1].track.playbackIdentity, queue: []))
    }

    func testUpdateStreamingQualitySkipsDownloadedFilesAndRestampsStreamingItems() {
        let controller = makeController()
        var queue = [
            QueueItem(
                track: makeTrack(id: "downloaded", localFilePath: "/downloads/downloaded.mp3"),
                streamingQuality: "old"
            ),
            QueueItem(
                track: makeTrack(id: "missing-local", localFilePath: "/downloads/missing.mp3"),
                streamingQuality: "old"
            ),
            QueueItem(track: makeTrack(id: "streaming"), streamingQuality: "old"),
        ]

        let changed = controller.updateStreamingQuality(
            "medium",
            queue: &queue,
            fileExists: { $0 == "/downloads/downloaded.mp3" }
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(queue[0].streamingQuality, "old")
        XCTAssertEqual(queue[1].streamingQuality, "medium")
        XCTAssertEqual(queue[2].streamingQuality, "medium")

        let unchanged = controller.updateStreamingQuality(
            "medium",
            queue: &queue,
            fileExists: { $0 == "/downloads/downloaded.mp3" }
        )

        XCTAssertFalse(unchanged)
    }

    func testUpdateStreamingQualityUsesPrecomputedExistingLocalPaths() {
        let controller = makeController()
        var queue = [
            QueueItem(
                track: makeTrack(id: "downloaded", localFilePath: "/downloads/downloaded.mp3"),
                streamingQuality: "old"
            ),
            QueueItem(
                track: makeTrack(id: "missing-local", localFilePath: "/downloads/missing.mp3"),
                streamingQuality: "old"
            ),
        ]

        var fileExistsCalls = 0
        let changed = controller.updateStreamingQuality(
            "medium",
            queue: &queue,
            existingLocalFilePaths: ["/downloads/downloaded.mp3"],
            fileExists: { _ in
                fileExistsCalls += 1
                return false
            }
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(fileExistsCalls, 0)
        XCTAssertEqual(queue[0].streamingQuality, "old")
        XCTAssertEqual(queue[1].streamingQuality, "medium")
    }

    func testRefreshDownloadStateAddsLocalPathClearsQualityAndReportsNonCurrentEviction() async {
        let controller = makeController()
        var queue = [
            QueueItem(track: makeTrack(id: "current"), streamingQuality: "high"),
            QueueItem(
                id: "queue-next",
                track: makeTrack(id: "next"),
                source: .upNext,
                streamingQuality: "high"
            ),
        ]

        let result = await controller.refreshDownloadState(
            queue: &queue,
            currentQueueIndex: 0,
            fallbackStreamingQuality: "medium",
            localFilePathForTrack: { track in
                track.id == "next" ? "/downloads/next.mp3" : nil
            }
        )

        XCTAssertEqual(result.changedTrackIds, [queue[1].track.playbackIdentity])
        XCTAssertEqual(result.nonCurrentTrackIdsNeedingCacheEviction, [queue[1].track.playbackIdentity])
        XCTAssertEqual(queue[1].id, "queue-next")
        XCTAssertEqual(queue[1].source, .upNext)
        XCTAssertEqual(queue[1].track.localFilePath, "/downloads/next.mp3")
        XCTAssertNil(queue[1].streamingQuality)
        XCTAssertEqual(queue[1].track.albumArtistName, "Album Artist")
        XCTAssertEqual(queue[1].track.genres, ["Electronic", "Test"])
    }

    func testRefreshDownloadStateRemovesCurrentLocalPathAndRestampsQualityWithoutEviction() async {
        let controller = makeController()
        var queue = [
            QueueItem(
                track: makeTrack(id: "current", localFilePath: "/downloads/current.mp3"),
                streamingQuality: nil
            ),
            QueueItem(
                track: makeTrack(id: "next", localFilePath: "/downloads/next.mp3"),
                streamingQuality: nil
            ),
        ]

        let result = await controller.refreshDownloadState(
            queue: &queue,
            currentQueueIndex: 0,
            fallbackStreamingQuality: "low",
            localFilePathForTrack: { track in
                track.id == "current" ? nil : track.localFilePath
            }
        )

        XCTAssertEqual(result.changedTrackIds, [queue[0].track.playbackIdentity])
        XCTAssertTrue(result.nonCurrentTrackIdsNeedingCacheEviction.isEmpty)
        XCTAssertNil(queue[0].track.localFilePath)
        XCTAssertEqual(queue[0].streamingQuality, "low")
        XCTAssertEqual(queue[1].track.localFilePath, "/downloads/next.mp3")
        XCTAssertNil(queue[1].streamingQuality)
    }

    private func makeController(maxHistorySize: Int = 100) -> PlaybackQueueController {
        PlaybackQueueController(
            queueStore: PlaybackQueueStore(defaults: .standard),
            maxHistorySize: maxHistorySize
        )
    }

    private func makeTrack(
        id: String,
        title: String? = nil,
        artistName: String = "Artist",
        duration: TimeInterval = 0,
        localFilePath: String? = nil,
        sourceCompositeKey: String? = "plex:account:server:library"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title ?? "Track \(id)",
            artistName: artistName,
            albumArtistName: "Album Artist",
            duration: duration,
            localFilePath: localFilePath,
            genres: ["Electronic", "Test"],
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeItem(
        id: String,
        source: QueueItemSource = .continuePlaying
    ) -> QueueItem {
        QueueItem(id: "queue-\(id)", track: makeTrack(id: id), source: source)
    }
}
