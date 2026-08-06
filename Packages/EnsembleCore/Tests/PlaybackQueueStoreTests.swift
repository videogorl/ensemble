import XCTest
@testable import EnsembleCore

final class PlaybackQueueStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var snapshotURL: URL!
    private var progressURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackQueueStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackQueueStoreTests.\(UUID().uuidString).snapshot.json")
        progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackQueueStoreTests.\(UUID().uuidString).json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: progressURL)
        defaults = nil
        suiteName = nil
        snapshotURL = nil
        progressURL = nil
        super.tearDown()
    }

    func testSaveAndLoadRoundTripUsesSnapshotFormat() async throws {
        let store = makeStore()
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertNil(defaults.data(forKey: "com.ensemble.playback.snapshot"))
    }

    func testProgressSaveDoesNotRewriteQueueSnapshot() async throws {
        let store = makeStore()
        let queue = [QueueItem(track: makeTrack(id: "track-1"))]
        store.save(queue: queue, history: [], currentIndex: 0, currentTime: 10)
        try await Task.sleep(nanoseconds: 200_000_000)
        let encodedSnapshot = try Data(contentsOf: snapshotURL)

        store.saveProgress(42)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(try Data(contentsOf: snapshotURL), encodedSnapshot)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.currentTime, 42, accuracy: 0.001)
    }

    func testLoadSnapshotWithoutQueueEditMarkerDefaultsToUnprotected() throws {
        let store = makeStore()
        let legacySnapshot = """
        {"queue":[],"history":[],"currentIndex":-1,"currentTime":0}
        """
        defaults.set(Data(legacySnapshot.utf8), forKey: "com.ensemble.playback.snapshot")
        defaults.set(Data("legacy".utf8), forKey: "com.ensemble.playback.queue")
        defaults.set(Data("legacy".utf8), forKey: "com.ensemble.playback.history")
        defaults.set(2, forKey: "com.ensemble.playback.currentIndex")
        defaults.set(12, forKey: "com.ensemble.playback.currentTime")

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertFalse(snapshot.hasUserQueueEdits)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertNil(defaults.data(forKey: "com.ensemble.playback.snapshot"))
        XCTAssertNil(defaults.data(forKey: "com.ensemble.playback.queue"))
        XCTAssertNil(defaults.data(forKey: "com.ensemble.playback.history"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentIndex"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentTime"))
    }

    func testLoadMigratesLegacyTrackArray() throws {
        let store = makeStore()
        let legacyTrack = makeTrack(id: "legacy-track")
        let encoded = try JSONEncoder().encode([legacyTrack])
        defaults.set(encoded, forKey: "com.ensemble.playback.queue")
        defaults.set(3, forKey: "com.ensemble.playback.currentTime")

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.queue.map(\.track.id), ["legacy-track"])
        XCTAssertEqual(snapshot.queue.first?.source, .continuePlaying)
        XCTAssertEqual(snapshot.currentTime, 3, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertNil(defaults.data(forKey: "com.ensemble.playback.queue"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentTime"))
    }

    func testSaveClearsAllKeysWhenQueueAndHistoryAreEmpty() async throws {
        let store = makeStore()
        defaults.set(Data("stale".utf8), forKey: "com.ensemble.playback.snapshot")
        defaults.set(Data("stale".utf8), forKey: "com.ensemble.playback.queue")

        store.save(queue: [], history: [], currentIndex: -1, currentTime: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.snapshot"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.queue"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.history"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentIndex"))
        XCTAssertNil(defaults.object(forKey: "com.ensemble.playback.currentTime"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    private func makeStore() -> PlaybackQueueStore {
        PlaybackQueueStore(
            defaults: defaults,
            snapshotURL: snapshotURL,
            progressURL: progressURL
        )
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
