import AVFoundation
import Foundation
@testable import EnsembleCore
import XCTest

/// File-backed playhead tests that drive a real AVAudioEngine.
@MainActor
final class AudioPlaybackEnginePositionTests: XCTestCase {
    private var fileURLs: [URL] = []

    override func tearDown() {
        fileURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        fileURLs = []
        super.tearDown()
    }

    func testPauseAfterRouteChangeAndGaplessAdvanceUsesCurrentItemPlayhead() async throws {
        let engine = AudioPlaybackEngine()
        try engine.setup()
        defer { engine.stop() }
        try engine.load(fileURL: makeSilentFile(seconds: 0.6), trackId: "first", playbackGeneration: 1)
        try engine.scheduleNext(fileURL: makeSilentFile(seconds: 5), trackId: "second")
        let advanced = expectation(description: "gapless advance")
        var advancedAt: CFTimeInterval = 0
        engine.onTrackAdvance = { trackID, _ in
            guard trackID == "second" else { return }
            advancedAt = CACurrentMediaTime()
            advanced.fulfill()
        }

        try engine.play()
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.prepareForRouteChange()
        await fulfillment(of: [advanced], timeout: 5)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        // An interruption pause long after the route change must not reuse its snapshot.
        engine.pause()

        XCTAssertEqual(engine.currentTrackId, "second")
        XCTAssertEqual(engine.currentTimeSubject.value.time, CACurrentMediaTime() - advancedAt, accuracy: 0.3)
    }

    /// Relaunch restore loads the item paused, then resume plays it; the gapless
    /// advance must still reach the service under the restored session.
    func testRestoredPausedLoadReportsGaplessAdvanceAfterResume() async throws {
        let engine = AudioPlaybackEngine()
        try engine.setup()
        defer { engine.stop() }
        let adapter = NativePlaybackEngineAdapter(engine: engine)
        let advanced = expectation(description: "item changed")
        adapter.onEvent = { envelope in
            if case let .itemChanged(trackID, via) = envelope.event {
                XCTAssertEqual(trackID, "second")
                XCTAssertEqual(via, .gapless)
                XCTAssertEqual(envelope.session.rawValue, 7)
                advanced.fulfill()
            }
        }

        adapter.willLoad(trackID: "first")
        try engine.load(fileURL: makeSilentFile(seconds: 0.4), trackId: "first", playbackGeneration: 7)
        try engine.scheduleNext(fileURL: makeSilentFile(seconds: 2), trackId: "second")
        engine.adoptPlaybackGeneration(7)
        try engine.resume()

        await fulfillment(of: [advanced], timeout: 5)
    }

    /// The player node's sample clock keeps counting across pause and gapless
    /// segments, so resume must not count already-played audio twice.
    func testResumeAfterGaplessAdvanceContinuesFromPausedPlayhead() async throws {
        let engine = AudioPlaybackEngine()
        try engine.setup()
        defer { engine.stop() }
        try engine.load(fileURL: makeSilentFile(seconds: 0.5), trackId: "first", playbackGeneration: 1)
        try engine.scheduleNext(fileURL: makeSilentFile(seconds: 5), trackId: "second")
        let advanced = expectation(description: "gapless advance")
        engine.onTrackAdvance = { _, _ in advanced.fulfill() }

        try engine.play()
        await fulfillment(of: [advanced], timeout: 5)
        try await Task.sleep(nanoseconds: 800_000_000)
        engine.pause()
        let pausedAt = engine.currentTimeSubject.value.time
        try engine.resume()
        let resumedAt = CACurrentMediaTime()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertGreaterThan(pausedAt, 0.5)
        XCTAssertEqual(engine.currentTime(), pausedAt + CACurrentMediaTime() - resumedAt, accuracy: 0.25)
    }

    func testRenderClockIsTrustedOnlyNearTheObservedPlayhead() {
        let cases: [(render: TimeInterval?, observed: TimeInterval, expected: TimeInterval?)] = [
            (nil, 10, nil),
            (10.5, 10, 10.5),
            (8.1, 10, 8.1),
            (856.45, 305.47, nil),
            (2.6, 0.3, nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                AudioPlaybackEngine.trustedRenderClockPosition(
                    testCase.render,
                    observedPosition: testCase.observed
                ),
                testCase.expected,
                "render=\(String(describing: testCase.render)) observed=\(testCase.observed)"
            )
        }
    }

    func testRouteRecoverySnapshotAppliesOnlyToItsItemBriefly() {
        let snapshot = AudioPlaybackEngine.RouteRecoverySnapshot(position: 42, trackId: "a", capturedAt: 100)
        let lifetime = AudioPlaybackEngine.routeRecoverySnapshotLifetime
        let cases: [(snapshot: AudioPlaybackEngine.RouteRecoverySnapshot?, trackId: String?, now: TimeInterval, expected: TimeInterval?)] = [
            (snapshot, "a", 101, 42),
            (snapshot, "a", 100 + lifetime, 42),
            (snapshot, "a", 100 + lifetime + 0.1, nil),
            (snapshot, "b", 101, nil),
            (snapshot, nil, 101, nil),
            (nil, "a", 101, nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                AudioPlaybackEngine.usableRouteRecoveryPosition(
                    testCase.snapshot,
                    currentTrackId: testCase.trackId,
                    now: testCase.now
                ),
                testCase.expected,
                "track=\(testCase.trackId ?? "nil") now=\(testCase.now)"
            )
        }
    }

    private func makeSilentFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-position-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        fileURLs.append(url)
        return url
    }
}
