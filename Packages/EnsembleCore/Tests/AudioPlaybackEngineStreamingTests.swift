import Foundation
@testable import EnsembleCore
import XCTest

final class AudioPlaybackEngineStreamingTests: XCTestCase {
    func testEngineLoadsStreamingSourceThroughSourceContract() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let engine = AudioPlaybackEngine()
        try engine.setup()
        let trackId = "streaming-engine-test"
        let source = PlaybackSource.directHTTP(
            URLRequest(url: fixtureURL),
            metadata: PlaybackSourceMetadata(
                trackId: trackId,
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 1,
                isSeekable: true,
                cacheFileExtension: "m4a"
            )
        )

        try await engine.load(source: source, trackId: trackId)

        XCTAssertEqual(engine.currentTrackId, trackId)
        try engine.play()
        engine.stop()
    }
}
