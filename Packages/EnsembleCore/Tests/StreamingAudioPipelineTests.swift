import AVFoundation
@testable import EnsembleCore
import XCTest

final class StreamingAudioPipelineTests: XCTestCase {
    func testDefaultConfigurationWaitsForConnectivityWithoutSpecialTrafficClass() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/file.m4a")))
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-pipeline-\(UUID().uuidString).m4a")

        let config = StreamingAudioPipeline.Configuration(
            request: request,
            fileExtension: "m4a",
            cacheURL: cacheURL
        )

        XCTAssertEqual(config.sessionConfiguration.networkServiceType, .default)
        XCTAssertTrue(config.sessionConfiguration.waitsForConnectivity)
    }

    func testPipelineEmitsPCMBeforeHTTPStreamCompletesAndWritesCache() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }
        let data = try Data(contentsOf: fixtureURL)
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: fixtureURL).load(.duration))
        DelayedAudioURLProtocol.configure(data: data, chunkSize: 4096, delay: 0.002)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedAudioURLProtocol.self]
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-pipeline-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/file.m4a")))
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: request,
            fileExtension: "m4a",
            cacheURL: cacheURL,
            duration: duration,
            sessionConfiguration: config
        ))

        let firstPCM = expectation(description: "first PCM")
        let firstBufferedProgress = expectation(description: "first buffered progress")
        let completed = expectation(description: "completed")
        var servedAtFirstPCM = 0
        var servedAtFirstBufferedProgress = 0
        var outputFormat: AVAudioFormat?
        var bufferedProgressValues: [Double] = []

        pipeline.onFormatReady = { outputFormat = $0 }
        pipeline.onFirstPCM = {
            servedAtFirstPCM = DelayedAudioURLProtocol.servedBytes
            firstPCM.fulfill()
        }
        pipeline.onBufferedProgress = { progress in
            bufferedProgressValues.append(progress)
            if progress > 0, progress < 1, servedAtFirstBufferedProgress == 0 {
                servedAtFirstBufferedProgress = DelayedAudioURLProtocol.servedBytes
                firstBufferedProgress.fulfill()
            }
        }
        pipeline.onComplete = { _ in completed.fulfill() }
        pipeline.onFailure = { error in XCTFail("pipeline failed: \(error)") }

        pipeline.start()
        await fulfillment(of: [firstPCM, firstBufferedProgress], timeout: 2)

        let format = try XCTUnwrap(outputFormat)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let read = try pipeline.read(into: output, frameCount: 512)

        XCTAssertGreaterThan(read, 0)
        XCTAssertLessThan(servedAtFirstPCM, data.count)
        XCTAssertLessThan(servedAtFirstBufferedProgress, data.count)
        XCTAssertGreaterThan(bufferedProgressValues.first ?? 0, 0)

        let activeDiagnostics = pipeline.diagnostics()
        XCTAssertEqual(activeDiagnostics.taskState, .running)
        XCTAssertNotNil(activeDiagnostics.secondsSinceLastByte)
        XCTAssertNotNil(activeDiagnostics.secondsSinceLastPCM)
        XCTAssertGreaterThan(activeDiagnostics.receivedBytes, 0)
        XCTAssertGreaterThan(activeDiagnostics.decodedFrames, 0)
        XCTAssertGreaterThanOrEqual(activeDiagnostics.bufferedFrames, 0)
        XCTAssertFalse(activeDiagnostics.isComplete)

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(bufferedProgressValues.last ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(pipeline.diagnostics().isComplete)
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attrs[.size] as? Int64, Int64(data.count))
    }

    func testPipelineFailsWhenStartupNeverProducesAudioFormat() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StalledAudioURLProtocol.self]
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-timeout-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/stalled.m4a"))),
            fileExtension: "m4a",
            cacheURL: cacheURL,
            startupTimeout: 0.05,
            sessionConfiguration: config
        ))
        let failed = expectation(description: "startup timed out")
        pipeline.onFailure = { error in
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
            failed.fulfill()
        }

        pipeline.start()

        await fulfillment(of: [failed], timeout: 1)
    }

    func testNetworkIngestionFinishesWhilePCMConsumerIsStalled() async throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }
        let data = try Data(contentsOf: fixtureURL)
        DelayedAudioURLProtocol.configure(data: data, chunkSize: 16_384, delay: 0)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAudioURLProtocol.self]
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-backpressure-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/backpressure.m4a"))),
            fileExtension: "m4a",
            cacheURL: cacheURL,
            bufferSeconds: 0.01,
            sessionConfiguration: configuration
        ))
        defer {
            pipeline.onFailure = nil
            pipeline.cancel()
        }
        pipeline.onFailure = { error in XCTFail("pipeline failed: \(error)") }

        pipeline.start()

        var cachedBytes: Int64 = 0
        for _ in 0 ..< 200 {
            let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
            cachedBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if cachedBytes == Int64(data.count) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(cachedBytes, Int64(data.count))
        XCTAssertFalse(pipeline.diagnostics().isComplete)
    }

    /// A download reports its end once, however it ends, so the prefetch it deferred can run.
    func testDownloadEndIsReportedOnceOnSuccessAndOnCancel() async throws {
        for succeeds in [true, false] {
            DelayedAudioURLProtocol.configure(data: Data(count: 4096), chunkSize: 4096, delay: 0)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [succeeds ? DelayedAudioURLProtocol.self : StalledAudioURLProtocol.self]
            let cacheURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("streaming-end-\(UUID().uuidString).mp3")
            defer { try? FileManager.default.removeItem(at: cacheURL) }
            let pipeline = StreamingAudioPipeline(configuration: .init(
                request: URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/end.mp3"))),
                fileExtension: "mp3",
                cacheURL: cacheURL,
                sessionConfiguration: configuration
            ))
            let ends = LockedEnds()
            pipeline.onDownloadEnd = { ends.increment() }
            if succeeds {
                _ = try await pipeline.downloadedFile()
            } else {
                pipeline.startDownload()
                pipeline.cancel()
            }
            pipeline.cancel()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(ends.count, 1, succeeds ? "success" : "cancel")
        }
    }

    // MARK: - Dropped downloads

    private enum Outcome { case resumed, completesWithoutResume, failsAfterReserve, failsAtOnce }

    /// A drop after startup keeps the buffered audio playing and resumes from the right byte; a resume that
    /// cannot be proved safe, a transcode, or a dead connection plays the reserve out and then fails.
    func testDroppedDownloadResumesOrFailsAfterTheReserve() async throws {
        let wav = Self.wavFixture(seconds: 4)
        let baseline = try await run(payload: wav, replies: [.ranged(dropAfter: nil)]).samples
        XCTAssertGreaterThan(baseline.count, 80_000)
        let drop = wav.count * 2 / 5
        let rows: [(name: String, etag: String?, replies: [ScriptedURLProtocol.Reply], outcome: Outcome, requests: Int)] = [
            ("drop, resumes from the byte it stopped at", "\"v1\"", [.ranged(dropAfter: drop), .ranged(dropAfter: nil)], .resumed, 2),
            ("every byte arrived, then the connection failed", "\"v1\"", [.ranged(dropAfter: wav.count)], .completesWithoutResume, 1),
            ("two drops in a row", "\"v1\"", [.ranged(dropAfter: drop), .ranged(dropAfter: 20_000), .ranged(dropAfter: nil)], .resumed, 3),
            ("ETag changed", "\"v1\"", [.ranged(dropAfter: drop), .changedETag], .failsAfterReserve, 2),
            ("server answers 200 to the Range request", "\"v1\"", [.ranged(dropAfter: drop), .full], .failsAfterReserve, 2),
            ("Content-Range does not match", "\"v1\"", [.ranged(dropAfter: drop), .wrongRange], .failsAfterReserve, 2),
            ("transcode: no ETag or length", nil, [.ranged(dropAfter: drop)], .failsAfterReserve, 1),
            ("dead connection: attempts time out until the window ends", "\"v1\"", [.ranged(dropAfter: drop), .timesOut, .timesOut], .failsAfterReserve, 3),
            ("drop before any byte is not resumed", "\"v1\"", [.timesOut], .failsAtOnce, 1),
        ]
        for row in rows {
            let result = try await run(payload: wav, etag: row.etag, replies: row.replies)
            XCTAssertEqual(result.requests.count, row.requests, row.name)
            switch row.outcome {
            case .resumed:
                XCTAssertNil(result.failure, row.name)
                XCTAssertEqual(result.samples, baseline, "\(row.name): decoded audio is continuous and complete")
                XCTAssertTrue(result.completed, row.name)
                let range = result.requests[1].value(forHTTPHeaderField: "Range")
                XCTAssertEqual(range, "bytes=\(drop)-", row.name)
            case .completesWithoutResume:
                XCTAssertNil(result.failure, row.name)
                XCTAssertEqual(result.samples, baseline, row.name)
                XCTAssertTrue(result.completed, row.name)
            case .failsAfterReserve:
                XCTAssertNotNil(result.failure, row.name)
                XCTAssertGreaterThan(result.samples.count, 0, "\(row.name): the reserve plays before the failure")
                XCTAssertEqual(result.samples, Array(baseline.prefix(result.samples.count)), "\(row.name): reserve is the start of the track")
            case .failsAtOnce:
                XCTAssertNotNil(result.failure, row.name)
                XCTAssertEqual(result.samples.count, 0, row.name)
            }
        }
    }

    /// Every request is bounded by the idle timeout, not URLSession's 60 s.
    func testRequestsGiveUpOnADeadConnectionAfterFifteenSeconds() async throws {
        let result = try await run(payload: Self.wavFixture(seconds: 1), replies: [.ranged(dropAfter: nil)], idleTimeout: nil)
        XCTAssertEqual(result.requests.first?.timeoutInterval, 15)
    }

    /// A path change restarts a download that has gone quiet at once (the retry pause is far longer than the
    /// test), leaves one that is still receiving alone, and does not retry a resume that cannot connect.
    func testPathChangeRestartsOnlyAStalledDownload() async throws {
        let wav = Self.wavFixture(seconds: 4)
        let baseline = try await run(payload: wav, replies: [.ranged(dropAfter: nil)]).samples
        let stall = wav.count / 2
        let stalled = try await run(payload: wav, replies: [.stalls(afterBytes: stall), .ranged(dropAfter: nil)], retryInterval: 60, healthyWindow: 0.2) { pipeline in
            while pipeline.diagnostics().receivedBytes < stall { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 400_000_000)
            pipeline.networkPathChanged()
        }
        XCTAssertNil(stalled.failure, "stalled")
        XCTAssertEqual(stalled.samples, baseline, "stalled")
        XCTAssertEqual(stalled.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=\(stall)-")

        let healthy = try await run(payload: wav, replies: [.trickles], healthyWindow: 5) { pipeline in
            while pipeline.diagnostics().receivedBytes < 40_000 { try await Task.sleep(nanoseconds: 2_000_000) }
            pipeline.networkPathChanged()
        }
        XCTAssertNil(healthy.failure, "healthy")
        XCTAssertEqual(healthy.samples, baseline, "healthy")
        XCTAssertEqual(healthy.requests.count, 1, "a transfer that is still receiving is not restarted")

        let unreachable = try await run(payload: wav, replies: [.stalls(afterBytes: stall), .timesOut], healthyWindow: 0.2) { pipeline in
            while pipeline.diagnostics().receivedBytes < stall { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 400_000_000)
            pipeline.networkPathChanged()
        }
        XCTAssertNotNil(unreachable.failure, "unreachable")
        XCTAssertEqual(unreachable.requests.count, 2, "one attempt after the path changed, then the service reloads")
    }

    /// A spliced direct download goes through the completed-artifact validation (size, duration) and is
    /// registered in the stream cache.
    func testSplicedDirectDownloadIsRecordedInTheStreamCache() async throws {
        let wav = Self.wavFixture(seconds: 12)
        let cache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("splice-cache-\(UUID().uuidString)"),
            byteBudget: 1 << 24
        )
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let key = PlaybackArtifactKey(trackIdentity: "splice-track", sourceFingerprint: "fp", requestedQuality: "original",
                                      delivery: .direct, fileExtension: "wav", startTime: 0)
        let result = try await run(
            payload: wav, replies: [.ranged(dropAfter: wav.count / 3), .ranged(dropAfter: nil)],
            duration: 12, artifactKey: key, artifactCache: cache
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.requests.count, 2)
        let cached = try XCTUnwrap(cache.completedArtifact(
            trackIdentity: key.trackIdentity, sourceFingerprint: "fp", requestedQuality: "original", requireDirect: true
        ))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cached.path))[.size] as? Int, wav.count)
    }

    /// Only an original is judged by its media, and only the media judges it: bytes the decoder
    /// rejects, and audio ending under half of what the file's own container states, are damage;
    /// a transcode is never reported as damaged, so it can never fall back.
    func testOriginalMediaDamageIsReportedAndATranscodeIsNeverJudged() async throws {
        let whole = try AudioFixtures.flac(seconds: 24)
        // The FLAC header states 24 s; a quarter of the bytes arrive.
        let truncated = Data(whole.prefix(whole.count / 4))
        let cache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("damage-cache-\(UUID().uuidString)"),
            byteBudget: 1 << 26
        )
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let cases: [(name: String, delivery: PlaybackArtifactDelivery, payload: Data, damaged: Bool)] = [
            ("original, audio ends early", .direct, truncated, true),
            ("original, whole file", .direct, whole, false),
            ("original, bytes are not audio", .direct, Data(repeating: 0, count: 600), true),
            ("transcode, audio ends early", .transcode, truncated, false),
            ("transcode, bytes are not audio", .transcode, Data(repeating: 0, count: 600), false),
        ]
        for (index, item) in cases.enumerated() {
            let key = PlaybackArtifactKey(trackIdentity: "damage-\(index)", sourceFingerprint: "fp", requestedQuality: "original",
                                          delivery: item.delivery, fileExtension: "flac", startTime: 0)
            let result = try await run(
                payload: item.payload, replies: [.ranged(dropAfter: nil)],
                duration: 24, artifactKey: key, artifactCache: cache, fileExtension: "flac"
            )
            var isDamage = false
            if case ProgressiveStreamError.damagedOriginal? = result.failure ?? result.earlyEnd { isDamage = true }
            XCTAssertEqual(isDamage, item.damaged, "\(item.name): \(String(describing: result.failure ?? result.earlyEnd))")
            if item.damaged {
                XCTAssertNil(cache.completedArtifact(
                    trackIdentity: key.trackIdentity, sourceFingerprint: "fp", requestedQuality: "original", requireDirect: false
                ), "\(item.name): a damaged original is not replayed from the cache")
            }
        }
    }

    /// A played original is decoded start to end when its download finishes, before it is registered: a
    /// whole file is cached as verified; a damaged one is never cached, is reported once, and the audio
    /// of its good part keeps playing.
    func testFinishedOriginalIsVerifiedBeforeItIsCached() async throws {
        let whole = try AudioFixtures.flac(seconds: 24)
        let cache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("verify-cache-\(UUID().uuidString)"),
            byteBudget: 1 << 26
        )
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        for (name, payload, damaged) in [("whole", whole, false), ("truncated", Data(whole.prefix(whole.count / 4)), true)] {
            let key = PlaybackArtifactKey(trackIdentity: "verify-\(name)", sourceFingerprint: "fp", requestedQuality: "original",
                                          delivery: .direct, fileExtension: "flac", startTime: 0)
            let result = try await run(
                payload: payload, replies: [.ranged(dropAfter: nil)], duration: 24,
                artifactKey: key, artifactCache: cache, fileExtension: "flac"
            ) { _ in try await Task.sleep(nanoseconds: 1_500_000_000) }
            XCTAssertEqual(result.damageFound, damaged, name)
            XCTAssertGreaterThan(result.samples.count, 22_050, "\(name): the good part plays")
            let cached = cache.completedArtifact(
                trackIdentity: key.trackIdentity, sourceFingerprint: "fp", requestedQuality: "original", requireDirect: true
            )
            XCTAssertEqual(cached != nil, !damaged, "\(name): only a verified original is cached")
        }
    }

    /// Next, seek, Pause's refresh and a new play cancel the pipeline: a pending resume never starts.
    func testCancelDuringResumeStartsNoRequest() async throws {
        let wav = Self.wavFixture(seconds: 4)
        let result = try await run(payload: wav, replies: [.ranged(dropAfter: wav.count / 2), .ranged(dropAfter: 1_000)], retryInterval: 0.3) { pipeline in
            while ScriptedURLProtocol.requests.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
            try await Task.sleep(nanoseconds: 50_000_000) // the resume dropped again: the next one is pending
            pipeline.cancel()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(result.requests.count, 2)
        XCTAssertEqual((result.failure as NSError?)?.code, NSURLErrorCancelled)
    }

    private struct RunResult {
        var samples: [Float]
        var requests: [URLRequest]
        var failure: Error?
        var completed: Bool
        var earlyEnd: Error?
        var damageFound: Bool
    }

    /// Plays one stubbed stream the way the engine's render callback does, until it completes or fails.
    private func run(
        payload: Data,
        etag: String? = "\"v1\"",
        replies: [ScriptedURLProtocol.Reply],
        idleTimeout: TimeInterval? = 15,
        retryInterval: TimeInterval = 0.01,
        healthyWindow: TimeInterval = 2,
        duration: TimeInterval? = nil,
        artifactKey: PlaybackArtifactKey? = nil,
        artifactCache: PlaybackArtifactCache = .shared,
        fileExtension: String = "wav",
        during: ((StreamingAudioPipeline) async throws -> Void)? = nil
    ) async throws -> RunResult {
        let clock = ScriptedURLProtocol.configure(payload: payload, etag: etag, replies: replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let cacheURL = try artifactKey.map { try artifactCache.partialURL(for: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).wav")
        defer { if artifactKey == nil { try? FileManager.default.removeItem(at: cacheURL) } }
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/file.\(fileExtension)"))),
            fileExtension: fileExtension,
            cacheURL: cacheURL,
            duration: duration,
            sessionConfiguration: configuration,
            artifactKey: artifactKey,
            artifactCache: artifactCache,
            idleTimeout: idleTimeout ?? 15,
            resumeWindow: 30,
            resumeRetryInterval: retryInterval,
            healthyWindow: healthyWindow,
            now: { clock.now }
        ))
        let state = RunState()
        pipeline.onFormatReady = { state.format = $0 }
        pipeline.onFailure = { state.failure = $0 }
        pipeline.onComplete = { _ in state.completed = true }
        pipeline.onDamageFound = { _ in state.damageFound = true }
        pipeline.start()
        let during = Task { try await during?(pipeline) }
        defer { pipeline.cancel() }

        var samples: [Float] = []
        let deadline = Date().addingTimeInterval(10)
        var drained = false
        while Date() < deadline, !drained {
            guard let format = state.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else {
                drained = state.finished || pipeline.isComplete
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            buffer.frameLength = 512
            let read = pipeline.render(into: buffer.mutableAudioBufferList, frameCount: 512)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: read)
            if read == 0 {
                drained = state.finished || pipeline.isComplete
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        try await during.value
        return RunResult(
            samples: samples, requests: ScriptedURLProtocol.requests, failure: state.failure,
            completed: state.completed, earlyEnd: pipeline.earlyEndError, damageFound: state.damageFound
        )
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _format: AVAudioFormat?
        private var _failure: Error?
        private var _completed = false
        var format: AVAudioFormat? { get { lock.lock(); defer { lock.unlock() }; return _format } set { lock.lock(); _format = newValue; lock.unlock() } }
        var failure: Error? { get { lock.lock(); defer { lock.unlock() }; return _failure } set { lock.lock(); _failure = newValue; lock.unlock() } }
        var completed: Bool { get { lock.lock(); defer { lock.unlock() }; return _completed } set { lock.lock(); _completed = newValue; lock.unlock() } }
        var damageFound: Bool { get { lock.lock(); defer { lock.unlock() }; return _damageFound } set { lock.lock(); _damageFound = newValue; lock.unlock() } }
        private var _damageFound = false
        var finished: Bool { failure != nil || completed }
    }

    /// 22.05 kHz mono 16-bit PCM WAV of a deterministic tone.
    private static func wavFixture(seconds: Int) -> Data {
        let rate = 22_050
        var pcm = Data()
        for index in 0 ..< rate * seconds {
            let value = Int16(12_000 * sin(Double(index) * 0.05) * (1 + 0.3 * sin(Double(index) * 0.0007)))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        var header = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16)
        header += le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        header += Data("data".utf8) + le32(pcm.count)
        return header + pcm
    }

    private final class LockedEnds: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }
}

private final class StalledAudioURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class DelayedAudioURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var chunkSize = 4096
    private static var delay: TimeInterval = 0
    private static var _servedBytes = 0

    static var servedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _servedBytes
    }

    static func configure(data: Data, chunkSize: Int, delay: TimeInterval) {
        lock.lock()
        payload = data
        self.chunkSize = chunkSize
        self.delay = delay
        _servedBytes = 0
        lock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.payload
        let chunkSize = Self.chunkSize
        let delay = Self.delay
        Self.lock.unlock()

        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mp4", "Content-Length": "\(data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global(qos: .utility).async {
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset ..< end]
                Self.lock.lock()
                Self._servedBytes = end
                Self.lock.unlock()
                self.client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: delay)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

/// Serves a payload with a strong ETag and byte ranges, and a scripted reply per request.
private final class ScriptedURLProtocol: URLProtocol {
    enum Reply {
        case ranged(dropAfter: Int?)   // 200 for a whole-file request, 206 for a Range request; optionally ends in a drop
        case full                      // ignores Range: 200 with the whole file
        case changedETag, wrongRange
        case stalls(afterBytes: Int)   // sends bytes, then holds the connection open
        case timesOut                  // 15 simulated seconds pass, then NSURLErrorTimedOut
        case trickles                  // the whole file, slowly
    }

    private static let lock = NSLock()
    private static var payload = Data()
    private static var etag: String?
    private static var replies: [Reply] = []
    private static var recorded: [URLRequest] = []
    private static var clock = TestClock()

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func configure(payload: Data, etag: String?, replies: [Reply]) -> TestClock {
        lock.lock()
        defer { lock.unlock() }
        self.payload = payload
        self.etag = etag
        self.replies = replies
        recorded = []
        clock = TestClock()
        return clock
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let index = Self.recorded.count
        Self.recorded.append(request)
        let payload = Self.payload
        let etag = Self.etag
        let reply = index < Self.replies.count ? Self.replies[index] : .ranged(dropAfter: nil)
        let clock = Self.clock
        Self.lock.unlock()

        let offset = request.value(forHTTPHeaderField: "Range")
            .flatMap { $0.dropFirst("bytes=".count).dropLast().description }.flatMap(Int.init) ?? 0
        var status = offset > 0 ? 206 : 200
        var tag = etag
        var headers = ["Content-Type": "audio/wav", "Accept-Ranges": "bytes"]
        var sent = offset
        var end = payload.count
        var failure: URLError.Code?
        var holds = false
        var pause = 0.001
        switch reply {
        case let .ranged(dropAfter):
            if let dropAfter { end = min(payload.count, offset + dropAfter); failure = .networkConnectionLost }
        case .full: status = 200; sent = 0
        case .changedETag: tag = "\"v2\""
        case .wrongRange: break
        case let .stalls(afterBytes): end = min(payload.count, afterBytes); holds = true
        case .trickles: pause = 0.005
        case .timesOut: clock.advance(by: 15); client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        if let tag { headers["ETag"] = tag }
        if etag != nil {
            headers["Content-Length"] = "\(payload.count - sent)"
            if status == 206 {
                headers["Content-Range"] = "bytes \(offset + (reply.isWrongRange ? 1 : 0))-\(payload.count - 1)/\(payload.count)"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .utility).async {
            for start in stride(from: sent, to: end, by: 8192) {
                self.client?.urlProtocol(self, didLoad: payload[start ..< min(start + 8192, end)])
                Thread.sleep(forTimeInterval: pause)
            }
            if let failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(failure))
            } else if !holds {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

private extension ScriptedURLProtocol.Reply {
    var isWrongRange: Bool { if case .wrongRange = self { return true } else { return false } }
}
