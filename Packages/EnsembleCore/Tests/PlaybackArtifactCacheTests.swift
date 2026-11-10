@testable import EnsembleCore
import XCTest

final class PlaybackArtifactCacheTests: XCTestCase {
    func testExactQualityAndFingerprintLookupWithLRUEviction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlaybackArtifactCache(directory: directory, byteBudget: 8)

        func record(_ identity: String, fingerprint: String, quality: String) throws -> URL {
            let key = PlaybackArtifactKey(
                trackIdentity: identity,
                sourceFingerprint: fingerprint,
                requestedQuality: quality,
                delivery: .direct,
                fileExtension: "mp3",
                startTime: 0
            )
            let url = try cache.partialURL(for: key)
            try Data(repeating: 1, count: 4).write(to: url)
            return try cache.recordCompleted(fileURL: url, key: key, expectedDuration: nil, mediaVerified: true)
        }

        let first = try record("first", fingerprint: "first-v1", quality: "high")
        _ = try record("second", fingerprint: "second-v1", quality: "high")

        XCTAssertNil(cache.completedArtifact(
            trackIdentity: "first",
            sourceFingerprint: "first-v1",
            requestedQuality: "medium",
            requireDirect: false
        ))
        XCTAssertNil(cache.completedArtifact(
            trackIdentity: "first",
            sourceFingerprint: "first-v2",
            requestedQuality: "high",
            requireDirect: false
        ))
        XCTAssertEqual(cache.completedArtifact(
            trackIdentity: "first",
            sourceFingerprint: "first-v1",
            requestedQuality: "high",
            requireDirect: false
        ), first)

        _ = try record("third", fingerprint: "third-v1", quality: "high")

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertNil(cache.completedArtifact(
            trackIdentity: "second",
            sourceFingerprint: "second-v1",
            requestedQuality: "high",
            requireDirect: false
        ))
        XCTAssertEqual(cache.size(), 8)
    }

    /// A direct original is served only once its media was verified. An entry written before that check
    /// (no marker) is a miss, and a verified entry of the same key replaces it. A transcode needs no marker.
    func testUnverifiedDirectEntryIsAMissAndAVerifiedOneReplacesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlaybackArtifactCache(directory: directory, byteBudget: 1 << 20)
        func key(_ delivery: PlaybackArtifactDelivery) -> PlaybackArtifactKey {
            PlaybackArtifactKey(trackIdentity: "t", sourceFingerprint: "fp", requestedQuality: "q",
                                delivery: delivery, fileExtension: "mp3", startTime: 0)
        }
        func record(_ delivery: PlaybackArtifactDelivery, verified: Bool) throws -> URL {
            let url = try cache.partialURL(for: key(delivery))
            try Data(repeating: 1, count: 8).write(to: url)
            return try cache.recordCompleted(fileURL: url, key: key(delivery), expectedDuration: nil, mediaVerified: verified)
        }
        func lookup() -> URL? {
            cache.completedArtifact(trackIdentity: "t", sourceFingerprint: "fp", requestedQuality: "q", requireDirect: false)
        }

        let legacy = try record(.direct, verified: false)
        XCTAssertNil(lookup(), "an unverified original is not served")
        XCTAssertFalse(cache.hasCompletedArtifact(trackIdentity: "t", sourceFingerprint: "fp", requestedQuality: "q", requireDirect: false))
        let verified = try record(.direct, verified: true)
        XCTAssertEqual(lookup(), verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "the verified entry replaces the unverified one")

        cache.removeArtifact(at: verified)
        let transcode = try record(.transcode, verified: false)
        XCTAssertEqual(lookup(), transcode)
    }
}
