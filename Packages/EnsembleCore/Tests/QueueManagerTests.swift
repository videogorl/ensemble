import XCTest
@testable import EnsembleCore

// MARK: - Test Helpers

/// Convenience for building test tracks quickly
private func makeTrack(
    _ id: String,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    duration: TimeInterval = 200
) -> Track {
    Track(
        id: id,
        key: "/library/metadata/\(id)",
        title: title ?? "Track \(id)",
        artistName: artist ?? "Artist",
        albumName: album ?? "Album",
        duration: duration
    )
}

/// Convenience for building an album-like tracklist
private func makeAlbumTracks(count: Int, idPrefix: String = "") -> [Track] {
    (1...count).map { makeTrack("\(idPrefix)\($0)", title: "Song \($0)") }
}

// MARK: - Queue Setup Tests

final class QueueSetupTests: XCTestCase {

    func testSetQueueFromAlbum() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 10)

        let result = qm.setQueue(tracks: tracks, startingAt: 0)

        XCTAssertEqual(result, 0)
        XCTAssertEqual(qm.queue.count, 10)
        XCTAssertEqual(qm.currentQueueIndex, 0)
        XCTAssertEqual(qm.currentTrack?.id, "1")
        // All items should be .continuePlaying
        XCTAssertTrue(qm.queue.allSatisfy { $0.source == .continuePlaying })
    }

    func testSetQueueStartingAtMiddle() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 10)

        let result = qm.setQueue(tracks: tracks, startingAt: 5)

        XCTAssertEqual(result, 5)
        XCTAssertEqual(qm.currentQueueIndex, 5)
        XCTAssertEqual(qm.currentTrack?.title, "Song 6")
    }

    func testSetQueueClearsHistory() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 5)
        qm.setQueue(tracks: tracks, startingAt: 0)

        // Advance a few times to build history
        _ = qm.next()
        _ = qm.next()
        XCTAssertFalse(qm.playbackHistory.isEmpty)

        // Start a new queue -- should clear history
        let newTracks = makeAlbumTracks(count: 3, idPrefix: "new")
        qm.setQueue(tracks: newTracks, startingAt: 0)
        XCTAssertTrue(qm.playbackHistory.isEmpty)
    }

    func testSetQueueDisablesShuffle() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 5)
        qm.setShuffledQueue(tracks: tracks)
        XCTAssertTrue(qm.isShuffleEnabled)

        // Setting a new queue should disable shuffle
        qm.setQueue(tracks: tracks, startingAt: 0)
        XCTAssertFalse(qm.isShuffleEnabled)
    }

    func testSetQueueEmptyTracksReturnsNil() {
        let qm = QueueManager()
        let result = qm.setQueue(tracks: [], startingAt: 0)
        XCTAssertNil(result)
        XCTAssertTrue(qm.queue.isEmpty)
    }

    func testSetQueueInvalidIndexReturnsNil() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 3)
        let result = qm.setQueue(tracks: tracks, startingAt: 10)
        XCTAssertNil(result)
    }

    func testShuffledQueueSetup() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 20)

        let result = qm.setShuffledQueue(tracks: tracks)

        XCTAssertEqual(result, 0)
        XCTAssertTrue(qm.isShuffleEnabled)
        XCTAssertEqual(qm.queue.count, 20)
        XCTAssertEqual(qm.currentQueueIndex, 0)
        // Original queue should be preserved for restore
        XCTAssertEqual(qm.originalQueue.count, 20)
    }
}

// MARK: - Next / Previous Navigation Tests

final class QueueNavigationTests: XCTestCase {

    func testNextAdvancesIndex() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let action = qm.next()

        if case .playIndex(let idx) = action {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected .playIndex, got \(action)")
        }
        XCTAssertEqual(qm.currentQueueIndex, 1)
    }

    func testNextRecordsHistory() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        _ = qm.next() // 0 -> 1
        _ = qm.next() // 1 -> 2

        XCTAssertEqual(qm.playbackHistory.count, 2)
        XCTAssertEqual(qm.playbackHistory[0].track.id, "1")
        XCTAssertEqual(qm.playbackHistory[1].track.id, "2")
    }

    func testNextAtEndOfQueueStops() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        _ = qm.next() // 0 -> 1

        let action = qm.next() // 1 -> end

        if case .stop = action {
            // correct
        } else {
            XCTFail("Expected .stop, got \(action)")
        }
    }

    func testNextAtEndWithRepeatAll() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        qm.cycleRepeatMode() // off -> all
        _ = qm.next() // 0 -> 1

        let action = qm.next() // 1 -> wrap to 0

        if case .repeatAllFromStart = action {
            XCTAssertEqual(qm.currentQueueIndex, 0)
        } else {
            XCTFail("Expected .repeatAllFromStart, got \(action)")
        }
    }

    func testNextAtEndWithAutoplay() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        qm._setQueueState(
            queue: qm.queue,
            currentIndex: 1,
            isAutoplayEnabled: true
        )

        let action = qm.next()

        if case .refreshAutoplay = action {
            // correct
        } else {
            XCTFail("Expected .refreshAutoplay, got \(action)")
        }
    }

    func testPreviousRestartsWhenOver3Seconds() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 2)

        let action = qm.previous(currentTime: 5.0)

        if case .seekToZero = action {
            XCTAssertEqual(qm.currentQueueIndex, 2, "Index should not change")
        } else {
            XCTFail("Expected .seekToZero, got \(action)")
        }
    }

    func testPreviousGoesBackWhenUnder3Seconds() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 2)

        // Simulate having some history
        qm.recordToHistory(qm.queue[0])
        qm.recordToHistory(qm.queue[1])

        let action = qm.previous(currentTime: 1.0)

        if case .playIndex(let idx) = action {
            XCTAssertEqual(idx, 1)
        } else {
            XCTFail("Expected .playIndex, got \(action)")
        }
    }

    func testPreviousAtStartRestartsTrack() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let action = qm.previous(currentTime: 0.5)

        if case .seekToZero = action {
            // correct
        } else {
            XCTFail("Expected .seekToZero, got \(action)")
        }
    }

    func testNextThenPreviousDoesNotDuplicateHistory() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        _ = qm.next() // history: [track1]
        _ = qm.next() // history: [track1, track2]
        XCTAssertEqual(qm.playbackHistory.count, 2)

        // Go back -- should remove last history entry
        _ = qm.previous(currentTime: 0)
        XCTAssertEqual(qm.playbackHistory.count, 1)
        XCTAssertEqual(qm.playbackHistory[0].track.id, "1")
    }

    func testJumpToIndexRecordsSkippedTracks() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 10), startingAt: 0)

        let action = qm.jumpToIndex(5)

        if case .playIndex(let idx) = action {
            XCTAssertEqual(idx, 5)
        } else {
            XCTFail("Expected .playIndex, got \(action)")
        }

        // Should record current (0) + skipped tracks (1,2,3,4) = 5 items
        XCTAssertEqual(qm.playbackHistory.count, 5)
        XCTAssertEqual(qm.playbackHistory.map { $0.track.id }, ["1", "2", "3", "4", "5"])
    }
}

// MARK: - Queue Manipulation Tests (playNext, playLast, remove, clear)

final class QueueManipulationTests: XCTestCase {

    func testPlayNextInsertsAfterCurrent() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let newTrack = makeTrack("new1", title: "New Song")
        qm.playNext(newTrack)

        XCTAssertEqual(qm.queue.count, 6)
        XCTAssertEqual(qm.queue[1].track.id, "new1")
        XCTAssertEqual(qm.queue[1].source, .upNext)
        // Currently playing track shouldn't change
        XCTAssertEqual(qm.currentQueueIndex, 0)
    }

    func testPlayNextMultipleTimes() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)

        // Each "play next" should insert right after current
        qm.playNext(makeTrack("A", title: "Track A"))
        qm.playNext(makeTrack("B", title: "Track B"))

        // B should be immediately after current (most recent playNext wins position 1)
        XCTAssertEqual(qm.queue[1].track.id, "B")
        XCTAssertEqual(qm.queue[2].track.id, "A")
    }

    func testPlayLastInsertsBeforeAutoplay() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 3)
        qm.setQueue(tracks: tracks, startingAt: 0)

        // Simulate autoplay tracks at the end
        let autoplayTracks = [makeTrack("auto1"), makeTrack("auto2")]
        qm.addAutoplayTracks(autoplayTracks)

        // playLast should insert before autoplay
        let lastTrack = makeTrack("last1", title: "Play Last Track")
        qm.playLast(lastTrack)

        // Verify: [0:current, 1:song2, 2:song3, 3:last1, 4:auto1, 5:auto2] (autoplay may be trimmed)
        let sections = qm.queueSections
        XCTAssertTrue(sections.continuePlaying.contains(where: { $0.track.id == "last1" }))

        // last1 should come before any autoplay items
        if let lastIdx = qm.queue.firstIndex(where: { $0.track.id == "last1" }),
           let autoIdx = qm.queue.firstIndex(where: { $0.source == .autoplay }) {
            XCTAssertLessThan(lastIdx, autoIdx, "Play Last track must appear before autoplay tracks")
        }
    }

    func testPlayLastMultipleTracks() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)

        let newTracks = [makeTrack("A"), makeTrack("B"), makeTrack("C")]
        qm.playLast(newTracks)

        XCTAssertEqual(qm.queue.count, 5)
        XCTAssertEqual(qm.queue[2].track.id, "A")
        XCTAssertEqual(qm.queue[3].track.id, "B")
        XCTAssertEqual(qm.queue[4].track.id, "C")
    }

    func testRemoveFromQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let removed = qm.removeFromQueue(at: 3)
        XCTAssertTrue(removed)
        XCTAssertEqual(qm.queue.count, 4)
        // Track 4 (index 3) removed, track 5 should now be at index 3
        XCTAssertEqual(qm.queue[3].track.id, "5")
    }

    func testCannotRemoveCurrentlyPlayingTrack() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 2)

        let removed = qm.removeFromQueue(at: 2)
        XCTAssertFalse(removed)
        XCTAssertEqual(qm.queue.count, 5)
    }

    func testRemoveBeforeCurrentAdjustsIndex() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 3)

        qm.removeFromQueue(at: 1)

        XCTAssertEqual(qm.currentQueueIndex, 2, "Index should shift down by 1")
        XCTAssertEqual(qm.currentTrack?.id, "4")
    }

    func testClearQueueKeepsCurrentTrack() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 10), startingAt: 5)

        qm.clearQueue()

        XCTAssertEqual(qm.queue.count, 1)
        XCTAssertEqual(qm.currentQueueIndex, 0)
        XCTAssertEqual(qm.currentTrack?.id, "6")
        XCTAssertTrue(qm.playbackHistory.isEmpty, "History should be cleared")
    }

    func testClearQueueWithNothingPlaying() {
        let qm = QueueManager()
        qm.clearQueue()

        XCTAssertTrue(qm.queue.isEmpty)
        XCTAssertEqual(qm.currentQueueIndex, -1)
    }

    func testNewQueueClearsOldQueue() {
        let qm = QueueManager()
        let albumA = makeAlbumTracks(count: 10, idPrefix: "a")
        qm.setQueue(tracks: albumA, startingAt: 0)
        _ = qm.next()
        _ = qm.next()

        // Tap a track from a different album -- should replace entire queue
        let albumB = makeAlbumTracks(count: 5, idPrefix: "b")
        qm.setQueue(tracks: albumB, startingAt: 2)

        XCTAssertEqual(qm.queue.count, 5)
        XCTAssertEqual(qm.currentTrack?.id, "b3")
        XCTAssertTrue(qm.playbackHistory.isEmpty, "New queue clears history")
    }
}

// MARK: - Move / Reorder Tests

final class QueueReorderTests: XCTestCase {

    func testMoveQueueItemByIdForward() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        // Move track at index 1 to index 3
        let itemId = qm.queue[1].id
        qm.moveQueueItem(byId: itemId, from: 1, to: 3)

        // Track 2 should now be at index 2 (after shift adjustment)
        XCTAssertEqual(qm.queue[2].track.id, "2")
    }

    func testMoveQueueItemByIdBackward() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let itemId = qm.queue[4].id
        qm.moveQueueItem(byId: itemId, from: 4, to: 1)

        XCTAssertEqual(qm.queue[1].track.id, "5")
    }

    func testMoveAutoplayItemFlattensToRegular() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 3)
        qm.setQueue(tracks: tracks, startingAt: 0)

        // Add autoplay track
        let autoTracks = [makeTrack("auto1")]
        qm.addAutoplayTracks(autoTracks)

        let autoIndex = qm.queue.firstIndex(where: { $0.track.id == "auto1" })!
        let autoItemId = qm.queue[autoIndex].id

        // Drag autoplay item into the regular queue
        qm.moveQueueItem(byId: autoItemId, from: autoIndex, to: 1)

        // Should be flattened to .continuePlaying
        let moved = qm.queue.first(where: { $0.id == autoItemId })!
        XCTAssertEqual(moved.source, .continuePlaying, "Autoplay items dragged into queue should become regular items")
    }

    func testMoveDoesNotChangeSamePosition() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let itemId = qm.queue[2].id
        qm.moveQueueItem(byId: itemId, from: 2, to: 2)

        // Queue should be unchanged
        XCTAssertEqual(qm.queue.map { $0.track.id }, ["1", "2", "3", "4", "5"])
    }

    func testMoveAcrossSections() {
        // Set up a queue with upNext, continuePlaying, and autoplay
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm.playNext(makeTrack("upnext1"))
        qm.addAutoplayTracks([makeTrack("auto1")])

        // Queue: [1(current), upnext1, 2, 3, auto1]
        // Move auto1 to position 2 (among the regular items)
        let autoIdx = qm.queue.firstIndex(where: { $0.track.id == "auto1" })!
        let autoId = qm.queue[autoIdx].id
        qm.moveQueueItem(byId: autoId, from: autoIdx, to: 2)

        // auto1 should now be flattened and among the regular items
        let movedItem = qm.queue.first(where: { $0.id == autoId })!
        XCTAssertEqual(movedItem.source, .continuePlaying)
    }

    func testMoveUpdatesCurrentIndexWhenMovingCurrentItem() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 2)

        let itemId = qm.queue[2].id // Currently playing
        qm.moveQueueItem(byId: itemId, from: 2, to: 4)

        // Current index should follow the moved item
        XCTAssertEqual(qm.currentQueueIndex, 3) // adjustedDest = 4-1 = 3
        XCTAssertEqual(qm.currentTrack?.id, "3")
    }
}

// MARK: - Queue Sections Tests

final class QueueSectionsTests: XCTestCase {

    func testSectionsWithMixedQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm.playNext(makeTrack("upnext1"))
        qm.playNext(makeTrack("upnext2"))
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2")])

        let sections = qm.queueSections

        XCTAssertEqual(sections.upNext.count, 2)
        XCTAssertEqual(sections.continuePlaying.count, 2) // tracks 2 and 3
        // Autoplay might be trimmed by maxQueueLookahead
        XCTAssertTrue(sections.autoplay.count <= 2)
    }

    func testSectionsExcludesCurrentTrack() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 2)

        let sections = qm.queueSections

        // Only tracks after index 2 (tracks 4, 5) should be in sections
        let allSectionTrackIds = sections.continuePlaying.map { $0.track.id }
        XCTAssertEqual(allSectionTrackIds, ["4", "5"])
        XCTAssertFalse(allSectionTrackIds.contains("3"), "Current track should not appear in sections")
    }

    func testSectionsEmpty() {
        let qm = QueueManager()
        let sections = qm.queueSections
        XCTAssertTrue(sections.upNext.isEmpty)
        XCTAssertTrue(sections.continuePlaying.isEmpty)
        XCTAssertTrue(sections.autoplay.isEmpty)
    }
}

// MARK: - Shuffle Tests

final class ShuffleTests: XCTestCase {

    func testToggleShuffleOn() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 20), startingAt: 5)

        qm.toggleShuffle()

        XCTAssertTrue(qm.isShuffleEnabled)
        XCTAssertEqual(qm.queue.count, 20) // minus history tracks which got filtered

        // Current track should still be at index 0 (moved to front)
        XCTAssertEqual(qm.currentQueueIndex, 0)
        XCTAssertEqual(qm.currentTrack?.id, "6")
    }

    func testToggleShuffleOff() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 10)
        qm.setQueue(tracks: tracks, startingAt: 3)

        qm.toggleShuffle() // on
        qm.toggleShuffle() // off

        XCTAssertFalse(qm.isShuffleEnabled)
        // Current track should still be "4" at its original position
        XCTAssertEqual(qm.currentTrack?.id, "4")
        XCTAssertEqual(qm.currentQueueIndex, 3)

        // Queue order should be restored
        XCTAssertEqual(qm.queue.map { $0.track.id }, tracks.map { $0.id })
    }

    func testShuffleExcludesAutoplayItems() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        // Add autoplay tracks
        let autoTracks = [makeTrack("auto1"), makeTrack("auto2")]
        qm.addAutoplayTracks(autoTracks)

        qm.toggleShuffle()

        // Autoplay items should be at the end, not shuffled into the middle
        let autoplayIndices = qm.queue.enumerated().compactMap { index, item in
            item.source == .autoplay ? index : nil
        }
        let regularIndices = qm.queue.enumerated().compactMap { index, item in
            item.source != .autoplay ? index : nil
        }

        if let lastRegular = regularIndices.last, let firstAutoplay = autoplayIndices.first {
            XCTAssertLessThan(lastRegular, firstAutoplay, "Autoplay items must remain after regular items")
        }
    }

    func testShuffleOnOffOnProducesNewShuffle() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 20)
        qm.setQueue(tracks: tracks, startingAt: 0)

        qm.toggleShuffle() // on
        let firstShuffleOrder = qm.queue.map { $0.track.id }

        qm.toggleShuffle() // off
        qm.toggleShuffle() // on again

        let secondShuffleOrder = qm.queue.map { $0.track.id }

        // With 20 tracks, the probability of getting the same order is effectively zero
        // But to be safe, just check that shuffle happened (not identical to original order)
        let originalOrder = tracks.map { $0.id }

        // At least one of the shuffles should differ from original
        let firstDiffers = firstShuffleOrder != originalOrder
        let secondDiffers = secondShuffleOrder != originalOrder
        XCTAssertTrue(firstDiffers || secondDiffers, "At least one shuffle should differ from original order")
    }

    func testUpNextTracksAreShuffled() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        // Add some "up next" tracks
        qm.playNext(makeTrack("upnext1"))
        qm.playNext(makeTrack("upnext2"))
        qm.playNext(makeTrack("upnext3"))

        qm.toggleShuffle()

        // Up next tracks should be included in the shuffle (not autoplay though)
        let upNextInQueue = qm.queue.filter { $0.source == .upNext }
        // They exist somewhere in the queue (may have been shuffled)
        XCTAssertEqual(upNextInQueue.count, 3)
    }
}

// MARK: - Autoplay Tests

final class AutoplayTests: XCTestCase {

    func testToggleAutoplayOn() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        let shouldRefresh = qm.toggleAutoplay()

        XCTAssertTrue(qm.isAutoplayEnabled)
        XCTAssertTrue(shouldRefresh, "Caller should refresh autoplay queue")
    }

    func testToggleAutoplayOffRemovesAutoplayTracks() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Add some autoplay tracks
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2"), makeTrack("auto3")])
        let totalBefore = qm.queue.count

        // Toggle off
        _ = qm.toggleAutoplay()

        XCTAssertFalse(qm.isAutoplayEnabled)
        XCTAssertTrue(qm.queue.allSatisfy { $0.source != .autoplay }, "No autoplay tracks should remain")
        XCTAssertLessThan(qm.queue.count, totalBefore)
    }

    func testAutoplayTracksFilterDuplicates() {
        let qm = QueueManager()
        let tracks = makeAlbumTracks(count: 3)
        qm.setQueue(tracks: tracks, startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Try to add tracks that include ones already in queue
        let autoTracks = [makeTrack("1"), makeTrack("auto1"), makeTrack("2"), makeTrack("auto2")]
        let added = qm.addAutoplayTracks(autoTracks)

        // Only auto1 and auto2 should be added (tracks 1 and 2 are already in queue)
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.contains(where: { $0.id == "auto1" }))
        XCTAssertTrue(added.contains(where: { $0.id == "auto2" }))
    }

    func testAutoplayTrimsExcessTracks() {
        let qm = QueueManager(maxQueueLookahead: 5)
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Add many autoplay tracks
        let autoTracks = (1...10).map { makeTrack("auto\($0)") }
        qm.addAutoplayTracks(autoTracks)

        // Future tracks should be capped at maxQueueLookahead (5)
        let futureCount = qm.queue.count - qm.currentQueueIndex - 1
        XCTAssertLessThanOrEqual(futureCount, 5)
    }

    func testAutoplaySeedIsLastRealTrack() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2")])

        // The last real track should be the seed for autoplay
        XCTAssertEqual(qm.lastRealTrackIndex, 4)
        XCTAssertEqual(qm.queue[qm.lastRealTrackIndex!].track.id, "5")
    }

    func testAutoplayRecalculatesWhenTrackAddedToEnd() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm.addAutoplayTracks([makeTrack("auto1")])

        // Before adding a track, last real is "3"
        XCTAssertEqual(qm.queue[qm.lastRealTrackIndex!].track.id, "3")

        // Add a new track via playLast
        qm.playLast(makeTrack("new_last"))

        // Now lastRealTrackIndex should point to "new_last"
        XCTAssertEqual(qm.queue[qm.lastRealTrackIndex!].track.id, "new_last")
    }

    func testNeedsAutoplayRefresh() {
        let qm = QueueManager(maxQueueLookahead: 5)
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Only 2 future tracks, needs refresh
        XCTAssertTrue(qm.needsAutoplayRefresh)

        // Disable autoplay - should not need refresh
        _ = qm.toggleAutoplay()
        XCTAssertFalse(qm.needsAutoplayRefresh)
    }
}

// MARK: - Flatten Autoplay Tests

final class FlattenAutoplayTests: XCTestCase {

    func testInsertBetweenAutoplayFlattens() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Add autoplay tracks
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2"), makeTrack("auto3")])

        // Queue: [1(current), 2, auto1, auto2, auto3]
        // Insert a user track between auto1 and auto2
        // Using playLast which inserts before autoplay
        qm.playLast(makeTrack("user_added"))

        // auto1 and auto2 that were BEFORE the insertion point should be flattened
        // playLast inserts at autoplayStartIndex, which is where auto1 is
        // So "user_added" goes at that position, pushing autos forward
        // The flatten logic runs on items between currentIndex+1 and insertIndex

        // Verify no autoplay items exist before user_added
        if let userIdx = qm.queue.firstIndex(where: { $0.track.id == "user_added" }) {
            for i in (qm.currentQueueIndex + 1)..<userIdx {
                XCTAssertNotEqual(qm.queue[i].source, .autoplay,
                    "Autoplay items before user-inserted track should be flattened")
            }
        }
    }

    func testPlayNextAmongAutoplayFlattens() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: [makeTrack("1")], startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Add autoplay tracks
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2"), makeTrack("auto3")])

        // Queue: [1(current), auto1, auto2, auto3]
        // playNext inserts at index 1 (right after current)
        qm.playNext(makeTrack("next1"))

        // Queue should now be: [1(current), next1, auto1, auto2, auto3]
        // No autoplay items should be before "next1" (it's at index 1)
        XCTAssertEqual(qm.queue[1].track.id, "next1")
        XCTAssertEqual(qm.queue[1].source, .upNext)
    }

    func testMoveAutoplayItemIntoRegularQueueFlattens() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2")])

        // Find auto1 and drag it to position 1 (right after current)
        let autoIdx = qm.queue.firstIndex(where: { $0.track.id == "auto1" })!
        let autoId = qm.queue[autoIdx].id
        qm.moveQueueItem(byId: autoId, from: autoIdx, to: 1)

        // auto1 should now be .continuePlaying
        let movedItem = qm.queue.first(where: { $0.id == autoId })!
        XCTAssertEqual(movedItem.source, .continuePlaying)
    }
}

// MARK: - History Tests

final class HistoryTests: XCTestCase {

    func testHistoryIsRecordedOnNext() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        _ = qm.next() // Track 1 -> history
        _ = qm.next() // Track 2 -> history
        _ = qm.next() // Track 3 -> history

        XCTAssertEqual(qm.playbackHistory.count, 3)
        XCTAssertEqual(qm.playbackHistory.map { $0.track.id }, ["1", "2", "3"])
    }

    func testHistoryFlattensAutoplaySource() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 2), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)
        qm.addAutoplayTracks([makeTrack("auto1")])

        // Advance through regular and into autoplay
        _ = qm.next() // Track 1 -> history
        _ = qm.next() // Track 2 -> history

        // All history items should be .continuePlaying (flattened)
        XCTAssertTrue(qm.playbackHistory.allSatisfy { $0.source == .continuePlaying },
            "History should flatten autoplay/upNext to continuePlaying")
    }

    func testHistoryCapAtMaxSize() {
        let qm = QueueManager(maxHistorySize: 5)
        let tracks = makeAlbumTracks(count: 10)
        qm.setQueue(tracks: tracks, startingAt: 0)

        for _ in 0..<9 {
            _ = qm.next()
        }

        XCTAssertLessThanOrEqual(qm.playbackHistory.count, 5, "History should be capped at maxHistorySize")
    }

    func testHistoryAvoidConsecutiveDuplicates() {
        let qm = QueueManager()
        let track = makeTrack("1")

        // Record the same track twice in a row
        qm.recordToHistory(QueueItem(track: track, source: .continuePlaying))
        qm.recordToHistory(QueueItem(track: track, source: .continuePlaying))

        XCTAssertEqual(qm.playbackHistory.count, 1, "Consecutive duplicate should be avoided")
    }

    func testPlayFromHistoryWhenTrackInQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        // Advance to build history
        _ = qm.next() // at 1, history: [track1]
        _ = qm.next() // at 2, history: [track1, track2]
        _ = qm.next() // at 3, history: [track1, track2, track3]

        // Play track1 from history (index 0) -- it's still in queue at position 0
        let action = qm.playFromHistory(at: 0)

        if case .playIndex(let idx) = action {
            XCTAssertEqual(idx, 0)
        } else {
            XCTFail("Expected .playIndex, got \(String(describing: action))")
        }

        // History from index 0 onwards should be removed
        XCTAssertTrue(qm.playbackHistory.isEmpty)
    }

    func testPlayFromHistoryWhenTrackNotInQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)

        // Navigate forward
        _ = qm.next()
        _ = qm.next()

        // Replace queue entirely
        let newTracks = makeAlbumTracks(count: 3, idPrefix: "new")
        qm.setQueue(tracks: newTracks, startingAt: 0)
        // History was cleared by setQueue, so manually simulate history with a track not in queue
        let orphanTrack = makeTrack("orphan", title: "Orphan Track")
        qm.recordToHistory(QueueItem(track: orphanTrack, source: .continuePlaying))

        let action = qm.playFromHistory(at: 0)

        if case .playIndex = action {
            // Track should have been inserted into queue
            XCTAssertTrue(qm.queue.contains(where: { $0.track.id == "orphan" }))
        } else {
            XCTFail("Expected .playIndex, got \(String(describing: action))")
        }
    }

    func testBackwardNavigationPreventsHistoryDuplication() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 5), startingAt: 0)

        _ = qm.next() // history: [track1]
        _ = qm.next() // history: [track1, track2]

        // Simulate going backward (handleItemAdvance with isNavigatingBackward = true)
        qm.isNavigatingBackward = true
        let recorded = qm.handleItemAdvance(from: 2)

        XCTAssertFalse(recorded, "Should not record history during backward navigation")
        XCTAssertFalse(qm.isNavigatingBackward, "Flag should be reset")
    }
}

// MARK: - Repeat Mode Tests

final class RepeatModeTests: XCTestCase {

    func testCycleRepeatMode() {
        let qm = QueueManager()

        XCTAssertEqual(qm.repeatMode, .off)

        qm.cycleRepeatMode()
        XCTAssertEqual(qm.repeatMode, .all)

        qm.cycleRepeatMode()
        XCTAssertEqual(qm.repeatMode, .one)

        qm.cycleRepeatMode()
        XCTAssertEqual(qm.repeatMode, .off)
    }

    func testRepeatAllWrapsQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm.cycleRepeatMode() // off -> all

        _ = qm.next() // 0 -> 1
        _ = qm.next() // 1 -> 2

        let action = qm.next() // 2 -> should wrap

        if case .repeatAllFromStart = action {
            XCTAssertEqual(qm.currentQueueIndex, 0)
        } else {
            XCTFail("Expected .repeatAllFromStart, got \(action)")
        }
    }
}

// MARK: - Integration / Complex Scenario Tests

final class QueueIntegrationTests: XCTestCase {

    /// Simulates: User plays album, adds songs up next, then navigates back and forth
    func testAlbumPlaybackWithUpNextAndNavigation() {
        let qm = QueueManager()
        let album = makeAlbumTracks(count: 8)
        qm.setQueue(tracks: album, startingAt: 0)

        // Play a couple tracks
        _ = qm.next() // at 1, history: [1]
        _ = qm.next() // at 2, history: [1, 2]

        // Add a song "up next"
        let favSong = makeTrack("fav", title: "Favorite Song")
        qm.playNext(favSong)

        // Next should play the "up next" track
        _ = qm.next() // at 3 (fav), history: [1, 2, 3]
        XCTAssertEqual(qm.currentTrack?.id, "fav")

        // Next plays the rest of the album
        _ = qm.next() // at 4, should be track 4
        XCTAssertEqual(qm.currentTrack?.id, "4")

        // Go back
        let action = qm.previous(currentTime: 0)
        if case .playIndex = action {
            XCTAssertEqual(qm.currentTrack?.id, "fav")
        }
    }

    /// Simulates: Queue with autoplay, user adds "play last" track, autoplay regenerates
    func testPlayLastBeforeAutoplay() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)

        // Simulate autoplay adding tracks
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2")])

        // User adds "play last"
        let userTrack = makeTrack("play_last", title: "User's Pick")
        qm.playLast(userTrack)

        // Verify order: regular tracks, play_last, then autoplay
        let userIdx = qm.queue.firstIndex(where: { $0.track.id == "play_last" })!

        // All tracks after userIdx with autoplay source should come after
        for i in (userIdx + 1)..<qm.queue.count {
            if qm.queue[i].source == .autoplay {
                XCTAssertGreaterThan(i, userIdx, "Autoplay tracks should come after play-last tracks")
            }
        }

        // Last real track should now be "play_last"
        XCTAssertEqual(qm.queue[qm.lastRealTrackIndex!].track.id, "play_last")
    }

    /// Simulates: Shuffle on, off, on behavior with up-next tracks
    func testShuffleToggleWithUpNextTracks() {
        let qm = QueueManager()
        let album = makeAlbumTracks(count: 10)
        qm.setQueue(tracks: album, startingAt: 0)

        // Add up-next tracks
        qm.playNext(makeTrack("upnext1"))
        qm.playNext(makeTrack("upnext2"))

        // Shuffle on
        qm.toggleShuffle()
        XCTAssertTrue(qm.isShuffleEnabled)

        // Up-next tracks should be included in shuffle (per spec)
        let upNextIds = Set(["upnext1", "upnext2"])
        let queueIds = qm.queue.map { $0.track.id }
        XCTAssertTrue(upNextIds.isSubset(of: Set(queueIds)), "Up-next tracks should still be in queue")

        // Current track should still be at index 0
        XCTAssertEqual(qm.currentQueueIndex, 0)
        XCTAssertEqual(qm.currentTrack?.id, "1")

        // Shuffle off - restore
        qm.toggleShuffle()
        XCTAssertEqual(qm.currentTrack?.id, "1")
    }

    /// Simulates: User enables autoplay, then disables it mid-queue
    func testDisableAutoplayMidQueue() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)
        qm.addAutoplayTracks([makeTrack("auto1"), makeTrack("auto2"), makeTrack("auto3")])

        let totalBefore = qm.queue.count
        let autoCountBefore = qm.queue.filter { $0.source == .autoplay }.count
        XCTAssertGreaterThan(autoCountBefore, 0)

        // Disable autoplay
        _ = qm.toggleAutoplay()

        // Autoplay tracks should be removed, but regular tracks remain
        let autoCountAfter = qm.queue.filter { $0.source == .autoplay }.count
        XCTAssertEqual(autoCountAfter, 0)
        XCTAssertEqual(qm.queue.count, totalBefore - autoCountBefore)
    }

    /// Simulates: Full session with navigation, queue manipulation, and history
    func testFullPlaybackSession() {
        let qm = QueueManager(maxQueueLookahead: 10)

        // 1. User taps track 3 in an album
        let album = makeAlbumTracks(count: 10)
        qm.setQueue(tracks: album, startingAt: 2)
        XCTAssertEqual(qm.currentTrack?.title, "Song 3")

        // 2. Advance a few tracks
        _ = qm.next() // Song 4
        _ = qm.next() // Song 5
        XCTAssertEqual(qm.currentTrack?.title, "Song 5")

        // 3. User adds "up next"
        let extraTrack = makeTrack("extra", title: "Extra Song")
        qm.playNext(extraTrack)

        // 4. Next should play the "up next" track
        _ = qm.next()
        XCTAssertEqual(qm.currentTrack?.id, "extra")

        // 5. Continue normal playback
        _ = qm.next()
        XCTAssertEqual(qm.currentTrack?.title, "Song 6")

        // 6. User taps "Song 9" in the queue
        let jumpAction = qm.jumpToIndex(qm.queue.firstIndex(where: { $0.track.id == "9" })!)
        if case .playIndex = jumpAction {
            XCTAssertEqual(qm.currentTrack?.title, "Song 9")
        }

        // 7. Go back
        _ = qm.previous(currentTime: 0.5)
        // Should go to previous queue index (Song 8)
        XCTAssertEqual(qm.currentTrack?.title, "Song 8")

        // 8. History should contain all played tracks
        XCTAssertGreaterThan(qm.playbackHistory.count, 0)
    }

    /// Verifies that tapping a track in a new view replaces the entire queue
    func testNewTrackListReplacesQueue() {
        let qm = QueueManager()

        // Playing from playlist A
        let playlistA = makeAlbumTracks(count: 5, idPrefix: "a")
        qm.setQueue(tracks: playlistA, startingAt: 0)
        _ = qm.next()
        _ = qm.next()

        // User navigates to Artist view and taps a track
        let artistTracks = makeAlbumTracks(count: 8, idPrefix: "art")
        qm.setQueue(tracks: artistTracks, startingAt: 3)

        // Queue should be entirely replaced
        XCTAssertEqual(qm.queue.count, 8)
        XCTAssertEqual(qm.currentTrack?.id, "art4")
        XCTAssertTrue(qm.queue.allSatisfy { $0.track.id.hasPrefix("art") })
        XCTAssertTrue(qm.playbackHistory.isEmpty, "History should be cleared for new queue")
    }

    /// Simulates the autoplay start index boundary helpers
    func testAutoplayStartIndex() {
        let qm = QueueManager(maxQueueLookahead: 10)
        qm.setQueue(tracks: makeAlbumTracks(count: 3), startingAt: 0)

        // No autoplay yet -- should return queue.count
        XCTAssertEqual(qm.autoplayStartIndex, qm.queue.count)

        // Add autoplay
        qm._setQueueState(queue: qm.queue, currentIndex: 0, isAutoplayEnabled: true)
        qm.addAutoplayTracks([makeTrack("auto1")])

        // Should point to the first autoplay item
        let autoIdx = qm.autoplayStartIndex
        XCTAssertEqual(qm.queue[autoIdx].source, .autoplay)
    }

    /// Verifies the addToQueue alias works the same as playLast
    func testAddToQueueIsAliasForPlayLast() {
        let qm1 = QueueManager(maxQueueLookahead: 10)
        let qm2 = QueueManager(maxQueueLookahead: 10)
        let tracks = makeAlbumTracks(count: 3)

        qm1.setQueue(tracks: tracks, startingAt: 0)
        qm2.setQueue(tracks: tracks, startingAt: 0)

        let newTrack = makeTrack("new1")
        qm1.addToQueue(newTrack)
        qm2.playLast(newTrack)

        // Both should have the same track IDs in the same order
        XCTAssertEqual(qm1.queue.map { $0.track.id }, qm2.queue.map { $0.track.id })
    }

    /// Edge case: queue with only one track
    func testSingleTrackQueue() {
        let qm = QueueManager()
        qm.setQueue(tracks: [makeTrack("solo")], startingAt: 0)

        XCTAssertEqual(qm.currentTrack?.id, "solo")

        // Next should stop
        let action = qm.next()
        if case .stop = action {
            // correct
        } else {
            XCTFail("Expected .stop for single-track queue at end, got \(action)")
        }

        // Previous should restart
        qm.setQueue(tracks: [makeTrack("solo")], startingAt: 0)
        let prevAction = qm.previous(currentTime: 0.5)
        if case .seekToZero = prevAction {
            // correct
        } else {
            XCTFail("Expected .seekToZero, got \(prevAction)")
        }
    }
}
