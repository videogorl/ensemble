import AVFoundation
@testable import EnsembleCore
import XCTest

final class StreamingAudioPipelineTests: XCTestCase {
    func testDefaultConfigurationMarksRequestsAsAVStreaming() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://audio.test/file.m4a")))
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-pipeline-\(UUID().uuidString).m4a")

        let config = StreamingAudioPipeline.Configuration(
            request: request,
            fileExtension: "m4a",
            cacheURL: cacheURL
        )

        XCTAssertEqual(config.sessionConfiguration.networkServiceType, .avStreaming)
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

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(bufferedProgressValues.last ?? 0, 1, accuracy: 0.001)
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attrs[.size] as? Int64, Int64(data.count))
    }
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
