import AVFoundation
import Foundation
@testable import EnsembleCore
import XCTest

final class AudioPlaybackEngineStreamingTests: XCTestCase {
    func testStreamingRenderHealthReportsSustainedPostStartUnderrunOnce() {
        var health = StreamingRenderHealth(recoveryThresholdFrames: 100)

        XCTAssertFalse(health.observe(renderedFrames: 0, requestedFrames: 100, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 50, requestedFrames: 50, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 25, requestedFrames: 50, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 50, requestedFrames: 50, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 0, requestedFrames: 75, isComplete: false))
        XCTAssertTrue(health.observe(renderedFrames: 0, requestedFrames: 25, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 0, requestedFrames: 100, isComplete: false))
    }

    func testStreamingRenderHealthIgnoresNormalCompletion() {
        var health = StreamingRenderHealth(recoveryThresholdFrames: 100)

        XCTAssertFalse(health.observe(renderedFrames: 100, requestedFrames: 100, isComplete: false))
        XCTAssertFalse(health.observe(renderedFrames: 0, requestedFrames: 100, isComplete: true))
    }

    func testOffsetStreamingBufferedProgressMapsOntoTrackTimeline() {
        XCTAssertEqual(
            AudioPlaybackEngine.absoluteStreamingBufferedProgress(
                0.10,
                startTime: 4,
                duration: 10
            ),
            0.50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioPlaybackEngine.absoluteStreamingBufferedProgress(
                1,
                startTime: 4,
                duration: 10
            ),
            1,
            accuracy: 0.001
        )
    }

    func testZeroStartStreamingBufferedProgressRemainsStreamRelative() {
        XCTAssertEqual(
            AudioPlaybackEngine.absoluteStreamingBufferedProgress(
                0.25,
                startTime: 0,
                duration: 10
            ),
            0.25,
            accuracy: 0.001
        )
    }

    func testOffsetStreamingSourceInitialBufferedProgressStartsAtOffset() {
        let source = PlaybackSource.transcodedHTTP(
            URLRequest(url: URL(string: "https://audio.test/start.mp3")!),
            metadata: PlaybackSourceMetadata(
                trackId: "offset-source",
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 10,
                startTime: 4,
                isSeekable: false,
                cacheFileExtension: "mp3"
            )
        )

        XCTAssertEqual(source.initialBufferedProgress, 0.4, accuracy: 0.001)
    }

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

    func testStreamingSourceResumesAfterPause() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let engine = AudioPlaybackEngine()
        try engine.setup()
        let rendered = expectation(description: "streaming source rendered")
        engine.onFirstAudibleRender = { _ in rendered.fulfill() }
        let source = PlaybackSource.directHTTP(
            URLRequest(url: fixtureURL),
            metadata: PlaybackSourceMetadata(
                trackId: "streaming-resume-test",
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 5,
                isSeekable: true,
                cacheFileExtension: "m4a"
            )
        )

        try await engine.load(source: source, trackId: "streaming-resume-test")
        try engine.play()
        await fulfillment(of: [rendered], timeout: 1)
        guard let sourceNode = streamingSourceNode(from: engine),
              let playingSampleTime = sourceNode.lastRenderTime?.sampleTime else {
            return XCTFail("Expected the streaming source node to render")
        }
        engine.pause()

        try engine.resume()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThan(sourceNode.lastRenderTime?.sampleTime ?? 0, playingSampleTime)
        engine.stop()
    }

    func testStreamingFailureAfterFormatReadyReachesEngineErrorHandler() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        StreamingFailureURLProtocol.payload = try Data(contentsOf: fixtureURL)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StreamingFailureURLProtocol.self]
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-failure-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: URLRequest(url: URL(string: "https://stream-failure.test/file.m4a")!),
            fileExtension: "m4a",
            cacheURL: cacheURL,
            duration: 5,
            sessionConfiguration: sessionConfiguration
        ))

        let engine = AudioPlaybackEngine()
        let failed = expectation(description: "streaming failure reached engine")
        engine.onError = { error, trackId in
            XCTAssertEqual((error as NSError).code, NSURLErrorNetworkConnectionLost)
            XCTAssertNil(trackId)
            failed.fulfill()
        }
        let format = try await engine.startStreamingPipeline(
            pipeline,
            trackId: "streaming-failure-test",
            startTime: 0,
            duration: 5
        )

        XCTAssertGreaterThan(format.sampleRate, 0)
        await fulfillment(of: [failed], timeout: 1)
        pipeline.cancel()
    }

    private func streamingSourceNode(from engine: AudioPlaybackEngine) -> AVAudioSourceNode? {
        guard let wrappedNode = Mirror(reflecting: engine).children
            .first(where: { $0.label == "streamingSourceNode" })?.value else {
            return nil
        }
        return Mirror(reflecting: wrappedNode).children.first?.value as? AVAudioSourceNode
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

    func testStreamingSourceStartTimeAnchorsPlaybackClock() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let engine = AudioPlaybackEngine()
        try engine.setup()
        let trackId = "streaming-start-offset-test"
        let source = PlaybackSource.directHTTP(
            URLRequest(url: fixtureURL),
            metadata: PlaybackSourceMetadata(
                trackId: trackId,
                ratingKey: "1",
                estimatedContentLength: nil,
                duration: 10,
                startTime: 4,
                isSeekable: true,
                cacheFileExtension: "m4a"
            )
        )

        try await engine.load(source: source, trackId: trackId)
        try engine.play()

        XCTAssertEqual(engine.currentTime(), 4, accuracy: 0.5)
        engine.stop()
    }
}

private final class StreamingFailureURLProtocol: URLProtocol {
    static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stream-failure.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mp4"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() {}
}
