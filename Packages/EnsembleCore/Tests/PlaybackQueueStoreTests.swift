import XCTest
@testable import EnsembleCore

final class PlaybackQueueStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var progressURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackQueueStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackQueueStoreTests.\(UUID().uuidString).json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: progressURL)
        defaults = nil
        suiteName = nil
        progressURL = nil
        super.tearDown()
    }

    func testSaveAndLoadRoundTripUsesSnapshotFormat() async throws {
        let store = PlaybackQueueStore(defaults: defaults, progressURL: progressURL)
        let queue = [QueueItem(track: makeTrack(id: "track-1"))]
        let history = [QueueItem(track: makeTrack(id: "track-2"))]

        store.save(
            queue: queue,
            history: history,
            currentIndex: 0,
            currentTime: 42,
            hasUserQueueEdits: true
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.queue, queue)
        XCTAssertEqual(snapshot.history, history)
        XCTAssertEqual(snapshot.currentIndex, 0)
        XCTAssertEqual(snapshot.currentTime, 42, accuracy: 0.001)
        XCTAssertTrue(snapshot.hasUserQueueEdits)
        XCTAssertNotNil(defaults.data(forKey: "com.ensemble.playback.snapshot"))
    }

    func testProgressSaveDoesNotRewriteQueueSnapshot() async throws {
        let store = PlaybackQueueStore(defaults: defaults, progressURL: progressURL)
        let queue = [QueueItem(track: makeTrack(id: "track-1"))]
        store.save(queue: queue, history: [], currentIndex: 0, currentTime: 10)
        try await Task.sleep(nanoseconds: 200_000_000)
        let encodedSnapshot = try XCTUnwrap(defaults.data(forKey: "com.ensemble.playback.snapshot"))

        store.saveProgress(42)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(defaults.data(forKey: "com.ensemble.playback.snapshot"), encodedSnapshot)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.currentTime, 42, accuracy: 0.001)
    }

    func testLoadSnapshotWithoutQueueEditMarkerDefaultsToUnprotected() throws {
        let store = PlaybackQueueStore(defaults: defaults, progressURL: progressURL)
        let legacySnapshot = """
        {"queue":[],"history":[],"currentIndex":-1,"currentTime":0}
        """
        defaults.set(Data(legacySnapshot.utf8), forKey: "com.ensemble.playback.snapshot")

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertFalse(snapshot.hasUserQueueEdits)
    }

    func testLoadMigratesLegacyTrackArray() throws {
        let store = PlaybackQueueStore(defaults: defaults, progressURL: progressURL)
        let legacyTrack = makeTrack(id: "legacy-track")
        let encoded = try JSONEncoder().encode([legacyTrack])
        defaults.set(encoded, forKey: "com.ensemble.playback.queue")
        defaults.set(3, forKey: "com.ensemble.playback.currentTime")

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.queue.map(\.track.id), ["legacy-track"])
        XCTAssertEqual(snapshot.queue.first?.source, .continuePlaying)
        XCTAssertEqual(snapshot.currentTime, 3, accuracy: 0.001)
    }

    func testSaveClearsAllKeysWhenQueueAndHistoryAreEmpty() async throws {
        let store = PlaybackQueueStore(defaults: defaults, progressURL: progressURL)
        defaults.set(Data("stale".utf8), forKey: "com.ensemble.playback.snapshot")
        defaults.set(Data("stale".utf8), forKey: "com.ensemble.playback.queue")

        store.save(queue: [], history: [], currentIndex: -1, currentTime: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.snapshot"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.queue"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.history"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentIndex"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentTime"))
    }

    private func makeTrack(id: String) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            artistName: "Artist",
            sourceCompositeKey: "plex:account:server:library"
        )
    }
}
