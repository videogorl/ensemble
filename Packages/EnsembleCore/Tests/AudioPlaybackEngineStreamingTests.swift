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

    func testKnownDurationStreamingSourceCompletesAtDuration() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let engine = AudioPlaybackEngine()
        try engine.setup()
        let completed = expectation(description: "streaming playback completed")
        engine.onPlaybackComplete = {
            completed.fulfill()
        }

        let trackId = "streaming-duration-completion-test"
        let source = PlaybackSource.directHTTP(
            URLRequest(url: fixtureURL),
            metadata: PlaybackSourceMetadata(
                trackId: trackId,
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 0.2,
                isSeekable: true,
                cacheFileExtension: "m4a"
            )
        )

        try await engine.load(source: source, trackId: trackId)
        try engine.play()
        await fulfillment(of: [completed], timeout: 2)
        engine.stop()
    }

    func testActiveStreamingSeekFailsInsteadOfMovingClock() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let engine = AudioPlaybackEngine()
        try engine.setup()
        let trackId = "streaming-seek-test"
        let source = PlaybackSource.directHTTP(
            URLRequest(url: fixtureURL),
            metadata: PlaybackSourceMetadata(
                trackId: trackId,
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 5,
                isSeekable: true,
                cacheFileExtension: "m4a"
            )
        )

        try await engine.load(source: source, trackId: trackId)
        XCTAssertThrowsError(try engine.seek(to: 2)) { error in
            XCTAssertEqual(error as? AudioPlaybackEngineError, .streamingSeekUnavailable)
        }
        XCTAssertEqual(engine.currentTime(), 0, accuracy: 0.2)
        engine.stop()
    }
}
