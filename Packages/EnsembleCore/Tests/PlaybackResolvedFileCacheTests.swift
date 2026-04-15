import XCTest
@testable import EnsembleCore

@MainActor
final class PlaybackResolvedFileCacheTests: XCTestCase {
    func testStoreEvictsLeastRecentlyUsedTrack() {
        let cache = PlaybackResolvedFileCache(maxCachedFileURLs: 2)
        let firstURL = URL(fileURLWithPath: "/tmp/first.mp3")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mp3")
        let thirdURL = URL(fileURLWithPath: "/tmp/third.mp3")

        XCTAssertEqual(cache.store(firstURL, for: "one"), [])
        XCTAssertEqual(cache.store(secondURL, for: "two"), [])
        _ = cache.cachedFileURL(for: "one")

        let evicted = cache.store(thirdURL, for: "three")

        XCTAssertEqual(evicted, ["two"])
        XCTAssertNotNil(cache.cachedFileURL(for: "one"))
        XCTAssertNil(cache.cachedFileURL(for: "two"))
        XCTAssertNotNil(cache.cachedFileURL(for: "three"))
    }

    func testBeginPrefetchRejectsDuplicateTrackUntilEnded() {
        let cache = PlaybackResolvedFileCache(maxCachedFileURLs: 2)

        XCTAssertTrue(cache.beginPrefetch(for: "track-1"))
        XCTAssertFalse(cache.beginPrefetch(for: "track-1"))

        cache.endPrefetch(for: "track-1")
        XCTAssertTrue(cache.beginPrefetch(for: "track-1"))
    }

    func testEvictUpcomingStaleTrackURLsOnlyRemovesUnscheduledEntries() {
        let cache = PlaybackResolvedFileCache(maxCachedFileURLs: 4)
        _ = cache.store(URL(fileURLWithPath: "/tmp/one.mp3"), for: "one")
        _ = cache.store(URL(fileURLWithPath: "/tmp/two.mp3"), for: "two")
        _ = cache.store(URL(fileURLWithPath: "/tmp/three.mp3"), for: "three")

        let stale = cache.evictUpcomingStaleTrackURLs(
            upcomingTrackIDs: ["one", "two", "three"],
            alreadyScheduledTrackIDs: ["two"]
        )

        XCTAssertEqual(Set(stale), Set(["one", "three"]))
        XCTAssertNil(cache.cachedFileURL(for: "one"))
        XCTAssertNotNil(cache.cachedFileURL(for: "two"))
        XCTAssertNil(cache.cachedFileURL(for: "three"))
    }
}
