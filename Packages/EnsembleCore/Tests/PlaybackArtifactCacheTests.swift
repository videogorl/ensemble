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
            return try cache.recordCompleted(fileURL: url, key: key, expectedDuration: nil)
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
}
